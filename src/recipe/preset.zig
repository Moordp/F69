// Mod-install presets. A preset says "if a staged archive's path list
// looks like X, the install steps are Y." Used to auto-pick the install
// recipe for a mod without making the user think about install steps.
//
// Two-tier loading: built-in presets are embedded into the binary via
// `@embedFile` (see `loadBuiltins`); user presets live alongside
// recipes at `<data_root>/mod-presets/<id>.preset.zon` and override
// built-ins by id.
//
// Anti-RCE: a Preset's `install` is the same `domain.InstallStep`
// tagged union as recipes — extract / copy / move / delete / chmod_x
// only. Detection is pure path-glob matching, no execution.

const std = @import("std");
const dom = @import("domain.zig");
const atomic_io = @import("util_atomic_io");
const errs = @import("errors.zig");

/// Detection spec attached to a preset. The staged archive's flat path
/// list is the input. Every `requires` glob that matches at least one
/// path contributes to the confidence score; `forbids` rejects matches
/// outright (used to keep e.g. an `RPGM MV patch` preset from claiming
/// a Ren'Py archive that happens to have a `www/` subdir for assets).
pub const MatchSpec = struct {
    requires: []const []const u8 = &.{},
    forbids: []const []const u8 = &.{},
    /// Minimum fraction of `requires` that must match (0..1) for the
    /// preset to be considered a hit. Defaults conservative.
    min_confidence: f32 = 0.5,
};

pub const Preset = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8 = "",
    /// Restrict consideration to a specific engine. `null` = match
    /// against any game regardless of engine.
    engine_hint: ?dom.Engine = null,
    match: MatchSpec,
    /// Install steps inlined into the mod recipe when this preset is
    /// chosen. Same shape as `GameRecipe.install` / `ModRecipe.install`.
    install: []const dom.InstallStep,
    /// Tiebreaker when two presets both match at the same confidence.
    /// Higher wins. Built-in presets weight 1.0; users can author
    /// higher-weight overrides for their own narrower patterns.
    weight: f32 = 1.0,
};

/// One scored preset hit. Returned by `detectAll` / `detectBest`.
pub const MatchedPreset = struct {
    preset: *const Preset,
    /// Fraction of `requires` patterns that matched [0..1].
    confidence: f32,
    /// `confidence * preset.weight` — sort key.
    score: f32,
};

/// Score a single preset against a flat path list. Returns null when
/// the preset doesn't apply (engine mismatch, confidence under floor,
/// or a `forbids` pattern hit).
pub fn scorePreset(preset: *const Preset, paths: []const []const u8, engine: ?dom.Engine) ?MatchedPreset {
    if (preset.engine_hint) |eh| {
        const e = engine orelse return null;
        if (eh != e) return null;
    }

    // Confidence: hit-count divided by required-pattern count.
    // Edge case: zero `requires` → preset matches everything that
    // doesn't trip a `forbids`, with confidence 1.0.
    const conf: f32 = if (preset.match.requires.len == 0) blk: {
        break :blk 1.0;
    } else blk: {
        var hits: usize = 0;
        for (preset.match.requires) |req| {
            if (anyPathMatches(req, paths)) hits += 1;
        }
        const f: f32 = @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(preset.match.requires.len));
        if (f < preset.match.min_confidence) return null;
        break :blk f;
    };

    for (preset.match.forbids) |bad| {
        if (anyPathMatches(bad, paths)) return null;
    }

    return .{
        .preset = preset,
        .confidence = conf,
        .score = conf * preset.weight,
    };
}

/// Score every preset; return matches sorted by score desc. Caller
/// owns the returned slice and must free with `alloc`.
pub fn detectAll(
    alloc: std.mem.Allocator,
    presets: []const Preset,
    paths: []const []const u8,
    engine: ?dom.Engine,
) ![]MatchedPreset {
    var out: std.ArrayList(MatchedPreset) = .empty;
    errdefer out.deinit(alloc);
    for (presets) |*p| {
        if (scorePreset(p, paths, engine)) |m| {
            try out.append(alloc, m);
        }
    }
    std.mem.sort(MatchedPreset, out.items, {}, struct {
        fn lessThan(_: void, a: MatchedPreset, b: MatchedPreset) bool {
            // Higher score first; deterministic tiebreak by id.
            if (a.score != b.score) return a.score > b.score;
            return std.mem.order(u8, a.preset.id, b.preset.id) == .lt;
        }
    }.lessThan);
    return out.toOwnedSlice(alloc);
}

