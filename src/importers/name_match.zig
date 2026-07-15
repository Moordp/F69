// Pure name-matching helpers for folder-import. Given a "candidate
// name" the folder scanner parsed (`"AboveTheClouds"`) and a set of
// library game names, score the candidate against each and pick the
// best match above a confidence threshold.
//
// Kept dependency-free on purpose. Callers feed in `[]const u8`
// names + `u64` thread ids; this module knows nothing about
// `library.Game` so it can be unit-tested without a DB and reused
// by any future importer that wants the same fuzzy-attach UX.

const std = @import("std");

/// Score threshold for `bestMatch` to declare a winner. 0.7 was
/// hand-tuned against the user's library (~handful of typo-style
/// folder variations like `BeautyandtheThug` vs `Beauty and the Thug`,
/// or `KarrynsPrison` vs `Karryn's Prison`). Lower → more false
/// positives; higher → user has to manually link too often.
pub const MATCH_THRESHOLD: f32 = 0.7;

/// Returned by `bestMatch`. `score` is for UI display (so the row
/// can show a confidence chip) and for the caller to decide
/// auto-link vs ask-to-confirm.
pub const Match = struct {
    thread_id: u64,
    name: []const u8,
    score: f32,
};

/// Lowercase suffix tokens we drop from BOTH sides before scoring —
/// they're platform / build noise, not part of the game's identity.
/// Aligned with `folder_scan.TAIL_NOISE` but kept independent so the
/// match-side rules can evolve without touching the scanner.
const TAIL_NOISE = [_][]const u8{
    "pc",       "linux",     "win",     "windows", "mac",  "macos", "android",
    "ios",      "final",     "market",  "steam",   "wip",  "eng",   "rus",
    "jpn",      "multi5",    "premium", "ver",     "beta", "alpha", "demo",
    "complete", "completed", "the",     "a",       "an",
};

fn isTailNoise(tok: []const u8) bool {
    for (TAIL_NOISE) |s| if (std.ascii.eqlIgnoreCase(tok, s)) return true;
    return false;
}

/// Write a normalised lowercase alphanumeric form of `raw` into
/// `out`, returning the slice of valid bytes. Strips punctuation,
/// whitespace, and apostrophes; keeps letters + digits only. Used
/// as the substrate for token splitting + scoring.
///
/// Returns null if `out` is too small to hold the result.
pub fn normalise(out: []u8, raw: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (raw) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (n >= out.len) return null;
            out[n] = std.ascii.toLower(c);
            n += 1;
        }
    }
    return out[0..n];
}

/// Split `s` into camelCase / digit-boundary / underscore-separated
/// tokens, dropping tail-noise tokens. `out` collects token slices
/// pointing INTO `s`.
///
/// Tokens are lowercased identifiers like `"abovetheclouds"`,
/// `"beautyandthethug"`, etc. We additionally split on case-change
/// boundaries in the ORIGINAL string when caller provided it (so
/// `"AboveTheClouds"` → `[above, the, clouds]`); but for the
/// already-normalised lowercase input we use here, split only on
/// digit-letter transitions.
fn tokenise(out: *[16][]const u8, lowered: []const u8) usize {
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < lowered.len) : (i += 1) {
        const cur = lowered[i];
        const at_boundary = i + 1 < lowered.len and
            (std.ascii.isDigit(cur) != std.ascii.isDigit(lowered[i + 1]));
        if (at_boundary) {
            // Keep single-char tokens — they're how a trailing digit
            // (chapter/season marker) shows up after digit/letter
            // splitting. Tail-noise filter still drops "a"/"an"/etc.
            if (i + 1 > start) {
                const tok = lowered[start .. i + 1];
                if (!isTailNoise(tok) and n < out.len) {
                    out[n] = tok;
                    n += 1;
                }
            }
            start = i + 1;
        }
    }
    if (lowered.len > start) {
        const tok = lowered[start..lowered.len];
        if (!isTailNoise(tok) and n < out.len) {
            out[n] = tok;
            n += 1;
        }
    }
    return n;
}

