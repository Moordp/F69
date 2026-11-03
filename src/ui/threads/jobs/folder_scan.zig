//! "Scan a folder of installed games" as a compute job. On click the UI
//! thread reads the library's game list once (for the link prefill) and
//! copies the root path plus each known game's thread id, name and
//! latest version into a `FolderScanJob`. This file does every disk step
//! on the compute thread: it lists the root, then for each top-level
//! folder runs the engine fingerprint walk and the compat scan, and
//! pushes one `ScanRow` per game folder onto the session's mailbox. The
//! import screen drains that mailbox each frame, so rows appear while the
//! scan runs.

const std = @import("std");
const Io = std.Io;
const importers = @import("importers");
const library = @import("library");
const state_mod = @import("../../state.zig");
const Mailbox = @import("../mailbox.zig").Mailbox;
const activity_mod = @import("../activity.zig");
const work_thread = @import("../work_thread.zig");

const Activity = activity_mod.Activity;
const ResultKind = activity_mod.ResultKind;
const folder_scan = importers.folder_scan;
const name_match = importers.name_match;

const log = std.log.scoped(.importers_folder);

pub const Engine = @FieldType(importers.ImportedGame, "engine");

/// Tests only: sleep this long after each folder, so a test can click
/// Stop part-way through a scan of a few tiny folders.
pub var test_step_delay_ms: u32 = 0;

/// One game folder the scan found: the bundle entry and the row state the
/// import screen shows for it. The strings are owned by the allocator of
/// the `Rows` it was pushed to; `deinit` frees them.
pub const ScanRow = struct {
    /// Parsed display name (folder name without the version token).
    name: []u8,
    version: ?[]u8,
    engine: Engine,
    /// `<folder>/<launcher rel path>`, relative to the scan root.
    install_executable_rel: []u8,
    /// Name, version and link prefill plus the compat issues.
    row: state_mod.FolderImportRowState,

    pub fn deinit(self: ScanRow, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        if (self.version) |v| alloc.free(v);
        alloc.free(self.install_executable_rel);
    }
};

/// The mailbox the job pushes rows onto, shared by the scan session (the
/// reader) and the job (the writer). Each side holds one reference; the
/// last `release` frees it and any rows still queued. The session closes
/// it when it is torn down, so a job still running sees `error.Closed` on
/// its next push and stops.
pub const Rows = struct {
    alloc: std.mem.Allocator,
    mb: Mailbox(ScanRow),
    refs: std.atomic.Value(u32) = .init(1),

    /// One reference, held by the caller.
    pub fn create(alloc: std.mem.Allocator, io: Io) !*Rows {
        const self = try alloc.create(Rows);
        self.* = .{ .alloc = alloc, .mb = Mailbox(ScanRow).init(alloc, io) };
        return self;
    }

    pub fn retain(self: *Rows) *Rows {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *Rows) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        while (self.mb.tryPop()) |r| r.deinit(self.alloc);
        const alloc = self.alloc;
        self.mb.deinit();
        alloc.destroy(self);
    }
};

