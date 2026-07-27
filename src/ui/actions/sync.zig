// Sync engine + image pipeline.
//
//   - sync-recap stack (end-of-batch "what changed" popup)
//   - per-game `syncGame` + `syncWorker` worker-thread offload
//   - on-disk image transcoding (cover + screenshots + thumbs)
//   - slide / thumb / cover read-through caches
//   - sync-all queue + `advanceSyncQueue` chaining
//   - cancelSync / cancelImageQueue
//   - phase-2 background screenshot worker (image queue)
//   - cover-cache disk LRU + cover pre-warmer
//
// External callers see this through the actions.zig re-export wall.

const std = @import("std");
const atomic_io = @import("util_atomic_io");
const log = std.log.scoped(.ui_actions);

/// CPU gate for image decode + JPEG encode across every in-flight
/// sync / image worker. Without this, raising the parallel worker
/// counts (Settings → Sync) to e.g. 8 + 8 = 16 simultaneous AVIF/JPEG
/// decode passes saturates every CPU core and starves the UI thread
/// of cycles — every dvui frame stalls until a worker finishes.
///
/// Implementation: an atomic counter + yield loop. We don't use
/// `std.Io.Semaphore` because the worker helpers don't have easy
/// access to the `io` context. Spin-yielding is fine here — contention
/// only kicks in when N+ workers are mid-decode, and the wait time is
/// roughly one decode pass which is plenty of "real CPU work going
/// on" for the loop to be benign.
///
/// Default cap = 4. Override via `setImageCpuLimit` from `main.zig`
/// after `std.Thread.getCpuCount` to tighten on low-core systems.
var image_cpu_limit: std.atomic.Value(u32) = .init(4);
var image_cpu_in_flight: std.atomic.Value(u32) = .init(0);

/// Replace the CPU cap. Safe to call at any time; new permits take
/// effect on the next `acquireImageCpuSlot` call.
pub fn setImageCpuLimit(permits: usize) void {
    const cap: u32 = @intCast(@max(@as(usize, 1), permits));
    image_cpu_limit.store(cap, .release);
    log.info("image-cpu cap: {d} permits", .{cap});
}

/// Acquire a CPU permit; spins-with-yield until one is free. Pair every
/// `acquireImageCpuSlot` with exactly one `releaseImageCpuSlot`.
fn acquireImageCpuSlot() void {
    while (true) {
        const cap = image_cpu_limit.load(.acquire);
        const cur = image_cpu_in_flight.load(.monotonic);
        if (cur < cap) {
            if (image_cpu_in_flight.cmpxchgWeak(cur, cur + 1, .acquire, .monotonic) == null) return;
            // CAS lost the race; retry without yielding.
            continue;
        }
        std.Thread.yield() catch {};
    }
}

fn releaseImageCpuSlot() void {
    _ = image_cpu_in_flight.fetchSub(1, .release);
}
const library = @import("library");
const f95 = @import("f95");
const f95_indexer = @import("f95_indexer");
const dvui = @import("dvui");
const image = @import("image");
const types = @import("../types.zig");
const state_mod = @import("../state.zig");
const owned_types = @import("../owned.zig");
const notify = @import("util_notify");
const job_mod = @import("../job.zig");
const common = @import("common.zig");
const downloads_mod = @import("downloads.zig");
const installer_mod = @import("installer.zig");
const launch_mod = @import("launch.zig");
const mods_act = @import("mods.zig");

const Frame = types.Frame;
const State = types.State;

const SyncRecapList = owned_types.SyncRecapList;

pub const SyncRecapEntry = owned_types.SyncRecapEntry;
pub const SyncPayload = owned_types.SyncPayload;
pub const SyncJob = owned_types.SyncJob;
pub const ImagePayload = owned_types.ImagePayload;
pub const ImageJob = owned_types.ImageJob;
pub const FastCheckPayload = owned_types.FastCheckPayload;
pub const FastCheckJob = owned_types.FastCheckJob;

// ============================================================
//  sync-batch recap — end-of-run "what changed" popup
// ============================================================
//
// During a sync-all / updates-check batch, every job that ends with
// a *different* version than what we stored (and only when we had
// a prior version to compare against — first-time syncs don't
// count as updates) appends an entry here. When the batch
// finishes, the UI raises a modal listing the games whose versions
// moved. Mirrors F95Checker's end-of-check recap.

fn syncRecapList(frame: *Frame) ?*SyncRecapList {
    if (frame.state.sync_recap) |list_ptr| return list_ptr;
    const list_ptr = frame.lib.alloc.create(SyncRecapList) catch return null;
    list_ptr.* = .empty;
    frame.state.sync_recap = list_ptr;
    return list_ptr;
}

/// Read-only accessor for the UI — returns `&.{}` when the recap
/// hasn't been touched yet.
pub fn syncRecapEntries(state: *const State) []const SyncRecapEntry {
    const list_ptr = state.sync_recap orelse return &.{};
    return list_ptr.items;
}

/// Free every entry's owned strings + the list itself. Idempotent.
pub fn freeSyncRecap(state: *State, alloc: std.mem.Allocator) void {
    if (state.sync_recap) |list_ptr| {
        for (list_ptr.items) |e| {
            alloc.free(e.name);
            alloc.free(e.old_version);
            alloc.free(e.new_version);
        }
        list_ptr.deinit(alloc);
        alloc.destroy(list_ptr);
        state.sync_recap = null;
    }
    state.sync_recap_show = false;
}

/// Clear the recap entries without destroying the backing list. Used
/// at the start of each new batch so stale entries from a previous
/// run don't leak into the new popup.
pub fn clearSyncRecap(frame: *Frame) void {
    const alloc = frame.lib.alloc;
    if (frame.state.sync_recap) |list_ptr| {
        for (list_ptr.items) |e| {
            alloc.free(e.name);
            alloc.free(e.old_version);
            alloc.free(e.new_version);
        }
        list_ptr.clearRetainingCapacity();
    }
    frame.state.sync_recap_show = false;
}

/// Append a version-bump entry. Silently drops on alloc failure —
/// the recap is convenience, not correctness, so it shouldn't fail
/// loudly.
fn pushSyncRecap(
    frame: *Frame,
    thread_id: u64,
    name: []const u8,
    old_version: []const u8,
    new_version: []const u8,
) void {
    const alloc = frame.lib.alloc;
    const name_dup = alloc.dupe(u8, name) catch return;
    errdefer alloc.free(name_dup);
    const old_dup = alloc.dupe(u8, old_version) catch {
        alloc.free(name_dup);
        return;
    };
    errdefer alloc.free(old_dup);
    const new_dup = alloc.dupe(u8, new_version) catch {
        alloc.free(name_dup);
        alloc.free(old_dup);
        return;
    };
    const list = syncRecapList(frame) orelse {
        alloc.free(name_dup);
        alloc.free(old_dup);
        alloc.free(new_dup);
        return;
    };
    list.append(alloc, .{
        .thread_id = thread_id,
        .name = name_dup,
        .old_version = old_dup,
        .new_version = new_dup,
    }) catch {
        alloc.free(name_dup);
        alloc.free(old_dup);
        alloc.free(new_dup);
    };
}

/// Flip the `auto_downloaded` flag on the recap entry matching
/// `thread_id`. Called from `drainSync` right after the auto-update
/// hook enqueues a download so the end-of-batch popup can label the
/// row. No-op when the entry isn't found (shouldn't happen — we
/// only call this right after `pushSyncRecap` on the same id — but
/// keep it forgiving rather than asserting).
fn markRecapAutoDownloaded(state: *State, thread_id: u64) void {
    const list_ptr = state.sync_recap orelse return;
    for (list_ptr.items) |*entry| {
        if (entry.thread_id == thread_id) {
            entry.auto_downloaded = true;
            return;
        }
    }
}

// ============================================================
//  sync action — worker-thread offload
// ============================================================

pub fn syncGame(frame: *Frame, game: *library.Game) void {
    // Any explicit user-initiated refresh re-enables the image
    // pipeline — a previous Cancel shouldn't keep new syncs from
    // queueing their screenshots.
    frame.state.image_fetch_suspended = false;
    spawnSyncJob(frame, game, null);
}

/// Internal worker spawner shared by the manual-button path (`syncGame`)
/// and the batch advance path (`advanceSyncQueue`). `known_lc` is the
/// pre-fetched `/fast` result when the batch indexer pre-flight already
/// learned it; null otherwise (worker will do its own `/fast` for the
/// indexer backend, or skip /fast for the scraper backend).
fn spawnSyncJob(frame: *Frame, game: *library.Game, known_lc: ?i64) void {
    const state = frame.state;
    // Idempotent guard: if this thread_id is already an active sync
    // OR already in the queue, do nothing.
    for (state.active_syncs) |maybe_slot| {
        if (maybe_slot) |j| {
            if (j.payload.thread_id == game.f95_thread_id) return;
        }
    }
    // If every sync slot is full, queue this game; drainSync will
    // pick it up as soon as a slot frees.
    if (!state.hasFreeSyncSlot()) {
        if (queuePosition(state, game.f95_thread_id) != null) return;
        appendToSyncQueue(frame.lib.alloc, state, game.f95_thread_id) catch {
            state.sync_status = .err;
            state.setSyncMsg("queue alloc failed");
        };
        return;
    }

    var tid_buf: [32]u8 = undefined;
    const tid_str = std.fmt.bufPrint(&tid_buf, "{d}", .{game.f95_thread_id}) catch {
        state.sync_status = .err;
        state.setSyncMsg("internal error: thread id format");
        return;
    };
    var url_buf: [128]u8 = undefined;
    const url_slice = f95.canonicalUrl(&url_buf, tid_str) catch {
        state.sync_status = .err;
        state.setSyncMsg("internal error: url build");
        return;
    };

    const alloc = frame.lib.alloc;
    const url_owned = alloc.dupe(u8, url_slice) catch {
        state.sync_status = .err;
        state.setSyncMsg("internal error: url dup");
        return;
    };
    const covers_owned = alloc.dupe(u8, frame.info.covers_dir) catch {
        alloc.free(url_owned);
        state.sync_status = .err;
        state.setSyncMsg("internal error: covers_dir dup");
        return;
    };

    // Pick the refresh backend at queue time, not worker time, so a
    // mid-sync settings toggle doesn't flip the in-flight job to a
    // half-different code path.
    const want_indexer = state.refresh_backend == .indexer;

    // Force /full when this row was synced under an older mapping
    // (or never indexer-synced at all). Mirrors F95Checker's
    // `last_check_before("X.Y", game.last_check_version)` check. The
    // worker honors `force_full` by skipping its unchanged-/full-skip
    // optimization.
    const parser_outdated = want_indexer and blk: {
        const v = game.last_indexer_parser_version orelse break :blk true;
        break :blk v != f95_indexer.PARSER_VERSION;
    };

    const slot = state.findEmptySyncSlot() orelse {
        // Race-safety: hasFreeSyncSlot returned true above, but if
        // something raced (it shouldn't on the UI thread) we'd hit
        // null here. Treat as "queue it" rather than panic.
        appendToSyncQueue(alloc, state, game.f95_thread_id) catch {};
        alloc.free(covers_owned);
        alloc.free(url_owned);
        return;
    };

    _ = job_mod.spawnJob(
        SyncPayload,
        syncWorker,
        alloc,
        frame.win,
        .{
            .thread_id = game.f95_thread_id,
            .url = url_owned,
            .f95_svc = frame.f95_svc,
            .indexer_client = if (want_indexer) frame.f95_indexer_client else null,
            .prev_last_indexer_change = game.last_indexer_change,
            .known_last_change = known_lc,
            .prev_indexer_parser_version = game.last_indexer_parser_version,
            .force_full = parser_outdated,
            .covers_dir = covers_owned,
            .io = frame.io,
            .progress_done = .init(0),
            .progress_total = .init(1),
        },
        slot,
    ) catch {
        alloc.free(covers_owned);
        alloc.free(url_owned);
        state.sync_status = .err;
        state.setSyncMsg("internal error: job alloc/spawn");
        return;
    };

    state.sync_status = .running;
    // Banner shows the active game's name + queue progress. If the
    // user adds another game while this one's running, the queue
    // The banner reads `state.currentSyncName()` and the queue
    // counters directly — no need to bake them into `sync_msg`. Clear
    // any lingering completion message so a stale "sync-all complete"
    // doesn't sit on top of the in-progress banner.
    state.setCurrentSyncName(game.name);
    state.sync_msg.clear();
    state.sync_status = .running;
}

/// Wall-clock milliseconds via the Zig 0.16 `std.Io.Clock` API.
/// Hides the verbose call site so the timing log macros stay tidy.
fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

/// Should this game be skipped when the user clicks Refresh All /
/// Check for updates? Match F95Checker's default refresh filter:
/// completed / abandoned / orphaned games that have been synced at
/// least once contribute essentially zero new information per refresh,
/// so spending /fast quota on them is wasteful. Unsynced games (never
/// scraped) always pass through; the first refresh has to learn their
/// state from somewhere.
fn shouldSkipInRefreshAll(g: *const library.Game) bool {
    // Never-synced rows always run — we still need their first /full.
    if (g.last_scraped_at == null) return false;
    return switch (g.dev_status) {
        .completed, .abandoned, .orphaned => true,
        else => false,
    };
}

