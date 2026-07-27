// F95Zone login. XenForo-style two-step:
//
//   1. GET https://f95zone.to/login/   → scrape `_xfToken` from HTML.
//   2. POST https://f95zone.to/login/login with the form body
//      `login=<user>&password=<pass>&remember=1&_xfToken=<token>
//       &_xfResponseType=json`. Captures `Set-Cookie: xf_*=…` headers
//      from the response and joins them into a single Cookie value.
//
// The combined cookie is suitable for `Cookie:` headers on subsequent
// requests; it's also handed to the existing `f95.Client.setCookie`
// so the regular scrape path is now authenticated.
//
// Persistence is the caller's job — load via `loadStoredCookie` /
// save via `storeCookie` (see main.zig wiring).

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.f95_auth);
const errs = @import("errors.zig");
const Client = @import("client.zig").Client;

pub const Credentials = struct {
    username: []const u8,
    password: []const u8,
};

const LOGIN_PAGE_URL = "https://f95zone.to/login/";
const LOGIN_POST_URL = "https://f95zone.to/login/login";
const TWO_STEP_URL = "https://f95zone.to/login/two-step";
const USER_AGENT = @import("client.zig").USER_AGENT;

/// Outcome of a password login. Either we got an authenticated cookie, or the
/// account has 2FA and F95 returned a two-step challenge that needs a code
/// submitted via `submitTwoStep`.
pub const LoginResult = union(enum) {
    /// Combined authenticated `xf_*` cookie (owned). Already applied to the
    /// client. Caller persists + frees.
    ok: []u8,
    /// 2FA required. Carries the challenge-session cookies (owned) to hand to
    /// `submitTwoStep` along with the user's code. NOT yet authenticated.
    two_step: []u8,
};

/// Run the password login dance. Returns `.ok` with the authenticated cookie
/// (applied to `client`), or `.two_step` when the account needs a 2FA code.
/// Caller frees the owned slice in whichever variant.
pub fn login(
    client: *Client,
    alloc: std.mem.Allocator,
    io: Io,
    creds: Credentials,
) errs.Error!LoginResult {
    log.debug("login: user='{s}' (pw len={d})", .{ creds.username, creds.password.len });

    var http: std.http.Client = .{ .allocator = alloc, .io = io };
    defer http.deinit();

    log.debug("login step 1/3: GET {s}", .{LOGIN_PAGE_URL});
    const token_and_cookies = try fetchTokenAndCookies(&http, alloc);
    defer alloc.free(token_and_cookies.token);
    defer alloc.free(token_and_cookies.cookies);

    log.debug("login step 2/3: build form body (token len={d}, carry-cookies len={d})", .{
        token_and_cookies.token.len,
        token_and_cookies.cookies.len,
    });
    const body = try buildFormBody(alloc, creds, token_and_cookies.token);
    defer alloc.free(body);

    log.debug("login step 3/3: POST {s} (body {d} bytes)", .{ LOGIN_POST_URL, body.len });
    const post = try postLogin(&http, alloc, body, token_and_cookies.cookies);
    defer alloc.free(post.body_head);
    errdefer alloc.free(post.cookies);

    if (post.has_xf_user) {
        try client.setCookie(post.cookies);
        log.info("F95 login OK ({d}-byte cookie)", .{post.cookies.len});
        return .{ .ok = post.cookies };
    }

    // No xf_user. Two-step (2FA) challenge, or just bad credentials? XenForo's
    // JSON reply for a 2FA account carries a redirect to /login/two-step.
    if (std.mem.indexOf(u8, post.body_head, "two-step") != null or
        std.mem.indexOf(u8, post.body_head, "two_step") != null or
        std.mem.indexOf(u8, post.body_head, "totp") != null)
    {
        // Carry both the GET's xf_csrf and the POST's challenge-session
        // cookies into the two-step requests.
        const carry = try mergeCookies(alloc, token_and_cookies.cookies, post.cookies);
        alloc.free(post.cookies);
        log.info("F95 login: two-step (2FA) challenge detected — carry cookies {d}B", .{carry.len});
        return .{ .two_step = carry };
    }

    log.warn("login rejected — no xf_user cookie and no two-step marker (bad credentials)", .{});
    // `errdefer alloc.free(post.cookies)` frees on this error return — don't
    // free explicitly here or it's a double-free.
    return errs.Error.AuthRequired;
}

