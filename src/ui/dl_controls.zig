// Downloader controls panel: slots, speed caps, torrent share, upload caps,
// seeding, watched folder and the MEGA status line. Shared by the
// Downloads page ("Controls" expander) and Settings → Downloads.
//
// Each numeric field is a text entry + Save. Save validates, then
// `actions.setDlSetting` writes `<data_root>/<name>`, updates
// `state.dl_settings` and sends `reload_settings`. The text buffers live in
// `state.dl_ctrl_bufs` (filled from `dl_settings` on the first render).

const std = @import("std");
const dvui = @import("dvui");
const tokens = @import("ui_tokens");
const file_picker = @import("util_file_picker");

const types = @import("types.zig");
const actions = @import("actions.zig");
const style = @import("style.zig");
const components = @import("components.zig");

const Frame = types.Frame;
const State = types.State;
const MegaStatus = @import("state.zig").MegaStatus;
const Field = actions.DlSettingField;

fn dcol(col: tokens.Color) dvui.Color {
    return tokens.toDvui(col, dvui.Color);
}

/// Fill one text buffer from `dl_settings`.
fn fillBuf(state: *State, f: Field) void {
    const b = &state.dl_ctrl_bufs[@intFromEnum(f)];
    @memset(b, 0);
    _ = std.fmt.bufPrint(b[0 .. b.len - 1], "{d}", .{f.get(state.dl_settings)}) catch {};
}

fn bufSlice(state: *State, f: Field) []const u8 {
    const b = &state.dl_ctrl_bufs[@intFromEnum(f)];
    const end = std.mem.indexOfScalar(u8, b, 0) orelse b.len;
    return std.mem.trim(u8, b[0..end], " \t\r\n");
}

fn setMsg(state: *State, f: Field, msg: []const u8) void {
    state.dl_ctrl_msg.write(msg);
    state.dl_ctrl_msg_field = @intFromEnum(f);
}

/// Validate the field's buffer and save it; the result message shows
/// under the field.
pub fn saveField(frame: *Frame, f: Field) void {
    const state = frame.state;
    const typed = std.fmt.parseInt(u32, bufSlice(state, f), 10) catch {
        setMsg(state, f, "not a valid whole number");
        return;
    };
    if (!actions.setDlSetting(frame, f, typed)) {
        setMsg(state, f, "save failed");
        return;
    }
    fillBuf(state, f);
    const saved = f.clamp(typed);
    var buf: [96]u8 = undefined;
    const m = if (saved != typed)
        std.fmt.bufPrint(&buf, "saved as {d} (allowed range)", .{saved}) catch "saved"
    else
        "saved \u{2014} applied now";
    setMsg(state, f, m);
}

fn groupTitle(key: u32, text: []const u8) void {
    _ = dvui.spacer(@src(), .{ .id_extra = key, .min_size_content = .{ .w = 1, .h = 10 } });
    dvui.labelNoFmt(@src(), text, .{}, .{ .id_extra = key, .color_text = .{ .color = dcol(tokens.active.acc) } });
    _ = dvui.spacer(@src(), .{ .id_extra = key, .min_size_content = .{ .w = 1, .h = 4 } });
}

/// One numeric field: label · entry · unit · Save, a help line, and the
/// last Save message when it belongs to this field.
fn numField(frame: *Frame, f: Field, label: []const u8, unit: []const u8, help: []const u8) void {
    const state = frame.state;
    const idx = @intFromEnum(f);
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = idx, .expand = .horizontal, .padding = .{ .x = 0, .y = 2, .w = 0, .h = 4 } });
    defer col.deinit();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.labelNoFmt(@src(), label, .{}, .{ .min_size_content = .{ .w = 220, .h = 20 }, .gravity_y = 0.5 });
        const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.dl_ctrl_bufs[idx] } }, .{
            .min_size_content = .{ .w = 100, .h = 28 },
            .gravity_y = 0.5,
        });
        const entered = te.enter_pressed;
        te.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        dvui.labelNoFmt(@src(), unit, .{}, .{ .min_size_content = .{ .w = 50, .h = 20 }, .gravity_y = 0.5, .color_text = .{ .color = style.labelDim() } });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        if (style.button(@src(), "Save", .{}, .{ .gravity_y = 0.5 }) or entered) saveField(frame, f);
        if (state.dl_ctrl_msg_field == idx and !state.dl_ctrl_msg.isEmpty()) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
            dvui.labelNoFmt(@src(), state.dl_ctrl_msg.read(), .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = style.labelDim() } });
        }
    }
    dvui.labelNoFmt(@src(), help, .{}, .{ .color_text = .{ .color = components.helpTextColor() } });
}

