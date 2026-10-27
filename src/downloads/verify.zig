// SHA-256 verification of downloaded archives. Streamed so we don't
// re-read large files into memory.

const std = @import("std");
const Io = std.Io;
const errs = @import("errors.zig");

pub const Hasher = struct {
    inner: std.crypto.hash.sha2.Sha256,

    pub fn init() Hasher {
        return .{ .inner = std.crypto.hash.sha2.Sha256.init(.{}) };
    }

    pub fn update(self: *Hasher, bytes: []const u8) void {
        self.inner.update(bytes);
    }

    pub fn finalize(self: *Hasher) [32]u8 {
        var out: [32]u8 = undefined;
        self.inner.final(&out);
        return out;
    }
};

/// Stream the file at `path` through SHA-256 and compare to `expected`.
/// Returns `HashMismatch` on any difference (or on file read errors —
/// surface a clean signal rather than two distinct fail modes).
pub fn verifyFile(io: Io, path: []const u8, expected: [32]u8) errs.Error!void {
    var f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return errs.Error.HashMismatch;
    defer f.close(io);

    var rd_buf: [64 * 1024]u8 = undefined;
    var fr = f.reader(io, &rd_buf);

    var hasher = Hasher.init();
    while (true) {
        var chunk: [64 * 1024]u8 = undefined;
        const got = fr.interface.readSliceShort(&chunk) catch return errs.Error.HashMismatch;
        if (got == 0) break;
        hasher.update(chunk[0..got]);
    }

    const got_hash = hasher.finalize();
    if (!std.mem.eql(u8, &got_hash, &expected)) return errs.Error.HashMismatch;
}

/// Pure. Decode a 64-char lowercase-hex SHA-256 into 32 bytes.
pub fn hexDecode(hex: []const u8) errs.Error![32]u8 {
    if (hex.len != 64) return errs.Error.HashMismatch;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return errs.Error.HashMismatch;
    return out;
}

// ============================================================
//  tests
// ============================================================

const testing = std.testing;
const test_env = @import("util_test_env");

test "Hasher: empty input" {
    var h = Hasher.init();
    const got = h.finalize();
    // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    const want = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };
    try testing.expectEqualSlices(u8, &want, &got);
}

test "Hasher: 'abc'" {
    var h = Hasher.init();
    h.update("abc");
    const got = h.finalize();
    // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    const want = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    try testing.expectEqualSlices(u8, &want, &got);
}

test "hexDecode: happy path" {
    const v = try hexDecode("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try testing.expectEqual(@as(u8, 0xba), v[0]);
    try testing.expectEqual(@as(u8, 0xad), v[31]);
}

test "hexDecode: wrong length" {
    try testing.expectError(errs.Error.HashMismatch, hexDecode("short"));
}

test "hexDecode: non-hex char" {
    try testing.expectError(errs.Error.HashMismatch, hexDecode("zz7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
}

test "verifyFile: hash matches" {
    var env = try test_env.TestEnv.init(testing.allocator, "verify-hit");
    defer env.deinit();

    try env.writeFile("data", "abc");
    const path = try env.path("data");
    defer testing.allocator.free(path);

    const expected = try hexDecode("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try verifyFile(env.io, path, expected);
}

test "verifyFile: hash mismatch" {
    var env = try test_env.TestEnv.init(testing.allocator, "verify-miss");
    defer env.deinit();

    try env.writeFile("data", "def");
    const path = try env.path("data");
    defer testing.allocator.free(path);

    // sha256 of "abc"
    const expected = try hexDecode("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try testing.expectError(errs.Error.HashMismatch, verifyFile(env.io, path, expected));
}

test "verifyFile: missing file → HashMismatch" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const empty: [32]u8 = @splat(0);
    try testing.expectError(errs.Error.HashMismatch, verifyFile(io, "/nonexistent-asdf", empty));
}
