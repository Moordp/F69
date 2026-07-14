//! aria2 JSON-RPC wire helpers — pure (no IO), so the envelope format and
//! event decoding are unit-tested independently of any transport. Both the
//! WebSocket and HTTP transports build requests with `buildCall`, surface
//! aria2 errors with `extractError`, and (WS) decode pushed events with
//! `parseNotification`.
//!
//! aria2 requires the RPC secret as the first param of every call,
//! formatted `token:<secret>`. `buildCall` injects it so callers never
//! hand-format the token.

const std = @import("std");

/// Build a JSON-RPC 2.0 request body for `aria2.<method>`. `inner_params`
/// is the comma-joined JSON for the args AFTER the secret token (e.g.
/// `"\"http://x\",{\"dir\":\"/d\"}"`), or "" for a token-only call. Caller
/// owns the returned bytes.
pub fn buildCall(
    alloc: std.mem.Allocator,
    id: []const u8,
    method: []const u8,
    secret: []const u8,
    inner_params: []const u8,
) error{OutOfMemory}![]u8 {
    if (inner_params.len == 0) {
        return std.fmt.allocPrint(
            alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"method\":\"{s}\",\"params\":[\"token:{s}\"]}}",
            .{ id, method, secret },
        );
    }
    return std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"method\":\"{s}\",\"params\":[\"token:{s}\",{s}]}}",
        .{ id, method, secret, inner_params },
    );
}

pub const RpcError = struct {
    code: i64,
    /// Owned by the caller's allocator.
    message: []u8,
};

/// If `body` carries a JSON-RPC `error` object, return it (message duped
/// into `alloc`). Returns null when there's no structured error (caller
/// then parses `result`). Malformed JSON → null (caller treats a body with
/// neither a parseable result nor an error as invalid).
pub fn extractError(alloc: std.mem.Allocator, body: []const u8) ?RpcError {
    const Shape = struct {
        @"error": ?struct {
            code: i64 = 0,
            message: []const u8 = "",
        } = null,
    };
    var parsed = std.json.parseFromSlice(Shape, alloc, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const e = parsed.value.@"error" orelse return null;
    const msg = alloc.dupe(u8, e.message) catch return null;
    return .{ .code = e.code, .message = msg };
}

pub const Notification = struct {
    /// Full method, e.g. "aria2.onDownloadComplete". Owned by `alloc`.
    method: []u8,
    /// The affected download's gid. Owned by `alloc`.
    gid: []u8,
};

/// Decode an aria2 push notification:
///   {"jsonrpc":"2.0","method":"aria2.onDownloadComplete","params":[{"gid":"2089b..."}]}
/// Returns null when `body` isn't a notification (no method, or a normal
/// id-bearing response). Caller owns `method`/`gid`.
pub fn parseNotification(alloc: std.mem.Allocator, body: []const u8) ?Notification {
    const Shape = struct {
        method: ?[]const u8 = null,
        id: ?std.json.Value = null,
        params: ?[]const struct { gid: []const u8 = "" } = null,
    };
    var parsed = std.json.parseFromSlice(Shape, alloc, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    // A notification has a method and NO id. Responses have an id, no method.
    if (parsed.value.id != null) return null;
    const method = parsed.value.method orelse return null;
    const params = parsed.value.params orelse return null;
    if (params.len == 0) return null;

    const m = alloc.dupe(u8, method) catch return null;
    const g = alloc.dupe(u8, params[0].gid) catch {
        alloc.free(m);
        return null;
    };
    return .{ .method = m, .gid = g };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "buildCall injects the secret token; with and without extra params" {
    const a = try buildCall(testing.allocator, "7", "aria2.tellStatus", "S3CR", "\"abc\"");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"7\",\"method\":\"aria2.tellStatus\",\"params\":[\"token:S3CR\",\"abc\"]}",
        a,
    );

    const b = try buildCall(testing.allocator, "1", "aria2.getGlobalStat", "S3CR", "");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.getGlobalStat\",\"params\":[\"token:S3CR\"]}",
        b,
    );
}

test "extractError surfaces aria2 error objects, else null" {
    const err = extractError(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"error\":{\"code\":1,\"message\":\"Unauthorized\"}}");
    try testing.expect(err != null);
    defer testing.allocator.free(err.?.message);
    try testing.expectEqual(@as(i64, 1), err.?.code);
    try testing.expectEqualStrings("Unauthorized", err.?.message);

    try testing.expect(extractError(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":\"OK\"}") == null);
    try testing.expect(extractError(testing.allocator, "not json") == null);
}

test "parseNotification decodes pushed events, ignores responses" {
    const n = parseNotification(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"aria2.onDownloadComplete\",\"params\":[{\"gid\":\"2089b05ecca3d829\"}]}");
    try testing.expect(n != null);
    defer {
        testing.allocator.free(n.?.method);
        testing.allocator.free(n.?.gid);
    }
    try testing.expectEqualStrings("aria2.onDownloadComplete", n.?.method);
    try testing.expectEqualStrings("2089b05ecca3d829", n.?.gid);

    // A normal response (has id, no method) is not a notification.
    try testing.expect(parseNotification(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"5\",\"result\":[]}") == null);
    // Malformed → null.
    try testing.expect(parseNotification(testing.allocator, "{oops") == null);
}

test "fuzz: rpc response parsers survive arbitrary bodies" {
    try std.testing.fuzz({}, fuzzRpcParsers, .{ .corpus = &.{
        fuzzSeed("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":1,\"message\":\"x\"},\"id\":\"1\"}"),
        fuzzSeed("{\"method\":\"aria2.onDownloadComplete\",\"params\":[{\"gid\":\"abc123\"}]}"),
        fuzzSeed("{}"),
        fuzzSeed("not json at all"),
    } });
}

fn fuzzRpcParsers(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [FUZZ_BUF_LEN]u8 = undefined;
    const n = smith.slice(&buf);
    const body = buf[0..n];
    const a = std.testing.allocator;

    // RpcError.message is duped into `a` (extractError, alloc.dupe of e.message);
    // Notification.method and .gid are both duped into `a` (parseNotification).
    if (extractError(a, body)) |e| a.free(e.message);
    if (parseNotification(a, body)) |note| {
        a.free(note.method);
        a.free(note.gid);
    }
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
