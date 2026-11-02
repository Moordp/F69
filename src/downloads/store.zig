//! Downloader v2 SQLite store: `dl_jobs` (one row per job) and `dl_events`
//! (per-job step log). Spec §3.3.
//!
//! The downloader thread opens its own `Store` on the same database file the
//! app's `Library` uses (WAL + busy timeout make that safe). Owned strings
//! in loaded jobs are allocated with the caller's allocator; free with
//! `freeJobs`.

const std = @import("std");
const dbu = @import("util_db");
const model = @import("model.zig");
const errs = @import("errors.zig");

const log = std.log.scoped(.dl_store);

/// Keep identical to migration 25 in src/library/library.zig (the library
/// module must not import downloads, so the DDL lives in both places).
pub const SCHEMA_SQL =
    \\CREATE TABLE IF NOT EXISTS dl_jobs (
    \\  id INTEGER PRIMARY KEY, group_id INTEGER NOT NULL, kind TEXT NOT NULL,
    \\  game_thread_id INTEGER NOT NULL DEFAULT 0, mod_id INTEGER,
    \\  title TEXT NOT NULL DEFAULT '', source_href TEXT NOT NULL, host TEXT NOT NULL DEFAULT '',
    \\  engine TEXT NOT NULL, platform TEXT, part INTEGER, version TEXT,
    \\  step TEXT NOT NULL, step_detail TEXT NOT NULL DEFAULT '', resume_step TEXT,
    \\  fail TEXT, fail_msg TEXT NOT NULL DEFAULT '', attempts INTEGER NOT NULL DEFAULT 0, next_retry_at INTEGER,
    \\  resolved_url TEXT, resolved_headers TEXT NOT NULL DEFAULT '', resolved_at INTEGER,
    \\  engine_ref TEXT, dest_dir TEXT NOT NULL, final_path TEXT,
    \\  expected_sha256 BLOB, bytes_done INTEGER NOT NULL DEFAULT 0, bytes_total INTEGER, bytes_uploaded INTEGER NOT NULL DEFAULT 0,
    \\  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, finished_at INTEGER
    \\);
    \\CREATE INDEX IF NOT EXISTS dl_jobs_game ON dl_jobs(game_thread_id);
    \\CREATE TABLE IF NOT EXISTS dl_events (
    \\  id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL, at INTEGER NOT NULL,
    \\  step TEXT NOT NULL, msg TEXT NOT NULL DEFAULT ''
    \\);
    \\CREATE INDEX IF NOT EXISTS dl_events_job ON dl_events(job_id, id);
;

const TERMINAL = "('done','failed','cancelled')";

const COLS =
    "id, group_id, kind, game_thread_id, mod_id, title, source_href, host, engine, platform, part, version, " ++
    "step, step_detail, resume_step, fail, fail_msg, attempts, next_retry_at, resolved_url, resolved_headers, " ++
    "resolved_at, engine_ref, dest_dir, final_path, expected_sha256, bytes_done, bytes_total, bytes_uploaded, " ++
    "created_at, updated_at, finished_at";

pub const Event = struct { at: i64, step: model.Step, msg: []const u8 };

/// One `download_sources` row, as `dl_classify.classify` takes it.
pub const CatalogueRow = struct { href: []const u8, text: []const u8, lead: []const u8, ctx: []const u8 };

fn i64Of(v: u64) i64 {
    return @intCast(@min(v, std.math.maxInt(i64)));
}
fn optI64(v: ?u64) ?i64 {
    return if (v) |x| i64Of(x) else null;
}
fn optTag(v: anytype) ?[]const u8 {
    return if (v) |x| @tagName(x) else null;
}
fn u64Of(v: i64) u64 {
    return @intCast(@max(v, 0));
}

