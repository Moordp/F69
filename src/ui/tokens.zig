// Design tokens — runtime, user-editable theme for the f69 UI.
//
// Pure module (no dvui import) so the color math + theme derivation are
// unit-testable in isolation. A thin `toDvui` adapter (added when the
// component layer is wired) converts `Color` → `dvui.Color` (identical
// layout). See docs/superpowers/specs/2026-06-07-design-system-dvui-mapping.md.

const std = @import("std");

// ----- layout / type scale (Design B: squared, dense) -----
pub const r: f32 = 3; // standard corner radius
pub const r_lg: f32 = 5; // cards / panels
pub const sp1: f32 = 4;
pub const sp2: f32 = 8;
pub const sp3: f32 = 12;
pub const sp4: f32 = 16;
pub const font_display = "archivo";
pub const font_body = "plex_sans";
pub const font_mono = "plex_mono";

/// RGBA color, 8 bits per channel. Same field layout as `dvui.Color`, so a
/// `toDvui` adapter is a field copy.
pub const Color = struct {
    r: u8 = 0xff,
    g: u8 = 0xff,
    b: u8 = 0xff,
    a: u8 = 0xff,

    /// Per-channel linear blend toward `other` by `t` (0..1).
    pub fn lerp(self: Color, other: Color, t: f32) Color {
        return .{
            .r = mix(self.r, other.r, t),
            .g = mix(self.g, other.g, t),
            .b = mix(self.b, other.b, t),
            .a = mix(self.a, other.a, t),
        };
    }
};

fn mix(x: u8, y: u8, t: f32) u8 {
    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);
    return @intFromFloat(@round(std.math.clamp(xf + (yf - xf) * t, 0, 255)));
}

fn parseByte(two: []const u8) ?u8 {
    return std.fmt.parseInt(u8, two, 16) catch null;
}

/// Parse `#rrggbb` or `#rrggbbaa` (alpha defaults to 0xff). Null on malformed input.
pub fn parseHex(s: []const u8) ?Color {
    if ((s.len != 7 and s.len != 9) or s[0] != '#') return null;
    return .{
        .r = parseByte(s[1..3]) orelse return null,
        .g = parseByte(s[3..5]) orelse return null,
        .b = parseByte(s[5..7]) orelse return null,
        .a = if (s.len == 9) (parseByte(s[7..9]) orelse return null) else 0xff,
    };
}

test "parseHex parses #rrggbb into channels" {
    const c = parseHex("#34d0c4").?;
    try std.testing.expectEqual(@as(u8, 0x34), c.r);
    try std.testing.expectEqual(@as(u8, 0xd0), c.g);
    try std.testing.expectEqual(@as(u8, 0xc4), c.b);
    try std.testing.expectEqual(@as(u8, 0xff), c.a);
}

/// Comptime hex literal → Color (compile error on malformed input). For preset tables.
pub fn hex(comptime s: []const u8) Color {
    @setEvalBranchQuota(10_000);
    return parseHex(s) orelse @compileError("invalid hex color: " ++ s);
}

/// Every semantic color slot the UI reads. Runtime-swappable for user themes.
pub const Theme = struct {
    bg0: Color,
    bg1: Color,
    bg2: Color,
    bg3: Color,
    surface: Color,
    line: Color,
    line_soft: Color,
    ink: Color,
    ink2: Color,
    ink3: Color,
    ink_on_acc: Color,
    acc: Color,
    acc_dim: Color,
    acc_wash: Color,
    accent2: Color,
    ok: Color,
    warn: Color,
    danger: Color,
    info: Color,
};

/// Perceived luminance (0..255) — rec601 weights. Used to choose contrasting text.
pub fn luma(col: Color) f32 {
    const rf: f32 = @floatFromInt(col.r);
    const gf: f32 = @floatFromInt(col.g);
    const bf: f32 = @floatFromInt(col.b);
    return 0.299 * rf + 0.587 * gf + 0.114 * bf;
}

/// The few colors a user actually edits; the rest of the `Theme` derives from these.
pub const Base = struct { bg: Color, accent: Color, ink: Color, accent2: Color };

