// f69 entry point. Resolves `data_root` (portable layout — `<exe_dir>/data/`
// by default, override via `F69_DATA_DIR`), opens the Library SQLite DB,
// wires services and the aria2 RPC daemon, then runs the UI loop.
//
// `pub fn main(init: std.process.Init)` is Zig 0.16's main signature when
// you want access to the process Init context (allocator, io, args, env).

const std = @import("std");
const builtin = @import("builtin");

const library = @import("library");
const f95 = @import("f95");
const f95_indexer = @import("f95_indexer");
const downloads = @import("downloads");
const recipe = @import("recipe");
const sandbox_mod = @import("sandbox");
const convert_mod = @import("convert");
const compat_mod = @import("compat");
const ui = @import("ui");
// The SDL3-GPU windowing backend. main owns the window backend's
// lifetime and hands it to `ui.runMainLoop`; the `ui` module itself is
// backend-agnostic (so it can be rebuilt against dvui's testing backend
// for headless integration tests). Only the GUI exe links SDL.
const SDLBackend = @import("sdl3gpu-backend");
const util_setting = @import("util_setting");
const theme_store = @import("ui_theme_store");
const build_options = @import("build_options");

/// Override the stdlib's default log level so `log.debug(...)` actually
/// reaches stderr. While we're still in phase-1 alpha, debug-level
/// chatter is the easier bug-finding path; ratcheted down to .info
/// once everything stabilizes.
///
/// `logFn` is the per-call filter — `log_scope_levels` would be the
/// idiomatic knob, but dvui's sdl3gpu backend iterates that slice in
/// a way that requires every element to be comptime-known, so adding
/// even one entry trips a Zig comptime error in the backend. The
/// custom logFn does the same job at runtime without touching dvui.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = customLogFn,
};