pub const Store = struct {
    alloc: std.mem.Allocator,
    conn: dbu.Conn,

    /// Open (creating if needed) the database at `db_path` and ensure the
    /// download tables exist. Safe on a file the Library already migrated.
    pub fn open(alloc: std.mem.Allocator, db_path: []const u8) errs.Error!Store {
        var conn = dbu.Conn.open(db_path, alloc, .{}) catch return errs.Error.StoreFailed;
        errdefer conn.close();
        conn.exec("PRAGMA busy_timeout = 5000") catch return errs.Error.StoreFailed;
        conn.exec("PRAGMA journal_mode = WAL") catch return errs.Error.StoreFailed;
        conn.exec("PRAGMA mmap_size = 0") catch return errs.Error.StoreFailed;
        conn.execScript(alloc, SCHEMA_SQL) catch return errs.Error.StoreFailed;
        return .{ .alloc = alloc, .conn = conn };
    }

    pub fn openMemory(alloc: std.mem.Allocator) errs.Error!Store {
        return open(alloc, ":memory:");
    }

    pub fn close(self: *Store) void {
        self.conn.close();
    }

    fn fail(self: *Store) errs.Error {
        log.err("store query failed: {s}", .{self.conn.lastError()});
        return errs.Error.StoreFailed;
    }

    /// Insert `job` (its `id` is ignored) and return the new id. A
    /// `group_id` of 0 becomes the new id.
    pub fn insert(self: *Store, job: *const model.Job) errs.Error!u64 {
        const headers = std.mem.join(self.alloc, "\n", job.resolved_headers) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(headers);
        const sha: ?dbu_blob = if (job.expected_sha256) |*s| dbu.blob(s) else null;
        self.conn.inner.exec(
            "INSERT INTO dl_jobs (" ++ COLS[4..] ++ ") VALUES (" ++ "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?" ++ ")",
            .{
                i64Of(job.group_id), @tagName(job.kind),      i64Of(job.game_thread_id), optI64(job.mod_id),
                job.title,           job.source_href,         job.host,                  @tagName(job.engine),
                job.platform,        job.part,                job.version,               @tagName(job.step),
                job.step_detail,     optTag(job.resume_step), optTag(job.fail),          job.fail_msg,
                job.attempts,        job.next_retry_at,       job.resolved_url,          headers,
                job.resolved_at,     job.engine_ref,          job.dest_dir,              job.final_path,
                sha,                 i64Of(job.bytes_done),   optI64(job.bytes_total),   i64Of(job.bytes_uploaded),
                job.created_at,      job.updated_at,          job.finished_at,
            },
        ) catch return self.fail();
        const id: u64 = @intCast(self.conn.inner.lastInsertedRowId());
        if (job.group_id == 0) {
            self.conn.inner.exec("UPDATE dl_jobs SET group_id = ? WHERE id = ?", .{ i64Of(id), i64Of(id) }) catch return self.fail();
        }
        return id;
    }

    /// Write every stored column of the row with `job.id`.
    pub fn update(self: *Store, job: *const model.Job) errs.Error!void {
        const headers = std.mem.join(self.alloc, "\n", job.resolved_headers) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(headers);
        const sha: ?dbu_blob = if (job.expected_sha256) |*s| dbu.blob(s) else null;
        self.conn.inner.exec(
            \\UPDATE dl_jobs SET group_id=?, kind=?, game_thread_id=?, mod_id=?, title=?, source_href=?, host=?,
            \\  engine=?, platform=?, part=?, version=?, step=?, step_detail=?, resume_step=?, fail=?, fail_msg=?,
            \\  attempts=?, next_retry_at=?, resolved_url=?, resolved_headers=?, resolved_at=?, engine_ref=?,
            \\  dest_dir=?, final_path=?, expected_sha256=?, bytes_done=?, bytes_total=?, bytes_uploaded=?,
            \\  created_at=?, updated_at=?, finished_at=?
            \\WHERE id=?
        ,
            .{
                i64Of(job.group_id), @tagName(job.kind),      i64Of(job.game_thread_id), optI64(job.mod_id),
                job.title,           job.source_href,         job.host,                  @tagName(job.engine),
                job.platform,        job.part,                job.version,               @tagName(job.step),
                job.step_detail,     optTag(job.resume_step), optTag(job.fail),          job.fail_msg,
                job.attempts,        job.next_retry_at,       job.resolved_url,          headers,
                job.resolved_at,     job.engine_ref,          job.dest_dir,              job.final_path,
                sha,                 i64Of(job.bytes_done),   optI64(job.bytes_total),   i64Of(job.bytes_uploaded),
                job.created_at,      job.updated_at,          job.finished_at,           i64Of(job.id),
            },
        ) catch return self.fail();
    }

    /// Cheap periodic write of the byte counters only.
    pub fn updateBytes(self: *Store, id: u64, done: u64, total: ?u64, uploaded: u64) errs.Error!void {
        self.conn.inner.exec(
            "UPDATE dl_jobs SET bytes_done = ?, bytes_total = ?, bytes_uploaded = ? WHERE id = ?",
            .{ i64Of(done), optI64(total), i64Of(uploaded), i64Of(id) },
        ) catch return self.fail();
    }

    /// Delete a job and its events.
    pub fn remove(self: *Store, id: u64) errs.Error!void {
        self.conn.exec("BEGIN") catch return self.fail();
        errdefer self.conn.exec("ROLLBACK") catch {};
        self.conn.inner.exec("DELETE FROM dl_events WHERE job_id = ?", .{i64Of(id)}) catch return self.fail();
        self.conn.inner.exec("DELETE FROM dl_jobs WHERE id = ?", .{i64Of(id)}) catch return self.fail();
        self.conn.exec("COMMIT") catch return self.fail();
    }

    /// All jobs ordered by id. Free with `freeJobs`.
    pub fn loadAll(self: *Store, alloc: std.mem.Allocator) errs.Error![]model.Job {
        var rows = self.conn.inner.rows("SELECT " ++ COLS ++ " FROM dl_jobs ORDER BY id", .{}) catch return self.fail();
        defer rows.deinit();
        var out: std.ArrayList(model.Job) = .empty;
        errdefer {
            for (out.items) |*j| freeJob(alloc, j);
            out.deinit(alloc);
        }
        while (rows.next()) |r| {
            var j = try readJob(alloc, r);
            errdefer freeJob(alloc, &j);
            out.append(alloc, j) catch return errs.Error.OutOfMemory;
        }
        if (rows.err) |_| return self.fail();
        return out.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
    }

    pub fn freeJobs(alloc: std.mem.Allocator, jobs: []model.Job) void {
        for (jobs) |*j| freeJob(alloc, j);
        alloc.free(jobs);
    }

    pub fn addEvent(self: *Store, job_id: u64, at: i64, step: model.Step, msg: []const u8) errs.Error!void {
        self.conn.inner.exec(
            "INSERT INTO dl_events (job_id, at, step, msg) VALUES (?, ?, ?, ?)",
            .{ i64Of(job_id), at, @tagName(step), msg },
        ) catch return self.fail();
    }

    /// A job's events oldest first. Free with `freeEvents`.
    pub fn listEvents(self: *Store, alloc: std.mem.Allocator, job_id: u64) errs.Error![]Event {
        var rows = self.conn.inner.rows(
            "SELECT at, step, msg FROM dl_events WHERE job_id = ? ORDER BY id",
            .{i64Of(job_id)},
        ) catch return self.fail();
        defer rows.deinit();
        var out: std.ArrayList(Event) = .empty;
        errdefer {
            for (out.items) |e| alloc.free(e.msg);
            out.deinit(alloc);
        }
        while (rows.next()) |r| {
            const step = std.meta.stringToEnum(model.Step, r.text(1)) orelse continue;
            const msg = alloc.dupe(u8, r.text(2)) catch return errs.Error.OutOfMemory;
            errdefer alloc.free(msg);
            out.append(alloc, .{ .at = r.int(0), .step = step, .msg = msg }) catch return errs.Error.OutOfMemory;
        }
        if (rows.err) |_| return self.fail();
        return out.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
    }

    pub fn freeEvents(alloc: std.mem.Allocator, events: []Event) void {
        for (events) |e| alloc.free(e.msg);
        alloc.free(events);
    }

    /// A game's catalogued download links (`download_sources`, written by
    /// the library's scrape) in page order. The table lives in the library
    /// schema, so on a store opened without it this fails with
    /// `StoreFailed`. Free with `freeCatalogue`.
    pub fn listCatalogue(self: *Store, alloc: std.mem.Allocator, game_thread_id: u64) errs.Error![]CatalogueRow {
        var rows = self.conn.inner.rows(
            "SELECT href, text, lead, ctx FROM download_sources WHERE game_thread_id = ? ORDER BY ord",
            .{i64Of(game_thread_id)},
        ) catch return self.fail();
        defer rows.deinit();
        var out: std.ArrayList(CatalogueRow) = .empty;
        errdefer {
            for (out.items) |row| freeCatalogueRow(alloc, row);
            out.deinit(alloc);
        }
        while (rows.next()) |r| {
            var row: CatalogueRow = .{ .href = "", .text = "", .lead = "", .ctx = "" };
            errdefer freeCatalogueRow(alloc, row);
            row.href = alloc.dupe(u8, r.text(0)) catch return errs.Error.OutOfMemory;
            row.text = alloc.dupe(u8, r.text(1)) catch return errs.Error.OutOfMemory;
            row.lead = alloc.dupe(u8, r.text(2)) catch return errs.Error.OutOfMemory;
            row.ctx = alloc.dupe(u8, r.text(3)) catch return errs.Error.OutOfMemory;
            out.append(alloc, row) catch return errs.Error.OutOfMemory;
        }
        if (rows.err) |_| return self.fail();
        return out.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
    }

    pub fn freeCatalogue(alloc: std.mem.Allocator, rows: []CatalogueRow) void {
        for (rows) |r| freeCatalogueRow(alloc, r);
        alloc.free(rows);
    }

    fn freeCatalogueRow(alloc: std.mem.Allocator, r: CatalogueRow) void {
        // Empty fields are zero-length (no allocation); free skips them.
        for ([_][]const u8{ r.href, r.text, r.lead, r.ctx }) |s| alloc.free(s);
    }

    /// Delete the oldest terminal (done/failed/cancelled) jobs, and their
    /// events, beyond the newest `keep`. Non-terminal jobs are never touched.
    /// Returns how many jobs were deleted.
    pub fn trimHistory(self: *Store, keep: u32) errs.Error!u32 {
        const keep_ids = "SELECT id FROM dl_jobs WHERE step IN " ++ TERMINAL ++ " ORDER BY id DESC LIMIT ?";
        self.conn.exec("BEGIN") catch return self.fail();
        errdefer self.conn.exec("ROLLBACK") catch {};
        self.conn.inner.exec(
            "DELETE FROM dl_events WHERE job_id IN (SELECT id FROM dl_jobs WHERE step IN " ++ TERMINAL ++
                " AND id NOT IN (" ++ keep_ids ++ "))",
            .{@as(i64, keep)},
        ) catch return self.fail();
        self.conn.inner.exec(
            "DELETE FROM dl_jobs WHERE step IN " ++ TERMINAL ++ " AND id NOT IN (" ++ keep_ids ++ ")",
            .{@as(i64, keep)},
        ) catch return self.fail();
        const n: u32 = @intCast(self.conn.inner.changes());
        self.conn.exec("COMMIT") catch return self.fail();
        return n;
    }

    const LegacyEntry = struct {
        id: u64 = 0,
        gid: []const u8 = "",
        url: []const u8,
        status: []const u8,
        game_id: u64 = 0,
        kind: []const u8 = "game",
        mod_id: ?u64 = null,
        version: ?[]const u8 = null,
    };
    const LegacyFile = struct { version: u32 = 1, next_id: u64 = 0, jobs: []const LegacyEntry = &.{} };

    /// One-time import of the old `manager_jobs.json` (spec §3.3). Returns
    /// the number of jobs imported and renames the file to `<path>.imported`.
    /// A missing file imports nothing (returns 0). aria2's own session file
    /// is untouched, so `engine_ref` (the gid) stays valid.
    pub fn importLegacyJson(self: *Store, alloc: std.mem.Allocator, io: std.Io, path: []const u8) errs.Error!u32 {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 * 1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => return 0,
            error.OutOfMemory => return errs.Error.OutOfMemory,
            else => {
                log.warn("legacy jobs read failed: {s}", .{@errorName(e)});
                return errs.Error.StoreFailed;
            },
        };
        defer alloc.free(bytes);
        var parsed = std.json.parseFromSlice(LegacyFile, alloc, bytes, .{ .ignore_unknown_fields = true }) catch |e| {
            log.warn("legacy jobs parse failed: {s}", .{@errorName(e)});
            return errs.Error.StoreFailed;
        };
        defer parsed.deinit();

        const now_s: i64 = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
        self.conn.exec("BEGIN") catch return self.fail();
        errdefer self.conn.exec("ROLLBACK") catch {};
        var count: u32 = 0;
        for (parsed.value.jobs) |e| {
            const step: model.Step = if (std.mem.eql(u8, e.status, "done"))
                .done
            else if (std.mem.eql(u8, e.status, "seeding"))
                .seeding
            else if (std.mem.eql(u8, e.status, "failed"))
                .failed
            else if (std.mem.eql(u8, e.status, "cancelled"))
                .cancelled
            else
                .downloading;
            const torrent = std.mem.startsWith(u8, e.url, "rpdl:") or step == .seeding;
            const job: model.Job = .{
                .id = 0,
                .group_id = 0,
                .kind = std.meta.stringToEnum(model.Kind, e.kind) orelse .game,
                .game_thread_id = e.game_id,
                .mod_id = e.mod_id,
                .source_href = e.url,
                .engine = if (torrent) .aria2_torrent else .aria2_http,
                .version = e.version,
                .step = step,
                .fail = if (step == .failed) .network else null,
                .engine_ref = if (e.gid.len > 0) e.gid else null,
                .dest_dir = "",
                .created_at = now_s,
                .updated_at = now_s,
            };
            _ = try self.insert(&job);
            count += 1;
        }
        self.conn.exec("COMMIT") catch return self.fail();

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dest = std.fmt.bufPrint(&buf, "{s}.imported", .{path}) catch return errs.Error.StoreFailed;
        std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), dest, io) catch |e| {
            log.warn("legacy jobs rename failed: {s}", .{@errorName(e)});
            return errs.Error.StoreFailed;
        };
        return count;
    }
};

