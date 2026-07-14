//! Minimal Python-pickle reader — just enough to decode a Ren'Py RPA archive
//! index, which is `pickle.dumps({filename: [(offset, length, prefix)], ...})`
//! (protocol 2). NOT a general pickle VM: it handles the opcodes that appear
//! in that structure (dicts, lists, tuples, ints, str/bytes, None/bool, and
//! the memo). Unknown opcodes return `error.Unsupported` rather than guessing.
//!
//! Values are arena-allocated and string/bytes payloads BORROW the input, so
//! the decoded tree is valid only while both the arena and `data` live.

const std = @import("std");

pub const Value = union(enum) {
    none,
    boolean: bool,
    int: i64,
    /// Unicode string (BINUNICODE family). Borrows input.
    str: []const u8,
    /// Byte string / py2 str (BINSTRING/BINBYTES). Borrows input.
    bytes: []const u8,
    list: []Value,
    tuple: []Value,
    dict: []Pair,

    /// Convenience: text of a str or bytes value, else null.
    pub fn text(self: Value) ?[]const u8 {
        return switch (self) {
            .str => |s| s,
            .bytes => |b| b,
            else => null,
        };
    }
    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |n| n,
            else => null,
        };
    }
};

pub const Pair = struct { key: Value, val: Value };

pub const Error = error{ Unsupported, Truncated, Empty, OutOfMemory };

pub fn load(arena: std.mem.Allocator, data: []const u8) Error!Value {
    var stack: std.ArrayList(Value) = .empty;
    var marks: std.ArrayList(usize) = .empty;
    var memo: std.ArrayList(Value) = .empty;

    var i: usize = 0;
    const need = struct {
        fn n(d: []const u8, at: usize, count: usize) Error!void {
            if (at + count > d.len) return Error.Truncated;
        }
    }.n;

    while (i < data.len) {
        const op = data[i];
        i += 1;
        switch (op) {
            0x80 => {
                try need(data, i, 1);
                i += 1;
            }, // PROTO
            0x95 => {
                try need(data, i, 8);
                i += 8;
            }, // FRAME
            0x2e => break, // STOP
            0x28 => try marks.append(arena, stack.items.len), // MARK
            0x4e => try stack.append(arena, .none), // NONE
            0x88 => try stack.append(arena, .{ .boolean = true }), // NEWTRUE
            0x89 => try stack.append(arena, .{ .boolean = false }), // NEWFALSE

            // ----- ints -----
            0x4b => { // BININT1 (u8)
                try need(data, i, 1);
                try stack.append(arena, .{ .int = data[i] });
                i += 1;
            },
            0x4d => { // BININT2 (u16 LE)
                try need(data, i, 2);
                try stack.append(arena, .{ .int = std.mem.readInt(u16, data[i..][0..2], .little) });
                i += 2;
            },
            0x4a => { // BININT (i32 LE)
                try need(data, i, 4);
                try stack.append(arena, .{ .int = std.mem.readInt(i32, data[i..][0..4], .little) });
                i += 4;
            },
            0x8a => { // LONG1 (u8 len + little-endian signed)
                try need(data, i, 1);
                const n = data[i];
                i += 1;
                try need(data, i, n);
                try stack.append(arena, .{ .int = readLongLE(data[i .. i + n]) });
                i += n;
            },

            // ----- strings / bytes -----
            0x55 => try pushSlice(arena, &stack, data, &i, 1, .bytes), // SHORT_BINSTRING
            0x54 => try pushSlice(arena, &stack, data, &i, 4, .bytes), // BINSTRING
            0x8c => try pushSlice(arena, &stack, data, &i, 1, .str), // SHORT_BINUNICODE
            0x58 => try pushSlice(arena, &stack, data, &i, 4, .str), // BINUNICODE
            0x43 => try pushSlice(arena, &stack, data, &i, 1, .bytes), // SHORT_BINBYTES
            0x42 => try pushSlice(arena, &stack, data, &i, 4, .bytes), // BINBYTES

            // ----- collections -----
            0x7d => try stack.append(arena, .{ .dict = &.{} }), // EMPTY_DICT
            0x5d => try stack.append(arena, .{ .list = &.{} }), // EMPTY_LIST
            0x29 => try stack.append(arena, .{ .tuple = &.{} }), // EMPTY_TUPLE
            0x85 => try makeTuple(arena, &stack, 1), // TUPLE1
            0x86 => try makeTuple(arena, &stack, 2), // TUPLE2
            0x87 => try makeTuple(arena, &stack, 3), // TUPLE3
            0x74 => try tupleFromMark(arena, &stack, &marks), // TUPLE
            0x61 => try appendOne(arena, &stack), // APPEND
            0x65 => try appendsFromMark(arena, &stack, &marks), // APPENDS
            0x73 => try setItem(arena, &stack), // SETITEM
            0x75 => try setItemsFromMark(arena, &stack, &marks), // SETITEMS

            // ----- memo -----
            0x94 => try memoize(arena, &memo, stack.items), // MEMOIZE
            0x71 => { // BINPUT (u8 idx)
                try need(data, i, 1);
                try memoPut(arena, &memo, data[i], stack.items);
                i += 1;
            },
            0x72 => { // LONG_BINPUT (u32 idx)
                try need(data, i, 4);
                try memoPut(arena, &memo, std.mem.readInt(u32, data[i..][0..4], .little), stack.items);
                i += 4;
            },
            0x68 => { // BINGET (u8 idx)
                try need(data, i, 1);
                try stack.append(arena, memoGet(memo.items, data[i]));
                i += 1;
            },
            0x6a => { // LONG_BINGET (u32 idx)
                try need(data, i, 4);
                try stack.append(arena, memoGet(memo.items, std.mem.readInt(u32, data[i..][0..4], .little)));
                i += 4;
            },

            else => return Error.Unsupported,
        }
    }

    if (stack.items.len == 0) return Error.Empty;
    return stack.items[stack.items.len - 1];
}

