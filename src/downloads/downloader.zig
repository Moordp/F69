//! Downloader v2 thread: command queue, snapshot, UI events, step driver.
//!
//! One thread (spawned by `start`) is the only writer of `dl_jobs`/`dl_events`
//! and the only caller of engines. The UI sends `Command`s, reads the
//! `Snapshot` under a short lock, and drains `UiEvent`s. `stepOnce(now)` is
//! one loop iteration and the test seam. Spec:
//! docs/superpowers/specs/2026-11-02-downloader-v2-design.md §3.1, §3.4, §3.7.
//!
//! Ownership: every string inside a job record is owned by `alloc`, or is a
//! static empty string / null (the same rule as `store.zig`). Engine refs
//! returned by `Engine.start` are freed with `alloc`, so engines must be
//! created with the same allocator as the Downloader.
const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");
const policy = @import("policy.zig");
const engine_mod = @import("engine.zig");
const verify = @import("verify.zig");
const archive = @import("archive.zig");
const workers = @import("workers.zig");

const Engine = engine_mod.Engine;
const sep = std.fs.path.sep_str;
const log = std.log.scoped(.downloader);

/// Loop period of the downloader thread.
const TICK_MS: i64 = 250;
/// Byte counters are written at most this often per job (seconds).
const BYTES_PERSIST_S: i64 = 5;
/// An engine that reported `daemon_gone` is not started again before this.
const ENGINE_RESTART_S: i64 = 30;
/// Terminal jobs kept in history (spec §3.3).
const HISTORY_KEEP: u32 = 500;

const NOT_ARCHIVE = "Not an archive — will install as a file";
const FOLDER_EXISTS = "Folder already exists — registering";
const MOD_ARCHIVE = "Mod archive — installed by the mod manager";
/// Written into an extract destination while f69 extracts into it.
const EXTRACT_MARKER = ".f69-extracting";

pub const EnqueueUrl = struct {
    url: []const u8,
    kind: model.Kind,
    game_thread_id: u64,
    mod_id: ?u64 = null,
    title: []const u8,
    version: ?[]const u8 = null,
    expected_sha256: ?[32]u8 = null,
    host: []const u8 = "",
    /// `Name: value` request headers (e.g. the donor cookie).
    headers: []const []const u8 = &.{},
};

pub const EnqueueTorrent = struct {
    /// Stored as the job's `source_href`; an "rpdl:" prefix marks RPDL.
    label: []const u8,
    torrent_bytes: []const u8,
    kind: model.Kind,
    game_thread_id: u64,
    mod_id: ?u64 = null,
    title: []const u8,
    version: ?[]const u8 = null,
};

/// Defined now; handled in stage 2 (Task 8).
pub const EnqueueCatalogue = struct {
    game_thread_id: u64,
    href: []const u8,
    title: []const u8,
    group_with: ?u64 = null,
};

/// UI → downloader. `send` deep-copies every string, so the caller's
/// buffers may be freed right after `send` returns.
pub const Command = union(enum) {
    enqueue_url: EnqueueUrl,
    enqueue_torrent: EnqueueTorrent,
    enqueue_catalogue: EnqueueCatalogue,
    pause: u64,
    unpause: u64,
    cancel: u64,
    retry: u64,
    remove: u64,
    pause_all,
    unpause_all,
    clear_history,
    stop_seeding: u64,
    /// Stage 3.
    paste_link: struct { job_id: u64, url: []const u8 },
    /// Stage 3.
    pick_file: struct { job_id: u64, path: []const u8 },
    /// Stage 3.
    accept_match: struct { job_id: u64, accept: bool },
    /// Stage 3.
    open_again: u64,
    install_ack: u64,
    install_failed: struct { job_id: u64, msg: []const u8 },
    /// Install again from what is on disk: a `done` job or one that failed
    /// at install goes back through extracting (an existing folder is
    /// registered as is) and raises `install_ready`; a seeding job raises
    /// `install_ready` at once. Other steps are ignored.
    retry_install: u64,
    reload_settings: policy.Settings,
    shutdown,
};

pub const InstallReady = struct {
    job_id: u64,
    game_thread_id: u64,
    kind: model.Kind,
    mod_id: ?u64,
    /// The downloaded file (`final_path`).
    archive_path: []const u8,
    /// Null when nothing was extracted (not an archive, or a mod).
    extracted_dir: ?[]const u8,
    version: ?[]const u8,
    source_is_rpdl: bool,
    expected_sha256: ?[32]u8,
};

/// Downloader → UI.
pub const UiEvent = union(enum) {
    install_ready: InstallReady,
    open_url: []const u8,
    toast: []const u8,
    sign_in_needed: enum { f95, mega },
};

pub const JobView = struct {
    /// Strings are snapshot-arena copies; `resolved_headers` is always empty
    /// (cookies never leave the downloader).
    job: model.Job,
    extract_pct: u8 = 0,
    /// Stage 3.
    awaiting_prompt: ?[]const u8 = null,
};

pub const Totals = struct {
    dl_speed: u64 = 0,
    ul_speed: u64 = 0,
    active: u32 = 0,
    waiting_for_user: u32 = 0,
    seeding: u32 = 0,
};

pub const Snapshot = struct {
    jobs: []const JobView = &.{},
    totals: Totals = .{},
    generation: u64 = 0,
};

pub const Engines = struct {
    aria2: Engine,
    megacmd: ?Engine = null,
    browser: ?Engine = null,
};

/// Borrowed: the caller keeps these alive for the Downloader's lifetime.
pub const Roots = struct {
    downloads_root: []const u8,
    library_root: []const u8,
    data_root: []const u8,
};

pub const EngineSlot = enum { aria2, megacmd, browser };

fn slotOf(e: model.EngineKind) EngineSlot {
    return switch (e) {
        .aria2_http, .aria2_torrent => .aria2,
        .megacmd => .megacmd,
        .browser => .browser,
    };
}

const PostKind = enum { verify, extract };

/// A verify or extract run. Owns copies of its paths so the job record may
/// change or go away while the thread runs.
const PostWorker = struct {
    w: workers.Worker(?model.FailReason) = .{},
    kind: PostKind,
    alloc: std.mem.Allocator,
    io: std.Io,
    src: []u8,
    dest: []const u8 = &.{},
    /// `<dest>/.f69-extracting`, removed when the extract succeeds.
    marker: []const u8 = &.{},
    sha: [32]u8 = @splat(0),

    fn run(pw: *PostWorker) ?model.FailReason {
        switch (pw.kind) {
            .verify => {
                verify.verifyFile(pw.io, pw.src, pw.sha) catch return .checksum_mismatch;
                return null;
            },
            .extract => {
                archive.extract(pw.alloc, pw.io, pw.src, pw.dest, .{}) catch |e| {
                    log.warn("extract '{s}' failed: {s}", .{ pw.src, @errorName(e) });
                    return if (e == error.DiskFull) .disk_full else .bad_archive;
                };
                std.Io.Dir.cwd().deleteFile(pw.io, pw.marker) catch |e|
                    log.warn("removing '{s}' failed: {s}", .{ pw.marker, @errorName(e) });
                return null;
            },
        }
    }

    fn destroy(pw: *PostWorker) void {
        pw.w.join();
        pw.alloc.free(pw.src);
        pw.alloc.free(pw.dest);
        pw.alloc.free(pw.marker);
        pw.alloc.destroy(pw);
    }
};

/// One job as the downloader holds it.
pub const Rec = struct {
    job: model.Job,
    /// Owned copy for the first start of an `enqueue_torrent` job.
    torrent_bytes: ?[]u8 = null,
    worker: ?*PostWorker = null,
    /// step/detail/fail/etc. changed since the last `store.update`.
    dirty: bool = false,
    bytes_dirty: bool = false,
    bytes_saved_at: i64 = 0,
};

const Queued = struct { cmd: Command, arena: std.heap.ArenaAllocator };

