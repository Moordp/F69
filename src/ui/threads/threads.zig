//! One import for screens and actions: the UI / I/O / compute thread
//! pieces (mailbox, activity book, UI event mailbox, compute thread,
//! I/O thread).

pub const mailbox = @import("mailbox.zig");
pub const activity = @import("activity.zig");
pub const events = @import("events.zig");
pub const work_thread = @import("work_thread.zig");
pub const io_thread = @import("io_thread.zig");

pub const Book = activity.Book;
pub const Activity = activity.Activity;
pub const Events = events.Events;
pub const UiEvent = events.UiEvent;
pub const Worker = work_thread.Worker;
pub const WorkJob = work_thread.WorkJob;
pub const IoThread = io_thread.IoThread;
pub const IoRequest = io_thread.IoRequest;
pub const IoReply = io_thread.IoReply;
pub const ModQueueHook = @import("jobs/mod_queue.zig").Hook;

test {
    _ = mailbox;
    _ = activity;
    _ = events;
    _ = work_thread;
    _ = io_thread;
    _ = @import("jobs/convert.zig");
    _ = @import("jobs/decrypt.zig");
    _ = @import("jobs/rpa.zig");
    _ = @import("jobs/compat.zig");
    _ = @import("jobs/reanalyse.zig");
    _ = @import("jobs/mod_queue.zig");
}