/// Complete a two-step (TOTP) challenge. `carry_cookies` comes from
/// `LoginResult.two_step`; `code` is the 6-digit authenticator code. On
/// success returns the authenticated cookie (applied to `client`) — same
/// shape as a password login.
pub fn submitTwoStep(
    client: *Client,
    alloc: std.mem.Allocator,
    io: Io,
    carry_cookies: []const u8,
    code: []const u8,
) errs.Error![]u8 {
    var http: std.http.Client = .{ .allocator = alloc, .io = io };
    defer http.deinit();

    // Step 1: GET the two-step page to read a fresh _xfToken + provider, and
    // pick up any cookies it sets.
    log.debug("two-step 1/2: GET {s}", .{TWO_STEP_URL});
    const page = try fetchTwoStep(&http, alloc, carry_cookies);
    defer alloc.free(page.token);
    defer alloc.free(page.provider);
    defer alloc.free(page.cookies);

    const carry2 = try mergeCookies(alloc, carry_cookies, page.cookies);
    defer alloc.free(carry2);

    // Step 2: POST the code.
    log.debug("two-step 2/2: POST {s} (provider='{s}', code len={d})", .{ TWO_STEP_URL, page.provider, code.len });
    const body = try buildTwoStepBody(alloc, code, page.provider, page.token);
    defer alloc.free(body);

    const cookie = try postTwoStep(&http, alloc, body, carry2);
    errdefer alloc.free(cookie);
    try client.setCookie(cookie);
    log.info("F95 two-step OK ({d}-byte cookie)", .{cookie.len});
    return cookie;
}

const GetResult = struct {
    /// `_xfToken` extracted from the form HTML.
    token: []u8,
    /// "name=value; name=value" — every Set-Cookie the login page
    /// sent us (notably `xf_csrf`). The POST has to send these back
    /// or XenForo rejects with 400.
    cookies: []u8,
};

// ----- step 1: GET token -----

/// Fetch the login page using the lower-level `request()` API so we
/// can both (a) read the body and (b) capture every `Set-Cookie:`
/// header — XenForo's `xf_csrf` from this response is required on
/// the subsequent POST.
fn fetchTokenAndCookies(http: *std.http.Client, alloc: std.mem.Allocator) errs.Error!GetResult {
    const uri = std.Uri.parse(LOGIN_PAGE_URL) catch return errs.Error.NetworkError;

    // We accept gzip/deflate and decompress on the read side — F95
    // sometimes ignores `accept-encoding: identity` and returns
    // gzipped HTML anyway, so we have to handle both.
    const headers = [_]std.http.Header{
        .{ .name = "accept", .value = "text/html" },
    };

    var req = http.request(.GET, uri, .{
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = USER_AGENT } },
        .extra_headers = &headers,
    }) catch |e| {
        log.warn("login GET request init failed: {s}", .{@errorName(e)});
        return errs.Error.NetworkError;
    };
    defer req.deinit();

    req.sendBodiless() catch |e| {
        log.warn("login GET sendBodiless failed: {s}", .{@errorName(e)});
        return errs.Error.NetworkError;
    };
    if (req.connection) |c| c.flush() catch {};

    var redir_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redir_buf) catch |e| {
        log.warn("login GET receiveHead failed: {s}", .{@errorName(e)});
        return errs.Error.NetworkError;
    };
    if (response.head.status != .ok) {
        log.warn("login GET status {d}", .{@intFromEnum(response.head.status)});
        return errs.Error.HttpStatusError;
    }
    log.debug("login GET content-encoding={s}", .{@tagName(response.head.content_encoding)});

    // Capture every Set-Cookie header — we'll replay them on the POST.
    // Header bytes get clobbered if we read the body via
    // `readerDecompressing` (which calls `head.invalidateStrings`),
    // so iterate cookies BEFORE reading.
    var jar: std.ArrayList(u8) = .empty;
    errdefer jar.deinit(alloc);
    var hdr_iter = response.head.iterateHeaders();
    var carry_count: u32 = 0;
    while (hdr_iter.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "set-cookie")) continue;
        const pair = trimSetCookieAttrs(h.value);
        if (pair.len == 0) continue;
        // Skip "=deleted" sentinels — they'd just confuse the server.
        if (std.mem.indexOf(u8, pair, "=deleted") != null) continue;
        if (jar.items.len > 0) jar.appendSlice(alloc, "; ") catch return errs.Error.OutOfMemory;
        jar.appendSlice(alloc, pair) catch return errs.Error.OutOfMemory;
        carry_count += 1;

        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        log.debug("login GET set-cookie: '{s}'", .{pair[0..eq]});
    }
    log.debug("login GET captured {d} cookie(s) to carry into POST", .{carry_count});

    // Read + decompress the body. `readerDecompressing` returns
    // `transfer_reader` directly when content-encoding is identity.
    var transfer_buf: [4096]u8 = undefined;
    var decompress_state: std.http.Decompress = undefined;
    var decompress_buf: [64 * 1024]u8 = undefined;
    const body_reader = response.readerDecompressing(
        &transfer_buf,
        &decompress_state,
        &decompress_buf,
    );

    var html_buf: std.ArrayList(u8) = .empty;
    defer html_buf.deinit(alloc); // safe even on early exits
    while (true) {
        var chunk: [4096]u8 = undefined;
        const got = body_reader.readSliceShort(&chunk) catch |e| {
            log.warn("login GET body read failed: {s}", .{@errorName(e)});
            return errs.Error.NetworkError;
        };
        if (got == 0) break;
        html_buf.appendSlice(alloc, chunk[0..got]) catch return errs.Error.OutOfMemory;
        if (html_buf.items.len > 4 * 1024 * 1024) {
            log.warn("login GET body too large; bailing", .{});
            return errs.Error.NetworkError;
        }
    }
    const html = html_buf.items;
    log.debug("login GET ok: {d} bytes of HTML", .{html.len});

    const token_view = extractXfToken(html) orelse {
        log.warn("no _xfToken / data-csrf in login page (HTML head: '{s}')", .{
            html[0..@min(160, html.len)],
        });
        return errs.Error.AuthRequired;
    };
    log.debug("extracted _xfToken (len={d}, head='{s}…')", .{
        token_view.len,
        token_view[0..@min(8, token_view.len)],
    });
    const token_owned = alloc.dupe(u8, token_view) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(token_owned);

    const cookies_owned = jar.toOwnedSlice(alloc) catch return errs.Error.OutOfMemory;
    return .{ .token = token_owned, .cookies = cookies_owned };
}

