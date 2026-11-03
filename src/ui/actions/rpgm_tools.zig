//! RPG Maker MV/MZ "decrypt assets" mod tool (M3 §2.1). On click the UI
//! thread only reads the game's latest install row; the key lookup, the
//! walk and the decrypt run on the compute thread in
//! `threads/jobs/decrypt.zig`. The result arrives as `.work_done` and is
//! toasted by `handleWorkDone`.
//!
//! Non-destructive: originals are kept, so the game keeps running while the
//! user gets raw assets for modding/extraction.

const std = @import("std");
const types = @import("../types.zig");
const threads_act = @import("threads.zig");

const Frame = types.Frame;
const threads = types.threads;

pub fn decryptRpgmAssets(frame: *Frame, thread_id: u64) void {
    const inst = (frame.lib.latestInstallForGame(thread_id) catch null) orelse {
        frame.state.notifyErr("Decrypt: no install found for this game.");
        return;
    };
    defer frame.lib.freeInstall(inst);

    const name = threads_act.gameNameFor(frame, thread_id);
    var title_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Decrypt \u{00B7} {s}", .{name}) catch "Decrypt";
    const a = threads_act.startTool(frame, .decrypt, thread_id, title) orelse return;

    const job = threads.work_thread.DecryptJob.create(frame.lib.alloc, thread_id, inst.install_path, name) catch {
        threads_act.failTool(frame, a, "Out of memory.");
        return;
    };
    frame.work.submit(.{ .decrypt = job }, a) catch {
        threads_act.failTool(frame, a, "Out of memory.");
        return;
    };
}
