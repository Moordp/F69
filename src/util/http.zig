// Minimal HTTP helper layered on `std.http.Client`. Consolidates the
// boilerplate that's been re-implemented in 5 places (`f95/client.zig`,
// `f95/auth.zig`, `downloads/rpdl.zig`, `convert/sdk_cache.zig`,
// `downloads/aria2_rpc.zig`):
//
//   - User-agent override from `build_options.version` so a release
//     bump propagates without a 5-file edit.
//   - Single ownership model: caller hands in an arena allocator + io;
//     we own the short-lived `std.http.Client` for the duration of
//     one request.
//   - Status classification: 2xx → ok, 4xx → ClientError, 5xx →
//     ServerError, network failure → NetworkError. Callers branch on
//     a tiny error set instead of re-mapping `error.UnexpectedConnect`.
//
// What this does NOT do:
//   - Streaming downloads through `fetch` — use `fetchToFile`, which
//     streams the body to disk in 64 KiB chunks and reports progress
//     (sdk_cache.fetch uses it for the 50–100 MiB SDK archives).
//   - Cookies — `f95/client.zig` keeps its rate-limit + cookie
//     middleware on top of this helper.
//   - Retries — the download manager's fallback chain handles per-source
//     retry at a higher level.

const std = @import("std");
const build_options = @import("build_options");
const ratelimit = @import("util_ratelimit");

const Io = std.Io;

pub const USER_AGENT = "f69/" ++ build_options.version;

// ----- per-host throttle -----
//
// Every one-shot fetch (rpdl, sdk_cache, f95 indexer) shares one process-
// global limiter so we don't hammer an external host from multiple worker
// threads. The F95 client and the aria2 RPC client use their own
// std.http.Client and do NOT go through here, so their cadence is unchanged.

/// Minimum spacing between requests to the same host, in ms. `0` disables
/// throttling entirely (used by tests). Tunable at runtime.
pub var min_interval_ms: u64 = 800;

var g_limiter: ratelimit.PerHostLimiter = .{};
var g_limiter_lock: Io.Mutex = .init;

