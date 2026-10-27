// Compat recipes — declarative descriptions of host-compatibility fixes
// the app can detect against an install + optionally apply on the user's
// behalf. Same anti-RCE shape as `recipe/domain.zig`: closed-set tagged
// unions, no `run`/`exec`/`script` variant in `Action`.
//
// A recipe is pure data: `id`, `title`, `explain`, a `Detect` expression
// that fingerprints the install + host, an ordered `[]Action` list, plus
// optional resource and distro-hint metadata. `detect.zig` evaluates
// detectors, `apply.zig` runs actions, `backup.zig` snapshots anything
// file-mutating actions touch before they touch it.

const std = @import("std");

pub const Severity = enum {
    /// Surface as advisory. Game can still launch unmodified.
    warn,
    /// The game will fail without this fix. UI shows it prominently.
    blocker,
    /// Quality-of-life only (perf, integration). Optional by nature.
    optional,
};

/// Canonical Os + Engine live in `util_domain`. Compat previously
/// declared its own subset of Engine variants which was a divergence
/// hazard (the subset was missing `unknown`).
pub const Os = @import("util_domain").Os;
pub const Engine = @import("util_domain").Engine;

/// Recursive Detect tree. ZON deserializes nested arrays of `Detect`
/// without issue (each element is a fresh value, arena-allocated).
pub const Detect = union(enum) {
    /// Single file present under install root.
    file_exists: []const u8,
    /// At least one of the listed paths exists under install root.
    file_exists_any: []const []const u8,
    /// True when the host's dynamic loader CANNOT resolve the named
    /// library. The classic NixOS / minimal-container trigger.
    host_lacks_soname: []const u8,
    /// True when ALL listed sonames are missing. Equivalent to wrapping
    /// each in `host_lacks_soname` under `all`; convenience for the
    /// common "needs X11 or Wayland and has neither" case.
    host_lacks_sonames_all: []const []const u8,
    /// True when ANY listed soname is missing. The Ren'Py SDL-FHS case:
    /// a stripped Debian container might have libX11 but lack libXmu,
    /// or vice versa, and either gap breaks the bundled runtime.
    /// Recipe authors don't need to know the host distro — they just
    /// list the sonames the engine wants and we report missing.
    host_lacks_any_soname: []const []const u8,
    /// Composite engine fingerprint. Implemented in `detect.zig` as a
    /// canned check for the engine's signature files.
    engine_fingerprint: Engine,
    /// True when the engine's detected version is <= `version`. Engine-
    /// specific version probes live in `detect.zig`. Currently only
    /// Ren'Py is wired up; other engines return false until their
    /// probe lands. Comparison uses `util_version.compare` (semver-ish).
    engine_version_at_most: EngineVersionBound,
    /// True when the engine's detected version is >= `version`.
    engine_version_at_least: EngineVersionBound,
    /// All sub-detectors must be true.
    all: []const Detect,
    /// At least one sub-detector must be true.
    any: []const Detect,
};

pub const EngineVersionBound = struct {
    engine: Engine,
    /// Semver-shaped string ("7.99", "8.0", "7.6.1"). Compared via
    /// `util_version.compare` after we strip the detected version
    /// to the same shape.
    version: []const u8,
};

/// One step in the recipe's `apply` pipeline. MVP implements env-only
/// variants. File-mutating variants (`patchelf_rpath`, `file_overlay`,
/// `file_replace`) are intentionally absent until a real recipe needs
/// them — adding them later is purely additive to the union.
pub const Action = union(enum) {
    /// Prepend a value to an env var at launch time. The value is the
    /// absolute path of a resolved compat resource, optionally
    /// `<resource>/<relpath>`. Existing value is preserved with `sep`
    /// between the prepended chunk and the original.
    env_prepend: EnvPrepend,
    /// Set an env var to a literal value. Overwrites whatever the host
    /// environment had. Use sparingly — env_prepend is safer.
    env_set: EnvSet,
    /// Informational message shown to the user. No automatic effect —
    /// used when the fix requires a system config change the app
    /// cannot perform itself (e.g., enabling `programs.nix-ld`).
    system_hint: SystemHint,
    /// Create a symlink at `link_path` (relative to install root)
    /// pointing at `target` (relative to the link's parent directory,
    /// OR absolute). Primary use case: per-game case-fix recipes that
    /// patch the in-game asset references RPGM scripts hard-coded with
    /// Windows-flavored casing — e.g. game asks for `VNButtons.png`
    /// but the on-disk file is `VNbuttons.png`. Idempotent — apply
    /// silently skips when the link already exists.
    symlink_create: SymlinkCreate,
};

