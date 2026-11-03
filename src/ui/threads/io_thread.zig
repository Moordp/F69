//! I/O thread: serves file reads, directory listings, install probes and
//! tree copy / delete, one request at a time in FIFO order. Each request
//! carries a `ticket`; the reply comes back on the UI event mailbox as
//! `UiEvent.io` with the same ticket. The UI thread frees a reply with
//! `freeReply`.
//!
//! Ownership: `send` copies every string of the request into a per-request
//! arena, so the caller's buffers may die right after `send` returns.
//! Replies are allocated with the thread's allocator (the gpa). Every
//! `err` text in a reply is a static string and is never freed.

const std = @import("std");
const builtin = @import("builtin");
const convert = @import("convert");
const library = @import("library");
const Mailbox = @import("mailbox.zig").Mailbox;
const activity_mod = @import("activity.zig");
const events_mod = @import("events.zig");
const job_mod = @import("../job.zig");
const launch_act = @import("../actions/launch.zig");
const mods_act = @import("../actions/mods.zig");
const common = @import("../actions/common.zig");

const Activity = activity_mod.Activity;
const Events = events_mod.Events;
const sep = std.fs.path.sep_str;

const log = std.log.scoped(.io_thread);

pub const ListKinds = packed struct { files: bool = true, dirs: bool = true };

/// `name` is owned by the reply allocator.
pub const DirEntry = struct { name: []u8, kind: std.Io.File.Kind };

/// Everything `doLaunchGame` and the Tools tab probe about an install.
/// The launcher / exe paths are relative to `game_root`. Every slice is
/// owned by the reply allocator.
pub const InstallProbe = struct {
    game_root: []u8,
    linux_launcher: ?[]u8,
    windows_exe: ?[]u8,
    mkxp_zoom: ?f32,
    rgss: convert.rpgm.RgssVariant,
    engine: library.Engine,
};

pub const IoRequest = union(enum) {
    read_file: struct { ticket: u64, path: []const u8, max: usize },
    list_dir: struct { ticket: u64, path: []const u8, kinds: ListKinds },
    probe_install: struct { ticket: u64, install_path: []const u8 },
    /// `activity` (optional) gets phase "Copying file i / n" and progress
    /// (i, n). The caller owns it and must `book.finish` it on every
    /// `done` reply, including "Stopped." and "Stopped before it started.".
    /// Merges into `dst`: same-named files are overwritten, files only in
    /// `dst` stay; to replace, `delete_tree` first. A failed or cancelled
    /// copy leaves a partial `dst`. Symlinks are never followed: they are
    /// recreated as links on Linux and skipped (logged) on Windows.
    copy_tree: struct { ticket: u64, src: []const u8, dst: []const u8, activity: ?*Activity },
    delete_tree: struct { ticket: u64, path: []const u8, activity: ?*Activity },
    shutdown: void,
};

pub const IoReply = union(enum) {
    file: struct { ticket: u64, bytes: ?[]u8, missing: bool, err: ?[]const u8 },
    dir: struct { ticket: u64, entries: []DirEntry, err: ?[]const u8 },
    install_probe: struct { ticket: u64, info: ?InstallProbe, err: ?[]const u8 },
    done: struct { ticket: u64, err: ?[]const u8 },
};

/// Frees what `r` owns. `err` texts are static and are not freed.
pub fn freeReply(alloc: std.mem.Allocator, r: IoReply) void {
    switch (r) {
        .file => |f| if (f.bytes) |b| alloc.free(b),
        .dir => |d| {
            for (d.entries) |e| alloc.free(e.name);
            alloc.free(d.entries);
        },
        .install_probe => |p| if (p.info) |info| {
            alloc.free(info.game_root);
            if (info.linux_launcher) |s| alloc.free(s);
            if (info.windows_exe) |s| alloc.free(s);
        },
        .done => {},
    }
}

pub const Deps = struct {
    library_root: []const u8 = "",
    exe_dir: []const u8 = "",
    data_root: []const u8 = "",
};

