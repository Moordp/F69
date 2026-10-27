// Convert-strategy presets. Each preset binds an engine (or any) to a
// concrete `ConvertSpec`, with metadata so users can see what each
// strategy does. Built-in presets cover the common cases; users can
// drop additional `*.preset.zon` files into `<data_root>/convert-presets/`
// to extend the catalog.
//
// Why presets and not just hardcoded if-else on engine:
//   - Two strategies for the same engine (codecs vs no-codecs RPGM).
//   - Future engines (Unity / GameMaker) can be added by shipping a
//     new preset alongside the handler module — no UI churn.
//   - Sharable: a NixOS-specific preset variant could be authored and
//     dropped in `<data_root>/convert-presets/` without modifying the
//     binary.

const std = @import("std");
const dom = @import("domain.zig");
const errs = @import("errors.zig");
const atomic_io = @import("util_atomic_io");

pub const Preset = struct {
    /// Stable identifier — `nwjs-codecs`, `renpy-standard`, etc.
    id: []const u8,
    /// User-facing label.
    name: []const u8,
    description: []const u8 = "",
    /// Engine this preset targets. `null` = generic / no-op handler
    /// (e.g. `.none` for "game is already Linux-native").
    engine_hint: ?dom.Engine = null,
    /// The actual convert spec the handler reads. Wraps the same
    /// `ConvertSpec` recipe-driven convert used to consume.
    spec: dom.ConvertSpec,
    /// Tiebreaker when two presets match the same engine. Higher
    /// wins. Built-ins weight 1.0; users can override with 1.5 to
    /// take priority on their machines.
    weight: f32 = 1.0,
};

pub const Matched = struct {
    preset: *const Preset,
    /// True when the preset came from a `<data_root>/convert-presets/`
    /// file (i.e. user-authored), false for built-ins. Settings UI
    /// uses this to gate Delete buttons.
    from_user: bool = false,
};

// ============================================================
//  Built-in presets — parsed at comptime via `@import("foo.zon")`
// ============================================================
//
// Zig 0.16's `@import` accepts ZON files and returns the parsed
// structure as a comptime-known constant baked into rodata. Replacing
// the previous `@embedFile + runtime fromSliceAlloc` path with
// `@import` eliminates four ZON parses + four arena allocations from
// every startup; the built-in `Preset` values are now plain `const`
// data the loader can hand back without any runtime work.

const BUILTIN_LIST: []const Preset = &.{
    @import("presets/renpy-standard.preset.zon"),
    @import("presets/rpgm-mv-standard.preset.zon"),
    @import("presets/rpgm-mv-no-codecs.preset.zon"),
    @import("presets/rpgm-mz-standard.preset.zon"),
};

pub const PRESET_FILE_SUFFIX = ".preset.zon";

/// Owned merged set: built-ins (always) plus any user-authored ZON in
/// `<data_root>/convert-presets/`. Same merging shape as the mod-side
/// preset bundle — user files override built-ins of the same id.
pub const MergedSet = struct {
    presets: []Preset,
    from_user: []bool,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *MergedSet) void {
        self.arena.deinit();
    }
};

pub fn loadMerged(
    parent_alloc: std.mem.Allocator,
    io: std.Io,
    user_dir: []const u8,
) errs.Error!MergedSet {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const aalloc = arena.allocator();

    var by_id: std.StringHashMap(usize) = .init(aalloc);
    var combined: std.ArrayList(Preset) = .empty;
    var from_user_list: std.ArrayList(bool) = .empty;

    // Built-ins are `const Preset` values in rodata (see BUILTIN_LIST).
    // Append a copy to the ArrayList; the parser-arena that previously
    // owned each Preset's strings is gone — strings now live in the
    // binary's read-only segment and outlive any runtime allocator.
    for (BUILTIN_LIST) |*p| {
        try combined.append(aalloc, p.*);
        try from_user_list.append(aalloc, false);
        by_id.put(p.id, combined.items.len - 1) catch return errs.Error.OutOfMemory;
    }

    // User dir scan — best-effort. Missing dir is fine.
    var dir = std.Io.Dir.cwd().openDir(io, user_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return finalize(&arena, &combined, &from_user_list, aalloc),
        else => return finalize(&arena, &combined, &from_user_list, aalloc),
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
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
            std.log.scoped(.convert_preset).warn("read failed for {s}: {s}", .{ entry.name, @errorName(e) });
            continue;
        };
        var diag: std.zon.parse.Diagnostics = undefined;
        const parsed = std.zon.parse.fromSlice(Preset, .{ .gpa = aalloc, .arena = aalloc, .source = bytes_z, .diagnostics = &diag, .ignore_unknown_fields = true }) catch |e| {
            std.log.scoped(.convert_preset).warn("parse failed for {s}: {s}", .{ entry.name, @errorName(e) });
            continue;
        };

        if (by_id.get(parsed.id)) |idx| {
            combined.items[idx] = parsed;
            from_user_list.items[idx] = true;
        } else {
            try combined.append(aalloc, parsed);
            try from_user_list.append(aalloc, true);
            by_id.put(parsed.id, combined.items.len - 1) catch return errs.Error.OutOfMemory;
        }
    }

    return finalize(&arena, &combined, &from_user_list, aalloc);
}

