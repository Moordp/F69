// Ren'Py Win→Linux conversion. Production port of
// `spikes/spike-03-renpy-convert.zig` (NixOS-validated 2026-05-08).
//
// Fixes applied vs the spike (per spike-03 findings):
//   - Symlink preservation in tree copy (recreates via `Dir.symLink`).
//   - Streaming reads via `File.Reader` → `File.Writer` (no `readFileAlloc`
//     for big files).
//   - Mode preservation on file copies (executable bit on python).
//   - Mode-aware launcher write (chmod +x via `setPermissions`).
//
// Network SDK fetch is deferred. The SDK must be pre-extracted at
// `<cache>/f69/convert/sdks/renpy-<v>/`; otherwise `Service.convert`
// returns `SdkNotCached` with the expected path.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.convert_renpy);
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const util_renpy = @import("util_renpy");

/// Detect the Ren'Py version that built this game. Thin shim over
/// `util_renpy.detectVersion` — the actual parsers live in the util
/// module so `compat/detect.zig` can share them without taking a
/// dependency on the (non-leaf) `convert` module.
pub fn detectVersion(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
) errs.Error!?[]u8 {
    return util_renpy.detectVersion(alloc, io, install_dir) catch return errs.Error.OutOfMemory;
}

// ============================================================
//  install: copy SDK Linux libs into the install dir
// ============================================================

/// Copy `lib/py3-linux-x86_64` (or py2, or linux-x86_64) + every
/// `lib/python*` dir from `sdk_dir` into `install_dir`. The launcher
/// picks whichever variants exist at runtime.
///
/// Symlinks are preserved (Ren'Py SDKs ship `lib/python` as a symlink
/// to the real `lib/python3.9` etc — losing it breaks the runtime).
/// File modes are preserved (the python interpreter is +x).
///
/// Counts every file + symlink across the kept dirs first, then copies
/// under phase "Copying runtime file i / n" with `tick(i, n)`;
/// `prog.stop()` is polled before each item → `Cancelled`.
pub fn installLinuxLibs(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    sdk_dir: []const u8,
    prog: dom.Progress,
) errs.Error!void {
    var sdk_lib_buf: [512]u8 = undefined;
    const sdk_lib = std.fmt.bufPrint(&sdk_lib_buf, "{s}/lib", .{sdk_dir}) catch return errs.Error.OutOfMemory;
    std.Io.Dir.cwd().access(io, sdk_lib, .{}) catch {
        log.warn("SDK has no `lib/` directory: {s}", .{sdk_dir});
        return errs.Error.SdkLayoutInvalid;
    };

    // Make sure the install dir's `lib/` exists.
    var install_lib_buf: [512]u8 = undefined;
    const install_lib = std.fmt.bufPrint(&install_lib_buf, "{s}/lib", .{install_dir}) catch return errs.Error.OutOfMemory;
    std.Io.Dir.cwd().createDirPath(io, install_lib) catch return errs.Error.LauncherWriteFailed;

    // ---- pick the runtime dirs ----
    var keep_names: std.ArrayList([]u8) = .empty;
    defer {
        for (keep_names.items) |n| alloc.free(n);
        keep_names.deinit(alloc);
    }
    {
        var sdk_lib_dir = std.Io.Dir.cwd().openDir(io, sdk_lib, .{ .iterate = true }) catch return errs.Error.SdkLayoutInvalid;
        defer sdk_lib_dir.close(io);
        var it = sdk_lib_dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const keep = std.mem.startsWith(u8, entry.name, "py3-linux-x86_64") or
                std.mem.startsWith(u8, entry.name, "py2-linux-x86_64") or
                std.mem.startsWith(u8, entry.name, "linux-x86_64") or
                std.mem.startsWith(u8, entry.name, "python");
            if (!keep) continue;
            const dup = alloc.dupe(u8, entry.name) catch return errs.Error.OutOfMemory;
            keep_names.append(alloc, dup) catch {
                alloc.free(dup);
                return errs.Error.OutOfMemory;
            };
        }
    }

    if (keep_names.items.len == 0) {
        log.warn("SDK `lib/` had no matching Linux runtime dirs", .{});
        return errs.Error.SdkLayoutInvalid;
    }

    // ---- pass 1: count ----
    var counter: CopyCounter = .{};
    for (keep_names.items) |name| {
        var src_buf: [640]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ sdk_lib, name }) catch return errs.Error.OutOfMemory;
        counter.total += try countTree(alloc, io, src);
    }

    // ---- pass 2: copy ----
    prog.tick(0, counter.total);
    for (keep_names.items) |name| {
        var src_buf: [640]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ sdk_lib, name }) catch return errs.Error.OutOfMemory;
        var dest_buf: [640]u8 = undefined;
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ install_lib, name }) catch return errs.Error.OutOfMemory;
        try copyTree(alloc, io, src, dest, prog, &counter);
    }

    log.info("installLinuxLibs: copied {d} dir(s), {d} item(s) from {s} → {s}", .{ keep_names.items.len, counter.done, sdk_lib, install_lib });
}

