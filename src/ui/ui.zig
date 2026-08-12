// dvui main loop and screen dispatcher.
//
// File layout for the ui module:
//
//   ui/state.zig     persistent UI state (Filters, View, Sort, etc.)
//   ui/types.zig     Frame, RuntimeInfo, theme, ascii/time helpers
//   ui/actions.zig   pure re-export wall over actions/*.zig (post-R9)
//   ui/actions/*.zig per-domain action code (sync, downloads, installer,
//                    launch, bookmarks, auth, mods, tags, imports, common)
//   ui/screens.zig   per-screen entry-point wall over screens/*.zig
//   ui/screens/*.zig per-screen render code (post-R8 split)
//   ui/ui.zig        this file: runMainLoop + guiFrame dispatcher
//
// `state.zig` and `types.zig` are leaves; the `actions/*` modules
// import `types.zig`; `screens.zig` imports `types.zig` + `actions.zig`;
// `ui.zig` imports everything. No cycles.

const std = @import("std");
const library = @import("library");
const f95 = @import("f95");
const f95_indexer = @import("f95_indexer");
const downloads = @import("downloads");
const recipe = @import("recipe");
const sandbox = @import("sandbox");
const convert = @import("convert");
const compat = @import("compat");
const dvui = @import("dvui");

const state_mod = @import("state.zig");
const types = @import("types.zig");
const actions = @import("actions.zig");
const screens = @import("screens.zig");
const mod_job_queue = @import("mod_job_queue.zig");
const fonts = @import("fonts.zig");

// Test discovery — pull in nested files' test {} blocks (Zig 0.16
// doesn't walk transitive imports for tests).
test {
    _ = actions;
    _ = types;
    _ = state_mod;
}

pub const State = state_mod.State;
pub const AutoCheckSettings = state_mod.AutoCheckSettings;
pub const AutoCheckUnit = state_mod.AutoCheckUnit;
pub const RefreshBackend = state_mod.RefreshBackend;
pub const UpdateCheckSource = state_mod.UpdateCheckSource;
pub const MAX_PARALLEL_SYNC = state_mod.MAX_PARALLEL_SYNC;
pub const MAX_PARALLEL_IMAGE = state_mod.MAX_PARALLEL_IMAGE;
pub const DEFAULT_PARALLEL = state_mod.DEFAULT_PARALLEL;
pub const setImageCpuLimit = actions.setImageCpuLimit;
// Re-exports for the headless integration harness (src/testkit/). These
// let the Layer-1 test driver reach the action layer + Frame deps
// without the harness having to know ui-internal module layout. See
// docs/test-automation-research.md.
pub const persistUiScaleIfDirty = actions.persistUiScaleIfDirty;
pub const Filters = state_mod.Filters;
pub const Screen = state_mod.Screen;
pub const startSyncAll = actions.startSyncAll;
pub const syncGame = actions.syncGame;
pub const doLogin = actions.doLogin;
pub const doFolderScan = actions.doFolderScan;
pub const findLinuxLauncher = actions.findLinuxLauncher;
pub const findWindowsLauncher = actions.findWindowsLauncher;
pub const findLauncher = actions.findLauncher;
pub const doLogout = actions.doLogout;
pub const commitFolderImport = actions.commitFolderImport;
pub const doOpenLogsFolder = actions.doOpenLogsFolder;
/// External-open recording seam, for flow tests that click "Open folder".
pub const external_open_hook = @import("actions/common.zig").external_open_hook;
pub const tickFolderScan = actions.tickFolderScan;
pub const folderScanRowStates = actions.folderScanRowStates;
pub const FolderImportLinkState = state_mod.FolderImportLinkState;
/// Register the bundled Design-B fonts onto a dvui window (Layer-2 GUI
/// tests need this before rendering, just like runMainLoop does, else the
/// theme's font families log "not in dvui database" errors).
pub fn registerBundledFonts(win: *dvui.Window) void {
    fonts.registerBundled(win);
}
/// Headless test harness — builds the full service graph + a Frame on a
/// caller-supplied dvui testing window. See src/ui/test_harness.zig.
pub const Harness = @import("test_harness.zig").Harness;
/// Exposed for the test harness's widget census (style.widgets_built /
/// widgets_tagged) — see the layer2b tests in src/testkit/integration.zig.
pub const style = @import("style.zig");
pub const Frame = types.Frame;
pub const RuntimeInfo = types.RuntimeInfo;
pub const Browser = types.Browser;

