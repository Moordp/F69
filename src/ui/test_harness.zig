//! Headless Layer-1 test harness.
//!
//! Builds the full f69 service graph + a `Frame` against a caller-
//! supplied dvui *testing* window (no SDL/Vulkan/display), so the action
//! layer can be driven head­lessly and uniformly on any OS. Lives inside
//! the `ui` module so it can construct ui-internal pieces (the mod-job
//! queue, RunnerCtx) the way `runMainLoop` does — keeping the harness's
//! service wiring from drifting away from production.
//!
//! The window is created by the caller (src/testkit/, which links dvui's
//! testing backend) and passed in; everything else is built here against
//! a throwaway data root. See docs/test-automation-research.md (Layer 1).

const std = @import("std");
const dvui = @import("dvui");

const library = @import("library");
const f95 = @import("f95");
const f95_indexer = @import("f95_indexer");
const downloads = @import("downloads");
const recipe = @import("recipe");
const sandbox = @import("sandbox");
const convert = @import("convert");
const compat = @import("compat");

const state_mod = @import("state.zig");
const types = @import("types.zig");
const actions = @import("actions.zig");
const mod_job_queue = @import("mod_job_queue.zig");

const State = state_mod.State;
const Frame = types.Frame;
const RuntimeInfo = types.RuntimeInfo;