fn readLongLE(b: []const u8) i64 {
    if (b.len == 0) return 0;
    var v: i64 = 0;
    var shift: u6 = 0;
    for (b) |byte| {
        v |= @as(i64, byte) << shift;
        shift +%= 8;
    }
    // Sign-extend from the top bit of the last byte.
    if (b[b.len - 1] & 0x80 != 0) {
        const bits: u7 = @intCast(b.len * 8);
        if (bits < 64) v -= (@as(i64, 1) << @intCast(bits));
    }
    return v;
}

const Tag = enum { str, bytes };

fn pushSlice(arena: std.mem.Allocator, stack: *std.ArrayList(Value), data: []const u8, i: *usize, len_bytes: u8, tag: Tag) Error!void {
    if (i.* + len_bytes > data.len) return Error.Truncated;
    const n: usize = switch (len_bytes) {
        1 => data[i.*],
        4 => std.mem.readInt(u32, data[i.*..][0..4], .little),
        else => unreachable,
    };
    i.* += len_bytes;
    if (i.* + n > data.len) return Error.Truncated;
    const s = data[i.* .. i.* + n];
    i.* += n;
    try stack.append(arena, if (tag == .str) .{ .str = s } else .{ .bytes = s });
}

fn makeTuple(arena: std.mem.Allocator, stack: *std.ArrayList(Value), n: usize) Error!void {
    if (stack.items.len < n) return Error.Truncated;
    const start = stack.items.len - n;
    const items = try arena.dupe(Value, stack.items[start..]);
    stack.shrinkRetainingCapacity(start);
    try stack.append(arena, .{ .tuple = items });
}

fn tupleFromMark(arena: std.mem.Allocator, stack: *std.ArrayList(Value), marks: *std.ArrayList(usize)) Error!void {
    const m = marks.pop() orelse return Error.Truncated;
    const items = try arena.dupe(Value, stack.items[m..]);
    stack.shrinkRetainingCapacity(m);
    try stack.append(arena, .{ .tuple = items });
}

fn appendOne(arena: std.mem.Allocator, stack: *std.ArrayList(Value)) Error!void {
    if (stack.items.len < 2) return Error.Truncated;
    const v = stack.pop().?;
    const list_idx = stack.items.len - 1;
    try appendToList(arena, &stack.items[list_idx], &.{v});
}

