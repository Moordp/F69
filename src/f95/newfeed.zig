// Parser for F95's "new versions" feed — `/watched/threads?tab=new`.
//
// One request lists 30 watched threads that shipped a new version, newest
// first, each row carrying what the latest-updates feeds don't:
//
//   <div class="f95wg-row is-seen">
//     <div class="f95wg-row-title">… <a href="…/threads/slug.94140/">Title [v0.114] [Dev]</a></div>
//     <div class="f95wg-row-version">
//       <span class="f95wg-ver">Part 8 v0.112 → Part 8 v0.114</span>
//       <span class="f95wg-muted">2 new versions</span>
//       <span class="f95wg-muted"><time … data-timestamp="1793124607">Today at 7:10 PM</time></span>
//
// so a caller learns the old and new version string, how many versions were
// skipped, and an exact epoch timestamp, without opening any thread page.
//
// Only WATCHED threads appear (bookmarks you don't watch never do), and the
// feed is a finite window (about three weeks / 6 pages). This module is PURE
// (parse only); the fetch + paging lives in the UI action layer.

const std = @import("std");
const bm = @import("bookmarks.zig");
const thread = @import("thread.zig");

pub const Error = error{OutOfMemory};

pub const Entry = struct {
    thread_id: u64,
    /// Version before the update, or "" when the row doesn't show one.
    old_version: []const u8,
    /// Version after the update, or "" when the row has no version element.
    new_version: []const u8,
    /// How many versions the row covers ("2 new versions"); 1 otherwise.
    new_count: u32,
    /// Epoch seconds of the update, 0 when the row has no timestamp.
    ts: i64,
};

pub fn freeEntries(alloc: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| {
        alloc.free(e.old_version);
        alloc.free(e.new_version);
    }
    alloc.free(entries);
}

/// Total pages, from the page's `pageNav` (1 when there is none).
pub fn pageTotal(html: []const u8) usize {
    return bm.extractPageNavTotal(html);
}

const ROW_MARKER = "<div class=\"f95wg-row";

/// Parse one feed page. Rows that don't link to a thread are skipped.
/// Caller frees with `freeEntries`.
pub fn parsePage(alloc: std.mem.Allocator, html: []const u8) Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |e| {
            alloc.free(e.old_version);
            alloc.free(e.new_version);
        }
        out.deinit(alloc);
    }

    const content = bm.pageContent(html);
    var start = nextRow(content, 0);
    while (start) |s| {
        const end = nextRow(content, s + ROW_MARKER.len) orelse content.len;
        if (try parseRow(alloc, content[s..end])) |entry| {
            out.append(alloc, entry) catch |e| {
                alloc.free(entry.old_version);
                alloc.free(entry.new_version);
                return e;
            };
        }
        start = if (end < content.len) end else null;
    }
    return out.toOwnedSlice(alloc) catch Error.OutOfMemory;
}

/// Start of the next `<div class="f95wg-row …">` at or after `from`.
/// `f95wg-row-title` / `-main` / … share the prefix, so require the class
/// name to end right after `f95wg-row` (space or closing quote).
fn nextRow(s: []const u8, from: usize) ?usize {
    var i = from;
    while (std.mem.indexOfPos(u8, s, i, ROW_MARKER)) |idx| {
        const after = idx + ROW_MARKER.len;
        if (after < s.len and (s[after] == ' ' or s[after] == '"')) return idx;
        i = idx + 1;
    }
    return null;
}

