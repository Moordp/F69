//! The Detail → Downloads tab's view of a game's link catalogue.
//!
//! Built once per game open from `download_sources` (one small SQLite
//! read on the UI thread) and classified with `dl_classify`. The tab looks
//! each `[LINK=url]` up here to decide whether the link starts a download
//! in f69 (file hosts) or keeps opening the browser (forum, profile,
//! unknown sites, hidden-host links).

const std = @import("std");
const library = @import("library");
const dl_classify = @import("f95").dl_classify;
const downloads = @import("downloads");

const model = downloads.model;

pub const Item = struct {
    entry: dl_classify.Entry,
    /// Index of the row in `Catalogue.rows` (page order).
    ord: u32,
};

pub const Catalogue = struct {
    alloc: std.mem.Allocator,
    /// Allocator that owns `rows` (the library's).
    rows_alloc: std.mem.Allocator,
    /// href → item. Keys borrow `rows[i].href`.
    map: std.StringHashMap(Item),
    rows: []library.DownloadSource,

    pub fn deinit(self: *Catalogue) void {
        self.map.deinit();
        for (self.rows) |r| {
            self.rows_alloc.free(r.href);
            self.rows_alloc.free(r.text);
            self.rows_alloc.free(r.lead);
            self.rows_alloc.free(r.ctx);
        }
        self.rows_alloc.free(self.rows);
        self.* = undefined;
    }

    pub fn lookup(self: *const Catalogue, href: []const u8) ?Item {
        return self.map.get(href);
    }

    /// The row an item came from.
    pub fn row(self: *const Catalogue, item: Item) library.DownloadSource {
        return self.rows[item.ord];
    }
};

/// Read and classify `tid`'s catalogue. One DB read.
pub fn build(alloc: std.mem.Allocator, lib: *library.Library, tid: u64) !Catalogue {
    return fromRows(alloc, lib.alloc, try lib.listDownloadSources(tid));
}

/// Classify `rows` (owned by `rows_alloc`; the catalogue takes them, also
/// on error).
pub fn fromRows(alloc: std.mem.Allocator, rows_alloc: std.mem.Allocator, rows: []library.DownloadSource) !Catalogue {
    var cat: Catalogue = .{
        .alloc = alloc,
        .rows_alloc = rows_alloc,
        .map = std.StringHashMap(Item).init(alloc),
        .rows = rows,
    };
    errdefer cat.deinit();
    try cat.map.ensureTotalCapacity(@intCast(rows.len));
    for (rows, 0..) |r, i| {
        // The first row wins when an href repeats (hidden-host links all
        // share one blanked href; they are not actionable anyway).
        const gop = cat.map.getOrPutAssumeCapacity(r.href);
        if (gop.found_existing) continue;
        gop.value_ptr.* = .{
            .entry = dl_classify.classify(r.href, r.text, r.lead, r.ctx),
            .ord = @intCast(i),
        };
    }
    return cat;
}

/// True when the link can start a download in f69: a file host that is
/// not hidden (blanked hrefs are shared by several rows).
pub fn isActionable(entry: dl_classify.Entry) bool {
    if (entry.wrapper == .hidden) return false;
    return switch (dl_classify.targetOf(entry)) {
        .file, .dead => true,
        else => false,
    };
}

/// "Win/Linux" style platform text, or null when the label names none.
pub fn platformText(buf: []u8, p: dl_classify.Platform) ?[]const u8 {
    var n: usize = 0;
    const names = [_]struct { on: bool, name: []const u8 }{
        .{ .on = p.windows, .name = "Win" },
        .{ .on = p.linux, .name = "Linux" },
        .{ .on = p.mac, .name = "Mac" },
        .{ .on = p.android, .name = "Android" },
    };
    for (names) |it| {
        if (!it.on) continue;
        const sep_len: usize = if (n > 0) 1 else 0;
        if (n + sep_len + it.name.len > buf.len) break;
        if (sep_len == 1) buf[n] = '/';
        n += sep_len;
        @memcpy(buf[n..][0..it.name.len], it.name);
        n += it.name.len;
    }
    return if (n == 0) null else buf[0..n];
}