pub const EnvPrepend = struct {
    name: []const u8,
    /// Resource id whose materialized directory provides the value.
    /// Resolved against `<data_root>/compat-resources/<id>/` at apply
    /// time. Mandatory for the MVP; literal-value prepend can be added
    /// as a sibling field later if a recipe needs it.
    from_resource: []const u8,
    /// Relative path inside the resource, joined with `/`. Empty string
    /// (default) means use the resource root.
    relpath: []const u8 = "",
    /// Separator between the prepended chunk and the existing value.
    /// Defaults to `":"` (POSIX path-list). Windows recipes set `";"`.
    sep: []const u8 = ":",
};

pub const EnvSet = struct {
    name: []const u8,
    value: []const u8,
};

pub const SystemHint = struct {
    /// Free-form explanation shown to the user. Per-distro install
    /// snippets go in the recipe's top-level `hints` field; this is
    /// the cross-distro narrative.
    message: []const u8,
};

pub const SymlinkCreate = struct {
    /// Path of the symlink to create, relative to install root. The
    /// parent directory must already exist; apply doesn't `mkdir -p`
    /// because every per-game case-fix recipe targets an existing
    /// `www/img/system/` etc. (the source file already lives there;
    /// only the case-variant symlink is missing).
    link_path: []const u8,
    /// What the link points at. Relative paths are resolved against
    /// the link's PARENT directory (so a same-directory case variant
    /// is just `target = "VNbuttons.png"`). Absolute paths are honored
    /// as-is but not the typical case-fix shape — usually relative.
    target: []const u8,
};

/// Per-package-manager copy-paste install snippet. Picked by the UI
/// after detecting the host's package manager. Recipes can list as
/// many as they want; UI falls back to the first one when no match.
pub const DistroHint = struct {
    /// Identifier of the manager / installation method:
    ///   "pacman" | "apt" | "dnf" | "zypper" | "nix-ld" | "nix-env"
    via: []const u8,
    /// Shell command or config snippet, verbatim.
    command: []const u8,
};

/// Top-level recipe — populated by `std.zon.parse` from a `.compat.zon`
/// file or an `@embedFile`d bundled recipe.
pub const Recipe = struct {
    /// Stable identifier. Convention: `<os>.<engine>[<version>].<short-tag>`,
    /// e.g. `linux.renpy7.sdl-fhs` or `linux.unity.player-fhs`. Stored
    /// on the install when applied so the UI can tell whether a fix
    /// has been applied.
    id: []const u8,
    /// Short human-readable headline shown next to the Fix button.
    title: []const u8,
    /// Multi-sentence explanation of what's wrong and what the fix
    /// will do. Shown above the Fix button so the user sees what
    /// they're agreeing to.
    explain: []const u8,
    severity: Severity = .warn,
    /// Whether the fix can be safely undone. File-mutating actions
    /// should set this true and provide reliable backups.
    reversible: bool = true,
    /// Operating systems this recipe applies to. Empty = applies to
    /// every OS the detector can succeed on (host-capability checks
    /// in the detector itself are the actual gate).
    platforms: []const Os = &.{},
    detect: Detect,
    apply: []const Action = &.{},
    /// Resource ids this recipe references in its actions. The
    /// validator checks that each id resolves to a materialized
    /// resource at app data dir. Independent of action contents so a
    /// recipe can declare a dependency without using it in every
    /// action.
    required_resources: []const []const u8 = &.{},
    /// Per-distro install hints — surfaced when a `system_hint` action
    /// runs, or when the resource lookup fails (telling the user how
    /// to install the missing piece).
    hints: []const DistroHint = &.{},
};

// -----------------------------------------------------------------
//  Detection results (returned from service.scan)
// -----------------------------------------------------------------

pub const IssueStatus = enum {
    /// Detector matched and no FixRecord exists for this recipe on
    /// the install.
    unfixed,
    /// FixRecord exists; fix is applied.
    fixed,
    /// User explicitly dismissed. Service skips re-surfacing.
    dismissed,
};

pub const Issue = struct {
    recipe_id: []const u8,
    title: []const u8,
    explain: []const u8,
    severity: Severity,
    status: IssueStatus,
    /// 0 when the recipe is env-only. Larger when actions are
    /// file-mutating. Surfaced in the UI before the Fix button.
    estimated_backup_bytes: u64 = 0,
};

