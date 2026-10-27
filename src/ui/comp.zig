// Design B component layer — theme-driven dvui widgets.
//
// Colors come from `tokens.active` (the runtime theme), so every widget follows
// the user's chosen palette. Mirrors the call idioms in `style.zig`. Screens
// compose these instead of hand-building boxes. Visual parity target:
// docs/superpowers/mockups/design-B.html.

const std = @import("std");
const dvui = @import("dvui");
const tokens = @import("ui_tokens");

/// tokens.Color → dvui.Color.
inline fn c(col: tokens.Color) dvui.Color {
    return tokens.toDvui(col, dvui.Color);
}

// ----- chips / badges -----

pub const ChipSpec = struct {
    label: []const u8,
    fill: tokens.Color,
    text: tokens.Color,
    border: tokens.Color,
    /// Label font size as a fraction of the theme body font (1 = full size).
    scale: f32 = 1,
};

/// The one pill renderer. All badges below are thin theme-driven wrappers.
pub fn chip(src: std.builtin.SourceLocation, spec: ChipSpec, opts: dvui.Options) void {
    const defaults: dvui.Options = .{
        .background = true,
        .color_fill = .{ .color = c(spec.fill) },
        .color_border = .{ .color = c(spec.border) },
        .border = dvui.Rect.all(1),
        .corners = dvui.CornerRect.all(tokens.r),
        .padding = .{ .x = 7, .y = 1, .w = 7, .h = 1 },
        .min_size_content = .{ .w = 0, .h = 19 },
    };
    var box = dvui.box(src, .{ .dir = .horizontal }, defaults.override(opts));
    defer box.deinit();
    const body = dvui.Font.theme(.body);
    dvui.labelNoFmt(@src(), spec.label, .{}, .{
        .color_text = .{ .color = c(spec.text) },
        .gravity_y = 0.5,
        .gravity_x = 0.5,
        .font = body.withSize(body.size * spec.scale),
    });
}

pub fn engineChip(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options) void {
    const t = tokens.active;
    chip(src, .{ .label = label, .fill = t.acc_wash, .text = t.acc, .border = t.acc_dim }, opts);
}

pub fn statusChip(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options) void {
    const t = tokens.active;
    chip(src, .{ .label = label, .fill = t.bg2, .text = t.ink2, .border = t.line }, opts);
}

pub fn newChip(src: std.builtin.SourceLocation, opts: dvui.Options) void {
    const t = tokens.active;
    chip(src, .{ .label = "NEW", .fill = t.bg2, .text = t.accent2, .border = t.line }, opts);
}

pub fn tagChip(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options) void {
    const t = tokens.active;
    chip(src, .{ .label = label, .fill = t.bg2, .text = t.ink2, .border = t.line }, opts);
}

/// Small status dot (install/sync state).
pub fn dot(src: std.builtin.SourceLocation, color: tokens.Color, opts: dvui.Options) void {
    const defaults: dvui.Options = .{
        .background = true,
        .color_fill = .{ .color = c(color) },
        .corners = dvui.CornerRect.all(2),
        .min_size_content = .{ .w = 7, .h = 7 },
    };
    var box = dvui.box(src, .{}, defaults.override(opts));
    box.deinit();
}

// ----- button -----

pub const Variant = enum { neutral, primary, danger, ghost };

pub fn button(src: std.builtin.SourceLocation, label: []const u8, variant: Variant, opts: dvui.Options) bool {
    const t = tokens.active;
    const skin: dvui.Options = switch (variant) {
        .primary => .{ .color_fill = .{ .color = c(t.acc) }, .color_text = .{ .color = c(t.ink_on_acc) }, .color_border = .{ .color = c(t.acc) } },
        .danger => .{ .color_fill = .{ .color = c(t.bg2) }, .color_text = .{ .color = c(t.danger) }, .color_border = .{ .color = c(t.line) } },
        .ghost => .{ .color_text = .{ .color = c(t.ink2) } },
        .neutral => .{ .color_fill = .{ .color = c(t.bg2) }, .color_text = .{ .color = c(t.ink) }, .color_border = .{ .color = c(t.line) } },
    };
    const layout: dvui.Options = .{
        .background = variant != .ghost,
        .border = dvui.Rect.all(1),
        .corners = dvui.CornerRect.all(tokens.r),
        .padding = .{ .x = 12, .y = 0, .w = 12, .h = 0 },
        .min_size_content = .{ .w = 0, .h = 29 },
    };
    return dvui.button(src, label, .{}, layout.override(skin).override(opts));
}

// ----- toggle switch + segmented control -----

