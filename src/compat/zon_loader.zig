// Parse a compat recipe via `std.zon.parse`. No custom lexer/AST.
// Compat recipes are deserialized straight into `dom.Recipe`.
//
// Bundled recipes (those shipped with the app) are loaded via
// `@embedFile` from the comptime list in `repository.zig`; this file
// handles only the filesystem path. Both go through `parseFromBytes`.

const std = @import("std");
const dom = @import("domain.zig");
const errs = @import("errors.zig");

/// Cap on a single recipe's source size. Recipes are small; this is
/// just a safety net against malformed files.
const RECIPE_MAX_BYTES: usize = 64 * 1024;

pub const Parsed = struct {
    recipe: dom.Recipe,
    arena: std.heap.ArenaAllocator,
    /// Raw bytes used for hashing (recipe_sha256 in FixRecord). Owned
    /// by `arena` — do not free separately.
    source_bytes: []const u8,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

/// Load a recipe from disk. Returned Parsed owns its arena.
pub fn loadPath(io: std.Io, parent_alloc: std.mem.Allocator, path: []const u8) errs.Error!Parsed {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const bytes_z = readFileSentinel(io, arena.allocator(), path) catch |e| return mapReadErr(e);
    return parseFromBytesArena(&arena, bytes_z);
}

/// Parse from already-loaded bytes. Used by repository.zig for
/// `@embedFile`d bundled recipes.
pub fn parseFromBytes(parent_alloc: std.mem.Allocator, bytes_z: [:0]const u8) errs.Error!Parsed {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    // Dupe into the arena so source_bytes survives independently of
    // the caller's buffer.
    const owned = arena.allocator().dupeSentinel(u8, bytes_z, 0) catch return errs.Error.OutOfMemory;
    return parseFromBytesArena(&arena, owned);
}

fn parseFromBytesArena(arena: *std.heap.ArenaAllocator, bytes_z: [:0]const u8) errs.Error!Parsed {
    var diag: std.zon.parse.Diagnostics = undefined;
    const recipe = std.zon.parse.fromSlice(dom.Recipe, .{ .gpa = arena.allocator(), .arena = arena.allocator(), .source = bytes_z, .diagnostics = &diag, .ignore_unknown_fields = true }) catch |e| return switch (e) {
        error.OutOfMemory => errs.Error.OutOfMemory,
        error.ParseZon => errs.Error.ZonParseError,
    };
    return .{
        .recipe = recipe,
        .arena = arena.*,
        .source_bytes = bytes_z[0..bytes_z.len],
    };
}

/// SHA-256 of the recipe source bytes, lowercase hex (64 chars).
/// Caller frees with `alloc`.
pub fn hashSource(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(source);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = try alloc.alloc(u8, 64);
    const tbl = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[2 * i] = tbl[b >> 4];
        hex[2 * i + 1] = tbl[b & 0xf];
    }
    return hex;
}

fn readFileSentinel(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        alloc,
        .limited(RECIPE_MAX_BYTES),
        .of(u8),
        0,
    );
}

fn mapReadErr(e: anyerror) errs.Error {
    return switch (e) {
        error.OutOfMemory => errs.Error.OutOfMemory,
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.IsDir => errs.Error.FileNotFound,
        else => errs.Error.IoError,
    };
}

// -----------------------------------------------------------------
//  tests
// -----------------------------------------------------------------

test "parseFromBytes minimal recipe" {
    const src: [:0]const u8 =
        \\.{
        \\    .id = "linux.example.basic",
        \\    .title = "Example",
        \\    .explain = "An example recipe.",
        \\    .detect = .{ .file_exists = "marker" },
        \\}
    ;
    var p = try parseFromBytes(std.testing.allocator, src);
    defer p.deinit();
    try std.testing.expectEqualStrings("linux.example.basic", p.recipe.id);
}

test "parseFromBytes recipe with apply actions" {
    const src: [:0]const u8 =
        \\.{
        \\    .id = "linux.example.env",
        \\    .title = "Env",
        \\    .explain = "Set LD_LIBRARY_PATH.",
        \\    .detect = .{ .file_exists = "renpy/bootstrap.py" },
        \\    .apply = .{
        \\        .{ .env_prepend = .{
        \\            .name = "LD_LIBRARY_PATH",
        \\            .from_resource = "renpy-fhs-libs",
        \\            .relpath = "lib",
        \\        } },
        \\    },
        \\    .required_resources = .{ "renpy-fhs-libs" },
        \\}
    ;
    var p = try parseFromBytes(std.testing.allocator, src);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.recipe.apply.len);
    try std.testing.expectEqualStrings("LD_LIBRARY_PATH", p.recipe.apply[0].env_prepend.name);
    try std.testing.expectEqualStrings("renpy-fhs-libs", p.recipe.required_resources[0]);
}
