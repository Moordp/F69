// bubblewrap (`bwrap`) launcher. Ported from `spikes/spike-01-bwrap.zig`
// (NixOS-validated 2026-05-08).
//
// **Arg list source of truth:** still ultimately
// `steam-runtime-launcher-service`. We carry a subset — Pulse +
// PipeWire sockets, DBus session bus, GPU device nodes, `/dev/shm`,
// fontconfig cache. Don't reinvent.
//
// Detection: PATH lookup for `bwrap` + `unshare -Ur true` smoke test
// for unprivileged userns. On Debian 12 / Ubuntu 24.04 the smoke test
// commonly fails; we currently return null (no bwrap backend) so the
// Sandbox falls back to `none`. A future round can wire a
// "best-effort no-userns" mode.
//
// `buildArgv` is split out as a *pure* function so the argv layout is
// unit-testable without spawning anything. `launch` is just buildArgv
// + std.process.spawn.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const log = std.log.scoped(.bwrap);
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const util_proc = @import("util_proc");

pub const Bwrap = struct {
    alloc: std.mem.Allocator,
    io: Io,
    /// Resolved absolute path to the bwrap executable. Allocator-owned.
    bwrap_path: []u8,
    distro: dom.Distro,

    /// Probe the host. Returns null when bwrap is missing OR unprivileged
    /// userns is blocked. Caller's `Sandbox` falls back to `.none` in
    /// that case.
    pub fn detect(alloc: std.mem.Allocator, io: Io, environ: std.process.Environ) ?Bwrap {
        const path = findInPath(alloc, io, environ, "bwrap") catch |e| {
            log.info("bwrap not found on $PATH: {s}", .{@errorName(e)});
            return null;
        };
        errdefer alloc.free(path);

        if (!testUserns(alloc, io)) {
            log.warn("unprivileged userns is blocked; bwrap backend disabled", .{});
            alloc.free(path);
            return null;
        }

        const distro = detectDistro(alloc, io);
        log.info("bwrap detected: {s} (distro={s})", .{ path, @tagName(distro) });
        return .{
            .alloc = alloc,
            .io = io,
            .bwrap_path = path,
            .distro = distro,
        };
    }

    pub fn deinit(self: *Bwrap) void {
        self.alloc.free(self.bwrap_path);
        self.* = undefined;
    }

    /// Build the bwrap argv + spawn it. Inherits stdout/stderr so the
    /// game's output streams to the f69 console.
    pub fn launch(self: *Bwrap, alloc: std.mem.Allocator, cfg: dom.SandboxConfig) errs.Error!dom.SpawnResult {
        // `buildArgv` may heap-allocate path joins (pipewire/pulse/dbus/
        // wayland/fontconfig). Give it an arena so all of it gets torn
        // down in one go after spawn returns.
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        var argv: std.ArrayList([]const u8) = .empty;
        buildArgv(&argv, aa, self.bwrap_path, self.distro, cfg) catch |e| switch (e) {
            error.OutOfMemory => return errs.Error.OutOfMemory,
        };

        log.info("launching {d}-arg bwrap (exe={s})", .{ argv.items.len, cfg.executable });
        for (argv.items) |a| log.debug("  arg: {s}", .{a});

        // Test seam: capture the composed bwrap command line instead of
        // spawning (bwrap redirects HOME via bind args, not env — nothing
        // env-shaped to record here).
        if (dom.spawn_hook.active) {
            return dom.spawn_hook.record("bwrap", argv.items, null, null);
        }

        const child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |e| {
            log.warn("bwrap spawn failed: {s}", .{@errorName(e)});
            return errs.Error.LaunchFailed;
        };
        // Don't wait — game runs detached. Future round can return a
        // handle for "Stop" / "Logs" actions.
        return .{ .pid = if (builtin.os.tag == .windows) 0 else (if (child.id) |pid| @intCast(pid) else 0) };
    }
};

