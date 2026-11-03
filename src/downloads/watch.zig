//! Watched-folder scanner for the browser ("manual") engine: finds files the
//! user downloaded by hand and matches them to jobs waiting for one.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// Seconds a file's size must stay unchanged before it counts as finished.
pub const stable_secs: i64 = 3;

const temp_suffixes = [_][]const u8{ ".part", ".crdownload", ".partial", ".tmp", ".download", ".opdownload" };

/// Names a browser (or the OS) uses for unfinished or hidden files.
pub fn isTempName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.' or name[0] == '~') return true;
    for (temp_suffixes) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    }
    return false;
}

pub const Candidate = struct { path: []const u8, name: []const u8, size: u64, mtime: i64 };
pub const Waiting = struct { job_id: u64, expected_name: ?[]const u8, expected_size: ?u64, since: i64 };
pub const Match = struct { job_id: u64, candidate_idx: usize, confidence: enum { name, size, only_one } };

/// Spec 3.5 order: (1) exact expected name (case-insensitive), (2) equal
/// expected size, (3) exactly one waiting job. Candidates older than the
/// oldest waiting job are ignored; among several, the oldest wins. A
/// `.only_one` match is a guess: the caller must ask the user.
pub fn matchFile(cands: []const Candidate, waiting: []const Waiting) ?Match {
    if (waiting.len == 0) return null;
    var min_since = waiting[0].since;
    for (waiting[1..]) |w| min_since = @min(min_since, w.since);

    // Candidate indices visited oldest first.
    var best_name: ?Match = null;
    var best_size: ?Match = null;
    var best_name_mtime: i64 = 0;
    var best_size_mtime: i64 = 0;
    var oldest_any: ?usize = null;
    for (cands, 0..) |c, i| {
        if (c.mtime < min_since) continue;
        if (oldest_any == null or c.mtime < cands[oldest_any.?].mtime) oldest_any = i;
        for (waiting) |w| {
            if (w.expected_name) |n| {
                if (std.ascii.eqlIgnoreCase(n, c.name) and (best_name == null or c.mtime < best_name_mtime)) {
                    best_name = .{ .job_id = w.job_id, .candidate_idx = i, .confidence = .name };
                    best_name_mtime = c.mtime;
                }
            }
            if (w.expected_size) |sz| {
                if (sz == c.size and (best_size == null or c.mtime < best_size_mtime)) {
                    best_size = .{ .job_id = w.job_id, .candidate_idx = i, .confidence = .size };
                    best_size_mtime = c.mtime;
                }
            }
        }
    }
    if (best_name) |m| return m;
    if (best_size) |m| return m;
    if (waiting.len == 1) {
        if (oldest_any) |i| return .{ .job_id = waiting[0].job_id, .candidate_idx = i, .confidence = .only_one };
    }
    return null;
}

pub fn freeCandidates(alloc: Allocator, cands: []Candidate) void {
    for (cands) |c| alloc.free(c.path); // `name` points into `path`
    alloc.free(cands);
}

const Seen = struct { size: u64, first_seen_at: i64 };

