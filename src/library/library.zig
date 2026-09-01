// Library — zqlite-backed store for games, installs, mods, mod_installs.
// Single struct; no Service-over-Repo layer (architect review 2026-05-08).
// When real cross-context orchestration shows up, a Service in installer/
// is the right home for it, not here.
//
// Migrations are ordered SQL strings + a `_schema_version` table tracking
// each applied migration's id, hash, and timestamp. Hash check on startup
// catches accidental edits to applied SQL.
//
// Caller-owned strings: returned slices use the allocator passed into the
// call. Caller frees.

const std = @import("std");
const dbu = @import("util_db");
const dom = @import("domain.zig");
const errs = @import("errors.zig");
const version_mod = @import("util_version");

const log = std.log.scoped(.library);

pub const Game = dom.Game;
pub const Install = dom.Install;
pub const InstallSource = dom.InstallSource;
pub const AutoUpdateOverride = dom.AutoUpdateOverride;
pub const BackupModePref = dom.BackupModePref;
pub const Mod = dom.Mod;
pub const ModInstall = dom.ModInstall;
pub const CompletionStatus = dom.CompletionStatus;
pub const Engine = dom.Engine;
pub const UserLabel = dom.UserLabel;
pub const UniversalMod = dom.UniversalMod;
pub const DevStatus = dom.DevStatus;
pub const CensoredState = dom.CensoredState;
pub const SandboxOverride = dom.SandboxOverride;
pub const SavesPaths = dom.SavesPaths;
pub const PlaySession = dom.PlaySession;
pub const errors = errs;

