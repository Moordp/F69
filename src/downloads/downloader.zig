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
const resolve = @import("resolve.zig");
const errs = @import("errors.zig");
const watch = @import("watch.zig");
const megacmd = @import("megacmd.zig");
const dl_classify = @import("f95").dl_classify;

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
/// Detail while another job's extract writes into the same folder.
const EXTRACT_WAIT = "Waiting for another extraction into the same folder";
/// Donor DDL link refused (expired signed URL / cookie).
const LINK_EXPIRED = "Link expired — click Download again";
/// `deinit` waits at most this long for running workers, then lets them go.
const QUIT_WAIT_MS: u32 = 3000;
/// Sibling folders tried after `<dir>` (`<dir> (2)` … `<dir> (99)`).
const MAX_SIBLINGS: u32 = 99;
const BROWSER_STAGE2 = "This host needs the browser flow (coming in 0.15.18)";
/// A resolved link older than this is resolved again on retry (spec §3.6).
const RESOLVE_CACHE_S: i64 = 3600;
/// At most one "sign in to F95" prompt per this many seconds.
const SIGN_IN_EVENT_S: i64 = 60;
/// The watched folder is listed at most this often (spec §3.5 watch.zig).
const SCAN_EVERY_S: i64 = 2;
/// `step_detail` of a job waiting in the browser; " · watching <dir>" is
/// appended when the watched folder is known.
const WAITING_BROWSER = "Waiting for you in the browser";

/// `EnqueueUrl.host` for a pasted link. Resolved only when it points at a
/// known file host or an F95 masked link (`needsResolve`).
pub const HOST_RAW = "raw";
/// `EnqueueUrl.host` for an F95 donor DDL link: already direct, carries
/// its own cookie header; never resolved.
pub const HOST_DONOR = "donor";

/// The resolver's HTTP. Null in `Downloader.init` = links are used as is.
pub const ResolverCtx = struct { http: resolve.Http };

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