pub const Scanner = struct {
    alloc: Allocator,
    io: std.Io,
    dir: []const u8,
    seen: std.StringHashMapUnmanaged(Seen) = .empty,

    pub fn init(alloc: Allocator, io: std.Io, dir: []const u8) Scanner {
        return .{ .alloc = alloc, .io = io, .dir = dir };
    }

    pub fn deinit(self: *Scanner) void {
        var it = self.seen.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.seen.deinit(self.alloc);
    }

    /// Files whose size has not changed since the previous scan and that
    /// were first seen at this size at least `stable_secs` ago and can be
    /// opened exclusively. Caller frees with `freeCandidates`.
    pub fn scan(self: *Scanner, now: i64) ![]Candidate {
        var out: std.ArrayList(Candidate) = .empty;
        errdefer {
            for (out.items) |c| self.alloc.free(c.path);
            out.deinit(self.alloc);
        }
        var present: std.StringHashMapUnmanaged(void) = .empty;
        defer present.deinit(self.alloc);

        var d = std.Io.Dir.cwd().openDir(self.io, self.dir, .{ .iterate = true }) catch {
            self.forgetAll();
            return out.toOwnedSlice(self.alloc);
        };
        defer d.close(self.io);

        var it = d.iterate();
        while (it.next(self.io) catch null) |e| {
            if (e.kind != .file or isTempName(e.name)) continue;
            const st = d.statFile(self.io, e.name, .{}) catch continue;
            const mtime = st.mtime.toSeconds();

            const gop = try self.seen.getOrPut(self.alloc, e.name);
            var unchanged = false;
            if (gop.found_existing) {
                unchanged = gop.value_ptr.size == st.size;
                if (!unchanged) gop.value_ptr.* = .{ .size = st.size, .first_seen_at = now };
            } else {
                errdefer _ = self.seen.remove(e.name);
                gop.key_ptr.* = try self.alloc.dupe(u8, e.name);
                gop.value_ptr.* = .{ .size = st.size, .first_seen_at = now };
            }
            try present.put(self.alloc, gop.key_ptr.*, {});
            if (!unchanged or now - gop.value_ptr.first_seen_at < stable_secs) continue;

            const path = try std.fs.path.join(self.alloc, &.{ self.dir, e.name });
            if (!openExclusive(self.io, path)) {
                self.alloc.free(path);
                continue;
            }
            errdefer self.alloc.free(path);
            try out.append(self.alloc, .{
                .path = path,
                .name = path[path.len - e.name.len ..],
                .size = st.size,
                .mtime = mtime,
            });
        }

        // Forget files that disappeared (moved, renamed after a download finished).
        var gone: std.ArrayList([]const u8) = .empty;
        defer gone.deinit(self.alloc);
        var kit = self.seen.keyIterator();
        while (kit.next()) |k| {
            if (!present.contains(k.*)) gone.append(self.alloc, k.*) catch break;
        }
        for (gone.items) |k| {
            _ = self.seen.remove(k);
            self.alloc.free(k);
        }
        return out.toOwnedSlice(self.alloc);
    }

    fn forgetAll(self: *Scanner) void {
        var it = self.seen.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.seen.clearRetainingCapacity();
    }
};

/// Linux: opening for reading is the check. Windows: open read/write with a
/// non-blocking exclusive lock, which fails while the browser still writes.
fn openExclusive(io: std.Io, path: []const u8) bool {
    const flags: std.Io.Dir.OpenFileOptions = if (builtin.os.tag == .windows)
        .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true }
    else
        .{ .mode = .read_only };
    const f = std.Io.Dir.cwd().openFile(io, path, flags) catch return false;
    f.close(io);
    return true;
}

/// Download folder to watch by default. Caller frees.
pub fn defaultWatchDir(alloc: Allocator, io: std.Io, environ: std.process.Environ) ![]u8 {
    if (builtin.os.tag == .windows) {
        const up = environ.getAlloc(alloc, "USERPROFILE") catch return error.NoHomeDir;
        defer alloc.free(up);
        return defaultWatchDirFromEnv(alloc, null, up, null, .windows);
    }
    const home = environ.getAlloc(alloc, "HOME") catch return error.NoHomeDir;
    defer alloc.free(home);
    const cfg = blk: {
        const xdg: ?[]u8 = environ.getAlloc(alloc, "XDG_CONFIG_HOME") catch null;
        defer if (xdg) |x| alloc.free(x);
        const p = (if (xdg) |x|
            std.fs.path.join(alloc, &.{ x, "user-dirs.dirs" })
        else
            std.fs.path.join(alloc, &.{ home, ".config", "user-dirs.dirs" })) catch break :blk null;
        defer alloc.free(p);
        break :blk std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(64 * 1024)) catch null;
    };
    defer if (cfg) |c| alloc.free(c);
    return defaultWatchDirFromEnv(alloc, home, null, cfg, builtin.os.tag);
}

