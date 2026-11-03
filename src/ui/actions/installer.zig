// Installer pipeline:
//   - per-mod install/uninstall worker (`modJobRunner`, `runInstall`,
//     `runUninstall`, the on-disk job recovery + drain loop).
//   - test-install preview (`doTestInstallPreview`, `testInstallWorker`,
//     `drainTestInstall`, etc.).
//   - mod install entry point (`doInstallMod`) + multi-conflict
//     detection (`detectAllModFileConflicts`, persistent overrides) +
//     clash modal state.
//   - resolver preflight (`preflightResolveMod`, `preflightSolveSingle`,
//     `reportResolverResult`).
//   - post-install pipeline (`installFromArchive`, `postInstallWorker`,
//     `drainPostInstall`): the downloader's `install_ready` event lands
//     here; verify + extract already ran on the downloader thread.
//   - manual-install pipeline (mirror of post-install with computed
//     SHA + user-supplied archive).
//   - `doRenameInstall` / `doDeleteInstall`.

const std = @import("std");
const atomic_io = @import("util_atomic_io");
const log = std.log.scoped(.ui_actions);
const library = @import("library");
const recipe = @import("recipe");
const installer_mod = @import("installer");
const resolver = @import("resolver");
const downloads = @import("downloads");
const version_mod = @import("util_version");
const dvui = @import("dvui");
const types = @import("../types.zig");
const state_mod = @import("../state.zig");
const mod_job_queue = @import("../mod_job_queue.zig");
const owned_types = @import("../owned.zig");
const job_mod = @import("../job.zig");
const common = @import("common.zig");
const dl_rows = @import("../dl_rows.zig");
const mods_act = @import("mods.zig");
const launch_act = @import("launch.zig");
const sync_act = @import("sync.zig");

const Frame = types.Frame;
const State = types.State;

const PostInstallJobsList = owned_types.PostInstallJobsList;
pub const PostInstallPayload = owned_types.PostInstallPayload;
pub const ManualInstallPayload = owned_types.ManualInstallPayload;

pub const TestInstallPayload = owned_types.TestInstallPayload;
pub const TestInstallJob = owned_types.TestInstallJob;
pub const PostInstallJob = owned_types.PostInstallJob;
pub const ManualInstallJob = owned_types.ManualInstallJob;
pub const ManualInstallJobsList = owned_types.ManualInstallJobsList;
pub const ModFileConflictAll = owned_types.ModFileConflictAll;
pub const ClashModalState = owned_types.ClashModalState;

// ============================================================
//  per-mod install — enqueue mod archive download, post-install applies
// ============================================================

/// True iff the per-install tracker carries any entry for this mod —
/// i.e. apply has already happened. Used by the detail screen to
/// flip the row's Install ↔ Uninstall button.
pub fn isModInstalled(frame: *Frame, parent_game: *const library.Game, mod_recipe: *const recipe.ModRecipe) bool {
    const alloc = frame.lib.alloc;
    const install_opt = mods_act.resolveModsPageInstall(frame, parent_game.f95_thread_id);
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const install = install_opt orelse return false;

    const layout = mods_act.modTrackerLayout(frame.io, alloc, install.install_path) catch return false;
    defer mods_act.freeModTrackerLayout(alloc, layout);
    var log_obj = installer_mod.Tracker.load(alloc, frame.io, layout.tracker_path) catch return false;
    defer log_obj.deinit(alloc);

    // Match either format the tracker may have written: the recipe
    // slug (current code path — covers locally-imported mods where
    // f95_thread is 0) OR the integer f95_thread (legacy format
    // from older builds; still on disk for any mod the user
    // installed before this fix shipped).
    var legacy_buf: [32]u8 = undefined;
    const legacy_id: []const u8 = std.fmt.bufPrint(&legacy_buf, "{d}", .{mod_recipe.f95_thread}) catch "";
    for (log_obj.entries) |e| {
        if (std.mem.eql(u8, e.mod_id, mod_recipe.id)) return true;
        if (legacy_id.len > 0 and std.mem.eql(u8, e.mod_id, legacy_id)) return true;
    }
    return false;
}

/// Click handler for the per-mod Uninstall button. Enqueues an
/// uninstall job; the worker thread runs `installer.uninstallMod` so a
/// big uninstall doesn't block the UI.
pub fn doUninstallMod(frame: *Frame, parent_game: *const library.Game, mod_recipe: *const recipe.ModRecipe) void {
    const state = frame.state;
    if (frame.mod_jobs.isModBusy(parent_game.f95_thread_id, mod_recipe.f95_thread)) {
        state.setDownloadMsg("This mod already has a job in flight.");
        return;
    }
    const install_opt = mods_act.resolveModsPageInstall(frame, parent_game.f95_thread_id);
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const install = install_opt orelse {
        state.setDownloadMsg("No install to uninstall from.");
        return;
    };
    enqueueModJob(frame, .uninstall, parent_game, mod_recipe, null, install.id[0..], .none) catch |e| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Failed to enqueue: {s}", .{@errorName(e)}) catch "Failed to enqueue uninstall";
        state.setDownloadMsg(msg);
    };
}

/// Runner the queue invokes from its worker thread. Owns all the work
/// `doInstallMod` / `doUninstallMod` used to do synchronously. Lives in
/// the UI layer because it needs Library + Repo handles. `ctx` is the
/// runner-context pointer set at queue init — we stash a `RunnerCtx`
/// there so the worker can reach lib/io.
pub const RunnerCtx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    lib: *library.Library,
    repo: *recipe.Repo,
    /// OS temp root for mod-apply staging (`%TEMP%` on Windows, `/tmp`
    /// elsewhere). Resolved once at startup; see RuntimeInfo.staging_dir.
    temp_root: []const u8 = "/tmp",
};

pub fn modJobRunner(ctx: ?*anyopaque, job: *mod_job_queue.Job) void {
    const c: *RunnerCtx = @ptrCast(@alignCast(ctx orelse return));
    runOneModJob(c, job) catch |e| {
        // runOneModJob already set err_buf/len on the job before
        // returning; fall through to phase=err.
        log.warn("mod job {d} failed: {s}", .{ job.id, @errorName(e) });
    };
    // Final phase: ensure terminal state is set. runOneModJob sets
    // .done on success; on error path we set .err here unless the
    // worker already flipped it.
    const p = job.currentPhase();
    if (p != .done and p != .canceled and p != .err) {
        job.phase.store(@intFromEnum(mod_job_queue.Phase.err), .release);
    }
}

fn runOneModJob(ctx: *RunnerCtx, job: *mod_job_queue.Job) !void {
    job.phase.store(@intFromEnum(mod_job_queue.Phase.preparing), .release);
    job.progress_done.store(0, .release);
    job.progress_total.store(0, .release);

    const alloc = ctx.alloc;
    const io = ctx.io;

    // Resolve the install row by pinned id. Latest fallback would be
    // wrong here: jobs can queue while the user installs new versions,
    // and we want each job's target stable.
    const install_opt = findInstallById(ctx.lib, job.game_thread_id, job.installId());
    defer if (install_opt) |i| ctx.lib.freeInstall(i);
    const install = install_opt orelse {
        setJobErr(job, "Install row vanished.") catch {};
        return;
    };

    const layout = mods_act.modTrackerLayout(io, alloc, install.install_path) catch {
        setJobErr(job, "Failed to resolve install root.") catch {};
        return;
    };
    defer mods_act.freeModTrackerLayout(alloc, layout);

    // Tracker writes / lookups use the recipe slug, not the integer
    // f95_thread. Locally-imported mods all have f95_thread = 0, so
    // formatting that as a string would collide every local mod onto
    // the same tracker key — and the cache lookup that reads "are
    // any tracker entries for THIS mod" would silently return all of
    // them as one. `mod_recipe_id` is the slugified recipe id, which
    // is unique per recipe on disk.
    const mod_id_str = job.mod_recipe_id;

    switch (job.kind) {
        .install => try runInstall(ctx, job, layout, mod_id_str),
        .uninstall => try runUninstall(ctx, job, layout, mod_id_str),
    }

    // Don't promote to `.done` if the sub-runner already flipped the
    // job to `.err` / `.canceled` via setJobErr — that was the bug
    // that made every uninstall look like a success.
    const cur: mod_job_queue.Phase = @enumFromInt(job.phase.load(.monotonic));
    if (cur != .err and cur != .canceled) {
        job.phase.store(@intFromEnum(mod_job_queue.Phase.done), .release);
    }
}

fn runInstall(
    ctx: *RunnerCtx,
    job: *mod_job_queue.Job,
    layout: mods_act.ModTrackerLayout,
    mod_id_str: []const u8,
) !void {
    const archive_path = job.archive_path orelse return setJobErr(job, "Install job has no archive path.");

    // Lookup the recipe so we can honor its install-step list (if any).
    // Falls through to a flat overlay when the recipe is gone or has
    // no custom steps.
    var parsed_mod_opt = ctx.repo.findMod(job.mod_recipe_id) catch null;
    defer if (parsed_mod_opt) |*p| p.deinit();

    job.phase.store(@intFromEnum(mod_job_queue.Phase.staging), .release);

    var tracker = installer_mod.Tracker.init(ctx.alloc, ctx.io, layout.tracker_path);
    defer tracker.deinit();
    var existing = installer_mod.Tracker.load(ctx.alloc, ctx.io, layout.tracker_path) catch installer_mod.InstallLog{ .entries = &.{} };
    defer existing.deinit(ctx.alloc);
    for (existing.entries) |e| tracker.record(e) catch {};

    job.phase.store(@intFromEnum(mod_job_queue.Phase.applying), .release);

    const apply_opts: installer_mod.ApplyOpts = .{
        .backup_mode = job.backup_mode,
        .progress_cb = jobProgressCb,
        .progress_ctx = job,
        .cancel = &job.cancel_flag,
        .staging_root = ctx.temp_root,
    };

    const apply_err: ?anyerror = if (parsed_mod_opt) |*pm| blk: {
        if (pm.recipe.install.len > 0) {
            installer_mod.applyModRecipe(
                ctx.alloc,
                ctx.io,
                mod_id_str,
                archive_path,
                layout.game_root,
                pm.recipe.install,
                &tracker,
                apply_opts,
            ) catch |e| break :blk e;
            break :blk null;
        }
        installer_mod.applyModArchive(
            ctx.alloc,
            ctx.io,
            mod_id_str,
            archive_path,
            layout.game_root,
            &tracker,
            apply_opts,
        ) catch |e| break :blk e;
        break :blk null;
    } else blk: {
        installer_mod.applyModArchive(
            ctx.alloc,
            ctx.io,
            mod_id_str,
            archive_path,
            layout.game_root,
            &tracker,
            apply_opts,
        ) catch |e| break :blk e;
        break :blk null;
    };

    if (apply_err) |e| switch (e) {
        error.Canceled => {
            // Roll back the partial install so cancelling doesn't leave
            // orphaned, half-tracked files in the game dir. `tracker`
            // holds every entry recorded so far (each file is recorded
            // then copied then cancel-checked, so a recorded file was
            // always written); flush the FULL in-memory log to disk,
            // reverse this mod's entries, then persist the log without
            // them — mirroring the uninstall path.
            job.phase.store(@intFromEnum(mod_job_queue.Phase.flushing), .release);
            tracker.flush() catch {};
            var log_obj = installer_mod.Tracker.load(ctx.alloc, ctx.io, layout.tracker_path) catch installer_mod.InstallLog{ .entries = &.{} };
            defer log_obj.deinit(ctx.alloc);
            installer_mod.uninstallMod(ctx.io, layout.game_root, mod_id_str, &log_obj) catch |ue|
                log.warn("cancel rollback: uninstall {s} failed: {s}", .{ mod_id_str, @errorName(ue) });
            var clean = installer_mod.Tracker.init(ctx.alloc, ctx.io, layout.tracker_path);
            defer clean.deinit();
            for (log_obj.entries) |le| clean.record(le) catch {};
            clean.removeMod(mod_id_str);
            clean.flush() catch {};
            job.phase.store(@intFromEnum(mod_job_queue.Phase.canceled), .release);
            return;
        },
        else => {
            var buf: [192]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Install failed: {s}", .{@errorName(e)}) catch "Install failed";
            return setJobErr(job, msg);
        },
    };

    job.phase.store(@intFromEnum(mod_job_queue.Phase.flushing), .release);
    tracker.flush() catch return setJobErr(job, "Tracker flush failed.");
}