/// Pulls the CSRF token out of the login page. XenForo emits it as
/// `<input type="hidden" name="_xfToken" value="…">` inside the form
/// and as `data-csrf="…"` on the `<html>` element on newer skins.
pub fn extractXfToken(html: []const u8) ?[]const u8 {
    {
        const marker = "name=\"_xfToken\" value=\"";
        if (std.mem.indexOf(u8, html, marker)) |s| {
            const value_start = s + marker.len;
            const end = std.mem.indexOfScalarPos(u8, html, value_start, '"') orelse return null;
            return html[value_start..end];
        }
    }
    {
        const marker = "data-csrf=\"";
        if (std.mem.indexOf(u8, html, marker)) |s| {
            const value_start = s + marker.len;
            const end = std.mem.indexOfScalarPos(u8, html, value_start, '"') orelse return null;
            return html[value_start..end];
        }
    }
    return null;
}

// ----- step 2: build form body -----

fn buildFormBody(alloc: std.mem.Allocator, creds: Credentials, token: []const u8) errs.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    appendField(&buf, alloc, "login", creds.username) catch return errs.Error.OutOfMemory;
    buf.append(alloc, '&') catch return errs.Error.OutOfMemory;
    appendField(&buf, alloc, "password", creds.password) catch return errs.Error.OutOfMemory;
    buf.append(alloc, '&') catch return errs.Error.OutOfMemory;
    appendField(&buf, alloc, "remember", "1") catch return errs.Error.OutOfMemory;
    buf.append(alloc, '&') catch return errs.Error.OutOfMemory;
    appendField(&buf, alloc, "_xfToken", token) catch return errs.Error.OutOfMemory;
    buf.append(alloc, '&') catch return errs.Error.OutOfMemory;
    appendField(&buf, alloc, "_xfResponseType", "json") catch return errs.Error.OutOfMemory;
    buf.append(alloc, '&') catch return errs.Error.OutOfMemory;
    appendField(&buf, alloc, "_xfWithData", "1") catch return errs.Error.OutOfMemory;

    return buf.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

fn appendField(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    try buf.appendSlice(alloc, name);
    try buf.append(alloc, '=');
    try appendUrlEncoded(buf, alloc, value);
}

fn appendUrlEncoded(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try buf.append(alloc, c),
            ' ' => try buf.append(alloc, '+'),
            else => {
                var hex: [3]u8 = undefined;
                _ = std.fmt.bufPrint(&hex, "%{X:0>2}", .{c}) catch unreachable;
                try buf.appendSlice(alloc, &hex);
            },
        }
    }
}

// ----- step 3: POST + capture Set-Cookie -----

const PostResult = struct {
    /// `xf_*` cookies captured from the POST response (owned). On a 2FA
    /// account these are the challenge-session cookies (no xf_user yet).
    cookies: []u8,
    /// True when an `xf_user` cookie was set — i.e. fully authenticated.
    has_xf_user: bool,
    /// First ~16 KB of the decompressed response body (owned), used to tell a
    /// two-step challenge apart from bad credentials + for live diagnostics.
    body_head: []u8,
};

