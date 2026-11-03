//! UI-side cache of small files and directory listings, filled by the
//! I/O thread. A frame never reads a file itself: `get` returns the
//! cached bytes, or null and sends one `read_file` request on the first
//! miss. The reply arrives on the next drain (`actions.drainThreads`
//! hands every `.io` reply to `onReply`) and the next frame sees it.
//!
//! What it remembers:
//!   - a file that exists: its bytes;
//!   - a file that is missing (or failed to read): `missing`, so a
//!     missing `.t` thumb is asked for once, not once per frame;
//!   - a request in flight: `pending` with its ticket.
//! Every entry stays until `invalidate` (or eviction). Code that writes
//! a cached file must invalidate its path.
//!
//! Limits: 256 file entries / 64 MiB of bytes and 64 directory
//! listings, least recently used out first. Pending entries are never
//! evicted and are not counted.
//!
//! Lifetimes: a slice from `get` / `getDir` stays valid until the next
//! `onReply` (eviction) or `invalidate*` call. Use it inside the frame
//! and do not keep it.
//!
//! UI thread only (`owner` asserts it in Debug).

const std = @import("std");
const thread_owner = @import("util_thread_owner");
const io_thread = @import("threads/io_thread.zig");

const IoThread = io_thread.IoThread;
const IoRequest = io_thread.IoRequest;
const IoReply = io_thread.IoReply;
pub const DirEntry = io_thread.DirEntry;

const log = std.log.scoped(.file_cache);

pub const max_entries: usize = 256;
pub const max_bytes: usize = 64 * 1024 * 1024;
pub const max_dirs: usize = 64;
/// Size cap of one `get` read. Larger files reply "File is too large"
/// and are remembered as missing.
pub const default_max: usize = 8 * 1024 * 1024;
/// First ticket of the cache. Tickets of other I/O-thread users stay
/// below this, so a reply is never taken for the wrong request.
pub const ticket_base: u64 = 1 << 62;

/// How the cache queues a request. Production uses the I/O thread; unit
/// tests pass a recorder.
pub const Sender = struct {
    ctx: *anyopaque,
    send: *const fn (ctx: *anyopaque, req: IoRequest) anyerror!void,

    fn ioThreadSend(ctx: *anyopaque, req: IoRequest) anyerror!void {
        const t: *IoThread = @ptrCast(@alignCast(ctx));
        return t.send(req);
    }

    pub fn ioThread(t: *IoThread) Sender {
        return .{ .ctx = t, .send = ioThreadSend };
    }
};