/// Score two raw names in 0..1. Higher = more similar.
///
/// Mix of two cheap signals:
///   1. Normalised-string equality / containment — catches the
///      "AboveTheClouds" vs "Above The Clouds" case (after normalise
///      both collapse to `abovetheclouds`).
///   2. Token Jaccard on digit-letter-split tokens — catches partial
///      matches like "BeautyAndThug" vs "BeautyAndTheThug".
///
/// 1.0 means the normalised forms are identical. ≥0.7 is the
/// auto-link threshold.
pub fn score(a_raw: []const u8, b_raw: []const u8) f32 {
    var a_buf: [128]u8 = undefined;
    var b_buf: [128]u8 = undefined;
    const a = normalise(&a_buf, a_raw) orelse return 0;
    const b = normalise(&b_buf, b_raw) orelse return 0;
    if (a.len == 0 or b.len == 0) return 0;

    // Exact normalised match wins outright.
    if (std.mem.eql(u8, a, b)) return 1.0;

    // Containment: one is a substring of the other. Single guard —
    // `shorter.len >= 3` — keeps "a"/"ab" from matching every entry
    // starting with a vowel, but lets any 3+ char meaningful query
    // surface its matches even in a long library title. No ratio
    // floor: in real-world use the typeahead is a search box, and
    // returning a weak-but-still-relevant match is better than
    // returning nothing. Score = max(ratio, MATCH_THRESHOLD) so it
    // always lands at "match" but ranks higher when the substring
    // dominates the longer name.
    const longer = if (a.len >= b.len) a else b;
    const shorter = if (a.len >= b.len) b else a;
    if (shorter.len >= 3 and std.mem.indexOf(u8, longer, shorter) != null) {
        const ratio = @as(f32, @floatFromInt(shorter.len)) / @as(f32, @floatFromInt(longer.len));
        return @max(ratio, MATCH_THRESHOLD);
    }

    // Token Jaccard. Bounded array — names beyond 16 tokens are
    // very unusual; truncation just lowers their score, which is OK.
    var a_toks: [16][]const u8 = undefined;
    var b_toks: [16][]const u8 = undefined;
    const a_n = tokenise(&a_toks, a);
    const b_n = tokenise(&b_toks, b);
    if (a_n == 0 or b_n == 0) return 0;

    var intersect: usize = 0;
    for (a_toks[0..a_n]) |at| {
        for (b_toks[0..b_n]) |bt| {
            if (std.mem.eql(u8, at, bt)) {
                intersect += 1;
                break;
            }
        }
    }
    const union_size = a_n + b_n - intersect;
    return @as(f32, @floatFromInt(intersect)) / @as(f32, @floatFromInt(union_size));
}

/// Caller's view of a library game for matching purposes. Just a
/// name + the thread id. Keeps this module free of any DB or
/// library coupling.
pub const Candidate = struct {
    thread_id: u64,
    name: []const u8,
};

/// Score `query` against each `Candidate` and return the highest
/// scorer if its score ≥ `MATCH_THRESHOLD`. Null when no candidate
/// crosses the bar — the caller treats that as "no auto-link" and
/// leaves the row to user resolution.
///
/// Ties broken by the caller — pass the candidates pre-sorted by
/// preferred-on-tie criteria (e.g. `last_updated_at DESC`) and the
/// first one to reach the top score wins (we use `> best_score`,
/// not `>=`, so the input order is the tiebreak).
pub fn bestMatch(query: []const u8, candidates: []const Candidate) ?Match {
    var best: ?Match = null;
    for (candidates) |c| {
        const s = score(query, c.name);
        if (s < MATCH_THRESHOLD) continue;
        if (best == null or s > best.?.score) {
            best = .{ .thread_id = c.thread_id, .name = c.name, .score = s };
        }
    }
    return best;
}