fn postLogin(http: *std.http.Client, alloc: std.mem.Allocator, form_body: []const u8, carry_cookies: []const u8) errs.Error!PostResult {
    const uri = std.Uri.parse(LOGIN_POST_URL) catch return errs.Error.NetworkError;

    // Build the header set: content-type + accept + identity encoding
    // + (optionally) the cookies we captured from the GET. Without
    // `xf_csrf` carried over here, XenForo returns 400.
    var hdr_storage: [4]std.http.Header = undefined;
    var n: usize = 0;
    hdr_storage[n] = .{ .name = "content-type", .value = "application/x-www-form-urlencoded" };
    n += 1;
    hdr_storage[n] = .{ .name = "accept", .value = "application/json, text/html" };
    n += 1;
    hdr_storage[n] = .{ .name = "accept-encoding", .value = "identity" };
    n += 1;
    if (carry_cookies.len > 0) {
        hdr_storage[n] = .{ .name = "cookie", .value = carry_cookies };
        n += 1;
    }
    const headers = hdr_storage[0..n];

    var req = http.request(.POST, uri, .{
        .keep_alive = false,
        // Don't auto-follow — the redirect would lose the Set-Cookie
        // headers we need to capture.
        .redirect_behavior = .unhandled,
        .headers = .{ .user_agent = .{ .override = USER_AGENT } },
        .extra_headers = headers,
    }) catch |e| {
        log.warn("login POST request init failed: {s}", .{@errorName(e)});
        return errs.Error.NetworkError;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = form_body.len };
    var body_writer = req.sendBodyUnflushed(&.{}) catch |e| {
        log.warn("login POST sendBodyUnflushed failed: {s}", .{@errorName(e)});
        return errs.Error.NetworkError;
    };
    body_writer.writer.writeAll(form_body) catch |e| {
        log.warn("login POST writeAll failed: {s}", .{@errorName(e)});
        return errs.Error.NetworkError;
    };
    body_writer.end() catch |e| {
        log.warn("login POST body.end failed: {s}", .{@errorName(e)});
        return errs.Error.NetworkError;
    };
    if (req.connection) |c| c.flush() catch {};

    var redir_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redir_buf) catch |e| {
        log.warn("login POST receiveHead failed: {s}", .{@errorName(e)});
        return errs.Error.NetworkError;
    };
    log.debug("login POST status={d}", .{@intFromEnum(response.head.status)});

    // Walk response headers for `Set-Cookie: xf_…=…`.
    var jar: std.ArrayList(u8) = .empty;
    errdefer jar.deinit(alloc);
    var set_cookie_seen: u32 = 0;
    var captured: u32 = 0;
    var hdr_iter = response.head.iterateHeaders();
    while (hdr_iter.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "set-cookie")) continue;
        set_cookie_seen += 1;
        const pair = trimSetCookieAttrs(h.value);
        // Find the cookie name (everything up to '=').
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const cookie_name = pair[0..eq];
        if (!std.mem.startsWith(u8, pair, "xf_")) {
            log.debug("set-cookie skipped (non-xf): '{s}'", .{cookie_name});
            continue;
        }
        if (std.mem.indexOf(u8, pair, "=deleted") != null) {
            log.debug("set-cookie skipped (=deleted): '{s}'", .{cookie_name});
            continue;
        }
        log.debug("set-cookie captured: '{s}'", .{cookie_name});
        captured += 1;
        if (jar.items.len > 0) jar.appendSlice(alloc, "; ") catch return errs.Error.OutOfMemory;
        jar.appendSlice(alloc, pair) catch return errs.Error.OutOfMemory;
    }
    log.debug("login response: {d} set-cookie headers, {d} captured", .{ set_cookie_seen, captured });

    // Drain body so the connection is in a sane state for close. We
    // also peek at the first 256 bytes for diagnostics — XenForo's
    // JSON error response carries a useful "errors" array. Use the
    // decompressing reader so peek shows readable text even when
    // F95 returned gzip.
    log.debug("login POST content-encoding={s}", .{@tagName(response.head.content_encoding)});
    var transfer_buf: [4096]u8 = undefined;
    var decompress_state: std.http.Decompress = undefined;
    var decompress_buf: [64 * 1024]u8 = undefined;
    const body_reader = response.readerDecompressing(
        &transfer_buf,
        &decompress_state,
        &decompress_buf,
    );
    // Read up to ~16 KB of the body. The caller inspects it to tell a
    // two-step (2FA) challenge apart from bad credentials; it's also logged
    // for live diagnostics of the real XenForo response.
    const body_head = readBodyHead(body_reader, alloc, 16 * 1024) catch
        (alloc.dupe(u8, "") catch return errs.Error.OutOfMemory);
    if (body_head.len > 0) log.debug("login response body head ({d}B): '{s}'", .{
        body_head.len, body_head[0..@min(512, body_head.len)],
    });

    const has_xf_user = jar.items.len > 0 and std.mem.indexOf(u8, jar.items, "xf_user=") != null;
    const cookies = jar.toOwnedSlice(alloc) catch {
        alloc.free(body_head);
        return errs.Error.OutOfMemory;
    };
    return .{ .cookies = cookies, .has_xf_user = has_xf_user, .body_head = body_head };
}