pub const Library = struct {
    alloc: std.mem.Allocator,
    conn: dbu.Conn,
    /// Monotonic counter bumped on every install-table mutation
    /// (`upsertInstall` / `deleteInstall` / `updateInstallName`). The
    /// UI uses this as the cache key for its per-frame
    /// `install_versions` snapshot — when it doesn't change, the
    /// snapshot is reused across frames instead of running a fresh
    /// SELECT over the installs table. Game-table mutations don't
    /// bump this; the UI detects those by comparing the frame's
    /// `games`-slice ptr+len. Wraps on overflow (`+%=`) — the cache
    /// only needs inequality, not ordering.
    install_generation: u64 = 0,

    pub fn open(alloc: std.mem.Allocator, db_path: []const u8) errs.Error!Library {
        var conn = dbu.Conn.open(db_path, alloc, .{ .create = true }) catch |e| {
            log.err("failed to open database at '{s}': {s}", .{ db_path, @errorName(e) });
            return errs.Error.DatabaseError;
        };
        errdefer conn.close();
        // SQLite defaults FK enforcement to OFF — turn it on so the
        // schema's `REFERENCES … ON DELETE CASCADE` clauses actually
        // fire. Per-connection setting, set once at open.
        conn.setPragmaInt(alloc, "foreign_keys", 1) catch return errs.Error.SchemaMigrationFailed;
        // Performance pragmas. WAL gives concurrent reads + faster
        // writes; synchronous=NORMAL still survives application + OS
        // crashes (WAL durability) while skipping fsyncs that FULL
        // requires; a 64 MB page cache + 256 MB mmap window keep hot
        // pages out of disk on a library scrolling through hundreds
        // of games; temp tables stay in RAM. journal_mode persists in
        // the DB file header, so re-opens inherit it; the rest are
        // per-connection. Audited from the perf review — every
        // listInstalls / listGames call previously paid the default
        // rollback-journal + 2 MB cache penalty.
        conn.exec("PRAGMA journal_mode = WAL") catch return errs.Error.SchemaMigrationFailed;
        conn.exec("PRAGMA synchronous = NORMAL") catch return errs.Error.SchemaMigrationFailed;
        conn.exec("PRAGMA cache_size = -65536") catch return errs.Error.SchemaMigrationFailed;
        conn.exec("PRAGMA mmap_size = 268435456") catch return errs.Error.SchemaMigrationFailed;
        conn.exec("PRAGMA temp_store = MEMORY") catch return errs.Error.SchemaMigrationFailed;
        runMigrations(alloc, &conn, db_path) catch return errs.Error.SchemaMigrationFailed;
        return .{ .alloc = alloc, .conn = conn };
    }

    pub fn close(self: *Library) void {
        self.conn.close();
        self.* = undefined;
    }

    /// Log the SQLite error message (sqlite3_errmsg) for the last failed
    /// operation, then return the generic DatabaseError. Used at
    /// `catch return self.dbFail()` sites so a DB failure says *what* broke
    /// (missing column, constraint violation, malformed image, I/O error, …)
    /// instead of a bare "DatabaseError".
    fn dbFail(self: *Library) errs.Error {
        log.err("database query/exec failed: {s}", .{self.conn.lastError()});
        return errs.Error.DatabaseError;
    }

    // ---- transactions ----
    //
    // SQLite default journal mode is rollback; nesting via savepoints
    // isn't exposed here. Caller must not nest beginTx calls.

    pub fn beginTx(self: *Library) errs.Error!void {
        self.conn.exec("BEGIN") catch return self.dbFail();
    }

    pub fn commitTx(self: *Library) errs.Error!void {
        self.conn.exec("COMMIT") catch return self.dbFail();
    }

    pub fn rollbackTx(self: *Library) errs.Error!void {
        self.conn.exec("ROLLBACK") catch return self.dbFail();
    }

    // -- games --

    /// JSON-encoded tags or "[]" if the game has none. Caller frees.
    fn encodeTagsJson(self: *Library, tags: []const []const u8) errs.Error![]u8 {
        return std.json.Stringify.valueAlloc(self.alloc, tags, .{}) catch return errs.Error.OutOfMemory;
    }

    /// INSERT OR IGNORE — used by the importer so re-pasting a thread
    /// list doesn't clobber rows that already have synced data.
    /// Returns true if a row was actually inserted.
    pub fn insertIfMissing(self: *Library, g: *const dom.Game) errs.Error!bool {
        const sql =
            \\INSERT OR IGNORE INTO games (
            \\  f95_thread_id, name, developer, cover_url, description_md,
            \\  tags_json, rating, vote_count, user_rating,
            \\  completion_status, engine, latest_version,
            \\  sandbox, last_played_at, total_playtime_s,
            \\  last_scraped_at, created_at, notes, screenshots_json,
            \\  changelog_md, reviews_md, download_links_json, dev_status,
            \\  downloads_md, last_updated_at, thread_info_md, censored,
            \\  last_indexer_change, last_indexer_parser_version, last_played_version,
            \\  pinned_version, status_changed_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ;
        const tags_json = try self.encodeTagsJson(g.tags);
        defer self.alloc.free(tags_json);
        const screenshots_json = try self.encodeTagsJson(g.screenshots);
        defer self.alloc.free(screenshots_json);
        const dl_json = try self.encodeTagsJson(g.download_links);
        defer self.alloc.free(dl_json);
        self.conn.inner.exec(sql, .{
            @as(i64, @intCast(g.f95_thread_id)),
            g.name,
            g.developer,
            g.cover_url,
            g.description_md,
            tags_json,
            if (g.rating) |r| @as(?f64, @floatCast(r)) else null,
            if (g.vote_count) |v| @as(?i64, @intCast(v)) else null,
            if (g.user_rating) |r| @as(?f64, @floatCast(r)) else null,
            @tagName(g.completion_status),
            @tagName(g.engine),
            g.latest_version,
            @tagName(g.sandbox),
            g.last_played_at,
            @as(i64, @intCast(g.total_playtime_s)),
            g.last_scraped_at,
            g.created_at,
            g.notes,
            screenshots_json,
            g.changelog_md,
            g.reviews_md,
            dl_json,
            @tagName(g.dev_status),
            g.downloads_md,
            g.last_updated_at,
            g.thread_info_md,
            @tagName(g.censored),
            g.last_indexer_change,
            if (g.last_indexer_parser_version) |v| @as(?i64, @intCast(v)) else null,
            g.last_played_version,
            g.pinned_version,
            g.status_changed_at,
        }) catch return self.dbFail();
        return self.conn.inner.changes() > 0;
    }

    /// Upsert by f95_thread_id (primary key). Uses INSERT … ON CONFLICT
    /// DO UPDATE, NOT `INSERT OR REPLACE`: REPLACE is implemented as
    /// DELETE-then-INSERT, and `installs.game_thread_id REFERENCES
    /// games(...) ON DELETE CASCADE` (with foreign_keys ON) means the
    /// delete would cascade-wipe every install row for this game on every
    /// sync — the "sync forgot my installs" bug. DO UPDATE mutates the row
    /// in place, so the FK delete never fires and children survive.
    pub fn upsertGame(self: *Library, g: *const dom.Game) errs.Error!void {
        const sql =
            \\INSERT INTO games (
            \\  f95_thread_id, name, developer, cover_url, description_md,
            \\  tags_json, rating, vote_count, user_rating,
            \\  completion_status, engine, latest_version,
            \\  sandbox, last_played_at, total_playtime_s,
            \\  last_scraped_at, created_at, notes, screenshots_json,
            \\  changelog_md, reviews_md, download_links_json, dev_status,
            \\  downloads_md, last_updated_at, thread_info_md, censored,
            \\  auto_update, mod_backup_mode, last_indexer_change,
            \\  last_indexer_parser_version, last_played_version, pinned_version, status_changed_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(f95_thread_id) DO UPDATE SET
            \\  name=excluded.name, developer=excluded.developer, cover_url=excluded.cover_url,
            \\  description_md=excluded.description_md, tags_json=excluded.tags_json,
            \\  rating=excluded.rating, vote_count=excluded.vote_count, user_rating=excluded.user_rating,
            \\  completion_status=excluded.completion_status, engine=excluded.engine,
            \\  latest_version=excluded.latest_version, sandbox=excluded.sandbox,
            \\  last_played_at=excluded.last_played_at, total_playtime_s=excluded.total_playtime_s,
            \\  last_scraped_at=excluded.last_scraped_at, created_at=excluded.created_at,
            \\  notes=excluded.notes, screenshots_json=excluded.screenshots_json,
            \\  changelog_md=excluded.changelog_md, reviews_md=excluded.reviews_md,
            \\  download_links_json=excluded.download_links_json, dev_status=excluded.dev_status,
            \\  downloads_md=excluded.downloads_md, last_updated_at=excluded.last_updated_at,
            \\  thread_info_md=excluded.thread_info_md, censored=excluded.censored,
            \\  auto_update=excluded.auto_update, mod_backup_mode=excluded.mod_backup_mode,
            \\  last_indexer_change=excluded.last_indexer_change,
            \\  last_indexer_parser_version=excluded.last_indexer_parser_version,
            \\  last_played_version=excluded.last_played_version, pinned_version=excluded.pinned_version,
            \\  status_changed_at=excluded.status_changed_at
        ;
        const tags_json = try self.encodeTagsJson(g.tags);
        defer self.alloc.free(tags_json);
        const screenshots_json = try self.encodeTagsJson(g.screenshots);
        defer self.alloc.free(screenshots_json);
        const dl_json = try self.encodeTagsJson(g.download_links);
        defer self.alloc.free(dl_json);
        self.conn.inner.exec(sql, .{
            @as(i64, @intCast(g.f95_thread_id)),
            g.name,
            g.developer,
            g.cover_url,
            g.description_md,
            tags_json,
            // zqlite binds f64 from anytype; convert ?f32 → ?f64.
            if (g.rating) |r| @as(?f64, @floatCast(r)) else null,
            if (g.vote_count) |v| @as(?i64, @intCast(v)) else null,
            if (g.user_rating) |r| @as(?f64, @floatCast(r)) else null,
            @tagName(g.completion_status),
            @tagName(g.engine),
            g.latest_version,
            @tagName(g.sandbox),
            g.last_played_at,
            @as(i64, @intCast(g.total_playtime_s)),
            g.last_scraped_at,
            g.created_at,
            g.notes,
            screenshots_json,
            g.changelog_md,
            g.reviews_md,
            dl_json,
            @tagName(g.dev_status),
            g.downloads_md,
            g.last_updated_at,
            g.thread_info_md,
            @tagName(g.censored),
            @tagName(g.auto_update),
            @tagName(g.mod_backup_mode),
            g.last_indexer_change,
            if (g.last_indexer_parser_version) |v| @as(?i64, @intCast(v)) else null,
            g.last_played_version,
            g.pinned_version,
            g.status_changed_at,
        }) catch return self.dbFail();
    }

    /// Single-column write — used by the Mods page dropdown so we
    /// don't have to re-`upsertGame` (which would clobber every
    /// other column the user might have edited concurrently).
    /// Pin a game to (or unpin from) a specific version. `version = null`
    /// clears the pin (track latest again). Single-column write so it
    /// doesn't clobber concurrent edits to other columns.
    pub fn setPinnedVersion(self: *Library, thread_id: u64, version: ?[]const u8) errs.Error!void {
        self.conn.inner.exec(
            "UPDATE games SET pinned_version = ? WHERE f95_thread_id = ?",
            .{ version, @as(i64, @intCast(thread_id)) },
        ) catch return self.dbFail();
    }

    // ----- user labels -----

    /// Create a label (idempotent on name). Returns the label's id whether
    /// it was just inserted or already existed.
    pub fn createLabel(self: *Library, name: []const u8, color: ?[]const u8) errs.Error!i64 {
        self.conn.inner.exec(
            "INSERT OR IGNORE INTO user_labels (name, color) VALUES (?, ?)",
            .{ name, color },
        ) catch return self.dbFail();
        var row = (self.conn.inner.row("SELECT id FROM user_labels WHERE name = ?", .{name}) catch
            return errs.Error.DatabaseError) orelse return errs.Error.DatabaseError;
        defer row.deinit();
        return row.int(0);
    }

    pub fn renameLabel(self: *Library, id: i64, name: []const u8) errs.Error!void {
        self.conn.inner.exec("UPDATE user_labels SET name = ? WHERE id = ?", .{ name, id }) catch
            return errs.Error.DatabaseError;
    }

    /// Set (or clear, when `color` is null) a user override for a tag's
    /// chip color. `color` is a 6-hex "RRGGBB" string.
    pub fn setTagColor(self: *Library, tag: []const u8, color: ?[]const u8) errs.Error!void {
        if (color) |c|
            self.conn.inner.exec("INSERT OR REPLACE INTO tag_colors (tag, color) VALUES (?, ?)", .{ tag, c }) catch return self.dbFail()
        else
            self.conn.inner.exec("DELETE FROM tag_colors WHERE tag = ?", .{tag}) catch return self.dbFail();
    }

    /// Load all tag-color overrides into a `tag -> 0xRRGGBB` map. Keys are
    /// alloc-owned; free with `freeTagColors`.
    pub fn loadTagColors(self: *Library, alloc: std.mem.Allocator) errs.Error!std.StringHashMap(u32) {
        var map = std.StringHashMap(u32).init(alloc);
        errdefer freeTagColors(&map);
        var rows = self.conn.inner.rows("SELECT tag, color FROM tag_colors", .{}) catch return self.dbFail();
        defer rows.deinit();
        while (rows.next()) |r| {
            const packed_rgb = parseHexColor(r.text(1)) orelse continue;
            const key = alloc.dupe(u8, r.text(0)) catch return errs.Error.OutOfMemory;
            map.put(key, packed_rgb) catch {
                alloc.free(key);
                return errs.Error.OutOfMemory;
            };
        }
        return map;
    }

    /// Free the alloc-owned keys of a map from `loadTagColors`, then the map.
    pub fn freeTagColors(map: *std.StringHashMap(u32)) void {
        var it = map.keyIterator();
        while (it.next()) |k| map.allocator.free(k.*);
        map.deinit();
    }

    pub fn setLabelColor(self: *Library, id: i64, color: ?[]const u8) errs.Error!void {
        self.conn.inner.exec("UPDATE user_labels SET color = ? WHERE id = ?", .{ color, id }) catch
            return errs.Error.DatabaseError;
    }

    /// Delete a label and all its game assignments.
    pub fn deleteLabel(self: *Library, id: i64) errs.Error!void {
        self.conn.inner.exec("DELETE FROM game_labels WHERE label_id = ?", .{id}) catch
            return errs.Error.DatabaseError;
        self.conn.inner.exec("DELETE FROM user_labels WHERE id = ?", .{id}) catch
            return errs.Error.DatabaseError;
    }

    /// All labels, name-sorted. Caller frees via `freeLabels`.
    pub fn listLabels(self: *Library) errs.Error![]dom.UserLabel {
        var out: std.ArrayList(dom.UserLabel) = .empty;
        errdefer {
            for (out.items) |l| {
                self.alloc.free(l.name);
                if (l.color) |c| self.alloc.free(c);
            }
            out.deinit(self.alloc);
        }
        var rows = self.conn.inner.rows(
            "SELECT id, name, color FROM user_labels ORDER BY name COLLATE NOCASE",
            .{},
        ) catch return self.dbFail();
        defer rows.deinit();
        while (rows.next()) |r| {
            const name = self.alloc.dupe(u8, r.text(1)) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(name);
            const color: ?[]u8 = if (r.nullableText(2)) |c|
                (self.alloc.dupe(u8, c) catch return errs.Error.OutOfMemory)
            else
                null;
            out.append(self.alloc, .{ .id = r.int(0), .name = name, .color = color }) catch
                return errs.Error.OutOfMemory;
        }
        return out.toOwnedSlice(self.alloc) catch errs.Error.OutOfMemory;
    }

    pub fn freeLabels(self: *Library, labels: []dom.UserLabel) void {
        for (labels) |l| {
            self.alloc.free(l.name);
            if (l.color) |c| self.alloc.free(c);
        }
        self.alloc.free(labels);
    }

    pub fn addGameLabel(self: *Library, game_thread_id: u64, label_id: i64) errs.Error!void {
        self.conn.inner.exec(
            "INSERT OR IGNORE INTO game_labels (game_thread_id, label_id) VALUES (?, ?)",
            .{ @as(i64, @intCast(game_thread_id)), label_id },
        ) catch return self.dbFail();
    }

    pub fn removeGameLabel(self: *Library, game_thread_id: u64, label_id: i64) errs.Error!void {
        self.conn.inner.exec(
            "DELETE FROM game_labels WHERE game_thread_id = ? AND label_id = ?",
            .{ @as(i64, @intCast(game_thread_id)), label_id },
        ) catch return self.dbFail();
    }

    /// Label ids assigned to a game. Caller frees the slice via `alloc.free`.
    pub fn labelsForGame(self: *Library, game_thread_id: u64) errs.Error![]i64 {
        var out: std.ArrayList(i64) = .empty;
        errdefer out.deinit(self.alloc);
        var rows = self.conn.inner.rows(
            "SELECT label_id FROM game_labels WHERE game_thread_id = ?",
            .{@as(i64, @intCast(game_thread_id))},
        ) catch return self.dbFail();
        defer rows.deinit();
        while (rows.next()) |r| out.append(self.alloc, r.int(0)) catch return errs.Error.OutOfMemory;
        return out.toOwnedSlice(self.alloc) catch errs.Error.OutOfMemory;
    }

    /// Game thread ids carrying `label_id`. Caller frees via `alloc.free`.
    /// Used by the library label filter (union across selected labels).
    pub fn gamesForLabel(self: *Library, label_id: i64) errs.Error![]u64 {
        var out: std.ArrayList(u64) = .empty;
        errdefer out.deinit(self.alloc);
        var rows = self.conn.inner.rows(
            "SELECT game_thread_id FROM game_labels WHERE label_id = ?",
            .{label_id},
        ) catch return self.dbFail();
        defer rows.deinit();
        while (rows.next()) |r| out.append(self.alloc, @intCast(r.int(0))) catch return errs.Error.OutOfMemory;
        return out.toOwnedSlice(self.alloc) catch errs.Error.OutOfMemory;
    }

    // ----- universal (engine-wide) mods -----

    pub fn createUniversalMod(self: *Library, name: []const u8, engine: dom.Engine, modfile_path: []const u8, now: i64) errs.Error!i64 {
        self.conn.inner.exec(
            "INSERT INTO universal_mods (name, engine, modfile_path, created_at) VALUES (?, ?, ?, ?)",
            .{ name, @tagName(engine), modfile_path, now },
        ) catch return self.dbFail();
        return self.conn.inner.lastInsertedRowId();
    }

    pub fn deleteUniversalMod(self: *Library, id: i64) errs.Error!void {
        self.conn.inner.exec("DELETE FROM game_universal_mod_disabled WHERE universal_mod_id = ?", .{id}) catch
            return errs.Error.DatabaseError;
        self.conn.inner.exec("DELETE FROM universal_mods WHERE id = ?", .{id}) catch
            return errs.Error.DatabaseError;
    }

    /// All universal mods (or just one engine's when `engine` is non-null),
    /// name-sorted. Caller frees via `freeUniversalMods`.
    pub fn listUniversalMods(self: *Library, engine: ?dom.Engine) errs.Error![]dom.UniversalMod {
        var out: std.ArrayList(dom.UniversalMod) = .empty;
        errdefer {
            for (out.items) |m| {
                self.alloc.free(m.name);
                self.alloc.free(m.modfile_path);
            }
            out.deinit(self.alloc);
        }
        var rows = if (engine) |e|
            self.conn.inner.rows(
                "SELECT id, name, engine, modfile_path, created_at, enabled FROM universal_mods WHERE engine = ? ORDER BY name COLLATE NOCASE",
                .{@tagName(e)},
            ) catch return errs.Error.DatabaseError
        else
            self.conn.inner.rows(
                "SELECT id, name, engine, modfile_path, created_at, enabled FROM universal_mods ORDER BY name COLLATE NOCASE",
                .{},
            ) catch return self.dbFail();
        defer rows.deinit();
        while (rows.next()) |r| {
            const name = self.alloc.dupe(u8, r.text(1)) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(name);
            const path = self.alloc.dupe(u8, r.text(3)) catch return errs.Error.OutOfMemory;
            out.append(self.alloc, .{
                .id = r.int(0),
                .name = name,
                .engine = std.meta.stringToEnum(dom.Engine, r.text(2)) orelse .unknown,
                .modfile_path = path,
                .created_at = r.int(4),
                .enabled = r.int(5) != 0,
            }) catch return errs.Error.OutOfMemory;
        }
        return out.toOwnedSlice(self.alloc) catch errs.Error.OutOfMemory;
    }

    pub fn freeUniversalMods(self: *Library, mods: []dom.UniversalMod) void {
        for (mods) |m| {
            self.alloc.free(m.name);
            self.alloc.free(m.modfile_path);
        }
        self.alloc.free(mods);
    }

    pub fn setUniversalModDisabled(self: *Library, game_thread_id: u64, mod_id: i64, disabled: bool) errs.Error!void {
        if (disabled) {
            self.conn.inner.exec(
                "INSERT OR IGNORE INTO game_universal_mod_disabled (game_thread_id, universal_mod_id) VALUES (?, ?)",
                .{ @as(i64, @intCast(game_thread_id)), mod_id },
            ) catch return self.dbFail();
        } else {
            self.conn.inner.exec(
                "DELETE FROM game_universal_mod_disabled WHERE game_thread_id = ? AND universal_mod_id = ?",
                .{ @as(i64, @intCast(game_thread_id)), mod_id },
            ) catch return self.dbFail();
        }
    }

    pub fn isUniversalModDisabled(self: *Library, game_thread_id: u64, mod_id: i64) errs.Error!bool {
        const row = self.conn.inner.row(
            "SELECT 1 FROM game_universal_mod_disabled WHERE game_thread_id = ? AND universal_mod_id = ?",
            .{ @as(i64, @intCast(game_thread_id)), mod_id },
        ) catch return self.dbFail();
        if (row) |r| {
            var rr = r;
            rr.deinit();
            return true;
        }
        return false;
    }

    /// Flip a universal mod's global enabled flag.
    pub fn setUniversalModEnabled(self: *Library, mod_id: i64, enabled: bool) errs.Error!void {
        self.conn.inner.exec(
            "UPDATE universal_mods SET enabled = ? WHERE id = ?",
            .{ @as(i64, if (enabled) 1 else 0), mod_id },
        ) catch return self.dbFail();
    }

    /// How many games have opted out of a given universal mod.
    pub fn countDisabledForMod(self: *Library, mod_id: i64) errs.Error!u32 {
        const row = self.conn.inner.row(
            "SELECT count(*) FROM game_universal_mod_disabled WHERE universal_mod_id = ?",
            .{mod_id},
        ) catch return self.dbFail();
        if (row) |r| {
            var rr = r;
            defer rr.deinit();
            return @intCast(rr.int(0));
        }
        return 0;
    }

    pub fn setGameModBackupMode(self: *Library, thread_id: u64, mode: dom.BackupModePref) errs.Error!void {
        self.conn.inner.exec(
            "UPDATE games SET mod_backup_mode = ? WHERE f95_thread_id = ?",
            .{ @tagName(mode), @as(i64, @intCast(thread_id)) },
        ) catch return self.dbFail();
    }

    pub fn getGame(self: *Library, thread_id: u64) errs.Error!?dom.Game {
        var rows = self.conn.inner.rows(
            \\SELECT f95_thread_id, name, developer, latest_version,
            \\       rating, vote_count, completion_status, engine,
            \\       sandbox, last_played_at, total_playtime_s, created_at,
            \\       notes, tags_json, last_scraped_at, screenshots_json,
            \\       description_md, changelog_md, reviews_md, download_links_json,
            \\       dev_status, downloads_md, last_updated_at, thread_info_md,
            \\       censored, auto_update, mod_backup_mode, last_indexer_change,
            \\       last_indexer_parser_version, last_played_version, pinned_version, status_changed_at
            \\FROM games WHERE f95_thread_id = ?
        , .{@as(i64, @intCast(thread_id))}) catch return self.dbFail();
        defer rows.deinit();
        if (rows.next()) |r| {
            return try hydrateGame(self.alloc, r);
        }
        return null;
    }

    /// Returns a heap-allocated slice of Games. Caller frees via
    /// `freeGames(alloc, slice)` so all duplicated strings are released.
    pub fn listGames(self: *Library) errs.Error![]dom.Game {
        var out: std.ArrayList(dom.Game) = .empty;
        errdefer out.deinit(self.alloc);

        var rows = self.conn.inner.rows(
            \\SELECT f95_thread_id, name, developer, latest_version,
            \\       rating, vote_count, completion_status, engine,
            \\       sandbox, last_played_at, total_playtime_s, created_at,
            \\       notes, tags_json, last_scraped_at, screenshots_json,
            \\       description_md, changelog_md, reviews_md, download_links_json,
            \\       dev_status, downloads_md, last_updated_at, thread_info_md,
            \\       censored, auto_update, mod_backup_mode, last_indexer_change,
            \\       last_indexer_parser_version, last_played_version, pinned_version, status_changed_at
            \\FROM games ORDER BY name COLLATE NOCASE
        , .{}) catch return self.dbFail();
        defer rows.deinit();

        while (rows.next()) |r| {
            const g = try hydrateGame(self.alloc, r);
            out.append(self.alloc, g) catch return errs.Error.OutOfMemory;
        }
        return out.toOwnedSlice(self.alloc) catch return errs.Error.OutOfMemory;
    }

    pub fn freeGame(self: *Library, g: dom.Game) void {
        self.alloc.free(g.name);
        if (g.developer) |s| self.alloc.free(s);
        if (g.latest_version) |s| self.alloc.free(s);
        if (g.notes) |s| self.alloc.free(s);
        if (g.description_md) |s| self.alloc.free(s);
        if (g.changelog_md) |s| self.alloc.free(s);
        if (g.reviews_md) |s| self.alloc.free(s);
        if (g.downloads_md) |s| self.alloc.free(s);
        if (g.thread_info_md) |s| self.alloc.free(s);
        if (g.last_played_version) |s| self.alloc.free(s);
        if (g.pinned_version) |s| self.alloc.free(s);
        self.freeTags(g.tags);
        self.freeTags(g.screenshots);
        self.freeTags(g.download_links);
    }

    pub fn freeGames(self: *Library, games: []dom.Game) void {
        for (games) |g| self.freeGame(g);
        self.alloc.free(games);
    }

    fn freeTags(self: *Library, tags: []const []const u8) void {
        for (tags) |t| self.alloc.free(t);
        // Empty tag slices are conventionally `&.{}` (a comptime sentinel
        // with no heap backing), per `std.ArrayList.toOwnedSlice` and
        // `Allocator.alloc(T, 0)`. Skip free in that case to avoid
        // undefined behavior on the sentinel.
        if (tags.len > 0) self.alloc.free(tags);
    }

    pub fn deleteGame(self: *Library, thread_id: u64) errs.Error!void {
        self.conn.inner.exec("DELETE FROM games WHERE f95_thread_id = ?", .{@as(i64, @intCast(thread_id))}) catch return self.dbFail();
    }

    /// True when a game row with this thread id exists.
    pub fn gameExists(self: *Library, thread_id: u64) errs.Error!bool {
        var row = (self.conn.inner.row("SELECT 1 FROM games WHERE f95_thread_id = ?", .{@as(i64, @intCast(thread_id))}) catch return self.dbFail()) orelse return false;
        row.deinit();
        return true;
    }

    /// Re-key a game to a different F95 thread id, carrying ALL of its per-game
    /// rows across — installs, mods, play sessions, labels and per-game mod
    /// overrides. Used when the user points an existing (often folder-imported
    /// or mis-keyed) game at the correct F95 thread so a real sync can populate
    /// it. Refuses with `ThreadIdInUse` if `new_tid` is already a game (we don't
    /// merge two libraries' worth of history), `GameNotFound` if `old_tid` isn't
    /// one, and no-ops when they're equal.
    ///
    /// FK enforcement is dropped for the move: `installs`/`mods` reference
    /// `games(f95_thread_id)` and SQLite checks that immediately, while the
    /// `foreign_keys` pragma is a no-op inside a transaction — so we toggle it
    /// off around the whole re-point and restore it no matter how we leave. The
    /// table list below is every table that carries `game_thread_id`; miss one
    /// and its rows would orphan, so keep it in sync with the schema.
    pub fn changeThreadId(self: *Library, old_tid: u64, new_tid: u64) errs.Error!void {
        if (old_tid == new_tid) return;
        if (!try self.gameExists(old_tid)) return errs.Error.GameNotFound;
        if (try self.gameExists(new_tid)) return errs.Error.ThreadIdInUse;

        self.conn.exec("PRAGMA foreign_keys = OFF") catch return self.dbFail();
        defer self.conn.exec("PRAGMA foreign_keys = ON") catch {};

        self.beginTx() catch return self.dbFail();
        errdefer self.rollbackTx() catch {};

        const o: i64 = @intCast(old_tid);
        const n: i64 = @intCast(new_tid);
        inline for (.{ "games", "installs", "mods", "play_sessions", "game_labels", "game_universal_mod_disabled" }) |tbl| {
            const col = if (comptime std.mem.eql(u8, tbl, "games")) "f95_thread_id" else "game_thread_id";
            self.conn.inner.exec("UPDATE " ++ tbl ++ " SET " ++ col ++ " = ? WHERE " ++ col ++ " = ?", .{ n, o }) catch return self.dbFail();
        }

        self.commitTx() catch return self.dbFail();
        self.install_generation +%= 1;
    }

    /// Set (or clear, when `path` is null) a game's manual saves-folder
    /// override. When set, the Open/Backup/Import-saves actions target this
    /// folder instead of the auto-derived per-game sandbox HOME.
    pub fn setGameSavePath(self: *Library, thread_id: u64, path: ?[]const u8) errs.Error!void {
        self.conn.inner.exec(
            "UPDATE games SET save_path_override = ? WHERE f95_thread_id = ?",
            .{ path, @as(i64, @intCast(thread_id)) },
        ) catch return self.dbFail();
    }

    /// The game's manual saves-folder override, or null when unset. Caller
    /// frees a non-null result.
    pub fn savePathOverride(self: *Library, thread_id: u64) errs.Error!?[]u8 {
        var row = (self.conn.inner.row(
            "SELECT save_path_override FROM games WHERE f95_thread_id = ?",
            .{@as(i64, @intCast(thread_id))},
        ) catch return self.dbFail()) orelse return null;
        defer row.deinit();
        const val = row.nullableText(0) orelse return null;
        if (val.len == 0) return null;
        return self.alloc.dupe(u8, val) catch return errs.Error.OutOfMemory;
    }

    /// True when a game has a manual saves-folder override set. No allocation —
    /// used by the detail menu to decide whether to show "Use default".
    pub fn hasSavePathOverride(self: *Library, thread_id: u64) errs.Error!bool {
        var row = (self.conn.inner.row(
            "SELECT save_path_override FROM games WHERE f95_thread_id = ? AND save_path_override IS NOT NULL AND save_path_override <> ''",
            .{@as(i64, @intCast(thread_id))},
        ) catch return self.dbFail()) orelse return false;
        row.deinit();
        return true;
    }

    /// Apply scrape result to an in-memory `Game` whose strings are
    /// already owned by `self.alloc` (i.e. came out of `listGames`).
    /// Replaces name/developer/latest_version with fresh `self.alloc`-
    /// owned dups; updates rating/vote_count; persists.
    ///
    /// Borrowed inputs: `name`, `version`, `developer`, `cover_url` are
    /// caller-owned; we copy what we need.
    pub const ScrapeUpdate = struct {
        name: ?[]const u8 = null,
        version: ?[]const u8 = null,
        developer: ?[]const u8 = null,
        rating: ?f32 = null,
        vote_count: ?u32 = null,
        engine: ?dom.Engine = null,
        dev_status: ?dom.DevStatus = null,
        last_updated_at: ?i64 = null,
        thread_info_md: ?[]const u8 = null,
        censored: ?dom.CensoredState = null,
        /// When non-null, replaces the stored tag list wholesale.
        /// Empty slice clears tags. Caller-borrowed; we dupe.
        tags: ?[]const []const u8 = null,
        /// Same shape as `tags`: replace screenshot URL list wholesale.
        screenshots: ?[]const []const u8 = null,
        /// Plain-text scrape outputs. Empty string clears (stored NULL).
        description_md: ?[]const u8 = null,
        changelog_md: ?[]const u8 = null,
        reviews_md: ?[]const u8 = null,
        downloads_md: ?[]const u8 = null,
        /// Each entry pre-formatted as `<host>\t<url>\t<label>`. Empty
        /// slice clears.
        download_links: ?[]const []const u8 = null,
        /// Unix seconds — caller stamps via `Io.Clock.real`. Library
        /// stays clock-free.
        last_scraped_at: ?i64 = null,
        /// F95Indexer `/fast` last-change timestamp. Set by the indexer
        /// refresh worker after a successful `/fast` response so the
        /// next refresh can skip `/full` when nothing moved server-side.
        /// Scraper path leaves this null.
        last_indexer_change: ?i64 = null,
        /// f95_indexer mapping version at the time of this update.
        /// Worker stamps this after a successful /full so subsequent
        /// refreshes can detect mapping changes (mirrors F95Checker's
        /// `last_check_version`).
        last_indexer_parser_version: ?u32 = null,
    };

    pub fn applyScrape(self: *Library, game: *dom.Game, upd: ScrapeUpdate) errs.Error!void {
        if (upd.name) |new_name| {
            const dup = self.alloc.dupe(u8, new_name) catch return errs.Error.OutOfMemory;
            self.alloc.free(game.name);
            game.name = dup;
        }
        if (upd.version) |new_v| {
            const dup = self.alloc.dupe(u8, new_v) catch return errs.Error.OutOfMemory;
            if (game.latest_version) |old| self.alloc.free(old);
            game.latest_version = dup;
        }
        if (upd.developer) |new_d| {
            const dup = self.alloc.dupe(u8, new_d) catch return errs.Error.OutOfMemory;
            if (game.developer) |old| self.alloc.free(old);
            game.developer = dup;
        }
        if (upd.rating) |r| game.rating = r;
        if (upd.vote_count) |c| game.vote_count = c;
        if (upd.engine) |e| game.engine = e;
        if (upd.dev_status) |d| {
            // Record when the developer status actually flips (Ongoing →
            // Completed/Abandoned/…) so the UI can flag it. Stamped with the
            // scrape time (the library stays clock-free).
            if (d != game.dev_status) {
                game.status_changed_at = upd.last_scraped_at orelse game.status_changed_at;
            }
            game.dev_status = d;
        }
        if (upd.last_updated_at) |t| game.last_updated_at = t;
        if (upd.thread_info_md) |s| {
            try self.replaceOptionalString(&game.thread_info_md, s);
        }
        if (upd.censored) |c| game.censored = c;
        if (upd.last_scraped_at) |t| game.last_scraped_at = t;
        if (upd.tags) |new_tags| {
            game.tags = try self.dupStringList(new_tags, game.tags);
        }
        if (upd.screenshots) |new_shots| {
            game.screenshots = try self.dupStringList(new_shots, game.screenshots);
        }
        if (upd.description_md) |s| {
            try self.replaceOptionalString(&game.description_md, s);
        }
        if (upd.changelog_md) |s| {
            try self.replaceOptionalString(&game.changelog_md, s);
        }
        if (upd.reviews_md) |s| {
            try self.replaceOptionalString(&game.reviews_md, s);
        }
        if (upd.downloads_md) |s| {
            try self.replaceOptionalString(&game.downloads_md, s);
        }
        if (upd.download_links) |new_links| {
            game.download_links = try self.dupStringList(new_links, game.download_links);
        }
        if (upd.last_indexer_change) |t| game.last_indexer_change = t;
        if (upd.last_indexer_parser_version) |v| game.last_indexer_parser_version = v;
        try self.upsertGame(game);
    }

    /// Replace a `?[]const u8` field on a Game with a fresh
    /// `self.alloc`-owned copy of `src`. Empty `src` clears to null.
    fn replaceOptionalString(self: *Library, target: *?[]const u8, src: []const u8) errs.Error!void {
        if (src.len == 0) {
            if (target.*) |old| self.alloc.free(old);
            target.* = null;
            return;
        }
        const dup = self.alloc.dupe(u8, src) catch return errs.Error.OutOfMemory;
        if (target.*) |old| self.alloc.free(old);
        target.* = dup;
    }

    /// Helper: dup a slice-of-strings into `self.alloc`-owned storage,
    /// then free the previously-owned `old` slice. Allocates the new
    /// list before touching `old` so OOM doesn't leave the caller
    /// with a dangling field.
    fn dupStringList(
        self: *Library,
        src: []const []const u8,
        old: []const []const u8,
    ) errs.Error![]const []const u8 {
        const dup_outer = self.alloc.alloc([]const u8, src.len) catch return errs.Error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (dup_outer[0..filled]) |t| self.alloc.free(t);
            self.alloc.free(dup_outer);
        }
        for (src) |t| {
            dup_outer[filled] = self.alloc.dupe(u8, t) catch return errs.Error.OutOfMemory;
            filled += 1;
        }
        self.freeTags(old);
        return dup_outer;
    }

    /// Replace `game.notes` with a `self.alloc`-owned copy of `text` and
    /// persist. Pass an empty slice to clear (stored as NULL in DB).
    pub fn setNotes(self: *Library, game: *dom.Game, text: []const u8) errs.Error!void {
        if (text.len == 0) {
            if (game.notes) |old| self.alloc.free(old);
            game.notes = null;
        } else {
            const dup = self.alloc.dupe(u8, text) catch return errs.Error.OutOfMemory;
            if (game.notes) |old| self.alloc.free(old);
            game.notes = dup;
        }
        try self.upsertGame(game);
    }

    /// Manual edit of a game's identity fields — for orphaned imports or
    /// non-F95 games the scraper can't fill in. `name` is required; empty
    /// `developer`/`version` clear the field to null. Mirrors applyScrape's
    /// per-field dup/free ownership, then upserts.
    pub fn setGameInfo(
        self: *Library,
        game: *dom.Game,
        name: []const u8,
        developer: []const u8,
        version: []const u8,
        engine: dom.Engine,
    ) errs.Error!void {
        if (name.len > 0) {
            const dup = self.alloc.dupe(u8, name) catch return errs.Error.OutOfMemory;
            self.alloc.free(game.name);
            game.name = dup;
        }
        try replaceOptional(self, &game.developer, developer);
        try replaceOptional(self, &game.latest_version, version);
        game.engine = engine;
        try self.upsertGame(game);
    }

    /// Set a `?[]const u8` field to an alloc-owned copy of `src`, or null
    /// when `src` is empty. Frees the previous value.
    fn replaceOptional(self: *Library, target: *?[]const u8, src: []const u8) errs.Error!void {
        if (src.len == 0) {
            if (target.*) |old| self.alloc.free(old);
            target.* = null;
        } else {
            const dup = self.alloc.dupe(u8, src) catch return errs.Error.OutOfMemory;
            if (target.*) |old| self.alloc.free(old);
            target.* = dup;
        }
    }

    /// Write a consistent snapshot of the whole DB to `dest_path` via
    /// `VACUUM INTO` — safe with an open connection + WAL (unlike a raw file
    /// copy, which can capture a torn mid-write state). `dest_path` must not
    /// already exist. App-controlled path; single quotes are escaped anyway.
    pub fn backupTo(self: *Library, alloc: std.mem.Allocator, dest_path: []const u8) errs.Error!void {
        const q_count = std.mem.count(u8, dest_path, "'");
        const escaped = alloc.alloc(u8, dest_path.len + q_count) catch return errs.Error.OutOfMemory;
        defer alloc.free(escaped);
        var j: usize = 0;
        for (dest_path) |c| {
            escaped[j] = c;
            j += 1;
            if (c == '\'') {
                escaped[j] = '\'';
                j += 1;
            }
        }
        const sql = std.fmt.allocPrint(alloc, "VACUUM INTO '{s}'", .{escaped}) catch return errs.Error.OutOfMemory;
        defer alloc.free(sql);
        self.conn.inner.exec(sql, .{}) catch return self.dbFail();
    }

    pub fn ratingStats(self: *Library) errs.Error!struct { mean: f32, count: u32 } {
        var rows = self.conn.inner.rows(
            \\SELECT COALESCE(AVG(rating), 3.5), COUNT(rating)
            \\FROM games WHERE rating IS NOT NULL
        , .{}) catch return self.dbFail();
        defer rows.deinit();
        if (rows.next()) |r| {
            return .{
                .mean = @as(f32, @floatCast(r.float(0))),
                .count = @as(u32, @intCast(r.int(1))),
            };
        }
        return .{ .mean = 3.5, .count = 0 };
    }

    // -- installs --

    /// INSERT OR REPLACE the row. UUID-style id is generated by the
    /// caller (typically Round-35's post-download install hook). The
    /// schema's `UNIQUE(game_thread_id, version)` keeps duplicates out
    /// when the user re-installs the same version.
    pub fn upsertInstall(self: *Library, i: *const dom.Install) errs.Error!void {
        const id_slice = i.id[0..];
        const source_text: []const u8 = switch (i.source) {
            .recipe => "recipe",
            .manual => "manual",
            .rpdl => "rpdl",
            .imported => "imported",
        };
        const sha_slice: ?[]const u8 = if (i.archive_sha256) |*h| h[0..] else null;
        self.conn.inner.exec(
            \\INSERT OR REPLACE INTO installs
            \\  (id, game_thread_id, version, install_path, executable, launch_args,
            \\   recipe_id, installed_at, name, source, archive_sha256)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        , .{
            id_slice,
            @as(i64, @intCast(i.game_thread_id)),
            i.version,
            i.install_path,
            i.executable orelse null,
            i.launch_args orelse null,
            i.recipe_id,
            i.installed_at,
            i.name orelse null,
            source_text,
            sha_slice,
        }) catch return self.dbFail();
        self.install_generation +%= 1;
    }

    /// True when ANY game already has an install registered at this path.
    /// `installs.install_path` is UNIQUE, so registering a second one there
    /// via `upsertInstall`'s INSERT OR REPLACE would silently delete the other
    /// game's row — `registerManualInstall` checks this first to refuse instead.
    pub fn installPathInUse(self: *Library, install_path: []const u8) errs.Error!bool {
        var row = (self.conn.inner.row("SELECT 1 FROM installs WHERE install_path = ?", .{install_path}) catch return self.dbFail()) orelse return false;
        row.deinit();
        return true;
    }

    fn installVersionExists(self: *Library, game_thread_id: u64, version: []const u8) errs.Error!bool {
        var row = (self.conn.inner.row(
            "SELECT 1 FROM installs WHERE game_thread_id = ? AND version = ?",
            .{ @as(i64, @intCast(game_thread_id)), version },
        ) catch return self.dbFail()) orelse return false;
        row.deinit();
        return true;
    }

    /// Register an already-installed folder as a `.manual` install for
    /// `game_thread_id` — the "I downloaded this game myself, point f69 at it"
    /// path. Non-destructive by design: refuses with `InstallPathInUse` when the
    /// folder already belongs to a game (never steals it via the UNIQUE(path)
    /// REPLACE), and `InstallVersionExists` when this game already has an install
    /// labelled `version` (that row's `id` may carry mod links we must not drop).
    /// `executable` is left null — the launch path auto-picks the game binary
    /// inside the folder, same as a downloaded install.
    pub fn registerManualInstall(
        self: *Library,
        game_thread_id: u64,
        version: []const u8,
        install_path: []const u8,
        id: [36]u8,
        installed_at: i64,
    ) errs.Error!void {
        if (try self.installPathInUse(install_path)) return errs.Error.InstallPathInUse;
        if (try self.installVersionExists(game_thread_id, version)) return errs.Error.InstallVersionExists;
        try self.upsertInstall(&.{
            .id = id,
            .game_thread_id = game_thread_id,
            .version = version,
            .install_path = install_path,
            .recipe_id = "",
            .installed_at = installed_at,
            .source = .manual,
        });
    }

    /// Newest install first by VERSION (not `installed_at`). The
    /// picker dropdown shows them in this order and Launch always
    /// targets `installs[0]` — so the user gets a single rule:
    /// "the top of the dropdown is what runs." installed_at breaks
    /// ties when two installs share an equivalent version (e.g.
    /// vanilla v0.20 + modded v0.20 — the most recent one ranks
    /// first within the tie). Caller frees via `freeInstalls`.
    pub fn listInstalls(self: *Library, game_thread_id: u64) errs.Error![]dom.Install {
        var out: std.ArrayList(dom.Install) = .empty;
        // Each hydrateInstall dupes 5+ strings onto self.alloc; on
        // mid-loop OOM (or rows.next failure) we have to walk what's
        // already appended and free their inner strings, not just
        // the ArrayList backing store.
        errdefer {
            for (out.items) |i| self.freeInstall(i);
            out.deinit(self.alloc);
        }

        // SQL fetch in any order — sort happens in Zig because
        // version strings need canonical parsing
        // (`util_version.compare`) that SQLite can't do.
        var rows = self.conn.inner.rows(
            \\SELECT id, game_thread_id, version, install_path,
            \\       executable, launch_args, recipe_id, installed_at,
            \\       name, source, archive_sha256
            \\FROM installs WHERE game_thread_id = ?
        , .{@as(i64, @intCast(game_thread_id))}) catch return self.dbFail();
        defer rows.deinit();

        while (rows.next()) |r| {
            const inst = try hydrateInstall(self.alloc, r);
            // If append OOMs, `inst` is on the stack with freshly
            // alloc'd strings the errdefer above wouldn't see — free
            // it explicitly here before returning the error.
            out.append(self.alloc, inst) catch |e| {
                self.freeInstall(inst);
                return switch (e) {
                    error.OutOfMemory => errs.Error.OutOfMemory,
                };
            };
        }
        const slice = out.toOwnedSlice(self.alloc) catch return errs.Error.OutOfMemory;
        std.mem.sort(dom.Install, slice, {}, installNewerFirst);
        return slice;
    }

    /// Per-frame cache primitive: one SELECT pulls every install
    /// row, grouped into `(game_thread_id → "latest version string")`.
    /// "Latest" is decided in Zig via `util_version.compare` (same
    /// comparator `installNewerFirst` uses) so this matches the
    /// per-game `latestInstallForGame` semantics — but pays one query
    /// up front instead of one per visible card.
    ///
    /// `arena` is expected to be a per-frame arena (dvui's
    /// `currentWindow().arena()`); the version strings + the
    /// HashMap's internal buckets all allocate from it and get
    /// reclaimed when the arena resets at frame end. **Do not pass
    /// a long-lived allocator** — the returned map is keyed on
    /// per-frame storage and reads next frame will dangle.
    ///
    /// Before this method existed, the Library screen called
    /// `latestInstallForGame` once per visible card per frame
    /// (60+ SQLite prepare+step+hydrate cycles); now it's one query
    /// + N HashMap lookups.
    pub fn latestInstallVersionMap(
        self: *Library,
        arena: std.mem.Allocator,
    ) errs.Error!std.AutoHashMap(u64, []const u8) {
        var map = std.AutoHashMap(u64, []const u8).init(arena);
        var rows = self.conn.inner.rows(
            "SELECT game_thread_id, version FROM installs",
            .{},
        ) catch return self.dbFail();
        defer rows.deinit();
        while (rows.next()) |r| {
            const tid: u64 = @intCast(r.int(0));
            const ver_src = r.text(1);
            const ver_dup = arena.dupe(u8, ver_src) catch return errs.Error.OutOfMemory;
            const gop = map.getOrPut(tid) catch return errs.Error.OutOfMemory;
            if (!gop.found_existing) {
                gop.value_ptr.* = ver_dup;
            } else if (version_mod.compare(gop.value_ptr.*, ver_dup) == .lt) {
                // We have a newer version. Free the older pointer
                // BEFORE overwriting — the doc string promised "pass
                // a short-lived arena" but the production caller
                // (`ui.zig`'s snapshot-rebuild path) passes a regular
                // allocator. With an arena `free` is a no-op so this
                // is safe either way.
                arena.free(gop.value_ptr.*);
                gop.value_ptr.* = ver_dup;
            } else {
                // Older version arrived second — drop the freshly
                // duped string we won't be using. Same arena-vs-real
                // logic as above.
                arena.free(ver_dup);
            }
        }
        return map;
    }

    /// One SELECT DISTINCT over the installs table — returns every
    /// `game_thread_id` that has at least one install row. The UI
    /// builds an `AutoHashMap(u64, void)` from this once per frame to
    /// drive the "installed" badge on cards and the
    /// installed-state filter. Cheap query (the installs table is
    /// small + indexed).
    pub fn fetchInstalledThreadIds(self: *Library) errs.Error![]u64 {
        var out: std.ArrayList(u64) = .empty;
        errdefer out.deinit(self.alloc);

        var rows = self.conn.inner.rows(
            "SELECT DISTINCT game_thread_id FROM installs",
            .{},
        ) catch return self.dbFail();
        defer rows.deinit();
        while (rows.next()) |r| {
            const tid: i64 = r.int(0);
            out.append(self.alloc, @intCast(tid)) catch return errs.Error.OutOfMemory;
        }
        return out.toOwnedSlice(self.alloc) catch errs.Error.OutOfMemory;
    }

    /// Highest-version install for a game (same ordering as
    /// `listInstalls`) or null when the table has no row for it.
    /// Used by the InstallDot heuristic and as the Launch fallback
    /// when the detail-page picker hasn't recorded a selection yet
    /// (e.g. card-click → Launch keybind before the detail page
    /// renders). Pays for one extra hydration pass vs the previous
    /// `LIMIT 1` query, but the installs table is small per-game.
    pub fn latestInstallForGame(self: *Library, game_thread_id: u64) errs.Error!?dom.Install {
        const installs = try self.listInstalls(game_thread_id);
        if (installs.len == 0) {
            self.alloc.free(installs);
            return null;
        }
        // Keep the head; free everything else.
        const head = installs[0];
        for (installs[1..]) |rest| self.freeInstall(rest);
        self.alloc.free(installs);
        return head;
    }

    /// Free strings in a single Install allocated via `listInstalls`
    /// or `latestInstallForGame`.
    pub fn freeInstall(self: *Library, i: dom.Install) void {
        self.alloc.free(i.version);
        self.alloc.free(i.install_path);
        if (i.executable) |s| self.alloc.free(s);
        if (i.launch_args) |s| self.alloc.free(s);
        self.alloc.free(i.recipe_id);
        if (i.name) |s| self.alloc.free(s);
    }

    pub fn freeInstalls(self: *Library, installs: []dom.Install) void {
        for (installs) |i| self.freeInstall(i);
        if (installs.len > 0) self.alloc.free(installs);
    }

    pub fn deleteInstall(self: *Library, install_id: []const u8) errs.Error!void {
        self.conn.inner.exec("DELETE FROM installs WHERE id = ?", .{install_id}) catch return self.dbFail();
        self.install_generation +%= 1;
    }

    /// Write a new `name` value on an existing install row. Pass null
    /// to clear the name (picker label falls back to bare version).
    /// Used by the detail-page ⋯ → Rename action.
    pub fn updateInstallName(self: *Library, install_id: []const u8, new_name: ?[]const u8) errs.Error!void {
        self.conn.inner.exec("UPDATE installs SET name = ? WHERE id = ?", .{
            new_name,
            install_id,
        }) catch return self.dbFail();
        self.install_generation +%= 1;
    }

    /// Per-install custom launch override: the executable/command to run instead
    /// of the heuristic launcher. Null clears it (back to auto).
    pub fn setInstallExecutable(self: *Library, install_id: []const u8, exe: ?[]const u8) errs.Error!void {
        self.conn.inner.exec("UPDATE installs SET executable = ? WHERE id = ?", .{
            exe,
            install_id,
        }) catch return self.dbFail();
        self.install_generation +%= 1;
    }

    /// Relocate the games library: rewrite every install_path that sits under
    /// `old_root` so it sits under `new_root` instead. Boundary-aware — only a
    /// path equal to `old_root` or starting with `old_root || '/'` is rewritten
    /// (so a sibling like `/x/library-old/…` is left alone). Moves no files;
    /// repoints the DB links only. Returns the number of rows rewritten.
    pub fn relocateInstalls(self: *Library, old_root: []const u8, new_root: []const u8) errs.Error!usize {
        self.conn.inner.exec(
            \\UPDATE installs
            \\SET install_path = ?1 || substr(install_path, length(?2) + 1)
            \\WHERE install_path = ?2
            \\   OR substr(install_path, 1, length(?2) + 1) = ?2 || '/'
        , .{ new_root, old_root }) catch return self.dbFail();
        const n: usize = @intCast(@max(self.conn.inner.changes(), 0));
        self.install_generation +%= 1;
        return n;
    }

    /// Per-install custom launch arguments (raw string; tokenized at launch).
    pub fn setInstallLaunchArgs(self: *Library, install_id: []const u8, args: ?[]const u8) errs.Error!void {
        self.conn.inner.exec("UPDATE installs SET launch_args = ? WHERE id = ?", .{
            args,
            install_id,
        }) catch return self.dbFail();
        self.install_generation +%= 1;
    }

    // TODO: mods table — upsertMod / listMods / setModInstalls /
    // listModInstalls were no-op stubs with zero callers; dropped.

    // -- compat fixes applied to an install --
    //
    // Library stores raw rows; the compat service (which knows the
    // BackupRecord shape) converts to/from JSON. Keeping Library
    // compat-agnostic avoids a circular module dependency.

    pub const AppliedCompatRow = struct {
        recipe_id: []const u8,
        recipe_sha256: []const u8,
        applied_at: i64,
        /// JSON-serialized []BackupRecord. Owned by the same alloc
        /// passed to `listAppliedCompat`; freed via `freeAppliedCompat`.
        backups_json: []const u8,
    };

    pub fn upsertAppliedCompat(
        self: *Library,
        install_id: []const u8,
        recipe_id: []const u8,
        recipe_sha256: []const u8,
        applied_at: i64,
        backups_json: []const u8,
    ) errs.Error!void {
        self.conn.inner.exec(
            \\INSERT INTO applied_compat_fixes
            \\  (install_id, recipe_id, recipe_sha256, applied_at, backups_json)
            \\VALUES (?, ?, ?, ?, ?)
            \\ON CONFLICT(install_id, recipe_id) DO UPDATE SET
            \\  recipe_sha256 = excluded.recipe_sha256,
            \\  applied_at = excluded.applied_at,
            \\  backups_json = excluded.backups_json
        , .{
            install_id,
            recipe_id,
            recipe_sha256,
            applied_at,
            backups_json,
        }) catch return self.dbFail();
    }

    pub fn deleteAppliedCompat(self: *Library, install_id: []const u8, recipe_id: []const u8) errs.Error!void {
        self.conn.inner.exec(
            "DELETE FROM applied_compat_fixes WHERE install_id = ? AND recipe_id = ?",
            .{ install_id, recipe_id },
        ) catch return self.dbFail();
    }

    pub fn listAppliedCompat(self: *Library, install_id: []const u8) errs.Error![]AppliedCompatRow {
        var out: std.ArrayList(AppliedCompatRow) = .empty;
        errdefer {
            for (out.items) |row| self.freeAppliedCompatRow(row);
            out.deinit(self.alloc);
        }
        var rows = self.conn.inner.rows(
            \\SELECT recipe_id, recipe_sha256, applied_at, backups_json
            \\FROM applied_compat_fixes
            \\WHERE install_id = ?
            \\ORDER BY applied_at
        , .{install_id}) catch return self.dbFail();
        defer rows.deinit();
        while (rows.next()) |r| {
            const rid = self.alloc.dupe(u8, r.text(0)) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(rid);
            const sha = self.alloc.dupe(u8, r.text(1)) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(sha);
            const bjson = self.alloc.dupe(u8, r.text(3)) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(bjson);
            out.append(self.alloc, .{
                .recipe_id = rid,
                .recipe_sha256 = sha,
                .applied_at = r.int(2),
                .backups_json = bjson,
            }) catch return errs.Error.OutOfMemory;
        }
        return out.toOwnedSlice(self.alloc) catch errs.Error.OutOfMemory;
    }

    pub fn freeAppliedCompatRow(self: *Library, row: AppliedCompatRow) void {
        self.alloc.free(row.recipe_id);
        self.alloc.free(row.recipe_sha256);
        self.alloc.free(row.backups_json);
    }

    pub fn freeAppliedCompatList(self: *Library, list: []AppliedCompatRow) void {
        for (list) |row| self.freeAppliedCompatRow(row);
        if (list.len > 0) self.alloc.free(list);
    }

    pub const InsertSessionArgs = struct {
        game_thread_id: u64,
        install_id: ?[36]u8 = null,
        version: []const u8,
        started_at: i64,
    };

    /// Open a play_sessions row. Returns the rowid (use it to close
    /// the session later via closeSession).
    pub fn insertSession(self: *Library, args: InsertSessionArgs) errs.Error!i64 {
        const install_id_slice: ?[]const u8 = if (args.install_id) |*id| id[0..] else null;
        self.conn.inner.exec(
            \\INSERT INTO play_sessions
            \\  (game_thread_id, install_id, version, started_at)
            \\VALUES (?, ?, ?, ?)
        ,
            .{
                @as(i64, @intCast(args.game_thread_id)),
                install_id_slice,
                args.version,
                args.started_at,
            },
        ) catch return self.dbFail();
        return self.conn.inner.lastInsertedRowId();
    }

    pub fn listPlaySessions(
        self: *Library,
        game_thread_id: u64,
    ) errs.Error![]dom.PlaySession {
        var rows = self.conn.inner.rows(
            \\SELECT id, game_thread_id, install_id, version,
            \\       started_at, ended_at, duration_s, counts_as_played
            \\FROM play_sessions
            \\WHERE game_thread_id = ?
            \\ORDER BY started_at DESC
        ,
            .{@as(i64, @intCast(game_thread_id))},
        ) catch return self.dbFail();
        defer rows.deinit();

        var out: std.ArrayList(dom.PlaySession) = .empty;
        errdefer {
            for (out.items) |*s| freePlaySessionFields(self.alloc, s);
            out.deinit(self.alloc);
        }
        while (rows.next()) |r| {
            var s: dom.PlaySession = undefined;
            s.id = r.int(0);
            s.game_thread_id = @intCast(r.int(1));
            if (r.nullableText(2)) |t| {
                if (t.len == 36) {
                    var id: [36]u8 = undefined;
                    @memcpy(&id, t);
                    s.install_id = id;
                } else s.install_id = null;
            } else s.install_id = null;
            s.version = self.alloc.dupe(u8, r.text(3)) catch return errs.Error.OutOfMemory;
            s.started_at = r.int(4);
            s.ended_at = r.nullableInt(5);
            s.duration_s = r.nullableInt(6);
            s.counts_as_played = r.int(7) != 0;
            out.append(self.alloc, s) catch {
                // append failed before `s` reached `out.items`, so the
                // errdefer cleanup above won't see this row's dupe.
                self.alloc.free(s.version);
                return errs.Error.OutOfMemory;
            };
        }
        return out.toOwnedSlice(self.alloc) catch return errs.Error.OutOfMemory;
    }

    pub fn freePlaySessions(self: *Library, sessions: []dom.PlaySession) void {
        for (sessions) |*s| freePlaySessionFields(self.alloc, s);
        self.alloc.free(sessions);
    }

    fn freePlaySessionFields(alloc: std.mem.Allocator, s: *dom.PlaySession) void {
        alloc.free(s.version);
    }

    /// Delete one play-session row (journal cleanup). Does NOT retroactively
    /// adjust games.total_playtime_s / last_played_* — those are derived
    /// running totals and self-heal on the next sync/launch; the journal
    /// aggregates recompute from the remaining rows on the next read.
    pub fn deletePlaySession(self: *Library, session_id: i64) errs.Error!void {
        self.conn.inner.exec("DELETE FROM play_sessions WHERE id = ?", .{session_id}) catch return self.dbFail();
    }

    pub const CloseSessionArgs = struct {
        session_id: i64,
        ended_at: i64,
        early_fail: bool,
        min_session_seconds: u32,
    };

    /// Close a play_sessions row. Computes duration_s and counts_as_played
    /// from the args. If counts_as_played, bumps games.total_playtime_s
    /// and games.last_played_at. (last_played_version is handled
    /// separately by setLastPlayedVersionIfNewer — that needs the
    /// util_version comparator which lives in the UI layer.)
    pub fn closeSession(self: *Library, args: CloseSessionArgs) errs.Error!void {
        // Read started_at + game_thread_id so we can compute duration
        // and (conditionally) bump aggregates.
        var rows = self.conn.inner.rows(
            \\SELECT game_thread_id, started_at FROM play_sessions WHERE id = ?
        ,
            .{args.session_id},
        ) catch return self.dbFail();
        defer rows.deinit();
        const r = rows.next() orelse return;
        const game_thread_id: u64 = @intCast(r.int(0));
        const started_at: i64 = r.int(1);

        const duration_s: i64 = @max(0, args.ended_at - started_at);
        const counts_as_played: bool =
            !args.early_fail and duration_s >= @as(i64, args.min_session_seconds);

        self.conn.inner.exec(
            \\UPDATE play_sessions
            \\SET ended_at = ?, duration_s = ?, counts_as_played = ?
            \\WHERE id = ?
        ,
            .{
                args.ended_at,
                duration_s,
                @as(i64, @intFromBool(counts_as_played)),
                args.session_id,
            },
        ) catch return self.dbFail();

        if (counts_as_played) {
            self.conn.inner.exec(
                \\UPDATE games
                \\SET total_playtime_s = total_playtime_s + ?,
                \\    last_played_at   = ?
                \\WHERE f95_thread_id = ?
            ,
                .{
                    duration_s,
                    args.ended_at,
                    @as(i64, @intCast(game_thread_id)),
                },
            ) catch return self.dbFail();
        }
    }

    pub const CompareFn = *const fn (a: []const u8, b: []const u8) std.math.Order;

    /// Set games.last_played_version = version iff the existing value
    /// is NULL or compare(version, existing) == .gt. Comparator is
    /// passed in so library/ stays independent of util_version.
    pub fn setLastPlayedVersionIfNewer(
        self: *Library,
        game_thread_id: u64,
        version: []const u8,
        compare: CompareFn,
    ) errs.Error!void {
        // Read current value.
        var rows = self.conn.inner.rows(
            \\SELECT last_played_version FROM games WHERE f95_thread_id = ?
        ,
            .{@as(i64, @intCast(game_thread_id))},
        ) catch return self.dbFail();
        defer rows.deinit();
        const row = rows.next() orelse return;
        const existing: ?[]const u8 = row.nullableText(0);

        const should_update = existing == null or compare(version, existing.?) == .gt;
        if (!should_update) return;

        self.conn.inner.exec(
            \\UPDATE games SET last_played_version = ? WHERE f95_thread_id = ?
        ,
            .{ version, @as(i64, @intCast(game_thread_id)) },
        ) catch return self.dbFail();
    }
};

/// Parse a 6-hex "RRGGBB" string into packed 0xRRGGBB. Null if malformed.
fn parseHexColor(s: []const u8) ?u32 {
    if (s.len != 6) return null;
    return std.fmt.parseInt(u32, s, 16) catch null;
}

// ----- migrations -----

const Migration = struct {
    id: u32,
    sql: []const u8,
};

const migrations = [_]Migration{
    .{
        .id = 1,
        .sql =
        \\CREATE TABLE IF NOT EXISTS _schema_version (
        \\  id INTEGER PRIMARY KEY,
        \\  hash TEXT NOT NULL,
        \\  applied_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS games (
        \\  f95_thread_id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  developer TEXT,
        \\  cover_url TEXT,
        \\  description_md TEXT,
        \\  tags_json TEXT NOT NULL DEFAULT '[]',
        \\  rating REAL,
        \\  vote_count INTEGER,
        \\  user_rating REAL,
        \\  completion_status TEXT NOT NULL DEFAULT 'not_started',
        \\  engine TEXT NOT NULL DEFAULT 'unknown',
        \\  latest_version TEXT,
        \\  default_install_id TEXT,
        \\  sandbox TEXT NOT NULL DEFAULT 'use_default',
        \\  last_played_at INTEGER,
        \\  total_playtime_s INTEGER NOT NULL DEFAULT 0,
        \\  last_scraped_at INTEGER,
        \\  created_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS installs (
        \\  id TEXT PRIMARY KEY,
        \\  game_thread_id INTEGER NOT NULL REFERENCES games(f95_thread_id) ON DELETE CASCADE,
        \\  version TEXT NOT NULL,
        \\  install_path TEXT NOT NULL UNIQUE,
        \\  executable TEXT,
        \\  launch_args TEXT,
        \\  recipe_id TEXT NOT NULL,
        \\  installed_at INTEGER NOT NULL,
        \\  UNIQUE (game_thread_id, version)
        \\);
        \\CREATE TABLE IF NOT EXISTS mods (
        \\  f95_thread_id INTEGER PRIMARY KEY,
        \\  game_thread_id INTEGER NOT NULL REFERENCES games(f95_thread_id) ON DELETE CASCADE,
        \\  name TEXT NOT NULL,
        \\  author TEXT,
        \\  latest_version TEXT,
        \\  created_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS mod_installs (
        \\  install_id TEXT NOT NULL REFERENCES installs(id) ON DELETE CASCADE,
        \\  mod_thread_id INTEGER NOT NULL REFERENCES mods(f95_thread_id) ON DELETE CASCADE,
        \\  mod_version TEXT NOT NULL,
        \\  load_index INTEGER NOT NULL,
        \\  applied_at INTEGER NOT NULL,
        \\  PRIMARY KEY (install_id, mod_thread_id)
        \\);
        \\CREATE INDEX IF NOT EXISTS games_name ON games(name COLLATE NOCASE);
        \\CREATE INDEX IF NOT EXISTS games_rating ON games(rating);
        \\CREATE INDEX IF NOT EXISTS installs_game ON installs(game_thread_id);
        \\CREATE INDEX IF NOT EXISTS mods_game ON mods(game_thread_id);
        \\CREATE INDEX IF NOT EXISTS mod_installs_install ON mod_installs(install_id);
        ,
    },
    .{
        .id = 2,
        .sql =
        \\ALTER TABLE games ADD COLUMN notes TEXT;
        ,
    },
    .{
        .id = 3,
        .sql =
        \\ALTER TABLE games ADD COLUMN screenshots_json TEXT;
        ,
    },
    .{
        .id = 4,
        .sql =
        \\ALTER TABLE games ADD COLUMN changelog_md TEXT;
        \\ALTER TABLE games ADD COLUMN reviews_md TEXT;
        \\ALTER TABLE games ADD COLUMN download_links_json TEXT;
        ,
    },
    .{
        .id = 5,
        .sql =
        \\ALTER TABLE games ADD COLUMN dev_status TEXT NOT NULL DEFAULT 'unknown';
        ,
    },
    .{
        .id = 6,
        .sql =
        \\ALTER TABLE games ADD COLUMN downloads_md TEXT;
        ,
    },
    .{
        .id = 7,
        .sql =
        \\ALTER TABLE games ADD COLUMN last_updated_at INTEGER;
        ,
    },
    .{
        .id = 8,
        .sql =
        \\ALTER TABLE games ADD COLUMN thread_info_md TEXT;
        ,
    },
    .{
        .id = 9,
        .sql =
        \\ALTER TABLE games ADD COLUMN censored TEXT NOT NULL DEFAULT 'unknown';
        ,
    },
    .{
        .id = 10,
        .sql =
        // Manual-install slice. Three changes in one migration:
        //   1. New columns: name (optional user label), source
        //      (recipe / manual / rpdl), archive_sha256 (hex hash
        //      of the source archive).
        //   2. Drop the UNIQUE(game_thread_id, version) constraint
        //      so a user can keep "0.20 modded" and "0.20 vanilla"
        //      side-by-side. install_path stays UNIQUE — that's
        //      the real on-disk identity.
        // SQLite has no ALTER ... DROP CONSTRAINT, so we recreate
        // the table. PRAGMA foreign_keys=OFF wraps the rebuild so
        // mod_installs' FK doesn't cascade rows away mid-rename.
        \\PRAGMA foreign_keys = OFF;
        \\CREATE TABLE installs_new (
        \\  id TEXT PRIMARY KEY,
        \\  game_thread_id INTEGER NOT NULL REFERENCES games(f95_thread_id) ON DELETE CASCADE,
        \\  version TEXT NOT NULL,
        \\  install_path TEXT NOT NULL UNIQUE,
        \\  executable TEXT,
        \\  launch_args TEXT,
        \\  recipe_id TEXT NOT NULL,
        \\  installed_at INTEGER NOT NULL,
        \\  name TEXT,
        \\  source TEXT NOT NULL DEFAULT 'recipe',
        \\  archive_sha256 TEXT
        \\);
        \\INSERT INTO installs_new
        \\  (id, game_thread_id, version, install_path, executable, launch_args,
        \\   recipe_id, installed_at)
        \\SELECT id, game_thread_id, version, install_path, executable, launch_args,
        \\       recipe_id, installed_at
        \\FROM installs;
        \\DROP TABLE installs;
        \\ALTER TABLE installs_new RENAME TO installs;
        \\CREATE INDEX IF NOT EXISTS installs_game ON installs(game_thread_id);
        \\PRAGMA foreign_keys = ON;
        ,
    },
    .{
        .id = 11,
        .sql =
        // Per-game auto-update override (always / never / use_default).
        // `use_default` defers to the global toggle in Settings.
        \\ALTER TABLE games ADD COLUMN auto_update TEXT NOT NULL DEFAULT 'use_default';
        ,
    },
    .{
        .id = 12,
        .sql =
        // Per-game uninstall safety: `none` (today's behaviour, no
        // pre-overwrite backups) or `copy` (mirror originals so
        // uninstall can restore). Picked via the Mods page dropdown.
        \\ALTER TABLE games ADD COLUMN mod_backup_mode TEXT NOT NULL DEFAULT 'none';
        ,
    },
    .{
        .id = 13,
        .sql =
        // Compat fixes applied to an install. One row per
        // (install_id, recipe_id). `recipe_sha256` lets the UI
        // detect "recipe upgraded since I applied it". `backups_json`
        // is the JSON-serialized []BackupRecord that `undo` needs.
        \\CREATE TABLE IF NOT EXISTS applied_compat_fixes (
        \\  install_id TEXT NOT NULL REFERENCES installs(id) ON DELETE CASCADE,
        \\  recipe_id TEXT NOT NULL,
        \\  recipe_sha256 TEXT NOT NULL,
        \\  applied_at INTEGER NOT NULL,
        \\  backups_json TEXT NOT NULL DEFAULT '[]',
        \\  PRIMARY KEY (install_id, recipe_id)
        \\);
        \\CREATE INDEX IF NOT EXISTS applied_compat_install ON applied_compat_fixes(install_id);
        ,
    },
    .{
        .id = 14,
        .sql =
        // F95Indexer last-change timestamp per game. Returned by the
        // indexer's `/fast` endpoint; we only call `/full` when the
        // server-side value moves past this. NULL = never fetched via
        // indexer → first refresh treats game as "needs full check".
        \\ALTER TABLE games ADD COLUMN last_indexer_change INTEGER;
        ,
    },
    .{
        .id = 15,
        .sql =
        // Indexer-mapping version at the time of the last successful
        // /full. Mirrors F95Checker's `last_check_version`. When the
        // mapping evolves (new fields parsed out of the indexer
        // response) we bump `f95_indexer.PARSER_VERSION`; rows whose
        // stored version doesn't match are force-/full'd on the next
        // refresh regardless of whether `last_indexer_change` moved.
        // Without this column, a mapping change couldn't propagate to
        // existing rows because `last_indexer_change` would pin them
        // to "unchanged".
        \\ALTER TABLE games ADD COLUMN last_indexer_parser_version INTEGER;
        ,
    },
    .{
        .id = 16,
        .sql =
        // Per-version play sessions. install_id is a soft pointer
        // (nullable, no FK) so the session survives uninstall. version
        // is denormalised for the same reason. ON DELETE CASCADE
        // against games is intentional: deleting a game also drops
        // its journal.
        \\CREATE TABLE play_sessions (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  game_thread_id INTEGER NOT NULL
        \\    REFERENCES games(f95_thread_id) ON DELETE CASCADE,
        \\  install_id TEXT,
        \\  version TEXT NOT NULL,
        \\  started_at INTEGER NOT NULL,
        \\  ended_at INTEGER,
        \\  duration_s INTEGER,
        \\  counts_as_played INTEGER NOT NULL DEFAULT 0
        \\);
        \\CREATE INDEX play_sessions_game ON play_sessions(game_thread_id);
        \\CREATE INDEX play_sessions_game_version
        \\  ON play_sessions(game_thread_id, version);
        \\ALTER TABLE games ADD COLUMN last_played_version TEXT;
        ,
    },
    .{
        .id = 17,
        .sql =
        \\ALTER TABLE games ADD COLUMN pinned_version TEXT;
        ,
    },
    .{
        .id = 18,
        .sql =
        \\CREATE TABLE user_labels (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL UNIQUE,
        \\  color TEXT
        \\);
        \\CREATE TABLE game_labels (
        \\  game_thread_id INTEGER NOT NULL,
        \\  label_id INTEGER NOT NULL,
        \\  PRIMARY KEY (game_thread_id, label_id)
        \\);
        \\CREATE INDEX game_labels_label ON game_labels(label_id);
        ,
    },
    .{
        .id = 19,
        .sql =
        \\ALTER TABLE games ADD COLUMN status_changed_at INTEGER;
        ,
    },
    .{
        .id = 20,
        .sql =
        \\CREATE TABLE universal_mods (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  engine TEXT NOT NULL,
        \\  modfile_path TEXT NOT NULL,
        \\  created_at INTEGER NOT NULL DEFAULT 0
        \\);
        \\CREATE INDEX universal_mods_engine ON universal_mods(engine);
        \\CREATE TABLE game_universal_mod_disabled (
        \\  game_thread_id INTEGER NOT NULL,
        \\  universal_mod_id INTEGER NOT NULL,
        \\  PRIMARY KEY (game_thread_id, universal_mod_id)
        \\);
        ,
    },
    .{
        .id = 21,
        .sql =
        \\ALTER TABLE universal_mods ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1;
        ,
    },
    .{
        .id = 22,
        .sql =
        // User overrides for tag-chip colors (F95Checker-style). `color`
        // is a 6-hex "RRGGBB" string; absence of a row means auto (hash).
        \\CREATE TABLE IF NOT EXISTS tag_colors (
        \\  tag   TEXT PRIMARY KEY,
        \\  color TEXT NOT NULL
        \\);
        ,
    },
    .{
        .id = 23,
        .sql =
        // Manual per-game saves-folder override. NULL = use the auto
        // location (the per-game sandbox HOME). Set when a game writes its
        // saves somewhere f69 can't guess (unsandboxed game, custom engine).
        // Deliberately NOT in upsertGame's column list, so a metadata sync's
        // ON CONFLICT DO UPDATE leaves it untouched.
        \\ALTER TABLE games ADD COLUMN save_path_override TEXT;
        ,
    },
};

fn runMigrations(alloc: std.mem.Allocator, conn: *dbu.Conn, db_path: []const u8) !void {
    // Make sure the version table exists. CREATE IF NOT EXISTS is idempotent.
    try conn.exec(
        \\CREATE TABLE IF NOT EXISTS _schema_version (
        \\  id INTEGER PRIMARY KEY,
        \\  hash TEXT NOT NULL,
        \\  applied_at INTEGER NOT NULL
        \\)
    );

    // Read max applied id.
    var max_applied: i64 = 0;
    {
        var rows = conn.inner.rows("SELECT COALESCE(MAX(id), 0) FROM _schema_version", .{}) catch return error.ExecFailed;
        defer rows.deinit();
        if (rows.next()) |r| max_applied = r.int(0);
    }

    // Refuse downgrade: if our highest declared id is below max applied,
    // the DB came from a newer build.
    var declared_max: u32 = 0;
    for (migrations) |m| {
        if (m.id > declared_max) declared_max = m.id;
    }
    if (max_applied > declared_max) {
        log.err("schema too new: db at {d}, binary supports up to {d}", .{ max_applied, declared_max });
        return error.SchemaTooNew;
    }

    // Anything to do?
    var pending: u32 = 0;
    for (migrations) |m| {
        if (m.id > max_applied) pending += 1;
    }
    if (pending == 0) {
        log.info("no pending migrations (at {d})", .{max_applied});
        return;
    }

    // Pre-migration snapshot (best-effort, defense in depth). The
    // per-migration transaction below already makes each step atomic —
    // a crash rolls back cleanly and leaves the DB untouched — so this
    // exists only to recover from a migration that SUCCEEDS but
    // transforms data wrongly. VACUUM INTO is WAL-safe and lands beside
    // the DB (whose dir already exists). Skipped for in-memory DBs and
    // for a fresh DB (max_applied == 0) that has no user data to protect.
    if (max_applied > 0 and !std.mem.eql(u8, db_path, ":memory:")) {
        const bak = std.fmt.allocPrint(alloc, "{s}.premig-{d}-to-{d}.bak", .{ db_path, max_applied, declared_max }) catch null;
        if (bak) |dest| {
            defer alloc.free(dest);
            vacuumInto(alloc, conn, dest) catch |e|
                log.warn("pre-migration backup to '{s}' failed: {s} (continuing — migrations are atomic)", .{ dest, @errorName(e) });
        }
    }

    // Apply pending migrations in order — each in its OWN transaction so
    // a crash or error mid-migration rolls the whole step back (schema +
    // the _schema_version record together). Without this, a crash between
    // a DROP and its RENAME could lose a table, or a crash between the
    // DDL and the version-record insert could re-run an ALTER on the next
    // start and soft-brick with a duplicate-column error.
    var applied_now: u32 = 0;
    for (migrations) |m| {
        if (m.id <= max_applied) continue;

        // Hash for record (so accidental edits to applied SQL get caught
        // on the next start-up — `_schema_version.hash` is verified later
        // when we add a self-check pass).
        var sha: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(m.sql, &sha, .{});
        const hex = std.fmt.bytesToHex(sha, .lower);

        // FK enforcement must be toggled OUTSIDE the transaction — SQLite
        // treats `PRAGMA foreign_keys` as a no-op while a transaction is
        // active. Migration 10 rebuilds a table (DROP/RENAME) and needs FK
        // off so a child table's cascade doesn't wipe rows mid-rebuild; do
        // it for every migration so the PRAGMAs embedded in that SQL become
        // harmless no-ops and no rebuild can cascade.
        conn.exec("PRAGMA foreign_keys = OFF") catch {};
        conn.exec("BEGIN") catch return error.ExecFailed;
        applyMigration(alloc, conn, m, hex[0..]) catch |e| {
            conn.exec("ROLLBACK") catch {};
            conn.exec("PRAGMA foreign_keys = ON") catch {};
            log.err("migration {d} failed: {s} — rolled back, DB left unchanged", .{ m.id, @errorName(e) });
            return e;
        };
        conn.exec("COMMIT") catch |e| {
            conn.exec("ROLLBACK") catch {};
            conn.exec("PRAGMA foreign_keys = ON") catch {};
            log.err("migration {d} commit failed: {s} — rolled back", .{ m.id, @errorName(e) });
            return e;
        };
        conn.exec("PRAGMA foreign_keys = ON") catch {};

        applied_now += 1;
        log.info("migration {d} applied", .{m.id});
    }
}

/// Run one migration's SQL and record it in `_schema_version`. Called
/// inside an open transaction so the schema change and its version
/// record commit or roll back together.
fn applyMigration(alloc: std.mem.Allocator, conn: *dbu.Conn, m: Migration, hex: []const u8) !void {
    try conn.execScript(alloc, m.sql);
    const ins = std.fmt.allocPrint(
        alloc,
        "INSERT INTO _schema_version (id, hash, applied_at) VALUES ({d}, '{s}', {d})",
        .{ m.id, hex, unixSecondsApprox() },
    ) catch return error.OutOfMemory;
    defer alloc.free(ins);
    try conn.exec(ins);
}

/// `VACUUM INTO 'dest'` with single-quote escaping. dest must not
/// already exist (SQLite refuses to overwrite). Used for the
/// pre-migration snapshot.
fn vacuumInto(alloc: std.mem.Allocator, conn: *dbu.Conn, dest: []const u8) !void {
    const q_count = std.mem.count(u8, dest, "'");
    const escaped = alloc.alloc(u8, dest.len + q_count) catch return error.OutOfMemory;
    defer alloc.free(escaped);
    var j: usize = 0;
    for (dest) |c| {
        escaped[j] = c;
        j += 1;
        if (c == '\'') {
            escaped[j] = '\'';
            j += 1;
        }
    }
    const sql = std.fmt.allocPrint(alloc, "VACUUM INTO '{s}'", .{escaped}) catch return error.OutOfMemory;
    defer alloc.free(sql);
    conn.inner.exec(sql, .{}) catch return error.ExecFailed;
}

/// Coarse wall-clock seconds. Avoids std.time API churn between Zig
/// versions; we just want a stamp on rows.
fn unixSecondsApprox() i64 {
    return 0; // TODO: real clock; see std.Io.Clock in 0.16+.
}

/// Ordering used by `listInstalls` to sort newest-version-first.
/// Falls back to `installed_at DESC` when the canonical version
/// comparator can't distinguish (e.g. two installs of v0.20 with
/// different names). Returns `true` when `a` should sort BEFORE
/// `b` (per `std.mem.sort` contract — `lessThan`).
fn installNewerFirst(_: void, a: dom.Install, b: dom.Install) bool {
    return switch (version_mod.compare(a.version, b.version)) {
        .gt => true,
        .lt => false,
        .eq => a.installed_at > b.installed_at,
    };
}

/// Build a Game from a query row. Allocates copies of the text columns.
/// Numeric/enum columns are best-effort — unknown enum values fall back
/// to default variants.
fn hydrateInstall(alloc: std.mem.Allocator, r: anytype) errs.Error!dom.Install {
    var inst: dom.Install = .{
        .id = [_]u8{0} ** 36,
        .game_thread_id = 0,
        .version = "",
        .install_path = "",
        .recipe_id = "",
    };

    const id_text = r.text(0);
    const n = @min(id_text.len, inst.id.len);
    @memcpy(inst.id[0..n], id_text[0..n]);

    inst.game_thread_id = @as(u64, @intCast(r.int(1)));

    inst.version = alloc.dupe(u8, r.text(2)) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(inst.version);

    inst.install_path = alloc.dupe(u8, r.text(3)) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(inst.install_path);

    if (r.nullableText(4)) |s| {
        inst.executable = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    errdefer if (inst.executable) |s| alloc.free(s);

    if (r.nullableText(5)) |s| {
        inst.launch_args = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    errdefer if (inst.launch_args) |s| alloc.free(s);

    inst.recipe_id = alloc.dupe(u8, r.text(6)) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(inst.recipe_id);

    inst.installed_at = r.int(7);

    // Columns 8..10 added in migration 10. Pre-migration rows return
    // null for `name` / `archive_sha256` and the schema default
    // `'recipe'` for `source`.
    if (r.nullableText(8)) |s| {
        inst.name = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    errdefer if (inst.name) |s| alloc.free(s);

    inst.source = std.meta.stringToEnum(dom.InstallSource, r.text(9)) orelse .recipe;

    if (r.nullableText(10)) |s| {
        if (s.len == 64) {
            var hex: [64]u8 = undefined;
            @memcpy(hex[0..], s);
            inst.archive_sha256 = hex;
        }
    }

    return inst;
}

fn hydrateGame(alloc: std.mem.Allocator, r: anytype) errs.Error!dom.Game {
    var g = dom.Game{
        .f95_thread_id = @as(u64, @intCast(r.int(0))),
        .name = "",
    };

    g.name = alloc.dupe(u8, r.text(1)) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(g.name);

    if (r.nullableText(2)) |s| {
        g.developer = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    errdefer if (g.developer) |s| alloc.free(s);

    if (r.nullableText(3)) |s| {
        g.latest_version = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    errdefer if (g.latest_version) |s| alloc.free(s);

    if (r.nullableFloat(4)) |x| g.rating = @as(f32, @floatCast(x));
    if (r.nullableInt(5)) |x| g.vote_count = @as(u32, @intCast(x));

    g.completion_status = parseCompletion(r.text(6));
    g.engine = parseEngine(r.text(7));
    g.sandbox = parseSandbox(r.text(8));

    g.last_played_at = r.nullableInt(9);
    g.total_playtime_s = @as(u64, @intCast(r.int(10)));
    g.created_at = r.int(11);

    if (r.nullableText(12)) |s| {
        g.notes = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }

    // Tags are stored as a JSON array of strings.
    g.tags = decodeTagsJson(alloc, r.text(13)) catch &.{};

    g.last_scraped_at = r.nullableInt(14);

    // Screenshot URLs — stored as JSON array, same shape as tags.
    if (r.nullableText(15)) |s| {
        g.screenshots = decodeTagsJson(alloc, s) catch &.{};
    }

    // description / changelog / reviews — all nullable plain text.
    if (r.nullableText(16)) |s| {
        g.description_md = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    if (r.nullableText(17)) |s| {
        g.changelog_md = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    if (r.nullableText(18)) |s| {
        g.reviews_md = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    // Download-link list — same JSON-of-strings shape as tags.
    if (r.nullableText(19)) |s| {
        g.download_links = decodeTagsJson(alloc, s) catch &.{};
    }
    g.dev_status = dom.DevStatus.fromStr(r.text(20));
    if (r.nullableText(21)) |s| {
        g.downloads_md = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    g.last_updated_at = r.nullableInt(22);
    if (r.nullableText(23)) |s| {
        g.thread_info_md = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    g.censored = dom.CensoredState.fromStr(r.text(24));
    g.auto_update = parseAutoUpdate(r.text(25));
    g.mod_backup_mode = parseBackupModePref(r.text(26));
    g.last_indexer_change = r.nullableInt(27);
    if (r.nullableInt(28)) |v| g.last_indexer_parser_version = @intCast(v);
    if (r.nullableText(29)) |s| {
        g.last_played_version = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    if (r.nullableText(30)) |s| {
        g.pinned_version = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    g.status_changed_at = r.nullableInt(31);

    return g;
}

fn parseAutoUpdate(s: []const u8) dom.AutoUpdateOverride {
    return std.meta.stringToEnum(dom.AutoUpdateOverride, s) orelse .use_default;
}

fn parseBackupModePref(s: []const u8) dom.BackupModePref {
    return std.meta.stringToEnum(dom.BackupModePref, s) orelse .none;
}

/// Parse a JSON array of strings into a freshly-`alloc`-owned slice
/// where every element is also `alloc`-owned. Returns empty on any
/// parse error so a corrupt row doesn't kill `listGames`; logs the
/// corruption so it surfaces in the log stream.
fn decodeTagsJson(alloc: std.mem.Allocator, json_text: []const u8) errs.Error![]const []const u8 {
    if (json_text.len == 0) return &.{};
    var parsed = std.json.parseFromSlice([]const []const u8, alloc, json_text, .{}) catch |err| {
        log.warn("tags_json corrupt — falling back to empty: {s}", .{@errorName(err)});
        return &.{};
    };
    defer parsed.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |t| alloc.free(t);
        out.deinit(alloc);
    }
    for (parsed.value) |t| {
        const dup = alloc.dupe(u8, t) catch return errs.Error.OutOfMemory;
        errdefer alloc.free(dup);
        out.append(alloc, dup) catch return errs.Error.OutOfMemory;
    }
    return out.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

fn parseCompletion(s: []const u8) dom.CompletionStatus {
    return std.meta.stringToEnum(dom.CompletionStatus, s) orelse .not_started;
}

fn parseEngine(s: []const u8) dom.Engine {
    return dom.Engine.fromStr(s);
}

fn parseSandbox(s: []const u8) dom.SandboxOverride {
    return std.meta.stringToEnum(dom.SandboxOverride, s) orelse .use_default;
}

test "library: open + migrate + listGames empty" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    const games = try lib.listGames();
    defer lib.freeGames(games);
    try std.testing.expectEqual(@as(usize, 0), games.len);
}

test "library: backupTo produces a populated snapshot" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 42, .name = "Backup Me" });

    const path = "/tmp/f69-backuptest-42.db";
    std.Io.Dir.cwd().deleteFile(io, path) catch {}; // VACUUM INTO needs dest absent
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try lib.backupTo(gpa, path);

    // Reopen the snapshot — proves VACUUM INTO wrote a valid, populated DB.
    var restored = try Library.open(gpa, path);
    defer restored.close();
    const games = try restored.listGames();
    defer restored.freeGames(games);
    try std.testing.expectEqual(@as(usize, 1), games.len);
    try std.testing.expectEqualStrings("Backup Me", games[0].name);
}

test "library: upsertGame preserves existing installs (no cascade delete)" {
    const gpa = std.testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    try lib.upsertGame(&.{ .f95_thread_id = 7, .name = "G" });
    try lib.upsertInstall(&.{
        .id = [_]u8{'a'} ** 36,
        .game_thread_id = 7,
        .version = "1.0",
        .install_path = "/tmp/x",
        .recipe_id = "",
        .installed_at = 1,
        .source = .manual,
    });

    // Re-upsert the game the way a sync's applyScrape does. With the old
    // INSERT OR REPLACE this cascade-deleted the install row (FK ON DELETE
    // CASCADE); the ON CONFLICT DO UPDATE must leave it intact.
    try lib.upsertGame(&.{ .f95_thread_id = 7, .name = "G (synced)" });

    const installs = try lib.listInstalls(7);
    defer lib.freeInstalls(installs);
    try std.testing.expectEqual(@as(usize, 1), installs.len);
    try std.testing.expectEqualStrings("1.0", installs[0].version);
}

test "library: tag color override round-trip" {
    const gpa = std.testing.allocator;
    var lib = try Library.open(gpa, ":memory:");
    defer lib.close();

    try lib.setTagColor("Corruption", "ff8800");
    {
        var m = try lib.loadTagColors(gpa);
        defer Library.freeTagColors(&m);
        try std.testing.expectEqual(@as(?u32, 0xff8800), m.get("Corruption"));
        try std.testing.expectEqual(@as(usize, 1), m.count());
    }
    // Clearing removes the override.
    try lib.setTagColor("Corruption", null);
    {
        var m = try lib.loadTagColors(gpa);
        defer Library.freeTagColors(&m);
        try std.testing.expectEqual(@as(usize, 0), m.count());
    }
}

test "library: install round-trip + latestInstallForGame" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    try lib.upsertGame(&.{ .f95_thread_id = 14014, .name = "Summertime Saga" });

    // Two installs at different times. Newest must come first.
    const id_a: [36]u8 = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".*;
    const id_b: [36]u8 = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb".*;
    try lib.upsertInstall(&.{
        .id = id_a,
        .game_thread_id = 14014,
        .version = "0.20.16",
        .install_path = "/games/14014/0.20.16",
        .recipe_id = "summertime-saga",
        .installed_at = 1_000,
    });
    try lib.upsertInstall(&.{
        .id = id_b,
        .game_thread_id = 14014,
        .version = "0.20.17",
        .install_path = "/games/14014/0.20.17",
        .recipe_id = "summertime-saga",
        .installed_at = 2_000,
    });

    const installs = try lib.listInstalls(14014);
    defer lib.freeInstalls(installs);
    try std.testing.expectEqual(@as(usize, 2), installs.len);
    try std.testing.expectEqualStrings("0.20.17", installs[0].version);
    try std.testing.expectEqualStrings("0.20.16", installs[1].version);

    const latest = (try lib.latestInstallForGame(14014)).?;
    defer lib.freeInstall(latest);
    try std.testing.expectEqualStrings("0.20.17", latest.version);
    try std.testing.expectEqualStrings("/games/14014/0.20.17", latest.install_path);
}

test "library: setInstallExecutable + setInstallLaunchArgs persist on the row" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 7, .name = "G" });
    const id: [36]u8 = "cccccccc-cccc-cccc-cccc-cccccccccccc".*;
    try lib.upsertInstall(&.{
        .id = id,
        .game_thread_id = 7,
        .version = "1.0",
        .install_path = "/g/7/1.0",
        .recipe_id = "r",
        .installed_at = 1,
    });
    try lib.setInstallExecutable(&id, "wine game.exe");
    try lib.setInstallLaunchArgs(&id, "--fullscreen --no-intro");
    const got = (try lib.latestInstallForGame(7)).?;
    defer lib.freeInstall(got);
    try std.testing.expectEqualStrings("wine game.exe", got.executable.?);
    try std.testing.expectEqualStrings("--fullscreen --no-intro", got.launch_args.?);
}

test "library: relocateInstalls rewrites the path prefix, boundary-aware" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 7, .name = "G" });
    // Two installs under the old root, plus a decoy whose path merely shares
    // a string prefix but is NOT under the old root (must NOT be rewritten).
    try lib.upsertInstall(&.{ .id = "11111111-1111-1111-1111-111111111111".*, .game_thread_id = 7, .version = "1.0", .install_path = "/media/ntfs/library/7/1.0", .recipe_id = "r", .installed_at = 1 });
    try lib.upsertInstall(&.{ .id = "22222222-2222-2222-2222-222222222222".*, .game_thread_id = 7, .version = "2.0", .install_path = "/media/ntfs/library/7/2.0", .recipe_id = "r", .installed_at = 2 });
    try lib.upsertInstall(&.{ .id = "33333333-3333-3333-3333-333333333333".*, .game_thread_id = 7, .version = "3.0", .install_path = "/media/ntfs/library-old/9/3.0", .recipe_id = "r", .installed_at = 3 });

    const n = try lib.relocateInstalls("/media/ntfs/library", "/home/u/games");
    try std.testing.expectEqual(@as(usize, 2), n);

    const installs = try lib.listInstalls(7);
    defer lib.freeInstalls(installs);
    // installs[0] = newest (3.0, the decoy) — untouched.
    try std.testing.expectEqualStrings("/media/ntfs/library-old/9/3.0", installs[0].install_path);
    try std.testing.expectEqualStrings("/home/u/games/7/2.0", installs[1].install_path);
    try std.testing.expectEqualStrings("/home/u/games/7/1.0", installs[2].install_path);
}

test "library: deleteInstall removes one row" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    try lib.upsertGame(&.{ .f95_thread_id = 14014, .name = "Summertime Saga" });
    const id: [36]u8 = "cccccccc-cccc-cccc-cccc-cccccccccccc".*;
    try lib.upsertInstall(&.{
        .id = id,
        .game_thread_id = 14014,
        .version = "1.0",
        .install_path = "/games/14014/1.0",
        .recipe_id = "x",
        .installed_at = 1,
    });

    try lib.deleteInstall(&id);
    const after = try lib.listInstalls(14014);
    defer lib.freeInstalls(after);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "library: deleteGame cascades to installs" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    try lib.upsertGame(&.{ .f95_thread_id = 99, .name = "Doomed" });
    const id: [36]u8 = "dddddddd-dddd-dddd-dddd-dddddddddddd".*;
    try lib.upsertInstall(&.{
        .id = id,
        .game_thread_id = 99,
        .version = "1.0",
        .install_path = "/games/99/1.0",
        .recipe_id = "x",
        .installed_at = 1,
    });

    try lib.deleteGame(99);
    const orphans = try lib.listInstalls(99);
    defer lib.freeInstalls(orphans);
    try std.testing.expectEqual(@as(usize, 0), orphans.len);
}

test "library: upsert + list + getGame round-trip" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    try lib.upsertGame(&.{
        .f95_thread_id = 12345,
        .name = "Summertime Saga",
        .developer = "Kompas Productions",
        .rating = 4.3,
        .vote_count = 9000,
        .latest_version = "0.20.17",
        .engine = .renpy,
        .completion_status = .in_progress,
        .sandbox = .always,
    });
    try lib.upsertGame(&.{
        .f95_thread_id = 67890,
        .name = "Babysitter",
        .rating = 3.8,
        .engine = .renpy,
    });

    const games = try lib.listGames();
    defer lib.freeGames(games);
    try std.testing.expectEqual(@as(usize, 2), games.len);
    // Ordered by name COLLATE NOCASE → Babysitter first.
    try std.testing.expectEqualStrings("Babysitter", games[0].name);
    try std.testing.expectEqualStrings("Summertime Saga", games[1].name);

    const stats = try lib.ratingStats();
    try std.testing.expectEqual(@as(u32, 2), stats.count);

    if (try lib.getGame(12345)) |g| {
        defer std.testing.allocator.free(g.name);
        defer if (g.developer) |s| std.testing.allocator.free(s);
        defer if (g.latest_version) |s| std.testing.allocator.free(s);
        try std.testing.expectEqualStrings("Summertime Saga", g.name);
        try std.testing.expectEqual(dom.CompletionStatus.in_progress, g.completion_status);
        try std.testing.expectEqual(dom.SandboxOverride.always, g.sandbox);
    } else {
        return error.MissingGame;
    }
}

test "library: migration 16 — play_sessions table exists" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    // Compile-time guard for the stub API surface. The real assertion
    // that the table exists arrives with Task 3 when `listPlaySessions`
    // grows a real SELECT body — until then this test only proves
    // `Library.open` (which runs the migrations) didn't error.
    const sessions = try lib.listPlaySessions(12345);
    defer lib.freePlaySessions(sessions);
    try std.testing.expectEqual(@as(usize, 0), sessions.len);
}

test "library: migration 16 — games.last_played_version column exists" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    try lib.upsertGame(&.{ .f95_thread_id = 1, .name = "G" });
    const g = (try lib.getGame(1)).?;
    defer lib.freeGame(g);
    try std.testing.expectEqual(@as(?[]const u8, null), g.last_played_version);
}

test "library: user labels create/assign/list/delete" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    const alloc = std.testing.allocator;

    try lib.upsertGame(&.{ .f95_thread_id = 1, .name = "G1" });
    try lib.upsertGame(&.{ .f95_thread_id = 2, .name = "G2" });

    const fav = try lib.createLabel("Favorites", "#1FA39A");
    const todo = try lib.createLabel("To Play", null);
    // Idempotent on name.
    try std.testing.expectEqual(fav, try lib.createLabel("Favorites", null));

    try lib.addGameLabel(1, fav);
    try lib.addGameLabel(1, todo);
    try lib.addGameLabel(2, fav);
    try lib.addGameLabel(1, fav); // dup ignored

    {
        const ids = try lib.labelsForGame(1);
        defer alloc.free(ids);
        try std.testing.expectEqual(@as(usize, 2), ids.len);
    }

    {
        const labels = try lib.listLabels();
        defer lib.freeLabels(labels);
        try std.testing.expectEqual(@as(usize, 2), labels.len);
        // name-sorted: "Favorites" < "To Play"
        try std.testing.expectEqualStrings("Favorites", labels[0].name);
        try std.testing.expectEqualStrings("#1FA39A", labels[0].color.?);
        try std.testing.expectEqual(@as(?[]const u8, null), labels[1].color);
    }

    {
        const games = try lib.gamesForLabel(fav);
        defer alloc.free(games);
        try std.testing.expectEqual(@as(usize, 2), games.len); // games 1 and 2
    }

    try lib.removeGameLabel(1, todo);
    {
        const ids = try lib.labelsForGame(1);
        defer alloc.free(ids);
        try std.testing.expectEqual(@as(usize, 1), ids.len);
        try std.testing.expectEqual(fav, ids[0]);
    }

    // Deleting a label cascades to assignments.
    try lib.deleteLabel(fav);
    {
        const ids = try lib.labelsForGame(2);
        defer alloc.free(ids);
        try std.testing.expectEqual(@as(usize, 0), ids.len);
        const labels = try lib.listLabels();
        defer lib.freeLabels(labels);
        try std.testing.expectEqual(@as(usize, 1), labels.len);
    }
}

