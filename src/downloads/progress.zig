//! Progress reporting for the long post-transfer steps (verify, extract,
//! install, mod apply). The worker calls `Sink.report(done, total)` as it
//! goes; the owner decides where the numbers land. `Atomic` is the
//! worker ↔ UI shape: two atomics the owner polls each tick.

const std = @import("std");

pub const Fn = *const fn (ctx: ?*anyopaque, done: u64, total: u64) void;

pub const Sink = struct {
    ctx: ?*anyopaque = null,
    cb: ?Fn = null,

    pub const none: Sink = .{};

    pub fn report(self: Sink, done: u64, total: u64) void {
        if (self.cb) |f| f(self.ctx, done, total);
    }
};

/// Two atomics the worker writes and the owner reads without a lock.
pub const Atomic = struct {
    done: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),

    pub fn sink(self: *Atomic) Sink {
        return .{ .ctx = self, .cb = store };
    }

    fn store(ctx: ?*anyopaque, done: u64, total: u64) void {
        const self: *Atomic = @ptrCast(@alignCast(ctx.?));
        self.total.store(total, .monotonic);
        self.done.store(done, .release);
    }

    pub fn reset(self: *Atomic) void {
        self.total.store(0, .monotonic);
        self.done.store(0, .release);
    }

    pub const Pair = struct { done: u64, total: u64 };

    pub fn get(self: *const Atomic) Pair {
        return .{ .done = self.done.load(.acquire), .total = self.total.load(.monotonic) };
    }
};

/// Whole percent 0..100 of `done / total`; 0 when `total` is 0.
pub fn percent(done: u64, total: u64) u8 {
    if (total == 0) return 0;
    return @intCast(@min(@divTrunc(done * 100, total), 100));
}

test "Sink.none reports nowhere; Atomic stores the last pair; percent clamps" {
    Sink.none.report(1, 2);
    var a: Atomic = .{};
    try std.testing.expectEqual(Atomic.Pair{ .done = 0, .total = 0 }, a.get());
    const s = a.sink();
    s.report(3, 10);
    s.report(7, 10);
    try std.testing.expectEqual(Atomic.Pair{ .done = 7, .total = 10 }, a.get());
    a.reset();
    try std.testing.expectEqual(Atomic.Pair{ .done = 0, .total = 0 }, a.get());
    try std.testing.expectEqual(@as(u8, 0), percent(5, 0));
    try std.testing.expectEqual(@as(u8, 70), percent(7, 10));
    try std.testing.expectEqual(@as(u8, 100), percent(12, 10));
}