pub const Downloader = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    store: store_mod.Store,
    engines: Engines,
    roots: Roots,
    settings: policy.Settings,
    /// Owns `settings` strings after a `reload_settings`; null while they
    /// are the caller's (from `init`).
    settings_arena: ?std.heap.ArenaAllocator = null,

    /// Ordered by id (FIFO). Only the downloader thread touches it.
    recs: std.ArrayList(*Rec) = .empty,
    /// Workers whose job was removed while they ran; freed once done.
    orphans: std.ArrayList(*PostWorker) = .empty,
    loaded: bool = false,

    cmd_lock: std.Io.Mutex = .init,
    cmds: std.ArrayList(Queued) = .empty,

    ev_lock: std.Io.Mutex = .init,
    events: std.ArrayList(UiEvent) = .empty,

    /// Guards `cur` and the snapshot the UI reads. The other buffer is
    /// built without the lock and swapped in.
    snap_lock: std.Io.Mutex = .init,
    snap_arenas: [2]std.heap.ArenaAllocator,
    snaps: [2]Snapshot = .{ .{}, .{} },
    cur: u1 = 0,
    generation: u64 = 0,

    wake_fn: ?*const fn (?*anyopaque) void = null,
    wake_ctx: ?*anyopaque = null,

    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),

    /// When an engine last reported its daemon gone; null = up.
    down_since: std.EnumArray(EngineSlot, ?i64) = .initFill(null),
    /// Plan last applied per engine; null = apply on the next tick.
    last_plan: std.EnumArray(EngineSlot, ?policy.Plan) = .initFill(null),
    /// Something visible changed this tick (publish even when idle).
    touched: bool = true,
    /// A job reached a terminal step since the last history trim.
    trim_due: bool = false,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        store: store_mod.Store,
        engines: Engines,
        roots: Roots,
        settings: policy.Settings,
    ) Downloader {
        return .{
            .alloc = alloc,
            .io = io,
            .store = store,
            .engines = engines,
            .roots = roots,
            .settings = settings,
            .snap_arenas = .{ .init(alloc), .init(alloc) },
        };
    }

    /// Stops the thread if running, waits for workers, frees everything and
    /// closes the store. Engines belong to the caller.
    pub fn deinit(self: *Downloader) void {
        self.stop();
        for (self.recs.items) |r| self.freeRec(r);
        self.recs.deinit(self.alloc);
        for (self.orphans.items) |pw| pw.destroy();
        self.orphans.deinit(self.alloc);
        for (self.cmds.items) |*q| q.arena.deinit();
        self.cmds.deinit(self.alloc);
        for (self.events.items) |e| freeEvent(self.alloc, e);
        self.events.deinit(self.alloc);
        for (&self.snap_arenas) |*a| a.deinit();
        if (self.settings_arena) |*a| a.deinit();
        self.store.close();
    }

    // ------------------------------------------------------------ public API

    /// Spawn the loop. The thread itself loads and reconciles the stored
    /// jobs before its first tick, so the caller (the UI) does no I/O here.
    pub fn start(self: *Downloader) !void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |e| {
            self.running.store(false, .release);
            return e;
        };
    }

    /// Send `shutdown` and join the thread. No-op when not started.
    pub fn stop(self: *Downloader) void {
        const t = self.thread orelse return;
        self.send(.shutdown);
        // Fallback in case the command could not be queued (OOM).
        self.running.store(false, .release);
        t.join();
        self.thread = null;
    }

    /// Queue a command (deep copy). Thread-safe.
    pub fn send(self: *Downloader, cmd: Command) void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        const copy = cloneCommand(arena.allocator(), cmd) catch {
            arena.deinit();
            log.err("command {s} dropped: out of memory", .{@tagName(cmd)});
            return;
        };
        self.cmd_lock.lockUncancelable(self.io);
        defer self.cmd_lock.unlock(self.io);
        self.cmds.append(self.alloc, .{ .cmd = copy, .arena = arena }) catch {
            arena.deinit();
            log.err("command {s} dropped: out of memory", .{@tagName(cmd)});
        };
    }

    /// Lock and return the current snapshot. The caller must call
    /// `releaseSnapshot` when done reading (keep it short: the loop waits).
    pub fn snapshot(self: *Downloader) *const Snapshot {
        self.snap_lock.lockUncancelable(self.io);
        return &self.snaps[self.cur];
    }

    pub fn releaseSnapshot(self: *Downloader) void {
        self.snap_lock.unlock(self.io);
    }

    /// Take every pending UI event; strings are duped with `alloc`. Free
    /// with `freeEvents(alloc, events)`. On out-of-memory returns an empty
    /// slice and keeps the events for the next call.
    pub fn drainEvents(self: *Downloader, alloc: std.mem.Allocator) []UiEvent {
        self.ev_lock.lockUncancelable(self.io);
        defer self.ev_lock.unlock(self.io);
        if (self.events.items.len == 0) return &.{};
        const out = alloc.alloc(UiEvent, self.events.items.len) catch return &.{};
        var n: usize = 0;
        for (self.events.items) |e| {
            out[n] = cloneEvent(alloc, e) catch {
                for (out[0..n]) |d| freeEvent(alloc, d);
                alloc.free(out);
                return &.{};
            };
            n += 1;
        }
        for (self.events.items) |e| freeEvent(self.alloc, e);
        self.events.clearRetainingCapacity();
        return out;
    }

    pub fn freeEvents(alloc: std.mem.Allocator, events: []UiEvent) void {
        if (events.len == 0) return;
        for (events) |e| freeEvent(alloc, e);
        alloc.free(events);
    }

    /// Wire the UI wake-up, called after each snapshot publish. Set before
    /// `start`.
    pub fn setWake(self: *Downloader, ctx: ?*anyopaque, f: *const fn (?*anyopaque) void) void {
        self.wake_ctx = ctx;
        self.wake_fn = f;
    }

    /// Load every stored job into memory. Called by `start`; tests call it
    /// directly before `reconcile`. Idempotent.
    pub fn load(self: *Downloader) !void {
        if (self.loaded) return;
        const jobs = try self.store.loadAll(self.alloc);
        defer self.alloc.free(jobs);
        var i: usize = 0;
        errdefer for (jobs[i..]) |*j| freeJobStrings(self.alloc, j);
        while (i < jobs.len) : (i += 1) {
            const r = try self.alloc.create(Rec);
            r.* = .{ .job = jobs[i] };
            self.recs.append(self.alloc, r) catch {
                self.alloc.destroy(r);
                return error.OutOfMemory;
            };
        }
        self.loaded = true;
    }

    /// Startup reconciliation (spec §3.3) of loaded, non-terminal jobs.
    pub fn reconcile(self: *Downloader) void {
        const now = self.nowSeconds();
        for (self.recs.items) |r| self.reconcileOne(r, now);
        self.persist(now);
        self.publish();
    }

    /// One loop iteration. Order: commands, start queued jobs, poll
    /// engines (side effects run as transitions apply), worker results,
    /// retry ticks (then a second scheduling pass so freed slots and due
    /// retries start this tick), persist, limits, publish.
    pub fn stepOnce(self: *Downloader, now: i64) void {
        self.drainCommands(now);
        self.schedule(now);
        self.pollEngines(now);
        self.reapWorkers(now);
        self.tickRetries(now);
        self.schedule(now);
        self.persist(now);
        self.applyLimits(now);
        // An idle app (only terminal jobs, nothing changed) must not wake
        // the UI four times a second.
        if (self.touched or self.anyLive()) self.publish();
        self.touched = false;
    }

    fn anyLive(self: *Downloader) bool {
        for (self.recs.items) |r| if (!r.job.step.isTerminal()) return true;
        return false;
    }

    pub fn find(self: *Downloader, id: u64) ?*Rec {
        for (self.recs.items) |r| if (r.job.id == id) return r;
        return null;
    }

    // ------------------------------------------------------------ loop

    fn nowSeconds(self: *Downloader) i64 {
        return std.Io.Clock.Timestamp.now(self.io, .real).raw.toSeconds();
    }

    fn threadMain(self: *Downloader) void {
        self.load() catch |e| log.err("loading stored downloads failed: {s}", .{@errorName(e)});
        self.reconcile();
        while (self.running.load(.acquire)) {
            self.stepOnce(self.nowSeconds());
            if (!self.running.load(.acquire)) break;
            self.io.sleep(std.Io.Duration.fromMilliseconds(TICK_MS), .real) catch {};
        }
    }

    fn drainCommands(self: *Downloader, now: i64) void {
        self.cmd_lock.lockUncancelable(self.io);
        var batch = self.cmds;
        self.cmds = .empty;
        self.cmd_lock.unlock(self.io);
        defer batch.deinit(self.alloc);
        for (batch.items) |*q| {
            self.handle(q, now);
            q.arena.deinit();
        }
    }

    fn handle(self: *Downloader, q: *Queued, now: i64) void {
        switch (q.cmd) {
            .enqueue_url => |e| self.enqueueUrl(e, now),
            .enqueue_torrent => |e| self.enqueueTorrent(e, now),
            .enqueue_catalogue => |e| log.warn("enqueue_catalogue not implemented yet (stage 2); dropped {s}", .{e.href}),
            .pause => |id| self.userInput(id, .user_pause, now),
            .unpause => |id| self.userInput(id, .user_resume, now),
            .cancel => |id| self.userInput(id, .user_cancel, now),
            .retry => |id| self.userInput(id, .user_retry, now),
            .remove => |id| if (self.indexOf(id)) |i| self.removeAt(i, now),
            .pause_all => for (self.recs.items) |r| self.transition(r, .user_pause, now, null),
            .unpause_all => for (self.recs.items) |r| self.transition(r, .user_resume, now, null),
            .clear_history => {
                var i = self.recs.items.len;
                while (i > 0) {
                    i -= 1;
                    if (self.recs.items[i].job.step.isTerminal()) self.removeAt(i, now);
                }
            },
            .stop_seeding => |id| if (self.find(id)) |r| {
                if (r.job.step != .seeding) return;
                self.cancelEngine(r);
                self.apply(r, .{ .step = .done, .attempts = r.job.attempts }, now);
            },
            .paste_link, .pick_file, .accept_match, .open_again => log.warn("{s} not implemented yet (stage 3); dropped", .{@tagName(q.cmd)}),
            .install_ack => |id| if (self.find(id)) |r| {
                self.transition(r, .install_ack, now, null);
                // A re-install of a finished torrent has no transfer left
                // to seed: it goes back to done, not seeding.
                if (r.job.step == .seeding and r.job.engine_ref == null)
                    self.apply(r, .{ .step = .done, .attempts = r.job.attempts }, now);
            },
            .retry_install => |id| if (self.find(id)) |r| self.retryInstall(r, now),
            .install_failed => |f| if (self.find(f.job_id)) |r| self.transition(r, .{ .install_err = f.msg }, now, null),
            .reload_settings => |s| self.reloadSettings(s),
            .shutdown => self.running.store(false, .release),
        }
    }

    fn retryInstall(self: *Downloader, r: *Rec, now: i64) void {
        const j = &r.job;
        if (j.step == .seeding) return self.raiseInstall(r);
        const again = j.step == .done or (j.step == .failed and j.fail == .install_failed);
        if (!again) {
            log.warn("job {d}: retry_install ignored in step {s}", .{ j.id, @tagName(j.step) });
            return;
        }
        self.apply(r, .{ .step = .extracting, .attempts = j.attempts }, now);
        self.startExtract(r, now);
    }

    fn userInput(self: *Downloader, id: u64, input: model.Input, now: i64) void {
        const r = self.find(id) orelse return;
        self.transition(r, input, now, null);
    }

    fn reloadSettings(self: *Downloader, s: policy.Settings) void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        const a = arena.allocator();
        var copy = s;
        copy.watch_dir = a.dupe(u8, s.watch_dir) catch {
            arena.deinit();
            log.warn("reload_settings dropped: out of memory", .{});
            return;
        };
        copy.megacmd_path = a.dupe(u8, s.megacmd_path) catch {
            arena.deinit();
            log.warn("reload_settings dropped: out of memory", .{});
            return;
        };
        if (self.settings_arena) |*old| old.deinit();
        self.settings_arena = arena;
        self.settings = copy;
        self.last_plan = .initFill(null);
        self.touched = true;
    }

    fn engineKindForUrl(url: []const u8) model.EngineKind {
        if (std.mem.startsWith(u8, url, "magnet:") or std.mem.endsWith(u8, url, ".torrent")) return .aria2_torrent;
        return .aria2_http;
    }

    fn enqueueUrl(self: *Downloader, e: EnqueueUrl, now: i64) void {
        const job: model.Job = .{
            .id = 0,
            .group_id = 0,
            .kind = e.kind,
            .game_thread_id = e.game_thread_id,
            .mod_id = e.mod_id,
            .title = e.title,
            .source_href = e.url,
            .host = e.host,
            .engine = engineKindForUrl(e.url),
            .version = e.version,
            .step = .queued,
            .resolved_headers = e.headers,
            .dest_dir = "",
            .expected_sha256 = e.expected_sha256,
            .created_at = now,
            .updated_at = now,
        };
        _ = self.addJob(&job, null, now);
    }

    fn enqueueTorrent(self: *Downloader, e: EnqueueTorrent, now: i64) void {
        const job: model.Job = .{
            .id = 0,
            .group_id = 0,
            .kind = e.kind,
            .game_thread_id = e.game_thread_id,
            .mod_id = e.mod_id,
            .title = e.title,
            .source_href = e.label,
            .host = "torrent",
            .engine = .aria2_torrent,
            .version = e.version,
            .step = .queued,
            .dest_dir = "",
            .created_at = now,
            .updated_at = now,
        };
        _ = self.addJob(&job, e.torrent_bytes, now);
    }

    /// Insert (to get the id), set `dest_dir`, keep an owned copy in memory.
    fn addJob(self: *Downloader, tmpl: *const model.Job, torrent: ?[]const u8, now: i64) ?*Rec {
        const id = self.store.insert(tmpl) catch {
            self.toast("Could not queue the download (database error)");
            return null;
        };
        const r = self.alloc.create(Rec) catch return self.addFailed(id);
        r.* = .{ .job = cloneJob(self.alloc, tmpl.*) catch {
            self.alloc.destroy(r);
            return self.addFailed(id);
        } };
        r.job.id = id;
        if (r.job.group_id == 0) r.job.group_id = id;
        r.job.dest_dir = std.fmt.allocPrint(self.alloc, "{s}" ++ sep ++ "{s}" ++ sep ++ "{d}" ++ sep, .{
            self.roots.downloads_root, @tagName(r.job.engine), id,
        }) catch {
            self.freeRec(r);
            return self.addFailed(id);
        };
        if (torrent) |b| r.torrent_bytes = self.alloc.dupe(u8, b) catch {
            self.freeRec(r);
            return self.addFailed(id);
        };
        self.recs.append(self.alloc, r) catch {
            self.freeRec(r);
            return self.addFailed(id);
        };
        self.store.update(&r.job) catch log.err("job {d}: dest_dir not stored", .{id});
        self.store.addEvent(id, now, .queued, "enqueued") catch |e|
            log.warn("job {d}: event not stored: {s}", .{ id, @errorName(e) });
        self.touched = true;
        return r;
    }

    fn addFailed(self: *Downloader, id: u64) ?*Rec {
        self.store.remove(id) catch {};
        self.toast("Could not queue the download (out of memory)");
        return null;
    }

    fn indexOf(self: *Downloader, id: u64) ?usize {
        for (self.recs.items, 0..) |r, i| if (r.job.id == id) return i;
        return null;
    }

    fn removeAt(self: *Downloader, i: usize, now: i64) void {
        const r = self.recs.items[i];
        if (!r.job.step.isTerminal()) self.transition(r, .user_cancel, now, null);
        self.cancelEngine(r);
        self.store.remove(r.job.id) catch log.err("job {d}: remove from store failed", .{r.job.id});
        _ = self.recs.orderedRemove(i);
        self.freeRec(r);
        self.touched = true;
    }

    // ------------------------------------------------------------ scheduling

    /// True for steps that hold a download slot.
    fn holdsSlot(s: model.Step) bool {
        return switch (s) {
            .resolving, .downloading, .fetching_metadata, .finding_peers => true,
            else => false,
        };
    }

    fn activeCounts(self: *Downloader) policy.ActiveCounts {
        var a: policy.ActiveCounts = .{ .files_downloading = 0, .torrents_downloading = 0, .any_downloading = false };
        for (self.recs.items) |r| {
            if (!holdsSlot(r.job.step)) continue;
            if (policy.isFileEngine(r.job.engine)) a.files_downloading += 1 else a.torrents_downloading += 1;
            a.any_downloading = true;
        }
        return a;
    }

    /// Engine down for less than `ENGINE_RESTART_S`: hold its queued jobs.
    /// Once the window has passed the engine is treated as up again and the
    /// next `start` respawns it.
    fn engineGated(self: *Downloader, kind: model.EngineKind, now: i64) bool {
        const slot = slotOf(kind);
        const since = self.down_since.get(slot) orelse return false;
        if (now - since < ENGINE_RESTART_S) return true;
        self.down_since.set(slot, null);
        self.last_plan.set(slot, null);
        return false;
    }

    fn markDown(self: *Downloader, kind: model.EngineKind, now: i64) void {
        const slot = slotOf(kind);
        if (self.down_since.get(slot) == null) {
            log.warn("{s} engine reported its daemon gone", .{@tagName(slot)});
            self.down_since.set(slot, now);
        }
        self.last_plan.set(slot, null);
    }

    fn schedule(self: *Downloader, now: i64) void {
        var counts = self.activeCounts();
        for (self.recs.items) |r| {
            if (r.job.step != .queued) continue;
            if (!policy.hasSlot(self.settings, counts, r.job.engine)) continue;
            if (self.engineGated(r.job.engine, now)) continue;
            self.transition(r, .slot_free, now, null);
            if (r.job.step == .resolving) self.startResolve(r, now);
            counts = self.activeCounts();
        }
    }

    /// Resolver hook. Stage 1: the link is used as is. Task 8 replaces this
    /// with the resolver worker.
    fn startResolve(self: *Downloader, r: *Rec, now: i64) void {
        self.transition(r, .{ .resolved = .{ .engine = r.job.engine } }, now, null);
    }

    fn engineFor(self: *Downloader, kind: model.EngineKind) ?Engine {
        return switch (slotOf(kind)) {
            .aria2 => self.engines.aria2,
            .megacmd => self.engines.megacmd,
            .browser => self.engines.browser,
        };
    }

    fn missingEngine(self: *Downloader, r: *Rec, now: i64) void {
        const t: model.Transition = switch (r.job.engine) {
            .megacmd => .{ .step = .failed, .fail = .engine_missing, .detail = "MEGAcmd is not installed", .attempts = r.job.attempts },
            else => .{ .step = .failed, .fail = .unknown, .detail = "This host needs the browser flow (coming in 0.15.18)", .attempts = r.job.attempts },
        };
        self.apply(r, t, now);
    }

    fn startEngine(self: *Downloader, r: *Rec, now: i64) void {
        const eng = self.engineFor(r.job.engine) orelse return self.missingEngine(r, now);
        if (r.job.engine == .aria2_torrent and r.torrent_bytes == null and !isFetchableTorrentHref(r.job.source_href)) {
            // Stage-1 limit: the .torrent body is kept in memory only.
            return self.apply(r, .{
                .step = .failed,
                .fail = .unknown,
                .detail = "Torrent file is gone after restart — start the download again",
                .attempts = 3,
            }, now);
        }
        // A retried job may still hold the previous ref: drop it first.
        self.cancelEngine(r);
        const ref = eng.start(.{
            .job_id = r.job.id,
            .url = r.job.resolved_url orelse r.job.source_href,
            .headers = r.job.resolved_headers,
            .dest_dir = r.job.dest_dir,
            .out_name = null,
            .torrent_bytes = r.torrent_bytes,
        }) catch |e| {
            log.warn("job {d}: engine start failed: {s}", .{ r.job.id, @errorName(e) });
            const reason: model.FailReason = switch (e) {
                error.DiskFull => .disk_full,
                error.AriaRpcError, error.AriaInvalidResponse => .unknown,
                else => .network,
            };
            if (e == error.AriaSpawnFailed or e == error.AriaStartTimeout) self.markDown(r.job.engine, now);
            const p: model.Progress = .{ .phase = .failed, .fail = reason, .msg = @errorName(e) };
            self.transition(r, .{ .engine_progress = .{ .p = p, .now = now } }, now, null);
            return;
        };
        r.job.engine_ref = ref;
        r.job.bytes_done = 0;
        r.job.bytes_uploaded = 0;
        r.dirty = true;
    }

    fn cancelEngine(self: *Downloader, r: *Rec) void {
        const ref = r.job.engine_ref orelse return;
        if (self.engineFor(r.job.engine)) |eng| eng.cancel(ref) catch |e|
            log.warn("job {d}: engine cancel failed: {s}", .{ r.job.id, @errorName(e) });
        self.alloc.free(ref);
        r.job.engine_ref = null;
        r.dirty = true;
    }

    fn pollable(r: *const Rec) bool {
        const s = r.job.step;
        if (r.job.engine_ref == null or s.isTerminal()) return false;
        if (s == .queued or s == .resolving or s == .awaiting_user) return false;
        // After the payload is complete only torrents still report (seeding).
        if (s.isPostTransfer() and r.job.engine != .aria2_torrent) return false;
        return true;
    }

    fn pollEngines(self: *Downloader, now: i64) void {
        for (self.recs.items) |r| {
            if (!pollable(r)) continue;
            const eng = self.engineFor(r.job.engine) orelse continue;
            const p = eng.poll(r.job.engine_ref.?) catch |e| {
                log.warn("job {d}: poll failed: {s}", .{ r.job.id, @errorName(e) });
                continue;
            };
            // `p.msg` is copied by `apply` before the next poll.
            self.absorbProgress(r, eng, p, now);
        }
    }

    fn absorbProgress(self: *Downloader, r: *Rec, eng: Engine, p: model.Progress, now: i64) void {
        const j = &r.job;
        if (p.phase == .daemon_gone) {
            self.markDown(j.engine, now);
        } else if (p.phase != .removed and p.phase != .failed) {
            if (j.bytes_done != p.bytes_done or !std.meta.eql(j.bytes_total, p.bytes_total) or j.bytes_uploaded != p.bytes_uploaded) r.bytes_dirty = true;
            j.bytes_done = p.bytes_done;
            j.bytes_total = p.bytes_total;
            j.bytes_uploaded = p.bytes_uploaded;
        }
        j.dl_speed = p.dl_speed;
        j.ul_speed = p.ul_speed;
        j.peers = p.peers;
        j.seeders = p.seeders;
        if ((p.phase == .transfer_done or p.phase == .seeding) and j.final_path == null) {
            if (p.final_path) |fp| {
                j.final_path = self.alloc.dupe(u8, fp) catch null;
            } else {
                j.final_path = eng.finalPath(self.alloc, j.engine_ref.?) catch null;
            }
            if (j.final_path != null) r.dirty = true;
        }
        self.transition(r, .{ .engine_progress = .{ .p = p, .now = now } }, now, null);
    }

    fn tickRetries(self: *Downloader, now: i64) void {
        for (self.recs.items) |r| {
            if (r.job.next_retry_at == null) continue;
            self.transition(r, .{ .tick = now }, now, null);
        }
    }

    // ------------------------------------------------------------ transitions

    /// `advance` + apply + side effect. `detail` overrides the transition's
    /// detail line when set.
    fn transition(self: *Downloader, r: *Rec, input: model.Input, now: i64, detail: ?[]const u8) void {
        var t = model.advance(&r.job, input);
        // Only a real step change takes the override (a late worker result
        // for a cancelled job must not rewrite its line).
        if (detail) |d| {
            if (t.step != r.job.step) t.detail = d;
        }
        self.apply(r, t, now);
        self.runEffect(r, t.side_effect, now);
    }

    /// Copy the transition onto the job. When the step, detail or failure
    /// changed, the `dl_events` row is written here at once; the `dl_jobs`
    /// row is marked dirty and written by `persist` at the end of the tick.
    fn apply(self: *Downloader, r: *Rec, t: model.Transition, now: i64) void {
        const j = &r.job;
        const step_changed = j.step != t.step;
        const detail_changed = !std.mem.eql(u8, j.step_detail, t.detail);
        const fail_changed = !std.meta.eql(j.fail, t.fail);
        const other_changed = !std.meta.eql(j.next_retry_at, t.next_retry_at) or j.attempts != t.attempts or !std.meta.eql(j.resume_step, t.resume_step);
        if (!step_changed and !detail_changed and !fail_changed and !other_changed) return;

        if (detail_changed) self.setStr(&j.step_detail, t.detail);
        j.step = t.step;
        j.fail = t.fail;
        j.next_retry_at = t.next_retry_at;
        j.attempts = t.attempts;
        j.resume_step = t.resume_step;
        if (t.fail != null) {
            if (detail_changed or fail_changed) self.setStr(&j.fail_msg, j.step_detail);
        } else if (j.fail_msg.len > 0) {
            self.setStr(&j.fail_msg, "");
        }
        j.updated_at = now;
        if (t.step.isTerminal()) {
            if (step_changed) j.finished_at = now;
        } else {
            j.finished_at = null;
        }
        r.dirty = true;
        self.touched = true;
        if (step_changed and t.step.isTerminal()) self.trim_due = true;
        if (step_changed or detail_changed or fail_changed) {
            self.store.addEvent(j.id, now, j.step, j.step_detail) catch |e|
                log.warn("job {d}: event not stored: {s}", .{ j.id, @errorName(e) });
        }
    }

    fn runEffect(self: *Downloader, r: *Rec, effect: model.SideEffect, now: i64) void {
        switch (effect) {
            .none => {},
            .start_engine => self.startEngine(r, now),
            .cancel_engine => self.cancelEngine(r),
            .pause_engine => if (r.job.engine_ref) |ref| if (self.engineFor(r.job.engine)) |eng|
                eng.pause(ref) catch |e| log.warn("job {d}: pause failed: {s}", .{ r.job.id, @errorName(e) }),
            .resume_engine => if (r.job.engine_ref) |ref| if (self.engineFor(r.job.engine)) |eng|
                eng.unpause(ref) catch |e| log.warn("job {d}: resume failed: {s}", .{ r.job.id, @errorName(e) }),
            .start_verify => self.startVerify(r, now),
            .start_extract => self.startExtract(r, now),
            .raise_install => self.raiseInstall(r),
            .delete_file_and_restart => {
                if (r.job.final_path) |fp| {
                    std.Io.Dir.cwd().deleteFile(self.io, fp) catch |e|
                        log.warn("job {d}: delete '{s}' failed: {s}", .{ r.job.id, fp, @errorName(e) });
                    self.alloc.free(fp);
                    r.job.final_path = null;
                }
                self.cancelEngine(r);
                r.job.bytes_done = 0;
                r.job.bytes_uploaded = 0;
                r.dirty = true;
            },
            .open_browser => self.pushEvent(.{ .open_url = r.job.source_href }),
        }
    }

    fn startVerify(self: *Downloader, r: *Rec, now: i64) void {
        const path = r.job.final_path orelse
            return self.transition(r, .{ .verify_err = .bad_archive }, now, "The downloaded file could not be found");
        if (r.job.expected_sha256) |sha| {
            const pw = self.newWorker(.verify, path, null, null) catch
                return self.transition(r, .{ .verify_err = .unknown }, now, "Could not start the checksum check");
            pw.sha = sha;
            self.spawnWorker(r, pw, now);
            return;
        }
        const st = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch
            return self.transition(r, .{ .verify_err = .bad_archive }, now, "The downloaded file is missing");
        if (st.size == 0) return self.transition(r, .{ .verify_err = .bad_archive }, now, "The downloaded file is empty");
        const detail: ?[]const u8 = if (archive.detectFormat(path) == .unknown) NOT_ARCHIVE else null;
        self.transition(r, .verify_ok, now, detail);
    }

    fn startExtract(self: *Downloader, r: *Rec, now: i64) void {
        const path = r.job.final_path orelse
            return self.transition(r, .{ .extract_err = .bad_archive }, now, "The downloaded file could not be found");
        if (archive.detectFormat(path) == .unknown) return self.transition(r, .extract_ok, now, NOT_ARCHIVE);
        if (r.job.kind == .mod) return self.transition(r, .extract_ok, now, MOD_ARCHIVE);
        const dir = self.extractDir(&r.job) catch
            return self.transition(r, .{ .extract_err = .unknown }, now, "Out of memory");
        const marker = std.fmt.allocPrint(self.alloc, "{s}" ++ EXTRACT_MARKER, .{dir}) catch {
            self.alloc.free(dir);
            return self.transition(r, .{ .extract_err = .unknown }, now, "Out of memory");
        };
        const cwd = std.Io.Dir.cwd();
        if ((cwd.access(self.io, marker, .{}) catch null) != null) {
            // Our own interrupted extract: start over from an empty folder.
            log.info("job {d}: clearing half-extracted '{s}'", .{ r.job.id, dir });
            cwd.deleteTree(self.io, dir) catch |e|
                log.warn("job {d}: clearing '{s}' failed: {s}", .{ r.job.id, dir, @errorName(e) });
        } else if (dirHasEntries(self.io, dir)) {
            self.alloc.free(marker);
            self.alloc.free(dir);
            return self.transition(r, .extract_ok, now, FOLDER_EXISTS);
        }
        writeMarker(self.io, dir, marker);
        const pw = self.newWorker(.extract, path, dir, marker) catch {
            self.alloc.free(marker);
            self.alloc.free(dir);
            return self.transition(r, .{ .extract_err = .unknown }, now, "Could not start extracting");
        };
        self.spawnWorker(r, pw, now);
    }

    /// Takes ownership of `dest` and `marker` on success.
    fn newWorker(self: *Downloader, kind: PostKind, src: []const u8, dest: ?[]u8, marker: ?[]u8) !*PostWorker {
        const pw = try self.alloc.create(PostWorker);
        errdefer self.alloc.destroy(pw);
        pw.* = .{ .kind = kind, .alloc = self.alloc, .io = self.io, .src = try self.alloc.dupe(u8, src) };
        pw.dest = dest orelse &.{};
        pw.marker = marker orelse &.{};
        return pw;
    }

    fn spawnWorker(self: *Downloader, r: *Rec, pw: *PostWorker, now: i64) void {
        pw.w.spawn(PostWorker.run, .{pw}) catch |e| {
            log.err("job {d}: worker spawn failed: {s}", .{ r.job.id, @errorName(e) });
            const kind = pw.kind;
            pw.destroy();
            const input: model.Input = if (kind == .verify) .{ .verify_err = .unknown } else .{ .extract_err = .unknown };
            return self.transition(r, input, now, "Could not start a worker thread");
        };
        if (r.worker) |old| self.orphan(old);
        r.worker = pw;
    }

    fn orphan(self: *Downloader, pw: *PostWorker) void {
        self.orphans.append(self.alloc, pw) catch {
            // Last resort: wait for it here rather than leak or free early.
            pw.destroy();
        };
    }

    fn reapWorkers(self: *Downloader, now: i64) void {
        for (self.recs.items) |r| {
            const pw = r.worker orelse continue;
            const res = pw.w.take() orelse continue;
            const kind = pw.kind;
            r.worker = null;
            pw.destroy();
            const input: model.Input = switch (kind) {
                .verify => if (res) |reason| .{ .verify_err = reason } else .verify_ok,
                .extract => if (res) |reason| .{ .extract_err = reason } else .extract_ok,
            };
            const detail: ?[]const u8 = if (res != null) switch (kind) {
                .verify => "Checksum does not match — Retry downloads it again",
                .extract => "Could not extract the archive",
            } else null;
            self.transition(r, input, now, detail);
        }
        var i: usize = 0;
        while (i < self.orphans.items.len) {
            const pw = self.orphans.items[i];
            if (pw.w.take() != null) {
                pw.destroy();
                _ = self.orphans.swapRemove(i);
            } else i += 1;
        }
    }

    /// `<library_root>/<game_thread_id>/<version or "unversioned">/`.
    fn extractDir(self: *Downloader, j: *const model.Job) ![]u8 {
        var vbuf: [128]u8 = undefined;
        const v = safeSegment(&vbuf, j.version);
        return std.fmt.allocPrint(self.alloc, "{s}" ++ sep ++ "{d}" ++ sep ++ "{s}" ++ sep, .{ self.roots.library_root, j.game_thread_id, v });
    }

    fn installReady(self: *Downloader, j: *const model.Job) !InstallReady {
        const archive_path = j.final_path orelse "";
        const extracted: ?[]u8 = if (j.kind != .mod and archive.detectFormat(archive_path) != .unknown) try self.extractDir(j) else null;
        return .{
            .job_id = j.id,
            .game_thread_id = j.game_thread_id,
            .kind = j.kind,
            .mod_id = j.mod_id,
            .archive_path = archive_path,
            .extracted_dir = extracted,
            .version = j.version,
            .source_is_rpdl = std.mem.startsWith(u8, j.source_href, "rpdl:"),
            .expected_sha256 = j.expected_sha256,
        };
    }

    fn raiseInstall(self: *Downloader, r: *Rec) void {
        const ev = self.installReady(&r.job) catch {
            log.err("job {d}: install_ready dropped: out of memory", .{r.job.id});
            return;
        };
        defer if (ev.extracted_dir) |d| self.alloc.free(d);
        self.pushEvent(.{ .install_ready = ev });
    }

    // ------------------------------------------------------------ reconcile

    fn reconcileOne(self: *Downloader, r: *Rec, now: i64) void {
        const j = &r.job;
        switch (j.step) {
            .done, .failed, .cancelled, .queued => {},
            .installing => self.raiseInstall(r),
            .verifying => self.startVerify(r, now),
            .extracting => self.startExtract(r, now),
            .awaiting_user => if (j.engine != .browser) self.apply(r, .{ .step = .queued, .attempts = j.attempts }, now),
            .resolving => self.apply(r, .{ .step = .queued, .attempts = j.attempts }, now),
            .fetching_metadata, .finding_peers, .downloading, .paused, .seeding => {
                const ref = j.engine_ref orelse return self.apply(r, .{ .step = .queued, .attempts = j.attempts }, now);
                const eng = self.engineFor(j.engine) orelse return self.missingEngine(r, now);
                const p = eng.poll(ref) catch |e| {
                    log.warn("job {d}: reconcile poll failed: {s}", .{ j.id, @errorName(e) });
                    return;
                };
                if (p.phase != .removed) return self.absorbProgress(r, eng, p, now);
                if (j.step == .seeding) {
                    // Installed already; the torrent is just gone from aria2.
                    return self.apply(r, .{ .step = .done, .attempts = j.attempts }, now);
                }
                if (j.final_path == null) {
                    j.final_path = findSingleFile(self.alloc, self.io, j.dest_dir);
                    if (j.final_path != null) r.dirty = true;
                }
                if (j.final_path) |fp| {
                    if (std.Io.Dir.cwd().statFile(self.io, fp, .{})) |_| {
                        self.apply(r, .{ .step = .verifying, .attempts = j.attempts }, now);
                        return self.startVerify(r, now);
                    } else |_| {}
                }
                self.apply(r, .{
                    .step = .failed,
                    .fail = .network,
                    .detail = "Download lost after restart — Retry starts it again",
                    // No automatic retry; the user's Retry resets attempts.
                    .attempts = 3,
                }, now);
            },
        }
    }

    // ------------------------------------------------------------ persist / limits / publish

    fn persist(self: *Downloader, now: i64) void {
        for (self.recs.items) |r| {
            if (r.dirty) {
                self.store.update(&r.job) catch log.err("job {d}: store update failed", .{r.job.id});
                r.dirty = false;
                r.bytes_dirty = false;
                r.bytes_saved_at = now;
            } else if (r.bytes_dirty and now - r.bytes_saved_at >= BYTES_PERSIST_S) {
                self.store.updateBytes(r.job.id, r.job.bytes_done, r.job.bytes_total, r.job.bytes_uploaded) catch |e|
                    log.warn("job {d}: byte counters not stored: {s}", .{ r.job.id, @errorName(e) });
                r.bytes_dirty = false;
                r.bytes_saved_at = now;
            }
        }
        if (self.trim_due) {
            self.trim_due = false;
            self.trimHistory();
        }
    }

    /// Keep the newest `HISTORY_KEEP` terminal jobs, in the store and in
    /// memory (same rule as `Store.trimHistory`: highest ids win).
    fn trimHistory(self: *Downloader) void {
        _ = self.store.trimHistory(HISTORY_KEEP) catch |e| {
            log.warn("history trim failed: {s}", .{@errorName(e)});
            return;
        };
        var terminal: usize = 0;
        for (self.recs.items) |r| {
            if (r.job.step.isTerminal()) terminal += 1;
        }
        // `recs` is ordered by id, so the oldest terminal jobs come first.
        var i: usize = 0;
        while (terminal > HISTORY_KEEP and i < self.recs.items.len) {
            const r = self.recs.items[i];
            if (!r.job.step.isTerminal()) {
                i += 1;
                continue;
            }
            _ = self.recs.orderedRemove(i);
            self.freeRec(r);
            terminal -= 1;
            self.touched = true;
        }
    }

    /// Engine has a transfer it is responsible for right now.
    fn hasLiveJob(self: *Downloader, slot: EngineSlot) bool {
        for (self.recs.items) |r| {
            if (r.job.engine_ref != null and !r.job.step.isTerminal() and slotOf(r.job.engine) == slot) return true;
        }
        return false;
    }

    /// Apply the plan per engine when it changed. An engine that is down,
    /// or not running with no live job, is skipped (no spawn at idle
    /// startup). A spawn failure marks the engine down (30 s gate).
    fn applyLimits(self: *Downloader, now: i64) void {
        const p = policy.plan(self.settings, self.activeCounts());
        for (std.enums.values(EngineSlot)) |slot| {
            const eng: Engine = switch (slot) {
                .aria2 => self.engines.aria2,
                .megacmd => self.engines.megacmd orelse continue,
                .browser => self.engines.browser orelse continue,
            };
            if (self.down_since.get(slot) != null) continue;
            if (self.last_plan.get(slot)) |lp| if (std.meta.eql(lp, p)) continue;
            if (!eng.isAlive() and !self.hasLiveJob(slot)) continue;
            eng.setLimits(p) catch |e| {
                log.warn("{s} setLimits failed: {s}", .{ @tagName(slot), @errorName(e) });
                if (e == error.AriaSpawnFailed or e == error.AriaStartTimeout) {
                    if (self.down_since.get(slot) == null) self.down_since.set(slot, now);
                }
                continue;
            };
            self.last_plan.set(slot, p);
        }
    }

    fn publish(self: *Downloader) void {
        const next: u1 = self.cur +% 1;
        const arena = &self.snap_arenas[next];
        _ = arena.reset(.retain_capacity);
        self.snaps[next] = self.buildSnapshot(arena.allocator()) catch .{};
        self.snap_lock.lockUncancelable(self.io);
        self.generation += 1;
        self.snaps[next].generation = self.generation;
        self.cur = next;
        self.snap_lock.unlock(self.io);
        if (self.wake_fn) |f| f(self.wake_ctx);
    }

    fn buildSnapshot(self: *Downloader, a: std.mem.Allocator) !Snapshot {
        const views = try a.alloc(JobView, self.recs.items.len);
        var totals: Totals = .{};
        for (self.recs.items, views) |r, *v| {
            var j = try cloneJob(a, r.job);
            j.resolved_headers = &.{};
            v.* = .{ .job = j };
            totals.dl_speed += r.job.dl_speed;
            totals.ul_speed += r.job.ul_speed;
            switch (r.job.step) {
                .awaiting_user => totals.waiting_for_user += 1,
                .seeding => totals.seeding += 1,
                .done, .failed, .cancelled => {},
                else => totals.active += 1,
            }
        }
        return .{ .jobs = views, .totals = totals };
    }

    // ------------------------------------------------------------ helpers

    fn pushEvent(self: *Downloader, ev: UiEvent) void {
        const copy = cloneEvent(self.alloc, ev) catch {
            log.err("ui event {s} dropped: out of memory", .{@tagName(ev)});
            return;
        };
        self.touched = true; // publish + wake so the UI drains it
        self.ev_lock.lockUncancelable(self.io);
        defer self.ev_lock.unlock(self.io);
        self.events.append(self.alloc, copy) catch {
            freeEvent(self.alloc, copy);
            log.err("ui event dropped: out of memory", .{});
        };
    }

    fn toast(self: *Downloader, msg: []const u8) void {
        self.pushEvent(.{ .toast = msg });
    }

    /// Replace an owned string field; on OOM the old value stays.
    fn setStr(self: *Downloader, field: *[]const u8, value: []const u8) void {
        const new: []const u8 = if (value.len == 0) "" else self.alloc.dupe(u8, value) catch return;
        if (field.len > 0) self.alloc.free(field.*);
        field.* = new;
    }

    fn freeRec(self: *Downloader, r: *Rec) void {
        if (r.worker) |pw| self.orphan(pw);
        freeJobStrings(self.alloc, &r.job);
        if (r.torrent_bytes) |b| self.alloc.free(b);
        self.alloc.destroy(r);
    }
};

