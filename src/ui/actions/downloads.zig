// Pre-download workers that turn a game into something the downloader
// can fetch, then hand it over with a `Command`:
//   - RPDL (Tier 2): worker thread → search dl.rpdl.net (or a recipe-
//     pinned torrent id) → fetch the .torrent → `enqueue_torrent`.
//   - Donor DDL (Tier 1): worker thread → POST /sam/dddl.php for a
//     signed URL + cookie → `enqueue_url` with the cookie header.
// Everything after the hand-over (slots, retries, verify, extract,
// install) is the downloader's job — see `dl.zig`.

const std = @import("std");
const log = std.log.scoped(.ui_actions);
const library = @import("library");
const f95 = @import("f95");
const downloads = @import("downloads");
const version_mod = @import("util_version");
const dvui = @import("dvui");
const types = @import("../types.zig");
const owned_types = @import("../owned.zig");
const job_mod = @import("../job.zig");

const Frame = types.Frame;
const State = types.State;

pub const RpdlDownloadPayload = owned_types.RpdlDownloadPayload;
pub const RpdlDownloadJob = owned_types.RpdlDownloadJob;
pub const DonorDownloadPayload = owned_types.DonorDownloadPayload;
pub const DonorDownloadJob = owned_types.DonorDownloadJob;

// ============================================================
//  RPDL auto-download (Tier 2)
// ============================================================
//
// Per-game flow: search dl.rpdl.net by sanitized game name + parsed
// version → pick best torrent → fetch .torrent bytes → `enqueue_torrent`
// → the downloader leeches + seeds to the configured ratio. All network
// work runs on a detached worker thread; `drainRpdlDownload` finishes
// the handoff on the UI thread.

/// Spawn the RPDL search → fetch worker. No-op when:
///   - another RPDL job is already running for any game (we
///     serialise to keep aria2's accept-rate sane);
///   - the user isn't logged into RPDL (the .torrent download
///     needs the bearer token).
pub fn startRpdlDownload(frame: *Frame, game: *const library.Game) void {
    startRpdl(frame, game, null);
}

/// Same flow for a recipe-pinned RPDL torrent: no search, fetch `id`.
pub fn startRpdlDownloadById(frame: *Frame, game: *const library.Game, id: u64) void {
    startRpdl(frame, game, id);
}

fn startRpdl(frame: *Frame, game: *const library.Game, direct_id: ?u64) void {
    const state = frame.state;
    log.info("startRpdlDownload: ENTRY tid={d} name='{s}'", .{ game.f95_thread_id, game.name });

    if (state.pending_rpdl_download != null) {
        log.warn("startRpdlDownload: REFUSED — pending_rpdl_download already set (job in flight)", .{});
        state.setDownloadMsg("another RPDL download is already starting…");
        return;
    }
    const token = state.rpdl_token orelse {
        log.warn("startRpdlDownload: REFUSED — no RPDL token", .{});
        state.setDownloadMsg("RPDL: not logged in — open Settings → Accounts → RPDL");
        return;
    };
    if (token.len == 0) {
        log.warn("startRpdlDownload: REFUSED — token len=0", .{});
        state.setDownloadMsg("RPDL: token is empty — re-login");
        return;
    }
    log.info(
        "startRpdlDownload: PROCEEDING tid={d} name='{s}' version={?s} token={d}b",
        .{ game.f95_thread_id, game.name, game.latest_version, token.len },
    );

    const alloc = frame.lib.alloc;
    const name_dup = alloc.dupe(u8, game.name) catch {
        log.err("startRpdlDownload: name dupe OOM", .{});
        return;
    };
    const token_dup = alloc.dupe(u8, token) catch {
        log.err("startRpdlDownload: token dupe OOM", .{});
        alloc.free(name_dup);
        return;
    };
    const version_dup: ?[]u8 = if (game.latest_version) |v| (alloc.dupe(u8, v) catch null) else null;

    _ = job_mod.spawnJob(
        RpdlDownloadPayload,
        rpdlDownloadWorker,
        alloc,
        frame.win,
        .{
            .io = frame.io,
            .token = token_dup,
            .game_name = name_dup,
            .game_version = version_dup,
            .thread_id = game.f95_thread_id,
            .direct_id = direct_id,
        },
        &state.pending_rpdl_download,
    ) catch |e| {
        log.err("startRpdlDownload: job alloc/spawn failed: {s}", .{@errorName(e)});
        alloc.free(name_dup);
        alloc.free(token_dup);
        if (version_dup) |v| alloc.free(v);
        return;
    };
    log.info("startRpdlDownload: worker thread spawned + detached", .{});
    log.info("startRpdlDownload: state.pending_rpdl_download set — awaiting drain", .{});
    var msg_buf: [128]u8 = undefined;
    const m = std.fmt.bufPrint(&msg_buf, "RPDL: searching for '{s}'…", .{game.name}) catch "RPDL: searching…";
    state.setDownloadMsg(m);
}

