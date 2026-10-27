// Scrape the logged-in user's bookmarked threads from F95.
// Requires a session cookie on `client` — anonymous fetches get
// redirected to the login page.
//
// Since ~2026-10-24 F95 serves bookmarks from the watched-threads page
// (`/account/bookmarks` now returns the new `f95wg_watched` template,
// which is not a bookmark list). Same approach as F95Checker's
// `import_f95_bookmarks` (commit 2f17efc): two sources, merged.
//   * `?tab=bookmarks`                  — classic XenForo `listPlain`
//                                         (`contentRow-title` anchors)
//   * `?tab=new&src=bookmarked`         — new f95wg rows
//                                         (`f95wg-row-title` anchors)
// Only the `p-body-pageContent` region is parsed, so menu / sidebar
// thread links are never mistaken for bookmarks.
//
// Each source is walked from page 1 until a page has no rows (or
// repeats the previous page — XenForo clamps overflow pages) or we hit
// a hard cap (500). 78-page libraries are real on F95.
//
// Output is a slice of `BookmarkEntry`. Both the outer slice and the
// `thread_id` / `title` / `url` strings inside each entry are owned
// by `alloc`; caller frees via `freeAll`.

const std = @import("std");
const log = std.log.scoped(.bookmarks);
const errs = @import("errors.zig");
const domain = @import("domain.zig");
const Client = @import("client.zig").Client;
const cli = @import("client.zig");

const PAGE_BASE = cli.BASE_URL ++ "/watched/threads";
const MAX_PAGES = 500;

const Source = struct {
    /// Query string up to and including `page=`.
    query: []const u8,
    /// Class name of the element wrapping each row's thread anchor.
    row_marker: []const u8,
};

const SOURCES = [_]Source{
    .{ .query = "?tab=bookmarks&page=", .row_marker = "contentRow-title" },
    .{ .query = "?tab=new&src=bookmarked&hide_seen=0&page=", .row_marker = "f95wg-row-title" },
};

/// Optional progress sink for `fetchAll`. Caller passes atomic pointers
/// the function updates as it walks pages. All fields can be null —
/// then progress reporting is skipped.
pub const Progress = struct {
    /// Number of pages fetched so far.
    current: ?*std.atomic.Value(u32) = null,
    /// Total page count, derived from the pagination on page 1. Set
    /// once after the first page is fetched.
    total: ?*std.atomic.Value(u32) = null,
    /// Called after each page is processed. Lets the caller wake an
    /// idle event loop (e.g., `dvui.refresh`) so the UI redraws with
    /// the new progress value, AND consume this page's entries for
    /// live library updates. `page_entries` is borrowed for the
    /// duration of the call — callback MUST dupe anything it wants
    /// to keep (the underlying `out` ArrayList may reallocate before
    /// the next page).
    on_page: ?*const fn (ctx: ?*anyopaque, page_entries: []const domain.BookmarkEntry) void = null,
    ctx: ?*anyopaque = null,
    /// Cooperative-cancel flag. `fetchAll` checks between pages and
    /// returns `errs.Error.Cancelled` if set. The partial result
    /// (everything pulled so far) is freed before returning, so
    /// nothing leaks.
    cancel: ?*std.atomic.Value(bool) = null,
};

