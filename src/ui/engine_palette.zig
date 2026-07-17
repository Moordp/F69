//! Per-engine accent colors — pure (`library.Engine` → `tokens.Color`).
//!
//! Extracted from `components.zig` so the *distinctness* property is
//! unit-testable without dragging in dvui. Each engine must be visually
//! separable at chip scale: the test at the bottom enforces a minimum
//! pairwise perceptual ("redmean") distance across every real engine, so
//! a future palette edit can't silently make two engines look alike.

const std = @import("std");
const library = @import("library");
const tokens = @import("ui_tokens");

const Color = tokens.Color;

inline fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = 0xff };
}

/// Fill / border / text colors for one tag chip.
pub const TagChip = struct { fill: Color, border: Color, text: Color };

/// Stable per-tag chip colors derived from the tag name — F95Checker's
/// "colorful tags" look with zero config: the same tag always maps to the
/// same hue, tuned for the dark UI (dark saturated fill, brighter border,
/// light readable text). A per-tag user override could layer on top later.
pub fn tagChip(tag: []const u8) TagChip {
    return tagChipFromHue(tagHue(tag));
}

/// The auto hue (0–360) a tag maps to by default.
pub fn tagHue(tag: []const u8) f32 {
    return @floatFromInt(std.hash.Wyhash.hash(0x7a9, tag) % 360);
}

/// Chip colors for a given hue — the shared dark-theme treatment used by
/// both the auto (hashed) hue and a user override, so overridden chips
/// stay as readable and consistent as the defaults.
pub fn tagChipFromHue(hue: f32) TagChip {
    return .{
        .fill = hslToRgb(hue, 0.45, 0.16),
        .border = hslToRgb(hue, 0.55, 0.42),
        .text = hslToRgb(hue, 0.55, 0.82),
    };
}

/// Chip colors for a user override packed as 0xRRGGBB — the chosen color
/// sets the hue; the standard treatment keeps it readable on the dark UI.
pub fn tagChipFromRgb(packed_rgb: u32) TagChip {
    const r: u8 = @intCast((packed_rgb >> 16) & 0xff);
    const g: u8 = @intCast((packed_rgb >> 8) & 0xff);
    const b: u8 = @intCast(packed_rgb & 0xff);
    return tagChipFromHue(rgbToHue(r, g, b));
}

fn rgbToHue(r8: u8, g8: u8, b8: u8) f32 {
    const r: f32 = @as(f32, @floatFromInt(r8)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(g8)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(b8)) / 255.0;
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const d = mx - mn;
    if (d == 0) return 0;
    var h: f32 = if (mx == r)
        @mod((g - b) / d, 6.0)
    else if (mx == g)
        (b - r) / d + 2.0
    else
        (r - g) / d + 4.0;
    h *= 60.0;
    if (h < 0) h += 360.0;
    return h;
}

fn hslToRgb(h_deg: f32, s: f32, l: f32) Color {
    const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const hp = h_deg / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    const m = l - c / 2.0;
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    if (hp < 1.0) {
        r = c;
        g = x;
    } else if (hp < 2.0) {
        r = x;
        g = c;
    } else if (hp < 3.0) {
        g = c;
        b = x;
    } else if (hp < 4.0) {
        g = x;
        b = c;
    } else if (hp < 5.0) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    return .{
        .r = @intFromFloat(@round((r + m) * 255.0)),
        .g = @intFromFloat(@round((g + m) * 255.0)),
        .b = @intFromFloat(@round((b + m) * 255.0)),
        .a = 0xff,
    };
}