pub fn runMainLoop(
    init: std.process.Init,
    lib: *library.Library,
    f95_svc: *f95.Service,
    f95_indexer_client: *f95_indexer.Client,
    dl_mgr: *downloads.Manager,
    recipe_repo: *recipe.Repo,
    sandbox_backend: *sandbox.Sandbox,
    host_launcher: *sandbox.NoSandbox,
    convert_svc: *convert.Service,
    compat_svc: *compat.Service,
    initial_rpdl_token: ?[]const u8,
    info: RuntimeInfo,
    // The windowing backend is created + owned by the caller. The GUI
    // entry point (main) builds an SDL3-GPU backend and passes it here;
    // the headless test harness never calls this loop (it drives the
    // action layer directly), so the SDL-specific backend methods below
    // are only ever instantiated against the real SDL backend.
    backend: anytype,
) !void {
    const io = init.io;
    const gpa = init.gpa;

    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{
        .theme = types.consoleTheme(backend.preferredColorScheme() orelse .dark),
    });
    defer win.deinit();
    // dvui folds `content_scale` into its layout math so scaling here
    // is a single knob for the whole app. The initial value comes from
    // disk (`<data_root>/ui_scale`); the Settings slider updates
    // `state.ui_scale`, which the main loop pushes back into
    // `win.content_scale` every frame so changes take effect live.
    win.content_scale = info.initial_ui_scale;

    // Bundled nerd fonts + user-dropped ones from `<exe_dir>/fonts/`.
    // Register before the first frame so the theme below resolves
    // them by family name. Default body/heading flips to JetBrainsMono
    // Nerd Font so the whole UI inherits the broader glyph coverage
    // (replaces the Latin-only default that rendered ✓ / ⚠ / 📁 as
    // empty boxes).
    fonts.registerBundled(&win);
    fonts.scanUserFonts(&win, gpa, init.io, info.exe_dir);
    // dvui's Theme exposes four font slots: body, heading, title, mono.
    // Design B: body/caption → IBM Plex Sans, heading/title → Archivo,
    // mono → IBM Plex Mono.
    applyDesignBFonts(&win.theme);

    // Library snapshot — held by runMainLoop, reloaded when the
    // importer or delete sets `state.reload_requested`.
    var games = try lib.listGames();
    defer lib.freeGames(games);

    // Warm the OS page cache for the first screen-worth of cover thumbs
    // so the first library frame doesn't wait on cold reads. The rest
    // load on demand off the UI thread (`spawnCoverLoadIfRoom`).
    actions.spawnCoverPrewarm(gpa, io, info.covers_dir, games, state_mod.COVER_PREWARM);

    // Mod install/uninstall queue + worker. Long-lived: spans the
    // app's lifetime so jobs survive screen navigation and the worker
    // stays warm between clicks.
    var mod_jobs_ctx = actions.RunnerCtx{ .alloc = gpa, .io = io, .lib = lib, .repo = recipe_repo, .temp_root = info.staging_dir };
    var mod_jobs = mod_job_queue.Queue.init(gpa, io, &win, actions.modJobRunner, &mod_jobs_ctx);
    defer mod_jobs.deinit();

    const mod_queue_path = try std.fmt.allocPrint(gpa, "{s}/mod-queue.json", .{info.data_root});
    defer gpa.free(mod_queue_path);
    try mod_jobs.setPersistPath(mod_queue_path);

    // Recovery: if the app died mid-install, the queue file holds the
    // job descriptions. For each "was running" entry, roll back what
    // the partial tracker recorded, then re-enqueue the install. The
    // periodic flush in ApplyOpts means the tracker has at most
    // `flush_every` orphans the rollback can't see.
    actions.recoverModJobsFromDisk(&mod_jobs, lib, gpa, io) catch |e| {
        std.log.warn("mod queue recovery failed: {s}", .{@errorName(e)});
    };

    try mod_jobs.start();

    var state: State = .{};
    state.login_status = if (f95_svc.client.hasCookie()) .logged_in else .logged_out;
    // Dev/test convenience: boot straight onto a screen (+thread) for the
    // local headless screenshot harness (scripts/localshot.sh). No-op unless
    // F69_OPEN_SCREEN is set.
    if (std.c.getenv("F69_OPEN_SCREEN")) |sc_z| {
        const sc = std.mem.span(sc_z);
        if (std.mem.eql(u8, sc, "detail")) {
            state.screen = .detail;
        } else if (std.mem.eql(u8, sc, "settings")) {
            state.screen = .settings;
        } else if (std.mem.eql(u8, sc, "downloads")) {
            state.screen = .downloads;
        } else if (std.mem.eql(u8, sc, "mods")) {
            state.screen = .universal_mods;
        }
        if (std.c.getenv("F69_OPEN_THREAD")) |tid_z| {
            state.selected_thread = std.fmt.parseInt(u64, std.mem.span(tid_z), 10) catch null;
        }
        if (std.c.getenv("F69_DOCK_OPEN") != null) state.dock_expanded = true;
        if (state.selected_thread) |tid| state.detail_state_for_thread = tid; // don't reset the boot tab
        if (std.c.getenv("F69_OPEN_TAB")) |tab_z| {
            const tb = std.mem.span(tab_z);
            if (std.mem.eql(u8, tb, "tools")) state.detail_tab = .tools;
        }
    }
    state.setBrowserPath(info.initial_browser_path);
    state.ui_scale = info.initial_ui_scale;
    state.ui_scale_persisted = info.initial_ui_scale;
    state.last_update_check_ts = info.initial_last_update_check_ts;
    state.auto_check = info.initial_auto_check;
    state.auto_check_persisted = info.initial_auto_check;
    actions.applyLibPrefs(&state, info.initial_lib_prefs);
    actions.seedLibPrefsMirror(&state);
    state.aria2_port_persisted = info.initial_aria2_port;
    state.auto_convert = info.initial_auto_convert;
    state.auto_convert_persisted = info.initial_auto_convert;
    state.auto_apply_compat = info.initial_auto_apply_compat;
    state.auto_apply_compat_persisted = info.initial_auto_apply_compat;
    state.sandbox_default = info.initial_sandbox_default;
    state.sandbox_default_persisted = info.initial_sandbox_default;
    state.auto_update_default = info.initial_auto_update_default;
    state.auto_update_default_persisted = info.initial_auto_update_default;
    state.desktop_notifications = info.initial_desktop_notifications;
    state.desktop_notifications_persisted = info.initial_desktop_notifications;
    state.refresh_backend = info.initial_refresh_backend;
    state.refresh_backend_persisted = info.initial_refresh_backend;
    state.update_check_source = info.initial_update_check_source;
    state.update_check_source_persisted = info.initial_update_check_source;
    state.max_parallel_sync = info.initial_max_parallel_sync;
    state.max_parallel_sync_persisted = info.initial_max_parallel_sync;
    state.max_parallel_image = info.initial_max_parallel_image;
    state.max_parallel_image_persisted = info.initial_max_parallel_image;
    // Seed the textEntry buffers so the Sync tab renders the saved
    // values on first paint rather than empty fields.
    _ = std.fmt.bufPrint(&state.max_parallel_sync_buf, "{d}", .{state.max_parallel_sync}) catch state.max_parallel_sync_buf[0..0];
    _ = std.fmt.bufPrint(&state.max_parallel_image_buf, "{d}", .{state.max_parallel_image}) catch state.max_parallel_image_buf[0..0];
    state.min_session_seconds = info.initial_min_session_seconds;
    state.min_session_seconds_persisted = info.initial_min_session_seconds;
    _ = std.fmt.bufPrint(&state.min_session_seconds_buf, "{d}", .{state.min_session_seconds}) catch state.min_session_seconds_buf[0..0];
    // Seed the textEntry buffer with the persisted port (or empty for
    // the "random ephemeral" sentinel). Leaving 0 blank reduces clutter.
    if (info.initial_aria2_port != 0) {
        const port_slice = std.fmt.bufPrint(&state.aria2_port_buf, "{d}", .{info.initial_aria2_port}) catch state.aria2_port_buf[0..0];
        _ = port_slice;
    }
    state.aria2_seed_ratio_persisted = info.initial_aria2_seed_ratio;
    {
        const sr_slice = std.fmt.bufPrint(&state.aria2_seed_ratio_buf, "{d:.1}", .{info.initial_aria2_seed_ratio}) catch state.aria2_seed_ratio_buf[0..0];
        _ = sr_slice;
    }
    state.aria2_seed_time_persisted = info.initial_aria2_seed_time;
    {
        const st_slice = std.fmt.bufPrint(&state.aria2_seed_time_buf, "{d}", .{info.initial_aria2_seed_time}) catch state.aria2_seed_time_buf[0..0];
        _ = st_slice;
    }

    // Master tag list — disk first, embedded build-time snapshot as
    // first-run fallback. The user's Refresh button in Settings →
    // Library overwrites the disk copy; after that, disk always wins.
    if (f95.tags.loadOrSeed(lib.alloc, io, info.tags_master_path)) |cached| {
        state.tags_master = cached.tags;
        state.tags_master_fetched_at = cached.fetched_at;
        std.log.info("tags: loaded {d} (fetched_at={d})", .{ cached.tags.len, cached.fetched_at });
    } else |e| {
        std.log.warn("tags load failed: {s}", .{@errorName(e)});
    }
    if (initial_rpdl_token) |t| {
        state.rpdl_token = try lib.alloc.dupe(u8, t);
        state.rpdl_status = .logged_in;
    } else {
        state.rpdl_status = .logged_out;
    }
    // No startup modal — the Accounts popup is opened on demand from the
    // toolbar account button (see library.zig). The donor-status probe still
    // runs once at startup below when an F95 cookie is already present so the
    // Download button's enabled-state is correct before the user clicks.
    defer {
        // Modfile cache + clash modal both own heap state — release
        // them on shutdown so DebugAllocator doesn't flag leaks.
        // Wizard state is inline on State (no heap).
        actions.freeModfileCacheState(&state, lib.alloc);
        actions.freeClashModalState(&state, lib.alloc);
        actions.freeCoverLoads(&state, lib.alloc);
        actions.freeCoverCache(&state, lib.alloc);
        actions.freeLibFilterCache(&state, lib.alloc);
        actions.freeSnapshotCache(&state, lib.alloc);
        actions.freeSlideCache(&state, lib.alloc);
        actions.invalidatePresetCache(&state);
        actions.freeTestInstallJob(&state, io);
        actions.freeThumbCache(&state, lib.alloc);
        actions.freePostInstalled(&state, lib.alloc);
        actions.freeInstalledSet(&state, lib.alloc);
        actions.freePostInstallJobs(&state, lib.alloc);
        actions.freeManualInstallJobs(&state, lib.alloc);
        actions.freeFolderScan(&state, lib, io);
        actions.freeF95Review(&state, lib.alloc);
        // Tear down NFDe if the user ever opened the file picker.
        // No-op when never used.
        @import("util_file_picker").deinit();
        actions.freeSyncRecap(&state, lib.alloc);
        actions.freeDonorTables(&state, lib.alloc);
        actions.freeTagsMaster(lib.alloc, &state);
        if (state.sync_queue) |q| lib.alloc.free(q);
        if (state.rpdl_token) |t| lib.alloc.free(t);
        if (state.tag_colors) |*m| library.Library.freeTagColors(m);
    }

    // Wire the download poller's UI wake-up: when the background aria2 poller
    // refreshes job progress it schedules a re-render via dvui.refresh. `&win`
    // is stable for the loop's lifetime; the poller is stopped (stopPoller)
    // before the window is torn down.
    dl_mgr.setWake(&win, wakeDownloadUi);

    var interrupted = false;
    main_loop: while (true) {
        if (state.reload_requested) {
            lib.freeGames(games);
            games = try lib.listGames();
            state.reload_requested = false;
            // Force re-sort after reload — clear both halves.
            state.sort_applied_column = null;
            state.sort_applied_dir = null;
            // Reload after import/delete — re-warm in case the new
            // games already have covers on disk from a previous sync.
            actions.spawnCoverPrewarm(gpa, io, info.covers_dir, games, state_mod.COVER_PREWARM);
        }

        // Live UI scale: state.ui_scale is the source of truth; push
        // it into the dvui window each frame so the Settings slider
        // takes effect immediately. The persist step (writing the new
        // value to disk) runs from `actions.persistUiScaleIfDirty`
        // once the user pauses on a value.
        win.content_scale = state.ui_scale;
        actions.persistUiScaleIfDirty(&state, info.ui_scale_path, io);
        actions.persistAutoCheckIfDirty(&state, info.auto_check_path, io);
        actions.persistLibPrefsIfDirty(&state, info.lib_prefs_path, io);
        actions.persistAutoConvertIfDirty(&state, info.auto_convert_path, io);
        actions.persistAutoApplyCompatIfDirty(&state, info.auto_apply_compat_path, io);
        actions.persistSandboxDefaultIfDirty(&state, info.sandbox_default_path, io);
        actions.persistAutoUpdateDefaultIfDirty(&state, info.auto_update_default_path, io);
        actions.persistDesktopNotificationsIfDirty(&state, info.desktop_notifications_path, io);
        actions.persistRefreshBackendIfDirty(&state, info.refresh_backend_path, io);
        actions.persistUpdateCheckSourceIfDirty(&state, info.update_check_source_path, io);
        actions.persistMaxParallelSyncIfDirty(&state, info.max_parallel_sync_path, io);
        actions.persistMaxParallelImageIfDirty(&state, info.max_parallel_image_path, io);
        actions.persistMinSessionSecondsIfDirty(&state, info.min_session_seconds_path, io);
        // Age + evict expired toasts each frame. info/success fade
        // around 3s, warn around 6s, err sticks until clicked.
        state.ageToasts();

        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        // `addAllEvents` returns true on SDL_QUIT or window-close-
        // requested. SDL3 converts SIGINT and SIGTERM into SDL_QUIT
        // automatically, so this is also the path Ctrl+C and the
        // compositor's "kill window" signal (e.g. niri's Super-Q)
        // come through.
        const should_quit = try backend.addAllEvents(&win);
        if (should_quit) {
            std.log.info("quit signal received, shutting down", .{});
            // Stop the download poller before any teardown — it touches the
            // window (wake-up), the daemon, and the jobs map.
            dl_mgr.stopPoller();
            // End this frame cleanly first.
            _ = try win.end(.{});

            // Graceful shutdown: signal cancel on every detached
            // worker, then spin a small drain loop so they hit a
            // phase boundary and report back. Without this, an
            // in-flight HTTP fetch leaves a connection in
            // `http.Client.connection_pool.used`, which makes
            // `f95.Client.deinit` skip its http teardown and leak.
            actions.cancelAllWorkers(&state);
            // The mod-job queue lives on the frame, not State, so
            // cancelAllWorkers can't reach it — signal cancel on every
            // queued/running mod job here so the drain loop can retire them.
            mod_jobs.lock();
            for (mod_jobs.jobsLocked()) |mj| mj.cancel_flag.store(true, .release);
            mod_jobs.unlock();
            var shutdown_frame: Frame = .{
                .state = &state,
                .games = games,
                .lib = lib,
                .f95_svc = f95_svc,
                .f95_indexer_client = f95_indexer_client,
                .dl_mgr = dl_mgr,
                .recipe_repo = recipe_repo,
                .sandbox = sandbox_backend,
                .host_launcher = host_launcher,
                .convert_svc = convert_svc,
                .compat_svc = compat_svc,
                .win = &win,
                .io = io,
                .mod_jobs = &mod_jobs,
                .info = info,
            };
            // Wait up to ~6 seconds. The forum rate-limit is 1.5 s
            // per request, so a worker that's mid-sleep needs at
            // least one full rate-limit cycle to come out and notice
            // the cancel. 5–6 s comfortably covers a couple cycles.
            var spin: u32 = 0;
            const SHUTDOWN_DRAIN_TICKS: u32 = 120; // × 50ms = 6 s
            while (actions.workersBusy(&state) and spin < SHUTDOWN_DRAIN_TICKS) : (spin += 1) {
                actions.drainSync(&shutdown_frame);
                actions.drainFastCheck(&shutdown_frame);
                actions.drainImageQueue(&shutdown_frame);
                actions.drainBookmarks(&shutdown_frame);
                actions.drainUpdateCheck(&shutdown_frame);
                actions.drainDonorProbe(&shutdown_frame);
                actions.drainSlideLoads(&shutdown_frame);
                actions.drainCoverLoads(&shutdown_frame);
                actions.drainLaunchWatcher(&shutdown_frame);
                actions.drainPostInstall(&shutdown_frame);
                actions.drainManualInstall(&shutdown_frame);
                actions.drainTestInstall(&shutdown_frame);
                // These three were missing: `workersBusy` counts import /
                // folder-import / mod jobs, but without draining them their
                // slots never clear, so quitting mid-import always burned
                // the full 6 s then hard-exited — and a finished Move-mode
                // folder import never ran onFolderImportDone, orphaning the
                // moved files with no install row. Draining lets them retire.
                actions.drainImport(&shutdown_frame);
                actions.drainFolderImport(&shutdown_frame);
                actions.drainModJobs(&shutdown_frame);
                io.sleep(std.Io.Duration.fromMilliseconds(50), .real) catch {};
            }
            if (actions.workersBusy(&state)) {
                // A worker is still running and we've run out of patience.
                // Letting `main`'s defers run from here would tear down
                // `init.io` / `f95_client.http` / `gpa` while the worker
                // thread is still touching them → segfault and a flood
                // of DebugAllocator leak reports. Hard-exit instead: the
                // OS reclaims every resource the worker holds, no
                // defers run, no use-after-free is possible.
                std.log.warn(
                    "shutdown timeout: workers still busy after {d}s, hard-exiting (skipping deinits)",
                    .{SHUTDOWN_DRAIN_TICKS / 20},
                );
                std.process.exit(0);
            }
            std.log.info("all workers drained cleanly", .{});
            break :main_loop;
        }

        var frame: Frame = .{
            .state = &state,
            .games = games,
            .lib = lib,
            .f95_svc = f95_svc,
            .f95_indexer_client = f95_indexer_client,
            .dl_mgr = dl_mgr,
            .recipe_repo = recipe_repo,
            .sandbox = sandbox_backend,
            .host_launcher = host_launcher,
            .convert_svc = convert_svc,
            .compat_svc = compat_svc,
            .win = &win,
            .io = io,
            .mod_jobs = &mod_jobs,
            .info = info,
        };
        // Auto-update-check: fires once at startup (if enabled) and
        // on a recurring interval. Gated on workers being idle so we
        // don't race a bookmark import.
        actions.maybeAutoUpdateCheck(&frame);
        const pf_build0 = perfNowNs(io);
        if (!try guiFrame(&frame)) break :main_loop;
        const pf_build1 = perfNowNs(io);

        const end_micros = try win.end(.{});
        const pf_gpu1 = perfNowNs(io);
        dumpTags(&win);
        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());
        const pf_present0 = perfNowNs(io);
        try backend.renderPresent();
        const pf_present1 = perfNowNs(io);
        perfFrame(
            io,
            @intCast(@divTrunc(pf_build1 - pf_build0, 1000)),
            @intCast(@divTrunc(pf_gpu1 - pf_build1, 1000)),
            @intCast(@divTrunc(pf_present1 - pf_present0, 1000)),
        );

        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }
}

