//! MEGAcmd-backed Engine (spec §3.5 "megacmd", §3.10). One `mega-get
//! <link> <dest_dir>` client per job, read on its own worker thread;
//! cancel/pause/resume go through `mega-transfers`, bandwidth through
//! `mega-speedlimit`. Account helpers (`login`/`whoami`/`logout`) are for
//! the Settings card and run on a UI worker, never the render thread.
//!
//! Threading: the Engine vtable is called only from the downloader thread.
//! A run's worker thread writes the progress atomics while it runs and the
//! rest of the `Run` result fields before it sets `done` (release); the
//! downloader thread reads them only after it sees `done` (acquire).
//! The child is reaped by the worker; `pid_lock` + `reaped` make sure a
//! kill from the downloader thread never targets a reaped pid/handle.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const util_proc = @import("util_proc");
const errs = @import("errors.zig");
const model = @import("model.zig");
const policy = @import("policy.zig");
const megacmd = @import("megacmd.zig");
const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const StartSpec = engine_mod.StartSpec;

const log = std.log.scoped(.mega_engine);

/// Bound for the collected `mega-get` stdout (quota text, `Download finished:`).
const STDOUT_MAX = 64 * 1024;
/// Bound for one stderr piece (progress line / ERR line).
const LINE_MAX = 1024;
/// `ensureServer` waits this long for `whoami` to answer.
const SERVER_PROBE_MS = 2000;
const NO_SERVER_MSG = "MEGAcmdServer.exe not found next to MegaClient.exe";

pub const LoginResult = enum { ok, already_logged_in, needs_auth_code, bad_credentials, not_installed };

/// One `mega-get` client and what its worker read from it.
const Run = struct {
    child: std.process.Child,
    thr: ?std.Thread = null,
    /// Owned.
    dest_dir: []u8,

    // ---- written by the worker while running ----
    prog_done: std.atomic.Value(u64) = .init(0),
    prog_total: std.atomic.Value(u64) = .init(0),
    have_prog: std.atomic.Value(bool) = .init(false),

    // ---- written by the worker before `done` ----
    err_buf: [LINE_MAX]u8 = undefined,
    err_len: usize = 0,
    out_buf: [STDOUT_MAX]u8 = undefined,
    out_len: usize = 0,
    /// Null when the client ended by a signal / unknown status.
    exit_code: ?u8 = null,
    done: std.atomic.Value(bool) = .init(false),

    // ---- child reap / kill guard ----
    pid_lock: std.atomic.Value(bool) = .init(false),
    /// Under `pid_lock`: the worker called `child.wait` (id is gone).
    reaped: bool = false,

    /// Set at creation: no server binary, so no child and no worker
    /// (`child` is undefined, `done` is already true).
    no_server: bool = false,

    // ---- downloader thread only ----
    paused: bool = false,
    last_ms: i64 = 0,
    last_bytes: u64 = 0,
    speed: u64 = 0,

    fn lock(r: *Run) void {
        while (r.pid_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.Thread.yield() catch {};
    }
    fn unlock(r: *Run) void {
        r.pid_lock.store(false, .release);
    }

    fn errLine(r: *const Run) ?[]const u8 {
        return if (r.err_len == 0) null else r.err_buf[0..r.err_len];
    }
    fn stdoutText(r: *const Run) []const u8 {
        return r.out_buf[0..r.out_len];
    }

    /// Stderr piece: progress or a kept `ERR` line.
    fn takePiece(r: *Run, raw: []const u8) void {
        const piece = std.mem.trim(u8, raw, " \t");
        if (piece.len == 0) return;
        if (megacmd.parseProgressLine(piece)) |p| {
            r.prog_done.store(p.done, .monotonic);
            r.prog_total.store(p.total, .monotonic);
            r.have_prog.store(true, .release);
            return;
        }
        if (isErrLine(piece)) {
            const n = @min(piece.len, r.err_buf.len);
            @memcpy(r.err_buf[0..n], piece[0..n]);
            r.err_len = n;
        }
    }

    /// Drain stdout to EOF; keeps the first `STDOUT_MAX` bytes, discards
    /// the rest (so the child never blocks on a full pipe).
    fn readStdout(r: *Run, io: Io) void {
        const f = r.child.stdout orelse return;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = f.readStreaming(io, &.{&buf}) catch break;
            const room = r.out_buf.len - r.out_len;
            const k = @min(n, room);
            @memcpy(r.out_buf[r.out_len..][0..k], buf[0..k]);
            r.out_len += k;
        }
    }

    /// Worker body: stdout on its own thread while this one reads stderr
    /// (incremental), so neither pipe can fill up and stall the client
    /// (the Windows pipe buffer is only 4 KB); then both are joined and
    /// the child is reaped.
    fn work(r: *Run, io: Io) void {
        const out_thr: ?std.Thread = std.Thread.spawn(.{}, readStdout, .{ r, io }) catch null;
        if (r.child.stderr) |f| {
            var buf: [4096]u8 = undefined;
            var line: [LINE_MAX]u8 = undefined;
            var len: usize = 0;
            while (true) {
                const n = f.readStreaming(io, &.{&buf}) catch break;
                for (buf[0..n]) |c| {
                    if (c == '\r' or c == '\n') {
                        r.takePiece(line[0..len]);
                        len = 0;
                    } else if (len < line.len) {
                        line[len] = c;
                        len += 1;
                    }
                }
            }
            r.takePiece(line[0..len]);
        }
        // No thread (spawn failed): drain stdout here, after stderr.
        if (out_thr) |t| t.join() else r.readStdout(io);
        waitExitNoReap(&r.child);
        r.lock();
        const term = r.child.wait(io) catch blk: {
            r.child.kill(io);
            break :blk null;
        };
        r.reaped = true;
        r.unlock();
        r.exit_code = if (term) |t| switch (t) {
            .exited => |c| c,
            else => null,
        } else null;
        r.done.store(true, .release);
    }

    /// Force the client to end without reaping it (the worker reaps).
    fn killChild(r: *Run) void {
        r.lock();
        defer r.unlock();
        if (r.reaped) return;
        const id = r.child.id orelse return;
        switch (builtin.os.tag) {
            .linux => _ = std.os.linux.kill(id, .KILL),
            .windows => {
                // Same effect as `Child.kill`'s NtTerminateProcess, but the
                // handles stay open for the worker's `wait` to clean up.
                const st: std.os.windows.NTSTATUS = @fromBackingInt(@as(u32, 1));
                _ = std.os.windows.ntdll.NtTerminateProcess(id, st);
            },
            else => _ = std.posix.system.kill(id, .KILL),
        }
    }
};

