//! UI-thread side of the threading model: drains the worker-to-UI event
//! mailbox once per frame. `guiFrame` calls `drainThreads` before every
//! other drain so results from the compute and I/O threads land first.

const std = @import("std");
const compat_mod = @import("compat");
const types = @import("../types.zig");
const state_mod = @import("../state.zig");
const common = @import("common.zig");
const convert_job = @import("../threads/jobs/convert.zig");
const compat_job = @import("../threads/jobs/compat.zig");
const launch_act = @import("launch.zig");
const mods_act = @import("mods.zig");
const reanalyse_job = @import("../threads/jobs/reanalyse.zig");

const threads = types.threads;
const Frame = types.Frame;
const Kind = threads.activity.Kind;

const log = std.log.scoped(.ui_threads);

/// Plain-language name of a tool, for toasts ("Convert is already
/// running for this game").
pub fn kindLabel(k: Kind) []const u8 {
    return switch (k) {
        .convert => "Convert",
        .decrypt => "Decrypt",
        .compat_fix => "Compat fix",
        .rpa_extract => "Extract .rpa",
        .hash => "Hashing",
        .reanalyse => "Re-analyse",
        .plan_sim => "Mod plan check",
        .folder_scan => "Folder scan",
        .mod_install => "Mod install",
        .mod_uninstall => "Mod uninstall",
        .sign_in => "Sign-in",
        .launch_probe => "Launch check",
    };
}

/// Starts an activity for a per-game tool. Returns null (after a toast)
/// when a tool already runs for `tid`, or when the book is out of memory.
/// The caller must submit the activity or `book.finish` it.
pub fn startTool(frame: *Frame, kind: Kind, tid: u64, title: []const u8) ?*threads.Activity {
    if (frame.book.liveForGame(tid)) {
        const running = liveKindForGame(frame, tid) orelse kind;
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s} is already running for this game", .{kindLabel(running)}) catch "A tool is already running for this game";
        frame.state.pushToast(.warn, msg);
        return null;
    }
    return frame.book.start(kind, tid, title) catch {
        frame.state.notifyErr("Out of memory.");
        return null;
    };
}

/// Cancel of a tool row or strip: flags the activity. A mod job
/// (`aux_id` is its mod-queue job id) is flagged in the mod queue too; a
/// queued one stays in the queue and ends as cancelled when the queue
/// reaches it.
pub fn cancelTool(frame: *Frame, id: u64) void {
    frame.book.requestCancel(id);
    var arena = std.heap.ArenaAllocator.init(frame.lib.alloc);
    defer arena.deinit();
    const views = frame.book.snapshot(arena.allocator()) catch return;
    for (views) |v| {
        if (v.id != id) continue;
        if ((v.kind == .mod_install or v.kind == .mod_uninstall) and v.aux_id != 0) frame.mod_jobs.cancel(v.aux_id);
        return;
    }
}

/// Removes every finished tool activity from the book (the drawer's
/// "Clear finished"). Live ones stay.
pub fn clearFinishedTools(frame: *Frame) void {
    var arena = std.heap.ArenaAllocator.init(frame.lib.alloc);
    defer arena.deinit();
    const views = frame.book.snapshot(arena.allocator()) catch return;
    for (views) |v| {
        if (v.status == .queued or v.status == .running) continue;
        frame.book.remove(v.id);
    }
}

/// Ends an activity that never reached the worker, with an error toast.
pub fn failTool(frame: *Frame, a: *threads.Activity, msg: []const u8) void {
    const now = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();
    frame.book.finish(a, .err, msg, now);
    frame.state.notifyErr(msg);
}

/// The game's name from the frame's in-memory game list (no DB read), or
/// "game" when it is not there.
pub fn gameNameFor(frame: *Frame, tid: u64) []const u8 {
    if (frame.games_by_thread) |map| if (map.get(tid)) |g| return g.name;
    for (frame.games) |*g| if (g.f95_thread_id == tid) return g.name;
    return "game";
}

/// Kind of the live activity for `tid`, if any.
fn liveKindForGame(frame: *Frame, tid: u64) ?Kind {
    var arena = std.heap.ArenaAllocator.init(frame.lib.alloc);
    defer arena.deinit();
    const views = frame.book.snapshot(arena.allocator()) catch return null;
    for (views) |v| {
        if (v.game_thread_id != tid) continue;
        if (v.status == .queued or v.status == .running) return v.kind;
    }
    return null;
}

/// The live (queued or running) activity for `tid`, copied into `arena`.
pub fn liveViewForGame(frame: *Frame, arena: std.mem.Allocator, tid: u64) ?threads.activity.View {
    const views = frame.book.snapshot(arena) catch return null;
    for (views) |v| {
        if (v.game_thread_id != tid) continue;
        if (v.status == .queued or v.status == .running) return v;
    }
    return null;
}

/// Maps the thread-side toast kind onto the State toast kind.
fn kindMap(k: threads.events.ToastKind) state_mod.ToastKind {
    return switch (k) {
        .ok => .success,
        .warn => .warn,
        .err => .err,
        .info => .info,
    };
}