/// Pure core of `defaultWatchDir`. `user_dirs_text` is the contents of
/// `~/.config/user-dirs.dirs` (Linux only). Caller frees.
pub fn defaultWatchDirFromEnv(
    alloc: Allocator,
    home: ?[]const u8,
    userprofile: ?[]const u8,
    user_dirs_text: ?[]const u8,
    os: std.Target.Os.Tag,
) ![]u8 {
    if (os == .windows) {
        const up = userprofile orelse return error.NoHomeDir;
        return std.fmt.allocPrint(alloc, "{s}\\Downloads", .{std.mem.trimEnd(u8, up, "\\/")});
    }
    if (user_dirs_text) |text| {
        if (xdgDownloadDir(alloc, home, text)) |p| return p else |_| {}
    }
    const h = home orelse return error.NoHomeDir;
    return std.fmt.allocPrint(alloc, "{s}/Downloads", .{std.mem.trimEnd(u8, h, "/")});
}

/// error.NotFound when the line is missing or unusable.
fn xdgDownloadDir(alloc: Allocator, home: ?[]const u8, text: []const u8) ![]u8 {
    const key = "XDG_DOWNLOAD_DIR=";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        var v = std.mem.trim(u8, line[key.len..], " \t");
        v = std.mem.trim(u8, v, "\"");
        var resolved: []u8 = undefined;
        if (std.mem.startsWith(u8, v, "$HOME") and (v.len == 5 or v[5] == '/')) {
            const h = home orelse return error.NotFound;
            resolved = try std.fmt.allocPrint(alloc, "{s}{s}", .{ std.mem.trimEnd(u8, h, "/"), v["$HOME".len..] });
        } else if (v.len > 0 and v[0] == '/') {
            resolved = try alloc.dupe(u8, v);
        } else return error.NotFound;
        errdefer alloc.free(resolved);
        // Trim a trailing slash ("$HOME/" means the home folder itself).
        var n = resolved.len;
        while (n > 1 and resolved[n - 1] == '/') n -= 1;
        if (n == resolved.len) return resolved;
        const trimmed = try alloc.dupe(u8, resolved[0..n]);
        alloc.free(resolved);
        return trimmed;
    }
    return error.NotFound;
}

pub const MovedPath = struct { path: []u8 };

/// Move `src` into `dest_dir` (created if missing). Rename first; across
/// mount points copy then delete the source. Caller frees `path`.
pub fn moveIntoDir(io: std.Io, alloc: Allocator, src: []const u8, dest_dir: []const u8) !MovedPath {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dest_dir);
    const dst = try uniqueDest(io, alloc, dest_dir, std.fs.path.basename(src));
    errdefer alloc.free(dst);
    cwd.rename(src, cwd, dst, io) catch |e| switch (e) {
        error.CrossDevice => {
            try copyFile(io, src, dst);
            cwd.deleteFile(io, src) catch {};
        },
        else => return e,
    };
    return .{ .path = dst };
}

/// `<dir>/<base>`, or `<dir>/<stem> (N).<ext>` when that already exists.
fn uniqueDest(io: std.Io, alloc: Allocator, dir: []const u8, base: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const first = try std.fs.path.join(alloc, &.{ dir, base });
    if (cwd.statFile(io, first, .{ .follow_symlinks = false })) |_| {} else |e| switch (e) {
        error.FileNotFound => return first,
        else => {
            alloc.free(first);
            return e;
        },
    }
    alloc.free(first);
    const ext = std.fs.path.extension(base);
    const stem = base[0 .. base.len - ext.len];
    var n: u32 = 2;
    while (n < 10_000) : (n += 1) {
        const name = try std.fmt.allocPrint(alloc, "{s} ({d}){s}", .{ stem, n, ext });
        defer alloc.free(name);
        const next = try std.fs.path.join(alloc, &.{ dir, name });
        if (cwd.statFile(io, next, .{ .follow_symlinks = false })) |_| {
            alloc.free(next);
        } else |e| switch (e) {
            error.FileNotFound => return next,
            else => {
                alloc.free(next);
                return e;
            },
        }
    }
    return error.PathAlreadyExists;
}

/// Copy `src` to a new file `dst`. On failure the partial `dst` is removed
/// after it is closed (Windows cannot delete an open file).
fn copyFile(io: std.Io, src: []const u8, dst: []const u8) !void {
    var in = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer in.close(io);
    var out = try std.Io.Dir.cwd().createFile(io, dst, .{ .exclusive = true });
    copyContents(io, &in, &out) catch |e| {
        out.close(io);
        std.Io.Dir.cwd().deleteFile(io, dst) catch {};
        return e;
    };
    out.close(io);
}

