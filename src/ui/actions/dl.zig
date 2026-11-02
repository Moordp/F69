// UI side of downloader v2.
//
//   - `drainDownloaderEvents` — once per frame: `install_ready` →
//     `installer.installFromArchive`, `open_url` → browser, `toast` /
//     `sign_in_needed` → the download message toast.
//   - `doDownloadGame` — recipe path (first source only): RPDL goes
//     through the RPDL worker, DDL / mirror URLs go straight in as
//     `enqueue_url`. Retries and fallbacks are the downloader's job.
//   - Snapshot readers (`hasActiveDownloadForGame`,
//     `findLeechingJobForGame`, `copySnapshot`): each takes the snapshot
//     and releases it in the same scope and returns copies only.
//
// Nothing here blocks on the network or on download files: commands are
// queued, the snapshot is an in-memory read.

const std = @import("std");
const library = @import("library");
const downloads = @import("downloads");
const types = @import("../types.zig");
const common = @import("common.zig");
const installer_act = @import("installer.zig");
const flows = @import("downloads.zig");
const state_mod = @import("../state.zig");

const Frame = types.Frame;
const JobView = downloads.JobView;

/// Take every pending downloader event and act on it (UI thread).
pub fn drainDownloaderEvents(frame: *Frame) void {
    const alloc = frame.lib.alloc;
    const evs = frame.dl.drainEvents(alloc);
    defer downloads.Downloader.freeEvents(alloc, evs);
    for (evs) |ev| switch (ev) {
        .install_ready => |ir| installer_act.installFromArchive(frame, ir),
        .open_url => |u| common.openExternalUrl(frame, u),
        .toast => |t| frame.state.setDownloadMsg(t),
        .sign_in_needed => |svc| frame.state.setDownloadMsg(switch (svc) {
            .f95 => "Sign in to F95zone to download this",
            .mega => "Sign in to MEGA in Settings → Accounts",
        }),
    };
}

/// Look up the recipe for `game` and queue its *first* source. RPDL
/// fetches the pinned torrent on a worker, then `enqueue_torrent`;
/// DDL / mirror sources go straight in as `enqueue_url`.
///
/// On success: routes to the Downloads screen so the user sees the new
/// job and returns true. On failure (no recipe, RPDL worker busy or not
/// signed in, …): one toast line, the screen stays, returns false.
pub fn doDownloadGame(frame: *Frame, game: *const library.Game) bool {
    const state = frame.state;

    const parsed_opt = frame.recipe_repo.findGameByThread(game.f95_thread_id) catch |e| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Recipe lookup failed: {s}", .{@errorName(e)}) catch "Recipe lookup failed";
        state.setDownloadMsg(msg);
        return false;
    };
    var parsed = parsed_opt orelse {
        state.setDownloadMsg("No recipe for this game. Drop one in <config>/f69/recipes/<id>.game.zon");
        return false;
    };
    defer parsed.deinit();

    if (parsed.recipe.sources.len == 0) {
        state.setDownloadMsg("Recipe has no sources defined.");
        return false;
    }

    switch (parsed.recipe.sources[0]) {
        .rpdl => |x| {
            // The worker refuses (with its own message) when another RPDL
            // fetch runs or no token is set; it then never enqueues.
            // A busy worker is detected by its game id, not just by the
            // slot being taken.
            const before = state.pending_rpdl_download;
            flows.startRpdlDownloadById(frame, game, x.id);
            const after = state.pending_rpdl_download orelse return false;
            if (before != null and before.? == after) return false;
        },
        .ddl => |x| enqueueUrl(frame, game, x.url, downloads.hexDecode(x.sha256) catch null, "ddl"),
        .mirror => |x| enqueueUrl(frame, game, x.url, if (x.sha256) |h| (downloads.hexDecode(h) catch null) else null, "mirror"),
    }
    state.setDownloadMsg("Queued download — see Downloads");
    state.screen = .downloads;
    return true;
}

fn enqueueUrl(frame: *Frame, game: *const library.Game, url: []const u8, sha: ?[32]u8, host: []const u8) void {
    frame.dl.send(.{ .enqueue_url = .{
        .url = url,
        .kind = .game,
        .game_thread_id = game.f95_thread_id,
        .title = game.name,
        .version = game.latest_version,
        .expected_sha256 = sha,
        .host = host,
    } });
}

// ----- Detail → Downloads tab (catalogue links) -----

const catalogue_view = @import("../catalogue_view.zig");
const State = types.State;
const log = std.log.scoped(.ui_dl);