// --- live widget-tag dump (F69_TAG_DUMP=<path>) ----------------------------
// When the env var is set, write every tagged widget's physical-pixel rect to
// the file each frame: "name<TAB>x<TAB>y<TAB>w<TAB>h<TAB>visible". An external
// GUI driver (VM screenshot + dotool) resolves a widget by tag name to an exact
// screen coordinate instead of eyeballing a screenshot. Off (one getenv) unless
// the var is present, so zero cost in normal runs. Uses libc (the app links it).
var g_tag_dump_checked: bool = false;
var g_tag_dump_path: ?[*:0]const u8 = null;

fn dumpTags(win: *dvui.Window) void {
    if (!g_tag_dump_checked) {
        g_tag_dump_checked = true;
        g_tag_dump_path = std.c.getenv("F69_TAG_DUMP");
    }
    const path = g_tag_dump_path orelse return;
    const f = std.c.fopen(path, "w") orelse return;
    defer _ = std.c.fclose(f);
    {
        // Framebuffer size first, so the driver can map physical rects → screen.
        const wp = win.rect_pixels;
        var hbuf: [128]u8 = undefined;
        const hline = std.fmt.bufPrint(&hbuf, "__window\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t1\n", .{ wp.x, wp.y, wp.w, wp.h }) catch return;
        _ = std.c.fwrite(hline.ptr, 1, hline.len, f);
    }
    var it = win.tags.iterator();
    while (it.next()) |e| {
        const td = e.value_ptr.*;
        const r = td.rect;
        var buf: [320]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}\t{d:.1}\t{d:.1}\t{d:.1}\t{d:.1}\t{d}\n", .{ e.key_ptr.*, r.x, r.y, r.w, r.h, @intFromBool(td.visible) }) catch continue;
        _ = std.c.fwrite(line.ptr, 1, line.len, f);
    }
}