/// Assemble the bwrap argv for the given configuration. No IO.
///
/// **Allocator contract:** `alloc` MUST be an arena-style allocator
/// (or one whose lifetime covers the eventual `std.process.spawn`).
/// `buildArgv` heap-allocates a handful of path joins (pipewire /
/// pulse / dbus socket paths, wayland socket, user fontconfig dirs)
/// that the argv slices then borrow from. Freeing each item
/// individually would be fiddly — caller's arena tears them all down
/// at once. `launch()` already wraps in an ArenaAllocator; tests do
/// the same.
///
/// Layout, in order:
///   1. bwrap exe path
///   2. OS namespace flags (--unshare-…, --die-with-parent)
///   3. Read-only filesystem skeleton (/usr, /etc/…)
///   4. Distro-specific binds (NixOS: /nix + /run/current-system…;
///      others: /lib + /lib64 + /bin + /sbin)
///   5. /tmp + /run + /proc + /dev + GPU device nodes
///   6. Sandbox HOME (rw) + install dir (ro at /game)
///   7. Display + audio sockets (Wayland/X11, PipeWire, Pulse, DBus)
///   8. Fontconfig binds
///   9. NSS-related binds (so hostname lookups inside the sandbox work)
///  10. Recipe-supplied `bind_extra`
///  11. --setenv HOME + --chdir /game + optional --unshare-net
///  12. The command (executable + launch_args)
pub fn buildArgv(
    argv: *std.ArrayList([]const u8),
    alloc: std.mem.Allocator,
    bwrap_path: []const u8,
    distro: dom.Distro,
    cfg: dom.SandboxConfig,
) error{OutOfMemory}!void {
    try argv.append(alloc, bwrap_path);

    // ---- 2. OS namespace flags ----
    try argv.appendSlice(alloc, &.{
        "--unshare-user",
        "--unshare-pid",
        "--unshare-ipc",
        "--unshare-uts",
        "--unshare-cgroup-try",
        "--die-with-parent",
    });

    // ---- 3. Read-only filesystem skeleton ----
    try argv.appendSlice(alloc, &.{
        "--ro-bind",     "/usr",                 "/usr",
        "--ro-bind-try", "/etc/resolv.conf",     "/etc/resolv.conf",
        "--ro-bind-try", "/etc/hostname",        "/etc/hostname",
        "--ro-bind-try", "/etc/hosts",           "/etc/hosts",
        "--ro-bind-try", "/etc/localtime",       "/etc/localtime",
        "--ro-bind-try", "/etc/passwd",          "/etc/passwd",
        "--ro-bind-try", "/etc/group",           "/etc/group",
        "--ro-bind-try", "/etc/machine-id",      "/etc/machine-id",
        "--ro-bind-try", "/etc/ssl",             "/etc/ssl",
        "--ro-bind-try", "/etc/ca-certificates", "/etc/ca-certificates",
    });

    // ---- 4. Distro-specific binds ----
    if (distro == .nixos) {
        // `/run/current-system/sw/lib` (NSS plugins for hostname lookups,
        // per spike-01 findings) is already covered by the parent
        // `/run/current-system` bind — re-binding the child path
        // collides with the parent's read-only mount and aborts the
        // launch.
        try argv.appendSlice(alloc, &.{
            "--ro-bind-try", "/nix",                       "/nix",
            "--ro-bind-try", "/run/current-system",        "/run/current-system",
            "--ro-bind-try", "/run/wrappers",              "/run/wrappers",
            "--ro-bind-try", "/run/opengl-driver",         "/run/opengl-driver",
            "--ro-bind-try", "/run/opengl-driver-32",      "/run/opengl-driver-32",
        });
    } else {
        try argv.appendSlice(alloc, &.{
            "--ro-bind-try", "/lib",   "/lib",
            "--ro-bind-try", "/lib32", "/lib32",
            "--ro-bind-try", "/lib64", "/lib64",
            "--ro-bind-try", "/bin",   "/bin",
            "--ro-bind-try", "/sbin",  "/sbin",
        });
    }

    // ---- 5. /tmp + /run + /proc + /dev + GPU ----
    try argv.appendSlice(alloc, &.{
        "--tmpfs",        "/tmp",
        "--tmpfs",        "/run",
        "--proc",         "/proc",
        "--dev",          "/dev",
        "--dev-bind-try", "/dev/dri",            "/dev/dri",
        "--dev-bind-try", "/dev/nvidia0",        "/dev/nvidia0",
        "--dev-bind-try", "/dev/nvidiactl",      "/dev/nvidiactl",
        "--dev-bind-try", "/dev/nvidia-modeset", "/dev/nvidia-modeset",
        "--dev-bind-try", "/dev/nvidia-uvm",     "/dev/nvidia-uvm",
        "--dev-bind-try", "/dev/snd",            "/dev/snd",
        "--dev-bind-try", "/dev/shm",            "/dev/shm",
    });

    // ---- 6. Sandbox HOME (rw) + install dir (ro) ----
    try argv.appendSlice(alloc, &.{
        "--bind",    cfg.sandbox_home, cfg.sandbox_home,
        "--ro-bind", cfg.install_path, "/game",
    });

    // ---- 7. Display + audio sockets ----
    if (cfg.host.xdg_runtime_dir) |runtime| {
        // PipeWire (modern), Pulse (legacy fallback), DBus session bus.
        const pipewire_0 = try std.fmt.allocPrint(alloc, "{s}/pipewire-0", .{runtime});
        try argv.appendSlice(alloc, &.{ "--ro-bind-try", pipewire_0, pipewire_0 });
        const pulse = try std.fmt.allocPrint(alloc, "{s}/pulse", .{runtime});
        try argv.appendSlice(alloc, &.{ "--ro-bind-try", pulse, pulse });
        const dbus = try std.fmt.allocPrint(alloc, "{s}/bus", .{runtime});
        try argv.appendSlice(alloc, &.{ "--ro-bind-try", dbus, dbus });

        if (cfg.host.wayland_display) |wd| {
            const wpath = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ runtime, wd });
            try argv.appendSlice(alloc, &.{ "--ro-bind-try", wpath, wpath });
            // Some games look at the bare env var too.
            try argv.appendSlice(alloc, &.{ "--setenv", "WAYLAND_DISPLAY", wd });
        }

        // Make the runtime path itself addressable so $XDG_RUNTIME_DIR
        // still resolves inside the sandbox.
        try argv.appendSlice(alloc, &.{ "--setenv", "XDG_RUNTIME_DIR", runtime });
    }

    if (cfg.host.x11_display) |xd| {
        try argv.appendSlice(alloc, &.{ "--ro-bind-try", "/tmp/.X11-unix", "/tmp/.X11-unix" });
        try argv.appendSlice(alloc, &.{ "--setenv", "DISPLAY", xd });
    }

    // ---- 8. Fontconfig — without these, games fall back to ugly
    // bitmap fonts. `--ro-bind-try` means missing paths are silently
    // skipped, so this is cheap on every distro. ----
    try argv.appendSlice(alloc, &.{
        "--ro-bind-try", "/etc/fonts",       "/etc/fonts",
        "--ro-bind-try", "/usr/share/fonts", "/usr/share/fonts",
    });
    if (cfg.host.home) |h| {
        const user_fonts = try std.fmt.allocPrint(alloc, "{s}/.local/share/fonts", .{h});
        try argv.appendSlice(alloc, &.{ "--ro-bind-try", user_fonts, user_fonts });
        const user_fontcache = try std.fmt.allocPrint(alloc, "{s}/.cache/fontconfig", .{h});
        try argv.appendSlice(alloc, &.{ "--ro-bind-try", user_fontcache, user_fontcache });
    }

    // ---- 9. NSS-related — hostname/host lookups via getaddrinfo /
    // getent work without these because we bound /etc/resolv.conf,
    // but `getent hosts` style paths need nsswitch.conf + the NSS .so
    // plugins. ----
    try argv.appendSlice(alloc, &.{
        "--ro-bind-try", "/etc/nsswitch.conf", "/etc/nsswitch.conf",
    });

    // ---- 10. Recipe-supplied extras ----
    for (cfg.bind_extra) |p| {
        try argv.appendSlice(alloc, &.{ "--ro-bind-try", p, p });
    }

    // ---- 11. Env + cwd + optional network kill ----
    try argv.appendSlice(alloc, &.{
        "--setenv", "HOME", cfg.sandbox_home,
        "--chdir",  "/game",
    });
    // Compat-recipe / caller-supplied env overrides. Emitted after
    // HOME so a recipe can override HOME explicitly if it really
    // needs to.
    for (cfg.env_extra) |kv| {
        try argv.appendSlice(alloc, &.{ "--setenv", kv.name, kv.value });
    }
    if (!cfg.network) {
        try argv.append(alloc, "--unshare-net");
    }

    // ---- 12. The actual command ----
    // Recipe may carry "./foo.sh" or "foo.sh"; both resolve against
    // /game since we chdir'd into it. Pass through verbatim.
    try argv.append(alloc, cfg.executable);
    for (cfg.launch_args) |a| try argv.append(alloc, a);
}