fn runUninstall(
    ctx: *RunnerCtx,
    job: *mod_job_queue.Job,
    layout: mods_act.ModTrackerLayout,
    mod_id_str: []const u8,
) !void {
    job.phase.store(@intFromEnum(mod_job_queue.Phase.applying), .release);

    var log_obj = installer_mod.Tracker.load(ctx.alloc, ctx.io, layout.tracker_path) catch return setJobErr(job, "Tracker load failed.");
    defer log_obj.deinit(ctx.alloc);

    installer_mod.uninstallMod(ctx.io, layout.game_root, mod_id_str, &log_obj) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Uninstall failed: {s}", .{@errorName(e)}) catch "Uninstall failed";
        return setJobErr(job, msg);
    };

    job.phase.store(@intFromEnum(mod_job_queue.Phase.flushing), .release);

    var tracker = installer_mod.Tracker.init(ctx.alloc, ctx.io, layout.tracker_path);
    defer tracker.deinit();
    for (log_obj.entries) |e| tracker.record(e) catch {};
    tracker.removeMod(mod_id_str);
    tracker.flush() catch return setJobErr(job, "Tracker flush failed.");
}

fn jobProgressCb(ctx: ?*anyopaque, done: u32, total: u32) void {
    const job: *mod_job_queue.Job = @ptrCast(@alignCast(ctx orelse return));
    job.progress_done.store(done, .monotonic);
    if (total != 0) job.progress_total.store(total, .monotonic);
}

fn setJobErr(job: *mod_job_queue.Job, msg: []const u8) error{}!void {
    const n = @min(msg.len, job.err_buf.len);
    @memcpy(job.err_buf[0..n], msg[0..n]);
    job.err_len = @intCast(n);
    job.phase.store(@intFromEnum(mod_job_queue.Phase.err), .release);
}

/// Lookup a specific install row by id. Returns alloc-owned Install;
/// caller frees with `lib.freeInstall`. Other rows in the listInstalls
/// result are freed inline so the returned Install is the sole owner
/// of its strings.
fn findInstallById(lib: *library.Library, game_thread_id: u64, install_id: []const u8) ?library.Install {
    const installs = lib.listInstalls(game_thread_id) catch return null;
    if (installs.len == 0) return null;

    var match_idx: ?usize = null;
    for (installs, 0..) |i, idx| {
        if (std.mem.eql(u8, i.id[0..], install_id)) {
            match_idx = idx;
            break;
        }
    }
    const idx = match_idx orelse {
        lib.freeInstalls(installs);
        return null;
    };

    const matched = installs[idx];
    for (installs, 0..) |inst, j| {
        if (j == idx) continue;
        lib.freeInstall(inst);
    }
    lib.alloc.free(installs);
    return matched;
}

/// Boot-time recovery. Read the persisted queue, for each "was running"
/// job: roll back any partial tracker entries it left behind so the
/// retry starts from a clean slate. Then re-enqueue every persisted
/// job (running + queued) in the original order. Called once from
/// `runMainLoop` before the worker starts.
pub fn recoverModJobsFromDisk(
    queue: *mod_job_queue.Queue,
    lib: *library.Library,
    alloc: std.mem.Allocator,
    io: std.Io,
) !void {
    var recovered = queue.loadPersisted() catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return,
    } orelse return;
    defer recovered.deinit(alloc);

    mod_job_queue.adoptRecoveredNextId(queue, recovered.next_id);

    for (recovered.jobs) |*r| {
        if (r.was_running) rollbackInterruptedJob(lib, alloc, io, r) catch |e| {
            log.warn("rollback failed for thread {d}: {s}", .{ r.mod_thread_id, @errorName(e) });
        };

        const ap_owned: ?[]u8 = if (r.archive_path) |a|
            alloc.dupe(u8, a) catch return error.OutOfMemory
        else
            null;
        errdefer if (ap_owned) |x| alloc.free(x);
        const rid_owned = alloc.dupe(u8, r.mod_recipe_id) catch return error.OutOfMemory;
        errdefer alloc.free(rid_owned);
        const disp_owned = alloc.dupe(u8, r.display) catch return error.OutOfMemory;
        errdefer alloc.free(disp_owned);

        _ = queue.enqueue(
            r.kind,
            r.game_thread_id,
            r.mod_thread_id,
            rid_owned,
            disp_owned,
            ap_owned,
            r.backup_mode,
            r.install_id,
        ) catch |e| {
            alloc.free(rid_owned);
            alloc.free(disp_owned);
            if (ap_owned) |x| alloc.free(x);
            return e;
        };
    }
}

/// Roll back whatever a crashed install partially recorded in the
/// tracker. The same `uninstallMod` path the user invokes on a clean
/// uninstall — it walks the partial entries and reverses them
/// (delete added_file, restore modified_file from .f69-backups when
/// backup_mode was .copy, leave warn-and-keep entries alone).
fn rollbackInterruptedJob(
    lib: *library.Library,
    alloc: std.mem.Allocator,
    io: std.Io,
    rec: *const mod_job_queue.RecoveredJob,
) !void {
    const install_opt = findInstallById(lib, rec.game_thread_id, rec.install_id);
    defer if (install_opt) |i| lib.freeInstall(i);
    const install = install_opt orelse return;

    const layout = mods_act.modTrackerLayout(io, alloc, install.install_path) catch return;
    defer mods_act.freeModTrackerLayout(alloc, layout);

    var mod_id_buf: [32]u8 = undefined;
    const mod_id_str = std.fmt.bufPrint(&mod_id_buf, "{d}", .{rec.mod_thread_id}) catch return;

    var log_obj = installer_mod.Tracker.load(alloc, io, layout.tracker_path) catch return;
    defer log_obj.deinit(alloc);

    installer_mod.uninstallMod(io, layout.game_root, mod_id_str, &log_obj) catch |e| {
        log.warn("rollback: uninstallMod for {d} failed: {s}", .{ rec.mod_thread_id, @errorName(e) });
        return;
    };

    // Rewrite the tracker without the rolled-back mod's entries so a
    // fresh install doesn't see them.
    var tracker = installer_mod.Tracker.init(alloc, io, layout.tracker_path);
    defer tracker.deinit();
    for (log_obj.entries) |e| tracker.record(e) catch {};
    tracker.removeMod(mod_id_str);
    tracker.flush() catch {};
}

/// Per-frame drain: pop terminal jobs, push a success / error toast.
pub fn drainModJobs(frame: *Frame) void {
    const state = frame.state;
    frame.mod_jobs.lock();
    // Toast on terminal transitions: scan for jobs we haven't yet
    // toasted, then drop them. Snapshot the job's kind alongside the
    // phase so the toast verb matches what actually happened
    // ("Uninstalled X" vs "Installed X"; previously every .done job
    // said "Installed" regardless of kind).
    const TerminalSnap = struct {
        phase: mod_job_queue.Phase,
        kind: mod_job_queue.Kind,
        display: [128]u8,
        display_len: u8,
        err: [128]u8,
        err_len: u8,
    };
    var to_toast: [8]TerminalSnap = undefined;
    var toast_n: usize = 0;
    {
        const jobs = frame.mod_jobs.jobsLocked();
        for (jobs) |j| {
            const p = j.currentPhase();
            if (p != .done and p != .err and p != .canceled) continue;
            if (toast_n >= to_toast.len) break;
            const dlen = @min(j.display.len, to_toast[toast_n].display.len);
            @memcpy(to_toast[toast_n].display[0..dlen], j.display[0..dlen]);
            to_toast[toast_n].display_len = @intCast(dlen);
            to_toast[toast_n].phase = p;
            to_toast[toast_n].kind = j.kind;
            const elen = @min(j.errMessage().len, to_toast[toast_n].err.len);
            @memcpy(to_toast[toast_n].err[0..elen], j.errMessage()[0..elen]);
            to_toast[toast_n].err_len = @intCast(elen);
            toast_n += 1;
        }
    }
    frame.mod_jobs.unlock();

    for (to_toast[0..toast_n]) |t| {
        const disp = t.display[0..t.display_len];
        var buf: [256]u8 = undefined;
        const verb: []const u8 = if (t.kind == .install) "Installed" else "Uninstalled";
        const msg = switch (t.phase) {
            .done => std.fmt.bufPrint(&buf, "{s} `{s}`.", .{ verb, disp }) catch "Mod job done.",
            .err => blk: {
                const e = t.err[0..t.err_len];
                break :blk std.fmt.bufPrint(&buf, "`{s}`: {s}", .{ disp, e }) catch "Mod job failed.";
            },
            .canceled => std.fmt.bufPrint(&buf, "`{s}` canceled.", .{disp}) catch "Mod job canceled.",
            else => unreachable,
        };
        const toast_kind: state_mod.ToastKind = switch (t.phase) {
            .done => .success,
            .err => .err,
            .canceled => .warn,
            else => .info,
        };
        state.pushToast(toast_kind, msg);
    }

    // Any terminal mod-job transition (install / uninstall, success or
    // failure) may have mutated the install tracker — drop the
    // mods-page render cache so the next frame reads fresh installed/
    // load_index state.
    if (toast_n > 0) mods_act.freeModsPageCacheState(state, frame.lib.alloc);

    frame.mod_jobs.drainFinished();
}

// ============================================================
//  Test install (real) — backgrounded worker
// ============================================================

/// "Test install (real)" — kicks off a worker thread that runs the
/// actual installer against a throwaway scratch dir. Verifies the
/// plan extracts cleanly against a real filesystem. UI stays
/// responsive while it runs; `drainTestInstall` per-frame posts the
/// success / failure toast when the worker finishes.
pub fn doTestInstallPreview(frame: *Frame, parent_game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const w = &(state.wizard orelse return);

    // Only one test at a time. Second click while one is running is a
    // soft no-op (the button label already says "Testing…").
    if (state.test_install_job != null) return;

    // 1. Archive path.
    const modfile_id = w.modfile_id_buf[0..w.modfile_id_len];
    const archive_path_opt = mods_act.modfileArchivePath(frame, parent_game, modfile_id);
    const archive_path = archive_path_opt orelse {
        state.pushToast(.err, "Test install: no archive registered for this mod.");
        return;
    };

    // 2. Scratch dir under the OS temp root (%TEMP% on Windows, /tmp else).
    var nonce: [16]u8 = undefined;
    frame.io.randomSecure(&nonce) catch frame.io.random(&nonce);
    const scratch = std.fmt.allocPrint(alloc, "{s}/f69-preview-{x}", .{ frame.info.staging_dir, std.fmt.bytesToHex(nonce, .lower) }) catch {
        alloc.free(archive_path);
        state.pushToast(.err, "Test install: out of memory.");
        return;
    };
    std.Io.Dir.cwd().createDirPath(frame.io, scratch) catch {
        alloc.free(archive_path);
        alloc.free(scratch);
        state.pushToast(.err, "Test install: failed to create scratch dir.");
        return;
    };

    // 3. Deep-copy install_steps + strings into a job-owned arena.
    //    The wizard's buffers can mutate after spawn; we need a
    //    stable snapshot.
    var steps_arena = std.heap.ArenaAllocator.init(alloc);
    const aalloc = steps_arena.allocator();

    var steps: std.ArrayList(recipe.InstallStep) = .empty;
    var bi: usize = 0;
    while (bi < w.block_count) : (bi += 1) {
        const b = &w.blocks[bi];
        const a_src = mods_act.sliceFromBuf(&b.a_buf);
        const b_src = mods_act.sliceFromBuf(&b.b_buf);
        const a = aalloc.dupe(u8, a_src) catch {
            steps_arena.deinit();
            alloc.free(archive_path);
            alloc.free(scratch);
            state.pushToast(.err, "Test install: out of memory.");
            return;
        };
        const bs = if (b_src.len > 0) (aalloc.dupe(u8, b_src) catch {
            steps_arena.deinit();
            alloc.free(archive_path);
            alloc.free(scratch);
            state.pushToast(.err, "Test install: out of memory.");
            return;
        }) else "";
        const step: recipe.InstallStep = switch (b.kind) {
            .extract => .{ .extract = .{ .to = a, .strip = b.strip } },
            .extract_inner => .{ .extract_inner = .{ .archive = a, .to = bs, .strip = b.strip } },
            .copy => .{ .copy = .{ .src = a, .dest = bs } },
            .move => .{ .move = .{ .src = a, .dest = bs } },
            .delete => .{ .delete = .{ .path = a } },
            .chmod_x => blk: {
                const paths_arr = aalloc.alloc([]const u8, 1) catch {
                    steps_arena.deinit();
                    alloc.free(archive_path);
                    alloc.free(scratch);
                    state.pushToast(.err, "Test install: out of memory.");
                    return;
                };
                paths_arr[0] = a;
                break :blk .{ .chmod_x = .{ .paths = paths_arr } };
            },
        };
        steps.append(aalloc, step) catch {
            steps_arena.deinit();
            alloc.free(archive_path);
            alloc.free(scratch);
            state.pushToast(.err, "Test install: out of memory.");
            return;
        };
    }
    const steps_slice = steps.toOwnedSlice(aalloc) catch {
        steps_arena.deinit();
        alloc.free(archive_path);
        alloc.free(scratch);
        state.pushToast(.err, "Test install: out of memory.");
        return;
    };

    // 4. Spawn the worker via the generic Job(P) primitive.
    const new_job = job_mod.spawnJob(
        TestInstallPayload,
        testInstallWorker,
        alloc,
        frame.win,
        .{
            .io = frame.io,
            .archive_path = archive_path,
            .scratch = scratch,
            .steps_arena = steps_arena,
            .steps = steps_slice,
        },
        &state.test_install_job,
    ) catch {
        steps_arena.deinit();
        alloc.free(archive_path);
        alloc.free(scratch);
        state.pushToast(.err, "Test install: failed to spawn worker thread.");
        return;
    };
    log.info("test install spawned → scratch {s}", .{new_job.payload.scratch});
}