/// iOS-style on/off switch (Design B). Returns true on the frame it's clicked —
/// caller flips the bound bool. 40×22 pill, teal when on, knob slides right.
pub fn toggle(src: std.builtin.SourceLocation, on: bool, opts: dvui.Options) bool {
    const t = tokens.active;
    var track = dvui.box(src, .{ .dir = .horizontal }, (dvui.Options{
        .background = true,
        .color_fill = .{ .color = c(if (on) t.acc_wash else t.bg3) },
        .color_border = .{ .color = c(if (on) t.acc_dim else t.line) },
        .border = dvui.Rect.all(1),
        .corners = dvui.CornerRect.all(11),
        .min_size_content = .{ .w = 40, .h = 22 },
        .padding = .{ .x = 3, .y = 3, .w = 3, .h = 3 },
    }).override(opts));
    defer track.deinit();
    // knob pinned left (off) or right (on) via a leading/trailing spacer.
    if (on) _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    var knob = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = .{ .color = c(if (on) t.acc else t.ink3) },
        .corners = dvui.CornerRect.all(8),
        .min_size_content = .{ .w = 16, .h = 16 },
        .gravity_y = 0.5,
    });
    knob.deinit();
    if (!on) _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    return dvui.clicked(track.data(), .{});
}

/// Segmented control (Design B) — a row of mutually-exclusive options. Active
/// segment is filled with the accent. Returns the clicked index, or null.
pub fn segmented(src: std.builtin.SourceLocation, labels: []const []const u8, active: usize, opts: dvui.Options) ?usize {
    const t = tokens.active;
    var row = dvui.box(src, .{ .dir = .horizontal }, (dvui.Options{
        .background = true,
        .color_fill = .{ .color = c(t.bg1) },
        .color_border = .{ .color = c(t.line) },
        .border = dvui.Rect.all(1),
        .corners = dvui.CornerRect.all(tokens.r),
    }).override(opts));
    defer row.deinit();
    var hit: ?usize = null;
    for (labels, 0..) |lab, i| {
        const is_on = i == active;
        if (dvui.button(@src(), lab, .{}, .{
            .id_extra = i,
            .background = is_on,
            .color_fill = .{ .color = c(t.acc) },
            .color_text = .{ .color = c(if (is_on) t.ink_on_acc else t.ink2) },
            .color_border = .{ .color = c(t.line) },
            .border = .{ .x = if (i == 0) 0 else 1, .y = 0, .w = 0, .h = 0 },
            .corners = dvui.CornerRect.all(0),
            .padding = .{ .x = 13, .y = 0, .w = 13, .h = 0 },
            .min_size_content = .{ .w = 0, .h = 27 },
        })) hit = i;
    }
    return hit;
}

// ----- progress + section header -----

/// Horizontal progress bar. `frac` 0..1; `width` is the track width in px.
pub fn progressBar(src: std.builtin.SourceLocation, frac: f32, width: f32, opts: dvui.Options) void {
    const t = tokens.active;
    const f = std.math.clamp(frac, 0, 1);
    const defaults: dvui.Options = .{
        .background = true,
        .color_fill = .{ .color = c(t.bg3) },
        .corners = dvui.CornerRect.all(2),
        .min_size_content = .{ .w = width, .h = 7 },
    };
    var outer = dvui.box(src, .{ .dir = .horizontal }, defaults.override(opts));
    defer outer.deinit();
    var inner = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = .{ .color = c(t.acc) },
        .corners = dvui.CornerRect.all(2),
        .min_size_content = .{ .w = width * f, .h = 7 },
    });
    inner.deinit();
}

/// Mono, dimmed, uppercase-style section label (e.g. "PLAN SUMMARY").
pub fn sectionHeader(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options) void {
    dvui.labelNoFmt(src, label, .{}, (dvui.Options{ .color_text = .{ .color = c(tokens.active.ink3) } }).override(opts));
}

// ----- containers / inputs -----

/// A bordered surface panel (card/pane). Returns the box; caller adds children + deinits.
pub fn panel(src: std.builtin.SourceLocation, opts: dvui.Options) *dvui.BoxWidget {
    const t = tokens.active;
    const defaults: dvui.Options = .{
        .background = true,
        .color_fill = .{ .color = c(t.bg1) },
        .color_border = .{ .color = c(t.line) },
        .border = dvui.Rect.all(1),
        .corners = dvui.CornerRect.all(tokens.r_lg),
    };
    return dvui.box(src, .{ .dir = .vertical }, defaults.override(opts));
}

/// Bordered search/text field bound to `buffer`.
pub fn searchBox(src: std.builtin.SourceLocation, buffer: []u8, opts: dvui.Options) void {
    const t = tokens.active;
    const defaults: dvui.Options = .{
        .background = true,
        .color_fill = .{ .color = c(t.bg0) },
        .color_border = .{ .color = c(t.line) },
        .border = dvui.Rect.all(1),
        .corners = dvui.CornerRect.all(tokens.r),
        .padding = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        .min_size_content = .{ .w = 0, .h = 29 },
    };
    var box = dvui.box(src, .{ .dir = .horizontal }, defaults.override(opts));
    defer box.deinit();
    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = buffer } }, .{ .expand = .horizontal, .color_text = .{ .color = c(t.ink) } });
    te.deinit();
}

test "comp compiles against dvui + tokens" {
    std.testing.refAllDecls(@This());
}