/// Derive a full `Theme` from a handful of base colors (the "Custom" theme path).
pub fn fromBase(base: Base) Theme {
    const white = Color{};
    const bg = base.bg;
    return .{
        .bg0 = bg,
        .bg1 = bg.lerp(white, 0.03),
        .bg2 = bg.lerp(white, 0.07),
        .bg3 = bg.lerp(white, 0.12),
        .surface = bg.lerp(white, 0.05),
        .line = bg.lerp(white, 0.16),
        .line_soft = bg.lerp(white, 0.10),
        .ink = base.ink,
        .ink2 = base.ink.lerp(bg, 0.30),
        .ink3 = base.ink.lerp(bg, 0.58),
        // readable text on the accent: dark for light accents, light for dark
        .ink_on_acc = if (luma(base.accent) > 140) Color{ .r = 8, .g = 8, .b = 8 } else Color{ .r = 245, .g = 245, .b = 245 },
        .acc = base.accent,
        .acc_dim = base.accent.lerp(bg, 0.55),
        .acc_wash = base.accent.lerp(bg, 0.88),
        .accent2 = base.accent2,
        // status colors are not derived — keep the standard set
        .ok = .{ .r = 0x52, .g = 0xc0, .b = 0x8a },
        .warn = .{ .r = 0xe6, .g = 0xb2, .b = 0x4a },
        .danger = .{ .r = 0xe2, .g = 0x60, .b = 0x4f },
        .info = .{ .r = 0x4a, .g = 0xa6, .b = 0xe6 },
    };
}

/// Convert to a structurally-identical color type (e.g. `dvui.Color`) without
/// coupling this pure module to dvui. Caller: `tokens.toDvui(c, dvui.Color)`.
pub fn toDvui(c: Color, comptime D: type) D {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

// ----- persistence (theme.zon-style: one `slot #hex` line per slot) -----

/// Write `#rrggbb` (or `#rrggbbaa` when alpha < 0xff) into `buf`; returns the slice.
pub fn hexOf(c: Color, buf: *[9]u8) []const u8 {
    return if (c.a == 0xff)
        std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch unreachable
    else
        std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b, c.a }) catch unreachable;
}

/// Serialize a theme as `slot #hex` lines into `out`. Caller sizes `out`
/// (≥ ~512 bytes); returns the written slice.
pub fn formatTheme(theme: Theme, out: []u8) []const u8 {
    var len: usize = 0;
    inline for (comptime std.meta.fieldNames(Theme)) |name| {
        var hb: [9]u8 = undefined;
        const hx = hexOf(@field(theme, name), &hb);
        const line = std.fmt.bufPrint(out[len..], "{s} {s}\n", .{ name, hx }) catch unreachable;
        len += line.len;
    }
    return out[0..len];
}

/// Parse override lines onto `base` (so a partial file = preset + overrides).
/// Unknown slots, comments, and malformed lines are ignored. No allocation.
pub fn parseTheme(base: Theme, text: []const u8) Theme {
    var result = base;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var it = std.mem.tokenizeScalar(u8, raw, ' ');
        const name = it.next() orelse continue;
        const val = it.next() orelse continue;
        const color = parseHex(val) orelse continue;
        inline for (comptime std.meta.fieldNames(Theme)) |field_name| {
            if (std.mem.eql(u8, name, field_name)) @field(result, field_name) = color;
        }
    }
    return result;
}

/// The live theme every component reads (`tokens.active.<slot>`). The Settings →
/// Appearance editor swaps this; immediate-mode means changes show next frame.
pub var active: Theme = presets.console;