fn testInstallWorker(job: *TestInstallJob) void {
    const p = &job.payload;
    var failed = false;
    const aalloc = p.steps_arena.allocator();

    // Tracker pointing into the scratch.
    const tracker_path = std.fmt.allocPrint(aalloc, "{s}/.f69-mods.json", .{p.scratch}) catch {
        p.err_name = "out of memory";
        job.markFailed();
        return;
    };
    var tracker = installer_mod.Tracker.init(job.alloc, p.io, tracker_path);
    defer tracker.deinit();

    installer_mod.applyModRecipe(
        job.alloc,
        p.io,
        "test-preview",
        p.archive_path,
        p.scratch,
        p.steps,
        &tracker,
        .{},
    ) catch |e| {
        failed = true;
        p.err_name = std.fmt.allocPrint(aalloc, "{s}", .{@errorName(e)}) catch "apply failed";
    };

    if (!failed) {
        // Walk the scratch to compute file count + total bytes.
        var root = std.Io.Dir.cwd().openDir(p.io, p.scratch, .{ .iterate = true, .access_sub_paths = true }) catch null;
        if (root) |*dir| {
            defer dir.close(p.io);
            var walker = dir.walk(job.alloc) catch null;
            if (walker) |*w| {
                defer w.deinit();
                while (w.next(p.io) catch null) |entry| {
                    if (entry.kind != .file) continue;
                    if (std.mem.endsWith(u8, entry.path, ".f69-mods.json")) continue;
                    p.file_count += 1;
                    var sub_path_buf: [1024]u8 = undefined;
                    const full = std.fmt.bufPrint(&sub_path_buf, "{s}/{s}", .{ p.scratch, entry.path }) catch continue;
                    const stat = std.Io.Dir.cwd().statFile(p.io, full, .{}) catch continue;
                    p.total_bytes += stat.size;
                }
            }
        }
    }

    if (failed) job.markFailed() else job.markDone();
}

/// Per-frame drain: checks the in-flight test-install job's phase, on
/// completion posts the success / failure toast, cleans up the scratch
/// tree, frees the job. Called from `guiFrame` alongside the other
/// worker drains.
pub fn drainTestInstall(frame: *Frame) void {
    job_mod.drainBackgroundJob(
        TestInstallPayload,
        onTestInstallDone,
        onTestInstallFailed,
        frame,
        &frame.state.test_install_job,
    );
}

fn freeTestInstallPayload(frame: *Frame, job: *TestInstallJob) void {
    const p = &job.payload;
    // Cleanup scratch. Best-effort.
    std.Io.Dir.cwd().deleteTree(frame.io, p.scratch) catch |e| {
        log.warn("test install scratch cleanup failed for {s}: {s}", .{ p.scratch, @errorName(e) });
    };
    // Arena owns the step strings + err_name; the outer allocator
    // owns archive_path / scratch.
    p.steps_arena.deinit();
    job.alloc.free(p.archive_path);
    job.alloc.free(p.scratch);
}

fn onTestInstallDone(frame: *Frame, job: *TestInstallJob) void {
    const state = frame.state;
    const p = &job.payload;
    defer freeTestInstallPayload(frame, job);
    var size_buf: [32]u8 = undefined;
    const size_txt = humanBytesActions(&size_buf, p.total_bytes);
    var msg_buf: [240]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Test install OK: {d} file(s), {s}.", .{ p.file_count, size_txt }) catch "Test install OK.";
    state.pushToast(.success, msg);
    log.info("test install done: {d} files, {s} to {s}", .{ p.file_count, size_txt, p.scratch });
}

fn onTestInstallFailed(frame: *Frame, job: *TestInstallJob) void {
    const state = frame.state;
    const p = &job.payload;
    defer freeTestInstallPayload(frame, job);
    var msg_buf: [240]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Test install failed: {s}", .{p.err_name orelse "unknown"}) catch "Test install failed";
    state.pushToast(.err, msg);
}

/// True when a test install is in flight. Used by the wizard's
/// Review-step button to swap its label to "Testing…" and refuse
/// repeat clicks until drain runs.
pub fn isTestInstallRunning(state: *const State) bool {
    return state.test_install_job != null;
}

/// Shutdown-time cleanup: if a test install is mid-run, drop the
/// scratch + free the job. Called from `ui.zig`'s teardown defer
/// alongside the other shutdown cleanups.
///
/// Note: the worker thread is detached (Job(P) primitive contract),
/// so we can't `join` it. If the worker is still mid-run when the
/// app shuts down, we tear down its payload anyway — the worst case
/// is a few failed syscalls inside the now-detached thread before
/// process exit reaps it. The scratch dir cleanup runs unconditionally
/// so /tmp doesn't grow across runs.
pub fn freeTestInstallJob(state: *State, io: std.Io) void {
    const job = state.test_install_job orelse return;
    const p = &job.payload;
    std.Io.Dir.cwd().deleteTree(io, p.scratch) catch {};
    p.steps_arena.deinit();
    job.alloc.free(p.archive_path);
    job.alloc.free(p.scratch);
    job.alloc.destroy(job);
    state.test_install_job = null;
}

fn humanBytesActions(buf: []u8, n: u64) []const u8 {
    const KB: f32 = 1024.0;
    const MB: f32 = 1024.0 * 1024.0;
    const GB: f32 = 1024.0 * 1024.0 * 1024.0;
    const f: f32 = @floatFromInt(n);
    if (f >= GB) return std.fmt.bufPrint(buf, "{d:.2} GB", .{f / GB}) catch "?";
    if (f >= MB) return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / MB}) catch "?";
    if (f >= KB) return std.fmt.bufPrint(buf, "{d:.1} KB", .{f / KB}) catch "?";
    return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
}

/// Resolve a modfile id to its archive's on-disk path. Caller owns
/// the returned slice (lib alloc). Returns null when the modfile
/// isn't in the per-game index. Used by the simulator and by the

pub fn doInstallMod(frame: *Frame, parent_game: *const library.Game, mod_recipe: *const recipe.ModRecipe) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    if (frame.mod_jobs.isModBusy(parent_game.f95_thread_id, mod_recipe.f95_thread)) {
        state.setDownloadMsg("This mod already has a job in flight.");
        return;
    }

    // 1. Archive must be registered.
    const archive_path_opt = mods_act.findRegisteredModArchive(frame, parent_game, mod_recipe);
    if (archive_path_opt == null) {
        state.setDownloadMsg("Click \"Add modfile…\" first — we don't auto-download mods.");
        return;
    }
    const archive_path = archive_path_opt.?;

    // 2. Resolver pre-flight (advisory — never enqueues anything).
    if (!preflightResolveMod(frame, parent_game, mod_recipe)) {
        alloc.free(archive_path);
        return;
    }

    // 3. Need a live install to apply against.
    const install_opt = mods_act.resolveModsPageInstall(frame, parent_game.f95_thread_id);
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const install = install_opt orelse {
        alloc.free(archive_path);
        state.setDownloadMsg("Install the base game before adding mods.");
        return;
    };

    // 4. Declared-file conflict scan — same modal flow as before. Done
    //    on the UI thread so the modal can open synchronously.
    const conflicts = detectAllModFileConflicts(frame, install.install_path, mod_recipe) catch &.{};
    defer freeConflictList(alloc, conflicts);
    if (conflicts.len > 0) {
        var overrides = loadOverrides(frame, install.install_path) catch OverrideList{ .pairs = &.{} };
        defer overrides.deinit(alloc);
        var unresolved: usize = 0;
        for (conflicts) |c| {
            if (!overrides.contains(mod_recipe.id, c.path)) unresolved += 1;
        }
        if (unresolved > 0) {
            openClashModal(frame, mod_recipe, install.install_path, conflicts);
            state.setDownloadMsg("File conflicts detected — review modal.");
            alloc.free(archive_path);
            return;
        }
    }

    // 5. Hand to the queue. Worker resolves game_root + tracker
    //    layout + runs apply. Backup policy comes from the game row
    //    (persisted via the Mods page dropdown), translated from the
    //    library enum to the installer enum.
    const installer_backup: installer_mod.BackupMode = switch (parent_game.mod_backup_mode) {
        .none => .none,
        .copy => .copy,
    };
    enqueueModJob(frame, .install, parent_game, mod_recipe, archive_path, install.id[0..], installer_backup) catch |e| {
        alloc.free(archive_path);
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Failed to enqueue: {s}", .{@errorName(e)}) catch "Failed to enqueue install";
        state.setDownloadMsg(msg);
    };
}

pub const UniversalInstallOutcome = enum { queued, busy, not_installed };

/// Enqueue a flat-overlay install of a universal mod's archive into one
/// game's current install. Universal mods have no `ModRecipe`, so we pass
/// a synthetic recipe id (`umod-<id>`) — the worker's `findMod` misses it
/// and falls through to `applyModArchive` (flat extract), and the tracker
/// keys on that slug so uninstall still works. A high-bit synthetic
/// mod-thread id keys the busy-dedup without colliding with real F95
/// thread ids. `archive_src` is COPIED (not consumed). Returns `.queued`,
/// `.busy` (a job already in flight), or `.not_installed` (no install to
/// apply against — universal mods can only go into an installed game).
pub fn enqueueUniversalModInstall(
    frame: *Frame,
    game: *const library.Game,
    mod_id: i64,
    mod_name: []const u8,
    archive_src: []const u8,
) !UniversalInstallOutcome {
    const alloc = frame.lib.alloc;
    const synth_thread: u64 = 0x8000_0000_0000_0000 | @as(u64, @intCast(@max(0, mod_id)));
    if (frame.mod_jobs.isModBusy(game.f95_thread_id, synth_thread)) return .busy;

    const install_opt = mods_act.resolveModsPageInstall(frame, game.f95_thread_id);
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const install = install_opt orelse return .not_installed;

    // Owned strings — enqueue takes ownership ONLY on success, so the
    // errdefers below free them on any failure before/at enqueue.
    const recipe_id = try std.fmt.allocPrint(alloc, "umod-{d}", .{mod_id});
    errdefer alloc.free(recipe_id);
    const display = try alloc.dupe(u8, mod_name);
    errdefer alloc.free(display);
    const archive_owned = try alloc.dupe(u8, archive_src);
    errdefer alloc.free(archive_owned);

    const backup: installer_mod.BackupMode = switch (game.mod_backup_mode) {
        .none => .none,
        .copy => .copy,
    };
    _ = try frame.mod_jobs.enqueue(.install, game.f95_thread_id, synth_thread, recipe_id, display, archive_owned, backup, install.id[0..]);
    return .queued;
}

