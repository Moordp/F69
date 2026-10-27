// Download queue + dispatcher.
//
// Phase 2 first-cut: a single `Aria2Daemon` is lazy-spawned on first
// enqueue and shared across all jobs. The Manager keeps an in-memory
// table of jobs (URL + aria2 GID + cached status) and exposes:
//
//   enqueueUrl(url)      → job id, kicks off the download
//   tick()               → refresh status of every non-terminal job
//   statusOf(id)         → current Job snapshot (UI reads this)
//   cancel(id)           → tell aria2 to stop the GID
//   list()               → iterate all jobs (UI table)
//
// Per-host handlers (RPDL, mega, mediafire, …) are still defined in
// `handlers/` but the original "register handler vtable, walk by
// priority" plumbing is deferred to a later round — for the first
// pass aria2 catches every http/https URL directly.

const std = @import("std");
const atomic_io = @import("util_atomic_io");
const log = std.log.scoped(.downloads);
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const Handler = @import("handler.zig").Handler;
const aria2_rpc = @import("aria2_rpc.zig");

/// How often the background poller refreshes per-job status (bytes, speed,
/// seed stats). 4 Hz — fast enough that progress looks live, and it runs off
/// the UI thread so the cadence never touches rendering.
const POLL_INTERVAL_MS: u64 = 250;

