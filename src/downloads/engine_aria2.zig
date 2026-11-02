//! aria2-backed Engine: maps aria2 tellStatus onto model.Progress.
const std = @import("std");
const Io = std.Io;
const errs = @import("errors.zig");
const model = @import("model.zig");
const policy = @import("policy.zig");
const aria2_rpc = @import("aria2_rpc.zig");
const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const StartSpec = engine_mod.StartSpec;

const log = std.log.scoped(.aria2_engine);

/// Seconds a torrent must sit at 0 connections and 0 speed before it is
/// reported as `finding_peers`.
const finding_peers_after_s: i64 = 10;

/// Consecutive unreachable polls after which the daemon handle is dropped
/// so the next `ensureDaemon` spawns a fresh aria2c.
const daemon_gone_limit: u8 = 3;

pub const DaemonConfig = struct {
    aria2_path: []const u8,
    direct_root: []const u8,
    torrents_root: []const u8,
    session_path: ?[]const u8,
    port: u16,
    seed_ratio: f32,
    seed_time_min: u32,
};

const Tracked = struct {
    is_torrent: bool,
    peers_zero_since: ?i64 = null,
};

pub const Aria2Engine = struct {
    alloc: std.mem.Allocator,
    io: Io,
    cfg: DaemonConfig,
    daemon: ?aria2_rpc.Daemon = null,
    /// gid (owned key) -> class + peer-less timer.
    gids: std.StringHashMapUnmanaged(Tracked) = .empty,
    last_plan: ?policy.Plan = null,
    /// Last failure message handed out in a `Progress`; valid until the next poll.
    last_msg: ?[]u8 = null,
    /// Consecutive downloader ticks in which the daemon was unreachable.
    /// Reset by any poll that got an answer.
    gone_polls: u8 = 0,
    /// The gid whose unreachable polls are counted (owned). The
    /// downloader polls each gid once per tick, so counting only this
    /// gid counts ticks, not jobs: three active jobs in one slow tick
    /// count once.
    gone_anchor: ?[]u8 = null,

    pub fn init(alloc: std.mem.Allocator, io: Io, cfg: DaemonConfig) Aria2Engine {
        return .{ .alloc = alloc, .io = io, .cfg = cfg };
    }

    pub fn deinit(self: *Aria2Engine) void {
        var it = self.gids.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.gids.deinit(self.alloc);
        if (self.last_msg) |m| self.alloc.free(m);
        self.clearGone();
        if (self.daemon) |*d| d.deinit();
        self.daemon = null;
    }

    pub fn engine(self: *Aria2Engine) Engine {
        return .{ .ptr = self, .vt = &vtable };
    }

    pub fn daemonAlive(self: *const Aria2Engine) bool {
        return self.daemon != null;
    }

    /// Spawn aria2c on first use. The daemon-wide dir is `direct_root`;
    /// each `start` overrides it per transfer.
    pub fn ensureDaemon(self: *Aria2Engine) errs.Error!*aria2_rpc.Daemon {
        if (self.daemon == null) {
            self.daemon = try aria2_rpc.Daemon.init(
                self.alloc,
                self.io,
                self.cfg.aria2_path,
                self.cfg.direct_root,
                self.cfg.session_path,
                self.cfg.port,
                self.cfg.seed_ratio,
                self.cfg.seed_time_min,
            );
            log.info("aria2c daemon ready", .{});
        }
        return &self.daemon.?;
    }

    /// Pure status mapping. `peers_zero_since` is when the torrent last
    /// became peerless and idle (unix seconds); `now` is the current time.
    pub fn mapStatus(s: *const aria2_rpc.Status, peers_zero_since: ?i64, now: i64) model.Progress {
        var p: model.Progress = .{
            .phase = .downloading,
            .bytes_done = s.completed_length,
            .bytes_total = if (s.total_length > 0) s.total_length else null,
            .bytes_uploaded = s.upload_length,
            .dl_speed = s.download_speed,
            .ul_speed = s.upload_speed,
            .peers = s.connections,
            .seeders = s.num_seeders,
        };
        const st = s.status;
        if (std.mem.eql(u8, st, "complete")) {
            p.phase = .transfer_done;
        } else if (std.mem.eql(u8, st, "error")) {
            p.phase = .failed;
            p.fail = mapErrorCode(s.error_code);
            p.msg = s.error_message orelse "";
        } else if (std.mem.eql(u8, st, "removed")) {
            p.phase = .removed;
        } else if (std.mem.eql(u8, st, "paused")) {
            p.phase = .paused;
        } else if (std.mem.eql(u8, st, "waiting")) {
            p.phase = .queued;
        } else if (std.mem.eql(u8, st, "active") and s.is_torrent) {
            if (s.seeder) {
                p.phase = .seeding;
            } else if (peerless(s) and peers_zero_since != null and now - peers_zero_since.? >= finding_peers_after_s) {
                p.phase = .finding_peers;
            } else if (s.total_length == 0) {
                p.phase = .fetching_metadata;
            }
        }
        return p;
    }

    pub fn mapErrorCode(code: ?u32) model.FailReason {
        const c = code orelse return .unknown;
        return switch (c) {
            3, 4 => .host_gone,
            22, 24 => .auth_required,
            6, 7, 8 => .network,
            9 => .disk_full,
            else => .unknown,
        };
    }

    fn peerless(s: *const aria2_rpc.Status) bool {
        return s.connections == 0 and s.download_speed == 0;
    }

    const vtable: Engine.VTable = .{
        .start = startImpl,
        .poll = pollImpl,
        .pause = pauseImpl,
        .unpause = unpauseImpl,
        .cancel = cancelImpl,
        .finalPath = finalPathImpl,
        .setLimits = setLimitsImpl,
        .isAlive = isAliveImpl,
    };

    fn cast(p: *anyopaque) *Aria2Engine {
        return @ptrCast(@alignCast(p));
    }

    fn track(self: *Aria2Engine, gid: []const u8, is_torrent: bool) errs.Error!void {
        const key = self.alloc.dupe(u8, gid) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(key);
        const gop = self.gids.getOrPut(self.alloc, key) catch return errs.Error.OutOfMemory;
        if (gop.found_existing) self.alloc.free(key);
        gop.value_ptr.* = .{ .is_torrent = is_torrent };
    }

    /// Adopt-on-poll: refs this instance never started (restored after a
    /// restart) are inserted using the class aria2 reports, then the
    /// peerless timer is updated. Returns the timer for `mapStatus`.
    fn observe(self: *Aria2Engine, ref: []const u8, st: *const aria2_rpc.Status, now: i64) errs.Error!?i64 {
        if (!self.gids.contains(ref)) try self.track(ref, st.is_torrent);
        const t = self.gids.getPtr(ref).?;
        t.is_torrent = st.is_torrent;
        if (st.is_torrent and std.mem.eql(u8, st.status, "active") and peerless(st)) {
            if (t.peers_zero_since == null) t.peers_zero_since = now;
        } else {
            t.peers_zero_since = null;
        }
        return t.peers_zero_since;
    }

    /// Phases after which the gid is dead to us: it is dropped from the map
    /// so `setLimits` stops fanning out to it. Seeding torrents stay.
    fn isTerminal(phase: model.Phase) bool {
        return switch (phase) {
            .transfer_done, .failed, .removed => true,
            else => false,
        };
    }

    fn forget(self: *Aria2Engine, gid: []const u8) void {
        // A cancelled anchor would stop the count: the next gone gid
        // becomes the anchor instead (the streak itself is kept).
        if (self.gone_anchor) |a| if (std.mem.eql(u8, a, gid)) {
            self.alloc.free(a);
            self.gone_anchor = null;
        };
        if (self.gids.fetchRemove(gid)) |kv| self.alloc.free(kv.key);
    }

    fn startImpl(p: *anyopaque, spec: StartSpec) errs.Error![]u8 {
        const self = cast(p);
        const d = try self.ensureDaemon();
        Io.Dir.cwd().createDirPath(self.io, spec.dest_dir) catch |e| {
            log.warn("createDirPath '{s}' failed: {s}", .{ spec.dest_dir, @errorName(e) });
            return switch (e) {
                error.NoSpaceLeft, error.DiskQuota => errs.Error.DiskFull,
                else => errs.Error.NetworkError,
            };
        };
        const gid = if (spec.torrent_bytes) |bytes|
            try d.addTorrent(bytes, .{ .dir = spec.dest_dir })
        else
            try d.addUri(spec.url, .{
                .headers = spec.headers,
                .split = 8,
                .max_connection_per_server = 8,
                .retry_wait = 3,
                .dir = spec.dest_dir,
                .out = spec.out_name,
            });
        errdefer self.alloc.free(gid);
        try self.track(gid, spec.torrent_bytes != null);
        return gid;
    }

    fn pollImpl(p: *anyopaque, ref: []const u8) errs.Error!model.Progress {
        const self = cast(p);
        const d = try self.ensureDaemon();
        const now = std.Io.Clock.Timestamp.now(self.io, .real).raw.toSeconds();
        return self.absorb(ref, d.tellStatus(ref), now);
    }

    /// Turn a tellStatus result into a Progress plus map bookkeeping.
    /// Takes ownership of an ok Status. A gid aria2 no longer knows is
    /// reported `removed` and forgotten; other failures mean the daemon
    /// is unreachable.
    fn absorb(self: *Aria2Engine, ref: []const u8, result: errs.Error!aria2_rpc.Status, now: i64) errs.Error!model.Progress {
        var st = result catch |e| switch (e) {
            errs.Error.NotFound => {
                self.clearGone();
                self.forget(ref);
                return .{ .phase = .removed };
            },
            else => {
                self.noteGone(ref);
                return .{ .phase = .daemon_gone };
            },
        };
        defer st.deinit(self.alloc);
        self.clearGone();

        const since = try self.observe(ref, &st, now);
        var prog = mapStatus(&st, since, now);
        if (isTerminal(prog.phase)) self.forget(ref);
        // `msg` borrows from `st`, freed on return: keep a copy that lives
        // until the next poll.
        if (prog.msg.len > 0) {
            const copy = self.alloc.dupe(u8, prog.msg) catch return errs.Error.OutOfMemory;
            if (self.last_msg) |old| self.alloc.free(old);
            self.last_msg = copy;
            prog.msg = copy;
        }
        return prog;
    }

    fn clearGone(self: *Aria2Engine) void {
        self.gone_polls = 0;
        if (self.gone_anchor) |a| self.alloc.free(a);
        self.gone_anchor = null;
    }

    /// Count one unreachable tick: only polls of the anchor gid count
    /// (the first gid seen unreachable becomes the anchor). After
    /// `daemon_gone_limit` ticks in a row the daemon handle is dropped
    /// (its process is stopped by `deinit`), so the next `ensureDaemon`
    /// respawns aria2c. The plan is cleared so the limits are sent again
    /// to the new daemon.
    fn noteGone(self: *Aria2Engine, ref: []const u8) void {
        if (self.gone_anchor) |a| {
            if (!std.mem.eql(u8, a, ref)) return;
        } else {
            // On OOM there is no anchor: every poll counts (old behaviour).
            self.gone_anchor = self.alloc.dupe(u8, ref) catch null;
        }
        self.gone_polls +|= 1;
        if (self.gone_polls < daemon_gone_limit) return;
        log.warn("aria2c unreachable for {d} polls in a row; restarting it on next use", .{self.gone_polls});
        if (self.daemon) |*d| d.deinit();
        self.daemon = null;
        self.last_plan = null;
        self.clearGone();
    }

    fn pauseImpl(p: *anyopaque, ref: []const u8) errs.Error!void {
        const self = cast(p);
        return (try self.ensureDaemon()).pause(ref);
    }

    fn unpauseImpl(p: *anyopaque, ref: []const u8) errs.Error!void {
        const self = cast(p);
        return (try self.ensureDaemon()).unpause(ref);
    }

    fn cancelImpl(p: *anyopaque, ref: []const u8) errs.Error!void {
        const self = cast(p);
        defer self.forget(ref);
        const d = try self.ensureDaemon();
        d.remove(ref) catch |e| switch (e) {
            errs.Error.NotFound => {},
            else => return e,
        };
        d.removeDownloadResult(ref) catch |e| switch (e) {
            errs.Error.NotFound => {},
            else => return e,
        };
    }

    fn finalPathImpl(p: *anyopaque, alloc: std.mem.Allocator, ref: []const u8) errs.Error!?[]u8 {
        const self = cast(p);
        const d = try self.ensureDaemon();
        const path = try d.getFiles(ref);
        defer self.alloc.free(path);
        if (path.len == 0) return null;
        return alloc.dupe(u8, path) catch errs.Error.OutOfMemory;
    }

    fn setLimitsImpl(p: *anyopaque, plan: policy.Plan) errs.Error!void {
        const self = cast(p);
        if (self.last_plan) |lp| if (std.meta.eql(lp, plan)) return;
        const d = try self.ensureDaemon();
        var buf: [24]u8 = undefined;
        try d.changeGlobalOption("max-overall-download-limit", fmtLimit(&buf, plan.aria2_global_down));
        try d.changeGlobalOption("max-overall-upload-limit", fmtLimit(&buf, plan.aria2_global_up));
        // Seed targets: only when they changed (a fresh daemon got them on
        // its command line). aria2 reads `seed-time=0` as "stop seeding at
        // once", so a 0 cap (meaning "no cap") is never sent.
        const seed_changed = if (self.last_plan) |lp|
            lp.seed_ratio != plan.seed_ratio or lp.seed_time_min != plan.seed_time_min
        else
            plan.seed_ratio != self.cfg.seed_ratio or plan.seed_time_min != self.cfg.seed_time_min;
        var ratio_buf: [24]u8 = undefined;
        const ratio_s = std.fmt.bufPrint(&ratio_buf, "{d:.2}", .{@max(plan.seed_ratio, 1.0)}) catch unreachable;
        if (seed_changed) {
            try d.changeGlobalOption("seed-ratio", ratio_s);
            if (plan.seed_time_min > 0) try d.changeGlobalOption("seed-time", fmtLimit(&buf, plan.seed_time_min));
        }
        // Gids aria2 no longer knows are forgotten after the loop; any other
        // failure (e.g. a rejected limit) propagates so the plan is retried.
        var dead: std.ArrayList([]const u8) = .empty;
        defer dead.deinit(self.alloc);
        var it = self.gids.iterator();
        while (it.next()) |kv| {
            const lim = if (kv.value_ptr.is_torrent) plan.per_torrent_down else plan.per_file_down;
            d.changeOption(kv.key_ptr.*, "max-download-limit", fmtLimit(&buf, lim)) catch |e| switch (e) {
                errs.Error.NotFound => {
                    dead.append(self.alloc, kv.key_ptr.*) catch return errs.Error.OutOfMemory;
                    continue;
                },
                else => return e,
            };
            if (seed_changed and kv.value_ptr.is_torrent) {
                // Best effort: a torrent that already finished may refuse.
                d.changeOption(kv.key_ptr.*, "seed-ratio", ratio_s) catch |e|
                    log.warn("seed-ratio for {s} not changed: {s}", .{ kv.key_ptr.*, @errorName(e) });
                if (plan.seed_time_min > 0) d.changeOption(kv.key_ptr.*, "seed-time", fmtLimit(&buf, plan.seed_time_min)) catch |e|
                    log.warn("seed-time for {s} not changed: {s}", .{ kv.key_ptr.*, @errorName(e) });
            }
        }
        for (dead.items) |k| self.forget(k);
        self.last_plan = plan;
    }

    fn isAliveImpl(p: *anyopaque) bool {
        return cast(p).daemonAlive();
    }

    fn fmtLimit(buf: *[24]u8, n: u64) []const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
    }
};

