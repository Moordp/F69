// One-at-a-time importer worker for F95Checker / xLibrary.
//
// Pattern mirrors `actions/bookmarks.zig`'s bookmarks worker: a background
// thread does the slow filesystem work (read source data → migrate
// install dirs → SHA-256 verify); the UI thread drains staged
// upserts each frame and commits them to the library DB.
//
// SQLite stays single-threaded: the worker never touches `Library`.
// It only reads the source DB / JSON and runs `migrate.copyVerifyDelete`,
// then queues a `StagedRow` for the UI thread to upsert.
//
// One job in flight at a time. Trying to start a second while one is
// running is rejected by `start()`.

const std = @import("std");
const library = @import("library");
const importers = @import("importers");
const dvui = @import("dvui");
const job_mod = @import("job.zig");

const log = std.log.scoped(.import_job);

pub const Source = enum { f95checker, xlibrary };

/// Per-import transfer mode. Mirrors `state.ImportMode` but lives
/// here so the worker file doesn't need to reach into the UI
/// namespace. Converted by the action layer at job creation time.
pub const Mode = enum {
    /// Cut + paste. Final disk = 1x.
    move,
    /// Copy + keep source. Final disk = 2x.
    copy,
    /// No filesystem mutation — install row points at the source.
    /// Safest mode (default for DB-driven imports).
    link,
};

pub const Phase = enum(u8) {
    queued = 0,
    reading = 1,
    migrating = 2,
    done = 3,
    err = 4,
    canceled = 5,
};

pub fn phaseLabel(p: Phase) []const u8 {
    return switch (p) {
        .queued => "Queued",
        .reading => "Reading source",
        .migrating => "Migrating installs",
        .done => "Done",
        .err => "Failed",
        .canceled => "Canceled",
    };
}

/// One imported game ready for the UI thread to upsert. Strings are
/// alloc-owned; UI consumes via `nextStaged()` which transfers
/// ownership and removes the entry.
pub const StagedRow = struct {
    game: library.Game,
    /// Set when this imported game had an install dir that was
    /// successfully migrated. Null when the source had no install or
    /// when migration failed (game row still gets imported).
    install: ?library.Install = null,
    /// Migration error message if any; non-null = migration failed but
    /// the game row is still being staged for upsert. UI converts to
    /// a warn toast so the user knows which install needs manual love.
    migrate_err: ?[]const u8 = null,
};

pub const Job = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    win: ?*dvui.Window,

    source: Source,
    /// Absolute path to the source data file (sqlite for F95Checker,
    /// JSON for xLibrary). Alloc-owned.
    data_path: []u8,
    /// Absolute path to the source's games-base-dir (relative install
    /// paths are joined against this). Alloc-owned.
    games_base_dir: []u8,
    /// f69's library root — where migrated installs land. Borrowed
    /// from `RuntimeInfo`; lives for the whole app run.
    library_root: []const u8,

    /// Transfer mode picked by the user. `.link` is the default for
    /// DB-driven imports because it's the safest — no source
    /// mutation, no risk of repeating the 2026-05-28
    /// `~/.config/f95checker/` data-loss incident.
    mode: Mode = .link,

    /// Thread-ids the UI already had at start time, so the worker
    /// knows which games to skip without querying the DB. Alloc-owned
    /// keys; freed in deinit.
    existing_ids: std.AutoHashMap(u64, void),

    phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.queued)),
    cancel: std.atomic.Value(bool) = .init(false),
    progress_done: std.atomic.Value(u32) = .init(0),
    progress_total: std.atomic.Value(u32) = .init(0),
    games_imported: std.atomic.Value(u32) = .init(0),
    installs_migrated: std.atomic.Value(u32) = .init(0),
    skipped: std.atomic.Value(u32) = .init(0),

    /// Name of the game currently being migrated, for the banner.
    /// Mutex-protected because the worker writes it and the UI reads
    /// during render.
    current_mu: std.Io.Mutex = .init,
    current_buf: [128]u8 = undefined,
    current_len: u8 = 0,

    /// Worker → UI handoff. Worker appends, UI pops from `stage[0..stage_drained]`.
    stage_mu: std.Io.Mutex = .init,
    stage: std.ArrayList(StagedRow) = .empty,
    stage_drained: usize = 0,

    err_buf: [192]u8 = undefined,
    err_len: u16 = 0,

    thread: ?std.Thread = null,

    pub fn currentPhase(self: *const Job) Phase {
        // `.acquire` pairs with the worker's `.release` store on
        // phase transitions, making the err_buf / err_len writes
        // that precede the store visible. `.monotonic` would risk
        // the UI seeing phase=.err with garbage error bytes.
        return @enumFromInt(self.phase.load(.acquire));
    }

    pub fn errMessage(self: *const Job) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    pub fn currentSlice(self: *Job) []const u8 {
        return self.current_buf[0..self.current_len];
    }

    pub fn deinit(self: *Job, alloc: std.mem.Allocator) void {
        if (self.thread) |t| t.join();
        self.thread = null;
        alloc.free(self.data_path);
        alloc.free(self.games_base_dir);
        self.existing_ids.deinit();
        // Free any un-drained staged rows.
        for (self.stage.items[self.stage_drained..]) |*r| freeStagedRow(alloc, r);
        self.stage.deinit(alloc);
        self.* = undefined;
    }
};

