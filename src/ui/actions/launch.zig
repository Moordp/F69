// Per-game launch + convert + running-games tracking + saves/folder
// helpers + compat env composition. After R9 lives separate from the
// sync / downloads / installer pipelines that surround it.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.ui_actions);
const library = @import("library");
const recipe = @import("recipe");
const sandbox_mod = @import("sandbox");
const convert_mod = @import("convert");
const compat_mod = @import("compat");
const downloads = @import("downloads");
const version_mod = @import("util_version");
const file_picker = @import("util_file_picker");
const argv = @import("util_argv");
const dvui = @import("dvui");
const types = @import("../types.zig");
const state_mod = @import("../state.zig");
const owned_types = @import("../owned.zig");
const job_mod = @import("../job.zig");
const mods_act = @import("mods.zig");

const Frame = types.Frame;
const State = types.State;

const RunningGamesMap = owned_types.RunningGamesMap;

// ============================================================
//  per-game launch — recipe + sandbox
// ============================================================

/// Resolve the recipe for `game`, ensure the placeholder install dir
/// + per-game sandbox HOME exist, then ask the sandbox backend to
/// launch the recipe's `launch.linux` executable.
///
/// Layout (until Phase 7 installer lands a real version-keyed layout):
///   - install dir:  `<library_root>/<thread_id>/`
///   - sandbox HOME: `<library_root>/<thread_id>/.f69-home/`
///
/// On failure: writes a one-line message to `state.launch_msg_buf`.
/// On success: same buffer reports the PID.
pub fn doLaunchGame(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // ---- 1. install_path ----
    // Resolve which install row Launch acts on:
    //   1. Honour `state.detail_picker_install_id` — whatever the
    //      detail-page dropdown currently shows is what runs.
    //   2. Fall back to the newest install (top of version-desc list)
    //      when the picker hasn't recorded a choice yet (e.g. detail
    //      page opened then Launch hit from a keybind before paint).
    //   3. Last-ditch fallback: legacy `<library_root>/<tid>/` for the
    //      pre-multi-install layout — keeps Launch alive for installs
    //      that predate the installs table.
    var fallback_buf: [640]u8 = undefined;
    const installs_owned: ?[]library.Install = frame.lib.listInstalls(game.f95_thread_id) catch null;
    defer if (installs_owned) |list| frame.lib.freeInstalls(list);
    const picked_install: ?*const library.Install = blk: {
        const list = installs_owned orelse break :blk null;
        if (list.len == 0) break :blk null;
        if (state.detail_picker_install_id) |sel| {
            for (list) |*inst| {
                if (std.mem.eql(u8, inst.id[0..], sel[0..])) break :blk inst;
            }
        }
        break :blk &list[0];
    };
    const install_path: []const u8 = if (picked_install) |i|
        i.install_path
    else
        std.fmt.bufPrint(&fallback_buf, "{s}/{d}", .{ frame.info.library_root, game.f95_thread_id }) catch {
            state.setLaunchMsg("Install path buffer overflow.");
            return;
        };
    std.Io.Dir.cwd().access(frame.io, install_path, .{}) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "No install at {s}. Download the game first.", .{install_path}) catch "No install dir.";
        state.setLaunchMsg(msg);
        return;
    };

    // ---- 2. sandbox HOME ----
    // Only built when the effective sandbox decision says "sandboxed".
    // For host-mode launches we pass an empty `sandbox_home` to
    // signal NoSandbox to keep the host's own HOME in the env.
    const want_sandbox = shouldSandbox(state, game);
    var home_buf: [640]u8 = undefined;
    var sandbox_home: []const u8 = "";
    if (want_sandbox) {
        sandbox_home = std.fmt.bufPrint(&home_buf, "{s}/{d}/.f69-home", .{ frame.info.library_root, game.f95_thread_id }) catch {
            state.setLaunchMsg("Sandbox HOME buffer overflow.");
            return;
        };
        std.Io.Dir.cwd().createDirPath(frame.io, sandbox_home) catch |e| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Failed to create sandbox HOME: {s}", .{@errorName(e)}) catch "createDirPath failed";
            state.setLaunchMsg(msg);
            return;
        };
    }

    // ---- 3. resolve executable ----
    // Launcher resolution: heuristic-only. We used to honor a recipe
    // `launch.linux` pin, but that field has been retired — the
    // heuristic finder catches the canonical cases and any pin
    // belongs in a per-game settings override (future work).
    //
    // Auto-convert before launch when nothing Linux-runnable is on
    // disk yet. The convert preset matcher figures out the spec from
    // the detected engine; `.none` means "nothing to do."
    var exe_buf: [512]u8 = undefined;
    var exe_storage: []const u8 = "";
    var custom_args: []const []const u8 = &.{};
    var owns_custom_args = false;
    defer if (owns_custom_args) argv.free(alloc, custom_args);

    // Per-install custom launch override (installs.executable). When set, run it
    // verbatim and skip the heuristic finder + auto-convert.
    if (picked_install) |inst| if (inst.executable) |custom| if (custom.len > 0) {
        exe_storage = custom;
        const raw_args: []const u8 = inst.launch_args orelse "";
        if (argv.tokenize(alloc, raw_args, .{ .install = install_path, .exe = custom })) |toks| {
            custom_args = toks;
            owns_custom_args = true;
        } else |_| {}
        log.info("launch: custom override '{s}' under {s}", .{ custom, install_path });
    };

    if (exe_storage.len == 0 and findLinuxLauncher(frame.io, alloc, install_path, &exe_buf) == null) {
        const conv_spec = mods_act.resolveConvertSpec(frame, install_path);
        if (conv_spec != .none) {
            state.setLaunchMsg("Converting before launch...");
            frame.convert_svc.convert(install_path, conv_spec, false) catch |e| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Auto-convert failed: {s}", .{@errorName(e)}) catch "Auto-convert failed";
                state.setLaunchMsg(msg);
                return;
            };
        }
    }

    // Second pass post-convert (or first pass when no convert was
    // needed). The launcher should exist now if everything worked.
    if (exe_storage.len == 0) {
        if (findLinuxLauncher(frame.io, alloc, install_path, &exe_buf)) |found| {
            exe_storage = found;
            log.info("launch: auto-picked launcher '{s}' under {s}", .{ found, install_path });
        } else {
            // Nothing Linux-native on disk. Look for a Windows .exe so we
            // can give an actionable message.
            if (findWindowsExe(frame.io, alloc, install_path, &exe_buf)) |win_exe| {
                var buf: [320]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &buf,
                    "Found Windows binary ({s}) — click Convert to translate it for Linux first.",
                    .{win_exe},
                ) catch "Windows build — click Convert first.";
                state.notifyErr(msg);
            } else {
                var buf: [384]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &buf,
                    "No runnable found under {s}. Either the archive didn't extract cleanly (re-download), or the install layout is non-standard (open the folder and check what's there).",
                    .{install_path},
                ) catch "No runnable found in the install dir.";
                state.notifyErr(msg);
            }
            return;
        }
    }

    // Sandbox config used to pull `network` / `bind_extra` from the
    // recipe. Those are local-user decisions; default to safe (net
    // on, no extra binds). Per-game overrides will move to a DB
    // settings table when needed.
    const net: bool = true;

    // ---- 3.5. Compose env_extra from any compat fixes applied to
    //           this install. Pre-merges prepend-mode pairs with the
    //           host environ so the sandbox sees plain `SET KEY VAL`.
    //           The compat resource dir is bound into the sandbox via
    //           `bind_extra` so env paths pointing at it actually
    //           resolve inside the bwrap namespace.
    const compat_envs: []sandbox_mod.EnvOverride = blk: {
        if (picked_install) |inst| {
            break :blk composeCompatEnv(frame, &inst.id) catch |e| switch (e) {
                else => {
                    log.warn("compat env compose failed: {s}", .{@errorName(e)});
                    break :blk &.{};
                },
            };
        }
        break :blk &.{};
    };
    defer freeCompatEnv(frame.lib.alloc, compat_envs);

    // Pre-launch diagnostics. Run cheap static checks (ldd unresolved
    // libs, etc.) on the picked launcher. If anything actionable is
    // detected AND the user hasn't already opted into a fix / "Try
    // anyway", open the launch diagnostic dialog and bail before
    // spawn. The dialog buttons re-invoke `doLaunchGame` either with
    // a fix flag set or with `launch_diag_acked = true` so we don't
    // loop on it.
    if (!state.launch_force_host_gpu and !state.launch_diag_acked) {
        if (runPreLaunchDiagnostics(alloc, frame.io, exe_storage)) |diag| {
            defer alloc.free(diag.summary);
            defer alloc.free(diag.log);
            stashLaunchDiag(state, game.f95_thread_id, diag);
            return;
        }
    }
    // Reset the acked flag once a launch attempt actually proceeds —
    // a future stale diagnosis on the next launch should re-open the
    // popup, not silently skip it.
    state.launch_diag_acked = false;

    // If the user opted into the host-GPU fix, fold the host GPU dirs
    // into LD_LIBRARY_PATH on top of any compat overrides.
    var launch_envs: []sandbox_mod.EnvOverride = compat_envs;
    var owns_launch_envs = false;
    defer if (owns_launch_envs) freeCompatEnv(alloc, launch_envs);
    if (state.launch_force_host_gpu) {
        if (composeHostGpuEnv(frame, compat_envs)) |merged| {
            launch_envs = merged;
            owns_launch_envs = true;
        } else |e| {
            log.warn("composeHostGpuEnv failed: {s}", .{@errorName(e)});
        }
    }
    const bind_extra: []const []const u8 = compatBindExtra(frame, compat_envs) catch &.{};
    defer freeCompatBindExtra(frame.lib.alloc, bind_extra);

    // ---- 4. SandboxConfig + launch ----
    // `want_sandbox` chose the route back in step 2. The sandboxed
    // path uses `frame.sandbox` (bwrap on Linux, sandboxie on Windows,
    // fallback NoSandbox elsewhere); the host path uses the always-
    // available `frame.host_launcher` with an empty `sandbox_home`
    // so the game sees the real `$HOME`.
    const cfg = sandbox_mod.SandboxConfig{
        .network = net,
        .bind_extra = bind_extra,
        .sandbox_home = sandbox_home,
        .install_path = install_path,
        .executable = exe_storage,
        .launch_args = custom_args,
        .host = frame.info.host,
        .env_extra = launch_envs,
    };
    const backend_name: []const u8 = if (want_sandbox) frame.sandbox.backendName() else "host";
    const result = (if (want_sandbox)
        frame.sandbox.launch(alloc, cfg)
    else
        frame.host_launcher.launch(alloc, cfg)) catch |e| {
        // Sandbox backends stash the detail string for the most
        // recent failure. Surface it verbatim — `LaunchFailed` alone
        // is not informative ("permission denied"/"file not found"/
        // "argv too long" all collapse to the same enum value).
        const detail = if (want_sandbox) frame.sandbox.lastError() else frame.host_launcher.lastError();
        const hint = launchFailureHint(detail, backend_name);
        var buf: [512]u8 = undefined;
        const msg = if (hint.len > 0 and detail.len > 0)
            std.fmt.bufPrint(&buf, "Launch failed (backend={s}): {s}\n{s}", .{ backend_name, detail, hint }) catch "Launch failed"
        else if (detail.len > 0)
            std.fmt.bufPrint(&buf, "Launch failed (backend={s}): {s}", .{ backend_name, detail }) catch "Launch failed"
        else
            std.fmt.bufPrint(&buf, "Launch failed: {s} (backend={s})", .{ @errorName(e), backend_name }) catch "Launch failed";
        state.notifyErr(msg);
        return;
    };

    if (result.pid > 0) {
        // POSIX realtime clock; on Windows result.pid is always 0 (launch is M2) so this
        // block never runs — keep it comptime-clean there.
        const now_s: i64 = if (builtin.os.tag == .windows) 0 else blk: {
            var _now_ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &_now_ts);
            break :blk _now_ts.sec;
        };

        // One install lookup, reused for both install_id and version.
        // `version_owned` stays null when we have nothing to dupe — that's
        // the unambiguous "no version" sentinel; non-null is always a heap
        // allocation owned by lib.alloc.
        var install_id_opt: ?[36]u8 = null;
        var version_owned: ?[]u8 = null;
        if (frame.lib.latestInstallForGame(game.f95_thread_id) catch null) |inst| {
            defer frame.lib.freeInstall(inst);
            var id: [36]u8 = undefined;
            @memcpy(&id, &inst.id);
            install_id_opt = id;
            if (inst.version.len > 0) {
                version_owned = frame.lib.alloc.dupe(u8, inst.version) catch null;
            }
        } else if (game.latest_version) |lv| {
            if (lv.len > 0) {
                version_owned = frame.lib.alloc.dupe(u8, lv) catch null;
            }
        }

        const sid = frame.lib.insertSession(.{
            .game_thread_id = game.f95_thread_id,
            .install_id = install_id_opt,
            .version = version_owned orelse "",
            .started_at = now_s,
        }) catch -1;

        // Ownership of version_owned transfers to the map entry.
        // It will be freed in drainRunningGames after reap (or in
        // shutdown cleanup — see Task 9).
        if (runningGamesMap(frame)) |rm| {
            rm.put(game.f95_thread_id, .{
                .pid = result.pid,
                .session_id = sid,
                .started_at = now_s,
                .version = version_owned,
            }) catch {
                // put() failed — we still own version_owned. Free it
                // and accept that this launch isn't tracked in-memory
                // (the DB row was already inserted; it stays open and
                // gets the "incomplete" treatment).
                if (version_owned) |v| frame.lib.alloc.free(v);
            };
        } else {
            if (version_owned) |v| frame.lib.alloc.free(v);
        }
    }
    // Early-failure detection now flows through `drainRunningGames` →
    // `notifyOnAbnormalExit` which opens the launch diag dialog on a
    // non-zero exit. The dedicated `LaunchWatchJob` was redundant —
    // drainRunningGames runs every frame and almost always reaps the
    // child before a 150ms-poll worker thread could.
    var ok_buf: [128]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Launched (pid {d}, {s})", .{
        result.pid,
        backend_name,
    }) catch "Launched";
    state.setLaunchMsg(ok_msg);
}