/// Chapter / season / episode markers that distinguish entries in
/// the same series. Sorted longest-first so prefix collisions don't
/// happen (`chapter` checked before `ch`, `episode` before `ep`).
const CHAPTER_MARKERS = [_][]const u8{
    "chapter", "episode", "season", "volume", "part", "ep", "ch", "vol", "s",
};

/// Strip a trailing chapter/season/episode marker (plus its digits)
/// from an already-normalised name. Used to group different chapters
/// of the same series so the typeahead can offer them as siblings
/// (NOT as auto-links). Two strategies, tried in order:
///
///   1. Trailing digits preceded by a known marker word.
///      `gamechapter2` → `game`, `tales3season1` is left alone.
///   2. Bare trailing digits when the stem is ≥3 chars.
///      `game2` → `game`. Avoids stripping the only content of
///      short names like `2` or `m2`.
///
/// Returns a slice into `norm` — caller must not retain past
/// `norm`'s lifetime.
pub fn stripChapterSuffix(norm: []const u8) []const u8 {
    if (norm.len == 0) return norm;

    var end = norm.len;
    while (end > 0 and std.ascii.isDigit(norm[end - 1])) end -= 1;
    const digits_len = norm.len - end;
    if (digits_len == 0) return norm; // no trailing number → not a chapter

    // Strategy 1: marker word right before the digits.
    for (CHAPTER_MARKERS) |m| {
        if (end >= m.len) {
            if (std.ascii.eqlIgnoreCase(norm[end - m.len .. end], m)) {
                const stem_end = end - m.len;
                if (stem_end >= 2) return norm[0..stem_end];
            }
        }
    }

    // Strategy 2: bare trailing digits. Require ≥3 chars of stem so
    // we don't reduce names to fragments.
    if (digits_len <= 2 and end >= 3) return norm[0..end];
    return norm;
}

/// Compute the series key for a raw name: normalise + strip chapter
/// suffix. Two names with the same `seriesKey` are likely entries in
/// the same game series (e.g. `Some Game Chapter 1` and
/// `Some Game Chapter 2`). Used by the typeahead to surface series
/// siblings as "Related" suggestions distinct from auto-link
/// matches.
///
/// Returns null when `out` is too small to hold the normalised form.
pub fn seriesKey(out: []u8, raw: []const u8) ?[]const u8 {
    const norm = normalise(out, raw) orelse return null;
    return stripChapterSuffix(norm);
}

/// True when `a` and `b` are likely different entries in the same
/// series — i.e. same `seriesKey`, but `score(a, b) < MATCH_THRESHOLD`
/// (the fuzzy matcher already says they're different games). The
/// typeahead uses this to add a "Related (series)" group beneath the
/// auto-link suggestions: user can still pick one as the target if
/// they really are the same install, but we don't auto-link.
pub fn isSeriesSibling(a: []const u8, b: []const u8) bool {
    var a_buf: [128]u8 = undefined;
    var b_buf: [128]u8 = undefined;
    const a_key = seriesKey(&a_buf, a) orelse return false;
    const b_key = seriesKey(&b_buf, b) orelse return false;
    if (a_key.len < 3) return false; // too short to call a series
    if (!std.mem.eql(u8, a_key, b_key)) return false;
    return score(a, b) < MATCH_THRESHOLD;
}

/// Stable random thread id for "custom new" library entries — games
/// the user explicitly added through the import preview without an
/// F95 thread URL. High bit set so they're in the synthetic-id
/// range (`folder_scan.isSyntheticThreadId` returns true), random
/// 63-bit body so two different imports don't collide on the same
/// id even when they share a name (unlike `syntheticThreadId` which
/// is a name hash).
///
/// Takes an `io` so the test harness can stub randomness.
pub fn customNewThreadId(io: std.Io) u64 {
    var buf: [8]u8 = undefined;
    io.randomSecure(&buf) catch io.random(&buf);
    const raw = std.mem.readInt(u64, &buf, .little);
    return raw | (@as(u64, 1) << 63);
}

