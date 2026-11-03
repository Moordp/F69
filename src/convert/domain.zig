// Convert specs — what fix-linux-games.sh does, hoisted into typed
// Zig. Per the 2026-05-12 architecture call: engine-keyed handlers in
// the app, recipe just declares `engine + sdk_version + extras`. No
// per-game declarative DSL.

const std = @import("std");

/// Engine + Distro live in `util_domain` so every context shares the
/// same enums (with the same `fromBracket` / `parseOsReleaseId`
/// parsers).
pub const Engine = @import("util_domain").Engine;
pub const Distro = @import("util_domain").Distro;

/// What `convert_linux` looks like in a recipe. Tagged union over the
/// engine-specific config blocks the handlers consume. `.none` means
/// "the game already has a Linux build" — convert is a no-op.
pub const ConvertSpec = union(enum) {
    none: void,
    renpy: struct {
        /// e.g. "7.5.3" — the SDK that ships matching `lib/{py3-,py2-,}linux-x86_64`.
        /// Recipe may pin or leave null to let convert detect from the
        /// install dir's `renpy/__init__.py` / `vc_version.py`.
        sdk_version: ?[]const u8 = null,
    },
    rpgm: struct {
        /// Pin nwjs version explicitly; null = auto-detect from `nw.dll`'s
        /// embedded Chrome version → `chromeToNwjs` table.
        nwjs_version: ?[]const u8 = null,
        ffmpeg_codecs: bool = true,
        bundle_syslibs: bool = true,
    },
    /// RPG Maker XP / VX / VX Ace via vendored mkxp-z (RGSS reimpl).
    /// The mkxp-z bundle ships in `<exe_dir>/data/mkxp-z/` — see
    /// `third_party/mkxp-z/`. Caller (launch.zig) resolves the
    /// absolute path before dispatch; convert/service.zig just
    /// hands it to rpgm.convertVxAce verbatim.
    mkxp_z: struct {
        /// Absolute path to the bundled mkxp-z install (the dir that
        /// contains `mkxp-z.x86_64`). Required.
        mkxp_z_dir: []const u8,
        /// Optional dir prepended to LD_LIBRARY_PATH in the launcher.
        /// NixOS hosts: `<exe_dir>/data/compat-resources/mkxp-z-fhs-libs/lib`
        /// supplies the libstdc++.so.6 the mkxp-z binary
        /// dynamic-links. `null` on distros that already ship a
        /// compatible system libstdc++.
        extra_libs_dir: ?[]const u8 = null,
        /// Window-size multiplier vs. the RGSS native resolution.
        /// 2.0 = default (e.g. VX Ace's 544×416 → 1088×832 window).
        /// Range clamped to [0.5, 4.0] by the convert step. Persisted
        /// per-install at `<install>/.mkxp-zoom` so the UI dropdown
        /// can survive across re-Converts.
        zoom: f32 = 2.0,
    },
};

/// What a long convert step tells its caller: a phase label, a
/// (done, total) tick inside that phase, and a cancel poll. All three
/// hooks are optional; `.none` reports nowhere and never cancels. The
/// hooks run on the thread that runs the convert (the compute thread),
/// so the owner must make them thread-safe.
pub const Progress = struct {
    ctx: ?*anyopaque = null,
    phase: ?*const fn (?*anyopaque, []const u8) void = null,
    report: ?*const fn (?*anyopaque, u64, u64) void = null,
    cancelled: ?*const fn (?*anyopaque) bool = null,

    pub const none: Progress = .{};

    /// Start a new phase. `text` is only valid for the duration of the
    /// call — the receiver copies it if it keeps it.
    pub fn setPhase(self: Progress, text: []const u8) void {
        if (self.phase) |f| f(self.ctx, text);
    }

    pub fn tick(self: Progress, done: u64, total: u64) void {
        if (self.report) |f| f(self.ctx, done, total);
    }

    /// True when the caller asked to stop. Checked between files and
    /// chunks; the convert step then returns `error.Cancelled`.
    pub fn stop(self: Progress) bool {
        if (self.cancelled) |f| return f(self.ctx);
        return false;
    }
};

test "Progress.none: reports nowhere and never stops" {
    const p = Progress.none;
    p.setPhase("x");
    p.tick(1, 2);
    try std.testing.expect(!p.stop());
}
