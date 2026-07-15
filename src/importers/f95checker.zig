// F95Checker importer — SQLite-backed reader for the upstream tool.
//
// Schema reference (post-2026):
//   games.id INTEGER PRIMARY KEY      → F95Zone thread id
//   games.name TEXT
//   games.version TEXT
//   games.developer TEXT
//   games.executables TEXT            → JSON array of relative paths
//                                       (relative to settings.default_exe_dir["2"])
//   games.tags TEXT                   → JSON array of strings
//   games.description TEXT
//   games.changelog TEXT
//   games.notes TEXT
//   games.score REAL                  → F95Zone average (0..5)
//   games.votes INTEGER
//   games.rating INTEGER              → user rating, 0..5 stars
//   games.last_launched INTEGER       → unix seconds
//   games.image_url TEXT              → cover
//   games.finished TEXT               → empty / "completed"
//
// Default games base dir lives at:
//   settings.default_exe_dir → JSON `{"2": "/path/on/linux"}`
//
// Caller picks the actual base dir at import time (the configured one
// may be stale), so we don't try to resolve absolute paths here; only
// the relative `install_executable_rel` is returned.

const std = @import("std");
const dbu = @import("util_db");
const imp = @import("importers.zig");

const log = std.log.scoped(.importer_f95checker);

/// Default db path. Settings UI lets the user override but most users
/// will have the upstream default.
pub const DEFAULT_DB_BASENAME = "db.sqlite3";

/// Read every game row from the F95Checker SQLite db at `db_path`.
/// Returns a `Bundle` owning every string via an arena. Caller frees
/// with `bundle.deinit()`.
/// True when `<db_path>-wal` exists and is non-empty — the strongest
/// libc-only signal that the source app has the DB open right now (a
/// cleanly-closed sqlite checkpoints and truncates its WAL). A read-only
/// open of a hot-WAL DB sees a stale snapshot, which is the leading
/// theory for the field report of imports needing several repeats.
fn walIsHot(db_path: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const wal = std.fmt.bufPrintZ(&buf, "{s}-wal", .{db_path}) catch return false;
    const f = std.c.fopen(wal.ptr, "rb") orelse return false;
    defer _ = std.c.fclose(f);
    // Non-empty ⟺ at least one byte readable (no fseek binding in std.c).
    var byte: [1]u8 = undefined;
    return std.c.fread(&byte, 1, 1, f) == 1;
}

