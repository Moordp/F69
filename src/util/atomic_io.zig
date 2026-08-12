// WINDOWS, READ THIS FIRST (established 2026-08-11 by tracing the Layer-1
// suite running natively on the Win11 VM):
//
//   1. `std.Io.Dir.createDirPath` DOES NOT RETURN on Windows. It used to be
//      called unconditionally on every write here; it is now the rare fallback
//      taken only when the target directory is genuinely missing.
//   2. READING a file immediately after this function writes it ALSO blocks.
//      Trace from `recipe/repository.zig`: the thread index hits, then
//      `findGame` -> `zon.loadGame` never returns. The suite parks there.
//
// Both are `std.Io` (Zig 0.16) Windows gaps, not f69 logic. Item 2 is still
// open and is the remaining blocker for running the suite on Windows; it needs
// either an upstream fix or a Win32 shim for the read path.
//
// Atomic file write — tmp + rename so a crash mid-write can never leave
// a partially-written file. Used everywhere the codebase persists state
// (recipe ZON, tracker JSON, settings files, manager_jobs, mod queue,
// tags.txt, …).
//
// The pattern is simple but every site that hand-rolled it added some
// variant of `<path>.tmp` extension + a `defer close` ordering bug
// waiting to happen. Centralising the write removes that surface.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Error = error{
    OutOfMemory,
    WriteFailed,
};

/// Write `bytes` to `path` atomically. Creates parent dirs if missing,
/// writes to `<path>.tmp`, then renames into place. Caller-owned path
/// + bytes (we don't take ownership).
pub fn writeFileAtomic(io: Io, path: []const u8, bytes: []const u8) Error!void {
    // WINDOWS: write straight to the destination.
    //
    // The tmp+rename dance is what gives POSIX its crash-safety, but on Windows
    // the rename appears to leave the destination un-openable — a read issued
    // right after this function blocks forever (see the header note). Writing
    // in place trades the atomicity window for a file that can actually be read
    // back. Revisit once the read path is fixed, ideally via ReplaceFileW which
    // is the real Win32 equivalent of an atomic replace.
    // WINDOWS: the whole write goes through libc — the std.Io write path
    // (createFile/writer) is where the lean headless test exe parks
    // deterministically on the VM (2026-08-12, uiscale-persist), same std.Io
    // defect family as the reads shimmed in zon_loader/util_setting. libc
    // I/O has no async machinery to park; windows-gnu always links mingw
    // libc. Write-in-place was already the Windows semantic here (see the
    // header note); ReplaceFileW-based atomicity stays future work.
    if (builtin.os.tag == .windows) {
        var pz_buf: [4096]u8 = undefined;
        const pz = std.fmt.bufPrintZ(&pz_buf, "{s}", .{path}) catch return Error.WriteFailed;
        const f = std.c.fopen(pz.ptr, "wb") orelse blk: {
            // Parent dir likely missing — build it, then retry once.
            if (std.fs.path.dirname(path)) |dir| {
                std.Io.Dir.cwd().createDirPath(io, dir) catch return Error.WriteFailed;
            }
            break :blk std.c.fopen(pz.ptr, "wb") orelse return Error.WriteFailed;
        };
        defer _ = std.c.fclose(f);
        if (bytes.len > 0 and std.c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) {
            return Error.WriteFailed;
        }
        return;
    }
    var tmp_buf: [4096]u8 = undefined;
    const tmp_path = if (builtin.os.tag == .windows) path else blk: {
        break :blk std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return Error.WriteFailed;
    };

    // Try the write FIRST and only build the directory chain if it actually
    // turns out to be missing.
    //
    // This used to call `createDirPath` unconditionally on every single write.
    // Two reasons that was wrong: the parent almost always already exists, so
    // it was an entire directory walk per write on a path the app hits
    // constantly (settings, recipe ZON, cookie, mod queue); and on Windows
    // `std.Io.Dir.createDirPath` does not return at all — the Layer-1 suite
    // parked there forever, with tracing showing "createDirPath" as the last
    // thing that ever printed. Making it the rare fallback keeps the common
    // path off the broken call entirely.
    var tmp = std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true }) catch |e| switch (e) {
        error.FileNotFound => blk: {
            if (std.fs.path.dirname(path)) |dir| {
                std.Io.Dir.cwd().createDirPath(io, dir) catch return Error.WriteFailed;
            }
            break :blk std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true }) catch return Error.WriteFailed;
        },
        else => return Error.WriteFailed,
    };
    {
        defer tmp.close(io);
        var fw_buf: [4096]u8 = undefined;
        var fw = tmp.writer(io, &fw_buf);
        fw.interface.writeAll(bytes) catch return Error.WriteFailed;
        fw.interface.flush() catch return Error.WriteFailed;
        }

    if (builtin.os.tag != .windows) {
        renameReplace(io, tmp_path, path) catch return Error.WriteFailed;
    }
}