// ---- tests ----------------------------------------------------

const testing = std.testing;

test "normalise: drops spaces + punctuation + apostrophes" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("abovetheclouds", normalise(&buf, "Above The Clouds").?);
    try testing.expectEqualStrings("karrynsprison", normalise(&buf, "Karryn's Prison").?);
    try testing.expectEqualStrings("beauty4ndthe5thug", normalise(&buf, "Beauty 4nd the 5Thug!").?);
}

test "score: identical (mod normalisation) → 1.0" {
    try testing.expectEqual(@as(f32, 1.0), score("Above The Clouds", "AboveTheClouds"));
    try testing.expectEqual(@as(f32, 1.0), score("Karryn's Prison", "karrynsprison"));
}

test "score: substring containment passes threshold" {
    // "BeautyAndTheThug" contains "BeautyAndTheThug" exactly → 1.0
    try testing.expectEqual(@as(f32, 1.0), score("Beauty and the Thug", "BeautyAndTheThug"));
    // Folder-stripped name inside a richer library entry:
    try testing.expect(score("AboveTheClouds", "Above The Clouds: A Lovers' Story") >= MATCH_THRESHOLD);
}

test "score: unrelated names → below threshold" {
    try testing.expect(score("Above The Clouds", "Dating Amy") < MATCH_THRESHOLD);
    try testing.expect(score("Karryn's Prison", "Acting Lessons") < MATCH_THRESHOLD);
}

test "score: short query matches longer library entry" {
    // "haley" → "haley's Story" should surface in search results.
    // Reported as too-strict cases by the user.
    try testing.expect(score("haley", "Haley's Story") >= MATCH_THRESHOLD);
    try testing.expect(score("Haley", "haley's") >= MATCH_THRESHOLD);
    try testing.expect(score("DMD fantasy", "DMD - Fantasy") >= MATCH_THRESHOLD);
    try testing.expect(score("dmd", "DMD - Fantasy Episode 2") >= MATCH_THRESHOLD);
}

test "score: 1-2 char queries don't match longer names" {
    // Containment guard — `a` shouldn't match every library entry
    // that happens to start with a vowel.
    try testing.expect(score("a", "Above The Clouds") < MATCH_THRESHOLD);
    try testing.expect(score("ab", "Above The Clouds") < MATCH_THRESHOLD);
}

test "bestMatch: picks the highest scorer ≥ threshold" {
    const candidates = [_]Candidate{
        .{ .thread_id = 1, .name = "Acting Lessons" },
        .{ .thread_id = 2, .name = "Above The Clouds" },
        .{ .thread_id = 3, .name = "Dating Amy" },
    };
    const m = bestMatch("AboveTheClouds", &candidates).?;
    try testing.expectEqual(@as(u64, 2), m.thread_id);
    try testing.expect(m.score >= MATCH_THRESHOLD);
}

test "bestMatch: returns null when nothing crosses the bar" {
    const candidates = [_]Candidate{
        .{ .thread_id = 1, .name = "Acting Lessons" },
        .{ .thread_id = 2, .name = "Dating Amy" },
    };
    try testing.expect(bestMatch("KarrynsPrison", &candidates) == null);
}

test "bestMatch: input order breaks ties" {
    const candidates = [_]Candidate{
        .{ .thread_id = 10, .name = "Above The Clouds" },
        .{ .thread_id = 20, .name = "Above The Clouds" }, // dup, same score
    };
    const m = bestMatch("AboveTheClouds", &candidates).?;
    // We use `>` not `>=`, so the FIRST max wins.
    try testing.expectEqual(@as(u64, 10), m.thread_id);
}

// ---- chapter / series detection ------------------------------