/// Filter `dvui`-scope debug noise (e.g. its per-frame
/// `borderAndBackground … forcing background` trace) while keeping
/// everything else at the level configured above. Other scopes
/// (including dvui at .info/.warn/.err) fall through to the default
/// log implementation.
fn customLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == .dvui and level == .debug) return;
    std.log.defaultLog(level, scope, format, args);
}

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // CLI flags — handled before any setup so `f69 --version` works
    // even if the data root can't be created (e.g. read-only mount).
    {
        // iterateAllocator is the cross-platform arg iterator (the no-alloc iterate()
        // @compileErrors on Windows/WASI, which need the command line decoded via an allocator).
        var it = try init.minimal.args.iterateAllocator(gpa);
        defer it.deinit();
        _ = it.next(); // skip argv[0]
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
                std.debug.print("f69 v{s}\n", .{build_options.version});
                return;
            }
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                std.debug.print(
                    \\f69 v{s} — F95Zone library manager
                    \\
                    \\Usage: f69 [options]
                    \\
                    \\Options:
                    \\  -V, --version       Print version and exit
                    \\  -h, --help          Print this help and exit
                    \\
                    \\Environment:
                    \\  F69_DATA_DIR        Override data root (default: <exe_dir>/data/)
                    \\  F95_INDEXER_URL     Override F95Indexer base URL
                    \\                      (default: https://api.f95checker.dev)
                    \\
                , .{build_options.version});
                return;
            }
        }
    }

    // **Portable data layout.** Everything lives under a single
    // `data_root`. Default: `<dir-of-this-exe>/data/`. Override with
    // the `F69_DATA_DIR` env var. Drop the f69 folder anywhere on disk
    // and it carries DB + recipes + library + caches + saves all
    // together.
    const data_root = try resolveDataRoot(gpa, init.io, init.minimal.environ);
    defer gpa.free(data_root);
    try std.Io.Dir.cwd().createDirPath(init.io, data_root);
    log.info("data root {s}", .{data_root});

    // DB at `<data_root>/f69.db`.
    const db_path = try std.fmt.allocPrint(gpa, "{s}/f69.db", .{data_root});
    defer gpa.free(db_path);

    // Cover-image cache at `<data_root>/covers/`.
    const covers_dir = try std.fmt.allocPrint(gpa, "{s}/covers", .{data_root});
    defer gpa.free(covers_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, covers_dir);
    sweepTmpCovers(init.io, covers_dir) catch {};

    // Per-game installs at `<data_root>/library/<thread_id>/<version>/`,
    // UNLESS the user relocated the games library to a different disk. The
    // override path lives in `<data_root>/library_dir` (one line, absolute);
    // Settings → Storage writes it and remaps the existing DB links. This lets
    // the app + DB live on a fast disk while the bulk game data stays put
    // (e.g. on a large NTFS volume). Missing/empty → the bundled default.
    const library_dir_setting = try std.fmt.allocPrint(gpa, "{s}/library_dir", .{data_root});
    defer gpa.free(library_dir_setting);
    const library_root = (util_setting.readSingleLine(init.io, gpa, library_dir_setting) catch null) orelse
        try std.fmt.allocPrint(gpa, "{s}/library", .{data_root});
    defer gpa.free(library_root);
    try std.Io.Dir.cwd().createDirPath(init.io, library_root);

    log.info("db        {s}", .{db_path});
    log.info("covers    {s}", .{covers_dir});
    log.info("library   {s}", .{library_root});

    var lib = try library.Library.open(gpa, db_path);
    defer lib.close();

    // Automatic DB backups: on startup, snapshot the (post-migration) DB to
    // `<data_root>/backups/` if the newest is older than a day, keeping the
    // most recent few. Best-effort — never blocks launch.
    maybeBackupDb(init.io, gpa, &lib, data_root);

    const rate_limit_ms: u64 = 1500;
    var f95_client = f95.Client.init(gpa, init.io, rate_limit_ms);
    defer f95_client.deinit();
    var f95_service = f95.Service.init(gpa, &f95_client);

    // Cookie persistence at `<data_root>/f95_cookie`.
    const cookie_path = try std.fmt.allocPrint(gpa, "{s}/f95_cookie", .{data_root});
    defer gpa.free(cookie_path);
    log.info("cookie    {s}", .{cookie_path});

    const recipes_dir = try std.fmt.allocPrint(gpa, "{s}/recipes", .{data_root});
    defer gpa.free(recipes_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, recipes_dir);
    log.info("recipes   {s}", .{recipes_dir});

    const mod_archives_dir = try std.fmt.allocPrint(gpa, "{s}/mod-archives", .{data_root});
    defer gpa.free(mod_archives_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, mod_archives_dir);
    log.info("mods      {s}", .{mod_archives_dir});

    // User-authored mod-install presets at `<data_root>/mod-presets/`.
    // Built-in presets ship embedded in the binary; this dir is for
    // user additions / overrides. Discovered + merged at preset
    // detection time.
    const mod_presets_dir = try std.fmt.allocPrint(gpa, "{s}/mod-presets", .{data_root});
    defer gpa.free(mod_presets_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, mod_presets_dir);
    log.info("presets   {s}", .{mod_presets_dir});

    // User-authored convert-strategy presets at
    // `<data_root>/convert-presets/`. Built-ins ship embedded; this
    // dir lets users add custom Win→Linux conversion variants.
    const convert_presets_dir = try std.fmt.allocPrint(gpa, "{s}/convert-presets", .{data_root});
    defer gpa.free(convert_presets_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, convert_presets_dir);
    log.info("convert   {s}", .{convert_presets_dir});
    if (loadCookie(init.io, gpa, cookie_path)) |cookie_opt| {
        if (cookie_opt) |cookie| {
            defer gpa.free(cookie);
            log.info("loaded stored F95 cookie ({d} bytes)", .{cookie.len});
            f95_client.setCookie(cookie) catch |e| {
                log.warn("failed to apply stored cookie: {s}", .{@errorName(e)});
            };
        } else {
            log.debug("no stored cookie", .{});
        }
    } else |e| {
        log.warn("cookie load failed: {s}", .{@errorName(e)});
    }

    // aria2 RPC port — `<data_root>/aria2_port`, default 0 (random
    // ephemeral). Settings → Downloads exposes a textEntry that writes
    // here; changes take effect on the next launch (the daemon binds
    // at spawn).
    const aria2_port_path = try std.fmt.allocPrint(gpa, "{s}/aria2_port", .{data_root});
    defer gpa.free(aria2_port_path);
    const initial_aria2_port: u16 = util_setting.loadInt(u16, init.io, gpa, aria2_port_path, 0);
    log.info("aria2 port {d} ({s})", .{ initial_aria2_port, if (initial_aria2_port == 0) "random" else "user-configured" });

    // aria2 seed ratio — `<data_root>/aria2_seed_ratio`. Floor 2.0,
    // default 5.0. Daemon-wide --seed-ratio flag wires from here.
    // Changes take effect on the next launch.
    const aria2_seed_ratio_path = try std.fmt.allocPrint(gpa, "{s}/aria2_seed_ratio", .{data_root});
    defer gpa.free(aria2_seed_ratio_path);
    // Seed ratio is clamped to ≥ 2.0 (RPDL community floor) — generic
    // loadFloat handles the parse + default, the floor stays here.
    const initial_aria2_seed_ratio: f32 = @max(util_setting.loadFloat(f32, init.io, gpa, aria2_seed_ratio_path, 5.0), 2.0);
    log.info("aria2 seed_ratio {d:.2}", .{initial_aria2_seed_ratio});

    // aria2 seed-time cap (minutes) — `<data_root>/aria2_seed_time`. 0 = no
    // cap (ratio governs). Applied live + at spawn via --seed-time.
    const aria2_seed_time_path = try std.fmt.allocPrint(gpa, "{s}/aria2_seed_time", .{data_root});
    defer gpa.free(aria2_seed_time_path);
    const initial_aria2_seed_time: u32 = util_setting.loadInt(u32, init.io, gpa, aria2_seed_time_path, 0);
    log.info("aria2 seed_time {d}m", .{initial_aria2_seed_time});

    // Downloads layout — split between `direct/` (plain HTTP) and
    // `torrents/` (BitTorrent). aria2's daemon-wide `--dir=` points at
    // `direct/`; `enqueueTorrent` overrides per-call to `torrents/`.
    // Kept under `<data_root>/downloads/` so the user can wipe both
    // categories with one rm -rf and never collides with installed
    // games under `<data_root>/library/`.
    // Overridable too (`<data_root>/downloads_dir`) — keeps in-flight /
    // seeding torrents on their original volume when the app+DB relocate.
    const downloads_dir_setting = try std.fmt.allocPrint(gpa, "{s}/downloads_dir", .{data_root});
    defer gpa.free(downloads_dir_setting);
    const downloads_root = (util_setting.readSingleLine(init.io, gpa, downloads_dir_setting) catch null) orelse
        try std.fmt.allocPrint(gpa, "{s}/downloads", .{data_root});
    defer gpa.free(downloads_root);
    const downloads_direct_root = try std.fmt.allocPrint(gpa, "{s}/direct", .{downloads_root});
    defer gpa.free(downloads_direct_root);
    const downloads_torrents_root = try std.fmt.allocPrint(gpa, "{s}/torrents", .{downloads_root});
    defer gpa.free(downloads_torrents_root);
    try std.Io.Dir.cwd().createDirPath(init.io, downloads_direct_root);
    try std.Io.Dir.cwd().createDirPath(init.io, downloads_torrents_root);
    log.info("downloads direct={s} torrents={s}", .{ downloads_direct_root, downloads_torrents_root });

    const aria2_path = try resolveAria2Path(gpa, init.io, init.minimal.environ);
    defer gpa.free(aria2_path);
    var dl_mgr = downloads.Manager.init(
        gpa,
        init.io,
        library_root,
        library_root,
        downloads_direct_root,
        downloads_torrents_root,
        aria2_path,
        initial_aria2_port,
        initial_aria2_seed_ratio,
        initial_aria2_seed_time,
    );
    defer dl_mgr.deinit();

    // Cross-restart persistence for in-flight downloads. Two files in
    // `<data_root>/cache/downloads/`:
    //   - aria2.session           — aria2's own session file.
    //   - manager_jobs.json       — our id ↔ gid ↔ url mapping.
    // SIGKILL-safe: aria2 checkpoints every 60s, manager_jobs writes
    // atomically on every enqueue/remove.
    const dl_cache_dir = try std.fmt.allocPrint(gpa, "{s}/cache/downloads", .{data_root});
    defer gpa.free(dl_cache_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, dl_cache_dir);
    const aria2_session_path = try std.fmt.allocPrint(gpa, "{s}/aria2.session", .{dl_cache_dir});
    defer gpa.free(aria2_session_path);
    const manager_jobs_path = try std.fmt.allocPrint(gpa, "{s}/manager_jobs.json", .{dl_cache_dir});
    defer gpa.free(manager_jobs_path);
    log.info("dl cache  {s}", .{dl_cache_dir});
    dl_mgr.enablePersistence(manager_jobs_path, aria2_session_path);
    // Eagerly spawn aria2 if we have anything to resume. Aria2's own
    // --input-file=<session> reads the persisted BT/HTTP state at
    // launch, so downloads that were mid-leech and torrents that
    // were mid-seed pick right back up. First-run users skip the
    // spawn — `resumeFromDisk` sees no jobs / no session and bails.
    dl_mgr.resumeFromDisk() catch |e| {
        log.warn("download manager resume failed: {s}", .{@errorName(e)});
    };

    // Recipe repository — points at `<config>/f69/recipes/`. UI's
    // per-game Download button calls `findGameByThread` against this.
    var recipe_repo = recipe.Repo.init(gpa, init.io, recipes_dir);
    defer recipe_repo.deinit();

    // Sandbox backend — bwrap on Linux, sandboxie on Windows, none
    // otherwise. Failures fall through to `.none` (Launch then surfaces
    // a clear backend-unavailable error). HostInfo carries the display
    // / audio / fontconfig env snapshot.
    // Sandboxie Start.exe override (Windows): the persisted Settings file-picker
    // value (<data_root>/sandboxie_path) wins; F69_SANDBOXIE_PATH env is the
    // fallback. Both empty → detection probes %ProgramFiles%\Sandboxie-Plus\.
    const sbie_path_file = try std.fmt.allocPrint(gpa, "{s}/sandboxie_path", .{data_root});
    defer gpa.free(sbie_path_file);
    const sbie_from_file = util_setting.readSingleLine(init.io, gpa, sbie_path_file) catch null;
    defer if (sbie_from_file) |s| gpa.free(s);
    const sbie_from_env = init.minimal.environ.getAlloc(gpa, "F69_SANDBOXIE_PATH") catch null;
    defer if (sbie_from_env) |s| gpa.free(s);
    const sbie_override: []const u8 = sbie_from_file orelse (sbie_from_env orelse "");
    var sandbox = sandbox_mod.pickBackend(gpa, init.io, init.minimal.environ, sbie_override);
    defer sandbox.deinit();
    log.info("sandbox   backend={s}", .{sandbox.backendName()});

    // Permanent `NoSandbox` instance used when the user has opted out
    // of sandboxing (per-game `.never`, or `.use_default` with the
    // global toggle off). Constructed once so the Launch button can
    // route either through the primary backend or this without any
    // per-launch allocation.
    var host_launcher = sandbox_mod.NoSandbox.init(init.io, init.minimal.environ);

    // Convert service — Ren'Py / RPGM Win→Linux. SDK cache lands at
    // <data_root>/cache/convert/sdks/. Distro detection runs once
    // at startup.
    const convert_cache_root = try std.fmt.allocPrint(gpa, "{s}/cache", .{data_root});
    defer gpa.free(convert_cache_root);
    var convert_svc = try convert_mod.Service.init(gpa, init.io, convert_cache_root);
    defer convert_svc.deinit();
    log.info("convert   distro={s} cache={s}/convert/sdks", .{ @tagName(convert_svc.distro), convert_cache_root });

    // Compat service — host-compatibility recipes (e.g. Ren'Py SDL
    // FHS-libs on NixOS). Bundled recipes are `@embedFile`d at
    // compile time; user overrides live in
    // `<data_root>/compat-recipes/`. Resources (the FHS lib bundles
    // we ship for compat fixes) land at
    // `<data_root>/compat-resources/<id>/`. Backups go to
    // `<data_root>/compat-backups/<install_id>/`.
    const compat_recipes_dir = try std.fmt.allocPrint(gpa, "{s}/compat-recipes", .{data_root});
    defer gpa.free(compat_recipes_dir);
    std.Io.Dir.cwd().createDirPath(init.io, compat_recipes_dir) catch {};
    const compat_resources_dir = try std.fmt.allocPrint(gpa, "{s}/compat-resources", .{data_root});
    defer gpa.free(compat_resources_dir);
    std.Io.Dir.cwd().createDirPath(init.io, compat_resources_dir) catch {};
    const compat_backups_dir = try std.fmt.allocPrint(gpa, "{s}/compat-backups", .{data_root});
    defer gpa.free(compat_backups_dir);
    std.Io.Dir.cwd().createDirPath(init.io, compat_backups_dir) catch {};

    var compat_host = compat_mod.probeHost(gpa, init.io) catch |e| {
        log.err("compat host probe failed: {s}", .{@errorName(e)});
        return e;
    };
    defer compat_host.deinit();
    log.info(
        "compat    pm={s} nixos={} sonames={s}",
        .{ @tagName(compat_host.package_manager), compat_host.is_nixos, compat_host.soname_search },
    );

    var compat_repo = compat_mod.Repo.init(gpa, init.io, compat_recipes_dir);
    defer compat_repo.deinit();
    compat_repo.load() catch |e| {
        log.warn("compat repo load failed: {s}", .{@errorName(e)});
    };

    var compat_resolver = compat_mod.Resolver.init(gpa, init.io, compat_resources_dir);
    var compat_backups = compat_mod.BackupStore.init(gpa, init.io, compat_backups_dir);
    var compat_svc = compat_mod.Service.init(gpa, init.io, &compat_repo, &compat_host, &compat_resolver, &compat_backups);

    const host_xdg_runtime = init.minimal.environ.getAlloc(gpa, "XDG_RUNTIME_DIR") catch null;
    defer if (host_xdg_runtime) |v| gpa.free(v);
    const host_wayland = init.minimal.environ.getAlloc(gpa, "WAYLAND_DISPLAY") catch null;
    defer if (host_wayland) |v| gpa.free(v);
    const host_x11 = init.minimal.environ.getAlloc(gpa, "DISPLAY") catch null;
    defer if (host_x11) |v| gpa.free(v);
    const host_home = init.minimal.environ.getAlloc(gpa, "HOME") catch null;
    defer if (host_home) |v| gpa.free(v);
    const host: sandbox_mod.HostInfo = .{
        .xdg_runtime_dir = host_xdg_runtime,
        .wayland_display = host_wayland,
        .x11_display = host_x11,
        .home = host_home,
    };

    // RPDL bearer token, plain-text at `<data_root>/rpdl_token`
    // (mode 0600). Mirrors the f95_cookie pattern. Absent file = null
    // → per-game Download falls back to error message on .rpdl sources.
    const rpdl_token_path = try std.fmt.allocPrint(gpa, "{s}/rpdl_token", .{data_root});
    defer gpa.free(rpdl_token_path);
    log.info("rpdl tok  {s}", .{rpdl_token_path});
    const rpdl_token: ?[]u8 = loadCookie(init.io, gpa, rpdl_token_path) catch |e| blk: {
        log.warn("rpdl token load failed: {s}", .{@errorName(e)});
        break :blk null;
    };
    defer if (rpdl_token) |t| gpa.free(t);
    if (rpdl_token) |t| log.info("loaded RPDL token ({d} bytes)", .{t.len});

    // Browser picker: detect installed browsers + load the user's
    // saved choice (if any) from `<config>/f69/browser`. The path
    // sent to xdg-open / spawn is whatever the user picked, with
    // `xdg-open` as the implicit fallback.
    const browsers = detectBrowsers(init.io, gpa, init.minimal.environ) catch &.{};
    defer freeBrowsers(gpa, @constCast(browsers));
    log.info("detected {d} browser(s):", .{browsers.len});
    for (browsers) |b| log.info("  {s} ({s})", .{ b.display, b.path });

    const browser_choice_path = try std.fmt.allocPrint(gpa, "{s}/browser", .{data_root});
    defer gpa.free(browser_choice_path);

    var browser_path_buf: [512]u8 = [_]u8{0} ** 512;
    if (util_setting.readSingleLine(init.io, gpa, browser_choice_path)) |loaded_opt| {
        if (loaded_opt) |loaded| {
            defer gpa.free(loaded);
            const n = @min(loaded.len, browser_path_buf.len - 1);
            @memcpy(browser_path_buf[0..n], loaded[0..n]);
        } else {
            const dflt = "xdg-open";
            @memcpy(browser_path_buf[0..dflt.len], dflt);
        }
    } else |_| {
        const dflt = "xdg-open";
        @memcpy(browser_path_buf[0..dflt.len], dflt);
    }

    // UI scale: loaded from `<data_root>/ui_scale` (default 1.25).
    // Slider in Settings rewrites this file when the user adjusts it.
    const ui_scale_path = try std.fmt.allocPrint(gpa, "{s}/ui_scale", .{data_root});
    defer gpa.free(ui_scale_path);

    // Theme: load the saved palette (if any) onto the console default before
    // the UI builds its theme. Settings → Appearance rewrites this file.
    const theme_path = try std.fmt.allocPrint(gpa, "{s}/theme.zon", .{data_root});
    defer gpa.free(theme_path);
    theme_store.setPath(theme_path);
    theme_store.load(init.io, gpa);
    // ui_scale is clamped to [0.75, 3.0] so a bad file can't render the
    // UI unreadable.
    const initial_ui_scale: f32 = std.math.clamp(util_setting.loadFloat(f32, init.io, gpa, ui_scale_path, 1.25), 0.75, 3.0);

    // Last-update-check timestamp — used as the stop-cursor when
    // walking F95's latest-updates pages. 0 (file missing) means the
    // worker will substitute "now - 14 days" so the very first run
    // doesn't scan years of history.
    const last_update_check_path = try std.fmt.allocPrint(gpa, "{s}/last_update_check", .{data_root});
    defer gpa.free(last_update_check_path);
    const initial_last_update_check_ts: i64 = util_setting.loadInt(i64, init.io, gpa, last_update_check_path, 0);

    // Auto-check preferences (on-startup toggle + recurring interval).
    const auto_check_path = try std.fmt.allocPrint(gpa, "{s}/auto_check", .{data_root});
    defer gpa.free(auto_check_path);
    const initial_auto_check: ui.AutoCheckSettings = loadAutoCheck(init.io, gpa, auto_check_path) catch .{};

    const lib_prefs_path = try std.fmt.allocPrint(gpa, "{s}/lib_prefs", .{data_root});
    defer gpa.free(lib_prefs_path);
    // Lives for the program — read straight into the main loop's RuntimeInfo.
    const initial_lib_prefs: []const u8 = (util_setting.readSingleLine(init.io, gpa, lib_prefs_path) catch null) orelse "";

    // Auto-convert toggle — `<data_root>/auto_convert` contains a
    // single `true` / `false`. Default false.
    const auto_convert_path = try std.fmt.allocPrint(gpa, "{s}/auto_convert", .{data_root});
    defer gpa.free(auto_convert_path);
    const initial_auto_convert: bool = util_setting.loadBool(init.io, gpa, auto_convert_path, false);

    // Auto-apply-compat toggle — `<data_root>/auto_apply_compat`.
    // Default TRUE (safe — fixes are reversible, collapses the
    // Convert → Launch-fail → Fix Compat → Launch cycle into one
    // click).
    const auto_apply_compat_path = try std.fmt.allocPrint(gpa, "{s}/auto_apply_compat", .{data_root});
    defer gpa.free(auto_apply_compat_path);
    const initial_auto_apply_compat: bool = util_setting.loadBool(init.io, gpa, auto_apply_compat_path, true);

    // Global sandbox-on-launch default — single-line `true` / `false`.
    // Default on (the safer choice). Per-game `SandboxOverride.use_default`
    // consults this value; `.always` / `.never` ignore it.
    const sandbox_default_path = try std.fmt.allocPrint(gpa, "{s}/sandbox_default", .{data_root});
    defer gpa.free(sandbox_default_path);
    const initial_sandbox_default: bool = util_setting.loadBool(init.io, gpa, sandbox_default_path, true);

    // Global auto-update default — single-line `true` / `false`.
    // Default off (auto-downloading in the background = bandwidth +
    // disk surprises; user opts in). Per-game `AutoUpdateOverride.use_default`
    // consults this value; `.always` / `.never` ignore it.
    const auto_update_default_path = try std.fmt.allocPrint(gpa, "{s}/auto_update_default", .{data_root});
    defer gpa.free(auto_update_default_path);
    const initial_auto_update_default: bool = util_setting.loadBool(init.io, gpa, auto_update_default_path, false);

    const desktop_notifications_path = try std.fmt.allocPrint(gpa, "{s}/desktop_notifications", .{data_root});
    defer gpa.free(desktop_notifications_path);
    const initial_desktop_notifications: bool = util_setting.loadBool(init.io, gpa, desktop_notifications_path, true);

    // Master tag list cache path. `runMainLoop` loads its contents
    // into State on startup so the sidebar's checkbox list is
    // populated even on first paint.
    const tags_master_path = try std.fmt.allocPrint(gpa, "{s}/tags.txt", .{data_root});
    defer gpa.free(tags_master_path);

    // CPU semaphore for image decode + JPEG encode. Capped at
    // `min(cpu_count - 1, 4)` so even with 8+8 parallel workers the
    // UI thread still has CPU time. Network fetches run unthrottled.
    const cpu_count = std.Thread.getCpuCount() catch 4;
    const cpu_for_images: usize = @max(@as(usize, 1), @min(cpu_count -| 1, @as(usize, 4)));
    ui.setImageCpuLimit(cpu_for_images);
    log.info("cpu_count={d} image-decode permits={d}", .{ cpu_count, cpu_for_images });

    // Refresh-pool parallelism caps. Two independent knobs: one for
    // /full + scrape workers, one for the screenshot ImageJob pool.
    // Both clamped to [1, MAX_PARALLEL_*]; default 4.
    const max_parallel_sync_path = try std.fmt.allocPrint(gpa, "{s}/max_parallel_sync", .{data_root});
    defer gpa.free(max_parallel_sync_path);
    const initial_max_parallel_sync: u32 = std.math.clamp(
        util_setting.loadInt(u32, init.io, gpa, max_parallel_sync_path, ui.DEFAULT_PARALLEL),
        @as(u32, 1),
        @as(u32, @intCast(ui.MAX_PARALLEL_SYNC)),
    );
    const max_parallel_image_path = try std.fmt.allocPrint(gpa, "{s}/max_parallel_image", .{data_root});
    defer gpa.free(max_parallel_image_path);
    const initial_max_parallel_image: u32 = std.math.clamp(
        util_setting.loadInt(u32, init.io, gpa, max_parallel_image_path, ui.DEFAULT_PARALLEL),
        @as(u32, 1),
        @as(u32, @intCast(ui.MAX_PARALLEL_IMAGE)),
    );

    // Minimum session duration (seconds) for counts_as_played.
    // Range 0..1800; default 60. 0 = every successful launch counts.
    const min_session_seconds_path = try std.fmt.allocPrint(gpa, "{s}/min_session_seconds", .{data_root});
    defer gpa.free(min_session_seconds_path);
    const initial_min_session_seconds: u32 = std.math.clamp(
        util_setting.loadInt(u32, init.io, gpa, min_session_seconds_path, 60),
        @as(u32, 0),
        @as(u32, 1800),
    );

    // Refresh backend selector — single-line `indexer` / `scraper`.
    // Default `indexer` (F95Indexer cache at api.f95checker.dev). The
    // toggle lives in Settings → Sync; this file persists the user's
    // pick across launches.
    const refresh_backend_path = try std.fmt.allocPrint(gpa, "{s}/refresh_backend", .{data_root});
    defer gpa.free(refresh_backend_path);
    const initial_refresh_backend: ui.RefreshBackend = blk: {
        const owned = util_setting.readSingleLine(init.io, gpa, refresh_backend_path) catch null;
        if (owned) |s| {
            defer gpa.free(s);
            break :blk ui.RefreshBackend.fromStr(s);
        }
        break :blk .indexer;
    };
    log.info("refresh backend {s}", .{@tagName(initial_refresh_backend)});

    // F95Indexer client. `F95_INDEXER_URL` env override lets users
    // point at a self-hosted instance; absent → public cache.
    const indexer_base_url_env = init.minimal.environ.getAlloc(gpa, "F95_INDEXER_URL") catch null;
    defer if (indexer_base_url_env) |s| gpa.free(s);
    const indexer_base_url: []const u8 = if (indexer_base_url_env) |s| s else f95_indexer.DEFAULT_BASE_URL;
    var indexer_client = f95_indexer.Client.init(gpa, init.io, indexer_base_url);
    log.info("indexer   base_url={s} ua={s}", .{ indexer_base_url, f95_indexer.USER_AGENT });

    const ui_exe_dir = resolveExeDir(gpa, init.io, init.minimal.environ) catch try gpa.dupe(u8, ".");
    defer gpa.free(ui_exe_dir);

    // Window backend — created + owned here so the `ui` module stays
    // backend-agnostic (rebuildable against dvui's testing backend for
    // headless tests). Must outlive the window dvui builds from it.
    SDLBackend.enableSDLLogging();
    var backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .allocator = gpa,
        .size = .{ .w = 1280.0, .h = 800.0 },
        .min_size = .{ .w = 900.0, .h = 600.0 },
        .vsync = true,
        .title = "f69",
        .icon = null,
    });
    defer backend.deinit();

    try ui.runMainLoop(init, &lib, &f95_service, &indexer_client, &dl_mgr, &recipe_repo, &sandbox, &host_launcher, &convert_svc, &compat_svc, rpdl_token, .{
        .exe_dir = ui_exe_dir,
        .data_root = data_root,
        .db_path = db_path,
        .covers_dir = covers_dir,
        .library_root = library_root,
        .cookie_path = cookie_path,
        .recipes_dir = recipes_dir,
        .mod_archives_dir = mod_archives_dir,
        .mod_presets_dir = mod_presets_dir,
        .convert_presets_dir = convert_presets_dir,
        .browser_path_file = browser_choice_path,
        .browsers = browsers,
        .initial_browser_path = browser_path_buf[0 .. std.mem.indexOfScalar(u8, &browser_path_buf, 0) orelse browser_path_buf.len],
        .rate_limit_ms = rate_limit_ms,
        .rpdl_token_path = rpdl_token_path,
        .ui_scale_path = ui_scale_path,
        .initial_ui_scale = initial_ui_scale,
        .last_update_check_path = last_update_check_path,
        .initial_last_update_check_ts = initial_last_update_check_ts,
        .auto_check_path = auto_check_path,
        .lib_prefs_path = lib_prefs_path,
        .initial_lib_prefs = initial_lib_prefs,
        .initial_auto_check = initial_auto_check,
        .tags_master_path = tags_master_path,
        .aria2_port_path = aria2_port_path,
        .initial_aria2_port = initial_aria2_port,
        .aria2_seed_ratio_path = aria2_seed_ratio_path,
        .initial_aria2_seed_ratio = initial_aria2_seed_ratio,
        .aria2_seed_time_path = aria2_seed_time_path,
        .initial_aria2_seed_time = initial_aria2_seed_time,
        .auto_convert_path = auto_convert_path,
        .initial_auto_convert = initial_auto_convert,
        .auto_apply_compat_path = auto_apply_compat_path,
        .initial_auto_apply_compat = initial_auto_apply_compat,
        .sandbox_default_path = sandbox_default_path,
        .initial_sandbox_default = initial_sandbox_default,
        .auto_update_default_path = auto_update_default_path,
        .initial_auto_update_default = initial_auto_update_default,
        .desktop_notifications_path = desktop_notifications_path,
        .initial_desktop_notifications = initial_desktop_notifications,
        .refresh_backend_path = refresh_backend_path,
        .initial_refresh_backend = initial_refresh_backend,
        .max_parallel_sync_path = max_parallel_sync_path,
        .initial_max_parallel_sync = initial_max_parallel_sync,
        .max_parallel_image_path = max_parallel_image_path,
        .initial_max_parallel_image = initial_max_parallel_image,
        .min_session_seconds_path = min_session_seconds_path,
        .initial_min_session_seconds = initial_min_session_seconds,
        .host = host,
    }, &backend);
}

