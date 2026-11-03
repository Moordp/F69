//! Compute thread: runs one `WorkJob` at a time. Each job carries an
//! `Activity` (title, phase, progress, cancel flag, result) that the UI
//! reads through `Book.snapshot`. When a job ends the thread finishes the
//! activity and pushes `.work_done` to the UI event mailbox.

const std = @import("std");
const convert = @import("convert");
const compat = @import("compat");
const recipe = @import("recipe");
const mod_job_queue = @import("../mod_job_queue.zig");
const job_mod = @import("../job.zig");
const Mailbox = @import("mailbox.zig").Mailbox;
const activity_mod = @import("activity.zig");
const events_mod = @import("events.zig");
const convert_job = @import("jobs/convert.zig");
const decrypt_job = @import("jobs/decrypt.zig");
const rpa_job = @import("jobs/rpa.zig");
const compat_job = @import("jobs/compat.zig");
const reanalyse_job = @import("jobs/reanalyse.zig");
const mod_queue_job = @import("jobs/mod_queue.zig");
const plan_sim_job = @import("jobs/plan_sim.zig");
const folder_scan_job = @import("jobs/folder_scan.zig");

const Activity = activity_mod.Activity;
const Book = activity_mod.Book;
const ResultKind = activity_mod.ResultKind;
const Events = events_mod.Events;

const log = std.log.scoped(.work_thread);

/// What a finished job hands back to the UI thread. Later tasks add the
/// real variants (convert, decrypt, rpa, compat, reanalyse, plan_sim,
/// folder_scan).
pub const WorkOutcome = union(enum) {
    none: void,
    mod_queue: void,
    /// Owns compat records; `handleWorkDone` frees them.
    convert: ConvertOutcome,
    /// Decrypted file count. Owns nothing.
    decrypt: struct { count: u32 },
    /// Extracted file and archive counts. Owns nothing.
    rpa: struct { files: u32, archives: u32 },
    /// Owns FixRecords; `handleWorkDone` writes and frees them.
    compat: CompatOutcome,
    /// Owns `updates`; `handleWorkDone` writes and frees them.
    reanalyse: ReanalyseOutcome,
    /// Owns the simulation and folder lists; `handleWorkDone` stores it
    /// in the recipe editor's cache (or frees it).
    plan_sim: PlanSimOutcome,
    /// Rows went to the session's mailbox as they were found. Owns nothing.
    folder_scan: void,
    /// Tests only.
    fake: struct { steps: u32 },
};

/// Tests only: reports phase "step i / n" and progress; honours cancel.
pub const FakeJob = struct {
    steps: u32,
    sleep_ms: u32,
    /// Tests only: keep running after cancel (models a job that is slow
    /// to notice it).
    ignore_cancel: bool = false,
};

/// One unit of compute work. Later tasks add the real variants.
pub const WorkJob = union(enum) {
    mod_queue: void,
    convert: ConvertJob,
    decrypt: DecryptJob,
    rpa_extract: RpaJob,
    compat_fix: CompatJob,
    reanalyse: ReanalyseJob,
    plan_sim: PlanSimJob,
    folder_scan: FolderScanJob,
    fake: FakeJob,
};

pub const ConvertJob = convert_job.ConvertJob;
pub const ConvertOutcome = convert_job.ConvertOutcome;
pub const DecryptJob = decrypt_job.DecryptJob;
pub const RpaJob = rpa_job.RpaJob;
pub const CompatJob = compat_job.CompatJob;
pub const CompatOutcome = compat_job.CompatOutcome;
pub const ReanalyseJob = reanalyse_job.ReanalyseJob;
pub const ReanalyseOutcome = reanalyse_job.ReanalyseOutcome;
pub const PlanSimJob = plan_sim_job.PlanSimJob;
pub const PlanSimOutcome = plan_sim_job.PlanSimOutcome;
pub const FolderScanJob = folder_scan_job.FolderScanJob;

/// Frees what a job owns. Called once per job: after it ran, or when it
/// is dropped without running.
fn freeJob(job: WorkJob) void {
    switch (job) {
        .convert => |c| c.deinit(),
        .decrypt => |d| d.deinit(),
        .rpa_extract => |r| r.deinit(),
        .compat_fix => |c| c.deinit(),
        .reanalyse => |r| r.deinit(),
        .plan_sim => |p| p.deinit(),
        .folder_scan => |f| f.deinit(),
        .mod_queue, .fake => {},
    }
}