/// Replace path separators and dot-only names so a version string is one
/// safe path segment. Empty / null → "unversioned".
fn safeSegment(buf: []u8, v: ?[]const u8) []const u8 {
    const s = v orelse return "unversioned";
    const n = @min(s.len, buf.len);
    var all_dots = true;
    for (s[0..n], buf[0..n]) |c, *o| {
        o.* = switch (c) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|' => '_',
            else => if (c < 0x20) '_' else c,
        };
        if (c != '.' and c != ' ') all_dots = false;
    }
    if (n == 0 or all_dots) return "unversioned";
    return buf[0..n];
}

/// A torrent job without its .torrent body can still start when the href
/// is a magnet link or a URL aria2 can fetch itself.
fn isFetchableTorrentHref(href: []const u8) bool {
    return std.mem.startsWith(u8, href, "magnet:") or
        std.mem.startsWith(u8, href, "http://") or
        std.mem.startsWith(u8, href, "https://");
}

/// Create `dir` and an empty marker file in it. Failure is logged: the
/// extract still runs, it just cannot be told apart from a user folder if
/// it is interrupted.
fn writeMarker(io: std.Io, dir: []const u8, marker: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch |e| {
        log.warn("create '{s}' failed: {s}", .{ dir, @errorName(e) });
        return;
    };
    var f = cwd.createFile(io, marker, .{ .truncate = true }) catch |e| {
        log.warn("create '{s}' failed: {s}", .{ marker, @errorName(e) });
        return;
    };
    f.close(io);
}