fn rpdlDownloadWorker(job: *RpdlDownloadJob) void {
    const p = &job.payload;
    const fail = struct {
        fn run(j: *RpdlDownloadJob, err: []const u8) void {
            j.payload.err_name = err;
            j.markFailed();
        }
    }.run;

    const t_search = std.Io.Clock.Timestamp.now(p.io, .real).raw.toMilliseconds();
    if (p.direct_id) |id| {
        log.info("rpdl worker: tid={d} fetching recipe-pinned torrent id={d}", .{ p.thread_id, id });
        p.picked_id = id;
        const bytes = downloads.rpdl.fetchTorrent(job.alloc, p.io, p.token, id) catch |e| {
            log.warn("rpdl fetchTorrent failed: {s}", .{@errorName(e)});
            fail(job, @errorName(e));
            return;
        };
        p.torrent_bytes = bytes;
        job.markDone();
        return;
    }
    log.info("rpdl worker: tid={d} starting search for '{s}'", .{ p.thread_id, p.game_name });
    const results = downloads.rpdl.search(job.alloc, p.io, p.game_name) catch |e| {
        log.warn("rpdl search failed: {s}", .{@errorName(e)});
        fail(job, @errorName(e));
        return;
    };
    defer downloads.rpdl.freeSearchResults(job.alloc, results);
    const t_after_search = std.Io.Clock.Timestamp.now(p.io, .real).raw.toMilliseconds();
    log.info("rpdl worker: tid={d} search_ms={d} returned {d} result(s)", .{ p.thread_id, t_after_search - t_search, results.len });

    if (results.len == 0) {
        log.warn("rpdl worker: tid={d} no search results", .{p.thread_id});
        fail(job, "NoMatches");
        return;
    }

    const ver_opt: ?[]const u8 = if (p.game_version) |v| v else null;
    const picked = downloads.rpdl.pickBestMatch(results, p.game_name, ver_opt) orelse {
        log.warn("rpdl worker: tid={d} all candidates rejected (zero-seed or name mismatch)", .{p.thread_id});
        fail(job, "NoSeeders");
        return;
    };

    p.picked_id = picked.id;
    p.picked_title = job.alloc.dupe(u8, picked.title) catch {
        fail(job, "OutOfMemory");
        return;
    };

    log.info("rpdl worker: tid={d} fetching .torrent for picked id={d}", .{ p.thread_id, picked.id });
    const t_fetch = std.Io.Clock.Timestamp.now(p.io, .real).raw.toMilliseconds();
    const bytes = downloads.rpdl.fetchTorrent(job.alloc, p.io, p.token, picked.id) catch |e| {
        log.warn("rpdl fetchTorrent failed: {s}", .{@errorName(e)});
        fail(job, @errorName(e));
        return;
    };
    const t_done = std.Io.Clock.Timestamp.now(p.io, .real).raw.toMilliseconds();
    log.info("rpdl worker: tid={d} fetched {d} torrent bytes in {d}ms (total elapsed {d}ms)", .{
        p.thread_id, bytes.len, t_done - t_fetch, t_done - t_search,
    });
    p.torrent_bytes = bytes;
    job.markDone();
}

