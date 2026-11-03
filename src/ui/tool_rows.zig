// Tool rows: one background tool (Convert, Decrypt, mod install, …) from
// the activity book, laid out like a download row. Used by the Tools and
// Tools history lists of the Downloads page and the Activity drawer.

const std = @import("std");
const dvui = @import("dvui");
const tokens = @import("ui_tokens");
const entypo = dvui.entypo;
const downloads = @import("downloads");

const types = @import("types.zig");
const style = @import("style.zig");
const components = @import("components.zig");
const comp = @import("ui_comp");
const dl_rows = @import("dl_rows.zig");

const Frame = types.Frame;
const activity = types.threads.activity;
const View = activity.View;
const Kind = activity.Kind;
const Status = activity.Status;
const ResultKind = activity.ResultKind;

pub const ToolAction = union(enum) { none, cancel: u64, remove: u64 };

/// Short chip label of a tool kind.
pub fn chipLabel(k: Kind) []const u8 {
    return switch (k) {
        .convert => "Convert",
        .decrypt => "Decrypt",
        .compat_fix => "Fix Compat",
        .rpa_extract => "Extract RPA",
        .hash => "Hash",
        .reanalyse => "Re-analyse",
        .plan_sim => "Plan",
        .folder_scan => "Scan",
        .mod_install => "Mod install",
        .mod_uninstall => "Mod remove",
        .sign_in => "Sign-in",
        .launch_probe => "Probe",
    };
}

/// Chip (and bar) colour of a tool status; the same colours as the
/// download status chips.
pub fn statusColor(s: Status) tokens.Color {
    return switch (s) {
        .queued => dl_rows.statusChipSpec(.queued).color,
        .running => tokens.active.acc,
        .done => dl_rows.statusChipSpec(.done).color,
        .failed => dl_rows.statusChipSpec(.failed).color,
        .cancelled => dl_rows.statusChipSpec(.cancelled).color,
    };
}

/// Text colour of a finished tool's result line.
fn resultColor(k: ResultKind) tokens.Color {
    return switch (k) {
        .ok => dl_rows.statusChipSpec(.done).color,
        .warn => dl_rows.statusChipSpec(.awaiting_user).color,
        .err => dl_rows.statusChipSpec(.failed).color,
    };
}

pub fn isLive(s: Status) bool {
    return s == .queued or s == .running;
}

/// Phase text to show: "Queued" while waiting, "Working" when the job
/// has not named a phase yet.
fn shownPhase(v: View) []const u8 {
    if (v.status == .queued) return "Queued";
    if (v.phase.len == 0) return "Working";
    return v.phase;
}

/// "Files" when the tool counts files, "Steps" otherwise.
pub fn barLabel(v: View) []const u8 {
    return if (v.files) "Files" else "Steps";
}

/// "<phase> · <done>/<total> (<pct>%) · <elapsed>", or
/// "<phase> · <elapsed>" with no total.
pub fn statsLine(buf: []u8, v: View, now: i64) []const u8 {
    var el_buf: [24]u8 = undefined;
    const elapsed = components.humanElapsed(&el_buf, dl_rows.elapsedSeconds(now, v.started_at));
    const phase = shownPhase(v);
    if (v.total > 0) {
        const pct = downloads.progress.percent(v.done, v.total);
        return std.fmt.bufPrint(buf, "{s} \u{00B7} {d}/{d} ({d}%) \u{00B7} {s}", .{ phase, v.done, v.total, pct, elapsed }) catch phase;
    }
    return std.fmt.bufPrint(buf, "{s} \u{00B7} {s}", .{ phase, elapsed }) catch phase;
}

/// How long a finished tool ran ("12 s"), or "\u{2013}" when unknown.
pub fn durationText(buf: []u8, v: View) []const u8 {
    if (v.started_at <= 0 or v.finished_at < v.started_at) return "\u{2013}";
    return components.humanElapsed(buf, @intCast(v.finished_at - v.started_at));
}

test "chipLabel and statusColor cover every value" {
    for (std.enums.values(Kind)) |k| try std.testing.expect(chipLabel(k).len > 0);
    try std.testing.expectEqualStrings("Extract RPA", chipLabel(.rpa_extract));
    try std.testing.expectEqualStrings("Mod remove", chipLabel(.mod_uninstall));
    try std.testing.expectEqual(dl_rows.statusChipSpec(.failed).color, statusColor(.failed));
    try std.testing.expectEqual(tokens.active.acc, statusColor(.running));
}