// ============================================================
//  compat env composition for launch
// ============================================================

/// Read the install's applied compat fixes, replay each recipe's
/// `env_prepend`/`env_set` actions, pre-merge prepend values with the
/// host environ, and return a freshly allocated []EnvOverride for the
/// sandbox. Caller frees via `freeCompatEnv`.
// ============================================================
//  pre-launch dependency check + host-GPU env fallback
// ============================================================

pub const MissingLibsResult = struct {
    /// `, `-separated list of missing lib names (e.g.
    /// `"libGL.so.1, libGLEW.so.2.1"`). Empty when nothing is missing.
    /// Owned by the same allocator that was passed to `findMissingLibs`.
    combined: []u8,
};

/// Run `ldd <exe>` against the resolved launcher and report any
/// `=> not found` lines. NixOS hosts of Ren'Py / Unity / godot games
/// commonly hit this for `libGL.so.1` because the bundled binary
/// links against libglvnd but no `LD_LIBRARY_PATH` points at
/// `/run/opengl-driver/lib`.
///
/// `ldd` failures are non-fatal — we return an empty result so the
/// launch proceeds. Worst case the user sees the upstream
/// `error while loading shared libraries` in the toast bar and we
/// fall back to the existing failure path.
pub fn findMissingLibs(alloc: std.mem.Allocator, io: std.Io, exe_path: []const u8) MissingLibsResult {
    const result = std.process.run(alloc, io, .{
        .argv = &.{ "ldd", exe_path },
    }) catch {
        return .{ .combined = alloc.dupe(u8, "") catch &.{} };
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    // Each `ldd` line that includes "=> not found" indicates an
    // unresolved dep. The lib name is the first whitespace-separated
    // token. Dedupe + comma-join.
    var out: std.ArrayList(u8) = .empty;
    var seen_any = false;
    var line_it = std.mem.tokenizeAny(u8, result.stdout, "\n");
    while (line_it.next()) |line| {
        if (std.mem.indexOf(u8, line, "=> not found") == null) continue;
        const trimmed = std.mem.trim(u8, line, " \t");
        const space = std.mem.indexOfAny(u8, trimmed, " \t") orelse continue;
        const lib_name = trimmed[0..space];
        if (lib_name.len == 0) continue;
        if (seen_any) out.appendSlice(alloc, ", ") catch break;
        out.appendSlice(alloc, lib_name) catch break;
        seen_any = true;
    }
    return .{ .combined = out.toOwnedSlice(alloc) catch alloc.dupe(u8, "") catch &.{} };
}

/// Build a fresh `[]EnvOverride` that includes everything from
/// `existing` plus an LD_LIBRARY_PATH entry prepended with the host
/// GPU dir (NixOS: `/run/opengl-driver/lib`) and standard distro
/// lib dirs. If `existing` already has an LD_LIBRARY_PATH entry it's
/// merged with the GPU paths so neither override clobbers the other.
fn composeHostGpuEnv(
    frame: *Frame,
    existing: []sandbox_mod.EnvOverride,
) ![]sandbox_mod.EnvOverride {
    const alloc = frame.lib.alloc;

    // Build the GPU-prepended LD_LIBRARY_PATH value.
    //   1. `<exe_dir>/lib`        — f69's own bundled libglvnd
    //                              (libGL / libGLX / libEGL). The
    //                              system NixOS path `/run/opengl-
    //                              driver/lib` has only vendor
    //                              backends (libGLX_nvidia etc.) —
    //                              the glvnd dispatchers come from
    //                              the bundle.
    //   2. `/run/opengl-driver/lib` — NixOS GPU vendor libs
    //                                (nvidia / mesa GLX / EGL
    //                                vendor implementations).
    //   3. Standard distro lib dirs — for non-NixOS hosts.
    var exe_lib_buf: [768]u8 = undefined;
    const exe_lib_path = std.fmt.bufPrint(&exe_lib_buf, "{s}/lib", .{frame.info.exe_dir}) catch null;
    var gpu_parts_buf: [5][]const u8 = undefined;
    var gpu_parts_len: usize = 0;
    if (exe_lib_path) |p| {
        gpu_parts_buf[gpu_parts_len] = p;
        gpu_parts_len += 1;
    }
    gpu_parts_buf[gpu_parts_len] = "/run/opengl-driver/lib";
    gpu_parts_len += 1;
    gpu_parts_buf[gpu_parts_len] = "/usr/lib/x86_64-linux-gnu";
    gpu_parts_len += 1;
    gpu_parts_buf[gpu_parts_len] = "/usr/lib64";
    gpu_parts_len += 1;
    gpu_parts_buf[gpu_parts_len] = "/usr/lib";
    gpu_parts_len += 1;
    const gpu_parts = gpu_parts_buf[0..gpu_parts_len];
    // Find existing LD_LIBRARY_PATH override (if any) to merge with.
    var existing_ld: ?[]const u8 = null;
    for (existing) |e| {
        if (std.mem.eql(u8, e.name, "LD_LIBRARY_PATH")) {
            existing_ld = e.value;
            break;
        }
    }
    const host_ld = frame.host_launcher.environ.getAlloc(alloc, "LD_LIBRARY_PATH") catch null;
    defer if (host_ld) |s| alloc.free(s);

    var ld_buf: std.ArrayList(u8) = .empty;
    defer ld_buf.deinit(alloc);
    var wrote_any = false;
    for (gpu_parts) |p| {
        if (wrote_any) try ld_buf.appendSlice(alloc, ":");
        try ld_buf.appendSlice(alloc, p);
        wrote_any = true;
    }
    if (existing_ld) |s| if (s.len > 0) {
        try ld_buf.appendSlice(alloc, ":");
        try ld_buf.appendSlice(alloc, s);
    };
    if (host_ld) |s| if (s.len > 0) {
        try ld_buf.appendSlice(alloc, ":");
        try ld_buf.appendSlice(alloc, s);
    };
    const ld_value = try ld_buf.toOwnedSlice(alloc);
    errdefer alloc.free(ld_value);

    // Build the combined override list: existing entries except any
    // LD_LIBRARY_PATH (replaced by ours), plus our new one.
    var out: std.ArrayList(sandbox_mod.EnvOverride) = .empty;
    errdefer {
        for (out.items) |e| {
            alloc.free(e.name);
            alloc.free(e.value);
        }
        out.deinit(alloc);
    }
    for (existing) |e| {
        if (std.mem.eql(u8, e.name, "LD_LIBRARY_PATH")) continue;
        try out.append(alloc, .{
            .name = try alloc.dupe(u8, e.name),
            .value = try alloc.dupe(u8, e.value),
        });
    }
    try out.append(alloc, .{
        .name = try alloc.dupe(u8, "LD_LIBRARY_PATH"),
        .value = ld_value,
    });
    return out.toOwnedSlice(alloc) catch error.OutOfMemory;
}

/// Pre-launch diagnostic result. `summary` is a single-line headline
/// shown in the popup title; `log` is the supporting evidence (raw
/// `ldd` output etc.) the user can read or copy to clipboard.
/// `fix_id` chooses which "Fix issue" affordance — if any — appears.
pub const LaunchDiagnosis = struct {
    summary: []const u8,
    log: []const u8,
    fix_id: ?state_mod.LaunchFixId,
};

/// Run the static-only checks we have today. Returns `null` when
/// the launcher looks fine. The caller owns nothing — the returned
/// struct's strings are stashed verbatim into `State` (which has
/// fixed-size buffers) by `stashLaunchDiag` and dropped after.
pub fn runPreLaunchDiagnostics(
    alloc: std.mem.Allocator,
    io: std.Io,
    exe_path: []const u8,
) ?LaunchDiagnosis {
    // Check 1: ldd unresolved libs.
    var ldd_out_buf: std.ArrayList(u8) = .empty;
    defer ldd_out_buf.deinit(alloc);
    const missing = findMissingLibs(alloc, io, exe_path);
    defer alloc.free(missing.combined);
    if (missing.combined.len > 0) {
        // Re-run ldd and stash full output as the diagnostic log so
        // the user gets the complete picture, not just the lib list.
        const full_ldd = captureLddOutput(alloc, io, exe_path) catch alloc.dupe(u8, "") catch &.{};

        var summary_buf: [256]u8 = undefined;
        const summary_txt = std.fmt.bufPrint(
            &summary_buf,
            "Missing shared libraries: {s}",
            .{missing.combined},
        ) catch missing.combined;

        // Heuristic: any GL-related lib → host_gpu_paths fix.
        const looks_like_gl =
            std.mem.indexOf(u8, missing.combined, "libGL.") != null or
            std.mem.indexOf(u8, missing.combined, "libGLX") != null or
            std.mem.indexOf(u8, missing.combined, "libEGL") != null or
            std.mem.indexOf(u8, missing.combined, "libGLEW") != null;

        return .{
            .summary = alloc.dupe(u8, summary_txt) catch alloc.dupe(u8, "") catch &.{},
            .log = full_ldd,
            .fix_id = if (looks_like_gl) .host_gpu_paths else null,
        };
    }
    return null;
}

/// Best-effort capture of full `ldd` stdout — used as the log body in
/// the diagnostic popup. Identical spawn pattern to `findMissingLibs`,
/// but returns the whole output instead of just the unresolved
/// lib names. Caller frees.
fn captureLddOutput(alloc: std.mem.Allocator, io: std.Io, exe_path: []const u8) ![]u8 {
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ "ldd", exe_path },
    });
    defer alloc.free(result.stderr);
    return result.stdout; // caller owns
}

pub const stashLaunchDiagPub = stashLaunchDiag;

/// Copy a diagnosis into State (fixed-size buffers) and open the
/// popup. Frees the input strings.
fn stashLaunchDiag(state: *State, thread_id: u64, diag: LaunchDiagnosis) void {
    {
        const n = @min(diag.summary.len, state.launch_diag_summary_buf.len);
        @memcpy(state.launch_diag_summary_buf[0..n], diag.summary[0..n]);
        state.launch_diag_summary_len = n;
    }
    {
        const n = @min(diag.log.len, state.launch_diag_log_buf.len);
        @memcpy(state.launch_diag_log_buf[0..n], diag.log[0..n]);
        state.launch_diag_log_len = n;
    }
    state.launch_diag_fix_id = diag.fix_id;
    state.launch_diag_thread_id = thread_id;
    state.launch_diag_open = true;
    state.launch_diag_acked = false;
    state.launch_diag_fix_applied = false;
}