fn syncWorker(job: *SyncJob) void {
    // Route to the indexer pipeline when state picked `.indexer` at
    // queue time. The two pipelines fill the same payload slots so
    // `drainSync` doesn't have to care which one ran.
    if (job.payload.indexer_client) |client| {
        indexerWorker(job, client);
        return;
    }

    const p = &job.payload;
    // Coarse wall-clock timing so the log shows where the seconds go.
    // Phase boundaries: HTML fetch+parse → cover fetch → screenshots.
    // The image phases dominate when a thread has many screenshots
    // because each GET is rate-limited at the F95 client level.
    const t_start = nowMs(p.io);
    const scraped = p.f95_svc.scrapeThread(p.url) catch |e| {
        // HTTP 404 from F95 means the thread is gone — dev took it
        // down, mod nuked it, whatever. We don't want to error out
        // (the user would have to dismiss a banner per orphaned
        // game during a sync-all). Instead flag the job and let
        // drainSync flip the row's dev_status to .orphaned.
        if (e == f95.errors.Error.NotFound) {
            log.info("sync tid={d} ORPHANED (F95 returned 404) elapsed_ms={d}", .{ p.thread_id, nowMs(p.io) - t_start });
            p.orphaned = true;
            job.markDone();
            return;
        }
        log.info("sync tid={d} FAIL scrape elapsed_ms={d} err={s}", .{ p.thread_id, nowMs(p.io) - t_start, @errorName(e) });
        p.err_name = @errorName(e);
        job.markFailed();
        return;
    };
    const t_after_scrape = nowMs(p.io);
    log.info(
        "sync tid={d} scrape_ms={d} name={?s} engine_str={?s} version={?s} developer={?s}",
        .{ p.thread_id, t_after_scrape - t_start, scraped.name, scraped.engine_str, scraped.version, scraped.developer },
    );

    // ScrapedThread strings are job.alloc-owned; we transfer ownership
    // onto the SyncJob fields, drainSync copies into Library.
    p.name = if (scraped.name) |n| @constCast(n) else null;
    p.version = if (scraped.version) |v| @constCast(v) else null;
    p.developer = if (scraped.developer) |d| @constCast(d) else null;
    p.rating = scraped.rating;
    p.vote_count = scraped.vote_count;
    if (scraped.engine_str) |e| {
        p.engine = library.Engine.fromBracket(e);
        job.alloc.free(e);
    }
    if (scraped.dev_status_str) |s| {
        p.dev_status = library.DevStatus.fromBracket(s);
        job.alloc.free(s);
    }
    if (scraped.last_updated_at) |ts| p.last_updated_at = ts;
    if (scraped.thread_info_md) |t| p.thread_info_md = @constCast(t);
    if (scraped.censored_str) |c| {
        p.censored = library.CensoredState.fromText(c);
        job.alloc.free(c);
    }
    if (scraped.tags.len > 0) p.tags = scraped.tags;
    if (scraped.screenshots.len > 0) p.screenshots = scraped.screenshots;
    if (scraped.description_md) |d| p.description_md = @constCast(d);
    if (scraped.changelog_md) |c| p.changelog_md = @constCast(c);
    if (scraped.reviews_md) |r| p.reviews_md = @constCast(r);
    if (scraped.downloads_md) |d| p.downloads_md = @constCast(d);
    if (scraped.download_links.len > 0) {
        p.download_links = encodeDownloadLinks(job.alloc, scraped.download_links) catch null;
        // Encoded copy lives on the job; free the source list now.
        for (scraped.download_links) |link| {
            job.alloc.free(link.url);
            if (link.label) |lab| job.alloc.free(lab);
        }
        job.alloc.free(scraped.download_links);
    }

    // Phase-1 work in this worker is intentionally minimal: text +
    // cover only. Screenshots are deferred to a background image
    // worker (see ImageJob / drainImageQueue) so the library row
    // becomes usable as soon as the cover + metadata commit. The
    // image-fetch phase used to dominate wall time (≥1.5s per shot
    // through the rate limiter) and blocked the row from showing
    // until the very last screenshot landed.
    const want_cover = scraped.cover_url != null;
    var cover_path_buf: [256]u8 = undefined;
    const cover_present = if (want_cover) blk: {
        const cp = std.fmt.bufPrint(&cover_path_buf, "{s}/{d}", .{ p.covers_dir, p.thread_id }) catch break :blk false;
        break :blk fileExists(p.io, cp);
    } else true;

    const t_before_images = nowMs(p.io);
    if (!want_cover or cover_present) {
        // Nothing to fetch in this worker. Leave `progress_total` at
        // its initial 1 so the banner's sub-progress doesn't flicker.
        if (scraped.cover_url) |cu| job.alloc.free(cu);
        log.info(
            "sync tid={d} cover_cached={any} shots_deferred={d}",
            .{ p.thread_id, want_cover and cover_present, scraped.screenshots.len },
        );
    } else {
        // Cover work coming up — publish the planned step count.
        p.progress_total.store(2, .release);
        p.progress_done.store(1, .release);
        job_mod.refreshDebounced(job.win, @src());
        if (scraped.cover_url) |cu| {
            defer job.alloc.free(cu);
            if (job.cancelRequested()) {
                log.info("sync tid={d} cancelled before cover fetch", .{p.thread_id});
            } else {
                const t_c0 = nowMs(p.io);
                if (fetchAndWriteCover(job, cu)) {
                    p.cover_updated = true;
                    log.info("sync tid={d} cover_ms={d}", .{ p.thread_id, nowMs(p.io) - t_c0 });
                } else |_| {
                    log.info("sync tid={d} cover FAIL elapsed_ms={d}", .{ p.thread_id, nowMs(p.io) - t_c0 });
                }
                _ = p.progress_done.fetchAdd(1, .release);
                job_mod.refreshDebounced(job.win, @src());
            }
        }
    }

    // If the user clicked Cancel, mark the job failed so drainSync
    // skips the applyScrape write — the scraped data is still owned
    // by job and will be freed via cleanup(). This keeps cancellation
    // observable to the UI without partial-row commits.
    if (job.cancelRequested()) {
        log.info("sync tid={d} TOTAL_ms={d} CANCELLED", .{ p.thread_id, nowMs(p.io) - t_start });
        p.err_name = "Cancelled";
        job.markFailed();
        return;
    }

    log.info(
        "sync tid={d} TOTAL_ms={d} scrape_ms={d} images_ms={d}",
        .{ p.thread_id, nowMs(p.io) - t_start, t_after_scrape - t_start, nowMs(p.io) - t_before_images },
    );
    job.markDone();
}

/// F95Indexer pipeline. Hits `/fast` to learn the latest change ts;
/// only pulls `/full/{id}?ts=<ts>` when that's newer than the persisted
/// `last_indexer_change`. Fills the same payload slots the scraper
/// path does, so `drainSync` is backend-agnostic.
///
/// Per-game chunk size 1 today; sync-all batching to chunk-of-10 is a
/// follow-up optimization (see docs/superpowers/specs/2026-05-26-...).
fn indexerWorker(job: *SyncJob, client: *f95_indexer.Client) void {
    const p = &job.payload;
    const t_start = nowMs(p.io);

    // If the batch pre-flight already ran `/fast` for this game, skip
    // the per-game call. Otherwise do a single-id `/fast` here (used
    // for single-game Refresh on a detail row).
    const last_change: i64 = if (p.known_last_change) |kt| kt else blk: {
        const ids = [_]u64{p.thread_id};
        const fast_results = client.fastCheck(&ids) catch |e| {
            log.info("indexer tid={d} /fast FAIL err={s}", .{ p.thread_id, @errorName(e) });
            p.err_name = @errorName(e);
            job.markFailed();
            return;
        };
        defer job.alloc.free(fast_results);

        if (fast_results.len == 0) {
            log.info("indexer tid={d} /fast returned empty", .{p.thread_id});
            p.err_name = "indexer /fast returned no results";
            job.markFailed();
            return;
        }
        break :blk fast_results[0].last_change;
    };
    p.new_last_indexer_change = last_change;

    // Skip `/full` when the indexer's last_change hasn't moved past
    // our recorded value AND the row was synced under the current
    // mapping version — F95Checker's same optimization, with the
    // mapping-version migration check added so a parser bump
    // propagates to every previously-synced row.
    const need_full = blk: {
        if (p.force_full) break :blk true;
        const prev = p.prev_last_indexer_change orelse break :blk true;
        if (last_change > prev) break :blk true;
        // Last_change didn't move. If our mapping has evolved since
        // this row was filled, treat it as needing /full anyway.
        const v = p.prev_indexer_parser_version orelse break :blk true;
        break :blk v != f95_indexer.PARSER_VERSION;
    };
    if (!need_full) {
        log.info(
            "indexer tid={d} unchanged last_change={d} elapsed_ms={d}",
            .{ p.thread_id, last_change, nowMs(p.io) - t_start },
        );
        // Mark done so drainSync can persist new_last_indexer_change.
        // All content slots stay null → applyScrape is a no-op for
        // those fields.
        job.markDone();
        return;
    }

    var data = client.fullCheck(p.thread_id, last_change) catch |e| {
        if (e == f95_indexer.Error.ThreadMissing) {
            log.info("indexer tid={d} ORPHANED (/full 404)", .{p.thread_id});
            p.orphaned = true;
            job.markDone();
            return;
        }
        log.info("indexer tid={d} /full FAIL err={s}", .{ p.thread_id, @errorName(e) });
        p.err_name = @errorName(e);
        job.markFailed();
        return;
    };
    defer data.deinit();

    // Strings in `data` are arena-owned; dupe into job.alloc which is
    // what drainSync expects on the payload slots.
    if (data.name) |n| p.name = job.alloc.dupe(u8, n) catch null;
    if (data.version) |v| p.version = job.alloc.dupe(u8, v) catch null;
    if (data.developer) |d| p.developer = job.alloc.dupe(u8, d) catch null;
    if (data.description) |s| p.description_md = job.alloc.dupe(u8, s) catch null;
    if (data.changelog) |s| p.changelog_md = job.alloc.dupe(u8, s) catch null;
    if (data.score) |s| p.rating = s;
    if (data.votes) |v| p.vote_count = v;
    if (data.last_updated) |t| p.last_updated_at = t;
    if (data.previews_urls.len > 0) {
        p.screenshots = dupStringList(job.alloc, data.previews_urls) catch null;
    }

    // F95Checker int → f69 enum translations. These are what the user
    // was missing vs the scraper path — the recipe-resolver, sort, and
    // filter widgets all key off `engine` / `dev_status`, so leaving
    // them null made indexer-synced rows feel "less synced".
    if (data.type_int) |t| p.engine = f95_indexer.engineFromTypeInt(t);
    if (data.status_int) |s| p.dev_status = f95_indexer.devStatusFromStatusInt(s);

    // Tags: indexer returns numeric IDs (F95Checker `Tag` enum) plus
    // a parallel `unknown_tags` slice for strings outside the table.
    // The embedded tag_table translates IDs back to the human-readable
    // labels f69 stores.
    if (data.tag_ids.len > 0 or data.unknown_tags.len > 0) {
        p.tags = f95_indexer.translateTags(job.alloc, data.tag_ids, data.unknown_tags) catch null;
    }

    // Reconstruct the "Key: Value" header block (Thread Updated /
    // Developer / Version / Engine / Status / Censored / Language).
    // Mines Censored + Language from the translated tags above, so it
    // must run AFTER `p.tags` is populated. Indexer doesn't expose
    // Release Date or OS — those fields are only in the verbatim OP
    // body the scraper preserves; an indexer-only refresh on a row
    // that's never been scraper-synced won't have them.
    const tags_for_header: []const []const u8 = if (p.tags) |t| t else &.{};
    if (f95_indexer.buildThreadInfoMd(job.alloc, &data, tags_for_header)) |info_md| {
        if (info_md.len > 0) {
            p.thread_info_md = info_md;
        } else {
            job.alloc.free(info_md);
        }
    } else |_| {}

    // Downloads: indexer returns groups of (label, [(host, url), ...]).
    // Encode into the same line format the scraper produces so
    // `applyScrape` can stash them in `Game.download_links`, and build
    // a markdown blob for the Downloads tab.
    if (data.downloads.len > 0) {
        p.download_links = f95_indexer.encodeDownloadLinks(job.alloc, data.downloads) catch null;
        p.downloads_md = f95_indexer.buildDownloadsMd(job.alloc, data.downloads) catch null;
    }

    // Cover handling — same on-disk layout as the scraper path. Fetch
    // only when the file is missing; URL-changed detection would need
    // a Game.cover_url roundtrip we don't have here (drainSync does
    // it post-hoc via applyScrape + image-queue enqueue).
    const want_cover = data.image_url != null;
    var cover_path_buf: [256]u8 = undefined;
    const cover_present = if (want_cover) blk: {
        const cp = std.fmt.bufPrint(&cover_path_buf, "{s}/{d}", .{ p.covers_dir, p.thread_id }) catch break :blk false;
        break :blk fileExists(p.io, cp);
    } else true;

    if (want_cover and !cover_present) {
        p.progress_total.store(2, .release);
        p.progress_done.store(1, .release);
        job_mod.refreshDebounced(job.win, @src());
        if (data.image_url) |url| {
            if (!job.cancelRequested()) {
                const t_c0 = nowMs(p.io);
                if (fetchAndWriteCover(job, url)) {
                    p.cover_updated = true;
                    log.info("indexer tid={d} cover_ms={d}", .{ p.thread_id, nowMs(p.io) - t_c0 });
                } else |_| {
                    log.info("indexer tid={d} cover FAIL", .{p.thread_id});
                }
                _ = p.progress_done.fetchAdd(1, .release);
                job_mod.refreshDebounced(job.win, @src());
            }
        }
    }

    if (job.cancelRequested()) {
        log.info("indexer tid={d} TOTAL_ms={d} CANCELLED", .{ p.thread_id, nowMs(p.io) - t_start });
        p.err_name = "Cancelled";
        job.markFailed();
        return;
    }

    // Successful /full ran end-to-end — stamp the mapping version so
    // a future refresh can detect parser drift and force /full again
    // when needed. Mirrors F95Checker setting `game.last_check_version
    // = globals.version` after every successful full_check.
    p.new_indexer_parser_version = f95_indexer.PARSER_VERSION;
    log.info("indexer tid={d} TOTAL_ms={d}", .{ p.thread_id, nowMs(p.io) - t_start });
    job.markDone();
}