fn freeStagedRow(alloc: std.mem.Allocator, r: *StagedRow) void {
    alloc.free(r.game.name);
    if (r.game.developer) |s| alloc.free(s);
    if (r.game.cover_url) |s| alloc.free(s);
    if (r.game.description_md) |s| alloc.free(s);
    if (r.game.changelog_md) |s| alloc.free(s);
    if (r.game.notes) |s| alloc.free(s);
    if (r.game.latest_version) |s| alloc.free(s);
    for (r.game.tags) |t| alloc.free(t);
    if (r.game.tags.len > 0) alloc.free(r.game.tags);
    if (r.install) |*i| {
        alloc.free(i.version);
        alloc.free(i.install_path);
        if (i.executable) |s| alloc.free(s);
        if (i.launch_args) |s| alloc.free(s);
        alloc.free(i.recipe_id);
    }
    if (r.migrate_err) |s| alloc.free(s);
}

/// Spawn the worker thread. Returns once the thread is detached/spawned.
pub fn start(job: *Job) !void {
    if (job.thread != null) return error.AlreadyRunning;
    job.thread = try std.Thread.spawn(.{}, workerMain, .{job});
}

/// Worker entry point. Reads the source bundle, then per-game:
/// skips existing, migrates the install dir if any, stages a row for
/// the UI thread to upsert. All filesystem work happens here; zero
/// SQLite access.
fn workerMain(job: *Job) void {
    job.phase.store(@intFromEnum(Phase.reading), .release);
    if (job.win) |w| job_mod.refreshDebounced(w, @src());

    var bundle = readBundle(job) catch |e| {
        setErr(job, e, "reading source data");
        return;
    };
    defer bundle.deinit();

    job.progress_total.store(@intCast(bundle.games.len), .release);
    job.phase.store(@intFromEnum(Phase.migrating), .release);
    if (job.win) |w| job_mod.refreshDebounced(w, @src());

    var done: u32 = 0;
    for (bundle.games) |*imp_g| {
        if (job.cancel.load(.monotonic)) {
            job.phase.store(@intFromEnum(Phase.canceled), .release);
            return;
        }

        defer {
            done += 1;
            job.progress_done.store(done, .release);
            if (job.win) |w| job_mod.refreshDebounced(w, @src());
        }

        setCurrent(job, imp_g.name);

        if (job.existing_ids.contains(imp_g.thread_id)) {
            _ = job.skipped.fetchAdd(1, .monotonic);
            continue;
        }

        processOne(job, imp_g) catch |e| {
            log.warn("import: game {d} ({s}) failed: {s}", .{ imp_g.thread_id, imp_g.name, @errorName(e) });
        };
    }

    job.phase.store(@intFromEnum(Phase.done), .release);
    if (job.win) |w| job_mod.refreshDebounced(w, @src());
}

fn readBundle(job: *Job) !importers.Bundle {
    return switch (job.source) {
        .f95checker => try importers.f95checker.loadFromDb(job.alloc, job.data_path),
        .xlibrary => try importers.xlibrary.loadFromJson(job.alloc, job.io, job.data_path),
    };
}

