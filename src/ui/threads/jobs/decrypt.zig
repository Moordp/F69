//! "Decrypt RPGM assets" as a compute job. The UI thread reads the
//! install row on click and copies the install path into a `DecryptJob`;
//! this file does every disk step on the compute thread: find the
//! System.json `encryptionKey`, walk the install for encrypted assets,
//! and write decrypted copies (.png/.ogg/.m4a) next to the originals.
//!
//! Non-destructive: originals are kept, so the game keeps running. The
//! pure cipher + filename logic lives in util/rpgm_crypt.zig.

const std = @import("std");
const Io = std.Io;
const rpgm = @import("util_rpgm_crypt");
const activity_mod = @import("../activity.zig");
const work_thread = @import("../work_thread.zig");

const Activity = activity_mod.Activity;
const ResultKind = activity_mod.ResultKind;

const log = std.log.scoped(.decrypt_job);

/// Every slice is owned by `arena`. The worker frees the job with
/// `deinit` when it ends (or when it never starts).
pub const DecryptJob = struct {
    arena: *std.heap.ArenaAllocator,
    tid: u64,
    install_path: []u8,
    name: []u8,

    /// Copies every input into a fresh arena on `alloc`.
    pub fn create(alloc: std.mem.Allocator, tid: u64, install_path: []const u8, name: []const u8) !DecryptJob {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer {
            arena.deinit();
            alloc.destroy(arena);
        }
        const a = arena.allocator();
        return .{
            .arena = arena,
            .tid = tid,
            .install_path = try a.dupe(u8, install_path),
            .name = try a.dupe(u8, name),
        };
    }

    pub fn deinit(self: DecryptJob) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

/// What the UI thread gets back. Owns nothing.
pub const DecryptOutcome = struct { count: u32 };

/// What `run` hands back when it does not return an error. Only a
/// cancel is returned as `error.Cancelled`.
pub const Ran = struct {
    outcome: DecryptOutcome,
    kind: ResultKind,
    msg: []const u8,
};

/// Relative paths (to `root`) of every file whose name
/// `rpgm.decryptedName` maps, in walk order. Slices are owned by `alloc`.
fn collectCandidates(io: Io, alloc: std.mem.Allocator, root: []const u8) ![][]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .access_sub_paths = true, .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        var nbuf: [512]u8 = undefined;
        _ = rpgm.decryptedName(&nbuf, std.fs.path.basename(entry.path)) orelse continue;
        try out.append(alloc, try alloc.dupe(u8, entry.path));
    }
    return out.toOwnedSlice(alloc);
}

/// Number of files under `root` whose name marks an encrypted RPGM
/// asset (`.rpgmvp`, `.png_`, ...). Does not read the files.
pub fn countDecryptCandidates(io: Io, alloc: std.mem.Allocator, root: []const u8) !u32 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const list = try collectCandidates(io, arena.allocator(), root);
    return @intCast(list.len);
}