/// Names a finished download never has: hidden files and the temp / control
/// files of aria2 and browsers.
fn isTempName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.' or name[0] == '~') return true;
    for ([_][]const u8{ ".aria2", ".part", ".tmp", ".crdownload", ".partial", ".download" }) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

/// The one finished file in `dir` (owned full path), or null when there is
/// none, more than one, or an aria2 control file marks a transfer as
/// incomplete.
fn findSingleFile(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) ?[]u8 {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return null;
    defer d.close(io);
    var name_buf: [std.fs.max_name_bytes]u8 = undefined;
    var name: ?[]const u8 = null;
    var it = d.iterate();
    while (it.next(io) catch return null) |e| {
        if (e.kind != .file) continue;
        if (std.mem.endsWith(u8, e.name, ".aria2")) return null;
        if (isTempName(e.name)) continue;
        if (name != null or e.name.len > name_buf.len) return null;
        @memcpy(name_buf[0..e.name.len], e.name);
        name = name_buf[0..e.name.len];
    }
    return std.fs.path.join(alloc, &.{ dir, name orelse return null }) catch null;
}

fn dirHasEntries(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    return (it.next(io) catch null) != null;
}

fn dupeOpt(a: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try dupeStr(a, v) else null;
}

/// Empty strings stay static so `freeJobStrings` can skip them.
fn dupeStr(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    return if (s.len == 0) "" else try a.dupe(u8, s);
}

