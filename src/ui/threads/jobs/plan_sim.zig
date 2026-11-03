//! Recipe editor preview as a compute job. The UI thread reads the
//! install row (SQL) and copies the wizard's plan, the archive path and
//! the install path into a `PlanSimJob` when the plan changes; this file
//! does every disk step on the compute thread: peel the wrapper folder
//! (`resolveGameRoot`), simulate the plan against it, and list the
//! archive's and the install's top-level folders for the Browse… menus.
//! The result comes back as a `PlanSimOutcome` that the editor caches in
//! `WizardState.sim_cache` and renders from until the next change.

const std = @import("std");
const recipe = @import("recipe");
const installer = @import("installer");
const activity_mod = @import("../activity.zig");
const work_thread = @import("../work_thread.zig");
const mods_act = @import("../../actions/mods.zig");

const Activity = activity_mod.Activity;
const ResultKind = activity_mod.ResultKind;

/// Every slice is owned by `arena`. The worker frees the job with
/// `deinit` when it ends (or when it never starts).
pub const PlanSimJob = struct {
    arena: *std.heap.ArenaAllocator,
    tid: u64,
    /// The modfile's archive on disk; null when the wizard has no
    /// modfile (or the modfile is not in the index).
    archive_path: ?[]u8,
    /// Install dir of the picked (or latest) install row; empty when
    /// the game has no install. The job peels the wrapper folder.
    install_path: []u8,
    /// Deep copy of the wizard's install blocks.
    steps: []recipe.InstallStep,
    /// `planInputHash` of the wizard state this job was built from.
    input_hash: u64,

    pub const In = struct {
        tid: u64,
        archive_path: ?[]const u8,
        install_path: []const u8,
        steps: []const recipe.InstallStep,
        input_hash: u64,
    };

    /// Copies every input (including every step string) into a fresh
    /// arena on `alloc`.
    pub fn create(alloc: std.mem.Allocator, in: In) !PlanSimJob {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer {
            arena.deinit();
            alloc.destroy(arena);
        }
        const a = arena.allocator();
        const steps = try a.alloc(recipe.InstallStep, in.steps.len);
        for (in.steps, steps) |src, *dst| dst.* = try dupeStep(a, src);
        return .{
            .arena = arena,
            .tid = in.tid,
            .archive_path = if (in.archive_path) |p| try a.dupe(u8, p) else null,
            .install_path = try a.dupe(u8, in.install_path),
            .steps = steps,
            .input_hash = in.input_hash,
        };
    }

    pub fn deinit(self: PlanSimJob) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

fn dupeStep(a: std.mem.Allocator, s: recipe.InstallStep) !recipe.InstallStep {
    return switch (s) {
        .extract => |x| .{ .extract = .{ .to = try a.dupe(u8, x.to), .strip = x.strip } },
        .extract_inner => |x| .{ .extract_inner = .{
            .archive = try a.dupe(u8, x.archive),
            .to = try a.dupe(u8, x.to),
            .strip = x.strip,
        } },
        .copy => |x| .{ .copy = .{ .src = try a.dupe(u8, x.src), .dest = try a.dupe(u8, x.dest) } },
        .move => |x| .{ .move = .{ .src = try a.dupe(u8, x.src), .dest = try a.dupe(u8, x.dest) } },
        .delete => |x| .{ .delete = .{ .path = try a.dupe(u8, x.path) } },
        .chmod_x => |x| blk: {
            const paths = try a.alloc([]const u8, x.paths.len);
            for (x.paths, paths) |src, *dst| dst.* = try a.dupe(u8, src);
            break :blk .{ .chmod_x = .{ .paths = paths } };
        },
    };
}

/// What the UI thread gets back. Every slice (and `sim`'s arena) is
/// owned by the worker's allocator (`Deps.alloc`); free with
/// `freeOutcome`.
pub const PlanSimOutcome = struct {
    /// Null when there is no archive, no install, or the simulation
    /// failed.
    sim: ?installer.SimulationResult = null,
    /// The job had an archive path to look at.
    archive_linked: bool = false,
    /// The archive could be listed (false: not readable from disk).
    archive_ok: bool = false,
    /// Sorted top-level folder names of the archive.
    archive_dirs: [][]u8 = &.{},
    /// Sorted top-level folder names of the resolved game root.
    install_dirs: [][]u8 = &.{},
    input_hash: u64 = 0,
};

pub fn freeOutcome(alloc: std.mem.Allocator, o: *PlanSimOutcome) void {
    if (o.sim) |*s| s.deinit();
    mods_act.freeTopDirs(alloc, o.archive_dirs);
    mods_act.freeTopDirs(alloc, o.install_dirs);
    o.* = .{};
}

/// What `run` hands back. It never returns an error: every failure
/// shows as a missing part of the outcome, so the editor always gets a
/// result and clears its "updating" flag.
pub const Ran = struct {
    outcome: PlanSimOutcome,
    kind: ResultKind,
    msg: []const u8,
};

/// Runs the preview for `job` on the compute thread.
pub fn run(deps: work_thread.Deps, job: PlanSimJob, a: *Activity, buf: []u8) anyerror!Ran {
    _ = a;
    _ = buf;
    return .{ .outcome = compute(deps.alloc, deps.io, job), .kind = .ok, .msg = "Plan checked." };
}

/// The disk part of the preview. `alloc` owns the outcome.
pub fn compute(alloc: std.mem.Allocator, io: std.Io, job: PlanSimJob) PlanSimOutcome {
    var out: PlanSimOutcome = .{ .input_hash = job.input_hash, .archive_linked = job.archive_path != null };

    // Game root: F95 archives often nest the game one folder deep, and
    // mods target the game's content tree, not the bare extract.
    const root: ?[]u8 = if (job.install_path.len > 0)
        mods_act.resolveGameRoot(io, job.install_path, alloc) catch null
    else
        null;
    defer if (root) |r| alloc.free(r);

    if (job.archive_path) |p| {
        if (mods_act.archiveTopDirs(alloc, p)) |dirs| {
            out.archive_dirs = dirs;
            out.archive_ok = true;
        }
    }

    if (job.install_path.len > 0) {
        out.install_dirs = mods_act.installTopDirs(alloc, io, root orelse job.install_path) orelse &.{};
    }

    if (job.archive_path) |p| if (root) |r| {
        out.sim = mods_act.simulatePlan(alloc, io, p, job.steps, r);
    };
    return out;
}
