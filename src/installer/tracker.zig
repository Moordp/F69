// Per-install file tracker. Records every path written by an install
// step so uninstall can reverse the adds. No backup of pre-existing
// files — quality F95 mods can be 15GB+, doubling that for
// "just in case" rollback was a non-starter.
//
// On-disk format: line-delimited JSON at `<install>/.f69-mods.json`.
// Each entry is a self-contained JSON object — easy to inspect with
// `jq`, easy to append to without rewriting the whole file (future
// optimization; today we serialize + atomic-rename the whole thing).

const std = @import("std");
const Io = std.Io;
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const atomic_io = @import("util_atomic_io");

pub const Tracker = struct {
    alloc: std.mem.Allocator,
    io: Io,
    log_path: []const u8,
    entries: std.ArrayList(dom.InstallLog.Entry),

    pub fn init(alloc: std.mem.Allocator, io: Io, log_path: []const u8) Tracker {
        return .{
            .alloc = alloc,
            .io = io,
            .log_path = log_path,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Tracker) void {
        for (self.entries.items) |e| {
            if (e.mod_id.len > 0) self.alloc.free(e.mod_id);
            self.alloc.free(e.path);
        }
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }

    /// Drop every entry whose `mod_id` matches `mod_id`. Caller is
    /// responsible for calling `flush` afterwards to persist.
    pub fn removeMod(self: *Tracker, mod_id: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            if (std.mem.eql(u8, e.mod_id, mod_id)) {
                _ = self.entries.orderedRemove(i);
                if (e.mod_id.len > 0) self.alloc.free(e.mod_id);
                self.alloc.free(e.path);
            } else {
                i += 1;
            }
        }
    }

    /// True iff any tracker entry was recorded for `mod_id`.
    pub fn hasMod(self: *const Tracker, mod_id: []const u8) bool {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.mod_id, mod_id)) return true;
        }
        return false;
    }

    /// Append an entry. Caller's strings are duplicated so the tracker
    /// can outlive whatever spawned the entry.
    pub fn record(self: *Tracker, entry: dom.InstallLog.Entry) errs.Error!void {
        const mod_id_owned = if (entry.mod_id.len > 0)
            self.alloc.dupe(u8, entry.mod_id) catch return errs.Error.OutOfMemory
        else
            "";
        errdefer if (mod_id_owned.len > 0) self.alloc.free(mod_id_owned);

        const path_owned = self.alloc.dupe(u8, entry.path) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(path_owned);

        self.entries.append(self.alloc, .{
            .mod_id = mod_id_owned,
            .path = path_owned,
            .kind = entry.kind,
            .sha256 = entry.sha256,
            .backup_mode = entry.backup_mode,
        }) catch return errs.Error.OutOfMemory;
    }

    /// Atomic-write the tracker's entries to `log_path` as
    /// line-delimited JSON (tmp file + rename).
    pub fn flush(self: *Tracker) errs.Error!void {
        var aw = Io.Writer.Allocating.initCapacity(self.alloc, 4096) catch return errs.Error.OutOfMemory;
        defer aw.deinit();

        for (self.entries.items) |e| {
            try writeJsonEntry(self.alloc, &aw.writer, e);
            aw.writer.writeAll("\n") catch return errs.Error.FileWriteFailed;
        }

        atomic_io.writeFileAtomic(self.io, self.log_path, aw.writer.buffered()) catch return errs.Error.FileWriteFailed;
    }

    /// Parse the on-disk tracker. Returns an `InstallLog` whose `entries`
    /// slice is allocator-owned (caller invokes `InstallLog.deinit`).
    /// Missing file → empty log (not an error).
    pub fn load(alloc: std.mem.Allocator, io: Io, log_path: []const u8) errs.Error!dom.InstallLog {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, log_path, alloc, .limited(8 * 1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => return .{ .entries = &.{} },
            else => return errs.Error.FileWriteFailed,
        };
        defer alloc.free(bytes);

        var entries: std.ArrayList(dom.InstallLog.Entry) = .empty;
        errdefer {
            for (entries.items) |e| {
                if (e.mod_id.len > 0) alloc.free(e.mod_id);
                alloc.free(e.path);
            }
            entries.deinit(alloc);
        }

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const e = parseJsonEntry(alloc, trimmed) catch continue;
            entries.append(alloc, e) catch return errs.Error.OutOfMemory;
        }
        const owned = entries.toOwnedSlice(alloc) catch return errs.Error.OutOfMemory;
        return .{ .entries = owned };
    }
};

// ============================================================
//  JSON encode / decode — line-per-entry
// ============================================================

const JsonEntry = struct {
    mod_id: []const u8 = "",
    path: []const u8,
    kind: []const u8, // serialized as the @tagName of dom.InstallLog.Kind
    sha256_hex: ?[]const u8 = null,
    /// Stored as @tagName(BackupMode). Optional so logs written before
    /// this field existed parse cleanly as `.none`.
    backup_mode: ?[]const u8 = null,
};

fn writeJsonEntry(alloc: std.mem.Allocator, w: *Io.Writer, e: dom.InstallLog.Entry) errs.Error!void {
    var sha_buf: [64]u8 = undefined;
    const sha_owned: ?[]const u8 = if (e.sha256) |h| blk: {
        const hex = std.fmt.bytesToHex(h, .lower);
        @memcpy(&sha_buf, &hex);
        break :blk sha_buf[0..64];
    } else null;

    // Only emit backup_mode when non-default; keeps logs identical for
    // the common `.none` case (the vast majority of entries) and lets
    // older readers ignore the new field as unknown.
    const bm: ?[]const u8 = if (e.backup_mode == .none) null else @tagName(e.backup_mode);

    const j = JsonEntry{
        .mod_id = e.mod_id,
        .path = e.path,
        .kind = @tagName(e.kind),
        .sha256_hex = sha_owned,
        .backup_mode = bm,
    };
    _ = alloc;
    std.json.Stringify.value(j, .{}, w) catch return errs.Error.FileWriteFailed;
}

