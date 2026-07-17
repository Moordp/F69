// F95 "latest updates" RSS pre-pass — a cheap bulk check for which
// library games changed recently, without scraping each thread.
//
// XenForo (F95's forum software) exposes forum feeds as RSS 2.0: each
// <item> carries a <link> to a thread (…/threads/name.<id>/) and a
// <pubDate>. The feed only lists recently-bumped threads, so a library
// game whose thread appears here was updated recently — that presence is
// the signal (pubDate refines it when parseable, but matching never
// depends on it, since RFC-822 dates are fiddly and feeds vary).
//
// This module is PURE (parse + match only). The fetch lives in the UI
// action layer using the existing f95 client, so the parser stays
// unit-testable with no network.

const std = @import("std");
const client = @import("client.zig");

pub const Error = error{ OutOfMemory, ParseFailed };

/// Minimal game view for matching — kept here so this module needn't
/// depend on the `library` layer. The UI action builds these from its
/// games slice.
pub const GameRef = struct {
    thread_id: u64,
    last_updated_at: ?i64 = null,
};

pub const Entry = struct {
    thread_id: u64,
    /// Unix seconds from <pubDate>, or null when absent/unparseable.
    updated: ?i64 = null,
};

/// Parse an RSS 2.0 body into thread entries. Skips items whose <link>
/// has no recognisable thread id. Best-effort: malformed items are
/// dropped, not fatal.
pub fn parseFeed(alloc: std.mem.Allocator, xml: []const u8) Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(alloc);

    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, xml, search_from, "<item")) |item_start| {
        const item_end = std.mem.indexOfPos(u8, xml, item_start, "</item>") orelse break;
        const item = xml[item_start..item_end];
        search_from = item_end + "</item>".len;

        const link = elementText(item, "link") orelse continue;
        const tid_str = client.extractThreadId(link) orelse continue;
        const tid = std.fmt.parseInt(u64, tid_str, 10) catch continue;

        const updated: ?i64 = if (elementText(item, "pubDate")) |pd| parsePubDate(pd) else null;
        out.append(alloc, .{ .thread_id = tid, .updated = updated }) catch return Error.OutOfMemory;
    }
    return out.toOwnedSlice(alloc) catch Error.OutOfMemory;
}

/// Thread ids of library games that the feed says changed recently: the
/// game's thread is in the feed AND (the feed entry has no timestamp, or
/// its timestamp is newer than the game's last_updated_at). Caller frees.
pub fn matchChanged(alloc: std.mem.Allocator, entries: []const Entry, games: []const GameRef) Error![]u64 {
    // thread_id -> newest feed timestamp (null = present but undated).
    var feed = std.AutoHashMap(u64, ?i64).init(alloc);
    defer feed.deinit();
    for (entries) |e| {
        const gop = feed.getOrPut(e.thread_id) catch return Error.OutOfMemory;
        if (!gop.found_existing) {
            gop.value_ptr.* = e.updated;
        } else if (e.updated) |u| {
            if (gop.value_ptr.*) |cur| {
                if (u > cur) gop.value_ptr.* = u;
            } else gop.value_ptr.* = u;
        }
    }

    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(alloc);
    for (games) |g| {
        const fv = feed.get(g.thread_id) orelse continue;
        const changed = if (fv) |feed_ts|
            (g.last_updated_at == null or feed_ts > g.last_updated_at.?)
        else
            true; // present but undated → treat as changed
        if (changed) out.append(alloc, g.thread_id) catch return Error.OutOfMemory;
    }
    return out.toOwnedSlice(alloc) catch Error.OutOfMemory;
}

/// Text between `<tag>` and `</tag>` inside `haystack`, trimmed and with a
/// single leading `<![CDATA[ ... ]]>` unwrapped. Null if absent.
fn elementText(haystack: []const u8, comptime tag: []const u8) ?[]const u8 {
    const open = "<" ++ tag;
    const os = std.mem.indexOf(u8, haystack, open) orelse return null;
    // Step past the rest of the open tag (attributes etc.) to its '>'.
    const gt = std.mem.indexOfScalarPos(u8, haystack, os + open.len, '>') orelse return null;
    const content_start = gt + 1;
    const close = "</" ++ tag ++ ">";
    const ce = std.mem.indexOfPos(u8, haystack, content_start, close) orelse return null;
    var v = std.mem.trim(u8, haystack[content_start..ce], " \t\r\n");
    if (std.mem.startsWith(u8, v, "<![CDATA[") and std.mem.endsWith(u8, v, "]]>")) {
        v = v["<![CDATA[".len .. v.len - "]]>".len];
    }
    return v;
}