/// A catalogue link of a game (spec §3.8); the downloader reads the row.
pub const EnqueueCatalogue = struct {
    game_thread_id: u64,
    href: []const u8,
    title: []const u8,
    group_with: ?u64 = null,
    /// The game's latest version (spec §3.7): names the install folder.
    version: ?[]const u8 = null,
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
    /// Jobs that are moving: not terminal, not paused, not seeding, not
    /// waiting for the user.
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

/// `fresh`: the extract that follows a download; a non-empty folder that
/// is not this job's goes to a new sibling. `again`: reconcile or
/// "Install again" — an existing folder is registered as it is.
const ExtractMode = enum { fresh, again };

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

/// A resolve run. Owns its href; the `Http` context outlives the
/// downloader (main.zig declares it first). The result is freed by whoever
/// takes it, or by `destroy` when nobody did.
const ResolveWorker = struct {
    const Out = errs.Error!resolve.Result;
    w: workers.Worker(Out) = .{},
    alloc: std.mem.Allocator,
    http: resolve.Http,
    href: []u8,

    fn run(rw: *ResolveWorker) Out {
        // Only the href is classified here: host and wrapper come from it;
        // the text-based host guess for hidden links must not send a
        // blanked href to a host resolver.
        const entry = dl_classify.classify(rw.href, "", "", "");
        return resolve.resolve(rw.alloc, rw.http, rw.href, entry, 0);
    }

    fn destroy(rw: *ResolveWorker) void {
        rw.w.join();
        if (rw.w.take()) |out| {
            var res = out catch null;
            if (res) |*r| r.deinit(rw.alloc);
        }
        rw.alloc.free(rw.href);
        rw.alloc.destroy(rw);
    }
};

/// Moves a file the user downloaded in the browser into the job's
/// `dest_dir` (rename, or copy + delete across devices: slow on NTFS, so
/// never on the downloader loop). Owns copies of its paths; the moved path
/// in the result is taken by `reapMoves`, or freed by `destroy`.
const MoveWorker = struct {
    const Out = anyerror!watch.MovedPath;
    w: workers.Worker(Out) = .{},
    alloc: std.mem.Allocator,
    io: std.Io,
    src: []u8,
    dest_dir: []u8,
    /// The file came from the watched folder (a match), not a pick: if it
    /// is gone by the time it moves, the job keeps waiting.
    from_watch: bool = false,

    fn run(mw: *MoveWorker) Out {
        return watch.moveIntoDir(mw.io, mw.alloc, mw.src, mw.dest_dir);
    }

    fn destroy(mw: *MoveWorker) void {
        mw.w.join();
        if (mw.w.take()) |out| {
            if (out) |m| mw.alloc.free(m.path) else |_| {}
        }
        mw.alloc.free(mw.src);
        mw.alloc.free(mw.dest_dir);
        mw.alloc.destroy(mw);
    }
};

/// A watched-folder file matched by size or as the only waiting job: shown
/// as a prompt until the user answers `accept_match`. All owned.
pub const PendingMatch = struct {
    path: []u8,
    size: u64,
    /// "Found <name> (<size>) — use it?"
    prompt: []u8,
};

/// One job as the downloader holds it.
pub const Rec = struct {
    job: model.Job,
    /// Owned copy for the first start of an `enqueue_torrent` job.
    torrent_bytes: ?[]u8 = null,
    worker: ?*PostWorker = null,
    resolve_worker: ?*ResolveWorker = null,
    /// Browser flow: a picked or matched file on its way into `dest_dir`.
    move_worker: ?*MoveWorker = null,
    /// When the job last entered `awaiting_user` (or the app restarted
    /// with it there); watched-folder files older than this are ignored.
    awaiting_since: i64 = 0,
    pending_match: ?PendingMatch = null,
    /// Extract held back while another job extracts into the same folder;
    /// retried each tick with this mode. Null = not waiting.
    extract_wait: ?ExtractMode = null,
    /// Watched-folder files the user said "no" to (owned paths). They are
    /// not offered again, to this job or any other.
    rejected: std.ArrayList([]u8) = .empty,
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
    resolver: ?ResolverCtx,
    /// Owns `settings` strings after a `reload_settings`; null while they
    /// are the caller's (from `init`).
    settings_arena: ?std.heap.ArenaAllocator = null,

    /// Ordered by id (FIFO). Only the downloader thread touches it.
    recs: std.ArrayList(*Rec) = .empty,
    /// Workers whose job was removed while they ran; freed once done.
    orphans: std.ArrayList(*PostWorker) = .empty,
    resolve_orphans: std.ArrayList(*ResolveWorker) = .empty,
    move_orphans: std.ArrayList(*MoveWorker) = .empty,
    loaded: bool = false,
    /// Process environment, for the default watched folder when
    /// `settings.watch_dir` is empty. Set by main before `start`; null
    /// (tests) = no default folder.
    environ: ?std.process.Environ = null,
    /// Watched-folder scanner, created on first use while a job waits in
    /// the browser; dropped when `reload_settings` changes the folder.
    scanner: ?watch.Scanner = null,
    /// The scanner's folder (owned; `Scanner.dir` borrows it).
    scanner_dir: ?[]u8 = null,
    last_scan_at: ?i64 = null,
    /// When the last `sign_in_needed = .f95` event went out.
    sign_in_at: ?i64 = null,

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
        resolver: ?ResolverCtx,
    ) Downloader {
        return .{
            .alloc = alloc,
            .io = io,
            .store = store,
            .engines = engines,
            .roots = roots,
            .settings = settings,
            .resolver = resolver,
            .snap_arenas = .{ .init(alloc), .init(alloc) },
        };
    }

    /// Stops the thread if running, frees everything and closes the store.
    /// Engines belong to the caller. Running workers (extract, verify,
    /// resolve, move) get at most `QUIT_WAIT_MS` in total; any still
    /// running after that is detached and its memory left allocated (the
    /// process is quitting). An interrupted extract keeps its marker and is
    /// redone by the next start's reconcile. Returns how many workers were
    /// left running: when non-zero, the caller must not free anything a
    /// worker may use (resolver HTTP, engines, allocator, io) — exit.
    pub fn deinit(self: *Downloader) usize {
        self.stop();
        for (self.recs.items) |r| self.freeRec(r);
        self.recs.deinit(self.alloc);
        self.waitOrphans(QUIT_WAIT_MS);
        var left: usize = 0;
        for (self.orphans.items) |pw| {
            if (pw.w.running()) {
                pw.w.detach();
                left += 1;
            } else pw.destroy();
        }
        self.orphans.deinit(self.alloc);
        for (self.resolve_orphans.items) |rw| {
            if (rw.w.running()) {
                rw.w.detach();
                left += 1;
            } else rw.destroy();
        }
        self.resolve_orphans.deinit(self.alloc);
        for (self.move_orphans.items) |mw| {
            if (mw.w.running()) {
                mw.w.detach();
                left += 1;
            } else mw.destroy();
        }
        self.move_orphans.deinit(self.alloc);
        if (left > 0) log.warn("quit: {d} background task(s) still running after {d} ms were left to end with the process", .{ left, QUIT_WAIT_MS });
        self.dropScanner();
        for (self.cmds.items) |*q| q.arena.deinit();
        self.cmds.deinit(self.alloc);
        for (self.events.items) |e| freeEvent(self.alloc, e);
        self.events.deinit(self.alloc);
        for (&self.snap_arenas) |*a| a.deinit();
        if (self.settings_arena) |*a| a.deinit();
        self.store.close();
        return left;
    }

    /// Sleep in short steps until no orphaned worker runs or `max_ms` pass.
    fn waitOrphans(self: *Downloader, max_ms: u32) void {
        var waited: u32 = 0;
        while (waited < max_ms) : (waited += 20) {
            var busy = false;
            for (self.orphans.items) |pw| busy = busy or pw.w.running();
            for (self.resolve_orphans.items) |rw| busy = busy or rw.w.running();
            for (self.move_orphans.items) |mw| busy = busy or mw.w.running();
            if (!busy) return;
            self.io.sleep(std.Io.Duration.fromMilliseconds(20), .real) catch return;
        }
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
        self.retryWaitingExtracts(now);
        self.reapResolves(now);
        self.reapMoves(now);
        self.scanWatched(now);
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
            .enqueue_catalogue => |e| self.enqueueCatalogue(e, now),
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
            .paste_link => |p| if (self.awaiting(p.job_id)) |r| self.pasteLink(r, p.url, now),
            .pick_file => |p| if (self.awaiting(p.job_id)) |r| self.adoptFile(r, p.path, false, now),
            .accept_match => |m| if (self.awaiting(m.job_id)) |r| self.acceptMatch(r, m.accept, now),
            .open_again => |id| if (self.awaiting(id)) |r| self.pushEvent(.{ .open_url = browserUrl(&r.job) }),
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
        var buf: [1200]u8 = undefined;
        if (self.downloadOnlyDetail(r, &buf) != null) {
            log.info("job {d}: retry_install ignored: not installed automatically", .{j.id});
            return self.toast("This download is not installed automatically — open its folder");
        }
        if (j.step == .seeding) return self.raiseInstall(r);
        const again = j.step == .done or (j.step == .failed and j.fail == .install_failed);
        if (!again) {
            log.warn("job {d}: retry_install ignored in step {s}", .{ j.id, @tagName(j.step) });
            return;
        }
        self.apply(r, .{ .step = .extracting, .attempts = j.attempts }, now);
        self.startExtract(r, now, .again);
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
        // Compare before the old strings are freed with their arena.
        if (!std.mem.eql(u8, self.settings.watch_dir, copy.watch_dir)) self.dropScanner();
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
        _ = self.addJob(&job, null, now, "enqueued");
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
        _ = self.addJob(&job, e.torrent_bytes, now, "enqueued");
    }

    /// Queue a link from the game's catalogue (spec §3.8). The downloader
    /// reads the catalogue row itself, so the UI only sends the href.
    fn enqueueCatalogue(self: *Downloader, e: EnqueueCatalogue, now: i64) void {
        for (self.recs.items) |r| {
            if (!r.job.step.isTerminal() and std.mem.eql(u8, r.job.source_href, e.href)) return self.toast("Already queued");
        }
        const rows = self.store.listCatalogue(self.alloc, e.game_thread_id) catch
            return self.toast("Could not read the game's download links (database error)");
        defer store_mod.Store.freeCatalogue(self.alloc, rows);
        const row = for (rows) |c| {
            if (std.mem.eql(u8, c.href, e.href)) break c;
        } else return self.toast("Link not in the catalogue — sync the game first");

        const entry = dl_classify.classify(row.href, row.text, row.lead, row.ctx);
        var plat_buf: [32]u8 = undefined;
        const plat = platformLabel(&plat_buf, entry.platform);
        var title_buf: [512]u8 = undefined;
        const title = catalogueTitle(&title_buf, e.title, entry.part, plat);
        const job: model.Job = .{
            .id = 0,
            .group_id = e.group_with orelse 0,
            // An update-only patch is not a full game: it is downloaded and
            // applied by hand, like extras (`downloadOnlyDetail`).
            .kind = if (entry.update_only) .extra else switch (entry.kind) {
                .game => .game,
                .mod => .mod,
                .extra, .translation => .extra,
            },
            .game_thread_id = e.game_thread_id,
            .title = title,
            .source_href = e.href,
            .host = entry.host.label(),
            .engine = resolve.engineFor(entry, e.href),
            .platform = plat,
            .part = entry.part,
            .version = e.version,
            .step = .queued,
            .dest_dir = "",
            .created_at = now,
            .updated_at = now,
        };
        _ = self.addJob(&job, null, now, "enqueued from thread");
    }

    /// Insert (to get the id), set `dest_dir`, keep an owned copy in memory.
    fn addJob(self: *Downloader, tmpl: *const model.Job, torrent: ?[]const u8, now: i64, event_msg: []const u8) ?*Rec {
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
        self.store.addEvent(id, now, .queued, event_msg) catch |e|
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

    /// The job just entered `resolving`. Without a resolver, or for a link
    /// that is already direct, the link is used as is. A link resolved less
    /// than an hour ago is reused (spec §3.6). Otherwise a worker resolves
    /// it; `reapResolves` reads the result.
    fn startResolve(self: *Downloader, r: *Rec, now: i64) void {
        // Already known to need the browser (retried, or resolving at a
        // restart): straight back to waiting for the user.
        if (r.job.engine == .browser) return self.transition(r, .needs_browser, now, null);
        const identity: model.Input = .{ .resolved = .{ .engine = r.job.engine } };
        const rc = self.resolver orelse return self.transition(r, identity, now, null);
        if (!needsResolve(&r.job)) return self.transition(r, identity, now, null);
        if (r.job.resolved_url != null) {
            if (r.job.resolved_at) |at| {
                if (now - at < RESOLVE_CACHE_S) return self.transition(r, identity, now, null);
            }
        }
        self.spawnResolve(r, rc, r.job.source_href, now);
    }

    /// Resolve `href` on a worker for a job in `resolving`.
    fn spawnResolve(self: *Downloader, r: *Rec, rc: ResolverCtx, href: []const u8, now: i64) void {
        const rw = self.alloc.create(ResolveWorker) catch
            return self.resolveFailed(r, error.OutOfMemory, now);
        rw.* = .{ .alloc = self.alloc, .http = rc.http, .href = self.alloc.dupe(u8, href) catch {
            self.alloc.destroy(rw);
            return self.resolveFailed(r, error.OutOfMemory, now);
        } };
        rw.w.spawn(ResolveWorker.run, .{rw}) catch |e| {
            log.err("job {d}: resolve worker spawn failed: {s}", .{ r.job.id, @errorName(e) });
            self.alloc.free(rw.href);
            self.alloc.destroy(rw);
            return self.resolveFailed(r, error.NetworkError, now);
        };
        if (r.resolve_worker) |old| self.orphanResolve(old);
        r.resolve_worker = rw;
    }

    fn orphanResolve(self: *Downloader, rw: *ResolveWorker) void {
        self.resolve_orphans.append(self.alloc, rw) catch rw.destroy();
    }

    /// Resolver error (network, out of memory): a retryable network
    /// failure, on the same back-off as an engine's.
    fn resolveFailed(self: *Downloader, r: *Rec, e: errs.Error, now: i64) void {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Could not resolve the link: {s}", .{@errorName(e)}) catch "Could not resolve the link";
        var t: model.Transition = .{ .step = .failed, .fail = .network, .detail = msg, .attempts = r.job.attempts };
        if (model.retryDelaySeconds(r.job.attempts)) |d| t.next_retry_at = now + @as(i64, d);
        self.apply(r, t, now);
    }

    fn reapResolves(self: *Downloader, now: i64) void {
        for (self.recs.items) |r| {
            const rw = r.resolve_worker orelse continue;
            const out = rw.w.take() orelse continue;
            r.resolve_worker = null;
            rw.destroy();
            var res = out catch |e| {
                if (r.job.step == .resolving) self.resolveFailed(r, e, now);
                continue;
            };
            defer res.deinit(self.alloc);
            // Cancelled (or removed and re-added) while the worker ran.
            if (r.job.step != .resolving) continue;
            self.applyResolved(r, &res, now);
        }
        var i: usize = 0;
        while (i < self.resolve_orphans.items.len) {
            const rw = self.resolve_orphans.items[i];
            if (rw.w.phase.load(.acquire) == @backingInt(workers.Phase.done)) {
                rw.destroy();
                _ = self.resolve_orphans.swapRemove(i);
            } else i += 1;
        }
    }

    fn applyResolved(self: *Downloader, r: *Rec, res: *resolve.Result, now: i64) void {
        const j = &r.job;
        switch (res.*) {
            .direct => |d| {
                self.setResolved(r, d.url, d.headers, d.engine, now) catch return self.resolveFailed(r, error.OutOfMemory, now);
                if (d.size) |n| {
                    if (j.bytes_total == null) j.bytes_total = n;
                }
                self.transition(r, .{ .resolved = .{ .engine = j.engine } }, now, null);
            },
            .mega => |link| {
                self.setResolved(r, link, &.{}, .megacmd, now) catch return self.resolveFailed(r, error.OutOfMemory, now);
                self.transition(r, .{ .resolved = .{ .engine = .megacmd } }, now, null);
            },
            .torrent_url => |url| {
                self.setResolved(r, url, &.{}, .aria2_torrent, now) catch return self.resolveFailed(r, error.OutOfMemory, now);
                self.transition(r, .{ .resolved = .{ .engine = .aria2_torrent } }, now, null);
            },
            .needs_browser, .captcha => self.transition(r, .needs_browser, now, null),
            .dead => |msg| self.transition(r, .{ .dead = msg }, now, null),
            .auth_required => {
                self.transition(r, .auth_required, now, "Sign in to F95Zone, then Retry");
                const due = if (self.sign_in_at) |at| now - at >= SIGN_IN_EVENT_S else true;
                if (due) {
                    self.sign_in_at = now;
                    self.pushEvent(.{ .sign_in_needed = .f95 });
                }
            },
        }
    }

    /// Store the resolver's answer on the job. A changed engine moves the
    /// job's (still empty) download folder under the new engine's name.
    fn setResolved(self: *Downloader, r: *Rec, url: []const u8, headers: []const []const u8, engine: model.EngineKind, now: i64) !void {
        const j = &r.job;
        const new_url = try self.alloc.dupe(u8, url);
        errdefer self.alloc.free(new_url);
        const new_headers = try dupeList(self.alloc, headers);
        errdefer freeList(self.alloc, new_headers);
        try self.switchEngine(r, engine);
        if (j.resolved_url) |old| freeStr(self.alloc, old);
        j.resolved_url = new_url;
        freeList(self.alloc, j.resolved_headers);
        j.resolved_headers = new_headers;
        j.resolved_at = now;
        r.dirty = true;
    }

    /// A changed engine moves the job's (still empty) download folder under
    /// the new engine's name.
    fn switchEngine(self: *Downloader, r: *Rec, engine: model.EngineKind) !void {
        const j = &r.job;
        if (engine == j.engine) return;
        const dir = try std.fmt.allocPrint(self.alloc, "{s}" ++ sep ++ "{s}" ++ sep ++ "{d}" ++ sep, .{
            self.roots.downloads_root, @tagName(engine), j.id,
        });
        freeStr(self.alloc, j.dest_dir);
        j.dest_dir = dir;
        j.engine = engine;
        r.dirty = true;
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
            .megacmd => .{ .step = .failed, .fail = .engine_missing, .detail = megacmd.installHint(), .attempts = r.job.attempts },
            else => .{ .step = .failed, .fail = .unknown, .detail = BROWSER_STAGE2, .attempts = r.job.attempts },
        };
        self.apply(r, t, now);
    }

    fn startEngine(self: *Downloader, r: *Rec, now: i64) void {
        const eng = self.engineFor(r.job.engine) orelse return self.missingEngine(r, now);
        if (r.job.engine == .aria2_torrent and r.torrent_bytes == null and !isFetchableTorrentHref(r.job.resolved_url orelse r.job.source_href)) {
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
        // A donor link the CDN refuses has expired: only a new Download
        // click (a fresh signed URL) helps; F95 sign-in does not.
        const expired = p.phase == .failed and isDonor(j) and (p.fail == .auth_required or p.fail == .host_gone);
        self.transition(r, .{ .engine_progress = .{ .p = p, .now = now } }, now, if (expired) LINK_EXPIRED else null);
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
        if (step_changed and j.step == .awaiting_user) self.clearPending(r);

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
        if (step_changed and t.step.isTerminal()) {
            self.trim_due = true;
            // Cookies never stay on a finished row. A failure with an
            // automatic retry pending keeps them until that retry runs.
            if (!(t.step == .failed and t.next_retry_at != null)) dropSecrets(self.alloc, j);
        }
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
            .start_extract => self.startExtract(r, now, .fresh),
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
            .open_browser => {
                // Stage 2 has no browser engine: the job cannot wait for
                // a browser download that nothing would pick up.
                const eng = self.engines.browser orelse return self.apply(r, .{
                    .step = .failed,
                    .fail = .unknown,
                    .detail = BROWSER_STAGE2,
                    .attempts = r.job.attempts,
                }, now);
                self.openBrowser(r, eng, now);
            },
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

    /// After verify (and on reconcile / "Install again"): extract the
    /// archive into the job's library folder, or finish without extracting
    /// for downloads that are not installed automatically.
    fn startExtract(self: *Downloader, r: *Rec, now: i64, mode: ExtractMode) void {
        r.extract_wait = null;
        const path = r.job.final_path orelse
            return self.transition(r, .{ .extract_err = .bad_archive }, now, "The downloaded file could not be found");
        var why_buf: [1200]u8 = undefined;
        if (self.downloadOnlyDetail(r, &why_buf)) |why| return self.finishDownloadOnly(r, why, now);
        if (archive.detectFormat(path) == .unknown) return self.transition(r, .extract_ok, now, NOT_ARCHIVE);
        if (r.job.kind == .mod) return self.transition(r, .extract_ok, now, MOD_ARCHIVE);
        var dir: []u8 = (if (r.job.extract_dir) |d| self.alloc.dupe(u8, d) else self.extractDirN(&r.job, 1)) catch
            return self.transition(r, .{ .extract_err = .unknown }, now, "Out of memory");
        // Never two extracts into one folder: wait for the other job's
        // worker (it always ends; a waiting job holds no worker, so two
        // waiting jobs never wait on each other).
        if (self.extractBusy(r, dir)) {
            self.alloc.free(dir);
            r.extract_wait = mode;
            self.apply(r, .{ .step = .extracting, .detail = EXTRACT_WAIT, .attempts = r.job.attempts }, now);
            return;
        }
        var marker = std.fmt.allocPrint(self.alloc, "{s}" ++ EXTRACT_MARKER, .{dir}) catch {
            self.alloc.free(dir);
            return self.transition(r, .{ .extract_err = .unknown }, now, "Out of memory");
        };
        const cwd = std.Io.Dir.cwd();
        if ((cwd.access(self.io, marker, .{}) catch null) != null) {
            // An interrupted extract (no worker runs there): start over.
            log.info("job {d}: clearing half-extracted '{s}'", .{ r.job.id, dir });
            cwd.deleteTree(self.io, dir) catch |e|
                log.warn("job {d}: clearing '{s}' failed: {s}", .{ r.job.id, dir, @errorName(e) });
        } else if (dirHasEntries(self.io, dir)) {
            self.alloc.free(marker);
            if (mode == .again or r.job.extract_dir != null) {
                // This job's own finished extract (or "Install again" of
                // what is on disk): register the folder as it is.
                self.setExtractDir(r, dir);
                self.alloc.free(dir);
                return self.transition(r, .extract_ok, now, FOLDER_EXISTS);
            }
            // Someone else's files: never register them under this job.
            self.alloc.free(dir);
            dir = self.freeSibling(r) orelse
                return self.transition(r, .{ .extract_err = .unknown }, now, "No free folder for this version in the library");
            marker = std.fmt.allocPrint(self.alloc, "{s}" ++ EXTRACT_MARKER, .{dir}) catch {
                self.alloc.free(dir);
                return self.transition(r, .{ .extract_err = .unknown }, now, "Out of memory");
            };
        }
        self.setExtractDir(r, dir);
        writeMarker(self.io, dir, marker);
        const pw = self.newWorker(.extract, path, dir, marker) catch {
            self.alloc.free(marker);
            self.alloc.free(dir);
            return self.transition(r, .{ .extract_err = .unknown }, now, "Could not start extracting");
        };
        self.spawnWorker(r, pw, now);
        if (std.mem.eql(u8, r.job.step_detail, EXTRACT_WAIT))
            self.apply(r, .{ .step = r.job.step, .attempts = r.job.attempts }, now);
    }

    /// Jobs held by `extract_wait` try again (after `reapWorkers`, so a
    /// folder freed this tick is seen at once).
    fn retryWaitingExtracts(self: *Downloader, now: i64) void {
        for (self.recs.items) |r| {
            const mode = r.extract_wait orelse continue;
            if (r.job.step != .extracting or r.worker != null) {
                r.extract_wait = null;
                continue;
            }
            self.startExtract(r, now, mode);
        }
    }

    /// Another job's (or an orphaned) extract worker writes into `dir`.
    fn extractBusy(self: *Downloader, r: *const Rec, dir: []const u8) bool {
        for (self.recs.items) |o| {
            if (o == r) continue;
            const pw = o.worker orelse continue;
            if (pw.kind == .extract and std.mem.eql(u8, pw.dest, dir)) return true;
        }
        for (self.orphans.items) |pw| {
            if (pw.kind == .extract and pw.w.running() and std.mem.eql(u8, pw.dest, dir)) return true;
        }
        return false;
    }

    /// The first `<dir> (N)` (N = 2…) that is missing or empty and not in
    /// use; null when all are taken. Owned.
    fn freeSibling(self: *Downloader, r: *const Rec) ?[]u8 {
        var n: u32 = 2;
        while (n <= MAX_SIBLINGS) : (n += 1) {
            const cand = self.extractDirN(&r.job, n) catch return null;
            if (!self.extractBusy(r, cand) and !dirHasEntries(self.io, cand)) return cand;
            self.alloc.free(cand);
        }
        return null;
    }

    /// Remember (and store at once, so a crash cannot lose it) the folder
    /// the job extracts into.
    fn setExtractDir(self: *Downloader, r: *Rec, dir: []const u8) void {
        if (r.job.extract_dir) |old| {
            if (std.mem.eql(u8, old, dir)) return;
        }
        const copy = self.alloc.dupe(u8, dir) catch {
            log.warn("job {d}: extract folder not remembered (out of memory)", .{r.job.id});
            return;
        };
        if (r.job.extract_dir) |old| freeStr(self.alloc, old);
        r.job.extract_dir = copy;
        r.dirty = true;
        self.store.update(&r.job) catch |e|
            log.warn("job {d}: extract folder not stored yet: {s}", .{ r.job.id, @errorName(e) });
    }

    /// Why this job is downloaded but not extracted / installed, or null
    /// when it installs normally:
    ///   - a pasted URL with no game (`game_thread_id == 0`);
    ///   - an extra / translation / update-only patch, or a mod without a
    ///     mod id (only the mod manager's own jobs have one);
    ///   - one part of a multi-part set (part 1 must be extracted by hand
    ///     once every part is there).
    fn downloadOnlyDetail(self: *Downloader, r: *const Rec, buf: []u8) ?[]const u8 {
        const j = &r.job;
        if (j.game_thread_id == 0)
            return std.fmt.bufPrint(buf, "Downloaded to {s}", .{j.dest_dir}) catch "Downloaded";
        if (j.kind == .extra or (j.kind == .mod and j.mod_id == null))
            return std.fmt.bufPrint(buf, "Downloaded to {s} — apply it by hand (Mods / patch)", .{j.dest_dir}) catch "Downloaded — apply it by hand (Mods / patch)";
        if (self.isMultiPart(r)) {
            const tail = " — extract part 1 by hand once all parts are here";
            if (j.part) |n| return std.fmt.bufPrint(buf, "Downloaded part {d}" ++ tail, .{n}) catch "Downloaded this part" ++ tail;
            return "Downloaded this part" ++ tail;
        }
        return null;
    }

    /// Part of a set: grouped with an earlier job, or a numbered part
    /// whose group has more than one job.
    fn isMultiPart(self: *Downloader, r: *const Rec) bool {
        const j = &r.job;
        if (j.group_id != j.id) return true;
        if (j.part == null) return false;
        var n: usize = 0;
        for (self.recs.items) |o| {
            if (o.job.group_id == j.group_id) n += 1;
        }
        return n > 1;
    }

    /// End a download-only job: `done` with `why`, or `seeding` for a
    /// torrent still held by aria2 (it seeds like any finished torrent).
    fn finishDownloadOnly(self: *Downloader, r: *Rec, why: []const u8, now: i64) void {
        const step: model.Step = if (r.job.engine == .aria2_torrent and r.job.engine_ref != null) .seeding else .done;
        self.apply(r, .{ .step = step, .detail = why, .attempts = r.job.attempts }, now);
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

    /// `<library_root>/<game_thread_id>/<version or "unversioned">` plus
    /// ` (<platform>)` when the link names one and ` (<n>)` for n > 1, and
    /// a trailing separator; e.g. `…/9/v1.2 (Linux)/`. Owned.
    fn extractDirN(self: *Downloader, j: *const model.Job, n: u32) ![]u8 {
        var vbuf: [128]u8 = undefined;
        const v = safeSegment(&vbuf, j.version);
        var sbuf: [96]u8 = undefined;
        var sn: usize = 0;
        if (j.platform) |p| if (p.len > 0) {
            var pbuf: [48]u8 = undefined;
            if (std.fmt.bufPrint(sbuf[sn..], " ({s})", .{safeSegment(&pbuf, p)})) |w| sn += w.len else |_| {}
        };
        if (n > 1) {
            if (std.fmt.bufPrint(sbuf[sn..], " ({d})", .{n})) |w| sn += w.len else |_| {}
        }
        return std.fmt.allocPrint(self.alloc, "{s}" ++ sep ++ "{d}" ++ sep ++ "{s}{s}" ++ sep, .{ self.roots.library_root, j.game_thread_id, v, sbuf[0..sn] });
    }

    fn installReady(self: *Downloader, j: *const model.Job) !InstallReady {
        const archive_path = j.final_path orelse "";
        const extracted: ?[]u8 = if (j.kind != .mod and archive.detectFormat(archive_path) != .unknown)
            (if (j.extract_dir) |d| try self.alloc.dupe(u8, d) else try self.extractDirN(j, 1))
        else
            null;
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

    // ------------------------------------------------------------ browser flow

    /// The job, when it is waiting for the user; otherwise null (logged:
    /// a late click on a row that has moved on).
    fn awaiting(self: *Downloader, id: u64) ?*Rec {
        const r = self.find(id) orelse return null;
        if (r.job.step == .awaiting_user) return r;
        log.info("job {d}: browser command ignored in step {s}", .{ id, @tagName(r.job.step) });
        return null;
    }

    /// `open_browser` effect: the job now belongs to the browser engine.
    /// Raises `open_url` once; the watched folder takes over from here.
    fn openBrowser(self: *Downloader, r: *Rec, eng: Engine, now: i64) void {
        const j = &r.job;
        self.cancelEngine(r);
        self.switchEngine(r, .browser) catch log.warn("job {d}: out of memory switching to the browser engine", .{j.id});
        j.engine_ref = eng.start(.{
            .job_id = j.id,
            .url = browserUrl(j),
            .headers = &.{},
            .dest_dir = j.dest_dir,
            .out_name = null,
            .torrent_bytes = null,
        }) catch |e| blk: {
            log.warn("job {d}: browser engine start failed: {s}", .{ j.id, @errorName(e) });
            break :blk null;
        };
        r.awaiting_since = now;
        r.dirty = true;
        self.clearPending(r);
        self.pushEvent(.{ .open_url = browserUrl(j) });
        var buf: [1024]u8 = undefined;
        const detail = if (self.watchDir()) |d|
            std.fmt.bufPrint(&buf, WAITING_BROWSER ++ " · watching {s}", .{d}) catch WAITING_BROWSER
        else
            WAITING_BROWSER;
        self.apply(r, .{ .step = .awaiting_user, .detail = detail, .attempts = j.attempts }, now);
    }

    /// The watched folder (`settings.watch_dir`, else the OS default), or
    /// null when neither is known. Creates the scanner on first use.
    fn watchDir(self: *Downloader) ?[]const u8 {
        if (self.scanner_dir) |d| return d;
        const dir: []u8 = if (self.settings.watch_dir.len > 0)
            self.alloc.dupe(u8, self.settings.watch_dir) catch return null
        else if (self.environ) |env|
            watch.defaultWatchDir(self.alloc, self.io, env) catch |e| {
                log.warn("no default watched folder: {s}", .{@errorName(e)});
                return null;
            }
        else
            return null;
        self.scanner_dir = dir;
        self.scanner = watch.Scanner.init(self.alloc, self.io, dir);
        return dir;
    }

    fn dropScanner(self: *Downloader) void {
        if (self.scanner) |*s| s.deinit();
        self.scanner = null;
        if (self.scanner_dir) |d| self.alloc.free(d);
        self.scanner_dir = null;
        self.last_scan_at = null;
    }

    /// `paste_link`: a direct link switches the job to aria2 (or MEGAcmd)
    /// and starts it; an F95 masked link goes through the resolver first.
    fn pasteLink(self: *Downloader, r: *Rec, raw: []const u8, now: i64) void {
        const url = std.mem.trim(u8, raw, " \t\r\n");
        const is_url = std.mem.startsWith(u8, url, "http://") or
            std.mem.startsWith(u8, url, "https://") or
            std.mem.startsWith(u8, url, "magnet:");
        if (!is_url) return self.toast("That is not a link");
        const p = dl_classify.parseHref(url);
        // Same rule as `needsResolve`: a masked link or a file-host page
        // goes through the resolver; a host page given to aria2 would
        // download the HTML.
        if (p.wrapper == .masked or (p.host.isFileHost() and self.resolver != null)) {
            const rc = self.resolver orelse return self.toast("That link cannot be resolved here — paste the final download link");
            self.cancelEngine(r);
            self.apply(r, .{ .step = .resolving, .attempts = r.job.attempts }, now);
            return self.spawnResolve(r, rc, url, now);
        }
        const kind: model.EngineKind = if (p.host == .mega) .megacmd else engineKindForUrl(url);
        // Drop the browser ref while the job still names the browser engine.
        self.cancelEngine(r);
        self.setResolved(r, url, &.{}, kind, now) catch return self.toast("Could not use the link (out of memory)");
        self.transition(r, .{ .resolved = .{ .engine = kind } }, now, null);
    }

    /// Move `src` into the job's folder on a worker; `reapMoves` continues
    /// at `file_arrived`. One move per job at a time.
    fn adoptFile(self: *Downloader, r: *Rec, src: []const u8, from_watch: bool, now: i64) void {
        if (r.move_worker != null) return;
        const mw = self.alloc.create(MoveWorker) catch return self.moveFailed(r, error.OutOfMemory, now);
        mw.* = .{ .alloc = self.alloc, .io = self.io, .src = undefined, .dest_dir = undefined, .from_watch = from_watch };
        mw.src = self.alloc.dupe(u8, src) catch {
            self.alloc.destroy(mw);
            return self.moveFailed(r, error.OutOfMemory, now);
        };
        mw.dest_dir = self.alloc.dupe(u8, r.job.dest_dir) catch {
            self.alloc.free(mw.src);
            self.alloc.destroy(mw);
            return self.moveFailed(r, error.OutOfMemory, now);
        };
        mw.w.spawn(MoveWorker.run, .{mw}) catch |e| {
            log.err("job {d}: move worker spawn failed: {s}", .{ r.job.id, @errorName(e) });
            mw.destroy();
            return self.moveFailed(r, e, now);
        };
        r.move_worker = mw;
        self.clearPending(r);
        self.touched = true;
    }

    fn moveFailed(self: *Downloader, r: *Rec, e: anyerror, now: i64) void {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Could not move the file: {s}", .{@errorName(e)}) catch "Could not move the file";
        self.apply(r, .{ .step = .failed, .fail = .unknown, .detail = msg, .attempts = r.job.attempts }, now);
    }

    fn orphanMove(self: *Downloader, mw: *MoveWorker) void {
        self.move_orphans.append(self.alloc, mw) catch mw.destroy();
    }

    fn reapMoves(self: *Downloader, now: i64) void {
        for (self.recs.items) |r| {
            const mw = r.move_worker orelse continue;
            const out = mw.w.take() orelse continue;
            const from_watch = mw.from_watch;
            r.move_worker = null;
            mw.destroy();
            const moved = out catch |e| {
                log.warn("job {d}: moving the file failed: {s}", .{ r.job.id, @errorName(e) });
                if (r.job.step != .awaiting_user) continue;
                // A matched file deleted or renamed before it moved: not
                // the job's fault, keep waiting for another one.
                if (from_watch and e == error.FileNotFound) {
                    self.clearPending(r);
                    self.toast("That file is gone — still waiting");
                    continue;
                }
                self.moveFailed(r, e, now);
                continue;
            };
            if (r.job.step != .awaiting_user) {
                // Cancelled while the file moved: it stays in dest_dir.
                log.info("job {d}: file moved to '{s}' after the job left awaiting_user", .{ r.job.id, moved.path });
                self.alloc.free(moved.path);
                continue;
            }
            if (r.job.final_path) |old| freeStr(self.alloc, old);
            r.job.final_path = moved.path;
            r.dirty = true;
            self.cancelEngine(r);
            self.transition(r, .{ .file_arrived = moved.path }, now, null);
        }
        var i: usize = 0;
        while (i < self.move_orphans.items.len) {
            const mw = self.move_orphans.items[i];
            if (mw.w.phase.load(.acquire) == @backingInt(workers.Phase.done)) {
                mw.destroy();
                _ = self.move_orphans.swapRemove(i);
            } else i += 1;
        }
    }

    fn acceptMatch(self: *Downloader, r: *Rec, accept: bool, now: i64) void {
        const pm = r.pending_match orelse return;
        if (accept) {
            // `adoptFile` copies the path, then clears the prompt.
            self.adoptFile(r, pm.path, true, now);
            self.clearPending(r);
            return;
        }
        r.rejected.append(self.alloc, pm.path) catch self.alloc.free(pm.path);
        self.alloc.free(pm.prompt);
        r.pending_match = null;
        self.touched = true;
    }

    fn proposeMatch(self: *Downloader, r: *Rec, c: watch.Candidate) void {
        const path = self.alloc.dupe(u8, c.path) catch return;
        var buf: [32]u8 = undefined;
        const prompt = std.fmt.allocPrint(self.alloc, "Found {s} ({s}) — use it?", .{ c.name, humanSize(&buf, c.size) }) catch {
            self.alloc.free(path);
            return;
        };
        self.clearPending(r);
        r.pending_match = .{ .path = path, .size = c.size, .prompt = prompt };
        self.touched = true;
    }

    fn clearPending(self: *Downloader, r: *Rec) void {
        const pm = r.pending_match orelse return;
        self.alloc.free(pm.path);
        self.alloc.free(pm.prompt);
        r.pending_match = null;
        self.touched = true;
    }

    /// A file that is already proposed, moving, or rejected.
    fn candidateTaken(self: *Downloader, path: []const u8) bool {
        for (self.recs.items) |r| {
            if (r.pending_match) |pm| if (std.mem.eql(u8, pm.path, path)) return true;
            if (r.move_worker) |mw| if (std.mem.eql(u8, mw.src, path)) return true;
            for (r.rejected.items) |p| if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    /// List the watched folder (at most every `SCAN_EVERY_S`, only while a
    /// job waits in the browser) and match ready files to waiting jobs:
    /// a name match is adopted at once, a size / only-one match becomes a
    /// prompt. Runs on the downloader thread, never the UI thread.
    fn scanWatched(self: *Downloader, now: i64) void {
        var any = false;
        for (self.recs.items) |r| {
            if (r.job.step == .awaiting_user) any = true;
        }
        if (!any) return;
        if (self.last_scan_at) |at| if (now - at < SCAN_EVERY_S) return;
        self.last_scan_at = now;
        _ = self.watchDir() orelse return;
        const sc = if (self.scanner) |*s| s else return;
        const cands = sc.scan(now) catch |e| {
            log.warn("watched folder scan failed: {s}", .{@errorName(e)});
            return;
        };
        defer watch.freeCandidates(self.alloc, cands);
        if (cands.len == 0) return;

        var free_cands: std.ArrayList(watch.Candidate) = .empty;
        defer free_cands.deinit(self.alloc);
        for (cands) |c| {
            if (self.candidateTaken(c.path)) continue;
            free_cands.append(self.alloc, c) catch return;
        }
        var waiting: std.ArrayList(watch.Waiting) = .empty;
        defer waiting.deinit(self.alloc);
        for (self.recs.items) |r| {
            if (r.job.step != .awaiting_user or r.move_worker != null or r.pending_match != null) continue;
            waiting.append(self.alloc, .{
                .job_id = r.job.id,
                .expected_name = expectedName(r.job.resolved_url orelse r.job.source_href),
                .expected_size = r.job.bytes_total,
                .since = r.awaiting_since,
            }) catch return;
        }
        // "Only one waiting job" counts every waiting job, also those with a
        // prompt or a move running, or a stray file would be offered to
        // the second job while the first is busy.
        var awaiting_total: usize = 0;
        for (self.recs.items) |r| {
            if (r.job.step == .awaiting_user) awaiting_total += 1;
        }
        while (watch.matchFile(free_cands.items, waiting.items)) |m| {
            if (m.confidence == .only_one and awaiting_total != 1) break;
            const c = free_cands.orderedRemove(m.candidate_idx);
            for (waiting.items, 0..) |w, i| {
                if (w.job_id != m.job_id) continue;
                _ = waiting.orderedRemove(i);
                break;
            }
            const r = self.find(m.job_id) orelse continue;
            switch (m.confidence) {
                .name => self.adoptFile(r, c.path, true, now),
                .size, .only_one => self.proposeMatch(r, c),
            }
        }
    }

    // ------------------------------------------------------------ reconcile

    fn reconcileOne(self: *Downloader, r: *Rec, now: i64) void {
        const j = &r.job;
        switch (j.step) {
            .done, .failed, .cancelled => {
                // Rows finished by an older build may still hold cookies.
                if (j.resolved_headers.len > 0 and !(j.step == .failed and j.next_retry_at != null)) {
                    dropSecrets(self.alloc, j);
                    r.dirty = true;
                }
            },
            .queued => {},
            .installing => self.raiseInstall(r),
            .verifying => self.startVerify(r, now),
            // A job that was waiting for another job's extract has no
            // folder of its own yet: a fresh start, never "register".
            .extracting => self.startExtract(r, now, if (j.extract_dir != null) .again else .fresh),
            // Browser jobs keep waiting; the page is not opened again (the
            // row offers "Open page again"). Files downloaded while f69
            // was closed are older than `awaiting_since` and not matched.
            .awaiting_user => if (j.engine != .browser) {
                self.apply(r, .{ .step = .queued, .attempts = j.attempts }, now);
            } else {
                r.awaiting_since = now;
            },
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
                // On failure the row stays dirty and is written next tick.
                self.store.update(&r.job) catch {
                    log.err("job {d}: store update failed", .{r.job.id});
                    continue;
                };
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
            v.* = .{ .job = j, .awaiting_prompt = if (r.pending_match) |pm| try a.dupe(u8, pm.prompt) else null };
            totals.dl_speed += r.job.dl_speed;
            totals.ul_speed += r.job.ul_speed;
            switch (r.job.step) {
                .awaiting_user => totals.waiting_for_user += 1,
                .seeding => totals.seeding += 1,
                // Paused jobs do not move: they must not keep the UI
                // redrawing every frame.
                .done, .failed, .cancelled, .paused => {},
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
        if (r.resolve_worker) |rw| self.orphanResolve(rw);
        if (r.move_worker) |mw| self.orphanMove(mw);
        self.clearPending(r);
        for (r.rejected.items) |p| self.alloc.free(p);
        r.rejected.deinit(self.alloc);
        freeJobStrings(self.alloc, &r.job);
        if (r.torrent_bytes) |b| self.alloc.free(b);
        self.alloc.destroy(r);
    }
};

/// An F95 donor DDL job (signed URL + cookie from the UI).
fn isDonor(j: *const model.Job) bool {
    return std.mem.eql(u8, j.host, HOST_DONOR);
}

/// Forget the job's request headers (cookies) and when its link was
/// resolved, so a later Retry resolves again instead of reusing a link
/// without its headers.
fn dropSecrets(a: std.mem.Allocator, j: *model.Job) void {
    freeList(a, j.resolved_headers);
    j.resolved_headers = &.{};
    j.resolved_at = null;
}

/// True when the job's link must go through the resolver: every catalogue
/// job (its host is a `dl_classify.Host` label), and a pasted (`HOST_RAW`)
/// link that points at a known file host or is an F95 masked link. Donor,
/// recipe (ddl/mirror) and torrent jobs are direct. Derived from stored
/// fields so it holds after a restart.
fn needsResolve(j: *const model.Job) bool {
    if (std.mem.eql(u8, j.host, HOST_RAW)) {
        const p = dl_classify.parseHref(j.source_href);
        return p.wrapper == .masked or p.host.isFileHost();
    }
    for (std.enums.values(dl_classify.Host)) |h| {
        if (std.mem.eql(u8, j.host, h.label())) return true;
    }
    return false;
}

/// What the browser opens: the resolver's link when there is one, else
/// what the user clicked.
fn browserUrl(j: *const model.Job) []const u8 {
    return j.resolved_url orelse j.source_href;
}

/// The last path segment of `href` when it looks like a file name (has a
/// '.', no query string); else null. Used for watched-folder name matches.
fn expectedName(href: []const u8) ?[]const u8 {
    if (std.mem.indexOfAny(u8, href, "?#") != null) return null;
    const slash = std.mem.lastIndexOfScalar(u8, href, '/') orelse return null;
    const name = href[slash + 1 ..];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '.') == null) return null;
    return name;
}

/// "512 B", "1.5 KB", "700.0 MB", "2.3 GB".
fn humanSize(buf: []u8, n: u64) []const u8 {
    if (n < 1024) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    var v: f64 = @as(f64, @floatFromInt(n)) / 1024.0;
    var i: usize = 0;
    while (v >= 1024.0 and i < units.len - 1) : (i += 1) v /= 1024.0;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[i] }) catch "?";
}

/// "Win", "Linux", "Mac", "Android" for the set flags joined by "/";
/// null when none is set.
fn platformLabel(buf: []u8, p: dl_classify.Platform) ?[]const u8 {
    var n: usize = 0;
    const names = [_]struct { on: bool, name: []const u8 }{
        .{ .on = p.windows, .name = "Win" },
        .{ .on = p.linux, .name = "Linux" },
        .{ .on = p.mac, .name = "Mac" },
        .{ .on = p.android, .name = "Android" },
    };
    for (names) |it| {
        if (!it.on) continue;
        const sep_len: usize = if (n > 0) 1 else 0;
        if (n + sep_len + it.name.len > buf.len) break;
        if (sep_len == 1) buf[n] = '/';
        n += sep_len;
        @memcpy(buf[n..][0..it.name.len], it.name);
        n += it.name.len;
    }
    return if (n == 0) null else buf[0..n];
}

/// `<game> · Part N`, else `<game> · <platform>`, else `<game>`. A title
/// too long for `buf` keeps just the game name.
fn catalogueTitle(buf: []u8, game: []const u8, part: ?u8, plat: ?[]const u8) []const u8 {
    if (part) |n| return std.fmt.bufPrint(buf, "{s} · Part {d}", .{ game, n }) catch game;
    if (plat) |p| return std.fmt.bufPrint(buf, "{s} · {s}", .{ game, p }) catch game;
    return game;
}

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

fn freeList(a: std.mem.Allocator, list: []const []const u8) void {
    if (list.len == 0) return;
    for (list) |s| freeStr(a, s);
    a.free(list);
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
    c.extract_dir = null;
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
    c.extract_dir = try dupeOpt(a, j.extract_dir);
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
    if (j.extract_dir) |s| freeStr(a, s);
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
            if (e.version) |v| e.version = try a.dupe(u8, v);
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
const engine_browser = @import("engine_browser.zig");

const Fx = struct {
    env: test_env.TestEnv,
    fake: engine_mod.FakeEngine,
    browser: engine_browser.BrowserEngine,
    dl: Downloader,
    dl_root: []u8,
    lib_root: []u8,
    data_root: []u8,

    fn create(settings: policy.Settings) !*Fx {
        return createWith(settings, null);
    }

    fn createWith(settings: policy.Settings, resolver: ?ResolverCtx) !*Fx {
        return createFull(settings, resolver, false);
    }

    /// With a `BrowserEngine` wired in (stage 3).
    fn createBrowser(settings: policy.Settings, resolver: ?ResolverCtx) !*Fx {
        return createFull(settings, resolver, true);
    }

    fn createFull(settings: policy.Settings, resolver: ?ResolverCtx, with_browser: bool) !*Fx {
        const a = testing.allocator;
        const fx = try a.create(Fx);
        errdefer a.destroy(fx);
        fx.env = try test_env.TestEnv.init(a, "downloader");
        fx.fake = .{ .alloc = a, .script = &.{} };
        fx.browser = .{ .alloc = a, .io = fx.env.io };
        fx.dl_root = try fx.env.path("dl");
        fx.lib_root = try fx.env.path("lib");
        fx.data_root = try fx.env.path("data");
        fx.dl = Downloader.init(
            a,
            fx.env.io,
            try store_mod.Store.openMemory(a),
            .{ .aria2 = fx.fake.engine(), .browser = if (with_browser) fx.browser.engine() else null },
            .{ .downloads_root = fx.dl_root, .library_root = fx.lib_root, .data_root = fx.data_root },
            settings,
            resolver,
        );
        return fx;
    }

    fn destroy(fx: *Fx) void {
        const a = testing.allocator;
        _ = fx.dl.deinit();
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
    try testing.expectEqualStrings(megacmd.installHint(), got.step_detail);
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

test "downloader: extract marker — our interrupted folder is cleared and re-extracted; the job's own finished folder is registered" {
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
    // Its own extract finished before the quit (folder recorded, no marker).
    const own = try std.fmt.allocPrint(testing.allocator, "{s}" ++ sep ++ "9" ++ sep ++ "v2" ++ sep, .{fx.lib_root});
    defer testing.allocator.free(own);
    b.extract_dir = own;
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

test "downloader: a paused job is not counted as active in the snapshot totals" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    const script = [_]model.Progress{.{ .phase = .downloading, .bytes_done = 1, .bytes_total = 5 }};
    fx.fake.script = &script;
    fx.enqueue("https://example.invalid/a.bin");
    fx.dl.stepOnce(1000);
    {
        const snap = fx.dl.snapshot();
        defer fx.dl.releaseSnapshot();
        try testing.expectEqual(@as(u32, 1), snap.totals.active);
    }
    fx.dl.send(.{ .pause = fx.dl.recs.items[0].job.id });
    fx.dl.stepOnce(1001);
    try testing.expectEqual(model.Step.paused, fx.dl.recs.items[0].job.step);
    const snap = fx.dl.snapshot();
    defer fx.dl.releaseSnapshot();
    try testing.expectEqual(@as(u32, 0), snap.totals.active);
}

// ---------------------------------------------------------------- resolver tests

/// Canned `resolve.Http` (same idea as resolve.zig's test stub). Called on
/// the resolve worker thread, so the hit counter is atomic.
const ResolveStub = struct {
    const Route = struct { prefix: []const u8, status: u16 = 200, body: []const u8 };
    routes: []const Route,
    cookie: ?[]const u8 = null,
    hits: std.atomic.Value(u32) = .init(0),
    /// While true, every call waits (to catch a job mid-resolve).
    hold: std.atomic.Value(bool) = .init(false),
    /// Each call first sleeps this long (a slow host).
    sleep_ms: i64 = 0,

    fn ctx(self: *ResolveStub) ResolverCtx {
        return .{ .http = .{ .ctx = self, .get = get, .postForm = post, .cookieHeader = cookieHeader } };
    }
    fn cast(p: *anyopaque) *ResolveStub {
        return @ptrCast(@alignCast(p));
    }
    fn find(self: *ResolveStub, url: []const u8) ?Route {
        for (self.routes) |r| if (std.mem.startsWith(u8, url, r.prefix)) return r;
        return null;
    }
    fn get(p: *anyopaque, alloc: std.mem.Allocator, url: []const u8) errs.Error![]u8 {
        const self = cast(p);
        _ = self.hits.fetchAdd(1, .monotonic);
        if (self.sleep_ms > 0) testing.io.sleep(std.Io.Duration.fromMilliseconds(self.sleep_ms), .real) catch {};
        while (self.hold.load(.acquire)) std.Thread.yield() catch {};
        const r = self.find(url) orelse return errs.Error.NotFound;
        return alloc.dupe(u8, r.body) catch errs.Error.OutOfMemory;
    }
    fn post(p: *anyopaque, alloc: std.mem.Allocator, url: []const u8, _: []const u8, _: []const []const u8) errs.Error!resolve.Http.Reply {
        const self = cast(p);
        _ = self.hits.fetchAdd(1, .monotonic);
        while (self.hold.load(.acquire)) std.Thread.yield() catch {};
        const r = self.find(url) orelse return errs.Error.NotFound;
        return .{ .status = r.status, .body = alloc.dupe(u8, r.body) catch return errs.Error.OutOfMemory };
    }
    fn cookieHeader(p: *anyopaque) ?[]const u8 {
        return cast(p).cookie;
    }
};

const PD_INFO: ResolveStub.Route = .{ .prefix = "https://pixeldrain.com/api/file/abc/info", .body = "{\"name\":\"Game.zip\",\"size\":12345}" };

/// Tick until no job has a resolve worker (the stub answers at once; the
/// worker is still a real thread). Gives up after 5 s.
fn settle(fx: *Fx, now: i64) !void {
    fx.dl.stepOnce(now);
    var waited_ms: u32 = 0;
    while (blk: {
        for (fx.dl.recs.items) |r| if (r.resolve_worker != null) break :blk true;
        break :blk false;
    }) {
        if (waited_ms >= 5000) return error.ResolveWorkerTimeout;
        fx.env.io.sleep(std.Io.Duration.fromMilliseconds(5), .real) catch {};
        waited_ms += 5;
        fx.dl.stepOnce(now);
    }
}

/// `download_sources` belongs to the library schema; the in-memory store
/// only has the dl tables, so the test creates it.
fn seedCatalogue(fx: *Fx, tid: u64, ord: i64, href: []const u8, text: []const u8, lead: []const u8) !void {
    try fx.dl.store.conn.exec(
        \\CREATE TABLE IF NOT EXISTS download_sources (
        \\  game_thread_id INTEGER NOT NULL, ord INTEGER NOT NULL, href TEXT NOT NULL,
        \\  text TEXT NOT NULL DEFAULT '', lead TEXT NOT NULL DEFAULT '', ctx TEXT NOT NULL DEFAULT '',
        \\  PRIMARY KEY (game_thread_id, ord))
    );
    try fx.dl.store.conn.inner.exec(
        "INSERT INTO download_sources(game_thread_id, ord, href, text, lead, ctx) VALUES (?, ?, ?, ?, ?, ?)",
        .{ @as(i64, @intCast(tid)), ord, href, text, lead, "" },
    );
}

fn enqueueRaw(fx: *Fx, url: []const u8, host: []const u8) void {
    fx.dl.send(.{ .enqueue_url = .{ .url = url, .kind = .game, .game_thread_id = 77, .title = "Game", .host = host } });
}

fn countEvents(evs: []const UiEvent, tag: std.meta.Tag(UiEvent)) usize {
    var n: usize = 0;
    for (evs) |e| {
        if (e == tag) n += 1;
    }
    return n;
}

test "downloader: enqueue_catalogue twice → one job + toast" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try seedCatalogue(fx, 9, 0, "https://pixeldrain.com/u/abc", "Pixeldrain", "Win");
    try seedCatalogue(fx, 9, 1, "https://pixeldrain.com/u/def", "Pixeldrain", "Part 2");

    fx.dl.send(.{ .enqueue_catalogue = .{ .game_thread_id = 9, .href = "https://pixeldrain.com/u/abc", .title = "My Game" } });
    fx.dl.stepOnce(1000);
    fx.dl.send(.{ .enqueue_catalogue = .{ .game_thread_id = 9, .href = "https://pixeldrain.com/u/abc", .title = "My Game" } });
    fx.dl.send(.{ .enqueue_catalogue = .{ .game_thread_id = 9, .href = "https://pixeldrain.com/u/def", .title = "My Game", .group_with = 1 } });
    fx.dl.stepOnce(1001);

    try testing.expectEqual(@as(usize, 2), fx.dl.recs.items.len);
    const j = fx.dl.recs.items[0].job;
    try testing.expectEqualStrings("My Game · Win", j.title);
    try testing.expectEqualStrings("Win", j.platform.?);
    try testing.expectEqualStrings("Pixeldrain", j.host);
    try testing.expectEqual(model.Kind.game, j.kind);
    try testing.expectEqual(model.EngineKind.aria2_http, j.engine);
    try testing.expectEqual(j.id, j.group_id);
    const p2 = fx.dl.recs.items[1].job;
    try testing.expectEqualStrings("My Game · Part 2", p2.title);
    try testing.expectEqual(@as(?u8, 2), p2.part);
    try testing.expectEqual(j.id, p2.group_id);

    const evs = fx.dl.drainEvents(testing.allocator);
    defer Downloader.freeEvents(testing.allocator, evs);
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqualStrings("Already queued", evs[0].toast);

    const logged = try fx.dl.store.listEvents(testing.allocator, j.id);
    defer store_mod.Store.freeEvents(testing.allocator, logged);
    try testing.expectEqualStrings("enqueued from thread", logged[0].msg);
}

test "downloader: enqueue_catalogue for an href not in the catalogue → toast, no job" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try seedCatalogue(fx, 9, 0, "https://pixeldrain.com/u/abc", "Pixeldrain", "");
    fx.dl.send(.{ .enqueue_catalogue = .{ .game_thread_id = 9, .href = "https://pixeldrain.com/u/zzz", .title = "G" } });
    fx.dl.send(.{ .enqueue_catalogue = .{ .game_thread_id = 10, .href = "https://pixeldrain.com/u/abc", .title = "G" } });
    fx.dl.stepOnce(1000);
    try testing.expectEqual(@as(usize, 0), fx.dl.recs.items.len);
    const evs = fx.dl.drainEvents(testing.allocator);
    defer Downloader.freeEvents(testing.allocator, evs);
    try testing.expectEqual(@as(usize, 2), evs.len);
    for (evs) |e| try testing.expectEqualStrings("Link not in the catalogue — sync the game first", e.toast);
}

test "downloader: catalogue job resolves through the stub and starts the engine" {
    var stub: ResolveStub = .{ .routes = &.{PD_INFO} };
    var fx = try Fx.createWith(.{}, stub.ctx());
    defer fx.destroy();
    try seedCatalogue(fx, 9, 0, "https://pixeldrain.com/u/abc", "Pixeldrain", "");
    fx.dl.send(.{ .enqueue_catalogue = .{ .game_thread_id = 9, .href = "https://pixeldrain.com/u/abc", .title = "G" } });
    try settle(fx, 1000);

    const j = fx.dl.recs.items[0].job;
    try testing.expectEqual(model.Step.downloading, j.step);
    try testing.expectEqual(@as(usize, 1), fx.fake.started);
    try testing.expectEqualStrings("Pixeldrain", j.host);
    try testing.expect(std.mem.endsWith(u8, j.resolved_url.?, "?download"));
    try testing.expectEqual(@as(?i64, 1000), j.resolved_at);
    try testing.expectEqual(@as(u32, 1), stub.hits.load(.monotonic));

    const rows = try fx.dl.store.loadAll(testing.allocator);
    defer store_mod.Store.freeJobs(testing.allocator, rows);
    try testing.expectEqualStrings(j.resolved_url.?, rows[0].resolved_url.?);
}

test "downloader: needs_browser without a browser engine → failed with the stage-2 message" {
    var stub: ResolveStub = .{ .routes = &.{} };
    var fx = try Fx.createWith(.{}, stub.ctx());
    defer fx.destroy();
    try seedCatalogue(fx, 9, 0, "https://workupload.com/file/xyz", "Workupload", "");
    fx.dl.send(.{ .enqueue_catalogue = .{ .game_thread_id = 9, .href = "https://workupload.com/file/xyz", .title = "G" } });
    try settle(fx, 1000);

    const j = fx.dl.recs.items[0].job;
    try testing.expectEqual(model.Step.failed, j.step);
    try testing.expectEqual(model.FailReason.unknown, j.fail.?);
    try testing.expectEqualStrings(BROWSER_STAGE2, j.step_detail);
    try testing.expectEqual(@as(?i64, null), j.next_retry_at);
    try testing.expectEqual(@as(usize, 0), fx.fake.started);
    const evs = fx.dl.drainEvents(testing.allocator);
    defer Downloader.freeEvents(testing.allocator, evs);
    try testing.expectEqual(@as(usize, 0), countEvents(evs, .open_url));
}

test "downloader: auth_required → failed{auth_required} + sign_in_needed event, no auto-retry" {
    var stub: ResolveStub = .{ .routes = &.{.{ .prefix = "https://f95zone.to/masked/", .status = 403, .body = "no" }} };
    var fx = try Fx.createWith(.{}, stub.ctx());
    defer fx.destroy();
    enqueueRaw(fx, "https://f95zone.to/masked/pixeldrain.com/abc/x", HOST_RAW);
    try settle(fx, 1000);

    const id = fx.dl.recs.items[0].job.id;
    try testing.expectEqual(model.Step.failed, fx.rec(id).job.step);
    try testing.expectEqual(model.FailReason.auth_required, fx.rec(id).job.fail.?);
    try testing.expectEqual(@as(?i64, null), fx.rec(id).job.next_retry_at);
    {
        const evs = fx.dl.drainEvents(testing.allocator);
        defer Downloader.freeEvents(testing.allocator, evs);
        try testing.expectEqual(@as(usize, 1), countEvents(evs, .sign_in_needed));
    }

    // No automatic retry, however long we wait.
    fx.dl.stepOnce(1000 + 10_000);
    try testing.expectEqual(model.Step.failed, fx.rec(id).job.step);
    try testing.expectEqual(@as(u32, 1), stub.hits.load(.monotonic));

    // A second job failing within 60 s does not prompt again.
    enqueueRaw(fx, "https://f95zone.to/masked/pixeldrain.com/def/y", HOST_RAW);
    try settle(fx, 1000 + 10_000 + 30);
    try testing.expectEqual(model.FailReason.auth_required, fx.dl.recs.items[1].job.fail.?);
    enqueueRaw(fx, "https://f95zone.to/masked/pixeldrain.com/ghi/z", HOST_RAW);
    try settle(fx, 1000 + 10_000 + 30);
    const evs = fx.dl.drainEvents(testing.allocator);
    defer Downloader.freeEvents(testing.allocator, evs);
    try testing.expectEqual(@as(usize, 1), countEvents(evs, .sign_in_needed));
}

test "downloader: re-resolve only when resolved_at older than 1 h on retry" {
    var stub: ResolveStub = .{ .routes = &.{PD_INFO} };
    var fx = try Fx.createWith(.{}, stub.ctx());
    defer fx.destroy();
    enqueueRaw(fx, "https://pixeldrain.com/u/abc", HOST_RAW);
    try settle(fx, 1000);
    const r = fx.dl.recs.items[0];
    try testing.expectEqual(model.Step.downloading, r.job.step);
    try testing.expectEqual(@as(u32, 1), stub.hits.load(.monotonic));

    // Fresh link (100 s old): the retry reuses it.
    r.job.step = .failed;
    r.job.fail = .unknown;
    r.job.resolved_at = 5000 - 100;
    fx.dl.send(.{ .retry = r.job.id });
    try settle(fx, 5000);
    try testing.expectEqual(model.Step.downloading, r.job.step);
    try testing.expectEqual(@as(u32, 1), stub.hits.load(.monotonic));
    try testing.expectEqual(@as(?i64, 5000 - 100), r.job.resolved_at);

    // Stale link (4000 s old): resolved again.
    r.job.step = .failed;
    r.job.fail = .unknown;
    r.job.resolved_at = 9000 - 4000;
    fx.dl.send(.{ .retry = r.job.id });
    try settle(fx, 9000);
    try testing.expectEqual(model.Step.downloading, r.job.step);
    try testing.expectEqual(@as(u32, 2), stub.hits.load(.monotonic));
    try testing.expectEqual(@as(?i64, 9000), r.job.resolved_at);
}

test "downloader: raw enqueue_url to a known host resolves; donor/raw plain URLs do not" {
    var stub: ResolveStub = .{ .routes = &.{PD_INFO} };
    var fx = try Fx.createWith(.{}, stub.ctx());
    defer fx.destroy();
    enqueueRaw(fx, "https://pixeldrain.com/u/abc", HOST_RAW);
    enqueueRaw(fx, "https://example.invalid/a.bin", HOST_RAW);
    enqueueRaw(fx, "https://pixeldrain.com/u/zzz", HOST_DONOR);
    try settle(fx, 1000);

    try testing.expectEqual(@as(u32, 1), stub.hits.load(.monotonic));
    for (fx.dl.recs.items) |r| try testing.expectEqual(model.Step.downloading, r.job.step);
    try testing.expect(std.mem.endsWith(u8, fx.dl.recs.items[0].job.resolved_url.?, "/api/file/abc?download"));
    try testing.expectEqual(@as(?[]const u8, null), fx.dl.recs.items[1].job.resolved_url);
    try testing.expectEqual(@as(?[]const u8, null), fx.dl.recs.items[2].job.resolved_url);
}

test "downloader: resolve worker errors fail as network with a retry; cancel/remove while resolving drop the result" {
    var stub: ResolveStub = .{ .routes = &.{} };
    var fx = try Fx.createWith(.{}, stub.ctx());
    defer fx.destroy();
    // Masked POST with no route → NotFound error from the stub.
    enqueueRaw(fx, "https://f95zone.to/masked/pixeldrain.com/abc/x", HOST_RAW);
    try settle(fx, 1000);
    const j = fx.dl.recs.items[0].job;
    try testing.expectEqual(model.Step.failed, j.step);
    try testing.expectEqual(model.FailReason.network, j.fail.?);
    try testing.expectEqual(@as(?i64, 1030), j.next_retry_at);

    enqueueRaw(fx, "https://f95zone.to/masked/pixeldrain.com/def/y", HOST_RAW);
    enqueueRaw(fx, "https://f95zone.to/masked/pixeldrain.com/ghi/z", HOST_RAW);
    stub.hold.store(true, .release);
    fx.dl.stepOnce(1001);
    const a = fx.dl.recs.items[1];
    const b_id = fx.dl.recs.items[2].job.id;
    try testing.expectEqual(model.Step.resolving, a.job.step);
    fx.dl.send(.{ .cancel = a.job.id });
    fx.dl.send(.{ .remove = b_id });
    fx.dl.stepOnce(1002);
    try testing.expectEqual(@as(usize, 1), fx.dl.resolve_orphans.items.len);
    stub.hold.store(false, .release);
    try settle(fx, 1003);
    try testing.expectEqual(model.Step.cancelled, a.job.step);
    try testing.expectEqual(@as(?*Rec, null), fx.dl.find(b_id));
}

// ---------------------------------------------------------------- browser flow tests

/// Queue a Workupload catalogue link (the resolver says needs-browser
/// without any HTTP) and settle it into `awaiting_user`. Returns the id.
fn awaitBrowser(fx: *Fx, ord: i64, href: []const u8) !u64 {
    try seedCatalogue(fx, 9, ord, href, "Workupload", "");
    fx.dl.send(.{ .enqueue_catalogue = .{ .game_thread_id = 9, .href = href, .title = "G" } });
    try settle(fx, 1000);
    for (fx.dl.recs.items) |r| {
        if (std.mem.eql(u8, r.job.source_href, href)) return r.job.id;
    }
    return error.JobNotFound;
}

/// Tick until no job has a move worker; gives up after 5 s.
fn waitMoves(fx: *Fx, now: i64) !void {
    fx.dl.stepOnce(now);
    var waited_ms: u32 = 0;
    while (blk: {
        for (fx.dl.recs.items) |r| if (r.move_worker != null) break :blk true;
        break :blk false;
    }) {
        if (waited_ms >= 5000) return error.MoveWorkerTimeout;
        fx.env.io.sleep(std.Io.Duration.fromMilliseconds(5), .real) catch {};
        waited_ms += 5;
        fx.dl.stepOnce(now);
    }
}

/// The snapshot prompt of job `id` (copied into `buf`), or null.
fn snapPrompt(fx: *Fx, id: u64, buf: []u8) ?[]const u8 {
    const snap = fx.dl.snapshot();
    defer fx.dl.releaseSnapshot();
    for (snap.jobs) |v| {
        if (v.job.id != id) continue;
        const p = v.awaiting_prompt orelse return null;
        @memcpy(buf[0..p.len], p);
        return buf[0..p.len];
    }
    return null;
}

fn fileExists(fx: *Fx, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(fx.env.io, path, .{}) catch return false;
    return true;
}

test "browser: needs_browser → awaiting_user + open_url event once; open_again raises again" {
    var stub: ResolveStub = .{ .routes = &.{} };
    var fx = try Fx.createBrowser(.{}, stub.ctx());
    defer fx.destroy();
    const href = "https://workupload.com/file/xyz";
    const id = try awaitBrowser(fx, 0, href);

    const j = fx.rec(id).job;
    try testing.expectEqual(model.Step.awaiting_user, j.step);
    try testing.expectEqual(model.EngineKind.browser, j.engine);
    var ref_buf: [32]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&ref_buf, "browser:{d}", .{id}), j.engine_ref.?);
    try testing.expectEqualStrings(WAITING_BROWSER, j.step_detail);
    try testing.expect(std.mem.indexOf(u8, j.dest_dir, "browser") != null);
    try testing.expectEqual(@as(i64, 1000), fx.rec(id).awaiting_since);
    try testing.expectEqual(@as(usize, 0), fx.fake.started);
    {
        const evs = fx.dl.drainEvents(testing.allocator);
        defer Downloader.freeEvents(testing.allocator, evs);
        try testing.expectEqual(@as(usize, 1), countEvents(evs, .open_url));
        for (evs) |e| if (e == .open_url) try testing.expectEqualStrings(href, e.open_url);
    }

    // Waiting holds no slot and raises nothing more on later ticks.
    fx.dl.stepOnce(1001);
    fx.dl.stepOnce(1005);
    {
        const evs = fx.dl.drainEvents(testing.allocator);
        defer Downloader.freeEvents(testing.allocator, evs);
        try testing.expectEqual(@as(usize, 0), countEvents(evs, .open_url));
    }
    try testing.expectEqual(@as(u32, 0), fx.dl.activeCounts().files_downloading);
    {
        const snap = fx.dl.snapshot();
        defer fx.dl.releaseSnapshot();
        try testing.expectEqual(@as(u32, 1), snap.totals.waiting_for_user);
    }

    fx.dl.send(.{ .open_again = id });
    fx.dl.stepOnce(1006);
    const evs = fx.dl.drainEvents(testing.allocator);
    defer Downloader.freeEvents(testing.allocator, evs);
    try testing.expectEqual(@as(usize, 1), countEvents(evs, .open_url));
    try testing.expectEqual(model.Step.awaiting_user, fx.rec(id).job.step);
}

test "browser: paste_link direct → aria2 engine started" {
    var stub: ResolveStub = .{ .routes = &.{} };
    var fx = try Fx.createBrowser(.{}, stub.ctx());
    defer fx.destroy();
    const id = try awaitBrowser(fx, 0, "https://workupload.com/file/xyz");

    fx.dl.send(.{ .paste_link = .{ .job_id = id, .url = "  https://cdn.example.invalid/Game.zip\n" } });
    fx.dl.stepOnce(1001);
    const j = fx.rec(id).job;
    try testing.expectEqual(@as(usize, 1), fx.fake.started);
    try testing.expectEqual(model.Step.downloading, j.step);
    try testing.expectEqual(model.EngineKind.aria2_http, j.engine);
    try testing.expectEqualStrings("https://cdn.example.invalid/Game.zip", j.resolved_url.?);
    try testing.expectEqual(@as(?i64, 1001), j.resolved_at);
    try testing.expect(std.mem.indexOf(u8, j.dest_dir, "aria2_http") != null);
    try testing.expectEqualStrings("fake-1", j.engine_ref.?);
}

test "browser: paste_link non-URL → toast and still awaiting" {
    var stub: ResolveStub = .{ .routes = &.{} };
    var fx = try Fx.createBrowser(.{}, stub.ctx());
    defer fx.destroy();
    const id = try awaitBrowser(fx, 0, "https://workupload.com/file/xyz");
    Downloader.freeEvents(testing.allocator, fx.dl.drainEvents(testing.allocator));

    fx.dl.send(.{ .paste_link = .{ .job_id = id, .url = "just some words" } });
    fx.dl.stepOnce(1001);
    try testing.expectEqual(model.Step.awaiting_user, fx.rec(id).job.step);
    try testing.expectEqual(@as(usize, 0), fx.fake.started);
    const evs = fx.dl.drainEvents(testing.allocator);
    defer Downloader.freeEvents(testing.allocator, evs);
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqualStrings("That is not a link", evs[0].toast);
}

test "browser: pick_file → verifying (file moved into dest_dir)" {
    var stub: ResolveStub = .{ .routes = &.{} };
    var fx = try Fx.createBrowser(.{}, stub.ctx());
    defer fx.destroy();
    const id = try awaitBrowser(fx, 0, "https://workupload.com/file/xyz");
    try fx.env.writeFile("picked/My Game.bin", "payload");
    const src = try fx.env.path("picked/My Game.bin");
    defer testing.allocator.free(src);

    fx.dl.send(.{ .pick_file = .{ .job_id = id, .path = src } });
    try waitMoves(fx, 1001);

    const j = fx.rec(id).job;
    try testing.expect(j.step != .awaiting_user and j.step != .failed);
    const fp = j.final_path.?;
    try testing.expect(std.mem.startsWith(u8, fp, j.dest_dir));
    try testing.expect(std.mem.endsWith(u8, fp, "My Game.bin"));
    try testing.expect(fileExists(fx, fp));
    try testing.expect(!fileExists(fx, src));
    try testing.expectEqual(@as(?[]const u8, null), j.engine_ref);

    const logged = try fx.dl.store.listEvents(testing.allocator, id);
    defer store_mod.Store.freeEvents(testing.allocator, logged);
    var saw_verifying = false;
    for (logged) |e| {
        if (e.step == .verifying) saw_verifying = true;
    }
    try testing.expect(saw_verifying);
}

test "browser: scanner name match adopts; only_one match sets prompt; accept=false keeps waiting and rejects the file; accept=true adopts" {
    var stub: ResolveStub = .{ .routes = &.{} };
    var fx = try Fx.createBrowser(.{}, stub.ctx());
    defer fx.destroy();
    try fx.env.mkdirP("watch");
    const wd = try fx.env.path("watch");
    defer testing.allocator.free(wd);
    fx.dl.send(.{ .reload_settings = .{ .watch_dir = wd } });
    fx.dl.stepOnce(900);

    const a = try awaitBrowser(fx, 0, "https://workupload.com/file/Game.bin");
    const b = try awaitBrowser(fx, 1, "https://workupload.com/file/xyz");
    try testing.expect(std.mem.indexOf(u8, fx.rec(b).job.step_detail, " · watching ") != null);
    try testing.expect(std.mem.endsWith(u8, fx.rec(b).job.step_detail, wd));

    // Name match: adopted at once, no prompt.
    try fx.env.writeFile("watch/Game.bin", "aaaa");
    fx.dl.stepOnce(1002); // first seen
    try waitMoves(fx, 1005); // stable for 3 s → matched → moved
    {
        const ja = fx.rec(a).job;
        try testing.expect(ja.step != .awaiting_user and ja.step != .failed);
        try testing.expect(std.mem.startsWith(u8, ja.final_path.?, ja.dest_dir));
        try testing.expect(std.mem.endsWith(u8, ja.final_path.?, "Game.bin"));
    }
    var pbuf: [128]u8 = undefined;
    try testing.expectEqual(model.Step.awaiting_user, fx.rec(b).job.step);
    try testing.expectEqual(@as(?[]const u8, null), snapPrompt(fx, b, &pbuf));

    // Only one job waits: an unknown file becomes a prompt.
    try fx.env.writeFile("watch/other.bin", "bbbbbb");
    fx.dl.stepOnce(1008);
    fx.dl.stepOnce(1011);
    try testing.expectEqualStrings("Found other.bin (6 B) — use it?", snapPrompt(fx, b, &pbuf).?);

    // No: the prompt goes away, the job keeps waiting, the file is not offered again.
    fx.dl.send(.{ .accept_match = .{ .job_id = b, .accept = false } });
    fx.dl.stepOnce(1012);
    try testing.expectEqual(@as(?[]const u8, null), snapPrompt(fx, b, &pbuf));
    try testing.expectEqual(@as(usize, 1), fx.rec(b).rejected.items.len);
    fx.dl.stepOnce(1014);
    fx.dl.stepOnce(1017);
    try testing.expectEqual(model.Step.awaiting_user, fx.rec(b).job.step);
    try testing.expectEqual(@as(?[]const u8, null), snapPrompt(fx, b, &pbuf));

    // Yes: the proposed file is adopted.
    try fx.env.writeFile("watch/third.bin", "cc");
    fx.dl.stepOnce(1020);
    fx.dl.stepOnce(1023);
    try testing.expectEqualStrings("Found third.bin (2 B) — use it?", snapPrompt(fx, b, &pbuf).?);
    fx.dl.send(.{ .accept_match = .{ .job_id = b, .accept = true } });
    try waitMoves(fx, 1024);
    const jb = fx.rec(b).job;
    try testing.expect(jb.step != .awaiting_user and jb.step != .failed);
    try testing.expect(std.mem.endsWith(u8, jb.final_path.?, "third.bin"));
    try testing.expectEqual(@as(?[]const u8, null), snapPrompt(fx, b, &pbuf));
    const other = try fx.env.path("watch/other.bin");
    defer testing.allocator.free(other);
    try testing.expect(fileExists(fx, other));
}

test "browser: reconcile keeps awaiting_user without re-opening" {
    var fx = try Fx.createBrowser(.{}, null);
    defer fx.destroy();
    var j = storedJob(.awaiting_user);
    j.engine = .browser;
    j.engine_ref = "browser:1";
    j.step_detail = WAITING_BROWSER;
    const id = try fx.dl.store.insert(&j);

    try fx.dl.load();
    fx.dl.reconcile();
    try testing.expectEqual(model.Step.awaiting_user, fx.rec(id).job.step);
    try testing.expect(fx.rec(id).awaiting_since > 1000);
    const evs = fx.dl.drainEvents(testing.allocator);
    defer Downloader.freeEvents(testing.allocator, evs);
    try testing.expectEqual(@as(usize, 0), evs.len);

    fx.dl.stepOnce(2000);
    try testing.expectEqual(model.Step.awaiting_user, fx.rec(id).job.step);
}

test "browser: expectedName and humanSize" {
    try testing.expectEqualStrings("Game.zip", expectedName("https://x.invalid/a/Game.zip").?);
    try testing.expectEqual(@as(?[]const u8, null), expectedName("https://x.invalid/file/xyz"));
    try testing.expectEqual(@as(?[]const u8, null), expectedName("https://x.invalid/a.zip?dl=1"));
    try testing.expectEqual(@as(?[]const u8, null), expectedName("https://x.invalid/"));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("512 B", humanSize(&buf, 512));
    try testing.expectEqualStrings("1.5 KB", humanSize(&buf, 1536));
    try testing.expectEqualStrings("2.0 GB", humanSize(&buf, 2 * 1024 * 1024 * 1024));
}

test "browser: paste_link to a file-host page goes through the resolver" {
    var stub: ResolveStub = .{ .routes = &.{PD_INFO} };
    var fx = try Fx.createBrowser(.{}, stub.ctx());
    defer fx.destroy();
    const id = try awaitBrowser(fx, 0, "https://workupload.com/file/xyz");

    stub.hold.store(true, .release);
    fx.dl.send(.{ .paste_link = .{ .job_id = id, .url = "https://pixeldrain.com/u/abc" } });
    fx.dl.stepOnce(1001);
    try testing.expectEqual(model.Step.resolving, fx.rec(id).job.step);
    try testing.expectEqual(@as(usize, 0), fx.fake.started);
    stub.hold.store(false, .release);
    try settle(fx, 1002);

    const j = fx.rec(id).job;
    try testing.expectEqual(model.Step.downloading, j.step);
    try testing.expectEqual(model.EngineKind.aria2_http, j.engine);
    try testing.expect(std.mem.endsWith(u8, j.resolved_url.?, "?download"));
    try testing.expectEqual(@as(usize, 1), fx.fake.started);
}

test "browser: only_one counts every waiting job — a second job is not offered a stray file while the first is prompted" {
    var stub: ResolveStub = .{ .routes = &.{} };
    var fx = try Fx.createBrowser(.{}, stub.ctx());
    defer fx.destroy();
    try fx.env.mkdirP("watch");
    const wd = try fx.env.path("watch");
    defer testing.allocator.free(wd);
    fx.dl.send(.{ .reload_settings = .{ .watch_dir = wd } });
    fx.dl.stepOnce(900);

    const a = try awaitBrowser(fx, 0, "https://workupload.com/file/xyz");
    try fx.env.writeFile("watch/one.bin", "1");
    fx.dl.stepOnce(1002);
    fx.dl.stepOnce(1005);
    var pbuf: [128]u8 = undefined;
    try testing.expectEqualStrings("Found one.bin (1 B) — use it?", snapPrompt(fx, a, &pbuf).?);

    const b = try awaitBrowser(fx, 1, "https://workupload.com/file/abc");
    try fx.env.writeFile("watch/two.bin", "22");
    fx.dl.stepOnce(1008);
    fx.dl.stepOnce(1011);
    fx.dl.stepOnce(1014);
    try testing.expectEqual(@as(?[]const u8, null), snapPrompt(fx, b, &pbuf));
    try testing.expectEqualStrings("Found one.bin (1 B) — use it?", snapPrompt(fx, a, &pbuf).?);
}

test "browser: accepting a file that is gone → toast, prompt cleared, still waiting" {
    var stub: ResolveStub = .{ .routes = &.{} };
    var fx = try Fx.createBrowser(.{}, stub.ctx());
    defer fx.destroy();
    try fx.env.mkdirP("watch");
    const wd = try fx.env.path("watch");
    defer testing.allocator.free(wd);
    fx.dl.send(.{ .reload_settings = .{ .watch_dir = wd } });
    fx.dl.stepOnce(900);

    const id = try awaitBrowser(fx, 0, "https://workupload.com/file/xyz");
    Downloader.freeEvents(testing.allocator, fx.dl.drainEvents(testing.allocator));
    try fx.env.writeFile("watch/gone.bin", "x");
    fx.dl.stepOnce(1002);
    fx.dl.stepOnce(1005);
    var pbuf: [128]u8 = undefined;
    try testing.expect(snapPrompt(fx, id, &pbuf) != null);

    const gone = try fx.env.path("watch/gone.bin");
    defer testing.allocator.free(gone);
    try std.Io.Dir.cwd().deleteFile(fx.env.io, gone);
    fx.dl.send(.{ .accept_match = .{ .job_id = id, .accept = true } });
    try waitMoves(fx, 1006);

    try testing.expectEqual(model.Step.awaiting_user, fx.rec(id).job.step);
    try testing.expectEqual(@as(?[]const u8, null), snapPrompt(fx, id, &pbuf));
    const evs = fx.dl.drainEvents(testing.allocator);
    defer Downloader.freeEvents(testing.allocator, evs);
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqualStrings("That file is gone — still waiting", evs[0].toast);
}

// ---------------------------------------------------------------- final-review fixes

/// Tick until no job has a verify/extract worker; gives up after 5 s.
fn waitWorkers(fx: *Fx, now: i64) !void {
    fx.dl.stepOnce(now);
    var waited_ms: u32 = 0;
    while (blk: {
        for (fx.dl.recs.items) |r| if (r.worker != null or r.extract_wait != null) break :blk true;
        break :blk false;
    }) {
        if (waited_ms >= 5000) return error.WorkerTimeout;
        fx.env.io.sleep(std.Io.Duration.fromMilliseconds(5), .real) catch {};
        waited_ms += 5;
        fx.dl.stepOnce(now);
    }
}

fn countInstallReady(fx: *Fx) usize {
    const evs = fx.dl.drainEvents(testing.allocator);
    defer Downloader.freeEvents(testing.allocator, evs);
    return countEvents(evs, .install_ready);
}

test "downloader: catalogue jobs of one game get versioned, per-platform extract folders (version sent with the command)" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try fx.env.writeFile("payload/g.zip", "not really a zip");
    const zip = try fx.env.path("payload/g.zip");
    defer testing.allocator.free(zip);
    const script = [_]model.Progress{.{ .phase = .transfer_done, .final_path = zip }};
    fx.fake.script = &script;
    try seedCatalogue(fx, 9, 0, "https://pixeldrain.com/u/abc", "Pixeldrain", "Win");
    try seedCatalogue(fx, 9, 1, "https://pixeldrain.com/u/def", "Pixeldrain", "Linux");
    fx.dl.send(.{ .enqueue_catalogue = .{ .game_thread_id = 9, .href = "https://pixeldrain.com/u/abc", .title = "G", .version = "v1" } });
    fx.dl.send(.{ .enqueue_catalogue = .{ .game_thread_id = 9, .href = "https://pixeldrain.com/u/def", .title = "G", .version = "v2/beta" } });
    fx.dl.stepOnce(1000);

    const a = fx.dl.recs.items[0];
    const b = fx.dl.recs.items[1];
    try testing.expectEqualStrings("v1", a.job.version.?);
    // The extract started (it may already have failed on the fake zip).
    const want_a = try std.fmt.allocPrint(testing.allocator, "{s}" ++ sep ++ "9" ++ sep ++ "v1 (Win)" ++ sep, .{fx.lib_root});
    defer testing.allocator.free(want_a);
    const want_b = try std.fmt.allocPrint(testing.allocator, "{s}" ++ sep ++ "9" ++ sep ++ "v2_beta (Linux)" ++ sep, .{fx.lib_root});
    defer testing.allocator.free(want_b);
    try testing.expectEqualStrings(want_a, a.job.extract_dir.?);
    try testing.expectEqualStrings(want_b, b.job.extract_dir.?);
    // Stored at once, before the extract ends.
    {
        const rows = try fx.dl.store.loadAll(testing.allocator);
        defer store_mod.Store.freeJobs(testing.allocator, rows);
        try testing.expectEqualStrings(want_a, rows[0].extract_dir.?);
    }
    try waitWorkers(fx, 1001);
}

test "downloader: two extracts into the same folder at once → the second waits, then runs" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try fx.env.writeFile("payload/g.zip", "not really a zip");
    const zip = try fx.env.path("payload/g.zip");
    defer testing.allocator.free(zip);
    // Two jobs of one game and version, both verified (e.g. two mirrors).
    var j = storedJob(.extracting);
    j.game_thread_id = 9;
    j.version = "v1";
    j.final_path = zip;
    const id_a = try fx.dl.store.insert(&j);
    const id_b = try fx.dl.store.insert(&j);
    try fx.dl.load();
    const a = fx.rec(id_a);
    const b = fx.rec(id_b);
    // Start both before any worker result is read (as one tick would).
    fx.dl.startExtract(a, 1000, .fresh);
    fx.dl.startExtract(b, 1000, .fresh);
    try testing.expect(a.worker != null);
    try testing.expectEqual(model.Step.extracting, b.job.step);
    try testing.expect(b.worker == null);
    try testing.expectEqual(@as(?ExtractMode, .fresh), b.extract_wait);
    try testing.expectEqualStrings(EXTRACT_WAIT, b.job.step_detail);
    try testing.expectEqualStrings(a.job.extract_dir.?, a.worker.?.dest);

    try waitWorkers(fx, 1001);
    // Both extracts ran (and failed on the fake zip); neither still waits.
    try testing.expectEqual(model.Step.failed, a.job.step);
    try testing.expectEqual(model.Step.failed, b.job.step);
    try testing.expectEqual(model.FailReason.bad_archive, b.job.fail.?);
    try testing.expect(b.extract_wait == null);
    try testing.expect(b.job.extract_dir != null);
}

test "downloader: a fresh download never registers someone else's folder — it extracts into '<dir> (2)'" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try fx.env.writeFile("payload/g.zip", "not really a zip");
    const zip = try fx.env.path("payload/g.zip");
    defer testing.allocator.free(zip);
    try fx.env.writeFile("lib/77/unversioned/user.txt", "mine");
    const script = [_]model.Progress{.{ .phase = .transfer_done, .final_path = zip }};
    fx.fake.script = &script;
    fx.enqueue("https://example.invalid/g.zip");
    fx.dl.stepOnce(1000);
    const r = fx.dl.recs.items[0];
    try testing.expect(std.mem.endsWith(u8, r.job.extract_dir.?, "77" ++ sep ++ "unversioned (2)" ++ sep));
    try testing.expect(!std.mem.eql(u8, r.job.step_detail, FOLDER_EXISTS));
    try waitWorkers(fx, 1001);
    const user = try fx.env.path("lib/77/unversioned/user.txt");
    defer testing.allocator.free(user);
    try testing.expect(fileExists(fx, user));
}