const Queued = struct {
    arena: *std.heap.ArenaAllocator,
    req: IoRequest,

    fn deinit(self: Queued, alloc: std.mem.Allocator) void {
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

const stopped_text = "Stopped before it started.";
const cancelled_text = "Stopped.";

/// The I/O thread. `IoThread` must not move after `start`: the thread
/// holds a pointer to it.
///
/// Lifetime: same rule as `Worker`. If `stop` has to detach the thread
/// (a request ran longer than `join_budget_ms`), that thread keeps using
/// this `IoThread` and the `Events` until its request ends; `deinit` then
/// leaves `self.*` untouched and the owner must keep both alive. `done`
/// turns true when the thread has finished.
pub const IoThread = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    events: *Events,
    deps: Deps,
    mb: Mailbox(Queued),
    thread: ?std.Thread = null,
    /// Set by the thread as its last action; `stop` polls it.
    done: std.atomic.Value(bool) = .init(false),
    /// Guards `current` and `stopping`.
    lock: std.Io.Mutex = .init,
    /// Activity of the copy / delete that is running, if any. `stop`
    /// sets its cancel flag.
    current: ?*Activity = null,
    stopping: bool = false,
    /// The thread did not exit in time and was detached; it may still
    /// touch `mb`, so `deinit` must not free it.
    detached: bool = false,
    /// How long `stop` waits for the thread before detaching it.
    join_budget_ms: u32 = 3000,

    /// `alloc` must be the allocator `events` frees replies with
    /// (`freeEvent` / `drainThreads` use `events.alloc`).
    pub fn init(alloc: std.mem.Allocator, io: std.Io, events: *Events, deps: Deps) IoThread {
        std.debug.assert(alloc.ptr == events.alloc.ptr);
        return .{
            .alloc = alloc,
            .io = io,
            .events = events,
            .deps = deps,
            .mb = Mailbox(Queued).init(alloc, io),
        };
    }

    /// Stops the thread (if any) and frees the queue. If the thread was
    /// detached it still uses `self`, so nothing is freed or overwritten.
    pub fn deinit(self: *IoThread) void {
        self.stop();
        if (self.detached) return;
        self.mb.deinit();
        self.* = undefined;
    }

    /// Spawns the thread. Calling it again, or after `stop`, does nothing.
    pub fn start(self: *IoThread) !void {
        if (self.thread != null) return;
        self.lock.lockUncancelable(self.io);
        const stopping = self.stopping;
        self.lock.unlock(self.io);
        if (stopping) return;
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Cancels the running copy / delete, closes the queue, replies to
    /// every queued request with "Stopped before it started.", then waits
    /// up to `join_budget_ms` for the thread to exit. If it does not, the
    /// thread is detached. Idempotent.
    pub fn stop(self: *IoThread) void {
        self.lock.lockUncancelable(self.io);
        const already = self.stopping;
        self.stopping = true;
        if (self.current) |a| a.cancel.store(true, .release);
        self.lock.unlock(self.io);
        if (already) return;

        self.mb.close();
        while (self.mb.tryPop()) |q| self.dropUnstarted(q);

        const t = self.thread orelse return;
        self.thread = null;
        var waited_ms: u32 = 0;
        const step_ms: u32 = @max(1, @min(50, self.join_budget_ms));
        while (!self.done.load(.acquire) and waited_ms < self.join_budget_ms) : (waited_ms += step_ms) {
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(step_ms), .awake) catch {};
        }
        if (self.done.load(.acquire)) {
            t.join();
        } else {
            log.warn("I/O thread did not stop within {d} ms; detaching it", .{self.join_budget_ms});
            self.detached = true;
            t.detach();
        }
    }

    /// Queues `req`. Every string in it is copied, so the caller keeps
    /// ownership of its own buffers. `error.Closed` after `stop`.
    pub fn send(self: *IoThread, req: IoRequest) !void {
        self.lock.lockUncancelable(self.io);
        const stopping = self.stopping;
        self.lock.unlock(self.io);
        if (stopping) return error.Closed;

        const arena = try self.alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.alloc);
        const q: Queued = .{ .arena = arena, .req = copyRequest(arena.allocator(), req) catch |e| {
            arena.deinit();
            self.alloc.destroy(arena);
            return e;
        } };
        self.mb.push(q) catch |e| {
            q.deinit(self.alloc);
            return e;
        };
    }

    fn copyRequest(a: std.mem.Allocator, req: IoRequest) !IoRequest {
        return switch (req) {
            .read_file => |r| .{ .read_file = .{ .ticket = r.ticket, .path = try a.dupe(u8, r.path), .max = r.max } },
            .list_dir => |r| .{ .list_dir = .{ .ticket = r.ticket, .path = try a.dupe(u8, r.path), .kinds = r.kinds } },
            .probe_install => |r| .{ .probe_install = .{ .ticket = r.ticket, .install_path = try a.dupe(u8, r.install_path) } },
            .copy_tree => |r| .{ .copy_tree = .{
                .ticket = r.ticket,
                .src = try a.dupe(u8, r.src),
                .dst = try a.dupe(u8, r.dst),
                .activity = r.activity,
            } },
            .delete_tree => |r| .{ .delete_tree = .{ .ticket = r.ticket, .path = try a.dupe(u8, r.path), .activity = r.activity } },
            .shutdown => .shutdown,
        };
    }

    /// Replies to a request that will never run, then frees it.
    fn dropUnstarted(self: *IoThread, q: Queued) void {
        defer q.deinit(self.alloc);
        const reply: IoReply = switch (q.req) {
            .read_file => |r| .{ .file = .{ .ticket = r.ticket, .bytes = null, .missing = false, .err = stopped_text } },
            .list_dir => |r| .{ .dir = .{ .ticket = r.ticket, .entries = &.{}, .err = stopped_text } },
            .probe_install => |r| .{ .install_probe = .{ .ticket = r.ticket, .info = null, .err = stopped_text } },
            .copy_tree => |r| blk: {
                if (r.activity) |a| a.cancel.store(true, .release);
                break :blk .{ .done = .{ .ticket = r.ticket, .err = stopped_text } };
            },
            .delete_tree => |r| blk: {
                if (r.activity) |a| a.cancel.store(true, .release);
                break :blk .{ .done = .{ .ticket = r.ticket, .err = stopped_text } };
            },
            .shutdown => return,
        };
        self.events.push(.{ .io = reply });
    }

    fn threadMain(self: *IoThread) void {
        defer self.done.store(true, .release);
        job_mod.lowerWorkerPriority();
        while (self.mb.popWait()) |q| {
            if (q.req == .shutdown) {
                q.deinit(self.alloc);
                break;
            }
            self.lock.lockUncancelable(self.io);
            if (self.stopping) {
                self.lock.unlock(self.io);
                self.dropUnstarted(q);
                continue;
            }
            self.current = switch (q.req) {
                .copy_tree => |r| r.activity,
                .delete_tree => |r| r.activity,
                else => null,
            };
            self.lock.unlock(self.io);

            const reply = serve(self.alloc, self.io, q.req);
            q.deinit(self.alloc);

            self.lock.lockUncancelable(self.io);
            self.current = null;
            self.lock.unlock(self.io);

            if (reply) |r| self.events.push(.{ .io = r });
        }
    }
};