// -----------------------------------------------------------------
//  Apply-time state — what gets persisted on the install record
// -----------------------------------------------------------------

/// One backed-up path. sha256 names the snapshot file in the backup
/// store; `relpath` lets undo write back to the correct spot inside
/// the install tree.
pub const BackupRecord = struct {
    /// Lowercase hex sha256 of the snapshot. 64 chars.
    sha256: []const u8,
    /// Path inside the install root, forward-slash separated.
    relpath: []const u8,
    /// File size in bytes (post-snapshot). 0 for symlinks.
    size: u64,
    /// st_mode bits (only the permission portion is honored on
    /// restore; type bits derived from `was_symlink`).
    mode: u32,
    was_symlink: bool = false,
    /// Original target when `was_symlink`. Restore re-creates the
    /// symlink without reading the snapshot file.
    symlink_target: ?[]const u8 = null,
    /// True when the touched path DID NOT EXIST before apply (the
    /// recipe is creating a new file/symlink). Restore deletes the
    /// path instead of writing back content. Lets actions like
    /// `symlink_create` participate in the backup→apply→undo
    /// machinery without needing a real prior file to snapshot.
    was_absent: bool = false,
};

pub const FixRecord = struct {
    recipe_id: []const u8,
    /// Hash of the recipe's serialized bytes at apply time. Lets the
    /// UI flag "recipe upgraded since this install was fixed" and the
    /// service refuse to undo with a divergent recipe.
    recipe_sha256: []const u8,
    /// Unix seconds.
    applied_at: i64,
    backups: []const BackupRecord = &.{},
};

// -----------------------------------------------------------------
//  Apply pipeline plumbing
// -----------------------------------------------------------------

/// Declared by an Action so service.zig knows which files to snapshot
/// before invoking the action. Env-only actions return an empty slice.
pub const TouchedPath = struct {
    relpath: []const u8,
    /// File must exist at apply time; if absent, service aborts with
    /// an error before any action runs. False = action can create.
    must_exist: bool = true,
    kind: enum { file, symlink, dir } = .file,
};

/// One `name=value` pair produced by env-affecting actions and
/// consumed by the launcher when composing the spawn env. Built by
/// `apply.compose_env(install_id)` from the install's applied fixes.
pub const EnvPair = struct {
    name: []const u8,
    value: []const u8,
    /// When true, prepend `value` + the action's `sep` to whatever the
    /// host environ has for `name`. When false, overwrite outright.
    /// Distinction lives here (not in the launcher) so the launcher
    /// stays env-agnostic.
    prepend: bool,
    /// Separator for prepend mode. Ignored when prepend = false.
    sep: []const u8 = ":",
};

test "Recipe parses minimal valid shape" {
    const src =
        \\.{
        \\    .id = "test.example.basic",
        \\    .title = "Test",
        \\    .explain = "Explanation here.",
        \\    .detect = .{ .file_exists = "marker" },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: std.zon.parse.Diagnostics = undefined;
    const r = try std.zon.parse.fromSlice(Recipe, .{ .gpa = arena.allocator(), .arena = arena.allocator(), .source = src, .diagnostics = &diag, .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("test.example.basic", r.id);
    try std.testing.expectEqualStrings("marker", r.detect.file_exists);
    try std.testing.expectEqual(Severity.warn, r.severity);
    try std.testing.expect(r.reversible);
}

test "Recipe parses nested detect tree" {
    const src =
        \\.{
        \\    .id = "test.compose",
        \\    .title = "Compose",
        \\    .explain = "Composite detect.",
        \\    .detect = .{ .all = .{
        \\        .{ .file_exists = "a" },
        \\        .{ .any = .{
        \\            .{ .host_lacks_soname = "libX11.so.6" },
        \\            .{ .host_lacks_soname = "libwayland-client.so.0" },
        \\        } },
        \\    } },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: std.zon.parse.Diagnostics = undefined;
    const r = try std.zon.parse.fromSlice(Recipe, .{ .gpa = arena.allocator(), .arena = arena.allocator(), .source = src, .diagnostics = &diag, .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 2), r.detect.all.len);
    try std.testing.expectEqualStrings("a", r.detect.all[0].file_exists);
    try std.testing.expectEqual(@as(usize, 2), r.detect.all[1].any.len);
}
