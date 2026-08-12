// Public face of the sandbox context. Tagged union over the platform
// backends — only one is ever active per process. Compiler exhaustively
// checks switch arms; no `*anyopaque` needed.

const std = @import("std");
const builtin = @import("builtin");

const errs = @import("errors.zig");
pub const errors = errs;

const util_proc = @import("util_proc");

const dom = @import("domain.zig");
pub const SandboxConfig = dom.SandboxConfig;
pub const SpawnResult = dom.SpawnResult;
pub const spawn_hook = dom.spawn_hook;
pub const HostInfo = dom.HostInfo;
pub const Distro = dom.Distro;
pub const EnvOverride = dom.EnvOverride;

const Bwrap = @import("linux_bwrap.zig").Bwrap;
const Sandboxie = @import("windows_sandboxie.zig").Sandboxie;

pub const Sandbox = union(enum) {
    bwrap: Bwrap,
    sandboxie: Sandboxie,
    /// "Best-effort" mode — no real isolation, just `$HOME` redirection
    /// via env + chdir. Used when neither bwrap nor Sandboxie is
    /// available (e.g. Debian without `kernel.unprivileged_userns_clone=1`).
    none: NoSandbox,

    pub fn launch(self: *Sandbox, alloc: std.mem.Allocator, cfg: SandboxConfig) errs.Error!SpawnResult {
        return switch (self.*) {
            inline else => |*x| x.launch(alloc, cfg),
        };
    }

    pub fn deinit(self: *Sandbox) void {
        switch (self.*) {
            inline else => |*x| if (@hasDecl(@TypeOf(x.*), "deinit")) x.deinit(),
        }
    }

    /// Active Sandboxie `Start.exe` path, or "" when the current backend
    /// isn't Sandboxie. Shown in the Settings UI so the user can see (and
    /// confirm) which install is in use.
    pub fn sandboxiePath(self: *const Sandbox) []const u8 {
        return switch (self.*) {
            .sandboxie => |*s| s.start_exe,
            else => "",
        };
    }

    /// Point the sandbox at an explicit Sandboxie `Start.exe` (a portable or
    /// non-standard install the user picked via the Settings file picker).
    /// Frees the previous backend and hot-swaps in the new one so the change
    /// takes effect without a restart. Returns false (leaving the current
    /// backend untouched) when not on Windows or the path doesn't resolve to
    /// an existing file — the caller surfaces a warning.
    pub fn applySandboxiePath(self: *Sandbox, alloc: std.mem.Allocator, io: std.Io, path: []const u8) bool {
        if (builtin.os.tag != .windows) return false;
        const sbie = Sandboxie.fromExplicitPath(alloc, io, path) orelse return false;
        self.deinit();
        self.* = .{ .sandboxie = sbie };
        return true;
    }

    /// Human-friendly tag for the active backend — Settings UI / logs.
    pub fn backendName(self: *const Sandbox) []const u8 {
        return switch (self.*) {
            .bwrap => "bwrap",
            .sandboxie => "sandboxie",
            .none => "none",
        };
    }

    /// Detail string for the most recent launch failure. Empty when
    /// the last launch succeeded or no launch has been attempted yet.
    /// Pulled by the UI to render an informative error — `LaunchFailed`
    /// alone tells the user nothing.
    pub fn lastError(self: *const Sandbox) []const u8 {
        return switch (self.*) {
            .none => |*x| x.lastError(),
            .sandboxie => |*x| x.lastError(),
            // bwrap doesn't track this yet — falls back to the empty
            // string so the UI shows the bare `LaunchFailed` plus the
            // backend name as before.
            else => "",
        };
    }
};

