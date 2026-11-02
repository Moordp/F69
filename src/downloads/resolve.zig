// Link resolver: turns a catalogued href into something an engine can
// fetch (direct URL, MEGA link, torrent) or says why it cannot (needs the
// browser, dead, sign-in required). All HTTP goes through `Http` so tests
// run on canned bodies with no network and never see the user's cookie.

const std = @import("std");
const errs = @import("errors.zig");
const model = @import("model.zig");
const dl_classify = @import("f95").dl_classify;

pub const Http = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, url: []const u8) errs.Error![]u8,
    postForm: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, url: []const u8, body: []const u8, extra_headers: []const []const u8) errs.Error!Reply,
    /// `Cookie: …` header for attachments.f95zone.to, or null when signed out.
    /// Owned by ctx; copy if kept.
    cookieHeader: *const fn (ctx: *anyopaque) ?[]const u8,

    pub const Reply = struct { status: u16, body: []u8 };
};

pub const Result = union(enum) {
    direct: Direct,
    /// MEGA link for the megacmd engine.
    mega: []u8,
    torrent_url: []u8,
    needs_browser,
    /// Reason text.
    dead: []u8,
    auth_required,
    captcha,

    pub const Direct = struct {
        url: []u8,
        /// Owned strings, e.g. `Cookie: …`.
        headers: []const []const u8,
        filename: ?[]u8 = null,
        size: ?u64 = null,
        engine: model.EngineKind,
    };

    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .direct => |d| {
                alloc.free(d.url);
                for (d.headers) |h| alloc.free(h);
                alloc.free(d.headers);
                if (d.filename) |f| alloc.free(f);
            },
            .mega => |s| alloc.free(s),
            .torrent_url => |s| alloc.free(s),
            .dead => |s| alloc.free(s),
            .needs_browser, .auth_required, .captcha => {},
        }
        self.* = .needs_browser;
    }
};

pub const max_depth: u8 = 2;
const masked_headers = [_][]const u8{ "X-Requested-With: XMLHttpRequest", "Accept: application/json" };

pub fn engineFor(entry: dl_classify.Entry, href: []const u8) model.EngineKind {
    if (entry.host == .mega) return .megacmd;
    if (std.mem.startsWith(u8, href, "magnet:") or std.mem.endsWith(u8, href, ".torrent")) return .aria2_torrent;
    return .aria2_http;
}

pub fn resolve(
    alloc: std.mem.Allocator,
    http: Http,
    href: []const u8,
    entry: dl_classify.Entry,
    depth: u8,
) errs.Error!Result {
    if (depth > max_depth) return .needs_browser;

    if (entry.wrapper == .masked) return resolveMasked(alloc, http, href, depth);

    if (engineFor(entry, href) == .aria2_torrent) {
        return .{ .torrent_url = try dupe(alloc, href) };
    }

    switch (entry.host) {
        .mega => return .{ .mega = try dupe(alloc, href) },
        .dead => return .{ .dead = try dupe(alloc, "This host no longer exists") },
        .pixeldrain => return resolvePixeldrain(alloc, http, href),
        .f95_attachment => {
            const cookie = http.cookieHeader(http.ctx) orelse return .auth_required;
            const headers = try alloc.alloc([]const u8, 1);
            errdefer alloc.free(headers);
            headers[0] = try dupe(alloc, cookie);
            errdefer alloc.free(headers[0]);
            const url = try dupe(alloc, href);
            return .{ .direct = .{ .url = url, .headers = headers, .engine = .aria2_http } };
        },
        .google_drive => {
            const id = driveId(href) orelse return .needs_browser;
            const url = std.fmt.allocPrint(
                alloc,
                "https://drive.usercontent.google.com/download?id={s}&export=download&confirm=t",
                .{id},
            ) catch return errs.Error.OutOfMemory;
            return directPlain(alloc, url);
        },
        .mediafire => {
            const page = try http.get(http.ctx, alloc, href);
            defer alloc.free(page);
            const link = mediafireDirect(page) orelse return .needs_browser;
            return directPlain(alloc, try dupe(alloc, link));
        },
        else => return .needs_browser,
    }
}