/// Build a queue job from a UI click. Consumes `archive_path` on success
/// (transfers ownership to the Job); caller frees on failure.
fn enqueueModJob(
    frame: *Frame,
    kind: mod_job_queue.Kind,
    parent_game: *const library.Game,
    mod_recipe: *const recipe.ModRecipe,
    archive_path: ?[]u8,
    install_id: []const u8,
    backup_mode: installer_mod.BackupMode,
) !void {
    const alloc = frame.lib.alloc;
    const recipe_id_owned = try alloc.dupe(u8, mod_recipe.id);
    errdefer alloc.free(recipe_id_owned);

    var disp_buf: [256]u8 = undefined;
    const disp = std.fmt.bufPrint(&disp_buf, "{s} v{s}", .{ mod_recipe.name, mod_recipe.version }) catch mod_recipe.name;
    const display_owned = try alloc.dupe(u8, disp);
    errdefer alloc.free(display_owned);

    _ = try frame.mod_jobs.enqueue(
        kind,
        parent_game.f95_thread_id,
        mod_recipe.f95_thread,
        recipe_id_owned,
        display_owned,
        archive_path,
        backup_mode,
        install_id,
    );
}

// ============================================================
//  Clash detection — multi-conflict + persistent overrides
// ============================================================

/// Heap-owned list of conflicts. Same shape as `ModFileConflict` but
/// returned as a slice rather than the first hit only.
fn freeConflictList(alloc: std.mem.Allocator, list: []const ModFileConflictAll) void {
    for (list) |c| {
        alloc.free(c.path);
        alloc.free(c.with_mod_id);
    }
    if (list.len > 0) alloc.free(list);
}

fn detectAllModFileConflicts(
    frame: *Frame,
    install_dir: []const u8,
    mod_recipe: *const recipe.ModRecipe,
) ![]const ModFileConflictAll {
    if (mod_recipe.files.len == 0) return &.{};
    const alloc = frame.lib.alloc;

    const layout = mods_act.modTrackerLayout(frame.io, alloc, install_dir) catch return &.{};
    defer mods_act.freeModTrackerLayout(alloc, layout);

    var log_obj = installer_mod.Tracker.load(alloc, frame.io, layout.tracker_path) catch installer_mod.InstallLog{ .entries = &.{} };
    defer log_obj.deinit(alloc);

    var my_id_buf: [32]u8 = undefined;
    const my_id = std.fmt.bufPrint(&my_id_buf, "{d}", .{mod_recipe.f95_thread}) catch return &.{};

    var out: std.ArrayList(ModFileConflictAll) = .empty;
    errdefer freeConflictList(alloc, out.items);

    for (log_obj.entries) |e| {
        if (e.mod_id.len == 0) continue;
        if (std.mem.eql(u8, e.mod_id, my_id)) continue;
        for (mod_recipe.files) |f| {
            if (std.mem.eql(u8, e.path, f)) {
                const owned_path = try alloc.dupe(u8, e.path);
                errdefer alloc.free(owned_path);
                const owned_owner = try alloc.dupe(u8, e.mod_id);
                try out.append(alloc, .{ .path = owned_path, .with_mod_id = owned_owner });
            }
        }
    }
    return try out.toOwnedSlice(alloc);
}

/// Persistent file-clash overrides. JSON array of `{mod_id, path}` —
/// install consults this so the modal isn't re-raised forever.
const OverrideList = struct {
    pairs: []OverridePair,

    pub fn contains(self: *const OverrideList, recipe_id: []const u8, path: []const u8) bool {
        for (self.pairs) |p| {
            if (std.mem.eql(u8, p.recipe_id, recipe_id) and std.mem.eql(u8, p.path, path)) return true;
        }
        return false;
    }

    pub fn deinit(self: *OverrideList, alloc: std.mem.Allocator) void {
        for (self.pairs) |p| {
            alloc.free(p.recipe_id);
            alloc.free(p.path);
        }
        if (self.pairs.len > 0) alloc.free(self.pairs);
        self.* = undefined;
    }
};

const OverridePair = struct {
    recipe_id: []u8,
    path: []u8,
};

fn overridesPath(install_dir: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/.f69-overrides.json", .{install_dir});
}

fn loadOverrides(frame: *Frame, install_dir: []const u8) !OverrideList {
    const alloc = frame.lib.alloc;
    var pb: [768]u8 = undefined;
    const path = try overridesPath(install_dir, &pb);

    const bytes = std.Io.Dir.cwd().readFileAlloc(frame.io, path, alloc, .limited(1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return OverrideList{ .pairs = &.{} },
        else => return e,
    };
    defer alloc.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return OverrideList{ .pairs = &.{} };

    var out: std.ArrayList(OverridePair) = .empty;
    errdefer {
        for (out.items) |p| {
            alloc.free(p.recipe_id);
            alloc.free(p.path);
        }
        out.deinit(alloc);
    }

    for (parsed.value.array.items) |v| {
        if (v != .object) continue;
        const rid_v = v.object.get("recipe_id") orelse continue;
        const path_v = v.object.get("path") orelse continue;
        if (rid_v != .string or path_v != .string) continue;
        // Locals so a mid-struct OOM doesn't strand the first dupe.
        const rid_d = try alloc.dupe(u8, rid_v.string);
        errdefer alloc.free(rid_d);
        const path_d = try alloc.dupe(u8, path_v.string);
        errdefer alloc.free(path_d);
        try out.append(alloc, .{
            .recipe_id = rid_d,
            .path = path_d,
        });
    }
    return OverrideList{ .pairs = try out.toOwnedSlice(alloc) };
}

fn saveOverrides(frame: *Frame, install_dir: []const u8, list: []const OverridePair) !void {
    const alloc = frame.lib.alloc;
    var pb: [768]u8 = undefined;
    const path = try overridesPath(install_dir, &pb);

    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(alloc, 1024);
    defer aw.deinit();
    try aw.writer.writeAll("[");
    for (list, 0..) |p, i| {
        if (i > 0) try aw.writer.writeAll(",");
        // Recipe paths can contain `"`, `\`, etc. on POSIX; JSON-
        // escape both fields so reload doesn't choke.
        try aw.writer.writeAll("\n  {\"recipe_id\":");
        try writeJsonString(&aw.writer, p.recipe_id);
        try aw.writer.writeAll(",\"path\":");
        try writeJsonString(&aw.writer, p.path);
        try aw.writer.writeAll("}");
    }
    try aw.writer.writeAll("\n]\n");

    var tmp_buf: [832]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    var f = std.Io.Dir.cwd().createFile(frame.io, tmp, .{ .truncate = true }) catch return error.WriteFailed;
    defer f.close(frame.io);
    var fw_buf: [4096]u8 = undefined;
    var fw = f.writer(frame.io, &fw_buf);
    fw.interface.writeAll(aw.writer.buffered()) catch return error.WriteFailed;
    fw.interface.flush() catch return error.WriteFailed;
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, frame.io) catch return error.WriteFailed;
}

/// Write `s` as a JSON-quoted, escape-correct string. Recipe ids and
/// paths can contain `"`, `\`, etc. on POSIX; naïve printing into JSON
/// would corrupt `.f69-overrides.json` on reload.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// ============================================================
//  Clash modal — open / accept / cancel
// ============================================================

pub fn clashModalState(frame: *Frame) ?*ClashModalState {
    return frame.state.clash_modal;
}

fn openClashModal(
    frame: *Frame,
    mod_recipe: *const recipe.ModRecipe,
    install_dir: []const u8,
    conflicts: []const ModFileConflictAll,
) void {
    const alloc = frame.lib.alloc;
    closeClashModal(frame); // drop any prior modal

    // Build each owned resource as a local with its own errdefer so a
    // mid-construction OOM unwinds cleanly. Original openClashModal
    // used `catch unreachable` for inner dupes (panic on OOM) and
    // leaked earlier copies — both fixed here.
    const recipe_id = alloc.dupe(u8, mod_recipe.id) catch return;
    errdefer alloc.free(recipe_id);

    const install_dir_d = alloc.dupe(u8, install_dir) catch return;
    errdefer alloc.free(install_dir_d);

    const copies = alloc.alloc(ModFileConflictAll, conflicts.len) catch return;
    var filled: usize = 0;
    errdefer {
        for (copies[0..filled]) |c| {
            alloc.free(c.path);
            alloc.free(c.with_mod_id);
        }
        alloc.free(copies);
    }

    for (conflicts) |c| {
        const path_d = alloc.dupe(u8, c.path) catch return;
        const owner_d = alloc.dupe(u8, c.with_mod_id) catch {
            alloc.free(path_d);
            return;
        };
        copies[filled] = .{ .path = path_d, .with_mod_id = owner_d };
        filled += 1;
    }

    const m = alloc.create(ClashModalState) catch return;
    m.* = .{
        .recipe_id = recipe_id,
        .game_thread_id = mod_recipe.f95_thread,
        .install_dir = install_dir_d,
        .conflicts = copies,
    };
    frame.state.clash_modal = m;
}

pub fn closeClashModal(frame: *Frame) void {
    freeClashModalState(frame.state, frame.lib.alloc);
}

/// State-only variant used by the shutdown teardown path. Idempotent.
pub fn freeClashModalState(state: *State, alloc: std.mem.Allocator) void {
    if (state.clash_modal) |m| {
        freeConflictList(alloc, m.conflicts);
        alloc.free(m.recipe_id);
        alloc.free(m.install_dir);
        alloc.destroy(m);
        state.clash_modal = null;
    }
}

/// Append every active conflict to `.f69-overrides.json`, then close
/// the modal and re-invoke the install (which will now skip the
/// override-suppressed conflicts).
pub fn clashModalAcceptAll(frame: *Frame, parent_game: *const library.Game) void {
    const alloc = frame.lib.alloc;
    const state = frame.state;
    const m = clashModalState(frame) orelse return;

    var current = loadOverrides(frame, m.install_dir) catch OverrideList{ .pairs = &.{} };
    defer current.deinit(alloc);

    var next: std.ArrayList(OverridePair) = .empty;
    defer {
        for (next.items) |p| {
            alloc.free(p.recipe_id);
            alloc.free(p.path);
        }
        next.deinit(alloc);
    }
    for (current.pairs) |p| {
        const rid_d = alloc.dupe(u8, p.recipe_id) catch return;
        const path_d = alloc.dupe(u8, p.path) catch {
            alloc.free(rid_d);
            return;
        };
        next.append(alloc, .{ .recipe_id = rid_d, .path = path_d }) catch {
            alloc.free(rid_d);
            alloc.free(path_d);
            return;
        };
    }
    for (m.conflicts) |c| {
        if (current.contains(m.recipe_id, c.path)) continue;
        const rid_d = alloc.dupe(u8, m.recipe_id) catch return;
        const path_d = alloc.dupe(u8, c.path) catch {
            alloc.free(rid_d);
            return;
        };
        next.append(alloc, .{ .recipe_id = rid_d, .path = path_d }) catch {
            alloc.free(rid_d);
            alloc.free(path_d);
            return;
        };
    }

    saveOverrides(frame, m.install_dir, next.items) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Save overrides failed: {s}", .{@errorName(e)}) catch "Save overrides failed";
        state.setDownloadMsg(msg);
        return;
    };

    // Re-look-up the recipe so we can call doInstallMod with the right
    // pointer (lifetime is owned by recipe_repo).
    const recipe_id_owned = alloc.dupe(u8, m.recipe_id) catch return;
    defer alloc.free(recipe_id_owned);
    closeClashModal(frame);

    var parsed = frame.recipe_repo.findMod(recipe_id_owned) catch null orelse {
        state.setDownloadMsg("Recipe vanished — refusing to re-install.");
        return;
    };
    defer parsed.deinit();
    doInstallMod(frame, parent_game, &parsed.recipe);
}

pub const ModFileConflict = struct {
    path: []u8, // declared file that collides
    with_mod_id: []u8, // mod_id that currently owns that path
};