test "library: universal mods registry + per-game disable" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    const renpy_id = try lib.createUniversalMod("Skip Splash", .renpy, "/mods/skip.zip", 100);
    _ = try lib.createUniversalMod("RPGM Cheat", .rpgm_mv, "/mods/cheat.zip", 101);

    {
        const all = try lib.listUniversalMods(null);
        defer lib.freeUniversalMods(all);
        try std.testing.expectEqual(@as(usize, 2), all.len);
    }
    {
        const renpy_mods = try lib.listUniversalMods(.renpy);
        defer lib.freeUniversalMods(renpy_mods);
        try std.testing.expectEqual(@as(usize, 1), renpy_mods.len);
        try std.testing.expectEqualStrings("Skip Splash", renpy_mods[0].name);
        try std.testing.expectEqual(dom.Engine.renpy, renpy_mods[0].engine);
        try std.testing.expectEqualStrings("/mods/skip.zip", renpy_mods[0].modfile_path);
    }

    // Per-game disable toggles.
    try std.testing.expect(!try lib.isUniversalModDisabled(42, renpy_id));
    try lib.setUniversalModDisabled(42, renpy_id, true);
    try std.testing.expect(try lib.isUniversalModDisabled(42, renpy_id));
    try lib.setUniversalModDisabled(42, renpy_id, false);
    try std.testing.expect(!try lib.isUniversalModDisabled(42, renpy_id));

    // Global enabled flag defaults on; toggle persists.
    {
        const all = try lib.listUniversalMods(.renpy);
        defer lib.freeUniversalMods(all);
        try std.testing.expect(all[0].enabled);
    }
    try lib.setUniversalModEnabled(renpy_id, false);
    {
        const all = try lib.listUniversalMods(.renpy);
        defer lib.freeUniversalMods(all);
        try std.testing.expect(!all[0].enabled);
    }

    // countDisabledForMod tracks opt-outs.
    try std.testing.expectEqual(@as(u32, 0), try lib.countDisabledForMod(renpy_id));
    try lib.setUniversalModDisabled(7, renpy_id, true);
    try lib.setUniversalModDisabled(8, renpy_id, true);
    try std.testing.expectEqual(@as(u32, 2), try lib.countDisabledForMod(renpy_id));
    try lib.setUniversalModDisabled(7, renpy_id, false);
    try lib.setUniversalModDisabled(8, renpy_id, false);

    // Delete cascades to disables.
    try lib.setUniversalModDisabled(42, renpy_id, true);
    try lib.deleteUniversalMod(renpy_id);
    try std.testing.expect(!try lib.isUniversalModDisabled(42, renpy_id));
    {
        const all = try lib.listUniversalMods(null);
        defer lib.freeUniversalMods(all);
        try std.testing.expectEqual(@as(usize, 1), all.len);
    }
}

