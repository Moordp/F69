// Diagnostics screen — read-only state dump for bug reports.

const std = @import("std");
const dvui = @import("dvui");
const tokens = @import("ui_tokens");
const entypo = dvui.entypo;
const build_options = @import("build_options");
const installer_mod = @import("installer");
const version_mod = @import("util_version");

const types = @import("../types.zig");
const components = @import("../components.zig");
const actions = @import("../actions.zig");

const Frame = types.Frame;

// ============================================================
//  Diagnostics screen — read-only state dump for bug reports
// ============================================================

pub fn diagnosticsScreen(frame: *Frame) !bool {
    const state = frame.state;
    const info = frame.info;

    // Top bar — back button to library.
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();
        if (components.iconOnly(@src(), "back", entypo.chevron_left, .{})) state.screen = .library;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.label(@src(), "Diagnostics", .{}, .{ .gravity_y = 0.5, .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
        .expand = .horizontal,
    });
    defer body.deinit();

    // --- build ---
    diagSection(@src(), "Build");
    diagRow(@src(), "f69 version", build_options.version);

    diagSep(@src());

    // --- paths ---
    diagSection(@src(), "Paths");
    diagRow(@src(), "data_root (portable)", info.data_root);
    diagRow(@src(), "db_path", info.db_path);
    diagRow(@src(), "library_root", info.library_root);
    diagRow(@src(), "covers_dir", info.covers_dir);
    diagRow(@src(), "recipes_dir", info.recipes_dir);
    diagRow(@src(), "cookie_path", info.cookie_path);
    diagRow(@src(), "rpdl_token_path", info.rpdl_token_path);
    diagRow(@src(), "browser_path_file", info.browser_path_file);

    // Per-run logs live at <data_root>/logs/f69-<epoch>.log. Show the folder
    // and give a one-click way to open it — this is the file to attach to a
    // bug report.
    {
        var logs_buf: [768]u8 = undefined;
        const logs_dir = std.fmt.bufPrint(&logs_buf, "{s}/logs", .{info.data_root}) catch "(path too long)";
        diagRow(@src(), "logs_dir", logs_dir);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = .{ .x = 8, .y = 0, .w = 0, .h = 0 } });
        defer row.deinit();
        if (dvui.button(@src(), "Open log folder", .{}, .{})) actions.doOpenLogsFolder(frame);
    }

    diagSep(@src());

    // --- sandbox ---
    diagSection(@src(), "Sandbox");
    diagRow(@src(), "backend", frame.sandbox.backendName());

    // --- host env snapshot ---
    diagSep(@src());
    diagSection(@src(), "Host env (captured at startup)");
    diagRow(@src(), "$HOME / %USERPROFILE%", info.host.home orelse "(unset)");
    diagRow(@src(), "$XDG_RUNTIME_DIR", info.host.xdg_runtime_dir orelse "(unset)");
    diagRow(@src(), "$WAYLAND_DISPLAY", info.host.wayland_display orelse "(unset)");
    diagRow(@src(), "$DISPLAY", info.host.x11_display orelse "(unset)");

    diagSep(@src());

    // --- accounts / tokens ---
    diagSection(@src(), "Accounts");
    diagRow(@src(), "F95 login", switch (state.login_status) {
        .logged_in => "logged in",
        .logged_out => "logged out",
        .logging_in => "logging in…",
        .err => "error",
        .unknown => "unknown",
    });
    diagRow(@src(), "RPDL", switch (state.rpdl_status) {
        .logged_in => "logged in (token set)",
        .logged_out => "logged out (no token)",
        .logging_in => "logging in…",
        .err => "error",
        .unknown => "unknown",
    });

    diagSep(@src());

    // --- downloads ---
    {
        diagSection(@src(), "Downloads");
        var jobs_buf: [64]u8 = undefined;
        const jobs_msg = std.fmt.bufPrint(&jobs_buf, "{d} job(s) in Manager", .{frame.dl_mgr.jobs.count()}) catch "?";
        dvui.labelNoFmt(@src(), jobs_msg, .{}, .{});

        var it = frame.dl_mgr.jobs.iterator();
        while (it.next()) |entry| {
            const j = entry.value_ptr;
            var row_buf: [256]u8 = undefined;
            const row = std.fmt.bufPrint(&row_buf, "  #{d} [{s}/{s}] game={d} mod={?d} src={s}", .{
                j.id,
                @tagName(j.kind),
                @tagName(j.status),
                j.game_id,
                j.mod_id,
                j.source_url,
            }) catch continue;
            dvui.labelNoFmt(@src(), row, .{}, .{});
        }
    }

    diagSep(@src());

    // --- installs from DB ---
    {
        diagSection(@src(), "Installs (SQLite)");
        // Walk every game; for each, list its installs.
        for (frame.games) |g| {
            const installs = frame.lib.listInstalls(g.f95_thread_id) catch continue;
            defer frame.lib.freeInstalls(installs);
            if (installs.len == 0) continue;

            var header_buf: [128]u8 = undefined;
            const header = std.fmt.bufPrint(&header_buf, "  {d}  {s}", .{ g.f95_thread_id, g.name }) catch continue;
            dvui.labelNoFmt(@src(), header, .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
            for (installs) |i| {
                var ib: [320]u8 = undefined;
                const line = std.fmt.bufPrint(&ib, "    v{s} at {s} (installed_at={d})", .{ version_mod.stripVPrefix(i.version), i.install_path, i.installed_at }) catch continue;
                dvui.labelNoFmt(@src(), line, .{}, .{});
            }
        }
    }

    diagSep(@src());

    // --- selected game tracker ---
    if (state.selected_thread) |tid| {
        diagSection(@src(), "Tracker (selected game)");
        const inst_opt = frame.lib.latestInstallForGame(tid) catch null;
        defer if (inst_opt) |i| frame.lib.freeInstall(i);
        if (inst_opt) |inst| {
            var tracker_path_buf: [768]u8 = undefined;
            const tracker_path = std.fmt.bufPrint(&tracker_path_buf, "{s}/.f69-mods.json", .{inst.install_path}) catch return false;
            var log_obj = installer_mod.Tracker.load(frame.lib.alloc, frame.io, tracker_path) catch installer_mod.InstallLog{ .entries = &.{} };
            defer log_obj.deinit(frame.lib.alloc);

            var hb: [128]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hb, "  {d} entries at {s}", .{ log_obj.entries.len, tracker_path }) catch return false;
            dvui.labelNoFmt(@src(), hdr, .{}, .{});
            for (log_obj.entries) |e| {
                var eb: [256]u8 = undefined;
                const line = std.fmt.bufPrint(&eb, "    [{s}] mod={s} path={s}", .{ @tagName(e.kind), e.mod_id, e.path }) catch continue;
                dvui.labelNoFmt(@src(), line, .{}, .{});
            }
        } else {
            dvui.label(@src(), "  (no installs DB row for selected game)", .{}, .{});
        }
    }

    return true;
}

fn diagSection(src: anytype, name: []const u8) void {
    dvui.label(src, "{s}", .{name}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
}

fn diagRow(src: anytype, key: []const u8, value: []const u8) void {
    var buf: [768]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "  {s}: {s}", .{ key, value }) catch return;
    dvui.label(src, "{s}", .{line}, .{});
}

fn diagSep(src: std.builtin.SourceLocation) void {
    // Take the caller's @src() — using @src() here gives every call the same
    // widget id (this one line), which dvui flags as a duplicate-id error.
    _ = dvui.spacer(src, .{ .min_size_content = .{ .w = 1, .h = 10 } });
}