pub const FileCache = struct {
    /// Must be the allocator the I/O thread allocates replies with: the
    /// cache keeps reply bytes / entries and frees them later.
    alloc: std.mem.Allocator,
    sender: Sender,
    next_ticket: u64 = ticket_base,
    files: std.StringHashMapUnmanaged(FileSlot) = .empty,
    dirs: std.StringHashMapUnmanaged(DirSlot) = .empty,
    /// LRU clock: every hit stamps the entry with the next value.
    clock: u64 = 0,
    /// Sum of the cached file bytes.
    bytes_total: usize = 0,
    owner: thread_owner.Owner = .{},

    pub const Entry = union(enum) {
        pending: u64,
        bytes: []u8,
        missing: void,
    };

    pub const DirListing = union(enum) {
        pending: u64,
        /// Empty when the folder is missing or could not be read.
        entries: []DirEntry,
    };

    const FileSlot = struct { entry: Entry, used: u64 };
    const DirSlot = struct { entry: DirListing, used: u64 };

    pub fn init(alloc: std.mem.Allocator, t: *IoThread) FileCache {
        return initWithSender(alloc, Sender.ioThread(t));
    }

    pub fn initWithSender(alloc: std.mem.Allocator, sender: Sender) FileCache {
        var self: FileCache = .{ .alloc = alloc, .sender = sender };
        self.owner.claim();
        return self;
    }

    pub fn deinit(self: *FileCache) void {
        var it = self.files.iterator();
        while (it.next()) |kv| {
            self.freeEntry(kv.value_ptr.entry);
            self.alloc.free(kv.key_ptr.*);
        }
        self.files.deinit(self.alloc);
        var dit = self.dirs.iterator();
        while (dit.next()) |kv| {
            freeListing(self.alloc, kv.value_ptr.entry);
            self.alloc.free(kv.key_ptr.*);
        }
        self.dirs.deinit(self.alloc);
        self.bytes_total = 0;
    }

    /// Bytes of `path`, or null while the read is pending or when the
    /// file is missing. The first call for a path sends the read.
    pub fn get(self: *FileCache, path: []const u8) ?[]const u8 {
        return self.getMax(path, default_max);
    }

    /// `get` with a size cap for the first read (later calls return
    /// what that read got).
    pub fn getMax(self: *FileCache, path: []const u8, max: usize) ?[]const u8 {
        self.owner.assert("FileCache.get");
        self.clock += 1;
        if (self.files.getPtr(path)) |s| {
            s.used = self.clock;
            return switch (s.entry) {
                .bytes => |b| b,
                .pending, .missing => null,
            };
        }
        const key = self.alloc.dupe(u8, path) catch return null;
        const ticket = self.takeTicket();
        self.files.put(self.alloc, key, .{ .entry = .{ .pending = ticket }, .used = self.clock }) catch {
            self.alloc.free(key);
            return null;
        };
        self.sender.send(self.sender.ctx, .{ .read_file = .{ .ticket = ticket, .path = key, .max = max } }) catch |e| {
            // Remember the failure: asking again every frame would fail
            // the same way (the I/O thread is stopped, or out of memory).
            log.warn("read of {s} not queued: {s}", .{ path, @errorName(e) });
            self.files.getPtr(key).?.entry = .missing;
        };
        return null;
    }

    /// Every entry (files and folders) of the folder at `path`, or null
    /// while the listing is pending. A missing folder lists as empty.
    pub fn getDir(self: *FileCache, path: []const u8) ?[]const DirEntry {
        self.owner.assert("FileCache.getDir");
        self.clock += 1;
        if (self.dirs.getPtr(path)) |s| {
            s.used = self.clock;
            return switch (s.entry) {
                .entries => |e| e,
                .pending => null,
            };
        }
        const key = self.alloc.dupe(u8, path) catch return null;
        const ticket = self.takeTicket();
        self.dirs.put(self.alloc, key, .{ .entry = .{ .pending = ticket }, .used = self.clock }) catch {
            self.alloc.free(key);
            return null;
        };
        self.sender.send(self.sender.ctx, .{ .list_dir = .{ .ticket = ticket, .path = key, .kinds = .{} } }) catch |e| {
            log.warn("listing of {s} not queued: {s}", .{ path, @errorName(e) });
            self.dirs.getPtr(key).?.entry = .{ .entries = &.{} };
        };
        return null;
    }

    /// Forgets `path` (file and folder listing). The next `get` /
    /// `getDir` reads it again. A reply still in flight for it is then
    /// not consumed by `onReply`, and the caller frees it.
    pub fn invalidate(self: *FileCache, path: []const u8) void {
        self.owner.assert("FileCache.invalidate");
        self.removeFile(path);
        if (self.dirs.fetchRemove(path)) |kv| {
            freeListing(self.alloc, kv.value.entry);
            self.alloc.free(kv.key);
        }
    }

    /// `path` may be the map's own key: it is not used after the free.
    fn removeFile(self: *FileCache, path: []const u8) void {
        if (self.files.fetchRemove(path)) |kv| {
            self.freeEntry(kv.value.entry);
            self.alloc.free(kv.key);
        }
    }

    /// Forgets every file entry whose path starts with `prefix` (for
    /// example all thumbs of one game: "<covers>/<tid>.").
    pub fn invalidatePrefix(self: *FileCache, prefix: []const u8) void {
        self.owner.assert("FileCache.invalidatePrefix");
        while (self.findFileKey(prefix, .prefix)) |k| self.removeFile(k);
    }

    /// Forgets every file entry whose path ends with `suffix`.
    pub fn invalidateSuffix(self: *FileCache, suffix: []const u8) void {
        self.owner.assert("FileCache.invalidateSuffix");
        while (self.findFileKey(suffix, .suffix)) |k| self.removeFile(k);
    }

    /// Takes the reply when it answers one of the cache's pending
    /// requests and returns true: the cache then owns the reply's bytes
    /// or entries. Returns false for any other reply; the caller still
    /// owns it and must free it.
    pub fn onReply(self: *FileCache, r: IoReply) bool {
        self.owner.assert("FileCache.onReply");
        switch (r) {
            .file => |f| {
                const s = findPending(FileSlot, &self.files, f.ticket) orelse return false;
                self.clock += 1;
                s.used = self.clock;
                if (f.bytes) |b| {
                    s.entry = .{ .bytes = b };
                    self.bytes_total += b.len;
                } else {
                    if (f.err) |e| log.debug("read failed: {s}", .{e});
                    s.entry = .missing;
                }
                self.evictFiles();
                return true;
            },
            .dir => |d| {
                const s = findPending(DirSlot, &self.dirs, d.ticket) orelse return false;
                self.clock += 1;
                s.used = self.clock;
                // A failed listing has an empty `entries`: store it as is.
                s.entry = .{ .entries = d.entries };
                self.evictDirs();
                return true;
            },
            .install_probe, .done => return false,
        }
    }

    /// Number of file entries that are not pending.
    pub fn readyFileCount(self: *const FileCache) usize {
        var n: usize = 0;
        var it = self.files.valueIterator();
        while (it.next()) |s| {
            if (s.entry != .pending) n += 1;
        }
        return n;
    }

    fn takeTicket(self: *FileCache) u64 {
        const t = self.next_ticket;
        self.next_ticket += 1;
        return t;
    }

    fn freeEntry(self: *FileCache, e: Entry) void {
        switch (e) {
            .bytes => |b| {
                self.bytes_total -= b.len;
                self.alloc.free(b);
            },
            .pending, .missing => {},
        }
    }

    fn freeListing(alloc: std.mem.Allocator, l: DirListing) void {
        switch (l) {
            .entries => |es| {
                for (es) |e| alloc.free(e.name);
                alloc.free(es);
            },
            .pending => {},
        }
    }

    fn findPending(comptime Slot: type, map: *std.StringHashMapUnmanaged(Slot), ticket: u64) ?*Slot {
        var it = map.valueIterator();
        while (it.next()) |s| switch (s.entry) {
            .pending => |t| if (t == ticket) return s,
            else => {},
        };
        return null;
    }

    fn findFileKey(self: *FileCache, affix: []const u8, comptime where: enum { prefix, suffix }) ?[]const u8 {
        var it = self.files.keyIterator();
        while (it.next()) |k| {
            const hit = switch (where) {
                .prefix => std.mem.startsWith(u8, k.*, affix),
                .suffix => std.mem.endsWith(u8, k.*, affix),
            };
            if (hit) return k.*;
        }
        return null;
    }

    /// Evicts least recently used non-pending files until both limits hold.
    fn evictFiles(self: *FileCache) void {
        while (self.readyFileCount() > max_entries or self.bytes_total > max_bytes) {
            var oldest: ?[]const u8 = null;
            var oldest_used: u64 = std.math.maxInt(u64);
            var it = self.files.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.entry == .pending) continue;
                if (kv.value_ptr.used < oldest_used) {
                    oldest_used = kv.value_ptr.used;
                    oldest = kv.key_ptr.*;
                }
            }
            self.removeFile(oldest orelse return);
        }
    }

    fn evictDirs(self: *FileCache) void {
        while (true) {
            var ready: usize = 0;
            var oldest: ?[]const u8 = null;
            var oldest_used: u64 = std.math.maxInt(u64);
            var it = self.dirs.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.entry == .pending) continue;
                ready += 1;
                if (kv.value_ptr.used < oldest_used) {
                    oldest_used = kv.value_ptr.used;
                    oldest = kv.key_ptr.*;
                }
            }
            if (ready <= max_dirs) return;
            const kv = self.dirs.fetchRemove(oldest.?).?;
            freeListing(self.alloc, kv.value.entry);
            self.alloc.free(kv.key);
        }
    }
};