test "downloader: retry_install still registers the folder on disk" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try fx.env.writeFile("payload/g.zip", "not really a zip");
    const zip = try fx.env.path("payload/g.zip");
    defer testing.allocator.free(zip);
    try fx.env.writeFile("lib/9/v3/game.exe", "x");
    var d = storedJob(.done);
    d.game_thread_id = 9;
    d.version = "v3";
    d.final_path = zip;
    const id = try fx.dl.store.insert(&d);
    try fx.dl.load();
    fx.dl.send(.{ .retry_install = id });
    fx.dl.stepOnce(1000);
    try testing.expectEqual(model.Step.installing, fx.rec(id).job.step);
    try testing.expectEqualStrings(FOLDER_EXISTS, fx.rec(id).job.step_detail);
    const want = try std.fmt.allocPrint(testing.allocator, "{s}" ++ sep ++ "9" ++ sep ++ "v3" ++ sep, .{fx.lib_root});
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, fx.rec(id).job.extract_dir.?);
    const evs = fx.dl.drainEvents(testing.allocator);
    defer Downloader.freeEvents(testing.allocator, evs);
    try testing.expectEqual(@as(usize, 1), evs.len);
    try testing.expectEqualStrings(want, evs[0].install_ready.extracted_dir.?);
}

test "downloader: a pasted URL with no game (game_thread_id 0) just downloads — done, no extract, no install" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try fx.env.writeFile("payload/g.zip", "not really a zip");
    const zip = try fx.env.path("payload/g.zip");
    defer testing.allocator.free(zip);
    const script = [_]model.Progress{.{ .phase = .transfer_done, .final_path = zip }};
    fx.fake.script = &script;
    fx.dl.send(.{ .enqueue_url = .{ .url = "https://example.invalid/g.zip", .kind = .game, .game_thread_id = 0, .title = "g.zip", .host = HOST_RAW } });
    fx.dl.stepOnce(1000);
    const r = fx.dl.recs.items[0];
    try testing.expectEqual(model.Step.done, r.job.step);
    try testing.expect(r.worker == null);
    try testing.expect(r.job.extract_dir == null);
    try testing.expect(std.mem.startsWith(u8, r.job.step_detail, "Downloaded to "));
    try testing.expect(std.mem.endsWith(u8, r.job.step_detail, r.job.dest_dir));
    try testing.expectEqual(@as(usize, 0), countInstallReady(fx));
    // "Install again" has nothing to install.
    fx.dl.send(.{ .retry_install = r.job.id });
    fx.dl.stepOnce(1001);
    try testing.expectEqual(model.Step.done, r.job.step);
    try testing.expectEqual(@as(usize, 0), countInstallReady(fx));
}