// Wake-up thunk handed to the download Manager's background poller: it runs
// on the poller thread and schedules a UI re-render so fresh download progress
// paints. `ctx` is the `*dvui.Window`. dvui.refresh is the documented
// cross-thread wake mechanism (same as the per-worker refresh calls).
fn wakeDownloadUi(ctx: ?*anyopaque) void {
    const w: *dvui.Window = @ptrCast(@alignCast(ctx));
    dvui.refresh(w, @src(), null);
}

// --- frame-pacing telemetry (F69_PERF=1) -----------------------------------
// Summarised once per second to stderr:
//   perf: fps=<n> build_max=<us> gpu_max=<us> present_max=<us>
// build   = widget-tree construction (guiFrame)
// gpu     = win.end() — dvui's draw-command flush + texture upload to the GPU
// present = swapchain present; INCLUDES the vsync wait, so ~16000us at a
//           steady 60 fps is normal and not a problem.
// Reading it: low fps + low build/gpu + present pinned near the vsync interval
// = we're simply not generating frames fast enough (pacing / event-wakeup),
// not GPU-bound. High gpu = real per-frame GPU cost. Off (one getenv) unless
// the var is set; the four clock reads per frame are negligible.
const perf_log = std.log.scoped(.perf);
var g_perf_checked: bool = false;
var g_perf_on: bool = false;
var g_perf_n: u32 = 0;
var g_perf_build_us: u64 = 0;
var g_perf_gpu_us: u64 = 0;
var g_perf_present_us: u64 = 0;
var g_perf_window_ns: i128 = 0;