fn nowSeconds(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
}

/// Serves one request. Null only for `shutdown`.
fn serve(alloc: std.mem.Allocator, io: std.Io, req: IoRequest) ?IoReply {
    return switch (req) {
        .read_file => |r| readFile(alloc, io, r.ticket, r.path, r.max),
        .list_dir => |r| listDir(alloc, io, r.ticket, r.path, r.kinds),
        .probe_install => |r| probeInstall(alloc, io, r.ticket, r.install_path),
        .copy_tree => |r| .{ .done = .{ .ticket = r.ticket, .err = copyTree(alloc, io, r.src, r.dst, r.activity) } },
        .delete_tree => |r| .{ .done = .{ .ticket = r.ticket, .err = deleteTree(io, r.path, r.activity) } },
        .shutdown => null,
    };
}

fn readFile(alloc: std.mem.Allocator, io: std.Io, ticket: u64, path: []const u8, max: usize) IoReply {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max)) catch |e| {
        return .{ .file = .{
            .ticket = ticket,
            .bytes = null,
            .missing = e == error.FileNotFound,
            .err = if (e == error.FileNotFound) null else switch (e) {
                error.StreamTooLong => "File is too large",
                else => @errorName(e),
            },
        } };
    };
    return .{ .file = .{ .ticket = ticket, .bytes = bytes, .missing = false, .err = null } };
}

/// Kind of `entry`, asking the file system when readdir did not say
/// (FUSE NTFS / exFAT report every entry as `.unknown`). With
/// `follow = false` a symlink stays `.sym_link`, so a tree walk never
/// descends into a linked directory.
fn resolveKind(dir: std.Io.Dir, io: std.Io, entry: std.Io.Dir.Entry, follow: bool) std.Io.File.Kind {
    if (entry.kind != .unknown) return entry.kind;
    const st = dir.statFile(io, entry.name, .{ .follow_symlinks = follow }) catch return .unknown;
    return st.kind;
}