/// Every slice is owned by `arena`. `rows` holds one reference, dropped
/// by `deinit`. The worker frees the job with `deinit` when it ends (or
/// when it never starts).
pub const FolderScanJob = struct {
    arena: *std.heap.ArenaAllocator,
    root: []u8,
    /// Thread ids of the library's games, for the link prefill.
    known_tids: []u64,
    /// Parallel to `known_tids`: the game's name.
    known_names: [][]u8,
    /// Parallel to `known_tids`: the game's latest version, if any.
    known_versions: []?[]u8,
    rows: *Rows,

    /// Copies `root` and the id, name and latest version of each game
    /// into a fresh arena on `alloc`, and takes a new reference on `rows`.
    pub fn create(alloc: std.mem.Allocator, root: []const u8, games: []const library.Game, rows: *Rows) !FolderScanJob {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer {
            arena.deinit();
            alloc.destroy(arena);
        }
        const a = arena.allocator();
        const tids = try a.alloc(u64, games.len);
        const names = try a.alloc([]u8, games.len);
        const versions = try a.alloc(?[]u8, games.len);
        for (games, 0..) |g, i| {
            tids[i] = g.f95_thread_id;
            names[i] = try a.dupe(u8, g.name);
            versions[i] = if (g.latest_version) |v| try a.dupe(u8, v) else null;
        }
        return .{
            .arena = arena,
            .root = try a.dupe(u8, root),
            .known_tids = tids,
            .known_names = names,
            .known_versions = versions,
            .rows = rows.retain(),
        };
    }

    pub fn deinit(self: FolderScanJob) void {
        self.rows.release();
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

/// What `run` hands back when it does not return an error. A cancel (or
/// a closed mailbox) is returned as a "Stopped." result, not as
/// `error.Cancelled`: only a returned result carries the `.folder_scan`
/// outcome that tells the session the scan has ended.
pub const Ran = struct {
    kind: ResultKind,
    msg: []const u8,
};

/// Names of the top-level entries that may be game folders, in listing
/// order. Slices are owned by `alloc`.
fn listCandidates(io: Io, alloc: std.mem.Allocator, root: []const u8) ![][]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var out: std.ArrayList([]const u8) = .empty;
    while (true) {
        const entry = it.next(io) catch |e| {
            // FUSE NTFS can fail on one entry; keep what was listed.
            log.warn("folder-scan list error: {s} — stopping the listing here", .{@errorName(e)});
            break;
        } orelse break;
        if (entry.kind != .directory and entry.kind != .unknown) {
            log.info("skip '{s}': not a dir (kind={s})", .{ entry.name, @tagName(entry.kind) });
            continue;
        }
        if (folder_scan.looksLikeCompanionFile(entry.name)) {
            log.info("skip '{s}': companion-file pattern", .{entry.name});
            continue;
        }
        try out.append(alloc, try alloc.dupe(u8, entry.name));
    }
    return out.toOwnedSlice(alloc);
}

/// At most `max` bytes of `s`, cut on a UTF-8 boundary.
fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// Runs the scan for `job` on the compute thread. `buf` holds the result
/// text.
pub fn run(deps: work_thread.Deps, job: FolderScanJob, a: *Activity, buf: []u8) anyerror!Ran {
    const io = deps.io;
    // The cancel flag is set, so the book records `cancelled`.
    const stopped: Ran = .{ .kind = .warn, .msg = "Stopped." };
    const scratch = job.arena.allocator();

    a.setPhase(io, "Listing folders");
    const names = listCandidates(io, scratch, job.root) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            const msg = std.fmt.bufPrint(buf, "Couldn't open the folder: {s}", .{@errorName(e)}) catch "Couldn't open the folder.";
            return .{ .kind = .err, .msg = msg };
        },
    };

    const candidates = try scratch.alloc(name_match.Candidate, job.known_tids.len);
    for (candidates, 0..) |*c, i| c.* = .{ .thread_id = job.known_tids[i], .name = job.known_names[i] };

    const n = names.len;
    a.report(0, n);
    var found: usize = 0;
    for (names, 0..) |name, idx| {
        if (a.cancelled()) return stopped;
        var pbuf: [96]u8 = undefined;
        const phase = std.fmt.bufPrint(&pbuf, "Scanning folder {d} / {d} \u{00B7} {s}", .{ idx + 1, n, utf8Prefix(name, 48) }) catch "Scanning folders";
        a.setPhase(io, phase);

        if (try analyse(deps, job, candidates, name)) |row| {
            job.rows.mb.push(row) catch |e| {
                row.deinit(job.rows.alloc);
                switch (e) {
                    // The session is gone (Clear or a new scan).
                    error.Closed => return stopped,
                    error.OutOfMemory => return e,
                }
            };
            found += 1;
        }
        a.report(idx + 1, n);
        if (test_step_delay_ms > 0) Io.sleep(io, Io.Duration.fromMilliseconds(test_step_delay_ms), .awake) catch {};
    }

    const msg = std.fmt.bufPrint(buf, "Scanned {d} folder(s), {d} game(s) found.", .{ n, found }) catch "Scan finished.";
    return .{ .kind = if (found == 0) .warn else .ok, .msg = msg };
}