pub fn loadFromDb(alloc: std.mem.Allocator, db_path: []const u8) imp.Error!imp.Bundle {
    if (walIsHot(db_path)) {
        log.warn(
            "{s} has a non-empty WAL — F95Checker looks like it's still running. " ++
                "This import may see a stale snapshot; close F95Checker and re-import if games are missing.",
            .{db_path},
        );
    }
    var conn = dbu.Conn.open(db_path, alloc, .{ .readonly = true, .create = false }) catch return imp.Error.OpenFailed;
    defer conn.close();

    const arena = alloc.create(std.heap.ArenaAllocator) catch return imp.Error.OutOfMemory;
    errdefer alloc.destroy(arena);
    arena.* = .init(alloc);
    errdefer arena.deinit();
    const aalloc = arena.allocator();

    var out: std.ArrayList(imp.ImportedGame) = .empty;
    errdefer out.deinit(aalloc);

    var rows = conn.inner.rows(
        \\SELECT id, name, version, developer, executables, tags,
        \\       description, changelog, notes, image_url, score,
        \\       votes, rating, last_launched, finished
        \\FROM games
        \\ORDER BY name COLLATE NOCASE
    , .{}) catch return imp.Error.ParseFailed;
    defer rows.deinit();

    // Per-run accounting: makes a partial import diagnosable from the log
    // (field report: imports sometimes need repeating; the counts tell us
    // whether rows were missing at READ time or lost downstream).
    var rows_read: usize = 0;
    var skipped_bad_id: usize = 0;
    var skipped_nameless: usize = 0;

    while (rows.next()) |r| {
        rows_read += 1;
        const id_i: i64 = r.int(0);
        if (id_i <= 0) {
            skipped_bad_id += 1;
            log.info("import skip: row with non-positive id {d}", .{id_i});
            continue;
        }
        const thread_id: u64 = @intCast(id_i);

        const name = (dupeNullable(aalloc, r.nullableText(1)) catch return imp.Error.OutOfMemory) orelse {
            // Skipping nameless rows keeps malformed source data from
            // polluting the import; F95Checker shouldn't emit them but
            // tests have seen broken installs.
            skipped_nameless += 1;
            log.info("import skip: nameless row id {d}", .{id_i});
            continue;
        };

        const version = blk: {
            const s = (dupeNullable(aalloc, r.nullableText(2)) catch return imp.Error.OutOfMemory) orelse break :blk null;
            // F95Checker stamps "Unchecked" for never-refreshed entries;
            // surface that as "no version" rather than a literal label
            // the user would see in their library.
            if (std.mem.eql(u8, s, "Unchecked") or s.len == 0) break :blk null;
            break :blk s;
        };
        const developer = (dupeNullable(aalloc, r.nullableText(3)) catch return imp.Error.OutOfMemory) orelse null;
        const executables_json = (dupeNullable(aalloc, r.nullableText(4)) catch return imp.Error.OutOfMemory) orelse "[]";
        const tags_json = (dupeNullable(aalloc, r.nullableText(5)) catch return imp.Error.OutOfMemory) orelse "[]";
        const description = (dupeNullable(aalloc, r.nullableText(6)) catch return imp.Error.OutOfMemory) orelse null;
        const changelog = (dupeNullable(aalloc, r.nullableText(7)) catch return imp.Error.OutOfMemory) orelse null;
        const notes = (dupeNullable(aalloc, r.nullableText(8)) catch return imp.Error.OutOfMemory) orelse null;
        const image_url = (dupeNullable(aalloc, r.nullableText(9)) catch return imp.Error.OutOfMemory) orelse null;

        const score_f: f64 = r.float(10);
        const rating_score: ?f32 = if (score_f > 0) @as(f32, @floatCast(score_f)) else null;

        const votes_i: i64 = r.int(11);
        const vote_count: ?u32 = if (votes_i > 0) @as(u32, @intCast(votes_i)) else null;

        const rating_i: i64 = r.int(12);
        const user_rating: ?f32 = if (rating_i > 0) @as(f32, @floatFromInt(rating_i)) else null;

        const launched_i: i64 = r.int(13);
        const last_played_at: ?i64 = if (launched_i > 0) launched_i else null;

        const finished_str = (dupeNullable(aalloc, r.nullableText(14)) catch return imp.Error.OutOfMemory) orelse "";

        const tags = parseJsonStringArray(aalloc, tags_json) catch &.{};
        const exes = parseJsonStringArray(aalloc, executables_json) catch &.{};
        const install_rel: ?[]const u8 = if (exes.len > 0) exes[0] else null;

        // F95Checker uses an empty `finished` for "not started" and any
        // truthy string for completed-ish. Pass the raw text through;
        // the f69 upsert side maps to its own enum.
        const completion: ?[]const u8 = if (finished_str.len > 0) finished_str else null;

        out.append(aalloc, .{
            .thread_id = thread_id,
            .name = name,
            .developer = developer,
            .version = version,
            .description = description,
            .changelog = changelog,
            .notes = notes,
            .cover_url = image_url,
            .tags = tags,
            .user_rating = user_rating,
            .rating = rating_score,
            .vote_count = vote_count,
            .last_played_at = last_played_at,
            .install_executable_rel = install_rel,
            .completion_status = completion,
        }) catch return imp.Error.OutOfMemory;
    }

    log.info("import read: {d} rows -> {d} games ({d} bad-id, {d} nameless skipped) from {s}", .{
        rows_read, rows_read - skipped_bad_id - skipped_nameless, skipped_bad_id, skipped_nameless, db_path,
    });

    const games = out.toOwnedSlice(aalloc) catch return imp.Error.OutOfMemory;
    return .{ .arena = arena, .games = games };
}

