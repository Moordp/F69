//! What the user sees of a background job: title, phase text, progress,
//! cancel flag and final result. Workers write through the `Activity`
//! pointer (atomics, plus `phase_lock` for the phase text); the UI thread
//! reads a copy made by `Book.snapshot`.

const std = @import("std");
const downloads = @import("downloads");

pub const Kind = enum { convert, decrypt, compat_fix, rpa_extract, hash, reanalyse, plan_sim, folder_scan, mod_install, mod_uninstall, sign_in, launch_probe };
pub const Status = enum(u8) { queued, running, done, failed, cancelled };
pub const ResultKind = enum(u8) { ok, warn, err };

fn copyTrunc(dst: []u8, src: []const u8) u8 {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return @intCast(n);
}

pub const Activity = struct {
    id: u64,
    kind: Kind,
    game_thread_id: u64,
    /// Id of the job this activity mirrors in another queue (the mod
    /// queue job id for `mod_install` / `mod_uninstall`); 0 when none.
    /// Set before the activity is submitted; read-only afterwards.
    aux_id: u64 = 0,
    title: [128]u8 = undefined,
    title_len: u8 = 0,
    status: std.atomic.Value(u8) = .init(@intFromEnum(Status.queued)),
    phase_lock: std.Io.Mutex = .init,
    phase: [96]u8 = undefined,
    phase_len: u8 = 0,
    prog: downloads.progress.Atomic = .{},
    files: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    started_at: std.atomic.Value(i64) = .init(0),
    finished_at: std.atomic.Value(i64) = .init(0),
    result: [192]u8 = undefined,
    result_len: u8 = 0,
    result_kind: std.atomic.Value(u8) = .init(@intFromEnum(ResultKind.ok)),

    /// Copies up to 96 bytes of `text`.
    pub fn setPhase(self: *Activity, io: std.Io, text: []const u8) void {
        self.phase_lock.lockUncancelable(io);
        defer self.phase_lock.unlock(io);
        self.phase_len = copyTrunc(&self.phase, text);
    }

    /// Length of the phase text, read under `phase_lock`.
    pub fn phaseLen(self: *Activity, io: std.Io) u8 {
        self.phase_lock.lockUncancelable(io);
        defer self.phase_lock.unlock(io);
        return self.phase_len;
    }

    pub fn report(self: *Activity, done: u64, total: u64) void {
        self.prog.sink().report(done, total);
    }

    pub fn sink(self: *Activity) downloads.progress.Sink {
        return self.prog.sink();
    }

    pub fn markRunning(self: *Activity, now: i64) void {
        self.started_at.store(now, .release);
        self.status.store(@intFromEnum(Status.running), .release);
    }

    pub fn cancelled(self: *const Activity) bool {
        return self.cancel.load(.acquire);
    }

    pub fn statusGet(self: *const Activity) Status {
        return @enumFromInt(self.status.load(.acquire));
    }

    fn isLive(self: *const Activity) bool {
        const s = self.statusGet();
        return s == .queued or s == .running;
    }
};

pub const View = struct {
    id: u64,
    kind: Kind,
    game_thread_id: u64,
    aux_id: u64,
    title: []const u8,
    phase: []const u8,
    done: u64,
    total: u64,
    files: bool,
    status: Status,
    started_at: i64,
    finished_at: i64,
    result: []const u8,
    result_kind: ResultKind,
};