pub fn fetchAll(
    client: *Client,
    alloc: std.mem.Allocator,
    progress: Progress,
) errs.Error![]domain.BookmarkEntry {
    // `seen` is a dedup helper. Keys are *borrowed* pointers into
    // `out[i].thread_id` — the canonical owner is `out`. So this
    // defer drops only the bucket array, never the key bytes (which
    // would double-free).
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    var out: std.ArrayList(domain.BookmarkEntry) = .empty;
    errdefer freeListPartial(alloc, &out);

    // Initial total — bumped to the real page count after page 1.
    if (progress.total) |t| t.store(1, .release);

    var pages_done: u32 = 0;
    for (SOURCES, 0..) |src, src_idx| {
        const pages_before = pages_done;
        // First thread id of the previous page — XenForo serves the last
        // page again for out-of-range page numbers, so a repeat means done.
        var prev_first: [20]u8 = undefined;
        var prev_first_len: usize = 0;

        var page: u32 = 1;
        while (page <= MAX_PAGES) : (page += 1) {
            // Cooperative cancel — checked BEFORE each network round-trip
            // so a Cancel click never has to wait for an HTTP response.
            if (progress.cancel) |c| if (c.load(.acquire)) {
                log.info("bookmarks pull cancelled at page {d}", .{page});
                return errs.Error.Cancelled;
            };

            pages_done += 1;
            if (progress.current) |c| c.store(pages_done, .release);

            var url_buf: [160]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "{s}{s}{d}", .{ PAGE_BASE, src.query, page }) catch
                return errs.Error.OutOfMemory;

            const body = client.get(url) catch |e| {
                log.warn("fetch {s} page {d} failed: {s}", .{ src.query, page, @errorName(e) });
                // The second source is a bonus; keep what the first one gave us.
                if (src_idx > 0 and out.items.len > 0) break;
                return e;
            };
            defer alloc.free(body);

            // Page 1 carries the pagination markup that tells us the
            // total. Update the progress sink once per source.
            if (page == 1) {
                const total = extractPageNavTotal(body);
                log.info("bookmarks {s} total pages: {d}", .{ src.query, total });
                if (progress.total) |t| t.store(@intCast(pages_before + total), .release);
            }

            const before_count = out.items.len;
            const found = try collectRows(alloc, body, src.row_marker, &seen, &out);
            const added = out.items.len - before_count;

            log.info("{s} page {d}: {d} rows, +{d} (running total {d})", .{ src.query, page, found.rows, added, out.items.len });

            // Wake the UI and hand it this page's entries (so callers
            // can live-insert during the pull instead of waiting for
            // the final return). Slice is borrowed; callback dupes if
            // it needs persistence (future `out` reallocs invalidate).
            if (progress.on_page) |cb| cb(progress.ctx, out.items[before_count..]);

            if (found.rows == 0) {
                // Diagnostic: tell the user's log whether we got an
                // unexpected page (login redirect, error page, changed
                // markup) vs. genuinely no bookmarks.
                if (page == 1) {
                    log.warn("{s} page 1 had no rows. body len={d} pageContent={any} template='{s}'", .{
                        src.query,
                        body.len,
                        std.mem.indexOf(u8, body, "p-body-pageContent") != null,
                        dataTemplate(body),
                    });
                }
                break;
            }

            const first = found.first_id orelse "";
            if (prev_first_len > 0 and std.mem.eql(u8, first, prev_first[0..prev_first_len])) break;
            prev_first_len = @min(first.len, prev_first.len);
            @memcpy(prev_first[0..prev_first_len], first[0..prev_first_len]);
        }
    }

    return out.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

/// Parse XenForo pagination — find every reference to a page number
/// in the HTML and return the highest. F95's bookmarks page emits
/// links in several flavors depending on the skin:
///   * `<a href="…?page=78">78</a>`
///   * `<a href="…&amp;page=78">78</a>` (HTML-escaped ampersand)
///   * `<a href="…/page-78">78</a>`
///   * `data-page="78"` (XenForo's pageNav-jump button)
///   * `data-last-page="78"`
/// The max across all of them is the total.
pub fn extractTotalPages(html: []const u8) usize {
    var max: usize = 1;
    const markers = [_][]const u8{
        "?page=",
        "&page=",
        "&amp;page=",
        "page-",
        "data-page=\"",
        "data-last-page=\"",
    };
    for (markers) |marker| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, html, pos, marker)) |i| {
            const v_start = i + marker.len;
            var end = v_start;
            while (end < html.len and std.ascii.isDigit(html[end])) end += 1;
            if (end > v_start) {
                if (std.fmt.parseInt(usize, html[v_start..end], 10)) |n| {
                    if (n > max) max = n;
                } else |_| {}
            }
            pos = if (end > pos) end else pos + 1;
        }
    }
    log.debug("extractTotalPages = {d}", .{max});
    return max;
}

pub fn freeAll(alloc: std.mem.Allocator, entries: []domain.BookmarkEntry) void {
    for (entries) |e| {
        alloc.free(e.thread_id);
        alloc.free(e.title);
        alloc.free(e.url);
    }
    alloc.free(entries);
}

fn freeListPartial(alloc: std.mem.Allocator, list: *std.ArrayList(domain.BookmarkEntry)) void {
    for (list.items) |e| {
        alloc.free(e.thread_id);
        alloc.free(e.title);
        alloc.free(e.url);
    }
    list.deinit(alloc);
}

/// Rows found on one page, counted before dedup. `first_id` borrows from
/// the page body — copy it before the body is freed.
const RowsFound = struct {
    rows: usize = 0,
    first_id: ?[]const u8 = null,
};

/// How far past a row marker to look for its `<a href="…">`.
const ANCHOR_WINDOW = 1024;