/// Built-in themes. `console` = Design B (default); `obsidian` = Design A.
pub const presets = struct {
    /// Resolve a preset by its name, or null if unknown.
    pub fn byName(name: []const u8) ?Theme {
        if (std.mem.eql(u8, name, "console")) return console;
        if (std.mem.eql(u8, name, "obsidian")) return obsidian;
        if (std.mem.eql(u8, name, "midnight")) return midnight;
        if (std.mem.eql(u8, name, "paper")) return paper;
        return null;
    }

    pub const console = Theme{
        .bg0 = hex("#0a0e12"),  .bg1 = hex("#0f141b"),      .bg2 = hex("#151c25"),       .bg3 = hex("#1d2630"),
        .surface = hex("#10161d"), .line = hex("#202b36"),  .line_soft = hex("#18212b"),
        .ink = hex("#dbe3ea"),  .ink2 = hex("#9fb0bd"),     .ink3 = hex("#5f7384"),      .ink_on_acc = hex("#03100f"),
        .acc = hex("#34d0c4"),  .acc_dim = hex("#1c5650"),  .acc_wash = hex("#0c1f1e"),  .accent2 = hex("#b8e34a"),
        .ok = hex("#52c08a"),   .warn = hex("#e6b24a"),     .danger = hex("#e2604f"),    .info = hex("#4aa6e6"),
    };
    pub const obsidian = Theme{
        .bg0 = hex("#0c0c0f"),  .bg1 = hex("#131318"),      .bg2 = hex("#1a1a21"),       .bg3 = hex("#22222b"),
        .surface = hex("#16161c"), .line = hex("#2a2a35"),  .line_soft = hex("#1f1f28"),
        .ink = hex("#ecebe9"),  .ink2 = hex("#b6b5b0"),     .ink3 = hex("#7d7c85"),      .ink_on_acc = hex("#1a1206"),
        .acc = hex("#e8a13c"),  .acc_dim = hex("#7a5a22"),  .acc_wash = hex("#241b0d"),  .accent2 = hex("#e0567f"),
        .ok = hex("#5fb87a"),   .warn = hex("#e8a13c"),     .danger = hex("#e2604f"),    .info = hex("#5aa6d6"),
    };
    pub const midnight = Theme{
        .bg0 = hex("#0b1020"),  .bg1 = hex("#11162a"),      .bg2 = hex("#181f3a"),       .bg3 = hex("#222b4d"),
        .surface = hex("#0f1426"), .line = hex("#283256"),  .line_soft = hex("#1c2342"),
        .ink = hex("#e6e9f5"),  .ink2 = hex("#aab2d6"),     .ink3 = hex("#6b74a0"),      .ink_on_acc = hex("#0a0f1f"),
        .acc = hex("#6c8cff"),  .acc_dim = hex("#2f3d7a"),  .acc_wash = hex("#141a36"),  .accent2 = hex("#8be9fd"),
        .ok = hex("#5fb87a"),   .warn = hex("#e6b24a"),     .danger = hex("#e2604f"),    .info = hex("#6c8cff"),
    };
    /// Light theme. `consoleTheme` flips to the adwaita_light base when bg0 is light.
    pub const paper = Theme{
        .bg0 = hex("#f4f1ea"),  .bg1 = hex("#efece3"),      .bg2 = hex("#e7e3d8"),       .bg3 = hex("#dcd7c9"),
        .surface = hex("#faf8f2"), .line = hex("#d6cfbe"),  .line_soft = hex("#e7e2d6"),
        .ink = hex("#22201c"),  .ink2 = hex("#5b564c"),     .ink3 = hex("#8a8478"),      .ink_on_acc = hex("#ffffff"),
        .acc = hex("#1d6f66"),  .acc_dim = hex("#a9cfc9"),  .acc_wash = hex("#e3efec"),  .accent2 = hex("#c2491f"),
        .ok = hex("#2f8f5b"),   .warn = hex("#b5860b"),     .danger = hex("#c0392b"),    .info = hex("#2d6fa8"),
    };
};

test "parseTheme overrides only the named slots, ignoring junk" {
    const t = parseTheme(presets.console, "acc #ff0000\nbg0 #010203\n// a comment\ngarble\nnope #zz\n");
    try std.testing.expectEqual(Color{ .r = 0xff, .g = 0, .b = 0, .a = 0xff }, t.acc);
    try std.testing.expectEqual(Color{ .r = 0x01, .g = 0x02, .b = 0x03, .a = 0xff }, t.bg0);
    try std.testing.expectEqual(presets.console.ink, t.ink); // untouched
}

test "hexOf formats rgb and rgba" {
    var b: [9]u8 = undefined;
    try std.testing.expectEqualStrings("#34d0c4", hexOf(Color{ .r = 0x34, .g = 0xd0, .b = 0xc4 }, &b));
    try std.testing.expectEqualStrings("#0a0e1280", hexOf(Color{ .r = 0x0a, .g = 0x0e, .b = 0x12, .a = 0x80 }, &b));
}

test "formatTheme then parseTheme round-trips a theme" {
    var buf: [1024]u8 = undefined;
    const text = formatTheme(presets.obsidian, &buf);
    try std.testing.expectEqual(presets.obsidian, parseTheme(presets.console, text));
}

test "active theme defaults to the console preset" {
    try std.testing.expectEqual(presets.console, active);
}

test "toDvui copies channels into any compatible color struct" {
    const D = struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, a: u8 = 0 };
    try std.testing.expectEqual(D{ .r = 1, .g = 2, .b = 3, .a = 4 }, toDvui(Color{ .r = 1, .g = 2, .b = 3, .a = 4 }, D));
}