/// Parse `<data_root>/auto_check`. Format is `key=value` per line.
/// Recognized keys: `on_startup`, `interval_enabled` (both
/// `true`/`false`), `interval_count` (integer 1..999),
/// `interval_unit` (`minutes`/`hours`/`days`). Unknown keys ignored;
/// missing file or unparseable values fall back to defaults.
fn loadAutoCheck(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !ui.AutoCheckSettings {
    var out: ui.AutoCheckSettings = .{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512)) catch |e| {
        if (e == error.FileNotFound) return out;
        return e;
    };
    defer gpa.free(bytes);
    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "on_startup")) {
            out.on_startup = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "interval_enabled")) {
            out.interval_enabled = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "interval_count")) {
            const n = std.fmt.parseInt(u32, val, 10) catch continue;
            out.interval_count = std.math.clamp(n, 1, 999);
        } else if (std.mem.eql(u8, key, "interval_unit")) {
            if (std.mem.eql(u8, val, "minutes")) out.interval_unit = .minutes;
            if (std.mem.eql(u8, val, "hours")) out.interval_unit = .hours;
            if (std.mem.eql(u8, val, "days")) out.interval_unit = .days;
        }
    }
    return out;
}

/// One entry in the "Browser:" dropdown. We mirror `ui.Browser`'s
/// shape (display + path) but path is mutable here because we own it.
const BrowserCandidate = struct {
    display: []const u8,
    exe: []const u8,
};