/// Make `state.detail_catalogue` hold `tid`'s catalogue. Reads the DB only
/// when the cached one is for another game (or was invalidated). A read
/// failure leaves it null and is not retried until the game changes.
pub fn ensureCatalogue(frame: *Frame, tid: u64) ?*const catalogue_view.Catalogue {
    const state = frame.state;
    if (state.detail_catalogue_tid != tid) {
        freeDetailCatalogue(state);
        state.detail_part_offer = null;
        state.detail_catalogue_tid = tid;
        state.detail_catalogue = catalogue_view.build(frame.lib.alloc, frame.lib, tid) catch |e| blk: {
            log.warn("download catalogue for {d}: {s}", .{ tid, @errorName(e) });
            break :blk null;
        };
    }
    if (state.detail_catalogue) |*c| return c;
    return null;
}

/// Drop the cached catalogue of `tid` (its sync just rewrote the rows).
pub fn invalidateCatalogue(state: *State, tid: u64) void {
    if (state.detail_catalogue_tid != tid) return;
    freeDetailCatalogue(state);
    state.detail_catalogue_tid = 0;
    if (state.detail_part_offer) |o| if (o.tid == tid) {
        state.detail_part_offer = null;
    };
}

pub fn freeDetailCatalogue(state: *State) void {
    if (state.detail_catalogue) |*c| c.deinit();
    state.detail_catalogue = null;
}

/// A non-terminal job's source link and step, copied out of the snapshot.
pub const RunningHref = struct { href: []const u8, step: downloads.model.Step };

/// Every non-terminal job's source href + step, copied into `a` (the
/// frame arena). One snapshot read, released before returning.
pub fn runningHrefs(frame: *Frame, a: std.mem.Allocator) []const RunningHref {
    const snap = frame.dl.snapshot();
    defer frame.dl.releaseSnapshot();
    var out: std.ArrayList(RunningHref) = .empty;
    for (snap.jobs) |v| {
        const j = &v.job;
        if (j.step.isTerminal() or j.source_href.len == 0) continue;
        const href = a.dupe(u8, j.source_href) catch break;
        out.append(a, .{ .href = href, .step = j.step }) catch break;
    }
    return out.items;
}

/// The id of a job queued from `href` (non-terminal first, else the
/// newest), or null.
fn jobIdForHref(frame: *Frame, href: []const u8) ?u64 {
    const snap = frame.dl.snapshot();
    defer frame.dl.releaseSnapshot();
    var any: ?u64 = null;
    for (snap.jobs) |v| {
        if (!std.mem.eql(u8, v.job.source_href, href)) continue;
        if (!v.job.step.isTerminal()) return v.job.id;
        if (any == null or v.job.id > any.?) any = v.job.id;
    }
    return any;
}

/// Queue one catalogue link of `game`. The downloader re-reads the row and
/// toasts on a duplicate ("Already queued") or a missing row. When the
/// link is Part N of a set and later parts exist, offers to queue them.
pub fn enqueueCatalogue(frame: *Frame, game: *const library.Game, href: []const u8) void {
    const state = frame.state;
    const tid = game.f95_thread_id;
    frame.dl.send(.{ .enqueue_catalogue = .{
        .game_thread_id = tid,
        .href = href,
        .title = game.name,
        .group_with = null,
    } });

    state.detail_part_offer = null;
    const cat: ?*const catalogue_view.Catalogue = if (state.detail_catalogue_tid == tid)
        (if (state.detail_catalogue) |*c| c else null)
    else
        null;
    if (cat) |c| if (c.lookup(href)) |item| if (catalogue_view.nextParts(c, item)) |range| {
        if (href.len <= 1024) {
            var offer: state_mod.PartOffer = .{ .tid = tid, .from = range.from, .to = range.to };
            @memcpy(offer.first_href_buf[0..href.len], href);
            offer.first_href_len = @intCast(href.len);
            state.detail_part_offer = offer;
            var buf: [96]u8 = undefined;
            const msg = if (range.from == range.to)
                std.fmt.bufPrint(&buf, "Queued part {d} · also queue part {d}?", .{ item.entry.part.?, range.from })
            else
                std.fmt.bufPrint(&buf, "Queued part {d} · also queue parts {d}–{d}?", .{ item.entry.part.?, range.from, range.to });
            state.setDownloadMsg(msg catch "Queued · see Downloads");
            return;
        }
    };
    state.setDownloadMsg("Queued · see Downloads");
}