/// Scan every existing tracker entry under `install_dir` for a path
/// that's also listed in `mod_recipe.files`. Returns the first
/// collision whose `mod_id` differs from this mod's. Re-installs of
/// the same mod are NOT conflicts.
///
/// Allocator-owned strings; caller frees both fields.
pub fn detectModFileConflicts(
    frame: *Frame,
    install_dir: []const u8,
    mod_recipe: *const recipe.ModRecipe,
) ?ModFileConflict {
    if (mod_recipe.files.len == 0) return null;
    const alloc = frame.lib.alloc;

    const layout = mods_act.modTrackerLayout(frame.io, alloc, install_dir) catch return null;
    defer mods_act.freeModTrackerLayout(alloc, layout);

    var log_obj = installer_mod.Tracker.load(alloc, frame.io, layout.tracker_path) catch installer_mod.InstallLog{ .entries = &.{} };
    defer log_obj.deinit(alloc);

    var my_id_buf: [32]u8 = undefined;
    const my_id = std.fmt.bufPrint(&my_id_buf, "{d}", .{mod_recipe.f95_thread}) catch return null;

    for (log_obj.entries) |e| {
        if (e.mod_id.len == 0) continue;
        if (std.mem.eql(u8, e.mod_id, my_id)) continue;
        for (mod_recipe.files) |f| {
            if (std.mem.eql(u8, e.path, f)) {
                const owned_path = alloc.dupe(u8, e.path) catch return null;
                const owned_owner = alloc.dupe(u8, e.mod_id) catch {
                    alloc.free(owned_path);
                    return null;
                };
                return .{ .path = owned_path, .with_mod_id = owned_owner };
            }
        }
    }
    return null;
}

/// Resolver pre-flight. Never enqueues downloads — on a non-ok result
/// it just posts the explanation chain as a toast and returns false.
fn preflightResolveMod(
    frame: *Frame,
    parent_game: *const library.Game,
    mod_recipe: *const recipe.ModRecipe,
) bool {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    const mods = frame.recipe_repo.listModsForGame(mod_recipe.for_game) catch |e| {
        log.warn("install-mod: listModsForGame failed: {s}", .{@errorName(e)});
        return preflightSolveSingle(frame, parent_game, mod_recipe);
    };
    defer frame.recipe_repo.freeModList(mods);

    const inst_opt = frame.lib.latestInstallForGame(parent_game.f95_thread_id) catch null;
    defer if (inst_opt) |i| frame.lib.freeInstall(i);
    const game_version: []const u8 = if (inst_opt) |i| i.version else "";

    var avail: std.ArrayList(recipe.ModRecipe) = .empty;
    defer avail.deinit(alloc);
    avail.append(alloc, mod_recipe.*) catch {
        state.setDownloadMsg("Out of memory.");
        return false;
    };
    for (mods) |pm| {
        if (std.mem.eql(u8, pm.recipe.id, mod_recipe.id)) continue;
        avail.append(alloc, pm.recipe) catch {
            state.setDownloadMsg("Out of memory.");
            return false;
        };
    }

    const requested = [_]recipe.ModRecipe{mod_recipe.*};
    var result = resolver.solveExplained(alloc, .{
        .requested = &requested,
        .available = avail.items,
        .game_version = game_version,
    }) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Resolver failed: {s}", .{@errorName(e)}) catch "Resolver failed";
        state.setDownloadMsg(msg);
        return false;
    };
    defer result.deinit(alloc);
    return reportResolverResult(state, &result);
}

fn preflightSolveSingle(
    frame: *Frame,
    parent_game: *const library.Game,
    mod_recipe: *const recipe.ModRecipe,
) bool {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const inst_opt = frame.lib.latestInstallForGame(parent_game.f95_thread_id) catch null;
    defer if (inst_opt) |i| frame.lib.freeInstall(i);
    const game_version: []const u8 = if (inst_opt) |i| i.version else "";

    const one = [_]recipe.ModRecipe{mod_recipe.*};
    var result = resolver.solveExplained(alloc, .{
        .requested = &one,
        .available = &one,
        .game_version = game_version,
    }) catch return true; // best-effort; let install try
    defer result.deinit(alloc);
    return reportResolverResult(state, &result);
}

/// Translate a non-ok `SolveResult` into a toast + return false.
/// Returns true for the `.ok` arm so the caller can proceed.
fn reportResolverResult(state: *State, result: *const resolver.SolveResult) bool {
    switch (result.*) {
        .ok => return true,
        .missing => |m| {
            var chain_buf: [256]u8 = undefined;
            const chain = resolver.formatChain(&chain_buf, m.chain);
            var msg_buf: [384]u8 = undefined;
            const msg = if (m.constraint.len > 0)
                std.fmt.bufPrint(&msg_buf, "Can't install: missing dep \"{s}\" {s} (chain: {s})", .{ m.missing_id, m.constraint, chain }) catch "Can't install: missing dep."
            else
                std.fmt.bufPrint(&msg_buf, "Can't install: missing dep \"{s}\" (chain: {s})", .{ m.missing_id, chain }) catch "Can't install: missing dep.";
            state.pushToast(.err, msg);
            return false;
        },
        .version_mismatch => |v| {
            var chain_buf: [256]u8 = undefined;
            const chain = resolver.formatChain(&chain_buf, v.chain);
            var msg_buf: [384]u8 = undefined;
            const what: []const u8 = switch (v.source) {
                .for_game_version => "game",
                .requires_version => "dep",
            };
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "Can't install: {s} version {s} doesn't satisfy {s} (chain: {s})",
                .{ what, v.found_version, v.wanted_constraint, chain },
            ) catch "Can't install: version mismatch.";
            state.pushToast(.err, msg);
            return false;
        },
        .conflict => |c| {
            var chain_buf: [256]u8 = undefined;
            const chain = resolver.formatChain(&chain_buf, c.chain);
            var msg_buf: [384]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "Can't install: conflict between \"{s}\" and \"{s}\" (chain: {s})",
                .{ c.a, c.b, chain },
            ) catch "Can't install: conflict.";
            state.pushToast(.err, msg);
            return false;
        },
        .cycle => {
            state.pushToast(.err, "Can't install: load-order cycle in mod graph.");
            return false;
        },
    }
}

// ============================================================
//  post-download install — auto-extract on .done transition
// ============================================================

// `PostInstalledSet`, `AttemptsMap`, `owned_types.InstalledSet` aliased from
// `owned.zig` at the top of the file. `postInstalledSet` is defined
// at the top of this file (pub so downloads.zig can call it).

// ============================================================
//  async post-install (SHA verify + archive extract)
// ============================================================
//
// Why async: large F95 archives are 1–10 GB; the stdlib zip
// extractor can take a minute on these. Doing it inline on the UI
// thread froze the Downloads page for the duration. Now each
// terminal-.done game-job spawns a detached worker that pulls the
// file path from aria2, verifies the hash (when pinned), and runs
// the archive extractor. `drainPostInstall` (called every frame)
// picks up completed workers, does the `installs` DB upsert on the
// UI thread (SQLite isn't multi-thread-write-safe at the app
// layer), and frees the job allocation.

fn postInstallJobsList(frame: *Frame) ?*PostInstallJobsList {
    if (frame.state.post_install_jobs) |list_ptr| return list_ptr;
    const list_ptr = frame.lib.alloc.create(PostInstallJobsList) catch return null;
    list_ptr.* = .empty;
    frame.state.post_install_jobs = list_ptr;
    return list_ptr;
}

pub fn freePostInstallJobs(state: *State, alloc: std.mem.Allocator) void {
    if (state.post_install_jobs) |list_ptr| {
        // Detached workers can't be joined here — graceful shutdown
        // either waits them out via workersBusy/drainPostInstall or
        // hard-exits via std.process.exit(0), which reclaims memory.
        // Any leftover entries we drop are leaked; that's fine on
        // process exit.
        list_ptr.deinit(alloc);
        alloc.destroy(list_ptr);
        state.post_install_jobs = null;
    }
}

/// What the post-install worker of download job `download_job_id` is
/// doing right now (bytes moved, or files applied for a mod); a zero
/// `LiveInstall` when none runs.
pub fn liveInstall(frame: *Frame, download_job_id: u64) dl_rows.LiveInstall {
    if (frame.state.post_install_jobs == null) return .{};
    const list = postInstallJobsList(frame) orelse return .{};
    for (list.items) |pij| {
        if (pij.payload.download_job_id != download_job_id) continue;
        if (pij.phaseGet() != .pending) return .{};
        const p = pij.payload.prog.get();
        return .{ .running = true, .done = p.done, .total = p.total, .files = pij.payload.prog_files };
    }
    return .{};
}

/// One row in the per-game "downloaded versions, ready to install"
/// list rendered as a dropdown next to the Install button. Owns a copy
/// of the version (the snapshot it came from is released before use).
pub const DownloadedEntry = struct {
    job_id: u64,
    version_buf: [64]u8 = undefined,
    version_len: u8 = 0,
    /// Kept for the detail screen's call shape; the downloader verifies.
    expected_sha256: ?[32]u8 = null,

    /// `""` when the job didn't capture a version. The UI labels it
    /// "unknown version".
    pub fn version(self: *const DownloadedEntry) []const u8 {
        return self.version_buf[0..self.version_len];
    }
};