fn perfNowNs(io: std.Io) i128 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toNanoseconds();
}

fn perfFrame(io: std.Io, build_us: u64, gpu_us: u64, present_us: u64) void {
    if (!g_perf_checked) {
        g_perf_checked = true;
        g_perf_on = std.c.getenv("F69_PERF") != null;
    }
    if (!g_perf_on) return;
    const now = perfNowNs(io);
    if (g_perf_window_ns == 0) g_perf_window_ns = now;
    g_perf_n += 1;
    if (build_us > g_perf_build_us) g_perf_build_us = build_us;
    if (gpu_us > g_perf_gpu_us) g_perf_gpu_us = gpu_us;
    if (present_us > g_perf_present_us) g_perf_present_us = present_us;
    if (now - g_perf_window_ns >= 1_000_000_000) {
        perf_log.info("fps={d} build_max={d}us gpu_max={d}us present_max={d}us", .{
            g_perf_n, g_perf_build_us, g_perf_gpu_us, g_perf_present_us,
        });
        g_perf_n = 0;
        g_perf_build_us = 0;
        g_perf_gpu_us = 0;
        g_perf_present_us = 0;
        g_perf_window_ns = now;
    }
}

/// Build the installed theme from the runtime token palette, with the bundled
/// font family applied. Re-applied each frame so Settings → Appearance edits
/// to `tokens.active` take effect live.
fn themedForActive() dvui.Theme {
    var t = types.consoleTheme(.dark);
    applyDesignBFonts(&t);
    return t;
}