fn copyContents(io: std.Io, in: *std.Io.File, out: *std.Io.File) !void {
    var chunk: [64 * 1024]u8 = undefined;
    var fr_buf: [4096]u8 = undefined;
    var fw_buf: [4096]u8 = undefined;
    var fr = in.reader(io, &fr_buf);
    var fw = out.writer(io, &fw_buf);
    while (true) {
        const got = try fr.interface.readSliceShort(&chunk);
        if (got == 0) break;
        try fw.interface.writeAll(chunk[0..got]);
    }
    try fw.interface.flush();
}

test "isTempName table" {
    try testing.expect(isTempName("Game.zip.crdownload"));
    try testing.expect(isTempName("a.PART"));
    try testing.expect(isTempName("x.partial"));
    try testing.expect(isTempName("x.tmp"));
    try testing.expect(isTempName("x.download"));
    try testing.expect(isTempName("x.opdownload"));
    try testing.expect(isTempName(".hidden"));
    try testing.expect(isTempName("~lock"));
    try testing.expect(isTempName(""));
    try testing.expect(!isTempName("Game.zip"));
    try testing.expect(!isTempName("part.zip"));
}

fn cand(name: []const u8, size: u64, mtime: i64) Candidate {
    return .{ .path = name, .name = name, .size = size, .mtime = mtime };
}

test "matchFile: name beats size" {
    const cands = [_]Candidate{ cand("other.zip", 500, 100), cand("Game.ZIP", 10, 100) };
    const waiting = [_]Waiting{
        .{ .job_id = 1, .expected_name = null, .expected_size = 500, .since = 50 },
        .{ .job_id = 2, .expected_name = "game.zip", .expected_size = null, .since = 50 },
    };
    const m = matchFile(&cands, &waiting).?;
    try testing.expectEqual(@as(u64, 2), m.job_id);
    try testing.expectEqual(@as(usize, 1), m.candidate_idx);
    try testing.expect(m.confidence == .name);
}

test "matchFile: size match" {
    const cands = [_]Candidate{ cand("a.bin", 1, 100), cand("b.bin", 500, 100) };
    const waiting = [_]Waiting{
        .{ .job_id = 1, .expected_name = "zzz.zip", .expected_size = 500, .since = 50 },
        .{ .job_id = 2, .expected_name = null, .expected_size = null, .since = 50 },
    };
    const m = matchFile(&cands, &waiting).?;
    try testing.expectEqual(@as(u64, 1), m.job_id);
    try testing.expectEqual(@as(usize, 1), m.candidate_idx);
    try testing.expect(m.confidence == .size);
}

test "matchFile: only one waiting job" {
    const cands = [_]Candidate{cand("unrelated.zip", 7, 100)};
    const waiting = [_]Waiting{.{ .job_id = 9, .expected_name = "x.zip", .expected_size = null, .since = 50 }};
    const m = matchFile(&cands, &waiting).?;
    try testing.expectEqual(@as(u64, 9), m.job_id);
    try testing.expect(m.confidence == .only_one);
}

test "matchFile: two waiting, no match" {
    const cands = [_]Candidate{cand("unrelated.zip", 7, 100)};
    const waiting = [_]Waiting{
        .{ .job_id = 1, .expected_name = "x.zip", .expected_size = null, .since = 50 },
        .{ .job_id = 2, .expected_name = null, .expected_size = 99, .since = 50 },
    };
    try testing.expect(matchFile(&cands, &waiting) == null);
}

test "matchFile: candidates older than the oldest waiting job are ignored" {
    const cands = [_]Candidate{cand("x.zip", 7, 40)};
    const waiting = [_]Waiting{.{ .job_id = 1, .expected_name = "x.zip", .expected_size = null, .since = 50 }};
    try testing.expect(matchFile(&cands, &waiting) == null);
    try testing.expect(matchFile(&cands, &.{}) == null);
}

