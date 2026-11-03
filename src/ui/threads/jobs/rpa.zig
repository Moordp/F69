//! "Extract .rpa" as a compute job. The UI thread reads the install row
//! on click and copies the install path into an `RpaJob`; this file does
//! every disk step on the compute thread: find every `.rpa` archive in
//! the install, then write its entries as loose files next to it (Ren'Py
//! prefers loose files, so this makes assets and scripts moddable).
//! Non-destructive: the `.rpa` is kept.

const std = @import("std");
const Io = std.Io;
const rpa = @import("util_rpa");
const activity_mod = @import("../activity.zig");
const work_thread = @import("../work_thread.zig");

const Activity = activity_mod.Activity;
const ResultKind = activity_mod.ResultKind;

const log = std.log.scoped(.rpa_job);

/// Every slice is owned by `arena`. The worker frees the job with
/// `deinit` when it ends (or when it never starts).
pub const RpaJob = struct {
    arena: *std.heap.ArenaAllocator,
    tid: u64,
    install_path: []u8,
    name: []u8,

    /// Copies every input into a fresh arena on `alloc`.
    pub fn create(alloc: std.mem.Allocator, tid: u64, install_path: []const u8, name: []const u8) !RpaJob {
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

    pub fn deinit(self: RpaJob) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

/// What the UI thread gets back. Owns nothing.
pub const RpaOutcome = struct { files: u32, archives: u32 };

/// What `run` hands back when it does not return an error. Only a
/// cancel is returned as `error.Cancelled`.
pub const Ran = struct {
    outcome: RpaOutcome,
    kind: ResultKind,
    msg: []const u8,
};

/// Relative paths (to `root`) of every `.rpa` file, in walk order.
fn findArchives(io: Io, alloc: std.mem.Allocator, root: []const u8) ![][]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .access_sub_paths = true, .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.path, ".rpa")) continue;
        try out.append(alloc, try alloc.dupe(u8, entry.path));
    }
    return out.toOwnedSlice(alloc);
}

/// Runs the extract for `job` on the compute thread. `buf` holds the
/// result text.
pub fn run(deps: work_thread.Deps, job: RpaJob, a: *Activity, buf: []u8) anyerror!Ran {
    const io = deps.io;
    const root = job.install_path;
    var out: RpaOutcome = .{ .files = 0, .archives = 0 };

    a.setPhase(io, "Finding archives");
    const list = findArchives(io, job.arena.allocator(), root) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .outcome = out, .kind = .err, .msg = "Extract: couldn't open the install directory." },
    };
    a.files.store(true, .release);

    for (list, 0..) |rel, idx| {
        if (a.cancelled()) return error.Cancelled;
        var pbuf: [96]u8 = undefined;
        const phase = std.fmt.bufPrint(&pbuf, "Extracting {s} ({d} / {d})", .{ std.fs.path.basename(rel), idx + 1, list.len }) catch "Extracting";
        a.setPhase(io, phase);
        a.report(0, 0);

        var path_buf: [1024]u8 = undefined;
        const rpa_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, rel }) catch continue;
        var out_buf: [1024]u8 = undefined;
        const out_dir = std.fmt.bufPrint(&out_buf, "{s}/{s}", .{ root, std.fs.path.dirname(rel) orelse "" }) catch continue;

        const n = extractOne(deps.alloc, io, rpa_path, out_dir, a) catch |e| {
            if (e == error.Cancelled) return e;
            log.warn("extract {s} failed: {s}", .{ rel, @errorName(e) });
            continue;
        };
        out.archives += 1;
        out.files += n;
    }

    if (out.archives == 0) return .{ .outcome = out, .kind = .warn, .msg = "No .rpa archives found." };
    const msg = std.fmt.bufPrint(buf, "Extracted {d} files from {d} archives.", .{ out.files, out.archives }) catch "Extract complete.";
    return .{ .outcome = out, .kind = .ok, .msg = msg };
}

/// Writes every safe entry of one archive under `out_dir`. Reports
/// per-entry progress on `a` and stops with `error.Cancelled` between
/// entries once cancel is set.
fn extractOne(alloc: std.mem.Allocator, io: Io, rpa_path: []const u8, out_dir: []const u8, a: *Activity) !u32 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, rpa_path, alloc, .limited(2 * 1024 * 1024 * 1024));
    defer alloc.free(bytes);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const entries = try rpa.loadIndex(arena.allocator(), bytes);

    var n: u32 = 0;
    a.report(0, entries.len);
    for (entries, 0..) |e, i| {
        if (a.cancelled()) return error.Cancelled;
        defer a.report(i + 1, entries.len);
        if (!safeRelPath(e.name)) continue;
        const data_len = if (e.length >= e.prefix.len) e.length - e.prefix.len else 0;
        const start = e.offset;
        const end = start + data_len;
        if (end > bytes.len) continue; // corrupt / out-of-range entry

        var dst_buf: [1024]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ out_dir, e.name }) catch continue;
        if (std.fs.path.dirname(dst)) |d| Io.Dir.cwd().createDirPath(io, d) catch continue;

        var f = Io.Dir.cwd().createFile(io, dst, .{ .truncate = true }) catch continue;
        defer f.close(io);
        var wbuf: [64 * 1024]u8 = undefined;
        var fw = f.writer(io, &wbuf);
        fw.interface.writeAll(e.prefix) catch continue;
        fw.interface.writeAll(bytes[start..end]) catch continue;
        fw.interface.flush() catch continue;
        n += 1;
    }
    return n;
}

/// Reject absolute paths and any ".." segment — RPA names are untrusted.
fn safeRelPath(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '/' or name[0] == '\\') return false;
    return std.mem.indexOf(u8, name, "..") == null;
}

test "safeRelPath rejects absolute and parent paths" {
    try std.testing.expect(safeRelPath("images/a.png"));
    try std.testing.expect(!safeRelPath(""));
    try std.testing.expect(!safeRelPath("/etc/passwd"));
    try std.testing.expect(!safeRelPath("\\x"));
    try std.testing.expect(!safeRelPath("a/../b"));
}

test "RpaJob: create copies inputs; deinit frees them" {
    var raw = "lib/2".*;
    const job = try RpaJob.create(std.testing.allocator, 4, &raw, "R");
    defer job.deinit();
    raw[0] = 'X';
    try std.testing.expectEqualStrings("lib/2", job.install_path);
    try std.testing.expectEqualStrings("R", job.name);
}

test "run: an install with no .rpa warns \"No .rpa archives found.\"" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "script.rpy", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var book = activity_mod.Book.init(gpa, io);
    defer book.deinit();
    const a = try book.start(.rpa_extract, 1, "Extract RPA");
    const job = try RpaJob.create(gpa, 1, root, "G");
    defer job.deinit();
    var buf: [192]u8 = undefined;
    const r = try run(.{ .alloc = gpa, .io = io }, job, a, &buf);
    try std.testing.expectEqual(ResultKind.warn, r.kind);
    try std.testing.expectEqualStrings("No .rpa archives found.", r.msg);
}
