//! UI-thread side of the threading model: drains the worker-to-UI event
//! mailbox once per frame. `guiFrame` calls `drainThreads` before every
//! other drain so results from the compute and I/O threads land first.

const std = @import("std");
const types = @import("../types.zig");
const state_mod = @import("../state.zig");

const threads = types.threads;
const Frame = types.Frame;

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
            .io => {},
            .wake => {},
        }
        // Toast messages are owned by the Events allocator.
        threads.events.freeEvent(frame.events.alloc, ev);
    }
}

/// Applies a finished compute job's outcome on the UI thread. The
/// current outcomes own no memory; later tasks add arms that do.
fn handleWorkDone(frame: *Frame, activity_id: u64, outcome: threads.work_thread.WorkOutcome) void {
    _ = frame;
    _ = activity_id;
    switch (outcome) {
        .none, .mod_queue, .fake => {},
    }
}

test "kindMap covers every toast kind" {
    try std.testing.expectEqual(state_mod.ToastKind.success, kindMap(.ok));
    try std.testing.expectEqual(state_mod.ToastKind.warn, kindMap(.warn));
    try std.testing.expectEqual(state_mod.ToastKind.err, kindMap(.err));
    try std.testing.expectEqual(state_mod.ToastKind.info, kindMap(.info));
}