fn listDir(alloc: std.mem.Allocator, io: std.Io, ticket: u64, path: []const u8, kinds: ListKinds) IoReply {
    var out: std.ArrayList(DirEntry) = .empty;
    const err = listInto(alloc, io, path, kinds, &out);
    if (err != null) {
        for (out.items) |e| alloc.free(e.name);
        out.deinit(alloc);
        return .{ .dir = .{ .ticket = ticket, .entries = &.{}, .err = err } };
    }
    const entries = out.toOwnedSlice(alloc) catch {
        for (out.items) |e| alloc.free(e.name);
        out.deinit(alloc);
        return .{ .dir = .{ .ticket = ticket, .entries = &.{}, .err = "Out of memory" } };
    };
    return .{ .dir = .{ .ticket = ticket, .entries = entries, .err = null } };
}

fn listInto(alloc: std.mem.Allocator, io: std.Io, path: []const u8, kinds: ListKinds, out: *std.ArrayList(DirEntry)) ?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e| return @errorName(e);
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |e| return @errorName(e)) |entry| {
        const kind = resolveKind(dir, io, entry, true);
        const is_dir = kind == .directory;
        if (is_dir and !kinds.dirs) continue;
        if (!is_dir and !kinds.files) continue;
        const name = alloc.dupe(u8, entry.name) catch return "Out of memory";
        out.append(alloc, .{ .name = name, .kind = kind }) catch {
            alloc.free(name);
            return "Out of memory";
        };
    }
    return null;
}

fn probeInstall(alloc: std.mem.Allocator, io: std.Io, ticket: u64, install_path: []const u8) IoReply {
    const fail: IoReply = .{ .install_probe = .{ .ticket = ticket, .info = null, .err = "Out of memory" } };
    std.Io.Dir.cwd().access(io, install_path, .{}) catch
        return .{ .install_probe = .{ .ticket = ticket, .info = null, .err = "The install folder is gone" } };
    const root = mods_act.resolveGameRoot(io, install_path, alloc) catch return fail;
    var buf: [512]u8 = undefined;
    const lin: ?[]u8 = if (launch_act.findLinuxLauncher(io, alloc, root, &buf)) |s|
        (alloc.dupe(u8, s) catch {
            alloc.free(root);
            return fail;
        })
    else
        null;
    const win: ?[]u8 = if (launch_act.findWindowsExe(io, alloc, root, &buf)) |s|
        (alloc.dupe(u8, s) catch {
            alloc.free(root);
            if (lin) |l| alloc.free(l);
            return fail;
        })
    else
        null;
    return .{ .install_probe = .{ .ticket = ticket, .err = null, .info = .{
        .game_root = root,
        .linux_launcher = lin,
        .windows_exe = win,
        .mkxp_zoom = convert.rpgm.readMkxpZoom(io, root),
        .rgss = convert.rpgm.detectRgssVariant(io, root),
        .engine = convert.detectEngine(io, root),
    } } };
}

const Tree = struct {
    files: std.ArrayList([]const u8) = .empty,
    dirs: std.ArrayList([]const u8) = .empty,
    links: std.ArrayList([]const u8) = .empty,
};

/// Collects every path under `root_path` (relative, joined with the
/// native separator) into `tree`. Arena-owned. Symlinks go to
/// `tree.links` and are never followed.
fn collectTree(
    a: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    rel: []const u8,
    tree: *Tree,
) !void {
    const abs = if (rel.len == 0) root_path else try std.fmt.allocPrint(a, "{s}" ++ sep ++ "{s}", .{ root_path, rel });
    var dir = try std.Io.Dir.cwd().openDir(io, abs, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = if (rel.len == 0)
            try a.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(a, "{s}" ++ sep ++ "{s}", .{ rel, entry.name });
        switch (resolveKind(dir, io, entry, false)) {
            .directory => {
                try tree.dirs.append(a, child);
                try collectTree(a, io, root_path, child, tree);
            },
            .sym_link => try tree.links.append(a, child),
            else => try tree.files.append(a, child),
        }
    }
}

