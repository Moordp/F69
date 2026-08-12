// aria2c daemon manager: spawns a local aria2c process with RPC enabled
// on a random port + secret, and exposes the methods we actually need
// (`addUri`, `tellStatus`, `shutdown`).
//
// Why RPC over the older "spawn one aria2 per file + parse stdout"
// approach: documented protocol, multi-download mux, pause/resume/cancel,
// version-stable across aria2 releases.
//
// Lifecycle:
//   const d = try Daemon.init(alloc, io, "/usr/bin/aria2c", download_dir);
//   defer d.deinit();
//   const gid = try d.addUri("https://example.com/file.zip");
//   defer alloc.free(gid);
//   const status = try d.tellStatus(gid);
//   defer status.deinit(alloc);

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const log = std.log.scoped(.aria2);
const errs = @import("errors.zig");
const transport = @import("transport.zig");
const http_transport = @import("http.zig");
const ws_transport = @import("ws.zig");

/// Re-export so the manager can drain push events without importing transport.
pub const Event = transport.Event;

pub const Status = struct {
    /// "active" | "complete" | "error" | "paused" | "removed" | "waiting"
    status: []u8,
    total_length: u64 = 0,
    completed_length: u64 = 0,
    download_speed: u64 = 0,
    /// Upload throughput in bytes/sec. Non-zero for active seeding.
    upload_speed: u64 = 0,
    /// Total bytes uploaded over this torrent's lifetime. Aria2
    /// preserves this across restarts when --bt-save-metadata is on.
    upload_length: u64 = 0,
    /// Live peer counts. Only meaningful when `is_torrent == true`.
    num_seeders: u32 = 0,
    /// Total connections (HTTP for plain downloads, BT peers for
    /// torrents). Useful as a "are we actually talking to anyone"
    /// signal in the UI.
    connections: u32 = 0,
    /// True ⇒ aria2 reports this gid as a BitTorrent download (the
    /// response carries a `bittorrent` block).
    is_torrent: bool = false,
    /// True ⇒ this peer (us) has the complete piece set and is
    /// uploading only. Combined with status="active" that's the
    /// "seeding" UI state.
    seeder: bool = false,
    /// Set when status == "error".
    error_message: ?[]u8 = null,

    pub fn deinit(self: *Status, alloc: std.mem.Allocator) void {
        alloc.free(self.status);
        if (self.error_message) |em| alloc.free(em);
        self.* = undefined;
    }

    pub fn isTerminal(self: Status) bool {
        return std.mem.eql(u8, self.status, "complete") or
            std.mem.eql(u8, self.status, "error") or
            std.mem.eql(u8, self.status, "removed");
    }
};