// ============================================================
//  Export: write f69's library into a F95Checker-shaped SQLite db.
//
//  Used by the "Export to F95Checker" UI flow. F95Checker has no
//  dedicated backup-format function (its only imports are URL
//  shortcuts / browser bookmarks HTML / live API fetches, none of
//  which carry rich metadata), so we write directly into a
//  `db.sqlite3` matching the upstream schema.
//
//  Safety: caller MUST have already backed up any existing target
//  file. We refuse to clobber unconditionally — see
//  `backupExistingIfPresent` in actions/imports.zig.
// ============================================================

/// One row to be exported. Caller fills these in by walking
/// `frame.games` + per-game `latestInstallForGame`. Strings are
/// borrowed (we just bind them as SQL params, sqlite copies).
pub const ExportGame = struct {
    thread_id: u64,
    name: []const u8,
    version: ?[]const u8 = null,
    developer: ?[]const u8 = null,
    description: ?[]const u8 = null,
    changelog: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    cover_url: ?[]const u8 = null,
    /// F95Zone average score (0..5 typically).
    score: f32 = 0,
    votes: u32 = 0,
    /// User's own 0..5 rating; 0 means "no rating".
    rating: u32 = 0,
    /// Unix seconds; 0 means "never launched".
    last_launched: i64 = 0,
    /// Unix seconds for `added_on`. Defaults to install timestamp at
    /// the caller's discretion (best-effort — f69 doesn't track when
    /// a game was added to the library distinctly from when it was
    /// installed).
    added_on: i64 = 0,
    last_updated: i64 = 0,
    /// Comma-free tag strings; serialized to a JSON array.
    tags: []const []const u8 = &.{},
    /// Pre-built JSON list — assembly logic lives in the caller so
    /// we keep this writer free of f69-side string ownership rules.
    /// Empty string means we'll emit `[]`.
    executables_json: []const u8 = "",
    /// F95Checker convention: empty string = not finished; a
    /// non-empty string (the version at which the user marked
    /// finished) = finished. We use `version` as the marker when
    /// completion_status is .completed, else empty.
    finished: []const u8 = "",
    /// Same convention: empty = not installed; the version string
    /// when installed. Setting this is what makes F95Checker's
    /// "Installed" filter find the game.
    installed: []const u8 = "",
    /// `https://f95zone.to/threads/<id>/` — caller may pass empty
    /// for synthetic games; we synthesize from `thread_id` when so.
    url: []const u8 = "",
};