/// Common Linux browsers we know how to launch URLs through. `xdg-open`
/// always lands first if present so the system default works without
/// any configuration.
const BROWSER_CANDIDATES = [_]BrowserCandidate{
    .{ .display = "System default (xdg-open)", .exe = "xdg-open" },
    .{ .display = "Firefox", .exe = "firefox" },
    .{ .display = "LibreWolf", .exe = "librewolf" },
    .{ .display = "Waterfox", .exe = "waterfox" },
    .{ .display = "Chromium", .exe = "chromium" },
    .{ .display = "Google Chrome", .exe = "google-chrome-stable" },
    .{ .display = "Google Chrome", .exe = "google-chrome" },
    .{ .display = "Brave", .exe = "brave" },
    .{ .display = "Brave", .exe = "brave-browser" },
    .{ .display = "Vivaldi", .exe = "vivaldi-stable" },
    .{ .display = "Vivaldi", .exe = "vivaldi" },
    .{ .display = "Opera", .exe = "opera" },
    .{ .display = "Microsoft Edge", .exe = "microsoft-edge-stable" },
    .{ .display = "Microsoft Edge", .exe = "microsoft-edge" },
};

/// Walk `$PATH` looking for known browser executables. Returns a slice
/// of the ones present, deduplicated by canonical path. Caller frees
/// via `freeBrowsers`.
fn detectBrowsers(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ) ![]ui.Browser {
    const path_env = environ.getAlloc(gpa, "PATH") catch return &.{};
    defer gpa.free(path_env);

    var out: std.ArrayList(ui.Browser) = .empty;
    // Don't use `out.toOwnedSlice` inside the errdefer — it allocates,
    // and the path we're cleaning up via errdefer is the OOM path that
    // brought us here. Walk the items directly so cleanup itself never
    // touches the allocator after the failure.
    errdefer {
        // `display` is a comptime literal from BROWSER_CANDIDATES;
        // only `path` is alloc'd (see `freeBrowsers`). Don't use
        // `out.toOwnedSlice` here — that allocates, and we're already
        // unwinding the OOM path that brought us here.
        for (out.items) |b| gpa.free(b.path);
        out.deinit(gpa);
    }

    candidates: for (BROWSER_CANDIDATES) |c| {
        var dir_iter = std.mem.tokenizeScalar(u8, path_env, ':');
        while (dir_iter.next()) |dir| {
            var path_buf: [512]u8 = undefined;
            const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, c.exe }) catch continue;
            std.Io.Dir.cwd().access(io, full, .{ .execute = true }) catch continue;
            // Dedupe — `/usr/bin/firefox` and `/usr/local/bin/firefox` etc.
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing.path, full)) continue :candidates;
            }
            const path_owned = try gpa.dupe(u8, full);
            try out.append(gpa, .{ .display = c.display, .path = path_owned });
            continue :candidates; // first hit per candidate is good enough
        }
    }
    return out.toOwnedSlice(gpa);
}