fn parseRow(alloc: std.mem.Allocator, row: []const u8) Error!?Entry {
    const title_i = std.mem.indexOf(u8, row, "f95wg-row-title") orelse return null;
    const window = row[title_i..@min(row.len, title_i + 4096)];
    const anchor = bm.findThreadAnchor(window) orelse return null;
    const t = std.mem.indexOf(u8, anchor.href, "threads/") orelse return null;
    const tid_s = bm.parseTrailingId(anchor.href[t + "threads/".len ..]) orelse return null;
    const tid = std.fmt.parseInt(u64, tid_s, 10) catch return null;

    var old_raw: []const u8 = "";
    var new_raw: []const u8 = "";
    const ver_key = "f95wg-ver\">";
    if (std.mem.indexOf(u8, row, ver_key)) |vi| {
        const s0 = vi + ver_key.len;
        const e0 = std.mem.indexOfPos(u8, row, s0, "</span>") orelse row.len;
        const text = std.mem.trim(u8, row[s0..e0], " \t\r\n");
        const arrow = "\xe2\x86\x92"; // →
        if (std.mem.indexOf(u8, text, arrow)) |ai| {
            old_raw = std.mem.trim(u8, text[0..ai], " \t\r\n");
            new_raw = std.mem.trim(u8, text[ai + arrow.len ..], " \t\r\n");
        } else {
            new_raw = text;
        }
    }

    var old_buf: [256]u8 = undefined;
    var new_buf: [256]u8 = undefined;
    const old_dec = thread.decodeHtmlEntities(&old_buf, old_raw[0..@min(old_raw.len, old_buf.len)]);
    const new_dec = thread.decodeHtmlEntities(&new_buf, new_raw[0..@min(new_raw.len, new_buf.len)]);

    const old_owned = alloc.dupe(u8, old_dec) catch return Error.OutOfMemory;
    errdefer alloc.free(old_owned);
    const new_owned = alloc.dupe(u8, new_dec) catch return Error.OutOfMemory;
    errdefer alloc.free(new_owned);

    return Entry{
        .thread_id = tid,
        .old_version = old_owned,
        .new_version = new_owned,
        .new_count = parseNewCount(row),
        .ts = parseTimestamp(row),
    };
}

/// "2 new versions" → 2; anything else → 1.
fn parseNewCount(row: []const u8) u32 {
    const needle = " new version";
    const i = std.mem.indexOf(u8, row, needle) orelse return 1;
    var s = i;
    while (s > 0 and std.ascii.isDigit(row[s - 1])) s -= 1;
    if (s == i) return 1;
    return std.fmt.parseInt(u32, row[s..i], 10) catch 1;
}

/// First `data-timestamp="N"` in the row, or 0.
fn parseTimestamp(row: []const u8) i64 {
    const key = "data-timestamp=\"";
    const i = std.mem.indexOf(u8, row, key) orelse return 0;
    const s = i + key.len;
    var e = s;
    while (e < row.len and std.ascii.isDigit(row[e])) e += 1;
    if (e == s) return 0;
    return std.fmt.parseInt(i64, row[s..e], 10) catch 0;
}

// ----- tests (offline; markup trimmed from a real saved page, 2026-10-27) -----

const sample_page =
    \\<html><body><nav><a href="/threads/menu-link.999/">menu</a></nav>
    \\<div class="p-body-pageContent">
    \\<ul class="pageNav-main"><li class="pageNav-page"><a href="/watched/threads?tab=new&amp;page=2">2</a></li><li><a href="/watched/threads?tab=new&amp;page=6">6</a></li></ul>
    \\<h3 class="f95wg-groupTitle">This week</h3>
    \\<div class="f95wg-row is-seen">
    \\<a href="https://f95zone.to/threads/grandmas-house-part-8-v0-114-moonbox.94140/" class="f95wg-cover"><img></a>
    \\<div class="f95wg-row-main">
    \\<div class="f95wg-row-title"><span class="label label--red" dir="auto">VN</span><span class="label-append">&nbsp;</span><a href="https://f95zone.to/threads/grandmas-house-part-8-v0-114-moonbox.94140/">Grandma's House [Part 8 v0.114] [Moonbox]</a></div>
    \\<div class="f95wg-row-version">
    \\<span class="f95wg-ver">Part 8 v0.112 → Part 8 v0.114</span>
    \\<span class="f95wg-muted">2 new versions</span>
    \\<span class="f95wg-muted"><time class="u-dt" datetime="2026-10-27T19:10:07+0100" data-timestamp="1793124607">Today at 7:10 PM</time></span>
    \\<span class="f95wg-source">Watched · new-version alerts</span>
    \\</div>
    \\</div>
    \\<div class="f95wg-row-actions"><a href="https://f95zone.to/threads/grandmas-house-part-8-v0-114-moonbox.94140/unread">Where I left off</a></div>
    \\</div>
    \\<div class="f95wg-row is-seen">
    \\<div class="f95wg-row-main">
    \\<div class="f95wg-row-title"><span class="label">VN</span><a href="https://f95zone.to/threads/naruto-shinobi-lord-v0-46-cats-creators.115967/">Naruto: Shinobi Lord [v0.46] [Cats-creators]</a></div>
    \\<div class="f95wg-row-version">
    \\<span class="f95wg-ver">v0.45 Public → v0.46</span>
    \\<span class="f95wg-muted"><time data-timestamp="1793098500">Today at 11:55 AM</time></span>
    \\</div></div></div>
    \\<div class="f95wg-row">
    \\<div class="f95wg-row-main">
    \\<div class="f95wg-row-title"><a href="/threads/taboo-request-final-icstor.492/">Taboo Request [Final] [ICSTOR]</a></div>
    \\<div class="f95wg-row-version"><span class="f95wg-ver">Final</span><span class="f95wg-muted"><time data-timestamp="1793000000">Yesterday</time></span></div>
    \\</div></div>
    \\</div>
    \\<div class="p-body-sidebar"><div class="f95wg-row"><a class="f95wg-row-title" href="/threads/side.1/">x</a></div></div>
    \\</body></html>