test "library: setPinnedVersion round-trips and clears" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    try lib.upsertGame(&.{ .f95_thread_id = 1, .name = "G" });
    {
        const g = (try lib.getGame(1)).?;
        defer lib.freeGame(g);
        try std.testing.expectEqual(@as(?[]const u8, null), g.pinned_version);
    }

    try lib.setPinnedVersion(1, "1.2.3");
    {
        const g = (try lib.getGame(1)).?;
        defer lib.freeGame(g);
        try std.testing.expectEqualStrings("1.2.3", g.pinned_version.?);
    }

    try lib.setPinnedVersion(1, null);
    {
        const g = (try lib.getGame(1)).?;
        defer lib.freeGame(g);
        try std.testing.expectEqual(@as(?[]const u8, null), g.pinned_version);
    }
}

test "library: insertSession opens a row with NULL ended_at" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    try lib.upsertGame(&.{ .f95_thread_id = 7, .name = "G" });
    const install_id: [36]u8 = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".*;
    try lib.upsertInstall(&.{
        .id = install_id,
        .game_thread_id = 7,
        .version = "0.1",
        .install_path = "/games/7/0.1",
        .recipe_id = "x",
        .installed_at = 1,
    });

    const sid = try lib.insertSession(.{
        .game_thread_id = 7,
        .install_id = install_id,
        .version = "0.1",
        .started_at = 1700000000,
    });
    try std.testing.expect(sid > 0);

    const sessions = try lib.listPlaySessions(7);
    defer lib.freePlaySessions(sessions);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("0.1", sessions[0].version);
    try std.testing.expectEqual(@as(?i64, null), sessions[0].ended_at);
    try std.testing.expectEqual(false, sessions[0].counts_as_played);
}

