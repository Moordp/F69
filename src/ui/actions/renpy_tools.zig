//! Ren'Py "enable developer console" mod tool (M3 §2.1). Drops a tiny `.rpy`
//! into the game's `game/` directory that flips `config.console` +
//! `config.developer` on, so the user gets the in-engine console (Shift+O)
//! and dev menu (Shift+D) — the standard cheat/debug entry point for Ren'Py
//! games. Non-destructive: it only adds one file, removable by deleting it.

const std = @import("std");
const Io = std.Io;
const types = @import("../types.zig");
const threads_act = @import("threads.zig");

const Frame = types.Frame;
const threads = types.threads;
const log = std.log.scoped(.renpy);

/// `init 999` runs after the game's own init blocks, so this overrides a
/// game that explicitly set `config.developer = False`.
const CONSOLE_RPY =
    "# Added by f69 — enables the Ren'Py developer console (Shift+O) + dev menu (Shift+D).\n" ++
    "# Delete this file to turn it back off.\n" ++
    "init 999 python:\n" ++
    "    config.console = True\n" ++
    "    config.developer = True\n";

const CONSOLE_FILENAME = "zzz_f69_console.rpy";

pub fn enableRenpyConsole(frame: *Frame, thread_id: u64) void {
    const alloc = frame.lib.alloc;
    const io = frame.io;

    const inst = (frame.lib.latestInstallForGame(thread_id) catch null) orelse {
        frame.state.notifyErr("Console: no install found for this game.");
        return;
    };
    defer frame.lib.freeInstall(inst);

    const game_dir = findGameDir(alloc, io, inst.install_path) orelse {
        frame.state.notifyErr("Console: couldn't find the Ren'Py game/ folder.");
        return;
    };
    defer alloc.free(game_dir);

    var pbuf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ game_dir, CONSOLE_FILENAME }) catch {
        frame.state.notifyErr("Console: path too long.");
        return;
    };
    writeFile(io, path, CONSOLE_RPY) catch |e| {
        log.warn("write {s} failed: {s}", .{ path, @errorName(e) });
        frame.state.notifyErr("Console: couldn't write the .rpy file.");
        return;
    };
    frame.state.notifyOk("Ren'Py console enabled — press Shift+O in-game.");
}

/// Extract every `.rpa` archive found in the game's install into loose
/// files next to the archive, on the compute thread. The UI thread only
/// reads the install row; the walk and the extract run in
/// `threads/jobs/rpa.zig`. The result arrives as `.work_done` and is
/// toasted by `handleWorkDone`.
pub fn extractRpaArchives(frame: *Frame, thread_id: u64) void {
    const inst = (frame.lib.latestInstallForGame(thread_id) catch null) orelse {
        frame.state.notifyErr("Extract: no install found for this game.");
        return;
    };
    defer frame.lib.freeInstall(inst);

    const name = threads_act.gameNameFor(frame, thread_id);
    var title_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Extract RPA \u{00B7} {s}", .{name}) catch "Extract RPA";
    const a = threads_act.startTool(frame, .rpa_extract, thread_id, title) orelse return;

    const job = threads.work_thread.RpaJob.create(frame.lib.alloc, thread_id, inst.install_path, name) catch {
        threads_act.failTool(frame, a, "Out of memory.");
        return;
    };
    frame.work.submit(.{ .rpa_extract = job }, a) catch {
        threads_act.failTool(frame, a, "Out of memory.");
        return;
    };
}

fn findGameDir(alloc: std.mem.Allocator, io: Io, root: []const u8) ?[]u8 {
    if (joinIfDir(alloc, io, root, "game")) |p| return p;
    // Some bundles wrap the game one level deeper — walk for a `game` dir.
    var dir = Io.Dir.cwd().openDir(io, root, .{ .access_sub_paths = true, .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(alloc) catch return null;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), "game")) continue;
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, entry.path }) catch null;
    }
    return null;
}

/// Return an owned "<root>/<rel>" if it's an openable directory, else null.
fn joinIfDir(alloc: std.mem.Allocator, io: Io, root: []const u8, rel: []const u8) ?[]u8 {
    const p = std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, rel }) catch return null;
    var d = Io.Dir.cwd().openDir(io, p, .{}) catch {
        alloc.free(p);
        return null;
    };
    d.close(io);
    return p;
}

fn writeFile(io: Io, path: []const u8, content: []const u8) !void {
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    try fw.interface.writeAll(content);
    try fw.interface.flush();
}
