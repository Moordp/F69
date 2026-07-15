// RPDL torrent fetch + auth.
//
// Endpoints (ported from F95Checker/modules/rpdl.py):
//
//   POST https://dl.rpdl.net/api/user/login
//        body: {"login": "<user>", "password": "<pass>"}
//        resp: {"data": {"username": "<user>", "token": "<jwt-ish>"}}
//
//   GET  https://dl.rpdl.net/api/torrent/download/{id}
//        header: Authorization: Bearer <token>
//        resp:   raw bencoded .torrent bytes (Content-Type varies)
//
// We do not piggyback on f95.Client — RPDL is its own host with its own
// auth scheme. Each call uses a short-lived std.http.Client.
//
// Token storage is the caller's concern (plaintext at <data_root>/rpdl_token
// today; a Secret Service backend is on the roadmap).

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.rpdl);
const errs = @import("errors.zig");
const version_mod = @import("util_version");
const util_http = @import("util_http");

pub const BASE_URL = "https://dl.rpdl.net";
const LOGIN_URL = BASE_URL ++ "/api/user/login";
const DOWNLOAD_URL_FMT = BASE_URL ++ "/api/torrent/download/{d}";
const SEARCH_URL_FMT = BASE_URL ++ "/api/torrents?page_size=50&page=0&sort=uploaded_DESC&categories=&search={s}";

/// One torrent entry returned by `/api/torrents?search=…`.
/// All slices are `alloc`-owned; caller frees via `freeSearchResults`.
pub const TorrentMatch = struct {
    id: u64,
    title: []const u8,
    file_size: u64,
    seeders: u32,
    leechers: u32,
    upload_date: []const u8,
};

pub fn freeSearchResults(alloc: std.mem.Allocator, results: []TorrentMatch) void {
    for (results) |m| {
        alloc.free(m.title);
        alloc.free(m.upload_date);
    }
    alloc.free(results);
}

/// Cap on the JSON login response. The real body is ~150 bytes.
const MAX_LOGIN_RESPONSE: usize = 32 * 1024;
/// Cap on a single .torrent file. Real-world .torrents top out around
/// 1 MiB even for huge multi-file releases; 8 MiB is the safety net.
pub const MAX_TORRENT_BYTES: usize = 8 * 1024 * 1024;

/// POST credentials to RPDL, return the bearer token. Allocator-owned;
/// caller frees.
pub fn login(
    alloc: std.mem.Allocator,
    io: Io,
    username: []const u8,
    password: []const u8,
) errs.Error![]u8 {
    log.debug("login: user='{s}' (pw len={d})", .{ username, password.len });
    if (username.len == 0 or password.len == 0) return errs.Error.AuthRequired;

    // Stdlib JSON does the escape for us — no need for a hand-rolled
    // string formatter that re-implements the same rules.
    var body_aw: Io.Writer.Allocating = .init(alloc);
    defer body_aw.deinit();
    std.json.Stringify.value(
        .{ .login = username, .password = password },
        .{},
        &body_aw.writer,
    ) catch return errs.Error.OutOfMemory;
    const body_bytes = body_aw.writer.buffered();

    const extra_headers = [_]util_http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "application/json" },
    };

    const resp = util_http.fetch(alloc, io, LOGIN_URL, .{
        .method = .POST,
        .payload = body_bytes,
        .extra_headers = &extra_headers,
        .max_response_bytes = MAX_LOGIN_RESPONSE,
    }) catch |e| {
        log.warn("RPDL login network error: {s}", .{@errorName(e)});
        return errs.Error.NetworkError;
    };
    defer alloc.free(resp.body);

    if (resp.status != 200) {
        log.warn("RPDL login status {d}", .{resp.status});
        return switch (resp.status) {
            401, 403 => errs.Error.AuthRequired,
            else => errs.Error.NetworkError,
        };
    }

    const tok = parseLoginResponse(alloc, resp.body) catch |e| return e;
    log.info("RPDL login OK ({d}-byte token)", .{tok.len});
    return tok;
}

fn parseLoginResponse(alloc: std.mem.Allocator, body: []const u8) errs.Error![]u8 {
    const TokenContainer = struct {
        data: ?struct {
            username: ?[]const u8 = null,
            token: ?[]const u8 = null,
        } = null,
    };
    var parsed = std.json.parseFromSlice(TokenContainer, alloc, body, .{
        .ignore_unknown_fields = true,
    }) catch return errs.Error.RpdlInvalidResponse;
    defer parsed.deinit();

    const data = parsed.value.data orelse return errs.Error.AuthRequired;
    const tok = data.token orelse return errs.Error.AuthRequired;
    if (tok.len == 0) return errs.Error.AuthRequired;
    return alloc.dupe(u8, tok) catch errs.Error.OutOfMemory;
}