/// Map the four dvui theme font slots onto the bundled Design B families:
/// Archivo for headings/titles, IBM Plex Sans for body, IBM Plex Mono for
/// mono. Keeps sizes/weights from the base theme — only the family changes.
fn applyDesignBFonts(t: *dvui.Theme) void {
    t.font_body = t.font_body.withFamily(fonts.FAMILY_BODY);
    t.font_heading = t.font_heading.withFamily(fonts.FAMILY_HEADING);
    t.font_title = t.font_title.withFamily(fonts.FAMILY_HEADING);
    t.font_mono = t.font_mono.withFamily(fonts.FAMILY_MONO);
}

/// Build one UI frame. `pub` so the Layer-2 headless GUI tests
/// (src/testkit/) can drive the real render via dvui's testing backend.
pub fn guiFrame(frame: *Frame) !bool {
    dvui.themeSet(themedForActive());
    // Snapshot caches: install_versions + games_by_thread. Both
    // survive across frames (owned by `lib.alloc`, lifetime managed
    // by `freeSnapshotCache`) and rebuild only when their key
    // changes:
    //
    //   - install_versions: when `Library.install_generation`
    //     advances (install row added / removed / renamed).
    //   - games_by_thread:  when `frame.games` ptr or len changes
    //     (a fresh `listGames` allocation invalidates every cached
    //     *Game pointer).
    //
    // On an idle library-scroll frame both are hits, so the UI
    // thread skips a full-table SELECT + a linear scan over every
    // game. Failure is non-fatal — readers fall back to the
    // per-game SQL / linear-scan paths via `orelse`.
    {
        const lib_gen = frame.lib.install_generation;
        if (frame.state.snapshot_install_versions == null or lib_gen != frame.state.snapshot_install_gen) {
            const t_iv = types.startLatency(frame.io);
            if (frame.state.snapshot_install_versions) |*m| {
                var it = m.valueIterator();
                while (it.next()) |v| frame.lib.alloc.free(v.*);
                m.deinit();
                frame.state.snapshot_install_versions = null;
            }
            frame.state.snapshot_install_versions = frame.lib.latestInstallVersionMap(frame.lib.alloc) catch null;
            frame.state.snapshot_install_gen = lib_gen;
            types.endLatency(frame.io, t_iv, "snapshot: install_versions rebuild");
        }
        if (frame.state.snapshot_install_versions) |*m| {
            frame.install_versions = m;
        }
    }

    {
        const games_ptr: usize = @intFromPtr(frame.games.ptr);
        const games_len: usize = frame.games.len;
        // `sortGames` swaps `games[]` contents in place without
        // changing ptr/len, so we additionally key the staleness
        // check on the applied-sort state. Without this, sorting
        // would silently keep cached `*Game` pointers that now
        // address the wrong games — clicking the top card would
        // open a different game's detail page.
        const sort_col: u32 = if (frame.state.sort_applied_column) |c| @intFromEnum(c) else std.math.maxInt(u32);
        const sort_dir: u32 = if (frame.state.sort_applied_dir) |d| @intFromEnum(d) else std.math.maxInt(u32);
        const stale = frame.state.snapshot_games_by_thread == null or
            games_ptr != frame.state.snapshot_games_ptr or
            games_len != frame.state.snapshot_games_len or
            sort_col != frame.state.snapshot_games_sort_column or
            sort_dir != frame.state.snapshot_games_sort_dir;
        if (stale) {
            if (frame.state.snapshot_games_by_thread) |*m| {
                m.deinit();
                frame.state.snapshot_games_by_thread = null;
            }
            var m = std.AutoHashMap(u64, *library.Game).init(frame.lib.alloc);
            m.ensureTotalCapacity(@intCast(frame.games.len)) catch {};
            for (frame.games) |*g| m.put(g.f95_thread_id, g) catch {};
            frame.state.snapshot_games_by_thread = m;
            frame.state.snapshot_games_ptr = games_ptr;
            frame.state.snapshot_games_len = games_len;
            frame.state.snapshot_games_sort_column = sort_col;
            frame.state.snapshot_games_sort_dir = sort_dir;
        }
        if (frame.state.snapshot_games_by_thread) |*m| {
            frame.games_by_thread = m;
        }
    }

    // One-shot donor-status probe on the first frame after sign-in.
    // Spawns a detached worker; result lands via `drainDonorProbe`
    // (called below). `donor_check_attempted` flips once the worker
    // reports back so we don't re-fire on transient errors.
    if (frame.state.login_status == .logged_in and
        !frame.state.donor_check_attempted and
        !frame.state.donor_check_in_flight)
    {
        actions.checkDonorStatus(frame);
    }

    const t_drain = types.startLatency(frame.io);
    actions.drainSync(frame);
    actions.drainFastCheck(frame);
    actions.drainImageQueue(frame);
    actions.drainBookmarks(frame);
    actions.drainUpdateCheck(frame);
    actions.drainRpdlDownload(frame);
    actions.drainDonorDownload(frame);
    actions.drainDonorProbe(frame);
    actions.drainSlideLoads(frame);
    actions.drainCoverLoads(frame);
    actions.drainLaunchWatcher(frame);
    actions.drainRefreshTags(frame);
    types.endLatency(frame.io, t_drain, "drain stack");
    // Refresh aria2-driven download progress. `tick()` self-throttles the
    // per-job status RPC to ~4 Hz (it's a synchronous round-trip on this
    // thread) and skips terminal jobs, so a queue of finished downloads no
    // longer blocks rendering. Skip the call entirely when there are no jobs.
    if (frame.dl_mgr.jobs.count() > 0) frame.dl_mgr.tick();
    // Aria2 progress + the detail-page "Installing…" sweep both
    // arrive/animate between input events. Without an explicit
    // re-render request, the main loop's `waitEventTimeout` would
    // sit idle and neither would move until the user touched the
    // mouse. Whenever any download job is non-terminal OR an
    // extract worker is in flight, ask dvui to schedule another
    // frame. vsync caps the cost at ~60 fps; idle libraries with
    // no activity incur zero wakeups.
    if (anyDownloadActive(frame.dl_mgr) or anyPostInstallActive(frame.state) or
        actions.folderImportActive(frame.state))
    {
        dvui.refresh(frame.win, @src(), null);
    }
    // Toasts need wall-clock ticks to fade out. Without an explicit
    // refresh request, the main loop blocks on input and toasts
    // appear to hang on screen forever. Cheap — capped at vsync.
    if (frame.state.toast_count > 0) {
        dvui.refresh(frame.win, @src(), null);
    }

    // Verbose telemetry for donor-DDL downloads. Throttled to ~once
    // per 3 s per job, with instant flushes on stall/recovery and
    // aria2 errorMessage changes. Cheap when no donor jobs exist
    // (early-out on empty `donor_jobs` map).
    actions.drainDonorTelemetry(frame);
    // Any newly-.done downloads with a known game_id get handed to
    // a detached extract worker. `drainCompletedDownloads` just
    // kicks off workers; `drainPostInstall` collects the finished
    // ones and writes the install DB row on the UI thread (SQLite
    // isn't multi-thread-write-safe at the app layer).
    actions.drainCompletedDownloads(frame);
    actions.drainPostInstall(frame);
    actions.drainManualInstall(frame);
    actions.drainTestInstall(frame);
    actions.drainModJobs(frame);
    actions.drainImport(frame);
    actions.drainFolderImport(frame);
    // Prune the running-games map for processes that have exited so
    // the detail screen's Launch ↔ Stop swap stays honest.
    actions.drainRunningGames(frame);

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{
        .style = .window,
        .background = true,
        .expand = .both,
        .name = "root",
    });
    defer root.deinit();

    const t0 = types.startLatency(frame.io);
    // Design-B shell: left icon rail (primary nav) + screen content.
    const result = blk: {
        // Cap the shell's propagated min-height. A screen whose content is a
        // `.auto` vertical scrollArea reports its FULL content height as its
        // own min-size (ScrollContainerWidget.deinit); that would bubble up
        // here, exceed the window, and squeeze the bottom activity dock
        // (renderStatusBar) to zero height. `expand = .both` still fills the
        // available viewport — the cap governs only layout claims, not the
        // rendered size — so the dock ALWAYS reserves its 30px on every screen.
        var shell = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .max_size_content = dvui.Options.MaxSize.height(120),
        });
        defer shell.deinit();
        screens.renderIconRail(frame);
        var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer content.deinit();
        break :blk switch (frame.state.screen) {
            .library => screens.libraryScreen(frame),
            .detail => screens.detailScreen(frame),
            .settings => screens.settingsScreen(frame),
            .import_urls => screens.importUrlsScreen(frame),
            .import_folder => screens.importFolderScreen(frame),
            .import_f95_review => screens.importF95CheckerReviewScreen(frame),
            .downloads => screens.downloadsScreen(frame),
            .diagnostics => screens.diagnosticsScreen(frame),
            .recipe_editor => screens.recipeEditorScreen(frame),
            .mods_for_game => screens.modsScreen(frame),
            .universal_mods => screens.universalModsScreen(frame),
        };
    };

    // Bottom status bar — full-width, under the rail + content; shows global
    // activity (download / install / sync) or "Ready". A normal layout child
    // (not floating), so it reserves its 24px at the very bottom of the window.
    screens.renderStatusBar(frame);
    // The dock expanded → the Downloads & Seeding drawer over the content.
    screens.renderActivityDrawer(frame);

    // End-of-batch sync recap popup. Sits on top of whichever screen
    // is active so the user always sees the "what changed" list,
    // even if they navigated mid-sync.
    if (frame.state.sync_recap_show) {
        screens.renderSyncRecapPopup(frame);
    }

    // Login popup — auto-opened by runMainLoop at startup when not
    // signed in; user dismisses via Skip or by completing a login.
    if (frame.state.login_popup_open) {
        screens.renderLoginPopup(frame);
    }
    // Launch-issue dialog — opened by `doLaunchGame` when a pre-launch
    // check finds an actionable issue. Decoupled from the login popup
    // so both can be open at once (rare, but no reason to block).
    if (frame.state.launch_diag_open) {
        screens.renderLaunchDiagPopup(frame);
    }

    // Toast overlay — rendered after every other screen widget so it
    // floats above the content. Visible from any screen.
    screens.renderToasts(frame);

    types.endLatency(frame.io, t0, switch (frame.state.screen) {
        .library => "render library",
        .detail => "render detail",
        .settings => "render settings",
        .import_urls => "render import (urls)",
        .import_folder => "render import (folder)",
        .import_f95_review => "render import (f95 review)",
        .downloads => "render downloads",
        .diagnostics => "render diagnostics",
        .recipe_editor => "render recipe editor",
        .mods_for_game => "render mods page",
        .universal_mods => "render universal mods",
    });
    return result;
}

/// True iff the download manager has any job that is still
/// changing (downloading, seeding, queued, mid-extract, etc.).
/// Drives the `dvui.refresh` call in `guiFrame` so progress bars
/// keep moving between input events.
fn anyDownloadActive(dl_mgr: *downloads.Manager) bool {
    if (dl_mgr.jobs.count() == 0) return false;
    var it = dl_mgr.jobs.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.status) {
            // Terminal + paused + seeding states don't animate
            // anything the user cares about per frame, so skip them
            // when deciding whether to schedule another redraw.
            // (Paused still re-polls via tick(), but the numbers
            // don't move. Seeding ticks an upload counter the UI
            // shows on the Downloads tab only; not worth a 60Hz
            // refresh on every screen.)
            .done, .failed, .cancelled, .paused, .seeding => continue,
            else => return true,
        }
    }
    return false;
}

/// True iff any post-install (extract) worker is in flight. Used
/// alongside `anyDownloadActive` to keep the main loop redrawing
/// while the detail-page "Installing…" sweep animation needs frames.
fn anyPostInstallActive(state: *const State) bool {
    return actions.anyPostInstallActive(state);
}