test "fromBase keeps the chosen colors and derives the ramps" {
    const t = fromBase(.{
        .bg = Color{ .r = 10, .g = 14, .b = 18 },
        .accent = Color{ .r = 52, .g = 208, .b = 196 },
        .ink = Color{ .r = 219, .g = 227, .b = 234 },
        .accent2 = Color{ .r = 184, .g = 227, .b = 74 },
    });
    // chosen colors pass through untouched
    try std.testing.expectEqual(Color{ .r = 52, .g = 208, .b = 196, .a = 255 }, t.acc);
    try std.testing.expectEqual(Color{ .r = 10, .g = 14, .b = 18, .a = 255 }, t.bg0);
    try std.testing.expectEqual(Color{ .r = 219, .g = 227, .b = 234, .a = 255 }, t.ink);
    // surface ramp lightens away from bg0
    try std.testing.expect(t.bg1.r > t.bg0.r and t.bg2.r > t.bg1.r and t.bg3.r > t.bg2.r);
    // dimmer text sits between ink and bg
    try std.testing.expect(t.ink3.r < t.ink.r and t.ink3.r > t.bg0.r);
    // accent wash is a dark, accent-tinted fill
    try std.testing.expect(t.acc_wash.r < t.acc.r);
}

test "fromBase picks readable on-accent text by accent luminance" {
    const base = Base{
        .bg = Color{ .r = 10, .g = 14, .b = 18 },
        .ink = Color{ .r = 219, .g = 227, .b = 234 },
        .accent2 = Color{ .r = 184, .g = 227, .b = 74 },
        .accent = undefined,
    };
    var bright = base;
    bright.accent = Color{ .r = 230, .g = 230, .b = 120 }; // light accent
    try std.testing.expect(luma(fromBase(bright).ink_on_acc) < 90); // → dark text

    var dark = base;
    dark.accent = Color{ .r = 20, .g = 30, .b = 80 }; // dark accent
    try std.testing.expect(luma(fromBase(dark).ink_on_acc) > 160); // → light text
}

test "presets.byName resolves known names, null otherwise" {
    try std.testing.expectEqual(presets.console, presets.byName("console").?);
    try std.testing.expectEqual(presets.obsidian, presets.byName("obsidian").?);
    try std.testing.expect(presets.byName("nope") == null);
}

test "console preset carries the Design B palette" {
    try std.testing.expectEqual(Color{ .r = 0x34, .g = 0xd0, .b = 0xc4, .a = 0xff }, presets.console.acc);
    try std.testing.expectEqual(Color{ .r = 0x0a, .g = 0x0e, .b = 0x12, .a = 0xff }, presets.console.bg0);
    try std.testing.expectEqual(Color{ .r = 0xb8, .g = 0xe3, .b = 0x4a, .a = 0xff }, presets.console.accent2);
}

test "obsidian preset carries the Design A accent" {
    try std.testing.expectEqual(Color{ .r = 0xe8, .g = 0xa1, .b = 0x3c, .a = 0xff }, presets.obsidian.acc);
}

test "midnight preset is dark indigo and resolves by name" {
    try std.testing.expectEqual(Color{ .r = 0x6c, .g = 0x8c, .b = 0xff, .a = 0xff }, presets.midnight.acc);
    try std.testing.expectEqual(presets.midnight, presets.byName("midnight").?);
}

test "paper preset is a light theme and resolves by name" {
    try std.testing.expect(luma(presets.paper.bg0) > 128); // light background
    try std.testing.expect(luma(presets.paper.ink) < 128); // dark text
    try std.testing.expectEqual(presets.paper, presets.byName("paper").?);
}

test "Color.lerp blends each channel at t" {
    const a = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const b = Color{ .r = 100, .g = 200, .b = 50, .a = 255 };
    const m = a.lerp(b, 0.5);
    try std.testing.expectEqual(Color{ .r = 50, .g = 100, .b = 25, .a = 255 }, m);
    try std.testing.expectEqual(a, a.lerp(b, 0.0));
    try std.testing.expectEqual(b, a.lerp(b, 1.0));
}

test "parseHex reads #rrggbbaa alpha and rejects malformed input" {
    try std.testing.expectEqual(@as(u8, 0x80), parseHex("#11223380").?.a);
    try std.testing.expectEqual(@as(u8, 0x11), parseHex("#11223380").?.r);
    try std.testing.expect(parseHex("") == null);
    try std.testing.expect(parseHex("11223344") == null); // missing '#'
    try std.testing.expect(parseHex("#12zz56") == null); // non-hex digits
    try std.testing.expect(parseHex("#123") == null); // wrong length
}