pub fn clearLaunchDiag(state: *State) void {
    state.launch_diag_open = false;
    state.launch_diag_summary_len = 0;
    state.launch_diag_log_len = 0;
    state.launch_diag_fix_id = null;
}

// ============================================================
//  Post-launch watcher
// ============================================================

/// Detached thread spawned after a successful host launch. Polls
/// `waitpid(pid, WNOHANG)` in `poll_ms` increments for up to `watch_ms`.
/// If the child exits with a non-zero code inside the window we mark
/// `early_fail = true` and let `drainLaunchWatcher` surface the
/// diagnostic dialog. Past the window we assume the launch is fine
/// and the watcher exits silently.
fn launchWatchWorker(job: *owned_types.LaunchWatchJob) void {
    const p = &job.payload;
    const linux = std.os.linux;
    const tick = std.Io.Duration.fromMilliseconds(p.poll_ms);
    var elapsed: u32 = 0;
    while (elapsed < p.watch_ms) : (elapsed += p.poll_ms) {
        if (job.cancelRequested()) break;
        var status: u32 = 0;
        const ret = linux.waitpid(p.pid, &status, linux.W.NOHANG);
        if (ret > 0) {
            // Decode the waitpid status: WIFEXITED gives the actual
            // exit code; otherwise a signal terminated the child and
            // we surface the signal number as a high-order code.
            const exited = (status & 0x7F) == 0;
            const code: i32 = if (exited)
                @as(i32, @intCast((status >> 8) & 0xFF))
            else
                -@as(i32, @intCast(status & 0x7F));
            p.exit_code = code;
            if (code != 0) {
                p.early_fail = true;
                const txt = std.fmt.bufPrint(
                    &p.summary_buf,
                    "Game exited with code {d} after {d} ms — likely a launch failure",
                    .{ code, elapsed },
                ) catch "Game exited shortly after launch.";
                p.summary_len = txt.len;
            }
            job.markDone();
            return;
        }
        std.Io.sleep(p.io, tick, .awake) catch break;
    }
    job.markDone();
}

fn onLaunchWatchDone(state: *State, job: *owned_types.LaunchWatchJob) void {
    const p = &job.payload;
    if (p.early_fail) {
        // Build a synthetic LaunchDiagnosis from the watcher payload
        // and stash via the same path the pre-launch dialog uses.
        // No stderr capture in v1 — the log body explains what we
        // know, and OK / Copy lets the user paste it elsewhere.
        const summary = p.summary_buf[0..p.summary_len];
        var log_buf: [512]u8 = undefined;
        const log_txt = std.fmt.bufPrint(
            &log_buf,
            "Launch attempt exited with code {d}.\n" ++
                "f69 isn't capturing the game's stderr yet, so the actual error message went to the terminal you launched f69 from.\n\n" ++
                "Common causes:\n" ++
                "  • Missing shared library (libGL / libGLEW / libdecor / …) — try the host GPU paths fix below\n" ++
                "  • Missing executable permissions on inner binaries\n" ++
                "  • Wrong launcher picked (try a different install in the dropdown)",
            .{p.exit_code},
        ) catch "Launch attempt exited early.";

        // We don't have an ldd-detected fix here, but offering the
        // host-GPU retry is a reasonable default first guess given
        // how common that failure mode is on NixOS.
        const diag: LaunchDiagnosis = .{
            .summary = summary,
            .log = log_txt,
            .fix_id = .host_gpu_paths,
        };
        stashLaunchDiag(state, p.thread_id, diag);
    }
}

fn onLaunchWatchFailed(state: *State, job: *owned_types.LaunchWatchJob) void {
    _ = state;
    _ = job;
}

pub fn drainLaunchWatcher(frame: *Frame) void {
    job_mod.drainBackgroundJob(
        owned_types.LaunchWatchPayload,
        onLaunchWatchDone,
        onLaunchWatchFailed,
        frame.state,
        &frame.state.launch_watch_job,
    );
}

/// Fire off the watcher after a successful spawn. No-op if a watcher
/// is already in flight for a previous launch — they're independent.
fn spawnLaunchWatcher(frame: *Frame, pid: i32, thread_id: u64) void {
    if (frame.state.launch_watch_job != null) return;
    if (pid <= 0) return;
    _ = job_mod.spawnJob(
        owned_types.LaunchWatchPayload,
        launchWatchWorker,
        frame.lib.alloc,
        frame.win,
        .{
            .pid = pid,
            .thread_id = thread_id,
            .io = frame.io,
        },
        &frame.state.launch_watch_job,
    ) catch |e| {
        log.warn("spawnLaunchWatcher: spawn failed: {s}", .{@errorName(e)});
    };
}

fn composeCompatEnv(frame: *Frame, install_id_ptr: *const [36]u8) ![]sandbox_mod.EnvOverride {
    const alloc = frame.lib.alloc;
    const install_id: []const u8 = install_id_ptr[0..];

    const applied = try frame.lib.listAppliedCompat(install_id);
    defer frame.lib.freeAppliedCompatList(applied);
    if (applied.len == 0) return &.{};

    // Collect recipe ids that point at recipes the repo still knows
    // about. Stale rows (recipe removed) are just skipped here; the
    // launch path doesn't take that as failure.
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(alloc);
    for (applied) |row| {
        ids.append(alloc, row.recipe_id) catch return error.OutOfMemory;
    }

    var outcome = try frame.compat_svc.composeEnv(ids.items);
    defer outcome.deinit();
    if (outcome.env_pairs.items.len == 0) return &.{};

    var overrides: std.ArrayList(sandbox_mod.EnvOverride) = .empty;
    errdefer freeOverridesList(alloc, &overrides);
    // Host environ getter — the frame doesn't carry an environ
    // reference, but the host_launcher does. We pull from there.
    //
    // For LD_LIBRARY_PATH specifically we ALSO pre-pend the GPU
    // driver dir (NixOS: /run/opengl-driver/lib). Without it,
    // libglvnd-based libGL.so.1 in our bundle can't find the
    // vendor implementation (libGLX_nvidia / libGLX_mesa) and
    // silently falls back to software rendering — a big perf hit
    // for anything that uses OpenGL.
    const gpu_driver_lib: ?[]const u8 = detectGpuDriverLib(frame);
    for (outcome.env_pairs.items) |p| {
        const name_owned = alloc.dupe(u8, p.name) catch return error.OutOfMemory;
        errdefer alloc.free(name_owned);
        const is_ld_path = std.mem.eql(u8, p.name, "LD_LIBRARY_PATH");
        const value_owned: []const u8 = if (p.prepend) blk: {
            const existing = frame.host_launcher.environ.getAlloc(alloc, p.name) catch null;
            defer if (existing) |e| alloc.free(e);
            // Format: <recipe value><sep><gpu driver><sep><existing>
            // Each part skipped when empty. Driver injection only
            // happens for LD_LIBRARY_PATH.
            const gpu_part: []const u8 = if (is_ld_path) (gpu_driver_lib orelse "") else "";
            const exist_str: []const u8 = if (existing) |e| e else "";
            const parts = [_][]const u8{ p.value, gpu_part, exist_str };
            const sep = p.sep;
            // Pre-compute total length + accumulate joining non-empty parts.
            var nonempty_count: usize = 0;
            var total: usize = 0;
            for (parts) |part| if (part.len > 0) {
                if (nonempty_count > 0) total += sep.len;
                total += part.len;
                nonempty_count += 1;
            };
            if (total == 0) break :blk alloc.dupe(u8, "") catch return error.OutOfMemory;
            const out = alloc.alloc(u8, total) catch return error.OutOfMemory;
            var idx: usize = 0;
            var written: usize = 0;
            for (parts) |part| if (part.len > 0) {
                if (written > 0) {
                    @memcpy(out[idx .. idx + sep.len], sep);
                    idx += sep.len;
                }
                @memcpy(out[idx .. idx + part.len], part);
                idx += part.len;
                written += 1;
            };
            break :blk out;
        } else alloc.dupe(u8, p.value) catch return error.OutOfMemory;
        errdefer alloc.free(value_owned);
        log.info("compat: env override {s} (len {d})", .{ name_owned, value_owned.len });
        overrides.append(alloc, .{
            .name = name_owned,
            .value = value_owned,
        }) catch return error.OutOfMemory;
    }

    // GLX vendor hint — only when the env hasn't already set it and
    // we can confidently pick from /dev. This lives outside the
    // recipe because it depends on the host's GPU layout, not on
    // any specific recipe.
    if (detectGlxVendor(frame)) |vendor| blk: {
        const existing = frame.host_launcher.environ.getAlloc(alloc, "__GLX_VENDOR_LIBRARY_NAME") catch null;
        defer if (existing) |e| alloc.free(e);
        if (existing != null and existing.?.len > 0) break :blk;
        const name = alloc.dupe(u8, "__GLX_VENDOR_LIBRARY_NAME") catch return error.OutOfMemory;
        errdefer alloc.free(name);
        const value = alloc.dupe(u8, vendor) catch return error.OutOfMemory;
        errdefer alloc.free(value);
        log.info("compat: GLX vendor hint -> {s}", .{vendor});
        overrides.append(alloc, .{ .name = name, .value = value }) catch return error.OutOfMemory;
    }

    return overrides.toOwnedSlice(alloc) catch error.OutOfMemory;
}

/// Return the absolute path of the host's GPU-driver lib dir if one
/// looks plausible. Currently only handles NixOS's
/// `/run/opengl-driver/lib`; other distros' libGL lives in the
/// standard loader path and needs no injection.
fn detectGpuDriverLib(frame: *Frame) ?[]const u8 {
    const candidate = "/run/opengl-driver/lib";
    std.Io.Dir.cwd().access(frame.io, candidate, .{}) catch return null;
    return candidate;
}

/// libglvnd asks the X server "which GLX vendor for this screen?"
/// On XWayland + NVIDIA the answer is sometimes wrong (XWayland
/// advertises Mesa) so libglvnd loads libGLX_mesa and Mesa falls
/// back to llvmpipe (software). Overriding via
/// `__GLX_VENDOR_LIBRARY_NAME` skips that probe and forces the
/// vendor we want. Detection is best-effort:
///   - `/dev/nvidia0` present  → nvidia
///   - else `/dev/dri/card*`   → mesa
///   - else                    → null (let libglvnd decide)
fn detectGlxVendor(frame: *Frame) ?[]const u8 {
    std.Io.Dir.cwd().access(frame.io, "/dev/nvidia0", .{}) catch {
        std.Io.Dir.cwd().access(frame.io, "/dev/dri", .{}) catch return null;
        return "mesa";
    };
    return "nvidia";
}

fn freeCompatEnv(alloc: std.mem.Allocator, env: []sandbox_mod.EnvOverride) void {
    for (env) |o| {
        alloc.free(o.name);
        alloc.free(o.value);
    }
    if (env.len > 0) alloc.free(env);
}

/// Build a `bind_extra` slice that exposes the compat resource dir
/// inside the bwrap sandbox. Without this, env vars pointing at
/// `<data_root>/compat-resources/...` resolve to a path that doesn't
/// exist inside the sandbox's filesystem namespace. No-op when there
/// are no compat overrides to support. Caller frees via
/// `freeCompatBindExtra`.
///
/// Also includes `/run/opengl-driver` (NixOS) when present so the
/// bundled libGL dispatcher can find the vendor implementation.
fn compatBindExtra(frame: *Frame, env_extra: []const sandbox_mod.EnvOverride) ![]const []const u8 {
    if (env_extra.len == 0) return &.{};
    const alloc = frame.lib.alloc;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| alloc.free(p);
        list.deinit(alloc);
    }
    const resources_path = try std.fmt.allocPrint(alloc, "{s}/compat-resources", .{frame.info.data_root});
    try list.append(alloc, resources_path);
    if (detectGpuDriverLib(frame) != null) {
        const gpu_path = try alloc.dupe(u8, "/run/opengl-driver");
        try list.append(alloc, gpu_path);
    }
    return list.toOwnedSlice(alloc) catch error.OutOfMemory;
}