/// Migrate one game's install (if any) + stage the upsert.
fn processOne(job: *Job, imp_g: *const importers.ImportedGame) !void {
    var staged: StagedRow = .{
        .game = try buildGameRow(job.alloc, imp_g),
    };

    // If there's an install dir, migrate it. On failure we still stage
    // the game row so the user gets the library entry; the migration
    // error rides along as a per-row warning.
    if (imp_g.installDirRel()) |sub_dir| install_blk: {
        // SAFETY: reject any sub_dir that's empty, absolute, or
        // contains traversal. installDirRel already filters these
        // but a second check costs nothing and stops a future bug
        // in the parser from rolling into `migrate.copyVerifyDelete →
        // deleteTree(games_base_dir)`. Lives next to the bufPrint to
        // make the invariant obvious at the call site.
        if (sub_dir.len == 0 or sub_dir[0] == '/' or sub_dir[0] == '\\' or
            std.mem.eql(u8, sub_dir, "..") or std.mem.eql(u8, sub_dir, ".") or
            std.mem.indexOfAny(u8, sub_dir, "/\\") != null or
            std.mem.indexOf(u8, sub_dir, "..") != null)
        {
            staged.migrate_err = try std.fmt.allocPrint(job.alloc, "unsafe install sub-path rejected: '{s}'", .{sub_dir});
            log.warn("import: refusing unsafe sub_dir='{s}' for tid={d} ({s})", .{ sub_dir, imp_g.thread_id, imp_g.name });
            break :install_blk;
        }
        var src_buf: [1024]u8 = undefined;
        const src_dir = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ job.games_base_dir, sub_dir }) catch {
            staged.migrate_err = try job.alloc.dupe(u8, "install path too long");
            break :install_blk;
        };
        // Skip if source doesn't actually exist — the user's source
        // DB referenced a directory they've already moved/deleted.
        std.Io.Dir.cwd().access(job.io, src_dir, .{}) catch {
            staged.migrate_err = try std.fmt.allocPrint(job.alloc, "source missing: {s}", .{src_dir});
            break :install_blk;
        };

        // Mode-dependent: link skips migrate entirely; move and copy
        // both go through copyVerifyDelete with `keep_source = (mode
        // == .copy)`. The destination is f69's library_root layout
        // for move/copy; link records the source dir directly.
        var dst_buf: [1024]u8 = undefined;
        var install_dir_owned: []u8 = undefined;
        switch (job.mode) {
            .link => {
                install_dir_owned = job.alloc.dupe(u8, src_dir) catch {
                    staged.migrate_err = try job.alloc.dupe(u8, "out of memory");
                    break :install_blk;
                };
            },
            .move, .copy => {
                const dst_dir_local = std.fmt.bufPrint(&dst_buf, "{s}/{d}/imported", .{ job.library_root, imp_g.thread_id }) catch {
                    staged.migrate_err = try job.alloc.dupe(u8, "destination path too long");
                    break :install_blk;
                };
                const dst_dir = try job.alloc.dupe(u8, dst_dir_local);
                errdefer job.alloc.free(dst_dir);

                _ = importers.migrate.copyVerifyDelete(job.alloc, job.io, src_dir, dst_dir, .{
                    .cancel = &job.cancel,
                    .keep_source = (job.mode == .copy),
                }) catch |e| {
                    staged.migrate_err = try std.fmt.allocPrint(job.alloc, "{s}: {s}", .{ src_dir, @errorName(e) });
                    job.alloc.free(dst_dir);
                    break :install_blk;
                };
                install_dir_owned = dst_dir;
            },
        }
        errdefer job.alloc.free(install_dir_owned);

        // Build the Install row. Path = install_dir_owned (dst for
        // move/copy, src for link); executable = `<dir>/<exe_basename>`.
        const exe_rel = imp_g.install_executable_rel.?; // implied by installDirRel != null
        const exe_basename = if (std.mem.indexOfAny(u8, exe_rel, "/\\")) |sep| exe_rel[sep + 1 ..] else exe_rel;
        const version_str = imp_g.version orelse "unversioned";

        var inst_id: [36]u8 = undefined;
        generateUuid(job.io, &inst_id);

        const now = std.Io.Clock.Timestamp.now(job.io, .real);
        const now_s: i64 = @intCast(@divTrunc(now.raw.toNanoseconds(), 1_000_000_000));

        staged.install = .{
            .id = inst_id,
            .game_thread_id = imp_g.thread_id,
            .version = try job.alloc.dupe(u8, version_str),
            .install_path = install_dir_owned,
            .executable = try std.fmt.allocPrint(job.alloc, "{s}/{s}", .{ install_dir_owned, exe_basename }),
            .launch_args = null,
            .recipe_id = try job.alloc.dupe(u8, ""), // no recipe — imported
            .installed_at = now_s,
            .name = null,
            .source = .imported,
        };
        _ = job.installs_migrated.fetchAdd(1, .monotonic);
    }

    _ = job.games_imported.fetchAdd(1, .monotonic);

    // Hand off to UI thread.
    job.stage_mu.lockUncancelable(job.io);
    defer job.stage_mu.unlock(job.io);
    job.stage.append(job.alloc, staged) catch {
        // OOM — undo the staged row so we don't leak.
        freeStagedRow(job.alloc, &staged);
    };
}