test "downloader: parts of a multi-part set are downloaded and verified only" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try fx.env.writeFile("payload/g.zip", "not really a zip");
    const zip = try fx.env.path("payload/g.zip");
    defer testing.allocator.free(zip);
    const script = [_]model.Progress{.{ .phase = .transfer_done, .final_path = zip }};
    fx.fake.script = &script;
    try seedCatalogue(fx, 9, 0, "https://pixeldrain.com/u/p1", "Pixeldrain", "Part 1");
    try seedCatalogue(fx, 9, 1, "https://pixeldrain.com/u/p2", "Pixeldrain", "Part 2");
    fx.dl.send(.{ .enqueue_catalogue = .{ .game_thread_id = 9, .href = "https://pixeldrain.com/u/p1", .title = "G", .version = "v1" } });
    fx.dl.send(.{ .enqueue_catalogue = .{ .game_thread_id = 9, .href = "https://pixeldrain.com/u/p2", .title = "G", .version = "v1", .group_with = 1 } });
    fx.dl.stepOnce(1000);
    const p1 = fx.dl.recs.items[0];
    const p2 = fx.dl.recs.items[1];
    try testing.expectEqual(p1.job.id, p2.job.group_id);
    try testing.expectEqual(model.Step.done, p1.job.step);
    try testing.expectEqual(model.Step.done, p2.job.step);
    try testing.expectEqualStrings("Downloaded part 1 — extract part 1 by hand once all parts are here", p1.job.step_detail);
    try testing.expectEqualStrings("Downloaded part 2 — extract part 1 by hand once all parts are here", p2.job.step_detail);
    try testing.expect(p1.worker == null and p2.worker == null);
    try testing.expectEqual(@as(usize, 0), countInstallReady(fx));
}