// ============================================================
//  Tests: a recorder stands in for the I/O thread.
// ============================================================

const testing = std.testing;

const Recorder = struct {
    reqs: std.ArrayList(Req) = .empty,
    fail: bool = false,

    const Req = struct { ticket: u64, path: []u8, dir: bool };

    fn send(ctx: *anyopaque, req: IoRequest) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.Closed;
        switch (req) {
            .read_file => |r| try self.reqs.append(testing.allocator, .{ .ticket = r.ticket, .path = try testing.allocator.dupe(u8, r.path), .dir = false }),
            .list_dir => |r| try self.reqs.append(testing.allocator, .{ .ticket = r.ticket, .path = try testing.allocator.dupe(u8, r.path), .dir = true }),
            else => return error.Unexpected,
        }
    }

    fn sender(self: *Recorder) Sender {
        return .{ .ctx = self, .send = send };
    }

    fn deinit(self: *Recorder) void {
        for (self.reqs.items) |r| testing.allocator.free(r.path);
        self.reqs.deinit(testing.allocator);
    }

    fn last(self: *Recorder) Req {
        return self.reqs.items[self.reqs.items.len - 1];
    }
};

fn fileReply(ticket: u64, text: ?[]const u8) !IoReply {
    const bytes: ?[]u8 = if (text) |t| try testing.allocator.dupe(u8, t) else null;
    return .{ .file = .{ .ticket = ticket, .bytes = bytes, .missing = text == null, .err = null } };
}