pub const Manager = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    library_root: []const u8,
    cache_root: []const u8,
    /// `<data_root>/downloads/direct/` — where aria2 writes plain HTTP
    /// downloads (donor DDL, MediaFire, raw URL pastes). Daemon-wide
    /// `--dir=` points here on spawn.
    downloads_direct_root: []const u8,
    /// `<data_root>/downloads/torrents/` — per-torrent `dir=` override
    /// in `enqueueTorrent` routes BT downloads/seeds here, keeping
    /// .torrent state and DL content separate from HTTP downloads.
    downloads_torrents_root: []const u8,
    /// Reserved for future per-host handlers; not used in phase-2 cut.
    handlers: std.ArrayList(Handler),
    /// Every enqueued job, keyed by `Manager.next_id`.
    jobs: std.AutoHashMap(u64, dom.Job),
    /// Allocator-owned URL slice per job (Job.source_url points into it).
    job_urls: std.AutoHashMap(u64, []u8),
    /// Allocator-owned aria2 GID per job — the handle we hand back to
    /// `tellStatus` and `remove`.
    job_gids: std.AutoHashMap(u64, []u8),
    next_id: u64 = 1,
    /// Serialises every aria2 daemon RPC and every jobs/gids/urls map
    /// STRUCTURAL change between the UI thread and the background poller
    /// thread (below). The hot render path reads `jobs` WITHOUT this lock —
    /// the map is only ever structurally mutated on the UI thread, and the
    /// poller writes only scalar progress fields — so rendering never blocks
    /// on a synchronous aria2 round-trip. Single lock ⇒ no lock-ordering /
    /// deadlock hazard.
    mtx: std.Io.Mutex = .init,
    poller_thread: ?std.Thread = null,
    poller_run: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// UI wake-up. The poller calls this after each poll cycle to schedule a
    /// re-render, so download progress animates without the UI thread ever
    /// touching aria2. Wired once at startup (`setWake` → `dvui.refresh`).
    wake_fn: ?*const fn (?*anyopaque) void = null,
    wake_ctx: ?*anyopaque = null,
    /// Resolved aria2c executable path (`"aria2c"` for PATH lookup).
    aria2_path: []const u8,
    /// RPC port the daemon should bind. 0 ⇒ random ephemeral.
    /// Persisted by the UI under `<data_root>/aria2_port`; changes
    /// take effect on the next app launch (the daemon binds at spawn).
    aria2_port: u16 = 0,
    /// Daemon-wide BitTorrent seed-ratio target. aria2 keeps every
    /// completed torrent seeding until uploaded ≥ this × downloaded.
    /// Default 5.0, minimum 2.0 (enforced by Daemon.init). Persisted
    /// by the UI under `<data_root>/aria2_seed_ratio`; changes take
    /// effect on the next launch (daemon-wide flag set at spawn).
    aria2_seed_ratio: f32 = 5.0,
    /// Daemon-wide BitTorrent seed-time cap in minutes. 0 = no time cap
    /// (the ratio governs). Persisted under `<data_root>/aria2_seed_time`.
    aria2_seed_time_min: u32 = 0,
    /// Lazy-started on first enqueue. Owned by the Manager.
    daemon: ?aria2_rpc.Daemon = null,
    /// Optional persistence paths. When set, Manager (a) rehydrates
    /// its jobs table from `jobs_json_path` on init, and (b) writes
    /// it back after every enqueue/remove. `aria2_session_path` is
    /// forwarded to the Daemon for its own session-file restore.
    jobs_json_path: ?[]const u8 = null,
    aria2_session_path: ?[]const u8 = null,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        library_root: []const u8,
        cache_root: []const u8,
        downloads_direct_root: []const u8,
        downloads_torrents_root: []const u8,
        aria2_path: []const u8,
        aria2_port: u16,
        aria2_seed_ratio: f32,
        aria2_seed_time_min: u32,
    ) Manager {
        return .{
            .alloc = alloc,
            .io = io,
            .library_root = library_root,
            .cache_root = cache_root,
            .downloads_direct_root = downloads_direct_root,
            .downloads_torrents_root = downloads_torrents_root,
            .aria2_path = aria2_path,
            .aria2_port = aria2_port,
            .aria2_seed_ratio = aria2_seed_ratio,
            .aria2_seed_time_min = aria2_seed_time_min,
            .handlers = .empty,
            .jobs = std.AutoHashMap(u64, dom.Job).init(alloc),
            .job_urls = std.AutoHashMap(u64, []u8).init(alloc),
            .job_gids = std.AutoHashMap(u64, []u8).init(alloc),
        };
    }

    /// Enable cross-restart persistence. Call once after `init` and
    /// before the first enqueue. `jobs_json_path` stores our id ↔ gid
    /// ↔ url table; `aria2_session_path` is what the daemon uses for
    /// its own --save-session / --input-file pair. Loads any prior
    /// state on success — best-effort, errors are logged.
    pub fn enablePersistence(
        self: *Manager,
        jobs_json_path: []const u8,
        aria2_session_path: []const u8,
    ) void {
        self.jobs_json_path = jobs_json_path;
        self.aria2_session_path = aria2_session_path;
        self.loadJobsJson() catch |e| {
            log.warn("manager_jobs.json load failed: {s}", .{@errorName(e)});
        };
    }

    /// Spawn aria2c right now (instead of lazily on first enqueue) so
    /// any persisted downloads/seeds pick up where they left off. The
    /// daemon is configured with `--input-file=<session>` so the
    /// resume happens inside aria2 — we just need to have started it.
    /// Idempotent — second call is a no-op via ensureDaemon's guard.
    /// Bails silently when persistence isn't enabled and there's
    /// nothing to resume (callers can call this unconditionally at
    /// startup; first-run users don't get an aria2 process they
    /// don't need).
    pub fn resumeFromDisk(self: *Manager) errs.Error!void {
        // Two signals that we have work to resume:
        //   1. manager_jobs.json restored at least one job — those
        //      already have aria2 GIDs that the session file should
        //      re-attach to.
        //   2. The aria2 session file itself is non-empty — covers
        //      the case where the JSON file got corrupted but aria2
        //      can still bring back its own state.
        const have_jobs = self.jobs.count() > 0;
        const have_session = if (self.aria2_session_path) |p|
            sessionFileNonEmpty(self.io, p)
        else
            false;
        if (!have_jobs and !have_session) {
            log.info("resumeFromDisk: nothing to resume — aria2 stays cold until first enqueue", .{});
            return;
        }
        log.info(
            "resumeFromDisk: spawning aria2 eagerly (jobs={d}, session_present={any})",
            .{ self.jobs.count(), have_session },
        );
        _ = try self.ensureDaemon();
    }

    pub fn deinit(self: *Manager) void {
        // Stop the poller FIRST — it touches the daemon, the jobs map, and
        // the UI wake-up window, all about to be torn down.
        self.stopPoller();
        if (self.daemon) |*d| d.deinit();
        for (self.handlers.items) |h| h.deinit(self.alloc);
        self.handlers.deinit(self.alloc);

        var url_it = self.job_urls.valueIterator();
        while (url_it.next()) |v| self.alloc.free(v.*);
        self.job_urls.deinit();

        var gid_it = self.job_gids.valueIterator();
        while (gid_it.next()) |v| self.alloc.free(v.*);
        self.job_gids.deinit();

        var job_it = self.jobs.valueIterator();
        while (job_it.next()) |j| {
            if (j.error_msg) |em| self.alloc.free(em);
            if (j.version) |v| self.alloc.free(v);
        }
        self.jobs.deinit();
        self.* = undefined;
    }

    /// Reserved-for-later: the priority-routed Handler model. Phase 2's
    /// first pass uses aria2 directly.
    pub fn registerHandler(self: *Manager, handler: Handler) errs.Error!void {
        self.handlers.append(self.alloc, handler) catch return errs.Error.OutOfMemory;
        std.sort.pdq(Handler, self.handlers.items, {}, struct {
            fn lt(_: void, a: Handler, b: Handler) bool {
                return a.priority < b.priority;
            }
        }.lt);
    }

    /// Lazy-start aria2c on first request.
    fn ensureDaemon(self: *Manager) errs.Error!*aria2_rpc.Daemon {
        if (self.daemon == null) {
            log.info(
                "starting aria2c (path='{s}', direct_dir='{s}', torrents_dir='{s}', session={?s}, port={d}, seed_ratio={d:.2})",
                .{
                    self.aria2_path,
                    self.downloads_direct_root,
                    self.downloads_torrents_root,
                    self.aria2_session_path,
                    self.aria2_port,
                    self.aria2_seed_ratio,
                },
            );
            // Daemon-wide --dir is `direct/` — most jobs are plain
            // HTTP (donor DDL, mediafire, raw URLs). Torrents override
            // per-call via `TorrentOptions.dir = torrents_root`.
            self.daemon = try aria2_rpc.Daemon.init(
                self.alloc,
                self.io,
                self.aria2_path,
                self.downloads_direct_root,
                self.aria2_session_path,
                self.aria2_port,
                self.aria2_seed_ratio,
                self.aria2_seed_time_min,
            );
            log.info("aria2c daemon ready", .{});
        }
        return &self.daemon.?;
    }

    /// Queue a URL and return the new job id. `url` is borrowed for the
    /// duration of this call; Manager copies what it needs to keep.
    /// `kind` distinguishes a base game download from a mod (drives the
    /// post-install dispatch). `game_id` is the F95 thread id of the
    /// game this job pertains to (0 = unknown — manual paste).
    /// `mod_id` (only meaningful when `kind = .mod`) is the F95 thread
    /// id of the mod whose archive this fetches. `expected_sha256`
    /// (when non-null) is verified before extract.
    pub fn enqueueUrl(
        self: *Manager,
        url: []const u8,
        kind: dom.JobKind,
        game_id: u64,
        mod_id: ?u64,
        expected_sha256: ?[32]u8,
        version: ?[]const u8,
        /// Per-URI aria2 options: headers (donor cookie), connection
        /// count, split count, retry wait. Defaults to `.{}` for raw
        /// HTTP downloads where the daemon-wide defaults suffice.
        http_opts: aria2_rpc.Daemon.UriOptions,
    ) errs.Error!u64 {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        const daemon = try self.ensureDaemon();
        const gid = try daemon.addUri(url, http_opts);
        errdefer self.alloc.free(gid);
        return self.registerJob(url, gid, kind, game_id, mod_id, expected_sha256, version);
    }

    /// Queue a local .torrent file (raw bencoded bytes) via aria2's
    /// `addTorrent` RPC. `label` is what the UI shows for the job
    /// (typically `"rpdl:<id>"`); aria2 derives the actual filenames
    /// from the torrent's `info.files` block. Other params as above.
    pub fn enqueueTorrent(
        self: *Manager,
        label: []const u8,
        torrent_bytes: []const u8,
        kind: dom.JobKind,
        game_id: u64,
        mod_id: ?u64,
        expected_sha256: ?[32]u8,
        version: ?[]const u8,
    ) errs.Error!u64 {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        const daemon = try self.ensureDaemon();
        const gid = try daemon.addTorrent(torrent_bytes, .{
            .dir = self.downloads_torrents_root,
        });
        errdefer self.alloc.free(gid);
        return self.registerJob(label, gid, kind, game_id, mod_id, expected_sha256, version);
    }

    /// Common bookkeeping for `enqueueUrl` / `enqueueTorrent`. On
    /// success Manager takes ownership of `gid`; on failure the
    /// caller's `errdefer` frees it. `version` (when non-null) is
    /// duped into Job.version so the install row records the exact
    /// build the user downloaded (RPDL title-derived for torrents,
    /// F95 scraped version for donor DDL).
    fn registerJob(
        self: *Manager,
        label: []const u8,
        gid: []u8,
        kind: dom.JobKind,
        game_id: u64,
        mod_id: ?u64,
        expected_sha256: ?[32]u8,
        version: ?[]const u8,
    ) errs.Error!u64 {
        const url_owned = self.alloc.dupe(u8, label) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(url_owned);

        const version_owned: ?[]u8 = if (version) |v|
            (self.alloc.dupe(u8, v) catch return errs.Error.OutOfMemory)
        else
            null;
        errdefer if (version_owned) |v| self.alloc.free(v);

        const id = self.next_id;
        self.next_id += 1;

        const job: dom.Job = .{
            .id = id,
            .kind = kind,
            .game_id = game_id,
            .mod_id = mod_id,
            .expected_sha256 = expected_sha256,
            .source_url = url_owned,
            .version = version_owned,
            .dest_path = self.library_root,
            .status = .downloading,
        };
        self.jobs.put(id, job) catch return errs.Error.OutOfMemory;
        errdefer _ = self.jobs.remove(id);

        self.job_urls.put(id, url_owned) catch return errs.Error.OutOfMemory;
        errdefer _ = self.job_urls.remove(id);

        self.job_gids.put(id, gid) catch return errs.Error.OutOfMemory;

        log.info("queued job {d} gid={s} game_id={d} version={?s} src={s}", .{ id, gid, game_id, version_owned, label });
        self.persistJobs() catch |e| {
            log.warn("manager_jobs.json save failed: {s}", .{@errorName(e)});
        };
        return id;
    }

    /// Refresh the cached status of every non-terminal job by polling
    /// `aria2.tellStatus`. Cheap — typically a handful of jobs and the
    /// RPC round-trip is sub-millisecond on localhost. Call once per
    /// UI frame (or whatever cadence makes the progress bars feel
    /// alive).
    pub fn tick(self: *Manager) void {
        // All aria2 I/O now runs on the background poller thread — the UI
        // thread does nothing here but lazily start it. tellStatus is a
        // synchronous RPC; running it (at any cadence) on the render thread
        // stutters the whole app, so it is fully decoupled.
        self.startPoller();
    }

    /// Wire the UI wake-up. The poller calls `fn(ctx)` after each poll cycle
    /// so the UI re-renders fresh progress. Call once at startup.
    pub fn setWake(self: *Manager, ctx: ?*anyopaque, f: *const fn (?*anyopaque) void) void {
        self.wake_ctx = ctx;
        self.wake_fn = f;
    }

    /// Lazily spawn the background poller once the daemon exists and the UI
    /// has wired its wake-up. Idempotent.
    fn startPoller(self: *Manager) void {
        if (self.poller_thread != null or self.daemon == null or self.wake_fn == null) return;
        self.poller_run.store(true, .release);
        self.poller_thread = std.Thread.spawn(.{}, pollerLoop, .{self}) catch |e| {
            self.poller_run.store(false, .release);
            log.warn("download poller thread spawn failed: {s}", .{@errorName(e)});
            return;
        };
        log.info("download status poller started", .{});
    }

    /// Stop the poller (signal + join). Idempotent; safe to call before the
    /// daemon/jobs are torn down. Must run before any state the poller touches
    /// (daemon, jobs, the wake-up window) is destroyed.
    pub fn stopPoller(self: *Manager) void {
        if (self.poller_thread) |th| {
            self.poller_run.store(false, .release);
            th.join();
            self.poller_thread = null;
        }
    }

    const PollTarget = struct { id: u64, gid: [48]u8 = undefined, len: u8 = 0 };

    /// Background loop: every POLL_INTERVAL, snapshot the non-terminal jobs,
    /// poll aria2 for each (the synchronous RPC happens HERE, never on the UI
    /// thread), write fresh stats back, then wake the UI. The lock is held
    /// only for the snapshot + each per-job RPC/write-back + the event drain;
    /// the UI render path reads `jobs` without it.
    fn pollerLoop(self: *Manager) void {
        var targets: std.ArrayList(PollTarget) = .empty;
        defer targets.deinit(self.alloc);
        while (self.poller_run.load(.acquire)) {
            self.io.sleep(std.Io.Duration.fromMilliseconds(POLL_INTERVAL_MS), .real) catch {};
            if (!self.poller_run.load(.acquire)) break;

            // --- snapshot non-terminal (id, gid) ---
            targets.clearRetainingCapacity();
            self.mtx.lockUncancelable(self.io);
            {
                var snap = self.jobs.iterator();
                while (snap.next()) |entry| {
                    const j = entry.value_ptr;
                    switch (j.status) {
                        // Terminal states never change again — skip them so a
                        // queue of finished downloads costs nothing.
                        .failed, .cancelled, .done => continue,
                        else => {},
                    }
                    const g = self.job_gids.get(j.id) orelse continue;
                    if (g.len > 48) continue;
                    var t = PollTarget{ .id = j.id, .len = @intCast(g.len) };
                    @memcpy(t.gid[0..g.len], g);
                    targets.append(self.alloc, t) catch {};
                }
            }
            self.mtx.unlock(self.io);

            var any_transition = false;
            for (targets.items) |t| {
                const gid = t.gid[0..t.len];
                self.mtx.lockUncancelable(self.io);
                const d = if (self.daemon) |*dd| dd else {
                    self.mtx.unlock(self.io);
                    break;
                };
                var s = d.tellStatus(gid) catch |e| {
                    if (e == errs.Error.NotFound) {
                        // aria2 forgot this gid (cleared after completion, or a
                        // session-restored job whose gid changed). Drop the
                        // mapping + settle the status.
                        if (self.job_gids.fetchRemove(t.id)) |kv| self.alloc.free(kv.value);
                        if (self.jobs.getPtr(t.id)) |j| {
                            j.status = switch (j.status) {
                                .done, .seeding => .done,
                                else => .cancelled,
                            };
                            any_transition = true;
                        }
                    }
                    self.mtx.unlock(self.io);
                    continue;
                };
                defer s.deinit(self.alloc);
                if (self.jobs.getPtr(t.id)) |j| {
                    const prev_status = j.status;
                    j.bytes_total = s.total_length;
                    j.bytes_done = s.completed_length;
                    j.download_speed = s.download_speed;
                    j.upload_speed = s.upload_speed;
                    j.bytes_uploaded = s.upload_length;
                    j.num_seeders = s.num_seeders;
                    j.connections = s.connections;
                    j.is_torrent = s.is_torrent;
                    if (std.mem.eql(u8, s.status, "complete")) {
                        j.status = .done;
                    } else if (std.mem.eql(u8, s.status, "error")) {
                        j.status = .failed;
                        if (j.error_msg == null) {
                            if (s.error_message) |em| j.error_msg = self.alloc.dupe(u8, em) catch null;
                        }
                    } else if (std.mem.eql(u8, s.status, "removed")) {
                        j.status = .cancelled;
                    } else if (std.mem.eql(u8, s.status, "paused")) {
                        j.status = .paused;
                    } else if (std.mem.eql(u8, s.status, "active")) {
                        // BT stays "active" through leeching AND seeding;
                        // `seeder` (we have every piece) distinguishes them.
                        j.status = if (s.is_torrent and s.seeder) .seeding else .downloading;
                    }
                    if (j.status != prev_status) {
                        any_transition = true;
                        log.info("job {d} {s} -> {s}: bytes={d}/{?d} dl={d}B/s up={d}B/s peers={d}/{d}", .{
                            j.id,             @tagName(prev_status), @tagName(j.status),
                            j.bytes_done,     j.bytes_total,         s.download_speed,
                            s.upload_speed,   s.num_seeders,         s.connections,
                        });
                    }
                }
                self.mtx.unlock(self.io);
            }

            // --- drain WS push events (no-op under HTTP) ---
            var events: std.ArrayList(aria2_rpc.Event) = .empty;
            self.mtx.lockUncancelable(self.io);
            if (self.daemon) |*d| d.drainEvents(self.alloc, &events);
            self.mtx.unlock(self.io);
            for (events.items) |e| {
                log.info("aria2 push event {s} gid={s}", .{ e.method, e.gid });
                e.deinit(self.alloc);
            }
            events.deinit(self.alloc);

            if (any_transition) {
                self.mtx.lockUncancelable(self.io);
                self.persistJobs() catch |e|
                    log.warn("manager_jobs.json save failed after poll: {s}", .{@errorName(e)});
                self.mtx.unlock(self.io);
            }

            // Wake the UI loop so the new numbers paint (~4 Hz).
            if (self.wake_fn) |f| f(self.wake_ctx);
        }
    }

    /// Pause every active download/seed. No-op when the daemon
    /// hasn't been spawned. tick() picks up aria2's `status="paused"`
    /// on the next poll and updates each Job's status accordingly.
    pub fn pauseAll(self: *Manager) void {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        if (self.daemon) |*d| {
            d.pauseAll() catch |e| {
                log.warn("aria2.pauseAll failed: {s}", .{@errorName(e)});
            };
        }
    }

    /// Resume every paused download/seed.
    pub fn resumeAll(self: *Manager) void {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        if (self.daemon) |*d| {
            d.unpauseAll() catch |e| {
                log.warn("aria2.unpauseAll failed: {s}", .{@errorName(e)});
            };
        }
    }

    /// Pause a single in-flight download. Optimistically flips the row to
    /// `.paused` for instant UI feedback; the next poll confirms it.
    pub fn pauseJob(self: *Manager, id: u64) void {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        if (self.daemon) |*d| {
            if (self.job_gids.get(id)) |gid| {
                d.pause(gid) catch |e|
                    log.warn("aria2.pause failed for job {d}: {s}", .{ id, @errorName(e) });
            }
        }
        if (self.jobs.getPtr(id)) |j| j.status = .paused;
    }

    /// Resume a single paused download. The next poll reflects aria2's real
    /// status (downloading / seeding / queued).
    pub fn resumeJob(self: *Manager, id: u64) void {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        if (self.daemon) |*d| {
            if (self.job_gids.get(id)) |gid| {
                d.unpause(gid) catch |e|
                    log.warn("aria2.unpause failed for job {d}: {s}", .{ id, @errorName(e) });
            }
        }
    }

    /// True iff any job is currently paused. UI uses this to decide
    /// whether to surface a "Resume all" button.
    pub fn anyPaused(self: *const Manager) bool {
        var it = self.jobs.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.status == .paused) return true;
        }
        return false;
    }

    /// True iff any job is currently in a state that pauseAll would
    /// affect — UI uses this to decide whether to surface a
    /// "Pause all" button.
    pub fn anyResumable(self: *const Manager) bool {
        var it = self.jobs.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.status) {
                .queued, .fetching_metadata, .downloading, .seeding, .verifying => return true,
                else => continue,
            }
        }
        return false;
    }

    /// Tell aria2 to force-stop the download. Status flips to
    /// `.cancelled` immediately; the next `tick()` may overwrite it
    /// with whatever aria2 returns (typically "removed" → mapped back
    /// to `.cancelled`).
    pub fn cancel(self: *Manager, id: u64) void {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        if (self.daemon) |*d| {
            if (self.job_gids.get(id)) |gid| {
                d.remove(gid) catch |e| {
                    log.warn("aria2.remove failed for job {d}: {s}", .{ id, @errorName(e) });
                };
            }
        }
        if (self.jobs.getPtr(id)) |j| j.status = .cancelled;
    }

    /// Apply a new seed-ratio without restarting aria2: set the daemon-wide
    /// default (for future downloads) AND push it onto every torrent already
    /// in flight. Updates the cached value used by the ratio-met checks.
    /// Best-effort — a dead daemon just updates the cached value (it'll take
    /// effect at next spawn via the persisted file).
    pub fn setSeedRatioLive(self: *Manager, ratio: f32) void {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        self.aria2_seed_ratio = ratio;
        const daemon = if (self.daemon) |*d| d else return;
        var buf: [16]u8 = undefined;
        const rstr = std.fmt.bufPrint(&buf, "{d:.2}", .{ratio}) catch return;
        daemon.changeGlobalOption("seed-ratio", rstr) catch |e|
            log.warn("changeGlobalOption seed-ratio failed: {s}", .{@errorName(e)});
        var it = self.jobs.iterator();
        while (it.next()) |entry| {
            const j = entry.value_ptr;
            if (!j.is_torrent) continue;
            const gid = self.job_gids.get(j.id) orelse continue;
            daemon.changeOption(gid, "seed-ratio", rstr) catch {};
        }
    }

    /// Apply a daemon-wide seed-time cap (minutes; 0 = no cap) live + to
    /// in-flight torrents. Same best-effort semantics as `setSeedRatioLive`.
    pub fn setSeedTimeLive(self: *Manager, minutes: u32) void {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        self.aria2_seed_time_min = minutes;
        const daemon = if (self.daemon) |*d| d else return;
        var buf: [16]u8 = undefined;
        const mstr = std.fmt.bufPrint(&buf, "{d}", .{minutes}) catch return;
        daemon.changeGlobalOption("seed-time", mstr) catch |e|
            log.warn("changeGlobalOption seed-time failed: {s}", .{@errorName(e)});
        var it = self.jobs.iterator();
        while (it.next()) |entry| {
            const j = entry.value_ptr;
            if (!j.is_torrent) continue;
            const gid = self.job_gids.get(j.id) orelse continue;
            daemon.changeOption(gid, "seed-time", mstr) catch {};
        }
    }

    /// Drop a single job from the table (any status). For non-
    /// terminal jobs we first force-stop the aria2 side, otherwise
    /// `removeDownloadResult` rejects with "in use" and aria2 happily
    /// keeps running the orphaned GID — and resurrects it from the
    /// session file on next launch. Then frees the job's owned strings.
    pub fn removeJob(self: *Manager, id: u64) void {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        if (self.daemon) |*d| {
            if (self.job_gids.get(id)) |gid| {
                // Step 1: stop active GIDs. `forceRemove` is idempotent
                // for already-terminal entries (RPC error swallowed by
                // the catch below) so it's safe to call unconditionally.
                d.remove(gid) catch |e| {
                    log.warn("removeJob: aria2.forceRemove for job {d} failed: {s}", .{ id, @errorName(e) });
                };
                // Step 2: drop from aria2's status table. Now safe
                // because step 1 transitioned it out of active.
                d.removeDownloadResult(gid) catch |e| {
                    log.warn("removeJob: aria2.removeDownloadResult for job {d} failed: {s}", .{ id, @errorName(e) });
                };
            }
        }
        if (self.job_urls.fetchRemove(id)) |kv| self.alloc.free(kv.value);
        if (self.job_gids.fetchRemove(id)) |kv| self.alloc.free(kv.value);
        if (self.jobs.fetchRemove(id)) |kv| {
            if (kv.value.error_msg) |em| self.alloc.free(em);
            if (kv.value.version) |v| self.alloc.free(v);
        }
        self.persistJobs() catch |e| {
            log.warn("manager_jobs.json save failed: {s}", .{@errorName(e)});
        };
        log.info("removeJob: dropped job {d} (aria2 + local table + manager_jobs.json)", .{id});
    }

    /// Prune terminal-state jobs that are *safe* to clear:
    ///   - failed / cancelled jobs (no seed obligation remains);
    ///   - plain HTTP downloads in `.done` (no seed concept);
    ///   - torrents that have actually met the configured seed
    ///     ratio (`bytes_uploaded ≥ bytes_total * aria2_seed_ratio`).
    ///
    /// Skips:
    ///   - any job still `.downloading` / `.queued` / `.seeding` /
    ///     `.extracting` / etc. (UI obviously);
    ///   - torrents whose `.done` reading came before the ratio
    ///     target was hit (shouldn't happen with our spawn flags,
    ///     but cheap to defend against).
    ///
    /// Returns the count removed.
    pub fn clearCompleted(self: *Manager) u32 {
        var doomed: std.ArrayList(u64) = .empty;
        defer doomed.deinit(self.alloc);
        var it = self.jobs.iterator();
        while (it.next()) |entry| {
            const j = entry.value_ptr.*;
            const clearable = switch (j.status) {
                .failed, .cancelled => true,
                .done => clearable: {
                    if (!j.is_torrent) break :clearable true;
                    // Torrent: only clear when the seed obligation is
                    // genuinely met. Without bytes_total we can't
                    // judge — be conservative and keep the row.
                    const total = j.bytes_total orelse 0;
                    if (total == 0) break :clearable false;
                    const target: u64 = @intFromFloat(
                        @as(f64, @floatFromInt(total)) * @as(f64, self.aria2_seed_ratio),
                    );
                    break :clearable j.bytes_uploaded >= target;
                },
                else => false,
            };
            if (clearable) {
                doomed.append(self.alloc, entry.key_ptr.*) catch return 0;
            }
        }
        for (doomed.items) |id| self.removeJob(id);
        return @intCast(doomed.items.len);
    }

    pub fn statusOf(self: *Manager, id: u64) ?dom.Job {
        return self.jobs.get(id);
    }

    pub fn jobCount(self: *const Manager) usize {
        return self.jobs.count();
    }

    /// Reserved for the worker thread that will surface progress
    /// events to the UI. Phase 2 first cut uses synchronous `tick()`
    /// from the UI thread instead — fast enough on localhost.
    pub fn run(self: *Manager) errs.Error!void {
        _ = self;
    }

    // ============================================================
    //  jobs-table persistence
    // ============================================================

    const SESSION_SCHEMA_VERSION: u32 = 1;

    /// On-disk schema. Deliberately *just* the bookkeeping needed to
    /// re-attach to aria2's session-restored downloads — progress
    /// counters get rebuilt by the first `tick()` against the daemon.
    /// `game_id` is additive (default 0 via `ignore_unknown_fields`),
    /// so older manager_jobs.json files still load.
    const JobsFileEntry = struct {
        id: u64,
        gid: []const u8,
        url: []const u8,
        status: []const u8,
        game_id: u64 = 0,
        /// `@tagName(JobKind)` — defaults to "game" on older files.
        kind: []const u8 = "game",
        mod_id: ?u64 = null,
        /// Captured game version (from RPDL title / F95 scrape).
        /// Optional + additive so older jobs files still load.
        version: ?[]const u8 = null,
    };
    const JobsFile = struct {
        version: u32,
        next_id: u64,
        jobs: []const JobsFileEntry,
    };

    /// Atomic-write the current jobs table to `jobs_json_path`. Tmp
    /// file in the same directory + rename so a SIGKILL mid-write
    /// can't leave a corrupt file.
    fn persistJobs(self: *Manager) errs.Error!void {
        const path = self.jobs_json_path orelse return;

        var entries: std.ArrayList(JobsFileEntry) = .empty;
        defer entries.deinit(self.alloc);
        var it = self.jobs.iterator();
        while (it.next()) |kv| {
            const gid = self.job_gids.get(kv.key_ptr.*) orelse continue;
            const url = self.job_urls.get(kv.key_ptr.*) orelse continue;
            entries.append(self.alloc, .{
                .id = kv.key_ptr.*,
                .gid = gid,
                .url = url,
                .status = jobStatusToString(kv.value_ptr.status),
                .game_id = kv.value_ptr.game_id,
                .kind = @tagName(kv.value_ptr.kind),
                .mod_id = kv.value_ptr.mod_id,
                .version = kv.value_ptr.version,
            }) catch return errs.Error.OutOfMemory;
        }

        const file = JobsFile{
            .version = SESSION_SCHEMA_VERSION,
            .next_id = self.next_id,
            .jobs = entries.items,
        };

        var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(self.alloc, 1024) catch return errs.Error.OutOfMemory;
        defer aw.deinit();
        std.json.Stringify.value(file, .{}, &aw.writer) catch return errs.Error.OutOfMemory;

        atomic_io.writeFileAtomic(self.io, path, aw.writer.buffered()) catch return errs.Error.OutOfMemory;
    }

    /// Reload the jobs table from disk if present. Skips silently if
    /// the file is absent or the schema version differs (forward-compat
    /// stance — a future schema break shouldn't crash the app).
    fn loadJobsJson(self: *Manager) !void {
        const path = self.jobs_json_path orelse return;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(1 * 1024 * 1024)) catch |e| {
            if (e == error.FileNotFound) return;
            return e;
        };
        defer self.alloc.free(bytes);

        var parsed = std.json.parseFromSlice(JobsFile, self.alloc, bytes, .{
            .ignore_unknown_fields = true,
        }) catch |e| {
            log.warn("manager_jobs.json parse failed: {s}", .{@errorName(e)});
            return;
        };
        defer parsed.deinit();

        if (parsed.value.version != SESSION_SCHEMA_VERSION) {
            log.warn("manager_jobs.json schema v{d} != expected v{d}; ignoring", .{ parsed.value.version, SESSION_SCHEMA_VERSION });
            return;
        }

        self.next_id = parsed.value.next_id;
        for (parsed.value.jobs) |e| {
            const url_owned = self.alloc.dupe(u8, e.url) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(url_owned);
            const gid_owned = self.alloc.dupe(u8, e.gid) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(gid_owned);

            const version_owned: ?[]u8 = if (e.version) |v|
                (self.alloc.dupe(u8, v) catch return errs.Error.OutOfMemory)
            else
                null;
            errdefer if (version_owned) |v| self.alloc.free(v);

            const job: dom.Job = .{
                .id = e.id,
                .kind = jobKindFromString(e.kind),
                .game_id = e.game_id,
                .mod_id = e.mod_id,
                .source_url = url_owned,
                .version = version_owned,
                .dest_path = self.library_root,
                .status = jobStatusFromString(e.status),
            };
            try self.jobs.put(e.id, job);
            try self.job_urls.put(e.id, url_owned);
            try self.job_gids.put(e.id, gid_owned);
        }
        log.info("restored {d} job(s) from {s}", .{ self.jobs.count(), path });
    }
};