fn resolveMasked(alloc: std.mem.Allocator, http: Http, href: []const u8, depth: u8) errs.Error!Result {
    const reply = http.postForm(http.ctx, alloc, href, "xhr=1&download=1", &masked_headers) catch |e| switch (e) {
        errs.Error.AuthRequired => return .auth_required,
        else => return e,
    };
    defer alloc.free(reply.body);
    if (reply.status == 401 or reply.status == 403) return .auth_required;

    switch (parseMaskedReply(reply.body)) {
        .html => return .needs_browser,
        .not_ok => |raw| return .{ .dead = try jsonUnescape(alloc, raw) },
        .ok => |raw| {
            const next = try jsonUnescape(alloc, raw);
            defer alloc.free(next);
            return resolve(alloc, http, next, dl_classify.classify(next, "", "", ""), depth + 1);
        },
    }
}

fn resolvePixeldrain(alloc: std.mem.Allocator, http: Http, href: []const u8) errs.Error!Result {
    const id = pixeldrainId(href) orelse return .needs_browser;
    const url = std.fmt.allocPrint(alloc, "https://pixeldrain.com/api/file/{s}?download", .{id}) catch
        return errs.Error.OutOfMemory;
    errdefer alloc.free(url);

    var filename: ?[]u8 = null;
    errdefer if (filename) |f| alloc.free(f);
    var size: ?u64 = null;

    const info_url = std.fmt.allocPrint(alloc, "https://pixeldrain.com/api/file/{s}/info", .{id}) catch
        return errs.Error.OutOfMemory;
    defer alloc.free(info_url);
    // Info is a nicety: any failure leaves filename/size unset.
    if (http.get(http.ctx, alloc, info_url)) |body| {
        defer alloc.free(body);
        const Info = struct { name: ?[]const u8 = null, size: ?u64 = null };
        if (std.json.parseFromSlice(Info, alloc, body, .{ .ignore_unknown_fields = true })) |parsed| {
            defer parsed.deinit();
            size = parsed.value.size;
            if (parsed.value.name) |n| {
                if (n.len > 0) filename = try dupe(alloc, n);
            }
        } else |_| {}
    } else |_| {}

    const headers = try alloc.alloc([]const u8, 0);
    return .{ .direct = .{ .url = url, .headers = headers, .filename = filename, .size = size, .engine = .aria2_http } };
}

/// Takes ownership of `url` (frees it on failure).
fn directPlain(alloc: std.mem.Allocator, url: []u8) errs.Error!Result {
    errdefer alloc.free(url);
    const headers = try alloc.alloc([]const u8, 0);
    return .{ .direct = .{ .url = url, .headers = headers, .engine = .aria2_http } };
}

fn dupe(alloc: std.mem.Allocator, s: []const u8) errs.Error![]u8 {
    return alloc.dupe(u8, s) catch errs.Error.OutOfMemory;
}

// ---- pure parsers ----

pub const MaskedReply = union(enum) {
    /// Raw JSON string contents (may contain escapes such as `\/`).
    ok: []const u8,
    not_ok: []const u8,
    html,
};

/// Classifies the reply to a masked-link POST. Strings are slices of `body`
/// and still JSON-escaped.
pub fn parseMaskedReply(body: []const u8) MaskedReply {
    const t = std.mem.trim(u8, body, " \t\r\n");
    if (t.len == 0 or t[0] != '{') return .html;
    const status = jsonStringField(t, "status") orelse return .html;
    const msg = jsonStringField(t, "msg");
    if (std.mem.eql(u8, status, "ok")) {
        return if (msg) |m| .{ .ok = m } else .html;
    }
    return .{ .not_ok = msg orelse "" };
}