/// Search the RPDL catalog for torrents matching `query`. No auth
/// required. Results sorted newest-first; caller picks a winner.
/// Owns the returned slice + each entry's inner strings — free via
/// `freeSearchResults`.
pub fn search(
    alloc: std.mem.Allocator,
    io: Io,
    query: []const u8,
) errs.Error![]TorrentMatch {
    // Sanitize: RPDL's search field works best on bare alnum runs.
    // xlibrary-linux strips everything else; we follow suit.
    var sanitized: std.ArrayList(u8) = .empty;
    defer sanitized.deinit(alloc);
    for (query) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            sanitized.append(alloc, c) catch return errs.Error.OutOfMemory;
        }
    }
    if (sanitized.items.len == 0) return errs.Error.NotFound;

    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, SEARCH_URL_FMT, .{sanitized.items}) catch
        return errs.Error.RpdlInvalidResponse;

    log.info("search: query='{s}' sanitized='{s}'", .{ query, sanitized.items });
    log.debug("search: GET {s}", .{url});
    const resp = util_http.fetch(alloc, io, url, .{}) catch |e| {
        log.warn("RPDL search network error: {s}", .{@errorName(e)});
        return errs.Error.NetworkError;
    };
    defer alloc.free(resp.body);

    if (resp.status != 200) {
        log.warn("RPDL search status {d}", .{resp.status});
        return errs.Error.NetworkError;
    }
    log.info("search: HTTP 200, {d} bytes received", .{resp.body.len});
    const matches = try parseSearchResponse(alloc, resp.body);
    log.info("search: parsed {d} torrent(s)", .{matches.len});
    if (matches.len > 0) {
        const cap = @min(matches.len, 5);
        for (matches[0..cap]) |m| {
            log.info("  -> id={d} seed={d} leech={d} title='{s}'", .{ m.id, m.seeders, m.leechers, m.title });
        }
    }
    return matches;
}

fn parseSearchResponse(alloc: std.mem.Allocator, body: []const u8) errs.Error![]TorrentMatch {
    // Actual response shape (xlibrary-linux confirms):
    //   {"data":{"results":[
    //     {"torrent_id":123,"title":"…","file_size":N,
    //      "seeders":S,"leechers":L,"upload_date":1652336851 OR "YYYY-MM-DD…"},
    //     …
    //   ]}}
    // Older RPDL deployments shipped `{"data":[…]}` (array) and used
    // `id` instead of `torrent_id`. We walk a generic `std.json.Value`
    // so the field types stay forgiving (upload_date can be number OR
    // string; numeric fields can be int OR float; etc.).
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{
        .ignore_unknown_fields = true,
    }) catch |e| {
        log.warn("rpdl search: JSON parse failed: {s} ({d} bytes)", .{ @errorName(e), body.len });
        return errs.Error.RpdlInvalidResponse;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        log.warn("rpdl search: top-level is not an object", .{});
        return errs.Error.RpdlInvalidResponse;
    }

    // Locate the entry array, accepting:
    //   data.results = [...]   (modern)
    //   data = [...]           (legacy)
    //   torrents = [...]       (legacy alt)
    const items: []std.json.Value = blk: {
        if (root.object.get("data")) |d| {
            switch (d) {
                .array => |a| break :blk a.items,
                .object => |obj| {
                    if (obj.get("results")) |r| {
                        if (r == .array) break :blk r.array.items;
                    }
                },
                else => {},
            }
        }
        if (root.object.get("torrents")) |t| {
            if (t == .array) break :blk t.array.items;
        }
        log.warn("rpdl search: could not locate results array", .{});
        return errs.Error.RpdlInvalidResponse;
    };

    return try buildMatches(alloc, items);
}