fn dupeList(a: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    if (list.len == 0) return &.{};
    const out = try a.alloc([]const u8, list.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |s| if (s.len > 0) a.free(s);
        a.free(out);
    }
    for (list) |s| {
        out[n] = try dupeStr(a, s);
        n += 1;
    }
    return out;
}

/// Deep copy of every string in `j` (same convention as `store.readJob`).
pub fn cloneJob(a: std.mem.Allocator, j: model.Job) !model.Job {
    var c = j;
    c.title = "";
    c.source_href = "";
    c.host = "";
    c.platform = null;
    c.version = null;
    c.step_detail = "";
    c.fail_msg = "";
    c.resolved_url = null;
    c.resolved_headers = &.{};
    c.engine_ref = null;
    c.dest_dir = "";
    c.final_path = null;
    errdefer freeJobStrings(a, &c);
    c.title = try dupeStr(a, j.title);
    c.source_href = try dupeStr(a, j.source_href);
    c.host = try dupeStr(a, j.host);
    c.platform = try dupeOpt(a, j.platform);
    c.version = try dupeOpt(a, j.version);
    c.step_detail = try dupeStr(a, j.step_detail);
    c.fail_msg = try dupeStr(a, j.fail_msg);
    c.resolved_url = try dupeOpt(a, j.resolved_url);
    c.resolved_headers = try dupeList(a, j.resolved_headers);
    c.engine_ref = try dupeOpt(a, j.engine_ref);
    c.dest_dir = try dupeStr(a, j.dest_dir);
    c.final_path = try dupeOpt(a, j.final_path);
    return c;
}