pub const Deps = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    convert_svc: ?*convert.Service = null,
    compat_svc: ?*compat.Service = null,
    recipe_repo: ?*recipe.Repo = null,
    mod_jobs: ?*mod_job_queue.Queue = null,
    library_root: []const u8 = "",
    exe_dir: []const u8 = "",
    data_root: []const u8 = "",
};

const Entry = struct { job: WorkJob, activity: *Activity };

/// What `run` hands back when a job ends without an error.
const Done = struct {
    outcome: WorkOutcome,
    kind: ResultKind = .ok,
    msg: []const u8,
};

fn nowSeconds(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
}

/// Plain-language text for a job error. `error.Cancelled` and the std.Io
/// spelling `error.Canceled` are handled by
/// the caller.
fn errorText(e: anyerror) []const u8 {
    return switch (e) {
        error.InstallNotFound => "The install folder is gone",
        error.NetworkError => "No network",
        else => @errorName(e),
    };
}

/// Result for a job that ended with `e`. A cancel (either spelling) is a
/// warning; the cancel flag is set, so `finish` records `cancelled`.
fn errorResult(e: anyerror) struct { kind: ResultKind, msg: []const u8 } {
    return switch (e) {
        error.Cancelled, error.Canceled => .{ .kind = .warn, .msg = "Stopped." },
        else => .{ .kind = .err, .msg = errorText(e) },
    };
}

/// `anyerror`: each job kind has its own error set; `runOne` maps them.
fn run(deps: Deps, job: WorkJob, a: *Activity, buf: []u8) anyerror!Done {
    return switch (job) {
        .mod_queue => blk: {
            const r = try mod_queue_job.run(deps, a, buf);
            break :blk .{ .outcome = .mod_queue, .kind = r.kind, .msg = r.msg };
        },
        .convert => |c| blk: {
            const r = try convert_job.run(deps, c, a, buf);
            break :blk .{ .outcome = .{ .convert = r.outcome }, .kind = r.kind, .msg = r.msg };
        },
        .decrypt => |d| blk: {
            const r = try decrypt_job.run(deps, d, a, buf);
            break :blk .{ .outcome = .{ .decrypt = .{ .count = r.outcome.count } }, .kind = r.kind, .msg = r.msg };
        },
        .rpa_extract => |j| blk: {
            const r = try rpa_job.run(deps, j, a, buf);
            break :blk .{ .outcome = .{ .rpa = .{ .files = r.outcome.files, .archives = r.outcome.archives } }, .kind = r.kind, .msg = r.msg };
        },
        .compat_fix => |c| blk: {
            const r = try compat_job.run(deps, c, a, buf);
            break :blk .{ .outcome = .{ .compat = r.outcome }, .kind = r.kind, .msg = r.msg };
        },
        .reanalyse => |j| blk: {
            const r = try reanalyse_job.run(deps, j, a, buf);
            break :blk .{ .outcome = .{ .reanalyse = r.outcome }, .kind = r.kind, .msg = r.msg };
        },
        .plan_sim => |j| blk: {
            const r = try plan_sim_job.run(deps, j, a, buf);
            break :blk .{ .outcome = .{ .plan_sim = r.outcome }, .kind = r.kind, .msg = r.msg };
        },
        .folder_scan => |j| blk: {
            const r = try folder_scan_job.run(deps, j, a, buf);
            break :blk .{ .outcome = .folder_scan, .kind = r.kind, .msg = r.msg };
        },
        .fake => |f| runFake(deps.io, f, a, buf),
    };
}

fn runFake(io: std.Io, job: FakeJob, a: *Activity, buf: []u8) !Done {
    var i: u32 = 1;
    while (i <= job.steps) : (i += 1) {
        if (a.cancelled() and !job.ignore_cancel) return error.Cancelled;
        var pbuf: [32]u8 = undefined;
        const phase = std.fmt.bufPrint(&pbuf, "step {d} / {d}", .{ i, job.steps }) catch unreachable;
        a.setPhase(io, phase);
        a.report(i, job.steps);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(job.sleep_ms), .awake) catch {};
    }
    const msg = std.fmt.bufPrint(buf, "Finished {d} steps.", .{job.steps}) catch "Finished.";
    return .{ .outcome = .{ .fake = .{ .steps = job.steps } }, .msg = msg };
}