/// Best single match across all presets. Zero-alloc convenience around
/// the same scoring as `detectAll`.
pub fn detectBest(presets: []const Preset, paths: []const []const u8, engine: ?dom.Engine) ?MatchedPreset {
    var best: ?MatchedPreset = null;
    for (presets) |*p| {
        if (scorePreset(p, paths, engine)) |m| {
            if (best) |b| {
                if (m.score > b.score) best = m;
            } else {
                best = m;
            }
        }
    }
    return best;
}

// ============================================================
//  Glob matcher
// ============================================================

/// Returns true when any path in `paths` matches `pattern`.
pub fn anyPathMatches(pattern: []const u8, paths: []const []const u8) bool {
    for (paths) |p| {
        if (globMatch(pattern, p)) return true;
    }
    return false;
}

/// Glob match a single path against a pattern. Supports:
///   `*`  — any chars except `/` (within one path segment)
///   `**` — any chars including `/` (zero or more segments)
///   anything else is matched literally
///
/// Paths are expected to use `/` as separator. Leading slashes are
/// stripped from both inputs for symmetry.
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    const pat = stripLeadingSlash(pattern);
    const p = stripLeadingSlash(path);
    return matchSegments(pat, p);
}

fn stripLeadingSlash(s: []const u8) []const u8 {
    if (s.len > 0 and s[0] == '/') return s[1..];
    return s;
}

/// Walk pattern and path segment-by-segment. `**` segments consume
/// zero-or-more path segments via backtracking — small inputs so the
/// recursion depth stays bounded.
fn matchSegments(pat: []const u8, path: []const u8) bool {
    if (pat.len == 0) return path.len == 0;

    const pat_seg_end = std.mem.indexOfScalar(u8, pat, '/') orelse pat.len;
    const pat_seg = pat[0..pat_seg_end];
    const pat_rest = if (pat_seg_end < pat.len) pat[pat_seg_end + 1 ..] else pat[pat_seg_end..pat_seg_end];

    // `**` — match zero or more path segments, then try `pat_rest`
    // against the remainder. Greedy doesn't matter for correctness
    // here; we try shortest first to keep stack shallow.
    if (std.mem.eql(u8, pat_seg, "**")) {
        // `**/foo` should match `foo` too — try with zero segments first.
        if (matchSegments(pat_rest, path)) return true;
        // Then consume one segment at a time.
        var rest = path;
        while (rest.len > 0) {
            const next_sep = std.mem.indexOfScalar(u8, rest, '/') orelse return matchSegments(pat_rest, "");
            rest = rest[next_sep + 1 ..];
            if (matchSegments(pat_rest, rest)) return true;
        }
        return false;
    }

    // Non-`**` segment: match one path segment only.
    if (path.len == 0) return false;
    const path_seg_end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    const path_seg = path[0..path_seg_end];
    const path_rest = if (path_seg_end < path.len) path[path_seg_end + 1 ..] else path[path_seg_end..path_seg_end];

    if (!matchSingleSegment(pat_seg, path_seg)) return false;
    return matchSegments(pat_rest, path_rest);
}

/// Glob a single segment (no `/` inside either input). Supports `*`
/// only — `**` is handled at the segment-list level.
fn matchSingleSegment(pat: []const u8, seg: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: ?usize = null;
    var star_si: usize = 0;
    while (si < seg.len) {
        if (pi < pat.len and pat[pi] == '*') {
            // Track star position for backtrack.
            star_pi = pi;
            star_si = si;
            pi += 1;
        } else if (pi < pat.len and pat[pi] == seg[si]) {
            pi += 1;
            si += 1;
        } else if (star_pi) |sp| {
            // Backtrack: extend star match by one byte.
            pi = sp + 1;
            star_si += 1;
            si = star_si;
        } else {
            return false;
        }
    }
    // Eat trailing `*`s in pattern.
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

// ============================================================
//  Parse + load helpers
// ============================================================

/// Parse a single preset from a sentinel-terminated ZON slice. Caller
/// owns the resulting arena.
pub const ParsedPreset = struct {
    preset: Preset,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParsedPreset) void {
        self.arena.deinit();
    }
};

pub fn parseFromBytes(parent_alloc: std.mem.Allocator, bytes_z: [:0]const u8) errs.Error!ParsedPreset {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    var diag: std.zon.parse.Diagnostics = undefined;
    const preset = std.zon.parse.fromSlice(Preset, .{ .gpa = arena.allocator(), .arena = arena.allocator(), .source = bytes_z, .diagnostics = &diag, .ignore_unknown_fields = true }) catch |e| return switch (e) {
        error.OutOfMemory => errs.Error.OutOfMemory,
        error.ParseZon => errs.Error.ZonParseError,
    };
    return .{ .preset = preset, .arena = arena };
}