const testing = std.testing;

fn testStatus(status: []u8, over: struct {
    torrent: bool = false,
    conns: u32 = 0,
    speed: u64 = 0,
    seeder: bool = false,
    total: u64 = 100,
    code: ?u32 = null,
    msg: ?[]u8 = null,
}) aria2_rpc.Status {
    return .{
        .status = status,
        .total_length = over.total,
        .completed_length = 10,
        .download_speed = over.speed,
        .connections = over.conns,
        .is_torrent = over.torrent,
        .seeder = over.seeder,
        .error_code = over.code,
        .error_message = over.msg,
    };
}

test "mapStatus: active torrent 0 conns 0 speed for 10 s → finding_peers; 5 s → downloading" {
    var buf = "active".*;
    const s = testStatus(&buf, .{ .torrent = true });
    try testing.expectEqual(model.Phase.finding_peers, Aria2Engine.mapStatus(&s, 100, 110).phase);
    try testing.expectEqual(model.Phase.downloading, Aria2Engine.mapStatus(&s, 100, 105).phase);
    // Never observed peerless yet: not finding_peers.
    try testing.expectEqual(model.Phase.downloading, Aria2Engine.mapStatus(&s, null, 200).phase);
    // Magnet still resolving metadata.
    const m = testStatus(&buf, .{ .torrent = true, .total = 0, .conns = 3 });
    try testing.expectEqual(model.Phase.fetching_metadata, Aria2Engine.mapStatus(&m, null, 0).phase);
}