test "statsLine and durationText" {
    var v: View = .{ .id = 1, .kind = .hash, .game_thread_id = 42, .aux_id = 0, .title = "Hash", .phase = "step 3 / 10", .done = 3, .total = 10, .files = false, .status = .running, .started_at = 100, .finished_at = 0, .result = "", .result_kind = .ok };
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("step 3 / 10 \u{00B7} 3/10 (30%) \u{00B7} 12 s", statsLine(&buf, v, 112));
    v.total = 0;
    try std.testing.expectEqualStrings("step 3 / 10 \u{00B7} 12 s", statsLine(&buf, v, 112));
    try std.testing.expectEqualStrings("Steps", barLabel(v));
    v.files = true;
    try std.testing.expectEqualStrings("Files", barLabel(v));
    v.status = .queued;
    v.started_at = 0;
    try std.testing.expectEqualStrings("Queued \u{00B7} 0 s", statsLine(&buf, v, 112));
    v.status = .done;
    v.started_at = 100;
    v.finished_at = 285;
    try std.testing.expectEqualStrings("3m 05s", durationText(&buf, v));
    v.started_at = 0;
    try std.testing.expectEqualStrings("\u{2013}", durationText(&buf, v));
}

/// One tool row. `tagged`: the first live row carries `tools-row` and
/// `tools-cancel`, the first finished row `tools-history-row` and
/// `tools-remove` (dvui logs an error for a tag used twice in a frame,
/// so the caller tags one row of each kind, and none in the drawer).
pub fn renderToolRow(frame: *Frame, v: View, now: i64, tagged: bool) ToolAction {
    const live = isLive(v.status);
    const tg = struct {
        fn f(on: bool, name: []const u8) ?[]const u8 {
            return if (on) name else null;
        }
    }.f;
    var action: ToolAction = .none;
    const color = statusColor(v.status);
    const fill = tokens.toDvui(color, dvui.Color);
    var row = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = @intCast(v.id),
        .expand = .horizontal,
        .background = true,
        .border = style.border_thin,
        .corners = style.corner_radius,
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        .color_fill = .{ .color = style.cardFill() },
        .color_border = .{ .color = style.borderColor() },
        .tag = tg(tagged, if (live) "tools-row" else "tools-history-row"),
    });
    defer row.deinit();

    // Header line: kind chip + title + Cancel / Remove.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hdr.deinit();
        comp.chip(@src(), .{
            .label = chipLabel(v.kind),
            .fill = color,
            .text = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
            .border = color,
            .scale = 0.8,
        }, .{
            .id_extra = @intCast(v.id),
            .gravity_y = 0.5,
            .padding = .{ .x = 7, .y = 2, .w = 7, .h = 2 },
            .corners = .all(3),
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        const title = v.title;
        const truncated = if (title.len > 80) title[0..80] else title;
        dvui.label(@src(), "{s}{s}", .{ truncated, if (title.len > 80) "\u{2026}" else "" }, .{
            .gravity_y = 0.5,
            .color_text = .{ .color = tokens.toDvui(tokens.active.acc, dvui.Color) },
        });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (live) {
            if (components.iconButton(@src(), "Cancel", entypo.cross, .{ .id_extra = @intCast(v.id), .style = .err, .gravity_y = 0.5, .tag = tg(tagged, "tools-cancel") })) {
                action = .{ .cancel = v.id };
            }
        } else {
            if (components.iconButton(@src(), "Remove", entypo.trash, .{ .id_extra = @intCast(v.id), .gravity_y = 0.5, .tag = tg(tagged, "tools-remove") })) {
                action = .{ .remove = v.id };
            }
        }
    }

    if (!live) {
        // Finished: the result text in its kind's colour, then how long
        // the tool ran.
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer line.deinit();
        const result: []const u8 = if (v.result.len > 0) v.result else @tagName(v.status);
        dvui.labelNoFmt(@src(), result, .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = tokens.toDvui(resultColor(v.result_kind), dvui.Color) } });
        var dur_buf: [24]u8 = undefined;
        dvui.labelNoFmt(@src(), " \u{00B7} ", .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = style.labelDim() } });
        dvui.labelNoFmt(@src(), durationText(&dur_buf, v), .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = style.labelDim() } });
        return action;
    }

    // Live: the bar, then the stats line (which leads with the phase).
    const bar_label = barLabel(v);
    if (v.total > 0) {
        const d: f64 = @floatFromInt(v.done);
        const t: f64 = @floatFromInt(v.total);
        dl_rows.renderBar(bar_label, @floatCast(@min(d / t, 1.0)), fill, v.id);
    } else if (v.status == .running) {
        dl_rows.renderSweepBar(frame.io, bar_label, fill, v.id);
    }
    var stats_buf: [192]u8 = undefined;
    dvui.labelNoFmt(@src(), statsLine(&stats_buf, v, now), .{}, .{ .color_text = .{ .color = style.labelDim() } });
    return action;
}