// ============================================================
//  detection helpers
// ============================================================

fn findInPath(alloc: std.mem.Allocator, io: Io, environ: std.process.Environ, name: []const u8) ![]u8 {
    const path_env = environ.getAlloc(alloc, "PATH") catch return error.PathUnset;
    defer alloc.free(path_env);

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
        Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch {
            alloc.free(candidate);
            continue;
        };
        return candidate;
    }
    return error.NotFound;
}

fn testUserns(alloc: std.mem.Allocator, io: Io) bool {
    // Best-effort probe — stderr kept silent so unsupported kernels
    // don't spam the f69 log; the wrapper's "userns blocked" warn
    // line is the only signal we want surfaced.
    const result = util_proc.run(alloc, io, &.{ "unshare", "-Ur", "--", "true" }, .{
        .stderr = .ignore,
    }) catch return false;
    defer alloc.free(result.stdout);
    return result.exit_code == 0;
}

fn detectDistro(alloc: std.mem.Allocator, io: Io) dom.Distro {
    const content = Io.Dir.cwd().readFileAlloc(io, "/etc/os-release", alloc, .unlimited) catch return .other;
    defer alloc.free(content);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "ID=")) continue;
        const v = std.mem.trim(u8, line[3..], "\"' \t");
        if (std.mem.eql(u8, v, "nixos")) return .nixos;
        if (std.mem.eql(u8, v, "arch")) return .arch;
        if (std.mem.eql(u8, v, "debian")) return .debian;
        if (std.mem.eql(u8, v, "ubuntu")) return .ubuntu;
        if (std.mem.eql(u8, v, "fedora")) return .fedora;
        return .other;
    }
    return .other;
}