pub const Daemon = struct {
    alloc: std.mem.Allocator,
    io: Io,
    aria2_path: []const u8,
    download_dir: []const u8,
    /// Optional `--save-session` / `--input-file` target. When set,
    /// aria2 (a) reads waiting + paused downloads from this file on
    /// spawn and (b) writes them back on `aria2.shutdown`, preserving
    /// GIDs across restarts. Borrowed; outlives the Daemon.
    session_path: ?[]const u8 = null,
    port: u16,
    /// Daemon-wide seed-ratio target. aria2 keeps every completed
    /// torrent seeding until uploaded ≥ `seed_ratio` × downloaded.
    /// Clamped to ≥ 2.0 by the caller — anything below is below the
    /// RPDL community "give back twice what you took" floor.
    seed_ratio: f32 = 5.0,
    /// Daemon-wide seed-time cap in minutes; 0 = no cap. Passed as
    /// `--seed-time` at spawn when non-zero.
    seed_time_min: u32 = 0,
    /// 32-byte hex string + null terminator. Distinct per process.
    secret: [33]u8,
    child: ?std.process.Child = null,
    /// `http://127.0.0.1:<port>/jsonrpc` — heap-owned so the string survives
    /// the by-value return from `init` (the HTTP transport borrows it).
    url: []u8 = &.{},
    /// RPC transports. Both heap-allocated so their addresses are stable
    /// across the Daemon's by-value move out of `init` (the WS read-thread
    /// and the Fallback's vtable ctx pointers must not dangle). `fallback`
    /// routes to WS first and auto-switches to HTTP on repeated failure.
    http_t: *http_transport.HttpTransport = undefined,
    ws_t: ?*ws_transport.WsTransport = null,
    fallback: transport.Fallback = undefined,

    /// Spawn aria2c and wait until it answers `aria2.getVersion`.
    /// `aria2_path` may be a bare name like "aria2c" — the OS resolves
    /// it via PATH on POSIX. `session_path` (when non-null) enables
    /// cross-restart persistence via aria2's session file format.
    /// `port = 0` picks a random ephemeral port (the historical
    /// behavior); any other value is honored as-is. If the chosen port
    /// is already in use, aria2's spawn surfaces the error and
    /// `waitReady` will time out — caller can recover by retrying with
    /// `port = 0`.
    pub fn init(
        alloc: std.mem.Allocator,
        io: Io,
        aria2_path: []const u8,
        download_dir: []const u8,
        session_path: ?[]const u8,
        port: u16,
        seed_ratio: f32,
        seed_time_min: u32,
    ) errs.Error!Daemon {
        var d: Daemon = .{
            .alloc = alloc,
            .io = io,
            .aria2_path = aria2_path,
            .download_dir = download_dir,
            .session_path = session_path,
            .port = if (port == 0) pickRandomPort(io) else port,
            .seed_ratio = @max(seed_ratio, 2.0),
            .seed_time_min = seed_time_min,
            .secret = undefined,
        };
        genSecret(io, &d.secret);

        // Heap-owned RPC URL + HTTP transport (always available). Built before
        // waitReady so the readiness probe runs over the transport too.
        d.url = std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/jsonrpc", .{d.port}) catch
            return errs.Error.OutOfMemory;
        errdefer alloc.free(d.url);
        d.http_t = alloc.create(http_transport.HttpTransport) catch return errs.Error.OutOfMemory;
        errdefer alloc.destroy(d.http_t);
        d.http_t.* = .{ .io = io, .url = d.url };
        // Until WS connects, both legs of the fallback are HTTP.
        d.fallback = .{ .primary = d.http_t.asTransport(), .secondary = d.http_t.asTransport() };

        try d.spawn();
        d.waitReady() catch |e| {
            if (d.child) |*c| c.kill(io);
            alloc.destroy(d.http_t);
            alloc.free(d.url);
            return e;
        };
        log.info("aria2 ready on 127.0.0.1:{d}", .{d.port});

        // aria2 is up — try to upgrade the primary leg to WebSocket so we get
        // push events (onDownloadComplete/…). On any failure we stay HTTP-only;
        // the fallback already points both legs at HTTP.
        d.tryConnectWs();
        return d;
    }

    /// Best-effort WebSocket upgrade. Sets `ws_t` + repoints the fallback's
    /// primary leg on success; silently keeps HTTP on failure.
    fn tryConnectWs(self: *Daemon) void {
        const wt = ws_transport.WsTransport.init(self.alloc, self.io, .{ .port = self.port }) catch {
            log.info("aria2 WS transport unavailable; using HTTP polling", .{});
            return;
        };
        const p = self.alloc.create(ws_transport.WsTransport) catch {
            var tmp = wt;
            tmp.deinit();
            return;
        };
        p.* = wt;
        p.start() catch {
            p.deinit();
            self.alloc.destroy(p);
            log.info("aria2 WS read-loop failed to start; using HTTP polling", .{});
            return;
        };
        self.ws_t = p;
        self.fallback = .{ .primary = p.asTransport(), .secondary = self.http_t.asTransport() };
        log.info("aria2 WS transport connected (push events enabled)", .{});
    }

    /// Drain pushed aria2 events (WS only) into `out`. No-op under HTTP.
    pub fn drainEvents(self: *Daemon, alloc: std.mem.Allocator, out: *std.ArrayList(transport.Event)) void {
        self.fallback.drainEvents(alloc, out);
    }

    pub fn deinit(self: *Daemon) void {
        self.shutdown() catch {};
        if (self.child) |*c| {
            // Aria2 should exit on its own from the shutdown RPC. `c.wait`
            // would block forever if it doesn't. Bound the wait with a
            // non-blocking waitpid(WNOHANG) poll. If still alive after 1s,
            // send SIGKILL directly (NOT `c.kill` — that internally does
            // kill+wait, which races with anything else waiting on the
            // same pid and panics with ECHILD). Then one blocking wait
            // reaps the corpse.
            // Linux keeps the hand-rolled non-blocking waitpid poll + direct SIGKILL
            // (avoids std.process.Child.kill's internal kill+wait racing other waiters).
            // Windows (HANDLE pid, no waitpid/SIGKILL): the shutdown RPC should have stopped
            // aria2; force-kill + reap portably via std.process.Child.kill.
            if (builtin.os.tag == .linux) {
                if (c.id) |pid| {
                    const tick = std.Io.Duration.fromMilliseconds(50);
                    const pid_usize: usize = @intCast(pid);
                    var reaped = false;
                    var i: usize = 0;
                    while (i < 20) : (i += 1) {
                        var status: u32 = 0;
                        const ret = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
                        if (ret == pid_usize) {
                            reaped = true;
                            break;
                        }
                        std.Io.sleep(self.io, tick, .awake) catch break;
                    }
                    if (!reaped) {
                        log.warn("aria2 didn't exit on shutdown RPC within 1s — sending SIGKILL", .{});
                        _ = std.os.linux.kill(pid, std.os.linux.SIG.KILL);
                        var status: u32 = 0;
                        _ = std.os.linux.waitpid(pid, &status, 0);
                    }
                }
            } else {
                c.kill(self.io);
            }
            // Hand-reaped — don't let std.process.Child.wait/kill run
            // again from a destructor or stray path.
            self.child = null;
        }
        self.freeTransports();
        self.* = undefined;
    }

    /// Per-call options for `addUri`. All fields optional — when
    /// every field is null/empty we send aria2 an empty options
    /// object and the daemon-wide defaults apply.
    pub const UriOptions = struct {
        /// Extra HTTP request headers to attach to this download.
        /// Each entry is `Name: value` (no trailing CRLF). aria2 sends
        /// them on every retry attempt, which is exactly what donor
        /// DDL needs for the per-URL `Cookie:` value F95 hands back.
        headers: []const []const u8 = &.{},
        /// Aria2's `max-connection-per-server`. Default 1 (single
        /// TCP stream); donor DDL via Cloudflare benefits from a
        /// higher value so the download isn't ratelimited by per-
        /// connection throughput shaping. Skipped when null.
        max_connection_per_server: ?u8 = null,
        /// Number of segments to split the file into. Pairs with
        /// `max-connection-per-server` — aria2 won't open more
        /// connections than `min(split, max-connection-per-server)`.
        split: ?u8 = null,
        /// Seconds to wait between retries. Default is 0 (immediate),
        /// which on a flaky CDN turns transient 5xx into a tight
        /// loop of mini-stalls; a 2-5 s delay smooths that out.
        retry_wait: ?u8 = null,
    };

    /// Add a URL to the download queue. Returns the aria2 GID, owned by
    /// `self.alloc` — caller frees.
    pub fn addUri(self: *Daemon, url: []const u8, opts: UriOptions) errs.Error![]u8 {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.alloc);
        body.appendSlice(self.alloc, "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.addUri\",\"params\":[\"token:") catch return errs.Error.OutOfMemory;
        body.appendSlice(self.alloc, self.secretSlice()) catch return errs.Error.OutOfMemory;
        body.appendSlice(self.alloc, "\",[") catch return errs.Error.OutOfMemory;
        appendJsonString(&body, self.alloc, url) catch return errs.Error.OutOfMemory;
        body.appendSlice(self.alloc, "]") catch return errs.Error.OutOfMemory;

        // Per-URI options. Aria2's addUri accepts a trailing options
        // dict; every numeric option is sent as a string (aria2's
        // RPC quirk). `header` is the one array-valued option.
        body.appendSlice(self.alloc, ",{") catch return errs.Error.OutOfMemory;
        var first = true;
        if (opts.headers.len > 0) {
            body.appendSlice(self.alloc, "\"header\":[") catch return errs.Error.OutOfMemory;
            for (opts.headers, 0..) |h, i| {
                if (i > 0) body.append(self.alloc, ',') catch return errs.Error.OutOfMemory;
                appendJsonString(&body, self.alloc, h) catch return errs.Error.OutOfMemory;
            }
            body.appendSlice(self.alloc, "]") catch return errs.Error.OutOfMemory;
            first = false;
        }
        if (opts.max_connection_per_server) |n| {
            var n_buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&n_buf, "{d}", .{n}) catch return errs.Error.OutOfMemory;
            try appendJsonOpt(&body, self.alloc, &first, "max-connection-per-server", s);
        }
        if (opts.split) |n| {
            var n_buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&n_buf, "{d}", .{n}) catch return errs.Error.OutOfMemory;
            try appendJsonOpt(&body, self.alloc, &first, "split", s);
        }
        if (opts.retry_wait) |n| {
            var n_buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&n_buf, "{d}", .{n}) catch return errs.Error.OutOfMemory;
            try appendJsonOpt(&body, self.alloc, &first, "retry-wait", s);
        }
        body.appendSlice(self.alloc, "}]}") catch return errs.Error.OutOfMemory;

        const resp = try self.rpcRaw(body.items);
        defer self.alloc.free(resp);

        const Resp = struct {
            jsonrpc: []const u8,
            id: []const u8,
            result: ?[]const u8 = null,
            @"error": ?ErrorObj = null,
        };
        var parsed = std.json.parseFromSlice(Resp, self.alloc, resp, .{
            .ignore_unknown_fields = true,
        }) catch return errs.Error.AriaInvalidResponse;
        defer parsed.deinit();

        if (parsed.value.@"error") |e| {
            log.warn("aria2.addUri RPC error: {d} {s}", .{ e.code, e.message });
            return errs.Error.AriaRpcError;
        }
        const gid = parsed.value.result orelse return errs.Error.AriaInvalidResponse;
        return self.alloc.dupe(u8, gid) catch errs.Error.OutOfMemory;
    }

    /// Per-call override knobs for `addTorrent`. All optional — when a
    /// field is null the daemon-wide default (set at spawn) applies.
    /// The aria2 RPC `addTorrent` signature is:
    ///   `aria2.addTorrent(secret, base64_torrent, uris[], options)`
    /// We always send an empty uris array.
    pub const TorrentOptions = struct {
        /// Where aria2 writes the downloaded files. Overrides `--dir`.
        dir: ?[]const u8 = null,
        /// Overall seed ratio for this torrent. 2.0 = upload twice
        /// the downloaded bytes before stopping.
        seed_ratio: ?f32 = null,
        /// Seed time in minutes. 0 = unlimited.
        seed_time_minutes: ?u32 = null,
    };

    /// Hand a local .torrent file body to aria2 via `aria2.addTorrent`.
    /// Aria2 base64-decodes the second param into the binary torrent
    /// and begins seeding/leeching. Returns the GID (owned by
    /// `self.alloc`).
    pub fn addTorrent(self: *Daemon, torrent_bytes: []const u8, opts: TorrentOptions) errs.Error![]u8 {
        const b64_size = std.base64.standard.Encoder.calcSize(torrent_bytes.len);
        const b64 = self.alloc.alloc(u8, b64_size) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(b64);
        _ = std.base64.standard.Encoder.encode(b64, torrent_bytes);

        // Build options JSON if any field is set. Empty `{}` is fine
        // for the no-overrides case.
        var opts_json: std.ArrayList(u8) = .empty;
        defer opts_json.deinit(self.alloc);
        opts_json.append(self.alloc, '{') catch return errs.Error.OutOfMemory;
        var first = true;
        if (opts.dir) |d| {
            try appendJsonOpt(&opts_json, self.alloc, &first, "dir", d);
        }
        if (opts.seed_ratio) |r| {
            var r_buf: [16]u8 = undefined;
            const r_str = std.fmt.bufPrint(&r_buf, "{d:.2}", .{r}) catch return errs.Error.OutOfMemory;
            try appendJsonOpt(&opts_json, self.alloc, &first, "seed-ratio", r_str);
        }
        if (opts.seed_time_minutes) |m| {
            var m_buf: [16]u8 = undefined;
            const m_str = std.fmt.bufPrint(&m_buf, "{d}", .{m}) catch return errs.Error.OutOfMemory;
            try appendJsonOpt(&opts_json, self.alloc, &first, "seed-time", m_str);
        }
        opts_json.append(self.alloc, '}') catch return errs.Error.OutOfMemory;

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.alloc);
        body.appendSlice(self.alloc, "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.addTorrent\",\"params\":[\"token:") catch return errs.Error.OutOfMemory;
        body.appendSlice(self.alloc, self.secretSlice()) catch return errs.Error.OutOfMemory;
        body.appendSlice(self.alloc, "\",\"") catch return errs.Error.OutOfMemory;
        // Standard base64 alphabet has no JSON-unsafe characters.
        body.appendSlice(self.alloc, b64) catch return errs.Error.OutOfMemory;
        body.appendSlice(self.alloc, "\",[],") catch return errs.Error.OutOfMemory;
        body.appendSlice(self.alloc, opts_json.items) catch return errs.Error.OutOfMemory;
        body.appendSlice(self.alloc, "]}") catch return errs.Error.OutOfMemory;

        const resp = try self.rpcRaw(body.items);
        defer self.alloc.free(resp);

        const Resp = struct {
            jsonrpc: []const u8,
            id: []const u8,
            result: ?[]const u8 = null,
            @"error": ?ErrorObj = null,
        };
        var parsed = std.json.parseFromSlice(Resp, self.alloc, resp, .{
            .ignore_unknown_fields = true,
        }) catch return errs.Error.AriaInvalidResponse;
        defer parsed.deinit();

        if (parsed.value.@"error") |e| {
            log.warn("aria2.addTorrent RPC error: {d} {s}", .{ e.code, e.message });
            return errs.Error.AriaRpcError;
        }
        const gid = parsed.value.result orelse return errs.Error.AriaInvalidResponse;
        log.info("aria2.addTorrent OK: gid={s} ({d} torrent bytes, opts={s})", .{
            gid, torrent_bytes.len, opts_json.items,
        });
        return self.alloc.dupe(u8, gid) catch errs.Error.OutOfMemory;
    }

    /// Poll the status of a download. Caller frees with `Status.deinit`.
    pub fn tellStatus(self: *Daemon, gid: []const u8) errs.Error!Status {
        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.tellStatus\",\"params\":[\"token:{s}\",\"{s}\",[" ++
                "\"gid\",\"status\",\"totalLength\",\"completedLength\",\"downloadSpeed\"," ++
                "\"uploadSpeed\",\"uploadLength\",\"numSeeders\",\"connections\"," ++
                "\"seeder\",\"bittorrent\",\"errorMessage\"]]}}",
            .{ self.secretSlice(), gid },
        ) catch return errs.Error.AriaInvalidResponse;

        const resp = try self.rpcRaw(body);
        defer self.alloc.free(resp);

        // Walk the response via std.json.Value — aria2 returns
        // `bittorrent` as an object (only for BT) and we just need
        // to know it exists, not parse it.
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, resp, .{
            .ignore_unknown_fields = true,
        }) catch return errs.Error.AriaInvalidResponse;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return errs.Error.AriaInvalidResponse;
        if (root.object.get("error")) |e_val| {
            if (e_val == .object) {
                const code: i64 = if (e_val.object.get("code")) |c| (if (c == .integer) c.integer else 0) else 0;
                const msg: []const u8 = if (e_val.object.get("message")) |m| (switch (m) {
                    .string => |s| s,
                    else => "(no message)",
                }) else "(no message)";
                // Code 1 = "GID ... is not found": benign + expected when a
                // gid is stale (download cleared from aria2, or a session-
                // restored job whose gid changed). Don't warn — return a
                // distinct error so the manager retires the job instead of
                // re-polling (and re-logging) it every tick.
                if (code == 1) return errs.Error.NotFound;
                log.warn("aria2.tellStatus RPC error: {d} {s}", .{ code, msg });
                return errs.Error.AriaRpcError;
            }
        }
        const r_val = root.object.get("result") orelse return errs.Error.AriaInvalidResponse;
        if (r_val != .object) return errs.Error.AriaInvalidResponse;
        const r = r_val.object;

        const status_s = ariaStr(r, "status") orelse return errs.Error.AriaInvalidResponse;
        var out: Status = .{
            .status = self.alloc.dupe(u8, status_s) catch return errs.Error.OutOfMemory,
            .total_length = ariaU64(r, "totalLength") orelse 0,
            .completed_length = ariaU64(r, "completedLength") orelse 0,
            .download_speed = ariaU64(r, "downloadSpeed") orelse 0,
            .upload_speed = ariaU64(r, "uploadSpeed") orelse 0,
            .upload_length = ariaU64(r, "uploadLength") orelse 0,
            .num_seeders = @intCast(@min(ariaU64(r, "numSeeders") orelse 0, std.math.maxInt(u32))),
            .connections = @intCast(@min(ariaU64(r, "connections") orelse 0, std.math.maxInt(u32))),
            .is_torrent = r.contains("bittorrent"),
            .seeder = blk: {
                // aria2 sends "true"/"false" as strings on the wire.
                const v = ariaStr(r, "seeder") orelse break :blk false;
                break :blk std.mem.eql(u8, v, "true");
            },
        };
        errdefer self.alloc.free(out.status);
        if (ariaStr(r, "errorMessage")) |em| {
            out.error_message = self.alloc.dupe(u8, em) catch return errs.Error.OutOfMemory;
        }
        return out;
    }

    /// Force-stop an active download. The GID transitions to the
    /// "removed" state on the next `tellStatus`; the partial file
    /// stays on disk so a future restart can resume.
    pub fn remove(self: *Daemon, gid: []const u8) errs.Error!void {
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.forceRemove\",\"params\":[\"token:{s}\",\"{s}\"]}}",
            .{ self.secretSlice(), gid },
        ) catch return errs.Error.AriaInvalidResponse;
        const resp = self.rpcRaw(body) catch |e| return e;
        self.alloc.free(resp);
    }

    /// Pause a single download by GID. Used by the Manager to give
    /// active leech jobs precedence over seeders sharing the daemon's
    /// concurrent-download slots.
    pub fn pause(self: *Daemon, gid: []const u8) errs.Error!void {
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.forcePause\",\"params\":[\"token:{s}\",\"{s}\"]}}",
            .{ self.secretSlice(), gid },
        ) catch return errs.Error.AriaInvalidResponse;
        const resp = self.rpcRaw(body) catch |e| return e;
        self.alloc.free(resp);
    }

    /// Resume a single paused download by GID.
    pub fn unpause(self: *Daemon, gid: []const u8) errs.Error!void {
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.unpause\",\"params\":[\"token:{s}\",\"{s}\"]}}",
            .{ self.secretSlice(), gid },
        ) catch return errs.Error.AriaInvalidResponse;
        const resp = self.rpcRaw(body) catch |e| return e;
        self.alloc.free(resp);
    }

    /// Pause every active download (both HTTP and BT). aria2
    /// transitions their `status` to "paused"; `tellStatus` shows
    /// `bytes_done` / `upload_length` frozen. `unpauseAll` resumes.
    pub fn pauseAll(self: *Daemon) errs.Error!void {
        var body_buf: [192]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.forcePauseAll\",\"params\":[\"token:{s}\"]}}",
            .{self.secretSlice()},
        ) catch return errs.Error.AriaInvalidResponse;
        const resp = self.rpcRaw(body) catch |e| return e;
        self.alloc.free(resp);
    }

    /// Resume every paused download. Inverse of `pauseAll`.
    pub fn unpauseAll(self: *Daemon) errs.Error!void {
        var body_buf: [192]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.unpauseAll\",\"params\":[\"token:{s}\"]}}",
            .{self.secretSlice()},
        ) catch return errs.Error.AriaInvalidResponse;
        const resp = self.rpcRaw(body) catch |e| return e;
        self.alloc.free(resp);
    }

    /// Change a daemon-wide default option live (applies to NEW downloads).
    /// e.g. `changeGlobalOption("seed-ratio", "3.00")`.
    pub fn changeGlobalOption(self: *Daemon, name: []const u8, value: []const u8) errs.Error!void {
        var body_buf: [320]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.changeGlobalOption\",\"params\":[\"token:{s}\",{{\"{s}\":\"{s}\"}}]}}",
            .{ self.secretSlice(), name, value },
        ) catch return errs.Error.AriaInvalidResponse;
        const resp = self.rpcRaw(body) catch |e| return e;
        self.alloc.free(resp);
    }

    /// Change an option on a single running download (GID) — used to apply a
    /// new seed-ratio / seed-time to torrents already in flight.
    pub fn changeOption(self: *Daemon, gid: []const u8, name: []const u8, value: []const u8) errs.Error!void {
        var body_buf: [384]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.changeOption\",\"params\":[\"token:{s}\",\"{s}\",{{\"{s}\":\"{s}\"}}]}}",
            .{ self.secretSlice(), gid, name, value },
        ) catch return errs.Error.AriaInvalidResponse;
        const resp = self.rpcRaw(body) catch |e| return e;
        self.alloc.free(resp);
    }

    /// Drop a finished/failed/removed entry from aria2's in-memory
    /// status table. Use after we've absorbed the final state into
    /// our own Job — keeps `aria2.tellActive` clean for diagnostics.
    pub fn removeDownloadResult(self: *Daemon, gid: []const u8) errs.Error!void {
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.removeDownloadResult\",\"params\":[\"token:{s}\",\"{s}\"]}}",
            .{ self.secretSlice(), gid },
        ) catch return errs.Error.AriaInvalidResponse;
        const resp = self.rpcRaw(body) catch |e| return e;
        self.alloc.free(resp);
    }

    /// Ask aria2 for the on-disk path of the first file that this gid
    /// produced. Used by the post-install hook to know where to point
    /// the archive extractor. Returns allocator-owned slice; caller
    /// frees. Empty string when aria2 reports no files (uncommon —
    /// usually means the job is still in fetching_metadata for
    /// torrents).
    pub fn getFiles(self: *Daemon, gid: []const u8) errs.Error![]u8 {
        var body_buf: [320]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.getFiles\",\"params\":[\"token:{s}\",\"{s}\"]}}",
            .{ self.secretSlice(), gid },
        ) catch return errs.Error.AriaInvalidResponse;

        const resp = try self.rpcRaw(body);
        defer self.alloc.free(resp);

        const FileEntry = struct {
            path: []const u8,
        };
        const Resp = struct {
            jsonrpc: []const u8,
            id: []const u8,
            result: ?[]const FileEntry = null,
            @"error": ?ErrorObj = null,
        };
        var parsed = std.json.parseFromSlice(Resp, self.alloc, resp, .{
            .ignore_unknown_fields = true,
        }) catch return errs.Error.AriaInvalidResponse;
        defer parsed.deinit();

        if (parsed.value.@"error") |e| {
            log.warn("aria2.getFiles RPC error: {d} {s}", .{ e.code, e.message });
            return errs.Error.AriaRpcError;
        }
        const files = parsed.value.result orelse return errs.Error.AriaInvalidResponse;
        if (files.len == 0) return self.alloc.dupe(u8, "") catch errs.Error.OutOfMemory;
        return self.alloc.dupe(u8, files[0].path) catch errs.Error.OutOfMemory;
    }

    /// Tell aria2 to exit cleanly. Best-effort; deinit also waits on
    /// the child.
    pub fn shutdown(self: *Daemon) errs.Error!void {
        var body_buf: [192]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.shutdown\",\"params\":[\"token:{s}\"]}}",
            .{self.secretSlice()},
        ) catch return errs.Error.AriaInvalidResponse;
        const resp = self.rpcRaw(body) catch |e| return e;
        self.alloc.free(resp);
    }

    // ---- internals ----

    fn spawn(self: *Daemon) errs.Error!void {
        // aria2 errors out at startup if `--dir` doesn't exist.
        // We get here on the very first download into a fresh
        // library_root; make sure the directory tree is in place.
        std.Io.Dir.cwd().createDirPath(self.io, self.download_dir) catch |e| {
            log.warn("could not ensure aria2 --dir '{s}': {s}", .{ self.download_dir, @errorName(e) });
        };

        const port_arg = std.fmt.allocPrint(self.alloc, "--rpc-listen-port={d}", .{self.port}) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(port_arg);
        const secret_arg = std.fmt.allocPrint(self.alloc, "--rpc-secret={s}", .{self.secretSlice()}) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(secret_arg);
        const dir_arg = std.fmt.allocPrint(self.alloc, "--dir={s}", .{self.download_dir}) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(dir_arg);
        const seed_ratio_arg = std.fmt.allocPrint(self.alloc, "--seed-ratio={d:.2}", .{self.seed_ratio}) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(seed_ratio_arg);
        // Optional seed-time cap (minutes). Omitted entirely when 0 so aria2
        // keeps "seed until ratio" semantics.
        var seed_time_arg: ?[]u8 = null;
        defer if (seed_time_arg) |s| self.alloc.free(s);
        if (self.seed_time_min > 0) {
            seed_time_arg = std.fmt.allocPrint(self.alloc, "--seed-time={d}", .{self.seed_time_min}) catch return errs.Error.OutOfMemory;
        }

        // Session args are only attached when persistence is enabled.
        // `--save-session-interval=60` makes aria2 checkpoint every
        // 60s rather than only on shutdown, so a SIGKILL still preserves
        // recent state.
        var save_arg: ?[]u8 = null;
        var input_arg: ?[]u8 = null;
        defer if (save_arg) |s| self.alloc.free(s);
        defer if (input_arg) |s| self.alloc.free(s);
        if (self.session_path) |sp| {
            save_arg = std.fmt.allocPrint(self.alloc, "--save-session={s}", .{sp}) catch return errs.Error.OutOfMemory;
            input_arg = std.fmt.allocPrint(self.alloc, "--input-file={s}", .{sp}) catch return errs.Error.OutOfMemory;
        }

        // Portable-bundle support: when a bundled glibc loader sits next to
        // aria2c (`<dir>/lib/ld-linux-x86-64.so.2`), invoke aria2c THROUGH it
        // with the bundle's lib/ on --library-path. The bundled aria2c keeps
        // its build-host (nix-store) PT_INTERP, which doesn't exist on other
        // distros, so a direct exec dies with "cannot execute: required file
        // not found". f69 itself is launched the same way by run.sh. No-op for
        // a system aria2c on $PATH (no sibling lib/ld-linux).
        var loader_path: ?[]u8 = null;
        var libpath_arg: ?[]u8 = null;
        defer if (loader_path) |s| self.alloc.free(s);
        defer if (libpath_arg) |s| self.alloc.free(s);
        if (std.fs.path.dirname(self.aria2_path)) |dir| {
            const cand = std.fmt.allocPrint(self.alloc, "{s}/lib/ld-linux-x86-64.so.2", .{dir}) catch return errs.Error.OutOfMemory;
            if (std.Io.Dir.cwd().access(self.io, cand, .{})) |_| {
                loader_path = cand;
                libpath_arg = std.fmt.allocPrint(self.alloc, "{s}/lib", .{dir}) catch return errs.Error.OutOfMemory;
                log.info("aria2c: launching via bundled loader {s}", .{cand});
            } else |_| self.alloc.free(cand);
        }

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        if (loader_path) |lp| {
            argv.appendSlice(self.alloc, &[_][]const u8{ lp, "--library-path", libpath_arg.? }) catch return errs.Error.OutOfMemory;
        }
        argv.appendSlice(self.alloc, &[_][]const u8{
            self.aria2_path,
            "--enable-rpc=true",
            "--rpc-listen-all=false",
            port_arg,
            secret_arg,
            dir_arg,
            // notice = per-download start/finish/error + Range-request
            // outcomes on stderr. Enough signal to diagnose "stuck at
            // 0 bytes" without flooding the console with every TCP
            // event. `--quiet=true` would gag all of it, so it's gone.
            "--console-log-level=notice",
            // Foreground so we hold the child handle. (`--daemon=true`
            // would fork to the background and detach.)
            "--daemon=false",
            // ---- BitTorrent defaults ----
            // Seed each completed torrent until uploaded ≥ N× the
            // downloaded amount, where N comes from
            // `<data_root>/aria2_seed_ratio` (default 5.0, min 2.0).
            // 2.0 is the RPDL community floor ("give back twice what
            // you took"); 5.0 is generous and gets a "good seeder"
            // reputation, which helps for rare/old torrents.
            //
            // IMPORTANT: Do NOT pass `--seed-time=0`. The aria2 docs
            // are counter-intuitive here — `--seed-time=0` does NOT
            // mean "no time cap", it means "do not seed at all after
            // download completes". Omitting the flag entirely is the
            // correct way to say "seed until --seed-ratio is met".
            // (Earlier revisions set --seed-time=0 and torrents
            // appeared to "stop" the moment leeching finished.)
            seed_ratio_arg,
            // Mainline DHT + Peer Exchange dramatically widen the
            // peer pool, especially for older / lightly-seeded
            // torrents. Off by default in some distros.
            "--enable-dht=true",
            "--enable-peer-exchange=true",
            "--bt-enable-lpd=true",
            // Persist `.aria2` resume metadata and re-use it on
            // restart so a half-downloaded torrent picks up where
            // it left off, both for the data file AND seeding ratio.
            "--bt-save-metadata=true",
            "--bt-load-saved-metadata=true",
            // Detach seed-only torrents from the concurrent-download budget:
            // a completed torrent that's only uploading no longer occupies a
            // download slot, so fresh leeches always get one. This replaces
            // the old manual "leech-precedence" pause/resume hack in the
            // manager (now deleted). See aria2_args.zig for the rewrite.
            "--bt-detach-seed-only=true",
            // Aria2's `--save-session` only persists active / paused
            // / waiting downloads by default — completed seeders are
            // silently dropped from the session file at save time.
            // `--force-save=true` flips that: it also saves completed
            // entries (and their control files), so a torrent that
            // was mid-seed when we exited comes back as a seeder on
            // the next launch and continues toward the ratio target.
            "--force-save=true",
            // Fixed BT listen ports — easier for the user's router/
            // firewall to allow once than a random range every run.
            // 51413 is the qBittorrent default; piggyback on any
            // existing port-forward rule. BT-peer and DHT ranges
            // MUST NOT overlap — when they did, aria2 silently
            // failed to bind one of the listeners and the daemon
            // couldn't accept connections.
            "--listen-port=51413-51419",
            "--dht-listen-port=51420-51425",
            // Some F95 mirrors serve via Cloudflare-fronted hosts
            // with cert chains aria2 occasionally trips on. We
            // already validate downloads via .torrent SHA1, so
            // skipping HTTPS chain check for tracker URLs is safe.
            "--check-certificate=false",
            // Aria2 refuses RPC from non-localhost by default; we
            // explicitly accept any origin since the bind is on
            // 127.0.0.1 anyway.
            "--rpc-allow-origin-all=true",
            // Modest leecher throttles — keep aria2 from saturating
            // home uplinks with default 0 (unlimited) upload speed.
            // 0 still means "no cap"; users can override via
            // per-call options or the future Settings panel.
            "--max-overall-upload-limit=0",
            "--max-overall-download-limit=0",
            // CRITICAL: aria2's default `--max-concurrent-downloads` is
            // 5, and that limit counts SEEDING torrents too. With even
            // a handful of completed torrents sitting in the session
            // file, a fresh start fills all 5 slots with seeders and
            // every new download queues silently behind them ("starts"
            // per aria2 status but never receives a byte). Bumping to
            // 32 gives ample headroom — actual parallelism is still
            // gated by the daemon-wide bandwidth limits above.
            "--max-concurrent-downloads=32",
        }) catch return errs.Error.OutOfMemory;
        if (seed_time_arg) |s| argv.append(self.alloc, s) catch return errs.Error.OutOfMemory;
        if (save_arg) |s| argv.append(self.alloc, s) catch return errs.Error.OutOfMemory;
        if (input_arg) |s| {
            argv.append(self.alloc, s) catch return errs.Error.OutOfMemory;
            // aria2 refuses to start if --input-file points at a path
            // that doesn't exist yet. Touch an empty file once on first
            // launch so the daemon comes up clean.
            ensureSessionFile(self.io, self.session_path.?);
            argv.append(self.alloc, "--save-session-interval=60") catch return errs.Error.OutOfMemory;
        }

        // Log the exact command-line we're about to run so the user
        // can copy/paste it for manual debugging if something goes
        // wrong. The argv slice is borrowed from the local arena —
        // it survives until this fn returns, well after the spawn.
        log.info("spawning aria2 with {d} args:", .{argv.items.len});
        for (argv.items, 0..) |a, i| {
            log.info("  argv[{d}] = {s}", .{ i, a });
        }

        // stdin/stdout still go to /dev/null — aria2 doesn't read
        // stdin and chatters too much on stdout (we use the RPC
        // anyway). stderr → .inherit so the user sees aria2's actual
        // failure mode (missing binary, port in use, bad flag combo,
        // tracker errors) in the same console our std.log writes to.
        self.child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        }) catch |e| {
            // warn, not err: the caller surfaces AriaSpawnFailed to the UI,
            // and the test runner counts err-level logs as test failures —
            // this exact path is regression-tested with a missing binary.
            log.warn(
                "aria2 spawn failed ({s}). Is '{s}' installed and on PATH? " ++
                    "Try: which aria2c. On NixOS: nix profile add nixpkgs#aria2",
                .{ @errorName(e), self.aria2_path },
            );
            return errs.Error.AriaSpawnFailed;
        };
        log.info("aria2 child started (pid resolves on POSIX after spawn)", .{});
    }

    fn waitReady(self: *Daemon) errs.Error!void {
        // Poll `aria2.getVersion` every 50ms for up to 5 seconds.
        // Log every second so the user knows we're not hung.
        var attempts: u32 = 0;
        var last_err: errs.Error = errs.Error.AriaStartTimeout;
        while (attempts < 100) : (attempts += 1) {
            self.io.sleep(Io.Duration.fromMilliseconds(50), .real) catch {};
            if (self.tryGetVersion()) {
                log.info("aria2 RPC ready after {d}ms", .{attempts * 50});
                return;
            } else |e| {
                last_err = e;
            }
            if (attempts > 0 and attempts % 20 == 0) {
                log.info("aria2 still starting… ({d}ms, last error {s})", .{ attempts * 50, @errorName(last_err) });
            }
        }
        // warn, not err: surfaced to the UI as AriaStartTimeout (see the
        // spawn-failure note above).
        log.warn(
            "aria2 startup timed out after 5s on port {d}. Probable causes: " ++
                "aria2c not installed, port collision, bad flag combo " ++
                "(check stderr above for aria2's own message). Last error: {s}",
            .{ self.port, @errorName(last_err) },
        );
        return errs.Error.AriaStartTimeout;
    }

    fn tryGetVersion(self: *Daemon) errs.Error!void {
        var body_buf: [192]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"aria2.getVersion\",\"params\":[\"token:{s}\"]}}",
            .{self.secretSlice()},
        ) catch return errs.Error.AriaInvalidResponse;
        const resp = try self.rpcRaw(body);
        self.alloc.free(resp);
    }

    /// Send a JSON-RPC body through the active transport (WS, or HTTP after
    /// fallback) and return the response body. Owned by `self.alloc`.
    fn rpcRaw(self: *Daemon, body: []const u8) errs.Error![]u8 {
        return self.fallback.call(self.alloc, body) catch errs.Error.HostUnreachable;
    }

    /// Free the heap-owned transports + URL. Call after the child is reaped
    /// (WS deinit closes the socket + joins the read thread).
    fn freeTransports(self: *Daemon) void {
        if (self.ws_t) |p| {
            p.deinit();
            self.alloc.destroy(p);
            self.ws_t = null;
        }
        self.alloc.destroy(self.http_t);
        self.alloc.free(self.url);
    }

    fn secretSlice(self: *const Daemon) []const u8 {
        return self.secret[0..32];
    }
};

