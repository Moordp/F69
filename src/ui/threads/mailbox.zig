//! Generic multi-producer, single-consumer mailbox used by worker threads.
//! Producers `push`; the consumer blocks in `popWait`, polls with `tryPop`,
//! or takes everything at once with `drainInto`. `close` wakes all waiters.

const std = @import("std");

pub fn Mailbox(comptime T: type) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        /// Live items are `items.items[head..]`.
        items: std.ArrayList(T) = .empty,
        head: usize = 0,
        closed: bool = false,

        pub fn init(alloc: std.mem.Allocator, io: std.Io) Self {
            return .{ .alloc = alloc, .io = io };
        }

        /// Frees the queue storage. Items still queued are dropped.
        pub fn deinit(self: *Self) void {
            self.items.deinit(self.alloc);
            self.* = undefined;
        }

        pub fn push(self: *Self, item: T) error{ OutOfMemory, Closed }!void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed) return error.Closed;
            // Reclaim consumed space before growing.
            if (self.head > 0 and self.head == self.items.items.len) {
                self.items.clearRetainingCapacity();
                self.head = 0;
            }
            try self.items.append(self.alloc, item);
            self.cond.broadcast(self.io);
        }

        /// Blocks until an item arrives or the mailbox is closed.
        /// Returns null only after `close` with no items left.
        pub fn popWait(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (self.head == self.items.items.len and !self.closed) {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
            return self.popLocked();
        }

        pub fn tryPop(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.popLocked();
        }

        /// Moves every queued item onto the end of `out`, in order.
        pub fn drainInto(self: *Self, alloc: std.mem.Allocator, out: *std.ArrayList(T)) error{OutOfMemory}!void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try out.appendSlice(alloc, self.items.items[self.head..]);
            self.items.clearRetainingCapacity();
            self.head = 0;
        }

        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closed = true;
            self.cond.broadcast(self.io);
        }

        pub fn len(self: *Self) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.items.items.len - self.head;
        }

        fn popLocked(self: *Self) ?T {
            if (self.head == self.items.items.len) return null;
            const item = self.items.items[self.head];
            self.head += 1;
            if (self.head == self.items.items.len) {
                self.items.clearRetainingCapacity();
                self.head = 0;
            }
            return item;
        }
    };
}

test "Mailbox: FIFO order, tryPop on empty is null, len" {
    var m = Mailbox(u32).init(std.testing.allocator, std.testing.io);
    defer m.deinit();
    try std.testing.expect(m.tryPop() == null);
    try m.push(1);
    try m.push(2);
    try m.push(3);
    try std.testing.expectEqual(@as(usize, 3), m.len());
    try std.testing.expectEqual(@as(?u32, 1), m.tryPop());
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(std.testing.allocator);
    try m.drainInto(std.testing.allocator, &out);
    try std.testing.expectEqualSlices(u32, &.{ 2, 3 }, out.items);
    try std.testing.expectEqual(@as(usize, 0), m.len());
}

test "Mailbox: popWait blocks until push; close wakes it with null; push after close is Closed" {
    var m = Mailbox(u32).init(std.testing.allocator, std.testing.io);
    defer m.deinit();
    const Consumer = struct {
        fn run(mb: *Mailbox(u32), got: *?u32) void {
            got.* = mb.popWait();
        }
    };
    var got: ?u32 = null;
    const t = try std.Thread.spawn(.{}, Consumer.run, .{ &m, &got });
    try m.push(7);
    t.join();
    try std.testing.expectEqual(@as(?u32, 7), got);
    var got2: ?u32 = 99;
    const t2 = try std.Thread.spawn(.{}, Consumer.run, .{ &m, &got2 });
    m.close();
    t2.join();
    try std.testing.expect(got2 == null);
    try std.testing.expectError(error.Closed, m.push(8));
}
