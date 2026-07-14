//! RPG Maker MV/MZ asset decryption — the core of the "decrypt RPGM mod"
//! tool. RPG Maker "encrypts" audio/image assets (.rpgmvp/.rpgmvo/.png_/
//! .ogg_/.m4a_) by prepending a 16-byte fake header and XOR-ing the real
//! file's first 16 bytes with a per-game key (System.json `encryptionKey`,
//! 32 hex chars). Everything past byte 32 is the original file untouched.
//!
//! Pure (no IO) so the (de)cipher + key parsing are unit-tested directly;
//! the recipe `decrypt_rpgm` step walks the staged tree and calls `decrypt`.

const std = @import("std");

pub const HEADER_LEN = 16;
pub const KEY_LEN = 16;

/// RPG Maker's fake-header signature: "RPGMV\0\0\0" + a version stamp. We
/// only match the "RPGMV" prefix — the trailing bytes vary by version.
const SIGNATURE = "RPGMV";

/// True if `data` carries the RPG Maker encrypted-asset header.
pub fn isEncrypted(data: []const u8) bool {
    return data.len >= HEADER_LEN and std.mem.startsWith(u8, data, SIGNATURE);
}

/// Parse a 32-hex-char `encryptionKey` into 16 raw bytes. Returns null on
/// the wrong length or a non-hex digit.
pub fn parseKey(hex: []const u8) ?[KEY_LEN]u8 {
    if (hex.len != KEY_LEN * 2) return null;
    var key: [KEY_LEN]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, hex) catch return null;
    return key;
}