test "stripChapterSuffix: 'chapter N' suffix" {
    try testing.expectEqualStrings("game", stripChapterSuffix("gamechapter2"));
    try testing.expectEqualStrings("game", stripChapterSuffix("gamechapter12"));
}

test "stripChapterSuffix: 'ch N' suffix" {
    try testing.expectEqualStrings("fifaislands", stripChapterSuffix("fifaislandsch1"));
}

test "stripChapterSuffix: 'season N' suffix" {
    try testing.expectEqualStrings("show", stripChapterSuffix("showseason3"));
}

test "stripChapterSuffix: 'sN' suffix" {
    try testing.expectEqualStrings("show", stripChapterSuffix("shows2"));
}

test "stripChapterSuffix: bare trailing digit" {
    try testing.expectEqualStrings("game", stripChapterSuffix("game2"));
}

test "stripChapterSuffix: no number → unchanged" {
    try testing.expectEqualStrings("dating", stripChapterSuffix("dating"));
}

test "stripChapterSuffix: short name not trimmed to fragment" {
    // "m2" - stem "m" is too short (<3), keep as-is.
    try testing.expectEqualStrings("m2", stripChapterSuffix("m2"));
}

test "seriesKey: variations collapse to same key" {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const k1 = seriesKey(&b1, "Some Game Chapter 1").?;
    const k2 = seriesKey(&b2, "Some Game Chapter 2").?;
    try testing.expectEqualStrings(k1, k2);
}

test "isSeriesSibling: different chapters are siblings, not matches" {
    try testing.expect(isSeriesSibling("Some Game Chapter 1", "Some Game Chapter 2"));
    try testing.expect(score("Some Game Chapter 1", "Some Game Chapter 2") < MATCH_THRESHOLD);
}

test "isSeriesSibling: same name → not a sibling (it's a match)" {
    try testing.expect(!isSeriesSibling("Some Game", "Some Game"));
}

test "isSeriesSibling: unrelated names → not a sibling" {
    try testing.expect(!isSeriesSibling("Dating Amy", "Above The Clouds"));
}

test "isSeriesSibling: bare-number variants" {
    try testing.expect(isSeriesSibling("AdventureGame 1", "AdventureGame 2"));
}

test "fuzz: name matching invariants hold on arbitrary input" {
    // Multi-call Smith stream — no hand-encoded corpus (the 4-byte-LE
    // fuzzSeed format only fits single-slice harnesses); the automatic
    // empty-input run is the replay smoke test.
    try std.testing.fuzz({}, fuzzNameMatch, .{});
}

fn fuzzNameMatch(_: void, smith: *std.testing.Smith) anyerror!void {
    // 300-byte inputs deliberately exceed score()'s internal 128-byte
    // normalise buffers to exercise the too-long rejection path.
    var a_buf: [300]u8 = undefined;
    const a_len = smith.slice(&a_buf);
    var b_buf: [300]u8 = undefined;
    const b_len = smith.slice(&b_buf);
    const a = a_buf[0..a_len];
    const b = b_buf[0..b_len];

    var norm_buf: [512]u8 = undefined;
    if (normalise(&norm_buf, a)) |norm| _ = stripChapterSuffix(norm);

    // score is a similarity in [0, 1].
    const s = score(a, b);
    try std.testing.expect(s >= 0.0);
    try std.testing.expect(s <= 1.0);

    // Self-match is exact (1.0) or degenerate (0.0 when normalise
    // rejects/empties) — nothing in between.
    const self_score = score(a, a);
    try std.testing.expect(self_score == 0.0 or self_score == 1.0);

    var key_buf: [512]u8 = undefined;
    _ = seriesKey(&key_buf, a);
    _ = isSeriesSibling(a, b);

    const candidates = [_]Candidate{
        .{ .thread_id = 1, .name = b },
    };
    if (bestMatch(a, &candidates)) |m| {
        try std.testing.expect(m.score >= MATCH_THRESHOLD);
    }
}
