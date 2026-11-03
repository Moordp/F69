//! Shared saves between chapters of one story.
//!
//! A sequel often reads the previous chapter's saves. Each game has its
//! own sandbox HOME (`<library>/<tid>/.f69-home`); linking a game to a
//! "root" game makes it use the root's HOME instead (`Game.saves_group`).
//! Pure helpers (`seriesKey`, `looksLikeSeries`) spot likely chapters so
//! the game page can suggest the link; the user confirms.

const std = @import("std");
const library = @import("library");
const types = @import("../types.zig");
const common = @import("common.zig");

const Frame = types.Frame;
const Game = library.Game;

/// The game whose sandbox HOME `tid` uses: its root when linked, else
/// itself.
pub fn rootOf(frame: *Frame, tid: u64) u64 {
    if (lookup(frame, tid)) |g| {
        if (g.saves_group) |r| return r;
    }
    return tid;
}

fn lookup(frame: *Frame, tid: u64) ?*Game {
    if (frame.games_by_thread) |map| {
        if (map.get(tid)) |g| return g;
    }
    for (frame.games) |*g| {
        if (g.f95_thread_id == tid) return g;
    }
    return null;
}

/// Number of other games that share `tid`'s HOME (point at it as root).
pub fn memberCount(frame: *Frame, tid: u64) usize {
    var n: usize = 0;
    for (frame.games) |*g| {
        if (g.f95_thread_id != tid and g.saves_group == tid) n += 1;
    }
    return n;
}

/// Make `tid` share the HOME of `other` (or of `other`'s root). Games
/// that shared `tid`'s HOME follow it to the same root, so one story
/// stays one group. No-op when the two already share.
pub fn link(frame: *Frame, tid: u64, other: u64) !void {
    if (tid == other) return;
    const root = rootOf(frame, other);
    if (root == tid) return; // `other` already follows `tid`
    if (rootOf(frame, tid) == root) return;
    try frame.lib.setSavesGroup(tid, root);
    if (lookup(frame, tid)) |g| g.saves_group = root;
    for (frame.games) |*g| {
        if (g.saves_group == tid) {
            try frame.lib.setSavesGroup(g.f95_thread_id, root);
            g.saves_group = root;
        }
    }
}

/// Give `tid` its own HOME again. Games that followed `tid` keep
/// following it (it stays their root).
pub fn unlink(frame: *Frame, tid: u64) !void {
    try frame.lib.setSavesGroup(tid, null);
    if (lookup(frame, tid)) |g| g.saves_group = null;
}

/// The installed game that looks like another chapter of `game`'s story
/// and does not share its HOME yet; null when there is none. Prefers a
/// root (a game with its own HOME) and, among those, the oldest thread.
pub fn suggestSibling(frame: *Frame, game: *const Game) ?*const Game {
    var best: ?*const Game = null;
    var key_buf: [160]u8 = undefined;
    const key = seriesKey(&key_buf, game.name);
    if (key.len == 0) return null;
    const my_root = rootOf(frame, game.f95_thread_id);
    for (frame.games) |*g| {
        if (g.f95_thread_id == game.f95_thread_id) continue;
        if (!common.isInstalled(frame, g.f95_thread_id)) continue;
        if (rootOf(frame, g.f95_thread_id) == my_root) continue;
        if (!looksLikeSeries(game.name, game.developer, g.name, g.developer)) continue;
        if (best) |b| {
            const b_root = b.saves_group == null;
            const g_root = g.saves_group == null;
            if (b_root and !g_root) continue;
            if (b_root == g_root and b.f95_thread_id < g.f95_thread_id) continue;
        }
        best = g;
    }
    return best;
}

/// Pure. True when the two titles read as chapters of one story: same
/// series key (see `seriesKey`) and, when both developers are known, the
/// same developer.
pub fn looksLikeSeries(name_a: []const u8, dev_a: ?[]const u8, name_b: []const u8, dev_b: ?[]const u8) bool {
    if (std.ascii.eqlIgnoreCase(name_a, name_b)) return false;
    var ba: [160]u8 = undefined;
    var bb: [160]u8 = undefined;
    var ka = seriesKey(&ba, name_a);
    var kb = seriesKey(&bb, name_b);
    // The first chapter often carries no number ("Long Story" and "Long
    // Story 2"): an unmarked title is its own key against a marked one.
    if (ka.len == 0 and kb.len > 0) ka = wholeKey(&ba, name_a);
    if (kb.len == 0 and ka.len > 0) kb = wholeKey(&bb, name_b);
    if (ka.len == 0 or !std.mem.eql(u8, ka, kb)) return false;
    if (dev_a) |a| {
        if (dev_b) |b| {
            if (a.len > 0 and b.len > 0 and !std.ascii.eqlIgnoreCase(a, b)) return false;
        }
    }
    return true;
}

const MARKERS = [_][]const u8{ "chapter", "chap", "ch", "part", "episode", "ep", "season", "book", "volume", "vol", "act" };