test "downloader: extras, update-only patches and mods without a mod id are downloaded only; a mod-manager mod still installs" {
    var fx = try Fx.create(.{ .slots_files = 8 });
    defer fx.destroy();
    try fx.env.writeFile("payload/g.zip", "not really a zip");
    const zip = try fx.env.path("payload/g.zip");
    defer testing.allocator.free(zip);
    const script = [_]model.Progress{.{ .phase = .transfer_done, .final_path = zip }};
    fx.fake.script = &script;
    try seedCatalogue(fx, 9, 0, "https://pixeldrain.com/u/upd", "Pixeldrain", "Update only (v1 to v2)");
    fx.dl.send(.{ .enqueue_url = .{ .url = "https://example.invalid/extra.zip", .kind = .extra, .game_thread_id = 77, .title = "Extra", .host = HOST_RAW } });
    fx.dl.send(.{ .enqueue_url = .{ .url = "https://example.invalid/mod.zip", .kind = .mod, .game_thread_id = 77, .title = "Mod", .host = HOST_RAW } });
    fx.dl.send(.{ .enqueue_catalogue = .{ .game_thread_id = 9, .href = "https://pixeldrain.com/u/upd", .title = "G" } });
    fx.dl.send(.{ .enqueue_url = .{ .url = "https://example.invalid/mm.zip", .kind = .mod, .mod_id = 5, .game_thread_id = 77, .title = "Managed mod", .host = HOST_RAW } });
    fx.dl.stepOnce(1000);
    for (fx.dl.recs.items[0..3]) |r| {
        try testing.expectEqual(model.Step.done, r.job.step);
        try testing.expect(std.mem.endsWith(u8, r.job.step_detail, "apply it by hand (Mods / patch)"));
        try testing.expect(r.worker == null);
    }
    try testing.expectEqual(model.Kind.extra, fx.dl.recs.items[2].job.kind);
    const mm = fx.dl.recs.items[3];
    try testing.expectEqual(model.Step.installing, mm.job.step);
    try testing.expectEqualStrings(MOD_ARCHIVE, mm.job.step_detail);
    try testing.expectEqual(@as(usize, 1), countInstallReady(fx));
}