fn appendsFromMark(arena: std.mem.Allocator, stack: *std.ArrayList(Value), marks: *std.ArrayList(usize)) Error!void {
    const m = marks.pop() orelse return Error.Truncated;
    const extra = stack.items[m..];
    if (m == 0) return Error.Truncated;
    try appendToList(arena, &stack.items[m - 1], extra);
    stack.shrinkRetainingCapacity(m);
}

fn appendToList(arena: std.mem.Allocator, list_val: *Value, extra: []const Value) Error!void {
    const old = switch (list_val.*) {
        .list => |l| l,
        else => return Error.Unsupported,
    };
    const merged = try arena.alloc(Value, old.len + extra.len);
    @memcpy(merged[0..old.len], old);
    @memcpy(merged[old.len..], extra);
    list_val.* = .{ .list = merged };
}

fn setItem(arena: std.mem.Allocator, stack: *std.ArrayList(Value)) Error!void {
    if (stack.items.len < 3) return Error.Truncated;
    const v = stack.pop().?;
    const k = stack.pop().?;
    const dict_idx = stack.items.len - 1;
    try addPairs(arena, &stack.items[dict_idx], &.{.{ .key = k, .val = v }});
}

fn setItemsFromMark(arena: std.mem.Allocator, stack: *std.ArrayList(Value), marks: *std.ArrayList(usize)) Error!void {
    const m = marks.pop() orelse return Error.Truncated;
    if (m == 0) return Error.Truncated;
    const flat = stack.items[m..];
    if (flat.len % 2 != 0) return Error.Truncated;
    var pairs = try arena.alloc(Pair, flat.len / 2);
    var p: usize = 0;
    while (p < pairs.len) : (p += 1) {
        pairs[p] = .{ .key = flat[p * 2], .val = flat[p * 2 + 1] };
    }
    try addPairs(arena, &stack.items[m - 1], pairs);
    stack.shrinkRetainingCapacity(m);
}

fn addPairs(arena: std.mem.Allocator, dict_val: *Value, extra: []const Pair) Error!void {
    const old = switch (dict_val.*) {
        .dict => |d| d,
        else => return Error.Unsupported,
    };
    const merged = try arena.alloc(Pair, old.len + extra.len);
    @memcpy(merged[0..old.len], old);
    @memcpy(merged[old.len..], extra);
    dict_val.* = .{ .dict = merged };
}

fn memoize(arena: std.mem.Allocator, memo: *std.ArrayList(Value), stack_items: []const Value) Error!void {
    if (stack_items.len == 0) return Error.Truncated;
    try memo.append(arena, stack_items[stack_items.len - 1]);
}

fn memoPut(arena: std.mem.Allocator, memo: *std.ArrayList(Value), idx: usize, stack_items: []const Value) Error!void {
    if (stack_items.len == 0) return Error.Truncated;
    while (memo.items.len <= idx) try memo.append(arena, .none);
    memo.items[idx] = stack_items[stack_items.len - 1];
}