/// Host component of an http(s) URL — scheme/userinfo/port/path stripped.
/// Pure + testable. Returns "" when no authority is present (the limiter
/// then keys everything under one bucket, which is harmless).
pub fn hostOf(url: []const u8) []const u8 {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    var auth_end: usize = after_scheme.len;
    for (after_scheme, 0..) |ch, i| {
        if (ch == '/' or ch == '?' or ch == '#') {
            auth_end = i;
            break;
        }
    }
    var authority = after_scheme[0..auth_end];
    if (std.mem.indexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (std.mem.indexOfScalar(u8, authority, ':')) |c| authority = authority[0..c];
    return authority;
}

fn isLocal(host: []const u8) bool {
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1");
}

/// Block until this host's next request slot is due, then return. Sleeps
/// outside the lock so concurrent callers each wait their own assigned slot
/// (PerHostLimiter spaces a burst into evenly-staggered slots) rather than
/// serializing on the mutex.
fn throttle(io: Io, url: []const u8) void {
    if (min_interval_ms == 0) return;
    const host = hostOf(url);
    if (isLocal(host)) return;

    // Units cancel in reserve(); work in ms throughout.
    const interval_ms: i128 = @intCast(min_interval_ms);
    g_limiter_lock.lockUncancelable(io);
    const now_ms: i128 = Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
    const wait_ms = g_limiter.reserve(host, now_ms, interval_ms);
    g_limiter_lock.unlock(io);

    if (wait_ms > 0) {
        io.sleep(Io.Duration.fromMilliseconds(@intCast(wait_ms)), .real) catch {};
    }
}

test "hostOf strips scheme, path, port and userinfo" {
    try std.testing.expectEqualStrings("dl.rpdl.net", hostOf("https://dl.rpdl.net/api/login"));
    try std.testing.expectEqualStrings("api.f95checker.dev", hostOf("https://api.f95checker.dev/"));
    try std.testing.expectEqualStrings("example.com", hostOf("http://example.com:8080/path?q=1"));
    try std.testing.expectEqualStrings("host.tld", hostOf("https://user:pass@host.tld/x"));
    try std.testing.expectEqualStrings("bare.host", hostOf("bare.host/no-scheme"));
    try std.testing.expectEqualStrings("a.b", hostOf("https://a.b"));
}

test "isLocal recognises loopback" {
    try std.testing.expect(isLocal("127.0.0.1"));
    try std.testing.expect(isLocal("localhost"));
    try std.testing.expect(!isLocal("dl.rpdl.net"));
}

pub const Error = error{
    NetworkError,
    ClientError,
    ServerError,
    UnexpectedStatus,
    OutOfMemory,
    /// `fetchToFile` could not create or write the destination file.
    WriteFailed,
    /// `fetchToFile`'s `Options.cancelled` hook returned true.
    Cancelled,
};

pub const Header = std.http.Header;
pub const Method = std.http.Method;

pub const Options = struct {
    method: Method = .GET,
    /// Body to send. Set non-empty for POST/PUT. `null` for bodyless
    /// methods (GET/HEAD).
    payload: ?[]const u8 = null,
    /// Headers added on top of the auto-injected user-agent.
    extra_headers: []const Header = &.{},
    /// Cap on response body size. Network adapter throws on overrun
    /// rather than allocating unbounded memory.
    max_response_bytes: usize = 16 * 1024 * 1024,
    /// Override the user-agent. Defaults to `USER_AGENT` (f69/<version>).
    user_agent: []const u8 = USER_AGENT,
    /// `fetchToFile` only: polled with its `ctx` before each body chunk.
    /// Returning true stops the download with `Error.Cancelled` (the
    /// partial file is deleted). Ignored by `fetch`.
    cancelled: ?*const fn (?*anyopaque) bool = null,
};

pub const Response = struct {
    /// Allocator-owned body. Caller frees.
    body: []u8,
    /// HTTP status code as a u16 (200, 404, etc).
    status: u16,
};

/// One-shot HTTP call. Spins up a short-lived `std.http.Client`, runs
/// the request, returns the body + status. Caller owns `body`.
pub fn fetch(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    opts: Options,
) Error!Response {
    // Space requests to the same external host (no-op for localhost / when
    // min_interval_ms == 0). Blocks the calling worker, never the UI thread.
    throttle(io, url);

    var http: std.http.Client = .{ .allocator = alloc, .io = io };
    defer http.deinit();

    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();

    const result = http.fetch(.{
        .location = .{ .url = url },
        .method = opts.method,
        .response_writer = &aw.writer,
        .payload = opts.payload,
        .headers = .{ .user_agent = .{ .override = opts.user_agent } },
        .extra_headers = opts.extra_headers,
        .keep_alive = false,
    }) catch {
        aw.deinit();
        return Error.NetworkError;
    };

    const status_u16: u16 = @intFromEnum(result.status);
    const body = aw.toOwnedSlice() catch return Error.OutOfMemory;
    if (body.len > opts.max_response_bytes) {
        alloc.free(body);
        return Error.UnexpectedStatus;
    }

    return .{ .body = body, .status = status_u16 };
}

/// Convenience: GET that returns the body + verifies a 2xx status.
/// Non-2xx → error (caller can't see the body in this path; use
/// `fetch` directly when you need the error body).
pub fn get(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
) Error![]u8 {
    const resp = try fetch(alloc, io, url, .{});
    if (resp.status >= 200 and resp.status < 300) return resp.body;
    alloc.free(resp.body);
    if (resp.status >= 400 and resp.status < 500) return Error.ClientError;
    if (resp.status >= 500) return Error.ServerError;
    return Error.UnexpectedStatus;
}

/// Called after every body chunk `fetchToFile` writes, with (bytes
/// received so far, Content-Length when the server sent one).
pub const ChunkFn = *const fn (ctx: ?*anyopaque, received: u64, total: ?u64) void;

/// Streaming GET: writes the response body to `dest_path` (created or
/// truncated) in 64 KiB chunks and calls `on_chunk(ctx, received,
/// content_length)` after each one. Returns the final HTTP status
/// (redirects are followed); the caller checks for 200. On a non-2xx
/// status no file is created. On any error the partial file is deleted.
/// `opts.payload` / `opts.method` are ignored — this is GET only.
/// `opts.max_response_bytes` caps the body (`Error.UnexpectedStatus`
/// past it, same as `fetch`).
pub fn fetchToFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    dest_path: []const u8,
    opts: Options,
    on_chunk: ?ChunkFn,
    ctx: ?*anyopaque,
) Error!u16 {
    throttle(io, url);

    var http: std.http.Client = .{ .allocator = alloc, .io = io };
    defer http.deinit();

    const uri = std.Uri.parse(url) catch return Error.NetworkError;
    var req = http.request(.GET, uri, .{
        .headers = .{
            .user_agent = .{ .override = opts.user_agent },
            // Raw bytes on disk: never let the server gzip the body in
            // transit (we would write the transfer-encoded stream).
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = opts.extra_headers,
        .keep_alive = false,
    }) catch return Error.NetworkError;
    defer req.deinit();

    req.sendBodiless() catch return Error.NetworkError;

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return Error.NetworkError;
    const status: u16 = @backingInt(response.head.status);
    if (status < 200 or status >= 300) return status;
    const content_length: ?u64 = response.head.content_length;

    var file = std.Io.Dir.cwd().createFile(io, dest_path, .{ .truncate = true }) catch return Error.WriteFailed;
    var complete = false;
    defer {
        file.close(io);
        if (!complete) std.Io.Dir.cwd().deleteFile(io, dest_path) catch {};
    }

    var wr_buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &wr_buf);

    var transfer_buf: [16 * 1024]u8 = undefined;
    const body = response.reader(&transfer_buf);

    // Heap chunk: three 64 KiB stack buffers in one frame is a lot for
    // a worker thread with a small stack.
    const chunk = alloc.alloc(u8, 64 * 1024) catch return Error.OutOfMemory;
    defer alloc.free(chunk);

    var received: u64 = 0;
    while (true) {
        if (opts.cancelled) |f| if (f(ctx)) return Error.Cancelled;
        const n = body.readSliceShort(chunk) catch return Error.NetworkError;
        if (n == 0) break;
        received += n;
        if (received > opts.max_response_bytes) return Error.UnexpectedStatus;
        fw.interface.writeAll(chunk[0..n]) catch return Error.WriteFailed;
        if (on_chunk) |cb| cb(ctx, received, content_length);
    }
    fw.interface.flush() catch return Error.WriteFailed;
    if (content_length) |len| if (received != len) return Error.NetworkError;
    complete = true;
    return status;
}