/// Running (done, total) across several `copyTree` calls, so one
/// install reports a single 1..n sequence.
pub const CopyCounter = struct {
    done: u64 = 0,
    total: u64 = 0,
};

/// Files + symlinks under `src` (what `copyTree` will tick for).
fn countTree(alloc: std.mem.Allocator, io: Io, src: []const u8) errs.Error!u64 {
    var src_dir = std.Io.Dir.cwd().openDir(io, src, .{ .access_sub_paths = true, .iterate = true }) catch return errs.Error.SdkLayoutInvalid;
    defer src_dir.close(io);
    var walker = src_dir.walk(alloc) catch return errs.Error.OutOfMemory;
    defer walker.deinit();
    var n: u64 = 0;
    while (walker.next(io) catch null) |entry| switch (entry.kind) {
        .file, .sym_link => n += 1,
        else => {},
    };
    return n;
}

/// Recursive copy preserving symlinks + file modes. Streams file
/// content (no `readFileAlloc`-style memory spikes). Each file or
/// symlink bumps `counter.done` and ticks `prog` under phase
/// "Copying runtime file i / n"; `prog.stop()` before each → `Cancelled`.
fn copyTree(
    alloc: std.mem.Allocator,
    io: Io,
    src: []const u8,
    dest: []const u8,
    prog: dom.Progress,
    counter: *CopyCounter,
) errs.Error!void {
    std.Io.Dir.cwd().createDirPath(io, dest) catch return errs.Error.LauncherWriteFailed;

    var src_dir = std.Io.Dir.cwd().openDir(io, src, .{ .access_sub_paths = true, .iterate = true }) catch return errs.Error.SdkLayoutInvalid;
    defer src_dir.close(io);

    var walker = src_dir.walk(alloc) catch return errs.Error.OutOfMemory;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        var dst_buf: [1024]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dest, entry.path }) catch return errs.Error.OutOfMemory;
        var src_buf: [1024]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src, entry.path }) catch return errs.Error.OutOfMemory;

        switch (entry.kind) {
            .directory => std.Io.Dir.cwd().createDirPath(io, dest_path) catch return errs.Error.LauncherWriteFailed,
            .file, .sym_link => {
                if (prog.stop()) return errs.Error.Cancelled;
                setCopyPhase(prog, counter.done + 1, counter.total);
                if (entry.kind == .file) {
                    copyFile(io, src_path, dest_path) catch return errs.Error.LauncherWriteFailed;
                } else {
                    copySymlink(alloc, io, src_path, dest_path) catch return errs.Error.LauncherWriteFailed;
                }
                counter.done += 1;
                prog.tick(counter.done, counter.total);
            },
            else => {}, // sockets, fifos, devices — skip
        }
    }
}

fn setCopyPhase(prog: dom.Progress, i: u64, n: u64) void {
    var buf: [64]u8 = undefined;
    prog.setPhase(std.fmt.bufPrint(&buf, "Copying runtime file {d} / {d}", .{ i, n }) catch "Copying runtime file");
}