fn freeCompatBindExtra(alloc: std.mem.Allocator, bind_extra: []const []const u8) void {
    for (bind_extra) |p| alloc.free(p);
    if (bind_extra.len > 0) alloc.free(bind_extra);
}

fn freeOverridesList(alloc: std.mem.Allocator, list: *std.ArrayList(sandbox_mod.EnvOverride)) void {
    for (list.items) |o| {
        alloc.free(o.name);
        alloc.free(o.value);
    }
    list.deinit(alloc);
}

// ============================================================
//  compat issue surface — scan + apply + undo helpers
// ============================================================
//
// Callable from any UI button. The result of `scanCompatForInstall`
// is owned by the caller and freed via the matching free helper.
// `applyCompatFix` and `undoCompatFix` persist their changes to the
// library DB so subsequent launches consult the updated state.

/// Scan an install's tree against every loaded compat recipe.
/// Returned slice is owned by the caller; free with
/// `freeCompatIssues`. Status field reflects whether a FixRecord for
/// the recipe is already present in the library for this install.
pub fn scanCompatForInstall(
    frame: *Frame,
    install_id: *const [36]u8,
    install_root: []const u8,
) ![]compat_mod.Issue {
    const id_slice: []const u8 = install_id[0..];
    const applied = try frame.lib.listAppliedCompat(id_slice);
    defer frame.lib.freeAppliedCompatList(applied);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(frame.lib.alloc);
    for (applied) |row| ids.append(frame.lib.alloc, row.recipe_id) catch return error.OutOfMemory;
    return frame.compat_svc.scan(install_root, ids.items);
}

pub fn freeCompatIssues(frame: *Frame, issues: []compat_mod.Issue) void {
    frame.compat_svc.freeIssues(issues);
}

/// Apply one fix and persist the FixRecord. Errors propagate from
/// the service (resource missing, snapshot failure, etc.). Caller is
/// responsible for surfacing the error message in the UI.
/// Convenience wrapper for the launch-diag Fix button. Looks up the
/// install row for `thread_id` to recover `install_path`, then calls
/// `applyCompatFix`. Returns `error.InstallNotFound` when the game
/// has no installs (rare — the diag wouldn't have been raised in
/// that case).
pub fn applyCompatFixForGame(
    frame: *Frame,
    thread_id: u64,
    install_id: *const [36]u8,
    recipe_id: []const u8,
) !void {
    const inst = (frame.lib.latestInstallForGame(thread_id) catch null) orelse return error.InstallNotFound;
    defer frame.lib.freeInstall(inst);
    try applyCompatFix(frame, install_id, inst.install_path, recipe_id);
}

/// Result of `autoApplyCompatAfterConvert`. `applied` counts both
/// fresh applications and sha-mismatch re-applications. `failed` is
/// best-effort — individual recipe failures are logged but never
/// surface as a hard error to the Convert path; we'd rather complete
/// the Convert with partial compat than abort.
pub const AutoApplyCompatResult = struct {
    applied: u32 = 0,
    reapplied: u32 = 0,
    failed: u32 = 0,
};

/// After a successful Convert, scan the install against every compat
/// recipe and apply each that is .unfixed. Also re-apply any .fixed
/// recipe whose bundled sha has changed since the original apply —
/// this covers the case where f69 ships a recipe upgrade and the
/// user's install still has the old fix recorded.
///
/// Gated by `state.auto_apply_compat`. Caller should consult that
/// before invoking. Returns counts for status reporting.
pub fn autoApplyCompatAfterConvert(
    frame: *Frame,
    install_id: *const [36]u8,
    install_root: []const u8,
) AutoApplyCompatResult {
    var res = AutoApplyCompatResult{};

    const id_slice: []const u8 = install_id[0..];
    const applied = frame.lib.listAppliedCompat(id_slice) catch |e| {
        log.warn("auto-apply-compat: list applied failed: {s}", .{@errorName(e)});
        return res;
    };
    defer frame.lib.freeAppliedCompatList(applied);

    var applied_ids: std.ArrayList([]const u8) = .empty;
    defer applied_ids.deinit(frame.lib.alloc);
    for (applied) |row| {
        applied_ids.append(frame.lib.alloc, row.recipe_id) catch return res;
    }

    const issues = frame.compat_svc.scan(install_root, applied_ids.items) catch |e| {
        log.warn("auto-apply-compat: scan failed: {s}", .{@errorName(e)});
        return res;
    };
    defer frame.compat_svc.freeIssues(issues);

    for (issues) |is| {
        // Decide whether to apply: .unfixed → yes. .fixed → only when
        // the bundled recipe's sha has moved on (recipe was upgraded
        // since the install was originally fixed).
        var needs_reapply = false;
        if (is.status == .fixed) {
            const entry = frame.compat_svc.repo.byId(is.recipe_id) orelse continue;
            for (applied) |row| {
                if (!std.mem.eql(u8, row.recipe_id, is.recipe_id)) continue;
                if (!std.mem.eql(u8, row.recipe_sha256, entry.source_sha256)) {
                    needs_reapply = true;
                    log.info("auto-apply-compat: {s} sha drifted ({s} → {s}) — re-applying", .{
                        is.recipe_id, row.recipe_sha256[0..@min(8, row.recipe_sha256.len)], entry.source_sha256[0..@min(8, entry.source_sha256.len)],
                    });
                }
                break;
            }
        }
        if (is.status != .unfixed and !needs_reapply) continue;

        // If we're re-applying due to sha drift, undo the old fix
        // first so its backups get restored and the row's slate is
        // clean before the new apply writes a fresh row.
        if (needs_reapply) {
            undoCompatFix(frame, install_id, install_root, is.recipe_id) catch |e| {
                log.warn("auto-apply-compat: stale-sha undo of {s} failed: {s}", .{ is.recipe_id, @errorName(e) });
                res.failed += 1;
                continue;
            };
        }

        applyCompatFix(frame, install_id, install_root, is.recipe_id) catch |e| {
            log.warn("auto-apply-compat: {s} failed: {s}", .{ is.recipe_id, @errorName(e) });
            res.failed += 1;
            continue;
        };
        if (needs_reapply) res.reapplied += 1 else res.applied += 1;
        log.info("auto-apply-compat: applied {s}", .{is.recipe_id});
    }

    return res;
}

pub fn applyCompatFix(
    frame: *Frame,
    install_id: *const [36]u8,
    install_root: []const u8,
    recipe_id: []const u8,
) !void {
    const alloc = frame.lib.alloc;
    const entry = frame.compat_svc.repo.byId(recipe_id) orelse return error.RecipeNotFound;
    const id_slice: []const u8 = install_id[0..];
    const fix = try frame.compat_svc.apply(id_slice, install_root, entry);
    defer {
        alloc.free(fix.recipe_id);
        alloc.free(fix.recipe_sha256);
        for (fix.backups) |b| frame.compat_svc.backups.freeRecord(b);
        if (fix.backups.len > 0) alloc.free(fix.backups);
    }
    const backups_json = try compat_mod.serializeBackups(alloc, fix.backups);
    defer alloc.free(backups_json);
    try frame.lib.upsertAppliedCompat(id_slice, fix.recipe_id, fix.recipe_sha256, fix.applied_at, backups_json);
}

/// Reverse an applied fix and remove its row from the DB. Errors
/// propagate from restore. A failed restore leaves the FixRecord
/// row in place so the user can retry.
pub fn undoCompatFix(
    frame: *Frame,
    install_id: *const [36]u8,
    install_root: []const u8,
    recipe_id: []const u8,
) !void {
    const id_slice: []const u8 = install_id[0..];
    const applied = try frame.lib.listAppliedCompat(id_slice);
    defer frame.lib.freeAppliedCompatList(applied);
    var match_idx: ?usize = null;
    for (applied, 0..) |row, i| if (std.mem.eql(u8, row.recipe_id, recipe_id)) {
        match_idx = i;
        break;
    };
    const row = applied[match_idx orelse return error.NotApplied];
    const backups = try compat_mod.deserializeBackups(frame.lib.alloc, row.backups_json);
    defer {
        for (backups) |b| {
            frame.lib.alloc.free(b.sha256);
            frame.lib.alloc.free(b.relpath);
            if (b.symlink_target) |t| frame.lib.alloc.free(t);
        }
        if (backups.len > 0) frame.lib.alloc.free(backups);
    }
    const fix_record = compat_mod.FixRecord{
        .recipe_id = row.recipe_id,
        .recipe_sha256 = row.recipe_sha256,
        .applied_at = row.applied_at,
        .backups = backups,
    };
    try frame.compat_svc.undo(id_slice, install_root, fix_record);
    try frame.lib.deleteAppliedCompat(id_slice, recipe_id);
}

/// Pick a one-line "what to try next" hint for the most common launch
/// failures, by sniffing the backend's error detail string. Empty
/// return = no known suggestion; the verbatim error is then on its
/// own. Patterns are conservative — better to stay silent than guess
/// wrong and send the user chasing the wrong fix.
fn launchFailureHint(detail: []const u8, backend: []const u8) []const u8 {
    if (detail.len == 0) return "";
    // bwrap-specific failures we see often on NixOS / hardened kernels.
    if (std.mem.eql(u8, backend, "bwrap")) {
        if (std.mem.indexOf(u8, detail, "user namespaces") != null or
            std.mem.indexOf(u8, detail, "unshare") != null or
            std.mem.indexOf(u8, detail, "EPERM") != null)
        {
            return "Tip: kernel.unprivileged_userns_clone may be off. Enable user namespaces (sysctl -w kernel.unprivileged_userns_clone=1) or turn sandbox off for this game.";
        }
        if (std.mem.indexOf(u8, detail, "not found") != null) {
            return "Tip: bwrap binary missing. Install it (NixOS: `nix profile add nixpkgs#bubblewrap`) or set Sandbox=Never for this game.";
        }
    }
    // Anywhere: a permission-denied on the executable means the install
    // dropped the +x bit. `chmod_x` recipe steps may have been skipped.
    if (std.mem.indexOf(u8, detail, "Permission denied") != null or
        std.mem.indexOf(u8, detail, "EACCES") != null)
    {
        return "Tip: executable missing the +x bit. `chmod +x` the launcher, or re-run Convert to redo the install's chmod step.";
    }
    if (std.mem.indexOf(u8, detail, "No such file") != null or
        std.mem.indexOf(u8, detail, "ENOENT") != null)
    {
        return "Tip: launcher path no longer exists. The install dir may have moved or been emptied — re-download / re-import.";
    }
    return "";
}

/// Resolve the effective sandbox decision for `game`. Per-game
/// `SandboxOverride` (`.always` / `.never`) wins; `.use_default`
/// consults `state.sandbox_default` (the global toggle in Settings).
pub fn shouldSandbox(state: *const State, game: *const library.Game) bool {
    return switch (game.sandbox) {
        .always => true,
        .never => false,
        .use_default => state.sandbox_default,
    };
}

/// Resolve the effective auto-update decision for `game`. A version pin
/// wins over everything — a pinned game is held on its version and never
/// auto-updated (the user clears the pin to resume tracking). Otherwise:
/// `.always` / `.never` wins; `.use_default` falls back to the global.
pub fn shouldAutoUpdate(state: *const State, game: *const library.Game) bool {
    if (game.pinned_version != null) return false;
    return switch (game.auto_update) {
        .always => true,
        .never => false,
        .use_default => state.auto_update_default,
    };
}

/// True iff a recipe exists for `game_id` AND it carries at least one
/// auto-fetchable source (RPDL torrent or DDL URL). Mirror entries
/// are link-lists, not auto-fetchable. Hits disk via the recipe
/// repo — keep call sites gated on a cheap pre-check (e.g. only
/// inside the recap-push branch, where version bumps are rare).
pub fn hasAutoFetchableSource(frame: *Frame, game_id: u64) bool {
    const parsed_opt = frame.recipe_repo.findGameByThread(game_id) catch return false;
    var parsed = parsed_opt orelse return false;
    defer parsed.deinit();
    for (parsed.recipe.sources) |s| switch (s) {
        .rpdl, .ddl => return true,
        .mirror => continue,
    };
    return false;
}

