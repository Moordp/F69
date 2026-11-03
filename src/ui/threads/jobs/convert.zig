//! Convert as a compute job. The UI thread gathers the in-memory inputs
//! (install path, compat rows already in the DB, preset dir) into a
//! `ConvertJob`; this file does every disk step on the compute thread:
//! game-root peel, engine detection, preset match, the convert itself,
//! and the file part of the compat post-step. The DB part of compat
//! (`upsertAppliedCompat` / `deleteAppliedCompat`) runs on the UI thread
//! in `actions/threads.zig` from `ConvertOutcome`.

const std = @import("std");
const convert_mod = @import("convert");
const compat_mod = @import("compat");
const library = @import("library");
const activity_mod = @import("../activity.zig");
const work_thread = @import("../work_thread.zig");
const launch_act = @import("../../actions/launch.zig");
const mods_act = @import("../../actions/mods.zig");

const Activity = activity_mod.Activity;
const ResultKind = activity_mod.ResultKind;
const RgssVariant = convert_mod.rpgm.RgssVariant;

const log = std.log.scoped(.convert_job);

/// One compat fix the DB already has for this install. Copied on click.
pub const AppliedRow = struct {
    recipe_id: []const u8,
    recipe_sha256: []const u8,
    backups_json: []const u8,
};