test "mapStatus: active seeder → seeding; complete → transfer_done; error 24 → failed auth_required; removed → removed" {
    var a = "active".*;
    const seeding = testStatus(&a, .{ .torrent = true, .seeder = true, .conns = 4 });
    try testing.expectEqual(model.Phase.seeding, Aria2Engine.mapStatus(&seeding, null, 0).phase);

    var c = "complete".*;
    const done = testStatus(&c, .{});
    const dp = Aria2Engine.mapStatus(&done, null, 0);
    try testing.expectEqual(model.Phase.transfer_done, dp.phase);
    try testing.expectEqual(@as(?[]const u8, null), dp.final_path);
    try testing.expectEqual(@as(u64, 10), dp.bytes_done);
    try testing.expectEqual(@as(?u64, 100), dp.bytes_total);

    var e = "error".*;
    var m = "Unauthorized".*;
    const failed = testStatus(&e, .{ .code = 24, .msg = &m });
    const fp = Aria2Engine.mapStatus(&failed, null, 0);
    try testing.expectEqual(model.Phase.failed, fp.phase);
    try testing.expectEqual(model.FailReason.auth_required, fp.fail.?);
    try testing.expectEqualStrings("Unauthorized", fp.msg);

    var r = "removed".*;
    const removed = testStatus(&r, .{});
    try testing.expectEqual(model.Phase.removed, Aria2Engine.mapStatus(&removed, null, 0).phase);

    var pz = "paused".*;
    try testing.expectEqual(model.Phase.paused, Aria2Engine.mapStatus(&testStatus(&pz, .{}), null, 0).phase);
    var w = "waiting".*;
    try testing.expectEqual(model.Phase.queued, Aria2Engine.mapStatus(&testStatus(&w, .{}), null, 0).phase);
}