fn freeStr(a: std.mem.Allocator, s: []const u8) void {
    if (s.len > 0) a.free(s);
}

fn freeJobStrings(a: std.mem.Allocator, j: *model.Job) void {
    freeStr(a, j.title);
    freeStr(a, j.source_href);
    freeStr(a, j.host);
    if (j.platform) |s| freeStr(a, s);
    if (j.version) |s| freeStr(a, s);
    freeStr(a, j.step_detail);
    freeStr(a, j.fail_msg);
    if (j.resolved_url) |s| freeStr(a, s);
    if (j.engine_ref) |s| freeStr(a, s);
    freeStr(a, j.dest_dir);
    if (j.final_path) |s| freeStr(a, s);
    if (j.resolved_headers.len > 0) {
        for (j.resolved_headers) |h| freeStr(a, h);
        a.free(j.resolved_headers);
    }
    j.* = .{ .id = j.id, .group_id = j.group_id, .kind = j.kind, .game_thread_id = j.game_thread_id, .source_href = "", .engine = j.engine, .step = j.step, .dest_dir = "" };
}

/// Deep copy into an arena (freed all at once), so no errdefer cleanup.
fn cloneCommand(a: std.mem.Allocator, cmd: Command) !Command {
    var c = cmd;
    switch (c) {
        .enqueue_url => |*e| {
            e.url = try a.dupe(u8, e.url);
            e.title = try a.dupe(u8, e.title);
            e.host = try a.dupe(u8, e.host);
            if (e.version) |v| e.version = try a.dupe(u8, v);
            const hs = try a.alloc([]const u8, e.headers.len);
            for (e.headers, hs) |h, *o| o.* = try a.dupe(u8, h);
            e.headers = hs;
        },
        .enqueue_torrent => |*e| {
            e.label = try a.dupe(u8, e.label);
            e.torrent_bytes = try a.dupe(u8, e.torrent_bytes);
            e.title = try a.dupe(u8, e.title);
            if (e.version) |v| e.version = try a.dupe(u8, v);
        },
        .enqueue_catalogue => |*e| {
            e.href = try a.dupe(u8, e.href);
            e.title = try a.dupe(u8, e.title);
        },
        .paste_link => |*e| e.url = try a.dupe(u8, e.url),
        .pick_file => |*e| e.path = try a.dupe(u8, e.path),
        .install_failed => |*e| e.msg = try a.dupe(u8, e.msg),
        .reload_settings => |*s| {
            s.watch_dir = try a.dupe(u8, s.watch_dir);
            s.megacmd_path = try a.dupe(u8, s.megacmd_path);
        },
        else => {},
    }
    return c;
}

fn cloneEvent(a: std.mem.Allocator, ev: UiEvent) !UiEvent {
    return switch (ev) {
        .install_ready => |ir| blk: {
            var c = ir;
            c.archive_path = try a.dupe(u8, ir.archive_path);
            errdefer a.free(c.archive_path);
            c.extracted_dir = if (ir.extracted_dir) |d| try a.dupe(u8, d) else null;
            errdefer if (c.extracted_dir) |d| a.free(d);
            c.version = if (ir.version) |v| try a.dupe(u8, v) else null;
            break :blk .{ .install_ready = c };
        },
        .open_url => |u| .{ .open_url = try a.dupe(u8, u) },
        .toast => |t| .{ .toast = try a.dupe(u8, t) },
        .sign_in_needed => ev,
    };
}

fn freeEvent(a: std.mem.Allocator, ev: UiEvent) void {
    switch (ev) {
        .install_ready => |ir| {
            a.free(ir.archive_path);
            if (ir.extracted_dir) |d| a.free(d);
            if (ir.version) |v| a.free(v);
        },
        .open_url => |u| a.free(u),
        .toast => |t| a.free(t),
        .sign_in_needed => {},
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const test_env = @import("util_test_env");

const Fx = struct {
    env: test_env.TestEnv,
    fake: engine_mod.FakeEngine,
    dl: Downloader,
    dl_root: []u8,
    lib_root: []u8,
    data_root: []u8,

    fn create(settings: policy.Settings) !*Fx {
        const a = testing.allocator;
        const fx = try a.create(Fx);
        errdefer a.destroy(fx);
        fx.env = try test_env.TestEnv.init(a, "downloader");
        fx.fake = .{ .alloc = a, .script = &.{} };
        fx.dl_root = try fx.env.path("dl");
        fx.lib_root = try fx.env.path("lib");
        fx.data_root = try fx.env.path("data");
        fx.dl = Downloader.init(
            a,
            fx.env.io,
            try store_mod.Store.openMemory(a),
            .{ .aria2 = fx.fake.engine() },
            .{ .downloads_root = fx.dl_root, .library_root = fx.lib_root, .data_root = fx.data_root },
            settings,
        );
        return fx;
    }

    fn destroy(fx: *Fx) void {
        const a = testing.allocator;
        fx.dl.deinit();
        a.free(fx.dl_root);
        a.free(fx.lib_root);
        a.free(fx.data_root);
        fx.env.deinit();
        a.destroy(fx);
    }

    fn enqueue(fx: *Fx, url: []const u8) void {
        fx.dl.send(.{ .enqueue_url = .{ .url = url, .kind = .game, .game_thread_id = 77, .title = "Game", .host = "raw" } });
    }

    fn rec(fx: *Fx, id: u64) *Rec {
        return fx.dl.find(id).?;
    }
};

test "downloader: enqueue_url → queued → downloading (engine started once) → transfer_done → verifying → extracting → install_ready event → install_ack → done, with events logged" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try fx.env.writeFile("payload/game.bin", "hello");
    const file = try fx.env.path("payload/game.bin");
    defer testing.allocator.free(file);
    const script = [_]model.Progress{
        .{ .phase = .downloading, .bytes_done = 1, .bytes_total = 5 },
        .{ .phase = .downloading, .bytes_done = 3, .bytes_total = 5 },
        .{ .phase = .transfer_done, .bytes_done = 5, .bytes_total = 5, .final_path = file },
    };
    fx.fake.script = &script;

    fx.enqueue("https://example.invalid/game.bin");
    fx.dl.stepOnce(1000);
    try testing.expectEqual(@as(usize, 1), fx.fake.started);
    const id = fx.dl.recs.items[0].job.id;
    try testing.expectEqual(model.Step.downloading, fx.rec(id).job.step);
    try testing.expect(std.mem.endsWith(u8, fx.rec(id).job.dest_dir, "aria2_http" ++ std.fs.path.sep_str ++ "1" ++ std.fs.path.sep_str));

    fx.dl.stepOnce(1001);
    try testing.expectEqual(model.Step.downloading, fx.rec(id).job.step);
    fx.dl.stepOnce(1002);
    try testing.expectEqual(@as(usize, 1), fx.fake.started);
    try testing.expectEqual(model.Step.installing, fx.rec(id).job.step);
    try testing.expectEqualStrings("Not an archive — will install as a file", fx.rec(id).job.step_detail);

    const evs = fx.dl.drainEvents(testing.allocator);
    defer Downloader.freeEvents(testing.allocator, evs);
    try testing.expectEqual(@as(usize, 1), evs.len);
    const ir = evs[0].install_ready;
    try testing.expectEqual(id, ir.job_id);
    try testing.expectEqual(@as(u64, 77), ir.game_thread_id);
    try testing.expectEqualStrings(file, ir.archive_path);
    try testing.expectEqual(@as(?[]const u8, null), ir.extracted_dir);
    try testing.expect(!ir.source_is_rpdl);

    fx.dl.send(.{ .install_ack = id });
    fx.dl.stepOnce(1003);
    try testing.expectEqual(model.Step.done, fx.rec(id).job.step);
    try testing.expectEqual(@as(?i64, 1003), fx.rec(id).job.finished_at);

    const logged = try fx.dl.store.listEvents(testing.allocator, id);
    defer store_mod.Store.freeEvents(testing.allocator, logged);
    const want = [_]model.Step{ .queued, .resolving, .downloading, .verifying, .extracting, .installing, .done };
    try testing.expectEqual(want.len, logged.len);
    for (want, logged) |w, e| try testing.expectEqual(w, e.step);
    try testing.expectEqualStrings("enqueued", logged[0].msg);

    const rows = try fx.dl.store.loadAll(testing.allocator);
    defer store_mod.Store.freeJobs(testing.allocator, rows);
    try testing.expectEqual(model.Step.done, rows[0].step);
    try testing.expectEqualStrings(file, rows[0].final_path.?);

    const snap = fx.dl.snapshot();
    defer fx.dl.releaseSnapshot();
    try testing.expectEqual(@as(usize, 1), snap.jobs.len);
    try testing.expectEqual(model.Step.done, snap.jobs[0].job.step);
}

test "downloader: slots — 4 file jobs with slots_files=3 → 3 downloading, 1 queued; after one finishes the 4th starts" {
    var fx = try Fx.create(.{ .slots_files = 3 });
    defer fx.destroy();
    try fx.env.writeFile("payload/a.bin", "data");
    const file = try fx.env.path("payload/a.bin");
    defer testing.allocator.free(file);
    const script = [_]model.Progress{
        .{ .phase = .downloading },
        .{ .phase = .downloading },
        .{ .phase = .downloading },
        .{ .phase = .transfer_done, .final_path = file },
        .{ .phase = .downloading },
    };
    fx.fake.script = &script;
    for (0..4) |_| fx.enqueue("https://example.invalid/a.bin");

    fx.dl.stepOnce(1000);
    try testing.expectEqual(@as(usize, 3), fx.fake.started);
    try testing.expectEqual(model.Step.queued, fx.dl.recs.items[3].job.step);

    fx.dl.stepOnce(1001);
    try testing.expectEqual(model.Step.installing, fx.dl.recs.items[0].job.step);
    try testing.expectEqual(@as(usize, 4), fx.fake.started);
    try testing.expectEqual(model.Step.downloading, fx.dl.recs.items[3].job.step);
}

test "downloader: pause/unpause/cancel/remove commands reach the engine and the store" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    const script = [_]model.Progress{.{ .phase = .downloading }};
    fx.fake.script = &script;
    fx.enqueue("https://example.invalid/1");
    fx.enqueue("https://example.invalid/2");
    fx.dl.stepOnce(1000);
    try testing.expectEqual(@as(usize, 2), fx.fake.started);
    const id1 = fx.dl.recs.items[0].job.id;
    const id2 = fx.dl.recs.items[1].job.id;

    fx.dl.send(.{ .pause = id1 });
    fx.dl.stepOnce(1001);
    try testing.expect(fx.fake.paused);
    try testing.expectEqual(model.Step.paused, fx.rec(id1).job.step);
    try testing.expectEqual(model.Step.downloading, fx.rec(id1).job.resume_step.?);

    fx.dl.send(.{ .unpause = id1 });
    fx.dl.stepOnce(1002);
    try testing.expect(!fx.fake.paused);
    try testing.expectEqual(model.Step.downloading, fx.rec(id1).job.step);

    fx.dl.send(.{ .cancel = id1 });
    fx.dl.stepOnce(1003);
    try testing.expect(fx.fake.cancelled);
    try testing.expectEqual(model.Step.cancelled, fx.rec(id1).job.step);
    try testing.expectEqual(@as(?[]const u8, null), fx.rec(id1).job.engine_ref);

    fx.fake.cancelled = false;
    fx.dl.send(.{ .remove = id2 });
    fx.dl.stepOnce(1004);
    try testing.expect(fx.fake.cancelled);
    try testing.expectEqual(@as(?*Rec, null), fx.dl.find(id2));

    const rows = try fx.dl.store.loadAll(testing.allocator);
    defer store_mod.Store.freeJobs(testing.allocator, rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(id1, rows[0].id);
    try testing.expectEqual(model.Step.cancelled, rows[0].step);

    const snap = fx.dl.snapshot();
    defer fx.dl.releaseSnapshot();
    try testing.expectEqual(@as(usize, 1), snap.jobs.len);
}

test "downloader: failed network → retry after 30 s (tick) → engine started again; after 3 → stays failed" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    const script = [_]model.Progress{.{ .phase = .failed, .fail = .network, .msg = "connection reset" }};
    fx.fake.script = &script;
    fx.enqueue("https://example.invalid/x");

    fx.dl.stepOnce(1000);
    const id = fx.dl.recs.items[0].job.id;
    try testing.expectEqual(model.Step.failed, fx.rec(id).job.step);
    try testing.expectEqual(model.FailReason.network, fx.rec(id).job.fail.?);
    try testing.expectEqualStrings("connection reset", fx.rec(id).job.fail_msg);
    try testing.expectEqual(@as(?i64, 1030), fx.rec(id).job.next_retry_at);

    fx.dl.stepOnce(1029);
    try testing.expectEqual(@as(usize, 1), fx.fake.started);
    // The due retry is started in the same tick; its next poll fails again.
    fx.dl.stepOnce(1030);
    try testing.expectEqual(@as(usize, 2), fx.fake.started);
    try testing.expectEqual(model.Step.downloading, fx.rec(id).job.step);
    fx.dl.stepOnce(1031);
    try testing.expectEqual(@as(?i64, 1031 + 120), fx.rec(id).job.next_retry_at);
    fx.dl.stepOnce(1151);
    try testing.expectEqual(@as(usize, 3), fx.fake.started);
    fx.dl.stepOnce(1152);
    try testing.expectEqual(@as(?i64, 1152 + 600), fx.rec(id).job.next_retry_at);
    fx.dl.stepOnce(1752);
    try testing.expectEqual(@as(usize, 4), fx.fake.started);
    fx.dl.stepOnce(1753);
    try testing.expectEqual(@as(u8, 3), fx.rec(id).job.attempts);
    try testing.expectEqual(@as(?i64, null), fx.rec(id).job.next_retry_at);
    fx.dl.stepOnce(9999);
    try testing.expectEqual(@as(usize, 4), fx.fake.started);
    try testing.expectEqual(model.Step.failed, fx.rec(id).job.step);
}