/// Build a fresh `library.Game` from the ImportedGame, duping every
/// string into the worker's allocator so the staged row owns it.
fn buildGameRow(alloc: std.mem.Allocator, imp_g: *const importers.ImportedGame) !library.Game {
    var g: library.Game = .{
        .f95_thread_id = imp_g.thread_id,
        .name = try alloc.dupe(u8, imp_g.name),
    };
    errdefer alloc.free(g.name);

    if (imp_g.developer) |s| g.developer = try alloc.dupe(u8, s);
    if (imp_g.cover_url) |s| g.cover_url = try alloc.dupe(u8, s);
    if (imp_g.description) |s| g.description_md = try alloc.dupe(u8, s);
    if (imp_g.changelog) |s| g.changelog_md = try alloc.dupe(u8, s);
    if (imp_g.notes) |s| g.notes = try alloc.dupe(u8, s);
    if (imp_g.version) |s| g.latest_version = try alloc.dupe(u8, s);
    g.rating = imp_g.rating;
    g.vote_count = imp_g.vote_count;
    g.user_rating = imp_g.user_rating;
    g.last_played_at = imp_g.last_played_at;

    // Tags: dupe each into the same allocator + an array.
    if (imp_g.tags.len > 0) {
        var arr = try alloc.alloc([]const u8, imp_g.tags.len);
        for (imp_g.tags, 0..) |t, i| arr[i] = try alloc.dupe(u8, t);
        g.tags = arr;
    }

    // Map source-side completion text to our enum where we can.
    if (imp_g.completion_status) |s| {
        g.completion_status = mapCompletion(s);
    }

    return g;
}

fn mapCompletion(s: []const u8) library.CompletionStatus {
    if (eqi(s, "completed")) return .completed;
    if (eqi(s, "playing") or eqi(s, "in progress") or eqi(s, "in_progress") or eqi(s, "started")) return .in_progress;
    if (eqi(s, "abandoned")) return .abandoned;
    if (eqi(s, "on hold") or eqi(s, "on_hold") or eqi(s, "in queue") or eqi(s, "in_queue")) return .in_queue;
    if (eqi(s, "replaying")) return .replaying;
    return .not_started; // includes "Not Started", "", anything unknown
}

fn eqi(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn setCurrent(job: *Job, name: []const u8) void {
    job.current_mu.lockUncancelable(job.io);
    defer job.current_mu.unlock(job.io);
    const n: usize = @min(name.len, job.current_buf.len);
    @memcpy(job.current_buf[0..n], name[0..n]);
    job.current_len = @intCast(n);
}

fn setErr(job: *Job, e: anyerror, ctx: []const u8) void {
    const msg = std.fmt.bufPrint(&job.err_buf, "{s}: {s}", .{ ctx, @errorName(e) }) catch ctx;
    job.err_len = @intCast(msg.len);
    job.phase.store(@intFromEnum(Phase.err), .release);
    if (job.win) |w| job_mod.refreshDebounced(w, @src());
}

fn generateUuid(io: std.Io, out: *[36]u8) void {
    var bytes: [16]u8 = undefined;
    io.randomSecure(&bytes) catch io.random(&bytes);
    // RFC 4122 v4 stamp.
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    const hex = "0123456789abcdef";
    var i: usize = 0;
    for (bytes, 0..) |b, n| {
        if (n == 4 or n == 6 or n == 8 or n == 10) {
            out[i] = '-';
            i += 1;
        }
        out[i] = hex[b >> 4];
        out[i + 1] = hex[b & 0x0F];
        i += 2;
    }
}