test "downloader: a refused donor link says it expired, is not retried, and its cookie is dropped; a retryable failure keeps it" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    const net = [_]model.Progress{.{ .phase = .failed, .fail = .network, .msg = "reset" }};
    fx.fake.script = &net;
    fx.dl.send(.{ .enqueue_url = .{ .url = "https://attachments.f95zone.to/x.zip", .kind = .game, .game_thread_id = 77, .title = "G", .host = HOST_DONOR, .headers = &.{"Cookie: xf_session=secret"} } });
    fx.dl.stepOnce(1000);
    const r = fx.dl.recs.items[0];
    try testing.expectEqual(model.Step.failed, r.job.step);
    try testing.expect(r.job.next_retry_at != null);
    // An automatic retry is pending: it still needs the cookie.
    try testing.expectEqual(@as(usize, 1), r.job.resolved_headers.len);

    const gone = [_]model.Progress{.{ .phase = .failed, .fail = .auth_required, .msg = "aria2 exit 24" }};
    fx.fake.script = &gone;
    fx.fake.idx = 0;
    fx.dl.stepOnce(1030); // the retry starts …
    fx.dl.stepOnce(1031); // … and the CDN refuses it
    try testing.expectEqual(model.Step.failed, r.job.step);
    try testing.expectEqual(model.FailReason.auth_required, r.job.fail.?);
    try testing.expectEqualStrings(LINK_EXPIRED, r.job.step_detail);
    try testing.expectEqual(@as(?i64, null), r.job.next_retry_at);
    try testing.expectEqual(@as(usize, 0), r.job.resolved_headers.len);
    const rows = try fx.dl.store.loadAll(testing.allocator);
    defer store_mod.Store.freeJobs(testing.allocator, rows);
    try testing.expectEqual(@as(usize, 0), rows[0].resolved_headers.len);
    // No automatic retry, however long we wait.
    const started = fx.fake.started;
    fx.dl.stepOnce(99_999);
    try testing.expectEqual(started, fx.fake.started);
}