/// Move `tmp_path` onto `path`, replacing it.
///
/// POSIX `rename(2)` replaces the destination atomically and that is the whole
/// basis of this module. Windows does not give the same guarantee: a move onto
/// an existing file can fail outright, and a *transient* sharing violation is
/// routine there — Defender and the Search indexer both open files moments
/// after they are written, and the app's own persistence (settings, recipe ZON,
/// the session cookie, the mod queue) writes constantly.
///
/// So on Windows: retry a bounded number of times, dropping the destination
/// between attempts. Still crash-safe — at every instant either the original or
/// the fully-written tmp exists.
fn renameReplace(io: Io, tmp_path: []const u8, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (builtin.os.tag != .windows) {
        return cwd.rename(tmp_path, cwd, path, io);
    }
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        if (cwd.rename(tmp_path, cwd, path, io)) |_| {
            return;
        } else |e| {
            if (attempt >= 10) return e;
            // Destination in the way (or briefly locked): remove and retry.
            cwd.deleteFile(io, path) catch {};
        }
    }
}

const testing = std.testing;
const test_env = @import("util_test_env");

test "writeFileAtomic: round-trips short content" {
    var env = try test_env.TestEnv.init(testing.allocator, "atomic-io-test");
    defer env.deinit();

    const path = try env.path("out.txt");
    defer testing.allocator.free(path);

    try writeFileAtomic(env.io, path, "hello atomic world\n");

    const bytes = try std.Io.Dir.cwd().readFileAlloc(env.io, path, testing.allocator, .limited(64));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("hello atomic world\n", bytes);
}

test "writeFileAtomic: overwrite is atomic" {
    var env = try test_env.TestEnv.init(testing.allocator, "atomic-io-overwrite");
    defer env.deinit();

    const path = try env.path("out.txt");
    defer testing.allocator.free(path);

    try writeFileAtomic(env.io, path, "first");
    try writeFileAtomic(env.io, path, "second");

    const bytes = try std.Io.Dir.cwd().readFileAlloc(env.io, path, testing.allocator, .limited(64));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("second", bytes);
}

test "writeFileAtomic: overwriting long content with short leaves no stale tail" {
    // Critical for the Windows write-in-place branch: without `.truncate`
    // a shorter rewrite would leave the old file's tail bytes appended to
    // the new content — silently corrupting every settings file the first
    // time a value gets shorter.
    var env = try test_env.TestEnv.init(testing.allocator, "atomic-io-shrink");
    defer env.deinit();

    const path = try env.path("out.txt");
    defer testing.allocator.free(path);

    try writeFileAtomic(env.io, path, "a much longer first value than the second");
    try writeFileAtomic(env.io, path, "x");

    const bytes = try std.Io.Dir.cwd().readFileAlloc(env.io, path, testing.allocator, .limited(64));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("x", bytes);
}

test "writeFileAtomic: creates missing parent directories" {
    // Exercises the FileNotFound → createDirPath fallback arm, which is
    // the rare path since the unconditional-createDirPath fix.
    var env = try test_env.TestEnv.init(testing.allocator, "atomic-io-parents");
    defer env.deinit();

    const path = try env.path("a/b/c/out.txt");
    defer testing.allocator.free(path);

    try writeFileAtomic(env.io, path, "nested");

    const bytes = try std.Io.Dir.cwd().readFileAlloc(env.io, path, testing.allocator, .limited(64));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("nested", bytes);
}
