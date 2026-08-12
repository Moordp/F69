// Shared test fixtures. Most f69 tests need a throwaway tmpdir with a
// few files in it (synthetic Ren'Py install, mod tracker JSON, recipe
// ZON, compat resource bundle, …). Each test file previously rolled
// its own tmpdir-name + touchFile + deleteTree pattern.
//
// `TestEnv` centralises that. Usage:
//
//     test "..." {
//         const ta = std.testing.allocator;
//         var env = try TestEnv.init(ta, "synthetic-renpy");
//         defer env.deinit();
//
//         try env.touchFile("renpy/bootstrap.py", "");
//         try env.writeFile("renpy/vc_version.py", "version = u'7.5.3'\n");
//         // env.root is the absolute tmpdir path, e.g. /tmp/f69-test-...
//     }
//
// On `deinit`, the tmpdir is recursively removed. A failing assertion
// before `deinit` leaks the tmpdir — that's by design so an attached
// debugger can inspect it.

const std = @import("std");
const builtin = @import("builtin");

/// Platform temp root, owned by `alloc`.
///
/// This module used to hardcode `/tmp`. Windows has no `/tmp` — the path
/// resolves against the current drive root instead — and because the suite had
/// never been run on Windows, nothing caught it. Mirrors `util/paths.zig`
/// `tempDir()`, inlined rather than imported: `util_test_env` is a dependency
/// of nearly every other module's tests, so it stays dependency-free.
fn tempBase(alloc: std.mem.Allocator) error{OutOfMemory}![]u8 {
    // `std.c.getenv` rather than the Environ API: this needs no allocator and
    // no Environ threaded down, and it's the pattern already used in ui.zig.
    const primary = if (builtin.os.tag == .windows) "TEMP" else "TMPDIR";
    if (std.c.getenv(primary)) |z| {
        const s = std.mem.span(z);
        if (s.len > 0) return alloc.dupe(u8, s);
    }
    if (builtin.os.tag == .windows) {
        if (std.c.getenv("TMP")) |z| {
            const s = std.mem.span(z);
            if (s.len > 0) return alloc.dupe(u8, s);
        }
        return alloc.dupe(u8, "C:\\Windows\\Temp");
    }
    return alloc.dupe(u8, "/tmp");
}

const sep = if (builtin.os.tag == .windows) "\\" else "/";

pub const TestEnv = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Owned by `io_threaded` below — kept here so callers can pass
    /// it through to code-under-test that needs an `Io`.
    io_threaded: std.Io.Threaded,
    /// Absolute path to the tmpdir. Owned by `alloc`.
    root: []u8,

    /// Create a fresh tmpdir at `/tmp/f69-test-<name>-<rand>/`. The
    /// random suffix prevents parallel tests stomping each other.
    pub fn init(alloc: std.mem.Allocator, name: []const u8) !TestEnv {
        // EXPLICIT async_limit. The default is `.limited(cpu_count - 1)`, so a
        // 2-core machine gets ONE async slot — and a single slot deadlocks:
        // `Dir.openDir` holds it while `Dir.iterate().next()` waits for a free
        // one. That is exactly how the Windows VM (2 visible cores) parked
        // forever in the recipe index while the 16-core Linux host never
        // contended. Tests must not be sensitive to core count.
        // smp_allocator, NOT the caller's `alloc` (which is almost always
        // std.testing.allocator — single-threaded by design): Threaded's
        // WORKER threads allocate through this allocator, and a non-thread-
        // safe one intermittently parks/corrupts under contention. This is
        // the strongest candidate for the "std.Io Windows park": suites on
        // smp-backed io (gui-test.exe) never parked; TestEnv-io suites did.
        var io_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
        errdefer io_threaded.deinit();
        const io = io_threaded.io();

        // Random 8 hex chars so concurrent test runs don't collide.
        var nonce_buf: [4]u8 = undefined;
        io.randomSecure(&nonce_buf) catch io.random(&nonce_buf);

        const base = try tempBase(alloc);
        defer alloc.free(base);
        const root = try std.fmt.allocPrint(
            alloc,
            "{s}" ++ sep ++ "f69-test-{s}-{x}",
            .{ base, name, std.fmt.bytesToHex(nonce_buf, .lower) },
        );
        errdefer alloc.free(root);

        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        try std.Io.Dir.cwd().createDirPath(io, root);

        return .{
            .alloc = alloc,
            .io = io,
            .io_threaded = io_threaded,
            .root = root,
        };
    }

    pub fn deinit(self: *TestEnv) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
        self.alloc.free(self.root);
        self.io_threaded.deinit();
    }

    /// Create an empty file at `<root>/<rel>`. Parent dirs created
    /// as needed.
    pub fn touchFile(self: *TestEnv, rel: []const u8) !void {
        return self.writeFile(rel, "");
    }

    /// Write `bytes` to `<root>/<rel>`. Parent dirs created as needed.
    pub fn writeFile(self: *TestEnv, rel: []const u8, bytes: []const u8) !void {
        const full = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.root, rel });
        defer self.alloc.free(full);
        if (std.fs.path.dirname(full)) |d| try std.Io.Dir.cwd().createDirPath(self.io, d);
        var f = try std.Io.Dir.cwd().createFile(self.io, full, .{ .truncate = true });
        defer f.close(self.io);
        if (bytes.len > 0) {
            var fw_buf: [4096]u8 = undefined;
            var fw = f.writer(self.io, &fw_buf);
            try fw.interface.writeAll(bytes);
            try fw.interface.flush();
        }
    }

    /// Allocator-owned `<root>/<rel>` path. Caller frees.
    pub fn path(self: *TestEnv, rel: []const u8) ![]u8 {
        return try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.root, rel });
    }

    /// Create directory `<root>/<rel>` (and any missing parents). No-op
    /// if it already exists.
    pub fn mkdirP(self: *TestEnv, rel: []const u8) !void {
        const full = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.root, rel });
        defer self.alloc.free(full);
        try std.Io.Dir.cwd().createDirPath(self.io, full);
    }
};

const testing = std.testing;

test "TestEnv: writes + cleans up" {
    var env = try TestEnv.init(testing.allocator, "smoke");
    defer env.deinit();
    try env.writeFile("game/bootstrap.py", "# hi\n");
    try env.touchFile("game/empty");

    const sub = try env.path("game/bootstrap.py");
    defer testing.allocator.free(sub);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(env.io, sub, testing.allocator, .limited(64));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("# hi\n", bytes);
}