/// Copies the tree at `src` into `dst`. `dst` may already exist; files
/// in it are overwritten. Returns null on success, else a static error
/// text. Honours `activity.cancelled()` between files.
fn copyTree(alloc: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8, activity: ?*Activity) ?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    if (activity) |act| {
        act.markRunning(nowSeconds(io));
        act.setPhase(io, "Listing files");
    }
    var tree: Tree = .{};
    collectTree(a, io, src, "", &tree) catch |e| return switch (e) {
        error.FileNotFound => "The source folder is gone",
        else => @errorName(e),
    };
    std.Io.Dir.cwd().createDirPath(io, dst) catch |e| return @errorName(e);
    for (tree.dirs.items) |d| {
        const p = std.fmt.allocPrint(a, "{s}" ++ sep ++ "{s}", .{ dst, d }) catch return "Out of memory";
        std.Io.Dir.cwd().createDirPath(io, p) catch |e| return @errorName(e);
    }
    for (tree.links.items) |l| {
        if (copyLink(a, io, src, dst, l)) |err| return err;
    }
    const files = tree.files;
    const n: u64 = files.items.len;
    if (activity) |act| act.report(0, n);
    for (files.items, 0..) |f, i| {
        if (activity) |act| {
            if (act.cancelled()) return cancelled_text;
            var pbuf: [64]u8 = undefined;
            const phase = std.fmt.bufPrint(&pbuf, "Copying file {d} / {d}", .{ i + 1, n }) catch "Copying";
            act.setPhase(io, phase);
        }
        const from = std.fmt.allocPrint(a, "{s}" ++ sep ++ "{s}", .{ src, f }) catch return "Out of memory";
        const to = std.fmt.allocPrint(a, "{s}" ++ sep ++ "{s}", .{ dst, f }) catch return "Out of memory";
        common.copyFileProgress(io, from, to, .none) catch |e| {
            log.warn("copy {s} -> {s}: {s}", .{ from, to, @errorName(e) });
            return @errorName(e);
        };
        if (activity) |act| act.report(i + 1, n);
    }
    return null;
}

/// Recreates the symlink `src/rel` at `dst/rel` with the same target
/// text (a relative link stays relative). An existing entry at the
/// destination is replaced. Windows: links need a privilege and may be
/// junctions, so they are skipped with a log line.
fn copyLink(a: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8, rel: []const u8) ?[]const u8 {
    const from = std.fmt.allocPrint(a, "{s}" ++ sep ++ "{s}", .{ src, rel }) catch return "Out of memory";
    if (builtin.os.tag == .windows) {
        log.info("copy: skipping symlink {s} (not copied on Windows)", .{from});
        return null;
    }
    const to = std.fmt.allocPrint(a, "{s}" ++ sep ++ "{s}", .{ dst, rel }) catch return "Out of memory";
    var tbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tlen = std.Io.Dir.cwd().readLink(io, from, &tbuf) catch |e| {
        log.warn("copy: read symlink {s}: {s}", .{ from, @errorName(e) });
        return @errorName(e);
    };
    std.Io.Dir.cwd().deleteFile(io, to) catch |e| switch (e) {
        error.FileNotFound => {},
        else => {
            log.warn("copy: replace {s}: {s}", .{ to, @errorName(e) });
            return @errorName(e);
        },
    };
    std.Io.Dir.cwd().symLink(io, tbuf[0..tlen], to, .{}) catch |e| {
        log.warn("copy: symlink {s} -> {s}: {s}", .{ to, tbuf[0..tlen], @errorName(e) });
        return @errorName(e);
    };
    return null;
}

/// Deletes the tree at `path`. A missing path is not an error.
fn deleteTree(io: std.Io, path: []const u8, activity: ?*Activity) ?[]const u8 {
    if (activity) |act| {
        act.markRunning(nowSeconds(io));
        if (act.cancelled()) return cancelled_text;
        act.setPhase(io, "Deleting");
        act.report(0, 1);
    }
    std.Io.Dir.cwd().deleteTree(io, path) catch |e| return @errorName(e);
    if (activity) |act| act.report(1, 1);
    return null;
}

// ============================================================
//  tests
// ============================================================

const testing = std.testing;

const TestEnv = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    book: activity_mod.Book,
    ev: Events,
    t: IoThread,

    /// Heap-allocated so `t` never moves after `start`.
    fn create() !*TestEnv {
        const env = try createIdle();
        errdefer env.destroy();
        try env.t.start();
        return env;
    }

    /// Like `create`, but the thread is not started.
    fn createIdle() !*TestEnv {
        const alloc = testing.allocator;
        const io = testing.io;
        const env = try alloc.create(TestEnv);
        errdefer alloc.destroy(env);
        env.tmp = testing.tmpDir(.{});
        errdefer env.tmp.cleanup();
        env.root = try env.tmp.dir.realPathFileAlloc(io, ".", alloc);
        env.book = activity_mod.Book.init(alloc, io);
        env.ev = Events.init(alloc, io, null);
        env.t = IoThread.init(alloc, io, &env.ev, .{});
        return env;
    }

    fn destroy(env: *TestEnv) void {
        const alloc = testing.allocator;
        env.t.deinit();
        env.ev.deinit();
        env.book.deinit();
        alloc.free(env.root);
        env.tmp.cleanup();
        alloc.destroy(env);
    }

    fn path(env: *TestEnv, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}" ++ sep ++ "{s}", .{ env.root, rel });
    }

    fn write(env: *TestEnv, rel: []const u8, data: []const u8) !void {
        try env.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    fn mkdir(env: *TestEnv, rel: []const u8) !void {
        try env.tmp.dir.createDirPath(testing.io, rel);
    }

    /// Next `.io` reply. Bounded: each test expects few events.
    fn nextReply(env: *TestEnv) !IoReply {
        var n: usize = 0;
        while (n < 16) : (n += 1) {
            const e = env.ev.mb.popWait() orelse return error.TestUnexpectedResult;
            switch (e) {
                .io => |r| return r,
                else => events_mod.freeEvent(testing.allocator, e),
            }
        }
        return error.TestUnexpectedResult;
    }
};