/// The compute thread. `Worker` must not move after `start`: the thread
/// holds a pointer to it.
///
/// Lifetime: if `stop` has to detach the thread (its job ignored cancel for
/// longer than `join_budget_ms`), that thread keeps using this `Worker`, the
/// `Book` and the `Events` until its job ends. `deinit` then leaves
/// `self.*` untouched, and the owner must keep the Worker, Book and Events
/// alive (not freed, not moved) for as long as the detached thread may run.
/// `done` turns true when it has finished.
pub const Worker = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    book: *Book,
    events: *Events,
    deps: Deps,
    mb: Mailbox(Entry),
    thread: ?std.Thread = null,
    /// Set by the thread as its last action; `stop` polls it.
    done: std.atomic.Value(bool) = .init(false),
    /// Guards `current` and `stopping`.
    lock: std.Io.Mutex = .init,
    current: ?*Activity = null,
    stopping: bool = false,
    /// The thread did not exit in time and was detached; it may still
    /// touch `mb`, so `deinit` must not free it.
    detached: bool = false,
    /// How long `stop` waits for the thread before detaching it.
    join_budget_ms: u32 = 3000,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, book: *Book, events: *Events, deps: Deps) Worker {
        return .{
            .alloc = alloc,
            .io = io,
            .book = book,
            .events = events,
            .deps = deps,
            .mb = Mailbox(Entry).init(alloc, io),
        };
    }

    /// Stops the thread (if any) and frees the queue. If the thread was
    /// detached it still uses `self`, so nothing is freed or overwritten;
    /// see the lifetime note on `Worker`.
    pub fn deinit(self: *Worker) void {
        self.stop();
        if (self.detached) return;
        self.mb.deinit();
        self.* = undefined;
    }

    /// Spawns the thread. Calling it again, or after `stop`, does nothing.
    pub fn start(self: *Worker) !void {
        if (self.thread != null) return;
        self.lock.lockUncancelable(self.io);
        const stopping = self.stopping;
        self.lock.unlock(self.io);
        if (stopping) return;
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Sets cancel on the running activity, closes the queue, finishes
    /// every queued entry as cancelled, then waits up to 3 s for the
    /// thread to exit. If it does not, the thread is detached.
    pub fn stop(self: *Worker) void {
        self.lock.lockUncancelable(self.io);
        const already = self.stopping;
        self.stopping = true;
        if (self.current) |a| a.cancel.store(true, .release);
        self.lock.unlock(self.io);
        if (already) return;

        self.mb.close();
        while (self.mb.tryPop()) |e| self.finishUnstarted(e);

        const t = self.thread orelse return;
        self.thread = null;
        var waited_ms: u32 = 0;
        const step_ms: u32 = @min(50, self.join_budget_ms);
        while (!self.done.load(.acquire) and waited_ms < self.join_budget_ms) : (waited_ms += step_ms) {
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(step_ms), .awake) catch {};
        }
        if (self.done.load(.acquire)) {
            t.join();
        } else {
            log.warn("compute thread did not stop within {d} ms; detaching it", .{self.join_budget_ms});
            self.detached = true;
            t.detach();
        }
    }

    /// Queues one job and takes ownership of it. `activity` must already
    /// be `queued` in `book`. If the worker is stopped the activity is
    /// finished as failed and the job freed; on `OutOfMemory` the job is
    /// freed and the activity is left for the caller to finish.
    pub fn submit(self: *Worker, job: WorkJob, activity: *Activity) !void {
        self.lock.lockUncancelable(self.io);
        const stopping = self.stopping;
        self.lock.unlock(self.io);
        if (stopping) {
            freeJob(job);
            return self.book.finish(activity, .err, "Not running.", nowSeconds(self.io));
        }
        self.mb.push(.{ .job = job, .activity = activity }) catch |e| {
            freeJob(job);
            switch (e) {
                error.Closed => self.book.finish(activity, .err, "Not running.", nowSeconds(self.io)),
                error.OutOfMemory => return e,
            }
        };
    }

    /// True while a job is running.
    pub fn busy(self: *const Worker) bool {
        const me: *Worker = @constCast(self);
        me.lock.lockUncancelable(me.io);
        defer me.lock.unlock(me.io);
        return me.current != null;
    }

    fn finishUnstarted(self: *Worker, e: Entry) void {
        freeJob(e.job);
        const a = e.activity;
        a.cancel.store(true, .release);
        self.book.finish(a, .warn, "Stopped before it started.", nowSeconds(self.io));
        self.events.push(.{ .work_done = .{ .activity_id = a.id, .outcome = .none } });
    }

    fn threadMain(self: *Worker) void {
        defer self.done.store(true, .release);
        job_mod.lowerWorkerPriority();
        while (self.mb.popWait()) |e| {
            self.lock.lockUncancelable(self.io);
            if (self.stopping) {
                self.lock.unlock(self.io);
                self.finishUnstarted(e);
                continue;
            }
            self.current = e.activity;
            self.lock.unlock(self.io);

            self.runOne(e);

            self.lock.lockUncancelable(self.io);
            self.current = null;
            self.lock.unlock(self.io);
        }
    }

    fn runOne(self: *Worker, e: Entry) void {
        defer freeJob(e.job);
        const a = e.activity;
        a.markRunning(nowSeconds(self.io));
        var buf: [192]u8 = undefined;
        var outcome: WorkOutcome = .none;
        if (run(self.deps, e.job, a, &buf)) |d| {
            outcome = d.outcome;
            self.book.finish(a, d.kind, d.msg, nowSeconds(self.io));
        } else |err| {
            const res = errorResult(err);
            self.book.finish(a, res.kind, res.msg, nowSeconds(self.io));
        }
        self.events.push(.{ .work_done = .{ .activity_id = a.id, .outcome = outcome } });
    }
};