/// Raw contents of `"key":"…"` (first match), without the quotes.
fn jsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, json, from, key)) |i| {
        from = i + key.len;
        if (i == 0 or json[i - 1] != '"') continue;
        var p = i + key.len;
        if (p >= json.len or json[p] != '"') continue;
        p += 1;
        while (p < json.len and (json[p] == ' ' or json[p] == ':')) : (p += 1) {}
        if (p >= json.len or json[p] != '"') continue;
        const start = p + 1;
        var q = start;
        while (q < json.len) : (q += 1) {
            if (json[q] == '\\') {
                q += 1;
                continue;
            }
            if (json[q] == '"') return json[start..q];
        }
        return null;
    }
    return null;
}

fn jsonUnescape(alloc: std.mem.Allocator, raw: []const u8) errs.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c != '\\' or i + 1 >= raw.len) {
            out.append(alloc, c) catch return errs.Error.OutOfMemory;
            continue;
        }
        i += 1;
        switch (raw[i]) {
            'n' => out.append(alloc, '\n') catch return errs.Error.OutOfMemory,
            't' => out.append(alloc, '\t') catch return errs.Error.OutOfMemory,
            'r' => out.append(alloc, '\r') catch return errs.Error.OutOfMemory,
            'u' => {
                const cp: ?u21 = if (i + 4 < raw.len)
                    std.fmt.parseInt(u21, raw[i + 1 .. i + 5], 16) catch null
                else
                    null;
                var buf: [4]u8 = undefined;
                if (cp) |v| {
                    const n = std.unicode.utf8Encode(v, &buf) catch 0;
                    if (n > 0) {
                        out.appendSlice(alloc, buf[0..n]) catch return errs.Error.OutOfMemory;
                        i += 4;
                        continue;
                    }
                }
                out.append(alloc, '?') catch return errs.Error.OutOfMemory;
            },
            else => |e| out.append(alloc, e) catch return errs.Error.OutOfMemory,
        }
    }
    return out.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

fn idUntilDelim(s: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < s.len and s[end] != '/' and s[end] != '?' and s[end] != '#' and s[end] != '&') : (end += 1) {}
    if (end == 0) return null;
    return s[0..end];
}

/// `/u/<id>` or `/api/file/<id>`; list links (`/l/<id>`) give null.
pub fn pixeldrainId(href: []const u8) ?[]const u8 {
    const no_scheme = if (std.mem.indexOf(u8, href, "://")) |i| href[i + 3 ..] else href;
    const path_start = std.mem.indexOfScalar(u8, no_scheme, '/') orelse return null;
    const path = no_scheme[path_start..];
    inline for (.{ "/u/", "/api/file/" }) |pre| {
        if (std.mem.startsWith(u8, path, pre)) return idUntilDelim(path[pre.len..]);
    }
    return null;
}

/// `/file/d/<id>/…`, `open?id=<id>`, `uc?id=<id>&…`.
pub fn driveId(href: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, href, "/file/d/")) |i| return idUntilDelim(href[i + "/file/d/".len ..]);
    const q = std.mem.indexOfScalar(u8, href, '?') orelse return null;
    var it = std.mem.splitScalar(u8, href[q + 1 ..], '&');
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv, "id=")) return idUntilDelim(kv[3..]);
    }
    return null;
}

/// The `href` of the anchor labelled `aria-label="Download file"` (or with
/// `id="downloadButton"`) on a MediaFire page.
pub fn mediafireDirect(page: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, page, from, "<a ")) |a| {
        const end = std.mem.indexOfScalarPos(u8, page, a, '>') orelse return null;
        const tag = page[a..end];
        from = end;
        if (std.mem.indexOf(u8, tag, "aria-label=\"Download file\"") == null and
            std.mem.indexOf(u8, tag, "id=\"downloadButton\"") == null) continue;
        var h: usize = 0;
        while (std.mem.indexOfPos(u8, tag, h, "href=\"")) |hi| {
            h = hi + 1;
            if (hi > 0 and tag[hi - 1] != ' ') continue;
            const start = hi + "href=\"".len;
            const close = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
            if (close == start) return null;
            return tag[start..close];
        }
    }
    return null;
}

// ---- tests ----