/// Internal — turn the parsed JSON entries into our owned slice.
fn buildMatches(alloc: std.mem.Allocator, items: []std.json.Value) errs.Error![]TorrentMatch {
    var out: std.ArrayList(TorrentMatch) = .empty;
    errdefer {
        for (out.items) |m| {
            alloc.free(m.title);
            alloc.free(m.upload_date);
        }
        out.deinit(alloc);
    }
    for (items) |entry| {
        if (entry != .object) continue;
        const obj = entry.object;

        const id = jsonU64(obj, "torrent_id") orelse jsonU64(obj, "id") orelse continue;
        const title_src = jsonStr(obj, "title") orelse jsonStr(obj, "name") orelse continue;
        const size: u64 = jsonU64(obj, "file_size") orelse jsonU64(obj, "size") orelse 0;
        const seeders: u32 = @intCast(@min(jsonU64(obj, "seeders") orelse 0, std.math.maxInt(u32)));
        const leechers: u32 = @intCast(@min(jsonU64(obj, "leechers") orelse 0, std.math.maxInt(u32)));

        // upload_date arrives as either a string ("2024-…") or a unix
        // timestamp integer. Normalise to a decimal-zero-padded string
        // so `std.mem.order` lex-compare still gives DESC-by-time.
        var date_buf: [32]u8 = undefined;
        const date_src: []const u8 = blk: {
            if (jsonStr(obj, "upload_date")) |s| break :blk s;
            if (jsonStr(obj, "uploaded_at")) |s| break :blk s;
            if (jsonI64(obj, "upload_date")) |n| {
                break :blk std.fmt.bufPrint(&date_buf, "{d:0>11}", .{n}) catch "";
            }
            if (jsonI64(obj, "uploaded_at")) |n| {
                break :blk std.fmt.bufPrint(&date_buf, "{d:0>11}", .{n}) catch "";
            }
            break :blk "";
        };

        const m: TorrentMatch = .{
            .id = id,
            .title = alloc.dupe(u8, title_src) catch return errs.Error.OutOfMemory,
            .file_size = size,
            .seeders = seeders,
            .leechers = leechers,
            .upload_date = alloc.dupe(u8, date_src) catch return errs.Error.OutOfMemory,
        };
        out.append(alloc, m) catch return errs.Error.OutOfMemory;
    }
    return out.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

/// Pull a string from a json object, accepting only the string variant.
fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string, .number_string => |s| s,
        else => null,
    };
}

/// Pull a non-negative integer, accepting integer, float, or numeric
/// string (RPDL has been observed using any of the three for size).
fn jsonU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i < 0) null else @intCast(i),
        .float => |f| if (f < 0 or !std.math.isFinite(f)) null else @intFromFloat(f),
        .number_string, .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

/// Pull a signed integer (used for unix timestamps which fit in i64).
fn jsonI64(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (!std.math.isFinite(f)) null else @intFromFloat(f),
        .number_string, .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Pick the best RPDL torrent for `(name, version)` from a search
/// result slice. Strategy:
///   1. Sanitize game name (alnum-only, lowercase) and require it to
///      appear (substring, sanitized) in the torrent's title.
///   2. Among survivors, prefer torrents whose title-extracted version
///      is canonically equivalent to the F95-scraped one
///      (`util_version.equivalent`).
///   3. Tie-break on seeders DESC, then on upload_date DESC.
///   4. Reject torrents with zero seeders — guaranteed-stuck downloads.
/// Returns null when no entry passes the filter.
pub fn pickBestMatch(
    results: []const TorrentMatch,
    name: []const u8,
    version: ?[]const u8,
) ?*const TorrentMatch {
    var buf: [128]u8 = undefined;
    const name_norm = sanitizeAlnumLower(&buf, name) orelse {
        log.warn("pickBestMatch: name '{s}' has no alphanumerics after sanitize", .{name});
        return null;
    };
    log.info("pickBestMatch: name='{s}' ({d} char norm) version={?s}, {d} candidates", .{
        name, name_norm.len, version, results.len,
    });

    var best: ?*const TorrentMatch = null;
    var best_has_version: bool = false;
    var best_seeders: u32 = 0;
    var best_date: []const u8 = "";

    for (results) |*m| {
        if (m.seeders == 0) {
            log.debug("  skip id={d} ({s}) — zero seeders", .{ m.id, m.title });
            continue;
        }
        var t_buf: [256]u8 = undefined;
        const t_norm = sanitizeAlnumLower(&t_buf, m.title) orelse continue;
        if (std.mem.indexOf(u8, t_norm, name_norm) == null) {
            log.debug("  skip id={d} ({s}) — sanitized title doesn't contain name", .{ m.id, m.title });
            continue;
        }
        const has_version = if (version) |v| blk: {
            if (v.len == 0) break :blk false;
            // Extract whichever version segment the torrent title
            // carries and ask util_version to decide equivalence.
            // Handles "Game-EP12-v0.20-Linux" ↔ "0.20.0" cases the
            // old sanitized-substring scan couldn't.
            const t_ver = version_mod.extractFromTitle(m.title) orelse break :blk false;
            break :blk version_mod.equivalent(v, t_ver);
        } else false;

        if (best == null) {
            best = m;
            best_has_version = has_version;
            best_seeders = m.seeders;
            best_date = m.upload_date;
            continue;
        }
        // Prefer the entry that actually matches the parsed version.
        if (has_version and !best_has_version) {
            best = m;
            best_has_version = true;
            best_seeders = m.seeders;
            best_date = m.upload_date;
            continue;
        }
        if (!has_version and best_has_version) continue;
        // Same version-match status — fall to seeders / date.
        if (m.seeders > best_seeders or
            (m.seeders == best_seeders and std.mem.order(u8, m.upload_date, best_date) == .gt))
        {
            best = m;
            best_seeders = m.seeders;
            best_date = m.upload_date;
        }
    }
    if (best) |b| {
        log.info("pickBestMatch: chose id={d} seed={d} date='{s}' title='{s}' (version_match={any})", .{
            b.id, b.seeders, b.upload_date, b.title, best_has_version,
        });
    } else {
        log.warn("pickBestMatch: no eligible torrent (all 0-seed or no name match)", .{});
    }
    return best;
}

/// Lowercase + alnum-only copy of `src` into `buf`. Returns the
/// filled slice, or null when `buf` is too small. Used by the match
/// picker so " RPGM - Game's Name [v0.5] " collapses to "rpgmgamesnameev05".
fn sanitizeAlnumLower(buf: []u8, src: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (src) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (n >= buf.len) return null;
            buf[n] = std.ascii.toLower(c);
            n += 1;
        }
    }
    return buf[0..n];
}