/// Build the list of "downloaded but not installed" entries for this
/// thread from the downloader snapshot, written into `buf`: finished
/// jobs (done / seeding) whose version has no `installs` row, and jobs
/// whose install step failed. Returns the populated prefix (capped at
/// `buf.len`).
pub fn listDownloadedNotInstalled(
    frame: *Frame,
    thread_id: u64,
    buf: []DownloadedEntry,
) []DownloadedEntry {
    if (isInstallingForGame(frame, thread_id)) return buf[0..0];
    var n: usize = 0;
    {
        const snap = frame.dl.snapshot();
        defer frame.dl.releaseSnapshot();
        for (snap.jobs) |v| {
            if (n >= buf.len) break;
            const j = &v.job;
            if (j.game_thread_id != thread_id or j.kind != .game) continue;
            const ready = switch (j.step) {
                .done, .seeding => true,
                .failed => j.fail == .install_failed,
                else => false,
            };
            if (!ready) continue;
            const ver = j.version orelse "";
            const len: u8 = @intCast(@min(ver.len, 64));
            buf[n] = .{ .job_id = j.id, .version_len = len, .expected_sha256 = j.expected_sha256 };
            @memcpy(buf[n].version_buf[0..len], ver[0..len]);
            n += 1;
        }
    }
    // Existing installs (DB read, after the snapshot is released) hide
    // versions the user already has, so the dropdown only offers new
    // builds. Versions compare with `version_mod.equivalent` ("21.0" ≡
    // "21.0.0").
    const installs = frame.lib.listInstalls(thread_id) catch &[_]library.Install{};
    defer frame.lib.freeInstalls(@constCast(installs));
    var kept: usize = 0;
    for (buf[0..n]) |e| {
        const ver = e.version();
        var already = false;
        for (installs) |inst| {
            if (ver.len > 0 and version_mod.equivalent(inst.version, ver)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        buf[kept] = e;
        kept += 1;
    }
    return buf[0..kept];
}

/// Install a downloaded job again (the detail page's Install button):
/// the downloader re-runs extract (an existing folder is registered as
/// is) and raises `install_ready`, which lands in `installFromArchive`.
pub fn startInstallFromDownloadJob(
    frame: *Frame,
    thread_id: u64,
    job_id: u64,
    expected_sha256: ?[32]u8,
) void {
    _ = expected_sha256;
    const state = frame.state;
    if (isInstallingForGame(frame, thread_id)) {
        state.setDownloadMsg("install already running for this game");
        return;
    }
    frame.dl.send(.{ .retry_install = job_id });
    state.setDownloadMsg("install started");
}

/// True iff a post-install worker is currently extracting an archive
/// for this F95 thread id. Detail page uses this to render an
/// "Installing…" progress strip; the strip disappears as soon as
/// `drainPostInstall` clears the worker entry.
pub fn isInstallingForGame(frame: *Frame, thread_id: u64) bool {
    if (frame.state.post_install_jobs) |list| {
        for (list.items) |pij| {
            if (pij.payload.game_id != thread_id) continue;
            if (pij.phaseGet() == .pending) return true;
        }
    }
    if (frame.state.manual_install_jobs) |list| {
        for (list.items) |job| {
            if (job.payload.game_id != thread_id) continue;
            if (job.phaseGet() == .pending) return true;
        }
    }
    return false;
}

/// What an in-flight install of this thread is doing, with its measured
/// progress (`total` 0 = nothing to measure yet). Null when no install
/// worker runs for the game.
pub const InstallActivity = struct {
    /// "checking the file" / "extracting the archive" / "moving the file
    /// into the library" / "applying the mod".
    verb: []const u8,
    done: u64,
    total: u64,
    /// `done`/`total` count files (a mod apply) rather than bytes.
    files: bool,

    pub fn pct(self: InstallActivity) ?u8 {
        if (self.total == 0) return null;
        return downloads.progress.percent(self.done, self.total);
    }
};

pub fn installActivityForGame(frame: *Frame, thread_id: u64) ?InstallActivity {
    if (frame.state.post_install_jobs) |list| {
        for (list.items) |pij| {
            if (pij.payload.game_id != thread_id) continue;
            if (pij.phaseGet() != .pending) continue;
            const p = pij.payload.prog.get();
            return .{
                .verb = if (pij.payload.mode == .apply_mod) "applying the mod" else "moving the file into the library",
                .done = p.done,
                .total = p.total,
                .files = pij.payload.prog_files,
            };
        }
    }
    if (frame.state.manual_install_jobs) |list| {
        for (list.items) |job| {
            if (job.payload.game_id != thread_id) continue;
            if (job.phaseGet() != .pending) continue;
            const p = job.payload.prog.get();
            return .{
                .verb = if (job.payload.phase.load(.acquire) == 0) "checking the file" else "extracting the archive",
                .done = p.done,
                .total = p.total,
                .files = false,
            };
        }
    }
    return null;
}

test "InstallActivity.pct: null without a total" {
    const a: InstallActivity = .{ .verb = "x", .done = 3, .total = 0, .files = false };
    try std.testing.expect(a.pct() == null);
    const b: InstallActivity = .{ .verb = "x", .done = 3, .total = 4, .files = true };
    try std.testing.expectEqual(@as(?u8, 75), b.pct());
}

/// True iff any post-install worker is in flight. Cheap state-only
/// probe (no allocator touch) used by the main loop to decide
/// whether to keep re-rendering for the animated "Installing…"
/// strip on the detail page.
pub fn anyPostInstallActive(state: *const State) bool {
    const list_ptr = state.post_install_jobs orelse return false;
    return list_ptr.items.len > 0;
}

/// True iff a manual (pick-an-archive) install worker is in flight.
pub fn anyManualInstallActive(state: *const State) bool {
    const list_ptr = state.manual_install_jobs orelse return false;
    return list_ptr.items.len > 0;
}

/// True iff a Mods-page install/uninstall is queued or running (the
/// Downloads page "Modding" section animates while one does).
pub fn anyModJobActive(frame: *Frame) bool {
    frame.mod_jobs.lock();
    defer frame.mod_jobs.unlock();
    for (frame.mod_jobs.jobsLocked()) |j| {
        const p = j.currentPhase();
        if (p != .done and p != .err and p != .canceled) return true;
    }
    return false;
}

/// Resolve the version string recorded on the install row. Priority:
///   1. The version captured on the job at enqueue time (the RPDL title
///      version, or the F95 scrape for donor DDL) — "the build the user
///      actually downloaded". Junk values ("0", blank) are skipped.
///   2. The recipe's version (if a recipe exists for this thread).
///   3. The F95-scraped `latest_version` of the library row.
///   4. "unversioned".
/// Returns owned slices; `have_recipe` reports whether a recipe matched.
fn resolveInstallVersion(frame: *Frame, game_id: u64, job_version: ?[]const u8) !struct { version: []u8, recipe_id: []u8, have_recipe: bool } {
    const alloc = frame.lib.alloc;
    var version_str: []u8 = try alloc.dupe(u8, "unversioned");
    errdefer alloc.free(version_str);
    var recipe_id: []u8 = try alloc.dupe(u8, "");
    errdefer alloc.free(recipe_id);
    var have_recipe = false;
    if (frame.recipe_repo.findGameByThread(game_id) catch null) |maybe| {
        var pp = maybe;
        defer pp.deinit();
        alloc.free(version_str);
        version_str = try alloc.dupe(u8, pp.recipe.version);
        alloc.free(recipe_id);
        recipe_id = try alloc.dupe(u8, pp.recipe.id);
        have_recipe = true;
    }
    if (job_version) |v| {
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "0")) {
            alloc.free(version_str);
            version_str = try alloc.dupe(u8, trimmed);
        }
    }
    if (std.mem.eql(u8, version_str, "unversioned")) {
        for (frame.games) |*gg| {
            if (gg.f95_thread_id != game_id) continue;
            if (gg.latest_version) |v| {
                const trimmed = std.mem.trim(u8, v, " \t\r\n");
                if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "0")) {
                    alloc.free(version_str);
                    version_str = try alloc.dupe(u8, trimmed);
                }
            }
            break;
        }
    }
    return .{ .version = version_str, .recipe_id = recipe_id, .have_recipe = have_recipe };
}

/// One path segment from a version string (same rule as the
/// downloader's extract folder): path separators and reserved
/// characters become `_`; empty / dot-only → "unversioned".
fn versionSegment(buf: []u8, v: []const u8) []const u8 {
    const n = @min(v.len, buf.len);
    var all_dots = true;
    for (v[0..n], buf[0..n]) |c, *o| {
        o.* = switch (c) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|' => '_',
            else => if (c < 0x20) '_' else c,
        };
        if (c != '.' and c != ' ') all_dots = false;
    }
    if (n == 0 or all_dots) return "unversioned";
    return buf[0..n];
}

fn trimTrailingSep(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and (p[end - 1] == '/' or p[end - 1] == '\\')) end -= 1;
    return p[0..end];
}

/// Tell the downloader the install for `job_id` failed.
fn sendInstallFailed(frame: *Frame, job_id: u64, msg: []const u8) void {
    frame.dl.send(.{ .install_failed = .{ .job_id = job_id, .msg = msg } });
}

/// Handle the downloader's `install_ready` event. The downloader has
/// already verified and (for game archives) extracted, so no archive
/// work happens here:
///   - game, `extracted_dir` set → register that folder (install row,
///     installed-set refresh, auto-convert, diagnostics), ack at once;
///   - game, `extracted_dir == null` (not an archive) → a worker moves
///     the file into `<library_root>/<tid>/<version>/`; the drain
///     registers that folder and acks;
///   - mod → a worker applies the archive onto the game's latest
///     install; the drain acks.
/// Any failure is reported with `install_failed`. `ev` is borrowed:
/// everything kept is copied.
pub fn installFromArchive(frame: *Frame, ev: downloads.downloader.InstallReady) void {
    installFromArchiveInner(frame, ev) catch |e| {
        log.warn("install for download {d} failed to start: {s}", .{ ev.job_id, @errorName(e) });
        var buf: [96]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "Install could not start: {s}", .{@errorName(e)}) catch "Install could not start";
        sendInstallFailed(frame, ev.job_id, m);
        frame.state.setDownloadMsg(m);
    };
}

fn installFromArchiveInner(frame: *Frame, ev: downloads.downloader.InstallReady) !void {
    const alloc = frame.lib.alloc;
    const source_kind: library.InstallSource = if (ev.source_is_rpdl) .rpdl else .recipe;

    if (ev.kind == .mod) {
        const mod_id = ev.mod_id orelse return error.NoModId;
        // Latest install of the parent game is where the mod applies.
        const install = (frame.lib.latestInstallForGame(ev.game_thread_id) catch null) orelse return error.GameNotInstalled;
        defer frame.lib.freeInstall(install);
        const file_path = try alloc.dupe(u8, ev.archive_path);
        errdefer alloc.free(file_path);
        const dest_dir = try alloc.dupe(u8, install.install_path);
        errdefer alloc.free(dest_dir);
        try spawnPostInstall(frame, .{
            .io = frame.io,
            .download_job_id = ev.job_id,
            .game_id = ev.game_thread_id,
            .mode = .apply_mod,
            .mod_id = mod_id,
            .file_path = file_path,
            .dest_dir = dest_dir,
            .version = try alloc.dupe(u8, ""),
            .recipe_id = try alloc.dupe(u8, ""),
            .have_recipe = false,
            .expected_sha256 = null,
            .source = source_kind,
        });
        return;
    }

    const rv = try resolveInstallVersion(frame, ev.game_thread_id, ev.version);
    log.info("install: download {d} tid={d} → version '{s}'", .{ ev.job_id, ev.game_thread_id, rv.version });

    if (ev.extracted_dir) |dir| {
        defer alloc.free(rv.version);
        defer alloc.free(rv.recipe_id);
        // An error here goes to `installFromArchive`, which reports
        // `install_failed`; the ack is only sent on success.
        try finishGameInstall(frame, ev.game_thread_id, rv.version, trimTrailingSep(dir), rv.recipe_id, source_kind);
        frame.dl.send(.{ .install_ack = ev.job_id });
        return;
    }

    // Not an archive: move the file into its own versioned folder on a
    // worker (the library may be on a slow FUSE mount).
    errdefer alloc.free(rv.version);
    errdefer alloc.free(rv.recipe_id);
    var seg_buf: [128]u8 = undefined;
    const seg = versionSegment(&seg_buf, ev.version orelse rv.version);
    const dest_dir = try std.fmt.allocPrint(alloc, "{s}" ++ std.fs.path.sep_str ++ "{d}" ++ std.fs.path.sep_str ++ "{s}", .{ frame.info.library_root, ev.game_thread_id, seg });
    errdefer alloc.free(dest_dir);
    const file_path = try alloc.dupe(u8, ev.archive_path);
    errdefer alloc.free(file_path);
    try spawnPostInstall(frame, .{
        .io = frame.io,
        .download_job_id = ev.job_id,
        .game_id = ev.game_thread_id,
        .mode = .move_file,
        .file_path = file_path,
        .dest_dir = dest_dir,
        .version = rv.version,
        .recipe_id = rv.recipe_id,
        .have_recipe = rv.have_recipe,
        .expected_sha256 = ev.expected_sha256,
        .source = source_kind,
    });
}

/// Spawn the post-install worker. Takes ownership of the payload's
/// strings on success; on error the caller still owns them.
fn spawnPostInstall(frame: *Frame, payload: PostInstallPayload) !void {
    const alloc = frame.lib.alloc;
    const list = postInstallJobsList(frame) orelse return error.OutOfMemory;
    try list.ensureUnusedCapacity(alloc, 1);
    var slot: ?*PostInstallJob = null;
    const pij = try job_mod.spawnJob(PostInstallPayload, postInstallWorker, alloc, frame.win, payload, &slot);
    list.appendAssumeCapacity(pij);
    log.info("post-install download {d}: {s} worker spawned", .{ payload.download_job_id, @tagName(payload.mode) });
}

/// Install row + installed-set refresh + optional auto-convert +
/// post-install diagnostics for a finished game folder. UI thread.
/// Fails (and does nothing else) when the install row cannot be written.
fn finishGameInstall(
    frame: *Frame,
    game_id: u64,
    version_str: []const u8,
    dest_dir: []const u8,
    recipe_id: []const u8,
    source: library.InstallSource,
) !void {
    // Always write the install row — even raw-paste / no-recipe installs
    // deserve an entry so they land in the detail-page dropdown.
    try doInstallUpsert(frame, game_id, version_str, dest_dir, recipe_id, source);
    // Refresh the per-frame install-set snapshot so the InstallDot +
    // detail page flip green immediately.
    common.refreshInstalledSet(frame);
    // Auto-convert hook (user opt-in).
    if (frame.state.auto_convert) maybeAutoConvert(frame, game_id, dest_dir);
    // Walk the folder for a Linux launcher and run the pre-launch checks;
    // an actionable issue opens the launch-issue dialog before Launch.
    runPostInstallDiagnostics(frame, game_id, dest_dir);
}

/// Move `src` into `dest_dir` (created). Rename first; a cross-volume
/// move (downloads and library on different drives) falls back to copy
/// + delete. `sink` gets (bytes moved, file size): one report after a
/// rename, one per chunk while copying.
fn moveFileInto(io: std.Io, src: []const u8, dest_dir: []const u8, sink: downloads.progress.Sink) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dest_dir);
    const size: u64 = if (cwd.statFile(io, src, .{})) |st| st.size else |_| 0;
    sink.report(0, size);
    var buf: [1024]u8 = undefined;
    const dst = try std.fmt.bufPrint(&buf, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ dest_dir, std.fs.path.basename(src) });
    cwd.rename(src, cwd, dst, io) catch |e| switch (e) {
        error.FileNotFound => return e,
        else => {
            log.info("rename '{s}' failed ({s}); copying instead", .{ src, @errorName(e) });
            try common.copyFileProgress(io, src, dst, sink);
            cwd.deleteFile(io, src) catch |de| log.warn("could not delete '{s}' after copy: {s}", .{ src, @errorName(de) });
        },
    };
    sink.report(size, size);
}