test "downloader: deinit returns within 4 s while a worker still runs (the worker is detached)" {
    // The worker outlives this test: its stub and allocator must too.
    const S = struct {
        var stub: ResolveStub = .{ .routes = &.{}, .sleep_ms = 10_000 };
    };
    const a = std.heap.smp_allocator;
    var fake: engine_mod.FakeEngine = .{ .alloc = a, .script = &.{} };
    var dl = Downloader.init(a, testing.io, try store_mod.Store.openMemory(a), .{ .aria2 = fake.engine() }, .{
        .downloads_root = "/nonexistent/f69-dl",
        .library_root = "/nonexistent/f69-lib",
        .data_root = "/nonexistent/f69-data",
    }, .{}, S.stub.ctx());
    dl.send(.{ .enqueue_url = .{ .url = "https://pixeldrain.com/u/slow", .kind = .game, .game_thread_id = 77, .title = "G", .host = HOST_RAW } });
    dl.stepOnce(1000);
    try testing.expect(dl.recs.items[0].resolve_worker != null);
    const t0 = std.Io.Clock.Timestamp.now(testing.io, .awake).raw.toMilliseconds();
    const detached = dl.deinit();
    const ms = std.Io.Clock.Timestamp.now(testing.io, .awake).raw.toMilliseconds() - t0;
    try testing.expect(ms < 4000);
    try testing.expect(ms >= QUIT_WAIT_MS - 100);
    try testing.expectEqual(@as(usize, 1), detached);
}

