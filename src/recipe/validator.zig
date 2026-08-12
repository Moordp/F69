// Schema-level validation. Anti-RCE is structural (no `run`/`exec`
// variant in InstallStep), but we also want runtime sanity checks:
//   - hash hex length 64 + lowercase hex chars
//   - non-empty required fields
//   - version constraint strings parse
//   - install step paths don't escape with `..`
// Cross-recipe checks (resolves `for_game`, etc.) happen in resolver/.

const std = @import("std");
const errs = @import("errors.zig");
const dom = @import("domain.zig");

pub fn validate(recipe: *const dom.Recipe) errs.Error!void {
    return switch (recipe.*) {
        .game => |*g| validateGame(g),
        .mod => |*m| validateMod(m),
    };
}

pub fn validateGame(g: *const dom.GameRecipe) errs.Error!void {
    if (g.id.len == 0 or g.name.len == 0 or g.version.len == 0) {
        return errs.Error.MissingRequiredField;
    }
    for (g.sources) |src| try checkSource(src);
    for (g.install) |step| try checkInstallStep(step);
}

pub fn validateMod(m: *const dom.ModRecipe) errs.Error!void {
    if (m.id.len == 0 or m.name.len == 0 or m.for_game.len == 0) {
        return errs.Error.MissingRequiredField;
    }
    for (m.sources) |src| try checkSource(src);
    for (m.install) |step| try checkInstallStep(step);
}

fn checkSource(src: dom.Source) errs.Error!void {
    switch (src) {
        .rpdl => |x| try checkSha256(x.sha256),
        .ddl => |x| try checkSha256(x.sha256),
        .mirror => |x| if (x.sha256) |h| try checkSha256(h),
    }
}

fn checkSha256(hex: []const u8) errs.Error!void {
    if (hex.len != 64) return errs.Error.InvalidHash;
    for (hex) |c| {
        if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return errs.Error.InvalidHash;
    }
}

fn checkInstallStep(step: dom.InstallStep) errs.Error!void {
    var visitor = SafePathVisitor{};
    try dom.walkSteps(&[_]dom.InstallStep{step}, &visitor);
}

/// `walkSteps` visitor that runs `checkSafePath` on every path-shaped
/// field of every variant. Compile-time exhaustive: if a new InstallStep
/// variant lands, the visitor must grow a matching method or the
/// caller's `walkSteps` invocation fails to compile.
const SafePathVisitor = struct {
    pub fn onExtract(_: *SafePathVisitor, x: anytype) errs.Error!void {
        try checkSafePath(x.to);
    }
    pub fn onExtractInner(_: *SafePathVisitor, x: anytype) errs.Error!void {
        try checkSafePath(x.archive);
        try checkSafePath(x.to);
    }
    pub fn onCopy(_: *SafePathVisitor, x: anytype) errs.Error!void {
        try checkSafePath(x.src);
        try checkSafePath(x.dest);
    }
    pub fn onMove(_: *SafePathVisitor, x: anytype) errs.Error!void {
        try checkSafePath(x.src);
        try checkSafePath(x.dest);
    }
    pub fn onDelete(_: *SafePathVisitor, x: anytype) errs.Error!void {
        try checkSafePath(x.path);
    }
    pub fn onChmodX(_: *SafePathVisitor, x: anytype) errs.Error!void {
        for (x.paths) |p| try checkSafePath(p);
    }
};

/// Reject `..` segments and absolute paths in recipe-driven file ops —
/// install steps must stay within the install dir.
pub fn checkSafePath(p: []const u8) errs.Error!void {
    if (p.len == 0) return errs.Error.MissingRequiredField;
    // BOTH separators. This used to split on '/' only, so `..\\windows`
    // sailed straight through — a recipe could escape the install directory on
    // Windows, where the backslash IS the separator. Recipes are downloadable
    // content, so this is the boundary that keeps a malicious one from writing
    // outside the game folder.
    if (p[0] == '/' or p[0] == '\\') return errs.Error.UnsafePath;
    // Drive-absolute (`C:\\...`, `C:/...`) is absolute too.
    if (p.len >= 2 and p[1] == ':' and std.ascii.isAlphabetic(p[0])) return errs.Error.UnsafePath;
    var it = std.mem.splitAny(u8, p, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return errs.Error.UnsafePath;
    }
}

test "checkSha256 rejects bad hex" {
    try std.testing.expectError(errs.Error.InvalidHash, checkSha256("notahash"));
    try std.testing.expectError(errs.Error.InvalidHash, checkSha256("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
    try checkSha256("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
}

test "checkSafePath rejects escapes" {
    try std.testing.expectError(errs.Error.UnsafePath, checkSafePath("/etc/passwd"));
    try std.testing.expectError(errs.Error.UnsafePath, checkSafePath("../../home"));
    try std.testing.expectError(errs.Error.UnsafePath, checkSafePath("game/../../etc"));
    try checkSafePath("./game/data");
}

test "checkSafePath rejects Windows-shaped escapes" {
    // Found by the hostile suite: only '/' was treated as a separator, so every
    // one of these was ACCEPTED and could write outside the install dir.
    try std.testing.expectError(errs.Error.UnsafePath, checkSafePath("..\\windows"));
    try std.testing.expectError(errs.Error.UnsafePath, checkSafePath("game\\..\\..\\windows"));
    try std.testing.expectError(errs.Error.UnsafePath, checkSafePath("\\windows\\system32"));
    try std.testing.expectError(errs.Error.UnsafePath, checkSafePath("C:\\windows"));
    try std.testing.expectError(errs.Error.UnsafePath, checkSafePath("C:/windows"));
    // Mixed separators must not sneak a traversal past the splitter either.
    try std.testing.expectError(errs.Error.UnsafePath, checkSafePath("game/..\\..\\etc"));
    // Normal Windows-style relative paths still pass.
    try checkSafePath("game\\data\\file.rpa");
}

test "checkInstallStep accepts extract_inner with safe paths" {
    const step: dom.InstallStep = .{ .extract_inner = .{
        .archive = "inner/payload.zip",
        .to = "./game/",
        .strip = 0,
    } };
    try checkInstallStep(step);
}

test "checkInstallStep rejects extract_inner with escape in archive" {
    const step: dom.InstallStep = .{ .extract_inner = .{
        .archive = "../../etc/passwd.zip",
        .to = "./",
    } };
    try std.testing.expectError(errs.Error.UnsafePath, checkInstallStep(step));
}

test "checkInstallStep rejects extract_inner with absolute dest" {
    const step: dom.InstallStep = .{ .extract_inner = .{
        .archive = "inner.zip",
        .to = "/tmp/oops",
    } };
    try std.testing.expectError(errs.Error.UnsafePath, checkInstallStep(step));
}
