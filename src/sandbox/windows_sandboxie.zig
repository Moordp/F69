// Sandboxie-Plus integration. The user installs Sandboxie themselves; we DETECT their install
// and shell out to `Start.exe /box:<box> <command>`. If it isn't found, the Sandbox falls back
// to the `none` backend (game runs unsandboxed).
//
// Detection priority:
//   1. config `sandboxie_path` — the user can Browse… to Start.exe in Settings (Appearance/Sandbox)
//   2. %ProgramFiles%\Sandboxie-Plus\Start.exe   (Sandboxie-Plus)
//   3. %ProgramFiles%\Sandboxie\Start.exe        (classic Sandboxie)

const std = @import("std");
const builtin = @import("builtin");
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const util_proc = @import("util_proc");

const log = std.log.scoped(.sandbox);

/// The Sandboxie box we launch games into. A fresh Sandboxie-Plus install
/// only ships `DefaultBox`; this box does NOT exist until we create it (see
/// `ensureBox`). Single-sourced so the `/box:` arg, the create/query calls,
/// and the error messages never drift.
const box_name = "f69";
const box_arg = "/box:" ++ box_name; // "/box:f69"

pub const Sandboxie = struct {
    start_exe: []const u8, // resolved Start.exe path (owned by `alloc`)
    /// Last-failure detail, same contract as `NoSandbox.lastError` — the UI
    /// reads it to render something better than the bare `LaunchFailed`.
    last_error_buf: [320]u8 = undefined,
    last_error_len: usize = 0,
    alloc: std.mem.Allocator,
    io: std.Io,

    /// Detect Sandboxie. `override` = `config.sandboxie_path` (empty when unset). Returns null
    /// when Sandboxie isn't found so `pickBackend` falls back to `none`.
    pub fn detect(alloc: std.mem.Allocator, io: std.Io, environ: std.process.Environ, override: []const u8) ?Sandboxie {
        if (builtin.os.tag != .windows) return null;
        // 1. explicit config override (the "Browse to Start.exe" target).
        if (fromExplicitPath(alloc, io, override)) |s| {
            log.info("sandboxie: using configured Start.exe at {s}", .{s.start_exe});
            return s;
        }
        // 2/3. standard install locations under %ProgramFiles%.
        const pf = environ.getAlloc(alloc, "ProgramFiles") catch return null;
        defer alloc.free(pf);
        const subdirs = [_][]const u8{ "Sandboxie-Plus", "Sandboxie" };
        for (subdirs) |sub| {
            const p = std.fmt.allocPrint(alloc, "{s}\\{s}\\Start.exe", .{ pf, sub }) catch continue;
            if (exists(io, p)) {
                log.info("sandboxie: detected Start.exe at {s}", .{p});
                return .{ .start_exe = p, .alloc = alloc, .io = io };
            }
            alloc.free(p);
        }
        return null;
    }

    /// Build a Sandboxie from an explicit Start.exe path — the Settings
    /// "Browse…" target / config override, used for portable or otherwise
    /// non-standard installs. Returns null when the path is empty or doesn't
    /// exist on disk (so the caller keeps the current backend). Caller owns
    /// the resulting `start_exe`.
    pub fn fromExplicitPath(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?Sandboxie {
        if (builtin.os.tag != .windows) return null;
        if (path.len == 0 or !exists(io, path)) return null;
        const dup = alloc.dupe(u8, path) catch return null;
        return .{ .start_exe = dup, .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *Sandboxie) void {
        if (self.start_exe.len > 0) self.alloc.free(self.start_exe);
    }

    pub fn lastError(self: *const Sandboxie) []const u8 {
        return self.last_error_buf[0..self.last_error_len];
    }

    fn setLastError(self: *Sandboxie, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.last_error_buf, fmt, args) catch {
            const fallback = "(truncated error)";
            const n = @min(fallback.len, self.last_error_buf.len);
            @memcpy(self.last_error_buf[0..n], fallback[0..n]);
            self.last_error_len = n;
            return;
        };
        self.last_error_len = s.len;
    }

    /// Launch the game inside a Sandboxie box: `Start.exe /box:f69 <abs_exe> [args]`.
    /// The `f69` box is created on demand first (`ensureBox`) — a fresh
    /// Sandboxie install doesn't have it, and without it Start.exe pops an
    /// "Invalid box name parameter: f69" dialog and the game never runs.
    pub fn launch(self: *Sandboxie, alloc: std.mem.Allocator, cfg: dom.SandboxConfig) errs.Error!dom.SpawnResult {
        self.last_error_len = 0;

        var exe_buf: [1024]u8 = undefined;
        const joined: []const u8 = if (std.fs.path.isAbsolute(cfg.executable))
            cfg.executable
        else
            std.fmt.bufPrint(&exe_buf, "{s}\\{s}", .{ cfg.install_path, cfg.executable }) catch {
                self.setLastError("launcher path too long to build ({s})", .{cfg.executable});
                return errs.Error.LaunchFailed;
            };
        // f69 builds library paths with `/` while this join uses `\`, so the
        // result is mixed (`C:\...\library/181313/final\Game.exe`). The Win32
        // APIs tolerate that, but Sandboxie's Start.exe parses the command
        // itself — hand it a canonical path rather than relying on that.
        var norm_buf: [1024]u8 = undefined;
        const abs_exe = normalizeWinSeps(&norm_buf, joined);

        // Check before spawning: "the file isn't there" and "the file isn't
        // runnable" are different user problems and the raw spawn error does
        // not distinguish them well.
        if (!exists(self.io, abs_exe)) {
            self.setLastError("launcher not found on disk: {s}", .{abs_exe});
            // warn, not err: matches NoSandbox's pre-spawn access failure —
            // the UI surfaces lastError either way, and the test runner
            // counts err-level logs as failures.
            log.warn("sandboxie: launcher missing: {s}", .{abs_exe});
            return errs.Error.LaunchFailed;
        }

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        argv.append(alloc, self.start_exe) catch return errs.Error.OutOfMemory;
        argv.append(alloc, box_arg) catch return errs.Error.OutOfMemory;
        argv.append(alloc, abs_exe) catch return errs.Error.OutOfMemory;
        for (cfg.launch_args) |a| argv.append(alloc, a) catch return errs.Error.OutOfMemory;

        // Test seam: capture the composed Start.exe command line instead of
        // spawning. Late on purpose — path join, separator normalization and
        // the exists() probe above all ran for real. Returns BEFORE ensureBox
        // so tests never touch the real Sandboxie config.
        if (dom.spawn_hook.active) {
            _ = dom.spawn_hook.record("sandboxie", argv.items, null, null);
            return .{ .pid = 0 };
        }

        // Create our box if it doesn't exist yet. On failure this returns a
        // descriptive LaunchFailed rather than spawning into a bad box — the
        // game does NOT silently run unsandboxed (that would drop the very
        // isolation the user asked for). Only runs on the real path; the seam
        // above returned first.
        try self.ensureBox(alloc);

        _ = std.process.spawn(self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = cfg.install_path },
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |e| {
            switch (e) {
                // Not a PE. The usual cause is the launcher auto-pick landing
                // on a Linux `.sh` that shipped alongside the `.exe`.
                error.InvalidExe => self.setLastError(
                    "{s} is not a Windows executable (a Linux .sh / .AppImage?). Set the launcher explicitly on the install if the auto-pick chose wrong.",
                    .{abs_exe},
                ),
                error.FileNotFound => self.setLastError(
                    "Sandboxie Start.exe not found at {s} — set it in Settings → Sandbox.",
                    .{self.start_exe},
                ),
                error.AccessDenied, error.PermissionDenied => self.setLastError(
                    "access denied starting {s} via Sandboxie (blocked by the box's rules, or by Defender?)",
                    .{abs_exe},
                ),
                else => self.setLastError(
                    "Sandboxie spawn failed: {s} (start={s}, exe={s})",
                    .{ @errorName(e), self.start_exe, abs_exe },
                ),
            }
            log.err("sandboxie launch failed: {s} (start={s}, exe={s})", .{ @errorName(e), self.start_exe, abs_exe });
            return errs.Error.LaunchFailed;
        };
        // Game runs detached inside the box. Host-side pid tracking on Windows is M2 → report 0.
        return .{ .pid = 0 };
    }

    /// Make sure the `f69` Sandboxie box exists before we launch into it.
    /// A fresh Sandboxie-Plus install only ships `DefaultBox`, so the first
    /// sandboxed launch used to hit `Start.exe`'s "Invalid box name
    /// parameter: f69" dialog — and because Start.exe is fire-and-forget we
    /// reported success while the game never ran. Creating the box with
    /// `SbieIni.exe set f69 Enabled y` + `Start.exe /reload` works as the
    /// normal user when the Sandboxie service is running (verified on the
    /// win11 VM: the service runs, the create + reload succeed rc=0, and a
    /// subsequent `Start.exe /box:f69` launches cleanly). On any failure we
    /// return a descriptive LaunchFailed so the caller surfaces it instead of
    /// silently dropping the sandbox.
    fn ensureBox(self: *Sandboxie, alloc: std.mem.Allocator) errs.Error!void {
        // SbieIni.exe lives next to Start.exe.
        const dir = std.fs.path.dirname(self.start_exe) orelse {
            self.setLastError("cannot locate SbieIni.exe: Start.exe has no parent dir ({s})", .{self.start_exe});
            return errs.Error.LaunchFailed;
        };
        var sbieini_buf: [1024]u8 = undefined;
        const sbieini = std.fmt.bufPrint(&sbieini_buf, "{s}\\SbieIni.exe", .{dir}) catch {
            self.setLastError("SbieIni.exe path too long under {s}", .{dir});
            return errs.Error.LaunchFailed;
        };
        if (!exists(self.io, sbieini)) {
            self.setLastError(
                "SbieIni.exe not found next to Start.exe ({s}) — can't create the '{s}' sandbox box. Point Settings → Sandbox at a complete Sandboxie install, or turn sandboxing off for this game.",
                .{ sbieini, box_name },
            );
            return errs.Error.LaunchFailed;
        }

        // Already there? Then nothing to do — skip the write + reload.
        if (self.boxEnabled(alloc, sbieini)) return;

        log.info("sandboxie: '{s}' box missing — creating it via {s}", .{ box_name, sbieini });
        // Minimal viable box: `Enabled=y`. Sandboxie fills in the rest from
        // its default template. Then reload so the driver sees the new box.
        if (!self.runOk(alloc, &.{ sbieini, "set", box_name, "Enabled", "y" })) {
            self.setLastError(
                "couldn't create the '{s}' Sandboxie box (SbieIni set failed — is the Sandboxie service running?). Turn sandboxing off for this game to launch it directly.",
                .{box_name},
            );
            return errs.Error.LaunchFailed;
        }
        if (!self.runOk(alloc, &.{ self.start_exe, "/reload" })) {
            self.setLastError("created the '{s}' box but Start.exe /reload failed — Sandboxie didn't pick it up.", .{box_name});
            return errs.Error.LaunchFailed;
        }
        // Verify it registered — a create that "succeeded" but didn't take
        // (unwritable config, service hiccup) would otherwise land us right
        // back at the invalid-box dialog.
        if (!self.boxEnabled(alloc, sbieini)) {
            self.setLastError("created the '{s}' Sandboxie box but it didn't register (Sandboxie config not writable?).", .{box_name});
            return errs.Error.LaunchFailed;
        }
        log.info("sandboxie: '{s}' box created and verified", .{box_name});
    }

    /// True when `SbieIni query <box> Enabled` reports "y" (rc 0) — i.e. the
    /// box already exists. A missing box exits nonzero / prints nothing, which
    /// reads as false. Best-effort: a spawn error also reads as "not there".
    fn boxEnabled(self: *Sandboxie, alloc: std.mem.Allocator, sbieini: []const u8) bool {
        const r = util_proc.run(alloc, self.io, &.{ sbieini, "query", box_name, "Enabled" }, .{ .stderr = .ignore }) catch return false;
        defer alloc.free(r.stdout);
        if (r.exit_code != 0) return false;
        return std.ascii.eqlIgnoreCase(std.mem.trim(u8, r.stdout, " \t\r\n"), "y");
    }

    /// Run `argv`, discard stdout, return true on a clean (rc 0) exit.
    fn runOk(self: *Sandboxie, alloc: std.mem.Allocator, argv: []const []const u8) bool {
        const r = util_proc.run(alloc, self.io, argv, .{ .stderr = .ignore }) catch return false;
        alloc.free(r.stdout);
        return r.exit_code == 0;
    }
};

/// Rewrite `/` as `\` in place into `buf`. Falls back to the input when it
/// doesn't fit, since a mixed-separator path still usually works.
fn normalizeWinSeps(buf: []u8, p: []const u8) []const u8 {
    if (p.len > buf.len) return p;
    for (p, 0..) |c, i| buf[i] = if (c == '/') '\\' else c;
    return buf[0..p.len];
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

const testing = std.testing;
const test_env = @import("util_test_env");

test "normalizeWinSeps: mixed separators become backslashes" {
    // The exact shape Sandboxie sees in production: library paths joined
    // with `/`, install root with `\` (windows_sandboxie.zig:93-96).
    var buf: [128]u8 = undefined;
    const out = normalizeWinSeps(&buf, "C:\\Users\\u\\Games\\f69\\library/181313/final\\Game.exe");
    try testing.expectEqualStrings("C:\\Users\\u\\Games\\f69\\library\\181313\\final\\Game.exe", out);
}

test "normalizeWinSeps: input longer than the buffer falls back unchanged" {
    var buf: [8]u8 = undefined;
    const in = "C:/a/very/long/path/Game.exe";
    const out = normalizeWinSeps(&buf, in);
    // Documented fallback: mixed separators usually still work, truncation never does.
    try testing.expectEqualStrings(in, out);
}

test "normalizeWinSeps: empty input" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("", normalizeWinSeps(&buf, ""));
}

test "Sandboxie.detect: empty environ and no override finds nothing" {
    // On Windows: no %ProgramFiles% in an empty environ, so both probe paths
    // are unreachable. Off Windows: comptime-guarded null. Either way the
    // pickBackend caller must get null and fall back to `none`.
    var env = try test_env.TestEnv.init(testing.allocator, "sbie-detect");
    defer env.deinit();
    try testing.expect(Sandboxie.detect(testing.allocator, env.io, .empty, "") == null);
}

test "Sandboxie.fromExplicitPath: empty and nonexistent paths are rejected" {
    var env = try test_env.TestEnv.init(testing.allocator, "sbie-explicit-bad");
    defer env.deinit();
    try testing.expect(Sandboxie.fromExplicitPath(testing.allocator, env.io, "") == null);
    const missing = try env.path("nope\\Start.exe");
    defer testing.allocator.free(missing);
    try testing.expect(Sandboxie.fromExplicitPath(testing.allocator, env.io, missing) == null);
}

test "Sandboxie.fromExplicitPath: a real Start.exe is accepted (Windows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var env = try test_env.TestEnv.init(testing.allocator, "sbie-explicit-ok");
    defer env.deinit();
    // Portable installs commonly live under paths with spaces.
    try env.writeFile("Sandboxie Portable/Start.exe", "MZ fake");
    const p = try env.path("Sandboxie Portable/Start.exe");
    defer testing.allocator.free(p);
    var sb = Sandboxie.fromExplicitPath(testing.allocator, env.io, p) orelse return error.TestUnexpectedResult;
    defer sb.deinit();
    try testing.expectEqualStrings(p, sb.start_exe);
}