/// True iff the aria2 session file exists AND has more than the
/// touched-empty bytes from `ensureSessionFile`. Used as a "do we
/// actually have BT/HTTP state to resume" probe.
fn sessionFileNonEmpty(io: std.Io, path: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return false;
    defer f.close(io);
    const st = f.stat(io) catch return false;
    return st.size > 0;
}

fn jobStatusToString(s: dom.JobStatus) []const u8 {
    return @tagName(s);
}

fn jobStatusFromString(s: []const u8) dom.JobStatus {
    inline for (comptime std.meta.fieldNames(dom.JobStatus)) |name| {
        if (std.mem.eql(u8, s, name)) return @field(dom.JobStatus, name);
    }
    return .queued;
}

fn jobKindFromString(s: []const u8) dom.JobKind {
    if (std.mem.eql(u8, s, "mod")) return .mod;
    return .game;
}

const test_env = @import("util_test_env");

test "Manager init/deinit doesn't spawn aria2" {
    // No daemon means deinit must be safe even if init never happened.
    var mgr = Manager.init(
        std.testing.allocator,
        undefined, // io — never used since we don't enqueue
        "/tmp/lib",
        "/tmp/cache",
        "/tmp/dl/direct",
        "/tmp/dl/torrents",
        "aria2c",
        0,
        5.0,
        0,
    );
    mgr.deinit();
}

