// Ren'Py-specific version probes and string parsers.
//
// Two modules need to read the engine version from an installed
// game tree:
//
//   - `src/convert/renpy.zig` — picks the SDK release matching the
//     game's Ren'Py version before doing Win→Linux conversion.
//   - `src/compat/detect.zig`  — gates `engine_version_at_*`
//     recipes (e.g. the renpy7 vs renpy8 SDL-FHS split).
//
// Both used to carry their own copy of these parsers. Living here
// keeps them in one place, removes the cross-cut dependency that
// would otherwise force `compat` to import `convert` (a non-leaf
// module), and lets future engine probes (Unity, RPGM nwjs) live
// alongside if/when they need similar treatment.

const std = @import("std");
const Io = std.Io;

/// Read the Ren'Py version that built the install at `install_dir`.
/// Tries the modern `renpy/vc_version.py` first; falls back to
/// `renpy/__init__.py`'s `version_tuple = (…)`. Returns "X.Y.Z" —
/// or `null` when neither file is parseable. IO errors are
/// suppressed as `null` (the caller's contract is "can you tell me
/// the version?", and "no" is the right answer for both "file
/// missing" and "file unreadable").
pub fn detectVersion(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
) std.mem.Allocator.Error!?[]u8 {
    // ---- vc_version.py: `version = u'7.6.1.23060707'` ----
    {
        var path_buf: [512]u8 = undefined;
        const vc_path = std.fmt.bufPrint(&path_buf, "{s}/renpy/vc_version.py", .{install_dir}) catch return null;
        const content_or = std.Io.Dir.cwd().readFileAlloc(io, vc_path, alloc, .limited(64 * 1024));
        if (content_or) |c| {
            defer alloc.free(c);
            if (parseVcVersion(c)) |raw| {
                return try takeMajMinPatch(alloc, raw);
            }
        } else |_| {}
    }

    // ---- __init__.py: `version_tuple = (7, 5, 3, vc_version)` ----
    {
        var path_buf: [512]u8 = undefined;
        const init_path = std.fmt.bufPrint(&path_buf, "{s}/renpy/__init__.py", .{install_dir}) catch return null;
        const content_or = std.Io.Dir.cwd().readFileAlloc(io, init_path, alloc, .limited(256 * 1024));
        if (content_or) |c| {
            defer alloc.free(c);
            return try parseVersionTuple(alloc, c);
        } else |_| {}
    }

    return null;
}

/// Pure. Parses `version = u'X.Y.Z.BUILD'` or `version = 'X.Y.Z.BUILD'`.
/// Returns the inner literal (borrowed from `content`).
fn parseVcVersion(content: []const u8) ?[]const u8 {
    const marker_a = "version = u'";
    const marker_b = "version = '";
    const start_a = std.mem.indexOf(u8, content, marker_a);
    const start_b = std.mem.indexOf(u8, content, marker_b);
    const start, const marker_len = blk: {
        if (start_a) |a| break :blk .{ a, marker_a.len };
        if (start_b) |b| break :blk .{ b, marker_b.len };
        return null;
    };
    const value_start = start + marker_len;
    const end = std.mem.indexOfScalarPos(u8, content, value_start, '\'') orelse return null;
    return content[value_start..end];
}

/// Pure. "7.6.1.23060707" → "7.6.1" (allocates). Strings shorter
/// than 3 dot-separated parts are returned as a dup of `raw`.
fn takeMajMinPatch(alloc: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '.');
    while (it.next()) |p| : (n += 1) {
        if (n >= 3) break;
        parts[n] = p;
    }
    if (n < 3) return alloc.dupe(u8, raw);
    return std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ parts[0], parts[1], parts[2] });
}

