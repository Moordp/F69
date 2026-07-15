// Scrape /account/bookmarks for the logged-in user's saved threads.
// Requires a session cookie on `client` — anonymous fetches get
// redirected to the login page.
//
// XenForo paginates via `?page=N`. We walk pages 1.. until either
// (a) the page yields no new thread ids that we haven't seen, or
// (b) we hit a hard cap (500). 78-page libraries are real on F95.
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

const PAGE_BASE = cli.BASE_URL ++ "/account/bookmarks";
const MAX_PAGES = 500;

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

    var page: u32 = 1;
    while (page <= MAX_PAGES) : (page += 1) {
        // Cooperative cancel — checked BEFORE each network round-trip
        // so a Cancel click never has to wait for an HTTP response.
        if (progress.cancel) |c| if (c.load(.acquire)) {
            log.info("bookmarks pull cancelled at page {d}", .{page});
            return errs.Error.Cancelled;
        };

        if (progress.current) |c| c.store(page, .release);

        var url_buf: [128]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}?page={d}", .{ PAGE_BASE, page }) catch
            return errs.Error.OutOfMemory;

        const body = client.get(url) catch |e| {
            log.warn("fetch page {d} failed: {s}", .{ page, @errorName(e) });
            return e;
        };
        defer alloc.free(body);

        // Page 1 carries the pagination markup that tells us the
        // total. Update the progress sink once.
        if (page == 1) {
            const total = extractTotalPages(body);
            log.info("bookmarks total pages: {d}", .{total});
            if (progress.total) |t| t.store(@intCast(total), .release);
        }

        const before_count = out.items.len;
        try collectFromPage(alloc, body, &seen, &out);
        const added = out.items.len - before_count;

        log.info("page {d}: +{d} (running total {d})", .{ page, added, out.items.len });

        // Wake the UI and hand it this page's entries (so callers
        // can live-insert during the pull instead of waiting for
        // the final return). Slice is borrowed; callback dupes if
        // it needs persistence (future `out` reallocs invalidate).
        if (progress.on_page) |cb| cb(progress.ctx, out.items[before_count..]);

        if (added == 0) {
            // Diagnostic: show a snippet so the user can tell whether
            // we got an unexpected page (login redirect, error page,
            // changed markup) vs. genuinely no bookmarks.
            const snippet_len = @min(body.len, 600);
            log.warn("page {d} parsed 0 bookmarks. Body head: '{s}…'", .{ page, body[0..snippet_len] });
            break;
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

/// Walk the page HTML for `/threads/<slug>.<id>/` (or `/threads/<id>/`)
/// links, extract numeric ids, dedupe across pages.
///
/// XenForo emits anchor `href`s in three flavors depending on the
/// template / version: leading-slash, relative, or absolute URL. Try
/// all three.
///
/// Ownership: every alloc'd string lives inside `out[i]`. `seen`'s keys
/// borrow `out[i].thread_id` — `seen` does NOT own anything.
fn collectFromPage(
    alloc: std.mem.Allocator,
    html: []const u8,
    seen: *std.StringHashMap(void),
    out: *std.ArrayList(domain.BookmarkEntry),
) errs.Error!void {
    const markers = [_][]const u8{
        "href=\"/threads/",
        "href=\"threads/",
        "href=\"https://f95zone.to/threads/",
        "href=\"http://f95zone.to/threads/",
    };
    for (markers) |marker| try collectMatches(alloc, html, marker, seen, out);
}

fn collectMatches(
    alloc: std.mem.Allocator,
    html: []const u8,
    marker: []const u8,
    seen: *std.StringHashMap(void),
    out: *std.ArrayList(domain.BookmarkEntry),
) errs.Error!void {
    var rest = html;
    while (std.mem.indexOf(u8, rest, marker)) |i| {
        const after = rest[i + marker.len ..];
        const close = std.mem.indexOfScalar(u8, after, '"') orelse break;
        const path = after[0..close];
        rest = after[close + 1 ..];

        const tid = parseTrailingId(path) orelse continue;
        // Dedup BEFORE allocating — `seen` hashes by bytes so the
        // transient `tid` slice into `html` works for the lookup.
        if (seen.contains(tid)) continue;

        const tid_owned = alloc.dupe(u8, tid) catch return errs.Error.OutOfMemory;
        errdefer alloc.free(tid_owned);

        // Title: grab inner text up to `</a>`. Best-effort — XenForo
        // wraps it in a span sometimes; strip tags if present.
        const title = extractAnchorText(rest) orelse "";
        const title_owned = alloc.dupe(u8, std.mem.trim(u8, title, " \t\n\r")) catch
            return errs.Error.OutOfMemory;
        errdefer alloc.free(title_owned);

        // F95 slugs can be long — bump from 128 to 512. If the path is
        // STILL too long for the buffer, skip the entry (it's almost
        // certainly malformed) instead of mis-reporting as OOM.
        var url_buf: [512]u8 = undefined;
        const url_full = std.fmt.bufPrint(&url_buf, "{s}/threads/{s}", .{ cli.BASE_URL, path }) catch {
            log.warn("URL too long, skipping (path len={d})", .{path.len});
            alloc.free(title_owned);
            alloc.free(tid_owned);
            continue;
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

/// `<a …>Title</a>` — pull the inner text. Strip nested tags by
/// taking the substring after the first `>` (closing the opening tag
/// minus the close-tag marker we just consumed) up to `</a>`.
fn extractAnchorText(rest_after_href: []const u8) ?[]const u8 {
    const gt = std.mem.indexOfScalar(u8, rest_after_href, '>') orelse return null;
    const after = rest_after_href[gt + 1 ..];
    const close = std.mem.indexOfPos(u8, after, 0, "</a>") orelse return null;
    const raw = after[0..close];
    // Strip any nested tags like `<span>title</span>` → "title". One
    // pass is enough for XF's typical markup.
    if (std.mem.indexOfScalar(u8, raw, '<')) |open| {
        const inner_after = raw[open..];
        const inner_gt = std.mem.indexOfScalar(u8, inner_after, '>') orelse return raw[0..open];
        const inner_text_start = open + inner_gt + 1;
        const close_tag = std.mem.indexOfPos(u8, raw, inner_text_start, "<") orelse raw.len;
        return raw[inner_text_start..close_tag];
    }
    return raw;
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

test "collectFromPage extracts new + dedupes across calls" {
    const alloc = std.testing.allocator;
    const html_a =
        \\<a href="/threads/some-game.111/">First</a>
        \\<a href="/threads/another.222/">Second</a>
    ;
    const html_b =
        \\<a href="/threads/some-game.111/">First</a>
        \\<a href="/threads/three.333/">Third</a>
    ;

    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit(); // keys borrow from out — freed there

    var out: std.ArrayList(domain.BookmarkEntry) = .empty;
    defer freeListPartial(alloc, &out);

    try collectFromPage(alloc, html_a, &seen, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);

    try collectFromPage(alloc, html_b, &seen, &out);
    // 111 already seen; only 333 added.
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("333", out.items[2].thread_id);
}

test "fuzz: bookmark page parsers survive arbitrary input" {
    try std.testing.fuzz({}, fuzzBookmarkParsers, .{ .corpus = &.{
        fuzzSeed("<a href=\"/bookmarks?page=17\">17</a>"),
        fuzzSeed("/threads/some-game.12345/"),
        fuzzSeed("page="),
    } });
}

fn fuzzBookmarkParsers(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [FUZZ_BUF_LEN]u8 = undefined;
    const n = smith.slice(&buf);
    const src = buf[0..n];
    _ = extractTotalPages(src);
    _ = parseTrailingId(src);
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