/// Draw the panel. Call with no snapshot held (the folder picker blocks).
pub fn renderControls(frame: *Frame) void {
    const state = frame.state;
    if (!state.dl_ctrl_loaded) {
        for (std.enums.values(Field)) |f| fillBuf(state, f);
        state.dl_ctrl_loaded = true;
    }

    groupTitle(1, "Slots");
    numField(frame, .slots_files, "Files at once", "", "Direct, MEGA and browser downloads that run at the same time (1\u{2013}8).");
    numField(frame, .slots_torrents, "Torrents at once", "", "Torrents that download at the same time (1\u{2013}8).");

    groupTitle(2, "Speed caps (KB/s, 0 = unlimited)");
    numField(frame, .cap_total_kbs, "Total download", "KB/s", "All downloads together.");
    numField(frame, .cap_files_kbs, "Files", "KB/s", "Direct, MEGA and browser downloads together.");
    numField(frame, .cap_torrents_kbs, "Torrents", "KB/s", "All torrents together.");
    numField(frame, .torrent_share_pct, "Torrent share when both run", "%", "Only used with a total cap. Class caps are not clamped to the total.");

    groupTitle(3, "Upload");
    numField(frame, .ul_cap_busy_kbs, "While downloading", "KB/s", "Upload cap while anything downloads (default 256).");
    numField(frame, .ul_cap_idle_kbs, "When idle", "KB/s", "Upload cap while nothing downloads. 0 = unlimited.");

    groupTitle(4, "Seeding");
    renderSeedRatio(frame);
    renderSeedTime(frame);
    if (state.aria2_seed_ratio_msg_len > 0) {
        dvui.labelNoFmt(@src(), state.aria2_seed_ratio_msg_buf[0..state.aria2_seed_ratio_msg_len], .{}, .{
            .color_text = .{ .color = style.labelDim() },
        });
    }

    groupTitle(5, "Watched folder");
    renderWatchedFolder(frame);

    groupTitle(6, "MEGA");
    renderMegaLine(frame);
}

fn setSeedMsg(state: *State, msg: []const u8) void {
    const n = @min(msg.len, state.aria2_seed_ratio_msg_buf.len);
    @memcpy(state.aria2_seed_ratio_msg_buf[0..n], msg[0..n]);
    state.aria2_seed_ratio_msg_len = n;
}

fn renderSeedRatio(frame: *Frame) void {
    const state = frame.state;
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .{ .x = 0, .y = 2, .w = 0, .h = 4 } });
    defer col.deinit();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Seed ratio", .{}, .{ .min_size_content = .{ .w = 220, .h = 20 }, .gravity_y = 0.5 });
        const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.aria2_seed_ratio_buf } }, .{
            .min_size_content = .{ .w = 100, .h = 28 },
            .gravity_y = 0.5,
        });
        te.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        dvui.labelNoFmt(@src(), "\u{00D7}", .{}, .{ .min_size_content = .{ .w = 50, .h = 20 }, .gravity_y = 0.5, .color_text = .{ .color = style.labelDim() } });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        if (style.button(@src(), "Save", .{}, .{ .gravity_y = 0.5 })) {
            if (actions.saveAria2SeedRatio(state, frame.info.aria2_seed_ratio_path, frame.io)) |ratio| {
                // Applied at once to the running daemon + in-flight
                // torrents; the file keeps it for the next launch.
                state.dl_settings.seed_ratio = ratio;
                frame.dl.send(.{ .reload_settings = state.dl_settings });
                var msg_buf: [80]u8 = undefined;
                setSeedMsg(state, std.fmt.bufPrint(&msg_buf, "saved \u{2014} {d:.1}\u{00D7} target applied now", .{ratio}) catch "saved");
            } else |e| {
                setSeedMsg(state, switch (e) {
                    error.Empty => "ratio cannot be blank",
                    error.BelowFloor => "ratio must be \u{2265} 1.0",
                    error.NotFinite => "not a finite number",
                    error.InvalidCharacter => "not a valid number",
                    else => "save failed",
                });
            }
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        var live_buf: [48]u8 = undefined;
        dvui.labelNoFmt(@src(), std.fmt.bufPrint(&live_buf, "now using {d:.1}\u{00D7}", .{state.dl_settings.seed_ratio}) catch "", .{}, .{
            .gravity_y = 0.5,
            .color_text = .{ .color = style.labelDim() },
        });
    }
    dvui.labelNoFmt(@src(), "Upload this much of each torrent before seeding stops (at least 1.0, default 3.0).", .{}, .{
        .color_text = .{ .color = components.helpTextColor() },
    });
}