test "Sandboxie.launch: missing game exe fails with a 'not found' detail" {
    var env = try test_env.TestEnv.init(testing.allocator, "sbie-launch-missing");
    defer env.deinit();
    var sb = Sandboxie{ .start_exe = "C:\\SB\\Start.exe", .alloc = testing.allocator, .io = env.io };
    const install = try env.path("games/Gone");
    defer testing.allocator.free(install);
    try testing.expectError(errs.Error.LaunchFailed, sb.launch(testing.allocator, .{
        .sandbox_home = "",
        .install_path = install,
        .executable = "Gone.exe",
    }));
    try testing.expect(std.mem.indexOf(u8, sb.lastError(), "not found on disk") != null);
}

test "Sandboxie.launch: relative exe overflowing the join buffer fails cleanly" {
    var env = try test_env.TestEnv.init(testing.allocator, "sbie-launch-long");
    defer env.deinit();
    var sb = Sandboxie{ .start_exe = "C:\\SB\\Start.exe", .alloc = testing.allocator, .io = env.io };
    const long_exe = "x" ** 1100 ++ ".exe";
    try testing.expectError(errs.Error.LaunchFailed, sb.launch(testing.allocator, .{
        .sandbox_home = "",
        .install_path = env.root,
        .executable = long_exe,
    }));
    // The detail message embeds the overlong path, so it overflows the
    // 320-byte last_error_buf and lands on the "(truncated error)"
    // fallback. The contract that matters: LaunchFailed + SOME detail,
    // never a crash or a silent empty string.
    try testing.expect(sb.lastError().len > 0);
}