/// The chip text for a link: "[platform · ][Part N · ]kind", where kind
/// is the running job's step label, or what the link is.
pub fn tagLabel(entry: dl_classify.Entry, href: []const u8, running: ?model.Step, buf: []u8) []const u8 {
    const kind: []const u8 = if (running) |s| s.label() else kindWord(entry, href);
    var plat_buf: [32]u8 = undefined;
    const plat = platformText(&plat_buf, entry.platform);
    var w: std.Io.Writer = .fixed(buf);
    if (plat) |p| w.print("{s} · ", .{p}) catch return kind;
    if (entry.part) |n| w.print("Part {d} · ", .{n}) catch return kind;
    w.writeAll(kind) catch return kind;
    return w.buffered();
}

fn kindWord(entry: dl_classify.Entry, href: []const u8) []const u8 {
    if (dl_classify.targetOf(entry) == .dead) return "dead";
    if (downloads.resolve.engineFor(entry, href) == .aria2_torrent) return "torrent";
    if (entry.host == .mega) return "MEGA";
    if (entry.wrapper == .masked) return "direct";
    return switch (entry.host) {
        .pixeldrain, .f95_attachment, .google_drive, .mediafire => "direct",
        else => "opens browser",
    };
}

/// The catalogue item for `part` that belongs with `like`: same platform
/// set, same spoiler depth, actionable file link.
pub fn findPart(cat: *const Catalogue, like: Item, part: u8) ?Item {
    const like_row = cat.row(like);
    for (cat.rows, 0..) |r, i| {
        const it = cat.lookup(r.href) orelse continue;
        if (it.ord != i) continue; // a repeated href: only its first row counts
        if (it.entry.part != part) continue;
        if (r.spoiler != like_row.spoiler) continue;
        if (!std.meta.eql(it.entry.platform, like.entry.platform)) continue;
        if (!isActionable(it.entry) or dl_classify.targetOf(it.entry) != .file) continue;
        return it;
    }
    return null;
}

pub const PartRange = struct { from: u8, to: u8 };