fn renderSeedTime(frame: *Frame) void {
    const state = frame.state;
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .{ .x = 0, .y = 2, .w = 0, .h = 4 } });
    defer col.deinit();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Seed time cap", .{}, .{ .min_size_content = .{ .w = 220, .h = 20 }, .gravity_y = 0.5 });
        const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.aria2_seed_time_buf } }, .{
            .min_size_content = .{ .w = 100, .h = 28 },
            .gravity_y = 0.5,
        });
        te.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        dvui.labelNoFmt(@src(), "min", .{}, .{ .min_size_content = .{ .w = 50, .h = 20 }, .gravity_y = 0.5, .color_text = .{ .color = style.labelDim() } });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        if (style.button(@src(), "Save", .{}, .{ .gravity_y = 0.5 })) {
            if (actions.saveAria2SeedTime(state, frame.info.aria2_seed_time_path, frame.io)) |minutes| {
                state.dl_settings.seed_time_min = minutes;
                frame.dl.send(.{ .reload_settings = state.dl_settings });
                var msg_buf: [80]u8 = undefined;
                setSeedMsg(state, if (minutes == 0)
                    "saved \u{2014} no seed-time cap"
                else
                    std.fmt.bufPrint(&msg_buf, "saved \u{2014} {d}m cap applied now", .{minutes}) catch "saved");
            } else |e| {
                setSeedMsg(state, switch (e) {
                    error.Empty => "minutes cannot be blank (use 0 for no cap)",
                    error.InvalidCharacter, error.Overflow => "not a valid whole number",
                    else => "save failed",
                });
            }
        }
    }
    dvui.labelNoFmt(@src(), "Stop seeding a torrent after this many minutes. 0 = no time cap.", .{}, .{
        .color_text = .{ .color = components.helpTextColor() },
    });
}

fn pickWatchDir(frame: *Frame) void {
    const alloc = frame.lib.alloc;
    const start: ?[]const u8 = if (frame.state.dl_settings.watch_dir.len > 0) frame.state.dl_settings.watch_dir else null;
    const picked = (file_picker.openFolder(alloc, start) catch |e| {
        var buf: [160]u8 = undefined;
        frame.state.notifyErr(std.fmt.bufPrint(&buf, "Folder picker failed: {s}", .{@errorName(e)}) catch "Folder picker failed");
        return;
    }) orelse return;
    defer alloc.free(picked);
    actions.setWatchDir(frame, picked);
}

fn renderWatchedFolder(frame: *Frame) void {
    const wd = frame.state.dl_settings.watch_dir;
    dvui.labelNoFmt(@src(), if (wd.len > 0) wd else "(default: your browser's Downloads folder)", .{}, .{
        .color_text = .{ .color = style.labelDim() },
    });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 0, .y = 4, .w = 0, .h = 2 } });
        defer row.deinit();
        if (dvui.button(@src(), "Change watched folder\u{2026}", .{}, .{ .gravity_y = 0.5, .tag = "settings-watch-dir" })) pickWatchDir(frame);
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (dvui.button(@src(), "Use default", .{}, .{ .gravity_y = 0.5, .tag = "settings-watch-default" })) actions.setWatchDir(frame, null);
    }
    dvui.labelNoFmt(@src(), "f69 watches this folder for files your browser downloads and offers them to waiting jobs.", .{}, .{
        .color_text = .{ .color = components.helpTextColor() },
    });
}

/// "MEGAcmd not installed" / "Signed out" / "Signed in as …".
pub fn megaStatusText(buf: []u8, status: MegaStatus, account: ?[]const u8) []const u8 {
    return switch (status) {
        .not_installed => "MEGAcmd not installed",
        .signed_in => std.fmt.bufPrint(buf, "Signed in as {s}", .{account orelse "?"}) catch "Signed in",
        .unknown, .busy => "Checking\u{2026}",
        .signed_out, .needs_code, .failed => "Signed out",
    };
}

test "megaStatusText: one line per status" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("MEGAcmd not installed", megaStatusText(&buf, .not_installed, null));
    try std.testing.expectEqualStrings("Signed out", megaStatusText(&buf, .signed_out, null));
    try std.testing.expectEqualStrings("Signed out", megaStatusText(&buf, .needs_code, null));
    try std.testing.expectEqualStrings("Signed in as a@b.cd", megaStatusText(&buf, .signed_in, "a@b.cd"));
}

fn renderMegaLine(frame: *Frame) void {
    const state = frame.state;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();
    var buf: [192]u8 = undefined;
    dvui.labelNoFmt(@src(), megaStatusText(&buf, state.mega_status, state.mega_account), .{}, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 220, .h = 20 },
        .tag = "dl-ctrl-mega",
    });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
    if (dvui.button(@src(), "Manage in Settings \u{2192} Accounts", .{}, .{ .gravity_y = 0.5 })) {
        state.screen = .settings;
        state.settings_tab = .accounts;
    }
}