const Stub = struct {
    const Route = struct { url_prefix: []const u8, status: u16 = 200, body: []const u8 };
    routes: []const Route,
    cookie: ?[]const u8 = null,

    fn http(self: *Stub) Http {
        return .{ .ctx = self, .get = stubGet, .postForm = stubPost, .cookieHeader = stubCookie };
    }
    fn find(self: *Stub, url: []const u8) ?Route {
        for (self.routes) |r| if (std.mem.startsWith(u8, url, r.url_prefix)) return r;
        return null;
    }
    fn stubGet(ctx: *anyopaque, alloc: std.mem.Allocator, url: []const u8) errs.Error![]u8 {
        const self: *Stub = @ptrCast(@alignCast(ctx));
        const r = self.find(url) orelse return errs.Error.NotFound;
        return alloc.dupe(u8, r.body) catch return errs.Error.OutOfMemory;
    }
    fn stubPost(ctx: *anyopaque, alloc: std.mem.Allocator, url: []const u8, body: []const u8, hdrs: []const []const u8) errs.Error!Http.Reply {
        const self: *Stub = @ptrCast(@alignCast(ctx));
        std.debug.assert(std.mem.eql(u8, body, "xhr=1&download=1"));
        std.debug.assert(hdrs.len == 2);
        const r = self.find(url) orelse return errs.Error.NotFound;
        return .{ .status = r.status, .body = alloc.dupe(u8, r.body) catch return errs.Error.OutOfMemory };
    }
    fn stubCookie(ctx: *anyopaque) ?[]const u8 {
        const self: *Stub = @ptrCast(@alignCast(ctx));
        return self.cookie;
    }
};

fn run(stub: *Stub, href: []const u8) !Result {
    return resolve(std.testing.allocator, stub.http(), href, dl_classify.classify(href, "", "", ""), 0);
}

test "parseMaskedReply ok / not_ok / html" {
    const a = parseMaskedReply("{\"status\":\"ok\",\"msg\":\"https://pixeldrain.com/u/abc\"}");
    try std.testing.expectEqualStrings("https://pixeldrain.com/u/abc", a.ok);
    const b = parseMaskedReply("{\"status\":\"error\",\"msg\":\"Link is dead\"}");
    try std.testing.expectEqualStrings("Link is dead", b.not_ok);
    try std.testing.expect(parseMaskedReply("<!DOCTYPE html><html></html>") == .html);
}

test "pixeldrainId" {
    try std.testing.expectEqualStrings("abc", pixeldrainId("https://pixeldrain.com/u/abc").?);
    try std.testing.expectEqualStrings("abc", pixeldrainId("https://pixeldrain.com/api/file/abc?download").?);
    try std.testing.expect(pixeldrainId("https://pixeldrain.com/l/abc") == null);
}

test "driveId" {
    try std.testing.expectEqualStrings("ID1", driveId("https://drive.google.com/file/d/ID1/view?usp=sharing").?);
    try std.testing.expectEqualStrings("ID2", driveId("https://drive.google.com/open?id=ID2").?);
    try std.testing.expectEqualStrings("ID3", driveId("https://drive.google.com/uc?id=ID3&export=download").?);
    try std.testing.expect(driveId("https://drive.google.com/drive/folders/x") == null);
}

test "mediafireDirect" {
    const page = "<div><a class=\"input popsok\" aria-label=\"Download file\" href=\"https://download2267.mediafire.com/x/file.zip\" id=\"x\">Download</a>";
    try std.testing.expectEqualStrings("https://download2267.mediafire.com/x/file.zip", mediafireDirect(page).?);
    try std.testing.expect(mediafireDirect("<a href=\"https://other\">x</a>") == null);
}

test "resolve: masked -> pixeldrain with info" {
    var stub = Stub{ .routes = &.{
        .{ .url_prefix = "https://f95zone.to/masked/", .body = "{\"status\":\"ok\",\"msg\":\"https:\\/\\/pixeldrain.com\\/u\\/abc\"}" },
        .{ .url_prefix = "https://pixeldrain.com/api/file/abc/info", .body = "{\"name\":\"Game.zip\",\"size\":12345}" },
    } };
    var r = try run(&stub, "https://f95zone.to/masked/pixeldrain.com/abc/x");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("https://pixeldrain.com/api/file/abc?download", r.direct.url);
    try std.testing.expectEqualStrings("Game.zip", r.direct.filename.?);
    try std.testing.expectEqual(@as(?u64, 12345), r.direct.size);
    try std.testing.expectEqual(model.EngineKind.aria2_http, r.direct.engine);
}

