// F95Zone HTTP client — single chokepoint for everything that hits
// f95zone.to. Centralizes rate-limit (1500ms between requests by default)
// and auth cookie handling.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.f95_client);
const errs = @import("errors.zig");

pub const BASE_URL = "https://f95zone.to";
pub const USER_AGENT = "f69/" ++ @import("build_options").version;

pub const Client = struct {
    alloc: std.mem.Allocator,
    io: Io,
    http: std.http.Client,
    rate_limit_ms: u64,
    /// Serializes calls to `waitRateLimit` so two racing callers can't
    /// both observe the same stale timestamp. Held across the sleep.
    rate_lock: Io.Mutex = .init,
    last_request_ms: i64 = 0,
    /// Separate lock for cookie state. Distinct from `rate_lock` so a
    /// `setCookie` call doesn't block waiting on a 1.5s rate sleep, and
    /// the in-flight HTTP fetch holds neither lock during the network
    /// round-trip (it only borrows a duped copy of the cookie).
    cookie_lock: Io.Mutex = .init,
    cookie: ?[]const u8 = null,
    /// Serializes `self.http.fetch` calls. `std.http.Client` is NOT
    /// thread-safe — its `connection_pool` (the `used`/`free` lists) is
    /// mutated on every open/close, so two worker threads fetching through
    /// the one shared client race the pool and one nulls a connection the
    /// other is about to flush → `req.connection.?` panic (seen from image
    /// cover fetches racing a scrape). Held across the whole fetch. This
    /// serializes HTTP, but forum requests are already 1.5s-rate-limited
    /// and CDN image workers still parallelize decode/write around it;
    /// re-scanning the CA bundle per request (the per-client alternative)
    /// would be far costlier.
    http_lock: Io.Mutex = .init,
    /// Longest one request may take, connect to last byte. `std.http.Client`
    /// has no read timeout, so a connection that goes silent mid-request
    /// blocked a sync forever (stuck on one game for 8+ minutes).
    request_timeout_ms: u64 = 45_000,

    pub fn init(alloc: std.mem.Allocator, io: Io, rate_limit_ms: u64) Client {
        return .{
            .alloc = alloc,
            .io = io,
            .http = .{ .allocator = alloc, .io = io },
            .rate_limit_ms = rate_limit_ms,
        };
    }

    pub fn deinit(self: *Client) void {
        // Tear down the std `http.Client` only when the connection
        // pool is idle. stdlib's `http.Client.deinit` asserts the
        // pool is empty in Debug and abort()s when it isn't —
        // detached worker threads (sync / bookmarks / update-check)
        // can leave connections in `used` if they're still mid-fetch
        // at process exit. When that happens we leak the http
        // internals; the kernel reclaims the sockets and the
        // DebugAllocator emits a few cert-bundle leak lines that we
        // accept as the cost of not waiting forever for a network
        // call to time out. The common case (quit with no workers
        // active) does the full deinit cleanly.
        if (self.http.connection_pool.used.first == null) {
            self.http.deinit();
        }
        if (self.cookie) |c| self.alloc.free(c);
        self.* = undefined;
    }

    pub fn setCookie(self: *Client, cookie: []const u8) errs.Error!void {
        const dup = self.alloc.dupe(u8, cookie) catch return errs.Error.OutOfMemory;
        self.cookie_lock.lockUncancelable(self.io);
        defer self.cookie_lock.unlock(self.io);
        if (self.cookie) |old| self.alloc.free(old);
        self.cookie = dup;
    }

    /// Drop the stored cookie. Acquires `cookie_lock` first so worker
    /// threads that are mid-snapshot (see the request paths below)
    /// can't observe a half-cleared optional or a freed pointer.
    pub fn clearCookie(self: *Client) void {
        self.cookie_lock.lockUncancelable(self.io);
        defer self.cookie_lock.unlock(self.io);
        if (self.cookie) |old| {
            self.cookie = null;
            self.alloc.free(old);
        }
    }

    /// Lock-protected "is a cookie set?" probe. Returns the same bit
    /// the request path checks. Cheap when the lock is uncontended.
    pub fn hasCookie(self: *Client) bool {
        self.cookie_lock.lockUncancelable(self.io);
        defer self.cookie_lock.unlock(self.io);
        return self.cookie != null;
    }

    /// Accept header for image fetches. Pinned to formats stb_image
    /// (the decoder dvui uses) understands. Without this, Cloudflare's
    /// Polish layer happily returns AVIF/WebP for `attachments.f95zone.to`
    /// URLs and stb fails with "Image not of any known type, or corrupt".
    pub const IMAGE_ACCEPT = "image/jpeg,image/png,image/gif,image/bmp;q=0.5";

    /// GET the URL after honoring the forum rate limit. Caller frees
    /// the body.
    ///
    /// Transient 5xx responses are retried up to 3 times with linear
    /// backoff (1s, 2s, 3s) before surfacing `ServerError`. 4xx errors
    /// surface immediately with the most specific category we can
    /// classify — `AuthRequired` (401/403), `NotFound` (404),
    /// `RateLimited` (429), `HttpStatusError` (other).
    pub fn get(self: *Client, url: []const u8) errs.Error![]u8 {
        return self.getWithAccept(url, null);
    }

    /// GET an image URL. Pins the Accept header so Cloudflare can't
    /// transcode the response to AVIF/WebP behind our back, and
    /// skips the forum rate limit — `attachments.f95zone.to` is the
    /// Cloudflare CDN, not the rate-sensitive forum API, so it
    /// happily serves us images back-to-back without a 1.5 s gap.
    pub fn getImage(self: *Client, url: []const u8) errs.Error![]u8 {
        return self.getWithAccept(url, IMAGE_ACCEPT);
    }

    fn getWithAccept(self: *Client, url: []const u8, accept: ?[]const u8) errs.Error![]u8 {
        return self.getWithAcceptOpts(url, accept, true);
    }

    /// `forum` = attach the session cookie and wait for the rate limit
    /// (the rate limit is skipped for CDN URLs either way).
    fn getWithAcceptOpts(self: *Client, url: []const u8, accept: ?[]const u8, forum: bool) errs.Error![]u8 {
        log.debug("GET {s}", .{url});
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const result = self.getOnce(url, accept, forum) catch |e| switch (e) {
                errs.Error.ServerError => {
                    if (attempt + 1 >= 3) {
                        log.warn("GET 5xx after {d} attempts, giving up: {s}", .{ attempt + 1, url });
                        return e;
                    }
                    const wait_s: u64 = attempt + 1;
                    log.warn("GET 5xx attempt {d}/3 for {s}; backing off {d}s", .{ attempt + 1, url, wait_s });
                    self.io.sleep(Io.Duration.fromSeconds(@intCast(wait_s)), .real) catch {};
                    continue;
                },
                errs.Error.NetworkError => {
                    // Most commonly fires when F95's CDN closes the
                    // keep-alive connection between the thread page GET
                    // and the first image GET — std.http surfaces it as
                    // `HttpConnectionClosing`. The fix is to just open
                    // a fresh connection. Retry up to 3 times with a
                    // very short backoff so the user doesn't notice.
                    if (attempt + 1 >= 3) {
                        log.warn("GET network error after {d} attempts, giving up: {s}", .{ attempt + 1, url });
                        return e;
                    }
                    log.info("GET network error attempt {d}/3 for {s}; retrying", .{ attempt + 1, url });
                    self.io.sleep(Io.Duration.fromMilliseconds(200), .real) catch {};
                    continue;
                },
                else => return e,
            };
            return result;
        }
    }

    fn getOnce(self: *Client, url: []const u8, accept: ?[]const u8, forum: bool) errs.Error![]u8 {
        // Only throttle forum-domain requests. Image fetches go to
        // `attachments.f95zone.to`, a Cloudflare-fronted asset host
        // that doesn't share the forum's rate budget — serializing
        // them at 1.5 s/image turned a 10-screenshot sync into a
        // 17-second wait for no reason.
        if (forum and !isCdnUrl(url)) self.waitRateLimit();

        // Snapshot the cookie under its lock so a concurrent `setCookie`
        // can't free the slice mid-fetch. The dupe is freed below.
        const cookie_snapshot: ?[]u8 = if (forum) self.cookieSnapshot() catch return errs.Error.OutOfMemory else null;
        defer if (cookie_snapshot) |c| self.alloc.free(c);

        var aw: Io.Writer.Allocating = .init(self.alloc);
        errdefer aw.deinit();

        var hdr_buf: [2]std.http.Header = undefined;
        var hdr_n: usize = 0;
        if (cookie_snapshot) |c| {
            hdr_buf[hdr_n] = .{ .name = "cookie", .value = c };
            hdr_n += 1;
        }
        if (accept) |a| {
            hdr_buf[hdr_n] = .{ .name = "accept", .value = a };
            hdr_n += 1;
        }
        const extra_headers: []const std.http.Header = hdr_buf[0..hdr_n];

        self.http_lock.lockUncancelable(self.io);
        defer self.http_lock.unlock(self.io);
        const result = self.fetchGuarded(.{
            .location = .{ .url = url },
            .response_writer = &aw.writer,
            .headers = .{ .user_agent = .{ .override = USER_AGENT } },
            .extra_headers = extra_headers,
            // No keep-alive for CDN image bursts: Cloudflare closes pooled
            // connections between our GETs, and reusing a dead pooled
            // connection can panic inside std.http.Client.fetch (null
            // req.connection on the flush path — reported from the field,
            // user crash in indexerWorker cover fetch). A fresh connection
            // per CDN request removes that path; forum-domain requests are
            // 1.5s-rate-limited anyway, so pooling bought nothing there
            // either.
            .keep_alive = false,
        }) catch |e| {
            log.warn("GET network error ({s}): {s}", .{ @errorName(e), url });
            return errs.Error.NetworkError;
        };

        const code: u16 = @intFromEnum(result.status);
        if (result.status != .ok) {
            log.warn("GET status {d}: {s}", .{ code, url });
            return classifyStatus(code);
        }
        const body = aw.toOwnedSlice() catch return errs.Error.OutOfMemory;
        log.debug("GET ok: {d} bytes from {s}", .{ body.len, url });
        return body;
    }

    /// POST a form-encoded body to a forum-domain URL. Honors the
    /// rate limit, attaches the session cookie + standard
    /// `application/x-www-form-urlencoded` content type. Returns the
    /// response body on 2xx; classifies non-2xx the same way as `get`.
    /// Caller frees the body.
    pub fn postForm(self: *Client, url: []const u8, body: []const u8) errs.Error![]u8 {
        const reply = try self.postRaw(url, body, &.{}, true);
        if (reply.status != 200) {
            self.alloc.free(reply.body);
            log.warn("POST status {d}: {s}", .{ reply.status, url });
            return classifyStatus(reply.status);
        }
        log.debug("POST ok: {d} bytes from {s}", .{ reply.body.len, url });
        return reply.body;
    }

    /// Status code plus body (owned by `Client.alloc`).
    pub const Reply = struct { status: u16, body: []u8 };

    /// Like `postForm`, plus `extra_headers` ("Name: value" lines, at most
    /// `MAX_EXTRA_HEADERS`; an `Accept` line replaces the default). The
    /// reply comes back for every status, so the caller reads it (F95's
    /// masked-link endpoint answers JSON or an HTML captcha page). The
    /// session cookie goes only to f95zone.to hosts. Caller frees `body`
    /// with `Client.alloc`.
    pub fn postFormWith(self: *Client, url: []const u8, body: []const u8, extra_headers: []const []const u8) errs.Error!Reply {
        return self.postRaw(url, body, extra_headers, isF95Url(url));
    }

    pub const MAX_EXTRA_HEADERS = 6;

    fn postRaw(self: *Client, url: []const u8, body: []const u8, extra: []const []const u8, send_cookie: bool) errs.Error!Reply {
        if (extra.len > MAX_EXTRA_HEADERS) return errs.Error.HttpStatusError;
        if (!isCdnUrl(url)) self.waitRateLimit();

        const cookie_snapshot: ?[]u8 = if (send_cookie) self.cookieSnapshot() catch return errs.Error.OutOfMemory else null;
        defer if (cookie_snapshot) |c| self.alloc.free(c);

        var aw: Io.Writer.Allocating = .init(self.alloc);
        errdefer aw.deinit();

        var hdr_buf: [3 + MAX_EXTRA_HEADERS]std.http.Header = undefined;
        var hdr_n: usize = 0;
        hdr_buf[hdr_n] = .{ .name = "content-type", .value = "application/x-www-form-urlencoded" };
        hdr_n += 1;
        var has_accept = false;
        for (extra) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " ");
            if (name.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(name, "accept")) has_accept = true;
            hdr_buf[hdr_n] = .{ .name = name, .value = std.mem.trim(u8, line[colon + 1 ..], " ") };
            hdr_n += 1;
        }
        if (!has_accept) {
            hdr_buf[hdr_n] = .{ .name = "accept", .value = "application/json, text/plain, */*" };
            hdr_n += 1;
        }
        if (cookie_snapshot) |c| {
            hdr_buf[hdr_n] = .{ .name = "cookie", .value = c };
            hdr_n += 1;
        }
        const extra_headers: []const std.http.Header = hdr_buf[0..hdr_n];

        self.http_lock.lockUncancelable(self.io);
        defer self.http_lock.unlock(self.io);
        const result = self.fetchGuarded(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .response_writer = &aw.writer,
            .headers = .{ .user_agent = .{ .override = USER_AGENT } },
            .extra_headers = extra_headers,
            // Same rationale as getOnce: the POST-payload path in
            // std.http.Client.fetch flushes `req.connection.?` directly, so
            // a dead pooled connection is a panic, not an error.
            .keep_alive = false,
        }) catch |e| {
            log.warn("POST network error ({s}): {s}", .{ @errorName(e), url });
            return errs.Error.NetworkError;
        };

        const out = aw.toOwnedSlice() catch return errs.Error.OutOfMemory;
        return .{ .status = @intFromEnum(result.status), .body = out };
    }

    /// Owned copy of the cookie taken under its lock, or null.
    fn cookieSnapshot(self: *Client) error{OutOfMemory}!?[]u8 {
        self.cookie_lock.lockUncancelable(self.io);
        defer self.cookie_lock.unlock(self.io);
        const c = self.cookie orelse return null;
        return try self.alloc.dupe(u8, c);
    }

    /// `Cookie: <cookie>` formatted into `buf` under the cookie lock, for
    /// callers that hand the header to another program (aria2 fetching an
    /// F95 attachment). Null when signed out or `buf` is too small. Never
    /// log the result.
    pub fn cookieHeader(self: *Client, buf: []u8) ?[]const u8 {
        self.cookie_lock.lockUncancelable(self.io);
        defer self.cookie_lock.unlock(self.io);
        const c = self.cookie orelse return null;
        return std.fmt.bufPrint(buf, "Cookie: {s}", .{c}) catch null;
    }

    /// GET for the download resolver: the session cookie goes only to
    /// f95zone.to hosts, and only forum URLs wait for the rate limit, so a
    /// file host never sees the F95 session. Same retries and status
    /// mapping as `get`. Caller frees the body.
    pub fn getScoped(self: *Client, url: []const u8) errs.Error![]u8 {
        return self.getWithAcceptOpts(url, null, isF95Url(url));
    }

    /// True when the URL's host is f95zone.to or one of its subdomains.
    pub fn isF95Url(url: []const u8) bool {
        const after = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else return false;
        var end: usize = 0;
        while (end < after.len and after[end] != '/' and after[end] != ':' and after[end] != '?' and after[end] != '#') : (end += 1) {}
        const host = after[0..end];
        // Userinfo ("user@host") would hide the real host: refuse it.
        if (std.mem.indexOfScalar(u8, host, '@') != null) return false;
        return std.ascii.eqlIgnoreCase(host, "f95zone.to") or
            (host.len > ".f95zone.to".len and std.ascii.endsWithIgnoreCase(host, ".f95zone.to"));
    }

    const GuardEvent = union(enum) {
        fetch: std.http.Client.FetchError!std.http.Client.FetchResult,
        timer: Io.Cancelable!void,
    };
    const GuardError = std.http.Client.FetchError || error{RequestTimedOut};

    fn guardTimer(io: Io, ms: u64) Io.Cancelable!void {
        return io.sleep(Io.Duration.fromMilliseconds(@intCast(ms)), .real);
    }

    /// `http.fetch` raced against a timer. Whichever ends first wins; the
    /// loser is cancelled (cancel interrupts the blocked socket read).
    /// Caller holds `http_lock`. Without spare concurrency, fetches unguarded.
    fn fetchGuarded(self: *Client, options: std.http.Client.FetchOptions) GuardError!std.http.Client.FetchResult {
        var buf: [2]GuardEvent = undefined;
        var sel = Io.Select(GuardEvent).init(self.io, &buf);
        sel.concurrent(.fetch, std.http.Client.fetch, .{ &self.http, options }) catch
            return self.http.fetch(options);
        sel.concurrent(.timer, guardTimer, .{ self.io, self.request_timeout_ms }) catch {
            const only = sel.await() catch {
                sel.cancelDiscard();
                return error.RequestTimedOut;
            };
            sel.cancelDiscard();
            return only.fetch;
        };
        const first = sel.await() catch {
            sel.cancelDiscard();
            return error.RequestTimedOut;
        };
        sel.cancelDiscard();
        return switch (first) {
            .fetch => |r| r,
            .timer => error.RequestTimedOut,
        };
    }

    fn classifyStatus(code: u16) errs.Error {
        return switch (code) {
            401, 403 => errs.Error.AuthRequired,
            404 => errs.Error.NotFound,
            429 => errs.Error.RateLimited,
            500, 502, 503, 504 => errs.Error.ServerError,
            else => errs.Error.HttpStatusError,
        };
    }

    /// True for image-asset URLs hosted on F95's Cloudflare CDN.
    /// Those bypass the forum rate limit since the CDN doesn't share
    /// the rate-sensitive forum backend.
    fn isCdnUrl(url: []const u8) bool {
        return std.mem.startsWith(u8, url, "https://attachments.f95zone.to/") or
            std.mem.startsWith(u8, url, "http://attachments.f95zone.to/");
    }

    fn waitRateLimit(self: *Client) void {
        // Hold the mutex through both the wait and the timestamp bump
        // so two racing callers can't both observe a stale timestamp.
        self.rate_lock.lockUncancelable(self.io);
        defer self.rate_lock.unlock(self.io);
        const now_ts = Io.Clock.Timestamp.now(self.io, .real);
        const now_ms = now_ts.raw.toMilliseconds();
        const since = now_ms - self.last_request_ms;
        if (since < @as(i64, @intCast(self.rate_limit_ms))) {
            const sleep_ms: i64 = @as(i64, @intCast(self.rate_limit_ms)) - since;
            self.io.sleep(Io.Duration.fromMilliseconds(sleep_ms), .real) catch {};
        }
        const after = Io.Clock.Timestamp.now(self.io, .real);
        self.last_request_ms = after.raw.toMilliseconds();
    }
};