/// Detect the active backend for this host. On Linux, attempts bwrap
/// (PATH lookup + userns smoke); on Windows, Sandboxie; falls back to
/// `none` everywhere else.
pub fn pickBackend(
    alloc: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    sandboxie_override: []const u8,
) Sandbox {
    if (builtin.os.tag == .linux) {
        if (Bwrap.detect(alloc, io, environ)) |b| return .{ .bwrap = b };
    } else if (builtin.os.tag == .windows) {
        if (Sandboxie.detect(alloc, io, environ, sandboxie_override)) |s| return .{ .sandboxie = s };
    }
    return .{ .none = NoSandbox.init(io, environ) };
}

/// Best-effort fallback when no real sandbox backend is available
/// (Debian without `kernel.unprivileged_userns_clone=1`, Windows
/// without Sandboxie, plain Unix). Provides `$HOME` redirection +
/// chdir, no isolation. Users are warned via the backend tag in the
/// Launch result message.
pub const NoSandbox = struct {
    io: std.Io,
    environ: std.process.Environ,
    /// Last-failure detail string. Filled by `launch` on the error
    /// path so the UI can render a useful message — the `LaunchFailed`
    /// enum alone is useless to the user.
    last_error_buf: [320]u8 = undefined,
    last_error_len: usize = 0,

    pub fn init(io: std.Io, environ: std.process.Environ) NoSandbox {
        return .{ .io = io, .environ = environ };
    }

    pub fn lastError(self: *const NoSandbox) []const u8 {
        return self.last_error_buf[0..self.last_error_len];
    }

    fn setLastError(self: *NoSandbox, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.last_error_buf, fmt, args) catch {
            // Truncate gracefully if the format runs past the buffer —
            // we just want SOMETHING informative.
            const fallback = "(truncated error)";
            const n = @min(fallback.len, self.last_error_buf.len);
            @memcpy(self.last_error_buf[0..n], fallback[0..n]);
            self.last_error_len = n;
            return;
        };
        self.last_error_len = s.len;
    }

    pub fn launch(self: *NoSandbox, alloc: std.mem.Allocator, cfg: SandboxConfig) errs.Error!SpawnResult {
        // Reset on every attempt so a successful launch leaves an
        // empty string for the UI to interpret as "no error".
        self.last_error_len = 0;
        // Build an env map from the host's environ, then override HOME
        // so saves still land in the per-game sandbox dir. When the
        // caller passes an empty `sandbox_home` we leave the host's
        // own HOME in place — that's the "user opted out of sandboxing
        // entirely" path (per-game `.never`, or global default off).
        var map = self.environ.createMap(alloc) catch {
            self.setLastError("could not snapshot environment (out of memory?)", .{});
            return errs.Error.LaunchFailed;
        };
        defer map.deinit();
        if (cfg.sandbox_home.len > 0) {
            map.put("HOME", cfg.sandbox_home) catch return errs.Error.OutOfMemory;
            // Windows games read USERPROFILE (Documents / Saved Games), not
            // HOME, so redirect it too — otherwise this NoSandbox fallback's
            // per-game save isolation is a silent no-op on Windows and the
            // game writes into the real user profile. Best-effort; Sandboxie
            // is the real isolation when present.
            if (builtin.os.tag == .windows) {
                map.put("USERPROFILE", cfg.sandbox_home) catch return errs.Error.OutOfMemory;
            }
        }
        // Suppress games' "open log in your editor" behaviour.
        // Ren'Py on crash invokes `xdg-open <traceback.txt>` which
        // on the user's system opens the .txt in nvim. Three layers
        // of defense — none alone is enough, all three together
        // catch every codepath we've seen:
        //
        //   1. `BROWSER=/bin/true` — Python's `webbrowser` module
        //      tries `$BROWSER` first. Ren'Py 8 uses webbrowser.open.
        //   2. `EDITOR=/bin/true` + `VISUAL=/bin/true` — some games
        //      use Python's `os.environ["EDITOR"]` directly.
        //   3. PATH shim — prepend a tmp dir with a no-op `xdg-open`
        //      script. Ren'Py 7 + many other engines call xdg-open
        //      directly via subprocess; bypassing webbrowser. The
        //      shim wins the PATH lookup so xdg-open is silently a
        //      no-op for the whole game session.
        //
        // f69's own launch-diag dialog shows the same traceback,
        // so the user loses nothing by suppressing the second
        // window that would otherwise pop up behind f69.
        // Linux-only env shimming: browser/editor suppression, the xdg-open
        // no-op shim, and the `:`-separated PATH prepend. None of it applies
        // on Windows (no /bin/true, no /tmp, and `:` would corrupt %PATH%),
        // where games are native .exe with their own crash UX.
        if (builtin.os.tag != .windows) {
        map.put("BROWSER", "/bin/true") catch return errs.Error.OutOfMemory;
        map.put("EDITOR", "/bin/true") catch return errs.Error.OutOfMemory;
        map.put("VISUAL", "/bin/true") catch return errs.Error.OutOfMemory;

        // Build the shim dir on demand. `/tmp/f69-game-shim/` is a
        // process-wide singleton — writing it on every launch is a
        // no-op after the first call. The shim file just `exit 0`s
        // so xdg-open returns success without doing anything.
        const shim_dir = "/tmp/f69-game-shim";
        // Under the spawn seam, skip materializing the shim: its chmod
        // shellout deadlocks the single-threaded test io, and no process
        // will consult PATH anyway. The PATH string itself is still built
        // and captured, so the prepend stays covered.
        if (!dom.spawn_hook.active) ensureShimDir(self.io, shim_dir);

        // Prepend shim_dir to PATH. Falls through to host PATH so
        // every other tool the game might call (sh, awk, etc.) still
        // resolves normally.
        const host_path: ?[]const u8 = self.environ.getAlloc(alloc, "PATH") catch null;
        defer if (host_path) |p| alloc.free(p);
        var path_buf: std.ArrayList(u8) = .empty;
        defer path_buf.deinit(alloc);
        path_buf.appendSlice(alloc, shim_dir) catch return errs.Error.OutOfMemory;
        if (host_path) |hp| if (hp.len > 0) {
            path_buf.append(alloc, ':') catch return errs.Error.OutOfMemory;
            path_buf.appendSlice(alloc, hp) catch return errs.Error.OutOfMemory;
        };
        map.put("PATH", path_buf.items) catch return errs.Error.OutOfMemory;
        }
        // Compat-recipe / caller-supplied env overrides. Applied after
        // HOME + BROWSER so a recipe can override either explicitly
        // if it really needs to.
        for (cfg.env_extra) |kv| {
            map.put(kv.name, kv.value) catch return errs.Error.OutOfMemory;
        }

        // Resolve argv[0] to an absolute path. POSIX exec treats an
        // argv[0] without any `/` as a PATH lookup, so passing a bare
        // "Game.sh" would search $PATH and fail with ENOENT.
        var exe_buf: [1024]u8 = undefined;
        const abs_exe: []const u8 = blk: {
            if (std.fs.path.isAbsolute(cfg.executable)) break :blk cfg.executable;
            break :blk std.fmt.bufPrint(&exe_buf, "{s}/{s}", .{ cfg.install_path, cfg.executable }) catch {
                self.setLastError(
                    "executable path too long ({s}/{s})",
                    .{ cfg.install_path, cfg.executable },
                );
                return errs.Error.LaunchFailed;
            };
        };

        // Confirm the launcher file is on disk at all (no perm
        // bits checked — `access(.{})` is just `F_OK`). Lets us tell
        // "extract didn't produce anything runnable" apart from
        // "found it but couldn't exec it".
        std.Io.Dir.cwd().access(self.io, abs_exe, .{}) catch |access_err| {
            switch (access_err) {
                error.FileNotFound => self.setLastError("launcher not found on disk: {s}", .{abs_exe}),
                else => self.setLastError(
                    "cannot access launcher ({s}): {s}",
                    .{ @errorName(access_err), abs_exe },
                ),
            }
            std.log.scoped(.sandbox).warn(
                "access (F_OK) failed before launch: {s} for {s}",
                .{ @errorName(access_err), abs_exe },
            );
            return errs.Error.LaunchFailed;
        };

        // Test seam: capture the composed spawn (argv + effective env
        // redirect) instead of running a real process. Sits after the
        // access probe and env composition (both asserted by tests) but
        // before the chmod pass — chmod shells out through util_proc.run,
        // which deadlocks under the single-threaded test io, and a spawn
        // no test may perform makes exec bits moot anyway.
        if (dom.spawn_hook.active) {
            var hook_argv: std.ArrayList([]const u8) = .empty;
            defer hook_argv.deinit(alloc);
            hook_argv.append(alloc, abs_exe) catch return errs.Error.OutOfMemory;
            for (cfg.launch_args) |a| hook_argv.append(alloc, a) catch return errs.Error.OutOfMemory;
            return dom.spawn_hook.record("none", hook_argv.items, map.get("HOME"), map.get("USERPROFILE"));
        }

        // Flip the exec bit recursively across the install tree.
        // Single-file chmod on the launcher isn't enough for games
        // whose .sh wrapper exec's a real binary inside (Ren'Py packs
        // the actual interpreter under `lib/py3-linux-x86_64/<game>`;
        // RPGM/Unity ports do similar). std.zip strips perms on
        // extract, so without this every wrapper bottoms out at
        // EACCES on the inner binary. `chmod -R u+rwX <install>`
        // gives the owner read/write, plus exec on directories and
        // any file that already has any exec bit; we follow it up
        // with a plain `+x` on the resolved launcher so wrappers
        // extracted with all exec bits stripped still recover.
        ensureTreeExecutable(alloc, self.io, cfg.install_path);
        ensureExecutable(alloc, self.io, abs_exe);

        // Build argv: [executable, launch_args...].
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        argv.append(alloc, abs_exe) catch return errs.Error.OutOfMemory;
        for (cfg.launch_args) |a| argv.append(alloc, a) catch return errs.Error.OutOfMemory;

        const child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = cfg.install_path },
            .environ_map = &map,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |e| {
            switch (e) {
                error.AccessDenied, error.PermissionDenied => self.setLastError(
                    "permission denied launching {s} — the file isn't executable and chmod +x didn't help (read-only mount, NoExec, foreign owner?)",
                    .{abs_exe},
                ),
                error.FileNotFound => self.setLastError(
                    "kernel couldn't find {s} at exec time (race? unmounted?)",
                    .{abs_exe},
                ),
                // The OS loader read the file and refused it. On Windows that
                // means "not a PE" — which is exactly what a Ren'Py `Game.sh`
                // looks like. Name the cause instead of echoing the enum, so
                // a bad launcher pick diagnoses itself.
                error.InvalidExe => self.setLastError(
                    "{s} is not an executable this OS can run (a Linux .sh / .AppImage on Windows?). Set the launcher explicitly on the install if the auto-pick chose wrong.",
                    .{abs_exe},
                ),
                else => self.setLastError(
                    "spawn failed: {s} (argv[0]={s}, cwd={s})",
                    .{ @errorName(e), abs_exe, cfg.install_path },
                ),
            }
            // err, not warn: the launch the user asked for did not happen.
            std.log.scoped(.sandbox).err(
                "spawn failed: {s} (argv[0]={s}, cwd={s})",
                .{ @errorName(e), abs_exe, cfg.install_path },
            );
            return errs.Error.LaunchFailed;
        };

        // child.id is a numeric pid on POSIX but a HANDLE (*anyopaque) on Windows; native
        // game launching + pid tracking is M2, so report 0 there for now.
        return .{ .pid = if (builtin.os.tag == .windows) 0 else (if (child.id) |pid| @intCast(pid) else 0) };
    }
};

