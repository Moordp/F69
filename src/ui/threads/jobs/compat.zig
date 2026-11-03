//! "Fix Compat" as a compute job. On click the UI thread reads the
//! install row and the compat rows the DB already has for it
//! (`listAppliedCompat`) and copies them into a `CompatJob`; this file
//! does every disk step on the compute thread: the recipe scan and each
//! `compat_svc.apply`. The DB part (`upsertAppliedCompat`) runs on the UI
//! thread in `actions/threads.zig` from `CompatOutcome.records`.

const std = @import("std");
const compat_mod = @import("compat");
const library = @import("library");
const activity_mod = @import("../activity.zig");
const work_thread = @import("../work_thread.zig");
const convert_job = @import("convert.zig");

const Activity = activity_mod.Activity;
const ResultKind = activity_mod.ResultKind;

const log = std.log.scoped(.compat_job);

pub const AppliedRow = convert_job.AppliedRow;

/// Every slice is owned by `arena`. The worker frees the job with
/// `deinit` when it ends (or when it never starts).
pub const CompatJob = struct {
    arena: *std.heap.ArenaAllocator,
    tid: u64,
    install_id: [36]u8,
    install_root: []u8,
    /// Recipes to apply. Empty: every `.unfixed` issue the scan finds.
    recipe_ids: [][]u8,
    /// Compat fixes already recorded for `install_id`.
    applied: []AppliedRow,

    pub const Init = struct {
        tid: u64,
        install_id: [36]u8,
        install_root: []const u8,
        recipe_ids: []const []const u8 = &.{},
        applied: []const library.Library.AppliedCompatRow = &.{},
    };

    /// Copies every input into a fresh arena on `alloc`.
    pub fn create(alloc: std.mem.Allocator, in: Init) !CompatJob {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer {
            arena.deinit();
            alloc.destroy(arena);
        }
        const a = arena.allocator();
        const ids = try a.alloc([]u8, in.recipe_ids.len);
        for (in.recipe_ids, ids) |src, *dst| dst.* = try a.dupe(u8, src);
        const applied = try a.alloc(AppliedRow, in.applied.len);
        for (in.applied, applied) |src, *dst| dst.* = .{
            .recipe_id = try a.dupe(u8, src.recipe_id),
            .recipe_sha256 = try a.dupe(u8, src.recipe_sha256),
            .backups_json = try a.dupe(u8, src.backups_json),
        };
        return .{
            .arena = arena,
            .tid = in.tid,
            .install_id = in.install_id,
            .install_root = try a.dupe(u8, in.install_root),
            .recipe_ids = ids,
            .applied = applied,
        };
    }

    pub fn deinit(self: CompatJob) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

/// What the UI thread gets back. `records` are owned by the compat
/// service's allocator; free with `freeOutcome`.
pub const CompatOutcome = struct {
    install_id: [36]u8,
    /// Fresh FixRecords to persist with `upsertAppliedCompat`.
    records: []compat_mod.FixRecord = &.{},
    failed: u32 = 0,
    /// "<recipe id>: <error>" of the last failed apply.
    last_err: [128]u8 = undefined,
    last_err_len: u8 = 0,
    /// The compat service that owns `records`. Set by the worker
    /// (`work_thread.run`) so a dropped outcome can be freed without a
    /// Frame (`work_thread.freeOutcome`).
    svc: ?*compat_mod.Service = null,

    pub fn lastErr(self: *const CompatOutcome) []const u8 {
        return self.last_err[0..self.last_err_len];
    }
};

/// Frees what `run` allocated for `o`. `svc` must be the compat service
/// the job used.
pub fn freeOutcome(svc: *compat_mod.Service, o: CompatOutcome) void {
    for (o.records) |fix| convert_job.freeFixRecord(svc, fix);
    if (o.records.len > 0) svc.alloc.free(o.records);
}

/// What `run` hands back when it does not return an error.
pub const Ran = struct {
    outcome: CompatOutcome,
    kind: ResultKind,
    msg: []const u8,
};

fn isApplied(job: CompatJob, id: []const u8) bool {
    for (job.applied) |row| if (std.mem.eql(u8, row.recipe_id, id)) return true;
    return false;
}

/// Runs the scan and the applies for `job` on the compute thread. `buf`
/// holds the result text. A cancel between fixes does not return an
/// error: the fixes already on disk must still reach the DB, so the
/// outcome carries them and the activity ends as cancelled (the cancel
/// flag is set).
pub fn run(deps: work_thread.Deps, job: CompatJob, a: *Activity, buf: []u8) anyerror!Ran {
    const io = deps.io;
    const scratch = job.arena.allocator();
    var out: CompatOutcome = .{ .install_id = job.install_id };
    const svc = deps.compat_svc orelse
        return .{ .outcome = out, .kind = .err, .msg = "Compat: the compat service is not available." };
    const alloc = svc.alloc;
    const id_slice: []const u8 = job.install_id[0..];

    // Targets: the given recipe ids, or every unfixed issue the scan finds.
    var targets: std.ArrayList([]const u8) = .empty;
    if (job.recipe_ids.len > 0) {
        for (job.recipe_ids) |rid| {
            if (isApplied(job, rid)) continue;
            try targets.append(scratch, rid);
        }
    } else {
        a.setPhase(io, "Scanning");
        const ids = try scratch.alloc([]const u8, job.applied.len);
        for (job.applied, ids) |row, *dst| dst.* = row.recipe_id;
        const issues = svc.scan(job.install_root, ids) catch |e| {
            const m = std.fmt.bufPrint(buf, "Compat scan failed: {s}", .{@errorName(e)}) catch "Compat scan failed.";
            return .{ .outcome = out, .kind = .err, .msg = m };
        };
        defer svc.freeIssues(issues);
        for (issues) |is| {
            if (is.status != .unfixed) continue;
            try targets.append(scratch, try scratch.dupe(u8, is.recipe_id));
        }
    }
    if (a.cancelled()) return error.Cancelled;

    const n = targets.items.len;
    if (n == 0) return .{ .outcome = out, .kind = .warn, .msg = "Compat: nothing to fix." };

    var records: std.ArrayList(compat_mod.FixRecord) = .empty;
    a.report(0, n);
    var stopped = false;
    for (targets.items, 0..) |rid, idx| {
        if (a.cancelled()) {
            stopped = true;
            break;
        }
        var pbuf: [96]u8 = undefined;
        const phase = std.fmt.bufPrint(&pbuf, "Fix {d} / {d} \u{00B7} {s}", .{ idx + 1, n, rid }) catch "Applying fix";
        a.setPhase(io, phase);

        if (applyOne(svc, id_slice, job.install_root, rid)) |fix| {
            records.append(alloc, fix) catch {
                convert_job.freeFixRecord(svc, fix);
                noteFail(&out, rid, error.OutOfMemory);
                a.report(idx + 1, n);
                continue;
            };
            log.info("compat: applied {s}", .{rid});
        } else |e| {
            log.warn("compat: {s} failed: {s}", .{ rid, @errorName(e) });
            noteFail(&out, rid, e);
        }
        a.report(idx + 1, n);
    }

    out.records = records.toOwnedSlice(alloc) catch blk: {
        for (records.items) |fix| convert_job.freeFixRecord(svc, fix);
        records.deinit(alloc);
        out.failed += 1;
        break :blk &.{};
    };
    return finishText(out, stopped, buf);
}

fn applyOne(svc: *compat_mod.Service, install_id: []const u8, install_root: []const u8, rid: []const u8) !compat_mod.FixRecord {
    const entry = svc.repo.byId(rid) orelse return error.RecipeNotFound;
    return svc.apply(install_id, install_root, entry);
}

fn noteFail(out: *CompatOutcome, rid: []const u8, e: anyerror) void {
    out.failed += 1;
    const m = std.fmt.bufPrint(&out.last_err, "{s}: {s}", .{ rid, @errorName(e) }) catch blk: {
        // Too long for the buffer: keep the error name only.
        const name = @errorName(e);
        const len = @min(name.len, out.last_err.len);
        @memcpy(out.last_err[0..len], name[0..len]);
        break :blk out.last_err[0..len];
    };
    out.last_err_len = @intCast(m.len);
}

/// Result kind and text for a finished run.
fn finishText(out: CompatOutcome, stopped: bool, buf: []u8) Ran {
    const applied = out.records.len;
    if (stopped) {
        const m = std.fmt.bufPrint(buf, "Compat: stopped after {d} fix(es).", .{applied}) catch "Compat: stopped.";
        return .{ .outcome = out, .kind = .warn, .msg = m };
    }
    if (out.failed > 0) {
        const m = std.fmt.bufPrint(buf, "Compat: {d} fix(es) applied, {d} failed ({s}).", .{ applied, out.failed, out.lastErr() }) catch "Compat: partial.";
        return .{ .outcome = out, .kind = if (applied == 0) .err else .warn, .msg = m };
    }
    const m = std.fmt.bufPrint(buf, "Compat: {d} fix(es) applied. Re-launch the game.", .{applied}) catch "Compat applied.";
    return .{ .outcome = out, .kind = .ok, .msg = m };
}

test "CompatJob: create copies every input; deinit frees it" {
    var root = "lib/1".*;
    var rid = "r1".*;
    const ids = [_][]const u8{&rid};
    const rows = [_]library.Library.AppliedCompatRow{.{ .recipe_id = "r0", .recipe_sha256 = "s0", .applied_at = 3, .backups_json = "[]" }};
    const job = try CompatJob.create(std.testing.allocator, .{
        .tid = 9,
        .install_id = "11111111-2222-3333-4444-555555555555".*,
        .install_root = &root,
        .recipe_ids = &ids,
        .applied = &rows,
    });
    defer job.deinit();
    root[0] = 'X';
    rid[0] = 'X';
    try std.testing.expectEqualStrings("lib/1", job.install_root);
    try std.testing.expectEqualStrings("r1", job.recipe_ids[0]);
    try std.testing.expectEqualStrings("r0", job.applied[0].recipe_id);
    try std.testing.expectEqual(@as(u64, 9), job.tid);
}

test "finishText: the result texts" {
    var buf: [192]u8 = undefined;
    var recs = [_]compat_mod.FixRecord{.{ .recipe_id = "a", .recipe_sha256 = "s", .applied_at = 0 }};
    var out: CompatOutcome = .{ .install_id = @splat('0'), .records = &recs };
    var r = finishText(out, false, &buf);
    try std.testing.expectEqual(ResultKind.ok, r.kind);
    try std.testing.expectEqualStrings("Compat: 1 fix(es) applied. Re-launch the game.", r.msg);

    noteFail(&out, "b", error.AccessDenied);
    r = finishText(out, false, &buf);
    try std.testing.expectEqual(ResultKind.warn, r.kind);
    try std.testing.expectEqualStrings("Compat: 1 fix(es) applied, 1 failed (b: AccessDenied).", r.msg);

    out.records = &.{};
    r = finishText(out, false, &buf);
    try std.testing.expectEqual(ResultKind.err, r.kind);

    r = finishText(out, true, &buf);
    try std.testing.expectEqual(ResultKind.warn, r.kind);
    try std.testing.expectEqualStrings("Compat: stopped after 0 fix(es).", r.msg);
}

test "noteFail: an over-long recipe id keeps the error name" {
    var out: CompatOutcome = .{ .install_id = @splat('0') };
    const long: [200]u8 = @splat('r');
    noteFail(&out, &long, error.AccessDenied);
    try std.testing.expectEqual(@as(u32, 1), out.failed);
    try std.testing.expectEqualStrings("AccessDenied", out.lastErr());
}