/// Pull the `encryptionKey` out of a System.json blob and parse it.
pub fn keyFromSystemJson(alloc: std.mem.Allocator, json: []const u8) ?[KEY_LEN]u8 {
    const Shape = struct { encryptionKey: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(Shape, alloc, json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const hex = parsed.value.encryptionKey orelse return null;
    return parseKey(hex);
}

/// Decrypt an encrypted RPG Maker asset: drop the 16-byte fake header, XOR
/// the next 16 bytes with `key`, leave the rest. Returns a fresh buffer
/// (caller owns). Output length = input − 16.
pub fn decrypt(alloc: std.mem.Allocator, data: []const u8, key: [KEY_LEN]u8) error{ NotEncrypted, OutOfMemory }![]u8 {
    if (!isEncrypted(data)) return error.NotEncrypted;
    const body = data[HEADER_LEN..];
    const out = alloc.alloc(u8, body.len) catch return error.OutOfMemory;
    @memcpy(out, body);
    const n = @min(KEY_LEN, out.len);
    for (0..n) |i| out[i] ^= key[i];
    return out;
}

/// Inverse of `decrypt` — only used by tests (and potentially a future
/// re-encrypt tool). Prepends the signature header and XORs the first 16
/// plaintext bytes with `key`.
pub fn encrypt(alloc: std.mem.Allocator, plain: []const u8, key: [KEY_LEN]u8) error{OutOfMemory}![]u8 {
    const out = alloc.alloc(u8, plain.len + HEADER_LEN) catch return error.OutOfMemory;
    @memset(out[0..HEADER_LEN], 0);
    @memcpy(out[0..SIGNATURE.len], SIGNATURE);
    @memcpy(out[HEADER_LEN..], plain);
    const n = @min(KEY_LEN, plain.len);
    for (0..n) |i| out[HEADER_LEN + i] ^= key[i];
    return out;
}

/// Encrypted-asset extension → decrypted extension. RPG Maker uses both the
/// `.rpgmv*` family (MV) and the `*_` trailing-underscore family (some MZ /
/// repacks).
const EXT_MAP = [_]struct { enc: []const u8, dec: []const u8 }{
    .{ .enc = ".rpgmvp", .dec = ".png" },
    .{ .enc = ".rpgmvo", .dec = ".ogg" },
    .{ .enc = ".rpgmvm", .dec = ".m4a" },
    .{ .enc = ".png_", .dec = ".png" },
    .{ .enc = ".ogg_", .dec = ".ogg" },
    .{ .enc = ".m4a_", .dec = ".m4a" },
};

/// If `name` is an encrypted RPG Maker asset, write its decrypted filename
/// into `buf` and return it; otherwise null. Case-insensitive on the suffix.
pub fn decryptedName(buf: []u8, name: []const u8) ?[]const u8 {
    for (EXT_MAP) |m| {
        if (name.len <= m.enc.len) continue;
        const suffix = name[name.len - m.enc.len ..];
        if (!std.ascii.eqlIgnoreCase(suffix, m.enc)) continue;
        const stem = name[0 .. name.len - m.enc.len];
        if (stem.len + m.dec.len > buf.len) return null;
        @memcpy(buf[0..stem.len], stem);
        @memcpy(buf[stem.len .. stem.len + m.dec.len], m.dec);
        return buf[0 .. stem.len + m.dec.len];
    }
    return null;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "decryptedName maps encrypted asset extensions" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Actor1.png", decryptedName(&buf, "Actor1.rpgmvp").?);
    try testing.expectEqualStrings("bgm.ogg", decryptedName(&buf, "bgm.rpgmvo").?);
    try testing.expectEqualStrings("se.m4a", decryptedName(&buf, "se.rpgmvm").?);
    try testing.expectEqualStrings("pic.png", decryptedName(&buf, "pic.png_").?);
    try testing.expect(decryptedName(&buf, "readme.txt") == null);
    try testing.expect(decryptedName(&buf, "plain.png") == null);
}

test "parseKey accepts 32 hex chars, rejects junk" {
    const k = parseKey("0123456789abcdef0123456789abcdef").?;
    try testing.expectEqual(@as(u8, 0x01), k[0]);
    try testing.expectEqual(@as(u8, 0xef), k[15]);
    try testing.expect(parseKey("tooshort") == null);
    try testing.expect(parseKey("zz23456789abcdef0123456789abcdef") == null);
}

test "keyFromSystemJson extracts the key" {
    const json = "{\"encryptionKey\":\"0123456789abcdef0123456789abcdef\",\"other\":1}";
    const k = keyFromSystemJson(testing.allocator, json).?;
    try testing.expectEqual(@as(u8, 0x01), k[0]);
    try testing.expect(keyFromSystemJson(testing.allocator, "{\"no\":\"key\"}") == null);
}

test "encrypt → decrypt round-trips and isEncrypted gates" {
    const key = parseKey("d41d8cd98f00b204e9800998ecf8427e").?;
    const plain = "\x89PNG\r\n\x1a\n....actual image bytes follow....and more";

    try testing.expect(!isEncrypted(plain));
    const enc = try encrypt(testing.allocator, plain, key);
    defer testing.allocator.free(enc);
    try testing.expect(isEncrypted(enc));
    try testing.expectEqual(plain.len + HEADER_LEN, enc.len);

    const dec = try decrypt(testing.allocator, enc, key);
    defer testing.allocator.free(dec);
    try testing.expectEqualStrings(plain, dec);

    try testing.expectError(error.NotEncrypted, decrypt(testing.allocator, plain, key));
}

test "decrypt handles assets shorter than the 16-byte key window" {
    const key = parseKey("ffffffffffffffffffffffffffffffff").?;
    const plain = "tiny"; // < KEY_LEN after header
    const enc = try encrypt(testing.allocator, plain, key);
    defer testing.allocator.free(enc);
    const dec = try decrypt(testing.allocator, enc, key);
    defer testing.allocator.free(dec);
    try testing.expectEqualStrings(plain, dec);
}

test "fuzz: rpgm encrypt/decrypt round-trip" {
    // Multi-call Smith stream — no hand-encoded corpus (fuzzSeed only fits
    // single-slice harnesses); the automatic empty-input run is the replay
    // smoke test.
    try std.testing.fuzz({}, fuzzRpgmRoundTrip, .{});
}

fn fuzzRpgmRoundTrip(_: void, smith: *std.testing.Smith) anyerror!void {
    var key: [KEY_LEN]u8 = undefined;
    smith.bytes(&key);
    var buf: [2048]u8 = undefined;
    const n = smith.slice(&buf);
    const plain = buf[0..n];
    const a = std.testing.allocator;

    const enc = try encrypt(a, plain, key);
    defer a.free(enc);
    try std.testing.expect(isEncrypted(enc));

    const dec = try decrypt(a, enc, key);
    defer a.free(dec);
    try std.testing.expectEqualSlices(u8, plain, dec);
}

test "fuzz: rpgm parsers survive arbitrary input" {
    try std.testing.fuzz({}, fuzzRpgmParsers, .{ .corpus = &.{
        fuzzSeed("00112233445566778899aabbccddeeff"),
        fuzzSeed("{\"encryptionKey\":\"00112233445566778899aabbccddeeff\"}"),
        fuzzSeed("picture.rpgmvp"),
    } });
}

/// Harness read-buffer length. fuzzSeed payloads must fit this, or Smith's
/// decode silently rejects the length and replays the seed as empty.
const FUZZ_BUF_LEN = 1024;

fn fuzzRpgmParsers(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [FUZZ_BUF_LEN]u8 = undefined;
    const n = smith.slice(&buf);
    const data = buf[0..n];

    _ = isEncrypted(data);
    _ = parseKey(data);
    _ = keyFromSystemJson(std.testing.allocator, data);

    var name_buf: [FUZZ_BUF_LEN]u8 = undefined;
    _ = decryptedName(&name_buf, data);

    // decrypt on arbitrary (mostly non-encrypted) data must reject cleanly.
    const key: [KEY_LEN]u8 = @splat(0xAA);
    if (decrypt(std.testing.allocator, data, key)) |d| {
        std.testing.allocator.free(d);
    } else |_| {}
}

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
