//! Mod install / uninstall as a compute job. Every `Queue.enqueue`
//! submits one `WorkJob.mod_queue` through `Hook.onEnqueue`; the compute
//! thread then takes the queue head (`takeHead`), runs the queue's runner
//! (`actions.modJobRunner`) with the activity, and releases the head
//! (`finishHead`). The runner mirrors phase and file progress into the
//! activity and copies its cancel flag into the job.
//!
//! The UI thread still drains finished heads (`drainModJobs`): it toasts
//! the result and drops the Mods-page cache, so `handleWorkDone` does
//! nothing for these activities.

const std = @import("std");
const mod_job_queue = @import("../../mod_job_queue.zig");
const activity_mod = @import("../activity.zig");
const work_thread = @import("../work_thread.zig");

const Activity = activity_mod.Activity;
const Book = activity_mod.Book;
const ResultKind = activity_mod.ResultKind;
const Queue = mod_job_queue.Queue;
const Job = mod_job_queue.Job;

const log = std.log.scoped(.mod_queue_job);

/// What `run` hands back. Only the text matters; the queue owns the job.
pub const Ran = struct {
    kind: ResultKind,
    msg: []const u8,
};

/// The `on_enqueue` hook: one activity + one compute job per enqueued
/// mod job. `book` and `work` must outlive the queue's last enqueue.
pub const Hook = struct {
    book: *Book,
    work: *work_thread.Worker,

    pub fn onEnqueue(ctx: ?*anyopaque, q: *Queue, job: *Job) void {
        const self: *Hook = @ptrCast(@alignCast(ctx orelse return));
        const kind: activity_mod.Kind = switch (job.kind) {
            .install => .mod_install,
            .uninstall => .mod_uninstall,
        };
        const a = self.book.start(kind, job.game_thread_id, job.display) catch {
            log.warn("mod job {d}: no activity (out of memory)", .{job.id});
            return q.failJob(job, "Out of memory.");
        };
        a.aux_id = job.id;
        a.files.store(true, .release);
        self.work.submit(.{ .mod_queue = {} }, a) catch {
            const now = std.Io.Clock.Timestamp.now(self.book.io, .real).raw.toSeconds();
            self.book.finish(a, .err, "Out of memory.", now);
            q.failJob(job, "Out of memory.");
        };
    }
};

/// Runs the queue head on the compute thread. `buf` holds the result text.
pub fn run(deps: work_thread.Deps, a: *Activity, buf: []u8) anyerror!Ran {
    const q = deps.mod_jobs orelse return .{ .kind = .err, .msg = "Mod queue is not set up." };
    const job = q.takeHead() orelse return .{ .kind = .warn, .msg = "Nothing queued." };

    // A Cancel pressed while the job waited reaches the runner here.
    if (a.cancelled()) job.cancel_flag.store(true, .release);
    a.setPhase(deps.io, mod_job_queue.phaseLabel(.preparing));

    q.runner(q.runner_ctx, job, a);

    // Read what the result needs before `finishHead`: after it the UI
    // thread may free the job.
    const phase = job.currentPhase();
    const res: Ran = switch (phase) {
        .done => .{
            .kind = .ok,
            .msg = std.fmt.bufPrint(buf, "{s} {s}.", .{ if (job.kind == .install) "Installed" else "Removed", job.display }) catch "Done.",
        },
        .canceled => blk: {
            // `Book.finish` records `cancelled` only when the flag is set.
            a.cancel.store(true, .release);
            break :blk .{ .kind = .warn, .msg = "Stopped." };
        },
        else => blk: {
            const e = job.errMessage();
            const n = @min(e.len, buf.len);
            @memcpy(buf[0..n], e[0..n]);
            break :blk .{ .kind = .err, .msg = if (n > 0) buf[0..n] else "Mod job failed." };
        },
    };
    q.finishHead(job);
    return res;
}

fn testRunner(ctx: ?*anyopaque, job: *Job, a: ?*Activity) void {
    const order: *std.ArrayList(u64) = @ptrCast(@alignCast(ctx.?));
    order.append(std.testing.allocator, job.id) catch {};
    if (a) |act| act.report(1, 1);
    job.phase.store(@intFromEnum(mod_job_queue.Phase.done), .release);
}

test "mod_queue job: two enqueues run in order on the compute thread; activities done with results" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const events_mod = @import("../events.zig");
    var order: std.ArrayList(u64) = .empty;
    defer order.deinit(alloc);
    var q = Queue.init(alloc, io, null, testRunner, &order);
    defer q.deinit();
    var book = Book.init(alloc, io);
    defer book.deinit();
    var ev = events_mod.Events.init(alloc, io, null);
    defer ev.deinit();
    var w = work_thread.Worker.init(alloc, io, &book, &ev, .{ .alloc = alloc, .io = io, .mod_jobs = &q });
    var hook: Hook = .{ .book = &book, .work = &w };
    q.on_enqueue = Hook.onEnqueue;
    q.on_enqueue_ctx = &hook;

    var ids: [2]u64 = undefined;
    for (&ids, [_]u64{ 1, 2 }) |*id, mt| {
        const rid = try alloc.dupe(u8, "rid");
        const disp = try alloc.dupe(u8, if (mt == 1) "Mod A" else "Mod B");
        id.* = try q.enqueue(.install, 5, mt, rid, disp, null, .none, "inst");
    }
    try w.start();
    var i: usize = 0;
    while (book.anyLive() and i < 2000) : (i += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    w.deinit();
    try std.testing.expectEqualSlices(u64, &ids, order.items);
    try std.testing.expectEqual(@as(usize, 2), book.items.items.len);
    const a1 = book.items.items[0];
    const a2 = book.items.items[1];
    try std.testing.expect(a1.id < a2.id);
    try std.testing.expectEqual(activity_mod.Status.done, a1.statusGet());
    try std.testing.expectEqual(activity_mod.Status.done, a2.statusGet());
    try std.testing.expectEqual(ids[0], a1.aux_id);
    try std.testing.expectEqual(activity_mod.Kind.mod_install, a1.kind);
    try std.testing.expectEqualStrings("Installed Mod A.", a1.result[0..a1.result_len]);
    try std.testing.expectEqualStrings("Installed Mod B.", a2.result[0..a2.result_len]);
    q.drainFinished();
    try std.testing.expectEqual(@as(usize, 0), q.jobs.items.len);
    var left: std.ArrayList(events_mod.UiEvent) = .empty;
    defer left.deinit(alloc);
    ev.drain(alloc, &left);
    for (left.items) |e| events_mod.freeEvent(alloc, e);
}