/// Best-effort `chmod +x` so a launch script extracted from a zip
/// (which strips POSIX exec bits) becomes runnable. Shells out to
/// `/bin/chmod` so we don't need to touch syscall-level chmod
/// plumbing across libcs. Silent on failure — the upcoming exec
/// will surface a clearer error if it actually mattered.
/// Create `<dir>/xdg-open` as a no-op `#!/bin/sh\nexit 0` script so
/// games (Ren'Py / Unity / godot) that invoke `xdg-open <log_path>`
/// on crash get a silent return instead of f69's window losing focus
/// to a text editor opening the traceback. Idempotent — the file is
/// only written when missing. Best-effort: any error along the path
/// is logged and the shim is simply absent, leaving the host's real
/// xdg-open in charge (the upstream user experience).
fn ensureShimDir(io: std.Io, dir: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, dir) catch |e| {
        std.log.scoped(.sandbox).warn("xdg-open shim: createDirPath({s}) failed: {s}", .{ dir, @errorName(e) });
        return;
    };
    var path_buf: [256]u8 = undefined;
    const shim_path = std.fmt.bufPrint(&path_buf, "{s}/xdg-open", .{dir}) catch return;
    // Skip the write when the shim already exists — we don't expect
    // it to drift and re-writing wastes a syscall on every launch.
    std.Io.Dir.cwd().access(io, shim_path, .{}) catch {
        std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = shim_path,
            .data = "#!/bin/sh\nexit 0\n",
        }) catch |e| {
            std.log.scoped(.sandbox).warn("xdg-open shim: writeFile failed: {s}", .{@errorName(e)});
            return;
        };
        // Mark executable so `xdg-open` resolves to a runnable file.
        // `runChmod` shells out — `chmod` is universally available
        // and we don't want to plumb libc chmod across the codebase
        // for this one-shot setup.
        // We fake an alloc here — `runChmod` only uses it for argv
        // assembly which is small. Use the heap page allocator since
        // we don't have the lib allocator in this scope.
        runChmod(std.heap.page_allocator, io, &.{ "chmod", "+x", shim_path });
        std.log.scoped(.sandbox).info("xdg-open shim: installed at {s}", .{shim_path});
    };
}