/// Drain the RPDL search/fetch worker each frame. On done: hand the
/// .torrent bytes to the downloader (`enqueue_torrent`).
/// On failed: surface the error in `download_msg`.
pub fn drainRpdlDownload(frame: *Frame) void {
    job_mod.drainBackgroundJob(
        RpdlDownloadPayload,
        onRpdlDownloadDone,
        onRpdlDownloadFailed,
        frame,
        &frame.state.pending_rpdl_download,
    );
}

fn freeRpdlPayload(job: *RpdlDownloadJob) void {
    const p = &job.payload;
    job.alloc.free(p.token);
    job.alloc.free(p.game_name);
    if (p.game_version) |v| job.alloc.free(v);
    if (p.picked_title) |t| job.alloc.free(t);
    if (p.torrent_bytes) |b| job.alloc.free(b);
}

fn onRpdlDownloadFailed(frame: *Frame, job: *RpdlDownloadJob) void {
    const state = frame.state;
    const p = &job.payload;
    defer freeRpdlPayload(job);
    log.info("drainRpdlDownload: observed phase=failed tid={d}", .{p.thread_id});
    var emsg: [160]u8 = undefined;
    const m = std.fmt.bufPrint(&emsg, "RPDL: {s}", .{rpdlErrorMessage(p.err_name orelse "?")}) catch "RPDL failed";
    state.setDownloadMsg(m);
}

fn onRpdlDownloadDone(frame: *Frame, job: *RpdlDownloadJob) void {
    const state = frame.state;
    const p = &job.payload;
    defer freeRpdlPayload(job);
    log.info("drainRpdlDownload: observed phase=done tid={d}", .{p.thread_id});

    const bytes = p.torrent_bytes orelse {
        state.setDownloadMsg("RPDL: internal error — no torrent bytes");
        return;
    };

    // Capture the RPDL-derived version from the torrent title so the
    // install row records the exact build the user downloaded. A
    // recipe-pinned id has no title: fall back to the scraped version.
    var label_buf: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "rpdl:{d}", .{p.picked_id}) catch "rpdl";
    const picked_version: ?[]const u8 = if (p.picked_title) |t|
        version_mod.extractFromTitle(t)
    else
        p.game_version;
    if (picked_version) |v| {
        log.info("rpdl: tid={d} captured version='{s}'", .{ p.thread_id, v });
    } else {
        log.warn("rpdl: tid={d} no version segment in torrent title", .{p.thread_id});
    }
    frame.dl.send(.{ .enqueue_torrent = .{
        .label = label,
        .torrent_bytes = bytes,
        .kind = .game,
        .game_thread_id = p.thread_id,
        .title = p.game_name,
        .version = picked_version,
    } });

    var ok_buf: [192]u8 = undefined;
    const title = p.picked_title orelse p.game_name;
    const m = std.fmt.bufPrint(
        &ok_buf,
        "RPDL: queued '{s}' (torrent #{d}) — seeds to a {d:.1}× ratio when done",
        .{ title, p.picked_id, state.dl_settings.seed_ratio },
    ) catch "RPDL: queued";
    state.setDownloadMsg(m);
}

/// Human-friendly error names for the RPDL flow. Falls through to
/// the raw `@errorName` when we don't recognise the cause.
fn rpdlErrorMessage(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "NoMatches")) return "no torrents found for this game";
    if (std.mem.eql(u8, name, "NoSeeders")) return "torrent has zero seeders — try again later";
    if (std.mem.eql(u8, name, "AuthRequired")) return "RPDL token rejected — re-login in Settings";
    if (std.mem.eql(u8, name, "NotFound")) return "torrent id not found on RPDL";
    if (std.mem.eql(u8, name, "NetworkError")) return "network error — check your connection";
    if (std.mem.eql(u8, name, "RpdlInvalidResponse")) return "RPDL returned an unexpected response";
    if (std.mem.eql(u8, name, "OutOfMemory")) return "out of memory";
    return name;
}


// ============================================================
//  Donor DDL (Tier 1) — POST /sam/dddl.php → aria2 enqueue
// ============================================================
//
// Per-game flow for users with an F95 donor account:
//   1. POST `/sam/dddl.php` with `thread_id=<tid>` and the session
//      cookie. Worker thread does this off the UI thread.
//   2. Response carries a short-lived signed URL pointing at
//      `attachments.f95zone.to`.
//   3. UI thread sends `enqueue_url` with the cookie header — aria2
//      downloads via HTTP, with Range-based resume support.
//
// A failed donor download is retried by the downloader with the same
// URL + cookie; an expired URL needs a fresh Download click.