test "mapErrorCode table" {
    const F = model.FailReason;
    try testing.expectEqual(F.host_gone, Aria2Engine.mapErrorCode(3));
    try testing.expectEqual(F.host_gone, Aria2Engine.mapErrorCode(4));
    try testing.expectEqual(F.auth_required, Aria2Engine.mapErrorCode(22));
    try testing.expectEqual(F.auth_required, Aria2Engine.mapErrorCode(24));
    try testing.expectEqual(F.network, Aria2Engine.mapErrorCode(6));
    try testing.expectEqual(F.network, Aria2Engine.mapErrorCode(7));
    try testing.expectEqual(F.network, Aria2Engine.mapErrorCode(8));
    try testing.expectEqual(F.disk_full, Aria2Engine.mapErrorCode(9));
    try testing.expectEqual(F.unknown, Aria2Engine.mapErrorCode(1));
    try testing.expectEqual(F.unknown, Aria2Engine.mapErrorCode(null));
}

test "tracking: poll adopts unknown refs; terminal phases forget them" {
    var eng = Aria2Engine.init(testing.allocator, undefined, undefined);
    defer eng.deinit();
    var a = "active".*;
    const st = testStatus(&a, .{ .torrent = true });
    // Adopted with the class from the wire; timer starts at first peerless poll.
    try testing.expectEqual(@as(?i64, 50), try eng.observe("gid1", &st, 50));
    try testing.expect(eng.gids.get("gid1").?.is_torrent);
    try testing.expectEqual(@as(?i64, 50), try eng.observe("gid1", &st, 60));
    // Connections appear: timer clears.
    const live = testStatus(&a, .{ .torrent = true, .conns = 2 });
    try testing.expectEqual(@as(?i64, null), try eng.observe("gid1", &live, 70));
    try testing.expectEqual(@as(u32, 1), eng.gids.count());
    try testing.expect(Aria2Engine.isTerminal(.failed));
    try testing.expect(Aria2Engine.isTerminal(.removed));
    try testing.expect(Aria2Engine.isTerminal(.transfer_done));
    try testing.expect(!Aria2Engine.isTerminal(.seeding));
    eng.forget("gid1");
    try testing.expectEqual(@as(u32, 0), eng.gids.count());
}

