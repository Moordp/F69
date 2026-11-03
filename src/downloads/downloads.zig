// Public API of the downloads context.

const arc = @import("archive.zig");
const ver = @import("verify.zig");
const aria2_rpc = @import("aria2_rpc.zig");

pub const errors = @import("errors.zig");

pub const Aria2Daemon = aria2_rpc.Daemon;
/// aria2 command-line construction — covered by the test suite.
pub const aria2_args = @import("aria2_args.zig");
pub const Aria2Status = aria2_rpc.Status;

pub const Format = arc.Format;
pub const ExtractOpts = arc.ExtractOpts;
pub const detectFormat = arc.detectFormat;
pub const extract = arc.extract;

pub const Hasher = ver.Hasher;
pub const verifyFile = ver.verifyFile;
pub const hashFile = ver.hashFile;
pub const progress = @import("progress.zig");
pub const hexDecode = ver.hexDecode;

// RPDL is concrete (search + fetchTorrent → bytes → `Command.enqueue_torrent`).
pub const rpdl = @import("rpdl.zig");

/// Downloader v2 job model and pure state machine.
pub const model = @import("model.zig");

/// Downloader v2 SQLite store (dl_jobs / dl_events).
pub const store = @import("store.zig");

/// Downloader v2 bandwidth and slot policy.
pub const policy = @import("policy.zig");

/// Downloader v2 engine interface, fake engine and aria2 engine.
pub const engine = @import("engine.zig");
pub const engine_aria2 = @import("engine_aria2.zig");
pub const engine_browser = @import("engine_browser.zig");
pub const engine_megacmd = @import("engine_megacmd.zig");

/// Downloader v2 thread: command queue, snapshot, events, step driver.
pub const downloader = @import("downloader.zig");
pub const workers = @import("workers.zig");

/// Link resolver: catalogue href → direct URL / MEGA / needs-browser.
pub const resolve = @import("resolve.zig");
pub const http_f95 = @import("http_f95.zig");

/// Watched-folder scanner + file matcher for the browser engine.
pub const watch = @import("watch.zig");

/// MEGAcmd output parsers + client locator (pure).
pub const megacmd = @import("megacmd.zig");
pub const Downloader = downloader.Downloader;
pub const Command = downloader.Command;
pub const UiEvent = downloader.UiEvent;
pub const Snapshot = downloader.Snapshot;
pub const JobView = downloader.JobView;

// Force `zig test` to discover the per-file `test {}` blocks. Without
// these references the compiler only pulls in the symbols re-exported
// above, so nested tests would silently no-op.
test {
    _ = aria2_rpc;
    _ = @import("rpdl.zig");
    _ = arc;
    _ = ver;
    _ = model;
    _ = store;
    _ = policy;
    _ = engine;
    _ = engine_aria2;
    _ = engine_browser;
    _ = engine_megacmd;
    _ = downloader;
    _ = workers;
    _ = resolve;
    _ = watch;
    _ = megacmd;
    _ = @import("http_f95.zig");
}
