//! The browser ("manual") engine. The user downloads the file in their own
//! browser; f69 never moves bytes itself. All behaviour lives in the
//! downloader's `awaiting_user` handling (open the page, paste a link,
//! pick a file, watched-folder matches), so this engine only hands out a
//! ref and reports nothing. Spec §3.5 "browser".
const std = @import("std");
const errs = @import("errors.zig");
const model = @import("model.zig");
const policy = @import("policy.zig");
const engine_mod = @import("engine.zig");

const Engine = engine_mod.Engine;

pub const BrowserEngine = struct {
    /// Allocates the refs `start` returns (the downloader frees them with
    /// the same allocator).
    alloc: std.mem.Allocator,
    io: std.Io,

    pub fn engine(self: *BrowserEngine) Engine {
        return .{ .ptr = self, .vt = &vtable };
    }

    const vtable: Engine.VTable = .{
        .start = startImpl,
        .poll = pollImpl,
        .pause = noop,
        .unpause = noop,
        .cancel = noop,
        .finalPath = finalPathImpl,
        .setLimits = setLimitsImpl,
        .isAlive = isAliveImpl,
    };

    fn cast(p: *anyopaque) *BrowserEngine {
        return @ptrCast(@alignCast(p));
    }

    /// `"browser:<job_id>"`. The page itself is opened by the downloader
    /// (`UiEvent.open_url`), not here.
    fn startImpl(p: *anyopaque, spec: engine_mod.StartSpec) errs.Error![]u8 {
        const self = cast(p);
        return std.fmt.allocPrint(self.alloc, "browser:{d}", .{spec.job_id}) catch errs.Error.OutOfMemory;
    }

    /// The browser never reports transfer progress.
    fn pollImpl(_: *anyopaque, _: []const u8) errs.Error!model.Progress {
        return .{ .phase = .queued };
    }

    fn noop(_: *anyopaque, _: []const u8) errs.Error!void {}

    fn finalPathImpl(_: *anyopaque, _: std.mem.Allocator, _: []const u8) errs.Error!?[]u8 {
        return null;
    }

    fn setLimitsImpl(_: *anyopaque, _: policy.Plan) errs.Error!void {}

    fn isAliveImpl(_: *anyopaque) bool {
        return true;
    }
};

test "BrowserEngine: start returns browser:<id>; poll is queued; the rest are no-ops" {
    const testing = std.testing;
    var be: BrowserEngine = .{ .alloc = testing.allocator, .io = undefined };
    const e = be.engine();
    const ref = try e.start(.{ .job_id = 42, .url = "https://x.invalid/a", .headers = &.{}, .dest_dir = "d", .out_name = null, .torrent_bytes = null });
    defer testing.allocator.free(ref);
    try testing.expectEqualStrings("browser:42", ref);
    try testing.expectEqual(model.Phase.queued, (try e.poll(ref)).phase);
    try e.pause(ref);
    try e.unpause(ref);
    try e.cancel(ref);
    try testing.expectEqual(@as(?[]u8, null), try e.finalPath(testing.allocator, ref));
    try e.setLimits(.{ .aria2_global_down = 0, .aria2_global_up = 0, .per_torrent_down = 0, .per_file_down = 0, .mega_down = 0 });
    try testing.expect(e.isAlive());
}