/// Built-in presets, parsed at comptime via `@import("foo.zon")`. Zig
/// 0.16's `@import` accepts ZON and returns the parsed structure as a
/// comptime-known `const`, so every entry below is a `Preset` value
/// baked into rodata — no runtime parse, no arena allocation. Adding a
/// new built-in = drop the file under `src/recipe/presets/` and add an
/// `@import` line. A malformed ZON breaks the build rather than
/// failing at startup.
const BUILTIN_LIST: []const Preset = &.{
    @import("presets/renpy-overlay.preset.zon"),
    @import("presets/rpgm-mv-patch.preset.zon"),
    @import("presets/rpgm-mz-patch.preset.zon"),
    @import("presets/unity-bepinex.preset.zon"),
    @import("presets/generic-overlay.preset.zon"),
};

/// Owned bundle of every built-in preset. Single arena holds all of
/// them so the caller frees with one `deinit`.
pub const BuiltinSet = struct {
    presets: []Preset,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *BuiltinSet) void {
        self.arena.deinit();
    }
};

/// Sentinel-name suffix for user preset files. Anything in the user
/// presets dir that doesn't end with this is ignored (lets users keep
/// scratch / backup files alongside without confusing the loader).
pub const PRESET_FILE_SUFFIX = ".preset.zon";

/// Cap on user-dir preset count. Realistic deployments will have a
/// handful; the cap prevents a misconfigured dir from blowing parse
/// budget at startup.
pub const USER_PRESET_CAP: usize = 256;

/// Copy the built-in list into an arena-backed slice. Built-in `Preset`
/// values live in rodata (`BUILTIN_LIST` is `@import("foo.zon")`-built),
/// so the only allocation here is the slice header — the strings and
/// nested arrays inside each Preset already outlive any allocator.
/// `BuiltinSet.arena.deinit()` still frees the slice, keeping the
/// caller API unchanged.
pub fn loadBuiltins(parent_alloc: std.mem.Allocator) errs.Error!BuiltinSet {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const aalloc = arena.allocator();

    const presets = aalloc.alloc(Preset, BUILTIN_LIST.len) catch return errs.Error.OutOfMemory;
    for (BUILTIN_LIST, 0..) |*p, i| presets[i] = p.*;

    return .{
        .presets = presets,
        .arena = arena,
    };
}

/// Owned merged preset set — built-ins plus any user files. The
/// merging is keyed by `id`: a user preset with the same id as a
/// built-in REPLACES the built-in (lets users fix a bad bundled
/// detection without recompiling). `from_user` flags which entries
/// originated from disk vs the binary.
pub const MergedSet = struct {
    presets: []Preset,
    from_user: []bool,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *MergedSet) void {
        self.arena.deinit();
    }
};

/// Load built-ins + scan `user_dir` for `*.preset.zon`, merge by id
/// (user wins). Missing or empty `user_dir` is fine — returns the
/// built-in set alone. Parse failures on individual user files log
/// and skip that file; the rest still load (partial bundle is
/// acceptable for user dirs because nothing else in the app encodes
/// dependencies on specific user-preset ids).
pub fn loadMerged(
    parent_alloc: std.mem.Allocator,
    io: std.Io,
    user_dir: []const u8,
) errs.Error!MergedSet {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const aalloc = arena.allocator();

    // Built-ins first — same logic as `loadBuiltins` but everything
    // lives in the merged arena so we hand back a single deinit-able
    // bundle. The built-ins are rodata-backed (`@import("foo.zon")`),
    // so appending `p.*` is a struct copy with no allocation for the
    // strings/slices it points at.
    var by_id: std.StringHashMap(usize) = .init(aalloc);
    var combined: std.ArrayList(Preset) = .empty;
    var from_user_list: std.ArrayList(bool) = .empty;

    for (BUILTIN_LIST) |*p| {
        try combined.append(aalloc, p.*);
        try from_user_list.append(aalloc, false);
        by_id.put(p.id, combined.items.len - 1) catch return errs.Error.OutOfMemory;
    }

    // User dir scan — best-effort. Missing dir → skip entirely.
    var dir = std.Io.Dir.cwd().openDir(io, user_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => {
            return finalizeMerged(parent_alloc, &arena, &combined, &from_user_list, aalloc);
        },
        else => return errs.Error.RecipeNotFound,
    };
    defer dir.close(io);

    var it = dir.iterate();
    var loaded: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (loaded >= USER_PRESET_CAP) break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, PRESET_FILE_SUFFIX)) continue;

        const path = std.fmt.allocPrint(aalloc, "{s}/{s}", .{ user_dir, entry.name }) catch return errs.Error.OutOfMemory;
        const bytes_z = std.Io.Dir.cwd().readFileAllocOptions(
            io,
            path,
            aalloc,
            .limited(64 * 1024),
            .of(u8),
            0,
        ) catch |e| {
            std.log.scoped(.preset).warn("read failed for {s}: {s}", .{ entry.name, @errorName(e) });
            continue;
        };

        var diag: std.zon.parse.Diagnostics = undefined;
        const parsed = std.zon.parse.fromSlice(Preset, .{ .gpa = aalloc, .arena = aalloc, .source = bytes_z, .diagnostics = &diag, .ignore_unknown_fields = true }) catch |e| {
            std.log.scoped(.preset).warn("parse failed for {s}: {s}", .{ entry.name, @errorName(e) });
            continue;
        };

        // Replace built-in or append.
        if (by_id.get(parsed.id)) |idx| {
            combined.items[idx] = parsed;
            from_user_list.items[idx] = true;
        } else {
            try combined.append(aalloc, parsed);
            try from_user_list.append(aalloc, true);
            by_id.put(parsed.id, combined.items.len - 1) catch return errs.Error.OutOfMemory;
        }
        loaded += 1;
    }

    return finalizeMerged(parent_alloc, &arena, &combined, &from_user_list, aalloc);
}

