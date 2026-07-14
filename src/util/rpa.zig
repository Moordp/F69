//! Ren'Py archive (.rpa) index reader (M3 §2.1). Supports RPA-3.0 (the
//! common case) and RPA-2.0. The index lives at a byte offset named in the
//! first header line, zlib-compressed, holding a pickle of
//! `{path: [(offset, length, prefix), ...]}`. In v3 the offset+length are
//! XOR-obfuscated with a key from the header; the prefix is literal bytes
//! prepended to the file content.
//!
//! Header parse + entry deobfuscation are pure (tested via hand-built pickle
//! fixtures); `loadIndex` adds the zlib decompress + pickle decode.

const std = @import("std");
const Io = std.Io;
const pickle = @import("pickle.zig");

pub const Error = error{ BadHeader, Decompress, OutOfMemory, Truncated, Unsupported };

pub const Header = struct {
    version: u8, // 2 or 3
    index_offset: u64,
    key: u32, // 0 for v2 (no obfuscation)
};

/// One indexed file. `name`/`prefix` borrow the decode arena. Content is
/// `prefix ++ archive[offset .. offset + (length - prefix.len)]`.
pub const Entry = struct {
    name: []const u8,
    offset: u64,
    length: u64,
    prefix: []const u8,
};

/// Parse the first header line ("RPA-3.0 <16hex off> <8hex key>" or
/// "RPA-2.0 <16hex off>"). Pure.
pub fn parseHeader(line: []const u8) ?Header {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const magic = it.next() orelse return null;
    if (std.mem.eql(u8, magic, "RPA-3.0")) {
        const off = std.fmt.parseInt(u64, it.next() orelse return null, 16) catch return null;
        const key = std.fmt.parseInt(u32, it.next() orelse return null, 16) catch return null;
        return .{ .version = 3, .index_offset = off, .key = key };
    }
    if (std.mem.eql(u8, magic, "RPA-2.0")) {
        const off = std.fmt.parseInt(u64, it.next() orelse return null, 16) catch return null;
        return .{ .version = 2, .index_offset = off, .key = 0 };
    }
    return null;
}

/// Build entries from a decoded pickle index dict, applying the XOR key.
/// Only the first segment of each file is used (multi-segment files are
/// vanishingly rare for game assets). Pure + testable.
pub fn entriesFromValue(arena: std.mem.Allocator, root: pickle.Value, key: u32) Error![]Entry {
    if (root != .dict) return Error.Unsupported;
    var out: std.ArrayList(Entry) = .empty;
    for (root.dict) |pair| {
        const name = pair.key.text() orelse continue;
        if (pair.val != .list or pair.val.list.len == 0) continue;
        const seg = pair.val.list[0];
        if (seg != .tuple or seg.tuple.len < 2) continue;
        const raw_off = seg.tuple[0].asInt() orelse continue;
        const raw_len = seg.tuple[1].asInt() orelse continue;
        const prefix: []const u8 = if (seg.tuple.len >= 3) (seg.tuple[2].text() orelse "") else "";
        try out.append(arena, .{
            .name = name,
            .offset = (@as(u64, @bitCast(raw_off))) ^ key,
            .length = (@as(u64, @bitCast(raw_len))) ^ key,
            .prefix = prefix,
        });
    }
    return out.toOwnedSlice(arena);
}

/// Decode an RPA archive's index from the full archive bytes. Entries +
/// strings are allocated in `arena`.
pub fn loadIndex(arena: std.mem.Allocator, archive: []const u8) Error![]Entry {
    const nl = std.mem.indexOfScalar(u8, archive, '\n') orelse return Error.BadHeader;
    const header = parseHeader(archive[0..nl]) orelse return Error.BadHeader;
    if (header.index_offset >= archive.len) return Error.Truncated;

    const compressed = archive[header.index_offset..];
    const index_bytes = zlibInflate(arena, compressed) catch return Error.Decompress;
    const root = pickle.load(arena, index_bytes) catch return Error.Unsupported;
    return entriesFromValue(arena, root, header.key);
}

fn zlibInflate(arena: std.mem.Allocator, data: []const u8) ![]u8 {
    var src = Io.Reader.fixed(data);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    defer arena.free(window);
    var dec = std.compress.flate.Decompress.init(&src, .zlib, window);
    return dec.reader.allocRemaining(arena, .unlimited);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseHeader: RPA-3.0 and RPA-2.0" {
    const h3 = parseHeader("RPA-3.0 000000000000abcd deadbeef").?;
    try testing.expectEqual(@as(u8, 3), h3.version);
    try testing.expectEqual(@as(u64, 0xabcd), h3.index_offset);
    try testing.expectEqual(@as(u32, 0xdeadbeef), h3.key);

    const h2 = parseHeader("RPA-2.0 0000000000000010").?;
    try testing.expectEqual(@as(u8, 2), h2.version);
    try testing.expectEqual(@as(u64, 16), h2.index_offset);
    try testing.expectEqual(@as(u32, 0), h2.key);

    try testing.expect(parseHeader("ZIP whatever") == null);
    try testing.expect(parseHeader("RPA-3.0 nothex zz") == null);
}