/// Every slice is owned by `arena`. The worker frees the job with
/// `deinit` when it ends (or when it never starts).
pub const ConvertJob = struct {
    arena: *std.heap.ArenaAllocator,
    tid: u64,
    /// The install dir from the DB. The job peels a wrapper folder.
    raw_install_path: []u8,
    game_name: []u8,
    engine: library.Engine,
    force: bool,
    auto_compat: bool,
    install_id: ?[36]u8,
    /// `<data_root>/convert-presets`; read on the compute thread.
    convert_presets_dir: []u8,
    /// Compat fixes already recorded for `install_id` (empty when
    /// `auto_compat` is false).
    applied: []AppliedRow,

    pub const Init = struct {
        tid: u64,
        raw_install_path: []const u8,
        game_name: []const u8,
        engine: library.Engine,
        force: bool,
        auto_compat: bool,
        install_id: ?[36]u8,
        convert_presets_dir: []const u8,
        applied: []const library.Library.AppliedCompatRow = &.{},
    };

    /// Copies every input into a fresh arena on `alloc`.
    pub fn create(alloc: std.mem.Allocator, in: Init) !ConvertJob {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer {
            arena.deinit();
            alloc.destroy(arena);
        }
        const a = arena.allocator();
        const applied = try a.alloc(AppliedRow, in.applied.len);
        for (in.applied, applied) |src, *dst| dst.* = .{
            .recipe_id = try a.dupe(u8, src.recipe_id),
            .recipe_sha256 = try a.dupe(u8, src.recipe_sha256),
            .backups_json = try a.dupe(u8, src.backups_json),
        };
        return .{
            .arena = arena,
            .tid = in.tid,
            .raw_install_path = try a.dupe(u8, in.raw_install_path),
            .game_name = try a.dupe(u8, in.game_name),
            .engine = in.engine,
            .force = in.force,
            .auto_compat = in.auto_compat,
            .install_id = in.install_id,
            .convert_presets_dir = try a.dupe(u8, in.convert_presets_dir),
            .applied = applied,
        };
    }

    pub fn deinit(self: ConvertJob) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

/// What the UI thread gets back. `compat_applied` / `compat_undone` are
/// owned by the compat service's allocators; free with `freeOutcome`.
pub const ConvertOutcome = struct {
    tid: u64,
    install_id: ?[36]u8 = null,
    /// A launcher was written.
    converted: bool = false,
    /// Fresh FixRecords to persist with `upsertAppliedCompat`.
    compat_applied: []compat_mod.FixRecord = &.{},
    /// Recipe ids whose old fix was undone on disk (sha drift); their DB
    /// rows are deleted before the new records are written.
    compat_undone: [][]u8 = &.{},
};

/// Frees what `run` allocated for `o`. `svc` must be the compat service
/// the job used.
pub fn freeOutcome(svc: *compat_mod.Service, o: ConvertOutcome) void {
    for (o.compat_applied) |fix| freeFixRecord(svc, fix);
    if (o.compat_applied.len > 0) svc.alloc.free(o.compat_applied);
    for (o.compat_undone) |id| svc.alloc.free(id);
    if (o.compat_undone.len > 0) svc.alloc.free(o.compat_undone);
}

pub fn freeFixRecord(svc: *compat_mod.Service, fix: compat_mod.FixRecord) void {
    svc.alloc.free(fix.recipe_id);
    svc.alloc.free(fix.recipe_sha256);
    for (fix.backups) |b| svc.backups.freeRecord(b);
    if (fix.backups.len > 0) svc.alloc.free(fix.backups);
}

/// What `run` hands back when it does not return an error. A failed
/// convert is a `.err` result here (with the error name in `msg`); only
/// a cancel is returned as `error.Cancelled`.
pub const Ran = struct {
    outcome: ConvertOutcome,
    kind: ResultKind,
    msg: []const u8,
};

/// Progress hooks over an `Activity`. Lives on the job's stack for the
/// whole run.
pub const ProgressCtx = struct {
    a: *Activity,
    io: std.Io,

    fn phase(ctx: ?*anyopaque, text: []const u8) void {
        const self: *ProgressCtx = @ptrCast(@alignCast(ctx.?));
        self.a.setPhase(self.io, text);
    }
    fn report(ctx: ?*anyopaque, done: u64, total: u64) void {
        const self: *ProgressCtx = @ptrCast(@alignCast(ctx.?));
        self.a.report(done, total);
    }
    fn cancelled(ctx: ?*anyopaque) bool {
        const self: *ProgressCtx = @ptrCast(@alignCast(ctx.?));
        return self.a.cancelled();
    }
};

/// A `convert.Progress` that writes into `ctx.a`. `ctx` must outlive
/// every use of the returned value.
pub fn progressFor(ctx: *ProgressCtx) convert_mod.Progress {
    return .{
        .ctx = ctx,
        .phase = ProgressCtx.phase,
        .report = ProgressCtx.report,
        .cancelled = ProgressCtx.cancelled,
    };
}

/// Pure. The six "nothing converted" messages, in the order the old
/// Convert button picked them. With `mkxp_bundled` an RGSS game is
/// converted instead, so the RGSS branches only fire without it.
pub fn describeNoConvert(has_lin: bool, has_win: bool, rgss: RgssVariant, mkxp_bundled: bool) []const u8 {
    if (has_lin) return "No convert needed — a Linux launcher (.sh / .AppImage) is already in the install.";
    if (!mkxp_bundled) switch (rgss) {
        .vx_ace => return "RPG Maker VX Ace: bundled mkxp-z is missing from this build of f69. Rebuild with the third_party/mkxp-z/ tree in place, or use WINE/Proton.",
        .vx => return "RPG Maker VX: bundled mkxp-z is missing from this build of f69. Rebuild with the third_party/mkxp-z/ tree in place, or use WINE/Proton.",
        .xp => return "RPG Maker XP: bundled mkxp-z is missing from this build of f69. Rebuild with the third_party/mkxp-z/ tree in place, or use WINE/Proton.",
        .unknown => {},
    };
    if (has_win) return "Can't convert: only Ren'Py and RPG Maker MV/MZ have Linux runtimes f69 can install. Other Windows-only engines need WINE or Proton.";
    return "No convert needed: no engine detected at this install path. Check the install folder contents.";
}

fn isCancel(e: anyerror) bool {
    return e == error.Cancelled or e == error.Canceled;
}

/// Runs the whole convert for `job` on the compute thread. `buf` holds
/// the result text.
pub fn run(deps: work_thread.Deps, job: ConvertJob, a: *Activity, buf: []u8) anyerror!Ran {
    const io = deps.io;
    const svc = deps.convert_svc orelse return error.NoConvertService;
    const alloc = job.arena.allocator();
    var pctx: ProgressCtx = .{ .a = a, .io = io };
    const prog = progressFor(&pctx);
    var out: ConvertOutcome = .{ .tid = job.tid, .install_id = job.install_id };

    prog.setPhase("Detecting engine");
    // Peel a wrapper folder (`<install>/Game v1.0d/...`) so detection
    // looks at the real game root.
    const install_path = mods_act.resolveGameRoot(io, job.raw_install_path, alloc) catch
        return .{ .outcome = out, .kind = .err, .msg = "Convert: failed to resolve game root." };
    if (!std.mem.eql(u8, install_path, job.raw_install_path)) {
        log.info("peeled wrapper {s} → {s}", .{ job.raw_install_path, install_path });
    }
    if (prog.stop()) return error.Cancelled;

    // Engine-keyed preset match over built-ins + `<data_root>/convert-presets/`.
    const detected = convert_mod.detectEngine(io, install_path);
    var bundle_opt: ?convert_mod.MergedPresetSet = null;
    defer if (bundle_opt) |*b| b.deinit();
    var spec: convert_mod.ConvertSpec = .none;
    if (detected != .unknown) {
        if (convert_mod.loadMergedPresets(deps.alloc, io, job.convert_presets_dir)) |b| {
            bundle_opt = b;
            if (convert_mod.pickPresetForEngine(bundle_opt.?.presets, detected)) |m| spec = m.preset.spec;
        } else |e| log.warn("convert presets: {s}", .{@errorName(e)});
    }

    var head: []const u8 = "Converted.";
    if (spec == .none) {
        var probe_buf: [512]u8 = undefined;
        const has_lin = launch_act.findLinuxLauncher(io, alloc, install_path, &probe_buf) != null;
        const has_win = launch_act.findWindowsExe(io, alloc, install_path, &probe_buf) != null;
        const rgss = convert_mod.rpgm.detectRgssVariant(io, install_path);
        var bin_buf: [640]u8 = undefined;
        var libs_buf: [640]u8 = undefined;
        const mkxp_dir = launch_act.mkxpZBundled(io, deps.exe_dir, &bin_buf);
        if (rgss == .unknown or mkxp_dir == null) {
            const msg = describeNoConvert(has_lin, has_win, rgss, mkxp_dir != null);
            return .{ .outcome = out, .kind = .warn, .msg = msg };
        }
        // Vendored mkxp-z covers RGSS1/2/3.
        const zoom = convert_mod.rpgm.readMkxpZoom(io, install_path) orelse convert_mod.rpgm.MKXP_ZOOM_DEFAULT;
        const mkxp_spec: convert_mod.ConvertSpec = .{ .mkxp_z = .{
            .mkxp_z_dir = mkxp_dir.?,
            .extra_libs_dir = launch_act.mkxpZExtraLibsDir(io, deps.exe_dir, &libs_buf),
            .zoom = zoom,
        } };
        svc.convert(install_path, mkxp_spec, job.force, prog) catch |e| {
            if (isCancel(e)) return error.Cancelled;
            log.warn("mkxp-z convert failed: {s}", .{@errorName(e)});
            const m = std.fmt.bufPrint(buf, "mkxp-z convert failed: {s}", .{@errorName(e)}) catch "mkxp-z convert failed";
            return .{ .outcome = out, .kind = .err, .msg = m };
        };
        head = "Converted via bundled mkxp-z.";
    } else {
        // force: a manual Convert always re-writes the launcher.
        svc.convert(install_path, spec, job.force, prog) catch |e| {
            if (isCancel(e)) return error.Cancelled;
            const m = std.fmt.bufPrint(buf, "Convert failed: {s}", .{@errorName(e)}) catch "Convert failed";
            return .{ .outcome = out, .kind = .err, .msg = m };
        };
    }
    out.converted = true;

    var counts: CompatCounts = .{};
    if (job.auto_compat) if (job.install_id) |id| if (deps.compat_svc) |csvc| {
        prog.setPhase("Applying compat fixes");
        counts = applyCompat(csvc, job, &id, install_path, &out);
    };

    var tail_buf: [96]u8 = undefined;
    const tail: []const u8 = if (counts.applied + counts.reapplied + counts.failed > 0)
        std.fmt.bufPrint(&tail_buf, " Compat: {d} applied, {d} re-applied, {d} failed.", .{ counts.applied, counts.reapplied, counts.failed }) catch ""
    else
        "";
    const ready: []const u8 = if (std.mem.eql(u8, head, "Converted.")) " Play is ready." else "";
    const msg = std.fmt.bufPrint(buf, "{s}{s}{s}", .{ head, tail, ready }) catch head;
    return .{ .outcome = out, .kind = .ok, .msg = msg };
}

const CompatCounts = struct { applied: u32 = 0, reapplied: u32 = 0, failed: u32 = 0 };

/// File part of the post-convert compat step (scan, undo stale, apply).
/// Mirrors `launch.autoApplyCompatAfterConvert`, with the DB rows taken
/// from `job.applied` and the new records handed back in `out`.
fn applyCompat(
    svc: *compat_mod.Service,
    job: ConvertJob,
    install_id: *const [36]u8,
    install_root: []const u8,
    out: *ConvertOutcome,
) CompatCounts {
    var res: CompatCounts = .{};
    const alloc = svc.alloc;
    const id_slice: []const u8 = install_id[0..];
    const scratch = job.arena.allocator();

    const ids = scratch.alloc([]const u8, job.applied.len) catch return res;
    for (job.applied, ids) |row, *dst| dst.* = row.recipe_id;
    const issues = svc.scan(install_root, ids) catch |e| {
        log.warn("auto-apply-compat: scan failed: {s}", .{@errorName(e)});
        return res;
    };
    defer svc.freeIssues(issues);

    var applied: std.ArrayList(compat_mod.FixRecord) = .empty;
    var undone: std.ArrayList([]u8) = .empty;

    for (issues) |is| {
        // `.unfixed` → apply. `.fixed` → re-apply only when the bundled
        // recipe's sha moved on since the install was fixed.
        var stale: ?AppliedRow = null;
        if (is.status == .fixed) {
            const entry = svc.repo.byId(is.recipe_id) orelse continue;
            for (job.applied) |row| {
                if (!std.mem.eql(u8, row.recipe_id, is.recipe_id)) continue;
                if (!std.mem.eql(u8, row.recipe_sha256, entry.source_sha256)) stale = row;
                break;
            }
        }
        if (is.status != .unfixed and stale == null) continue;

        if (stale) |row| {
            undoOnDisk(svc, id_slice, install_root, row) catch |e| {
                log.warn("auto-apply-compat: stale-sha undo of {s} failed: {s}", .{ is.recipe_id, @errorName(e) });
                res.failed += 1;
                continue;
            };
            const dup = alloc.dupe(u8, is.recipe_id) catch {
                res.failed += 1;
                continue;
            };
            undone.append(alloc, dup) catch {
                alloc.free(dup);
                res.failed += 1;
                continue;
            };
        }

        const entry = svc.repo.byId(is.recipe_id) orelse {
            res.failed += 1;
            continue;
        };
        const fix = svc.apply(id_slice, install_root, entry) catch |e| {
            log.warn("auto-apply-compat: {s} failed: {s}", .{ is.recipe_id, @errorName(e) });
            res.failed += 1;
            continue;
        };
        applied.append(alloc, fix) catch {
            freeFixRecord(svc, fix);
            res.failed += 1;
            continue;
        };
        if (stale != null) res.reapplied += 1 else res.applied += 1;
        log.info("auto-apply-compat: applied {s}", .{is.recipe_id});
    }

    out.compat_applied = applied.toOwnedSlice(alloc) catch blk: {
        for (applied.items) |fix| freeFixRecord(svc, fix);
        applied.deinit(alloc);
        break :blk &.{};
    };
    out.compat_undone = undone.toOwnedSlice(alloc) catch blk: {
        for (undone.items) |id| alloc.free(id);
        undone.deinit(alloc);
        break :blk &.{};
    };
    return res;
}

/// Restores the backups of one recorded fix (file part of `undoCompatFix`).
fn undoOnDisk(svc: *compat_mod.Service, install_id: []const u8, install_root: []const u8, row: AppliedRow) !void {
    const alloc = svc.alloc;
    const backups = try compat_mod.deserializeBackups(alloc, row.backups_json);
    defer {
        for (backups) |b| {
            alloc.free(b.sha256);
            alloc.free(b.relpath);
            if (b.symlink_target) |t| alloc.free(t);
        }
        if (backups.len > 0) alloc.free(backups);
    }
    try svc.undo(install_id, install_root, .{
        .recipe_id = row.recipe_id,
        .recipe_sha256 = row.recipe_sha256,
        .applied_at = 0,
        .backups = backups,
    });
}

test "describeNoConvert: the six messages" {
    const t = std.testing;
    try t.expect(std.mem.startsWith(u8, describeNoConvert(true, true, .vx_ace, false), "No convert needed — a Linux launcher"));
    try t.expect(std.mem.startsWith(u8, describeNoConvert(false, true, .vx_ace, false), "RPG Maker VX Ace: bundled mkxp-z is missing"));
    try t.expect(std.mem.startsWith(u8, describeNoConvert(false, true, .vx, false), "RPG Maker VX: bundled mkxp-z is missing"));
    try t.expect(std.mem.startsWith(u8, describeNoConvert(false, false, .xp, false), "RPG Maker XP: bundled mkxp-z is missing"));
    try t.expect(std.mem.startsWith(u8, describeNoConvert(false, true, .unknown, false), "Can't convert: only Ren'Py and RPG Maker MV/MZ"));
    try t.expect(std.mem.startsWith(u8, describeNoConvert(false, false, .unknown, false), "No convert needed: no engine detected"));
    // With mkxp-z bundled the RGSS branches do not fire.
    try t.expect(std.mem.startsWith(u8, describeNoConvert(false, true, .vx_ace, true), "Can't convert:"));
}

test "ConvertJob: create copies every input; deinit frees it" {
    var raw = "lib/1".*;
    const rows = [_]library.Library.AppliedCompatRow{.{ .recipe_id = "r1", .recipe_sha256 = "s1", .applied_at = 3, .backups_json = "[]" }};
    const job = try ConvertJob.create(std.testing.allocator, .{
        .tid = 9,
        .raw_install_path = &raw,
        .game_name = "G",
        .engine = .renpy,
        .force = true,
        .auto_compat = true,
        .install_id = null,
        .convert_presets_dir = "p",
        .applied = &rows,
    });
    defer job.deinit();
    raw[0] = 'X';
    try std.testing.expectEqualStrings("lib/1", job.raw_install_path);
    try std.testing.expectEqualStrings("r1", job.applied[0].recipe_id);
    try std.testing.expectEqualStrings("[]", job.applied[0].backups_json);
}

test "progressFor: phase, report and cancel reach the Activity" {
    var book = activity_mod.Book.init(std.testing.allocator, std.testing.io);
    defer book.deinit();
    const a = try book.start(.convert, 1, "Convert");
    var ctx: ProgressCtx = .{ .a = a, .io = std.testing.io };
    const p = progressFor(&ctx);
    p.setPhase("Copying runtime file 1 / 2");
    p.tick(1, 2);
    try std.testing.expectEqual(@as(u8, 26), a.phaseLen(std.testing.io));
    try std.testing.expectEqual(@as(u64, 1), a.prog.get().done);
    try std.testing.expect(!p.stop());
    book.requestCancel(a.id);
    try std.testing.expect(p.stop());
}