/// `applyModArchive` progress (files applied / files in the mod) → the
/// payload's counters.
fn postInstallModProgress(ctx: ?*anyopaque, done: u32, total: u32) void {
    const job: *PostInstallJob = @ptrCast(@alignCast(ctx orelse return));
    job.payload.prog.sink().report(done, total);
}

fn postInstallWorker(job: *PostInstallJob) void {
    const p = &job.payload;
    switch (p.mode) {
        .move_file => {
            moveFileInto(p.io, p.file_path, p.dest_dir, p.prog.sink()) catch |e| {
                log.warn("post-install download {d}: moving {s} failed: {s}", .{ p.download_job_id, p.file_path, @errorName(e) });
                p.err_name = @errorName(e);
                job.markFailed();
                return;
            };
        },
        .apply_mod => {
            applyModWorker(job) catch |e| {
                log.warn("post-install mod download {d}: apply failed: {s}", .{ p.download_job_id, @errorName(e) });
                p.err_name = @errorName(e);
                job.markFailed();
                return;
            };
        },
    }
    job.markDone();
}

/// Apply a downloaded mod archive onto the game install at `dest_dir`.
/// The tracker lives at `<game_root>/.f69-mods.json` — the same place
/// `doInstallMod` writes — so the Mods page sees the result.
fn applyModWorker(job: *PostInstallJob) !void {
    const p = &job.payload;
    const alloc = job.alloc;
    const layout = try mods_act.modTrackerLayout(p.io, alloc, p.dest_dir);
    defer mods_act.freeModTrackerLayout(alloc, layout);
    var tracker = installer_mod.Tracker.init(alloc, p.io, layout.tracker_path);
    defer tracker.deinit();
    // Re-load existing entries so the flush rewrites the full file.
    var existing = installer_mod.Tracker.load(alloc, p.io, layout.tracker_path) catch installer_mod.InstallLog{ .entries = &.{} };
    defer existing.deinit(alloc);
    for (existing.entries) |e| tracker.record(e) catch {};
    var mod_id_buf: [32]u8 = undefined;
    const mod_id_str = try std.fmt.bufPrint(&mod_id_buf, "{d}", .{p.mod_id});
    log.info("post-install mod download {d}: applying {s} → {s}", .{ p.download_job_id, p.file_path, layout.game_root });
    try installer_mod.applyModArchive(alloc, p.io, mod_id_str, p.file_path, layout.game_root, &tracker, .{
        .progress_cb = postInstallModProgress,
        .progress_ctx = job,
    });
}

/// Each guiFrame: collect finished post-install workers. A finished
/// file move writes the install row (UI thread — SQLite isn't multi-
/// thread-safe at the app layer); then the downloader gets
/// `install_ack`, or `install_failed` when the worker failed.
pub fn drainPostInstall(frame: *Frame) void {
    if (frame.state.post_install_jobs == null) return;
    const list = postInstallJobsList(frame) orelse return;

    var i: usize = 0;
    while (i < list.items.len) {
        const pij = list.items[i];
        const phase = pij.phaseGet();
        if (phase == .pending) {
            i += 1;
            continue;
        }
        const p = &pij.payload;
        if (phase == .done) {
            const registered = if (p.mode == .move_file)
                finishGameInstall(frame, p.game_id, p.version, p.dest_dir, p.recipe_id, p.source)
            else {};
            if (registered) |_| {
                frame.dl.send(.{ .install_ack = p.download_job_id });
            } else |e| {
                var buf: [96]u8 = undefined;
                const m = std.fmt.bufPrint(&buf, "Install failed: could not save the install ({s})", .{@errorName(e)}) catch "Install failed";
                sendInstallFailed(frame, p.download_job_id, m);
                frame.state.setDownloadMsg(m);
            }
        } else if (phase == .failed) {
            log.warn("post-install download {d}: worker failed ({s})", .{ p.download_job_id, p.err_name orelse "?" });
            var buf: [96]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "Install failed: {s}", .{p.err_name orelse "cancelled"}) catch "Install failed";
            sendInstallFailed(frame, p.download_job_id, m);
            frame.state.setDownloadMsg(m);
        }
        pij.alloc.free(p.file_path);
        pij.alloc.free(p.dest_dir);
        pij.alloc.free(p.version);
        pij.alloc.free(p.recipe_id);
        pij.alloc.destroy(pij);
        _ = list.swapRemove(i);
        // Don't bump i — swapRemove may have moved a fresh entry
        // into this slot that still needs checking.
    }
}

/// Post-install diagnostics — finds a Linux launcher under the
/// freshly-extracted install dir and runs the same static checks
/// the pre-launch path uses. If anything actionable is detected the
/// launch diag popup auto-opens so the user sees the issue (and any
/// available fix) before they click Launch the first time.
///
/// No-op when no Linux launcher exists yet (Windows-only build, or
/// the user installed without Convert and there's nothing to check).
fn runPostInstallDiagnostics(frame: *Frame, game_id: u64, install_dir: []const u8) void {
    const alloc = frame.lib.alloc;
    var exe_buf: [512]u8 = undefined;
    const launcher = launch_act.findLinuxLauncher(frame.io, alloc, install_dir, &exe_buf) orelse return;
    if (launch_act.runPreLaunchDiagnostics(alloc, frame.io, launcher)) |diag| {
        defer alloc.free(diag.summary);
        defer alloc.free(diag.log);
        log.info(
            "post-install diagnostics tid={d}: {s}",
            .{ game_id, diag.summary },
        );
        launch_act.stashLaunchDiagPub(frame.state, game_id, diag);
    }
}

/// Called after a fresh post-install if `state.auto_convert` is on.
/// Looks up the recipe, builds a ConvertSpec, and runs Convert in
/// place. Surfaces failures via `state.setConvertMsg` — most
/// commonly "no recipe — Convert needs a recipe with convert_linux"
/// when the user has the toggle on but the game has no recipe.
fn maybeAutoConvert(frame: *Frame, game_id: u64, install_dir: []const u8) void {
    const state = frame.state;
    const conv_spec = mods_act.resolveConvertSpec(frame, install_dir);
    if (conv_spec == .none) {
        state.setConvertMsg("Auto-convert skipped: engine not detected, or game is already Linux-native.");
        return;
    }
    log.info("auto-convert: tid={d} engine={s} → {s}", .{ game_id, @tagName(conv_spec), install_dir });
    frame.convert_svc.convert(install_dir, conv_spec, false, .none) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Auto-convert failed: {s}", .{@errorName(e)}) catch "Auto-convert failed";
        state.setConvertMsg(msg);
        return;
    };

    // Chain auto-apply-compat when the toggle is on. Same rationale
    // as the manual Convert button: the very next thing the user
    // will try after a successful Convert is Launch, and Launch
    // typically needs the compat env. Folding it into the post-install
    // pipeline avoids the "Launch → fail → click Fix → Launch" loop.
    var compat_tail: []const u8 = "";
    var compat_buf: [128]u8 = undefined;
    if (state.auto_apply_compat) {
        if (frame.lib.latestInstallForGame(game_id) catch null) |inst| {
            defer frame.lib.freeInstall(inst);
            const res = launch_act.autoApplyCompatAfterConvert(frame, &inst.id, install_dir);
            if (res.applied + res.reapplied + res.failed > 0) {
                compat_tail = std.fmt.bufPrint(
                    &compat_buf,
                    " Compat: {d} applied, {d} re-applied, {d} failed.",
                    .{ res.applied, res.reapplied, res.failed },
                ) catch "";
            }
        }
    }

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Auto-convert: done.{s}", .{compat_tail}) catch "Auto-convert: done.";
    state.setConvertMsg(msg);
}

fn doInstallUpsert(
    frame: *Frame,
    game_id: u64,
    version_str: []const u8,
    dest_dir: []const u8,
    recipe_id: []const u8,
    source: library.InstallSource,
) !void {
    var id_buf: [36]u8 = undefined;
    generateUuid(frame.io, &id_buf);
    const now = std.Io.Clock.Timestamp.now(frame.io, .real);
    const now_s: i64 = @intCast(@divTrunc(now.raw.toNanoseconds(), 1_000_000_000));
    frame.lib.upsertInstall(&.{
        .id = id_buf,
        .game_thread_id = game_id,
        .version = version_str,
        .install_path = dest_dir,
        .recipe_id = recipe_id,
        .installed_at = now_s,
        .source = source,
    }) catch |e| {
        log.warn("installs row for game {d} failed: {s}", .{ game_id, @errorName(e) });
        return e;
    };
}


// ============================================================
//  manual install (user-supplied archive)
// ============================================================
//
// Mirror of the post-install pipeline but with two differences:
//   - SHA-256 is *computed* during extract, not verified — there's
//     no expected hash for a hand-picked archive.
//   - The Install row carries `source = .manual`, an optional user
//     `name`, and the computed `archive_sha256`. Lets the picker
//     show provenance and disambiguate two installs of the same
//     version.

// ManualInstall uses the canonical `Job.Phase` from `src/ui/job.zig`.

fn manualInstallJobsList(frame: *Frame) ?*ManualInstallJobsList {
    if (frame.state.manual_install_jobs) |list_ptr| return list_ptr;
    const list_ptr = frame.lib.alloc.create(ManualInstallJobsList) catch return null;
    list_ptr.* = .empty;
    frame.state.manual_install_jobs = list_ptr;
    return list_ptr;
}

pub fn freeManualInstallJobs(state: *State, alloc: std.mem.Allocator) void {
    if (state.manual_install_jobs) |list_ptr| {
        list_ptr.deinit(alloc);
        alloc.destroy(list_ptr);
        state.manual_install_jobs = null;
    }
}

/// True iff at least one manual-install worker is still extracting.
/// `workersBusy` consults this so shutdown drains them before tearing
/// down `init.io`.
pub fn manualInstallsRunning(state: *const State) bool {
    if (state.manual_install_jobs) |list_ptr| {
        return list_ptr.items.len > 0;
    }
    return false;
}