fn finalizeMerged(
    parent_alloc: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    combined: *std.ArrayList(Preset),
    from_user_list: *std.ArrayList(bool),
    aalloc: std.mem.Allocator,
) errs.Error!MergedSet {
    _ = parent_alloc;
    const presets = combined.toOwnedSlice(aalloc) catch return errs.Error.OutOfMemory;
    const from_user = from_user_list.toOwnedSlice(aalloc) catch return errs.Error.OutOfMemory;
    return .{
        .presets = presets,
        .from_user = from_user,
        .arena = arena.*,
    };
}

/// Stringify + atomically write a user preset to
/// `<user_dir>/<id>.preset.zon`. Used by "Save as preset…".
pub fn saveUserPreset(
    parent_alloc: std.mem.Allocator,
    io: std.Io,
    user_dir: []const u8,
    preset: *const Preset,
) errs.Error!void {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(parent_alloc, 1024) catch return errs.Error.OutOfMemory;
    defer aw.deinit();
    std.zon.stringify.serialize(preset.*, .{}, &aw.writer) catch return errs.Error.SaveFailed;

    const path = std.fmt.allocPrint(parent_alloc, "{s}/{s}{s}", .{ user_dir, preset.id, PRESET_FILE_SUFFIX }) catch return errs.Error.OutOfMemory;
    defer parent_alloc.free(path);
    atomic_io.writeFileAtomic(io, path, aw.writer.buffered()) catch return errs.Error.SaveFailed;
}

// ============================================================
//  tests
// ============================================================

test "globMatch: literal exact" {
    try std.testing.expect(globMatch("foo", "foo"));
    try std.testing.expect(!globMatch("foo", "bar"));
    try std.testing.expect(!globMatch("foo", "foobar"));
}

test "globMatch: star matches within segment" {
    try std.testing.expect(globMatch("game/*.rpy", "game/script.rpy"));
    try std.testing.expect(!globMatch("game/*.rpy", "game/sub/script.rpy"));
    try std.testing.expect(globMatch("*.json", "data.json"));
    try std.testing.expect(!globMatch("*.json", "sub/data.json"));
}

test "globMatch: double-star matches across segments" {
    try std.testing.expect(globMatch("game/**/*.rpy", "game/script.rpy"));
    try std.testing.expect(globMatch("game/**/*.rpy", "game/sub/script.rpy"));
    try std.testing.expect(globMatch("game/**/*.rpy", "game/a/b/c.rpy"));
    try std.testing.expect(!globMatch("game/**/*.rpy", "other/script.rpy"));
}

test "globMatch: leading slash agnostic" {
    try std.testing.expect(globMatch("/game/foo", "game/foo"));
    try std.testing.expect(globMatch("game/foo", "/game/foo"));
}

test "globMatch: trailing star matches anything after" {
    try std.testing.expect(globMatch("game/*", "game/foo"));
    try std.testing.expect(globMatch("game/*", "game/foo.bar"));
    try std.testing.expect(!globMatch("game/*", "other/foo"));
}