fn exists(env: *TestEnv, rel: []const u8) bool {
    env.tmp.dir.access(testing.io, rel, .{}) catch return false;
    return true;
}

test "IoThread: read_file returns the bytes; a missing file is missing, not an error" {
    const env = try TestEnv.create();
    defer env.destroy();
    try env.write("a.txt", "hello");
    const p = try env.path("a.txt");
    defer testing.allocator.free(p);
    try env.t.send(.{ .read_file = .{ .ticket = 11, .path = p, .max = 1024 } });
    const missing = try env.path("nope.txt");
    defer testing.allocator.free(missing);
    try env.t.send(.{ .read_file = .{ .ticket = 12, .path = missing, .max = 1024 } });

    const r1 = try env.nextReply();
    defer freeReply(testing.allocator, r1);
    try testing.expectEqual(@as(u64, 11), r1.file.ticket);
    try testing.expectEqualStrings("hello", r1.file.bytes.?);
    try testing.expect(!r1.file.missing);
    try testing.expect(r1.file.err == null);

    const r2 = try env.nextReply();
    defer freeReply(testing.allocator, r2);
    try testing.expectEqual(@as(u64, 12), r2.file.ticket);
    try testing.expect(r2.file.missing);
    try testing.expect(r2.file.bytes == null);
    try testing.expect(r2.file.err == null);
}

test "IoThread: list_dir with dirs = false lists only the two files" {
    const env = try TestEnv.create();
    defer env.destroy();
    try env.mkdir("list");
    try env.write("list" ++ sep ++ "one.txt", "1");
    try env.write("list" ++ sep ++ "two.txt", "2");
    try env.mkdir("list" ++ sep ++ "sub");
    const p = try env.path("list");
    defer testing.allocator.free(p);
    try env.t.send(.{ .list_dir = .{ .ticket = 21, .path = p, .kinds = .{ .dirs = false } } });
    const r = try env.nextReply();
    defer freeReply(testing.allocator, r);
    try testing.expectEqual(@as(u64, 21), r.dir.ticket);
    try testing.expect(r.dir.err == null);
    try testing.expectEqual(@as(usize, 2), r.dir.entries.len);
    for (r.dir.entries) |e| {
        try testing.expectEqual(std.Io.File.Kind.file, e.kind);
        try testing.expect(std.mem.endsWith(u8, e.name, ".txt"));
    }
}

test "IoThread: probe_install on a Ren'Py install finds the launcher, exe and engine" {
    const env = try TestEnv.create();
    defer env.destroy();
    try env.mkdir("rp" ++ sep ++ "game");
    try env.mkdir("rp" ++ sep ++ "renpy");
    try env.write("rp" ++ sep ++ "Game.sh", "#!/bin/sh\n");
    try env.write("rp" ++ sep ++ "Game.exe", "MZ");
    const p = try env.path("rp");
    defer testing.allocator.free(p);
    try env.t.send(.{ .probe_install = .{ .ticket = 31, .install_path = p } });
    const r = try env.nextReply();
    defer freeReply(testing.allocator, r);
    try testing.expectEqual(@as(u64, 31), r.install_probe.ticket);
    try testing.expect(r.install_probe.err == null);
    const info = r.install_probe.info.?;
    try testing.expectEqualStrings(p, info.game_root);
    try testing.expectEqualStrings("Game.sh", info.linux_launcher.?);
    try testing.expectEqualStrings("Game.exe", info.windows_exe.?);
    try testing.expectEqual(library.Engine.renpy, info.engine);
    try testing.expectEqual(convert.rpgm.RgssVariant.unknown, info.rgss);
    try testing.expect(info.mkxp_zoom == null);
}

