// Public face of the importer context.
//
// Two sources today — F95Checker (SQLite at ~/.config/f95checker/) and
// xLibrary (Electron app, JSON at ~/.config/xlibrary/). Both shapes
// land in `ImportedGame` so the migration + library-upsert flow
// downstream only sees one type.
//
// Each reader returns a `Bundle` that owns its string memory via an
// arena, so the caller frees with one `bundle.deinit()` call.

const std = @import("std");

pub const Engine = @import("util_domain").Engine;

pub const Error = error{
    OpenFailed,
    ParseFailed,
    OutOfMemory,
};

pub const ImportedGame = struct {
    /// F95Zone thread id — the primary key f69's library uses to dedupe.
    thread_id: u64,
    name: []const u8,
    /// Detected engine, when the importer was able to determine it.
    /// The folder-scan importer fills this via file fingerprints
    /// (`renpy/bootstrap.py`, `UnityPlayer.so`, …). F95Checker /
    /// xLibrary importers leave it `.unknown` — engine is reconciled
    /// from the F95 thread title / scrape at sync time for those.
    engine: Engine = .unknown,
    developer: ?[]const u8 = null,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    changelog: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    cover_url: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    /// 0..5 scale on the source DB's user rating axis. Both sources use
    /// the F95Zone star scale so this maps 1:1 onto `library.Game.user_rating`.
    user_rating: ?f32 = null,
    /// F95Zone-scraped average score (0..5). Maps to `library.Game.rating`.
    rating: ?f32 = null,
    vote_count: ?u32 = null,
    last_played_at: ?i64 = null,
    /// Relative path from the source's games-base-dir down to the
    /// launcher binary, exactly as the source recorded it
    /// (e.g. `Babysitter-0.2.2b.-linux/Babysitter.sh`). The migrator
    /// uses the *first* path segment as the install directory to copy.
    /// Null = source has no install for this game (library-only entry).
    install_executable_rel: ?[]const u8 = null,
    /// Optional source-claimed completion state ("Completed" /
    /// "Not Started" / etc.). Down-converted to f69's enum at upsert
    /// time; null = unknown.
    completion_status: ?[]const u8 = null,

    /// First path segment of `install_executable_rel`, which is the
    /// directory the migrator should copy. Null when no install, the
    /// executable is at the base dir's top level, or the path is
    /// UNSAFE for use as a sub-directory under the games-base-dir.
    ///
    /// SAFETY: rejects absolute paths and `..` traversal segments.
    /// F95Checker's DB stores absolute paths in its `executables`
    /// JSON column; xLibrary may do the same. Without this check the
    /// caller would end up with `src_dir = "<games_base_dir>/"` (an
    /// empty first segment from a leading "/") and `migrate.copyVerifyDelete`
    /// would then `deleteTree(games_base_dir)` after copying — wiping
    /// the user-selected directory. This is HOW
    /// `~/.config/f95checker/` got nuked for users who pointed the
    /// games-base-dir picker at their f95checker config folder.
    ///
    /// Separator handling: the source tool wrote this path on
    /// whatever OS it was running on, so it may use `/` (Linux/macOS
    /// F95Checker/xLibrary) or `\` (Windows). Both are treated as
    /// segment separators, and both a leading `/` or `\` and a
    /// drive-letter prefix (`C:\...`, `C:/...`) count as absolute.
    pub fn installDirRel(self: *const ImportedGame) ?[]const u8 {
        const p = self.install_executable_rel orelse return null;
        if (p.len == 0 or isAbsolutePath(p)) return null;
        const sep = std.mem.indexOfAny(u8, p, "/\\") orelse return null;
        const seg = p[0..sep];
        // Reject empty and traversal segments. `..` would land src_dir
        // at games_base_dir's PARENT, an even bigger blast radius.
        if (seg.len == 0) return null;
        if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return null;
        return seg;
    }
};

/// True for `/foo`, `\foo`, `\\server\share`, or a drive-letter path
/// (`C:\foo`, `C:/foo`) — every absolute-path convention the source
/// tool might have written this field with, on any OS.
fn isAbsolutePath(p: []const u8) bool {
    if (p.len == 0) return false;
    if (p[0] == '/' or p[0] == '\\') return true;
    if (p.len >= 2 and std.ascii.isAlphabetic(p[0]) and p[1] == ':') return true;
    return false;
}