fn memoGet(memo: []const Value, idx: usize) Value {
    if (idx >= memo.len) return .none;
    return memo[idx];
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "load decodes an RPA-shaped index: {str: [(int,int,bytes)]}" {
    // Hand-encoded pickle (protocol 2) for:
    //   {"a.png": [(16, 100, b"")]}
    // PROTO 2; EMPTY_DICT; MARK; SHORT_BINUNICODE "a.png"; EMPTY_LIST; MARK;
    //   MARK; BININT1 16; BININT1 100; SHORT_BINBYTES "" ; TUPLE; APPENDS;
    //   SETITEMS; STOP
    const data = [_]u8{
        0x80, 0x02, // PROTO 2
        0x7d, // EMPTY_DICT
        0x28, // MARK   (for SETITEMS)
        0x8c, 0x05, 'a', '.', 'p', 'n', 'g', // SHORT_BINUNICODE "a.png"
        0x5d, // EMPTY_LIST
        0x28, // MARK   (for APPENDS)
        0x28, // MARK   (for TUPLE)
        0x4b, 0x10, // BININT1 16
        0x4b, 0x64, // BININT1 100
        0x43, 0x00, // SHORT_BINBYTES ""
        0x74, // TUPLE  (from inner MARK)
        0x65, // APPENDS (from list MARK)
        0x75, // SETITEMS (from dict MARK)
        0x2e, // STOP
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try load(arena.allocator(), &data);

    try testing.expect(root == .dict);
    try testing.expectEqual(@as(usize, 1), root.dict.len);
    try testing.expectEqualStrings("a.png", root.dict[0].key.text().?);
    const list = root.dict[0].val.list;
    try testing.expectEqual(@as(usize, 1), list.len);
    const tup = list[0].tuple;
    try testing.expectEqual(@as(usize, 3), tup.len);
    try testing.expectEqual(@as(i64, 16), tup[0].asInt().?);
    try testing.expectEqual(@as(i64, 100), tup[1].asInt().?);
    try testing.expectEqualStrings("", tup[2].text().?);
}

test "memo: BINPUT then BINGET reuses a value" {
    // {"x": []} where the empty list is memoized then... simpler: encode a
    // tuple (k, k) where k is a string put into memo and fetched back.
    // PROTO2; MARK; SHORT_BINUNICODE "k" BINPUT 0; BINGET 0; TUPLE; STOP
    const data = [_]u8{
        0x80, 0x02,
        0x28, // MARK
        0x8c, 0x01, 'k', // SHORT_BINUNICODE "k"
        0x71, 0x00, // BINPUT 0
        0x68, 0x00, // BINGET 0
        0x74, // TUPLE
        0x2e, // STOP
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try load(arena.allocator(), &data);
    try testing.expect(root == .tuple);
    try testing.expectEqual(@as(usize, 2), root.tuple.len);
    try testing.expectEqualStrings("k", root.tuple[0].text().?);
    try testing.expectEqualStrings("k", root.tuple[1].text().?);
}

test "BININT2 / BININT decode widths" {
    // tuple (300, 70000): BININT2 300; BININT 70000
    const data = [_]u8{
        0x80, 0x02,
        0x28, // MARK
        0x4d, 0x2c, 0x01, // BININT2 300
        0x4a, 0x70, 0x11, 0x01, 0x00, // BININT 70000
        0x74, 0x2e,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try load(arena.allocator(), &data);
    try testing.expectEqual(@as(i64, 300), root.tuple[0].asInt().?);
    try testing.expectEqual(@as(i64, 70000), root.tuple[1].asInt().?);
}

test "unsupported opcode is reported, not guessed" {
    const data = [_]u8{ 0x80, 0x02, 0x00 }; // 0x00 is not handled
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(Error.Unsupported, load(arena.allocator(), &data));
}

test "fuzz: pickle.load survives arbitrary input" {
    try std.testing.fuzz({}, fuzzPickleLoad, .{
        .corpus = &.{
            fuzzSeed(&.{ 0x80, 0x02, 0x7d, 0x2e }), // PROTO 2, EMPTY_DICT, STOP
            fuzzSeed(&.{ 0x80, 0x02, 0x7d, 0x28 }), // PROTO 2, EMPTY_DICT, MARK (no STOP — loop exhaustion)
            fuzzSeed("N."), // NONE, STOP
            fuzzSeed(&.{0x80}), // truncated PROTO
            // RPA-shaped index {"a.png": [(16, 100, b"")]} — exercises
            // SHORT_BINUNICODE, SHORT_BINBYTES, TUPLE/APPENDS/SETITEMS marks.
            fuzzSeed(&.{
                0x80, 0x02, // PROTO 2
                0x7d, // EMPTY_DICT
                0x28, // MARK   (for SETITEMS)
                0x8c, 0x05, 'a', '.', 'p', 'n', 'g', // SHORT_BINUNICODE "a.png"
                0x5d, // EMPTY_LIST
                0x28, // MARK   (for APPENDS)
                0x28, // MARK   (for TUPLE)
                0x4b, 0x10, // BININT1 16
                0x4b, 0x64, // BININT1 100
                0x43, 0x00, // SHORT_BINBYTES ""
                0x74, // TUPLE  (from inner MARK)
                0x65, // APPENDS (from list MARK)
                0x75, // SETITEMS (from dict MARK)
                0x2e, // STOP
            }),
        },
    });
}

fn fuzzPickleLoad(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [FUZZ_BUF_LEN]u8 = undefined;
    const n = smith.slice(&buf);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Every error in pickle.Error is an expected reject; anything else
    // (panic, overflow, OOB) is what fuzzing exists to catch.
    _ = load(arena.allocator(), buf[0..n]) catch return;
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