test "library: closeSession sets ended_at, duration, counts_as_played" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 1, .name = "G" });

    const sid = try lib.insertSession(.{
        .game_thread_id = 1,
        .version = "0.1",
        .started_at = 1000,
    });
    try lib.closeSession(.{
        .session_id = sid,
        .ended_at = 1090,
        .early_fail = false,
        .min_session_seconds = 60,
    });

    const sessions = try lib.listPlaySessions(1);
    defer lib.freePlaySessions(sessions);
    try std.testing.expectEqual(@as(?i64, 1090), sessions[0].ended_at);
    try std.testing.expectEqual(@as(?i64, 90), sessions[0].duration_s);
    try std.testing.expect(sessions[0].counts_as_played); // 90s > 60s threshold
}

test "library: closeSession — below threshold does not count" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 1, .name = "G" });
    const sid = try lib.insertSession(.{
        .game_thread_id = 1,
        .version = "0.1",
        .started_at = 1000,
    });
    try lib.closeSession(.{
        .session_id = sid,
        .ended_at = 1059, // 59s
        .early_fail = false,
        .min_session_seconds = 60,
    });
    const sessions = try lib.listPlaySessions(1);
    defer lib.freePlaySessions(sessions);
    try std.testing.expect(!sessions[0].counts_as_played);
}