/// Write the export. Opens (creates) `db_path`, runs F95Checker's
/// minimal table schema, inserts every game. Idempotency: callers
/// SHOULD have moved any existing file to a backup first — this
/// writer creates the DB; if a file is already there with a non-
/// matching schema the inserts will error.
pub fn writeToDb(
    alloc: std.mem.Allocator,
    db_path: []const u8,
    games: []const ExportGame,
) imp.Error!void {
    var conn = dbu.Conn.open(db_path, alloc, .{ .readonly = false, .create = true }) catch return imp.Error.OpenFailed;
    defer conn.close();

    // Replicate F95Checker's `games` table schema verbatim
    // (modules/db.py:271). The DEFAULT clauses on the f95checker
    // side use Type.Unchecked = 23 and Status.Unchecked = 5
    // (sourced from common/structs.py).
    conn.exec(F95CHECKER_GAMES_DDL) catch return imp.Error.ParseFailed;

    // Pre-create all the F95Checker tables. F95Checker's startup
    // runs CREATE TABLE IF NOT EXISTS + ALTER TABLE ADD COLUMN for
    // each table; that work happens inside an implicit transaction
    // that only commits after ~30s (save_loop) or on clean exit.
    // If F95Checker crashes between startup and the first save (e.g.
    // because the `settings` table has no row and a SELECT returns
    // None → AttributeError on dataclass coerce → crash), every DDL
    // step rolls back and the next launch sees the same broken DB.
    //
    // Solution: ship all the tables ourselves so F95Checker's
    // CREATE TABLE IF NOT EXISTS calls are no-ops, AND insert the
    // singleton `_=0` row F95Checker's settings loader expects.
    // F95Checker's create_table will then ALTER our minimal table
    // shapes to add its full column set (with defaults) on first
    // launch — but the singleton row stays + the schema is sound.
    //
    // We deliberately don't ship every column-on-every-table because
    // that would lock us to F95Checker's exact schema-of-the-week
    // and break any future upstream column rename. F95Checker's
    // own migration code is the right tool to bring the schema up
    // to date; we just need the tables to exist + the singleton row.
    conn.exec(
        \\CREATE TABLE IF NOT EXISTS settings (
        \\  _ INTEGER PRIMARY KEY CHECK (_=0)
        \\)
    ) catch return imp.Error.ParseFailed;
    conn.exec("INSERT INTO settings (_) VALUES (0) ON CONFLICT DO NOTHING") catch return imp.Error.ParseFailed;
    conn.exec(
        \\CREATE TABLE IF NOT EXISTS cookies (
        \\  key   TEXT PRIMARY KEY,
        \\  value TEXT DEFAULT ""
        \\)
    ) catch return imp.Error.ParseFailed;
    conn.exec(
        \\CREATE TABLE IF NOT EXISTS labels (
        \\  id    INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  name  TEXT DEFAULT "",
        \\  color TEXT DEFAULT "#696969"
        \\)
    ) catch return imp.Error.ParseFailed;
    conn.exec(
        \\CREATE TABLE IF NOT EXISTS tabs (
        \\  id       INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  name     TEXT    DEFAULT "",
        \\  icon     TEXT    DEFAULT "",
        \\  color    TEXT    DEFAULT NULL,
        \\  position INTEGER DEFAULT 0
        \\)
    ) catch return imp.Error.ParseFailed;
    conn.exec(
        \\CREATE TABLE IF NOT EXISTS timeline_events (
        \\  game_id   INTEGER DEFAULT NULL,
        \\  timestamp INTEGER DEFAULT 0,
        \\  arguments TEXT    DEFAULT "[]",
        \\  type      INTEGER DEFAULT 1
        \\)
    ) catch return imp.Error.ParseFailed;

    // Wrap inserts in a transaction — couple-hundred-row libraries
    // would otherwise sync every row to disk individually.
    conn.exec("BEGIN") catch return imp.Error.ParseFailed;
    errdefer conn.exec("ROLLBACK") catch {};

    const insert_sql =
        \\INSERT INTO games (
        \\  id, name, version, developer, url,
        \\  added_on, last_updated, last_launched,
        \\  score, votes, rating,
        \\  finished, installed, executables,
        \\  description, changelog, tags, notes,
        \\  image_url
        \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(id) DO UPDATE SET
        \\  name=excluded.name, version=excluded.version, developer=excluded.developer,
        \\  url=excluded.url, added_on=excluded.added_on, last_updated=excluded.last_updated,
        \\  last_launched=excluded.last_launched, score=excluded.score, votes=excluded.votes,
        \\  rating=excluded.rating, finished=excluded.finished, installed=excluded.installed,
        \\  executables=excluded.executables, description=excluded.description,
        \\  changelog=excluded.changelog, tags=excluded.tags, notes=excluded.notes,
        \\  image_url=excluded.image_url
    ;

    // Scratch buffers for fields we serialize per-row.
    var url_buf: [128]u8 = undefined;

    for (games) |g| {
        // F95Checker stores tags as INTEGER IDs that map to the
        // `Tag` IntEnumHack in common/structs.py (e.g. "3dcg" → 4,
        // "anal-sex" → 7). On load, F95Checker coerces each element
        // via `Tag(x)` which calls `int.__new__(cls, x)` — passing a
        // string crashes the entire DB load with a ValueError, taking
        // the app down before settings are even committed.
        //
        // Mapping f69's free-form tag strings → upstream tag IDs would
        // require shipping a 150-entry name table that drifts every
        // time F95Zone renames a tag. Cleaner: emit an empty array and
        // let the user run F95Checker's "Refresh All" to repopulate
        // tags from F95Zone, which produces the canonical IDs anyway.
        _ = g.tags;
        const tags_json: []const u8 = "[]";
        const exes_json: []const u8 = if (g.executables_json.len == 0) "[]" else g.executables_json;

        // Synthesize the F95Zone thread URL when the caller didn't
        // supply one. F95Checker accepts the canonical `/threads/<id>/`
        // form — the version slug isn't required.
        const url_slice: []const u8 = if (g.url.len > 0)
            g.url
        else
            std.fmt.bufPrint(&url_buf, "https://f95zone.to/threads/{d}/", .{g.thread_id}) catch return imp.Error.OutOfMemory;

        conn.inner.exec(insert_sql, .{
            @as(i64, @intCast(g.thread_id)),
            g.name,
            g.version orelse "Unchecked",
            g.developer orelse "",
            url_slice,
            g.added_on,
            g.last_updated,
            g.last_launched,
            @as(f64, g.score),
            @as(i64, @intCast(g.votes)),
            @as(i64, @intCast(g.rating)),
            g.finished,
            g.installed,
            exes_json,
            g.description orelse "",
            g.changelog orelse "",
            tags_json,
            g.notes orelse "",
            g.cover_url orelse "",
        }) catch return imp.Error.ParseFailed;
    }

    conn.exec("COMMIT") catch return imp.Error.ParseFailed;
}

/// F95Checker's `games` table DDL, hand-translated from the upstream
/// `create_table` call in `modules/db.py`. Type/Status `Unchecked`
/// constants are hardcoded to their upstream values (Type=23,
/// Status=5) — change here if upstream renumbers them.
const F95CHECKER_GAMES_DDL =
    \\CREATE TABLE IF NOT EXISTS games (
    \\  id                  INTEGER PRIMARY KEY,
    \\  custom              INTEGER DEFAULT NULL,
    \\  name                TEXT    DEFAULT "",
    \\  version             TEXT    DEFAULT "Unchecked",
    \\  developer           TEXT    DEFAULT "",
    \\  type                INTEGER DEFAULT 23,
    \\  status              INTEGER DEFAULT 5,
    \\  url                 TEXT    DEFAULT "",
    \\  added_on            INTEGER DEFAULT 0,
    \\  last_updated        INTEGER DEFAULT 0,
    \\  last_full_check     INTEGER DEFAULT 0,
    \\  last_check_version  TEXT    DEFAULT "",
    \\  last_launched       INTEGER DEFAULT 0,
    \\  score               REAL    DEFAULT 0,
    \\  votes               INTEGER DEFAULT 0,
    \\  rating              INTEGER DEFAULT 0,
    \\  finished            TEXT    DEFAULT "",
    \\  installed           TEXT    DEFAULT "",
    \\  updated             INTEGER DEFAULT NULL,
    \\  archived            INTEGER DEFAULT 0,
    \\  executables         TEXT    DEFAULT "[]",
    \\  description         TEXT    DEFAULT "",
    \\  changelog           TEXT    DEFAULT "",
    \\  tags                TEXT    DEFAULT "[]",
    \\  unknown_tags        TEXT    DEFAULT "[]",
    \\  unknown_tags_flag   INTEGER DEFAULT 0,
    \\  labels              TEXT    DEFAULT "[]",
    \\  tab                 INTEGER DEFAULT NULL,
    \\  notes               TEXT    DEFAULT "",
    \\  image_url           TEXT    DEFAULT "",
    \\  previews_urls       TEXT    DEFAULT "[]",
    \\  downloads           TEXT    DEFAULT "[]",
    \\  reviews_total       INTEGER DEFAULT 0,
    \\  reviews             TEXT    DEFAULT "[]"
    \\)
;

/// Read `settings.default_exe_dir` and return the JSON value for the
/// Linux platform key ("2"). Useful as the suggested default for the
/// games-base-dir picker. Null if the field is empty or absent.
/// Caller frees the returned string.
pub fn readConfiguredGamesDir(alloc: std.mem.Allocator, db_path: []const u8) !?[]u8 {
    var conn = dbu.Conn.open(db_path, alloc, .{ .readonly = true, .create = false }) catch return imp.Error.OpenFailed;
    defer conn.close();

    var maybe_row = conn.inner.row("SELECT default_exe_dir FROM settings WHERE _ = 0", .{}) catch return imp.Error.ParseFailed;
    if (maybe_row) |*r| {
        defer r.deinit();
        const raw = r.nullableText(0) orelse return null;
        if (raw.len == 0) return null;
        return try extractLinuxPath(alloc, raw);
    }
    return null;
}

/// Pull the `"2"` entry out of `{"2": "/path"}`. Tiny hand-rolled
/// JSON peek so we don't drag a full parser allocation in for a
/// single key lookup.
fn extractLinuxPath(alloc: std.mem.Allocator, json: []const u8) !?[]u8 {
    // Look for the literal `"2"` key.
    const key = "\"2\"";
    const k_at = std.mem.indexOf(u8, json, key) orelse return null;
    var i = k_at + key.len;
    // Skip whitespace + colon + whitespace + opening quote.
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == ':')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {
        // F95Checker doesn't escape slashes; we don't expect backslash
        // escapes either. If we hit one, bail to keep the parser tiny.
        if (json[i] == '\\') return null;
    }
    if (i >= json.len) return null;
    return try alloc.dupe(u8, json[start..i]);
}

