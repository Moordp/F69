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