// ============================================================
//  tests — pure buildArgv coverage
// ============================================================

const testing = std.testing;

fn containsArg(items: []const []const u8, needle: []const u8) bool {
    for (items) |it| if (std.mem.eql(u8, it, needle)) return true;
    return false;
}

fn containsBindTrio(items: []const []const u8, flag: []const u8, host: []const u8, sandbox: []const u8) bool {
    var i: usize = 0;
    while (i + 2 < items.len) : (i += 1) {
        if (std.mem.eql(u8, items[i], flag) and
            std.mem.eql(u8, items[i + 1], host) and
            std.mem.eql(u8, items[i + 2], sandbox)) return true;
    }
    return false;
}

const test_cfg_base = dom.SandboxConfig{
    .sandbox_home = "/sandbox/home",
    .install_path = "/games/foo",
    .executable = "./foo.sh",
};

/// Bundle of arena + argv list so each test can spin up scaffolding
/// in a single call.
const TestArgv = struct {
    arena: std.heap.ArenaAllocator,
    argv: std.ArrayList([]const u8),

    fn init() TestArgv {
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .argv = .empty,
        };
    }

    fn deinit(self: *TestArgv) void {
        self.arena.deinit();
    }
};

test "buildArgv: NixOS distro emits /nix binds" {
    var t = TestArgv.init();
    defer t.deinit();
    try buildArgv(&t.argv, t.arena.allocator(), "bwrap", .nixos, test_cfg_base);

    try testing.expect(containsBindTrio(t.argv.items, "--ro-bind-try", "/nix", "/nix"));
    try testing.expect(containsBindTrio(t.argv.items, "--ro-bind-try", "/run/opengl-driver", "/run/opengl-driver"));
    try testing.expect(containsBindTrio(t.argv.items, "--ro-bind-try", "/run/current-system", "/run/current-system"));
    // `/run/current-system/sw/lib` is covered transitively by the
    // parent `/run/current-system` bind — re-binding the child
    // overlay-collides on a read-only mount.
    try testing.expect(!containsBindTrio(t.argv.items, "--ro-bind-try", "/run/current-system/sw/lib", "/run/current-system/sw/lib"));
    // Should NOT have the Debian-style /lib binds.
    try testing.expect(!containsBindTrio(t.argv.items, "--ro-bind-try", "/lib", "/lib"));
}

