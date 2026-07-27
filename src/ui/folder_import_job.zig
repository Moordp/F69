// Background worker for folder-import file transfers.
//
// The "Import ticked rows" / per-row resolve paths used to run
// `migrate.copyVerifyDelete` synchronously on the UI render thread,
// freezing the whole GUI for the duration of a large copy (an 18 GB
// cross-device move would lock the app for minutes and draw no
// progress). This worker moves the bytes off-thread so the bottom-bar
// progress indicator can animate and the user can cancel.
//
// Same single-threaded-SQLite contract as `import_job.zig`: the worker
// NEVER touches `Library`. The action layer does the cheap DB work
// (insertIfMissing + path build) on the UI thread BEFORE spawning, and
// commits the install rows (upsertInstall) on the UI thread AFTER the
// worker reports `.done`. The worker only shuffles files.

const std = @import("std");
const importers = @import("importers");
const dvui = @import("dvui");
const job_mod = @import("job.zig");

const migrate = importers.migrate;
const log = std.log.scoped(.folder_import_job);

/// One folder transfer plus the install-row data the UI thread needs
/// to commit it once the bytes land. Every slice is alloc-owned by the
/// job and released in `freePayload`.
pub const Item = struct {
    /// Display name for the status bar ("Importing {name}").
    name: []u8,
    /// Absolute source / destination dirs. `dst` doubles as the
    /// install row's `install_path` on success.
    src: []u8,
    dst: []u8,
    /// `migrate.copyVerifyDelete` keep_source — true for Copy mode,
    /// false for Move (source deleted after a clean verify).
    keep_source: bool,
    // ---- install-row payload the UI upserts on completion ----
    tid: u64,
    version: []u8,
    id: [36]u8,
    // ---- outcome: worker writes, UI reads after phase == .done ----
    ok: bool = false,
    source_delete_failed: bool = false,
    err_name: ?[]const u8 = null,
    /// True when the batch was cancelled before this item ran (or this
    /// item's transfer was itself cancelled). Distinct from a failure so
    /// the UI recap doesn't report user-requested stops as errors.
    canceled: bool = false,
};

pub const Payload = struct {
    /// `std.Io` doesn't ride on the generic `Job` carrier, so the
    /// payload carries it for the worker's filesystem calls.
    io: std.Io,
    /// Immutable for the job's lifetime — the UI thread reads
    /// `items[cur_index].name` during render without locking.
    items: []Item,
    /// Index of the transfer in flight, for the status-bar label.
    cur_index: std.atomic.Value(u32) = .init(0),
    /// Batch-wide byte progress. `bytes_total` = 2 × Σ(file sizes)
    /// across all items (copy pass writes + verify pass reads), set
    /// once before the loop so the bar denominator never moves.
    /// `bytes_done` is bumped inside `copyVerifyDelete`.
    bytes_done: std.atomic.Value(u64) = .init(0),
    bytes_total: std.atomic.Value(u64) = .init(0),
};

pub const Job = job_mod.Job(Payload);

pub fn worker(job: *Job) void {
    const p = &job.payload;

    // Pre-compute the fixed batch-wide byte total (×2 covers the
    // verify re-read). stat-only — negligible next to the copy.
    var total: u64 = 0;
    for (p.items) |it| total +|= migrate.sumTreeBytes(job.alloc, p.io, it.src) *| 2;
    p.bytes_total.store(total, .release);
    job_mod.refreshDebounced(job.win, @src());

    for (p.items, 0..) |*it, i| {
        // Cancel between items: mark this and every remaining item as
        // canceled (NOT failed) so the recap counts them honestly.
        if (job.cancelRequested()) {
            for (p.items[i..]) |*rest| rest.canceled = true;
            break;
        }
        p.cur_index.store(@intCast(i), .release);
        job_mod.refreshDebounced(job.win, @src());

        const stats = migrate.copyVerifyDelete(job.alloc, p.io, it.src, it.dst, .{
            .keep_source = it.keep_source,
            .cancel = &job.cancel,
            .byte_done = &p.bytes_done,
        }) catch |e| {
            if (e == error.Canceled) {
                // Cancel fired mid-transfer: this item and the rest didn't
                // complete, but that's a stop, not a failure.
                for (p.items[i..]) |*rest| rest.canceled = true;
                break;
            }
            it.ok = false;
            it.err_name = @errorName(e);
            log.warn("folder-import transfer failed for '{s}': {s}", .{ it.name, @errorName(e) });
            continue;
        };
        it.ok = true;
        it.source_delete_failed = stats.source_delete_failed;
        job_mod.refreshDebounced(job.win, @src());
    }
    // Always `.done` — even on cancel/partial failure. The UI drain
    // walks per-item `ok` flags to decide which installs to commit.
    job.markDone();
}

/// Free every alloc-owned string + the items slice. Called by the UI
/// drain handlers before the carrier is destroyed.
pub fn freePayload(job: *Job) void {
    const alloc = job.alloc;
    for (job.payload.items) |it| {
        alloc.free(it.name);
        alloc.free(it.src);
        alloc.free(it.dst);
        alloc.free(it.version);
    }
    alloc.free(job.payload.items);
}