/// The row for top-level folder `entry_name`, or null when it has no
/// engine fingerprint. Strings are owned by `job.rows.alloc`.
fn analyse(deps: work_thread.Deps, job: FolderScanJob, candidates: []const name_match.Candidate, entry_name: []const u8) !?ScanRow {
    const io = deps.io;
    const alloc = job.rows.alloc;

    var top_path_buf: [1024]u8 = undefined;
    const top_path = std.fmt.bufPrint(&top_path_buf, "{s}/{s}", .{ job.root, entry_name }) catch {
        log.info("skip '{s}': path too long", .{entry_name});
        return null;
    };
    var rel_buf: [1024]u8 = undefined;
    const hit = folder_scan.detectEngineDeep(io, top_path, &rel_buf) orelse {
        log.info("skip '{s}': no engine fingerprint", .{entry_name});
        return null;
    };

    var parse_buf: [1024]u8 = undefined;
    const parsed = folder_scan.parseFolderName(&parse_buf, entry_name);
    const parsed_name: []const u8 = if (parsed) |p| p.name else entry_name;
    const parsed_version: ?[]const u8 = if (parsed) |p| p.version else null;

    const name = try alloc.dupe(u8, parsed_name);
    errdefer alloc.free(name);
    const version: ?[]u8 = if (parsed_version) |v| try alloc.dupe(u8, v) else null;
    errdefer if (version) |v| alloc.free(v);
    const exe_rel = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ entry_name, hit.fingerprint_rel });
    errdefer alloc.free(exe_rel);

    var row: state_mod.FolderImportRowState = .{};
    copyToBuf(&row.name_buf, name);
    if (version) |v| copyToBuf(&row.version_buf, v);

    if (name_match.bestMatch(name, candidates)) |m| {
        row.link_state = .linked_existing;
        row.link_thread_id = m.thread_id;
        copyToBuf(&row.link_buf, m.name);
        if (version == null) {
            for (job.known_tids, 0..) |tid, i| {
                if (tid != m.thread_id) continue;
                if (job.known_versions[i]) |lv| copyToBuf(&row.version_buf, lv);
                break;
            }
        }
    } else {
        // No match crossed the threshold: seed the Link cell with the
        // parsed name so the typeahead has something to filter on.
        copyToBuf(&row.link_buf, name);
    }

    if (deps.compat_svc) |svc| populateIssues(svc, &row, top_path);

    return .{
        .name = name,
        .version = version,
        .engine = hit.engine,
        .install_executable_rel = exe_rel,
        .row = row,
    };
}

/// Copies up to `FOLDER_IMPORT_MAX_ISSUES` matched recipe ids and titles
/// from the compat scan of `install_root` into `row`.
fn populateIssues(svc: anytype, row: *state_mod.FolderImportRowState, install_root: []const u8) void {
    row.issue_count = 0;
    const issues = svc.scan(install_root, &.{}) catch return;
    defer svc.freeIssues(issues);
    var n: u8 = 0;
    for (issues) |iss| {
        if (n >= state_mod.FOLDER_IMPORT_MAX_ISSUES) break;
        var slot = &row.issues[n];
        const id_n = @min(iss.recipe_id.len, slot.id_buf.len);
        @memcpy(slot.id_buf[0..id_n], iss.recipe_id[0..id_n]);
        slot.id_len = @intCast(id_n);
        const t_n = @min(iss.title.len, slot.title_buf.len);
        @memcpy(slot.title_buf[0..t_n], iss.title[0..t_n]);
        slot.title_len = @intCast(t_n);
        n += 1;
    }
    row.issue_count = n;
}

fn copyToBuf(dst: []u8, src: []const u8) void {
    @memset(dst, 0);
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
}

test "utf8Prefix: never cuts inside a multi-byte sequence" {
    try std.testing.expectEqualStrings("abc", utf8Prefix("abc", 10));
    // "a" + U+00E9 (2 bytes): a 2-byte cap must stop after "a".
    try std.testing.expectEqualStrings("a", utf8Prefix("a\u{00E9}x", 2));
}

test "Rows: the last release frees queued rows" {
    const alloc = std.testing.allocator;
    const rows = try Rows.create(alloc, std.testing.io);
    _ = rows.retain();
    try rows.mb.push(.{
        .name = try alloc.dupe(u8, "G"),
        .version = try alloc.dupe(u8, "1.0"),
        .engine = .unknown,
        .install_executable_rel = try alloc.dupe(u8, "G/x"),
        .row = .{},
    });
    rows.release();
    rows.release();
}

test "FolderScanJob: create copies inputs; deinit frees them and drops its reference" {
    const alloc = std.testing.allocator;
    const rows = try Rows.create(alloc, std.testing.io);
    defer rows.release();
    var raw = "lib/games".*;
    const job = try FolderScanJob.create(alloc, &raw, &.{}, rows);
    raw[0] = 'X';
    try std.testing.expectEqualStrings("lib/games", job.root);
    try std.testing.expectEqual(@as(u32, 2), rows.refs.load(.acquire));
    job.deinit();
    try std.testing.expectEqual(@as(u32, 1), rows.refs.load(.acquire));
}
