// Recipe `Detect` evaluator. Pure, side-effect-free (modulo stat
// syscalls): given an install root + Host probe + a Detect tree,
// return whether the detector matches.

const std = @import("std");
const dom = @import("domain.zig");
const host_mod = @import("host.zig");
const util_version = @import("util_version");
const util_renpy = @import("util_renpy");

pub const Ctx = struct {
    io: std.Io,
    /// Absolute path to the install root (e.g.
    /// `<library_root>/<thread>/<version>/base`).
    install_root: []const u8,
    host: *const host_mod.Host,
};

/// Evaluate a detector. Errors surface as "no match" — the recipe
/// shouldn't fire if we can't even examine the install.
pub fn matches(ctx: *const Ctx, d: *const dom.Detect) bool {
    const result = switch (d.*) {
        .file_exists => |p| fileExists(ctx, p),
        .file_exists_any => |list| blk: {
            for (list) |p| if (fileExists(ctx, p)) break :blk true;
            break :blk false;
        },
        .host_lacks_soname => |s| ctx.host.lacksSoname(ctx.io, s),
        .host_lacks_sonames_all => |list| blk: {
            for (list) |s| if (ctx.host.hasSoname(ctx.io, s)) break :blk false;
            break :blk true;
        },
        .host_lacks_any_soname => |list| blk: {
            for (list) |s| if (ctx.host.lacksSoname(ctx.io, s)) break :blk true;
            break :blk false;
        },
        .engine_fingerprint => |eng| engineFingerprint(ctx, eng),
        .engine_version_at_most => |b| versionMatches(ctx, b, .at_most),
        .engine_version_at_least => |b| versionMatches(ctx, b, .at_least),
        .all => |list| blk: {
            for (list) |*child| if (!matches(ctx, child)) break :blk false;
            break :blk true;
        },
        .any => |list| blk: {
            for (list) |*child| if (matches(ctx, child)) break :blk true;
            break :blk false;
        },
    };
    std.log.scoped(.compat).info("detect.matches: tag={s} -> {}", .{ @tagName(d.*), result });
    return result;
}

const VersionMatchMode = enum { at_most, at_least };

/// Read the engine's installed version + compare against `bound.version`.
/// Returns false on probe failure ("can't tell" defaults to "not a
/// match" — the recipe doesn't fire if we can't confirm). The
/// per-engine probe is delegated to the shared util module so the
/// parsers stay in one place (also used by `convert/renpy.zig`).
fn versionMatches(ctx: *const Ctx, bound: dom.EngineVersionBound, mode: VersionMatchMode) bool {
    // page_allocator — Ren'Py's `__init__.py` fallback path can read
    // up to 256 KiB, which blew a previous 4 KiB FBA and silently
    // turned every version probe into "no match". Probe runs once
    // per detector, so heap cost is fine. The returned version
    // string is allocator-owned; free it before we return.
    const alloc = std.heap.page_allocator;
    const detected_opt: ?[]const u8 = switch (bound.engine) {
        .renpy => detectRenpyVersion(ctx, alloc),
        // Other engines: version probing not implemented yet. An
        // engine_version_at_* bound therefore can NEVER match for them, so
        // the recipe is silently skipped. Log it loudly (warn, distinct
        // from a genuine probe-read failure) so a recipe author can see
        // WHY their version-gated fix never fires, instead of guessing.
        else => {
            std.log.scoped(.compat).warn(
                "versionMatches: no version probe for engine={s} yet — an engine_version_at_* bound can never match, so this fix will be SKIPPED (bound={s})",
                .{ @tagName(bound.engine), bound.version },
            );
            return false;
        },
    };
    const detected = detected_opt orelse {
        std.log.scoped(.compat).info("versionMatches: engine={s} probe FAILED (no version file readable) — bound={s} mode={s}", .{ @tagName(bound.engine), bound.version, @tagName(mode) });
        return false;
    };
    defer alloc.free(detected);
    const ord = util_version.compare(detected, bound.version);
    std.log.scoped(.compat).info("versionMatches: engine={s} detected={s} bound={s} mode={s} ord={s}", .{ @tagName(bound.engine), detected, bound.version, @tagName(mode), @tagName(ord) });
    return switch (mode) {
        .at_most => ord != .gt,
        .at_least => ord != .lt,
    };
}

/// Try `<install_root>` first, then one level of subdir nesting
/// (prebuilt games extract under a named folder like
/// `<install>/GoodGirlGoneBad/renpy/...`). Reuses
/// `util_renpy.detectVersion` for the actual parse.
fn detectRenpyVersion(ctx: *const Ctx, alloc: std.mem.Allocator) ?[]const u8 {
    if (util_renpy.detectVersion(alloc, ctx.io, ctx.install_root) catch null) |v| return v;
    var dir = std.Io.Dir.cwd().openDir(ctx.io, ctx.install_root, .{ .iterate = true }) catch return null;
    defer dir.close(ctx.io);
    var it = dir.iterate();
    var sub_buf: [1024]u8 = undefined;
    while (it.next(ctx.io) catch null) |entry| {
        // Accept `.unknown` — see comment in `fileExists` above for
        // why (NTFS / FAT mounts surface every entry as DT_UNKNOWN).
        if (entry.kind != .directory and entry.kind != .unknown) continue;
        const sub_root = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ ctx.install_root, entry.name }) catch continue;
        if (util_renpy.detectVersion(alloc, ctx.io, sub_root) catch null) |v| return v;
    }
    return null;
}