/// Validate inputs, choose a destination directory that doesn't
/// collide on disk, and spawn the worker thread. Writes a short
/// status line via `setDownloadMsg` either way — this slot already
/// houses the per-game "install in flight" channel.
pub fn startManualInstall(
    frame: *Frame,
    game_id: u64,
    file_path_in: []const u8,
    version_in: []const u8,
    name_in: []const u8,
) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // ---- input sanity ----
    const file_path_trim = std.mem.trim(u8, file_path_in, " \t\r\n");
    if (file_path_trim.len == 0) {
        state.setDownloadMsg("Pick an archive file first.");
        return;
    }
    const version_trim = std.mem.trim(u8, version_in, " \t\r\n");
    if (version_trim.len == 0) {
        state.setDownloadMsg("Version is required — type it in or accept the suggestion.");
        return;
    }
    const name_trim = std.mem.trim(u8, name_in, " \t\r\n");

    // Format must be one of the supported archive types. RAR + bz2/xz
    // aren't wired up yet; rejecting up-front beats a worker that
    // fails halfway through.
    const fmt = downloads.detectFormat(file_path_trim);
    if (fmt == .unknown) {
        state.setDownloadMsg("Archive type not recognised (expected .zip / .7z / .tar.gz / .rar).");
        return;
    }

    std.Io.Dir.cwd().access(frame.io, file_path_trim, .{}) catch {
        state.setDownloadMsg("That file doesn't exist or isn't readable.");
        return;
    };

    // ---- destination path ----
    // `<library_root>/<tid>/<version-slug>/`. When the slug collides
    // (a prior install of the same version) we suffix `-2`, `-3`, …
    // up to a small cap so the unique-path constraint never bites.
    var slug_buf: [128]u8 = undefined;
    const slug = slugify(&slug_buf, version_trim) orelse {
        state.setDownloadMsg("Version string normalised to empty — pick a different value.");
        return;
    };
    var dest_buf: [768]u8 = undefined;
    var attempt: u32 = 1;
    const dest_dir_local: []const u8 = while (attempt <= 20) : (attempt += 1) {
        const candidate = if (attempt == 1)
            std.fmt.bufPrint(&dest_buf, "{s}/{d}/{s}", .{ frame.info.library_root, game_id, slug }) catch {
                state.setDownloadMsg("Destination path too long.");
                return;
            }
        else
            std.fmt.bufPrint(&dest_buf, "{s}/{d}/{s}-{d}", .{ frame.info.library_root, game_id, slug, attempt }) catch {
                state.setDownloadMsg("Destination path too long.");
                return;
            };
        if (!dirNonEmpty(frame.io, candidate)) break candidate;
    } else {
        state.setDownloadMsg("Too many existing installs at this version — clean up before adding another.");
        return;
    };

    // ---- own every input string so the worker outlives this frame ----
    const file_path_owned = alloc.dupe(u8, file_path_trim) catch {
        state.setDownloadMsg("Out of memory.");
        return;
    };
    errdefer alloc.free(file_path_owned);
    const dest_dir_owned = alloc.dupe(u8, dest_dir_local) catch {
        state.setDownloadMsg("Out of memory.");
        return;
    };
    errdefer alloc.free(dest_dir_owned);
    const version_owned = alloc.dupe(u8, version_trim) catch {
        state.setDownloadMsg("Out of memory.");
        return;
    };
    errdefer alloc.free(version_owned);
    var name_owned: ?[]u8 = null;
    if (name_trim.len > 0) {
        name_owned = alloc.dupe(u8, name_trim) catch {
            state.setDownloadMsg("Out of memory.");
            return;
        };
    }
    errdefer if (name_owned) |s| alloc.free(s);

    const list = manualInstallJobsList(frame) orelse {
        alloc.free(file_path_owned);
        alloc.free(dest_dir_owned);
        alloc.free(version_owned);
        if (name_owned) |s| alloc.free(s);
        state.setDownloadMsg("Out of memory.");
        return;
    };
    var slot: ?*ManualInstallJob = null;
    const job = job_mod.spawnJob(
        ManualInstallPayload,
        manualInstallWorker,
        alloc,
        frame.win,
        .{
            .io = frame.io,
            .game_id = game_id,
            .file_path = file_path_owned,
            .dest_dir = dest_dir_owned,
            .version = version_owned,
            .name = name_owned,
        },
        &slot,
    ) catch |e| {
        alloc.free(file_path_owned);
        alloc.free(dest_dir_owned);
        alloc.free(version_owned);
        if (name_owned) |s| alloc.free(s);
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Spawn failed: {s}", .{@errorName(e)}) catch "Spawn failed";
        state.setDownloadMsg(msg);
        return;
    };
    list.append(alloc, job) catch {
        // Worker is already running — request cancel and let the
        // next drain reap it. The carrier still gets cleaned up via
        // drainBackgroundJob's free path when phase flips terminal.
        job.requestCancel();
        state.setDownloadMsg("Out of memory.");
        return;
    };
    state.setDownloadMsg("Manual install: hashing + extracting…");
    log.info("manual-install: tid={d} src='{s}' dest='{s}' v='{s}'", .{ game_id, file_path_owned, dest_dir_owned, version_owned });
}

fn manualInstallWorker(job: *ManualInstallJob) void {
    const p = &job.payload;
    const fail = struct {
        fn run(j: *ManualInstallJob, name: []const u8) void {
            j.payload.err_name = name;
            j.markFailed();
        }
    }.run;

    // ---- hash ----
    // Stream the archive through SHA-256 before extract. Cheap on top
    // of the disk read we'd do anyway, and the result lets the
    // diagnostics page identify the file later if the user re-picks
    // a renamed copy. Progress: bytes hashed / file size.
    p.phase.store(0, .release);
    const sha_bytes = downloads.hashFile(p.io, p.file_path, p.prog.sink()) catch |e| {
        fail(job, if (e == error.FileNotFound) "OpenFailed" else "ReadFailed");
        return;
    };
    const sha_hex = std.fmt.bytesToHex(sha_bytes, .lower);
    @memcpy(p.archive_sha256_hex[0..], &sha_hex);
    p.archive_sha256_set = true;

    // ---- extract ---- Progress: compressed bytes read / file size.
    p.prog.reset();
    p.phase.store(1, .release);
    downloads.extract(job.alloc, p.io, p.file_path, p.dest_dir, .{ .strip = 0, .progress = p.prog.sink() }) catch {
        fail(job, "ExtractionFailed");
        return;
    };

    job.markDone();
}

/// UI-thread drain — runs each frame from `ui.runMainLoop`. Picks up
/// terminal manual-install workers, writes the `installs` row, and
/// frees the job.
pub fn drainManualInstall(frame: *Frame) void {
    if (frame.state.manual_install_jobs == null) return;
    const list = manualInstallJobsList(frame) orelse return;
    const state = frame.state;

    var i: usize = 0;
    while (i < list.items.len) {
        const job = list.items[i];
        const phase = job.phaseGet();
        if (phase == .pending) {
            i += 1;
            continue;
        }
        const p = &job.payload;
        if (phase == .done) {
            var id_buf: [36]u8 = undefined;
            generateUuid(frame.io, &id_buf);
            const now = std.Io.Clock.Timestamp.now(frame.io, .real);
            const now_s: i64 = @intCast(@divTrunc(now.raw.toNanoseconds(), 1_000_000_000));
            const sha_opt: ?[64]u8 = if (p.archive_sha256_set) p.archive_sha256_hex else null;
            frame.lib.upsertInstall(&.{
                .id = id_buf,
                .game_thread_id = p.game_id,
                .version = p.version,
                .install_path = p.dest_dir,
                .recipe_id = "",
                .installed_at = now_s,
                .name = p.name,
                .source = .manual,
                .archive_sha256 = sha_opt,
            }) catch |e| {
                log.warn("manual-install: upsert failed: {s}", .{@errorName(e)});
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Manual install: DB upsert failed: {s}", .{@errorName(e)}) catch "Manual install: DB upsert failed";
                state.setDownloadMsg(msg);
            };
            common.refreshInstalledSet(frame);
            state.setDownloadMsg("Manual install: done.");
            log.info("manual-install: tid={d} v='{s}' installed at '{s}'", .{ p.game_id, p.version, p.dest_dir });
        } else if (phase == .failed) {
            var buf: [192]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "Manual install failed: {s}",
                .{p.err_name orelse "?"},
            ) catch "Manual install failed";
            state.setDownloadMsg(msg);
            log.warn("manual-install: tid={d} failed ({s})", .{ p.game_id, p.err_name orelse "?" });
        }
        job.alloc.free(p.file_path);
        job.alloc.free(p.dest_dir);
        job.alloc.free(p.version);
        if (p.name) |s| job.alloc.free(s);
        job.alloc.destroy(job);
        _ = list.swapRemove(i);
    }
}

/// Replace runs of non-alnum chars with `-`, collapse repeats, drop
/// leading/trailing dashes. Returns null when the result is empty.
fn slugify(buf: []u8, src: []const u8) ?[]const u8 {
    var n: usize = 0;
    var last_was_dash = true;
    for (src) |c| {
        if (n >= buf.len) break;
        if (std.ascii.isAlphanumeric(c) or c == '.') {
            buf[n] = std.ascii.toLower(c);
            n += 1;
            last_was_dash = false;
        } else if (!last_was_dash) {
            buf[n] = '-';
            n += 1;
            last_was_dash = true;
        }
    }
    // strip trailing dash
    while (n > 0 and buf[n - 1] == '-') : (n -= 1) {}
    if (n == 0) return null;
    return buf[0..n];
}

/// Fill `out` with a random RFC-4122 v4 UUID string. 36 chars
/// `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`.
fn generateUuid(io: std.Io, out: *[36]u8) void {
    var raw: [16]u8 = undefined;
    io.randomSecure(&raw) catch io.random(&raw);
    // Version 4, variant 1 (10xx) bits.
    raw[6] = (raw[6] & 0x0F) | 0x40;
    raw[8] = (raw[8] & 0x3F) | 0x80;
    _ = std.fmt.bufPrint(out, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        raw[0],  raw[1],  raw[2],  raw[3],
        raw[4],  raw[5],
        raw[6],  raw[7],
        raw[8],  raw[9],
        raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
    }) catch unreachable;
}

fn dirNonEmpty(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |_| return true;
    return false;
}


// ============================================================
//  per-game open saves — recipe.saves.linux → xdg-open
// ============================================================

/// Resolve the recipe's `saves.linux` path (expanding `$HOME` →
/// per-game sandbox HOME and `$XDG_DATA_HOME` → `<sandbox>/.local/share`)
/// and ask `xdg-open` (or the user's configured browser path) to open
/// it in the system file manager. Falls back to opening the sandbox
/// HOME root when the recipe doesn't pin a saves path.
/// Open the game's install folder in the system file manager. Routes
/// through `xdg-open` like `doOpenSaves`. Latest install row from the
/// DB takes precedence; falls back to `<library_root>/<tid>/` (where
/// no-recipe installs land).
/// Write a new `name` to the install row (or clear it when the new
/// value is all-whitespace). Surfaces the result via
/// `setDownloadMsg` — the picker-label refresh happens for free on
/// the next frame's `listInstalls` call.
pub fn doRenameInstall(frame: *Frame, install_id: [36]u8, new_name: []const u8) void {
    const trimmed = std.mem.trim(u8, new_name, " \t\r\n");
    const name_opt: ?[]const u8 = if (trimmed.len == 0) null else trimmed;
    frame.lib.updateInstallName(install_id[0..], name_opt) catch |e| {
        log.warn("rename install: {s}", .{@errorName(e)});
        frame.state.setDownloadMsg("Rename failed (DB error).");
        return;
    };
    frame.state.setDownloadMsg(if (name_opt == null) "Name cleared." else "Renamed.");
}

/// Delete an install: wipe the on-disk install folder, then drop the
/// DB row. Order matters — if `deleteTree` fails (permissions, mounted
/// volume) we keep the DB row so the user can still see/retry rather
/// than ending up with files but no record.
pub fn doDeleteInstall(frame: *Frame, install_id: [36]u8, install_path: []const u8) void {
    const state = frame.state;

    if (install_path.len > 0) {
        // Safety: never let a delete take the per-game sandbox HOME
        // (saves) with it. Saves live at `<library_root>/<tid>/.f69-home`,
        // a SIBLING of the version dir we delete. A well-formed
        // install_path is `<tid>/<version>` and never IS or CONTAINS
        // `.f69-home`; if it does, the path is malformed (points at the
        // tid-level dir or the saves dir itself) and deleting it would
        // wipe the player's saves — refuse instead.
        if (std.mem.eql(u8, std.fs.path.basename(install_path), ".f69-home")) {
            log.warn("doDeleteInstall: refusing to delete saves dir {s}", .{install_path});
            state.setDownloadMsg("Refused: that path is the game's saves folder.");
            return;
        }
        var saves_buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&saves_buf, "{s}/.f69-home", .{install_path})) |saves_child| {
            if ((std.Io.Dir.cwd().access(frame.io, saves_child, .{}) catch null) != null) {
                log.warn("doDeleteInstall: refusing to delete {s} — it contains the sandbox HOME (saves)", .{install_path});
                state.setDownloadMsg("Refused: deleting this folder would remove the game's saves.");
                return;
            }
        } else |_| {}

        // deleteTree's error set doesn't expose `FileNotFound` (it's
        // already considered success), so we don't special-case it
        // here. Treat NotDir as a "stale entry" caller bug — log and
        // continue to the DB drop.
        std.Io.Dir.cwd().deleteTree(frame.io, install_path) catch |e| {
            var buf: [240]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Delete failed (disk): {s}", .{@errorName(e)}) catch "Delete failed (disk)";
            log.warn("doDeleteInstall: deleteTree({s}) failed: {s}", .{ install_path, @errorName(e) });
            state.setDownloadMsg(msg);
            return;
        };
        log.info("doDeleteInstall: removed install dir {s}", .{install_path});
    }

    frame.lib.deleteInstall(install_id[0..]) catch |e| {
        log.warn("doDeleteInstall: DB row delete failed: {s}", .{@errorName(e)});
        state.setDownloadMsg("Disk gone, DB row delete failed (stale row).");
        return;
    };
    common.refreshInstalledSet(frame);
    state.setDownloadMsg("Install removed (disk + record).");
}