test "IoThread: copy_tree copies 5 files with progress, then delete_tree removes the copy" {
    const env = try TestEnv.create();
    defer env.destroy();
    try env.mkdir("src" ++ sep ++ "deep");
    try env.write("src" ++ sep ++ "f1", "1");
    try env.write("src" ++ sep ++ "f2", "22");
    try env.write("src" ++ sep ++ "f3", "333");
    try env.write("src" ++ sep ++ "deep" ++ sep ++ "f4", "4444");
    try env.write("src" ++ sep ++ "deep" ++ sep ++ "f5", "55555");
    // The destination already exists, with a file the copy overwrites.
    try env.mkdir("dst");
    try env.write("dst" ++ sep ++ "f1", "old contents");
    const src = try env.path("src");
    defer testing.allocator.free(src);
    const dst = try env.path("dst");
    defer testing.allocator.free(dst);

    const a = try env.book.start(.hash, 1, "copy");
    try env.t.send(.{ .copy_tree = .{ .ticket = 41, .src = src, .dst = dst, .activity = a } });
    const r = try env.nextReply();
    defer freeReply(testing.allocator, r);
    try testing.expectEqual(@as(u64, 41), r.done.ticket);
    try testing.expect(r.done.err == null);
    const prog = a.prog.get();
    try testing.expectEqual(@as(u64, 5), prog.done);
    try testing.expectEqual(@as(u64, 5), prog.total);
    try testing.expect(exists(env, "dst" ++ sep ++ "deep" ++ sep ++ "f5"));
    var buf: [32]u8 = undefined;
    const f1 = try env.tmp.dir.readFile(testing.io, "dst" ++ sep ++ "f1", &buf);
    try testing.expectEqualStrings("1", f1);

    const b = try env.book.start(.hash, 1, "delete");
    try env.t.send(.{ .delete_tree = .{ .ticket = 42, .path = dst, .activity = b } });
    const r2 = try env.nextReply();
    defer freeReply(testing.allocator, r2);
    try testing.expectEqual(@as(u64, 42), r2.done.ticket);
    try testing.expect(r2.done.err == null);
    try testing.expect(!exists(env, "dst"));
    try testing.expect(exists(env, "src" ++ sep ++ "f1"));
}

test "IoThread: copy_tree never follows symlinks; recreates them on Linux, no loop" {
    const env = try TestEnv.create();
    defer env.destroy();
    try env.mkdir("src" ++ sep ++ "sub");
    try env.write("src" ++ sep ++ "real.txt", "real");
    try env.write("src" ++ sep ++ "sub" ++ sep ++ "inner.txt", "inner");
    // A file link, and a directory link back to its parent (a loop if
    // the walk followed it).
    env.tmp.dir.symLink(testing.io, "real.txt", "src" ++ sep ++ "file_link", .{}) catch return error.SkipZigTest;
    env.tmp.dir.symLink(testing.io, "..", "src" ++ sep ++ "sub" ++ sep ++ "up", .{ .is_directory = true }) catch return error.SkipZigTest;
    const src = try env.path("src");
    defer testing.allocator.free(src);
    const dst = try env.path("dst");
    defer testing.allocator.free(dst);
    const a = try env.book.start(.hash, 1, "copy");
    try env.t.send(.{ .copy_tree = .{ .ticket = 61, .src = src, .dst = dst, .activity = a } });
    const r = try env.nextReply();
    defer freeReply(testing.allocator, r);
    try testing.expectEqual(@as(u64, 61), r.done.ticket);
    try testing.expect(r.done.err == null);
    // Only the two regular files count.
    try testing.expectEqual(@as(u64, 2), a.prog.get().total);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("real", try env.tmp.dir.readFile(testing.io, "dst" ++ sep ++ "real.txt", &buf));
    try testing.expectEqualStrings("inner", try env.tmp.dir.readFile(testing.io, "dst" ++ sep ++ "sub" ++ sep ++ "inner.txt", &buf));
    if (builtin.os.tag == .windows) {
        try testing.expect(!exists(env, "dst" ++ sep ++ "file_link"));
        try testing.expect(!exists(env, "dst" ++ sep ++ "sub" ++ sep ++ "up"));
    } else {
        var lbuf: [64]u8 = undefined;
        const n1 = try env.tmp.dir.readLink(testing.io, "dst" ++ sep ++ "file_link", &lbuf);
        try testing.expectEqualStrings("real.txt", lbuf[0..n1]);
        const n2 = try env.tmp.dir.readLink(testing.io, "dst" ++ sep ++ "sub" ++ sep ++ "up", &lbuf);
        try testing.expectEqualStrings("..", lbuf[0..n2]);
        // Copying again onto the existing links replaces them.
        try env.t.send(.{ .copy_tree = .{ .ticket = 62, .src = src, .dst = dst, .activity = null } });
        const r2 = try env.nextReply();
        defer freeReply(testing.allocator, r2);
        try testing.expect(r2.done.err == null);
    }
}

