// Per-host request spacing. The F95 client already self-throttles, but other
// hosts (e.g. dl.rpdl.net) need their own floor so heavy fetches don't trip
// rate limits. Pure + clock-injected (caller passes `now`), so it's testable.
// PLAN §2.6.

const std = @import("std");

pub const PerHostLimiter = struct {
    const Slot = struct { hash: u64, next_ns: i128 = 0, used: bool = false };
    slots: [32]Slot = @splat(.{ .hash = 0 }),

    fn slotFor(self: *PerHostLimiter, host: []const u8) *Slot {
        const h = std.hash.Wyhash.hash(0, host);
        var free: ?*Slot = null;
        for (&self.slots) |*s| {
            if (s.used and s.hash == h) return s;
            if (!s.used and free == null) free = s;
        }
        const s = free orelse &self.slots[0]; // table full → evict slot 0
        s.* = .{ .hash = h, .next_ns = 0, .used = true };
        return s;
    }

    /// Reserve the next request slot for `host`. Returns how long (ns) the
    /// caller must wait before issuing; 0 means go now. Advances the host's
    /// next-allowed time by `interval_ns`.
    pub fn reserve(self: *PerHostLimiter, host: []const u8, now_ns: i128, interval_ns: i128) i128 {
        const s = self.slotFor(host);
        if (now_ns >= s.next_ns) {
            s.next_ns = now_ns + interval_ns;
            return 0;
        }
        const wait = s.next_ns - now_ns;
        s.next_ns += interval_ns;
        return wait;
    }
};

test "limiter spaces requests per host by the interval" {
    var lim = PerHostLimiter{};
    try std.testing.expectEqual(@as(i128, 0), lim.reserve("a.com", 0, 1000));
    try std.testing.expectEqual(@as(i128, 1000), lim.reserve("a.com", 0, 1000)); // back-to-back waits
    try std.testing.expectEqual(@as(i128, 0), lim.reserve("b.com", 0, 1000)); // other host independent
    try std.testing.expectEqual(@as(i128, 0), lim.reserve("a.com", 2000, 1000)); // enough time elapsed
}

test "limiter queues a burst into evenly spaced slots" {
    var lim = PerHostLimiter{};
    try std.testing.expectEqual(@as(i128, 0), lim.reserve("h", 0, 500));
    try std.testing.expectEqual(@as(i128, 500), lim.reserve("h", 0, 500));
    try std.testing.expectEqual(@as(i128, 1000), lim.reserve("h", 0, 500));
}
