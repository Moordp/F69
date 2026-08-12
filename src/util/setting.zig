// Small-file persistence helper. f69's "settings" live as a sprawl of
// one-key-per-file under `<data_root>/` (aria2_port, aria2_seed_ratio,
// auto_convert, sandbox_default, ui_scale, …). Each previously had its
// own bespoke `loadFooFromFile(io, alloc, path)` helper in main.zig.
//
// `readSingleLine` + the four `parseX` helpers below cover every
// existing setting type. Settings UI calls `util_atomic_io.writeFileAtomic`
// to save.
//
// This is intentionally minimal: no Setting(T) class with builtin
// persistence; the load/save split mirrors how main.zig wants to
// invoke these (load at startup into a runtime-info struct, save
// on user-edit via a Settings panel).

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ OutOfMemory };

/// Read the trimmed content of a small text file. Missing file →
/// `null`. IO errors → `null` (the caller can fall back to defaults).
pub fn readSingleLine(io: std.Io, alloc: std.mem.Allocator, path: []const u8) Error!?[]u8 {
    // WINDOWS: read via libc, not std.Io — the std.Io read of a recently
    // written file parks forever (intermittently; traced on the Win11 VM
    // 2026-08-11/12, same defect as recipe/zon_loader.zig readFileSentinel).
    // Settings files are read straight after being written constantly, so
    // this path was parking the suite at uiscale-persist. Comptime-scoped;
    // x86_64-windows-gnu always links mingw libc.
    if (builtin.os.tag == .windows) {
        var pz_buf: [1024]u8 = undefined;
        const pz = std.fmt.bufPrintZ(&pz_buf, "{s}", .{path}) catch return null;
        const f = std.c.fopen(pz.ptr, "rb") orelse return null;
        defer _ = std.c.fclose(f);
        var buf: [256]u8 = undefined;
        const n = std.c.fread(&buf, 1, buf.len, f);
        const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (trimmed.len == 0) return null;
        return alloc.dupe(u8, trimmed) catch return Error.OutOfMemory;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(256)) catch return null;
    defer alloc.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    const dup = alloc.dupe(u8, trimmed) catch return Error.OutOfMemory;
    return dup;
}

/// Parse "true" / "1" / "on" / "yes" (case-sensitive) as true; anything
/// else as false.
pub fn parseBool(s: []const u8) bool {
    return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1") or
        std.mem.eql(u8, s, "on") or std.mem.eql(u8, s, "yes");
}

/// Convenience: load + parseBool + free in one call. Missing/malformed → default.
pub fn loadBool(io: std.Io, alloc: std.mem.Allocator, path: []const u8, default: bool) bool {
    const owned = (readSingleLine(io, alloc, path) catch return default) orelse return default;
    defer alloc.free(owned);
    return parseBool(owned);
}

/// Convenience: load + parseInt + free. Missing/malformed → default.
pub fn loadInt(comptime T: type, io: std.Io, alloc: std.mem.Allocator, path: []const u8, default: T) T {
    const owned = (readSingleLine(io, alloc, path) catch return default) orelse return default;
    defer alloc.free(owned);
    return std.fmt.parseInt(T, owned, 10) catch default;
}

/// Convenience: load + parseFloat + free. Missing/malformed → default.
pub fn loadFloat(comptime T: type, io: std.Io, alloc: std.mem.Allocator, path: []const u8, default: T) T {
    const owned = (readSingleLine(io, alloc, path) catch return default) orelse return default;
    defer alloc.free(owned);
    return std.fmt.parseFloat(T, owned) catch default;
}

const testing = std.testing;

test "parseBool: truthy + falsy" {
    try testing.expect(parseBool("true"));
    try testing.expect(parseBool("1"));
    try testing.expect(parseBool("on"));
    try testing.expect(parseBool("yes"));
    try testing.expect(!parseBool("false"));
    try testing.expect(!parseBool("0"));
    try testing.expect(!parseBool(""));
}