/// Pure. The story part of a title, lowercased into `buf`: everything
/// before a chapter marker ("Chapter 2", "Ch.1", "Part II", "Episode 3",
/// "Season 2", "Book 1", "Vol. 2", "Act 3") or before a trailing bare
/// number ("Story 2"), with trailing separators removed. Empty when the
/// title has no marker or the key would be shorter than 4 characters.
pub fn seriesKey(buf: []u8, name: []const u8) []const u8 {
    const n = @min(name.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], name[0..n]);
    var cut: ?usize = null;
    // Word by word: a marker word followed by a number (or roman numeral)
    // ends the key; so does a bare number as the last word, unless the
    // word before it is a marker ("Chapter 2" alone is no story).
    var i: usize = 0;
    var prev_marker = false;
    while (i < lower.len) {
        while (i < lower.len and !isWordChar(lower[i])) : (i += 1) {}
        if (i >= lower.len) break;
        const start = i;
        while (i < lower.len and isWordChar(lower[i])) : (i += 1) {}
        const word = lower[start..i];
        const marker = isMarker(word);
        defer prev_marker = marker;
        if (marker and nextIsNumber(lower[i..])) {
            if (start == 0) return buf[0..0]; // a title cannot be only a marker
            cut = start;
            break;
        }
        if (start > 0 and !prev_marker and isNumberWord(word) and restIsBlank(lower[i..])) {
            cut = start;
            break;
        }
    }
    const end = cut orelse return buf[0..0];
    return trimKey(lower, end);
}

/// `lower[0..end]` without trailing separators; empty when shorter than 4.
fn trimKey(lower: []const u8, end: usize) []const u8 {
    var k = end;
    while (k > 0 and !isWordChar(lower[k - 1])) : (k -= 1) {}
    if (k < 4) return lower[0..0];
    return lower[0..k];
}

/// The whole title as a key (lowercased, trailing separators removed).
fn wholeKey(buf: []u8, name: []const u8) []const u8 {
    const n = @min(name.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], name[0..n]);
    return trimKey(lower, lower.len);
}

/// Letters and digits only: "Ch.2" splits into the marker "ch" and "2".
fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

fn isMarker(word: []const u8) bool {
    for (MARKERS) |m| if (std.mem.eql(u8, word, m)) return true;
    return false;
}

fn isNumberWord(word: []const u8) bool {
    if (word.len == 0) return false;
    var all_digits = true;
    for (word) |c| if (!std.ascii.isDigit(c)) {
        all_digits = false;
        break;
    };
    if (all_digits) return true;
    const romans = [_][]const u8{ "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x" };
    for (romans) |r| if (std.mem.eql(u8, word, r)) return true;
    return false;
}

/// `rest` starts right after a marker: optional separators, then a number word.
fn nextIsNumber(rest: []const u8) bool {
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '.' or rest[i] == '#' or rest[i] == '-' or rest[i] == ':')) : (i += 1) {}
    const start = i;
    while (i < rest.len and isWordChar(rest[i])) : (i += 1) {}
    return isNumberWord(rest[start..i]);
}

fn restIsBlank(rest: []const u8) bool {
    for (rest) |c| if (isWordChar(c)) return false;
    return true;
}

test "seriesKey: chapter markers, bare trailing numbers, no marker" {
    var b: [160]u8 = undefined;
    try std.testing.expectEqualStrings("long story", seriesKey(&b, "Long Story Ch.2"));
    try std.testing.expectEqualStrings("long story", seriesKey(&b, "Long Story - Chapter 1"));
    try std.testing.expectEqualStrings("long story", seriesKey(&b, "Long Story: Episode III"));
    try std.testing.expectEqualStrings("long story", seriesKey(&b, "Long Story Season 2"));
    try std.testing.expectEqualStrings("long story", seriesKey(&b, "Long Story 2"));
    try std.testing.expectEqualStrings("long story", seriesKey(&b, "Long Story Part 2 (Remastered)"));
    try std.testing.expectEqualStrings("", seriesKey(&b, "Long Story"));
    try std.testing.expectEqualStrings("", seriesKey(&b, "Chapter 2"));
    try std.testing.expectEqualStrings("", seriesKey(&b, "Ep 2"));
    // "Act" inside a word is not a marker; a number mid-title is not a chapter.
    try std.testing.expectEqualStrings("", seriesKey(&b, "Exact Science"));
    try std.testing.expectEqualStrings("", seriesKey(&b, "Area 51 Nights"));
}

test "looksLikeSeries: same key and developer; developer unknown passes; identical titles never" {
    try std.testing.expect(looksLikeSeries("Long Story Ch.1", "Dev A", "Long Story Ch.2", "dev a"));
    try std.testing.expect(looksLikeSeries("Long Story", "Dev A", "Long Story 2", null));
    try std.testing.expect(!looksLikeSeries("Long Story Ch.1", "Dev A", "Long Story Ch.2", "Dev B"));
    try std.testing.expect(!looksLikeSeries("Long Story Ch.1", null, "Other Story Ch.2", null));
    try std.testing.expect(!looksLikeSeries("Long Story Ch.1", null, "long story ch.1", null));
}