/// Auto-update readiness for a single game. Bundles two disk-hitting
/// checks into one recipe lookup:
///   1. Recipe has at least one auto-fetchable source (RPDL / DDL).
///   2. Recipe version is canonically equivalent to F95's
///      `latest_version` — i.e. the recipe knows about this build.
///      A stale recipe (still pinned to v0.20 while F95 ships v0.21)
///      would re-download the same old archive and label it the new
///      version; skip those silently and let the recipe-repo catch
///      up out-of-band.
/// Returns `true` only when both checks pass. Used as the auto-update
/// gate inside `drainSync`.
pub fn recipeReadyForAutoUpdate(frame: *Frame, game_id: u64, target_version: []const u8) bool {
    const parsed_opt = frame.recipe_repo.findGameByThread(game_id) catch return false;
    var parsed = parsed_opt orelse return false;
    defer parsed.deinit();
    var has_fetchable = false;
    for (parsed.recipe.sources) |s| switch (s) {
        .rpdl, .ddl => {
            has_fetchable = true;
            break;
        },
        .mirror => continue,
    };
    if (!has_fetchable) return false;
    return version_mod.equivalent(parsed.recipe.version, target_version);
}

/// Open the manual-install panel pre-filled with `latest_version` so
/// the user can point at a new archive to satisfy the update. No-op
/// on the version pre-fill when the buffer is already non-empty —
/// don't clobber whatever the user typed.
/// Look up a recipe-recorded version by SHA-256 of the user-picked
/// archive. Used by the manual-install panel to pre-fill the
/// Version field when the local recipe set happens to know this
/// file. Sync hash compute — capped at 500 MB so the UI thread
/// doesn't freeze on multi-GB game archives (the filename heuristic
/// covers larger files).
///
/// Returns the matching `recipe.version`, allocator-owned by
/// `frame.lib.alloc`, or null when:
///   - file > size cap
///   - file unreadable
///   - no recipe source's sha256 matches
const HASH_LOOKUP_MAX_BYTES: u64 = 500 * 1024 * 1024;

pub fn lookupVersionFromArchiveSha(frame: *Frame, file_path: []const u8) ?[]u8 {
    var f = std.Io.Dir.cwd().openFile(frame.io, file_path, .{ .mode = .read_only }) catch return null;
    defer f.close(frame.io);
    const st = f.stat(frame.io) catch return null;
    if (st.size > HASH_LOOKUP_MAX_BYTES) return null;

    var rd_buf: [64 * 1024]u8 = undefined;
    var fr = f.reader(frame.io, &rd_buf);
    var hasher = downloads.Hasher.init();
    while (true) {
        var chunk: [64 * 1024]u8 = undefined;
        const got = fr.interface.readSliceShort(&chunk) catch return null;
        if (got == 0) break;
        hasher.update(chunk[0..got]);
    }
    const sha_bytes = hasher.finalize();
    const hex = std.fmt.bytesToHex(sha_bytes, .lower);

    return frame.recipe_repo.findVersionByArchiveSha256(&hex) catch null;
}

pub fn openManualInstallForUpdate(state: *State, latest_version: []const u8) void {
    state.manual_install_open = true;
    const cur = state.manualInstallVersionSlice();
    if (cur.len == 0 and latest_version.len > 0) {
        const n = @min(latest_version.len, state.manual_install_version_buf.len - 1);
        @memcpy(state.manual_install_version_buf[0..n], latest_version[0..n]);
        state.manual_install_version_buf[n] = 0;
        // Placeholder, not a user choice — archive detection may override it.
        state.manual_install_version_autofilled = true;
    }
}

/// Walk `install_path` (up to a depth of 3) looking for a launchable
/// Linux file. Priority order:
///   1. `<game>.sh` at the root — Ren'Py / Linux ports universally
///      drop their launch script here.
///   2. Any `.sh` anywhere (search depth-limited).
///   3. Any `.AppImage` file.
/// Returns the path *relative to install_path* in `buf`. Null when
/// nothing matches.
pub fn findLinuxLauncher(io: std.Io, alloc: std.mem.Allocator, install_path: []const u8, buf: []u8) ?[]const u8 {
    _ = alloc;
    // Pass 1: shallow root scan first — that's where Ren'Py / native
    // Linux ports put their `.sh`. Cheap.
    var root = std.Io.Dir.cwd().openDir(io, install_path, .{ .iterate = true }) catch return null;
    defer root.close(io);

    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        // Accept `.unknown` alongside `.file` — FUSE NTFS / exFAT
        // mounts surface every readdir entry as `.unknown` (no
        // d_type). Without this, a converted `Game.sh` sitting on a
        // FUSE mount would be invisible and the user would get the
        // "Found Windows binary — click Convert first" message even
        // after convert ran successfully.
        if (entry.kind != .file and entry.kind != .unknown) continue;
        if (std.mem.endsWith(u8, entry.name, ".sh") or
            std.mem.endsWith(u8, entry.name, ".AppImage"))
        {
            return std.fmt.bufPrint(buf, "{s}", .{entry.name}) catch null;
        }
    }

    // Pass 2: one level deeper. Many extracted archives wrap the
    // game in a single subdir.
    var it2 = root.iterate();
    while (it2.next(io) catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .unknown) continue;
        var sub_path_buf: [320]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_path_buf, "{s}/{s}", .{ install_path, entry.name }) catch continue;
        var sub = std.Io.Dir.cwd().openDir(io, sub_path, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var sub_it = sub.iterate();
        while (sub_it.next(io) catch null) |sub_entry| {
            if (sub_entry.kind != .file and sub_entry.kind != .unknown) continue;
            if (std.mem.endsWith(u8, sub_entry.name, ".sh") or
                std.mem.endsWith(u8, sub_entry.name, ".AppImage"))
            {
                return std.fmt.bufPrint(buf, "{s}/{s}", .{ entry.name, sub_entry.name }) catch null;
            }
        }
    }
    return null;
}

/// Same shape as `findLinuxLauncher`, but for `.exe`. Used to give
/// the user an actionable "needs conversion" message instead of just
/// "nothing runnable found".
fn findWindowsExe(io: std.Io, alloc: std.mem.Allocator, install_path: []const u8, buf: []u8) ?[]const u8 {
    _ = alloc;
    var root = std.Io.Dir.cwd().openDir(io, install_path, .{ .iterate = true }) catch return null;
    defer root.close(io);
    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .unknown) continue;
        if (std.mem.endsWith(u8, entry.name, ".exe")) {
            return std.fmt.bufPrint(buf, "{s}", .{entry.name}) catch null;
        }
    }
    var it2 = root.iterate();
    while (it2.next(io) catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .unknown) continue;
        var sub_path_buf: [320]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_path_buf, "{s}/{s}", .{ install_path, entry.name }) catch continue;
        var sub = std.Io.Dir.cwd().openDir(io, sub_path, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var sub_it = sub.iterate();
        while (sub_it.next(io) catch null) |sub_entry| {
            if (sub_entry.kind != .file and sub_entry.kind != .unknown) continue;
            if (std.mem.endsWith(u8, sub_entry.name, ".exe")) {
                return std.fmt.bufPrint(buf, "{s}/{s}", .{ entry.name, sub_entry.name }) catch null;
            }
        }
    }
    return null;
}

// ============================================================
//  per-game convert — recipe + ConvertService
// ============================================================

/// Resolve the recipe for `game`, build a `convert.ConvertSpec` from
/// its `convert_linux` block, then ask the service to apply it against
/// `<library_root>/<thread_id>/` (the same placeholder install dir
/// the Launch action uses). Idempotent — re-clicking after a
/// successful convert reports "already converted".
/// True when any of `names` exists under `install_path`. Used to
/// pick engine-specific "can't convert" messages so the user knows
/// WHICH Windows-only engine they're looking at rather than just
/// "needs WINE." Stat-only, no directory walk.
fn installHasAny(io: std.Io, install_path: []const u8, names: []const []const u8) bool {
    for (names) |n| {
        var buf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ install_path, n }) catch continue;
        if (std.Io.Dir.cwd().access(io, full, .{})) return true else |_| {}
    }
    return false;
}

/// Resolve the bundled mkxp-z directory. Two install layouts are
/// supported:
///   - Portable: `<exe_dir>/data/mkxp-z/`            (zig-out/bin layout)
///   - FHS:      `<exe_dir>/../share/f69/data/mkxp-z/` (rpm/deb layout)
/// The FHS path is checked first so a /usr/bin install picks up
/// /usr/share/f69/... without falling back to a stale portable tree.
/// Returns the dir slice (written into `buf`) when the binary inside
/// it exists, null otherwise.
fn mkxpZBundled(frame: *Frame, exe_dir: []const u8, buf: []u8) ?[]const u8 {
    // FHS path first — /usr/bin/f69 → /usr/share/f69/data/mkxp-z/.
    if (std.fmt.bufPrint(buf, "{s}/../share/f69/data/mkxp-z", .{exe_dir})) |dir| {
        var bin_buf: [640]u8 = undefined;
        if (std.fmt.bufPrint(&bin_buf, "{s}/mkxp-z.x86_64", .{dir})) |bin| {
            if (std.Io.Dir.cwd().access(frame.io, bin, .{})) |_| return dir else |_| {}
        } else |_| {}
    } else |_| {}
    // Portable path — <exe_dir>/data/mkxp-z/.
    const portable = std.fmt.bufPrint(buf, "{s}/data/mkxp-z", .{exe_dir}) catch return null;
    var bin_buf: [640]u8 = undefined;
    const bin = std.fmt.bufPrint(&bin_buf, "{s}/mkxp-z.x86_64", .{portable}) catch return null;
    std.Io.Dir.cwd().access(frame.io, bin, .{}) catch return null;
    return portable;
}

/// Probe the mkxp-z FHS-libs bundle dir. Same portable-vs-FHS dual
/// check as `mkxpZBundled`. Empty (returns null) on non-NixOS builds
/// where the bundle wasn't materialised.
fn mkxpZExtraLibsDir(frame: *Frame, exe_dir: []const u8, buf: []u8) ?[]const u8 {
    if (std.fmt.bufPrint(buf, "{s}/../share/f69/data/compat-resources/mkxp-z-fhs-libs/lib", .{exe_dir})) |dir| {
        if (std.Io.Dir.cwd().access(frame.io, dir, .{})) |_| return dir else |_| {}
    } else |_| {}
    const portable = std.fmt.bufPrint(buf, "{s}/data/compat-resources/mkxp-z-fhs-libs/lib", .{exe_dir}) catch return null;
    std.Io.Dir.cwd().access(frame.io, portable, .{}) catch return null;
    return portable;
}