/// Accent color for an engine's badge/chip. Hues are spread around the
/// wheel for separability while keeping a loose nod to each engine's
/// branding (Ren'Py teal, HTML5 orange, Java amber, Unity graphite…).
pub fn badgeColor(e: library.Engine) Color {
    return switch (e) {
        .renpy => rgb(0x1F, 0xA3, 0x9A), // teal
        .rpgm_mv => rgb(0xD6, 0x3A, 0x2F), // red
        .rpgm_mz => rgb(0xE0, 0x6E, 0xB0), // pink
        .rpgm_vx => rgb(0x7E, 0x4F, 0xC0), // violet
        .unity => rgb(0x33, 0x33, 0x33), // graphite
        .unreal => rgb(0x2A, 0x4F, 0xB0), // royal blue
        .html => rgb(0xE8, 0x73, 0x1F), // HTML5 orange
        .flash => rgb(0x8E, 0x20, 0x20), // maroon
        .java => rgb(0xA8, 0x6B, 0x12), // amber-brown
        .wolf_rpg => rgb(0x2F, 0x9E, 0x4F), // green
        .qsp => rgb(0x9E, 0x2E, 0x8A), // magenta
        .tyranobuilder => rgb(0xD4, 0xC0, 0x17), // gold
        .twine => rgb(0x8F, 0xC7, 0x3E), // lime
        .adrift => rgb(0x45, 0x6B, 0x7A), // steel
        .rags => rgb(0xE0, 0x8A, 0x6E), // coral
        .tads => rgb(0x8A, 0x8A, 0x2E), // olive
        .webgl => rgb(0x1B, 0xC5, 0xD4), // aqua
        .other => rgb(0x8A, 0x8A, 0x8A), // grey
        .unknown => rgb(0x6F, 0x6F, 0x6F), // grey (gated off in UI)
    };
}

// ---------------------------------------------------------------------------

/// Perceptual color distance (Thiadmer Riemersma's "redmean" — a cheap
/// approximation of CIE76 that weights channels by how red the pair is).
fn redmean(a: Color, b: Color) f64 {
    const af = struct {
        fn f(v: u8) f64 {
            return @floatFromInt(v);
        }
    }.f;
    const rmean = (af(a.r) + af(b.r)) / 2.0;
    const dr = af(a.r) - af(b.r);
    const dg = af(a.g) - af(b.g);
    const db = af(a.b) - af(b.b);
    return @sqrt((2.0 + rmean / 256.0) * dr * dr + 4.0 * dg * dg + (2.0 + (255.0 - rmean) / 256.0) * db * db);
}

test "tagChip is stable per tag and varies across tags" {
    const a = tagChip("Corruption");
    const b = tagChip("Corruption");
    try std.testing.expectEqual(a.fill.r, b.fill.r);
    try std.testing.expectEqual(a.fill.g, b.fill.g);
    try std.testing.expectEqual(a.border.b, b.border.b);
    const c = tagChip("Sandbox");
    try std.testing.expect(a.fill.r != c.fill.r or a.fill.g != c.fill.g or a.fill.b != c.fill.b);
    // Text stays light (readable on the dark fill).
    try std.testing.expect(a.text.r > 0x90 or a.text.g > 0x90 or a.text.b > 0x90);
}

test "every engine badge color is perceptually distinct" {
    // All real engines (`unknown` is gated off in the UI, so skip it).
    const engines = [_]library.Engine{
        .renpy,  .rpgm_mv,       .rpgm_mz, .rpgm_vx, .unity,
        .unreal, .html,          .flash,   .java,    .wolf_rpg,
        .qsp,    .tyranobuilder, .twine,   .other,   .adrift,
        .rags,   .tads,          .webgl,
    };
    // Empirically, ~13 = the old palette's tightest pair (mv vs html);
    // a comfortable "tell them apart at chip scale" floor sits near 80.
    const MIN: f64 = 80.0;
    var ok = true;
    for (engines, 0..) |e1, i| {
        for (engines[i + 1 ..]) |e2| {
            const d = redmean(badgeColor(e1), badgeColor(e2));
            if (d < MIN) {
                std.debug.print("too close: {s} <> {s} = {d:.1}\n", .{ @tagName(e1), @tagName(e2), d });
                ok = false;
            }
        }
    }
    try std.testing.expect(ok);
}