/// Read + own up to `limit` bytes of a body, then drain the rest.
fn readBodyHead(reader: anytype, alloc: std.mem.Allocator, limit: usize) errs.Error![]u8 {
    var acc: std.ArrayList(u8) = .empty;
    errdefer acc.deinit(alloc);
    while (acc.items.len < limit) {
        var chunk: [4096]u8 = undefined;
        const want = @min(chunk.len, limit - acc.items.len);
        const got = reader.readSliceShort(chunk[0..want]) catch break;
        if (got == 0) break;
        acc.appendSlice(alloc, chunk[0..got]) catch return errs.Error.OutOfMemory;
    }
    _ = reader.discardRemaining() catch {};
    return acc.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

/// Merge two "a=b; c=d" cookie strings, de-duplicating by name (later wins).
fn mergeCookies(alloc: std.mem.Allocator, first: []const u8, second: []const u8) errs.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    // Emit `second` first (fresher), then any name from `first` not already seen.
    appendCookiePairs(&out, alloc, second) catch return errs.Error.OutOfMemory;
    var it = std.mem.splitSequence(u8, first, "; ");
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const name = pair[0..eq];
        if (cookieHasName(out.items, name)) continue;
        if (out.items.len > 0) out.appendSlice(alloc, "; ") catch return errs.Error.OutOfMemory;
        out.appendSlice(alloc, pair) catch return errs.Error.OutOfMemory;
    }
    return out.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

fn appendCookiePairs(out: *std.ArrayList(u8), alloc: std.mem.Allocator, cookies: []const u8) !void {
    var it = std.mem.splitSequence(u8, cookies, "; ");
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        if (out.items.len > 0) try out.appendSlice(alloc, "; ");
        try out.appendSlice(alloc, pair);
    }
}

fn cookieHasName(cookies: []const u8, name: []const u8) bool {
    var it = std.mem.splitSequence(u8, cookies, "; ");
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (std.mem.eql(u8, pair[0..eq], name)) return true;
    }
    return false;
}

// ----- two-step (TOTP) helpers -----

const TwoStepPage = struct {
    token: []u8, // _xfToken from the two-step form (owned)
    provider: []u8, // "totp" (owned)
    cookies: []u8, // xf_* the two-step page set (owned)
};

/// GET the two-step page, carrying the challenge cookies. Scrapes a fresh
/// `_xfToken`, guesses the provider (default "totp"), and captures any
/// `xf_*` Set-Cookie. Logs the body head for live diagnostics.
fn fetchTwoStep(http: *std.http.Client, alloc: std.mem.Allocator, carry_cookies: []const u8) errs.Error!TwoStepPage {
    const uri = std.Uri.parse(TWO_STEP_URL) catch return errs.Error.NetworkError;
    const headers = [_]std.http.Header{
        .{ .name = "accept", .value = "text/html" },
        .{ .name = "cookie", .value = carry_cookies },
    };
    var req = http.request(.GET, uri, .{
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = USER_AGENT } },
        .extra_headers = &headers,
    }) catch return errs.Error.NetworkError;
    defer req.deinit();

    req.sendBodiless() catch return errs.Error.NetworkError;
    if (req.connection) |c| c.flush() catch {};

    var redir_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redir_buf) catch return errs.Error.NetworkError;
    if (response.head.status != .ok) {
        log.warn("two-step GET status {d}", .{@intFromEnum(response.head.status)});
        return errs.Error.HttpStatusError;
    }

    // Capture xf_* cookies BEFORE reading the body (reading invalidates header
    // strings).
    var jar: std.ArrayList(u8) = .empty;
    errdefer jar.deinit(alloc);
    var hdr_iter = response.head.iterateHeaders();
    while (hdr_iter.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "set-cookie")) continue;
        const pair = trimSetCookieAttrs(h.value);
        if (!std.mem.startsWith(u8, pair, "xf_")) continue;
        if (std.mem.indexOf(u8, pair, "=deleted") != null) continue;
        if (jar.items.len > 0) jar.appendSlice(alloc, "; ") catch return errs.Error.OutOfMemory;
        jar.appendSlice(alloc, pair) catch return errs.Error.OutOfMemory;
    }

    var transfer_buf: [4096]u8 = undefined;
    var decompress_state: std.http.Decompress = undefined;
    var decompress_buf: [64 * 1024]u8 = undefined;
    const body_reader = response.readerDecompressing(&transfer_buf, &decompress_state, &decompress_buf);
    const html = try readBodyHead(body_reader, alloc, 64 * 1024);
    defer alloc.free(html);
    log.debug("two-step GET body head ({d}B): '{s}'", .{ html.len, html[0..@min(512, html.len)] });

    const token_view = extractXfToken(html) orelse {
        log.warn("two-step page had no _xfToken", .{});
        jar.deinit(alloc);
        return errs.Error.AuthRequired;
    };
    const token = alloc.dupe(u8, token_view) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(token);
    const provider = alloc.dupe(u8, extractProvider(html)) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(provider);
    const cookies = jar.toOwnedSlice(alloc) catch return errs.Error.OutOfMemory;
    return .{ .token = token, .provider = provider, .cookies = cookies };
}