test "absorb: NotFound reports removed and forgets the gid" {
    var eng = Aria2Engine.init(testing.allocator, undefined, undefined);
    defer eng.deinit();
    try eng.track("gidX", false);
    try testing.expectEqual(@as(u32, 1), eng.gids.count());
    const p = try eng.absorb("gidX", errs.Error.NotFound, 0);
    try testing.expectEqual(model.Phase.removed, p.phase);
    try testing.expectEqual(@as(u32, 0), eng.gids.count());
    // Transport failure: daemon_gone, nothing forgotten.
    try eng.track("gidY", false);
    const q = try eng.absorb("gidY", errs.Error.HostUnreachable, 0);
    try testing.expectEqual(model.Phase.daemon_gone, q.phase);
    try testing.expectEqual(@as(u32, 1), eng.gids.count());
}

test "absorb: 3 unreachable polls in a row drop the daemon handle; an answer resets the count" {
    var eng = Aria2Engine.init(testing.allocator, undefined, undefined);
    defer eng.deinit();
    eng.last_plan = .{ .aria2_global_down = 0, .aria2_global_up = 0, .per_torrent_down = 0, .per_file_down = 0, .mega_down = 0 };
    _ = try eng.absorb("g", errs.Error.HostUnreachable, 0);
    _ = try eng.absorb("g", errs.Error.HostUnreachable, 0);
    try testing.expectEqual(@as(u8, 2), eng.gone_polls);
    // The daemon answered (unknown gid): the streak ends.
    _ = try eng.absorb("g", errs.Error.NotFound, 0);
    try testing.expectEqual(@as(u8, 0), eng.gone_polls);
    try testing.expect(eng.last_plan != null);
    for (0..3) |_| _ = try eng.absorb("g", errs.Error.HostUnreachable, 0);
    // Third in a row: handle dropped (null here already), plan cleared so
    // the respawned daemon gets the limits again, counter reset.
    try testing.expectEqual(@as(u8, 0), eng.gone_polls);
    try testing.expect(eng.daemon == null);
    try testing.expect(eng.last_plan == null);
}