const dbu_blob = @TypeOf(dbu.blob(""));

fn dupe(alloc: std.mem.Allocator, s: []const u8) errs.Error![]u8 {
    return alloc.dupe(u8, s) catch errs.Error.OutOfMemory;
}
fn dupeOpt(alloc: std.mem.Allocator, s: ?[]const u8) errs.Error!?[]u8 {
    return if (s) |v| try dupe(alloc, v) else null;
}
fn optU64(v: ?i64) ?u64 {
    return if (v) |x| u64Of(x) else null;
}

/// Build a `Job` from a `COLS`-ordered row; every string is copied.
fn readJob(alloc: std.mem.Allocator, r: anytype) errs.Error!model.Job {
    var j: model.Job = .{
        .id = u64Of(r.int(0)),
        .group_id = u64Of(r.int(1)),
        .kind = std.meta.stringToEnum(model.Kind, r.text(2)) orelse .game,
        .game_thread_id = u64Of(r.int(3)),
        .mod_id = optU64(r.nullableInt(4)),
        .source_href = "",
        .engine = std.meta.stringToEnum(model.EngineKind, r.text(8)) orelse .aria2_http,
        .part = if (r.nullableInt(10)) |p| @intCast(std.math.clamp(p, 0, 255)) else null,
        .step = std.meta.stringToEnum(model.Step, r.text(12)) orelse .failed,
        .resume_step = if (r.nullableText(14)) |t| std.meta.stringToEnum(model.Step, t) else null,
        .fail = if (r.nullableText(15)) |t| std.meta.stringToEnum(model.FailReason, t) else null,
        .attempts = @intCast(std.math.clamp(r.int(17), 0, 255)),
        .next_retry_at = r.nullableInt(18),
        .resolved_headers = &.{},
        .resolved_at = r.nullableInt(21),
        .dest_dir = "",
        .bytes_done = u64Of(r.int(26)),
        .bytes_total = optU64(r.nullableInt(27)),
        .bytes_uploaded = u64Of(r.int(28)),
        .created_at = r.int(29),
        .updated_at = r.int(30),
        .finished_at = r.nullableInt(31),
    };
    if (r.nullableBlob(25)) |b| {
        if (b.len == 32) j.expected_sha256 = b[0..32].*;
    }
    // String fields start as static "" / null / &.{} so a failure part-way
    // leaves only what has been allocated; `freeJob` skips empty slices.
    errdefer freeJob(alloc, &j);
    j.source_href = try dupe(alloc, r.text(6));
    j.title = try dupe(alloc, r.text(5));
    j.host = try dupe(alloc, r.text(7));
    j.platform = try dupeOpt(alloc, r.nullableText(9));
    j.version = try dupeOpt(alloc, r.nullableText(11));
    j.step_detail = try dupe(alloc, r.text(13));
    j.fail_msg = try dupe(alloc, r.text(16));
    j.resolved_url = try dupeOpt(alloc, r.nullableText(19));
    j.engine_ref = try dupeOpt(alloc, r.nullableText(22));
    j.dest_dir = try dupe(alloc, r.text(23));
    j.final_path = try dupeOpt(alloc, r.nullableText(24));

    const hs = r.text(20);
    if (hs.len > 0) {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |h| alloc.free(h);
            list.deinit(alloc);
        }
        var it = std.mem.splitScalar(u8, hs, '\n');
        while (it.next()) |h| {
            const d = try dupe(alloc, h);
            errdefer alloc.free(d);
            list.append(alloc, d) catch return errs.Error.OutOfMemory;
        }
        j.resolved_headers = list.toOwnedSlice(alloc) catch return errs.Error.OutOfMemory;
    }
    return j;
}

