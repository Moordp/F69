//! Generic worker-job primitive.
//!
//! Every UI feature that offloads work to a detached thread followed
//! the same shape:
//!   1. heap-alloc a struct with `phase: atomic.Value(u8)`, `thr`,
//!      `alloc`, `win`, plus payload-specific fields;
//!   2. spawn a worker thread that flips `phase` on terminal state +
//!      calls `dvui.refresh(win, …)` to wake the UI;
//!   3. each frame, drain the slot: if `phase == .pending` return;
//!      otherwise branch on `.done` / `.failed`, run a cleanup, free.
//!
//! Twelve+ jobs hand-rolled that scaffolding. `Job(Payload)` captures
//! the common shape; `spawnJob` factors the alloc + spawn + detach +
//! slot-set chain; `drainBackgroundJob` factors the per-frame reap.
//! New workers reduce to: define a `Payload` struct, write
//! `myWorker(job: *Job(Payload)) void`, call `spawnJob`, and
//! `drainBackgroundJob(...onDone, ...onFailed)` once per frame.
//!
//! Per-job phase enums (`SyncJobPhase`, `RefreshTagsPhase`, …) all
//! used the canonical pending/done/failed shape so this primitive
//! standardises on `Job.Phase`.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

/// Nudge the calling thread to background-nice on Linux. UI thread
/// stays at the default nice value (0); workers add +5 so the kernel
/// preempts them in favour of UI work when CPU contention rises.
/// Image decode / encode used to monopolise cores when 8+ workers
/// ran in parallel; this is a cheap second line of defense beneath
/// the explicit `image_cpu_limit` semaphore. No-op on non-Linux.
pub fn lowerWorkerPriority() void {
    if (builtin.os.tag != .linux) return;
    // PRIO_PROCESS = 0. Linux interprets `who=0` as the calling
    // task (kernel TID), so this affects only the current worker
    // thread, not the UI thread or other workers. Errors ignored —
    // losing the priority hint is non-fatal.
    _ = std.os.linux.syscall3(.setpriority, 0, 0, 5);
}

/// Canonical job phase. Worker flips from `.pending` to either
/// `.done` or `.failed` exactly once; UI thread only ever observes
/// the terminal transition through the atomic.
pub const Phase = enum(u8) { pending, done, failed };

/// Floor on inter-refresh interval for worker → UI wake-ups, in ns.
/// At ~30 Hz the user perceives the wake as instant but we drop the
/// redundant intra-tick refreshes from N workers completing close in
/// time. dvui's own event loop still wakes on input events at full
/// rate; this only governs how often workers can force a re-render.
const REFRESH_MIN_INTERVAL_NS: u64 = 33_000_000;

var last_refresh_ns: std.atomic.Value(u64) = .init(0);

/// Worker-side replacement for `dvui.refresh`. Drops calls that fall
/// inside the global ~30 Hz interval window so a burst of N workers
/// completing in the same tick triggers at most one redraw.
///
/// Safe to call from any thread. The atomic timestamp races
/// benignly: two callers may both see "interval elapsed" and both
/// fire — net cost is a couple extra refreshes per burst, still far
/// fewer than the unconditional N. Callers that need a guaranteed
/// wake (terminal phase transition, etc.) can still use
/// `dvui.refresh` directly — but every `markDone` / `markFailed`
/// already triggers a refresh, so they don't need to.
pub fn refreshDebounced(win: *dvui.Window, src: std.builtin.SourceLocation) void {
    const now = monotonicNanos();
    const last = last_refresh_ns.load(.monotonic);
    if (now -% last < REFRESH_MIN_INTERVAL_NS) return;
    last_refresh_ns.store(now, .monotonic);
    dvui.refresh(win, src, null);
}

/// Linux monotonic clock in nanoseconds via `clock_gettime` — no
/// `io` context needed, which lets us call this from any worker
/// thread without plumbing. Falls back to 0 on the (Linux-only)
/// unlikely syscall failure so the next call still fires the
/// refresh deterministically.
fn monotonicNanos() u64 {
    // Linux: clock_gettime(MONOTONIC). Elsewhere (Windows/macOS): a cross-platform
    // wall-clock ns — fine for this ~30 Hz refresh debounce. Both are io-free so any
    // worker thread can call without plumbing.
    switch (builtin.os.tag) {
        .windows => {
            // GetTickCount64: monotonic ms since boot — io-free, and ms resolution is plenty
            // for this ~30 Hz refresh debounce.
            const k32 = struct {
                extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
            };
            return k32.GetTickCount64() *% std.time.ns_per_ms;
        },
        else => {
            var ts: std.c.timespec = undefined;
            if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
            const sec: u64 = @intCast(ts.sec);
            const nsec: u64 = @intCast(ts.nsec);
            return sec *% std.time.ns_per_s +% nsec;
        },
    }
}