test "buildArgv: Debian distro emits /lib binds, not /nix" {
    var t = TestArgv.init();
    defer t.deinit();
    try buildArgv(&t.argv, t.arena.allocator(), "bwrap", .debian, test_cfg_base);

    try testing.expect(containsBindTrio(t.argv.items, "--ro-bind-try", "/lib", "/lib"));
    try testing.expect(containsBindTrio(t.argv.items, "--ro-bind-try", "/lib64", "/lib64"));
    try testing.expect(containsBindTrio(t.argv.items, "--ro-bind-try", "/bin", "/bin"));
    try testing.expect(!containsBindTrio(t.argv.items, "--ro-bind-try", "/nix", "/nix"));
}

test "buildArgv: network=false adds --unshare-net" {
    var cfg = test_cfg_base;
    cfg.network = false;
    var t = TestArgv.init();
    defer t.deinit();
    try buildArgv(&t.argv, t.arena.allocator(), "bwrap", .arch, cfg);
    try testing.expect(containsArg(t.argv.items, "--unshare-net"));
}

test "buildArgv: network=true (default) does NOT add --unshare-net" {
    var t = TestArgv.init();
    defer t.deinit();
    try buildArgv(&t.argv, t.arena.allocator(), "bwrap", .arch, test_cfg_base);
    try testing.expect(!containsArg(t.argv.items, "--unshare-net"));
}

test "buildArgv: wayland socket bound when WAYLAND_DISPLAY set" {
    var cfg = test_cfg_base;
    cfg.host = .{
        .xdg_runtime_dir = "/run/user/1000",
        .wayland_display = "wayland-1",
    };
    var t = TestArgv.init();
    defer t.deinit();
    try buildArgv(&t.argv, t.arena.allocator(), "bwrap", .nixos, cfg);
    try testing.expect(containsBindTrio(t.argv.items, "--ro-bind-try", "/run/user/1000/wayland-1", "/run/user/1000/wayland-1"));
    try testing.expect(containsBindTrio(t.argv.items, "--ro-bind-try", "/run/user/1000/pipewire-0", "/run/user/1000/pipewire-0"));
}