fn storedJob(step: model.Step) model.Job {
    return .{
        .id = 0,
        .group_id = 0,
        .kind = .game,
        .game_thread_id = 5,
        .source_href = "https://example.invalid/s",
        .engine = .aria2_http,
        .step = step,
        .dest_dir = "/nonexistent/dl/aria2_http/1/",
        .created_at = 10,
        .updated_at = 10,
    };
}

test "downloader: reconcile — stored downloading job whose engine poll says removed and no file → failed{network,'lost after restart'}; stored installing → install_ready re-raised; stored done untouched" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    const script = [_]model.Progress{.{ .phase = .removed }};
    fx.fake.script = &script;

    var a = storedJob(.downloading);
    a.engine_ref = "gone";
    const id_a = try fx.dl.store.insert(&a);
    var b = storedJob(.installing);
    b.final_path = "/nonexistent/b.bin";
    b.source_href = "rpdl:123";
    const id_b = try fx.dl.store.insert(&b);
    const id_c = try fx.dl.store.insert(&storedJob(.done));

    try fx.dl.load();
    fx.dl.reconcile();

    const ja = fx.rec(id_a).job;
    try testing.expectEqual(model.Step.failed, ja.step);
    try testing.expectEqual(model.FailReason.network, ja.fail.?);
    try testing.expect(std.mem.indexOf(u8, ja.step_detail, "lost after restart") != null);
    try testing.expectEqual(@as(?i64, null), ja.next_retry_at);
    try testing.expectEqual(@as(u8, 3), ja.attempts);

    const evs = fx.dl.drainEvents(testing.allocator);
    defer Downloader.freeEvents(testing.allocator, evs);
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqual(id_b, evs[0].install_ready.job_id);
    try testing.expect(evs[0].install_ready.source_is_rpdl);
    try testing.expectEqual(model.Step.installing, fx.rec(id_b).job.step);

    try testing.expectEqual(model.Step.done, fx.rec(id_c).job.step);
    try testing.expectEqual(@as(i64, 10), fx.rec(id_c).job.updated_at);

    const rows = try fx.dl.store.loadAll(testing.allocator);
    defer store_mod.Store.freeJobs(testing.allocator, rows);
    try testing.expectEqual(model.Step.failed, rows[0].step);

    // User Retry still works after the no-auto-retry failure.
    fx.dl.send(.{ .retry = id_a });
    fx.dl.stepOnce(2000);
    try testing.expectEqual(@as(usize, 1), fx.fake.started);
}

test "downloader: setLimits called only when plan changes" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    const script = [_]model.Progress{.{ .phase = .downloading }};
    fx.fake.script = &script;
    fx.dl.stepOnce(1000);
    try testing.expect(fx.fake.last_plan != null);
    fx.fake.last_plan = null;
    fx.dl.stepOnce(1001);
    try testing.expectEqual(@as(?policy.Plan, null), fx.fake.last_plan);

    fx.enqueue("https://example.invalid/y");
    fx.dl.stepOnce(1002);
    try testing.expectEqual(@as(u64, 256 * 1024), fx.fake.last_plan.?.aria2_global_up);

    fx.fake.last_plan = null;
    fx.dl.send(.{ .reload_settings = .{ .ul_cap_busy_kbs = 100, .watch_dir = "/tmp/w" } });
    fx.dl.stepOnce(1003);
    try testing.expectEqual(@as(u64, 100 * 1024), fx.fake.last_plan.?.aria2_global_up);
    try testing.expectEqualStrings("/tmp/w", fx.dl.settings.watch_dir);
}

test "downloader: engine poll daemon_gone → affected jobs failed{network} with auto-retry; engine restarted at most once per 30 s" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    const script = [_]model.Progress{
        .{ .phase = .daemon_gone },
        .{ .phase = .daemon_gone },
        .{ .phase = .downloading },
    };
    fx.fake.script = &script;
    fx.enqueue("https://example.invalid/1");
    fx.enqueue("https://example.invalid/2");

    fx.dl.stepOnce(1000);
    try testing.expectEqual(@as(usize, 2), fx.fake.started);
    for (fx.dl.recs.items) |r| {
        try testing.expectEqual(model.Step.failed, r.job.step);
        try testing.expectEqual(model.FailReason.network, r.job.fail.?);
        try testing.expectEqual(@as(?i64, 1030), r.job.next_retry_at);
    }
    try testing.expectEqual(@as(?i64, 1000), fx.dl.down_since.get(.aria2));

    // A manual Retry while the engine is down waits for the 30 s window.
    fx.dl.send(.{ .retry = fx.dl.recs.items[0].job.id });
    fx.dl.stepOnce(1010);
    try testing.expectEqual(model.Step.queued, fx.dl.recs.items[0].job.step);
    try testing.expectEqual(@as(usize, 2), fx.fake.started);

    fx.dl.stepOnce(1030);
    try testing.expectEqual(@as(usize, 4), fx.fake.started);
    try testing.expectEqual(@as(?i64, null), fx.dl.down_since.get(.aria2));
    for (fx.dl.recs.items) |r| try testing.expectEqual(model.Step.downloading, r.job.step);
}

test "downloader: missing MEGAcmd engine fails the job without retry" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    var j = storedJob(.queued);
    j.engine = .megacmd;
    const id = try fx.dl.store.insert(&j);
    try fx.dl.load();
    fx.dl.stepOnce(1000);
    const got = fx.rec(id).job;
    try testing.expectEqual(model.Step.failed, got.step);
    try testing.expectEqual(model.FailReason.engine_missing, got.fail.?);
    try testing.expectEqualStrings("MEGAcmd is not installed", got.step_detail);
    try testing.expectEqual(@as(?i64, null), got.next_retry_at);
}