/// Pull the selected two-step provider from `name="provider" value="…"`.
/// Defaults to "totp" — the common authenticator-app provider.
fn extractProvider(html: []const u8) []const u8 {
    const marker = "name=\"provider\" value=\"";
    if (std.mem.indexOf(u8, html, marker)) |s| {
        const start = s + marker.len;
        if (std.mem.indexOfScalarPos(u8, html, start, '"')) |end| {
            const v = html[start..end];
            if (v.len > 0) return v;
        }
    }
    return "totp";
}

fn buildTwoStepBody(alloc: std.mem.Allocator, code: []const u8, provider: []const u8, token: []const u8) errs.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    appendField(&buf, alloc, "code", code) catch return errs.Error.OutOfMemory;
    buf.append(alloc, '&') catch return errs.Error.OutOfMemory;
    appendField(&buf, alloc, "provider", provider) catch return errs.Error.OutOfMemory;
    buf.append(alloc, '&') catch return errs.Error.OutOfMemory;
    appendField(&buf, alloc, "trust", "1") catch return errs.Error.OutOfMemory;
    buf.append(alloc, '&') catch return errs.Error.OutOfMemory;
    appendField(&buf, alloc, "remember", "1") catch return errs.Error.OutOfMemory;
    buf.append(alloc, '&') catch return errs.Error.OutOfMemory;
    appendField(&buf, alloc, "_xfToken", token) catch return errs.Error.OutOfMemory;
    buf.append(alloc, '&') catch return errs.Error.OutOfMemory;
    appendField(&buf, alloc, "_xfResponseType", "json") catch return errs.Error.OutOfMemory;
    return buf.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

/// POST the TOTP code. Captures the `xf_*` cookies; success = an `xf_user`
/// cookie comes back. Mirrors `postLogin`.
fn postTwoStep(http: *std.http.Client, alloc: std.mem.Allocator, form_body: []const u8, carry_cookies: []const u8) errs.Error![]u8 {
    const uri = std.Uri.parse(TWO_STEP_URL) catch return errs.Error.NetworkError;
    var hdr: [4]std.http.Header = .{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "accept", .value = "application/json, text/html" },
        .{ .name = "accept-encoding", .value = "identity" },
        .{ .name = "cookie", .value = carry_cookies },
    };
    var req = http.request(.POST, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{ .user_agent = .{ .override = USER_AGENT } },
        .extra_headers = &hdr,
    }) catch return errs.Error.NetworkError;
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = form_body.len };
    var body_writer = req.sendBodyUnflushed(&.{}) catch return errs.Error.NetworkError;
    body_writer.writer.writeAll(form_body) catch return errs.Error.NetworkError;
    body_writer.end() catch return errs.Error.NetworkError;
    if (req.connection) |c| c.flush() catch {};

    var redir_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redir_buf) catch return errs.Error.NetworkError;
    log.debug("two-step POST status={d}", .{@intFromEnum(response.head.status)});

    var jar: std.ArrayList(u8) = .empty;
    errdefer jar.deinit(alloc);
    var hdr_iter = response.head.iterateHeaders();
    while (hdr_iter.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "set-cookie")) continue;
        const pair = trimSetCookieAttrs(h.value);
        if (!std.mem.startsWith(u8, pair, "xf_")) continue;
        if (std.mem.indexOf(u8, pair, "=deleted") != null) continue;
        if (jar.items.len > 0) jar.appendSlice(alloc, "; ") catch return errs.Error.OutOfMemory;
        jar.appendSlice(alloc, pair) catch return errs.Error.OutOfMemory;
    }

    var transfer_buf: [4096]u8 = undefined;
    var decompress_state: std.http.Decompress = undefined;
    var decompress_buf: [64 * 1024]u8 = undefined;
    const body_reader = response.readerDecompressing(&transfer_buf, &decompress_state, &decompress_buf);
    const body_head = readBodyHead(body_reader, alloc, 4 * 1024) catch (alloc.dupe(u8, "") catch return errs.Error.OutOfMemory);
    defer alloc.free(body_head);
    if (body_head.len > 0) log.debug("two-step POST body head ({d}B): '{s}'", .{ body_head.len, body_head[0..@min(512, body_head.len)] });

    if (jar.items.len == 0 or std.mem.indexOf(u8, jar.items, "xf_user=") == null) {
        log.warn("two-step rejected — no xf_user cookie (bad/expired code?)", .{});
        return errs.Error.AuthRequired;
    }
    return jar.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

