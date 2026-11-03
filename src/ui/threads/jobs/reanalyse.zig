//! "Re-detect engines" (Settings → Library) as a compute job. The UI
//! thread reads one install row per game on click and copies the game
//! id, name, stored engine and install path into a `ReanalyseJob`; this
//! file does every disk step on the compute thread: peel the wrapper
//! folder, run `detectEngine` and the RGSS marker probe. The engine
//! changes come back as `ReanalyseOutcome.updates`; the UI drain
//! (`actions/threads.zig`) writes them with `applyScrape`.

const std = @import("std");
const library = @import("library");
const convert_mod = @import("convert");
const activity_mod = @import("../activity.zig");
const work_thread = @import("../work_thread.zig");
const mods_act = @import("../../actions/mods.zig");

const Activity = activity_mod.Activity;
const ResultKind = activity_mod.ResultKind;

pub const Stats = mods_act.EngineReanalyseStats;

/// One game with an install row. Slices are owned by the job arena.
pub const Entry = struct {
    tid: u64,
    name: []u8,
    /// The engine stored for the game when the user clicked.
    engine: library.Engine,
    install_path: []u8,
};

/// Every slice is owned by `arena`. The worker frees the job with
/// `deinit` when it ends (or when it never starts).
pub const ReanalyseJob = struct {
    arena: *std.heap.ArenaAllocator,
    entries: []Entry,
    /// Games the UI thread found without an install row.
    no_install: u32,

    pub const In = struct {
        tid: u64,
        name: []const u8,
        engine: library.Engine,
        install_path: []const u8,
    };

    /// Copies every input into a fresh arena on `alloc`.
    pub fn create(alloc: std.mem.Allocator, in: []const In, no_install: u32) !ReanalyseJob {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer {
            arena.deinit();
            alloc.destroy(arena);
        }
        const a = arena.allocator();
        const entries = try a.alloc(Entry, in.len);
        for (in, entries) |src, *dst| dst.* = .{
            .tid = src.tid,
            .name = try a.dupe(u8, src.name),
            .engine = src.engine,
            .install_path = try a.dupe(u8, src.install_path),
        };
        return .{ .arena = arena, .entries = entries, .no_install = no_install };
    }

    pub fn deinit(self: ReanalyseJob) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

/// One engine label to write.
pub const Update = struct { tid: u64, engine: library.Engine };

/// What the UI thread gets back. `updates` is owned by the worker's
/// allocator (`Deps.alloc`); free with `freeOutcome`. `stats.changed`
/// and the `to_*` counts are what the job found; the drain recounts them
/// from the writes that succeed.
pub const ReanalyseOutcome = struct {
    updates: []Update = &.{},
    stats: Stats = .{},
};

pub fn freeOutcome(alloc: std.mem.Allocator, o: ReanalyseOutcome) void {
    if (o.updates.len > 0) alloc.free(o.updates);
}

/// What `run` hands back when it does not return an error. Only a
/// cancel is returned as `error.Cancelled`.
pub const Ran = struct {
    outcome: ReanalyseOutcome,
    kind: ResultKind,
    msg: []const u8,
};

/// Adds one changed engine to the per-engine counts.
pub fn countChange(stats: *Stats, engine: library.Engine) void {
    stats.changed += 1;
    switch (engine) {
        .renpy => stats.to_renpy += 1,
        .rpgm_mv => stats.to_rpgm_mv += 1,
        .rpgm_mz => stats.to_rpgm_mz += 1,
        .rpgm_vx => stats.to_rpgm_vx += 1,
        .unity => stats.to_unity += 1,
        else => {},
    }
}

/// The engine found on disk under `root`, or `.unknown`. RPGM XP / VX /
/// VX Ace all map to `.rpgm_vx` (the Engine enum has no XP value).
pub fn detect(io: std.Io, root: []const u8) library.Engine {
    const detected = convert_mod.detectEngine(io, root);
    if (detected != .unknown) return detected;
    if (convert_mod.rpgm.detectRgssVariant(io, root) != .unknown) return .rpgm_vx;
    return .unknown;
}

/// Runs the scan for `job` on the compute thread. Cancel is checked
/// between games. `buf` holds the result text.
pub fn run(deps: work_thread.Deps, job: ReanalyseJob, a: *Activity, buf: []u8) anyerror!Ran {
    const io = deps.io;
    const scratch = job.arena.allocator();
    var stats: Stats = .{ .skipped_no_install = job.no_install };
    var updates: std.ArrayList(Update) = .empty;
    errdefer updates.deinit(deps.alloc);

    const n = job.entries.len;
    a.report(0, n);
    for (job.entries, 0..) |e, idx| {
        if (a.cancelled()) return error.Cancelled;
        var pbuf: [160]u8 = undefined;
        const phase = std.fmt.bufPrint(&pbuf, "Game {d} / {d} \u{00B7} {s}", .{ idx + 1, n, e.name }) catch "Scanning";
        a.setPhase(io, phase);

        const root = mods_act.resolveGameRoot(io, e.install_path, scratch) catch {
            stats.skipped_no_install += 1;
            a.report(idx + 1, n);
            continue;
        };
        stats.scanned += 1;
        const detected = detect(io, root);
        if (detected == .unknown) {
            stats.skipped_detect_unknown += 1;
        } else if (detected != e.engine) {
            try updates.append(deps.alloc, .{ .tid = e.tid, .engine = detected });
            countChange(&stats, detected);
        }
        a.report(idx + 1, n);
    }

    const owned = try updates.toOwnedSlice(deps.alloc);
    const msg = std.fmt.bufPrint(buf, "Scanned {d}. Found {d} engine change(s).", .{ stats.scanned, stats.changed }) catch "Scan complete.";
    return .{ .outcome = .{ .updates = owned, .stats = stats }, .kind = .ok, .msg = msg };
}

test "ReanalyseJob: create copies every input; deinit frees it" {
    var raw = "lib/1".*;
    const in = [_]ReanalyseJob.In{.{ .tid = 7, .name = "G", .engine = .renpy, .install_path = &raw }};
    const job = try ReanalyseJob.create(std.testing.allocator, &in, 2);
    defer job.deinit();
    raw[0] = 'X';
    try std.testing.expectEqual(@as(usize, 1), job.entries.len);
    try std.testing.expectEqualStrings("lib/1", job.entries[0].install_path);
    try std.testing.expectEqualStrings("G", job.entries[0].name);
    try std.testing.expectEqual(@as(u32, 2), job.no_install);
}

test "reanalyse run: a Ren'Py and an RPGM MV install give the right engine updates" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "rp/renpy", "rp/game", "mv/www/js" }) |d| try tmp.dir.createDirPath(io, d);
    try tmp.dir.writeFile(io, .{ .sub_path = "rp/renpy/vc_version.py", .data = "version = u'8.1.0'\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "rp/game/script.rpy", .data = "label start:\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mv/package.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mv/www/js/rpg_core.js", .data = "//" });
    const rp = try tmp.dir.realPathFileAlloc(io, "rp", gpa);
    defer gpa.free(rp);
    const mv = try tmp.dir.realPathFileAlloc(io, "mv", gpa);
    defer gpa.free(mv);

    const in = [_]ReanalyseJob.In{
        .{ .tid = 1, .name = "Ren Game", .engine = .unknown, .install_path = rp },
        .{ .tid = 2, .name = "MV Game", .engine = .unknown, .install_path = mv },
    };
    const job = try ReanalyseJob.create(gpa, &in, 1);
    defer job.deinit();

    var book = activity_mod.Book.init(gpa, io);
    defer book.deinit();
    const a = try book.start(.reanalyse, 0, "Re-analyse engines");
    var buf: [192]u8 = undefined;
    const r = try run(.{ .alloc = gpa, .io = io }, job, a, &buf);
    defer freeOutcome(gpa, r.outcome);

    try std.testing.expectEqual(@as(usize, 2), r.outcome.updates.len);
    try std.testing.expectEqual(@as(u64, 1), r.outcome.updates[0].tid);
    try std.testing.expectEqual(library.Engine.renpy, r.outcome.updates[0].engine);
    try std.testing.expectEqual(@as(u64, 2), r.outcome.updates[1].tid);
    try std.testing.expectEqual(library.Engine.rpgm_mv, r.outcome.updates[1].engine);
    try std.testing.expectEqual(@as(u32, 2), r.outcome.stats.scanned);
    try std.testing.expectEqual(@as(u32, 2), r.outcome.stats.changed);
    try std.testing.expectEqual(@as(u32, 1), r.outcome.stats.skipped_no_install);
    try std.testing.expectEqualStrings("Scanned 2. Found 2 engine change(s).", r.msg);
    const p = a.prog.get();
    try std.testing.expectEqual(@as(u64, 2), p.done);
    try std.testing.expectEqual(@as(u64, 2), p.total);
}

test "reanalyse run: an unchanged engine gives no update; cancel stops between games" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "rp/renpy", "rp/game" }) |d| try tmp.dir.createDirPath(io, d);
    try tmp.dir.writeFile(io, .{ .sub_path = "rp/renpy/x", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "rp/game/x", .data = "" });
    const rp = try tmp.dir.realPathFileAlloc(io, "rp", gpa);
    defer gpa.free(rp);
    const in = [_]ReanalyseJob.In{.{ .tid = 1, .name = "R", .engine = .renpy, .install_path = rp }};
    const job = try ReanalyseJob.create(gpa, &in, 0);
    defer job.deinit();

    var book = activity_mod.Book.init(gpa, io);
    defer book.deinit();
    const a = try book.start(.reanalyse, 0, "Re-analyse engines");
    var buf: [192]u8 = undefined;
    const r = try run(.{ .alloc = gpa, .io = io }, job, a, &buf);
    defer freeOutcome(gpa, r.outcome);
    try std.testing.expectEqual(@as(usize, 0), r.outcome.updates.len);
    try std.testing.expectEqual(@as(u32, 1), r.outcome.stats.scanned);

    const b = try book.start(.reanalyse, 0, "Re-analyse engines");
    b.cancel.store(true, .release);
    try std.testing.expectError(error.Cancelled, run(.{ .alloc = gpa, .io = io }, job, b, &buf));
}
