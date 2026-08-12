// XDG path helpers (Windows known-folders) + project-specific path conventions.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ NoHomeDir, OutOfMemory };

/// Config base: `%APPDATA%` on Windows; `$XDG_CONFIG_HOME` or `$HOME/.config` elsewhere. Caller frees.
pub fn configHome(environ: std.process.Environ, alloc: std.mem.Allocator) Error![]u8 {
    if (builtin.os.tag == .windows) {
        return environ.getAlloc(alloc, "APPDATA") catch Error.NoHomeDir;
    }
    if (environ.getAlloc(alloc, "XDG_CONFIG_HOME")) |x| return x else |_| {}
    const h = environ.getAlloc(alloc, "HOME") catch return Error.NoHomeDir;
    defer alloc.free(h);
    return std.fmt.allocPrint(alloc, "{s}/.config", .{h}) catch Error.OutOfMemory;
}

/// Cache base: `%LOCALAPPDATA%` on Windows; `$XDG_CACHE_HOME` or `$HOME/.cache` elsewhere. Caller frees.
pub fn cacheHome(environ: std.process.Environ, alloc: std.mem.Allocator) Error![]u8 {
    if (builtin.os.tag == .windows) {
        return environ.getAlloc(alloc, "LOCALAPPDATA") catch Error.NoHomeDir;
    }
    if (environ.getAlloc(alloc, "XDG_CACHE_HOME")) |x| return x else |_| {}
    const h = environ.getAlloc(alloc, "HOME") catch return Error.NoHomeDir;
    defer alloc.free(h);
    return std.fmt.allocPrint(alloc, "{s}/.cache", .{h}) catch Error.OutOfMemory;
}

/// Home dir: `%USERPROFILE%` on Windows; `$HOME` elsewhere. Caller frees.
pub fn home(environ: std.process.Environ, alloc: std.mem.Allocator) Error![]u8 {
    const key = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    return environ.getAlloc(alloc, key) catch Error.NoHomeDir;
}

/// System temp dir: `%TEMP%`/`%TMP%` on Windows; `$TMPDIR` or `/tmp`
/// elsewhere. Never fails — falls back to a platform-conventional default
/// so callers always get a usable scratch root (used for mod-apply
/// staging, which on Windows must land in the real temp dir rather than
/// a drive-root `C:\tmp`). Caller frees.
pub fn tempDir(environ: std.process.Environ, alloc: std.mem.Allocator) error{OutOfMemory}![]u8 {
    if (builtin.os.tag == .windows) {
        if (environ.getAlloc(alloc, "TEMP")) |x| return x else |_| {}
        if (environ.getAlloc(alloc, "TMP")) |x| return x else |_| {}
        return alloc.dupe(u8, "C:\\Windows\\Temp");
    }
    if (environ.getAlloc(alloc, "TMPDIR")) |x| return x else |_| {}
    return alloc.dupe(u8, "/tmp");
}

/// `<library_root>/<game_id>/<version>/`. Caller frees.
pub fn installDir(alloc: std.mem.Allocator, library_root: []const u8, game_id: []const u8, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ library_root, game_id, version });
}

/// `<config_home>/f69/sandbox/<game_id>/`. Per-game (NOT per-install) so
/// saves carry across versions. Caller frees.
pub fn sandboxHome(alloc: std.mem.Allocator, config_home: []const u8, game_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/f69/sandbox/{s}", .{ config_home, game_id });
}

/// Bundled mkxp-z dir. Two install layouts:
///   - Portable: `<exe_dir>/data/mkxp-z/`
///   - FHS:      `<exe_dir>/../share/f69/data/mkxp-z/` (rpm/deb)
/// Probes the FHS path first; falls back to portable. Returns the
/// path even if it doesn't exist (caller must verify) — matches the
/// pre-refactor contract. Caller frees.
pub fn bundledMkxpZDir(alloc: std.mem.Allocator, exe_dir: []const u8) ![]u8 {
    return resolveBundledDataPath(alloc, exe_dir, "mkxp-z");
}

/// Bundled mkxp-z FHS-libs dir (NixOS-only libstdc++ bundle the
/// convert launcher prepends to LD_LIBRARY_PATH). Empty (returned as-
/// is, caller must check existence) on non-Nix builds. Same
/// portable-vs-FHS dual probe as `bundledMkxpZDir`. Caller frees.
pub fn bundledMkxpZLibsDir(alloc: std.mem.Allocator, exe_dir: []const u8) ![]u8 {
    return resolveBundledDataPath(alloc, exe_dir, "compat-resources/mkxp-z-fhs-libs/lib");
}

const testing = std.testing;

// Synthetic environs are POSIX-only: on Windows `Environ.Block` is
// `GlobalBlock` (real process env or empty — nothing in between), so the
// Windows tests below use `.empty` for the error/fallback arms and the
// global environ (self-consistency against a direct key lookup) for the
// happy path. That split is why every test here carries an OS guard.