/// Moves every queued `UiEvent` off `frame.events` and handles it, then
/// frees the strings it owns.
pub fn drainThreads(frame: *Frame) void {
    const alloc = frame.lib.alloc;
    var list: std.ArrayList(threads.UiEvent) = .empty;
    defer list.deinit(alloc);
    frame.events.drain(alloc, &list);
    for (list.items) |ev| {
        switch (ev) {
            .toast => |t| frame.state.pushToast(kindMap(t.kind), t.msg),
            .work_done => |w| handleWorkDone(frame, w.activity_id, w.outcome),
            .io => |r| {
                // Task 15 routes replies to the file cache. Until then
                // nothing waits on a ticket: free the reply here.
                threads.io_thread.freeReply(frame.events.alloc, r);
                continue;
            },
            .wake => {},
        }
        // Toast messages are owned by the Events allocator.
        threads.events.freeEvent(frame.events.alloc, ev);
    }
}

fn resultToast(k: threads.activity.ResultKind) state_mod.ToastKind {
    return switch (k) {
        .ok => .success,
        .warn => .warn,
        .err => .err,
    };
}

/// Applies a finished compute job's outcome on the UI thread, frees what
/// the outcome owns, and toasts the result of a per-game tool.
fn handleWorkDone(frame: *Frame, activity_id: u64, outcome: threads.work_thread.WorkOutcome) void {
    switch (outcome) {
        // Decrypt and RPA extract own nothing: the toast below is all.
        .none, .mod_queue, .fake, .decrypt, .rpa => {},
        .convert => |c| applyConvertOutcome(frame, c),
        .compat => |c| applyCompatOutcome(frame, c),
        // Writes the labels and toasts the summary itself (the activity
        // result text is the job's own count, before the DB writes).
        .reanalyse => |r| {
            defer reanalyse_job.freeOutcome(frame.work.deps.alloc, r);
            mods_act.applyReanalyseOutcome(frame, r);
        },
    }

    var arena = std.heap.ArenaAllocator.init(frame.lib.alloc);
    defer arena.deinit();
    const views = frame.book.snapshot(arena.allocator()) catch return;
    for (views) |v| {
        if (v.id != activity_id) continue;
        switch (v.kind) {
            .convert, .decrypt, .rpa_extract, .compat_fix => {},
            // A finished re-analyse toasted its summary above; a stop or
            // a failure toasts the activity result here.
            .reanalyse => if (v.status == .done) return,
            else => return,
        }
        frame.state.pushToast(resultToast(v.result_kind), v.result);
        // A finished convert (not a cancel, not a failure) answers the
        // "Found a Windows build" Play error: drop the hero button.
        if (v.kind == .convert and v.status == .done and v.result_kind != .err) {
            if (frame.state.last_play_needs_convert == v.game_thread_id) frame.state.last_play_needs_convert = null;
        }
        return;
    }
}

/// DB part of the post-convert compat step: drop the rows of fixes the
/// job undid, write the new ones (same as `launch.applyCompatFix`), then
/// refresh the installed set.
fn applyConvertOutcome(frame: *Frame, c: threads.work_thread.ConvertOutcome) void {
    defer convert_job.freeOutcome(frame.compat_svc, c);
    if (c.install_id) |*id| {
        const id_slice: []const u8 = id[0..];
        for (c.compat_undone) |rid| {
            frame.lib.deleteAppliedCompat(id_slice, rid) catch |e| {
                log.warn("convert: delete compat row {s} failed: {s}", .{ rid, @errorName(e) });
            };
        }
        if (recordCompatFixes(frame, id_slice, c.compat_applied) > 0)
            frame.state.notifyErr("Convert: a compat fix was applied but could not be saved.");
    }
    if (c.converted) common.refreshInstalledSet(frame);
}

/// DB part of Fix Compat: write each FixRecord the job applied on disk.
fn applyCompatOutcome(frame: *Frame, c: compat_job.CompatOutcome) void {
    defer compat_job.freeOutcome(frame.compat_svc, c);
    if (recordCompatFixes(frame, c.install_id[0..], c.records) > 0)
        frame.state.notifyErr("Compat: a fix was applied but could not be saved.");
}

/// Writes every record with `launch.recordCompatFix`. Does not free
/// them. Returns how many could not be saved (each is logged).
fn recordCompatFixes(frame: *Frame, install_id: []const u8, records: []const compat_mod.FixRecord) u32 {
    var failed: u32 = 0;
    for (records) |fix| {
        launch_act.recordCompatFix(frame, install_id, fix) catch |e| {
            log.warn("compat: save {s} failed: {s}", .{ fix.recipe_id, @errorName(e) });
            failed += 1;
        };
    }
    return failed;
}

test "kindMap covers every toast kind" {
    try std.testing.expectEqual(state_mod.ToastKind.success, kindMap(.ok));
    try std.testing.expectEqual(state_mod.ToastKind.warn, kindMap(.warn));
    try std.testing.expectEqual(state_mod.ToastKind.err, kindMap(.err));
    try std.testing.expectEqual(state_mod.ToastKind.info, kindMap(.info));
}
