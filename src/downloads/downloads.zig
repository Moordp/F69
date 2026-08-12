// Public API of the downloads context.

const dom = @import("domain.zig");
const mgr = @import("manager.zig");
const hnd = @import("handler.zig");
const arc = @import("archive.zig");
const ver = @import("verify.zig");
const aria2_rpc = @import("aria2_rpc.zig");

pub const errors = @import("errors.zig");

pub const Job = dom.Job;
pub const JobKind = dom.JobKind;
pub const JobStatus = dom.JobStatus;

pub const Manager = mgr.Manager;
pub const Handler = hnd.Handler;

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
pub const hexDecode = ver.hexDecode;

// RPDL is concrete (login + fetchTorrent → bytes → Manager.enqueueTorrent),
// not a vtable Handler. The active download path goes Manager → aria2 Daemon
// directly; the old per-host Handler stubs (mega/mediafire/gofile/browser/
// http/aria2) were never registered and have been removed in the aria2
// rewrite. If a specialty host ever needs a resolver, it resolves to a
// direct URL fed to the daemon — no vtable indirection.
pub const rpdl = @import("rpdl.zig");

// Force `zig test` to discover the per-file `test {}` blocks. Without
// these references the compiler only pulls in the symbols re-exported
// above, so nested tests would silently no-op.
test {
    _ = mgr;
    _ = aria2_rpc;
    _ = @import("rpdl.zig");
    _ = arc;
    _ = ver;
}