test "configHome: XDG_CONFIG_HOME wins (POSIX)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const block = [_:null]?[*:0]const u8{ "XDG_CONFIG_HOME=/x/cfg", "HOME=/home/u" };
    const environ: std.process.Environ = .{ .block = .{ .slice = &block } };
    const got = try configHome(environ, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/x/cfg", got);
}

test "configHome: falls back to HOME/.config (POSIX)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const block = [_:null]?[*:0]const u8{"HOME=/home/u"};
    const environ: std.process.Environ = .{ .block = .{ .slice = &block } };
    const got = try configHome(environ, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/u/.config", got);
}

test "configHome + cacheHome + home: no HOME anywhere is NoHomeDir" {
    // Same assertion on both OSes: `.empty` has no APPDATA / LOCALAPPDATA /
    // USERPROFILE on Windows and no XDG_* / HOME on POSIX.
    try testing.expectError(Error.NoHomeDir, configHome(.empty, testing.allocator));
    try testing.expectError(Error.NoHomeDir, cacheHome(.empty, testing.allocator));
    try testing.expectError(Error.NoHomeDir, home(.empty, testing.allocator));
}

test "cacheHome: XDG_CACHE_HOME wins, else HOME/.cache (POSIX)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    {
        const block = [_:null]?[*:0]const u8{ "XDG_CACHE_HOME=/x/cache", "HOME=/home/u" };
        const environ: std.process.Environ = .{ .block = .{ .slice = &block } };
        const got = try cacheHome(environ, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/x/cache", got);
    }
    {
        const block = [_:null]?[*:0]const u8{"HOME=/home/u"};
        const environ: std.process.Environ = .{ .block = .{ .slice = &block } };
        const got = try cacheHome(environ, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/home/u/.cache", got);
    }
}

test "tempDir: TMPDIR wins, else /tmp (POSIX)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    {
        const block = [_:null]?[*:0]const u8{"TMPDIR=/var/scratch"};
        const environ: std.process.Environ = .{ .block = .{ .slice = &block } };
        const got = try tempDir(environ, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/var/scratch", got);
    }
    {
        const got = try tempDir(.empty, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/tmp", got);
    }
}

test "tempDir: empty environ falls back to C:\\Windows\\Temp (Windows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // The mod-apply staging bug this guards: without the fallback, staging
    // landed in a drive-root `C:\tmp` (see tempDir's doc comment).
    const got = try tempDir(.empty, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("C:\\Windows\\Temp", got);
}

test "Windows base dirs map to the right known folders (Windows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // Self-consistency against a direct key lookup on the REAL process env:
    // configHome must be %APPDATA% specifically (not LOCALAPPDATA), cacheHome
    // %LOCALAPPDATA%, home %USERPROFILE%. A swapped key here would scatter the
    // user's config/cache across the wrong roaming profile silently.
    const environ: std.process.Environ = .{ .block = .global };
    const cases = [_]struct { key: []const u8, got: Error![]u8 }{
        .{ .key = "APPDATA", .got = configHome(environ, testing.allocator) },
        .{ .key = "LOCALAPPDATA", .got = cacheHome(environ, testing.allocator) },
        .{ .key = "USERPROFILE", .got = home(environ, testing.allocator) },
    };
    for (cases) |case| {
        const want = environ.getAlloc(testing.allocator, case.key) catch {
            // Var genuinely unset on this host — the resolver must agree.
            try testing.expectError(Error.NoHomeDir, case.got);
            continue;
        };
        defer testing.allocator.free(want);
        const got = try case.got;
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
        try testing.expect(got.len > 0);
    }
}

test "installDir + sandboxHome: path shapes" {
    {
        const got = try installDir(testing.allocator, "/lib/root", "181313", "final");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/lib/root/181313/final", got);
    }
    {
        const got = try sandboxHome(testing.allocator, "/home/u/.config", "181313");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/home/u/.config/f69/sandbox/181313", got);
    }
}

fn resolveBundledDataPath(alloc: std.mem.Allocator, exe_dir: []const u8, sub: []const u8) ![]u8 {
    // FHS first — when exe_dir is /usr/bin, /usr/share/f69/data/... is
    // where the .rpm / .deb packaging lands the bundle. `std.Io.Dir.cwd().access`
    // would need an `io` handle here; this helper is hot on the convert
    // path and used by stat-cheap callers, so we just return the first
    // path that's a directory by checking on disk via std.fs.cwd.statFile
    // — same allocator semantics, no io param plumbing required.
    const fhs = try std.fmt.allocPrint(alloc, "{s}/../share/f69/data/{s}", .{ exe_dir, sub });
    if (std.fs.cwd().statFile(fhs)) |st| {
        if (st.kind == .directory) return fhs;
    } else |_| {}
    alloc.free(fhs);
    return std.fmt.allocPrint(alloc, "{s}/data/{s}", .{ exe_dir, sub });
}