test "FileCache: a miss returns null and sends one read" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var c = FileCache.initWithSender(testing.allocator, rec.sender());
    defer c.deinit();

    try testing.expect(c.get("/x/a.t") == null);
    try testing.expectEqual(@as(usize, 1), rec.reqs.items.len);
    try testing.expectEqualStrings("/x/a.t", rec.last().path);
    try testing.expect(rec.last().ticket >= ticket_base);
    // Still pending: no second request.
    try testing.expect(c.get("/x/a.t") == null);
    try testing.expectEqual(@as(usize, 1), rec.reqs.items.len);
}

test "FileCache: a bytes reply is returned by get without a new read" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var c = FileCache.initWithSender(testing.allocator, rec.sender());
    defer c.deinit();

    _ = c.get("/x/a.t");
    try testing.expect(c.onReply(try fileReply(rec.last().ticket, "abc")));
    try testing.expectEqualStrings("abc", c.get("/x/a.t").?);
    try testing.expectEqualStrings("abc", c.get("/x/a.t").?);
    try testing.expectEqual(@as(usize, 1), rec.reqs.items.len);
    try testing.expectEqual(@as(usize, 3), c.bytes_total);
}

test "FileCache: a missing reply is remembered and not asked again" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var c = FileCache.initWithSender(testing.allocator, rec.sender());
    defer c.deinit();

    _ = c.get("/x/gone.t");
    try testing.expect(c.onReply(try fileReply(rec.last().ticket, null)));
    var i: usize = 0;
    while (i < 10) : (i += 1) try testing.expect(c.get("/x/gone.t") == null);
    try testing.expectEqual(@as(usize, 1), rec.reqs.items.len);
}