/// Copy `src` → `dest` streaming; preserves source mode bits (notably
/// the executable bit on `lib/.../python`).
fn copyFile(io: Io, src: []const u8, dest: []const u8) !void {
    var in = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer in.close(io);

    if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var out = try std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true });
    defer out.close(io);

    // Stream copy — 64 KiB chunks. `chunk` distinct from `rd_buf` so
    // readSliceShort's @memcpy doesn't alias its own backing buffer.
    var rd_buf: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var wr_buf: [64 * 1024]u8 = undefined;
    var in_reader = in.reader(io, &rd_buf);
    var out_writer = out.writer(io, &wr_buf);
    while (true) {
        const got = in_reader.interface.readSliceShort(&chunk) catch break;
        if (got == 0) break;
        try out_writer.interface.writeAll(chunk[0..got]);
    }
    try out_writer.interface.flush();

    // Preserve mode bits (executable, etc.).
    const st = in.stat(io) catch return;
    try out.setPermissions(io, st.permissions);
}

/// Read the symlink target and recreate at `dest`. Failure to read is
/// fatal; failure to recreate (e.g. dest dir missing) is fatal too.
fn copySymlink(alloc: std.mem.Allocator, io: Io, src: []const u8, dest: []const u8) !void {
    // 4 KiB is enough for any sane symlink target; Linux `PATH_MAX` is
    // 4096. Use a heap buffer so we don't bake the assumption in.
    const buf = try alloc.alloc(u8, 4096);
    defer alloc.free(buf);
    const n = try std.Io.Dir.cwd().readLink(io, src, buf);
    const target = buf[0..n];

    if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    // If a stale dest exists from a previous run, drop it so symLink
    // doesn't fail with EEXIST.
    std.Io.Dir.cwd().deleteFile(io, dest) catch {};
    try std.Io.Dir.cwd().symLink(io, target, dest, .{});
}

// ============================================================
//  launcher
// ============================================================

/// Pick the launcher base name from a game's root dir. First non-noise
/// `<name>.py` wins (Ren'Py convention); falls back to `<name>.exe`.
pub fn findLauncherName(alloc: std.mem.Allocator, io: Io, install_dir: []const u8) errs.Error!?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, install_dir, .{ .access_sub_paths = true, .iterate = true }) catch return errs.Error.InstallNotFound;
    defer dir.close(io);

    var it = dir.iterate();
    var fallback_exe: ?[]u8 = null;
    errdefer if (fallback_exe) |x| alloc.free(x);

    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".py") and
            !std.mem.eql(u8, entry.name, "log.py") and
            !std.mem.eql(u8, entry.name, "__init__.py"))
        {
            const base = entry.name[0 .. entry.name.len - 3];
            if (fallback_exe) |x| alloc.free(x);
            return alloc.dupe(u8, base) catch errs.Error.OutOfMemory;
        }
        if (std.mem.endsWith(u8, entry.name, ".exe") and
            !std.mem.startsWith(u8, entry.name, "notification_helper") and
            !std.mem.startsWith(u8, entry.name, "UnityCrashHandler"))
        {
            if (fallback_exe == null) {
                fallback_exe = alloc.dupe(u8, entry.name[0 .. entry.name.len - 4]) catch return errs.Error.OutOfMemory;
            }
        }
    }
    return fallback_exe;
}

/// Write the Linux launcher script + chmod +x. `name` is the base
/// (no extension); the script lands at `<install_dir>/<name>.sh`.
/// `wrap_steam_run = true` on NixOS so the launcher gets glibc.
pub fn writeLauncher(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    name: []const u8,
    wrap_steam_run: bool,
) errs.Error!void {
    const content = renderLauncher(alloc, name, wrap_steam_run) catch return errs.Error.OutOfMemory;
    defer alloc.free(content);

    var path_buf: [512]u8 = undefined;
    const sh_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.sh", .{ install_dir, name }) catch return errs.Error.OutOfMemory;

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sh_path, .data = content }) catch return errs.Error.LauncherWriteFailed;

    var f = std.Io.Dir.cwd().openFile(io, sh_path, .{ .mode = .read_write }) catch return errs.Error.LauncherWriteFailed;
    defer f.close(io);
    f.setPermissions(io, .executable_file) catch return errs.Error.LauncherWriteFailed;
}