/// Duplicate a list of strings into `alloc`-owned storage. Used by the
/// indexer worker to move tags / previews_urls off the arena that
/// `ThreadData.deinit()` will free.
fn dupStringList(
    alloc: std.mem.Allocator,
    src: []const []const u8,
) ![]const []const u8 {
    var out = try alloc.alloc([]const u8, src.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |s| alloc.free(s);
        alloc.free(out);
    }
    while (i < src.len) : (i += 1) {
        out[i] = try alloc.dupe(u8, src[i]);
    }
    return out;
}

/// Encode a `DownloadLink` slice into the persisted line format —
/// `<host>\t<url>\t<label>` — and return an outer slice owned by
/// `alloc` (each row also `alloc`-owned). Caller frees inner + outer.
fn encodeDownloadLinks(alloc: std.mem.Allocator, links: []const f95.DownloadLink) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    for (links) |link| {
        const host = @tagName(link.host);
        const label = link.label orelse "";
        const line = try std.fmt.allocPrint(alloc, "{s}\t{s}\t{s}", .{ host, link.url, label });
        errdefer alloc.free(line);
        try out.append(alloc, line);
    }
    return try out.toOwnedSlice(alloc);
}

/// Worker-thread helper: fetch image bytes via the same rate-limited
/// HTTP client and atomically replace the on-disk cover file.
///
/// The decode + JPEG-encode work is gated by `image_cpu_sem` so
/// raising the parallel-worker caps to (say) 8+8 doesn't run 16
/// simultaneous AVIF decodes — which would saturate every CPU core
/// and freeze the UI. Network fetch is OUTSIDE the gate so I/O still
/// parallelizes freely.
fn fetchAndWriteCover(job: *SyncJob, cover_url: []const u8) !void {
    const p = &job.payload;
    const raw = try p.f95_svc.client.getImage(cover_url);
    defer job.alloc.free(raw);

    acquireImageCpuSlot();
    defer releaseImageCpuSlot();

    const ready = prepareImageForDisk(job.alloc, raw) catch |e| {
        std.log.scoped(.ui_actions).warn("cover transcode failed ({s}): {s}", .{ @errorName(e), cover_url });
        return e;
    };
    defer job.alloc.free(ready);

    var path_buf: [256]u8 = undefined;
    const path = try coverPath(&path_buf, p.covers_dir, p.thread_id);
    try writeAtomic(p.io, path, ready);

    // Also write the thumbnail. Failure here is non-fatal — the lazy
    // path in `thumbBytes` will regenerate from the full-size file.
    writeThumbBeside(job.alloc, p.io, path, ready) catch |e| {
        std.log.scoped(.ui_actions).warn("cover thumb gen failed: {s}", .{@errorName(e)});
    };
}

/// Thin shim around `util/atomic_io.writeFileAtomic`. dvui reads
/// images via stb, so a half-written file would render garbage —
/// the rename ensures readers only ever see the complete file.
fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try atomic_io.writeFileAtomic(io, path, bytes);
}

/// Fetch a single screenshot to `<covers_dir>/<tid>.s<n>`. Same atomic
/// write pattern as the cover; same CPU-semaphore gating around the
/// decode+encode work so 8 parallel image workers can't run 8
/// simultaneous AVIF decodes.
fn fetchAndWriteScreenshot(job: *SyncJob, url: []const u8, idx: usize) !void {
    const p = &job.payload;
    const raw = try p.f95_svc.client.getImage(url);
    defer job.alloc.free(raw);

    acquireImageCpuSlot();
    defer releaseImageCpuSlot();

    const ready = prepareImageForDisk(job.alloc, raw) catch |e| {
        std.log.scoped(.ui_actions).warn("screenshot {d} transcode failed ({s}): {s}", .{ idx, @errorName(e), url });
        return e;
    };
    defer job.alloc.free(ready);

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{d}.s{d}", .{ p.covers_dir, p.thread_id, idx });
    try writeAtomic(p.io, path, ready);

    writeThumbBeside(job.alloc, p.io, path, ready) catch |e| {
        std.log.scoped(.ui_actions).warn("screenshot {d} thumb gen failed: {s}", .{ idx, @errorName(e) });
    };
}

/// Generate a thumbnail from the JPEG bytes we just wrote and save it
/// to `<full_path>.t` atomically. Pulled into its own helper because
/// both cover and screenshot fetches need it.
fn writeThumbBeside(alloc: std.mem.Allocator, io: std.Io, full_path: []const u8, ready_bytes: []const u8) !void {
    const thumb_bytes = try thumbify(alloc, ready_bytes);
    defer alloc.free(thumb_bytes);
    var tbuf: [320]u8 = undefined;
    const tpath = try std.fmt.bufPrint(&tbuf, "{s}.t", .{full_path});
    try writeAtomic(io, tpath, thumb_bytes);
}

/// Normalize downloaded image bytes for on-disk caching.
///
/// Every supported format is decoded to RGBA, downscaled to fit under
/// the SDL3 GPU transfer-buffer ceiling (`image.MAX_DIM` per side),
/// and re-encoded as JPEG quality 90. The disk cache thus contains
/// uniform JPEGs at known-safe dimensions — dvui's render-time stb
/// path can never hit the over-2048-pixel-per-side memcpy that crashed
/// on a 1 MiB animated GIF from the F95 CDN.
///
/// Format routing:
///   - AVIF / HEIF (`ftyp`-prefixed) → libavif (statically linked)
///   - JPEG / PNG / GIF / BMP        → stb_image (vendored by dvui)
///   - anything else                  → `UnsupportedImageFormat`
///
/// GIFs lose animation here (stb returns the first frame only). That's
/// the same trade-off the rest of the pipeline made anyway — dvui can't
/// animate GIFs. If we ever want playback we'd swap this for
/// `stbi_load_gif_from_memory` and a per-game frame cache.
fn prepareImageForDisk(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (image.isAvif(raw)) {
        var dec = try image.decodeAvif(alloc, raw);
        defer dec.deinit();
        return try fitAndEncodeJpeg(alloc, dec.rgba, dec.width, dec.height);
    }
    if (image.isStbFormat(raw)) {
        return try decodeStbAndEncodeJpeg(alloc, raw);
    }
    return error.UnsupportedImageFormat;
}

/// stb decode → fit → JPEG encode. We must memcpy stb's output into
/// our own allocator because `stbi_image_free` expects libc's free
/// (stb is built without libc malloc shims, but the freer matches
/// stb's internal allocator).
fn decodeStbAndEncodeJpeg(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var iw: c_int = 0;
    var ih: c_int = 0;
    var ic: c_int = 0;
    const data = dvui.c.stbi_load_from_memory(
        raw.ptr,
        @intCast(raw.len),
        &iw,
        &ih,
        &ic,
        4, // request RGBA
    ) orelse {
        log.warn("stbi_load_from_memory failed", .{});
        return error.DecodeFailed;
    };
    defer dvui.c.stbi_image_free(data);

    if (iw <= 0 or ih <= 0) return error.DecodeFailed;
    const w: u32 = @intCast(iw);
    const h: u32 = @intCast(ih);
    const total: usize = @as(usize, w) * h * 4;
    return try fitAndEncodeJpeg(alloc, data[0..total], w, h);
}

/// Halve-until-fits, then JPEG-encode. Always writes a heap-allocated
/// slice; caller frees.
fn fitAndEncodeJpeg(alloc: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    const fit = try image.fitToMaxDim(alloc, rgba, w, h);
    defer alloc.free(fit.rgba);
    return try encodeRgbaToJpeg(alloc, fit.rgba, fit.w, fit.h, JPEG_QUALITY_FULL);
}

/// JPEG qualities. Full-size cache uses 90 (near-imperceptible loss);
/// thumbnails use 85 (still clean at 96×54, smaller files).
const JPEG_QUALITY_FULL: c_int = 90;
const JPEG_QUALITY_THUMB: c_int = 85;

/// Encode an RGBA8 buffer to a JPEG byte stream via stb_image_write
/// (vendored by dvui). stb's JPEG encoder ignores the alpha channel,
/// which is fine for game screenshots.
fn encodeRgbaToJpeg(alloc: std.mem.Allocator, rgba: []const u8, w: u32, h: u32, quality: c_int) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(alloc, 4096);
    errdefer aw.deinit();

    const res = dvui.c.stbi_write_jpg_to_func(
        &stbiJpegWriteCallback,
        @ptrCast(&aw.writer),
        @intCast(w),
        @intCast(h),
        4, // RGBA in; stb drops the alpha channel for JPEG
        rgba.ptr,
        quality,
    );
    if (res == 0) return error.JpegEncodeFailed;
    return aw.toOwnedSlice();
}

/// Decode → resize to thumbnail cap → JPEG q85 encode. The result
/// is what we save as `<tid>.t` / `<tid>.s<n>.t` so the ribbon, list
/// rows, and grid cards never have to decode a full-size image.
fn thumbify(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (image.isAvif(raw)) {
        var dec = try image.decodeAvif(alloc, raw);
        defer dec.deinit();
        const fit = try image.fitToCap(alloc, dec.rgba, dec.width, dec.height, image.THUMB_CAP);
        defer alloc.free(fit.rgba);
        return try encodeRgbaToJpeg(alloc, fit.rgba, fit.w, fit.h, JPEG_QUALITY_THUMB);
    }
    if (image.isStbFormat(raw)) {
        var iw: c_int = 0;
        var ih: c_int = 0;
        var ic: c_int = 0;
        const data = dvui.c.stbi_load_from_memory(raw.ptr, @intCast(raw.len), &iw, &ih, &ic, 4) orelse {
            log.warn("thumbify: stbi_load failed", .{});
            return error.DecodeFailed;
        };
        defer dvui.c.stbi_image_free(data);
        if (iw <= 0 or ih <= 0) return error.DecodeFailed;
        const w: u32 = @intCast(iw);
        const h: u32 = @intCast(ih);
        const total: usize = @as(usize, w) * h * 4;
        const fit = try image.fitToCap(alloc, data[0..total], w, h, image.THUMB_CAP);
        defer alloc.free(fit.rgba);
        return try encodeRgbaToJpeg(alloc, fit.rgba, fit.w, fit.h, JPEG_QUALITY_THUMB);
    }
    return error.UnsupportedImageFormat;
}

/// stb_image_write callback that funnels its emitted bytes into a
/// `std.Io.Writer.Allocating`. stb writes the JPEG in chunks; we
/// concatenate them all into the writer's growable buffer.
fn stbiJpegWriteCallback(ctx: ?*anyopaque, data_ptr: ?*anyopaque, len: c_int) callconv(.c) void {
    const writer: *std.Io.Writer = @ptrCast(@alignCast(ctx.?));
    if (data_ptr == null or len <= 0) return;
    const bytes: []const u8 = @as([*]const u8, @ptrCast(@alignCast(data_ptr.?)))[0..@intCast(len)];
    writer.writeAll(bytes) catch |err| {
        std.log.scoped(.ui_actions).warn("jpeg encode write failed: {s}", .{@errorName(err)});
    };
}

/// File path for a screenshot — paired with `coverPath` for the cover.
pub fn screenshotPath(buf: []u8, covers_dir: []const u8, thread_id: u64, idx: usize) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}/{d}.s{d}", .{ covers_dir, thread_id, idx });
}

/// True when on-disk image set already matches the scrape: cover
/// file present (when `want_cover`), s1..s<want_count> all present,
/// and s<want_count+1> absent (so we re-fetch when an image was
/// added). Used to short-circuit the per-game image fetch loop on
/// re-sync. Any stat error is treated as "missing".
fn imagesAlreadyFetched(
    io: std.Io,
    covers_dir: []const u8,
    thread_id: u64,
    want_cover: bool,
    want_count: usize,
) bool {
    var path_buf: [256]u8 = undefined;

    if (want_cover) {
        const cover = std.fmt.bufPrint(&path_buf, "{s}/{d}", .{ covers_dir, thread_id }) catch return false;
        if (!fileExists(io, cover)) return false;
    }

    var i: usize = 1;
    while (i <= want_count) : (i += 1) {
        const p = std.fmt.bufPrint(&path_buf, "{s}/{d}.s{d}", .{ covers_dir, thread_id, i }) catch return false;
        if (!fileExists(io, p)) return false;
    }

    // Reject when the on-disk set has MORE files than the scrape —
    // means the OP gained/lost screenshots and we should re-fetch
    // wholesale. (Cheap check; only one extra stat per call.)
    const extra = std.fmt.bufPrint(&path_buf, "{s}/{d}.s{d}", .{ covers_dir, thread_id, want_count + 1 }) catch return false;
    if (fileExists(io, extra)) return false;

    return true;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

/// Return cached slide bytes for the current (thread, idx) pair. If
/// the active slide changed since last call, drop the old buffer and
/// load the new file. The pointer stays stable across frames while
/// the user is on the same slide, so dvui's texture cache hits and
/// no re-decode/upload happens per frame.
///
/// Returns null if the file is missing on disk (screenshot not yet
/// synced) — callers should render a placeholder.
///
/// Cache lifetime is tied to the slide selection. `freeSlideCache`
/// must be called when the detail page closes or the user navigates
/// to a different game so we don't leak the buffer.
pub fn slideBytes(frame: *Frame, thread_id: u64, idx: usize) ?[]const u8 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "{s}/{d}.s{d}",
        .{ frame.info.covers_dir, thread_id, idx },
    ) catch return null;
    return slideSlotBytes(frame, thread_id, idx, path);
}

