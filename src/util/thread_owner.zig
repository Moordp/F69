//! Thread ownership marker. A structure that only one thread may touch
//! (for example UI state) claims an `Owner`; `assert` then catches calls
//! from other threads. In ReleaseFast/ReleaseSmall `assert` compiles to nothing.

const std = @import("std");
const builtin = @import("builtin");

pub fn currentThreadId() u64 {
    return @intCast(std.Thread.getCurrentId());
}

pub const Owner = struct {
    /// 0 means unowned: any thread may call.
    id: std.atomic.Value(u64) = .init(0),

    pub fn claim(self: *Owner) void {
        self.id.store(currentThreadId(), .release);
    }

    pub fn release(self: *Owner) void {
        self.id.store(0, .release);
    }

    /// True when unowned or when the current thread is the owner.
    pub fn isOwner(self: *const Owner) bool {
        const owner = self.id.load(.acquire);
        return owner == 0 or owner == currentThreadId();
    }

    pub fn assert(self: *const Owner, comptime what: []const u8) void {
        if (builtin.mode == .debug or builtin.mode == .safe) {
            if (!self.isOwner()) @panic(what ++ " called from the wrong thread");
        }
    }
};

test "claim makes this thread the owner and others not" {
    var o: Owner = .{};
    o.claim();
    try std.testing.expect(o.isOwner());
    o.assert("test");
    const T = struct {
        fn run(owner: *const Owner, out: *bool) void {
            out.* = owner.isOwner();
        }
    };
    var other: bool = true;
    const t = try std.Thread.spawn(.{}, T.run, .{ &o, &other });
    t.join();
    try std.testing.expect(!other);
}

test "release makes every thread an owner" {
    var o: Owner = .{};
    o.claim();
    o.release();
    try std.testing.expect(o.isOwner());
    const T = struct {
        fn run(owner: *const Owner, out: *bool) void {
            out.* = owner.isOwner();
        }
    };
    var other: bool = false;
    const t = try std.Thread.spawn(.{}, T.run, .{ &o, &other });
    t.join();
    try std.testing.expect(other);
}