/// Block until the child exited, leaving it reapable (no `wait` yet), so
/// a concurrent `killChild` under `pid_lock` can never hit a reused pid.
fn waitExitNoReap(child: *std.process.Child) void {
    const id = child.id orelse return;
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var info: linux.siginfo_t = undefined;
            while (true) {
                const rc = linux.waitid(.PID, id, &info, linux.W.EXITED | linux.W.NOWAIT, null);
                if (linux.errno(rc) != .INTR) break;
            }
        },
        .windows => _ = std.os.windows.ntdll.NtWaitForSingleObject(id, .FALSE, null),
        // Elsewhere `wait` runs under the lock and blocks there.
        else => {},
    }
}

/// `ensureServer` handoff with a detached `whoami` thread. The thread owns
/// the probe once the waiter gives up (`abandoned`), so neither side waits
/// on a client that never closes its pipes.
const Probe = struct {
    alloc: Allocator,
    io: Io,
    argv: []const []const u8,
    /// 0 running, 1 done, 2 abandoned.
    state: std.atomic.Value(u8) = .init(0),
    answered: bool = false,

    fn run(p: *Probe) void {
        if (util_proc.run(p.alloc, p.io, p.argv, .{ .stderr = .ignore })) |res| {
            p.answered = res.exit_code == 0 or res.exit_code == megacmd.EXIT_NOT_LOGGED_IN;
            p.alloc.free(res.stdout);
        } else |_| {}
        if (p.state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) p.destroy();
    }
    fn destroy(p: *Probe) void {
        megacmd.freeArgv(p.alloc, p.argv);
        p.alloc.destroy(p);
    }
};