/// Shared slot lookup for the multi-slot slide cache. `slot_idx` is
/// the index into `state.slide_cache_bytes`: 0 = full-resolution cover,
/// 1..N = screenshots. `path` is the on-disk file the slot should
/// hold. Thread-switch detection lives here, so both `slideBytes` and
/// `coverFullBytes` share the same lifetime semantics.
///
/// On a slot miss the file read is dispatched to a detached worker
/// (`slide_load_job` slot). The caller sees `null` for this frame;
/// the bytes land via `drainSlideLoads` on a subsequent frame. One
/// in-flight job at a time — fine for sequential carousel use.
fn slideSlotBytes(frame: *Frame, thread_id: u64, slot_idx: usize, path: []const u8) ?[]const u8 {
    const state = frame.state;
    if (state.slide_cache_thread != thread_id) {
        freeSlideCache(state, frame.lib.alloc);
        state.slide_cache_thread = thread_id;
    }
    if (slot_idx >= state_mod.SLIDE_CACHE_SLOTS) return null;
    if (state.slide_cache_bytes[slot_idx]) |b| return b;
    // Slot empty — try to put a loader in flight. If one is already
    // running (possibly for a different slot, since we serialise),
    // the caller renders a placeholder this frame and tries again
    // next frame.
    if (state.slide_load_job == null and path.len <= 256) {
        spawnSlideLoad(frame, thread_id, slot_idx, path);
    }
    return null;
}

fn slideLoadWorker(job: *owned_types.SlideLoadJob) void {
    const p = &job.payload;
    if (job.cancelRequested()) {
        p.err_name = "cancelled";
        job.markFailed();
        return;
    }
    const path = p.path[0..p.path_len];
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        p.io,
        path,
        p.bytes_alloc,
        .limited(16 * 1024 * 1024),
    ) catch |e| {
        p.err_name = @errorName(e);
        job.markFailed();
        return;
    };
    p.bytes = bytes;
    job.markDone();
}

fn spawnSlideLoad(frame: *Frame, thread_id: u64, slot_idx: usize, path: []const u8) void {
    std.debug.assert(path.len <= 256);
    var payload: owned_types.SlideLoadPayload = .{
        .io = frame.io,
        .bytes_alloc = frame.lib.alloc,
        .slot_idx = slot_idx,
        .thread_id = thread_id,
        .path_len = path.len,
    };
    @memcpy(payload.path[0..path.len], path);
    _ = job_mod.spawnJob(
        owned_types.SlideLoadPayload,
        slideLoadWorker,
        frame.lib.alloc,
        frame.win,
        payload,
        &frame.state.slide_load_job,
    ) catch return;
}

/// Reap the single in-flight slide loader. On `.done`, transfer
/// bytes into the matching cache slot (if the game hasn't switched
/// underneath us — otherwise drop them). On `.failed`, just clear
/// the slot. Caller-frame ownership: `frame.lib.alloc` matches the
/// allocator the worker used.
pub fn drainSlideLoads(frame: *Frame) void {
    const state = frame.state;
    const job = state.slide_load_job orelse return;
    switch (job.phaseGet()) {
        .pending => return,
        .done => {
            const same_game = state.slide_cache_thread == job.payload.thread_id;
            const idx = job.payload.slot_idx;
            if (same_game and idx < state_mod.SLIDE_CACHE_SLOTS and
                state.slide_cache_bytes[idx] == null)
            {
                state.slide_cache_bytes[idx] = job.payload.bytes;
                job.payload.bytes = null;
            } else if (job.payload.bytes) |b| {
                frame.lib.alloc.free(b);
                job.payload.bytes = null;
            }
        },
        .failed => {},
    }
    state.slide_load_job = null;
    job.alloc.destroy(job);
}

/// Drop every slot of the slide cache. Call on detail-page exit, on
/// Sync (the bytes on disk just got rewritten), and when navigating
/// to a different game. The in-flight loader (if any) is asked to
/// cancel; `drainSlideLoads` reaps it next frame and discards any
/// bytes whose `thread_id` no longer matches.
pub fn freeSlideCache(state: *State, alloc: std.mem.Allocator) void {
    for (&state.slide_cache_bytes) |*slot| {
        if (slot.*) |b| alloc.free(b);
        slot.* = null;
    }
    if (state.slide_load_job) |j| j.cancel.store(true, .release);
    state.slide_cache_thread = null;
}

/// Return cached bytes for the thumbnail-strip slot at `idx` for the
/// given thread. Slide 0 is the cover; 1..N are screenshots. Bytes
/// are loaded lazily on first call per slot and stay cached for the
/// lifetime of the user's stay on this game's detail page. Returns
/// null when the file is missing on disk.
pub fn thumbBytes(frame: *Frame, thread_id: u64, idx: usize) ?[]const u8 {
    const state = frame.state;

    if (state.thumb_cache_thread != thread_id) {
        // Different game — drop the entire strip and reset.
        for (&state.thumb_cache_bytes) |*slot| {
            if (slot.*) |b| frame.lib.alloc.free(b);
            slot.* = null;
        }
        state.thumb_cache_thread = thread_id;
    }

    if (idx >= state.thumb_cache_bytes.len) return null;

    if (state.thumb_cache_bytes[idx] == null) {
        // All image work happens at sync time — `.t` files are
        // written alongside the full-size cover/screenshots by
        // `writeThumbBeside`. If the thumb is missing here, the
        // game was synced before the thumb pipeline existed; the
        // renderer shows a placeholder. Re-sync (or a future
        // "Fix images" button) regenerates everything.
        var thumb_buf: [256]u8 = undefined;
        const thumb_path = if (idx == 0)
            (std.fmt.bufPrint(&thumb_buf, "{s}/{d}.t", .{ frame.info.covers_dir, thread_id }) catch return null)
        else
            (std.fmt.bufPrint(&thumb_buf, "{s}/{d}.s{d}.t", .{ frame.info.covers_dir, thread_id, idx }) catch return null);
        state.thumb_cache_bytes[idx] = std.Io.Dir.cwd().readFileAlloc(
            frame.io,
            thumb_path,
            frame.lib.alloc,
            .limited(2 * 1024 * 1024),
        ) catch null;
    }
    return state.thumb_cache_bytes[idx];
}

/// Drop the thumb-strip cache. Call on detail-page exit, when
/// switching games (`thumbBytes` does this automatically), and on
/// Sync (the on-disk bytes just got rewritten).
pub fn freeThumbCache(state: *State, alloc: std.mem.Allocator) void {
    for (&state.thumb_cache_bytes) |*slot| {
        if (slot.*) |b| {
            alloc.free(b);
            slot.* = null;
        }
    }
    state.thumb_cache_thread = null;
}

/// Called once per frame. Iterates every parallel sync slot; for each
/// slot that holds a worker, drains its terminal phase and either
/// applies the result or surfaces the error. After all slots are
/// drained, refills empty ones from the sync queue (so a sync-all
/// batch keeps `MAX_PARALLEL_SYNC` workers in flight until exhausted).
pub fn drainSync(frame: *Frame) void {
    const state = frame.state;
    var any_drained: bool = false;
    for (&state.active_syncs) |*slot| {
        if (slot.* == null) continue;
        // Snapshot before drain so we know to do post-drain bookkeeping
        // for THIS slot even after drainBackgroundJob nulls it.
        any_drained = true;
        job_mod.drainBackgroundJob(
            SyncPayload,
            onSyncDone,
            onSyncFailed,
            frame,
            slot,
        );
    }
    if (!any_drained) return;
    // Clear the active-sync banner once nothing's running. Single-game
    // mid-flight ⇒ banner stays. Batch refill happens unconditionally.
    if (!state.anyActiveSync()) state.active_sync_name.clear();
    if (state.sync_queue != null) advanceSyncQueue(frame);
}

/// Drop any cover/slide/thumb caches keyed on this job's thread id
/// before transferring ownership back to the UI thread. Runs from
/// both onSyncDone and onSyncFailed so cancelled / failed jobs that
/// still wrote a fresh cover (cover_updated) don't leave stale bytes
/// in the cache.
fn invalidateCachesForJob(frame: *Frame, job: *SyncJob) void {
    const state = frame.state;
    const p = &job.payload;
    if (p.cover_updated) {
        invalidateCover(state, frame.lib.alloc, p.thread_id);
    }
    if (state.slide_cache_thread == p.thread_id) {
        freeSlideCache(state, frame.lib.alloc);
    }
    if (state.thumb_cache_thread == p.thread_id) {
        freeThumbCache(state, frame.lib.alloc);
    }
}

/// Free every payload-owned heap allocation. Called from both
/// handlers right before drainBackgroundJob destroys the carrier.
/// Idempotent — every field is null-checked.
fn freeSyncPayload(job: *SyncJob) void {
    const p = &job.payload;
    job.alloc.free(p.url);
    job.alloc.free(p.covers_dir);
    if (p.name) |n| job.alloc.free(n);
    if (p.version) |v| job.alloc.free(v);
    if (p.developer) |d| job.alloc.free(d);
    if (p.tags) |ts| {
        for (ts) |t| job.alloc.free(t);
        job.alloc.free(ts);
    }
    if (p.screenshots) |ss| {
        for (ss) |x| job.alloc.free(x);
        job.alloc.free(ss);
    }
    if (p.description_md) |d| job.alloc.free(d);
    if (p.changelog_md) |c| job.alloc.free(c);
    if (p.reviews_md) |r| job.alloc.free(r);
    if (p.downloads_md) |d| job.alloc.free(d);
    if (p.thread_info_md) |t| job.alloc.free(t);
    if (p.download_links) |dl| {
        for (dl) |d| job.alloc.free(d);
        job.alloc.free(dl);
    }
}

fn onSyncFailed(frame: *Frame, job: *SyncJob) void {
    const state = frame.state;
    const p = &job.payload;
    invalidateCachesForJob(frame, job);
    // User cancellation is not an error path — silently clean up
    // and DO NOT chain into the rest of the queue (cancelSync
    // already freed it). Real failures still surface a banner.
    const was_cancelled = p.err_name != null and std.mem.eql(u8, p.err_name.?, "Cancelled");
    if (was_cancelled) {
        state.sync_status = .idle;
        state.sync_msg.clear();
        freeSyncPayload(job);
        return;
    }
    state.sync_status = .err;
    const friendly = common.friendlyError(p.err_name orelse "?");
    var emsg: [128]u8 = undefined;
    const m = if (state.sync_queue) |_|
        std.fmt.bufPrint(&emsg, "sync-all: {d}/{d} — failed: {s}", .{ state.sync_queue_started, state.sync_queue_total, friendly }) catch "sync-all error"
    else
        std.fmt.bufPrint(&emsg, "scrape failed: {s}", .{friendly}) catch "scrape failed";
    state.setSyncMsg(m);
    // A single-game sync failure is a discrete user action — surface it as
    // a toast so it can't be missed. In a sync-all queue this handler fires
    // once PER failing game, so a toast each would spam; there the status
    // bar's err line carries the outcome instead.
    if (state.sync_queue == null) state.notifyErr(m);
    freeSyncPayload(job);
}