test "downloader: reconcile drops cookies left on finished rows; a failure with a retry pending keeps them" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    var d = storedJob(.done);
    d.resolved_headers = &.{"Cookie: a=b"};
    const id_d = try fx.dl.store.insert(&d);
    var f = storedJob(.failed);
    f.fail = .network;
    f.next_retry_at = 99_999;
    f.resolved_headers = &.{"Cookie: c=d"};
    const id_f = try fx.dl.store.insert(&f);
    try fx.dl.load();
    fx.dl.reconcile();
    try testing.expectEqual(@as(usize, 0), fx.rec(id_d).job.resolved_headers.len);
    try testing.expectEqual(@as(usize, 1), fx.rec(id_f).job.resolved_headers.len);
    const rows = try fx.dl.store.loadAll(testing.allocator);
    defer store_mod.Store.freeJobs(testing.allocator, rows);
    try testing.expectEqual(@as(usize, 0), rows[0].resolved_headers.len);
}

test "downloader: reconcile — a job that was waiting to extract (no folder of its own) never registers another job's folder" {
    var fx = try Fx.create(.{});
    defer fx.destroy();
    try fx.env.writeFile("payload/g.zip", "not really a zip");
    const zip = try fx.env.path("payload/g.zip");
    defer testing.allocator.free(zip);
    // The other job's finished extract.
    try fx.env.writeFile("lib/9/v1/game.exe", "x");
    var j = storedJob(.extracting);
    j.game_thread_id = 9;
    j.version = "v1";
    j.final_path = zip;
    j.step_detail = EXTRACT_WAIT;
    const id = try fx.dl.store.insert(&j);
    try fx.dl.load();
    fx.dl.reconcile();
    try testing.expect(!std.mem.eql(u8, fx.rec(id).job.step_detail, FOLDER_EXISTS));
    try testing.expect(std.mem.endsWith(u8, fx.rec(id).job.extract_dir.?, "9" ++ sep ++ "v1 (2)" ++ sep));
    try waitWorkers(fx, 1001);
}
