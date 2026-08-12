// Sandbox configuration types. SandboxConfig is per-launch; it's built
// from the recipe's `sandbox` block + per-game override + AppConfig
// default.

const std = @import("std");

/// Canonical Distro lives in `util_domain`.
pub const Distro = @import("util_domain").Distro;

/// Host-side environment data the bwrap backend needs to wire up the
/// sandbox's display + audio sockets. Caller fills from
/// `init.minimal.environ` at launch time.
pub const HostInfo = struct {
    /// `$XDG_RUNTIME_DIR` — parent of wayland/pipewire/pulse/dbus sockets.
    xdg_runtime_dir: ?[]const u8 = null,
    /// `$WAYLAND_DISPLAY` — typically "wayland-1".
    wayland_display: ?[]const u8 = null,
    /// `$DISPLAY` — X11 display, e.g. ":0".
    x11_display: ?[]const u8 = null,
    /// `$HOME` — used as the source for fontconfig user font path.
    home: ?[]const u8 = null,
};

pub const EnvOverride = struct {
    name: []const u8,
    /// Final value to set. Prepend/append composition (e.g. compat
    /// recipes wanting `LD_LIBRARY_PATH=<resource>:<existing>`) is
    /// done by the caller — the sandbox just sets whatever it's given.
    value: []const u8,
};

pub const SandboxConfig = struct {
    /// Allow network. Recipe-level default; `false` adds `--unshare-net`.
    network: bool = true,
    /// Extra read-only host paths to bind into the sandbox (useful for
    /// system fonts, GPU drivers when default binds aren't enough).
    bind_extra: []const []const u8 = &.{},
    /// Per-game sandbox HOME, shared across versions. Path on the host;
    /// the sandbox sees this as $HOME. Must exist + be writable.
    sandbox_home: []const u8,
    /// Read-only bind for the install dir. Bound at /game inside the
    /// sandbox + chdir'd into.
    install_path: []const u8,
    /// Game executable, relative to install_path. Either `./foo.sh`
    /// or `foo.sh` — both resolved against /game.
    executable: []const u8,
    launch_args: []const []const u8 = &.{},
    /// Host environment snapshot — filled from `std.process.Init.environ`.
    host: HostInfo = .{},
    /// Extra env vars to inject at launch time. Compat recipes emit
    /// these to provide host-compat libraries (LD_LIBRARY_PATH, etc).
    /// Applied after HOME is set so a recipe that overrides HOME via
    /// env_extra wins. Empty = no overrides.
    env_extra: []const EnvOverride = &.{},
};

pub const SpawnResult = struct {
    /// PID of the launched process (host-side).
    pid: i32,
};

// --- test seam ------------------------------------------------------------
// Every backend's `launch` bottoms out in `std.process.spawn`, which a test
// must never reach: a spawned game escapes the test sandbox, and the hero-play
// GUI flow was permanently unreachable because of it. When `active`, the
// backends record the fully-composed spawn (argv after launcher resolution +
// separator normalization, plus the effective HOME/USERPROFILE for the
// NoSandbox env-redirect path) and return `fake_pid` without spawning.
//
// The hook sits as late as possible — after existence checks, env composition,
// and argv assembly — so a test exercises everything except the spawn itself.
// Unset in production: one bool check per launch, same contract as
// `file_picker.test_hook`.
pub const spawn_hook = struct {
    pub var active: bool = false;
    pub var calls: usize = 0;
    pub var fake_pid: i32 = 0;

    var argv_buf: [2048]u8 = undefined;
    var argv_len: usize = 0;
    var home_buf: [1024]u8 = undefined;
    var home_len: usize = 0;
    var userprofile_buf: [1024]u8 = undefined;
    var userprofile_len: usize = 0;
    var backend_buf: [32]u8 = undefined;
    var backend_len: usize = 0;

    pub fn install(pid: i32) void {
        reset();
        active = true;
        fake_pid = pid;
    }

    pub fn reset() void {
        active = false;
        calls = 0;
        fake_pid = 0;
        argv_len = 0;
        home_len = 0;
        userprofile_len = 0;
        backend_len = 0;
    }

    /// Record one intercepted spawn. argv entries are joined with '\n' so a
    /// test can match exact entries without a separator ever colliding with
    /// path content. Overlong captures truncate silently — the assertions
    /// in play match prefixes/substrings well inside the buffers.
    pub fn record(backend: []const u8, argv: []const []const u8, home: ?[]const u8, userprofile: ?[]const u8) SpawnResult {
        calls += 1;
        backend_len = @min(backend.len, backend_buf.len);
        @memcpy(backend_buf[0..backend_len], backend[0..backend_len]);
        argv_len = 0;
        for (argv, 0..) |a, i| {
            if (i > 0 and argv_len < argv_buf.len) {
                argv_buf[argv_len] = '\n';
                argv_len += 1;
            }
            const n = @min(a.len, argv_buf.len - argv_len);
            @memcpy(argv_buf[argv_len..][0..n], a[0..n]);
            argv_len += n;
        }
        home_len = 0;
        if (home) |h| {
            home_len = @min(h.len, home_buf.len);
            @memcpy(home_buf[0..home_len], h[0..home_len]);
        }
        userprofile_len = 0;
        if (userprofile) |u| {
            userprofile_len = @min(u.len, userprofile_buf.len);
            @memcpy(userprofile_buf[0..userprofile_len], u[0..userprofile_len]);
        }
        return .{ .pid = fake_pid };
    }

    /// '\n'-joined argv of the last intercepted spawn.
    pub fn argvJoined() []const u8 {
        return argv_buf[0..argv_len];
    }

    /// The `i`th argv entry of the last intercepted spawn, or null.
    pub fn arg(i: usize) ?[]const u8 {
        var it = std.mem.splitScalar(u8, argvJoined(), '\n');
        var idx: usize = 0;
        while (it.next()) |a| : (idx += 1) {
            if (idx == i) return a;
        }
        return null;
    }

    /// Effective HOME the game would have seen ("" when not overridden).
    pub fn envHome() []const u8 {
        return home_buf[0..home_len];
    }

    /// Effective USERPROFILE ("" when not overridden / non-Windows).
    pub fn envUserProfile() []const u8 {
        return userprofile_buf[0..userprofile_len];
    }

    pub fn backendName() []const u8 {
        return backend_buf[0..backend_len];
    }
};