/// The slice of `html` that holds the page's real content: from the
/// `p-body-pageContent` container up to the sidebar. Empty if the
/// container is missing (login redirect, error page, changed markup) so
/// menu / footer thread links can never be taken for bookmarks.
fn pageContent(html: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, html, "p-body-pageContent") orelse return html[0..0];
    const tail = html[start..];
    const end = std.mem.indexOf(u8, tail, "p-body-sidebar") orelse tail.len;
    return tail[0..end];
}

/// Value of the `data-template="…"` attribute, for diagnostics.
fn dataTemplate(html: []const u8) []const u8 {
    const key = "data-template=\"";
    const i = std.mem.indexOf(u8, html, key) orelse return "";
    const rest = html[i + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
    return rest[0..@min(end, 64)];
}

/// XenForo's pagination total, read only from the `pageNav` list so the
/// rest of the page (which can mention any `page-N`) can't inflate it.
/// 1 when there is no pagination.
fn extractPageNavTotal(html: []const u8) usize {
    const content = pageContent(html);
    const start = std.mem.indexOf(u8, content, "pageNav-main") orelse return 1;
    const tail = content[start..];
    const end = std.mem.indexOf(u8, tail, "</ul>") orelse tail.len;
    return extractTotalPages(tail[0..end]);
}

/// Walk the page content for row elements carrying `row_marker`, take the
/// `/threads/<slug>.<id>/` anchor inside each, extract numeric ids and
/// dedupe across pages and sources.
///
/// XenForo emits anchor `href`s as absolute URL or leading-slash path;
/// both contain `threads/`, which is what we key on.
///
/// Ownership: every alloc'd string lives inside `out[i]`. `seen`'s keys
/// borrow `out[i].thread_id` — `seen` does NOT own anything.
fn collectRows(
    alloc: std.mem.Allocator,
    html: []const u8,
    row_marker: []const u8,
    seen: *std.StringHashMap(void),
    out: *std.ArrayList(domain.BookmarkEntry),
) errs.Error!RowsFound {
    var res: RowsFound = .{};
    var rest = pageContent(html);
    while (std.mem.indexOf(u8, rest, row_marker)) |i| {
        rest = rest[i + row_marker.len ..];
        const window = rest[0..@min(rest.len, ANCHOR_WINDOW)];

        const a = std.mem.indexOf(u8, window, "<a ") orelse continue;
        const href_key = "href=\"";
        const k = std.mem.indexOfPos(u8, window, a, href_key) orelse continue;
        const v_start = k + href_key.len;
        const v_end = std.mem.indexOfScalarPos(u8, window, v_start, '"') orelse continue;
        const href = window[v_start..v_end];

        const t = std.mem.indexOf(u8, href, "threads/") orelse continue;
        const path = href[t + "threads/".len ..];
        const tid = parseTrailingId(path) orelse continue;

        res.rows += 1;
        if (res.first_id == null) res.first_id = tid;
        try appendEntry(alloc, path, tid, rest[v_end + 1 ..], seen, out);
    }
    return res;
}

/// Add one entry unless `tid` was already seen. `path` is what follows
/// `threads/` in the href; `after_href` starts right after the href's
/// closing quote (used to read the anchor text).
fn appendEntry(
    alloc: std.mem.Allocator,
    path: []const u8,
    tid: []const u8,
    after_href: []const u8,
    seen: *std.StringHashMap(void),
    out: *std.ArrayList(domain.BookmarkEntry),
) errs.Error!void {
    // Dedup BEFORE allocating — `seen` hashes by bytes so the
    // transient `tid` slice into `html` works for the lookup.
    if (seen.contains(tid)) return;

    const tid_owned = alloc.dupe(u8, tid) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(tid_owned);

    // Title: inner text up to `</a>` with tags stripped. Best-effort.
    const title_owned = stripTags(alloc, extractAnchorText(after_href) orelse "") catch
        return errs.Error.OutOfMemory;
    errdefer alloc.free(title_owned);

    // Canonical `<slug>.<id>/` — drop trailing `page-2` / `unread` bits.
    // F95 slugs can be long, so the buffer is generous; if it's STILL too
    // small, skip the entry (almost certainly malformed) instead of
    // mis-reporting as OOM.
    const seg_end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    var url_buf: [512]u8 = undefined;
    const url_full = std.fmt.bufPrint(&url_buf, "{s}/threads/{s}/", .{ cli.BASE_URL, path[0..seg_end] }) catch {
        log.warn("URL too long, skipping (path len={d})", .{path.len});
        return;
    };
    const url_owned = alloc.dupe(u8, url_full) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(url_owned);

    // Append to `out` first so on success the strings are owned
    // by an entry. Then put the key into `seen` (borrowing from
    // out). If `seen.put` fails after a successful append, we
    // tolerate the inconsistency — at worst we'd append a duplicate
    // entry on a later page (cheap waste, not a leak).
    out.append(alloc, .{
        .thread_id = tid_owned,
        .title = title_owned,
        .url = url_owned,
    }) catch return errs.Error.OutOfMemory;

    seen.put(tid_owned, {}) catch {};
}
/// `path` is the slice between `/threads/` and the closing `"`.
/// Examples:
///   "some-game.12345/"          → "12345"
///   "12345/"                    → "12345"
///   "some-game.12345/page-2"    → "12345"
/// Returns null if no trailing numeric run exists.
pub fn parseTrailingId(path: []const u8) ?[]const u8 {
    // Strip trailing slash + everything after the next slash.
    var seg_end: usize = 0;
    while (seg_end < path.len and path[seg_end] != '/') : (seg_end += 1) {}
    const segment = path[0..seg_end];

    // Walk back from the end of the segment over digits.
    var i: usize = segment.len;
    while (i > 0 and std.ascii.isDigit(segment[i - 1])) : (i -= 1) {}
    if (i == segment.len) return null;
    return segment[i..];
}

/// `<a …>Title</a>` — the anchor's inner HTML, tags and all. `appendEntry`
/// strips the tags; F95 puts label `<span>`s before and after the title,
/// so picking one nested piece would return a label instead of the name.
fn extractAnchorText(rest_after_href: []const u8) ?[]const u8 {
    const gt = std.mem.indexOfScalar(u8, rest_after_href, '>') orelse return null;
    const after = rest_after_href[gt + 1 ..];
    const close = std.mem.indexOfPos(u8, after, 0, "</a>") orelse return null;
    return after[0..close];
}

/// Drop `<…>` tags and collapse whitespace runs to one space. Caller owns
/// the result.
fn stripTags(alloc: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var in_tag = false;
    var pending_space = false;
    for (raw) |c| {
        if (c == '<') {
            in_tag = true;
            continue;
        }
        if (c == '>' and in_tag) {
            in_tag = false;
            continue;
        }
        if (in_tag) continue;
        if (std.ascii.isWhitespace(c)) {
            pending_space = buf.items.len > 0;
            continue;
        }
        if (pending_space) {
            try buf.append(alloc, ' ');
            pending_space = false;
        }
        try buf.append(alloc, c);
    }
    return buf.toOwnedSlice(alloc);
}

// ----- tests (offline) -----

test "parseTrailingId variants" {
    try std.testing.expectEqualStrings("12345", parseTrailingId("some-game.12345/").?);
    try std.testing.expectEqualStrings("12345", parseTrailingId("12345/").?);
    try std.testing.expectEqualStrings("12345", parseTrailingId("some-game.12345/page-2").?);
    try std.testing.expect(parseTrailingId("noid/") == null);
}

test "extractTotalPages picks the max ?page= seen" {
    const html =
        \\<a href="/account/bookmarks?page=2">2</a>
        \\<a href="/account/bookmarks?page=78">78</a>
        \\<a href="/account/bookmarks?page=3">3</a>
    ;
    try std.testing.expectEqual(@as(usize, 78), extractTotalPages(html));
}

test "extractTotalPages handles slug page-N form" {
    const html =
        \\<a href="/threads/x.123/page-2">2</a>
        \\<a href="/threads/x.123/page-15">15</a>
    ;
    try std.testing.expectEqual(@as(usize, 15), extractTotalPages(html));
}

test "extractTotalPages: no pagination → 1" {
    try std.testing.expectEqual(@as(usize, 1), extractTotalPages("<html>nothing</html>"));
}

const classic_page =
    \\<html data-template="f95wg_watched"><body>
    \\<nav><a href="/threads/menu-link.999/">Menu</a></nav>
    \\<div class="p-body-pageContent">
    \\<ul class="pageNav-main"><li><a href="/watched/threads?tab=bookmarks&amp;page=2">2</a></li>
    \\<li><a href="/watched/threads?tab=bookmarks&amp;page=7">7</a></li></ul>
    \\<ol class="listPlain">
    \\<li><h3 class="contentRow-title"><a href="/threads/some-game.111/">First <span>x</span></a></h3></li>
    \\<li><h3 class="contentRow-title"><a href="https://f95zone.to/threads/another.222/unread">Second</a></h3></li>
    \\</ol></div>
    \\<div class="p-body-sidebar"><a href="/threads/side-link.888/">Side</a></div>
    \\</body></html>
;

const new_page =
    \\<div class="p-body-pageContent">
    \\<div class="f95wg-row"><div class="f95wg-row-title"><a href="/threads/some-game.111/">First</a></div></div>
    \\<div class="f95wg-row"><div class="f95wg-row-title"><a href="/threads/three.333/">Third</a></div></div>
    \\</div>
;

test "collectRows reads classic bookmark rows, ignores menu + sidebar links" {
    const alloc = std.testing.allocator;
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit(); // keys borrow from out — freed there
    var out: std.ArrayList(domain.BookmarkEntry) = .empty;
    defer freeListPartial(alloc, &out);

    const found = try collectRows(alloc, classic_page, "contentRow-title", &seen, &out);
    try std.testing.expectEqual(@as(usize, 2), found.rows);
    try std.testing.expectEqualStrings("111", found.first_id.?);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("111", out.items[0].thread_id);
    try std.testing.expectEqualStrings("First x", out.items[0].title);
    try std.testing.expectEqualStrings("https://f95zone.to/threads/some-game.111/", out.items[0].url);
    // Absolute href with a trailing `/unread` is normalised.
    try std.testing.expectEqualStrings("222", out.items[1].thread_id);
    try std.testing.expectEqualStrings("https://f95zone.to/threads/another.222/", out.items[1].url);
}

test "collectRows reads new f95wg rows and dedupes across sources" {
    const alloc = std.testing.allocator;
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    var out: std.ArrayList(domain.BookmarkEntry) = .empty;
    defer freeListPartial(alloc, &out);

    _ = try collectRows(alloc, classic_page, "contentRow-title", &seen, &out);
    const found = try collectRows(alloc, new_page, "f95wg-row-title", &seen, &out);
    // Both rows counted, but 111 was already seen — only 333 is new.
    try std.testing.expectEqual(@as(usize, 2), found.rows);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("333", out.items[2].thread_id);
}

test "collectRows: page without p-body-pageContent yields nothing" {
    const alloc = std.testing.allocator;
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    var out: std.ArrayList(domain.BookmarkEntry) = .empty;
    defer freeListPartial(alloc, &out);

    const html = "<h3 class=\"contentRow-title\"><a href=\"/threads/x.1/\">x</a></h3>";
    const found = try collectRows(alloc, html, "contentRow-title", &seen, &out);
    try std.testing.expectEqual(@as(usize, 0), found.rows);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "extractPageNavTotal reads only the pageNav list" {
    try std.testing.expectEqual(@as(usize, 7), extractPageNavTotal(classic_page));
    // `page-609` outside pageNav must not inflate the total.
    try std.testing.expectEqual(@as(usize, 1), extractPageNavTotal("<div class=\"p-body-pageContent\"><a href=\"/x/page-609\">x</a></div>"));
    try std.testing.expectEqual(@as(usize, 1), extractPageNavTotal(new_page));
}

test "dataTemplate" {
    try std.testing.expectEqualStrings("f95wg_watched", dataTemplate(classic_page));
    try std.testing.expectEqualStrings("", dataTemplate("<html>"));
}

test "fuzz: bookmark page parsers survive arbitrary input" {
    try std.testing.fuzz({}, fuzzBookmarkParsers, .{ .corpus = &.{
        fuzzSeed("<a href=\"/bookmarks?page=17\">17</a>"),
        fuzzSeed("/threads/some-game.12345/"),
        fuzzSeed("page="),
        fuzzSeed("<div class=\"p-body-pageContent\"><h3 class=\"contentRow-title\"><a href=\"/threads/a.1/\">a</a>"),
    } });
}

fn fuzzBookmarkParsers(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [FUZZ_BUF_LEN]u8 = undefined;
    const n = smith.slice(&buf);
    const src = buf[0..n];
    _ = extractTotalPages(src);
    _ = parseTrailingId(src);
    _ = extractPageNavTotal(src);
    _ = dataTemplate(src);
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    var out: std.ArrayList(domain.BookmarkEntry) = .empty;
    defer freeListPartial(std.testing.allocator, &out);
    _ = try collectRows(std.testing.allocator, src, "contentRow-title", &seen, &out);
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