;

test "parsePage reads old/new version, count, timestamp for each row" {
    const alloc = std.testing.allocator;
    const entries = try parsePage(alloc, sample_page);
    defer freeEntries(alloc, entries);

    try std.testing.expectEqual(@as(usize, 3), entries.len);

    try std.testing.expectEqual(@as(u64, 94140), entries[0].thread_id);
    try std.testing.expectEqualStrings("Part 8 v0.112", entries[0].old_version);
    try std.testing.expectEqualStrings("Part 8 v0.114", entries[0].new_version);
    try std.testing.expectEqual(@as(u32, 2), entries[0].new_count);
    try std.testing.expectEqual(@as(i64, 1793124607), entries[0].ts);

    try std.testing.expectEqual(@as(u64, 115967), entries[1].thread_id);
    try std.testing.expectEqualStrings("v0.45 Public", entries[1].old_version);
    try std.testing.expectEqualStrings("v0.46", entries[1].new_version);
    try std.testing.expectEqual(@as(u32, 1), entries[1].new_count);

    // No arrow: just a new status/version, old is empty.
    try std.testing.expectEqual(@as(u64, 492), entries[2].thread_id);
    try std.testing.expectEqualStrings("", entries[2].old_version);
    try std.testing.expectEqualStrings("Final", entries[2].new_version);
}

test "parsePage ignores menu and sidebar rows; empty page gives no entries" {
    const alloc = std.testing.allocator;
    const entries = try parsePage(alloc, sample_page);
    defer freeEntries(alloc, entries);
    for (entries) |e| try std.testing.expect(e.thread_id != 999 and e.thread_id != 1);

    const none = try parsePage(alloc, "<html><body>nothing</body></html>");
    defer freeEntries(alloc, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "parsePage decodes entities in versions" {
    const alloc = std.testing.allocator;
    const html =
        \\<div class="p-body-pageContent"><div class="f95wg-row"><div class="f95wg-row-title"><a href="/threads/a-b.5/">A</a></div>
        \\<div class="f95wg-row-version"><span class="f95wg-ver">Ch.1 &amp; 2 → Ch.3 &#039;Beta&#039;</span></div></div></div>
    ;
    const entries = try parsePage(alloc, html);
    defer freeEntries(alloc, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("Ch.1 & 2", entries[0].old_version);
    try std.testing.expectEqualStrings("Ch.3 'Beta'", entries[0].new_version);
}

test "pageTotal reads the page nav" {
    try std.testing.expectEqual(@as(usize, 6), pageTotal(sample_page));
    try std.testing.expectEqual(@as(usize, 1), pageTotal("<html></html>"));
}

test "fuzz: feed parser survives arbitrary input" {
    try std.testing.fuzz({}, fuzzFeed, .{ .corpus = &.{
        fuzzSeed("<div class=\"p-body-pageContent\"><div class=\"f95wg-row\"><div class=\"f95wg-row-title\"><a href=\"/threads/a.1/\">a</a></div><span class=\"f95wg-ver\">1 \xe2\x86\x92 2</span>"),
        fuzzSeed("f95wg-ver\">"),
        fuzzSeed("data-timestamp=\""),
    } });
}

fn fuzzFeed(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [FUZZ_BUF_LEN]u8 = undefined;
    const n = smith.slice(&buf);
    const entries = try parsePage(std.testing.allocator, buf[0..n]);
    freeEntries(std.testing.allocator, entries);
    _ = pageTotal(buf[0..n]);
}

/// Harness read-buffer length; fuzzSeed payloads must fit (see bookmarks.zig).
const FUZZ_BUF_LEN = 4096;

/// 4-byte LE length prefix + payload (Smith input stream format).
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