/// Consecutive parts after `item` (Part N → N+1, N+2, … while they
/// exist), or null when `item` has no part or no next part exists.
pub fn nextParts(cat: *const Catalogue, item: Item) ?PartRange {
    const n = item.entry.part orelse return null;
    var k: u8 = n;
    while (k < std.math.maxInt(u8)) : (k += 1) {
        if (findPart(cat, item, k + 1) == null) break;
    }
    if (k == n) return null;
    return .{ .from = n + 1, .to = k };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn entryOf(href: []const u8, lead: []const u8, text: []const u8) dl_classify.Entry {
    return dl_classify.classify(href, text, lead, "");
}

test "tagLabel: kinds, platform prefix, part, running step" {
    var buf: [96]u8 = undefined;
    const Case = struct { href: []const u8, lead: []const u8, text: []const u8, running: ?model.Step = null, want: []const u8 };
    const cases = [_]Case{
        .{ .href = "https://pixeldrain.com/u/abc", .lead = "Win", .text = "Pixeldrain", .want = "Win · direct" },
        .{ .href = "https://pixeldrain.com/u/abc", .lead = "", .text = "Pixeldrain", .want = "direct" },
        .{ .href = "https://mega.nz/file/x#k", .lead = "Linux", .text = "MEGA", .want = "Linux · MEGA" },
        .{ .href = "https://gofile.io/d/abc", .lead = "Part 2", .text = "Gofile", .want = "Part 2 · opens browser" },
        .{ .href = "https://f95zone.to/masked/mega.nz/1/2", .lead = "", .text = "MEGA", .want = "MEGA" },
        .{ .href = "https://f95zone.to/masked/gofile.io/1/2", .lead = "", .text = "GOFILE", .want = "direct" },
        .{ .href = "https://drive.google.com/file/d/abc/view", .lead = "", .text = "Drive", .want = "direct" },
        .{ .href = "https://www.mediafire.com/file/x/y.zip/file", .lead = "", .text = "MF", .want = "direct" },
        .{ .href = "https://anonfiles.com/abc", .lead = "", .text = "Anonfile", .want = "dead" },
        .{ .href = "https://example.org/game.torrent", .lead = "", .text = "Torrent", .want = "torrent" },
        .{ .href = "https://pixeldrain.com/u/abc", .lead = "Win", .text = "Pixeldrain", .running = .downloading, .want = "Win · Downloading" },
    };
    for (cases) |c| {
        const e = entryOf(c.href, c.lead, c.text);
        errdefer std.debug.print("case {s}\n", .{c.href});
        try testing.expectEqualStrings(c.want, tagLabel(e, c.href, c.running, &buf));
    }
}

test "tagLabel: Win/Linux joined, part after platform" {
    var buf: [96]u8 = undefined;
    var e = entryOf("https://pixeldrain.com/u/abc", "", "Pixeldrain");
    e.platform = .{ .windows = true, .linux = true };
    e.part = 3;
    try testing.expectEqualStrings("Win/Linux · Part 3 · direct", tagLabel(e, "https://pixeldrain.com/u/abc", null, &buf));
    // A buffer too small for the prefix still yields the kind word.
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("direct", tagLabel(e, "https://pixeldrain.com/u/abc", null, &tiny));
}

fn testRows(specs: []const [3][]const u8, spoilers: []const u8) ![]library.DownloadSource {
    const a = testing.allocator;
    const rows = try a.alloc(library.DownloadSource, specs.len);
    for (specs, spoilers, rows) |s, sp, *r| r.* = .{
        .href = try a.dupe(u8, s[0]),
        .text = try a.dupe(u8, s[1]),
        .lead = try a.dupe(u8, s[2]),
        .ctx = try a.dupe(u8, ""),
        .spoiler = sp,
    };
    return rows;
}

test "nextParts: consecutive parts with same platform and spoiler depth" {
    const rows = try testRows(&.{
        .{ "https://pixeldrain.com/u/p1", "Pixeldrain", "Win Part 1" },
        .{ "https://pixeldrain.com/u/p2", "Pixeldrain", "Win Part 2" },
        .{ "https://pixeldrain.com/u/p3", "Pixeldrain", "Win Part 3" },
        .{ "https://pixeldrain.com/u/l2", "Pixeldrain", "Linux Part 2" },
        .{ "https://pixeldrain.com/u/s4", "Pixeldrain", "Win Part 4" },
        .{ "https://pixeldrain.com/u/x", "Pixeldrain", "Win" },
    }, &.{ 0, 0, 0, 0, 1, 0 });
    var cat = try fromRows(testing.allocator, testing.allocator, rows);
    defer cat.deinit();

    const p1 = cat.lookup("https://pixeldrain.com/u/p1").?;
    try testing.expectEqual(@as(?u8, 1), p1.entry.part);
    const r = nextParts(&cat, p1).?;
    try testing.expectEqual(@as(u8, 2), r.from);
    try testing.expectEqual(@as(u8, 3), r.to); // part 4 sits in a spoiler
    try testing.expectEqualStrings("https://pixeldrain.com/u/p2", cat.row(findPart(&cat, p1, 2).?).href);
    try testing.expect(nextParts(&cat, cat.lookup("https://pixeldrain.com/u/p3").?) == null);
    try testing.expect(nextParts(&cat, cat.lookup("https://pixeldrain.com/u/l2").?) == null);
    try testing.expect(nextParts(&cat, cat.lookup("https://pixeldrain.com/u/x").?) == null);
}

test "isActionable: hidden wrapper and forum links are not" {
    var e = entryOf("https://pixeldrain.com/u/abc", "", "Pixeldrain");
    try testing.expect(isActionable(e));
    e.wrapper = .hidden;
    try testing.expect(!isActionable(e));
    try testing.expect(!isActionable(entryOf("https://f95zone.to/threads/x.1/", "", "thread")));
    try testing.expect(!isActionable(entryOf("https://example.org/page", "", "site")));
}