test "errorText maps known errors to plain language" {
    try std.testing.expectEqualStrings("The install folder is gone", errorText(error.InstallNotFound));
    try std.testing.expectEqualStrings("No network", errorText(error.NetworkError));
    try std.testing.expectEqualStrings("AccessDenied", errorText(error.AccessDenied));
}

fn waitWorkDone(ev: *Events, id: u64) !WorkOutcome {
    // Bounded: every job in these tests finishes or is cancelled quickly.
    var n: usize = 0;
    while (n < 16) : (n += 1) {
        const e = ev.mb.popWait() orelse return error.TestUnexpectedResult;
        switch (e) {
            .work_done => |d| if (d.activity_id == id) return d.outcome,
            else => {},
        }
        events_mod.freeEvent(std.testing.allocator, e);
    }
    return error.TestUnexpectedResult;
}

fn waitPhase(a: *Activity) !void {
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        if (a.phaseLen(std.testing.io) > 0) return;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

fn phaseText(a: *Activity, buf: []u8) []const u8 {
    a.phase_lock.lockUncancelable(std.testing.io);
    defer a.phase_lock.unlock(std.testing.io);
    @memcpy(buf[0..a.phase_len], a.phase[0..a.phase_len]);
    return buf[0..a.phase_len];
}

test "Worker: fake job runs to done with phase, progress and result" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var book = Book.init(alloc, io);
    defer book.deinit();
    var ev = Events.init(alloc, io, null);
    defer ev.deinit();
    var w = Worker.init(alloc, io, &book, &ev, .{ .alloc = alloc, .io = io });
    defer w.deinit();
    try w.start();
    const a = try book.start(.hash, 1, "fake");
    try w.submit(.{ .fake = .{ .steps = 5, .sleep_ms = 1 } }, a);
    const out = try waitWorkDone(&ev, a.id);
    try std.testing.expectEqual(@as(u32, 5), out.fake.steps);
    try std.testing.expectEqual(activity_mod.Status.done, a.statusGet());
    try std.testing.expectEqualStrings("Finished 5 steps.", a.result[0..a.result_len]);
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("step 5 / 5", phaseText(a, &buf));
    const p = a.prog.get();
    try std.testing.expectEqual(@as(u64, 5), p.done);
    try std.testing.expectEqual(@as(u64, 5), p.total);
    try std.testing.expect(a.started_at.load(.acquire) > 0);
}