test "absorb: several gids unreachable in one tick count once; three ticks drop the daemon" {
    var eng = Aria2Engine.init(testing.allocator, undefined, undefined);
    defer eng.deinit();
    const gids = [_][]const u8{ "a", "b", "c", "d" };
    // Tick 1: four active jobs, daemon unreachable for all of them.
    for (gids) |g| _ = try eng.absorb(g, errs.Error.HostUnreachable, 10);
    try testing.expectEqual(@as(u8, 1), eng.gone_polls);
    // Tick 2.
    for (gids) |g| _ = try eng.absorb(g, errs.Error.HostUnreachable, 11);
    try testing.expectEqual(@as(u8, 2), eng.gone_polls);
    // The anchor job is cancelled: the next gone gid takes over, the
    // streak is kept.
    eng.forget("a");
    _ = try eng.absorb("b", errs.Error.HostUnreachable, 12);
    // Third tick in a row: handle dropped, counter and anchor reset.
    try testing.expectEqual(@as(u8, 0), eng.gone_polls);
    try testing.expect(eng.gone_anchor == null);
    try testing.expect(eng.daemon == null);
    // The rest of that tick starts a new streak at 1, not 2.
    _ = try eng.absorb("c", errs.Error.HostUnreachable, 12);
    _ = try eng.absorb("d", errs.Error.HostUnreachable, 12);
    try testing.expectEqual(@as(u8, 1), eng.gone_polls);
    // Any answer ends the streak.
    _ = try eng.absorb("c", errs.Error.NotFound, 13);
    try testing.expectEqual(@as(u8, 0), eng.gone_polls);
    try testing.expect(eng.gone_anchor == null);
}