pub const MegaEngine = struct {
    alloc: Allocator,
    io: Io,
    /// Owned; freed by `deinit`.
    located: megacmd.Located,
    runs: std.AutoHashMapUnmanaged(u64, *Run) = .empty,
    /// Download cap (bytes/s, 0 = unlimited) last sent to `mega-speedlimit`.
    last_limit: ?u64 = null,
    /// Cap from the latest plan; applied only while a run exists, so an
    /// idle app never spawns MEGAcmd.
    want_limit: ?u64 = null,
    /// Borrowed by the last `poll` result; freed on the next poll.
    poll_msg: ?[]u8 = null,
    poll_final: ?[]u8 = null,

    /// Takes ownership of `located`. Windows: when the locator found no
    /// server, `<dir>\MEGAcmdServer.exe` is used if it exists.
    pub fn init(alloc: Allocator, io: Io, located: megacmd.Located) MegaEngine {
        var l = located;
        if (builtin.os.tag == .windows and l.server == null) {
            if (std.fs.path.join(alloc, &.{ l.dir, "MEGAcmdServer.exe" })) |sp| {
                if (Io.Dir.cwd().statFile(io, sp, .{})) |_| l.server = sp else |_| alloc.free(sp);
            } else |_| {}
        }
        return .{ .alloc = alloc, .io = io, .located = l };
    }

    /// Cancels and kills every live run, joins its worker, frees it.
    pub fn deinit(self: *MegaEngine) void {
        var it = self.runs.valueIterator();
        while (it.next()) |rp| self.stopRun(rp.*);
        self.runs.deinit(self.alloc);
        self.freePollStrings();
        megacmd.freeLocated(self.alloc, self.located);
        self.* = undefined;
    }

    pub fn engine(self: *MegaEngine) Engine {
        return .{ .ptr = self, .vt = &vtable };
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

    fn cast(p: *anyopaque) *MegaEngine {
        return @ptrCast(@alignCast(p));
    }

    // ---------------------------------------------------------------- account

    /// Windows only: start `MEGAcmdServer.exe` ourselves (all std handles
    /// ignored, no window, not waited for) when `whoami` gets no answer
    /// within 2 s. The client's own auto-start would inherit our pipes and
    /// block EOF. Linux: no-op (the client auto-starts the server).
    pub fn ensureServer(self: *MegaEngine) void {
        _ = self.serverReady();
    }

    /// `ensureServer`, and false on Windows when there is no server binary
    /// to start: then no MEGAcmd client may run (its own auto-start would
    /// hold our pipes open and hang the reader). Always true on Linux.
    fn serverReady(self: *MegaEngine) bool {
        if (builtin.os.tag != .windows) return true;
        const server = self.located.server orelse return false;
        if (self.probeServer()) return true;
        log.info("MEGAcmd server not answering; starting {s}", .{server});
        var child = std.process.spawn(self.io, .{
            .argv = &.{server},
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
        }) catch |e| {
            log.warn("starting MEGAcmd server failed: {s}", .{@errorName(e)});
            return true;
        };
        // Not waited for: the server outlives this call (and f69).
        if (builtin.os.tag == .windows) {
            std.os.windows.CloseHandle(child.id.?);
            std.os.windows.CloseHandle(child.thread_handle);
            child.id = null;
        }
        return true;
    }

    /// True when `whoami` answered (signed in or out) within 2 s.
    fn probeServer(self: *MegaEngine) bool {
        const p = self.alloc.create(Probe) catch return false;
        p.* = .{
            .alloc = self.alloc,
            .io = self.io,
            .argv = megacmd.argv(self.alloc, self.located, "whoami", &.{}) catch {
                self.alloc.destroy(p);
                return false;
            },
        };
        const t = std.Thread.spawn(.{}, Probe.run, .{p}) catch {
            p.destroy();
            return false;
        };
        t.detach();
        var waited: u32 = 0;
        while (waited < SERVER_PROBE_MS) : (waited += 50) {
            if (p.state.load(.acquire) == 1) {
                const ok = p.answered;
                p.destroy();
                return ok;
            }
            self.io.sleep(Io.Duration.fromMilliseconds(50), .real) catch break;
        }
        if (p.state.cmpxchgStrong(0, 2, .acq_rel, .acquire) == null) return false; // thread frees it
        const ok = p.answered;
        p.destroy();
        return ok;
    }

    /// `mega-login <email> <password> [--auth-code=<code>]`. The password
    /// is one argv element and is never logged. Blocks: call on a worker.
    pub fn login(self: *MegaEngine, alloc: Allocator, email: []const u8, password: []const u8, auth_code: ?[]const u8) errs.Error!LoginResult {
        if (!self.serverReady()) return .not_installed;
        const code_arg: ?[]u8 = if (auth_code) |c|
            std.fmt.allocPrint(alloc, "--auth-code={s}", .{c}) catch return errs.Error.OutOfMemory
        else
            null;
        defer if (code_arg) |c| alloc.free(c);
        var args_buf: [3][]const u8 = .{ email, password, "" };
        var n: usize = 2;
        if (code_arg) |c| {
            args_buf[2] = c;
            n = 3;
        }
        const av = megacmd.argv(alloc, self.located, "login", args_buf[0..n]) catch return errs.Error.OutOfMemory;
        defer megacmd.freeArgv(alloc, av);
        const cap = capture(alloc, self.io, av) catch |e| switch (e) {
            error.OutOfMemory => return errs.Error.OutOfMemory,
            error.SpawnFailed => return .not_installed,
        };
        defer cap.deinit(alloc);
        return loginResult(cap.code, cap.stderr, cap.stdout);
    }

    /// Signed-in account e-mail (owned by `alloc`), or null when signed out,
    /// not installed or the call failed. Blocks: call on a worker.
    pub fn whoami(self: *MegaEngine, alloc: Allocator) ?[]u8 {
        if (!self.serverReady()) return null;
        const av = megacmd.argv(alloc, self.located, "whoami", &.{}) catch return null;
        defer megacmd.freeArgv(alloc, av);
        const res = util_proc.run(alloc, self.io, av, .{ .stderr = .ignore }) catch return null;
        defer alloc.free(res.stdout);
        if (res.exit_code != 0) return null;
        const email = megacmd.parseWhoami(res.stdout) orelse return null;
        return alloc.dupe(u8, email) catch null;
    }

    /// `mega-logout`; failures are logged only. Blocks: call on a worker.
    pub fn logout(self: *MegaEngine) void {
        if (!self.serverReady()) return;
        const av = megacmd.argv(self.alloc, self.located, "logout", &.{}) catch return;
        defer megacmd.freeArgv(self.alloc, av);
        const res = util_proc.run(self.alloc, self.io, av, .{ .stderr = .ignore }) catch |e| {
            log.warn("mega-logout failed: {s}", .{@errorName(e)});
            return;
        };
        self.alloc.free(res.stdout);
        if (res.exit_code != 0) log.warn("mega-logout exited with code {d}", .{res.exit_code});
    }

    // ---------------------------------------------------------------- engine

    fn refId(ref: []const u8) ?u64 {
        if (!std.mem.startsWith(u8, ref, "mega:")) return null;
        return std.fmt.parseInt(u64, ref["mega:".len..], 10) catch null;
    }

    fn startImpl(p: *anyopaque, spec: StartSpec) errs.Error![]u8 {
        const self = cast(p);
        // A leftover run for the same job (retry without cancel) goes first.
        if (self.runs.fetchRemove(spec.job_id)) |kv| self.stopRun(kv.value);

        const ref = std.fmt.allocPrint(self.alloc, "mega:{d}", .{spec.job_id}) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(ref);
        self.runs.ensureUnusedCapacity(self.alloc, 1) catch return errs.Error.OutOfMemory;

        Io.Dir.cwd().createDirPath(self.io, spec.dest_dir) catch |e| {
            log.warn("mega: creating '{s}' failed: {s}", .{ spec.dest_dir, @errorName(e) });
            return if (e == error.NoSpaceLeft) errs.Error.DiskFull else errs.Error.NetworkError;
        };
        const ready = self.serverReady();
        if (ready) self.applyLimitReady(true);

        const run = self.alloc.create(Run) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.destroy(run);
        const dest = self.alloc.dupe(u8, spec.dest_dir) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(dest);
        if (!ready) {
            // Windows without MEGAcmdServer.exe: never spawn the client.
            // The run is born finished; `poll` reports engine_missing.
            log.warn("mega: job {d}: no MEGAcmdServer.exe next to {s}", .{ spec.job_id, self.located.client });
            run.* = .{ .child = undefined, .dest_dir = dest, .no_server = true };
            run.done.store(true, .release);
            self.runs.putAssumeCapacity(spec.job_id, run);
            return ref;
        }
        const av = megacmd.argv(self.alloc, self.located, "get", &.{ spec.url, spec.dest_dir }) catch return errs.Error.OutOfMemory;
        defer megacmd.freeArgv(self.alloc, av);
        const child = std.process.spawn(self.io, .{
            .argv = av,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        }) catch |e| {
            log.warn("mega: spawning '{s}' failed: {s}", .{ av[0], @errorName(e) });
            return errs.Error.NetworkError;
        };
        run.* = .{ .child = child, .dest_dir = dest };
        run.thr = std.Thread.spawn(.{}, Run.work, .{ run, self.io }) catch {
            run.child.kill(self.io);
            return errs.Error.OutOfMemory;
        };
        self.runs.putAssumeCapacity(spec.job_id, run);
        log.info("mega: job {d} started into '{s}'", .{ spec.job_id, spec.dest_dir });
        return ref;
    }

    fn freePollStrings(self: *MegaEngine) void {
        if (self.poll_msg) |m| self.alloc.free(m);
        if (self.poll_final) |f| self.alloc.free(f);
        self.poll_msg = null;
        self.poll_final = null;
    }

    fn pollImpl(p: *anyopaque, ref: []const u8) errs.Error!model.Progress {
        const self = cast(p);
        self.freePollStrings();
        const id = refId(ref) orelse return .{ .phase = .removed };
        const run = self.runs.get(id) orelse return .{ .phase = .removed };
        if (!run.done.load(.acquire)) {
            const have = run.have_prog.load(.acquire);
            const done_b = run.prog_done.load(.monotonic);
            self.sampleSpeed(run, done_b);
            return .{
                .phase = if (run.paused) .paused else .downloading,
                .bytes_done = done_b,
                .bytes_total = if (have) run.prog_total.load(.monotonic) else null,
                .dl_speed = if (run.paused) 0 else run.speed,
            };
        }
        const done_b = run.prog_done.load(.monotonic);
        const total: ?u64 = if (run.have_prog.load(.acquire)) run.prog_total.load(.monotonic) else null;
        if (run.no_server) {
            self.poll_msg = self.alloc.dupe(u8, NO_SERVER_MSG) catch null;
            return .{ .phase = .failed, .fail = .engine_missing, .msg = self.poll_msg orelse "" };
        }
        const code = run.exit_code;
        if (code == 0) {
            self.poll_final = findFinal(self.alloc, self.io, run);
            return .{ .phase = .transfer_done, .bytes_done = total orelse done_b, .bytes_total = total, .final_path = self.poll_final };
        }
        const reason: model.FailReason = if (code) |c| megacmd.exitToFail(c) orelse .network else .network;
        self.poll_msg = switch (reason) {
            .quota_exceeded => std.fmt.allocPrint(self.alloc, "MEGA transfer quota exceeded — wait {s}", .{
                megacmd.parseQuotaWait(run.stdoutText()) orelse "a while",
            }) catch null,
            .auth_required => self.alloc.dupe(u8, "Sign in to MEGA in Settings → Accounts") catch null,
            else => if (run.errLine()) |l|
                self.alloc.dupe(u8, l) catch null
            else if (code) |c|
                std.fmt.allocPrint(self.alloc, "mega-get exited with code {d}", .{c}) catch null
            else
                self.alloc.dupe(u8, "mega-get was stopped") catch null,
        };
        return .{ .phase = .failed, .fail = reason, .msg = self.poll_msg orelse "", .bytes_done = done_b, .bytes_total = total };
    }

    fn sampleSpeed(self: *MegaEngine, run: *Run, bytes: u64) void {
        const now = Io.Clock.awake.now(self.io).toMilliseconds();
        if (run.last_ms == 0) {
            run.last_ms = now;
            run.last_bytes = bytes;
            return;
        }
        const dt = now - run.last_ms;
        if (dt < 1000) return;
        const db = bytes -| run.last_bytes;
        run.speed = db * 1000 / @as(u64, @intCast(dt));
        run.last_ms = now;
        run.last_bytes = bytes;
    }

    /// Live MEGAcmd transfers whose destination is inside `dest_dir`.
    fn liveTags(self: *MegaEngine, dest_dir: []const u8) ![]u32 {
        const av = try megacmd.argv(self.alloc, self.located, "transfers", &.{
            "--only-downloads",
            "--col-separator=|",
            "--output-cols=TAG,DESTINYPATH,PROGRESS,STATE",
            "--limit=1000",
        });
        defer megacmd.freeArgv(self.alloc, av);
        const res = try util_proc.run(self.alloc, self.io, av, .{ .stderr = .ignore });
        defer self.alloc.free(res.stdout);
        const ts = try megacmd.parseTransfersTable(res.stdout, self.alloc);
        defer megacmd.freeTransfers(self.alloc, ts);
        var tags: std.ArrayList(u32) = .empty;
        errdefer tags.deinit(self.alloc);
        for (ts) |t| {
            switch (t.state) {
                .COMPLETED, .CANCELLED, .FAILED => continue,
                else => {},
            }
            if (!underDir(t.dest, dest_dir)) continue;
            try tags.append(self.alloc, t.tag);
        }
        return tags.toOwnedSlice(self.alloc);
    }

    /// `mega-transfers <flag> <tag>` for every live transfer of `run`.
    /// Returns how many tags were found.
    fn transfersAction(self: *MegaEngine, run: *Run, flag: []const u8) usize {
        // Windows: a dead server would be auto-started by this helper and
        // hold its stdout pipe open, so the call would never return.
        if (!self.serverReady()) return 0;
        const tags = self.liveTags(run.dest_dir) catch |e| {
            log.warn("mega-transfers lookup failed: {s}", .{@errorName(e)});
            return 0;
        };
        defer self.alloc.free(tags);
        for (tags) |tag| {
            var tb: [16]u8 = undefined;
            const ts = std.fmt.bufPrint(&tb, "{d}", .{tag}) catch unreachable;
            const av = megacmd.argv(self.alloc, self.located, "transfers", &.{ flag, ts }) catch continue;
            defer megacmd.freeArgv(self.alloc, av);
            const res = util_proc.run(self.alloc, self.io, av, .{ .stderr = .ignore }) catch |e| {
                log.warn("mega-transfers {s} {d} failed: {s}", .{ flag, tag, @errorName(e) });
                continue;
            };
            self.alloc.free(res.stdout);
        }
        return tags.len;
    }

    /// Cancel the server-side transfer (when still running), kill the
    /// client, join the worker, free the run.
    /// Order: kill first, so a hung lookup can never keep the client alive.
    fn stopRun(self: *MegaEngine, run: *Run) void {
        if (!run.done.load(.acquire)) {
            run.killChild();
            // The server keeps the transfer after the client dies: cancel it.
            _ = self.transfersAction(run, "-c");
        }
        if (run.thr) |t| t.join();
        self.alloc.free(run.dest_dir);
        self.alloc.destroy(run);
    }

    fn cancelImpl(p: *anyopaque, ref: []const u8) errs.Error!void {
        const self = cast(p);
        const id = refId(ref) orelse return;
        const kv = self.runs.fetchRemove(id) orelse return;
        self.stopRun(kv.value);
    }

    fn pauseImpl(p: *anyopaque, ref: []const u8) errs.Error!void {
        const self = cast(p);
        const run = self.runs.get(refId(ref) orelse return) orelse return;
        if (run.done.load(.acquire)) return;
        if (self.transfersAction(run, "-p") == 0) return errs.Error.NotFound;
        run.paused = true;
    }

    fn unpauseImpl(p: *anyopaque, ref: []const u8) errs.Error!void {
        const self = cast(p);
        const run = self.runs.get(refId(ref) orelse return) orelse return;
        if (run.done.load(.acquire)) return;
        if (self.transfersAction(run, "-r") == 0) return errs.Error.NotFound;
        run.paused = false;
    }

    fn finalPathImpl(p: *anyopaque, alloc: Allocator, ref: []const u8) errs.Error!?[]u8 {
        const self = cast(p);
        const run = self.runs.get(refId(ref) orelse return null) orelse return null;
        if (!run.done.load(.acquire) or run.no_server) return null;
        return findFinal(alloc, self.io, run);
    }

    fn setLimitsImpl(p: *anyopaque, plan: policy.Plan) errs.Error!void {
        const self = cast(p);
        self.want_limit = plan.mega_down;
        self.applyLimit(false);
    }

    /// Send `want_limit` to `mega-speedlimit -d` when it changed and a run
    /// exists (or one is about to start).
    fn applyLimit(self: *MegaEngine, starting: bool) void {
        const want = self.want_limit orelse return;
        if (self.last_limit) |l| if (l == want) return;
        if (!starting and self.runs.count() == 0) return;
        if (!self.serverReady()) return;
        self.applyLimitReady(starting);
    }

    /// `applyLimit` once the server is known to be up.
    fn applyLimitReady(self: *MegaEngine, starting: bool) void {
        const want = self.want_limit orelse return;
        if (self.last_limit) |l| if (l == want) return;
        if (!starting and self.runs.count() == 0) return;
        var nb: [24]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{want}) catch unreachable;
        const av = megacmd.argv(self.alloc, self.located, "speedlimit", &.{ "-d", ns }) catch return;
        defer megacmd.freeArgv(self.alloc, av);
        const res = util_proc.run(self.alloc, self.io, av, .{ .stderr = .ignore }) catch |e| {
            log.warn("mega-speedlimit failed: {s}", .{@errorName(e)});
            return;
        };
        self.alloc.free(res.stdout);
        if (res.exit_code == 0) self.last_limit = want else log.warn("mega-speedlimit exited with code {d}", .{res.exit_code});
    }

    fn isAliveImpl(_: *anyopaque) bool {
        return true;
    }
};