/// Accept the "Queue parts a–b" offer: one `enqueue_catalogue` per part,
/// grouped with the first part's job when the downloader already has it.
pub fn acceptPartOffer(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const offer = state.detail_part_offer orelse return;
    state.detail_part_offer = null;
    if (offer.tid != game.f95_thread_id) return;
    const cat: *const catalogue_view.Catalogue = if (state.detail_catalogue_tid == offer.tid)
        (if (state.detail_catalogue) |*c| c else return)
    else
        return;
    const first = cat.lookup(offer.firstHref()) orelse return;
    // Snapshot read (and release) before any send.
    const group = jobIdForHref(frame, offer.firstHref());
    var sent: u32 = 0;
    var k: u16 = offer.from;
    while (k <= offer.to) : (k += 1) {
        const it = catalogue_view.findPart(cat, first, @intCast(k)) orelse continue;
        frame.dl.send(.{ .enqueue_catalogue = .{
            .game_thread_id = offer.tid,
            .href = cat.row(it).href,
            .title = game.name,
            .group_with = group,
        } });
        sent += 1;
    }
    var buf: [64]u8 = undefined;
    state.setDownloadMsg(std.fmt.bufPrint(&buf, "Queued {d} more part(s) · see Downloads", .{sent}) catch "Queued · see Downloads");
}

/// Retry a failed download (the downloader requeues it with the same
/// source; a checksum / bad-archive failure deletes the file first).
pub fn retryDownload(frame: *Frame, job_id: u64) void {
    frame.dl.send(.{ .retry = job_id });
}

/// True iff a job for this F95 thread is not terminal (queued,
/// downloading, installing, seeding …). The detail page's Download
/// button uses this to offer "View download" instead of a duplicate.
pub fn hasActiveDownloadForGame(frame: *Frame, thread_id: u64) bool {
    const snap = frame.dl.snapshot();
    defer frame.dl.releaseSnapshot();
    for (snap.jobs) |v| {
        if (v.job.game_thread_id == thread_id and !v.job.step.isTerminal()) return true;
    }
    return false;
}

/// Progress numbers of one download, copied out of the snapshot.
pub const DlProgress = struct {
    id: u64,
    bytes_done: u64,
    bytes_total: ?u64,
    dl_speed: u64,
};

/// The first job of this game that is still fetching bytes (queued up
/// to verifying). Seeding is skipped: the payload is complete. Null when
/// nothing is in flight.
pub fn findLeechingJobForGame(frame: *Frame, thread_id: u64) ?DlProgress {
    const snap = frame.dl.snapshot();
    defer frame.dl.releaseSnapshot();
    for (snap.jobs) |v| {
        const j = &v.job;
        if (j.game_thread_id != thread_id) continue;
        switch (j.step) {
            .queued, .resolving, .fetching_metadata, .finding_peers, .downloading, .verifying => return .{
                .id = j.id,
                .bytes_done = j.bytes_done,
                .bytes_total = j.bytes_total,
                .dl_speed = j.dl_speed,
            },
            else => {},
        }
    }
    return null;
}

/// A copy of the snapshot whose strings live in `a` (normally the dvui
/// per-frame arena). Renderers use this so the snapshot lock is not held
/// while widgets are built. On out-of-memory the job list is shortened.
pub const SnapCopy = struct {
    jobs: []const JobView,
    totals: downloads.downloader.Totals,
};

pub fn copySnapshot(frame: *Frame, a: std.mem.Allocator) SnapCopy {
    const snap = frame.dl.snapshot();
    defer frame.dl.releaseSnapshot();
    const out = a.alloc(JobView, snap.jobs.len) catch return .{ .jobs = &.{}, .totals = snap.totals };
    var n: usize = 0;
    for (snap.jobs) |v| {
        var c = v;
        c.job = downloads.downloader.cloneJob(a, v.job) catch continue;
        c.awaiting_prompt = if (v.awaiting_prompt) |p| (a.dupe(u8, p) catch null) else null;
        out[n] = c;
        n += 1;
    }
    return .{ .jobs = out[0..n], .totals = snap.totals };
}

/// Any non-terminal job that can be paused / any paused job — for the
/// Pause all / Resume all buttons.
pub const PauseResume = struct { any_pausable: bool = false, any_paused: bool = false };

pub fn pauseResumeState(jobs: []const JobView) PauseResume {
    var r: PauseResume = .{};
    for (jobs) |v| switch (v.job.step) {
        .fetching_metadata, .finding_peers, .downloading => r.any_pausable = true,
        .paused => r.any_paused = true,
        else => {},
    };
    return r;
}