fn freeJob(alloc: std.mem.Allocator, j: *model.Job) void {
    freeStr(alloc, j.source_href);
    freeStr(alloc, j.title);
    freeStr(alloc, j.host);
    if (j.platform) |s| freeStr(alloc, s);
    if (j.version) |s| freeStr(alloc, s);
    freeStr(alloc, j.step_detail);
    freeStr(alloc, j.fail_msg);
    if (j.resolved_url) |s| freeStr(alloc, s);
    if (j.engine_ref) |s| freeStr(alloc, s);
    freeStr(alloc, j.dest_dir);
    if (j.final_path) |s| freeStr(alloc, s);
    if (j.resolved_headers.len > 0) {
        for (j.resolved_headers) |h| alloc.free(h);
        alloc.free(j.resolved_headers);
    }
}

fn freeStr(alloc: std.mem.Allocator, s: []const u8) void {
    if (s.len > 0) alloc.free(s);
}

const testing = std.testing;

fn fullJob() model.Job {
    return .{
        .id = 0,
        .group_id = 0,
        .kind = .mod,
        .game_thread_id = 4242,
        .mod_id = 7,
        .title = "Game · Part 2",
        .source_href = "https://f95zone.to/masked/abc",
        .host = "mega",
        .engine = .megacmd,
        .platform = "Linux",
        .part = 2,
        .version = "v1.2",
        .step = .failed,
        .step_detail = "detail",
        .resume_step = .downloading,
        .fail = .quota_exceeded,
        .fail_msg = "wait 30 min",
        .attempts = 2,
        .next_retry_at = 1000,
        .resolved_url = "https://x/y",
        .resolved_headers = &.{ "Cookie: a=b", "Referer: https://z" },
        .resolved_at = 900,
        .engine_ref = "gid123",
        .dest_dir = "/dl/megacmd/1",
        .final_path = "/dl/megacmd/1/a.zip",
        .expected_sha256 = @as([32]u8, @splat(0xAB)),
        .bytes_done = 10,
        .bytes_total = 100,
        .bytes_uploaded = 5,
        .created_at = 111,
        .updated_at = 222,
        .finished_at = 333,
    };
}

