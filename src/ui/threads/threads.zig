//! One import for screens and actions: the UI / I/O / compute thread
//! pieces (mailbox, activity book, UI event mailbox, compute thread).

pub const mailbox = @import("mailbox.zig");
pub const activity = @import("activity.zig");
pub const events = @import("events.zig");
pub const work_thread = @import("work_thread.zig");

pub const Book = activity.Book;
pub const Activity = activity.Activity;
pub const Events = events.Events;
pub const UiEvent = events.UiEvent;
pub const Worker = work_thread.Worker;
pub const WorkJob = work_thread.WorkJob;

test {
    _ = mailbox;
    _ = activity;
    _ = events;
    _ = work_thread;
    _ = @import("jobs/convert.zig");
}