fn parseJsonEntry(alloc: std.mem.Allocator, json_line: []const u8) !dom.InstallLog.Entry {
    var parsed = try std.json.parseFromSlice(JsonEntry, alloc, json_line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const j = parsed.value;

    var sha: ?[32]u8 = null;
    if (j.sha256_hex) |hex| {
        if (hex.len == 64) {
            var out: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidSha;
            sha = out;
        }
    }

    return .{
        .mod_id = if (j.mod_id.len > 0) try alloc.dupe(u8, j.mod_id) else "",
        .path = try alloc.dupe(u8, j.path),
        .kind = parseKind(j.kind),
        .sha256 = sha,
        .backup_mode = parseBackupMode(j.backup_mode),
    };
}

fn parseKind(s: []const u8) dom.InstallLog.Kind {
    if (std.mem.eql(u8, s, "added_file")) return .added_file;
    if (std.mem.eql(u8, s, "modified_file")) return .modified_file;
    if (std.mem.eql(u8, s, "created_dir")) return .created_dir;
    return .mounted_overlay;
}

fn parseBackupMode(s_opt: ?[]const u8) dom.BackupMode {
    const s = s_opt orelse return .none;
    if (std.mem.eql(u8, s, "copy")) return .copy;
    return .none;
}

// ============================================================
//  tests
// ============================================================

const testing = std.testing;
const test_env = @import("util_test_env");

test "Tracker: empty round-trip" {
    var env = try test_env.TestEnv.init(testing.allocator, "tracker-empty");
    defer env.deinit();

    const path = try env.path("tracker.json");
    defer testing.allocator.free(path);

    var t = Tracker.init(testing.allocator, env.io, path);
    defer t.deinit();
    try t.flush();

    var log = try Tracker.load(testing.allocator, env.io, path);
    defer log.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), log.entries.len);
}

test "Tracker: single added_file round-trip" {
    var env = try test_env.TestEnv.init(testing.allocator, "tracker-single");
    defer env.deinit();

    const path = try env.path("tracker.json");
    defer testing.allocator.free(path);

    var t = Tracker.init(testing.allocator, env.io, path);
    defer t.deinit();

    try t.record(.{
        .mod_id = "summertime-saga.cheat-menu",
        .path = "game/scripts/cheats.rpyc",
        .kind = .added_file,
        .sha256 = @splat(0xAB),
    });
    try t.flush();

    var log = try Tracker.load(testing.allocator, env.io, path);
    defer log.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), log.entries.len);
    try testing.expectEqualStrings("summertime-saga.cheat-menu", log.entries[0].mod_id);
    try testing.expectEqualStrings("game/scripts/cheats.rpyc", log.entries[0].path);
    try testing.expectEqual(dom.InstallLog.Kind.added_file, log.entries[0].kind);
}

test "Tracker: mixed entries round-trip in order" {
    var env = try test_env.TestEnv.init(testing.allocator, "tracker-mixed");
    defer env.deinit();

    const path = try env.path("tracker.json");
    defer testing.allocator.free(path);

    var t = Tracker.init(testing.allocator, env.io, path);
    defer t.deinit();
    try t.record(.{ .mod_id = "a", .path = "p1", .kind = .added_file });
    try t.record(.{ .mod_id = "a", .path = "p2", .kind = .created_dir });
    try t.record(.{ .mod_id = "b", .path = "p3", .kind = .modified_file });
    try t.flush();

    var log = try Tracker.load(testing.allocator, env.io, path);
    defer log.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), log.entries.len);
    try testing.expectEqualStrings("a", log.entries[0].mod_id);
    try testing.expectEqualStrings("a", log.entries[1].mod_id);
    try testing.expectEqualStrings("b", log.entries[2].mod_id);
    try testing.expectEqual(dom.InstallLog.Kind.modified_file, log.entries[2].kind);
}

test "Tracker: backup_mode round-trip" {
    var env = try test_env.TestEnv.init(testing.allocator, "tracker-backup");
    defer env.deinit();

    const path = try env.path("tracker.json");
    defer testing.allocator.free(path);

    var t = Tracker.init(testing.allocator, env.io, path);
    defer t.deinit();
    try t.record(.{ .mod_id = "m1", .path = "p1", .kind = .modified_file, .backup_mode = .copy });
    try t.record(.{ .mod_id = "m1", .path = "p2", .kind = .added_file });
    try t.flush();

    var log = try Tracker.load(testing.allocator, env.io, path);
    defer log.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), log.entries.len);
    try testing.expectEqual(dom.BackupMode.copy, log.entries[0].backup_mode);
    try testing.expectEqual(dom.BackupMode.none, log.entries[1].backup_mode);
}

test "Tracker.load: missing file → empty log" {
    var env = try test_env.TestEnv.init(testing.allocator, "tracker-nope");
    defer env.deinit();

    const missing = try env.path("does-not-exist.json");
    defer testing.allocator.free(missing);

    var log = try Tracker.load(testing.allocator, env.io, missing);
    defer log.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), log.entries.len);
}