pub fn doConvertGame(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

    // Convert operates against whatever the *latest* install is. If
    // there's no DB row yet, fall back to the legacy placeholder dir.
    var fallback_buf: [640]u8 = undefined;
    const install_opt = frame.lib.latestInstallForGame(game.f95_thread_id) catch null;
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const raw_install_path: []const u8 = if (install_opt) |i|
        i.install_path
    else
        std.fmt.bufPrint(&fallback_buf, "{s}/{d}", .{ frame.info.library_root, game.f95_thread_id }) catch {
            state.setConvertMsg("Install path buffer overflow.");
            return;
        };

    // Peel a wrapper folder if present. F95 archives commonly ship
    // their content one level deep (`<install>/Game v1.0d/www/...`);
    // without this peel `detectEngine` looks at the shallow path,
    // finds no markers, and Convert spuriously bails as "engine not
    // supported." `resolveGameRoot` no-ops when the install dir is
    // already the real game root.
    const install_path = mods_act.resolveGameRoot(frame.io, raw_install_path, frame.lib.alloc) catch {
        state.setConvertMsg("Convert: failed to resolve game root.");
        return;
    };
    defer frame.lib.alloc.free(install_path);
    if (!std.mem.eql(u8, install_path, raw_install_path)) {
        log.info("Convert: peeled wrapper {s} → {s}", .{ raw_install_path, install_path });
    }

    // Convert spec from the preset matcher — engine-keyed dispatch
    // over the merged built-in + `<data_root>/convert-presets/` pool.
    const spec = mods_act.resolveConvertSpec(frame, install_path);
    if (spec == .none) {
        // Disambiguate "already Linux" from "Windows-only, no
        // converter exists." Look for tell-tale files to figure
        // out which side of the line the install sits on.
        var probe_buf: [512]u8 = undefined;
        const has_lin_launcher = (findLinuxLauncher(frame.io, frame.lib.alloc, install_path, &probe_buf) != null);
        const has_win_exe = (findWindowsExe(frame.io, frame.lib.alloc, install_path, &probe_buf) != null);
        // Use the convert/rpgm marker table directly so both the engine
        // detection AND the Convert dispatch share one source of truth.
        // The flat probes that used to live here missed VX Ace installs
        // whose RGSS300.dll sits in `System/` (the canonical layout when
        // a game ships unencrypted with `Game.rvproj2`).
        const rgss_variant = convert_mod.rpgm.detectRgssVariant(frame.io, install_path);
        const looks_like_vx_ace = rgss_variant == .vx_ace;
        const looks_like_vx = rgss_variant == .vx;
        const looks_like_xp = rgss_variant == .xp;

        // Vendored mkxp-z covers RGSS1/2/3 — try it for any RGSS variant.
        // On success the launcher lands in the game dir and we report
        // converted; on missing-bundle (e.g. non-Linux build of f69) we
        // fall through to the WINE message below.
        if (looks_like_vx_ace or looks_like_vx or looks_like_xp) {
            var bin_buf: [640]u8 = undefined;
            var libs_buf: [640]u8 = undefined;
            if (mkxpZBundled(frame, frame.info.exe_dir, &bin_buf)) |mkxp_dir| {
                const extra_libs = mkxpZExtraLibsDir(frame, frame.info.exe_dir, &libs_buf);
                // Per-install zoom override (file at `<install>/.mkxp-zoom`);
                // falls back to the global default the UI dropdown ships with.
                const zoom = convert_mod.rpgm.readMkxpZoom(frame.io, install_path) orelse convert_mod.rpgm.MKXP_ZOOM_DEFAULT;
                const mkxp_spec: convert_mod.ConvertSpec = .{ .mkxp_z = .{
                    .mkxp_z_dir = mkxp_dir,
                    .extra_libs_dir = extra_libs,
                    .zoom = zoom,
                } };
                // force=true: manual Convert clicks always re-write the
                // launcher even if `alreadyConverted` would otherwise
                // skip — iterating on launcher templates (FONTCONFIG_FILE
                // injection, env tweaks) is the main reason to click
                // Convert on an already-converted install.
                if (frame.convert_svc.convert(install_path, mkxp_spec, true)) |_| {
                    const compat_msg = maybeAutoApplyCompatPostConvert(frame, install_opt, install_path);
                    setConvertOk(state, "Converted via bundled mkxp-z.", compat_msg);
                    return;
                } else |e| {
                    log.warn("mkxp-z convert failed: {s}", .{@errorName(e)});
                    var ebuf: [256]u8 = undefined;
                    const m = std.fmt.bufPrint(&ebuf, "mkxp-z convert failed: {s}", .{@errorName(e)}) catch "mkxp-z convert failed";
                    state.setConvertMsg(m);
                    return;
                }
            }
        }

        const msg = if (has_lin_launcher)
            "No convert needed — a Linux launcher (.sh / .AppImage) is already in the install."
        else if (looks_like_vx_ace)
            "RPG Maker VX Ace: bundled mkxp-z is missing from this build of f69. Rebuild with the third_party/mkxp-z/ tree in place, or use WINE/Proton."
        else if (looks_like_vx)
            "RPG Maker VX: bundled mkxp-z is missing from this build of f69. Rebuild with the third_party/mkxp-z/ tree in place, or use WINE/Proton."
        else if (looks_like_xp)
            "RPG Maker XP: bundled mkxp-z is missing from this build of f69. Rebuild with the third_party/mkxp-z/ tree in place, or use WINE/Proton."
        else if (has_win_exe)
            "Can't convert: only Ren'Py and RPG Maker MV/MZ have Linux runtimes f69 can install. Other Windows-only engines need WINE or Proton."
        else
            "No convert needed: no engine detected at this install path. Check the install folder contents.";
        state.setConvertMsg(msg);
        return;
    }

    // force=true on manual Convert clicks; see comment above for the
    // mkxp-z dispatch on the same rationale (re-write launcher + any
    // sidecar configs every time, the user explicitly asked for it).
    frame.convert_svc.convert(install_path, spec, true) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Convert failed: {s}", .{@errorName(e)}) catch "Convert failed";
        state.setConvertMsg(msg);
        return;
    };

    const compat_msg = maybeAutoApplyCompatPostConvert(frame, install_opt, install_path);
    setConvertOk(state, "Converted.", compat_msg);
}

/// Run `autoApplyCompatAfterConvert` if the install has a DB id and
/// the user hasn't disabled the toggle. Returns a slice into a
/// thread-local-ish buffer suitable for embedding in a toast string.
/// Empty string when nothing fired (toggle off or no install).
const COMPAT_SUFFIX_LEN = 96;
var compat_suffix_buf: [COMPAT_SUFFIX_LEN]u8 = undefined;

fn maybeAutoApplyCompatPostConvert(
    frame: *Frame,
    install_opt: ?library.Install,
    install_path: []const u8,
) []const u8 {
    if (!frame.state.auto_apply_compat) return "";
    const install = install_opt orelse return "";

    const res = autoApplyCompatAfterConvert(frame, &install.id, install_path);
    if (res.applied == 0 and res.reapplied == 0 and res.failed == 0) return "";

    const written = std.fmt.bufPrint(
        &compat_suffix_buf,
        " Compat: {d} applied, {d} re-applied, {d} failed.",
        .{ res.applied, res.reapplied, res.failed },
    ) catch return "";
    return written;
}

fn setConvertOk(state: *State, head: []const u8, compat_tail: []const u8) void {
    var buf: [320]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{s} Try Launch.", .{ head, compat_tail }) catch {
        state.setConvertMsg("Converted. Try Launch.");
        return;
    };
    state.setConvertMsg(msg);
}

// `RunningGamesMap` aliased from `owned.zig` at the top of the file.

fn runningGamesMap(frame: *Frame) ?*RunningGamesMap {
    if (frame.state.running_games) |p| return p;
    const map_ptr = frame.lib.alloc.create(RunningGamesMap) catch return null;
    map_ptr.* = RunningGamesMap.init(frame.lib.alloc);
    frame.state.running_games = map_ptr;
    return map_ptr;
}

/// Read-only probe — screens.zig uses this to swap Launch ↔ Stop.
pub fn isGameRunning(frame: *Frame, thread_id: u64) bool {
    if (frame.state.running_games == null) return false;
    const m = runningGamesMap(frame) orelse return false;
    return m.contains(thread_id);
}

/// SIGTERM the running game for `game.f95_thread_id` and drop the
/// state entry. No-op + cleanup when the process is already dead.
pub fn doStopGame(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const m = runningGamesMap(frame) orelse {
        state.setLaunchMsg("Game is not tracked as running.");
        return;
    };
    const entry = m.get(game.f95_thread_id) orelse {
        state.setLaunchMsg("Game is not tracked as running.");
        return;
    };
    const pid = entry.pid;
    if (builtin.os.tag == .windows) {
        // Native game launch + stop is M2; nothing is tracked-running on Windows yet.
        _ = m.remove(game.f95_thread_id);
        state.setLaunchMsg("Stopping a running game isn't supported on Windows yet.");
        return;
    }
    std.posix.kill(@intCast(pid), .TERM) catch |e| switch (e) {
        error.ProcessNotFound => {
            // Already dead; just clean up state.
            _ = m.remove(game.f95_thread_id);
            state.setLaunchMsg("Game already exited.");
            return;
        },
        else => {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Stop failed: {s}", .{@errorName(e)}) catch "Stop failed";
            state.setLaunchMsg(msg);
            return;
        },
    };
    _ = m.remove(game.f95_thread_id);
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "SIGTERM sent to pid {d}", .{pid}) catch "Stopped";
    state.setLaunchMsg(msg);
}

/// Each guiFrame: prune entries whose pid has exited. Uses
/// `waitpid(pid, WNOHANG)` instead of `kill(pid, 0)` because the
/// launched game is f69's child — once it exits it becomes a
/// zombie, and `kill(zombie, 0)` returns success (zombies "exist"
/// until reaped). `waitpid(WNOHANG)` both detects the exit AND
/// reaps the zombie in a single non-blocking call.
pub fn drainRunningGames(frame: *Frame) void {
    // Reaps tracked game pids via waitpid — POSIX-only. Native game launch is M2 on Windows,
    // so nothing is ever tracked-running there; skip the whole reaper (keeps std.c.* off Windows).
    if (builtin.os.tag == .windows) return;
    if (frame.state.running_games == null) return;
    const m = runningGamesMap(frame) orelse return;

    var doomed: std.ArrayList(struct {
        tid: u64,
        status: u32,
        pid: i32,
        session_id: i64,
        started_at: i64,
        version: ?[]u8,
    }) = .empty;
    defer doomed.deinit(frame.lib.alloc);
    var it = m.iterator();
    while (it.next()) |entry| {
        const pid: std.c.pid_t = @intCast(entry.value_ptr.*.pid);
        // libc waitpid(WNOHANG) returns:
        //   >0  → child exited; we just reaped it.
        //    0  → child still running.
        //   -1  → ECHILD (not our child / already reaped). Treat as
        //         exited so the stale entry doesn't pin the UI.
        var status: c_int = 0;
        const rc = std.c.waitpid(pid, &status, std.posix.W.NOHANG);
        if (rc != 0) {
            log.info("running game pid={d} (tid={d}) exited (waitpid rc={d}, status=0x{x}) — clearing entry", .{
                pid, entry.key_ptr.*, rc, status,
            });
            doomed.append(frame.lib.alloc, .{
                .tid = entry.key_ptr.*,
                .status = @bitCast(status),
                .pid = pid,
                .session_id = entry.value_ptr.*.session_id,
                .started_at = entry.value_ptr.*.started_at,
                .version = entry.value_ptr.*.version,
            }) catch break;
        }
    }
    for (doomed.items) |d| {
        _ = m.remove(d.tid);
        // Close the session row. Early-fail mirrors the dialog rule:
        // exited cleanly with code 0 → !early_fail; anything else within
        // EARLY_FAIL_S → early_fail.
        const EARLY_FAIL_S: i64 = 5;
        var _now_ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &_now_ts);
        const now_s: i64 = _now_ts.sec;
        const duration_s: i64 = @max(0, now_s - d.started_at);
        const W = std.posix.W;
        const exited_clean: bool = W.IFEXITED(d.status) and W.EXITSTATUS(d.status) == 0;
        const early_fail: bool = !exited_clean and duration_s < EARLY_FAIL_S;

        if (d.session_id > 0) {
            frame.lib.closeSession(.{
                .session_id = d.session_id,
                .ended_at = now_s,
                .early_fail = early_fail,
                .min_session_seconds = frame.state.min_session_seconds,
            }) catch |e| log.warn("closeSession failed: {s}", .{@errorName(e)});

            // last_played_version monotonic update (only when counted).
            const counts_as_played = !early_fail and duration_s >= @as(i64, frame.state.min_session_seconds);
            if (counts_as_played) {
                if (d.version) |v| {
                    frame.lib.setLastPlayedVersionIfNewer(d.tid, v, version_mod.compare) catch |e| log.warn("setLastPlayedVersionIfNewer failed: {s}", .{@errorName(e)});
                }
            }
        }

        // Only surface a notification when the exit code is non-zero
        // (a clean exit means the user quit the game normally). The
        // ECHILD case (rc == -1) collapses into status = 0 here so
        // it stays silent too — those are stale entries, not crashes.
        notifyOnAbnormalExit(frame, d.tid, d.status);

        // Free the version string we duped at launch time.
        if (d.version) |v| frame.lib.alloc.free(v);
    }
}