fn freeBrowsers(gpa: std.mem.Allocator, browsers: []ui.Browser) void {
    for (browsers) |b| gpa.free(@constCast(b.path));
    if (browsers.len > 0) gpa.free(browsers);
}

/// Bundle root for every `<exe_dir>/<thing>` lookup (aria2c, data,
/// future bundled binaries). Two tiers, in priority order:
///
///   1. `$F69_EXE_DIR` — set by `run.sh` to the bundle dir. This
///      exists because `run.sh` execs the bundled loader directly
///      (`exec lib/ld-linux-x86-64.so.2 ./f69 …`), which makes
///      `/proc/self/exe` resolve to the loader inside `lib/` — not
///      to the f69 binary. The env var sidesteps that ambiguity.
///   2. `dirname(/proc/self/exe)` — for direct `./f69` launches
///      (dev shells, `zig build run`, system installs where
///      `f69` is symlinked from `/usr/bin`).
///
/// Caller frees.
fn resolveExeDir(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ) ![]u8 {
    if (environ.getAlloc(gpa, "F69_EXE_DIR")) |x| return x else |_| {}

    var link_buf: [4096]u8 = undefined;
    const n = try std.Io.Dir.cwd().readLink(io, "/proc/self/exe", &link_buf);
    const exe_path = link_buf[0..n];
    const dir = std.fs.path.dirname(exe_path) orelse return error.NoExeDir;
    return gpa.dupe(u8, dir);
}