/// `path` is `dir` or inside it (a separator follows the prefix).
fn underDir(path: []const u8, dir: []const u8) bool {
    const d = std.mem.trimEnd(u8, dir, "/\\");
    if (!std.mem.startsWith(u8, path, d)) return false;
    if (path.len == d.len) return true;
    return path[d.len] == '/' or path[d.len] == '\\';
}

const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    fn deinit(c: Captured, alloc: Allocator) void {
        alloc.free(c.stdout);
        alloc.free(c.stderr);
    }
};

/// One-shot run with stderr captured too (login needs it). Reads stderr
/// first, then stdout: both are a few lines for the account commands.
fn capture(alloc: Allocator, io: Io, av: []const []const u8) error{ OutOfMemory, SpawnFailed }!Captured {
    var child = std.process.spawn(io, .{
        .argv = av,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch return error.SpawnFailed;
    var err_w: Io.Writer.Allocating = .init(alloc);
    defer err_w.deinit();
    var out_w: Io.Writer.Allocating = .init(alloc);
    defer out_w.deinit();
    var buf: [4096]u8 = undefined;
    var ok = true;
    inline for (.{ .{ child.stderr, &err_w }, .{ child.stdout, &out_w } }) |pair| {
        if (pair[0]) |f| {
            var r = f.reader(io, &buf);
            _ = r.interface.streamRemaining(&pair[1].writer) catch {
                ok = false;
            };
        }
    }
    const term = child.wait(io) catch {
        child.kill(io);
        return error.SpawnFailed;
    };
    if (!ok) return error.OutOfMemory;
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 1,
    };
    const so = try out_w.toOwnedSlice();
    errdefer alloc.free(so);
    const se = try err_w.toOwnedSlice();
    return .{ .stdout = so, .stderr = se, .code = code };
}

/// A kept stderr error line: ` ERR ` / `ERR:` in any case.
fn isErrLine(piece: []const u8) bool {
    return std.ascii.findIgnoreCase(piece, " err ") != null or std.ascii.findIgnoreCase(piece, "err:") != null;
}

fn loginResult(code: u8, stderr: []const u8, stdout: []const u8) LoginResult {
    if (code == 0) return .ok;
    if (code == megacmd.EXIT_ALREADY_LOGGED_IN) return .already_logged_in;
    for ([_][]const u8{ stderr, stdout }) |text| {
        for ([_][]const u8{ "auth code", "authentication code", "two-factor", "2fa", "multi-factor" }) |w| {
            if (std.ascii.findIgnoreCase(text, w) != null) return .needs_auth_code;
        }
    }
    return .bad_credentials;
}

/// MEGAcmd temp names and hidden files never count as the payload.
fn isMegaTemp(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.' or name[0] == '~') return true;
    for ([_][]const u8{ ".mega", ".part", ".tmp", ".partial", ".download" }) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

/// `Download finished: <path>` when that file exists, else the one
/// non-temp file in the run's `dest_dir` (same rule as the downloader's
/// `findSingleFile`). Owned by `alloc`.
fn findFinal(alloc: Allocator, io: Io, run: *const Run) ?[]u8 {
    var lines = std.mem.splitScalar(u8, run.stdoutText(), '\n');
    while (lines.next()) |line| {
        const p = megacmd.parseDownloadFinished(line) orelse continue;
        if (Io.Dir.cwd().statFile(io, p, .{})) |_| {
            return alloc.dupe(u8, p) catch null;
        } else |_| {}
    }
    return singleFile(alloc, io, run.dest_dir);
}

fn singleFile(alloc: Allocator, io: Io, dir: []const u8) ?[]u8 {
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return null;
    defer d.close(io);
    var name_buf: [std.fs.max_name_bytes]u8 = undefined;
    var name: ?[]const u8 = null;
    var it = d.iterate();
    while (it.next(io) catch return null) |e| {
        if (e.kind != .file) continue;
        if (isMegaTemp(e.name)) continue;
        if (name != null or e.name.len > name_buf.len) return null;
        @memcpy(name_buf[0..e.name.len], e.name);
        name = name_buf[0..e.name.len];
    }
    return std.fs.path.join(alloc, &.{ dir, name orelse return null }) catch null;
}

// ---- tests ----

const testing = std.testing;

const fake_script =
    \\#!/bin/sh
    \\d="$(dirname "$0")"
    \\n="$(basename "$0")"
    \\echo "$n $*" >> "$d/argv.log"
    \\code=0
    \\[ -f "$d/exit_code" ] && code="$(cat "$d/exit_code")"
    \\case "$n" in
    \\  mega-get)
    \\    dest="$2"
    \\    echo "$dest" > "$d/last_dest"
    \\    printf 'abcdef' > "$dest/Game.zip"
    \\    [ -f "$d/bigout" ] && head -c 100000 /dev/zero | tr '\0' 'x'
    \\    printf 'TRANSFERRING ||##||( 1/6 MB:  16.67 %%) \rTRANSFERRING ||####||( 6/6 MB: 100.00 %%) \n' >&2
    \\    [ -f "$d/hang" ] && exec sleep 30
    \\    if [ "$code" = 17 ]; then
    \\      echo "Transfer quota exceeded. You can't continue downloading as you've used all of the transfer quota available to you. Please wait for 5 hours 3 minutes until more free quota becomes available."
    \\    else
    \\      echo "Download finished: $dest/Game.zip"
    \\    fi
    \\    exit "$code" ;;
    \\  mega-transfers)
    \\    case "$1" in -c|-p|-r) exit 0 ;; esac
    \\    echo "TAG|DESTINYPATH|PROGRESS|STATE"
    \\    echo "12|$(cat "$d/last_dest")/Game.zip|6 B of 6 B  100%|ACTIVE"
    \\    exit 0 ;;
    \\  *) exit 0 ;;
    \\esac
    \\