fn onSyncDone(frame: *Frame, job: *SyncJob) void {
    const state = frame.state;
    const p = &job.payload;
    invalidateCachesForJob(frame, job);

    // .done — find the row by thread_id and apply numeric fields.
    var target: ?*library.Game = null;
    for (frame.games) |*gg| {
        if (gg.f95_thread_id == p.thread_id) {
            target = gg;
            break;
        }
    }
    const game = target orelse {
        state.sync_status = .err;
        state.setSyncMsg("synced game no longer in list");
        freeSyncPayload(job);
        return;
    };

    const now_s = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();

    // Orphaned outcome: F95 returned 404 for this thread. Don't
    // clobber the row's good data with the empty scrape — only flip
    // dev_status + bump last_scraped_at so the badge updates and the
    // user can see the row was checked.
    if (p.orphaned) {
        frame.lib.applyScrape(game, .{
            .dev_status = .orphaned,
            .last_scraped_at = now_s,
            .last_indexer_change = p.new_last_indexer_change,
            .last_indexer_parser_version = p.new_indexer_parser_version,
        }) catch |e| {
            state.sync_status = .err;
            var emsg: [80]u8 = undefined;
            const m = std.fmt.bufPrint(&emsg, "DB write failed: {s}", .{@errorName(e)}) catch "DB write failed";
            state.setSyncMsg(m);
            freeSyncPayload(job);
            return;
        };
        // In-place edit (dev_status → orphaned) — invalidate the filter cache.
        state.game_edit_gen +%= 1;
        state.sync_status = .ok;
        state.sort_applied_column = null;
        state.sort_applied_dir = null;
        var orph_buf: [128]u8 = undefined;
        const m = if (state.sync_queue) |_|
            std.fmt.bufPrint(&orph_buf, "sync-all: {d}/{d} — orphaned (thread gone from F95)", .{ state.sync_queue_started, state.sync_queue_total }) catch "orphaned"
        else
            std.fmt.bufPrint(&orph_buf, "orphaned — F95 returned 404 for thread {d}", .{p.thread_id}) catch "orphaned";
        state.setSyncMsg(m);
        freeSyncPayload(job);
        return;
    }

    // Capture the *old* version before applyScrape rewrites it, so
    // the end-of-batch recap can show "Foo 0.5 → 0.6" diffs. Only
    // games that already had a version recorded count as "updates";
    // first-time syncs of an unsynced row don't qualify.
    const old_version_snapshot: ?[]u8 = if (game.latest_version) |v|
        frame.lib.alloc.dupe(u8, v) catch null
    else
        null;
    defer if (old_version_snapshot) |s| frame.lib.alloc.free(s);

    // Indexer-mode synthesized `thread_info_md` is intentionally lean
    // (no Release Date / OS / Developer links — those only exist in
    // the verbatim OP body the scraper preserves). If this row was
    // ever scraper-synced it already has the richer block, so don't
    // clobber it with the synthesized version. The job came from the
    // indexer pipeline iff `indexer_client != null` at queue time.
    const indexer_origin = p.indexer_client != null;
    const new_info_len: usize = if (p.thread_info_md) |s| s.len else 0;
    const existing_info_len: usize = if (game.thread_info_md) |s| s.len else 0;
    const keep_existing_info = indexer_origin and existing_info_len > new_info_len;
    const apply_info_md: ?[]u8 = if (keep_existing_info) null else p.thread_info_md;

    frame.lib.applyScrape(game, .{
        .name = p.name,
        .version = p.version,
        .developer = p.developer,
        .rating = p.rating,
        .vote_count = p.vote_count,
        .engine = p.engine,
        .dev_status = p.dev_status,
        .last_updated_at = p.last_updated_at,
        .thread_info_md = apply_info_md,
        .censored = p.censored,
        .tags = p.tags,
        .screenshots = p.screenshots,
        .description_md = p.description_md,
        .changelog_md = p.changelog_md,
        .reviews_md = p.reviews_md,
        .download_links = p.download_links,
        .downloads_md = p.downloads_md,
        .last_scraped_at = now_s,
        .last_indexer_change = p.new_last_indexer_change,
    }) catch |e| {
        state.sync_status = .err;
        var emsg: [80]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "DB write failed: {s}", .{@errorName(e)}) catch "DB write failed";
        state.setSyncMsg(m);
        freeSyncPayload(job);
        return;
    };

    // The scrape edited this game's fields IN PLACE (name/status/version/…)
    // without replacing the `games` slice, so bump game_edit_gen to
    // invalidate the library filter cache — otherwise a status/text filter
    // could keep showing (or hiding) this row until an unrelated refresh.
    state.game_edit_gen +%= 1;

    // After a successful scrape we have everything needed to author
    // the canonical game recipe (name + version + engine + thread).
    // Auto-save it idempotently so the Recipe tab — which we're
    // about to retire — never becomes a precondition for anything
    // else (mods, downloads, sharing).
    mods_act.ensureGameRecipeOnDisk(frame, game) catch |e| {
        log.warn("auto-save game recipe for {d} failed: {s}", .{ game.f95_thread_id, @errorName(e) });
    };

    // Recap accumulation. Only fires when we're inside a batch (the
    // popup at the end is the whole point) AND the version actually
    // moved AND there *was* a prior version to move from. A solo
    // per-game sync still updates the row but doesn't generate a
    // recap entry; that's by design — the popup is for the long-
    // running "what should I redownload?" flows.
    if (state.sync_queue != null) {
        if (old_version_snapshot) |old_v| {
            if (game.latest_version) |new_v| {
                if (!std.mem.eql(u8, old_v, new_v)) {
                    pushSyncRecap(frame, game.f95_thread_id, game.name, old_v, new_v);
                    // Auto-update hook: only inside batch sync, only
                    // when this game opted in (or inherits an opted-in
                    // global default), and only when the recipe is
                    // ready (has an auto-fetchable source AND its
                    // version matches the new F95 version — a stale
                    // recipe would just re-fetch the old build).
                    // Skipped silently when manual-only or a
                    // download/install is already in flight.
                    if (launch_mod.shouldAutoUpdate(state, game) and
                        !downloads_mod.hasActiveDownloadForGame(frame, game.f95_thread_id) and
                        !installer_mod.isInstallingForGame(frame, game.f95_thread_id) and
                        launch_mod.recipeReadyForAutoUpdate(frame, game.f95_thread_id, new_v))
                    {
                        log.info("auto-update: tid={d} '{s}' {s} -> {s}", .{ game.f95_thread_id, game.name, old_v, new_v });
                        downloads_mod.doDownloadGame(frame, game);
                        markRecapAutoDownloaded(state, game.f95_thread_id);
                    } else if (launch_mod.shouldAutoUpdate(state, game) and
                        !launch_mod.hasAutoFetchableSource(frame, game.f95_thread_id))
                    {
                        log.info("auto-update: tid={d} skipped — no auto-fetchable recipe source", .{game.f95_thread_id});
                    } else if (launch_mod.shouldAutoUpdate(state, game) and
                        launch_mod.hasAutoFetchableSource(frame, game.f95_thread_id))
                    {
                        log.info("auto-update: tid={d} skipped — recipe version doesn't match new F95 version {s} (recipe lags)", .{ game.f95_thread_id, new_v });
                    }
                }
            }
        }
    }

    state.sync_status = .ok;
    // Game's rating/vote_count just changed — invalidate sort so a
    // rating-/votes-sorted view re-orders next frame.
    state.sort_applied_column = null;
    state.sort_applied_dir = null;

    var msgbuf: [96]u8 = undefined;
    const m = if (state.sync_queue) |_|
        std.fmt.bufPrint(&msgbuf, "sync-all: {d}/{d} — last \xE2\x98\x85 {?d:.2}", .{ state.sync_queue_started, state.sync_queue_total, game.rating }) catch "sync-all"
    else
        std.fmt.bufPrint(&msgbuf, "synced: \xE2\x98\x85 {?d:.2} ({?d} votes)", .{ game.rating, game.vote_count }) catch "synced";
    state.setSyncMsg(m);

    // Phase 2: hand the just-scraped screenshot list to the background
    // image worker so the row is fully populated in the background.
    // game.screenshots is library-owned and stable; the enqueue copy
    // happens lazily on spawn (drainImageQueue dupes for the worker).
    // Idempotent — `enqueueImageFetch` no-ops on dupes.
    if (game.screenshots.len > 0) {
        enqueueImageFetch(frame, game.f95_thread_id, game.screenshots.len);
    }

    freeSyncPayload(job);
}

// ============================================================
//  sync-all queue
// ============================================================

/// Build a queue of every "(unsynced)" game's thread_id and kick off
/// the first sync. drainSync auto-pops the next when each completes.
pub fn startSyncAll(frame: *Frame) void {
    const state = frame.state;
    if (state.anyActiveSync() or state.sync_queue != null) return;
    if (state.pending_fast_check != null) return;
    // Clear the cancel-cascade suspend so this fresh batch can queue
    // screenshot fetches normally.
    state.image_fetch_suspended = false;
    log.info("startSyncAll: queueing all {d} games", .{frame.games.len});
    // Fresh batch starts with an empty recap — stale entries from a
    // previous run would mislead the end-of-batch popup.
    clearSyncRecap(frame);

    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(frame.lib.alloc);

    // Filter out terminal-state games so refresh-all isn't dominated by
    // pinging the indexer about games that effectively never change.
    // Mirrors F95Checker's default: Completed / Abandoned threads are
    // skipped, and orphaned (thread gone from F95) makes no sense to
    // check. Unsynced games always pass through. This is the main
    // reason F95Checker's "Refresh!" runs in seconds while our naive
    // "check everything" walked the whole library.
    for (frame.games) |*g| {
        if (shouldSkipInRefreshAll(g)) continue;
        ids.append(frame.lib.alloc, g.f95_thread_id) catch return;
    }
    log.info("startSyncAll: filtered {d}/{d} games (skipped completed/abandoned/orphaned)", .{
        ids.items.len, frame.games.len,
    });

    if (ids.items.len == 0) {
        state.sync_status = .ok;
        state.setSyncMsg("library is empty — add games first");
        return;
    }

    const owned = ids.toOwnedSlice(frame.lib.alloc) catch return;

    // Indexer mode: send through the batched `/fast` pre-flight so we
    // only run `/full` against games that actually changed.
    // Scraper mode: every game gets a full HTML scrape, so just queue
    // them all and let the parallel slot pool grind through.
    if (state.refresh_backend == .indexer) {
        startSyncBatchIndexer(frame, owned);
        return;
    }
    state.sync_queue = owned;
    state.sync_queue_idx = 0;
    state.sync_queue_started = 0;
    state.sync_queue_total = @intCast(owned.len);
    advanceSyncQueue(frame);
}

/// Queue a sync for every game still showing as `(unsynced)` (a row
/// added via paste-import or bookmarks pull that hasn't been
/// scraped yet). Skips already-synced rows so a big freshly-imported
/// batch can finish quickly without redoing the whole library.
pub fn startSyncAllUnsynced(frame: *Frame) void {
    const state = frame.state;
    // Unconditional entry log so a click that gets gated out is
    // visible in the log instead of silently doing nothing.
    log.info("startSyncAllUnsynced: invoked (games_len={d})", .{frame.games.len});

    if (state.anyActiveSync() or state.sync_queue != null or state.pending_fast_check != null) {
        log.info("startSyncAllUnsynced: refused — a sync is already running", .{});
        state.pushToast(.info, "A sync is already running — cancel it first.");
        return;
    }
    // Fresh batch — let new syncs enqueue images again.
    state.image_fetch_suspended = false;
    clearSyncRecap(frame);

    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(frame.lib.alloc);

    // "Never synced" is the authoritative signal — Game.last_scraped_at
    // is null until the first successful sync sets it. The earlier
    // predicate (`name == "(unsynced)"`) only matched the placeholder
    // name that paste-import / bookmarks pull writes initially; a row
    // whose first scrape failed could still have a real-looking name
    // from an OP fragment yet have never been completed.
    for (frame.games) |*g| {
        if (g.last_scraped_at != null) continue;
        ids.append(frame.lib.alloc, g.f95_thread_id) catch return;
    }

    if (ids.items.len == 0) {
        // The sync banner is hidden when no queue/job exists, so
        // setSyncMsg here would be invisible. Push a toast instead so
        // the click visibly does *something* — even when the answer
        // is "nothing matches your filter".
        log.info("startSyncAllUnsynced: no rows with last_scraped_at == null — nothing to queue", .{});
        state.pushToast(.info, "No unsynced games — every library row has been scraped at least once.");
        return;
    }

    log.info("startSyncAllUnsynced: queueing {d} unsynced game(s)", .{ids.items.len});

    const owned = ids.toOwnedSlice(frame.lib.alloc) catch return;

    if (state.refresh_backend == .indexer) {
        startSyncBatchIndexer(frame, owned);
        return;
    }
    state.sync_queue = owned;
    state.sync_queue_idx = 0;
    state.sync_queue_started = 0;
    state.sync_queue_total = @intCast(owned.len);
    advanceSyncQueue(frame);
}

/// Position of `thread_id` in the sync queue (1-indexed, where 1 is
/// "next up"). Returns null if it's not queued. Used to label the
/// detail-page sync button as "Queued (N/M)" so the user knows where
/// in line they are.
pub fn queuePosition(state: *State, thread_id: u64) ?struct { idx: usize, total: usize } {
    const q = state.sync_queue orelse return null;
    var i: usize = state.sync_queue_idx;
    while (i < q.len) : (i += 1) {
        if (q[i] == thread_id) {
            const remaining_total = q.len - state.sync_queue_idx;
            return .{ .idx = (i - state.sync_queue_idx) + 1, .total = remaining_total };
        }
    }
    return null;
}

/// Append a thread_id to the in-memory sync queue, growing the slice
/// by one. If no queue exists yet, allocates a fresh one. Callers
/// only invoke this while a sync is already running, so the existing
/// active job is counted as "item 1" of the resulting batch — total
/// = (running + items in queue). The pop offset (`sync_queue_idx`)
/// stays 0-based for `advanceSyncQueue`; the display counter
/// (`sync_queue_started`) tracks the 1-based current-item position.
fn appendToSyncQueue(alloc: std.mem.Allocator, state: *State, thread_id: u64) !void {
    if (state.sync_queue) |q| {
        const new_q = try alloc.realloc(q, q.len + 1);
        new_q[q.len] = thread_id;
        state.sync_queue = new_q;
        state.sync_queue_total += 1;
    } else {
        const q = try alloc.alloc(u64, 1);
        q[0] = thread_id;
        state.sync_queue = q;
        state.sync_queue_idx = 0;
        // Currently-running solo sync is item 1; this appended one
        // becomes item 2 once popped.
        state.sync_queue_started = 1;
        state.sync_queue_total = 2;
    }
}


/// Cancel the running sync (if any) and drop the rest of the batch
/// queue. Worker observes `job.cancel` between phases and exits as
/// `Cancelled`. UI thread frees the queue immediately; drainSync's
/// cleanup will run when the worker reports back.
pub fn cancelSync(frame: *Frame) void {
    const state = frame.state;
    // Flag cancel on every active sync slot. drainSync will reap them
    // in the next few frames as each worker checks `job.cancel`.
    for (state.active_syncs) |maybe_slot| {
        if (maybe_slot) |j| {
            j.cancel.store(true, .release);
            log.info("cancelSync: flag set on tid={d}", .{j.payload.thread_id});
        }
    }
    if (state.sync_queue) |q| {
        frame.lib.alloc.free(q);
        state.sync_queue = null;
        state.sync_queue_idx = 0;
        state.sync_queue_started = 0;
        state.sync_queue_total = 0;
    }
    if (state.sync_queue_known_last_change) |arr| {
        frame.lib.alloc.free(arr);
        state.sync_queue_known_last_change = null;
    }
    // Cancel the fast-check pre-flight if it's still running so it
    // doesn't carry on after cancellation and re-install a queue.
    if (state.pending_fast_check) |j| j.cancel.store(true, .release);
    // Phase-2 piggybacks: cancelling a sync drops queued image work
    // too. `drainImageQueue` reaps active jobs, clears the queue,
    // and resets `image_cancel` to false once everything's torn down.
    // The persistent `image_fetch_suspended` flag prevents any in-flight
    // sync that finishes AFTER cancel from re-enqueueing screenshots.
    state.image_cancel.store(true, .release);
    state.image_fetch_suspended = true;
}