test "library: closeSession — early_fail forces counts_as_played=0" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 1, .name = "G" });
    const sid = try lib.insertSession(.{
        .game_thread_id = 1,
        .version = "0.1",
        .started_at = 1000,
    });
    // Long duration but early_fail=true (e.g. game crashed at 5h)
    try lib.closeSession(.{
        .session_id = sid,
        .ended_at = 19000,
        .early_fail = true,
        .min_session_seconds = 60,
    });
    const sessions = try lib.listPlaySessions(1);
    defer lib.freePlaySessions(sessions);
    try std.testing.expect(!sessions[0].counts_as_played);
}

test "library: closeSession bumps total_playtime_s and last_played_at when counted" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 1, .name = "G" });
    const sid = try lib.insertSession(.{
        .game_thread_id = 1,
        .version = "0.1",
        .started_at = 1000,
    });
    try lib.closeSession(.{
        .session_id = sid,
        .ended_at = 1300, // 300s
        .early_fail = false,
        .min_session_seconds = 60,
    });

    const g = (try lib.getGame(1)).?;
    defer lib.freeGame(g);
    try std.testing.expectEqual(@as(u64, 300), g.total_playtime_s);
    try std.testing.expectEqual(@as(?i64, 1300), g.last_played_at);
}

test "library: closeSession does NOT bump aggregates when not counted" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 1, .name = "G" });
    const sid = try lib.insertSession(.{
        .game_thread_id = 1,
        .version = "0.1",
        .started_at = 1000,
    });
    try lib.closeSession(.{
        .session_id = sid,
        .ended_at = 1010, // 10s, below threshold
        .early_fail = false,
        .min_session_seconds = 60,
    });
    const g = (try lib.getGame(1)).?;
    defer lib.freeGame(g);
    try std.testing.expectEqual(@as(u64, 0), g.total_playtime_s);
    try std.testing.expectEqual(@as(?i64, null), g.last_played_at);
}