/// **Portable mode** — resolve the directory where the f69 executable
/// lives and put all our data under `<exe_dir>/data/`. Override the
/// whole thing with the `F69_DATA_DIR` env var. Caller frees.
///
/// Resolve where DB / library / covers / recipes / downloads live.
/// Three tiers:
///
///   1. `$F69_DATA_DIR` — explicit user override. Always wins.
///      Portable launchers (`run.sh`) set this to `<bundle>/data/`.
///
///   2. **Portable install** — binary lives in a user-writable location
///      (anywhere outside `/usr/`, `/nix/store/`, `/opt/`). Data goes
///      to `<dir-of-binary>/data/`, so a portable bundle on a USB stick
///      carries its state with it.
///
///   3. **System install** — binary lives in `/usr/bin/`, `/nix/store/...`,
///      or `/opt/...`. Those locations are read-only for the user. Data
///      goes to `$XDG_DATA_HOME/f69` (default `~/.local/share/f69`).
///
/// Read /proc/self/exe to find the binary's dir. Falls back to `./data`
/// (cwd-relative) on the rare Linux setup where /proc isn't mounted.
fn resolveDataRoot(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ) ![]u8 {
    // Tier 1: explicit override.
    if (environ.getAlloc(gpa, "F69_DATA_DIR")) |x| return x else |_| {}

    // Windows: roaming app data at %APPDATA%\f69 — the platform convention, and independent of
    // exe-dir resolution (which can fail when launched from a UNC/redirected path).
    if (builtin.os.tag == .windows) {
        if (environ.getAlloc(gpa, "APPDATA")) |appdata| {
            defer gpa.free(appdata);
            return std.fmt.allocPrint(gpa, "{s}/f69", .{appdata});
        } else |_| {}
    }

    const exe_dir = resolveExeDir(gpa, io, environ) catch {
        log.warn("resolveDataRoot: exe dir undeterminable; falling back to ./data", .{});
        return gpa.dupe(u8, "./data");
    };
    defer gpa.free(exe_dir);

    // Tier 3 first (cheap test): system install → XDG user dir.
    const is_system_install = std.mem.startsWith(u8, exe_dir, "/usr/") or
        std.mem.startsWith(u8, exe_dir, "/nix/store/") or
        std.mem.startsWith(u8, exe_dir, "/opt/");
    if (is_system_install) {
        if (environ.getAlloc(gpa, "XDG_DATA_HOME")) |xdg| {
            defer gpa.free(xdg);
            return std.fmt.allocPrint(gpa, "{s}/f69", .{xdg});
        } else |_| {}
        if (environ.getAlloc(gpa, "HOME")) |home| {
            defer gpa.free(home);
            return std.fmt.allocPrint(gpa, "{s}/.local/share/f69", .{home});
        } else |_| {}
        log.warn("resolveDataRoot: system install but no $HOME / $XDG_DATA_HOME; falling back to ./data", .{});
        return gpa.dupe(u8, "./data");
    }

    // Tier 2: portable install — keep data next to the binary.
    return std.fmt.allocPrint(gpa, "{s}/data", .{exe_dir});
}