test "Sandboxie.launch: argv is [Start.exe, /box:f69, exe, args] with canonical separators (Windows)" {
    // The exists() probe runs against the normalized path, which only
    // resolves on a real Windows filesystem — hence the guard.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var env = try test_env.TestEnv.init(testing.allocator, "sbie-launch-argv");
    defer env.deinit();
    try env.writeFile("games/Foo Bar/Foo.exe", "MZ fake");
    // Mixed separators on purpose — the production join produces exactly this.
    const install = try env.path("games/Foo Bar");
    defer testing.allocator.free(install);

    var sb = Sandboxie{ .start_exe = "C:\\SB\\Start.exe", .alloc = testing.allocator, .io = env.io };
    dom.spawn_hook.install(0);
    defer dom.spawn_hook.reset();
    const res = try sb.launch(testing.allocator, .{
        .sandbox_home = "",
        .install_path = install,
        .executable = "Foo.exe",
        .launch_args = &.{"-fullscreen"},
    });
    try testing.expectEqual(@as(i32, 0), res.pid);
    try testing.expectEqual(@as(usize, 1), dom.spawn_hook.calls);
    try testing.expectEqualStrings("C:\\SB\\Start.exe", dom.spawn_hook.arg(0).?);
    try testing.expectEqualStrings("/box:f69", dom.spawn_hook.arg(1).?);
    const exe_arg = dom.spawn_hook.arg(2).?;
    try testing.expect(std.mem.indexOfScalar(u8, exe_arg, '/') == null);
    try testing.expect(std.mem.endsWith(u8, exe_arg, "\\games\\Foo Bar\\Foo.exe"));
    try testing.expectEqualStrings("-fullscreen", dom.spawn_hook.arg(3).?);
}