test "store: insert/loadAll round-trip keeps every column" {
    var st = try Store.openMemory(testing.allocator);
    defer st.close();
    const j = fullJob();
    const id = try st.insert(&j);
    try testing.expectEqual(@as(u64, 1), id);
    const jobs = try st.loadAll(testing.allocator);
    defer Store.freeJobs(testing.allocator, jobs);
    try testing.expectEqual(@as(usize, 1), jobs.len);
    const g = jobs[0];
    try testing.expectEqual(id, g.id);
    try testing.expectEqual(id, g.group_id);
    try testing.expectEqual(j.kind, g.kind);
    try testing.expectEqual(@as(u64, 4242), g.game_thread_id);
    try testing.expectEqual(@as(?u64, 7), g.mod_id);
    try testing.expectEqualStrings(j.title, g.title);
    try testing.expectEqualStrings(j.source_href, g.source_href);
    try testing.expectEqualStrings("mega", g.host);
    try testing.expectEqual(j.engine, g.engine);
    try testing.expectEqualStrings("Linux", g.platform.?);
    try testing.expectEqual(@as(?u8, 2), g.part);
    try testing.expectEqualStrings("v1.2", g.version.?);
    try testing.expectEqual(model.Step.failed, g.step);
    try testing.expectEqualStrings("detail", g.step_detail);
    try testing.expectEqual(@as(?model.Step, .downloading), g.resume_step);
    try testing.expectEqual(@as(?model.FailReason, .quota_exceeded), g.fail);
    try testing.expectEqualStrings("wait 30 min", g.fail_msg);
    try testing.expectEqual(@as(u8, 2), g.attempts);
    try testing.expectEqual(@as(?i64, 1000), g.next_retry_at);
    try testing.expectEqualStrings("https://x/y", g.resolved_url.?);
    try testing.expectEqual(@as(usize, 2), g.resolved_headers.len);
    try testing.expectEqualStrings("Cookie: a=b", g.resolved_headers[0]);
    try testing.expectEqualStrings("Referer: https://z", g.resolved_headers[1]);
    try testing.expectEqual(@as(?i64, 900), g.resolved_at);
    try testing.expectEqualStrings("gid123", g.engine_ref.?);
    try testing.expectEqualStrings("/dl/megacmd/1", g.dest_dir);
    try testing.expectEqualStrings("/dl/megacmd/1/a.zip", g.final_path.?);
    try testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0xAB))), &g.expected_sha256.?);
    try testing.expectEqual(@as(u64, 10), g.bytes_done);
    try testing.expectEqual(@as(?u64, 100), g.bytes_total);
    try testing.expectEqual(@as(u64, 5), g.bytes_uploaded);
    try testing.expectEqual(@as(i64, 111), g.created_at);
    try testing.expectEqual(@as(i64, 222), g.updated_at);
    try testing.expectEqual(@as(?i64, 333), g.finished_at);
}

