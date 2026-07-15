// Version string handling for f69. F95 OPs publish free-form versions
// ("Ep 12 v0.20 Public", "Final", "0.20.0a"); RPDL torrent titles
// publish dash-separated tokens ("Game-Title-v0.20-Linux"). Earlier
// code lived in two places — `ui/actions.zig::versionsEquivalent` and
// `downloads/rpdl.zig::extractVersionFromTitle` — and the two rules
// drifted, leading to the install dot flashing "outdated" against
// versions that were actually the same release with different
// surface tokens.
//
// This module centralizes both: a single `Canonical` form (episode,
// numeric core, optional letter suffix, is_final flag) used for both
// equivalence and right-to-left extraction.

const std = @import("std");

pub const Canonical = struct {
    /// Episode/chapter number extracted from "ep12" / "episode 12" /
    /// "ch3" / "chapter 3". `null` when not declared.
    episode: ?u32 = null,
    /// Numeric segments of the version joined with '.' — e.g. "0.20.0".
    /// Empty when only `is_final` was found. Borrows from the
    /// canonicalize() output buffer.
    core: []const u8 = "",
    /// Trailing single-letter build qualifier ('a','b',…). Lowercase.
    /// `0` when none.
    suffix: u8 = 0,
    /// "final" / "complete" / "full" appeared anywhere in the input.
    /// On its own (no numeric core) it acts as a release-state sentinel
    /// that compares equal to any other final. Mixed with a numeric
    /// core it's informational — comparison still goes by core.
    is_final: bool = false,

    pub fn empty(self: Canonical) bool {
        return !self.is_final and self.core.len == 0 and self.episode == null;
    }
};

/// Right-to-left scan for a version-shaped token. Walks segments
/// separated by `-`, `_`, ` `, or `\t` and returns the first one
/// that "looks like a version": starts with a digit, or starts with
/// 'v'+digit, or is one of {Final, Complete, Full}. Returned slice
/// borrows from `title`; caller dupes if it needs an independent
/// lifetime. Returns null when no segment qualifies.
pub fn extractFromTitle(title: []const u8) ?[]const u8 {
    var end = title.len;
    while (end > 0) {
        var i: usize = end;
        while (i > 0) : (i -= 1) {
            const c = title[i - 1];
            if (c == '-' or c == '_' or c == ' ' or c == '\t') break;
        }
        const seg = title[i..end];
        if (looksLikeVersion(seg)) return seg;
        if (i == 0) break;
        end = i - 1;
    }
    return null;
}