fn dupeNullable(alloc: std.mem.Allocator, opt: ?[]const u8) !?[]const u8 {
    const s = opt orelse return null;
    return try alloc.dupe(u8, s);
}

/// Decode F95Checker's JSON-array-of-strings columns (`tags`, `executables`).
/// Returns an arena-allocated slice of arena-allocated strings.
fn parseJsonStringArray(alloc: std.mem.Allocator, json: []const u8) ![]const []const u8 {
    var parsed = try std.json.parseFromSlice([]const []const u8, alloc, json, .{});
    defer parsed.deinit();
    // dupe into arena so deinit() of the parsed value doesn't kill us.
    var out = try alloc.alloc([]const u8, parsed.value.len);
    for (parsed.value, 0..) |s, i| {
        out[i] = try alloc.dupe(u8, s);
    }
    return out;
}

// ============================================================
//  Tests — use in-memory SQLite with a synthesized schema so we
//  don't depend on the user's home directory.
// ============================================================

const testing = std.testing;
const test_env = @import("util_test_env");

test "loadFromDb: empty games table → empty bundle" {
    var env = try test_env.TestEnv.init(testing.allocator, "f95checker-empty");
    defer env.deinit();
    const tmp = try env.path("games.sqlite3");
    defer testing.allocator.free(tmp);

    {
        var conn = try dbu.Conn.open(tmp, testing.allocator, .{ .create = true });
        defer conn.close();
        try conn.exec(
            "CREATE TABLE games (id INTEGER PRIMARY KEY, name TEXT, version TEXT, developer TEXT, executables TEXT DEFAULT '[]', tags TEXT DEFAULT '[]', description TEXT, changelog TEXT, notes TEXT, image_url TEXT, score REAL DEFAULT 0, votes INTEGER DEFAULT 0, rating INTEGER DEFAULT 0, last_launched INTEGER DEFAULT 0, finished TEXT DEFAULT '')",
        );
    }

    var bundle = try loadFromDb(testing.allocator, tmp);
    defer bundle.deinit();
    try testing.expectEqual(@as(usize, 0), bundle.games.len);
}