;

const FakeMega = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    eng: MegaEngine,

    fn create(opts: struct { exit_code: ?[]const u8 = null, hang: bool = false, bigout: bool = false }) !*FakeMega {
        const a = testing.allocator;
        const io = testing.io;
        const f = try a.create(FakeMega);
        errdefer a.destroy(f);
        f.tmp = testing.tmpDir(.{});
        errdefer f.tmp.cleanup();
        try f.tmp.dir.writeFile(io, .{ .sub_path = "mega-get", .data = fake_script, .flags = .{ .permissions = .executable_file } });
        try f.tmp.dir.symLink(io, "mega-get", "mega-transfers", .{});
        try f.tmp.dir.symLink(io, "mega-get", "mega-speedlimit", .{});
        if (opts.exit_code) |c| try f.tmp.dir.writeFile(io, .{ .sub_path = "exit_code", .data = c });
        if (opts.hang) try f.tmp.dir.writeFile(io, .{ .sub_path = "hang", .data = "" });
        if (opts.bigout) try f.tmp.dir.writeFile(io, .{ .sub_path = "bigout", .data = "" });
        f.root = try f.tmp.dir.realPathFileAlloc(io, ".", a);
        errdefer a.free(f.root);
        const client = try std.fs.path.join(a, &.{ f.root, "mega-get" });
        errdefer a.free(client);
        const dir = try a.dupe(u8, f.root);
        f.eng = MegaEngine.init(a, io, .{ .client = client, .server = null, .dir = dir, .is_windows_direct = false });
        return f;
    }

    fn destroy(f: *FakeMega) void {
        const a = testing.allocator;
        f.eng.deinit();
        a.free(f.root);
        f.tmp.cleanup();
        a.destroy(f);
    }

    fn destDir(f: *FakeMega, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/dl/1", .{f.root});
    }

    fn argvLog(f: *FakeMega) ![]u8 {
        return f.tmp.dir.readFileAlloc(testing.io, "argv.log", testing.allocator, .limited(64 * 1024));
    }
};