test "IoThread: a cancelled copy stops between files" {
    const env = try TestEnv.create();
    defer env.destroy();
    try env.mkdir("src");
    try env.write("src" ++ sep ++ "f1", "1");
    try env.write("src" ++ sep ++ "f2", "2");
    const src = try env.path("src");
    defer testing.allocator.free(src);
    const dst = try env.path("dst");
    defer testing.allocator.free(dst);
    const a = try env.book.start(.hash, 1, "copy");
    a.cancel.store(true, .release);
    try env.t.send(.{ .copy_tree = .{ .ticket = 51, .src = src, .dst = dst, .activity = a } });
    const r = try env.nextReply();
    defer freeReply(testing.allocator, r);
    try testing.expectEqual(@as(u64, 51), r.done.ticket);
    try testing.expectEqualStrings(cancelled_text, r.done.err.?);
    try testing.expectEqual(@as(u64, 0), a.prog.get().done);
}

test "IoThread: stop with pending requests returns within 3 s and replies to each" {
    const env = try TestEnv.create();
    defer env.destroy();
    try env.write("a.txt", "x");
    const p = try env.path("a.txt");
    defer testing.allocator.free(p);
    const count: u64 = 200;
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        try env.t.send(.{ .read_file = .{ .ticket = i, .path = p, .max = 16 } });
    }
    const t0 = std.Io.Clock.Timestamp.now(testing.io, .awake).raw.toMilliseconds();
    env.t.stop();
    const t1 = std.Io.Clock.Timestamp.now(testing.io, .awake).raw.toMilliseconds();
    try testing.expect(t1 - t0 < 3000);
    try testing.expect(!env.t.detached);
    try testing.expectError(error.Closed, env.t.send(.{ .read_file = .{ .ticket = 999, .path = p, .max = 16 } }));
    // Every request got exactly one reply, served or dropped.
    var left: std.ArrayList(events_mod.UiEvent) = .empty;
    defer left.deinit(testing.allocator);
    env.ev.drain(testing.allocator, &left);
    defer for (left.items) |e| events_mod.freeEvent(testing.allocator, e);
    try testing.expectEqual(@as(usize, count), left.items.len);
    var seen: [count]bool = @splat(false);
    for (left.items) |e| {
        const tk = e.io.file.ticket;
        try testing.expect(!seen[tk]);
        seen[tk] = true;
    }
}

test "IoThread: stop replies \"Stopped before it started.\" to every request that never ran" {
    const env = try TestEnv.createIdle();
    defer env.destroy();
    var i: u64 = 0;
    while (i < 3) : (i += 1) try env.t.send(.{ .read_file = .{ .ticket = i, .path = "x", .max = 1 } });
    try env.t.send(.{ .delete_tree = .{ .ticket = 3, .path = "x", .activity = null } });
    env.t.stop();
    var left: std.ArrayList(events_mod.UiEvent) = .empty;
    defer left.deinit(testing.allocator);
    env.ev.drain(testing.allocator, &left);
    defer for (left.items) |e| events_mod.freeEvent(testing.allocator, e);
    try testing.expectEqual(@as(usize, 4), left.items.len);
    for (left.items[0..3], 0..) |e, k| {
        try testing.expectEqual(@as(u64, k), e.io.file.ticket);
        try testing.expectEqualStrings(stopped_text, e.io.file.err.?);
    }
    try testing.expectEqualStrings(stopped_text, left.items[3].io.done.err.?);
}

test "IoThread: shutdown request ends the loop" {
    const env = try TestEnv.create();
    defer env.destroy();
    try env.t.send(.shutdown);
    var n: usize = 0;
    while (!env.t.done.load(.acquire) and n < 2000) : (n += 1) {
        std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(env.t.done.load(.acquire));
}

test "freeReply frees an empty dir reply and a probe without paths" {
    freeReply(testing.allocator, .{ .dir = .{ .ticket = 1, .entries = &.{}, .err = "x" } });
    freeReply(testing.allocator, .{ .install_probe = .{ .ticket = 2, .info = null, .err = null } });
}