/// Decode `status` from waitpid and, if it indicates an abnormal
/// exit, push a toast pointing the user at the game and (when a
/// compat scan finds anything) at the Fix Compat button.
fn notifyOnAbnormalExit(frame: *Frame, thread_id: u64, status: u32) void {
    log.info("launch-diag: notifyOnAbnormalExit fired for tid={d} status=0x{x}", .{ thread_id, status });
    const W = std.posix.W;
    const exited = W.IFEXITED(status);
    const signaled = W.IFSIGNALED(status);
    if (exited and W.EXITSTATUS(status) == 0) {
        log.info("launch-diag: clean exit (code 0) — no diag", .{});
        return;
    }
    if (!exited and !signaled) {
        log.info("launch-diag: stopped/continued — no diag", .{});
        return;
    }

    // Find the game name so the dialog summary is intelligible.
    const name = blk: {
        if (frame.games_by_thread) |map| {
            if (map.get(thread_id)) |g| break :blk g.name;
        } else {
            for (frame.games) |*g| if (g.f95_thread_id == thread_id) break :blk g.name;
        }
        break :blk "(unknown game)";
    };

    // Build the diagnostic summary + log. The log explains where the
    // upstream error message actually went (game's own stderr, which
    // f69 isn't capturing yet — see Phase 3 follow-up) and lists the
    // common causes the user should rule out. Offering the host-GPU
    // retry as the default fix because that's the dominant failure
    // mode on NixOS / sandboxed distros.
    var summary_buf: [256]u8 = undefined;
    const summary = if (exited)
        std.fmt.bufPrint(&summary_buf, "{s} exited with code {d}", .{ name, W.EXITSTATUS(status) }) catch "Game exited with error"
    else
        std.fmt.bufPrint(&summary_buf, "{s} was killed by signal {d}", .{ name, W.TERMSIG(status) }) catch "Game killed by signal";

    // Scan for any matching compat recipe AND grab the install dir
    // so we can read Ren'Py's own log files. Both are best-effort.
    var compat_recipe_id: ?[]const u8 = null;
    var compat_recipe_id_owned: ?[]u8 = null;
    defer if (compat_recipe_id_owned) |s| frame.lib.alloc.free(s);
    var install_id_set: bool = false;
    var install_id_buf: [36]u8 = undefined;
    var install_path_buf: [640]u8 = undefined;
    var install_path: []const u8 = "";
    if (frame.lib.latestInstallForGame(thread_id) catch null) |inst| {
        defer frame.lib.freeInstall(inst);
        @memcpy(&install_id_buf, &inst.id);
        install_id_set = true;
        const n = @min(inst.install_path.len, install_path_buf.len);
        @memcpy(install_path_buf[0..n], inst.install_path[0..n]);
        install_path = install_path_buf[0..n];
        log.info("launch-diag: scanning compat for tid={d} install_root='{s}'", .{ thread_id, install_path });
        if (scanCompatForInstall(frame, &inst.id, inst.install_path)) |issues| {
            defer freeCompatIssues(frame, issues);
            log.info("launch-diag: compat scan returned {d} issue(s)", .{issues.len});
            for (issues) |is| {
                log.info("launch-diag:   issue recipe='{s}' status={s} severity={s}", .{
                    is.recipe_id, @tagName(is.status), @tagName(is.severity),
                });
                if (is.status != .unfixed) continue;
                compat_recipe_id_owned = frame.lib.alloc.dupe(u8, is.recipe_id) catch null;
                compat_recipe_id = compat_recipe_id_owned;
                break;
            }
        } else |e| {
            log.warn("launch-diag: compat scan failed: {s}", .{@errorName(e)});
        }
    } else {
        log.warn("launch-diag: latestInstallForGame returned null for tid={d}", .{thread_id});
    }

    // Build the log body. Preference order:
    //   1. Ren'Py's `traceback.txt` (full Python traceback — gold).
    //   2. Ren'Py's `log.txt` (less detail, but covers non-Python crashes).
    //   3. Our generic "we don't capture stderr yet" boilerplate.
    //
    // Ren'Py writes these into the *game* root (one level below the
    // install root for the typical `<install>/GameName-X.Y/` wrapper
    // layout), so check both the install root and every immediate
    // subdir before giving up.
    var log_storage_buf: [8 * 1024]u8 = undefined;
    var log_txt: []const u8 = "";
    var used_log_file = false;
    if (install_path.len > 0) {
        const candidates = [_][]const u8{ "traceback.txt", "log.txt" };
        used_log_file = readFirstExistingLog(frame.io, install_path, &candidates, &log_storage_buf, &log_txt);
        if (!used_log_file) {
            // Wrapper-folder fallback: look one subdir deep.
            var dir = std.Io.Dir.cwd().openDir(frame.io, install_path, .{ .iterate = true }) catch null;
            if (dir) |*d| {
                defer d.close(frame.io);
                var it = d.iterate();
                var sub_path_buf: [768]u8 = undefined;
                while (it.next(frame.io) catch null) |entry| {
                    if (entry.kind != .directory and entry.kind != .unknown) continue;
                    const sub = std.fmt.bufPrint(&sub_path_buf, "{s}/{s}", .{ install_path, entry.name }) catch continue;
                    if (readFirstExistingLog(frame.io, sub, &candidates, &log_storage_buf, &log_txt)) {
                        used_log_file = true;
                        break;
                    }
                }
            }
        }
    }
    if (!used_log_file) {
        const generic = std.fmt.bufPrint(
            &log_storage_buf,
            "Game exited unexpectedly. f69 doesn't capture the game's own stderr yet.\n\n" ++
                "Common causes for an immediate exit:\n" ++
                "  - Missing shared library (libGL / libwayland / libxkbcommon)\n" ++
                "  - Wrong launcher picked (try a different install in the dropdown)\n" ++
                "  - Inner binary not marked executable\n",
            .{},
        ) catch "Game exited unexpectedly.";
        log_txt = generic;
    }

    // Only offer the Fix button when we have a SPECIFIC, known fix.
    // No fallback to host_gpu_paths "best guess" — when we don't know
    // what's wrong, leave fix_id null so the dialog shows just OK +
    // Copy and the user can decide.
    var fix_id: ?state_mod.LaunchFixId = null;
    if (compat_recipe_id) |rid| {
        if (install_id_set) {
            fix_id = .compat_recipe;
            const n = @min(rid.len, frame.state.launch_diag_compat_recipe_buf.len);
            @memcpy(frame.state.launch_diag_compat_recipe_buf[0..n], rid[0..n]);
            frame.state.launch_diag_compat_recipe_len = n;
            @memcpy(&frame.state.launch_diag_install_id_buf, &install_id_buf);
            frame.state.launch_diag_install_id_set = true;
        }
    } else {
        frame.state.launch_diag_compat_recipe_len = 0;
        frame.state.launch_diag_install_id_set = false;
    }

    const diag: LaunchDiagnosis = .{
        .summary = summary,
        .log = log_txt,
        .fix_id = fix_id,
    };
    stashLaunchDiag(frame.state, thread_id, diag);
}

/// Try each `candidate` filename under `base_dir`. On the first hit
/// that reads cleanly, fills `out_slice` with the slice into
/// `out_buf` and returns true. Used to locate Ren'Py's crash logs,
/// which may live either at the install root or inside a wrapper
/// subfolder.
fn readFirstExistingLog(
    io: std.Io,
    base_dir: []const u8,
    candidates: []const []const u8,
    out_buf: []u8,
    out_slice: *[]const u8,
) bool {
    var path_buf: [768]u8 = undefined;
    for (candidates) |fname| {
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, fname }) catch continue;
        if (readFilePrefix(io, path, out_buf)) |bytes| {
            out_slice.* = bytes;
            return true;
        } else |_| {}
    }
    return false;
}

/// Read up to `out.len` bytes from `path` into `out`. Returns a slice
/// of the actual bytes read. Used to pull Ren'Py's `log.txt` /
/// `traceback.txt` into the diag dialog without round-tripping the
/// heap.
fn readFilePrefix(io: std.Io, path: []const u8, out: []u8) ![]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(@intCast(out.len)));
    defer std.heap.page_allocator.free(bytes);
    const n = @min(bytes.len, out.len);
    @memcpy(out[0..n], bytes[0..n]);
    return out[0..n];
}

pub fn freeRunningGames(state: *State, alloc: std.mem.Allocator) void {
    if (state.running_games) |map_ptr| {
        var it = map_ptr.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.version) |v| alloc.free(v);
        }
        map_ptr.deinit();
        alloc.destroy(map_ptr);
        state.running_games = null;
    }
}

/// Called each guiFrame. For every `.done` job that we haven't already
/// handed off AND that has a real `game_id`, kick off an async worker
/// that SHA-verifies + extracts the archive into
/// `<library_root>/<game_id>/<version>/`. The actual heavy lifting
/// (gigabyte-sized 7z/zip extracts) lives on a detached thread so the
/// UI stays responsive. `.failed` jobs go straight to the next-source

// ============================================================
//  per-game backup saves — sandbox HOME → dated XDG_DATA_HOME copy
// ============================================================

/// Recursively copy the per-game sandbox HOME to
/// `<XDG_DATA_HOME>/f69/save-backups/<thread_id>/<YYYY-MM-DD-HHMMSS>/`.
/// Defends against the Round-18 footgun where deleting an install dir
/// also wipes the co-located sandbox HOME (Phase 7 installer will
/// decouple these — until then, periodic backups are the mitigation).
pub fn doBackupSaves(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    var home_buf: [640]u8 = undefined;
    const sandbox_home = std.fmt.bufPrint(&home_buf, "{s}/{d}/.f69-home", .{ frame.info.library_root, game.f95_thread_id }) catch {
        state.setLaunchMsg("Saves path buffer overflow.");
        return;
    };
    std.Io.Dir.cwd().access(frame.io, sandbox_home, .{}) catch {
        state.setLaunchMsg("No sandbox HOME yet — launch the game once to create it.");
        return;
    };

    // Backups live under data_root so they travel with the portable
    // f69 folder. `<data_root>/save-backups/<thread_id>/<unix-seconds>/`.
    const ts = backupTimestamp(frame.io);
    var dest_buf: [768]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/save-backups/{d}/{s}", .{ frame.info.data_root, game.f95_thread_id, ts }) catch {
        state.setLaunchMsg("Backup path buffer overflow.");
        return;
    };
    std.Io.Dir.cwd().createDirPath(frame.io, dest) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Backup mkdir failed: {s}", .{@errorName(e)}) catch "Backup mkdir failed";
        state.setLaunchMsg(msg);
        return;
    };

    copyTreePlain(alloc, frame.io, sandbox_home, dest) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Backup copy failed: {s}", .{@errorName(e)}) catch "Backup copy failed";
        state.setLaunchMsg(msg);
        return;
    };

    var ok_buf: [256]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Saves backed up to {s}", .{dest}) catch "Saves backed up";
    state.setLaunchMsg(ok_msg);
}

/// Inverse of `doBackupSaves`: pick a folder (e.g. a previous save
/// backup, or the user's existing save data) and copy its contents into
/// the per-game sandbox HOME. Lets a player carry saves into f69's
/// sandbox for a game they were already playing outside it.
pub fn doImportSaves(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    const picked = file_picker.openFolder(alloc, null) catch |e| {
        var buf: [128]u8 = undefined;
        state.setLaunchMsg(std.fmt.bufPrint(&buf, "Folder picker failed: {s}", .{@errorName(e)}) catch "Folder picker failed");
        return;
    } orelse return; // cancelled
    defer alloc.free(picked);

    var home_buf: [640]u8 = undefined;
    const sandbox_home = std.fmt.bufPrint(&home_buf, "{s}/{d}/.f69-home", .{ frame.info.library_root, game.f95_thread_id }) catch {
        state.setLaunchMsg("Saves path buffer overflow.");
        return;
    };

    // Import writes files into the sandbox HOME with truncate — an
    // in-place merge over whatever saves are already there. If that
    // directory already holds the player's current saves, snapshot them
    // FIRST so an accidental import of an older backup is recoverable.
    // A failed pre-import backup aborts the import (safety over convenience).
    if (dirHasEntries(frame.io, sandbox_home)) {
        const ts = backupTimestamp(frame.io);
        var bak_buf: [800]u8 = undefined;
        const bak = std.fmt.bufPrint(&bak_buf, "{s}/save-backups/{d}/pre-import-{s}", .{ frame.info.data_root, game.f95_thread_id, ts }) catch {
            state.setLaunchMsg("Pre-import backup path buffer overflow — import aborted.");
            return;
        };
        copyTreePlain(alloc, frame.io, sandbox_home, bak) catch |e| {
            var buf: [224]u8 = undefined;
            state.setLaunchMsg(std.fmt.bufPrint(&buf, "Couldn't back up existing saves ({s}) — import aborted to protect them.", .{@errorName(e)}) catch "Pre-import backup failed — import aborted");
            return;
        };
    }

    std.Io.Dir.cwd().createDirPath(frame.io, sandbox_home) catch |e| {
        var buf: [192]u8 = undefined;
        state.setLaunchMsg(std.fmt.bufPrint(&buf, "Sandbox HOME mkdir failed: {s}", .{@errorName(e)}) catch "mkdir failed");
        return;
    };
    copyTreePlain(alloc, frame.io, picked, sandbox_home) catch |e| {
        var buf: [192]u8 = undefined;
        state.setLaunchMsg(std.fmt.bufPrint(&buf, "Save import failed: {s}", .{@errorName(e)}) catch "Save import failed");
        return;
    };
    var ok: [256]u8 = undefined;
    state.setLaunchMsg(std.fmt.bufPrint(&ok, "Saves imported into sandbox HOME from {s} (existing saves, if any, were backed up first)", .{picked}) catch "Saves imported");
}