/// Poll until the phase leaves `downloading` (≤5 s).
fn pollUntilDone(e: Engine, ref: []const u8) !model.Progress {
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const p = try e.poll(ref);
        if (p.phase != .downloading) return p;
        testing.io.sleep(Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    return error.TestTimedOut;
}

test "mega engine: progress parsed, exit 0 → transfer_done with final_path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try FakeMega.create(.{});
    defer f.destroy();
    const e = f.eng.engine();
    var db: [512]u8 = undefined;
    const dest = try f.destDir(&db);
    const ref = try e.start(.{ .job_id = 1, .url = "https://mega.nz/file/abc#key", .headers = &.{}, .dest_dir = dest, .out_name = null, .torrent_bytes = null });
    defer testing.allocator.free(ref);
    try testing.expectEqualStrings("mega:1", ref);
    const p = try pollUntilDone(e, ref);
    try testing.expectEqual(model.Phase.transfer_done, p.phase);
    try testing.expectEqual(@as(?u64, 6 * 1024 * 1024), p.bytes_total);
    try testing.expectEqual(@as(u64, 6 * 1024 * 1024), p.bytes_done);
    try testing.expect(std.mem.endsWith(u8, p.final_path.?, "Game.zip"));
    const fp = (try e.finalPath(testing.allocator, ref)).?;
    defer testing.allocator.free(fp);
    try testing.expect(std.mem.endsWith(u8, fp, "dl/1/Game.zip"));
    try e.cancel(ref);
    try testing.expectEqual(model.Phase.removed, (try e.poll(ref)).phase);
    const lg = try f.argvLog();
    defer testing.allocator.free(lg);
    try testing.expect(std.mem.indexOf(u8, lg, "mega-get https://mega.nz/file/abc#key ") != null);
    // A finished run is not looked up in mega-transfers on cancel.
    try testing.expect(std.mem.indexOf(u8, lg, "mega-transfers") == null);
}