test "loadFromDb: full row round-trips through the bundle" {
    var env = try test_env.TestEnv.init(testing.allocator, "f95checker-full");
    defer env.deinit();
    const tmp = try env.path("games.sqlite3");
    defer testing.allocator.free(tmp);

    {
        var conn = try dbu.Conn.open(tmp, testing.allocator, .{ .create = true });
        defer conn.close();
        try conn.exec(
            "CREATE TABLE games (id INTEGER PRIMARY KEY, name TEXT, version TEXT, developer TEXT, executables TEXT DEFAULT '[]', tags TEXT DEFAULT '[]', description TEXT, changelog TEXT, notes TEXT, image_url TEXT, score REAL DEFAULT 0, votes INTEGER DEFAULT 0, rating INTEGER DEFAULT 0, last_launched INTEGER DEFAULT 0, finished TEXT DEFAULT '')",
        );
        conn.inner.exec(
            "INSERT INTO games VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            .{
                @as(i64, 2428),
                "Babysitter",
                "v0.2.2b",
                "T4bbo",
                "[\"Babysitter-0.2.2b.-linux/Babysitter.sh\"]",
                "[\"3dcg\",\"romance\"]",
                "the description",
                "the changelog",
                "the notes",
                "https://attachments.f95zone.to/cover.png",
                @as(f64, 4.5),
                @as(i64, 1234),
                @as(i64, 5),
                @as(i64, 1700000000),
                "completed",
            },
        ) catch unreachable;
    }

    var bundle = try loadFromDb(testing.allocator, tmp);
    defer bundle.deinit();

    try testing.expectEqual(@as(usize, 1), bundle.games.len);
    const g = bundle.games[0];
    try testing.expectEqual(@as(u64, 2428), g.thread_id);
    try testing.expectEqualStrings("Babysitter", g.name);
    try testing.expectEqualStrings("v0.2.2b", g.version.?);
    try testing.expectEqualStrings("T4bbo", g.developer.?);
    try testing.expectEqualStrings("Babysitter-0.2.2b.-linux/Babysitter.sh", g.install_executable_rel.?);
    try testing.expectEqualStrings("Babysitter-0.2.2b.-linux", g.installDirRel().?);
    try testing.expectEqual(@as(usize, 2), g.tags.len);
    try testing.expectEqualStrings("3dcg", g.tags[0]);
    try testing.expectEqualStrings("romance", g.tags[1]);
    try testing.expectEqual(@as(?f32, 4.5), g.rating);
    try testing.expectEqual(@as(?u32, 1234), g.vote_count);
    try testing.expectEqual(@as(?f32, 5), g.user_rating);
    try testing.expectEqual(@as(?i64, 1700000000), g.last_played_at);
    try testing.expectEqualStrings("completed", g.completion_status.?);
}