/// Extract the F95 thread id from any URL form. Public so other contexts
/// can canonicalize stored URLs without going through the full client.
pub fn extractThreadId(url: []const u8) ?[]const u8 {
    const marker = "/threads/";
    const start = std.mem.indexOf(u8, url, marker) orelse return null;
    const after = url[start + marker.len ..];
    var end: usize = 0;
    while (end < after.len and after[end] != '/' and after[end] != '?' and after[end] != '#') : (end += 1) {}
    const segment = after[0..end];
    var i: usize = segment.len;
    while (i > 0 and std.ascii.isDigit(segment[i - 1])) : (i -= 1) {}
    if (i == segment.len) return null;
    return segment[i..];
}

pub fn canonicalUrl(buf: []u8, thread_id: []const u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}/threads/thread.{s}/", .{ BASE_URL, thread_id });
}

test "get: a server that never answers times out instead of hanging" {
    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Listening but never accepting: the TCP handshake completes in the
    // kernel backlog, the request is sent, and no reply ever comes.
    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var c = Client.init(std.testing.allocator, io, 0);
    defer c.deinit();
    c.request_timeout_ms = 500;

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});
    const t0 = Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
    try std.testing.expectError(errs.Error.NetworkError, c.get(url));
    const took = Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds() - t0;
    try std.testing.expect(took < 5000);
}

