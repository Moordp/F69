// Master tag-list refresh — one-shot worker that re-fetches F95's
// `/tags/` index, sorts + dedupes, swaps `state.tags_master`, and
// persists to `<data_root>/tags.txt`. Tags change rarely so the user
// clicks "Refresh" in Settings → Library every now and then.
//
// Wired through the R6 `Job(Payload)` primitive — see `src/ui/job.zig`
// for the spawn/drain contract.

const std = @import("std");
const log = std.log.scoped(.ui_actions);
const f95 = @import("f95");
const types = @import("../types.zig");
const owned_types = @import("../owned.zig");
const job_mod = @import("../job.zig");
const common = @import("common.zig");

const Frame = types.Frame;
const State = types.State;

pub const RefreshTagsPayload = owned_types.RefreshTagsPayload;
pub const RefreshTagsJob = owned_types.RefreshTagsJob;

pub fn startRefreshTags(frame: *Frame) void {
    const state = frame.state;
    if (state.pending_tags_refresh != null) return;

    _ = job_mod.spawnJob(
        RefreshTagsPayload,
        refreshTagsWorker,
        frame.lib.alloc,
        frame.win,
        .{ .io = frame.io, .f95_svc = frame.f95_svc },
        &state.pending_tags_refresh,
    ) catch return; // alloc/spawn failure: silent, slot stays null
}

fn refreshTagsWorker(job: *RefreshTagsJob) void {
    const p = &job.payload;
    const tags = f95.tags.fetchAllTags(job.alloc, p.f95_svc.client) catch |e| {
        log.warn("refresh tags failed: {s}", .{@errorName(e)});
        p.err_name = @errorName(e);
        job.markFailed();
        return;
    };
    p.tags_out = tags;
    p.fetched_at = std.Io.Clock.Timestamp.now(p.io, .real).raw.toSeconds();
    job.markDone();
}

pub fn drainRefreshTags(frame: *Frame) void {
    job_mod.drainBackgroundJob(
        RefreshTagsPayload,
        onRefreshTagsDone,
        onRefreshTagsFailed,
        frame,
        &frame.state.pending_tags_refresh,
    );
}

fn onRefreshTagsDone(frame: *Frame, job: *RefreshTagsJob) void {
    const state = frame.state;
    const p = &job.payload;

    // Swap in the new list. Free the old master list first.
    freeTagsMaster(frame.lib.alloc, state);
    state.tags_master = p.tags_out;
    state.tags_master_fetched_at = p.fetched_at;

    // Persist. Best-effort — log on failure, don't crash the UI.
    f95.tags.saveToDisk(frame.lib.alloc, frame.io, frame.info.tags_master_path, p.tags_out, p.fetched_at) catch |e| {
        log.warn("tags.txt save failed: {s}", .{@errorName(e)});
    };

    var ok_buf: [96]u8 = undefined;
    const m = std.fmt.bufPrint(&ok_buf, "refreshed {d} tags", .{p.tags_out.len}) catch "refreshed tags";
    state.sync_status = .ok;
    state.setSyncMsg(m);
}

fn onRefreshTagsFailed(frame: *Frame, job: *RefreshTagsJob) void {
    const state = frame.state;
    var emsg: [160]u8 = undefined;
    const m = std.fmt.bufPrint(&emsg, "tag refresh failed: {s}", .{common.friendlyError(job.payload.err_name orelse "?")}) catch "tag refresh failed";
    state.sync_status = .err;
    state.setSyncMsg(m);
    // Single discrete action — surface as a toast (no per-item spam risk).
    state.notifyErr(m);
}

/// Release the master tag list back to `alloc`. Used by the refresh
/// drain before swap-in, and by `runMainLoop`'s shutdown defer.
pub fn freeTagsMaster(alloc: std.mem.Allocator, state: *types.State) void {
    for (state.tags_master) |t| alloc.free(t);
    if (state.tags_master.len > 0) alloc.free(state.tags_master);
    state.tags_master = &.{};
}