test "downloader: sha256 mismatch runs the verify worker and fails with checksum_mismatch (Retry deletes the file)" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try fx.env.writeFile("payload/g.bin", "not what you expected");
    const file = try fx.env.path("payload/g.bin");
    defer testing.allocator.free(file);
    const script = [_]model.Progress{.{ .phase = .transfer_done, .final_path = file }};
    fx.fake.script = &script;
    fx.dl.send(.{ .enqueue_url = .{ .url = "https://example.invalid/g.bin", .kind = .game, .game_thread_id = 1, .title = "G", .expected_sha256 = @as([32]u8, @splat(0)) } });

    fx.dl.stepOnce(1000);
    const id = fx.dl.recs.items[0].job.id;
    var spins: usize = 0;
    while (fx.rec(id).job.step == .verifying and spins < 5000) : (spins += 1) {
        fx.env.io.sleep(std.Io.Duration.fromMilliseconds(1), .real) catch {};
        fx.dl.stepOnce(1001);
    }
    try testing.expectEqual(model.Step.failed, fx.rec(id).job.step);
    try testing.expectEqual(model.FailReason.checksum_mismatch, fx.rec(id).job.fail.?);
    try testing.expectEqual(@as(?*PostWorker, null), fx.rec(id).worker);

    fx.dl.send(.{ .retry = id });
    fx.dl.stepOnce(1002);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(fx.env.io, file, .{}));
    try testing.expectEqual(@as(usize, 2), fx.fake.started);
}

test "downloader: start spawns the loop thread and stop joins it" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try fx.dl.start();
    try testing.expect(fx.dl.thread != null);
    fx.dl.stop();
    try testing.expectEqual(@as(?std.Thread, null), fx.dl.thread);
    const snap = fx.dl.snapshot();
    defer fx.dl.releaseSnapshot();
    try testing.expect(snap.generation >= 1);
}

test "downloader: limits are not applied to an idle engine that is not running; a down engine does not block another" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    const script = [_]model.Progress{.{ .phase = .downloading }};
    fx.fake.script = &script;
    fx.fake.alive = false;
    fx.dl.stepOnce(1000);
    try testing.expectEqual(@as(?policy.Plan, null), fx.fake.last_plan);

    fx.enqueue("https://example.invalid/z");
    fx.dl.stepOnce(1001);
    try testing.expect(fx.fake.last_plan != null);

    var mega: engine_mod.FakeEngine = .{ .alloc = testing.allocator, .script = &.{} };
    fx.dl.engines.megacmd = mega.engine();
    fx.dl.down_since.set(.megacmd, 1001);
    fx.fake.last_plan = null;
    fx.dl.send(.{ .reload_settings = .{ .ul_cap_busy_kbs = 7 } });
    fx.dl.stepOnce(1002);
    try testing.expectEqual(@as(u64, 7 * 1024), fx.fake.last_plan.?.aria2_global_up);
    try testing.expectEqual(@as(?policy.Plan, null), mega.last_plan);
}

test "downloader: idle app does not republish every tick" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    fx.dl.stepOnce(1000);
    const g1 = fx.dl.generation;
    fx.dl.stepOnce(1001);
    fx.dl.stepOnce(1002);
    try testing.expectEqual(g1, fx.dl.generation);
    fx.enqueue("https://example.invalid/w");
    fx.dl.stepOnce(1003);
    try testing.expect(fx.dl.generation > g1);
}

test "downloader: extract marker — our interrupted folder is cleared and re-extracted; a foreign non-empty folder is registered" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try fx.env.writeFile("payload/g.zip", "not really a zip");
    const zip = try fx.env.path("payload/g.zip");
    defer testing.allocator.free(zip);
    try fx.env.writeFile("lib/9/v1/old.txt", "half");
    try fx.env.writeFile("lib/9/v1/" ++ EXTRACT_MARKER, "");
    try fx.env.writeFile("lib/9/v2/user.txt", "mine");

    var a = storedJob(.extracting);
    a.game_thread_id = 9;
    a.version = "v1";
    a.final_path = zip;
    const id_a = try fx.dl.store.insert(&a);
    var b = a;
    b.version = "v2";
    const id_b = try fx.dl.store.insert(&b);

    try fx.dl.load();
    fx.dl.reconcile();

    try testing.expectEqual(model.Step.installing, fx.rec(id_b).job.step);
    try testing.expectEqualStrings(FOLDER_EXISTS, fx.rec(id_b).job.step_detail);
    const user = try fx.env.path("lib/9/v2/user.txt");
    defer testing.allocator.free(user);
    _ = try std.Io.Dir.cwd().statFile(fx.env.io, user, .{});

    var spins: usize = 0;
    while (fx.rec(id_a).job.step == .extracting and spins < 5000) : (spins += 1) {
        fx.env.io.sleep(std.Io.Duration.fromMilliseconds(1), .real) catch {};
        fx.dl.stepOnce(1000);
    }
    // The re-extract ran (and failed on the fake zip): not "registering".
    try testing.expectEqual(model.Step.failed, fx.rec(id_a).job.step);
    try testing.expectEqual(model.FailReason.bad_archive, fx.rec(id_a).job.fail.?);
    const old = try fx.env.path("lib/9/v1/old.txt");
    defer testing.allocator.free(old);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(fx.env.io, old, .{}));
    const marker = try fx.env.path("lib/9/v1/" ++ EXTRACT_MARKER);
    defer testing.allocator.free(marker);
    _ = try std.Io.Dir.cwd().statFile(fx.env.io, marker, .{});
}

test "downloader: history keeps the newest 500 terminal jobs in the store and in memory" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    for (0..501) |_| _ = try fx.dl.store.insert(&storedJob(.done));
    var m = storedJob(.queued);
    m.engine = .megacmd;
    _ = try fx.dl.store.insert(&m);
    try fx.dl.load();
    fx.dl.stepOnce(1000); // the MEGAcmd job fails → 502 terminal
    try testing.expectEqual(@as(usize, 500), fx.dl.recs.items.len);
    try testing.expectEqual(@as(u64, 3), fx.dl.recs.items[0].job.id);
    const rows = try fx.dl.store.loadAll(testing.allocator);
    defer store_mod.Store.freeJobs(testing.allocator, rows);
    try testing.expectEqual(@as(usize, 500), rows.len);
    try testing.expectEqual(@as(u64, 3), rows[0].id);
}

test "downloader: torrent without its .torrent body after restart fails without retry; a magnet still starts" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    const script = [_]model.Progress{.{ .phase = .downloading }};
    fx.fake.script = &script;
    var t = storedJob(.queued);
    t.engine = .aria2_torrent;
    t.source_href = "rpdl:5";
    const id_t = try fx.dl.store.insert(&t);
    var mg = t;
    mg.source_href = "magnet:?xt=urn:btih:abc";
    const id_m = try fx.dl.store.insert(&mg);
    try fx.dl.load();
    fx.dl.stepOnce(1000);
    const jt = fx.rec(id_t).job;
    try testing.expectEqual(model.Step.failed, jt.step);
    try testing.expectEqual(model.FailReason.unknown, jt.fail.?);
    try testing.expectEqualStrings("Torrent file is gone after restart — start the download again", jt.step_detail);
    try testing.expectEqual(@as(u8, 3), jt.attempts);
    try testing.expectEqual(@as(?i64, null), jt.next_retry_at);
    try testing.expectEqual(@as(usize, 1), fx.fake.started);
    try testing.expectEqual(model.Step.downloading, fx.rec(id_m).job.step);
}

test "downloader: reconcile finds the single finished file in dest_dir when final_path is unknown" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    const script = [_]model.Progress{.{ .phase = .removed }};
    fx.fake.script = &script;
    try fx.env.writeFile("dl/aria2_http/1/game.bin", "payload");
    try fx.env.writeFile("dl/aria2_http/1/.hidden", "");
    const dest = try fx.env.path("dl/aria2_http/1/");
    defer testing.allocator.free(dest);
    var j = storedJob(.downloading);
    j.engine_ref = "gone";
    j.dest_dir = dest;
    const id = try fx.dl.store.insert(&j);
    try fx.dl.load();
    fx.dl.reconcile();
    try testing.expectEqual(model.Step.installing, fx.rec(id).job.step);
    try testing.expect(std.mem.endsWith(u8, fx.rec(id).job.final_path.?, "game.bin"));
}

test "downloader: retry_install re-raises install_ready for a done job and for an install failure; a torrent re-install ends done" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try fx.env.writeFile("payload/game.bin", "hello");
    const file = try fx.env.path("payload/game.bin");
    defer testing.allocator.free(file);
    const script = [_]model.Progress{.{ .phase = .transfer_done, .bytes_done = 5, .bytes_total = 5, .final_path = file }};
    fx.fake.script = &script;

    fx.enqueue("https://example.invalid/game.bin");
    fx.dl.stepOnce(1000);
    fx.dl.stepOnce(1001);
    const id = fx.dl.recs.items[0].job.id;
    try testing.expectEqual(model.Step.installing, fx.rec(id).job.step);
    Downloader.freeEvents(testing.allocator, fx.dl.drainEvents(testing.allocator));

    // Install fails → failed{install_failed}; retry_install raises it again.
    fx.dl.send(.{ .install_failed = .{ .job_id = id, .msg = "disk said no" } });
    fx.dl.stepOnce(1002);
    try testing.expectEqual(model.Step.failed, fx.rec(id).job.step);
    try testing.expectEqual(model.FailReason.install_failed, fx.rec(id).job.fail.?);
    fx.dl.send(.{ .retry_install = id });
    fx.dl.stepOnce(1003);
    try testing.expectEqual(model.Step.installing, fx.rec(id).job.step);
    {
        const evs = fx.dl.drainEvents(testing.allocator);
        defer Downloader.freeEvents(testing.allocator, evs);
        try testing.expectEqual(@as(usize, 1), evs.len);
        try testing.expectEqual(id, evs[0].install_ready.job_id);
    }
    fx.dl.send(.{ .install_ack = id });
    fx.dl.stepOnce(1004);
    try testing.expectEqual(model.Step.done, fx.rec(id).job.step);

    // A done job: same again. Pretend it was a torrent with no live ref:
    // the ack must land on done, not on a seeding step nothing polls.
    fx.rec(id).job.engine = .aria2_torrent;
    if (fx.rec(id).job.engine_ref) |ref| testing.allocator.free(ref);
    fx.rec(id).job.engine_ref = null;
    fx.dl.send(.{ .retry_install = id });
    fx.dl.stepOnce(1005);
    try testing.expectEqual(model.Step.installing, fx.rec(id).job.step);
    Downloader.freeEvents(testing.allocator, fx.dl.drainEvents(testing.allocator));
    fx.dl.send(.{ .install_ack = id });
    fx.dl.stepOnce(1006);
    try testing.expectEqual(model.Step.done, fx.rec(id).job.step);

    // Any other step ignores it.
    fx.enqueue("https://example.invalid/other.bin");
    fx.dl.stepOnce(1007);
    const id2 = fx.dl.recs.items[1].job.id;
    const before = fx.rec(id2).job.step;
    fx.dl.send(.{ .retry_install = id2 });
    fx.dl.stepOnce(1008);
    try testing.expect(fx.rec(id2).job.step != .installing or before == .installing);
}