/// Check whether `<install_root>/<relpath>` exists, OR any
/// `<install_root>/<subdir>/<relpath>` for direct subdirectories of
/// install_root. Most prebuilt game archives extract a single named
/// folder under the version dir (e.g.
/// `<install>/GoodGirlGoneBad/renpy/bootstrap.py`), so a strict
/// root-only check misses them. We bound the search at depth 1 to
/// stay cheap.
fn fileExists(ctx: *const Ctx, relpath: []const u8) bool {
    if (fileExistsAt(ctx.io, ctx.install_root, relpath)) return true;
    var dir = std.Io.Dir.cwd().openDir(ctx.io, ctx.install_root, .{ .iterate = true }) catch |e| {
        std.log.scoped(.compat).info("fileExists: openDir({s}) failed: {s}", .{ ctx.install_root, @errorName(e) });
        return false;
    };
    defer dir.close(ctx.io);
    var it = dir.iterate();
    var path_buf: [1024]u8 = undefined;
    std.log.scoped(.compat).info("fileExists: scanning {s} for {s}", .{ ctx.install_root, relpath });
    while (it.next(ctx.io) catch null) |entry| {
        std.log.scoped(.compat).info("fileExists:   entry name={s} kind={s}", .{ entry.name, @tagName(entry.kind) });
        // Accept `.unknown` alongside `.directory` — on filesystems
        // that don't carry `d_type` in their readdir entries (FAT,
        // NTFS / exFAT external mounts, some network filesystems),
        // Linux returns `DT_UNKNOWN` and Zig maps that to
        // `entry.kind = .unknown`. Skipping those silently misses
        // every nested `<install>/<wrapper>/renpy/bootstrap.py` on
        // those filesystems — which broke the entire compat scan
        // for installs living on non-FHS-aware mounts (the F95
        // games-on-external-HDD setup). The fileExistsAt call below
        // does its own access() probe, so .file / .symlink entries
        // that we'd try to descend into return false harmlessly.
        if (entry.kind != .directory and entry.kind != .unknown) continue;
        const sub_root = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ ctx.install_root, entry.name }) catch continue;
        if (fileExistsAt(ctx.io, sub_root, relpath)) return true;
    }
    return false;
}

fn fileExistsAt(io: std.Io, base: []const u8, relpath: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ base, relpath }) catch return false;
    std.Io.Dir.cwd().access(io, full, .{}) catch return false;
    return true;
}

fn engineFingerprint(ctx: *const Ctx, eng: dom.Engine) bool {
    return switch (eng) {
        .renpy => fileExists(ctx, "renpy/bootstrap.py"),
        .rpgm_mv => fileExists(ctx, "www/js/rpg_managers.js"),
        .rpgm_mz => fileExists(ctx, "js/rmmz_managers.js"),
        .unity => fileExists(ctx, "UnityPlayer.so") or
            fileExists(ctx, "UnityPlayer.dll"),
        // Other engines: no fingerprint heuristic yet — fall through.
        else => false,
    };
}

const host_mod_for_test = @import("host.zig");
const test_env = @import("util_test_env");

test "host_lacks_any_soname fires when at least one is missing" {
    const ta = std.testing.allocator;
    var env = try test_env.TestEnv.init(ta, "compat-host-lacks");
    defer env.deinit();

    // Synthetic search dir: holds libfoo.so.1, but not libbar.so.99.
    // Host's soname_search points only at this dir so the result is
    // deterministic regardless of what the real system has installed.
    try env.touchFile("libfoo.so.1");

    var host_obj = host_mod_for_test.Host{
        .alloc = ta,
        .soname_search = try ta.dupe(u8, env.root),
        .package_manager = .unknown,
        .is_nixos = false,
    };
    defer host_obj.deinit();

    const ctx = Ctx{ .io = env.io, .install_root = "/tmp/never-exists-f69-test", .host = &host_obj };
    const both_present = [_][]const u8{ "libfoo.so.1", "libfoo.so.1" };
    const one_missing = [_][]const u8{ "libfoo.so.1", "libbar.so.99" };

    try std.testing.expect(!matches(&ctx, &.{ .host_lacks_any_soname = &both_present }));
    try std.testing.expect(matches(&ctx, &.{ .host_lacks_any_soname = &one_missing }));
}

test "engine_version_at_most fires on Ren'Py 7" {
    const ta = std.testing.allocator;
    var env = try test_env.TestEnv.init(ta, "compat-renpy7-version");
    defer env.deinit();

    try env.writeFile("renpy/vc_version.py", "version = u'7.6.1.23060707'\n");

    var host_obj = host_mod_for_test.Host{
        .alloc = ta,
        .soname_search = try ta.dupe(u8, ""),
        .package_manager = .unknown,
        .is_nixos = false,
    };
    defer host_obj.deinit();
    const ctx = Ctx{ .io = env.io, .install_root = env.root, .host = &host_obj };

    try std.testing.expect(matches(&ctx, &.{ .engine_version_at_most = .{ .engine = .renpy, .version = "7.99" } }));
    try std.testing.expect(!matches(&ctx, &.{ .engine_version_at_least = .{ .engine = .renpy, .version = "8.0" } }));
}

test "engineFingerprint finds Ren'Py nested one subdir deep" {
    const ta = std.testing.allocator;
    var env = try test_env.TestEnv.init(ta, "compat-detect-nested");
    defer env.deinit();

    // Game lives in a subdir named after the game.
    try env.touchFile("GoodGirlGoneBad/renpy/bootstrap.py");

    var host_obj = host_mod_for_test.Host{
        .alloc = ta,
        .soname_search = try ta.dupe(u8, ""),
        .package_manager = .unknown,
        .is_nixos = false,
    };
    defer host_obj.deinit();

    const ctx = Ctx{ .io = env.io, .install_root = env.root, .host = &host_obj };
    try std.testing.expect(engineFingerprint(&ctx, .renpy));
}