test "mega engine: exit 17 → quota_exceeded with wait text" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try FakeMega.create(.{ .exit_code = "17" });
    defer f.destroy();
    const e = f.eng.engine();
    var db: [512]u8 = undefined;
    const dest = try f.destDir(&db);
    const ref = try e.start(.{ .job_id = 1, .url = "https://mega.nz/file/abc#key", .headers = &.{}, .dest_dir = dest, .out_name = null, .torrent_bytes = null });
    defer testing.allocator.free(ref);
    const p = try pollUntilDone(e, ref);
    try testing.expectEqual(model.Phase.failed, p.phase);
    try testing.expectEqual(model.FailReason.quota_exceeded, p.fail.?);
    try testing.expectEqualStrings("MEGA transfer quota exceeded — wait 5 hours 3 minutes", p.msg);
    try e.cancel(ref);
}

test "mega engine: cancel runs transfers lookup and -c" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try FakeMega.create(.{ .hang = true });
    defer f.destroy();
    const e = f.eng.engine();
    var db: [512]u8 = undefined;
    const dest = try f.destDir(&db);
    const ref = try e.start(.{ .job_id = 1, .url = "https://mega.nz/file/abc#key", .headers = &.{}, .dest_dir = dest, .out_name = null, .torrent_bytes = null });
    defer testing.allocator.free(ref);
    // Wait until the client printed its progress (it then hangs).
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const p = try e.poll(ref);
        try testing.expectEqual(model.Phase.downloading, p.phase);
        if (p.bytes_done == 6 * 1024 * 1024) break;
        testing.io.sleep(Io.Duration.fromMilliseconds(10), .real) catch {};
    } else return error.TestTimedOut;
    try e.cancel(ref);
    try testing.expectEqual(model.Phase.removed, (try e.poll(ref)).phase);
    const lg = try f.argvLog();
    defer testing.allocator.free(lg);
    try testing.expect(std.mem.indexOf(u8, lg, "mega-transfers --only-downloads --col-separator=| --output-cols=TAG,DESTINYPATH,PROGRESS,STATE --limit=1000") != null);
    try testing.expect(std.mem.indexOf(u8, lg, "mega-transfers -c 12") != null);
}

