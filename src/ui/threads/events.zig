//! Worker-to-UI event mailbox. Workers `push`; the UI thread `drain`s once
//! per frame. Pushing also wakes the window so the frame actually runs.

const std = @import("std");
const dvui = @import("dvui");
const Mailbox = @import("mailbox.zig").Mailbox;
const job_mod = @import("../job.zig");

const log = std.log.scoped(.ui_events);

const work_thread = @import("work_thread.zig");
pub const WorkOutcome = work_thread.WorkOutcome;

pub const ToastKind = enum { ok, warn, err, info };

pub const UiEvent = union(enum) {
    /// `msg` is owned by the sender's allocator; `freeEvent` frees it.
    toast: struct { kind: ToastKind, msg: []const u8 },
    work_done: struct { activity_id: u64, outcome: WorkOutcome },
    /// Task 14 replaces this with the real reply type.
    io: void,
    wake: void,
};

/// Frees strings owned by the event.
pub fn freeEvent(alloc: std.mem.Allocator, ev: UiEvent) void {
    switch (ev) {
        .toast => |t| alloc.free(t.msg),
        else => {},
    }
}

pub const Events = struct {
    mb: Mailbox(UiEvent),
    win: ?*dvui.Window,
    /// Allocator that owns toast messages; used to free dropped events.
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, win: ?*dvui.Window) Events {
        return .{ .mb = Mailbox(UiEvent).init(alloc, io), .win = win, .alloc = alloc };
    }

    pub fn deinit(self: *Events) void {
        self.mb.deinit();
    }

    /// Queues `ev` and wakes the window. If the mailbox is closed or out of
    /// memory the event is dropped and its owned strings are freed.
    pub fn push(self: *Events, ev: UiEvent) void {
        self.mb.push(ev) catch |err| {
            log.warn("dropping UI event: {s}", .{@errorName(err)});
            freeEvent(self.alloc, ev);
            return;
        };
        if (self.win) |w| job_mod.refreshDebounced(w, @src());
    }

    /// Moves every queued event onto `out`, in order.
    pub fn drain(self: *Events, alloc: std.mem.Allocator, out: *std.ArrayList(UiEvent)) void {
        self.mb.drainInto(alloc, out) catch |err| {
            log.warn("drain failed: {s}", .{@errorName(err)});
        };
    }
};

test "push two toasts then drain in order" {
    const alloc = std.testing.allocator;
    var ev = Events.init(alloc, std.testing.io, null);
    defer ev.deinit();
    ev.push(.{ .toast = .{ .kind = .ok, .msg = try alloc.dupe(u8, "one") } });
    ev.push(.{ .toast = .{ .kind = .err, .msg = try alloc.dupe(u8, "two") } });
    var out: std.ArrayList(UiEvent) = .empty;
    defer out.deinit(alloc);
    ev.drain(alloc, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("one", out.items[0].toast.msg);
    try std.testing.expectEqualStrings("two", out.items[1].toast.msg);
    for (out.items) |e| freeEvent(alloc, e);
}

test "push after close drops and frees" {
    const alloc = std.testing.allocator;
    var ev = Events.init(alloc, std.testing.io, null);
    defer ev.deinit();
    ev.mb.close();
    ev.push(.{ .toast = .{ .kind = .info, .msg = try alloc.dupe(u8, "late") } });
    var out: std.ArrayList(UiEvent) = .empty;
    defer out.deinit(alloc);
    ev.drain(alloc, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