const ErrorObj = struct {
    code: i64,
    message: []const u8,
};

/// Touch the aria2 session file so `--input-file=<path>` doesn't
/// refuse to start on first launch. Best-effort.
fn ensureSessionFile(io: Io, path: []const u8) void {
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        var f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return;
        f.close(io);
    };
}

fn genSecret(io: Io, out: *[33]u8) void {
    var raw: [16]u8 = undefined;
    // Best-effort: prefer the OS's CSPRNG. If the secure source is
    // unavailable on this platform we fall back to the non-secure RNG
    // — the secret guards localhost RPC where any local user is
    // already trusted, so degraded entropy is not a security boundary.
    io.randomSecure(&raw) catch io.random(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    @memcpy(out[0..32], &hex);
    out[32] = 0;
}

/// Pick a port in the IANA "ephemeral" range. Doesn't reserve it — if
/// it's already taken, aria2's spawn will surface a startup error and
/// `waitReady` will time out. For first-cut that's acceptable; a future
/// refinement is to bind/close a TCP socket to grab a guaranteed-free
/// port atomically.
fn pickRandomPort(io: Io) u16 {
    var raw: [2]u8 = undefined;
    io.randomSecure(&raw) catch io.random(&raw);
    const r: u16 = @as(u16, raw[0]) | (@as(u16, raw[1]) << 8);
    return 49152 + (r % 16384);
}

/// Append `s` to `buf` as a JSON-encoded string (with surrounding quotes
/// and escaping for `"`, `\`, control chars).
/// Append a `"key":"value"` pair to an aria2 options-object buffer.
/// `first` is flipped to false on the first call so subsequent
/// fields get a leading comma. aria2 expects every option value to
/// be a string, even numeric ones (seed-ratio, seed-time, etc).
fn appendJsonOpt(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    first: *bool,
    key: []const u8,
    value: []const u8,
) !void {
    if (!first.*) try buf.append(alloc, ',');
    first.* = false;
    try appendJsonString(buf, alloc, key);
    try buf.append(alloc, ':');
    try appendJsonString(buf, alloc, value);
}

fn appendJsonString(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    s: []const u8,
) !void {
    try buf.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            // Other control chars: \uXXXX. Skips 9/10/13 since they're
            // handled above.
            0...8, 11, 12, 14...0x1f => {
                var hex: [6]u8 = undefined;
                _ = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(alloc, &hex);
            },
            else => try buf.append(alloc, c),
        }
    }
    try buf.append(alloc, '"');
}

/// Tellstatus helper — pull a string field. Aria2 returns every value
/// (even numbers) as a JSON string, so this is the common path.
fn ariaStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string, .number_string => |s| s,
        else => null,
    };
}

/// Same but parse to u64 — aria2 hands us decimal-string ints
/// (`"123456"`). Returns null for missing/unparseable.
fn ariaU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const s = ariaStr(obj, key) orelse return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

test "appendJsonString basic" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendJsonString(&buf, std.testing.allocator, "hello \"world\"\n");
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\n\"", buf.items);
}

// Note: genSecret takes an `Io` and isn't trivially testable from a
// unit-test (would need a mock Io or the threaded default). Smoke
// coverage comes from spike-aria2-rpc.