/// Pure. Parses `version_tuple = (7, 5, 3, vc_version)` style.
/// Returns allocator-owned "X.Y.Z" or null.
fn parseVersionTuple(alloc: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error!?[]u8 {
    const marker = "version_tuple = (";
    const start = std.mem.indexOf(u8, content, marker) orelse return null;
    const open = start + marker.len;
    const close = std.mem.indexOfScalarPos(u8, content, open, ')') orelse return null;
    const inside = content[open..close];

    var nums: [3]u32 = .{ 0, 0, 0 };
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, inside, ',');
    while (it.next()) |raw_part| {
        if (n >= 3) break;
        const t = std.mem.trim(u8, raw_part, " \t");
        const v = std.fmt.parseInt(u32, t, 10) catch continue;
        nums[n] = v;
        n += 1;
    }
    if (n == 0) return null;
    return try std.fmt.allocPrint(alloc, "{d}.{d}.{d}", .{ nums[0], nums[1], nums[2] });
}

// ============================================================
//  tests
// ============================================================

const testing = std.testing;

test "parseVcVersion: u-prefixed literal" {
    const src = "version = u'7.5.3.23060707'\n";
    try testing.expectEqualStrings("7.5.3.23060707", parseVcVersion(src).?);
}

test "parseVcVersion: plain literal" {
    const src = "version = '8.2.1.24030407'\n";
    try testing.expectEqualStrings("8.2.1.24030407", parseVcVersion(src).?);
}

test "parseVcVersion: no match" {
    try testing.expect(parseVcVersion("nothing to see here") == null);
}

test "takeMajMinPatch: 4-component → 3-component" {
    const got = try takeMajMinPatch(testing.allocator, "7.5.3.23060707");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("7.5.3", got);
}

test "takeMajMinPatch: shorter than 3 → dup" {
    const got = try takeMajMinPatch(testing.allocator, "7.5");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("7.5", got);
}

test "parseVersionTuple: 4-tuple → first 3" {
    const src = "version_tuple = (7, 5, 3, vc_version)";
    const got = try parseVersionTuple(testing.allocator, src);
    defer if (got) |v| testing.allocator.free(v);
    try testing.expectEqualStrings("7.5.3", got.?);
}

test "parseVersionTuple: no marker → null" {
    const got = try parseVersionTuple(testing.allocator, "nothing");
    try testing.expect(got == null);
}

test "fuzz: renpy version parsers survive arbitrary file content" {
    try std.testing.fuzz({}, fuzzRenpyParsers, .{ .corpus = &.{
        fuzzSeed("version = u'7.6.1.23060707'\n"),
        fuzzSeed("version_tuple = (7, 5, 3, vc_version)\n"),
        fuzzSeed("version = "),
    } });
}

fn fuzzRenpyParsers(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [FUZZ_BUF_LEN]u8 = undefined;
    const n = smith.slice(&buf);
    const content = buf[0..n];
    const a = std.testing.allocator;

    if (parseVcVersion(content)) |raw| {
        // Borrowed slice of `content`; feeding it on covers takeMajMinPatch
        // with fuzz-shaped raw versions, mirroring detectVersion's flow.
        const v = try takeMajMinPatch(a, raw);
        a.free(v);
    }
    if (try parseVersionTuple(a, content)) |v| a.free(v);
}

/// Harness read-buffer length. fuzzSeed payloads must fit this, or Smith's
/// decode silently rejects the length and replays the seed as empty.
const FUZZ_BUF_LEN = 2048;

/// Encode one corpus entry for a testOne that makes a single smith.slice()
/// call: 4-byte LE length prefix + payload (Smith input stream format).
/// The payload must fit the harness read buffer (FUZZ_BUF_LEN): a longer
/// length is rejected by Smith's decode and the seed silently replays as
/// an empty string.
fn fuzzSeed(comptime payload: []const u8) []const u8 {
    comptime std.debug.assert(payload.len <= FUZZ_BUF_LEN);
    const S = struct {
        const entry: [4 + payload.len]u8 = blk: {
            var e: [4 + payload.len]u8 = undefined;
            std.mem.writeInt(u32, e[0..4], payload.len, .little);
            @memcpy(e[4..], payload);
            break :blk e;
        };
    };
    return &S.entry;
}