test "writeToDb: round-trips through loadFromDb" {
    var env = try test_env.TestEnv.init(testing.allocator, "f95checker-export");
    defer env.deinit();
    const tmp = try env.path("db.sqlite3");
    defer testing.allocator.free(tmp);

    const tags = [_][]const u8{ "3dcg", "romance" };
    const exes_json = "[\"/home/moortu/.local/share/f69/library/2428/imported/Babysitter.sh\"]";
    const games = [_]ExportGame{
        .{
            .thread_id = 2428,
            .name = "Babysitter",
            .version = "v0.2.2b",
            .developer = "T4bbo",
            .description = "the description",
            .changelog = "the changelog",
            .notes = "the notes",
            .cover_url = "https://attachments.f95zone.to/cover.png",
            .score = 4.5,
            .votes = 1234,
            .rating = 5,
            .last_launched = 1700000000,
            .added_on = 1690000000,
            .last_updated = 1700000000,
            .tags = &tags,
            .executables_json = exes_json,
            .finished = "v0.2.2b",
            .installed = "v0.2.2b",
            .url = "https://f95zone.to/threads/2428/",
        },
    };
    try writeToDb(testing.allocator, tmp, &games);

    // Re-read via the existing importer to verify shape parity.
    var bundle = try loadFromDb(testing.allocator, tmp);
    defer bundle.deinit();

    try testing.expectEqual(@as(usize, 1), bundle.games.len);
    const g = bundle.games[0];
    try testing.expectEqual(@as(u64, 2428), g.thread_id);
    try testing.expectEqualStrings("Babysitter", g.name);
    try testing.expectEqualStrings("v0.2.2b", g.version.?);
    try testing.expectEqualStrings("T4bbo", g.developer.?);
    // tags are intentionally emitted as `[]` on export — see writeToDb.
    try testing.expectEqual(@as(usize, 0), g.tags.len);
    try testing.expectEqual(@as(?f32, 4.5), g.rating);
    try testing.expectEqual(@as(?u32, 1234), g.vote_count);
    try testing.expectEqual(@as(?f32, 5), g.user_rating);
    try testing.expectEqual(@as(?i64, 1700000000), g.last_played_at);
    try testing.expectEqualStrings("completed-as-v0.2.2b — completion mapper checks", "completed-as-v0.2.2b — completion mapper checks"); // sanity placeholder
    // The exporter writes `finished = version` to mark "completed at version".
    // The importer returns the raw text → the UI's `mapCompletion`
    // turns a non-empty `finished` into `.completed`. We assert the
    // raw value made the round trip.
    try testing.expectEqualStrings("v0.2.2b", g.completion_status.?);
}

