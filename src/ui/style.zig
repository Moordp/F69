// Global visual style. Every chrome widget in the app — buttons,
// dropdowns, text entries, icon chips, card frames — should source
// its dimensions and colors from here so the UI feels cohesive.
//
// Callers can override per-call by passing the relevant `opts` field;
// `defaults.override(opts)` lets the caller win. Things that need to
// break out entirely (carousel chevrons, raw `dvui.buttonIcon`) just
// keep calling dvui directly.

const std = @import("std");
const dvui = @import("dvui");
const tokens = @import("ui_tokens");

// =============================================================
//  Dimensions
// =============================================================

/// Outer "content height" used for every text button, dropdown,
/// and text entry on the toolbar. Matches `icon_size.h` so an
/// icon-only button and a text button sit at the same height.
pub const button_h: f32 = 16;

/// Square icon glyph size for icon-only buttons.
pub const icon_size: dvui.Size = .{ .w = 16, .h = 16 };

/// Standard corner radius for cards, chips, and buttons.
pub const corner_radius: dvui.Rect = .all(4);

/// Standard 1-px border for cards and chips.
pub const border_thin: dvui.Rect = .all(1);

/// Tight padding for cover-area chips (engine + status badges).
/// Vertical zero so the chip hugs the text height.
pub const chip_padding: dvui.Rect = .all(0);

/// Inset for chip text — a tiny amount of left/right breathing
/// room without the chip looking baggy.
pub const chip_label_padding: dvui.Rect = .{ .x = 1, .y = 0, .w = 1, .h = 0 };

// =============================================================
//  Typography
// =============================================================

/// Font-size scale for chip text. Multiplied by `body.size`.
pub const chip_font_scale: f32 = 0.51;

/// Font-size scale for subtitle / meta rows under card titles.
pub const meta_font_scale: f32 = 0.85;

/// Font-size scale for card titles. Multiplied by `heading.size`.
pub const title_font_scale: f32 = 0.85;

// =============================================================
//  Colors
// =============================================================

/// Border shared by card frames and chip outlines — follows the active theme.
pub fn borderColor() dvui.Color {
    return tokens.toDvui(tokens.active.line, dvui.Color);
}

/// Default card fill — follows the active theme.
pub fn cardFill() dvui.Color {
    return tokens.toDvui(tokens.active.bg1, dvui.Color);
}

/// Muted label / field-caption text — follows the active theme.
pub fn labelDim() dvui.Color {
    return tokens.toDvui(tokens.active.ink3, dvui.Color);
}

/// Readable secondary text — field captions, list sublines, help copy that
/// must stay legible on a dark card. Brighter than `labelDim` (ink3, ~3:1 on
/// graphite); ink2 is ~7:1.
pub fn labelText() dvui.Color {
    return tokens.toDvui(tokens.active.ink2, dvui.Color);
}

/// Letterbox / cover-empty fill behind aspect-preserved images.
pub const letterbox_fill: dvui.Color = .{ .r = 0x00, .g = 0x00, .b = 0x00 };

// =============================================================
//  Widget wrappers
// =============================================================

/// `dvui.button` with the app's standard outer height.
/// Census counters for the test sweep. Every interactive widget built in a
/// frame bumps `widgets_built`; those carrying a `.tag` (and so reachable by
/// `dvui.testing.moveTo`) bump `widgets_tagged`. The gap is the set of buttons
/// no automated test can click, which is otherwise invisible — see
/// docs/superpowers/specs/2026-08-10-exhaustive-test-harness-design.md.
///
/// Live in all builds on purpose: the enforcement tests have to measure the
/// configuration we actually ship, and the cost is one increment per widget.
pub var widgets_built: usize = 0;
pub var widgets_tagged: usize = 0;

pub fn resetWidgetCensus() void {
    widgets_built = 0;
    widgets_tagged = 0;
}

pub fn button(
    src: std.builtin.SourceLocation,
    label: []const u8,
    init_opts: dvui.ButtonWidget.InitOptions,
    opts: dvui.Options,
) bool {
    widgets_built += 1;
    if (opts.tag != null) widgets_tagged += 1;
    const defaults: dvui.Options = .{
        .min_size_content = .{ .w = 0, .h = button_h },
    };
    return dvui.button(src, label, init_opts, defaults.override(opts));
}

/// `dvui.dropdown` with the app's standard outer height.
pub fn dropdown(
    src: std.builtin.SourceLocation,
    entries: []const []const u8,
    choice: dvui.DropdownChoice(usize),
    init_opts: dvui.DropdownInitOptions,
    opts: dvui.Options,
) bool {
    const defaults: dvui.Options = .{
        .min_size_content = .{ .w = 0, .h = button_h },
    };
    return dvui.dropdown(src, entries, choice, init_opts, defaults.override(opts));
}

/// `dvui.textEntry` with the app's standard outer height.
pub fn textEntry(
    src: std.builtin.SourceLocation,
    init_opts: dvui.TextEntryWidget.InitOptions,
    opts: dvui.Options,
) *dvui.TextEntryWidget {
    const defaults: dvui.Options = .{
        .min_size_content = .{ .w = 0, .h = button_h },
    };
    return dvui.textEntry(src, init_opts, defaults.override(opts));
}