test "jobStatus round-trip" {
    try std.testing.expectEqual(dom.JobStatus.downloading, jobStatusFromString("downloading"));
    try std.testing.expectEqual(dom.JobStatus.done, jobStatusFromString("done"));
    try std.testing.expectEqual(dom.JobStatus.failed, jobStatusFromString("failed"));
    try std.testing.expectEqualStrings("downloading", jobStatusToString(.downloading));
    try std.testing.expectEqualStrings("queued", jobStatusToString(.queued));
    // Unknown string falls back to .queued (forward-compat).
    try std.testing.expectEqual(dom.JobStatus.queued, jobStatusFromString("future_status_we_dont_know"));
}

test "persistJobs / loadJobsJson round-trip" {
    const alloc = std.testing.allocator;
    var env = try test_env.TestEnv.init(alloc, "manager-jobs");
    defer env.deinit();
    const io = env.io;

    const path = try env.path("jobs.json");
    defer alloc.free(path);

    // ---- write side: populate maps directly + persist ----
    var write_mgr = Manager.init(alloc, io, "/tmp/lib", "/tmp/cache", "/tmp/dl/direct", "/tmp/dl/torrents", "aria2c", 0, 5.0, 0);
    defer write_mgr.deinit();
    write_mgr.jobs_json_path = path;

    const url1 = try alloc.dupe(u8, "https://example.com/a.zip");
    const gid1 = try alloc.dupe(u8, "abc123");
    try write_mgr.jobs.put(1, .{
        .id = 1,
        .kind = .game,
        .game_id = 14014,
        .mod_id = null,
        .source_url = url1,
        .dest_path = write_mgr.library_root,
        .status = .downloading,
    });
    try write_mgr.job_urls.put(1, url1);
    try write_mgr.job_gids.put(1, gid1);

    const url2 = try alloc.dupe(u8, "rpdl:67890");
    const gid2 = try alloc.dupe(u8, "deadbeef");
    try write_mgr.jobs.put(2, .{
        .id = 2,
        .kind = .game,
        .game_id = 0,
        .source_url = url2,
        .dest_path = write_mgr.library_root,
        .status = .done,
    });
    try write_mgr.job_urls.put(2, url2);
    try write_mgr.job_gids.put(2, gid2);
    write_mgr.next_id = 3;

    try write_mgr.persistJobs();

    // ---- read side: fresh Manager picks up the same jobs ----
    var read_mgr = Manager.init(alloc, io, "/tmp/lib", "/tmp/cache", "/tmp/dl/direct", "/tmp/dl/torrents", "aria2c", 0, 5.0, 0);
    defer read_mgr.deinit();
    read_mgr.jobs_json_path = path;
    try read_mgr.loadJobsJson();

    try std.testing.expectEqual(@as(usize, 2), read_mgr.jobs.count());
    try std.testing.expectEqual(@as(u64, 3), read_mgr.next_id);

    const j1 = read_mgr.jobs.get(1).?;
    try std.testing.expectEqualStrings("https://example.com/a.zip", j1.source_url);
    try std.testing.expectEqual(dom.JobStatus.downloading, j1.status);
    try std.testing.expectEqualStrings("abc123", read_mgr.job_gids.get(1).?);

    const j2 = read_mgr.jobs.get(2).?;
    try std.testing.expectEqualStrings("rpdl:67890", j2.source_url);
    try std.testing.expectEqual(dom.JobStatus.done, j2.status);
}

test "loadJobsJson handles missing file" {
    const alloc = std.testing.allocator;
    var env = try test_env.TestEnv.init(alloc, "manager-missing-jobs");
    defer env.deinit();

    const path = try env.path("missing-jobs.json");
    defer alloc.free(path);

    var mgr = Manager.init(alloc, env.io, "/tmp/lib", "/tmp/cache", "/tmp/dl/direct", "/tmp/dl/torrents", "aria2c", 0, 5.0, 0);
    defer mgr.deinit();
    mgr.jobs_json_path = path;
    try mgr.loadJobsJson(); // should be a no-op, not an error
    try std.testing.expectEqual(@as(usize, 0), mgr.jobs.count());
}