/// Kick off the donor-DDL fetch worker. No-op when:
///   - another donor job is already starting (we serialise so the
///     URL→enqueue handoff stays simple);
///   - the user has no F95 session cookie (the POST would 401).
pub fn startDonorDownload(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    log.info("startDonorDownload: ENTRY tid={d} name='{s}'", .{ game.f95_thread_id, game.name });

    if (state.pending_donor_download != null) {
        log.warn("startDonorDownload: REFUSED — pending_donor_download already set", .{});
        state.setDownloadMsg("donor DDL: another request is already in flight…");
        return;
    }
    if (state.login_status != .logged_in) {
        log.warn("startDonorDownload: REFUSED — not logged in (status={s})", .{@tagName(state.login_status)});
        state.setDownloadMsg("donor DDL: log into F95 first (Settings → Accounts)");
        return;
    }
    log.info("startDonorDownload: PROCEEDING tid={d}", .{game.f95_thread_id});

    const alloc = frame.lib.alloc;
    const name_dup = alloc.dupe(u8, game.name) catch {
        log.err("startDonorDownload: name dupe OOM", .{});
        return;
    };
    const version_dup: ?[]u8 = if (game.latest_version) |v| (alloc.dupe(u8, v) catch null) else null;

    _ = job_mod.spawnJob(
        DonorDownloadPayload,
        donorDownloadWorker,
        alloc,
        frame.win,
        .{
            .io = frame.io,
            .f95_client = frame.f95_svc.client,
            .game_name = name_dup,
            .game_version = version_dup,
            .thread_id = game.f95_thread_id,
        },
        &state.pending_donor_download,
    ) catch |e| {
        log.err("startDonorDownload: job alloc/spawn failed: {s}", .{@errorName(e)});
        alloc.free(name_dup);
        if (version_dup) |v| alloc.free(v);
        return;
    };
    log.info("startDonorDownload: worker thread spawned + detached", .{});
    log.info("startDonorDownload: state.pending_donor_download set — awaiting drain", .{});
    var msg_buf: [128]u8 = undefined;
    const m = std.fmt.bufPrint(&msg_buf, "donor DDL: requesting signed URL for '{s}'…", .{game.name}) catch "donor DDL: requesting…";
    state.setDownloadMsg(m);
}

fn donorDownloadWorker(job: *DonorDownloadJob) void {
    const p = &job.payload;
    log.info("donor worker: tid={d} starting two-step DDL flow", .{p.thread_id});
    const dl = f95.donor_ddl.requestDownload(job.alloc, p.f95_client, p.thread_id) catch |e| {
        log.warn("donor worker: tid={d} flow failed: {s}", .{ p.thread_id, @errorName(e) });
        p.err_name = @errorName(e);
        job.markFailed();
        return;
    };
    log.info(
        "donor worker: tid={d} got URL+cookie (url-len={d}, cookie-len={d}, file='{s}')",
        .{ p.thread_id, dl.url.len, dl.cookie.len, dl.filename },
    );
    p.signed_url = dl.url;
    p.signed_cookie = dl.cookie;
    p.signed_filename = dl.filename;
    job.markDone();
}

pub fn drainDonorDownload(frame: *Frame) void {
    job_mod.drainBackgroundJob(
        DonorDownloadPayload,
        onDonorDownloadDone,
        onDonorDownloadFailed,
        frame,
        &frame.state.pending_donor_download,
    );
}

fn freeDonorPayload(job: *DonorDownloadJob) void {
    const p = &job.payload;
    job.alloc.free(p.game_name);
    if (p.game_version) |v| job.alloc.free(v);
    if (p.signed_url) |u| job.alloc.free(u);
    if (p.signed_cookie) |c| job.alloc.free(c);
    if (p.signed_filename) |fn_| job.alloc.free(fn_);
}