/// Heap-allocated job carrier. Behavior is in `actions/*.zig`
/// workers; this struct is pure data plus the atomic phase + cancel
/// flag the UI/worker contract relies on.
///
/// Lifetime: `spawnJob` allocates + spawns + detaches; the worker
/// runs to terminal phase; the next `drainBackgroundJob` reap on
/// the UI thread destroys the job. The `thr` handle is never
/// joined — detached threads are reaped by the OS, and the atomic
/// phase already gives the UI a safe happens-before for reading
/// any worker-written payload field.
pub fn Job(comptime Payload: type) type {
    return struct {
        const Self = @This();
        pub const PayloadT = Payload;

        phase: std.atomic.Value(u8),
        cancel: std.atomic.Value(bool) = .init(false),
        thr: std.Thread,
        alloc: std.mem.Allocator,
        win: *dvui.Window,
        payload: Payload,

        /// Worker → UI: flip to `.done`, refresh. The refresh goes
        /// through `refreshDebounced` so a burst of N workers
        /// completing in the same tick produces one redraw instead
        /// of N.
        pub fn markDone(self: *Self) void {
            // Capture `win` BEFORE the release-store: once the store is
            // visible, the UI reaper (drainBackgroundJob) may observe the
            // terminal phase and `destroy(self)` before this line runs, so
            // reading `self.win` after the store is a use-after-free. The
            // Window itself outlives the job, so the captured pointer stays
            // valid.
            const win = self.win;
            self.phase.store(@intFromEnum(Phase.done), .release);
            refreshDebounced(win, @src());
        }

        /// Worker → UI: flip to `.failed`, refresh. The payload's
        /// `err_name` (or equivalent) carries the diagnostic;
        /// `markFailed` itself is allocator-free so it works from
        /// any worker control path.
        pub fn markFailed(self: *Self) void {
            // Same UAF window as markDone — capture `win` before the store.
            const win = self.win;
            self.phase.store(@intFromEnum(Phase.failed), .release);
            refreshDebounced(win, @src());
        }

        /// UI thread snapshot of the current phase.
        pub fn phaseGet(self: *const Self) Phase {
            return @enumFromInt(self.phase.load(.acquire));
        }

        /// UI thread asks the worker to bail out at its next phase
        /// boundary. Workers must poll `cancelRequested` between
        /// long operations; the contract is *cooperative* — there's
        /// no kill primitive here.
        pub fn requestCancel(self: *Self) void {
            self.cancel.store(true, .release);
        }

        /// Worker thread polls between long operations.
        pub fn cancelRequested(self: *const Self) bool {
            return self.cancel.load(.acquire);
        }
    };
}

/// Spawn a detached worker thread that runs `workerFn(job)`. The
/// caller's `slot` (a `*?*Job(Payload)` typed pointer on `State`)
/// is updated to point at the new job on success. Returns the job
/// pointer too so the caller can record additional bookkeeping
/// (e.g. seeding a thread-id into a sibling map).
///
/// On failure (alloc or spawn) the slot is left unchanged and the
/// job is reclaimed; caller decides whether to surface a toast.
pub fn spawnJob(
    comptime Payload: type,
    comptime workerFn: fn (*Job(Payload)) void,
    alloc: std.mem.Allocator,
    win: *dvui.Window,
    payload: Payload,
    slot: *?*Job(Payload),
) !*Job(Payload) {
    const job = try alloc.create(Job(Payload));
    errdefer alloc.destroy(job);
    job.* = .{
        .phase = .init(@intFromEnum(Phase.pending)),
        .thr = undefined,
        .alloc = alloc,
        .win = win,
        .payload = payload,
    };
    // Wrap the worker so every spawnJob-launched thread picks up the
    // background nice value before user code runs. Centralising this
    // means individual worker fns don't need to remember.
    const J = Job(Payload);
    const Wrapper = struct {
        fn run(j: *J) void {
            lowerWorkerPriority();
            workerFn(j);
        }
    };
    job.thr = try std.Thread.spawn(.{}, Wrapper.run, .{job});
    job.thr.detach();
    slot.* = job;
    return job;
}

/// UI-thread reaper. Reads `slot.*`, returns if no job or still
/// pending; otherwise calls the appropriate handler, nulls the
/// slot, and destroys the heap allocation. The handlers are
/// responsible for any payload-owned cleanup (freeing strings,
/// transferring ownership into Library, etc.) BEFORE this helper
/// destroys the carrier.
///
/// The handler signature is `fn (*Ctx, *Job(Payload)) void`. `Ctx`
/// is `anytype` so callers can pass `*Frame`, `*State`, or
/// whatever. Both handlers must take the same `Ctx` type.
pub fn drainBackgroundJob(
    comptime Payload: type,
    comptime onDone: anytype,
    comptime onFailed: anytype,
    ctx: anytype,
    slot: *?*Job(Payload),
) void {
    const job = slot.* orelse return;
    switch (job.phaseGet()) {
        .pending => return,
        .done => onDone(ctx, job),
        .failed => onFailed(ctx, job),
    }
    slot.* = null;
    job.alloc.destroy(job);
}