// ----- fetchToFile test: one-shot loopback server -----

const OneShotServer = struct {
    io: Io,
    server: std.Io.net.Server,
    port: u16,
    body: []const u8,
    accepted: std.atomic.Value(bool) = .init(false),

    fn serve(self: *OneShotServer) void {
        var stream = self.server.accept(self.io) catch return;
        self.accepted.store(true, .release);
        defer stream.close(self.io);
        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var sr = stream.reader(self.io, &rbuf);
        var sw = stream.writer(self.io, &wbuf);
        var hs = std.http.Server.init(&sr.interface, &sw.interface);
        var r = hs.receiveHead() catch return;
        r.respond(self.body, .{ .keep_alive = false }) catch {};
    }
};

test "fetchToFile: streams a 300 KiB body to disk with monotonic ticks ending at (len, len)" {
    const testing = std.testing;
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const body = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv: OneShotServer = .{
        .io = io,
        .server = try addr.listen(io, .{ .reuse_address = true }),
        .port = 0,
        .body = body,
    };
    defer srv.server.deinit(io);
    srv.port = srv.server.socket.address.getPort();
    const thr = try std.Thread.spawn(.{}, OneShotServer.serve, .{&srv});
    defer thr.join();
    // Runs before the join: if fetchToFile failed before it connected,
    // wake the parked accept() so the join cannot hang the test.
    defer if (!srv.accepted.load(.acquire)) {
        if (Io.net.IpAddress.parseIp4("127.0.0.1", srv.port)) |wake| {
            if (wake.connect(io, .{ .mode = .stream })) |c| {
                var st = c;
                st.close(io);
            } else |_| {}
        } else |_| {}
    };

    const Ticks = struct {
        last: u64 = 0,
        total: ?u64 = null,
        count: usize = 0,
        monotonic: bool = true,
        fn cb(c: ?*anyopaque, received: u64, total: ?u64) void {
            const self: *@This() = @ptrCast(@alignCast(c.?));
            if (received < self.last) self.monotonic = false;
            self.last = received;
            self.total = total;
            self.count += 1;
        }
    };
    var ticks: Ticks = .{};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/sdk.tar.gz", .{srv.port});
    // std.testing.tmpDir (under .zig-cache/tmp) rather than /tmp, so the
    // test also runs on the Windows VM.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_root);
    const dest = try std.fs.path.join(testing.allocator, &.{ tmp_root, "sdk.tar.gz.part" });
    defer testing.allocator.free(dest);

    const status = try fetchToFile(testing.allocator, io, url, dest, .{}, Ticks.cb, &ticks);
    try testing.expectEqual(@as(u16, 200), status);
    try testing.expect(ticks.monotonic);
    try testing.expect(ticks.count >= 2);
    try testing.expectEqual(@as(u64, body.len), ticks.last);
    try testing.expectEqual(@as(?u64, body.len), ticks.total);

    const got = try std.Io.Dir.cwd().readFileAlloc(io, dest, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, body, got);
}