test "library: setLastPlayedVersionIfNewer — null replaced unconditionally" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 1, .name = "G" });

    const cmp = struct {
        fn f(a: []const u8, b: []const u8) std.math.Order {
            return std.mem.order(u8, a, b);
        }
    }.f;
    try lib.setLastPlayedVersionIfNewer(1, "0.1", cmp);

    const g = (try lib.getGame(1)).?;
    defer lib.freeGame(g);
    try std.testing.expectEqualStrings("0.1", g.last_played_version.?);
}

test "library: setLastPlayedVersionIfNewer — newer wins" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 1, .name = "G" });

    const cmp = struct {
        fn f(a: []const u8, b: []const u8) std.math.Order {
            return std.mem.order(u8, a, b);
        }
    }.f;
    try lib.setLastPlayedVersionIfNewer(1, "0.1", cmp);
    try lib.setLastPlayedVersionIfNewer(1, "0.2", cmp);

    const g = (try lib.getGame(1)).?;
    defer lib.freeGame(g);
    try std.testing.expectEqualStrings("0.2", g.last_played_version.?);
}

test "library: setLastPlayedVersionIfNewer — older does NOT regress" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 1, .name = "G" });

    const cmp = struct {
        fn f(a: []const u8, b: []const u8) std.math.Order {
            return std.mem.order(u8, a, b);
        }
    }.f;
    try lib.setLastPlayedVersionIfNewer(1, "0.2", cmp);
    try lib.setLastPlayedVersionIfNewer(1, "0.1", cmp);

    const g = (try lib.getGame(1)).?;
    defer lib.freeGame(g);
    try std.testing.expectEqualStrings("0.2", g.last_played_version.?);
}