test "store: nullable columns round-trip as null and explicit group_id is kept" {
    var st = try Store.openMemory(testing.allocator);
    defer st.close();
    const j: model.Job = .{ .id = 0, .group_id = 9, .kind = .game, .game_thread_id = 1, .source_href = "h", .engine = .aria2_http, .step = .queued, .dest_dir = "" };
    _ = try st.insert(&j);
    const jobs = try st.loadAll(testing.allocator);
    defer Store.freeJobs(testing.allocator, jobs);
    const g = jobs[0];
    try testing.expectEqual(@as(u64, 9), g.group_id);
    try testing.expect(g.mod_id == null and g.platform == null and g.part == null and g.version == null);
    try testing.expect(g.resume_step == null and g.fail == null and g.next_retry_at == null);
    try testing.expect(g.resolved_url == null and g.resolved_at == null and g.engine_ref == null);
    try testing.expect(g.final_path == null and g.expected_sha256 == null and g.bytes_total == null and g.finished_at == null);
    try testing.expectEqual(@as(usize, 0), g.resolved_headers.len);
}

test "store: update + updateBytes" {
    var st = try Store.openMemory(testing.allocator);
    defer st.close();
    var j = fullJob();
    const id = try st.insert(&j);
    j.id = id;
    j.group_id = id;
    j.step = .done;
    j.fail = null;
    j.title = "New";
    j.resolved_headers = &.{};
    try st.update(&j);
    try st.updateBytes(id, 50, null, 7);
    const jobs = try st.loadAll(testing.allocator);
    defer Store.freeJobs(testing.allocator, jobs);
    try testing.expectEqual(model.Step.done, jobs[0].step);
    try testing.expect(jobs[0].fail == null);
    try testing.expectEqualStrings("New", jobs[0].title);
    try testing.expectEqual(@as(usize, 0), jobs[0].resolved_headers.len);
    try testing.expectEqual(@as(u64, 50), jobs[0].bytes_done);
    try testing.expect(jobs[0].bytes_total == null);
    try testing.expectEqual(@as(u64, 7), jobs[0].bytes_uploaded);
}