/// Pure-ish: produce a stable "YYYYMMDD-HHMMSS"-shaped string. Uses
/// the host clock; falls back to "unknown" if the clock read fails.
fn backupTimestamp(io: std.Io) [24]u8 {
    var out: [24]u8 = [_]u8{0} ** 24;
    const ts = std.Io.Clock.Timestamp.now(io, .real);
    const secs = @divTrunc(ts.raw.toNanoseconds(), 1_000_000_000);
    _ = std.fmt.bufPrint(&out, "{d}", .{secs}) catch return out;
    return out;
}

/// True if `path` exists as a directory and contains at least one
/// entry. Used to decide whether importing saves would clobber an
/// existing (non-empty) sandbox HOME. Any open/iterate error → false
/// (treat as "nothing worth protecting").
fn dirHasEntries(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer d.close(io);
    var it = d.iterate();
    return (it.next(io) catch return false) != null;
}

/// Simple recursive copy: directories + files, preserves modes, no
/// symlink magic. Backup destinations are user-owned save scratch
/// dirs — a symlink in there would be unusual and copying through is
/// closer to "snapshot what's there now".
fn copyTreePlain(alloc: std.mem.Allocator, io: std.Io, src: []const u8, dest: []const u8) !void {
    var src_dir = try std.Io.Dir.cwd().openDir(io, src, .{ .access_sub_paths = true, .iterate = true });
    defer src_dir.close(io);
    try std.Io.Dir.cwd().createDirPath(io, dest);

    var walker = try src_dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        var dst_buf: [1024]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dest, entry.path }) catch return error.PathTooLong;
        var src_buf: [1024]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src, entry.path }) catch return error.PathTooLong;

        switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(io, dest_path),
            .file => try copyOneFile(io, src_path, dest_path),
            else => {},
        }
    }
}

fn copyOneFile(io: std.Io, src: []const u8, dest: []const u8) !void {
    var in = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer in.close(io);
    const expected_size = (in.stat(io) catch return error.StatFailed).size;
    if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var out = try std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true });
    defer out.close(io);

    var rd_buf: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var wr_buf: [64 * 1024]u8 = undefined;
    var in_reader = in.reader(io, &rd_buf);
    var out_writer = out.writer(io, &wr_buf);
    var copied: u64 = 0;
    while (true) {
        // A read error MUST propagate, not be swallowed as EOF: swallowing
        // silently truncates the save backup/import while the caller still
        // reports success. readSliceShort aliases its source if the
        // destination is the reader's own backing buffer — keep them distinct.
        const got = try in_reader.interface.readSliceShort(&chunk);
        if (got == 0) break;
        try out_writer.interface.writeAll(chunk[0..got]);
        copied += got;
    }
    try out_writer.interface.flush();
    // Guard against a silent short read leaving a truncated copy.
    if (copied != expected_size) return error.ShortCopy;
    const st = in.stat(io) catch return;
    try out.setPermissions(io, st.permissions);
}

pub fn doOpenGameFolder(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // Honour the detail-page install picker. If the user has picked a
    // specific install in the dropdown, open *that* install's dir
    // rather than always the latest — matches how Launch resolves.
    var fallback_buf: [640]u8 = undefined;
    const installs_owned: ?[]library.Install = frame.lib.listInstalls(game.f95_thread_id) catch null;
    defer if (installs_owned) |list| frame.lib.freeInstalls(list);
    const picked: ?*const library.Install = blk: {
        const list = installs_owned orelse break :blk null;
        if (list.len == 0) break :blk null;
        if (state.detail_picker_install_id) |sel| {
            for (list) |*inst| {
                if (std.mem.eql(u8, inst.id[0..], sel[0..])) break :blk inst;
            }
        }
        break :blk &list[0];
    };
    const target: []const u8 = if (picked) |i|
        i.install_path
    else
        std.fmt.bufPrint(&fallback_buf, "{s}/{d}", .{ frame.info.library_root, game.f95_thread_id }) catch {
            state.setLaunchMsg("Open folder: path buffer overflow.");
            return;
        };

    std.Io.Dir.cwd().access(frame.io, target, .{}) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "No install at {s}. Download the game first.", .{target}) catch "No install dir";
        state.setLaunchMsg(msg);
        return;
    };

    spawnXdgOpen(alloc, frame.io, target) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Open folder failed: {s}", .{@errorName(e)}) catch "Open folder failed";
        state.setLaunchMsg(msg);
        return;
    };
    var ok_buf: [256]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Opened {s}", .{target}) catch "Opened folder";
    state.setLaunchMsg(ok_msg);
}

/// Open `<data_root>/logs/` (where the per-run logs live) in the file
/// manager. Surfaced from the Diagnostics screen so users can actually find
/// the log to attach to a bug report.
pub fn doOpenLogsFolder(frame: *Frame) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    var buf: [640]u8 = undefined;
    const target = std.fmt.bufPrint(&buf, "{s}/logs", .{frame.info.data_root}) catch {
        state.setLaunchMsg("Open logs: path buffer overflow.");
        return;
    };
    std.Io.Dir.cwd().createDirPath(frame.io, target) catch {}; // best-effort

    spawnXdgOpen(alloc, frame.io, target) catch |e| {
        var eb: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&eb, "Open logs failed: {s}", .{@errorName(e)}) catch "Open logs failed";
        state.setLaunchMsg(msg);
        return;
    };
    var ok: [256]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok, "Opened {s}", .{target}) catch "Opened logs";
    state.setLaunchMsg(ok_msg);
}

pub fn doOpenSaves(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    var sandbox_home_buf: [640]u8 = undefined;
    const sandbox_home = std.fmt.bufPrint(&sandbox_home_buf, "{s}/{d}/.f69-home", .{ frame.info.library_root, game.f95_thread_id }) catch {
        state.setConvertMsg("Saves path buffer overflow.");
        return;
    };

    // Recipe-pinned save paths were retired — the `saves` block on
    // GameRecipe is gone. Engine-derived defaults (Ren'Py:
    // `$XDG_DATA_HOME/RenPy/...`; RPGM: `<install>/www/save/`) will
    // land later. For now we fall back to the sandbox HOME itself
    // so the user can navigate manually. `game` stays in scope for
    // the future engine-derive path.
    const target = sandbox_home;
    std.Io.Dir.cwd().createDirPath(frame.io, target) catch {}; // best-effort

    // Spawn xdg-open detached so the UI doesn't block on the file
    // manager startup.
    spawnXdgOpen(alloc, frame.io, target) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Open saves failed: {s}", .{@errorName(e)}) catch "Open saves failed";
        state.setConvertMsg(msg);
        return;
    };

    var ok_buf: [256]u8 = undefined;
    const ok_msg = std.fmt.bufPrint(&ok_buf, "Opened {s}", .{target}) catch "Opened saves";
    state.setConvertMsg(ok_msg);
}

/// Open the install directory for the currently-selected mods-page
/// install in the user's file manager. Falls back to the game's most
/// recent install when nothing is explicitly picked. Non-blocking
/// (xdg-open is reaped on a detached thread). Logs + toasts on
/// failure; never blocks the UI thread.
pub fn doOpenInstallFolder(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    const install_opt = mods_act.resolveModsPageInstall(frame, game.f95_thread_id);
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const install = install_opt orelse {
        state.pushToast(.warn, "No install for this game yet.");
        return;
    };
    spawnXdgOpen(alloc, frame.io, install.install_path) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Open folder failed: {s}", .{@errorName(e)}) catch "Open folder failed";
        state.pushToast(.err, msg);
        return;
    };
}

/// Pure. Expand `$HOME` and `$XDG_DATA_HOME` in the recipe's saves
/// template against the per-game sandbox HOME. Allocator-owned result.
pub fn expandSavesPath(alloc: std.mem.Allocator, tmpl: []const u8, sandbox_home: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < tmpl.len) {
        if (std.mem.startsWith(u8, tmpl[i..], "$XDG_DATA_HOME")) {
            try out.appendSlice(alloc, sandbox_home);
            try out.appendSlice(alloc, "/.local/share");
            i += "$XDG_DATA_HOME".len;
        } else if (std.mem.startsWith(u8, tmpl[i..], "$HOME")) {
            try out.appendSlice(alloc, sandbox_home);
            i += "$HOME".len;
        } else {
            try out.append(alloc, tmpl[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn spawnXdgOpen(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const path_owned = try alloc.dupe(u8, path);
    // The reaper thread takes ownership of `path_owned` + the child
    // handle; UI thread returns immediately without blocking on
    // xdg-open's exit. Without this the f69 main thread sat on
    // `child.wait` for the few ms xdg-open lives, and the launched
    // file manager / browser appeared as f69's child in `ps`.
    const ReaperArgs = struct { io: std.Io, alloc: std.mem.Allocator, path: []u8 };
    const args_ptr = alloc.create(ReaperArgs) catch {
        alloc.free(path_owned);
        return error.OutOfMemory;
    };
    args_ptr.* = .{ .io = io, .alloc = alloc, .path = path_owned };

    const ReaperFn = struct {
        fn run(a: *ReaperArgs) void {
            defer a.alloc.free(a.path);
            defer a.alloc.destroy(a);
            // Per-OS file-manager / opener: Windows opens Explorer (or the
            // default handler) via `start`, macOS via `open`, Linux via
            // `xdg-open`. A literal `xdg-open` doesn't exist off Linux.
            var argv_buf: [5][]const u8 = undefined;
            const open_argv: []const []const u8 = switch (builtin.os.tag) {
                .windows => blk: {
                    argv_buf = .{ "cmd", "/c", "start", "", a.path };
                    break :blk argv_buf[0..5];
                },
                .macos => blk: {
                    argv_buf[0] = "open";
                    argv_buf[1] = a.path;
                    break :blk argv_buf[0..2];
                },
                else => blk: {
                    argv_buf[0] = "xdg-open";
                    argv_buf[1] = a.path;
                    break :blk argv_buf[0..2];
                },
            };
            var child = std.process.spawn(a.io, .{
                .argv = open_argv,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch return;
            _ = child.wait(a.io) catch {};
        }
    };
    const thr = std.Thread.spawn(.{}, ReaperFn.run, .{args_ptr}) catch |e| {
        alloc.free(args_ptr.path);
        alloc.destroy(args_ptr);
        return e;
    };
    thr.detach();
}

const testing = std.testing;

test "expandSavesPath: $HOME substitution" {
    const got = try expandSavesPath(testing.allocator, "$HOME/.renpy/save", "/games/14014/.f69-home");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/games/14014/.f69-home/.renpy/save", got);
}

test "expandSavesPath: $XDG_DATA_HOME substitution" {
    const got = try expandSavesPath(testing.allocator, "$XDG_DATA_HOME/RenPy/SummertimeSaga-1454697768", "/games/14014/.f69-home");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/games/14014/.f69-home/.local/share/RenPy/SummertimeSaga-1454697768", got);
}

test "expandSavesPath: literal path passes through" {
    const got = try expandSavesPath(testing.allocator, "/abs/path", "/sandbox");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/abs/path", got);
}

test "expandSavesPath: $XDG_DATA_HOME takes precedence over $HOME prefix" {
    // Both markers start with `$`; the longer one must win at any
    // given position.
    const got = try expandSavesPath(testing.allocator, "$XDG_DATA_HOME/x", "/sb");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/sb/.local/share/x", got);
}
