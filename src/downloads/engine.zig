//! Downloader v2 engine interface plus a scripted fake for tests.
const std = @import("std");
const testing = std.testing;
const errs = @import("errors.zig");
const model = @import("model.zig");
const policy = @import("policy.zig");

/// Everything an engine needs to begin one transfer.
pub const StartSpec = struct {
    job_id: u64,
    url: []const u8,
    /// `Name: value` request headers.
    headers: []const []const u8,
    dest_dir: []const u8,
    out_name: ?[]const u8,
    /// When set, the transfer is this .torrent body instead of `url`.
    torrent_bytes: ?[]const u8,
};

/// Type-erased download engine. Engines are called only from the downloader
/// thread and do no internal locking. `Progress.msg` returned by `poll`
/// borrows from the engine and is valid only until the next `poll` of any
/// ref; callers must copy it before polling again.
/// `ref` is the engine's own handle for a
/// transfer (a gid for aria2), returned by `start`.
pub const Engine = struct {
    ptr: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        /// Returns the engine ref, owned by the engine's allocator.
        start: *const fn (*anyopaque, StartSpec) errs.Error![]u8,
        poll: *const fn (*anyopaque, ref: []const u8) errs.Error!model.Progress,
        pause: *const fn (*anyopaque, ref: []const u8) errs.Error!void,
        unpause: *const fn (*anyopaque, ref: []const u8) errs.Error!void,
        /// Remove the transfer and forget the ref.
        cancel: *const fn (*anyopaque, ref: []const u8) errs.Error!void,
        finalPath: *const fn (*anyopaque, std.mem.Allocator, ref: []const u8) errs.Error!?[]u8,
        setLimits: *const fn (*anyopaque, policy.Plan) errs.Error!void,
    };

    pub fn start(self: Engine, spec: StartSpec) errs.Error![]u8 {
        return self.vt.start(self.ptr, spec);
    }
    pub fn poll(self: Engine, ref: []const u8) errs.Error!model.Progress {
        return self.vt.poll(self.ptr, ref);
    }
    pub fn pause(self: Engine, ref: []const u8) errs.Error!void {
        return self.vt.pause(self.ptr, ref);
    }
    pub fn unpause(self: Engine, ref: []const u8) errs.Error!void {
        return self.vt.unpause(self.ptr, ref);
    }
    pub fn cancel(self: Engine, ref: []const u8) errs.Error!void {
        return self.vt.cancel(self.ptr, ref);
    }
    pub fn finalPath(self: Engine, alloc: std.mem.Allocator, ref: []const u8) errs.Error!?[]u8 {
        return self.vt.finalPath(self.ptr, alloc, ref);
    }
    pub fn setLimits(self: Engine, plan: policy.Plan) errs.Error!void {
        return self.vt.setLimits(self.ptr, plan);
    }
};

/// Scripted engine for tests. `poll` returns `script[min(idx, len-1)]`
/// and advances `idx`. Not test-gated: other files' tests import it.
pub const FakeEngine = struct {
    /// Allocates the refs `start` returns; the caller frees them with it.
    alloc: std.mem.Allocator,
    script: []const model.Progress,
    idx: usize = 0,
    started: usize = 0,
    paused: bool = false,
    cancelled: bool = false,
    last_plan: ?policy.Plan = null,

    pub fn engine(self: *FakeEngine) Engine {
        return .{ .ptr = self, .vt = &vtable };
    }

    const vtable: Engine.VTable = .{
        .start = startImpl,
        .poll = pollImpl,
        .pause = pauseImpl,
        .unpause = unpauseImpl,
        .cancel = cancelImpl,
        .finalPath = finalPathImpl,
        .setLimits = setLimitsImpl,
    };

    fn cast(p: *anyopaque) *FakeEngine {
        return @ptrCast(@alignCast(p));
    }
    fn startImpl(p: *anyopaque, _: StartSpec) errs.Error![]u8 {
        const self = cast(p);
        self.started += 1;
        return std.fmt.allocPrint(self.alloc, "fake-{d}", .{self.started}) catch errs.Error.OutOfMemory;
    }
    fn pollImpl(p: *anyopaque, _: []const u8) errs.Error!model.Progress {
        const self = cast(p);
        if (self.script.len == 0) return .{ .phase = .queued };
        const r = self.script[@min(self.idx, self.script.len - 1)];
        self.idx += 1;
        return r;
    }
    fn pauseImpl(p: *anyopaque, _: []const u8) errs.Error!void {
        cast(p).paused = true;
    }
    fn unpauseImpl(p: *anyopaque, _: []const u8) errs.Error!void {
        cast(p).paused = false;
    }
    fn cancelImpl(p: *anyopaque, _: []const u8) errs.Error!void {
        cast(p).cancelled = true;
    }
    fn finalPathImpl(_: *anyopaque, _: std.mem.Allocator, _: []const u8) errs.Error!?[]u8 {
        return null;
    }
    fn setLimitsImpl(p: *anyopaque, plan: policy.Plan) errs.Error!void {
        cast(p).last_plan = plan;
    }
};

test "FakeEngine walks its script and records pause/cancel/setLimits" {
    const script = [_]model.Progress{
        .{ .phase = .queued },
        .{ .phase = .downloading, .bytes_done = 5 },
    };
    var fake: FakeEngine = .{ .alloc = testing.allocator, .script = &script };
    const e = fake.engine();
    const ref = try e.start(.{ .job_id = 1, .url = "u", .headers = &.{}, .dest_dir = "d", .out_name = null, .torrent_bytes = null });
    defer testing.allocator.free(ref);
    try testing.expectEqualStrings("fake-1", ref);
    try testing.expectEqual(model.Phase.queued, (try e.poll(ref)).phase);
    try testing.expectEqual(model.Phase.downloading, (try e.poll(ref)).phase);
    try testing.expectEqual(model.Phase.downloading, (try e.poll(ref)).phase);
    try e.pause(ref);
    try testing.expect(fake.paused);
    try e.unpause(ref);
    try testing.expect(!fake.paused);
    const plan: policy.Plan = .{ .aria2_global_down = 1, .aria2_global_up = 2, .per_torrent_down = 3, .per_file_down = 4, .mega_down = 5 };
    try e.setLimits(plan);
    try testing.expectEqual(plan, fake.last_plan.?);
    try testing.expectEqual(@as(?[]u8, null), try e.finalPath(testing.allocator, ref));
    try e.cancel(ref);
    try testing.expect(fake.cancelled);
}