pub const Book = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    lock: std.Io.Mutex = .init,
    items: std.ArrayList(*Activity) = .empty,
    next_id: u64 = 1,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Book {
        return .{ .alloc = alloc, .io = io };
    }

    /// Frees every Activity. No worker may still hold a pointer.
    pub fn deinit(self: *Book) void {
        for (self.items.items) |a| self.alloc.destroy(a);
        self.items.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn start(self: *Book, kind: Kind, game_thread_id: u64, title: []const u8) !*Activity {
        const a = try self.alloc.create(Activity);
        errdefer self.alloc.destroy(a);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        a.* = .{ .id = self.next_id, .kind = kind, .game_thread_id = game_thread_id };
        a.title_len = copyTrunc(&a.title, title);
        try self.items.append(self.alloc, a);
        self.next_id += 1;
        return a;
    }

    pub fn finish(self: *Book, a: *Activity, kind: ResultKind, msg: []const u8, now: i64) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        a.result_len = copyTrunc(&a.result, msg);
        a.result_kind.store(@intFromEnum(kind), .release);
        a.finished_at.store(now, .release);
        const st: Status = if (kind == .err) .failed else if (a.cancelled()) .cancelled else .done;
        a.status.store(@intFromEnum(st), .release);
    }

    /// Copies every string into `arena`: live first (id ascending), then
    /// finished, newest `finished_at` first.
    pub fn snapshot(self: *Book, arena: std.mem.Allocator) ![]View {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        var out: std.ArrayList(View) = .empty;
        // Live pass (items are in id order), then finished pass.
        for ([_]bool{ true, false }) |want_live| {
            const first = out.items.len;
            for (self.items.items) |a| {
                if (a.isLive() != want_live) continue;
                try out.append(arena, try self.view(arena, a));
            }
            if (!want_live) std.mem.sort(View, out.items[first..], {}, newerFirst);
        }
        return out.toOwnedSlice(arena);
    }

    fn newerFirst(_: void, l: View, r: View) bool {
        if (l.finished_at != r.finished_at) return l.finished_at > r.finished_at;
        return l.id > r.id;
    }

    fn view(self: *Book, arena: std.mem.Allocator, a: *Activity) !View {
        const title = try arena.dupe(u8, a.title[0..a.title_len]);
        a.phase_lock.lockUncancelable(self.io);
        const phase = arena.dupe(u8, a.phase[0..a.phase_len]) catch |e| {
            a.phase_lock.unlock(self.io);
            return e;
        };
        a.phase_lock.unlock(self.io);
        const result = try arena.dupe(u8, a.result[0..a.result_len]);
        const p = a.prog.get();
        return .{
            .id = a.id,
            .kind = a.kind,
            .game_thread_id = a.game_thread_id,
            .aux_id = a.aux_id,
            .title = title,
            .phase = phase,
            .done = p.done,
            .total = p.total,
            .files = a.files.load(.acquire),
            .status = a.statusGet(),
            .started_at = a.started_at.load(.acquire),
            .finished_at = a.finished_at.load(.acquire),
            .result = result,
            .result_kind = @enumFromInt(a.result_kind.load(.acquire)),
        };
    }

    /// Removes a finished activity; live ones are ignored.
    pub fn remove(self: *Book, id: u64) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.items.items, 0..) |a, i| {
            if (a.id != id) continue;
            if (a.isLive()) return;
            _ = self.items.orderedRemove(i);
            self.alloc.destroy(a);
            return;
        }
    }

    pub fn anyLive(self: *Book) bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.items.items) |a| if (a.isLive()) return true;
        return false;
    }

    pub fn liveForGame(self: *Book, tid: u64) bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.items.items) |a| if (a.isLive() and a.game_thread_id == tid) return true;
        return false;
    }

    pub fn requestCancel(self: *Book, id: u64) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.items.items) |a| if (a.id == id) {
            a.cancel.store(true, .release);
            return;
        };
    }
};

test "Book: start → queued; markRunning; phase/progress visible in snapshot; finish ok → done; cancelled finish; remove only finished" {
    var book = Book.init(std.testing.allocator, std.testing.io);
    defer book.deinit();
    const a = try book.start(.decrypt, 42, "Decrypt · Eternal Dusk");
    try std.testing.expectEqual(Status.queued, a.statusGet());
    a.markRunning(1000);
    a.setPhase(std.testing.io, "Decrypting file 3 / 10");
    a.report(3, 10);
    a.files.store(true, .release);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try book.snapshot(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), v.len);
    try std.testing.expectEqualStrings("Decrypting file 3 / 10", v[0].phase);
    try std.testing.expectEqual(@as(u64, 3), v[0].done);
    try std.testing.expect(v[0].files);
    try std.testing.expect(book.anyLive() and book.liveForGame(42) and !book.liveForGame(7));
    book.remove(a.id); // live: ignored
    try std.testing.expectEqual(@as(usize, 1), book.items.items.len);
    book.finish(a, .ok, "Decrypted 10 files.", 1010);
    try std.testing.expectEqual(Status.done, a.statusGet());
    try std.testing.expect(!book.anyLive());
    const b = try book.start(.convert, 42, "Convert");
    book.requestCancel(b.id);
    try std.testing.expect(b.cancelled());
    book.finish(b, .warn, "Stopped.", 1020);
    try std.testing.expectEqual(Status.cancelled, b.statusGet());
    book.remove(a.id);
    try std.testing.expectEqual(@as(usize, 1), book.items.items.len);
}

test "Book: snapshot orders live first, then finished newest first; phase truncates at 96" {
    var book = Book.init(std.testing.allocator, std.testing.io);
    defer book.deinit();
    const old = try book.start(.hash, 1, "old");
    const newer = try book.start(.hash, 1, "newer");
    const live = try book.start(.folder_scan, 1, "live");
    book.finish(old, .ok, "x", 5);
    book.finish(newer, .err, "boom", 9);
    try std.testing.expectEqual(Status.failed, newer.statusGet());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try book.snapshot(arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), v.len);
    try std.testing.expectEqualStrings("live", v[0].title);
    try std.testing.expectEqualStrings("newer", v[1].title);
    try std.testing.expectEqualStrings("old", v[2].title);
    const long: [150]u8 = @splat('p');
    live.setPhase(std.testing.io, &long);
    try std.testing.expectEqual(@as(u8, 96), live.phase_len);
}