// ============================================================
//  Cookie sign-in (2FA / passkey workaround)
// ============================================================
//
// Password login can't clear a two-step / passkey challenge (see the header
// note + the UI). The escape hatch: the user logs in with their real browser
// (where the passkey works), copies the `xf_user` + `xf_session` cookie values
// out of devtools, and pastes them here. We assemble the Cookie string, verify
// it actually authenticates, and hand it back for the client + on-disk cookie.

const BASE_URL = "https://f95zone.to/";

pub const CookieCheck = enum { ok, invalid, network_error };

/// Strip a value copied from browser devtools down to the bare cookie value.
/// Tolerates the user pasting `xf_user=VALUE` (or `VALUE`), surrounding
/// whitespace, quotes, and a trailing `;`.
fn cleanCookieValue(name: []const u8, raw: []const u8) []const u8 {
    var v = std.mem.trim(u8, raw, " \t\r\n\"';");
    // "xf_user=ABC" → "ABC" (case-insensitive name match).
    if (v.len > name.len + 1 and std.ascii.eqlIgnoreCase(v[0..name.len], name) and v[name.len] == '=') {
        v = std.mem.trim(u8, v[name.len + 1 ..], " \t\r\n\"';");
    }
    return v;
}

/// Build a `xf_user=…; xf_session=…` Cookie value from the two parts the user
/// pasted. `xf_session` is optional (some accounts authenticate on `xf_user`
/// alone). Returns an owned slice; caller frees. Errors if `xf_user` is empty.
pub fn buildCookieFromParts(alloc: std.mem.Allocator, xf_user_raw: []const u8, xf_session_raw: []const u8) errs.Error![]u8 {
    const user = cleanCookieValue("xf_user", xf_user_raw);
    const session = cleanCookieValue("xf_session", xf_session_raw);
    if (user.len == 0) return errs.Error.AuthRequired;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    buf.appendSlice(alloc, "xf_user=") catch return errs.Error.OutOfMemory;
    buf.appendSlice(alloc, user) catch return errs.Error.OutOfMemory;
    if (session.len > 0) {
        buf.appendSlice(alloc, "; xf_session=") catch return errs.Error.OutOfMemory;
        buf.appendSlice(alloc, session) catch return errs.Error.OutOfMemory;
    }
    return buf.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

/// GET the site root with the candidate cookie and read the `<html>` tag's
/// `data-logged-in` flag XenForo stamps on every page. `.ok` = the cookie
/// authenticates, `.invalid` = it doesn't, `.network_error` = couldn't tell.
pub fn verifyCookie(alloc: std.mem.Allocator, io: Io, cookie: []const u8) CookieCheck {
    var http: std.http.Client = .{ .allocator = alloc, .io = io };
    defer http.deinit();

    const uri = std.Uri.parse(BASE_URL) catch return .network_error;
    const headers = [_]std.http.Header{
        .{ .name = "accept", .value = "text/html" },
        .{ .name = "cookie", .value = cookie },
    };
    var req = http.request(.GET, uri, .{
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = USER_AGENT } },
        .extra_headers = &headers,
    }) catch return .network_error;
    defer req.deinit();

    req.sendBodiless() catch return .network_error;
    if (req.connection) |c| c.flush() catch {};

    var redir_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redir_buf) catch return .network_error;
    if (response.head.status != .ok) {
        log.warn("verifyCookie: GET {s} status {d}", .{ BASE_URL, @intFromEnum(response.head.status) });
        return .network_error;
    }

    var transfer_buf: [4096]u8 = undefined;
    var decompress_state: std.http.Decompress = undefined;
    var decompress_buf: [64 * 1024]u8 = undefined;
    const body_reader = response.readerDecompressing(&transfer_buf, &decompress_state, &decompress_buf);

    // The flag lives in the `<html …>` tag at the very top, so scan only the
    // opening chunk. Keep a small carry so a marker split across reads still
    // matches.
    var scanned: usize = 0;
    var carry: [64]u8 = undefined;
    var carry_len: usize = 0;
    while (scanned < 256 * 1024) {
        var chunk: [16 * 1024]u8 = undefined;
        @memcpy(chunk[0..carry_len], carry[0..carry_len]);
        const got = body_reader.readSliceShort(chunk[carry_len..]) catch return .network_error;
        if (got == 0) break;
        const view = chunk[0 .. carry_len + got];
        scanned += got;
        if (std.mem.indexOf(u8, view, "data-logged-in=\"true\"") != null) {
            _ = body_reader.discardRemaining() catch {};
            return .ok;
        }
        if (std.mem.indexOf(u8, view, "data-logged-in=\"false\"") != null) {
            _ = body_reader.discardRemaining() catch {};
            return .invalid;
        }
        carry_len = @min(carry.len, view.len);
        @memcpy(carry[0..carry_len], view[view.len - carry_len ..]);
    }
    // No marker on this skin — inconclusive rather than a hard reject.
    log.warn("verifyCookie: no data-logged-in marker found", .{});
    return .network_error;
}