test "matchFile: several ready candidates, oldest first" {
    const cands = [_]Candidate{ cand("new.zip", 7, 300), cand("old.zip", 7, 100) };
    const waiting = [_]Waiting{.{ .job_id = 1, .expected_name = null, .expected_size = 7, .since = 50 }};
    const m = matchFile(&cands, &waiting).?;
    try testing.expectEqual(@as(usize, 1), m.candidate_idx);
}

test "Scanner: file stable across two scans 3 s apart" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Game.zip", .data = "abc" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Game.zip.crdownload", .data = "abc" });

    var sc = Scanner.init(testing.allocator, testing.io, dir);
    defer sc.deinit();

    const c1 = try sc.scan(1000);
    defer freeCandidates(testing.allocator, c1);
    try testing.expectEqual(@as(usize, 0), c1.len);

    // Still growing: size changed, timer restarts.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Game.zip", .data = "abcdef" });
    const c2 = try sc.scan(1003);
    defer freeCandidates(testing.allocator, c2);
    try testing.expectEqual(@as(usize, 0), c2.len);

    const c3 = try sc.scan(1005);
    defer freeCandidates(testing.allocator, c3);
    try testing.expectEqual(@as(usize, 0), c3.len); // only 2 s since the last change

    const c4 = try sc.scan(1006);
    defer freeCandidates(testing.allocator, c4);
    try testing.expectEqual(@as(usize, 1), c4.len);
    try testing.expectEqualStrings("Game.zip", c4[0].name);
    try testing.expectEqual(@as(u64, 6), c4[0].size);
    try testing.expect(std.mem.endsWith(u8, c4[0].path, "Game.zip"));
}

test "defaultWatchDirFromEnv linux prefers XDG_DOWNLOAD_DIR" {
    const a = testing.allocator;
    const t1 = try defaultWatchDirFromEnv(a, "/home/u", null,
        \\# comment
        \\XDG_DESKTOP_DIR="$HOME/Desktop"
        \\XDG_DOWNLOAD_DIR="$HOME/Dl"
        \\
    , .linux);
    defer a.free(t1);
    try testing.expectEqualStrings("/home/u/Dl", t1);

    const t2 = try defaultWatchDirFromEnv(a, "/home/u", null, "XDG_DOWNLOAD_DIR=\"/data/dl\"\n", .linux);
    defer a.free(t2);
    try testing.expectEqualStrings("/data/dl", t2);

    const t3 = try defaultWatchDirFromEnv(a, "/home/u", null, null, .linux);
    defer a.free(t3);
    try testing.expectEqualStrings("/home/u/Downloads", t3);

    const t4 = try defaultWatchDirFromEnv(a, "/home/u", null, "XDG_DOWNLOAD_DIR=\"$HOME/\"\n", .linux);
    defer a.free(t4);
    try testing.expectEqualStrings("/home/u", t4);

    try testing.expectError(error.NoHomeDir, defaultWatchDirFromEnv(a, null, null, null, .linux));
}

test "defaultWatchDirFromEnv windows uses USERPROFILE" {
    const t = try defaultWatchDirFromEnv(testing.allocator, null, "C:\\Users\\u", null, .windows);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("C:\\Users\\u\\Downloads", t);
}

test "uniqueDest: only FileNotFound means the name is free" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "afile", .data = "x" });
    // A free name in an existing dir is returned as is.
    const free = try uniqueDest(testing.io, testing.allocator, root, "new.zip");
    defer testing.allocator.free(free);
    try testing.expect(std.mem.endsWith(u8, free, "new.zip"));
    // "afile/x.zip": stat fails with NotDir, not FileNotFound; must be an error.
    const bad_dir = try std.fs.path.join(testing.allocator, &.{ root, "afile" });
    defer testing.allocator.free(bad_dir);
    try testing.expect(std.meta.isError(uniqueDest(testing.io, testing.allocator, bad_dir, "x.zip")));
}