test "Worker: requestCancel stops a running fake job; status cancelled" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var book = Book.init(alloc, io);
    defer book.deinit();
    var ev = Events.init(alloc, io, null);
    defer ev.deinit();
    var w = Worker.init(alloc, io, &book, &ev, .{ .alloc = alloc, .io = io });
    defer w.deinit();
    try w.start();
    const a = try book.start(.hash, 1, "long");
    try w.submit(.{ .fake = .{ .steps = 100, .sleep_ms = 20 } }, a);
    try waitPhase(a);
    try std.testing.expect(w.busy());
    book.requestCancel(a.id);
    _ = try waitWorkDone(&ev, a.id);
    try std.testing.expectEqual(activity_mod.Status.cancelled, a.statusGet());
    try std.testing.expectEqualStrings("Stopped.", a.result[0..a.result_len]);
}

test "Worker: stop cancels the running job and the queued one never starts; returns within 3 s" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var book = Book.init(alloc, io);
    defer book.deinit();
    var ev = Events.init(alloc, io, null);
    defer ev.deinit();
    var w = Worker.init(alloc, io, &book, &ev, .{ .alloc = alloc, .io = io });
    defer w.deinit();
    try w.start();
    const run_a = try book.start(.hash, 1, "running");
    const queued = try book.start(.hash, 1, "queued");
    try w.submit(.{ .fake = .{ .steps = 100, .sleep_ms = 20 } }, run_a);
    try w.submit(.{ .fake = .{ .steps = 5, .sleep_ms = 1 } }, queued);
    try waitPhase(run_a);
    const t0 = std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds();
    w.stop();
    const t1 = std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds();
    try std.testing.expect(t1 - t0 < 3000);
    try std.testing.expectEqual(activity_mod.Status.cancelled, run_a.statusGet());
    try std.testing.expectEqual(activity_mod.Status.cancelled, queued.statusGet());
    try std.testing.expectEqualStrings("Stopped before it started.", queued.result[0..queued.result_len]);
    try std.testing.expectEqual(@as(i64, 0), queued.started_at.load(.acquire));
    // Submitting after stop fails the activity instead of hanging it.
    const late = try book.start(.hash, 1, "late");
    try w.submit(.{ .fake = .{ .steps = 1, .sleep_ms = 1 } }, late);
    try std.testing.expectEqual(activity_mod.Status.failed, late.statusGet());
    try std.testing.expectEqualStrings("Not running.", late.result[0..late.result_len]);
    // Drop leftover events (all work_done; nothing owned).
    var left: std.ArrayList(events_mod.UiEvent) = .empty;
    defer left.deinit(alloc);
    ev.drain(alloc, &left);
    for (left.items) |e| events_mod.freeEvent(alloc, e);
}

test "Worker: stop detaches a job that ignores cancel; deinit leaves the state intact for it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var book = Book.init(alloc, io);
    defer book.deinit();
    var ev = Events.init(alloc, io, null);
    defer ev.deinit();
    var w = Worker.init(alloc, io, &book, &ev, .{ .alloc = alloc, .io = io });
    w.join_budget_ms = 100;
    try w.start();
    const a = try book.start(.hash, 1, "stubborn");
    // About 300 ms in total: longer than the 100 ms join budget.
    try w.submit(.{ .fake = .{ .steps = 6, .sleep_ms = 50, .ignore_cancel = true } }, a);
    try waitPhase(a);
    w.stop();
    try std.testing.expect(w.detached);
    w.deinit();
    // The detached thread must still find the Worker fields intact.
    var i: usize = 0;
    while (!w.done.load(.acquire) and i < 2000) : (i += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(w.done.load(.acquire));
    // `done` is the thread's last store; give it a moment to return.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    try std.testing.expectEqual(activity_mod.Status.cancelled, a.statusGet());
    try std.testing.expectEqualStrings("Finished 6 steps.", a.result[0..a.result_len]);
    // The thread is gone now, so the queue the detached path kept can be freed.
    w.mb.deinit();
    var left: std.ArrayList(events_mod.UiEvent) = .empty;
    defer left.deinit(alloc);
    ev.drain(alloc, &left);
    for (left.items) |e| events_mod.freeEvent(alloc, e);
}

test "errorResult: both cancel spellings are a warning \"Stopped.\"; others are errors" {
    for ([_]anyerror{ error.Cancelled, error.Canceled }) |e| {
        const res = errorResult(e);
        try std.testing.expectEqual(ResultKind.warn, res.kind);
        try std.testing.expectEqualStrings("Stopped.", res.msg);
    }
    const res = errorResult(error.NetworkError);
    try std.testing.expectEqual(ResultKind.err, res.kind);
    try std.testing.expectEqualStrings("No network", res.msg);
}