fn monthNum(m: []const u8) ?u8 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (names, 1..) |n, i| if (std.ascii.eqlIgnoreCase(m, n)) return @intCast(i);
    return null;
}

/// Days from 1970-01-01 to y-m-d (Howard Hinnant's civil algorithm).
fn daysFromCivil(y_in: i64, m: u8, d: u8) i64 {
    var y = y_in;
    if (m <= 2) y -= 1;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, m) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// RFC-822 date ("Wed, 15 Jul 2026 21:14:00 +0000" / "... GMT") → unix
/// seconds. Null on any parse trouble — matching tolerates that.
fn parsePubDate(s: []const u8) ?i64 {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    var tok = it.next() orelse return null;
    // Optional leading weekday "Wed,"
    if (std.mem.endsWith(u8, tok, ",")) tok = it.next() orelse return null;
    const day = std.fmt.parseInt(u8, tok, 10) catch return null;
    const mon = monthNum(it.next() orelse return null) orelse return null;
    const year = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const time_tok = it.next() orelse return null;
    var ts = std.mem.tokenizeScalar(u8, time_tok, ':');
    const hh = std.fmt.parseInt(i64, ts.next() orelse return null, 10) catch return null;
    const mm = std.fmt.parseInt(i64, ts.next() orelse return null, 10) catch return null;
    const ss = std.fmt.parseInt(i64, ts.next() orelse "0", 10) catch 0;
    var epoch = daysFromCivil(year, mon, day) * 86400 + hh * 3600 + mm * 60 + ss;
    // Optional numeric timezone offset "+0000" / "-0530".
    if (it.next()) |tz| {
        if ((tz[0] == '+' or tz[0] == '-') and tz.len >= 5) {
            const off_h = std.fmt.parseInt(i64, tz[1..3], 10) catch 0;
            const off_m = std.fmt.parseInt(i64, tz[3..5], 10) catch 0;
            const off = off_h * 3600 + off_m * 60;
            epoch += if (tz[0] == '+') -off else off;
        }
    }
    return epoch;
}

const testing = std.testing;

const SAMPLE =
    \\<rss version="2.0"><channel>
    \\<item><title>Alpha Game [v1.2]</title>
    \\<link>https://f95zone.to/threads/alpha-game.111/</link>
    \\<pubDate>Wed, 15 Jul 2026 21:14:00 +0000</pubDate></item>
    \\<item><title>Bravo Game</title>
    \\<link>https://f95zone.to/threads/bravo.222/</link>
    \\<pubDate>Tue, 14 Jul 2026 10:00:00 GMT</pubDate></item>
    \\<item><title>No thread id here</title><link>https://f95zone.to/whatsnew/</link></item>
    \\</channel></rss>
;

test "parseFeed pulls thread ids + dates, skips id-less items" {
    const e = try parseFeed(testing.allocator, SAMPLE);
    defer testing.allocator.free(e);
    try testing.expectEqual(@as(usize, 2), e.len);
    try testing.expectEqual(@as(u64, 111), e[0].thread_id);
    try testing.expect(e[0].updated != null);
    try testing.expectEqual(@as(u64, 222), e[1].thread_id);
}

test "parsePubDate RFC-822 → epoch" {
    // 2000-01-01 00:00:00 UTC = 946684800.
    try testing.expectEqual(@as(?i64, 946684800), parsePubDate("Sat, 01 Jan 2000 00:00:00 +0000"));
    try testing.expectEqual(@as(?i64, 946684800), parsePubDate("01 Jan 2000 00:00:00 GMT"));
    // +0100 means local is one hour ahead of UTC → epoch one hour earlier.
    try testing.expectEqual(@as(?i64, 946681200), parsePubDate("Sat, 01 Jan 2000 00:00:00 +0100"));
    try testing.expectEqual(@as(?i64, null), parsePubDate("garbage"));
}

test "matchChanged flags library games present + newer in the feed" {
    const entries = [_]Entry{
        .{ .thread_id = 111, .updated = 1000 },
        .{ .thread_id = 222, .updated = null }, // present but undated
        .{ .thread_id = 333, .updated = 500 },
    };
    const games = [_]GameRef{
        .{ .thread_id = 111, .last_updated_at = 900 }, // feed newer → changed
        .{ .thread_id = 222, .last_updated_at = 9999 }, // undated feed → changed
        .{ .thread_id = 333, .last_updated_at = 800 }, // feed older → NOT
        .{ .thread_id = 444, .last_updated_at = 0 }, // not in feed → NOT
    };
    const got = try matchChanged(testing.allocator, &entries, &games);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    // order follows `games`: 111 then 222.
    try testing.expectEqual(@as(u64, 111), got[0]);
    try testing.expectEqual(@as(u64, 222), got[1]);
}
