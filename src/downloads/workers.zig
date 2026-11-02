//! Worker plumbing for the downloader thread: one background thread per
//! long call (verify, extract, later resolve), reporting back through an
//! atomic phase plus a result the loop reads once.
//!
//! The thread handle is kept and joined when the result is taken (the
//! thread has already finished by then, so the join is instant) or on
//! shutdown. This lets the owner free the worker safely; a detached thread
//! could still be writing `result` when the owner frees it.
const std = @import("std");

pub const Phase = enum(u8) { pending, done, consumed };

pub fn Worker(comptime Result: type) type {
    return struct {
        const Self = @This();

        phase: std.atomic.Value(u8) = .init(@backingInt(Phase.pending)),
        result: Result = undefined,
        thr: ?std.Thread = null,

        /// Run `func(args...)` on a new thread; its return value becomes
        /// `result`. `args` is copied into the thread, so anything it
        /// points to must outlive the worker.
        pub fn spawn(self: *Self, comptime func: anytype, args: anytype) std.Thread.SpawnError!void {
            const Args = @TypeOf(args);
            const Run = struct {
                fn run(s: *Self, a: Args) void {
                    s.result = @call(.auto, func, a);
                    s.phase.store(@backingInt(Phase.done), .release);
                }
            };
            self.phase.store(@backingInt(Phase.pending), .monotonic);
            self.thr = try std.Thread.spawn(.{}, Run.run, .{ self, args });
        }

        /// The result once, after the worker finished; null while pending
        /// and after the result was taken.
        pub fn take(self: *Self) ?Result {
            if (self.phase.load(.acquire) != @backingInt(Phase.done)) return null;
            self.join();
            self.phase.store(@backingInt(Phase.consumed), .monotonic);
            return self.result;
        }

        /// Block until the thread exits. Safe to call more than once.
        pub fn join(self: *Self) void {
            if (self.thr) |t| t.join();
            self.thr = null;
        }
    };
}

fn addForTest(a: u32, b: u32) u32 {
    return a + b;
}

test "workers: result is taken exactly once" {
    var w: Worker(u32) = .{};
    try w.spawn(addForTest, .{ 2, 3 });
    var got: ?u32 = null;
    while (got == null) {
        got = w.take();
        if (got == null) std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u32, 5), got.?);
    try std.testing.expectEqual(@as(?u32, null), w.take());
    w.join();
}
