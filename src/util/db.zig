// Thin wrapper around karlseguin/zqlite. Exists so a future swap to a
// different binding is a single-file change rather than a project-wide
// refactor.
//
// zqlite ships sqlite3.c bundled (static link), so there's no system
// sqlite3 dependency to manage in flake.nix.

const std = @import("std");
const zqlite = @import("zqlite");

const log = std.log.scoped(.db);

pub const Error = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    StepFailed,
    NotFound,
    OutOfMemory,
};

pub const OpenFlags = struct {
    create: bool = true,
    readonly: bool = false,
};

pub const Conn = struct {
    inner: zqlite.Conn,

    pub fn open(path: []const u8, alloc: std.mem.Allocator, flags: OpenFlags) Error!Conn {
        // zqlite wants a [*:0]const u8 path.
        const cpath = alloc.dupeSentinel(u8, path, 0) catch return Error.OutOfMemory;
        defer alloc.free(cpath);

        var bits: c_int = 0;
        if (flags.readonly) {
            bits = zqlite.OpenFlags.ReadOnly;
        } else {
            bits = zqlite.OpenFlags.ReadWrite;
            if (flags.create) bits |= zqlite.OpenFlags.Create;
        }

        const c = zqlite.open(cpath, bits) catch |e| {
            log.err("sqlite open failed for '{s}': {s} (create={}, readonly={})", .{ path, @errorName(e), flags.create, flags.readonly });
            return Error.OpenFailed;
        };
        return .{ .inner = c };
    }

    pub fn close(self: *Conn) void {
        self.inner.close();
        self.* = undefined;
    }

    /// Last SQLite error message for this connection (sqlite3_errmsg), as a
    /// slice. Valid right after a failed operation.
    pub fn lastError(self: *Conn) []const u8 {
        return std.mem.span(self.inner.lastError());
    }

    pub fn exec(self: *Conn, sql: []const u8) Error!void {
        // execNoArgs needs a [*:0]const u8; allocate a NUL-terminated copy.
        var buf: [4096]u8 = undefined;
        if (sql.len + 1 > buf.len) return Error.ExecFailed;
        @memcpy(buf[0..sql.len], sql);
        buf[sql.len] = 0;
        const z: [*:0]const u8 = @ptrCast(&buf);
        self.inner.execNoArgs(z) catch {
            log.err("sqlite exec failed: {s} — SQL: {s}", .{ self.lastError(), sql });
            return Error.ExecFailed;
        };
    }

    /// Multi-statement migration script. Splits on ';' boundaries (naive —
    /// fine for our DDL, won't handle ';' inside string literals).
    pub fn execScript(self: *Conn, alloc: std.mem.Allocator, sql: []const u8) Error!void {
        var it = std.mem.splitScalar(u8, sql, ';');
        while (it.next()) |raw| {
            const stmt = std.mem.trim(u8, raw, " \t\r\n");
            if (stmt.len == 0) continue;
            const z = alloc.dupeSentinel(u8, stmt, 0) catch return Error.OutOfMemory;
            defer alloc.free(z);
            self.inner.execNoArgs(z) catch {
                log.err("sqlite migration statement failed: {s} — stmt: {s}", .{ self.lastError(), stmt });
                return Error.ExecFailed;
            };
        }
    }

    pub fn pragmaInt(self: *Conn, alloc: std.mem.Allocator, name: []const u8) Error!i64 {
        const sql = std.fmt.allocPrint(alloc, "PRAGMA {s}", .{name}) catch return Error.OutOfMemory;
        defer alloc.free(sql);
        var maybe_row = self.inner.row(sql, .{}) catch {
            log.err("sqlite pragma read failed: {s} — {s}", .{ self.lastError(), sql });
            return Error.ExecFailed;
        };
        if (maybe_row) |*r| {
            defer r.deinit();
            return r.int(0);
        }
        return 0;
    }

    pub fn setPragmaInt(self: *Conn, alloc: std.mem.Allocator, name: []const u8, value: i64) Error!void {
        const sql = std.fmt.allocPrint(alloc, "PRAGMA {s} = {d}", .{ name, value }) catch return Error.OutOfMemory;
        defer alloc.free(sql);
        const z = alloc.dupeSentinel(u8, sql, 0) catch return Error.OutOfMemory;
        defer alloc.free(z);
        self.inner.execNoArgs(z) catch {
            log.err("sqlite pragma set failed: {s} — {s}", .{ self.lastError(), sql });
            return Error.ExecFailed;
        };
    }
};

test "open in-memory + create table + count rows" {
    var conn = try Conn.open(":memory:", std.testing.allocator, .{});
    defer conn.close();

    try conn.exec("CREATE TABLE t (k INTEGER PRIMARY KEY, v TEXT)");
    try conn.exec("INSERT INTO t VALUES (1, 'one'), (2, 'two')");

    var rows = try conn.inner.rows("SELECT count(*) FROM t", .{});
    defer rows.deinit();
    const r = rows.next().?;
    try std.testing.expectEqual(@as(i64, 2), r.int(0));
}