fn finalize(
    arena: *std.heap.ArenaAllocator,
    combined: *std.ArrayList(Preset),
    from_user_list: *std.ArrayList(bool),
    aalloc: std.mem.Allocator,
) errs.Error!MergedSet {
    const presets = combined.toOwnedSlice(aalloc) catch return errs.Error.OutOfMemory;
    const from_user = from_user_list.toOwnedSlice(aalloc) catch return errs.Error.OutOfMemory;
    return .{
        .presets = presets,
        .from_user = from_user,
        .arena = arena.*,
    };
}

/// Pick the highest-weight preset whose `engine_hint` matches
/// `engine`. Returns null when nothing applies (typically only when
/// the merged set is empty, since the bundled `native` preset is the
/// catch-all).
pub fn pickForEngine(presets: []const Preset, engine: dom.Engine) ?Matched {
    var best: ?*const Preset = null;
    var best_weight: f32 = -1.0;
    for (presets) |*p| {
        const hint = p.engine_hint orelse continue;
        if (hint != engine) continue;
        if (p.weight > best_weight) {
            best = p;
            best_weight = p.weight;
        }
    }
    if (best) |b| return .{ .preset = b };
    return null;
}

/// Write a user preset to `<user_dir>/<id>.preset.zon`. Atomic via
/// tmp-and-rename. Used by future "Save as preset" / hand-authored
/// editor flows.
pub fn save(
    parent_alloc: std.mem.Allocator,
    io: std.Io,
    user_dir: []const u8,
    preset: *const Preset,
) errs.Error!void {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(parent_alloc, 1024) catch return errs.Error.OutOfMemory;
    defer aw.deinit();
    std.zon.stringify.serialize(preset.*, .{}, &aw.writer) catch return errs.Error.WriteFailed;

    const path = std.fmt.allocPrint(parent_alloc, "{s}/{s}{s}", .{ user_dir, preset.id, PRESET_FILE_SUFFIX }) catch return errs.Error.OutOfMemory;
    defer parent_alloc.free(path);
    atomic_io.writeFileAtomic(io, path, aw.writer.buffered()) catch return errs.Error.WriteFailed;
}

// ============================================================
//  tests
// ============================================================

test "embedded built-ins are well-formed" {
    // Comptime `@import("foo.zon")` already proved every shipped ZON
    // parses — if any file were malformed the build wouldn't compile.
    // The runtime check left here is a smoke test: every preset has a
    // non-empty id (the rest of the app keys off it).
    try std.testing.expect(BUILTIN_LIST.len > 0);
    for (BUILTIN_LIST) |p| {
        try std.testing.expect(p.id.len > 0);
        try std.testing.expect(p.name.len > 0);
    }
}

test "pickForEngine: matches by hint" {
    const presets = [_]Preset{
        .{ .id = "a", .name = "A", .engine_hint = .renpy, .spec = .{ .renpy = .{} }, .weight = 1.0 },
        .{ .id = "b", .name = "B", .engine_hint = .rpgm_mv, .spec = .{ .rpgm = .{} }, .weight = 1.0 },
    };
    const m = pickForEngine(&presets, .renpy).?;
    try std.testing.expectEqualStrings("a", m.preset.id);
    try std.testing.expect(pickForEngine(&presets, .unity) == null);
}

test "pickForEngine: highest weight wins" {
    const presets = [_]Preset{
        .{ .id = "low", .name = "L", .engine_hint = .rpgm_mv, .spec = .{ .rpgm = .{ .ffmpeg_codecs = true } }, .weight = 1.0 },
        .{ .id = "high", .name = "H", .engine_hint = .rpgm_mv, .spec = .{ .rpgm = .{ .ffmpeg_codecs = false } }, .weight = 1.5 },
    };
    const m = pickForEngine(&presets, .rpgm_mv).?;
    try std.testing.expectEqualStrings("high", m.preset.id);
}