test "sanitizeAlnumLower basics" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("renpygame", sanitizeAlnumLower(&buf, "Ren'Py - Game!").?);
    try std.testing.expectEqualStrings("v05a", sanitizeAlnumLower(&buf, " v0.5a ").?);
}

test "pickBestMatch: prefers version match" {
    const results = [_]TorrentMatch{
        .{ .id = 1, .title = "Foo v0.4", .file_size = 0, .seeders = 50, .leechers = 0, .upload_date = "2023-01-01" },
        .{ .id = 2, .title = "Foo v0.5", .file_size = 0, .seeders = 10, .leechers = 0, .upload_date = "2024-01-01" },
    };
    const m = pickBestMatch(&results, "Foo", "v0.5").?;
    try std.testing.expectEqual(@as(u64, 2), m.id);
}

test "pickBestMatch: zero-seeder rejected" {
    const results = [_]TorrentMatch{
        .{ .id = 1, .title = "Bar", .file_size = 0, .seeders = 0, .leechers = 0, .upload_date = "2024-01-01" },
    };
    try std.testing.expect(pickBestMatch(&results, "Bar", null) == null);
}

test "pickBestMatch: ties broken by seeders, then date" {
    const results = [_]TorrentMatch{
        .{ .id = 1, .title = "Baz", .file_size = 0, .seeders = 5, .leechers = 0, .upload_date = "2024-02-01" },
        .{ .id = 2, .title = "Baz", .file_size = 0, .seeders = 5, .leechers = 0, .upload_date = "2024-03-01" },
        .{ .id = 3, .title = "Baz", .file_size = 0, .seeders = 7, .leechers = 0, .upload_date = "2023-01-01" },
    };
    const m = pickBestMatch(&results, "Baz", null).?;
    try std.testing.expectEqual(@as(u64, 3), m.id);
}

