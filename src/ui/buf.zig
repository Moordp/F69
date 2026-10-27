// Fixed-capacity sentinel-trimmed string buffer.
//
// f69's `State` is a stack-allocated god-object whose UI helpers
// historically used the same pattern over and over: a `_buf: [N]u8`
// field paired with a `_len: usize` field, plus a hand-written
// `setMsg(s) / getMsg() → []const u8` pair. Different `_buf` sizes per
// concern (sync message: 128, import message: 128, login message: 128,
// browser message: 80, …) but the shape was always the same.
//
// `MessageBuf(N)` collapses that pattern into one type. Pure data —
// callers `.write(s)` to set, `.read()` to consume, `.clear()` to
// reset, `.isEmpty()` to test.
//
// Why not `std.BoundedArray(u8, N)`? It has the right shape but the
// API is verbose for the truncating-write pattern we want (`.write`
// silently truncates oversize input rather than erroring — UI messages
// are advisory; never crash because a translation grew).

const std = @import("std");

pub fn MessageBuf(comptime cap: usize) type {
    return struct {
        bytes: [cap]u8 = @splat(0),
        len: usize = 0,

        const Self = @This();
        pub const capacity: usize = cap;

        pub fn read(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn write(self: *Self, s: []const u8) void {
            const n = @min(s.len, cap);
            @memcpy(self.bytes[0..n], s[0..n]);
            self.len = n;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }
    };
}

const testing = std.testing;

test "MessageBuf: write + read + clear" {
    var mb: MessageBuf(16) = .{};
    try testing.expect(mb.isEmpty());
    mb.write("hello");
    try testing.expectEqualStrings("hello", mb.read());
    try testing.expect(!mb.isEmpty());
    mb.clear();
    try testing.expect(mb.isEmpty());
    try testing.expectEqualStrings("", mb.read());
}

test "MessageBuf: truncates oversized input" {
    var mb: MessageBuf(4) = .{};
    mb.write("abcdefgh");
    try testing.expectEqualStrings("abcd", mb.read());
}