/// Prefer `<exe_dir>/aria2c` (bundled into the portable build by
/// `zig build portable`); fall back to bare `"aria2c"` so the OS does
/// a `$PATH` lookup on system installs / dev shells. Caller frees.
///
/// Returns the literal `"aria2c"` (not a `<exe_dir>/aria2c` path) on
/// every failure path so we never hand `Manager.init` a stale absolute
/// path that doesn't resolve.
fn resolveAria2Path(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ) ![]u8 {
    const exe_dir = resolveExeDir(gpa, io, environ) catch return gpa.dupe(u8, "aria2c");
    defer gpa.free(exe_dir);
    const candidate = try std.fmt.allocPrint(gpa, "{s}/aria2c", .{exe_dir});
    std.Io.Dir.cwd().access(io, candidate, .{}) catch {
        gpa.free(candidate);
        return gpa.dupe(u8, "aria2c");
    };
    log.info("aria2c: using bundled binary at {s}", .{candidate});
    return candidate;
}

/// Remove orphan `*.tmp` cover files left by a prior run that crashed
/// or was Ctrl+C'd mid-write (see ui.fetchAndWriteCover's atomic
/// tmp+rename). Best-effort.
const BACKUP_INTERVAL_S: i64 = 24 * 60 * 60; // one snapshot per day
const BACKUP_KEEP: usize = 10;