test "FileCache: invalidate makes the next get read again" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var c = FileCache.initWithSender(testing.allocator, rec.sender());
    defer c.deinit();

    _ = c.get("/x/a.t");
    try testing.expect(c.onReply(try fileReply(rec.last().ticket, "old")));
    c.invalidate("/x/a.t");
    try testing.expectEqual(@as(usize, 0), c.bytes_total);
    try testing.expect(c.get("/x/a.t") == null);
    try testing.expectEqual(@as(usize, 2), rec.reqs.items.len);
    try testing.expect(c.onReply(try fileReply(rec.last().ticket, "new")));
    try testing.expectEqualStrings("new", c.get("/x/a.t").?);
}

test "FileCache: a reply for an invalidated pending read is not consumed" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var c = FileCache.initWithSender(testing.allocator, rec.sender());
    defer c.deinit();

    _ = c.get("/x/a.t");
    const stale = rec.last().ticket;
    c.invalidate("/x/a.t");
    const r = try fileReply(stale, "stale");
    try testing.expect(!c.onReply(r));
    io_thread.freeReply(testing.allocator, r);
    // Replies of other I/O-thread users are not taken either.
    try testing.expect(!c.onReply(.{ .done = .{ .ticket = stale, .err = null } }));
}

test "FileCache: invalidatePrefix drops every thumb of one game only" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var c = FileCache.initWithSender(testing.allocator, rec.sender());
    defer c.deinit();

    for ([_][]const u8{ "/c/7.t", "/c/7.s1.t", "/c/7.s2.t", "/c/77.t" }) |p| {
        _ = c.get(p);
        try testing.expect(c.onReply(try fileReply(rec.last().ticket, "x")));
    }
    c.invalidatePrefix("/c/7.");
    try testing.expectEqual(@as(usize, 1), c.readyFileCount());
    try testing.expect(c.get("/c/77.t") != null);
}

test "FileCache: LRU evicts the oldest ready entry beyond 256, never a pending one" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var c = FileCache.initWithSender(testing.allocator, rec.sender());
    defer c.deinit();

    // A pending entry made first (the oldest stamp) must survive.
    _ = c.get("/p/pending");
    const pending_ticket = rec.last().ticket;

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < max_entries) : (i += 1) {
        const p = try std.fmt.bufPrint(&buf, "/f/{d}", .{i});
        _ = c.get(p);
        try testing.expect(c.onReply(try fileReply(rec.last().ticket, "b")));
    }
    try testing.expectEqual(max_entries, c.readyFileCount());
    // Touch /f/0 so /f/1 is now the least recently used.
    try testing.expect(c.get("/f/0") != null);
    _ = c.get("/f/new");
    try testing.expect(c.onReply(try fileReply(rec.last().ticket, "b")));
    try testing.expectEqual(max_entries, c.readyFileCount());
    try testing.expect(c.get("/f/0") != null);
    try testing.expect(c.files.get("/f/1") == null);
    try testing.expect(c.files.get("/p/pending").?.entry == .pending);
    try testing.expect(c.onReply(try fileReply(pending_ticket, "late")));
    try testing.expectEqualStrings("late", c.get("/p/pending").?);
}

test "FileCache: getDir lists once; a failed send is remembered" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var c = FileCache.initWithSender(testing.allocator, rec.sender());
    defer c.deinit();

    try testing.expect(c.getDir("/g") == null);
    try testing.expect(rec.last().dir);
    const entries = try testing.allocator.alloc(DirEntry, 1);
    entries[0] = .{ .name = try testing.allocator.dupe(u8, "walk.pdf"), .kind = .file };
    try testing.expect(c.onReply(.{ .dir = .{ .ticket = rec.last().ticket, .entries = entries, .err = null } }));
    try testing.expectEqualStrings("walk.pdf", c.getDir("/g").?[0].name);
    try testing.expectEqual(@as(usize, 1), rec.reqs.items.len);

    rec.fail = true;
    try testing.expect(c.get("/closed") == null);
    try testing.expect(c.get("/closed") == null);
    try testing.expectEqual(@as(usize, 1), rec.reqs.items.len);
}
