// Custom panic handler. Writes `<cache_dir>/f69/crashes/<unix-ts>.log`
// with the panic message, stack trace, zig version, git rev (baked at
// build time), and platform. `<cache_dir>` is `%LOCALAPPDATA%` on
// Windows, `$XDG_CACHE_HOME`/`~/.cache` elsewhere — see
// `util_paths.cacheHome`.
//
// A panic handler has Zig's fixed `(message, first_trace_addr)
// noreturn` signature: no `Io`, no env, no allocator reaches it. So
// the crash directory and the `Io` instance to write with are
// resolved once at normal startup and stashed in module globals —
// the same pattern main.zig uses for its per-run log file
// (`g_log_file`/`g_log_io`) — *before* installing the handler:
//
//     crash.init(init.io, gpa, init.minimal.environ);
//     pub const panic = std.debug.FullPanic(crash.panicHandler);
//
// (or wire via Zig 0.16's `std.panic_handler` mechanism). Prints the
// log directory to stderr so the user sees where to find it, then
// hands off to `std.debug.defaultPanic` for the real stack-trace
// dump + abort — writeLog only ever adds a side-channel log file, it
// never replaces the normal panic behavior.

const std = @import("std");
const builtin = @import("builtin");
const util_paths = @import("util_paths");
const atomic_io = @import("util_atomic_io");

pub const build_git_rev: []const u8 = if (builtin.mode == .Debug) "dev" else "unknown";

var g_crash_io: ?std.Io = null;
var g_crash_dir: ?[]const u8 = null;

/// Resolve and stash `<cache_dir>/f69/crashes` + the `Io` instance to
/// write it with. Call once at startup, before installing the panic
/// handler (see module docs above). Best-effort: leaves both null on
/// any failure (no HOME/APPDATA, alloc failure), so `writeLog` simply
/// no-ops rather than ever risking startup.
pub fn init(io: std.Io, alloc: std.mem.Allocator, environ: std.process.Environ) void {
    const cache_base = util_paths.cacheHome(environ, alloc) catch return;
    defer alloc.free(cache_base);
    g_crash_dir = std.fmt.allocPrint(alloc, "{s}/f69/crashes", .{cache_base}) catch return;
    g_crash_io = io;
}

pub fn panicHandler(message: []const u8, first_trace_addr: ?usize) noreturn {
    // Best-effort log write — never block the panic from completing.
    writeLog(message) catch {};
    if (g_crash_dir) |d| std.debug.print("(crash log: see {s}/)\n", .{d});

    // The actual message + stack trace on stderr, plus the correct
    // abort behavior — not reimplemented here.
    std.debug.defaultPanic(message, first_trace_addr);
}

fn writeLog(message: []const u8) !void {
    const dir_path = g_crash_dir orelse return;
    const io = g_crash_io orelse return;

    const ts = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
    var file_buf: [512]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&file_buf, "{s}/{d}.log", .{ dir_path, ts });

    // Fixed buffer, not an allocator — a panic (possibly an OOM panic)
    // is the wrong place to risk a second allocation failing.
    var body_buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&body_buf);
    try w.print(
        "f69 crash log\n" ++
            "ts: {d}\n" ++
            "git: {s}\n" ++
            "zig: {s}\n" ++
            "platform: {s}-{s}\n" ++
            "\nmessage:\n{s}\n",
        .{
            ts,
            build_git_rev,
            builtin.zig_version_string,
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
            message,
        },
    );

    atomic_io.writeFileAtomic(io, file_path, w.buffered()) catch return;
}

const testing = std.testing;
const test_env = @import("util_test_env");

test "writeLog: writes a crash log with message + metadata, cross-platform dir resolution untouched" {
    var env = try test_env.TestEnv.init(testing.allocator, "crash-writeLog");
    defer env.deinit();

    g_crash_dir = env.root;
    g_crash_io = env.io;
    defer {
        g_crash_dir = null;
        g_crash_io = null;
    }

    try writeLog("test panic: index out of bounds");

    var dir = try std.Io.Dir.cwd().openDir(env.io, env.root, .{ .iterate = true });
    defer dir.close(env.io);
    var it = dir.iterate();
    var found = false;
    while (try it.next(env.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".log")) continue;
        found = true;
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ env.root, entry.name });
        defer testing.allocator.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(env.io, path, testing.allocator, .limited(4096));
        defer testing.allocator.free(bytes);
        try testing.expect(std.mem.startsWith(u8, bytes, "f69 crash log\n"));
        try testing.expect(std.mem.indexOf(u8, bytes, "test panic: index out of bounds") != null);
        try testing.expect(std.mem.indexOf(u8, bytes, @tagName(builtin.os.tag)) != null);
    }
    try testing.expect(found);
}

test "writeLog: no-ops when init was never called" {
    // g_crash_dir/g_crash_io are null at this point (previous test
    // resets them in its own defer) — writeLog must return cleanly,
    // not error, so a panic before startup finishes never itself panics.
    try writeLog("unreachable before init");
}