/// Runs the decrypt for `job` on the compute thread. `buf` holds the
/// result text.
pub fn run(deps: work_thread.Deps, job: DecryptJob, a: *Activity, buf: []u8) anyerror!Ran {
    const io = deps.io;
    const alloc = deps.alloc;
    const scratch = job.arena.allocator();
    const root = job.install_path;
    var out: DecryptOutcome = .{ .count = 0 };

    const key = findKey(alloc, io, root) orelse
        return .{ .outcome = out, .kind = .err, .msg = "Decrypt: couldn't find System.json encryptionKey." };
    if (a.cancelled()) return error.Cancelled;

    a.setPhase(io, "Counting files");
    const list = collectCandidates(io, scratch, root) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .outcome = out, .kind = .err, .msg = "Decrypt: couldn't open the install directory." },
    };
    const n = list.len;
    a.files.store(true, .release);
    a.report(0, n);

    for (list, 0..) |rel, idx| {
        if (a.cancelled()) return error.Cancelled;
        var pbuf: [64]u8 = undefined;
        const phase = std.fmt.bufPrint(&pbuf, "Decrypting file {d} / {d}", .{ idx + 1, n }) catch "Decrypting";
        a.setPhase(io, phase);

        var nbuf: [512]u8 = undefined;
        const new_base = rpgm.decryptedName(&nbuf, std.fs.path.basename(rel)) orelse continue;
        var src_buf: [1024]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ root, rel }) catch continue;
        var dst_buf: [1024]u8 = undefined;
        const dst_path = if (std.fs.path.dirname(rel)) |d|
            std.fmt.bufPrint(&dst_buf, "{s}/{s}/{s}", .{ root, d, new_base }) catch continue
        else
            std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ root, new_base }) catch continue;

        if (decryptOne(alloc, io, src_path, dst_path, key)) {
            out.count += 1;
        } else |e| {
            log.warn("decrypt {s} failed: {s}", .{ rel, @errorName(e) });
        }
        a.report(idx + 1, n);
    }

    if (out.count == 0) return .{ .outcome = out, .kind = .warn, .msg = "No encrypted RPGM assets found." };
    const msg = std.fmt.bufPrint(buf, "Decrypted {d} RPGM asset(s) — originals kept.", .{out.count}) catch "Decrypt complete.";
    return .{ .outcome = out, .kind = .ok, .msg = msg };
}

fn decryptOne(alloc: std.mem.Allocator, io: Io, src: []const u8, dst: []const u8, key: [rpgm.KEY_LEN]u8) !void {
    const data = try Io.Dir.cwd().readFileAlloc(io, src, alloc, .limited(512 * 1024 * 1024));
    defer alloc.free(data);
    const dec = try rpgm.decrypt(alloc, data, key); // NotEncrypted/OutOfMemory
    defer alloc.free(dec);

    var f = try Io.Dir.cwd().createFile(io, dst, .{ .truncate = true });
    defer f.close(io);
    var wbuf: [64 * 1024]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    try fw.interface.writeAll(dec);
    try fw.interface.flush();
}

/// Locate System.json and parse its encryptionKey. Tries the common MV/MZ
/// locations first, then walks the tree as a fallback.
fn findKey(alloc: std.mem.Allocator, io: Io, root: []const u8) ?[rpgm.KEY_LEN]u8 {
    const candidates = [_][]const u8{
        "www/data/System.json",
        "data/System.json",
        "www/System.json",
        "System.json",
    };
    for (candidates) |rel| {
        if (readKeyAt(alloc, io, root, rel)) |k| return k;
    }

    var dir = Io.Dir.cwd().openDir(io, root, .{ .access_sub_paths = true, .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(alloc) catch return null;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), "System.json")) continue;
        if (readKeyAt(alloc, io, root, entry.path)) |k| return k;
    }
    return null;
}

fn readKeyAt(alloc: std.mem.Allocator, io: Io, root: []const u8, rel: []const u8) ?[rpgm.KEY_LEN]u8 {
    var pbuf: [1024]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ root, rel }) catch return null;
    const bytes = Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(8 * 1024 * 1024)) catch return null;
    defer alloc.free(bytes);
    return rpgm.keyFromSystemJson(alloc, bytes);
}

test "countDecryptCandidates: counts encrypted-asset names only" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.rpgmvp", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.png_", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try std.testing.expectEqual(@as(u32, 2), try countDecryptCandidates(io, gpa, root));
}

test "DecryptJob: create copies inputs; deinit frees them" {
    var raw = "lib/1".*;
    const job = try DecryptJob.create(std.testing.allocator, 3, &raw, "G");
    defer job.deinit();
    raw[0] = 'X';
    try std.testing.expectEqualStrings("lib/1", job.install_path);
    try std.testing.expectEqualStrings("G", job.name);
    try std.testing.expectEqual(@as(u64, 3), job.tid);
}