fn ensureExecutable(alloc: std.mem.Allocator, io: std.Io, path: []const u8) void {
    runChmod(alloc, io, &.{ "chmod", "+x", path });
}

/// Recursively grant the owner read/write/exec on the install tree.
/// We use plain `u+rwx` (lowercase x — set unconditionally) instead
/// of `u+rwX` (capital X — only sets exec where it was already set)
/// because std.zip extracts everything as 0644 with no exec bits at
/// all, and Ren'Py games then can't exec their inner binary
/// (`lib/py3-linux-x86_64/<game>`) when the `.sh` wrapper tries.
///
/// Side effect: data files (images, audio) also get the exec bit set.
/// Harmless — Linux only consults that bit when exec'ing the file.
/// The reach is bounded to the per-game install dir, never spills
/// into the user's $HOME.
///
/// Falls back silently when chmod isn't on PATH — `spawn` later will
/// surface the eventual error with a specific message.
fn ensureTreeExecutable(alloc: std.mem.Allocator, io: std.Io, install_path: []const u8) void {
    runChmod(alloc, io, &.{ "chmod", "-R", "u+rwx", install_path });
}

fn runChmod(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) void {
    if (builtin.os.tag == .windows) return;
    // stderr stays silent (`.ignore`) — chmod's "no such file" messages
    // are not actionable here; the upcoming exec surfaces a clearer
    // error if it actually mattered. stdout is always empty for chmod,
    // freed unconditionally.
    const result = util_proc.run(alloc, io, argv, .{
        .stderr = .ignore,
    }) catch |e| {
        std.log.scoped(.sandbox).warn("chmod spawn failed: {s}", .{@errorName(e)});
        return;
    };
    defer alloc.free(result.stdout);
    if (result.exit_code != 0) {
        std.log.scoped(.sandbox).warn("chmod exited with code {d}", .{result.exit_code});
    }
}