fn onDonorDownloadFailed(frame: *Frame, job: *DonorDownloadJob) void {
    const state = frame.state;
    const p = &job.payload;
    defer freeDonorPayload(job);
    log.info("drainDonorDownload: observed phase=failed tid={d}", .{p.thread_id});
    var emsg: [160]u8 = undefined;
    const m = std.fmt.bufPrint(&emsg, "donor DDL: {s}", .{donorErrorMessage(p.err_name orelse "?")}) catch "donor DDL failed";
    state.setDownloadMsg(m);
}

fn onDonorDownloadDone(frame: *Frame, job: *DonorDownloadJob) void {
    const state = frame.state;
    const p = &job.payload;
    defer freeDonorPayload(job);
    log.info("drainDonorDownload: observed phase=done tid={d}", .{p.thread_id});

    const url = p.signed_url orelse {
        state.setDownloadMsg("donor DDL: internal error — no signed URL");
        return;
    };

    // Build the `Cookie:` header from the per-URL cookie F95 handed
    // back on step 2. Without these on every GET (and every aria2
    // retry), the attachments.f95zone.to CDN 403s. The header list
    // is built on the stack; aria2 sees just one header for now.
    var cookie_hdr_buf: [4096]u8 = undefined;
    const headers: []const []const u8 = blk: {
        const cookie = p.signed_cookie orelse break :blk &.{};
        if (cookie.len == 0) break :blk &.{};
        const hdr = std.fmt.bufPrint(&cookie_hdr_buf, "Cookie: {s}", .{cookie}) catch {
            log.warn("donor: cookie too large to fit in header buffer ({d} bytes); proceeding without it", .{cookie.len});
            break :blk &.{};
        };
        break :blk @as([]const []const u8, &.{hdr});
    };

    // aria2 gets split=8 / 8 connections / retry-wait=3 for every HTTP
    // job (engine_aria2), which is what the CDN needs. Log the host and
    // cookie size — useful when a user reports stalls.
    var url_host_buf: [128]u8 = undefined;
    const url_host = extractHostForLog(&url_host_buf, url);
    const cookie_len: usize = if (headers.len > 0) headers[0].len else 0;
    log.info(
        "donor enqueue: tid={d} host='{s}' url_len={d} cookie_hdr_len={d} version={?s}",
        .{ p.thread_id, url_host, url.len, cookie_len, p.game_version },
    );
    frame.dl.send(.{ .enqueue_url = .{
        .url = url,
        .kind = .game,
        .game_thread_id = p.thread_id,
        .title = p.game_name,
        .version = p.game_version,
        .host = downloads.downloader.HOST_DONOR,
        .headers = headers,
    } });
    state.setDownloadMsg("donor DDL: queued — see Downloads");
}

/// Human-friendly error names for the donor-DDL flow.
/// Pull just the host segment out of a URL for log lines —
/// `https://attachments.f95zone.to/long/signed/path` → `attachments.f95zone.to`.
/// Falls back to `"?"` if the URL doesn't look like an http URL.
fn extractHostForLog(buf: []u8, url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return "?";
    const host_start = scheme_end + 3;
    var host_end = host_start;
    while (host_end < url.len and url[host_end] != '/' and url[host_end] != '?') : (host_end += 1) {}
    const host = url[host_start..host_end];
    const n = @min(host.len, buf.len);
    @memcpy(buf[0..n], host[0..n]);
    return buf[0..n];
}

fn donorErrorMessage(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "AuthRequired")) return "F95 session expired — log in again";
    if (std.mem.eql(u8, name, "DonorNotEligible")) return "this F95 account isn't a donor — Tier-1 DDL requires a paid contribution";
    if (std.mem.eql(u8, name, "DonorNoDdl")) return "no donor DDL configured for this thread — try RPDL instead";
    if (std.mem.eql(u8, name, "DonorInvalidResponse")) return "F95 returned an unexpected response (endpoint changed?)";
    if (std.mem.eql(u8, name, "NotFound")) return "F95 says this thread doesn't exist";
    if (std.mem.eql(u8, name, "NetworkError")) return "network error — check your connection";
    if (std.mem.eql(u8, name, "OutOfMemory")) return "out of memory";
    return name;
}