/// Cancel ONLY the phase-2 image fetch queue. Leaves any in-flight
/// sync alone — used by the dedicated "Cancel images" banner button
/// that shows after phase-1 has wrapped up. Sets the same suspend
/// flag so a sync that hasn't finished yet won't re-queue screenshots
/// when it later commits.
pub fn cancelImageQueue(frame: *Frame) void {
    frame.state.image_cancel.store(true, .release);
    frame.state.image_fetch_suspended = true;
    log.info("cancelImageQueue: flag set, image_fetch_suspended=true", .{});
}

/// Refill every empty sync slot from the queue. Called once per frame
/// by `drainSync` (after a worker completes) and at batch start by
/// `startSyncAll` / `startSyncAllUnsynced`.
///
/// Pops as many thread_ids as there are free slots, spawning each via
/// `syncGame`. When the queue runs dry AND every slot is idle, the
/// batch is declared complete and the recap popup may show.
pub fn advanceSyncQueue(frame: *Frame) void {
    const state = frame.state;
    const queue = state.sync_queue orelse return;

    // Spawn workers into every free slot until either the queue is
    // exhausted or all `MAX_PARALLEL_SYNC` slots are full.
    while (state.hasFreeSyncSlot() and state.sync_queue_idx < queue.len) {
        const idx = state.sync_queue_idx;
        const tid = queue[idx];
        // `null` ⇒ no batch pre-flight ran for THIS slot (either we're
        // in scraper mode, or this slot is an ad-hoc append after the
        // batch was queued). The worker then handles `/fast` itself.
        const known_lc: ?i64 = blk: {
            const arr = state.sync_queue_known_last_change orelse break :blk null;
            if (idx >= arr.len) break :blk null;
            break :blk arr[idx];
        };
        state.sync_queue_idx += 1;
        state.sync_queue_started += 1;

        var target: ?*library.Game = null;
        for (frame.games) |*gg| {
            if (gg.f95_thread_id == tid) {
                target = gg;
                break;
            }
        }
        const game = target orelse continue; // disappeared — skip
        spawnSyncJob(frame, game, known_lc);
    }

    // Queue exhausted? Only declare "complete" once every in-flight
    // slot has also drained — workers can outlive the queue.
    if (state.sync_queue_idx >= queue.len and !state.anyActiveSync()) {
        frame.lib.alloc.free(queue);
        if (state.sync_queue_known_last_change) |arr| {
            frame.lib.alloc.free(arr);
            state.sync_queue_known_last_change = null;
        }
        state.sync_queue = null;
        state.sync_queue_idx = 0;
        var msg_buf: [80]u8 = undefined;
        const m = std.fmt.bufPrint(&msg_buf, "sync-all complete ({d} games)", .{state.sync_queue_total}) catch "sync-all complete";
        state.sync_status = .ok;
        state.setSyncMsg(m);
        state.sync_queue_total = 0;
        state.sync_queue_started = 0;
        const recap = syncRecapEntries(state);
        if (recap.len > 0) {
            state.sync_recap_show = true;
            if (state.desktop_notifications) {
                var sbuf: [64]u8 = undefined;
                var bbuf: [192]u8 = undefined;
                notify.send(
                    frame.io,
                    notify.updateSummary(&sbuf, recap.len),
                    notify.updateBody(&bbuf, recap[0].name, recap.len),
                );
            }
        }
    }
}

// ============================================================
//  phase-2: background screenshot fetch
// ============================================================
//
// Why this exists: phase-1 (`syncWorker`) used to fetch the cover AND
// every screenshot serially before marking the row .done. Each image
// is rate-limited at ≥1.5s through `f95.Client`, so a popular OP with
// 20 screenshots blocked the row from showing for ~30s, and a sync-
// all of 1500 games was effectively unusable.
//
// Phase-2 splits the work: as soon as phase-1 commits text+cover
// (`applyScrape`), `drainSync` enqueues the tid here. A single
// background worker walks the FIFO, refetching only the screenshots
// the OP advertises. The library is fully usable in the meantime —
// the detail page already lazy-loads screenshots from disk and
// renders placeholders for missing slides.
//
// Concurrency: ONE image job in flight at a time. The rate limiter
// serializes per-host requests anyway, so parallel workers would just
// queue behind each other. Single-worker means simpler state.

fn imageWorker(job: *ImageJob) void {
    const p = &job.payload;
    const t_start = nowMs(p.io);
    var ok: u32 = 0;
    var fail: u32 = 0;
    var skipped: u32 = 0;
    defer log.info(
        "imgworker tid={d} TOTAL_ms={d} ok={d} fail={d} skipped={d}",
        .{ p.thread_id, nowMs(p.io) - t_start, ok, fail, skipped },
    );

    for (p.urls, 0..) |url, idx| {
        if (p.cancel_ptr.load(.acquire)) {
            log.info("imgworker tid={d} cancelled at shot {d}", .{ p.thread_id, idx + 1 });
            break;
        }

        // Skip when the file is already on disk — re-running sync over
        // a partially-fetched tid should not re-download what we have.
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{d}.s{d}", .{ p.covers_dir, p.thread_id, idx + 1 }) catch {
            fail += 1;
            _ = p.aggregate_done.fetchAdd(1, .release);
            _ = p.progress_done.fetchAdd(1, .release);
            job_mod.refreshDebounced(job.win, @src());
            continue;
        };
        if (fileExists(p.io, path)) {
            skipped += 1;
            // Do NOT bump `aggregate_done` (the banner's numerator):
            // `enqueueImageFetch` already excluded on-disk shots from
            // `state.image_total`, so counting skips here would push
            // `done` past `total`. Per-job `progress_done` still
            // advances for the (display-internal) X/Y counter.
            _ = p.progress_done.fetchAdd(1, .release);
            job_mod.refreshDebounced(job.win, @src());
            continue;
        }

        const t_s0 = nowMs(p.io);
        // Reuse phase-1's helper. It writes `<covers>/<tid>.s<idx>`
        // atomically + a thumb beside it; identical layout to before
        // the phase split, so detail-page slide loads keep working.
        fetchAndWriteScreenshotForImage(job, url, idx + 1) catch |e| {
            std.log.scoped(.ui_actions).warn(
                "phase2 screenshot {d} fetch failed: {s}",
                .{ idx + 1, @errorName(e) },
            );
            fail += 1;
            _ = p.aggregate_done.fetchAdd(1, .release);
            _ = p.progress_done.fetchAdd(1, .release);
            job_mod.refreshDebounced(job.win, @src());
            continue;
        };
        log.info("imgworker tid={d} shot[{d}]_ms={d}", .{ p.thread_id, idx + 1, nowMs(p.io) - t_s0 });
        ok += 1;
        _ = p.aggregate_done.fetchAdd(1, .release);
        _ = p.progress_done.fetchAdd(1, .release);
        job_mod.refreshDebounced(job.win, @src());
    }

    job.markDone();
}

/// Thin wrapper to call `fetchAndWriteScreenshot` from an `ImageJob`
/// (which doesn't carry a `SyncJob`). Same byte format on disk so
/// slide-cache reads work unchanged.
fn fetchAndWriteScreenshotForImage(job: *ImageJob, url: []const u8, idx: usize) !void {
    const p = &job.payload;
    const raw = try p.f95_svc.client.getImage(url);
    defer job.alloc.free(raw);

    acquireImageCpuSlot();
    defer releaseImageCpuSlot();

    const ready = prepareImageForDisk(job.alloc, raw) catch |e| {
        std.log.scoped(.ui_actions).warn("phase2 screenshot {d} transcode failed ({s}): {s}", .{ idx, @errorName(e), url });
        return e;
    };
    defer job.alloc.free(ready);

    var path_buf: [256]u8 = undefined;
    const path = try screenshotPath(&path_buf, p.covers_dir, p.thread_id, idx);
    try writeAtomic(p.io, path, ready);

    writeThumbBeside(job.alloc, p.io, path, ready) catch |e| {
        std.log.scoped(.ui_actions).warn("phase2 screenshot thumb gen failed: {s}", .{@errorName(e)});
    };
}

/// Enqueue a tid for phase-2 screenshot fetch. UI-thread only; called
/// from `drainSync` after `applyScrape` succeeds. Idempotent: a tid
/// already pending is left alone (the worker reads URLs from the
/// current Library row anyway, so a duplicate enqueue would just
/// fetch the same thing twice). Grows the queue geometrically.
pub fn enqueueImageFetch(frame: *Frame, thread_id: u64, planned_urls: usize) void {
    const state = frame.state;
    if (planned_urls == 0) return;
    // Honor the cancel-cascade flag — a sync that finishes after the
    // user clicked Cancel must NOT re-fill the image queue, otherwise
    // canceling would just postpone the work by one drain cycle.
    if (state.image_fetch_suspended) return;

    // Dedup against the PENDING queue.
    if (state.image_queue) |q| {
        var i: usize = state.image_queue_head;
        while (i < state.image_queue_len) : (i += 1) {
            if (q[i] == thread_id) return;
        }
    }
    // Dedup against the ACTIVELY-RUNNING image slots. Without this,
    // a re-sync of game X while X's image worker was still mid-fetch
    // would spawn a SECOND worker for X. Both would iterate the same
    // url list and write to the same `<tid>.s<N>` paths, interleaving
    // each other's atomic-renames and producing screenshot files
    // whose contents don't match their thumb siblings (and vice
    // versa). dedup here is O(MAX_PARALLEL_IMAGE) — trivially cheap.
    for (state.active_images) |maybe_slot| {
        if (maybe_slot) |j| {
            if (j.payload.thread_id == thread_id) return;
        }
    }

    // Count only the screenshots actually MISSING on disk. The worker
    // skips already-present `<tid>.s<idx>` files almost instantly, so
    // counting them toward `image_total` made the banner flash a full
    // 0→100% bar for games with no new images. `missing == 0` means
    // nothing to do — bail before touching the queue (and before any
    // alloc) so the banner never appears for those jobs at all. Path
    // scheme matches the worker's (`imageWorker`) exactly.
    var missing: usize = 0;
    {
        var i: usize = 1;
        var path_buf: [256]u8 = undefined;
        while (i <= planned_urls) : (i += 1) {
            const sp = std.fmt.bufPrint(&path_buf, "{s}/{d}.s{d}", .{ frame.info.covers_dir, thread_id, i }) catch {
                missing += 1; // path error → treat as missing (worker will retry)
                continue;
            };
            if (!fileExists(frame.io, sp)) missing += 1;
        }
    }
    if (missing == 0) {
        log.info("enqueueImageFetch tid={d} urls={d} — all on disk, skipping", .{ thread_id, planned_urls });
        return;
    }

    // Grow when full. Start at 32 slots; double thereafter.
    if (state.image_queue == null or state.image_queue_len == state.image_queue_cap) {
        const new_cap: usize = if (state.image_queue_cap == 0) 32 else state.image_queue_cap * 2;
        const new_buf = frame.lib.alloc.alloc(u64, new_cap) catch {
            log.warn("enqueueImageFetch: queue alloc failed for tid={d}", .{thread_id});
            return;
        };
        if (state.image_queue) |old| {
            @memcpy(new_buf[0..state.image_queue_len], old[0..state.image_queue_len]);
            frame.lib.alloc.free(old);
        }
        state.image_queue = new_buf;
        state.image_queue_cap = new_cap;
    }
    state.image_queue.?[state.image_queue_len] = thread_id;
    state.image_queue_len += 1;
    state.image_total += @intCast(missing);
    log.info("enqueueImageFetch tid={d} urls={d} missing={d} queue_len={d} total={d}", .{ thread_id, planned_urls, missing, state.image_queue_len - state.image_queue_head, state.image_total });
}