test "copyFile: copies content and refuses an existing destination" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "abc" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "taken", .data = "old" });
    const a = try std.fs.path.join(testing.allocator, &.{ root, "a" });
    defer testing.allocator.free(a);
    const b = try std.fs.path.join(testing.allocator, &.{ root, "b" });
    defer testing.allocator.free(b);
    const taken = try std.fs.path.join(testing.allocator, &.{ root, "taken" });
    defer testing.allocator.free(taken);
    try copyFile(testing.io, a, b);
    const got = try tmp.dir.readFileAlloc(testing.io, "b", testing.allocator, .limited(10));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("abc", got);
    try testing.expect(std.meta.isError(copyFile(testing.io, a, taken)));
    // The pre-existing file must survive the failed copy.
    const old = try tmp.dir.readFileAlloc(testing.io, "taken", testing.allocator, .limited(10));
    defer testing.allocator.free(old);
    try testing.expectEqualStrings("old", old);
}

test "copyFile: a failing copy removes the partial destination" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(testing.io, "srcdir");
    const src = try std.fs.path.join(testing.allocator, &.{ root, "srcdir" });
    defer testing.allocator.free(src);
    const dst = try std.fs.path.join(testing.allocator, &.{ root, "out" });
    defer testing.allocator.free(dst);
    // Opening a directory succeeds, the first read fails: dst exists by then.
    try testing.expect(std.meta.isError(copyFile(testing.io, src, dst)));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "out", .{}));
}

test "moveIntoDir: same-filesystem rename" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(testing.io, "dest");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.zip", .data = "hello" });
    const src = try std.fs.path.join(testing.allocator, &.{ root, "f.zip" });
    defer testing.allocator.free(src);
    const dest = try std.fs.path.join(testing.allocator, &.{ root, "dest" });
    defer testing.allocator.free(dest);

    const moved = try moveIntoDir(testing.io, testing.allocator, src, dest);
    defer testing.allocator.free(moved.path);
    try testing.expect(std.mem.endsWith(u8, moved.path, "dest" ++ std.fs.path.sep_str ++ "f.zip"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "f.zip", .{}));
    const data = try tmp.dir.readFileAlloc(testing.io, "dest/f.zip", testing.allocator, .limited(100));
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("hello", data);
}

test "moveIntoDir: existing destination gets a unique name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(testing.io, "dest");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dest/f.zip", .data = "old" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.zip", .data = "new" });
    const src = try std.fs.path.join(testing.allocator, &.{ root, "f.zip" });
    defer testing.allocator.free(src);
    const dest = try std.fs.path.join(testing.allocator, &.{ root, "dest" });
    defer testing.allocator.free(dest);

    const moved = try moveIntoDir(testing.io, testing.allocator, src, dest);
    defer testing.allocator.free(moved.path);
    try testing.expect(std.mem.endsWith(u8, moved.path, "f (2).zip"));
    const old = try tmp.dir.readFileAlloc(testing.io, "dest/f.zip", testing.allocator, .limited(100));
    defer testing.allocator.free(old);
    try testing.expectEqualStrings("old", old);
    const new = try tmp.dir.readFileAlloc(testing.io, "dest/f (2).zip", testing.allocator, .limited(100));
    defer testing.allocator.free(new);
    try testing.expectEqualStrings("new", new);
}

test "defaultWatchDirFromEnv: $HOMEX is not expanded" {
    const t = try defaultWatchDirFromEnv(testing.allocator, "/home/u", null, "XDG_DOWNLOAD_DIR=\"$HOMEX/dl\"\n", .linux);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("/home/u/Downloads", t);
}

test "Scanner: unopenable file does not leak" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "locked.zip", .data = "abc" });
    try tmp.dir.setFilePermissions(testing.io, "locked.zip", .fromMode(0), .{});
    defer tmp.dir.setFilePermissions(testing.io, "locked.zip", .fromMode(0o644), .{}) catch {};
    // Running as root, open still succeeds: the skip branch is not reached.
    var probe = tmp.dir.openFile(testing.io, "locked.zip", .{}) catch null;
    if (probe) |*f| {
        f.close(testing.io);
        return error.SkipZigTest;
    }

    var sc = Scanner.init(testing.allocator, testing.io, dir);
    defer sc.deinit();
    const c1 = try sc.scan(1000);
    defer freeCandidates(testing.allocator, c1);
    const c2 = try sc.scan(1004);
    defer freeCandidates(testing.allocator, c2);
    try testing.expectEqual(@as(usize, 0), c2.len);
}