/// Parse `f69-<epoch>.db` → the epoch seconds; null for anything else.
fn parseBackupEpoch(name: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, name, "f69-")) return null;
    if (!std.mem.endsWith(u8, name, ".db")) return null;
    const mid = name["f69-".len .. name.len - ".db".len];
    if (mid.len == 0) return null;
    return std.fmt.parseInt(i64, mid, 10) catch null;
}

/// Startup DB backup: snapshot to `<data_root>/backups/f69-<now>.db` when the
/// newest existing snapshot is older than `BACKUP_INTERVAL_S`, then prune to
/// the newest `BACKUP_KEEP`. Best-effort: any failure logs and returns.
fn maybeBackupDb(io: std.Io, gpa: std.mem.Allocator, lib: *library.Library, data_root: []const u8) void {
    const dir_path = std.fmt.allocPrint(gpa, "{s}/backups", .{data_root}) catch return;
    defer gpa.free(dir_path);
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |e| {
        log.warn("db backup: mkdir {s} failed: {s}", .{ dir_path, @errorName(e) });
        return;
    };
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var epochs: std.ArrayList(i64) = .empty;
    defer epochs.deinit(gpa);
    var newest: i64 = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const ep = parseBackupEpoch(entry.name) orelse continue;
        epochs.append(gpa, ep) catch continue;
        if (ep > newest) newest = ep;
    }

    const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
    if (newest != 0 and now - newest < BACKUP_INTERVAL_S) return; // not due yet

    const dest = std.fmt.allocPrint(gpa, "{s}/f69-{d}.db", .{ dir_path, now }) catch return;
    defer gpa.free(dest);
    lib.backupTo(gpa, dest) catch |e| {
        log.warn("db backup: VACUUM INTO {s} failed: {s}", .{ dest, @errorName(e) });
        return;
    };
    log.info("db backup -> {s}", .{dest});
    epochs.append(gpa, now) catch {};

    if (epochs.items.len > BACKUP_KEEP) {
        std.mem.sort(i64, epochs.items, {}, std.sort.asc(i64));
        const drop = epochs.items.len - BACKUP_KEEP;
        for (epochs.items[0..drop]) |ep| {
            var nb: [64]u8 = undefined;
            const nm = std.fmt.bufPrint(&nb, "f69-{d}.db", .{ep}) catch continue;
            dir.deleteFile(io, nm) catch {};
        }
    }
}

test "parseBackupEpoch" {
    try std.testing.expectEqual(@as(?i64, 1700000000), parseBackupEpoch("f69-1700000000.db"));
    try std.testing.expectEqual(@as(?i64, null), parseBackupEpoch("f69.db"));
    try std.testing.expectEqual(@as(?i64, null), parseBackupEpoch("other-123.db"));
    try std.testing.expectEqual(@as(?i64, null), parseBackupEpoch("f69-abc.db"));
    try std.testing.expectEqual(@as(?i64, null), parseBackupEpoch("f69-123.txt"));
}

fn sweepTmpCovers(io: std.Io, covers_dir: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, covers_dir, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tmp")) continue;
        dir.deleteFile(io, entry.name) catch {};
    }
}

/// Read the stored F95 cookie if present. Caller frees the returned
/// slice. Returns `null` (not an error) when the file is absent.
fn loadCookie(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024)) catch |e| {
        if (e == error.FileNotFound) return null;
        return e;
    };
    // The file may have a trailing newline from a hand-edited save.
    // Strip whitespace before handing to the client.
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) {
        gpa.free(bytes);
        return null;
    }
    if (trimmed.len == bytes.len) return bytes;
    const dup = try gpa.dupe(u8, trimmed);
    gpa.free(bytes);
    return dup;
}