// Test discovery — Zig 0.16's `zig build test` only walks reachable
// decls, not transitive imports. Without this the buildArgv tests in
// linux_bwrap.zig silently no-op.
test {
    _ = @import("linux_bwrap.zig");
    _ = @import("windows_sandboxie.zig");
}

const testing = std.testing;
const test_env = @import("util_test_env");

test "pickBackend: empty environ yields a usable backend on every OS" {
    var env = try test_env.TestEnv.init(testing.allocator, "pick-backend");
    defer env.deinit();
    var sb = pickBackend(testing.allocator, env.io, .empty, "");
    defer sb.deinit();
    try testing.expect(sb.backendName().len > 0);
    if (builtin.os.tag == .windows) {
        // No %ProgramFiles% in an empty environ and no override → the ONLY
        // correct outcome is the unsandboxed fallback, never a crash.
        try testing.expectEqualStrings("none", sb.backendName());
    }
    // Whatever was picked, the failure-detail contract holds from the start.
    try testing.expectEqualStrings("", sb.lastError());
}

test "pickBackend: real environ detects an actual Sandboxie install (Windows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var env = try test_env.TestEnv.init(testing.allocator, "pick-backend-real");
    defer env.deinit();

    // The REAL process environment — this is the only test that probes the
    // machine's actual %ProgramFiles% for a genuine Sandboxie install.
    // Environment-sensing by design: both outcomes have hard invariants,
    // and the print says which arm ran on this host.
    const environ: std.process.Environ = .{ .block = .global };
    var sb = pickBackend(testing.allocator, env.io, environ, "");
    defer sb.deinit();

    if (std.mem.eql(u8, sb.backendName(), "sandboxie")) {
        std.debug.print("pickBackend-real: Sandboxie detected at {s}\n", .{sb.sandboxiePath()});
        try testing.expect(std.mem.endsWith(u8, sb.sandboxiePath(), "\\Start.exe"));

        // Launch a real on-disk exe through the DETECTED install — the seam
        // captures the exact command line one step short of the spawn.
        try env.writeFile("games/Real/Real.exe", "MZ fake");
        const install = try env.path("games/Real");
        defer testing.allocator.free(install);
        dom.spawn_hook.install(0);
        defer dom.spawn_hook.reset();
        _ = try sb.launch(testing.allocator, .{
            .sandbox_home = "",
            .install_path = install,
            .executable = "Real.exe",
        });
        try testing.expectEqual(@as(usize, 1), dom.spawn_hook.calls);
        try testing.expectEqualStrings(sb.sandboxiePath(), dom.spawn_hook.arg(0).?);
        try testing.expectEqualStrings("/box:f69", dom.spawn_hook.arg(1).?);
    } else {
        // No Sandboxie on this host: the only correct outcome is the
        // unsandboxed fallback, never a crash or a half-picked backend.
        std.debug.print("pickBackend-real: no Sandboxie on this host — fallback to none\n", .{});
        try testing.expectEqualStrings("none", sb.backendName());
    }
}