test "buildArgv: missing wayland_display skips wayland bind" {
    var cfg = test_cfg_base;
    cfg.host = .{ .xdg_runtime_dir = "/run/user/1000" }; // no wayland_display
    var t = TestArgv.init();
    defer t.deinit();
    try buildArgv(&t.argv, t.arena.allocator(), "bwrap", .nixos, cfg);
    // pipewire / pulse / dbus still bound (always-on when runtime set)
    try testing.expect(containsBindTrio(t.argv.items, "--ro-bind-try", "/run/user/1000/pipewire-0", "/run/user/1000/pipewire-0"));
    // wayland-N bind is absent
    for (t.argv.items) |it| {
        try testing.expect(std.mem.indexOf(u8, it, "wayland-") == null);
    }
}

test "buildArgv: x11 display sets DISPLAY env + binds /tmp/.X11-unix" {
    var cfg = test_cfg_base;
    cfg.host = .{ .x11_display = ":0" };
    var t = TestArgv.init();
    defer t.deinit();
    try buildArgv(&t.argv, t.arena.allocator(), "bwrap", .arch, cfg);
    try testing.expect(containsBindTrio(t.argv.items, "--ro-bind-try", "/tmp/.X11-unix", "/tmp/.X11-unix"));
    // --setenv DISPLAY :0 — find adjacent triple
    var found_display_env = false;
    var i: usize = 0;
    while (i + 2 < t.argv.items.len) : (i += 1) {
        if (std.mem.eql(u8, t.argv.items[i], "--setenv") and
            std.mem.eql(u8, t.argv.items[i + 1], "DISPLAY") and
            std.mem.eql(u8, t.argv.items[i + 2], ":0")) {
            found_display_env = true;
            break;
        }
    }
    try testing.expect(found_display_env);
}

test "buildArgv: bind_extra paths land in argv" {
    var cfg = test_cfg_base;
    cfg.bind_extra = &.{ "/opt/proton", "/opt/wine-deps" };
    var t = TestArgv.init();
    defer t.deinit();
    try buildArgv(&t.argv, t.arena.allocator(), "bwrap", .arch, cfg);
    try testing.expect(containsBindTrio(t.argv.items, "--ro-bind-try", "/opt/proton", "/opt/proton"));
    try testing.expect(containsBindTrio(t.argv.items, "--ro-bind-try", "/opt/wine-deps", "/opt/wine-deps"));
}

test "buildArgv: sandbox HOME + install dir + executable + chdir" {
    var t = TestArgv.init();
    defer t.deinit();
    try buildArgv(&t.argv, t.arena.allocator(), "/usr/bin/bwrap", .arch, .{
        .sandbox_home = "/sandbox/h",
        .install_path = "/games/g",
        .executable = "./play.sh",
        .launch_args = &.{ "--cheat", "--debug" },
    });

    // First arg = bwrap path
    try testing.expectEqualStrings("/usr/bin/bwrap", t.argv.items[0]);

    // The mounts we care about
    try testing.expect(containsBindTrio(t.argv.items, "--bind", "/sandbox/h", "/sandbox/h"));
    try testing.expect(containsBindTrio(t.argv.items, "--ro-bind", "/games/g", "/game"));

    // HOME redirected + chdir
    var found_home = false;
    var found_chdir = false;
    var i: usize = 0;
    while (i + 1 < t.argv.items.len) : (i += 1) {
        if (std.mem.eql(u8, t.argv.items[i], "--setenv") and
            i + 2 < t.argv.items.len and
            std.mem.eql(u8, t.argv.items[i + 1], "HOME") and
            std.mem.eql(u8, t.argv.items[i + 2], "/sandbox/h")) found_home = true;
        if (std.mem.eql(u8, t.argv.items[i], "--chdir") and
            std.mem.eql(u8, t.argv.items[i + 1], "/game")) found_chdir = true;
    }
    try testing.expect(found_home);
    try testing.expect(found_chdir);

    // Executable + args land at the tail.
    const n = t.argv.items.len;
    try testing.expectEqualStrings("--debug", t.argv.items[n - 1]);
    try testing.expectEqualStrings("--cheat", t.argv.items[n - 2]);
    try testing.expectEqualStrings("./play.sh", t.argv.items[n - 3]);
}