/// GET the bencoded .torrent file for the given RPDL torrent id.
/// Allocator-owned bytes; caller frees.
pub fn fetchTorrent(
    alloc: std.mem.Allocator,
    io: Io,
    token: []const u8,
    torrent_id: u64,
) errs.Error![]u8 {
    if (token.len == 0) return errs.Error.AuthRequired;

    var url_buf: [128]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, DOWNLOAD_URL_FMT, .{torrent_id}) catch
        return errs.Error.RpdlInvalidResponse;

    var auth_buf: [512]u8 = undefined;
    const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch
        return errs.Error.AuthRequired;

    const extra_headers = [_]util_http.Header{
        .{ .name = "authorization", .value = auth_value },
        .{ .name = "accept", .value = "application/x-bittorrent, application/octet-stream" },
    };

    log.debug("fetchTorrent: GET {s}", .{url});
    const resp = util_http.fetch(alloc, io, url, .{
        .extra_headers = &extra_headers,
        .max_response_bytes = MAX_TORRENT_BYTES,
    }) catch |e| {
        log.warn("RPDL fetchTorrent network error: {s}", .{@errorName(e)});
        return errs.Error.NetworkError;
    };
    errdefer alloc.free(resp.body);

    if (resp.status != 200) {
        log.warn("RPDL fetchTorrent status {d}", .{resp.status});
        alloc.free(resp.body);
        return switch (resp.status) {
            401, 403 => errs.Error.AuthRequired,
            404 => errs.Error.NotFound,
            else => errs.Error.NetworkError,
        };
    }

    // Bencoded torrent files always start with 'd' (dict). Any HTML or
    // JSON error body that slipped past status==200 would start with
    // '<' or '{'.
    if (!isBencodedDict(resp.body)) {
        log.warn("RPDL fetchTorrent: body not bencoded ({d} bytes)", .{resp.body.len});
        alloc.free(resp.body);
        return errs.Error.RpdlInvalidResponse;
    }
    log.info("RPDL fetchTorrent OK: torrent_id={d}, {d} bytes", .{ torrent_id, resp.body.len });
    return resp.body;
}

fn isBencodedDict(bytes: []const u8) bool {
    return bytes.len > 0 and bytes[0] == 'd';
}

// `appendJsonStr` removed — login body now goes through
// `std.json.Stringify.value` which does the escape itself.

// ============================================================
//  tests
// ============================================================

test "parseLoginResponse: happy path" {
    const body =
        \\{"data":{"username":"alice","token":"tok123"}}
    ;
    const t = try parseLoginResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("tok123", t);
}

test "parseLoginResponse: ignores extra fields" {
    const body =
        \\{"data":{"username":"a","token":"xyz","is_admin":false},"extra":1}
    ;
    const t = try parseLoginResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("xyz", t);
}

test "parseLoginResponse: missing token → AuthRequired" {
    const body =
        \\{"data":{"username":"alice"}}
    ;
    try std.testing.expectError(
        errs.Error.AuthRequired,
        parseLoginResponse(std.testing.allocator, body),
    );
}

test "parseLoginResponse: empty token → AuthRequired" {
    const body =
        \\{"data":{"username":"a","token":""}}
    ;
    try std.testing.expectError(
        errs.Error.AuthRequired,
        parseLoginResponse(std.testing.allocator, body),
    );
}

test "parseLoginResponse: malformed → RpdlInvalidResponse" {
    const body = "{ not json";
    try std.testing.expectError(
        errs.Error.RpdlInvalidResponse,
        parseLoginResponse(std.testing.allocator, body),
    );
}

test "isBencodedDict" {
    try std.testing.expect(isBencodedDict("d8:announce..."));
    try std.testing.expect(!isBencodedDict("<html>"));
    try std.testing.expect(!isBencodedDict("{json}"));
    try std.testing.expect(!isBencodedDict(""));
}

test "fetchTorrent: empty token rejected without network" {
    try std.testing.expectError(
        errs.Error.AuthRequired,
        fetchTorrent(std.testing.allocator, undefined, "", 42),
    );
}

test "fuzz: pickBestMatch survives arbitrary titles and names" {
    // Multi-call Smith stream — fuzzSeed corpus only fits single-slice
    // harnesses; the automatic empty-input run is the replay smoke test.
    try std.testing.fuzz({}, fuzzPickBestMatch, .{});
}

fn fuzzPickBestMatch(_: void, smith: *std.testing.Smith) anyerror!void {
    var name_buf: [200]u8 = undefined;
    const name_len = smith.slice(&name_buf);
    var title_a: [300]u8 = undefined;
    const title_a_len = smith.slice(&title_a);
    var title_b: [300]u8 = undefined;
    const title_b_len = smith.slice(&title_b);
    var ver_buf: [64]u8 = undefined;
    const ver_len = smith.slice(&ver_buf);

    const results = [_]TorrentMatch{
        .{ .id = 1, .title = title_a[0..title_a_len], .file_size = 0, .seeders = smith.value(u8), .leechers = 0, .upload_date = "2026-01-01T00:00:00Z" },
        .{ .id = 2, .title = title_b[0..title_b_len], .file_size = 0, .seeders = smith.value(u8), .leechers = 0, .upload_date = "2025-12-31T00:00:00Z" },
    };
    _ = pickBestMatch(&results, name_buf[0..name_len], ver_buf[0..ver_len]);
    _ = pickBestMatch(&results, name_buf[0..name_len], null);
    _ = pickBestMatch(&.{}, name_buf[0..name_len], null);
}