/// Per-frame: reap every completed image slot, then refill all empty
/// slots from the queue. Runs up to `MAX_PARALLEL_IMAGE` workers in
/// parallel — covers + screenshots from `attachments.f95zone.to` (a
/// Cloudflare CDN that bypasses the forum rate limit) can saturate
/// the slot pool without triggering 429s.
pub fn drainImageQueue(frame: *Frame) void {
    const state = frame.state;

    // Reap every finished slot. The worker may still be running in
    // some slots — leave those untouched and continue with the rest.
    for (&state.active_images) |*slot| {
        const job = slot.* orelse continue;
        if (job.phaseGet() != .done) continue;
        const p = &job.payload;
        log.info("drainImageQueue: tid={d} job done", .{p.thread_id});

        // If the user is on the detail page for this tid, dump the
        // slide / thumb caches so the freshly-fetched bytes show
        // up on the next paint instead of the cached placeholders.
        if (state.slide_cache_thread == p.thread_id) {
            freeSlideCache(state, frame.lib.alloc);
        }
        if (state.thumb_cache_thread == p.thread_id) {
            freeThumbCache(state, frame.lib.alloc);
        }

        // Free payload-owned memory. `name` may be the empty literal
        // fallback when dupe failed — skip the free in that case.
        for (p.urls) |u| job.alloc.free(u);
        job.alloc.free(p.urls);
        if (p.name.len > 0) job.alloc.free(p.name);
        job.alloc.free(p.covers_dir);
        job.alloc.destroy(job);
        slot.* = null;
    }
    if (!state.anyActiveImage()) state.image_active_name.clear();

    // If the user cancelled, drop the rest of the queue NOW (after
    // each slot's active job has been reaped). But DO NOT reset
    // `image_cancel` until every active worker has actually exited —
    // workers read `p.cancel_ptr` (pointing at `state.image_cancel`)
    // between fetches, so resetting it early would unstick the
    // in-flight workers and they'd happily finish downloading the
    // remaining URLs (the old behavior — cancel button felt
    // unresponsive because the workers kept fetching for seconds
    // after the click).
    if (state.image_cancel.load(.acquire)) {
        if (state.image_queue) |q| {
            frame.lib.alloc.free(q);
            state.image_queue = null;
            state.image_queue_cap = 0;
        }
        state.image_queue_head = 0;
        state.image_queue_len = 0;
        if (state.anyActiveImage()) {
            // Workers still mid-fetch — keep the flag set so each
            // one's loop iteration sees `cancel=true` and breaks. We
            // come back next frame.
            return;
        }
        // All workers gone — fully clear cancel state.
        state.image_total = 0;
        state.image_done.store(0, .release);
        state.image_cancel.store(false, .release);
        log.info("drainImageQueue: cancelled + drained", .{});
        return;
    }

    if (state.image_queue == null) {
        if (!state.anyActiveImage()) state.image_total = 0;
        return;
    }
    if (state.image_queue_head >= state.image_queue_len) {
        if (state.anyActiveImage()) return; // last in-flight workers still running
        frame.lib.alloc.free(state.image_queue.?);
        state.image_queue = null;
        state.image_queue_head = 0;
        state.image_queue_len = 0;
        state.image_queue_cap = 0;
        state.image_total = 0;
        state.image_done.store(0, .release);
        log.info("drainImageQueue: batch complete", .{});
        return;
    }

    // Refill every empty slot from the queue.
    while (state.hasFreeImageSlot() and state.image_queue_head < state.image_queue_len) {
        if (!spawnNextImageJob(frame)) return;
    }
}

/// Pop one tid from the queue and spawn an image worker into the
/// first free slot. Returns `true` on success, `false` if anything
/// went wrong (caller should stop trying for this frame). Idempotent
/// on alloc-failure: any partial state is rolled back.
fn spawnNextImageJob(frame: *Frame) bool {
    const state = frame.state;
    const tid = state.image_queue.?[state.image_queue_head];
    state.image_queue_head += 1;

    // Look up the game row to read its screenshot URL list.
    var target: ?*const library.Game = null;
    for (frame.games) |*gg| {
        if (gg.f95_thread_id == tid) {
            target = gg;
            break;
        }
    }
    const game = target orelse {
        log.info("drainImageQueue: tid={d} not in games list, skipping", .{tid});
        return true; // not a fatal error — try the next id next iteration
    };

    const urls_src = game.screenshots;
    if (urls_src.len == 0) {
        // No screenshots advertised — nothing to fetch. Skip cleanly;
        // we already charged `image_total` for this tid at enqueue
        // time.
        log.info("drainImageQueue: tid={d} has 0 screenshots, skipping", .{tid});
        return true;
    }

    // Spawn the worker via the Job(P) primitive. URLs + name +
    // covers_dir all live on lib.alloc; cancel + aggregate_done point
    // into shared state slots so a Cancel click reaches every parallel
    // worker AND any queued tids.
    var alloc_failed = false;
    const urls_dup = blk: {
        const outer = frame.lib.alloc.alloc([]const u8, urls_src.len) catch {
            alloc_failed = true;
            break :blk @as([]const []const u8, &.{});
        };
        var n: usize = 0;
        for (urls_src) |u| {
            const dup = frame.lib.alloc.dupe(u8, u) catch {
                alloc_failed = true;
                break;
            };
            outer[n] = dup;
            n += 1;
        }
        if (alloc_failed) {
            for (outer[0..n]) |u| frame.lib.alloc.free(u);
            frame.lib.alloc.free(outer);
            break :blk @as([]const []const u8, &.{});
        }
        break :blk @as([]const []const u8, outer);
    };
    if (alloc_failed) {
        log.warn("drainImageQueue: URL dup failed for tid={d}", .{tid});
        return false;
    }
    const name_dup = frame.lib.alloc.dupe(u8, game.name) catch "";
    const covers_dup = frame.lib.alloc.dupe(u8, frame.info.covers_dir) catch {
        for (urls_dup) |u| frame.lib.alloc.free(u);
        frame.lib.alloc.free(@constCast(urls_dup));
        if (name_dup.len > 0) frame.lib.alloc.free(name_dup);
        log.warn("drainImageQueue: covers_dir dup failed for tid={d}", .{tid});
        return false;
    };

    const slot = state.findEmptyImageSlot() orelse {
        // Should not happen — caller already verified `hasFreeImageSlot`.
        for (urls_dup) |u| frame.lib.alloc.free(u);
        frame.lib.alloc.free(@constCast(urls_dup));
        if (name_dup.len > 0) frame.lib.alloc.free(name_dup);
        frame.lib.alloc.free(covers_dup);
        return false;
    };

    _ = job_mod.spawnJob(
        ImagePayload,
        imageWorker,
        frame.lib.alloc,
        frame.win,
        .{
            .thread_id = tid,
            .urls = urls_dup,
            .name = name_dup,
            .progress_total = @intCast(urls_dup.len),
            .f95_svc = frame.f95_svc,
            .covers_dir = covers_dup,
            .io = frame.io,
            .cancel_ptr = &state.image_cancel,
            .aggregate_done = &state.image_done,
        },
        slot,
    ) catch {
        log.warn("drainImageQueue: spawn failed for tid={d}", .{tid});
        // Roll back the payload-owned allocs so we don't leak.
        for (urls_dup) |u| frame.lib.alloc.free(u);
        frame.lib.alloc.free(@constCast(urls_dup));
        if (name_dup.len > 0) frame.lib.alloc.free(name_dup);
        frame.lib.alloc.free(covers_dup);
        return false;
    };
    state.setCurrentImageName(name_dup);
    log.info("drainImageQueue: spawned tid={d} urls={d}", .{ tid, urls_dup.len });
    return true;
}

// ============================================================
//  cover image — disk cache (LRU-ish FIFO with on-hit promotion)
// ============================================================

/// File path for a thread's cached cover bytes.
pub fn coverPath(buf: []u8, covers_dir: []const u8, thread_id: u64) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}/{d}", .{ covers_dir, thread_id });
}

/// Look up cover THUMB bytes for `thread_id`, populating the cache on
/// miss. Returns null if the file isn't there yet (cover not synced).
///
/// Returns the THUMB (`<tid>.t`) — small, fast to decode. Library
/// screens (grid + list) use this to avoid 4 MB-per-cover RGBA blowups
/// from full-size decodes. Detail-page carousel slide 0 uses the
/// separate full-size path via `slideBytes` / direct read so it shows
/// the high-quality cover.
///
/// Cache eviction is FIFO with LRU-ish promotion: on hit, the entry is
/// swapped into the slot just before `cover_cache_next`.
///
/// DIAG: per-frame cover-cache miss counter. UI-thread only, so a
/// plain global is safe. `renderVirtualizedList` reads + resets it
/// each frame to log thrash. Remove once the scroll-perf cause is
/// pinned down.
pub var dbg_cover_misses: usize = 0;
pub fn coverBytes(frame: *Frame, thread_id: u64) ?[]const u8 {
    const state = frame.state;
    const cap = state.cover_cache.len;
    // Fast path: cache hit. Promote on hit.
    for (&state.cover_cache, 0..) |*slot_ptr, idx| {
        if (slot_ptr.*) |slot| {
            if (slot.thread_id == thread_id) {
                const recent = (state.cover_cache_next + cap - 1) % cap;
                if (idx != recent) {
                    const tmp = state.cover_cache[idx];
                    state.cover_cache[idx] = state.cover_cache[recent];
                    state.cover_cache[recent] = tmp;
                }
                return state.cover_cache[recent].?.bytes;
            }
        }
    }

    // Miss — kick off an ASYNC load (worker thread) and render the
    // placeholder this frame. Never read on the UI thread here: a slow
    // FUSE/NTFS thumb read would stall the whole scroll. `drainCoverLoads`
    // lands the bytes in the cache a frame or two later, and the worker's
    // `markDone` refreshes so the cover pops in without further input.
    dbg_cover_misses += 1; // DIAG: attribute library-scroll cost
    spawnCoverLoadIfRoom(frame, thread_id);
    return null;
}

/// Worker: read one cover thumbnail off the UI thread.
fn coverLoadWorker(job: *owned_types.CoverLoadJob) void {
    const p = &job.payload;
    if (job.cancelRequested()) {
        p.err_name = "cancelled";
        job.markFailed();
        return;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        p.io,
        p.path[0..p.path_len],
        p.bytes_alloc,
        .limited(2 * 1024 * 1024),
    ) catch |e| {
        p.err_name = @errorName(e);
        job.markFailed();
        return;
    };
    p.bytes = bytes;
    job.markDone();
}

/// Start an async load for `thread_id`'s cover thumb if a worker slot is
/// free and one isn't already loading that game. No-op (placeholder this
/// frame) when the small pool is full — the next frame retries.
fn spawnCoverLoadIfRoom(frame: *Frame, thread_id: u64) void {
    const state = frame.state;
    var free_slot: ?usize = null;
    for (&state.cover_load_jobs, 0..) |*slot, i| {
        if (slot.*) |j| {
            if (j.payload.thread_id == thread_id) return; // already in flight
        } else if (free_slot == null) {
            free_slot = i;
        }
    }
    const si = free_slot orelse return; // pool full — retry next frame
    var thumb_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&thumb_buf, "{s}/{d}.t", .{ frame.info.covers_dir, thread_id }) catch return;
    if (path.len > 256) return;
    var payload: owned_types.CoverLoadPayload = .{
        .io = frame.io,
        .bytes_alloc = frame.lib.alloc,
        .thread_id = thread_id,
        .path_len = path.len,
    };
    @memcpy(payload.path[0..path.len], path);
    _ = job_mod.spawnJob(
        owned_types.CoverLoadPayload,
        coverLoadWorker,
        frame.lib.alloc,
        frame.win,
        payload,
        &state.cover_load_jobs[si],
    ) catch return;
}

/// Insert freshly-loaded cover bytes into the round-robin cache (evicting
/// the oldest). Dedups against a concurrent insert for the same game.
fn coverCacheInsert(state: *State, alloc: std.mem.Allocator, thread_id: u64, bytes: []u8) void {
    for (&state.cover_cache) |slot| {
        if (slot) |s| if (s.thread_id == thread_id) {
            alloc.free(bytes); // already cached — drop the duplicate
            return;
        };
    }
    const idx = state.cover_cache_next;
    state.cover_cache_next = (idx + 1) % state.cover_cache.len;
    if (state.cover_cache[idx]) |old| alloc.free(old.bytes);
    state.cover_cache[idx] = .{ .thread_id = thread_id, .bytes = bytes };
}

/// Reap finished async cover loaders into the cache. Cheap when the pool
/// is idle (all slots null). Call once per frame.
pub fn drainCoverLoads(frame: *Frame) void {
    const state = frame.state;
    for (&state.cover_load_jobs) |*slot| {
        const job = slot.* orelse continue;
        switch (job.phaseGet()) {
            .pending => continue,
            .done => {
                if (job.payload.bytes) |b| {
                    coverCacheInsert(state, frame.lib.alloc, job.payload.thread_id, b);
                    job.payload.bytes = null;
                }
            },
            .failed => {
                if (job.payload.bytes) |b| frame.lib.alloc.free(b);
            },
        }
        slot.* = null;
        job.alloc.destroy(job);
    }
}

/// Read full-size cover bytes for the detail-page carousel slide 0.
/// Bypasses the thumb-bound `cover_cache`. Caller does NOT free —
/// the bytes are managed via the multi-slot `slide_cache_bytes` array
/// (slot 0). Reused across frames while the carousel stays on this
/// game; freed wholesale on game switch by `freeSlideCache`.
pub fn coverFullBytes(frame: *Frame, thread_id: u64) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const path = coverPath(&buf, frame.info.covers_dir, thread_id) catch return null;
    return slideSlotBytes(frame, thread_id, 0, path);
}

/// Drop the cache entry for `thread_id` (sync just rewrote the file).
pub fn invalidateCover(state: *State, alloc: std.mem.Allocator, thread_id: u64) void {
    for (&state.cover_cache) |*slot_ptr| {
        if (slot_ptr.*) |slot| {
            if (slot.thread_id == thread_id) {
                alloc.free(slot.bytes);
                slot_ptr.* = null;
                return;
            }
        }
    }
}

pub fn freeCoverCache(state: *State, alloc: std.mem.Allocator) void {
    for (&state.cover_cache) |*slot_ptr| {
        if (slot_ptr.*) |slot| {
            alloc.free(slot.bytes);
            slot_ptr.* = null;
        }
    }
}

/// Tear down the async cover-loader pool: cancel every in-flight worker
/// and reap it. Workers are detached, so we spin until each reaches a
/// terminal phase (they bail fast once cancelled), freeing the job +
/// any bytes. Call on app quit and harness deinit.
pub fn freeCoverLoads(state: *State, alloc: std.mem.Allocator) void {
    for (&state.cover_load_jobs) |*slot| {
        if (slot.*) |j| j.requestCancel();
    }
    var guard: usize = 0;
    while (guard < 1_000_000) : (guard += 1) {
        var pending = false;
        for (&state.cover_load_jobs) |*slot| {
            const job = slot.* orelse continue;
            if (job.phaseGet() == .pending) {
                pending = true;
                continue;
            }
            if (job.payload.bytes) |b| alloc.free(b);
            slot.* = null;
            job.alloc.destroy(job);
        }
        if (!pending) break;
        std.Thread.yield() catch {};
    }
}