test "NoSandbox.launch: sandbox_home redirects HOME (and USERPROFILE on Windows)" {
    var env = try test_env.TestEnv.init(testing.allocator, "nosandbox-home");
    defer env.deinit();
    try env.writeFile("install/Game.sh", "#!/bin/sh\nexit 0\n");
    try env.mkdirP("sbhome");
    const install = try env.path("install");
    defer testing.allocator.free(install);
    const sbhome = try env.path("sbhome");
    defer testing.allocator.free(sbhome);

    var ns = NoSandbox.init(env.io, .empty);
    dom.spawn_hook.install(777);
    defer dom.spawn_hook.reset();

    const res = try ns.launch(testing.allocator, .{
        .sandbox_home = sbhome,
        .install_path = install,
        .executable = "Game.sh",
    });
    try testing.expectEqual(@as(i32, 777), res.pid);
    try testing.expectEqual(@as(usize, 1), dom.spawn_hook.calls);
    try testing.expectEqualStrings(sbhome, dom.spawn_hook.envHome());
    if (builtin.os.tag == .windows) {
        // Windows games read USERPROFILE, not HOME — without this redirect the
        // per-game save isolation is a silent no-op (sandbox.zig:160-167).
        try testing.expectEqualStrings(sbhome, dom.spawn_hook.envUserProfile());
    }
    // argv[0] must be the ABSOLUTE launcher path — a bare relative argv[0]
    // becomes a PATH lookup at exec time and fails ENOENT.
    const argv0 = dom.spawn_hook.arg(0).?;
    try testing.expect(std.fs.path.isAbsolute(argv0));
    try testing.expect(std.mem.endsWith(u8, argv0, "Game.sh"));
}