/// Best-effort version guess from an archive file PATH (the file the
/// user actually picked, not the thread's latest). Strips the directory
/// (handling both `/` and `\` separators) and the archive extension —
/// including compound ones like `.tar.gz` — then runs `extractFromTitle`
/// on the stem. Returns a slice into `path`, or null when the basename
/// has no version-like token. Used by the manual-install panel so an
/// install is labelled by the build on disk rather than F95's newest.
pub fn fromArchivePath(path: []const u8) ?[]const u8 {
    // Strip directory: last of either separator.
    const fwd = std.mem.lastIndexOfScalar(u8, path, '/');
    const back = std.mem.lastIndexOfScalar(u8, path, '\\');
    const sep: ?usize = if (fwd) |f| (if (back) |b| @max(f, b) else f) else back;
    const base = if (sep) |s| path[s + 1 ..] else path;

    // Strip the extension. Compound archive extensions first so
    // `Game-1.2.tar.gz` doesn't keep a stray `.tar` that the version
    // scan would otherwise swallow.
    const compound = [_][]const u8{ ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst" };
    var stem = base;
    for (compound) |ext| {
        if (base.len >= ext.len and eqlAsciiCase(base[base.len - ext.len ..], ext)) {
            stem = base[0 .. base.len - ext.len];
            break;
        }
    } else {
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
        stem = base[0..dot];
    }
    return extractFromTitle(stem);
}

fn looksLikeVersion(seg: []const u8) bool {
    if (seg.len == 0) return false;
    if (std.ascii.isDigit(seg[0])) return true;
    if ((seg[0] == 'v' or seg[0] == 'V') and seg.len >= 2 and std.ascii.isDigit(seg[1])) return true;
    const finals = [_][]const u8{ "final", "complete", "full" };
    for (finals) |f| if (eqlAsciiCase(seg, f)) return true;
    // RPDL torrent titles routinely use chapter/part-style suffixes
    // ("ChroniclesOfKartoba-C1P1"). They're not v1.2 versions but
    // they ARE the only stable identifier we get for that build, so
    // accept any segment that mixes letters with digits — that's a
    // good enough "version-like" signal to beat the "unversioned"
    // bucket. Cap segment length so a basename like "abcdef-deadbeef"
    // doesn't latch onto the hash trailer.
    if (seg.len <= 20) {
        for (seg) |c| if (std.ascii.isDigit(c)) return true;
    }
    return false;
}

/// Total ordering on version strings. Drives "newest install on top"
/// in the picker. Best-effort — F95 versions aren't strictly
/// orderable (you can encounter `Ep11 v0.20` vs `Final` vs `0.21a`
/// in the same library) — but the rule set below covers the cases
/// that matter in practice:
///   1. Episode/chapter ranks first (Ep12 > Ep11). Null episode is
///      treated as 0 so a labelled-episode install beats an unlabelled
///      one at the same numeric version.
///   2. Numeric core compared segment-wise, missing segments default
///      to 0 (so `21.0` == `21.0.0`).
///   3. Suffix letter ('b' > 'a', no-suffix < any letter — patch
///      letter convention F95 mostly uses).
///   4. `is_final` flag as the last tiebreaker.
/// Caller falls back to literal `std.mem.order` when either side
/// can't canonicalize (rare, e.g. >128 byte version strings).
pub fn compare(a: []const u8, b: []const u8) std.math.Order {
    if (a.len == 0 and b.len == 0) return .eq;
    if (a.len == 0) return .lt;
    if (b.len == 0) return .gt;
    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;
    const ca = canonicalize(&buf_a, a) orelse return std.mem.order(u8, a, b);
    const cb = canonicalize(&buf_b, b) orelse return std.mem.order(u8, a, b);
    return canonicalCompare(ca, cb);
}

fn canonicalCompare(a: Canonical, b: Canonical) std.math.Order {
    // "Final"/"Complete" with no numeric core is a release-state
    // sentinel — F95 uses it for "this is the last build of the
    // game". Sorts above any numeric version. A `1.0 Final`
    // (numeric core + flag) doesn't get the sentinel boost; its
    // numeric core competes normally and is_final only breaks
    // ties at the very end.
    const a_top = a.is_final and a.core.len == 0;
    const b_top = b.is_final and b.core.len == 0;
    if (a_top and b_top) return .eq;
    if (a_top) return .gt;
    if (b_top) return .lt;

    const ea = a.episode orelse 0;
    const eb = b.episode orelse 0;
    if (ea != eb) return std.math.order(ea, eb);

    const core_ord = coresCompare(a.core, b.core);
    if (core_ord != .eq) return core_ord;

    if (a.suffix != b.suffix) return std.math.order(a.suffix, b.suffix);

    if (a.is_final and !b.is_final) return .gt;
    if (!a.is_final and b.is_final) return .lt;
    return .eq;
}

fn coresCompare(a: []const u8, b: []const u8) std.math.Order {
    var it_a = std.mem.splitScalar(u8, a, '.');
    var it_b = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const sa_opt = it_a.next();
        const sb_opt = it_b.next();
        if (sa_opt == null and sb_opt == null) return .eq;
        // Missing segment defaults to "0" — keeps "21.0" == "21.0.0"
        // even via the strict comparator (matters because callers
        // sort with this; equivalent strings must collapse to .eq).
        const sa = sa_opt orelse "0";
        const sb = sb_opt orelse "0";
        const na = std.fmt.parseInt(u64, sa, 10) catch return std.mem.order(u8, sa, sb);
        const nb = std.fmt.parseInt(u64, sb, 10) catch return std.mem.order(u8, sa, sb);
        if (na != nb) return std.math.order(na, nb);
    }
}

/// Operator in a single constraint term. `eq` is also the implicit
/// operator when the term has no prefix (e.g. `"0.20"` means
/// `"=0.20"`).
pub const ConstraintOp = enum { eq, ne, gt, gte, lt, lte };