test "store: events list in order, remove deletes events" {
    var st = try Store.openMemory(testing.allocator);
    defer st.close();
    const j = fullJob();
    const a = try st.insert(&j);
    const b = try st.insert(&j);
    try st.addEvent(a, 1, .queued, "one");
    try st.addEvent(a, 2, .downloading, "two");
    try st.addEvent(b, 3, .queued, "other");
    {
        const ev = try st.listEvents(testing.allocator, a);
        defer Store.freeEvents(testing.allocator, ev);
        try testing.expectEqual(@as(usize, 2), ev.len);
        try testing.expectEqualStrings("one", ev[0].msg);
        try testing.expectEqual(model.Step.downloading, ev[1].step);
        try testing.expectEqual(@as(i64, 2), ev[1].at);
    }
    try st.remove(a);
    const ev = try st.listEvents(testing.allocator, a);
    defer Store.freeEvents(testing.allocator, ev);
    try testing.expectEqual(@as(usize, 0), ev.len);
    const evb = try st.listEvents(testing.allocator, b);
    defer Store.freeEvents(testing.allocator, evb);
    try testing.expectEqual(@as(usize, 1), evb.len);
    const jobs = try st.loadAll(testing.allocator);
    defer Store.freeJobs(testing.allocator, jobs);
    try testing.expectEqual(@as(usize, 1), jobs.len);
}