test "library: changeThreadId re-keys the game and carries its installs across" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 111, .name = "Old Key" });
    try lib.upsertInstall(&.{
        .id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".*,
        .game_thread_id = 111,
        .version = "1.0",
        .install_path = "/games/foo",
        .recipe_id = "",
        .installed_at = 1,
    });

    try lib.changeThreadId(111, 222);

    // Old key is gone, new key exists.
    try std.testing.expect(!try lib.gameExists(111));
    try std.testing.expect(try lib.gameExists(222));
    // The install followed the game to the new key (FK-critical path).
    const under_old = try lib.listInstalls(111);
    defer lib.freeInstalls(under_old);
    try std.testing.expectEqual(@as(usize, 0), under_old.len);
    const under_new = try lib.listInstalls(222);
    defer lib.freeInstalls(under_new);
    try std.testing.expectEqual(@as(usize, 1), under_new.len);
    try std.testing.expectEqualStrings("/games/foo", under_new[0].install_path);
}

test "library: changeThreadId refuses when the target thread already exists" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 1, .name = "A" });
    try lib.upsertGame(&.{ .f95_thread_id = 2, .name = "B" });
    try std.testing.expectError(errs.Error.ThreadIdInUse, lib.changeThreadId(1, 2));
    // Both survive untouched.
    try std.testing.expect(try lib.gameExists(1));
    try std.testing.expect(try lib.gameExists(2));
}

test "library: changeThreadId on a missing source is GameNotFound; equal ids no-op" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try std.testing.expectError(errs.Error.GameNotFound, lib.changeThreadId(9, 10));
    try lib.upsertGame(&.{ .f95_thread_id = 5, .name = "G" });
    try lib.changeThreadId(5, 5); // no-op, no error
    try std.testing.expect(try lib.gameExists(5));
}

test "library: registerManualInstall adds a .manual install and guards collisions" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 7, .name = "G" });
    try lib.upsertGame(&.{ .f95_thread_id = 8, .name = "H" });

    try lib.registerManualInstall(7, "0.2.40", "/media/games/G", "11111111-1111-1111-1111-111111111111".*, 1);
    const installs = try lib.listInstalls(7);
    defer lib.freeInstalls(installs);
    try std.testing.expectEqual(@as(usize, 1), installs.len);
    try std.testing.expectEqual(dom.InstallSource.manual, installs[0].source);
    try std.testing.expectEqualStrings("/media/games/G", installs[0].install_path);

    // Same path claimed by another game → refused (would otherwise steal it).
    try std.testing.expectError(errs.Error.InstallPathInUse, lib.registerManualInstall(8, "0.2.40", "/media/games/G", "22222222-2222-2222-2222-222222222222".*, 2));
    // Same (game, version) again → refused (would clobber a row that may carry mod links).
    try std.testing.expectError(errs.Error.InstallVersionExists, lib.registerManualInstall(7, "0.2.40", "/media/games/G2", "33333333-3333-3333-3333-333333333333".*, 3));
}

test "library: save-path override round-trips and a metadata sync preserves it" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();
    try lib.upsertGame(&.{ .f95_thread_id = 42, .name = "G" });

    try std.testing.expect(!try lib.hasSavePathOverride(42));
    try std.testing.expect((try lib.savePathOverride(42)) == null);

    try lib.setGameSavePath(42, "/home/u/saves/G");
    try std.testing.expect(try lib.hasSavePathOverride(42));
    const got = (try lib.savePathOverride(42)).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/home/u/saves/G", got);

    // A metadata sync goes through upsertGame's ON CONFLICT DO UPDATE, which
    // must NOT touch save_path_override (it's not in the column list).
    try lib.upsertGame(&.{ .f95_thread_id = 42, .name = "G (synced)", .rating = 4.5 });
    const after = (try lib.savePathOverride(42)).?;
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("/home/u/saves/G", after);

    try lib.setGameSavePath(42, null);
    try std.testing.expect(!try lib.hasSavePathOverride(42));
    try std.testing.expect((try lib.savePathOverride(42)) == null);
}

// Pull nested tests into this module's test binary (same idiom as
// downloads.zig / importers.zig roots).
test {
    _ = @import("domain.zig");
    _ = @import("errors.zig");
}