test "resolve: masked 403 and AuthRequired -> auth_required" {
    var stub = Stub{ .routes = &.{.{ .url_prefix = "https://f95zone.to/masked/", .status = 403, .body = "no" }} };
    var r = try run(&stub, "https://f95zone.to/masked/pixeldrain.com/abc/x");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r == .auth_required);
}

test "resolve: masked html -> needs_browser" {
    var stub = Stub{ .routes = &.{.{ .url_prefix = "https://f95zone.to/masked/", .body = "<!DOCTYPE html><html>captcha</html>" }} };
    var r = try run(&stub, "https://f95zone.to/masked/pixeldrain.com/abc/x");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r == .needs_browser);
}

test "resolve: masked not ok -> dead" {
    var stub = Stub{ .routes = &.{.{ .url_prefix = "https://f95zone.to/masked/", .body = "{\"status\":\"error\",\"msg\":\"Link is dead\"}" }} };
    var r = try run(&stub, "https://f95zone.to/masked/pixeldrain.com/abc/x");
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Link is dead", r.dead);
}

test "resolve: workupload, dead, mega, google drive, mediafire, torrent" {
    var stub = Stub{ .routes = &.{
        .{ .url_prefix = "https://www.mediafire.com/", .body = "<a aria-label=\"Download file\" href=\"https://download1.mediafire.com/a/f.zip\">" },
    } };
    {
        var r = try run(&stub, "https://workupload.com/file/abc");
        defer r.deinit(std.testing.allocator);
        try std.testing.expect(r == .needs_browser);
    }
    {
        var r = try run(&stub, "https://anonfiles.com/abc/file");
        defer r.deinit(std.testing.allocator);
        try std.testing.expect(r == .dead);
    }
    {
        var r = try run(&stub, "https://mega.nz/file/abc#key");
        defer r.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("https://mega.nz/file/abc#key", r.mega);
    }
    {
        var r = try run(&stub, "https://drive.google.com/file/d/ID1/view");
        defer r.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("https://drive.usercontent.google.com/download?id=ID1&export=download&confirm=t", r.direct.url);
    }
    {
        var r = try run(&stub, "https://www.mediafire.com/file/abc/f.zip/file");
        defer r.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("https://download1.mediafire.com/a/f.zip", r.direct.url);
    }
    {
        var r = try run(&stub, "https://example.org/a.torrent");
        defer r.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("https://example.org/a.torrent", r.torrent_url);
    }
}

test "resolve: f95 attachment with and without cookie" {
    const href = "https://attachments.f95zone.to/2024/01/123_game.zip";
    var stub = Stub{ .routes = &.{}, .cookie = "Cookie: xf_user=1" };
    {
        var r = try run(&stub, href);
        defer r.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(href, r.direct.url);
        try std.testing.expectEqual(@as(usize, 1), r.direct.headers.len);
        try std.testing.expectEqualStrings("Cookie: xf_user=1", r.direct.headers[0]);
    }
    stub.cookie = null;
    var r = try run(&stub, href);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(r == .auth_required);
}

test "engineFor" {
    const e = dl_classify.classify("https://mega.nz/file/a", "", "", "");
    try std.testing.expectEqual(model.EngineKind.megacmd, engineFor(e, "https://mega.nz/file/a"));
    const o = dl_classify.classify("https://x.org/a", "", "", "");
    try std.testing.expectEqual(model.EngineKind.aria2_torrent, engineFor(o, "magnet:?xt=1"));
    try std.testing.expectEqual(model.EngineKind.aria2_torrent, engineFor(o, "https://x.org/a.torrent"));
    try std.testing.expectEqual(model.EngineKind.aria2_http, engineFor(o, "https://x.org/a.zip"));
}