test "scorePreset: requires all → confidence 1.0" {
    const preset: Preset = .{
        .id = "test",
        .name = "T",
        .match = .{
            .requires = &.{ "game/*.rpy", "game/*.rpyc" },
            .min_confidence = 0.5,
        },
        .install = &.{},
    };
    const paths = [_][]const u8{ "game/foo.rpy", "game/bar.rpyc" };
    const m = scorePreset(&preset, &paths, null).?;
    try std.testing.expectEqual(@as(f32, 1.0), m.confidence);
    try std.testing.expectEqual(@as(f32, 1.0), m.score);
}

test "scorePreset: partial → fraction" {
    const preset: Preset = .{
        .id = "test",
        .name = "T",
        .match = .{
            .requires = &.{ "game/*.rpy", "game/*.rpyc" },
            .min_confidence = 0.4,
        },
        .install = &.{},
    };
    const paths = [_][]const u8{"game/foo.rpy"};
    const m = scorePreset(&preset, &paths, null).?;
    try std.testing.expectEqual(@as(f32, 0.5), m.confidence);
}

test "scorePreset: below floor → null" {
    const preset: Preset = .{
        .id = "test",
        .name = "T",
        .match = .{
            .requires = &.{ "game/*.rpy", "game/*.rpyc", "game/*.rpyb" },
            .min_confidence = 0.8,
        },
        .install = &.{},
    };
    const paths = [_][]const u8{"game/foo.rpy"};
    try std.testing.expect(scorePreset(&preset, &paths, null) == null);
}

test "scorePreset: forbids rejects" {
    const preset: Preset = .{
        .id = "test",
        .name = "T",
        .match = .{
            .requires = &.{"game/*.rpy"},
            .forbids = &.{"www/**/*.json"},
            .min_confidence = 0.5,
        },
        .install = &.{},
    };
    const paths = [_][]const u8{ "game/foo.rpy", "www/data/x.json" };
    try std.testing.expect(scorePreset(&preset, &paths, null) == null);
}

test "scorePreset: engine_hint filters" {
    const preset: Preset = .{
        .id = "test",
        .name = "T",
        .engine_hint = .renpy,
        .match = .{ .requires = &.{}, .min_confidence = 0.0 },
        .install = &.{},
    };
    const paths = [_][]const u8{"anything"};
    try std.testing.expect(scorePreset(&preset, &paths, .renpy) != null);
    try std.testing.expect(scorePreset(&preset, &paths, .unity) == null);
    try std.testing.expect(scorePreset(&preset, &paths, null) == null);
}

test "detectBest: highest score wins" {
    const presets = [_]Preset{
        .{
            .id = "low",
            .name = "L",
            .match = .{ .requires = &.{ "a", "b" }, .min_confidence = 0.4 },
            .install = &.{},
            .weight = 1.0,
        },
        .{
            .id = "high",
            .name = "H",
            .match = .{ .requires = &.{"a"}, .min_confidence = 0.5 },
            .install = &.{},
            .weight = 1.5,
        },
    };
    const paths = [_][]const u8{"a"};
    const best = detectBest(&presets, &paths, null).?;
    try std.testing.expectEqualStrings("high", best.preset.id);
}

test "detectAll: sorted by score desc, stable on id" {
    const presets = [_]Preset{
        .{
            .id = "b",
            .name = "B",
            .match = .{ .requires = &.{"x"}, .min_confidence = 0.5 },
            .install = &.{},
        },
        .{
            .id = "a",
            .name = "A",
            .match = .{ .requires = &.{"x"}, .min_confidence = 0.5 },
            .install = &.{},
        },
    };
    const paths = [_][]const u8{"x"};
    const all = try detectAll(std.testing.allocator, &presets, &paths, null);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    // Same score → id ascending breaks the tie.
    try std.testing.expectEqualStrings("a", all[0].preset.id);
    try std.testing.expectEqualStrings("b", all[1].preset.id);
}

test "loadBuiltins: all five parse" {
    var bundle = try loadBuiltins(std.testing.allocator);
    defer bundle.deinit();
    try std.testing.expectEqual(@as(usize, 5), bundle.presets.len);
    // IDs are stable; the rest of the UI binds to them.
    var saw_renpy = false;
    var saw_generic = false;
    for (bundle.presets) |p| {
        if (std.mem.eql(u8, p.id, "renpy-overlay")) saw_renpy = true;
        if (std.mem.eql(u8, p.id, "generic-overlay")) saw_generic = true;
    }
    try std.testing.expect(saw_renpy);
    try std.testing.expect(saw_generic);
}