test "mega engine: setLimits waits for a run, then sends speedlimit once per change" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try FakeMega.create(.{ .hang = true });
    defer f.destroy();
    const e = f.eng.engine();
    const plan: policy.Plan = .{ .aria2_global_down = 0, .aria2_global_up = 0, .per_torrent_down = 0, .per_file_down = 0, .mega_down = 4096 };
    try e.setLimits(plan);
    try testing.expectEqual(@as(?u64, null), f.eng.last_limit); // idle: no spawn
    var db: [512]u8 = undefined;
    const dest = try f.destDir(&db);
    const ref = try e.start(.{ .job_id = 1, .url = "https://mega.nz/file/abc#key", .headers = &.{}, .dest_dir = dest, .out_name = null, .torrent_bytes = null });
    defer testing.allocator.free(ref);
    try testing.expectEqual(@as(?u64, 4096), f.eng.last_limit);
    try e.setLimits(plan); // unchanged → no second call
    try e.cancel(ref);
    const lg = try f.argvLog();
    defer testing.allocator.free(lg);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, lg, "mega-speedlimit -d 4096"));
}

test "mega engine: login result mapping" {
    try testing.expectEqual(LoginResult.ok, loginResult(0, "", ""));
    try testing.expectEqual(LoginResult.already_logged_in, loginResult(54, "", ""));
    try testing.expectEqual(LoginResult.needs_auth_code, loginResult(1, "[API:err: ...] ERR Two-factor Authentication required\n", ""));
    try testing.expectEqual(LoginResult.needs_auth_code, loginResult(9, "", "Enter the 2FA code"));
    try testing.expectEqual(LoginResult.bad_credentials, loginResult(9, "Login failed: invalid email or password", ""));
    try testing.expectEqual(LoginResult.bad_credentials, loginResult(9, "[API:err: 12:00:00] Login failed: authentication failed", ""));
    try testing.expectEqual(LoginResult.needs_auth_code, loginResult(9, "Please enter the authentication code", ""));
    try testing.expectEqual(LoginResult.needs_auth_code, loginResult(9, "Multi-factor authentication is enabled", ""));
}

test "mega engine: ERR lines match in any case" {
    try testing.expect(isErrLine("[API:err: 12:00:00] Failed to get node"));
    try testing.expect(isErrLine("[12:00:00] ERR Not found"));
    try testing.expect(isErrLine("[ERR: x] boom"));
    try testing.expect(!isErrLine("TRANSFERRING ||##||( 1/6 MB:  16.67 %)"));
    try testing.expect(!isErrLine("Download finished: /x/error.zip"));
}

test "mega engine: >64 KB of stdout before exit does not stall the reader" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try FakeMega.create(.{ .bigout = true });
    defer f.destroy();
    const e = f.eng.engine();
    var db: [512]u8 = undefined;
    const dest = try f.destDir(&db);
    const ref = try e.start(.{ .job_id = 1, .url = "https://mega.nz/file/abc#key", .headers = &.{}, .dest_dir = dest, .out_name = null, .torrent_bytes = null });
    defer testing.allocator.free(ref);
    const p = try pollUntilDone(e, ref);
    try testing.expectEqual(model.Phase.transfer_done, p.phase);
    const run = f.eng.runs.get(1).?;
    try testing.expectEqual(@as(?u8, 0), run.exit_code);
    try testing.expectEqual(@as(usize, STDOUT_MAX), run.out_len); // capped, rest drained
    // `Download finished:` sat past the cap; the single-file rule finds it.
    try testing.expect(std.mem.endsWith(u8, p.final_path.?, "Game.zip"));
    try e.cancel(ref);
}

test "mega engine: a run without a server binary fails engine_missing" {
    var me = MegaEngine.init(testing.allocator, testing.io, .{
        .client = try testing.allocator.dupe(u8, "/x/MegaClient.exe"),
        .server = null,
        .dir = try testing.allocator.dupe(u8, "/x"),
        .is_windows_direct = true,
    });
    defer me.deinit();
    const dest = try testing.allocator.dupe(u8, "/x/dl");
    const run = try testing.allocator.create(Run);
    run.* = .{ .child = undefined, .dest_dir = dest, .no_server = true };
    run.done.store(true, .release);
    try me.runs.put(testing.allocator, 7, run);
    const e = me.engine();
    const p = try e.poll("mega:7");
    try testing.expectEqual(model.Phase.failed, p.phase);
    try testing.expectEqual(model.FailReason.engine_missing, p.fail.?);
    try testing.expectEqualStrings(NO_SERVER_MSG, p.msg);
    try testing.expectEqual(@as(?[]u8, null), try e.finalPath(testing.allocator, "mega:7"));
    try e.cancel("mega:7");
}

test "mega engine: underDir needs a separator after the prefix" {
    try testing.expect(underDir("/d/dl/1/Game.zip", "/d/dl/1"));
    try testing.expect(underDir("/d/dl/1", "/d/dl/1/"));
    try testing.expect(!underDir("/d/dl/10/Game.zip", "/d/dl/1"));
    try testing.expect(underDir("C:\\dl\\1\\Game.zip", "C:\\dl\\1"));
}

test "mega engine: Windows-only paths are analysed" {
    // Force semantic analysis of the account/server code on every target.
    _ = &MegaEngine.ensureServer;
    _ = &MegaEngine.login;
    _ = &MegaEngine.whoami;
    _ = &MegaEngine.logout;
    _ = &Run.killChild;
    _ = &MegaEngine.engine;
    _ = &MegaEngine.deinit;
}