test "entriesFromValue deobfuscates offset/length with the key" {
    // Pickle for {"a.rpy": [(16 ^ key, 100 ^ key, b"")]} so after XOR we get
    // back 16 / 100. key = 0x01020304.
    const key: u32 = 0x01020304;
    const off_obf: u32 = 16 ^ key;
    const len_obf: u32 = 100 ^ key;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const a = testing.allocator;
    try buf.appendSlice(a, &.{ 0x80, 0x02, 0x7d, 0x28 }); // PROTO2 EMPTY_DICT MARK
    try buf.appendSlice(a, &.{ 0x8c, 0x05, 'a', '.', 'r', 'p', 'y' }); // key str
    try buf.appendSlice(a, &.{ 0x5d, 0x28, 0x28 }); // EMPTY_LIST MARK(appends) MARK(tuple)
    try buf.append(a, 0x4a); // BININT off_obf
    try buf.appendSlice(a, &@as([4]u8, @bitCast(std.mem.nativeToLittle(u32, off_obf))));
    try buf.append(a, 0x4a); // BININT len_obf
    try buf.appendSlice(a, &@as([4]u8, @bitCast(std.mem.nativeToLittle(u32, len_obf))));
    try buf.appendSlice(a, &.{ 0x43, 0x00 }); // SHORT_BINBYTES ""
    try buf.appendSlice(a, &.{ 0x74, 0x65, 0x75, 0x2e }); // TUPLE APPENDS SETITEMS STOP

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try pickle.load(arena.allocator(), buf.items);
    const entries = try entriesFromValue(arena.allocator(), root, key);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("a.rpy", entries[0].name);
    try testing.expectEqual(@as(u64, 16), entries[0].offset);
    try testing.expectEqual(@as(u64, 100), entries[0].length);
    try testing.expectEqualStrings("", entries[0].prefix);
}

/// A minimal fully valid RPA-3.0 archive, built at comptime: header line,
/// then a zlib stream (single *stored* deflate block, so no compressor
/// needed, plus adler32) wrapping the one-entry pickle index
/// {"a.rpy": [(16, 100, b"")]} with key 0 (no obfuscation).
const valid_archive = blk: {
    const header = "RPA-3.0 0000000000000022 00000000\n"; // index at 0x22 = header.len
    const pkl = [_]u8{
        0x80, 0x02, 0x7d, 0x28, // PROTO2 EMPTY_DICT MARK
        0x8c, 0x05, 'a', '.', 'r', 'p', 'y', // SHORT_BINUNICODE "a.rpy"
        0x5d, 0x28, 0x28, // EMPTY_LIST MARK(appends) MARK(tuple)
        0x4a, 16, 0, 0, 0, // BININT 16
        0x4a, 100, 0, 0, 0, // BININT 100
        0x43, 0x00, // SHORT_BINBYTES ""
        0x74, 0x65, 0x75, 0x2e, // TUPLE APPENDS SETITEMS STOP
    };
    var z: [2 + 5 + pkl.len + 4]u8 = undefined;
    z[0] = 0x78; // zlib CMF: deflate, 32K window
    z[1] = 0x01; // zlib FLG (check bits valid for 0x7801)
    z[2] = 0x01; // BFINAL=1, BTYPE=00 (stored)
    std.mem.writeInt(u16, z[3..5], pkl.len, .little);
    std.mem.writeInt(u16, z[5..7], ~@as(u16, pkl.len), .little);
    @memcpy(z[7..][0..pkl.len], &pkl);
    var s1: u32 = 1; // adler32 over the uncompressed bytes
    var s2: u32 = 0;
    for (pkl) |b| {
        s1 = (s1 + b) % 65521;
        s2 = (s2 + s1) % 65521;
    }
    std.mem.writeInt(u32, z[7 + pkl.len ..][0..4], (s2 << 16) | s1, .big);
    break :blk header.* ++ z;
};

test "loadIndex succeeds on the comptime valid archive (fuzz seed sanity)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const entries = try loadIndex(arena.allocator(), &valid_archive);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("a.rpy", entries[0].name);
    try testing.expectEqual(@as(u64, 16), entries[0].offset);
    try testing.expectEqual(@as(u64, 100), entries[0].length);
}

test "fuzz: rpa header and index parsers survive arbitrary input" {
    try std.testing.fuzz({}, fuzzRpa, .{ .corpus = &.{
        fuzzSeed("RPA-3.0 000000000000002c deadbeef\nGARBAGE-INDEX-BYTES"),
        fuzzSeed("RPA-2.0 0000000000000010\n"),
        fuzzSeed("RPA-3.0 nothex zz"),
        fuzzSeed("ZIP whatever"),
        fuzzSeed(&valid_archive),
    } });
}

fn fuzzRpa(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [FUZZ_BUF_LEN]u8 = undefined;
    const n = smith.slice(&buf);
    const data = buf[0..n];

    // First line as a header candidate.
    const line_end = std.mem.indexOfScalar(u8, data, '\n') orelse data.len;
    _ = parseHeader(data[0..line_end]);

    // Whole blob as an archive: header line + compressed pickle index.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = loadIndex(arena.allocator(), data) catch return; // rpa.Error = expected reject
}

/// Harness read-buffer length. fuzzSeed payloads must fit this, or Smith's
/// decode silently rejects the length and replays the seed as empty.
const FUZZ_BUF_LEN = 4096;

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