/// Tear down the library-list filter-result cache. Called from the
/// shutdown defer chain in `runMainLoop`.
pub fn freeLibFilterCache(state: *State, alloc: std.mem.Allocator) void {
    if (state.lib_filter_cache_indices) |old| {
        alloc.free(old);
        state.lib_filter_cache_indices = null;
    }
    state.lib_filter_cache_sig = 0;
}

/// Tear down the per-frame snapshot caches (install_versions +
/// games_by_thread). Called from the shutdown defer chain in
/// `runMainLoop` and from each cache-miss rebuild path.
pub fn freeSnapshotCache(state: *State, alloc: std.mem.Allocator) void {
    if (state.snapshot_install_versions) |*m| {
        var it = m.valueIterator();
        while (it.next()) |v| alloc.free(v.*);
        m.deinit();
        state.snapshot_install_versions = null;
    }
    if (state.snapshot_games_by_thread) |*m| {
        m.deinit();
        state.snapshot_games_by_thread = null;
    }
    state.snapshot_install_gen = 0;
    state.snapshot_games_ptr = 0;
    state.snapshot_games_len = 0;
}

// ============================================================
//  cover pre-warmer — populate OS page cache on a worker thread
// ============================================================
//
// Cold-cache: the very first frame of the library screen calls
// `coverBytes` for every visible card, each one doing a sync
// `readFileAlloc`. With 32 cards × few-ms-per-read that's a visible
// stall.
//
// We don't want to share the in-memory `state.cover_cache` across
// threads (would need a lock on every UI access), so this worker just
// touches the files: it reads + immediately frees the bytes. That's
// enough to populate the OS page cache, so the subsequent UI-thread
// reads through `coverBytes` hit memcpy-speed instead of disk.
//
// Caller-owned: nothing. The worker is detached and frees its own job.

const PrewarmJob = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    covers_dir: []u8,
    thread_ids: []u64,
};

/// Spawn a detached worker that reads the first `cap` cover files
/// referenced by `games` to warm the OS page cache. No-op if `games`
/// is empty.
pub fn spawnCoverPrewarm(
    alloc: std.mem.Allocator,
    io: std.Io,
    covers_dir: []const u8,
    games: []const library.Game,
    cap: usize,
) void {
    const n = @min(games.len, cap);
    if (n == 0) return;

    const job = alloc.create(PrewarmJob) catch return;
    const ids = alloc.alloc(u64, n) catch {
        alloc.destroy(job);
        return;
    };
    for (games[0..n], 0..) |g, i| ids[i] = g.f95_thread_id;

    const dir_owned = alloc.dupe(u8, covers_dir) catch {
        alloc.free(ids);
        alloc.destroy(job);
        return;
    };
    job.* = .{ .alloc = alloc, .io = io, .covers_dir = dir_owned, .thread_ids = ids };

    const thr = std.Thread.spawn(.{}, prewarmWorker, .{job}) catch {
        alloc.free(dir_owned);
        alloc.free(ids);
        alloc.destroy(job);
        return;
    };
    thr.detach();
}

fn prewarmWorker(job: *PrewarmJob) void {
    job_mod.lowerWorkerPriority();
    defer {
        job.alloc.free(job.covers_dir);
        job.alloc.free(job.thread_ids);
        job.alloc.destroy(job);
    }
    var buf: [256]u8 = undefined;
    for (job.thread_ids) |tid| {
        // Warm the `.t` THUMB — that's what `coverBytes` actually reads
        // (warming the full cover, as this did before, was wasted I/O).
        const path = std.fmt.bufPrint(&buf, "{s}/{d}.t", .{ job.covers_dir, tid }) catch continue;
        // Read + immediately free. The file content lives in the OS
        // page cache after this; the worker's later `readFileAlloc`
        // serves from there.
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            job.io,
            path,
            job.alloc,
            .limited(8 * 1024 * 1024),
        ) catch continue;
        job.alloc.free(bytes);
    }
}

// ============================================================
//  thumb pre-warmer — same trick, run on detail-page entry
// ============================================================
//
// First frame of the detail page calls `thumbBytes` for every slot
// in the ribbon strip — 20+ synchronous `readFileAlloc` calls. We
// can't fill the in-memory cache from a worker (UI thread owns it),
// but reading the files off-thread populates the OS page cache so
// the UI-thread reads land in memory.

const ThumbPrewarmJob = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    covers_dir: []u8,
    thread_id: u64,
    count: usize,
};

/// Spawn a detached worker that reads every thumbnail file for the
/// given game (slots 1..count). Slot 0 (the cover thumb) is already
/// covered by `spawnCoverPrewarm` / `cover_cache`.
pub fn spawnThumbPrewarm(
    alloc: std.mem.Allocator,
    io: std.Io,
    covers_dir: []const u8,
    thread_id: u64,
    count: usize,
) void {
    if (count == 0) return;
    const job = alloc.create(ThumbPrewarmJob) catch return;
    const dir_owned = alloc.dupe(u8, covers_dir) catch {
        alloc.destroy(job);
        return;
    };
    job.* = .{ .alloc = alloc, .io = io, .covers_dir = dir_owned, .thread_id = thread_id, .count = count };
    const thr = std.Thread.spawn(.{}, thumbPrewarmWorker, .{job}) catch {
        alloc.free(dir_owned);
        alloc.destroy(job);
        return;
    };
    thr.detach();
}

fn thumbPrewarmWorker(job: *ThumbPrewarmJob) void {
    job_mod.lowerWorkerPriority();
    defer {
        job.alloc.free(job.covers_dir);
        job.alloc.destroy(job);
    }
    var buf: [256]u8 = undefined;
    var i: usize = 1;
    while (i <= job.count) : (i += 1) {
        const path = std.fmt.bufPrint(&buf, "{s}/{d}.s{d}.t", .{ job.covers_dir, job.thread_id, i }) catch continue;
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            job.io,
            path,
            job.alloc,
            .limited(2 * 1024 * 1024),
        ) catch continue;
        job.alloc.free(bytes);
    }
}

// ============================================================
//  indexer: batch /fast pre-flight
// ============================================================
//
// F95Checker pattern: refresh-all chunks games into groups of 10 and
// hits `/fast?ids=<csv>` per chunk to learn each game's `last_change`
// without scraping. Only games whose `last_change` advanced get a
// `/full/{id}?ts=<last_change>` call after.
//
// This worker is the chunked /fast pass. It runs alone (one in-flight
// at a time, gated through `state.pending_fast_check`), then hands
// the per-game decision back to the UI thread which populates the
// regular `sync_queue` + `sync_queue_known_last_change` parallel slice.
// Per-game indexer workers then spawn in parallel through the
// `MAX_PARALLEL_SYNC` slot pool, each skipping its own `/fast` because
// `known_last_change` is already set.

/// Spawn the indexer batch /fast pre-flight. Owns `ids_slice` for the
/// duration of the job. UI thread sets `sync_status = .running` + a
/// "checking…" banner; the recap clear / queue init happens after the
/// worker reports back.
fn startSyncBatchIndexer(frame: *Frame, ids_slice: []u64) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    _ = job_mod.spawnJob(
        FastCheckPayload,
        fastCheckWorker,
        alloc,
        frame.win,
        .{
            .ids = ids_slice,
            .indexer_client = frame.f95_indexer_client,
            .io = frame.io,
            .fast_total = @intCast(ids_slice.len),
        },
        &state.pending_fast_check,
    ) catch {
        alloc.free(ids_slice);
        state.sync_status = .err;
        state.setSyncMsg("fast-check spawn failed");
        return;
    };

    state.sync_status = .running;
    state.setSyncMsg("checking for changes…");
    log.info("startSyncBatchIndexer: /fast pre-flight ids={d}", .{ids_slice.len});
}

fn fastCheckWorker(job: *FastCheckJob) void {
    const p = &job.payload;
    const alloc = job.alloc;
    const t_start = nowMs(p.io);

    const last_changes = alloc.alloc(i64, p.ids.len) catch {
        p.err_name = "OutOfMemory";
        job.markFailed();
        return;
    };
    @memset(last_changes, 0);

    var i: usize = 0;
    while (i < p.ids.len) {
        if (job.cancelRequested()) {
            alloc.free(last_changes);
            p.err_name = "Cancelled";
            job.markFailed();
            return;
        }
        const chunk_end = @min(i + f95_indexer.MAX_IDS_PER_FAST, p.ids.len);
        const chunk = p.ids[i..chunk_end];
        const results = p.indexer_client.fastCheck(chunk) catch |e| {
            log.warn("fast-check chunk {d}..{d} FAIL: {s}", .{ i, chunk_end, @errorName(e) });
            alloc.free(last_changes);
            p.err_name = @errorName(e);
            job.markFailed();
            return;
        };
        defer alloc.free(results);

        // The indexer doesn't guarantee response order matches request;
        // it returns a dict. Match each result back to its slot.
        for (results) |r| {
            for (chunk, 0..) |tid, j| {
                if (tid == r.id) {
                    last_changes[i + j] = r.last_change;
                    break;
                }
            }
        }
        i = chunk_end;
        // Surface pre-flight progress to the bottom-bar indicator. The
        // UI is otherwise blind during this phase (no sync slot, no
        // queue yet), so without this the bar sits at "Ready" while a
        // big library grinds through dozens of `/fast` chunks.
        p.fast_done.store(@intCast(i), .release);
        job_mod.refreshDebounced(job.win, @src());
    }

    p.last_changes = last_changes;
    log.info("fast-check TOTAL_ms={d} ids={d} chunks={d}", .{
        nowMs(p.io) - t_start,
        p.ids.len,
        (p.ids.len + f95_indexer.MAX_IDS_PER_FAST - 1) / f95_indexer.MAX_IDS_PER_FAST,
    });
    job.markDone();
}

fn onFastCheckDone(frame: *Frame, job: *FastCheckJob) void {
    const state = frame.state;
    const p = &job.payload;
    const alloc = frame.lib.alloc;
    defer freeFastCheckPayload(job);

    const last_changes = p.last_changes orelse {
        state.sync_status = .err;
        state.setSyncMsg("fast-check: no results returned");
        return;
    };

    // Filter to games whose `last_change` actually moved. Each kept
    // entry's index in keep_ids matches its known_last_change in
    // keep_lcs (parallel slices).
    var keep_ids: std.ArrayList(u64) = .empty;
    var keep_lcs: std.ArrayList(i64) = .empty;
    defer keep_ids.deinit(alloc);
    defer keep_lcs.deinit(alloc);

    for (p.ids, 0..) |tid, i| {
        const lc = last_changes[i];
        var target: ?*library.Game = null;
        for (frame.games) |*gg| {
            if (gg.f95_thread_id == tid) {
                target = gg;
                break;
            }
        }
        const game = target orelse continue;
        const prev = game.last_indexer_change orelse 0;
        // Parser-version migration check (mirrors F95Checker's
        // `last_check_before(...)`). If we've bumped the mapping
        // since this row was filled, force-queue it so it picks up
        // the new fields even when `last_change` hasn't moved.
        const parser_drift = blk: {
            const v = game.last_indexer_parser_version orelse break :blk true;
            break :blk v != f95_indexer.PARSER_VERSION;
        };
        if (prev == 0 or lc > prev or parser_drift) {
            keep_ids.append(alloc, tid) catch return;
            keep_lcs.append(alloc, lc) catch return;
        }
    }

    if (keep_ids.items.len == 0) {
        state.sync_status = .ok;
        var buf: [128]u8 = undefined;
        const m = std.fmt.bufPrint(
            &buf,
            "all {d} games up to date — nothing to fetch",
            .{p.ids.len},
        ) catch "all games up to date";
        state.setSyncMsg(m);
        return;
    }

    const owned_ids = keep_ids.toOwnedSlice(alloc) catch return;
    const owned_lcs = keep_lcs.toOwnedSlice(alloc) catch {
        alloc.free(owned_ids);
        return;
    };
    state.sync_queue = owned_ids;
    state.sync_queue_known_last_change = owned_lcs;
    state.sync_queue_idx = 0;
    state.sync_queue_started = 0;
    state.sync_queue_total = @intCast(owned_ids.len);
    log.info("fast-check: queued {d}/{d} games for /full", .{ owned_ids.len, p.ids.len });
    advanceSyncQueue(frame);
}

fn onFastCheckFailed(frame: *Frame, job: *FastCheckJob) void {
    const state = frame.state;
    const p = &job.payload;
    defer freeFastCheckPayload(job);

    const cancelled = p.err_name != null and std.mem.eql(u8, p.err_name.?, "Cancelled");
    if (cancelled) {
        state.sync_status = .idle;
        state.sync_msg.clear();
        return;
    }
    state.sync_status = .err;
    var emsg: [160]u8 = undefined;
    const m = std.fmt.bufPrint(&emsg, "indexer fast-check failed: {s}", .{p.err_name orelse "?"}) catch "indexer fast-check failed";
    state.setSyncMsg(m);
}

fn freeFastCheckPayload(job: *FastCheckJob) void {
    const p = &job.payload;
    job.alloc.free(p.ids);
    if (p.last_changes) |lc| job.alloc.free(lc);
}

/// Drain the fast-check job — called once per frame from the main loop.
pub fn drainFastCheck(frame: *Frame) void {
    const state = frame.state;
    job_mod.drainBackgroundJob(
        FastCheckPayload,
        onFastCheckDone,
        onFastCheckFailed,
        frame,
        &state.pending_fast_check,
    );
}