/// Pure. Returns allocator-owned launcher script body.
pub fn renderLauncher(alloc: std.mem.Allocator, name: []const u8, wrap_steam_run: bool) ![]u8 {
    const exec_prefix = if (wrap_steam_run) "exec steam-run " else "exec ";
    return std.fmt.allocPrint(alloc,
        \\#!/usr/bin/env bash
        \\# auto-generated Ren'Py Linux launcher (f69)
        \\cd "$(dirname "$(readlink -f "$0")")"
        \\
        \\ARCH="x86_64"
        \\if   [ -d "lib/py3-linux-${{ARCH}}" ]; then LIB="lib/py3-linux-${{ARCH}}"
        \\elif [ -d "lib/py2-linux-${{ARCH}}" ]; then LIB="lib/py2-linux-${{ARCH}}"
        \\elif [ -d "lib/linux-${{ARCH}}" ];     then LIB="lib/linux-${{ARCH}}"
        \\else echo "no Linux runtime libs found" >&2; exit 1; fi
        \\
        \\export LD_LIBRARY_PATH="${{LIB}}:${{LD_LIBRARY_PATH:-}}"
        \\export RENPY_PLATFORM="linux-${{ARCH}}"
        \\
        \\if   [ -x "${{LIB}}/python" ];  then PYTHON="${{LIB}}/python"
        \\elif [ -x "${{LIB}}/pythonw" ]; then PYTHON="${{LIB}}/pythonw"
        \\elif [ -x "${{LIB}}/python3" ]; then PYTHON="${{LIB}}/python3"
        \\else echo "no python in ${{LIB}}" >&2; exit 1; fi
        \\
        \\{s}"${{PYTHON}}" -EO "{s}.py" "$@"
        \\
    , .{ exec_prefix, name });
}

// ============================================================
//  idempotency
// ============================================================

/// Already-converted check — mirrors `fix-linux-games.sh`'s
/// `has_linux_support`. True iff (a) `<name>.sh` exists at install
/// root AND (b) at least one `lib/.linux-x86_64` dir is present.
pub fn alreadyConverted(io: Io, install_dir: []const u8, launcher_base: []const u8) bool {
    var sh_buf: [512]u8 = undefined;
    const sh_path = std.fmt.bufPrint(&sh_buf, "{s}/{s}.sh", .{ install_dir, launcher_base }) catch return false;
    std.Io.Dir.cwd().access(io, sh_path, .{}) catch return false;

    const lib_subs = [_][]const u8{ "lib/py3-linux-x86_64", "lib/py2-linux-x86_64", "lib/linux-x86_64" };
    for (lib_subs) |sub| {
        var lib_buf: [512]u8 = undefined;
        const lib_path = std.fmt.bufPrint(&lib_buf, "{s}/{s}", .{ install_dir, sub }) catch continue;
        if (std.Io.Dir.cwd().access(io, lib_path, .{})) |_| return true else |_| {}
    }
    return false;
}

// ============================================================
//  tests
// ============================================================

const testing = std.testing;

// Parser tests live in `util/renpy.zig` next to the implementations.

test "renderLauncher: NixOS steam-run wrap" {
    const out = try renderLauncher(testing.allocator, "MyGame", true);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "exec steam-run") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"MyGame.py\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "RENPY_PLATFORM=") != null);
}

test "renderLauncher: plain exec on non-NixOS" {
    const out = try renderLauncher(testing.allocator, "Foo", false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "steam-run") == null);
    try testing.expect(std.mem.indexOf(u8, out, "exec \"${PYTHON}\"") != null);
}

test "renderLauncher: bash header + cd to script dir" {
    const out = try renderLauncher(testing.allocator, "X", false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "#!/usr/bin/env bash"));
    try testing.expect(std.mem.indexOf(u8, out, "cd \"$(dirname") != null);
}