/// A complete, headless f69 instance. Heap-allocated and self-
/// referential (services hold pointers to each other), so never move it
/// — always work through the returned pointer.
pub const Harness = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    win: *dvui.Window,
    arena: std.heap.ArenaAllocator,

    lib: library.Library,
    f95_client: f95.Client,
    f95_service: f95.Service,
    indexer_client: f95_indexer.Client,
    dl_mgr: downloads.Manager,
    recipe_repo: recipe.Repo,
    sandbox_backend: sandbox.Sandbox,
    host_launcher: sandbox.NoSandbox,
    convert_svc: convert.Service,
    compat_repo: compat.Repo,
    compat_host: compat.Host,
    compat_resolver: compat.Resolver,
    compat_backups: compat.BackupStore,
    compat_svc: compat.Service,
    mod_jobs_ctx: actions.RunnerCtx,
    mod_jobs: mod_job_queue.Queue,

    state: State,
    info: RuntimeInfo,
    games: []library.Game,

    fn join(a: std.mem.Allocator, root: []const u8, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(a, "{s}/{s}", .{ root, name });
    }

    /// Build a fresh instance rooted at `root` (a tmpdir). `win` is a
    /// dvui window on the testing backend, created + owned by the caller.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, win: *dvui.Window, root: []const u8) !*Harness {
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.io = io;
        self.win = win;
        self.arena = std.heap.ArenaAllocator.init(gpa);
        const a = self.arena.allocator();

        const cwd = std.Io.Dir.cwd();
        const db_path = try join(a, root, "f69.db");
        const covers_dir = try join(a, root, "covers");
        const library_root = try join(a, root, "library");
        const recipes_dir = try join(a, root, "recipes");
        const direct_root = try join(a, root, "downloads/direct");
        const torrents_root = try join(a, root, "downloads/torrents");
        const cache_root = try join(a, root, "cache");
        const compat_recipes = try join(a, root, "compat-recipes");
        const compat_resources = try join(a, root, "compat-resources");
        const compat_backups_dir = try join(a, root, "compat-backups");
        for ([_][]const u8{ covers_dir, library_root, recipes_dir, direct_root, torrents_root, compat_recipes, compat_resources, compat_backups_dir }) |d| {
            cwd.createDirPath(io, d) catch {};
        }

        self.lib = try library.Library.open(gpa, db_path);
        errdefer self.lib.close();

        self.f95_client = f95.Client.init(gpa, io, 1500);
        self.f95_service = f95.Service.init(gpa, &self.f95_client);
        self.indexer_client = f95_indexer.Client.init(gpa, io, f95_indexer.DEFAULT_BASE_URL);
        self.dl_mgr = downloads.Manager.init(gpa, io, library_root, library_root, direct_root, torrents_root, "aria2c", 0, 5.0, 0);
        self.recipe_repo = recipe.Repo.init(gpa, io, recipes_dir);

        const env = std.process.Environ.empty;
        self.host_launcher = sandbox.NoSandbox.init(io, env);
        self.sandbox_backend = sandbox.pickBackend(gpa, io, env, "");

        self.convert_svc = try convert.Service.init(gpa, io, cache_root);
        self.compat_repo = compat.Repo.init(gpa, io, compat_recipes);
        self.compat_host = try compat.probeHost(gpa, io);
        self.compat_resolver = compat.Resolver.init(gpa, io, compat_resources);
        self.compat_backups = compat.BackupStore.init(gpa, io, compat_backups_dir);
        self.compat_svc = compat.Service.init(gpa, io, &self.compat_repo, &self.compat_host, &self.compat_resolver, &self.compat_backups);

        self.mod_jobs_ctx = .{ .alloc = gpa, .io = io, .lib = &self.lib, .repo = &self.recipe_repo };
        self.mod_jobs = mod_job_queue.Queue.init(gpa, io, win, actions.modJobRunner, &self.mod_jobs_ctx);

        self.state = .{};
        self.games = &.{};
        self.info = .{
            .exe_dir = ".",
            .data_root = try a.dupe(u8, root),
            .db_path = db_path,
            .covers_dir = covers_dir,
            .library_root = library_root,
            .cookie_path = try join(a, root, "f95_cookie"),
            .recipes_dir = recipes_dir,
            .mod_archives_dir = try join(a, root, "mod-archives"),
            .mod_presets_dir = try join(a, root, "mod-presets"),
            .convert_presets_dir = try join(a, root, "convert-presets"),
            .browser_path_file = try join(a, root, "browser"),
            .browsers = &.{},
            .initial_browser_path = "xdg-open",
            .rate_limit_ms = 1500,
            .rpdl_token_path = try join(a, root, "rpdl_token"),
            .ui_scale_path = try join(a, root, "ui_scale"),
            .initial_ui_scale = 1.25,
            .last_update_check_path = try join(a, root, "last_update_check"),
            .initial_last_update_check_ts = 0,
            .auto_check_path = try join(a, root, "auto_check"),
            .initial_auto_check = .{},
            .lib_prefs_path = try join(a, root, "lib_prefs"),
            .initial_lib_prefs = "",
            .auto_convert_path = try join(a, root, "auto_convert"),
            .initial_auto_convert = false,
            .auto_apply_compat_path = try join(a, root, "auto_apply_compat"),
            .initial_auto_apply_compat = true,
            .sandbox_default_path = try join(a, root, "sandbox_default"),
            .initial_sandbox_default = true,
            .auto_update_default_path = try join(a, root, "auto_update_default"),
            .initial_auto_update_default = false,
            .desktop_notifications_path = try join(a, root, "desktop_notifications"),
            .initial_desktop_notifications = true,
            .refresh_backend_path = try join(a, root, "refresh_backend"),
            .initial_refresh_backend = .indexer,
            .max_parallel_sync_path = try join(a, root, "max_parallel_sync"),
            .initial_max_parallel_sync = 4,
            .max_parallel_image_path = try join(a, root, "max_parallel_image"),
            .initial_max_parallel_image = 4,
            .min_session_seconds_path = try join(a, root, "min_session_seconds"),
            .initial_min_session_seconds = 60,
            .tags_master_path = try join(a, root, "tags.txt"),
            .aria2_port_path = try join(a, root, "aria2_port"),
            .initial_aria2_port = 0,
            .aria2_seed_ratio_path = try join(a, root, "aria2_seed_ratio"),
            .initial_aria2_seed_ratio = 5.0,
            .aria2_seed_time_path = try join(a, root, "aria2_seed_time"),
            .initial_aria2_seed_time = 0,
            .update_check_source_path = try join(a, root, "update_check_source"),
            .initial_update_check_source = .builtin,
            .host = .{},
        };

        return self;
    }

    /// Pump every async-worker drain once. Each drain is a no-op when its
    /// slot is empty, so this is safe to call repeatedly. Mirrors the set
    /// runMainLoop calls each frame.
    fn pumpDrains(f: *Frame) void {
        actions.drainSync(f);
        actions.drainFastCheck(f);
        actions.drainImageQueue(f);
        actions.drainSlideLoads(f);
        actions.drainBookmarks(f);
        actions.drainUpdateCheck(f);
        actions.drainRefreshTags(f);
        actions.drainDonorProbe(f);
        actions.drainRpdlDownload(f);
        actions.drainDonorDownload(f);
        actions.drainCompletedDownloads(f);
        actions.drainImport(f);
        actions.drainModJobs(f);
        actions.drainPostInstall(f);
        actions.drainManualInstall(f);
        actions.drainTestInstall(f);
        actions.drainLaunchWatcher(f);
        actions.drainRunningGames(f);
    }

    /// Pump drains until no worker is busy (or the bound trips). Use after
    /// driving an async action (login → donor probe, sync, download, …) so
    /// the result has landed before asserting. `max_ticks` * 20 ms is the
    /// ceiling.
    pub fn drainWorkers(self: *Harness, max_ticks: usize) void {
        var f = self.frame();
        var i: usize = 0;
        while (i < max_ticks) : (i += 1) {
            pumpDrains(&f);
            if (!actions.workersBusy(&self.state)) return;
            self.io.sleep(std.Io.Duration.fromMilliseconds(20), .real) catch {};
        }
    }

    pub fn deinit(self: *Harness) void {
        const gpa = self.gpa;
        // Signal cancel to any worker the test left running, then pump the
        // drains until they clear — otherwise tearing down the services
        // races a live worker thread's next syscall (UAF). Mirrors
        // runMainLoop's graceful-shutdown drain.
        actions.cancelAllWorkers(&self.state);
        {
            var f = self.frame();
            var i: usize = 0;
            while (i < 300 and actions.workersBusy(&self.state)) : (i += 1) {
                pumpDrains(&f);
                self.io.sleep(std.Io.Duration.fromMilliseconds(20), .real) catch {};
            }
        }
        // Release every heap-owning bit of State, mirroring runMainLoop's
        // shutdown defer — otherwise actions that stash session/cache data
        // on State (folder scan, install jobs, caches) leak under the test
        // allocator. Run while the services are still alive.
        const lib_alloc = self.lib.alloc;
        actions.freeModfileCacheState(&self.state, lib_alloc);
        actions.freeClashModalState(&self.state, lib_alloc);
        actions.freeCoverLoads(&self.state, lib_alloc);
        actions.freeCoverCache(&self.state, lib_alloc);
        actions.freeLibFilterCache(&self.state, lib_alloc);
        actions.freeSnapshotCache(&self.state, lib_alloc);
        actions.freeSlideCache(&self.state, lib_alloc);
        actions.invalidatePresetCache(&self.state);
        actions.freeTestInstallJob(&self.state, self.io);
        actions.freeThumbCache(&self.state, lib_alloc);
        actions.freePostInstalled(&self.state, lib_alloc);
        actions.freeInstalledSet(&self.state, lib_alloc);
        actions.freePostInstallJobs(&self.state, lib_alloc);
        actions.freeManualInstallJobs(&self.state, lib_alloc);
        actions.freeFolderScan(&self.state, &self.lib, self.io);
        actions.freeF95Review(&self.state, lib_alloc);
        actions.freeSyncRecap(&self.state, lib_alloc);
        actions.freeDonorTables(&self.state, lib_alloc);
        actions.freeTagsMaster(lib_alloc, &self.state);
        if (self.state.sync_queue) |q| lib_alloc.free(q);
        if (self.state.rpdl_token) |t| lib_alloc.free(t);

        if (self.games.len > 0) self.lib.freeGames(self.games);
        self.mod_jobs.deinit();
        self.compat_host.deinit();
        self.compat_repo.deinit();
        self.convert_svc.deinit();
        self.sandbox_backend.deinit();
        self.recipe_repo.deinit();
        self.dl_mgr.deinit();
        self.f95_client.deinit();
        self.lib.close();
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// A `Frame` borrowing this harness's services. Rebuild per logical
    /// step (cheap); the per-frame arena caches stay null (the action
    /// layer rebuilds them as needed, exactly like `guiFrame`).
    pub fn frame(self: *Harness) Frame {
        return .{
            .state = &self.state,
            .games = self.games,
            .lib = &self.lib,
            .f95_svc = &self.f95_service,
            .f95_indexer_client = &self.indexer_client,
            .dl_mgr = &self.dl_mgr,
            .recipe_repo = &self.recipe_repo,
            .sandbox = &self.sandbox_backend,
            .host_launcher = &self.host_launcher,
            .convert_svc = &self.convert_svc,
            .compat_svc = &self.compat_svc,
            .win = self.win,
            .io = self.io,
            .mod_jobs = &self.mod_jobs,
            .info = self.info,
        };
    }

    /// Reload the in-memory games snapshot from the DB (after an action
    /// that inserts/updates rows). Mirrors `runMainLoop`'s reload path.
    pub fn reloadGames(self: *Harness) !void {
        if (self.games.len > 0) self.lib.freeGames(self.games);
        self.games = try self.lib.listGames();
    }
};
