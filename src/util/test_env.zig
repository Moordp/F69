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

// mingw libc's directory-create — one arg, no mode. Used on Windows instead
// of std.Io.Dir.createDirPath, which is the documented std.Io parker there
// (see util/atomic_io.zig header + the 2026-08-12 uiscale-persist trace).
extern "c" fn _mkdir(path: [*:0]const u8) c_int;

/// Best-effort `mkdir -p` via libc for an ABSOLUTE Windows path. Failures
/// (including already-exists) are ignored — the following fopen surfaces a
/// real problem with a clearer error.
fn winMkdirP(path: []const u8) void {
    var buf: [1024:0]u8 = undefined;
    if (path.len >= buf.len) return;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        const c = path[i];
        buf[i] = if (c == '/') '\\' else c;
        if ((c == '/' or c == '\\') and i > 2) { // skip the drive root "C:\"
            buf[i] = 0;
            _ = _mkdir(&buf);
            buf[i] = '\\';
        }
    }
    buf[path.len] = 0;
    _ = _mkdir(&buf);
}

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
        // PRNG seeded from clock+ASLR, NOT io.randomSecure — no std.Io op
        // before the first test body on Windows (any of them can park), and
        // this is a tmpdir nonce, not key material.
        // Seed: per-process ASLR (global's address) + per-init counter.
        // Distinct across processes AND across inits in one process — all a
        // tmpdir nonce needs.
        const Seed = struct {
            var counter: u64 = 0;
        };
        Seed.counter +%= 0x9E3779B97F4A7C15;
        var nonce_buf: [4]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(@intFromPtr(&Seed.counter) +% Seed.counter);
        prng.random().bytes(&nonce_buf);

        const base = try tempBase(alloc);
        defer alloc.free(base);
        const root = try std.fmt.allocPrint(
            alloc,
            "{s}" ++ sep ++ "f69-test-{s}-{x}",
            .{ base, name, std.fmt.bytesToHex(nonce_buf, .lower) },
        );
        errdefer alloc.free(root);

        if (builtin.os.tag == .windows) {
            // libc mkdir; the nonce guarantees a fresh name so no pre-clean.
            winMkdirP(root);
        } else {
            std.Io.Dir.cwd().deleteTree(io, root) catch {};
            try std.Io.Dir.cwd().createDirPath(io, root);
        }

        return .{
            .alloc = alloc,
            .io = io,
            .io_threaded = io_threaded,
            .root = root,
        };
    }

    pub fn deinit(self: *TestEnv) void {
        // Windows: deleteTree walks the tree via std.Io — park risk. The
        // nonce'd dirs live under %TEMP%; leaking them is the lesser evil
        // and the OS temp cleanup collects them eventually.
        if (builtin.os.tag != .windows) {
            std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
        }
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
        if (builtin.os.tag == .windows) {
            // libc all the way — see the module header note on the std.Io park.
            if (std.fs.path.dirname(full)) |d| winMkdirP(d);
            var pz_buf: [1024]u8 = undefined;
            const pz = std.fmt.bufPrintZ(&pz_buf, "{s}", .{full}) catch return error.NameTooLong;
            const f = std.c.fopen(pz.ptr, "wb") orelse return error.FileNotFound;
            defer _ = std.c.fclose(f);
            if (bytes.len > 0 and std.c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) {
                return error.WriteFailed;
            }
            return;
        }
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
        if (builtin.os.tag == .windows) {
            winMkdirP(full);
            return;
        }
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