test "store: trimHistory keeps newest 2 terminal rows and all non-terminal" {
    var st = try Store.openMemory(testing.allocator);
    defer st.close();
    var j = fullJob();
    const steps = [_]model.Step{ .done, .failed, .downloading, .cancelled, .done, .queued };
    for (steps) |s| {
        j.step = s;
        const id = try st.insert(&j);
        try st.addEvent(id, 1, s, "e");
    }
    const removed = try st.trimHistory(2);
    try testing.expectEqual(@as(u32, 2), removed);
    const jobs = try st.loadAll(testing.allocator);
    defer Store.freeJobs(testing.allocator, jobs);
    var ids: [4]u64 = undefined;
    try testing.expectEqual(@as(usize, 4), jobs.len);
    for (jobs, 0..) |g, i| ids[i] = g.id;
    try testing.expectEqualSlices(u64, &.{ 3, 4, 5, 6 }, &ids);
    const ev = try st.listEvents(testing.allocator, 1);
    defer Store.freeEvents(testing.allocator, ev);
    try testing.expectEqual(@as(usize, 0), ev.len);
}

test "store: file-backed open is idempotent and persists rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/dl.db", .{dir});
    defer testing.allocator.free(path);
    {
        var st = try Store.open(testing.allocator, path);
        defer st.close();
        const j = fullJob();
        _ = try st.insert(&j);
    }
    var st = try Store.open(testing.allocator, path);
    defer st.close();
    const jobs = try st.loadAll(testing.allocator);
    defer Store.freeJobs(testing.allocator, jobs);
    try testing.expectEqual(@as(usize, 1), jobs.len);
}

test "store: importLegacyJson maps statuses and renames the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/manager_jobs.json", .{dir});
    defer testing.allocator.free(path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "manager_jobs.json", .data =
        \\{"version":1,"next_id":9,"jobs":[
        \\{"id":1,"gid":"g1","url":"https://a/b.zip","status":"done","game_id":11,"kind":"game","version":"v1"},
        \\{"id":2,"gid":"g2","url":"https://a/c.zip","status":"seeding","game_id":12},
        \\{"id":3,"gid":"g3","url":"rpdl:555","status":"paused","game_id":13,"kind":"mod","mod_id":4},
        \\{"id":4,"gid":"g4","url":"https://a/d.zip","status":"failed","game_id":14}
        \\]}
    });
    var st = try Store.openMemory(testing.allocator);
    defer st.close();
    const n = try st.importLegacyJson(testing.allocator, testing.io, path);
    try testing.expectEqual(@as(u32, 4), n);
    const jobs = try st.loadAll(testing.allocator);
    defer Store.freeJobs(testing.allocator, jobs);
    try testing.expectEqual(@as(usize, 4), jobs.len);
    try testing.expectEqual(model.Step.done, jobs[0].step);
    try testing.expectEqual(model.Step.seeding, jobs[1].step);
    try testing.expectEqual(model.Step.downloading, jobs[2].step);
    try testing.expectEqual(model.Step.failed, jobs[3].step);
    try testing.expectEqual(@as(?model.FailReason, .network), jobs[3].fail);
    try testing.expectEqual(model.EngineKind.aria2_http, jobs[0].engine);
    try testing.expectEqual(model.EngineKind.aria2_torrent, jobs[1].engine);
    try testing.expectEqual(model.EngineKind.aria2_torrent, jobs[2].engine);
    try testing.expectEqualStrings("g3", jobs[2].engine_ref.?);
    try testing.expectEqualStrings("rpdl:555", jobs[2].source_href);
    try testing.expectEqual(model.Kind.mod, jobs[2].kind);
    try testing.expectEqual(@as(?u64, 4), jobs[2].mod_id);
    try testing.expectEqual(@as(u64, 13), jobs[2].game_thread_id);
    try testing.expectEqualStrings("v1", jobs[0].version.?);
    try testing.expectEqualStrings("", jobs[0].dest_dir);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "manager_jobs.json", .{}));
    try tmp.dir.access(testing.io, "manager_jobs.json.imported", .{});
    // Missing file is not an error.
    try testing.expectEqual(@as(u32, 0), try st.importLegacyJson(testing.allocator, testing.io, path));
}