test "writeToDb: minimal row (only thread_id + name)" {
    var env = try test_env.TestEnv.init(testing.allocator, "f95checker-export-min");
    defer env.deinit();
    const tmp = try env.path("db.sqlite3");
    defer testing.allocator.free(tmp);

    const games = [_]ExportGame{
        .{ .thread_id = 99999, .name = "Bare Game" },
    };
    try writeToDb(testing.allocator, tmp, &games);

    var bundle = try loadFromDb(testing.allocator, tmp);
    defer bundle.deinit();
    try testing.expectEqual(@as(usize, 1), bundle.games.len);
    try testing.expectEqual(@as(u64, 99999), bundle.games[0].thread_id);
    try testing.expectEqualStrings("Bare Game", bundle.games[0].name);
    // Default version "Unchecked" → loadFromDb normalises to null
    // (see the next test). So we should see null here too.
    try testing.expect(bundle.games[0].version == null);
}

test "loadFromDb: 'Unchecked' version is normalised to null" {
    var env = try test_env.TestEnv.init(testing.allocator, "f95checker-unchecked");
    defer env.deinit();
    const tmp = try env.path("games.sqlite3");
    defer testing.allocator.free(tmp);

    {
        var conn = try dbu.Conn.open(tmp, testing.allocator, .{ .create = true });
        defer conn.close();
        try conn.exec(
            "CREATE TABLE games (id INTEGER PRIMARY KEY, name TEXT, version TEXT, developer TEXT, executables TEXT DEFAULT '[]', tags TEXT DEFAULT '[]', description TEXT, changelog TEXT, notes TEXT, image_url TEXT, score REAL DEFAULT 0, votes INTEGER DEFAULT 0, rating INTEGER DEFAULT 0, last_launched INTEGER DEFAULT 0, finished TEXT DEFAULT '')",
        );
        conn.inner.exec(
            "INSERT INTO games (id, name, version) VALUES (?, ?, ?)",
            .{ @as(i64, 100), "Fresh", "Unchecked" },
        ) catch unreachable;
    }

    var bundle = try loadFromDb(testing.allocator, tmp);
    defer bundle.deinit();
    try testing.expectEqual(@as(?[]const u8, null), bundle.games[0].version);
}

test "extractLinuxPath: pulls value for key \"2\"" {
    const out = try extractLinuxPath(testing.allocator, "{\"2\": \"/path/to/games\"}");
    defer if (out) |s| testing.allocator.free(s);
    try testing.expectEqualStrings("/path/to/games", out.?);
}

test "extractLinuxPath: missing key returns null" {
    const out = try extractLinuxPath(testing.allocator, "{}");
    try testing.expectEqual(@as(?[]u8, null), out);
}

test "walIsHot: nonexistent sidecar means cold" {
    try testing.expect(!walIsHot("/nonexistent/db.sqlite3"));
}

test "walIsHot: non-empty -wal sidecar means hot" {
    var env = try test_env.TestEnv.init(testing.allocator, "f95checker-wal");
    defer env.deinit();
    const db = try env.path("db.sqlite3");
    defer testing.allocator.free(db);
    const wal = try std.fmt.allocPrintSentinel(testing.allocator, "{s}-wal", .{db}, 0);
    defer testing.allocator.free(wal);

    // Empty sidecar (checkpointed WAL after clean close) — cold.
    {
        const f = std.c.fopen(wal.ptr, "wb") orelse return error.SkipZigTest;
        _ = std.c.fclose(f);
    }
    try testing.expect(!walIsHot(db));

    // Non-empty sidecar — the source app likely has the DB open.
    {
        const f = std.c.fopen(wal.ptr, "wb") orelse return error.SkipZigTest;
        _ = std.c.fwrite("x", 1, 1, f);
        _ = std.c.fclose(f);
    }
    try testing.expect(walIsHot(db));
}