/// Owns every string referenced by `games`. Caller frees with `deinit`.
pub const Bundle = struct {
    arena: *std.heap.ArenaAllocator,
    games: []ImportedGame,

    pub fn deinit(self: *Bundle) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.* = undefined;
    }
};

pub const f95checker = @import("f95checker.zig");
pub const xlibrary = @import("xlibrary.zig");
pub const folder_scan = @import("folder_scan.zig");
pub const migrate = @import("migrate.zig");
pub const name_match = @import("name_match.zig");

test {
    _ = f95checker;
    _ = xlibrary;
    _ = folder_scan;
    _ = migrate;
    _ = name_match;
}

// ============================================================
//  installDirRel safety regression tests
//
//  REGRESSION: F95Checker's DB stores ABSOLUTE paths in its
//  `executables` column. The old `installDirRel` returned the
//  segment before the first '/', which is the empty string for
//  absolute paths. The migrator then computed
//  `src_dir = "<games_base_dir>/" + ""` ≈ the games-base-dir
//  itself, ran `migrate.copyVerifyDelete`, and `deleteTree`d the
//  user-selected directory. Users who picked `~/.config/f95checker/`
//  as their games dir lost their entire F95Checker config.
//
//  Every case below MUST return null. Adding a case is welcome;
//  loosening one needs a very careful look at `processOne`.
// ============================================================

const testing = std.testing;

test "installDirRel: absolute path returns null (F95Checker DB case)" {
    const g = ImportedGame{ .thread_id = 1, .name = "x", .install_executable_rel = "/home/u/games/Foo/Foo.sh" };
    try testing.expect(g.installDirRel() == null);
}

test "installDirRel: empty string returns null" {
    const g = ImportedGame{ .thread_id = 1, .name = "x", .install_executable_rel = "" };
    try testing.expect(g.installDirRel() == null);
}

test "installDirRel: leading slash only returns null" {
    const g = ImportedGame{ .thread_id = 1, .name = "x", .install_executable_rel = "/" };
    try testing.expect(g.installDirRel() == null);
}

test "installDirRel: parent traversal returns null" {
    const g = ImportedGame{ .thread_id = 1, .name = "x", .install_executable_rel = "../escape/Foo.sh" };
    try testing.expect(g.installDirRel() == null);
}

test "installDirRel: dot traversal returns null" {
    const g = ImportedGame{ .thread_id = 1, .name = "x", .install_executable_rel = "./Foo.sh" };
    try testing.expect(g.installDirRel() == null);
}

test "installDirRel: legitimate relative path returns the first segment" {
    const g = ImportedGame{ .thread_id = 1, .name = "x", .install_executable_rel = "Babysitter-0.2.2b.-linux/Babysitter.sh" };
    try testing.expectEqualStrings("Babysitter-0.2.2b.-linux", g.installDirRel().?);
}

test "installDirRel: top-level executable (no slash) returns null" {
    const g = ImportedGame{ .thread_id = 1, .name = "x", .install_executable_rel = "Game.sh" };
    try testing.expect(g.installDirRel() == null);
}

test "installDirRel: Windows drive-letter absolute path returns null" {
    const g = ImportedGame{ .thread_id = 1, .name = "x", .install_executable_rel = "C:\\Users\\u\\games\\Foo\\Foo.exe" };
    try testing.expect(g.installDirRel() == null);
}

test "installDirRel: Windows leading backslash returns null" {
    const g = ImportedGame{ .thread_id = 1, .name = "x", .install_executable_rel = "\\Foo\\Foo.exe" };
    try testing.expect(g.installDirRel() == null);
}

test "installDirRel: Windows-style relative path returns the first segment" {
    const g = ImportedGame{ .thread_id = 1, .name = "x", .install_executable_rel = "Babysitter-0.2.2b-win\\Babysitter.exe" };
    try testing.expectEqualStrings("Babysitter-0.2.2b-win", g.installDirRel().?);
}

test "installDirRel: Windows-style parent traversal returns null" {
    const g = ImportedGame{ .thread_id = 1, .name = "x", .install_executable_rel = "..\\escape\\Foo.exe" };
    try testing.expect(g.installDirRel() == null);
}