test "NoSandbox.launch: empty sandbox_home leaves HOME untouched" {
    var env = try test_env.TestEnv.init(testing.allocator, "nosandbox-nohome");
    defer env.deinit();
    try env.writeFile("install/Game.sh", "#!/bin/sh\nexit 0\n");
    const install = try env.path("install");
    defer testing.allocator.free(install);

    var ns = NoSandbox.init(env.io, .empty);
    dom.spawn_hook.install(1);
    defer dom.spawn_hook.reset();
    _ = try ns.launch(testing.allocator, .{
        .sandbox_home = "",
        .install_path = install,
        .executable = "Game.sh",
    });
    // Empty environ snapshot + no override → the game sees no HOME at all.
    // A non-empty capture here would mean the opt-out path stopped opting out.
    try testing.expectEqualStrings("", dom.spawn_hook.envHome());
    try testing.expectEqualStrings("", dom.spawn_hook.envUserProfile());
}

test "NoSandbox.launch: missing launcher fails before spawn with a 'not found' detail" {
    var env = try test_env.TestEnv.init(testing.allocator, "nosandbox-missing");
    defer env.deinit();
    try env.mkdirP("install");
    const install = try env.path("install");
    defer testing.allocator.free(install);

    var ns = NoSandbox.init(env.io, .empty);
    dom.spawn_hook.install(1);
    defer dom.spawn_hook.reset();
    try testing.expectError(errs.Error.LaunchFailed, ns.launch(testing.allocator, .{
        .sandbox_home = "",
        .install_path = install,
        .executable = "Gone.sh",
    }));
    // Failed BEFORE reaching the spawn seam — the access probe caught it.
    try testing.expectEqual(@as(usize, 0), dom.spawn_hook.calls);
    try testing.expect(std.mem.indexOf(u8, ns.lastError(), "not found") != null);
}

test "applySandboxiePath: rejects junk everywhere, accepts a real file on Windows" {
    var env = try test_env.TestEnv.init(testing.allocator, "apply-sbie");
    defer env.deinit();
    var sb: Sandbox = .{ .none = NoSandbox.init(env.io, .empty) };
    defer sb.deinit();

    // Nonexistent path: rejected on every OS, backend untouched.
    const missing = try env.path("nope/Start.exe");
    defer testing.allocator.free(missing);
    try testing.expect(!sb.applySandboxiePath(testing.allocator, env.io, missing));
    try testing.expectEqualStrings("none", sb.backendName());
    try testing.expectEqualStrings("", sb.sandboxiePath());

    if (builtin.os.tag == .windows) {
        try env.writeFile("Sandboxie Portable/Start.exe", "MZ fake");
        const p = try env.path("Sandboxie Portable/Start.exe");
        defer testing.allocator.free(p);
        try testing.expect(sb.applySandboxiePath(testing.allocator, env.io, p));
        try testing.expectEqualStrings("sandboxie", sb.backendName());
        try testing.expectEqualStrings(p, sb.sandboxiePath());
    }
}