/// Cookie sign-in end to end: assemble → verify → apply to the client.
/// Returns the owned cookie (caller persists + frees), mirroring `login`.
pub fn loginWithCookie(client: *Client, alloc: std.mem.Allocator, io: Io, xf_user: []const u8, xf_session: []const u8) errs.Error![]u8 {
    const cookie = try buildCookieFromParts(alloc, xf_user, xf_session);
    errdefer alloc.free(cookie);
    switch (verifyCookie(alloc, io, cookie)) {
        .ok => log.info("cookie sign-in verified OK", .{}),
        .invalid => {
            log.warn("cookie sign-in rejected — F95 reports not-logged-in for the pasted cookie", .{});
            return errs.Error.AuthRequired;
        },
        // Couldn't reach F95 to confirm — accept optimistically; the first
        // authenticated action will surface a bad cookie. Better than blocking
        // a user who's briefly offline behind a false "cookie invalid".
        .network_error => log.warn("cookie sign-in: could not verify (network) — applying unverified", .{}),
    }
    try client.setCookie(cookie);
    return cookie;
}

/// `xf_user=ABC; Path=/; HttpOnly` → `xf_user=ABC`.
fn trimSetCookieAttrs(value: []const u8) []const u8 {
    const semi = std.mem.indexOfScalar(u8, value, ';') orelse return std.mem.trim(u8, value, " \t");
    return std.mem.trim(u8, value[0..semi], " \t");
}

// ----- tests (offline) -----

test "extractXfToken: form input" {
    const html =
        \\<form><input type="hidden" name="_xfToken" value="abc123def">
        \\</form>
    ;
    try std.testing.expectEqualStrings("abc123def", extractXfToken(html).?);
}

test "extractXfToken: data-csrf fallback" {
    const html = "<html data-csrf=\"toktok\" lang=\"en\">";
    try std.testing.expectEqualStrings("toktok", extractXfToken(html).?);
}

test "extractXfToken: missing → null" {
    try std.testing.expect(extractXfToken("<html></html>") == null);
}

test "trimSetCookieAttrs strips attrs" {
    try std.testing.expectEqualStrings(
        "xf_user=A1B2",
        trimSetCookieAttrs("xf_user=A1B2; Path=/; HttpOnly; Secure"),
    );
    try std.testing.expectEqualStrings(
        "xf_session=xyz",
        trimSetCookieAttrs("  xf_session=xyz "),
    );
}

test "mergeCookies dedups by name, second wins" {
    const a = std.testing.allocator;
    const m = try mergeCookies(a, "xf_csrf=OLD; xf_user=U", "xf_csrf=NEW; xf_session=S");
    defer a.free(m);
    // second emitted first; xf_user carried from first; xf_csrf not duplicated.
    try std.testing.expectEqualStrings("xf_csrf=NEW; xf_session=S; xf_user=U", m);
}

test "extractProvider default + explicit" {
    try std.testing.expectEqualStrings("totp", extractProvider("<form>no provider here</form>"));
    try std.testing.expectEqualStrings("email", extractProvider("<input name=\"provider\" value=\"email\">"));
}

test "buildTwoStepBody fields" {
    const a = std.testing.allocator;
    const b = try buildTwoStepBody(a, "123456", "totp", "TOK");
    defer a.free(b);
    try std.testing.expectEqualStrings(
        "code=123456&provider=totp&trust=1&remember=1&_xfToken=TOK&_xfResponseType=json",
        b,
    );
}

test "cleanCookieValue strips name= prefix, quotes, whitespace" {
    try std.testing.expectEqualStrings("ABC123", cleanCookieValue("xf_user", "xf_user=ABC123"));
    try std.testing.expectEqualStrings("ABC123", cleanCookieValue("xf_user", "  xf_user=ABC123 ; "));
    try std.testing.expectEqualStrings("ABC123", cleanCookieValue("xf_user", "\"ABC123\""));
    try std.testing.expectEqualStrings("ABC123", cleanCookieValue("xf_user", "ABC123"));
}

test "buildCookieFromParts joins both, session optional, empty user errors" {
    const a = std.testing.allocator;
    {
        const c = try buildCookieFromParts(a, "xf_user=U1", "S1");
        defer a.free(c);
        try std.testing.expectEqualStrings("xf_user=U1; xf_session=S1", c);
    }
    {
        const c = try buildCookieFromParts(a, "U1", "");
        defer a.free(c);
        try std.testing.expectEqualStrings("xf_user=U1", c);
    }
    try std.testing.expectError(errs.Error.AuthRequired, buildCookieFromParts(a, "  ", "S1"));
}

test "appendUrlEncoded reserved chars" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendUrlEncoded(&buf, std.testing.allocator, "a b&c=d%");
    try std.testing.expectEqualStrings("a+b%26c%3Dd%25", buf.items);
}