test "extractThreadId" {
    try std.testing.expectEqualStrings("12345", extractThreadId("https://f95zone.to/threads/x.12345/").?);
    try std.testing.expectEqualStrings("12345", extractThreadId("https://f95zone.to/threads/12345").?);
    try std.testing.expect(extractThreadId("https://example.com/foo") == null);
}

test "canonicalUrl" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https://f95zone.to/threads/thread.12345/", try canonicalUrl(&buf, "12345"));
}

test "client: isF95Url only for f95zone.to and its subdomains" {
    try std.testing.expect(Client.isF95Url("https://f95zone.to/masked/x"));
    try std.testing.expect(Client.isF95Url("https://attachments.f95zone.to/a.zip"));
    try std.testing.expect(Client.isF95Url("HTTPS://F95ZONE.TO:443/x"));
    try std.testing.expect(!Client.isF95Url("https://pixeldrain.com/api/file/a"));
    try std.testing.expect(!Client.isF95Url("https://evilf95zone.to/x"));
    try std.testing.expect(!Client.isF95Url("https://f95zone.to.evil.com/x"));
    try std.testing.expect(!Client.isF95Url("https://f95zone.to@evil.com/x"));
    try std.testing.expect(!Client.isF95Url("f95zone.to/x"));
}

test "client: cookieHeader formats under the lock, null when signed out or too small" {
    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var c = Client.init(std.testing.allocator, threaded.io(), 0);
    defer c.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), c.cookieHeader(&buf));
    try c.setCookie("xf_user=1");
    try std.testing.expectEqualStrings("Cookie: xf_user=1", c.cookieHeader(&buf).?);
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), c.cookieHeader(&tiny));
}

test "fuzz: url parsers survive arbitrary input" {
    try std.testing.fuzz({}, fuzzUrlParsers, .{ .corpus = &.{
        fuzzSeed("https://f95zone.to/threads/name.12345/"),
        fuzzSeed("threads/.1/"),
        fuzzSeed("12345"),
    } });
}

fn fuzzUrlParsers(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [FUZZ_BUF_LEN]u8 = undefined;
    const n = smith.slice(&buf);
    const src = buf[0..n];

    _ = extractThreadId(src);

    // canonicalUrl treats src as a thread id; error (NoSpaceLeft) is an
    // expected reject for oversized ids.
    var url_buf: [FUZZ_BUF_LEN + 64]u8 = undefined;
    _ = canonicalUrl(&url_buf, src) catch {};
}

/// Harness read-buffer length. fuzzSeed payloads must fit this, or Smith's
/// decode silently rejects the length and replays the seed as empty.
const FUZZ_BUF_LEN = 1024;

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