/// Does `version` satisfy `constraint`? The constraint is a comma-
/// separated AND-list of terms, each `<op><version>` where op is one
/// of `>=`, `<=`, `>`, `<`, `=`, `!=` (op omitted → implicit `=`).
/// Examples that should all evaluate true for "0.20.5":
///   ""                    — empty constraint matches anything
///   "0.20.5"              — implicit equality (via equivalent)
///   ">=0.20"              — newer or equal
///   ">=0.20,<0.21"        — typical "compatible with v0.20.x" pin
///   "<1.0"                — anything below 1.0
/// Whitespace around operators / terms is tolerated.
/// Returns true on empty constraint. Unknown operators degrade to
/// implicit-equality comparison against the bare text — a
/// nonsense term ("??garbage") behaves like requiring version ==
/// "??garbage", which fails for any real version. Errs toward
/// "excluded" rather than "matched anything" when in doubt.
pub fn satisfies(version: []const u8, constraint: []const u8) bool {
    const trimmed = std.mem.trim(u8, constraint, " \t\r\n");
    if (trimmed.len == 0) return true;

    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |raw_term| {
        const term = std.mem.trim(u8, raw_term, " \t\r\n");
        if (term.len == 0) continue;
        const parsed = parseTerm(term) orelse continue; // permissive on malformed
        if (!evaluateTerm(version, parsed.op, parsed.target)) return false;
    }
    return true;
}

const ParsedTerm = struct { op: ConstraintOp, target: []const u8 };

fn parseTerm(term: []const u8) ?ParsedTerm {
    // Two-char ops first so `>=` doesn't parse as `>`.
    if (std.mem.startsWith(u8, term, ">=")) {
        return .{ .op = .gte, .target = std.mem.trim(u8, term[2..], " \t") };
    }
    if (std.mem.startsWith(u8, term, "<=")) {
        return .{ .op = .lte, .target = std.mem.trim(u8, term[2..], " \t") };
    }
    if (std.mem.startsWith(u8, term, "!=")) {
        return .{ .op = .ne, .target = std.mem.trim(u8, term[2..], " \t") };
    }
    if (std.mem.startsWith(u8, term, ">")) {
        return .{ .op = .gt, .target = std.mem.trim(u8, term[1..], " \t") };
    }
    if (std.mem.startsWith(u8, term, "<")) {
        return .{ .op = .lt, .target = std.mem.trim(u8, term[1..], " \t") };
    }
    if (std.mem.startsWith(u8, term, "=")) {
        return .{ .op = .eq, .target = std.mem.trim(u8, term[1..], " \t") };
    }
    // No prefix → implicit equality. Most common in `target = "x", version = "1.2"` shorthand.
    return .{ .op = .eq, .target = term };
}

fn evaluateTerm(version: []const u8, op: ConstraintOp, target: []const u8) bool {
    return switch (op) {
        .eq => equivalent(version, target),
        .ne => !equivalent(version, target),
        .gt => compare(version, target) == .gt,
        .gte => switch (compare(version, target)) {
            .gt, .eq => true,
            .lt => false,
        },
        .lt => compare(version, target) == .lt,
        .lte => switch (compare(version, target)) {
            .lt, .eq => true,
            .gt => false,
        },
    };
}

/// True when `a` and `b` describe the same release modulo cosmetic
/// surface differences: leading 'v', episode prefix, platform /
/// distribution suffixes ("Linux", "Public", "Patreon"), trailing
/// zero segments, ASCII case. Errs toward "different" — if either
/// side fails to canonicalize (buffer too small) we fall back to a
/// case-insensitive literal compare rather than guess.
pub fn equivalent(a: []const u8, b: []const u8) bool {
    if (a.len == 0 and b.len == 0) return true;
    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;
    const ca = canonicalize(&buf_a, a) orelse return std.ascii.eqlIgnoreCase(a, b);
    const cb = canonicalize(&buf_b, b) orelse return std.ascii.eqlIgnoreCase(a, b);
    return canonicalEqual(ca, cb);
}

/// True when `latest` is a genuinely newer release than `installed`.
/// Equivalence wins over ordering: F95 routinely reformats a version
/// string without shipping a new build ("1.0" → "Final v1.0" when a
/// game completes), and `compare`'s lexical fallback would read that
/// as an upgrade. Callers deciding "update available" / "installed is
/// current" must use this, not raw `compare`.
pub fn hasNewer(latest: []const u8, installed: []const u8) bool {
    if (equivalent(latest, installed)) return false;
    return compare(latest, installed) == .gt;
}

