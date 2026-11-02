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
        .sign_in_needed => frame.state.setDownloadMsg("Sign in to F95zone to download this"),
    };
}

/// Look up the recipe for `game` and queue its *first* source. RPDL
/// fetches the pinned torrent on a worker, then `enqueue_torrent`;
/// DDL / mirror sources go straight in as `enqueue_url`.
///
/// On success: routes to the Downloads screen so the user sees the new
/// job. On failure: one toast line and the detail screen stays.
pub fn doDownloadGame(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

    const parsed_opt = frame.recipe_repo.findGameByThread(game.f95_thread_id) catch |e| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Recipe lookup failed: {s}", .{@errorName(e)}) catch "Recipe lookup failed";
        state.setDownloadMsg(msg);
        return;
    };
    var parsed = parsed_opt orelse {
        state.setDownloadMsg("No recipe for this game. Drop one in <config>/f69/recipes/<id>.game.zon");
        return;
    };
    defer parsed.deinit();

    if (parsed.recipe.sources.len == 0) {
        state.setDownloadMsg("Recipe has no sources defined.");
        return;
    }

    switch (parsed.recipe.sources[0]) {
        .rpdl => |x| {
            // The worker refuses (with its own message) when another RPDL
            // fetch runs or no token is set; it then never enqueues.
            flows.startRpdlDownloadById(frame, game, x.id);
            if (state.pending_rpdl_download == null) return;
        },
        .ddl => |x| enqueueUrl(frame, game, x.url, downloads.hexDecode(x.sha256) catch null, "ddl"),
        .mirror => |x| enqueueUrl(frame, game, x.url, if (x.sha256) |h| (downloads.hexDecode(h) catch null) else null, "mirror"),
    }
    state.setDownloadMsg("Queued download — see Downloads");
    state.screen = .downloads;
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