/// Parse `input` into a Canonical, writing the lowercased text into
/// `buf` (Canonical.core borrows from this buffer; keep `buf` alive
/// while the returned Canonical is in use). Returns null when `input`
/// doesn't fit `buf` — caller should fall back to literal compare.
pub fn canonicalize(buf: []u8, input: []const u8) ?Canonical {
    if (input.len > buf.len) return null;
    for (input, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const lower = buf[0..input.len];

    var result: Canonical = .{};
    var last_version: []const u8 = "";
    // Fallback: a bare digit-only token (e.g. plain "1") doesn't pass
    // the strong-version test, but if it's the *only* numeric thing in
    // the input it's the version. Captured here; consumed only when no
    // strong candidate emerges.
    var weak_version: []const u8 = "";
    var pending_episode_label: bool = false;

    var it = std.mem.tokenizeAny(u8, lower, " \t-_,()[]{}/");
    while (it.next()) |raw| {
        // Episode capture: a bare "ep" / "episode" / "ch" / "chapter"
        // token primes the next pure-digit token as the episode number.
        if (pending_episode_label) {
            pending_episode_label = false;
            if (parseAllDigits(raw)) |n| {
                if (result.episode == null) result.episode = n;
                continue;
            }
            // fall through to normal classification — the label
            // without a trailing digit was just noise.
        }
        if (eqlAsciiCase(raw, "ep") or eqlAsciiCase(raw, "episode") or
            eqlAsciiCase(raw, "ch") or eqlAsciiCase(raw, "chapter"))
        {
            pending_episode_label = true;
            continue;
        }
        // Combined "ep12" / "episode12" / "ch3" / "chapter3".
        if (stripPrefixDigits(raw, "episode")) |n| {
            if (result.episode == null) result.episode = n;
            continue;
        }
        if (stripPrefixDigits(raw, "chapter")) |n| {
            if (result.episode == null) result.episode = n;
            continue;
        }
        if (stripPrefixDigits(raw, "ep")) |n| {
            if (result.episode == null) result.episode = n;
            continue;
        }
        if (stripPrefixDigits(raw, "ch")) |n| {
            if (result.episode == null) result.episode = n;
            continue;
        }
        // Release-state sentinels.
        if (eqlAsciiCase(raw, "final") or eqlAsciiCase(raw, "complete") or eqlAsciiCase(raw, "full")) {
            result.is_final = true;
            continue;
        }
        // Distribution / platform noise.
        if (isStopWord(raw)) continue;
        // Strip leading 'v' / 'V' from a version-shaped token so
        // `v0.20` and `0.20` compare equal.
        var tok = raw;
        var had_v_prefix = false;
        if (tok.len > 1 and (tok[0] == 'v') and std.ascii.isDigit(tok[1])) {
            tok = tok[1..];
            had_v_prefix = true;
        }
        if (isVersionToken(tok, had_v_prefix)) {
            // Last-wins: titles usually publish the version after
            // the game name, so the right-most match is the real one.
            last_version = tok;
        } else if (parseAllDigits(tok) != null) {
            weak_version = tok;
        }
    }

    if (last_version.len == 0 and weak_version.len > 0) {
        last_version = weak_version;
    }

    if (last_version.len > 0) {
        // Peel a trailing single letter ('a','b','c'…). Only a letter
        // immediately following a digit qualifies — guards against
        // stripping the 'h' off "1.0h2" if that ever appears.
        const n = last_version.len;
        const last_c = last_version[n - 1];
        if (n >= 2 and std.ascii.isAlphabetic(last_c) and std.ascii.isDigit(last_version[n - 2])) {
            result.suffix = std.ascii.toLower(last_c);
            result.core = last_version[0 .. n - 1];
        } else {
            result.core = last_version;
        }
    }

    return result;
}

/// Stop-words dropped silently during tokenization. Conservative —
/// these are tokens we've seen attached to versions on F95 / RPDL
/// that never carry release information.
///
/// Stored as a comptime perfect-hash set keyed by the lowercase form
/// so each call is one probe instead of the 28-entry `eqlAsciiCase`
/// cascade the table replaced.
const STOP_WORDS = std.StaticStringMap(void).initComptime(.{
    .{ "linux", {} },   .{ "windows", {} }, .{ "win", {} },   .{ "mac", {} },     .{ "macos", {} },      .{ "android", {} },  .{ "pc", {} },
    .{ "public", {} },  .{ "patreon", {} }, .{ "steam", {} }, .{ "demo", {} },    .{ "bugfix", {} },     .{ "hotfix", {} },   .{ "build", {} },
    .{ "release", {} }, .{ "rel", {} },     .{ "ver", {} },   .{ "version", {} }, .{ "x64", {} },        .{ "x86_64", {} },   .{ "x86", {} },
    .{ "i686", {} },    .{ "aarch64", {} }, .{ "free", {} },  .{ "paid", {} },    .{ "uncensored", {} }, .{ "censored", {} },
});

fn isStopWord(t: []const u8) bool {
    // Lowercase into a stack buffer so the lookup can be case-sensitive
    // against the all-lowercase key set. Tokens longer than the buffer
    // can't be stop-words (longest key is 10 chars: "uncensored").
    if (t.len > 16) return false;
    var buf: [16]u8 = undefined;
    for (t, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return STOP_WORDS.has(buf[0..t.len]);
}

fn parseAllDigits(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn stripPrefixDigits(s: []const u8, prefix: []const u8) ?u32 {
    if (s.len <= prefix.len) return null;
    if (!eqlAsciiCase(s[0..prefix.len], prefix)) return null;
    return parseAllDigits(s[prefix.len..]);
}

/// A version-shaped numeric token: digits, optional `.digits` groups,
/// optional single trailing letter. Requires `had_v_prefix` OR a `.`
/// somewhere in the token — guards against treating a bare "2" left
/// over from "Hotfix 2" as if it were a version.
fn isVersionToken(t: []const u8, had_v_prefix: bool) bool {
    if (t.len == 0) return false;
    if (!std.ascii.isDigit(t[0])) return false;
    var has_dot = false;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (std.ascii.isDigit(c)) continue;
        if (c == '.') {
            has_dot = true;
            continue;
        }
        if (std.ascii.isAlphabetic(c) and i == t.len - 1) {
            return had_v_prefix or has_dot;
        }
        return false;
    }
    return had_v_prefix or has_dot;
}

fn eqlAsciiCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

fn canonicalEqual(a: Canonical, b: Canonical) bool {
    if (a.empty() and b.empty()) return true;
    // No numeric core on either side: fall back to the release-state
    // sentinel. Two "Final"s match; a "Final" against an empty doesn't.
    if (a.core.len == 0 and b.core.len == 0) {
        return a.is_final and b.is_final;
    }
    // One side has a core, the other doesn't → definitely different.
    if (a.core.len == 0 or b.core.len == 0) return false;
    // Episodes must agree only when BOTH sides published one. One-
    // sided episodes are ignored — a torrent that strips the "Ep12"
    // prefix is still about the same release the F95 OP published.
    if (a.episode != null and b.episode != null and a.episode.? != b.episode.?) return false;
    if (a.suffix != b.suffix) return false;
    return coresEqual(a.core, b.core);
}

fn coresEqual(a: []const u8, b: []const u8) bool {
    var it_a = std.mem.splitScalar(u8, a, '.');
    var it_b = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const sa = it_a.next();
        const sb = it_b.next();
        if (sa == null and sb == null) return true;
        if (sa == null) return restAllZero(sb.?, &it_b);
        if (sb == null) return restAllZero(sa.?, &it_a);
        const na = std.fmt.parseInt(u64, sa.?, 10) catch return false;
        const nb = std.fmt.parseInt(u64, sb.?, 10) catch return false;
        if (na != nb) return false;
    }
}

fn restAllZero(first: []const u8, rest: anytype) bool {
    if (!isAllZeroSeg(first)) return false;
    while (rest.next()) |seg| if (!isAllZeroSeg(seg)) return false;
    return true;
}

fn isAllZeroSeg(seg: []const u8) bool {
    if (seg.len == 0) return true;
    for (seg) |c| if (c != '0') return false;
    return true;
}

// ============================================================
//  tests
// ============================================================

test "equivalent: trailing zeros" {
    try std.testing.expect(equivalent("21.0", "21.0.0"));
    try std.testing.expect(equivalent("21.0.0", "21.0"));
    try std.testing.expect(equivalent("1.0.0.0", "1"));
}

test "equivalent: leading v + case" {
    try std.testing.expect(equivalent("v1.0", "1.0"));
    try std.testing.expect(equivalent("V0.9b", "0.9B"));
    try std.testing.expect(equivalent("Final", "final"));
}

test "equivalent: different numeric segments" {
    try std.testing.expect(!equivalent("1.2.3", "1.2.4"));
    try std.testing.expect(!equivalent("1.2", "1.3"));
    try std.testing.expect(!equivalent("2.0", "1.0"));
}

test "hasNewer: cosmetic reformat of the same release is not an update" {
    // Field report: after a sync, installed games showed as forgotten /
    // update-available. F95 reformats version strings without shipping a
    // build; the completion rename is the worst offender — raw compare()
    // reads "Final v1.0" as lexically newer than "1.0".
    try std.testing.expect(!hasNewer("Final v1.0", "1.0"));
    try std.testing.expect(!hasNewer("v0.5.5a", "0.5.5a"));
    try std.testing.expect(!hasNewer("0.5.5a Linux", "0.5.5a"));
    try std.testing.expect(!hasNewer("Ch. 5 v0.5.5", "0.5.5"));
    try std.testing.expect(!hasNewer("V1.2 Patreon", "v1.2"));
    try std.testing.expect(!hasNewer("1.2.0", "1.2"));
}

test "hasNewer: real upgrades still detected, downgrades are not updates" {
    try std.testing.expect(hasNewer("0.6", "0.5.5a"));
    try std.testing.expect(hasNewer("v1.1", "1.0"));
    try std.testing.expect(hasNewer("Ch. 6 v0.6", "Ch. 5 v0.5"));
    try std.testing.expect(!hasNewer("1.0", "1.1"));
    try std.testing.expect(!hasNewer("0.5.5a", "0.5.5a"));
}

test "equivalent: empty strings" {
    try std.testing.expect(equivalent("", ""));
    try std.testing.expect(!equivalent("", "1.0"));
}

test "equivalent: platform suffix dropped" {
    try std.testing.expect(equivalent("0.20.0 Linux", "v0.20"));
    try std.testing.expect(equivalent("0.20 Public", "v0.20.0"));
    try std.testing.expect(equivalent("0.20 Patreon", "0.20"));
    try std.testing.expect(equivalent("v0.5 Windows", "0.5"));
}

test "equivalent: episode prefix matches when one side carries it" {
    try std.testing.expect(equivalent("Ep12 v0.20", "v0.20"));
    try std.testing.expect(equivalent("Episode 12 v0.20", "0.20"));
    try std.testing.expect(equivalent("Ch3 1.4", "1.4"));
}

test "equivalent: episode mismatch when both sides set" {
    try std.testing.expect(!equivalent("Ep11 v0.20", "Ep12 v0.20"));
    try std.testing.expect(!equivalent("Episode 1 v0.20", "Episode 2 v0.20"));
}

test "equivalent: suffix letter matters" {
    try std.testing.expect(!equivalent("0.9", "0.9b"));
    try std.testing.expect(equivalent("0.9b", "v0.9B"));
}

test "equivalent: 'Hotfix 2' does not become version 2" {
    try std.testing.expect(equivalent("0.9 Hotfix 2", "0.9"));
    try std.testing.expect(!equivalent("0.9 Hotfix 2", "2.0"));
}

test "equivalent: Final sentinel" {
    try std.testing.expect(equivalent("Final", "Complete"));
    try std.testing.expect(equivalent("1.0 Final", "1.0"));
    try std.testing.expect(!equivalent("Final", "1.0"));
}

test "extractFromTitle: basic shapes" {
    try std.testing.expectEqualStrings("1.0", extractFromTitle("ABitchJKInAnRPG-1.0").?);
    try std.testing.expectEqualStrings("v0.5", extractFromTitle("Some-Game-v0.5").?);
    try std.testing.expectEqualStrings("Final", extractFromTitle("My.Long.Title-Final").?);
    try std.testing.expectEqualStrings("0.9b", extractFromTitle("Foo-0.9b").?);
    try std.testing.expectEqualStrings("v1.2", extractFromTitle("Foo-Episode-3-v1.2").?);
}

test "extractFromTitle: no match returns null" {
    try std.testing.expect(extractFromTitle("JustAName") == null);
    try std.testing.expect(extractFromTitle("Name-Tag-Bar") == null);
    try std.testing.expect(extractFromTitle("") == null);
}

test "extractFromTitle: accepts chapter/part-style trailing segments" {
    // RPDL torrent title where the last segment is the only stable
    // build identifier even though it's not a v1.2 version.
    try std.testing.expectEqualStrings("C1P1", extractFromTitle("ChroniclesOfKartoba-C1P1").?);
    try std.testing.expectEqualStrings("Ep12", extractFromTitle("LightNovelSaga-Ep12").?);
}

test "extractFromTitle: ignores letter-only trailers" {
    // No digits in the trailer = not a version. Falls through to
    // earlier segments (none version-like → null).
    try std.testing.expect(extractFromTitle("Game-FixedAudio") == null);
}

test "extractFromTitle: tokens separated by space or underscore" {
    try std.testing.expectEqualStrings("v0.5", extractFromTitle("Some Game v0.5").?);
    try std.testing.expectEqualStrings("v0.5", extractFromTitle("Some_Game_v0.5").?);
}

test "fromArchivePath: strips dir + extension, finds version" {
    try std.testing.expectEqualStrings("1.0", fromArchivePath("/home/u/Downloads/ABitchJKInAnRPG-1.0-pc.zip").?);
    try std.testing.expectEqualStrings("v0.5", fromArchivePath("Some-Game-v0.5.7z").?);
    try std.testing.expectEqualStrings("0.9b", fromArchivePath("Foo-0.9b.rar").?);
}

test "fromArchivePath: handles Windows backslash paths" {
    try std.testing.expectEqualStrings("0.9b", fromArchivePath("C:\\Users\\w10\\Downloads\\Some-Game-0.9b.zip").?);
}

test "fromArchivePath: strips compound archive extensions" {
    try std.testing.expectEqualStrings("1.2", fromArchivePath("/x/My-Game-1.2.tar.gz").?);
    try std.testing.expectEqualStrings("2.3", fromArchivePath("/x/My-Game-2.3.tar.bz2").?);
    try std.testing.expectEqualStrings("1.0", fromArchivePath("Game-1.0.tgz").?);
}

test "fromArchivePath: no version returns null" {
    try std.testing.expect(fromArchivePath("/home/u/JustAName.zip") == null);
    try std.testing.expect(fromArchivePath("Readme.txt") == null);
}

test "compare: numeric ordering" {
    try std.testing.expectEqual(std.math.Order.lt, compare("0.20", "0.21"));
    try std.testing.expectEqual(std.math.Order.gt, compare("0.21", "0.20"));
    try std.testing.expectEqual(std.math.Order.lt, compare("1.0", "1.0.1"));
    try std.testing.expectEqual(std.math.Order.eq, compare("21.0", "21.0.0"));
    try std.testing.expectEqual(std.math.Order.eq, compare("1.0", "v1.0"));
}

test "compare: suffix letter" {
    try std.testing.expectEqual(std.math.Order.lt, compare("0.9", "0.9a"));
    try std.testing.expectEqual(std.math.Order.lt, compare("0.9a", "0.9b"));
    try std.testing.expectEqual(std.math.Order.gt, compare("0.9b", "0.9a"));
}

test "compare: episode trumps core" {
    try std.testing.expectEqual(std.math.Order.lt, compare("Ep11 v0.20", "Ep12 v0.20"));
    try std.testing.expectEqual(std.math.Order.gt, compare("Ep12 v0.20", "Ep11 v0.20"));
    // Episode 12 with low version beats episode 11 with high version.
    try std.testing.expectEqual(std.math.Order.gt, compare("Ep12 v0.1", "Ep11 v9.9"));
}

test "compare: final flag as tiebreaker only" {
    try std.testing.expectEqual(std.math.Order.gt, compare("Final", "v0.9"));
    try std.testing.expectEqual(std.math.Order.gt, compare("1.0 Final", "1.0"));
    try std.testing.expectEqual(std.math.Order.eq, compare("Final", "Complete"));
    // Numeric core wins over final flag.
    try std.testing.expectEqual(std.math.Order.gt, compare("1.1", "1.0 Final"));
}

test "compare: empty strings sort lowest" {
    try std.testing.expectEqual(std.math.Order.eq, compare("", ""));
    try std.testing.expectEqual(std.math.Order.lt, compare("", "0.1"));
    try std.testing.expectEqual(std.math.Order.gt, compare("0.1", ""));
}

test "canonicalize: episode + core + suffix" {
    var buf: [128]u8 = undefined;
    const c = canonicalize(&buf, "Ep12 v0.20a Linux").?;
    try std.testing.expectEqual(@as(?u32, 12), c.episode);
    try std.testing.expectEqualStrings("0.20", c.core);
    try std.testing.expectEqual(@as(u8, 'a'), c.suffix);
    try std.testing.expect(!c.is_final);
}

test "satisfies: empty constraint matches anything" {
    try std.testing.expect(satisfies("0.20.5", ""));
    try std.testing.expect(satisfies("", ""));
}

test "satisfies: implicit equality" {
    try std.testing.expect(satisfies("0.20.5", "0.20.5"));
    try std.testing.expect(satisfies("0.20", "0.20.0")); // equivalent
    try std.testing.expect(!satisfies("0.20.5", "0.20.6"));
}

test "satisfies: each operator" {
    try std.testing.expect(satisfies("0.20", ">=0.20"));
    try std.testing.expect(satisfies("0.21", ">=0.20"));
    try std.testing.expect(!satisfies("0.19", ">=0.20"));
    try std.testing.expect(satisfies("0.21", ">0.20"));
    try std.testing.expect(!satisfies("0.20", ">0.20"));
    try std.testing.expect(satisfies("0.19", "<0.20"));
    try std.testing.expect(!satisfies("0.20", "<0.20"));
    try std.testing.expect(satisfies("0.20", "<=0.20"));
    try std.testing.expect(satisfies("0.19", "<=0.20"));
    try std.testing.expect(!satisfies("0.21", "<=0.20"));
    try std.testing.expect(satisfies("0.21", "!=0.20"));
    try std.testing.expect(!satisfies("0.20", "!=0.20"));
}

test "satisfies: AND across comma-joined terms" {
    try std.testing.expect(satisfies("0.20.5", ">=0.20.0,<0.21.0"));
    try std.testing.expect(!satisfies("0.21.0", ">=0.20.0,<0.21.0"));
    try std.testing.expect(!satisfies("0.19.9", ">=0.20.0,<0.21.0"));
    try std.testing.expect(satisfies("0.20.5", ">=0.20,<0.21"));
    // Whitespace tolerated.
    try std.testing.expect(satisfies("1.5", " >=1.0 , <2.0 "));
}

test "satisfies: bogus term degrades to implicit-equality" {
    // "??garbage" → op = .eq, target = "??garbage" → fails for any
    // real version. AND-joined: the other half is irrelevant.
    try std.testing.expect(!satisfies("0.20", "??garbage,>=0.20"));
    try std.testing.expect(!satisfies("0.19", "??garbage,>=0.20"));
}

test "fuzz: version parsers survive arbitrary input" {
    try std.testing.fuzz({}, fuzzVersionParsers, .{ .corpus = &.{
        fuzzSeed("My Game [v1.2.3] [Dev]"),
        fuzzSeed("v0.10.1-beta"),
        fuzzSeed("Game_Name-1.0-pc.zip"),
        fuzzSeed("Ch. 5 v0.5.5a"),
        fuzzSeed(""),
    } });
}

/// Harness read-buffer length. fuzzSeed payloads must fit this, or Smith's
/// decode silently rejects the length and replays the seed as empty.
const FUZZ_BUF_LEN = 256;

fn fuzzVersionParsers(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [FUZZ_BUF_LEN]u8 = undefined;
    const n = smith.slice(&buf);
    const s = buf[0..n];

    _ = extractFromTitle(s);
    _ = fromArchivePath(s);

    var canon_buf: [256]u8 = undefined;
    _ = canonicalize(&canon_buf, s);

    // Reflexivity: any string must compare equal to itself. If this fires,
    // compare() has a real ordering bug — investigate, don't weaken it.
    try std.testing.expectEqual(std.math.Order.eq, compare(s, s));

    _ = satisfies(s, ">=1.0");
    _ = satisfies("1.0", s);
    _ = equivalent(s, s);
}

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
