//! Universal (engine-wide) mods management screen (feature C). One modfile
//! applies to every game of an engine; per-game opt-out lives on the game's
//! detail page. Redesigned (dock-and-rail-redesign): header + slide-over add,
//! engine-grouped cards with apply-counts + an enable toggle.

const std = @import("std");
const dvui = @import("dvui");
const entypo = dvui.entypo;
const library = @import("library");
const tokens = @import("ui_tokens");

const types = @import("../types.zig");
const actions = @import("../actions.zig");
const style = @import("../style.zig");
const components = @import("../components.zig");
const comp = @import("ui_comp");

const Frame = types.Frame;

const ENGINE_LABELS: [actions.universalModEngines.len][]const u8 = blk: {
    var arr: [actions.universalModEngines.len][]const u8 = undefined;
    for (actions.universalModEngines, 0..) |e, i| arr[i] = components.engineShortLabel(e);
    break :blk arr;
};

pub fn universalModsScreen(frame: *Frame) !bool {
    const state = frame.state;
    const t = tokens.active;

    const mods_opt: ?[]library.UniversalMod = frame.lib.listUniversalMods(null) catch null;
    defer if (mods_opt) |m| frame.lib.freeUniversalMods(m);
    const mods = mods_opt orelse &.{};

    // engine count (distinct engines present)
    var engines_present: usize = 0;
    for (actions.universalModEngines) |eng| {
        for (mods) |m| {
            if (m.engine == eng) {
                engines_present += 1;
                break;
            }
        }
    }

    // ---- header ----
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
        });
        defer top.deinit();
        if (components.iconButton(@src(), "Library", entypo.chevron_left, .{ .gravity_y = 0.5 })) state.screen = .library;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        dvui.labelNoFmt(@src(), "Universal Mods", .{}, .{
            .gravity_y = 0.5,
            .color_text = .{ .color = tokens.toDvui(t.ink, dvui.Color) },
            .font = dvui.Font.theme(.title),
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
        {
            var cb: [48]u8 = undefined;
            const cnt = std.fmt.bufPrint(&cb, "{d} mods \u{00b7} {d} engines", .{ mods.len, engines_present }) catch "";
            const mono = dvui.Font.theme(.mono);
            dvui.labelNoFmt(@src(), cnt, .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = style.labelDim() }, .font = mono.withSize(mono.size * 0.85) });
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (components.iconButton(@src(), "Add universal mod", entypo.plus, .{ .style = .highlight, .gravity_y = 0.5, .tag = "mod-add" })) {
            state.universal_mod_add_open = true;
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // ---- empty state ----
    if (mods.len == 0) {
        components.emptyState(entypo.tools, "No universal mods yet", "Add a modfile once and f69 applies it across every game of that engine — opt individual games out from their detail page.");
        renderAddSlideover(frame);
        return true;
    }

    // ---- engine-grouped list ----
    var list = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer list.deinit();
    var inner = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .{ .x = 14, .y = 10, .w = 14, .h = 14 } });
    defer inner.deinit();

    var pending_delete: ?struct { id: i64, path: []const u8 } = null;
    for (actions.universalModEngines) |eng| {
        var n: usize = 0;
        for (mods) |m| {
            if (m.engine == eng) n += 1;
        }
        if (n == 0) continue;
        modGroupHeader(components.engineShortLabel(eng), n);
        for (mods) |m| {
            if (m.engine != eng) continue;
            if (renderModCard(frame, m)) pending_delete = .{ .id = m.id, .path = m.modfile_path };
        }
    }
    if (pending_delete) |d| actions.doDeleteUniversalMod(frame, d.id, d.path);

    renderAddSlideover(frame);
    return true;
}

/// Mono engine group label.
fn modGroupHeader(label: []const u8, n: usize) void {
    var b: [40]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{s} \u{00b7} {d}", .{ label, n }) catch label;
    const mono = dvui.Font.theme(.mono);
    dvui.labelNoFmt(@src(), s, .{}, .{
        .id_extra = @intFromPtr(label.ptr),
        .color_text = .{ .color = style.labelDim() },
        .font = mono.withSize(mono.size * 0.8),
        .padding = .{ .x = 2, .y = 10, .w = 0, .h = 4 },
    });
}

/// One universal-mod card. Returns true when the user asked to delete it
/// (the caller applies the delete after the loop to avoid mutating mid-read).
fn renderModCard(frame: *Frame, m: library.UniversalMod) bool {
    const t = tokens.active;
    const id_extra = @as(u64, @bitCast(m.id));
    var want_delete = false;

    var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = true,
        .border = style.border_thin,
        .corners = style.corner_radius,
        .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        .color_fill = .{ .color = style.cardFill() },
        .color_border = .{ .color = style.borderColor() },
    });
    defer card.deinit();

    // engine chip
    const fill = components.engineBadgeColor(m.engine);
    comp.chip(@src(), .{
        .label = components.engineShortLabel(m.engine),
        .fill = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
        .text = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
        .border = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
        .scale = 0.75,
    }, .{
        .id_extra = id_extra,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 72, .h = 1 },
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
        .corners = .all(3),
    });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });

    // name + modfile path
    {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id_extra, .gravity_y = 0.5 });
        defer col.deinit();
        const name = if (m.name.len > 0) m.name else "(unnamed mod)";
        dvui.labelNoFmt(@src(), name, .{}, .{
            .color_text = .{ .color = tokens.toDvui(if (m.enabled) t.ink else t.ink3, dvui.Color) },
            .font = dvui.Font.theme(.title).withSize(dvui.Font.theme(.title).size * 0.88),
        });
        const mono = dvui.Font.theme(.mono);
        dvui.labelNoFmt(@src(), m.modfile_path, .{}, .{
            .color_text = .{ .color = style.labelDim() },
            .font = mono.withSize(mono.size * 0.82),
        });
    }
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    // applied counts: active on N games · M opted out
    {
        const opted_out: u32 = frame.lib.countDisabledForMod(m.id) catch 0;
        var eng_total: u32 = 0;
        for (frame.games) |g| {
            if (g.engine == m.engine) eng_total += 1;
        }
        const active: u32 = if (eng_total > opted_out) eng_total - opted_out else 0;
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id_extra, .gravity_y = 0.5 });
        defer col.deinit();
        const mono = dvui.Font.theme(.mono);
        var ab: [40]u8 = undefined;
        const act_s = std.fmt.bufPrint(&ab, "active on {d}", .{active}) catch "";
        dvui.labelNoFmt(@src(), act_s, .{}, .{ .gravity_x = 1.0, .color_text = .{ .color = tokens.toDvui(t.ink2, dvui.Color) }, .font = mono.withSize(mono.size * 0.82) });
        var ob: [40]u8 = undefined;
        const out_s = std.fmt.bufPrint(&ob, "{d} opted out", .{opted_out}) catch "";
        dvui.labelNoFmt(@src(), out_s, .{}, .{ .gravity_x = 1.0, .color_text = .{ .color = style.labelDim() }, .font = mono.withSize(mono.size * 0.76) });
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });

    // enable toggle (On/Off pill)
    {
        const lbl = if (m.enabled) "On" else "Off";
        const opts: dvui.Options = if (m.enabled)
            .{ .id_extra = id_extra, .style = .highlight, .gravity_y = 0.5 }
        else
            .{ .id_extra = id_extra, .style = .control, .gravity_y = 0.5, .color_text = .{ .color = tokens.toDvui(t.ink3, dvui.Color) } };
        if (style.button(@src(), lbl, .{}, opts)) {
            frame.lib.setUniversalModEnabled(m.id, !m.enabled) catch {};
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });

    // Apply (skipped/disabled when the mod is off)
    {
        const apply_opts: dvui.Options = if (m.enabled)
            .{ .id_extra = id_extra, .gravity_y = 0.5 }
        else
            .{ .id_extra = id_extra, .gravity_y = 0.5, .style = .control, .color_text = .{ .color = tokens.toDvui(t.ink3, dvui.Color) } };
        if (components.iconButton(@src(), "Apply", entypo.cycle, apply_opts) and m.enabled) {
            actions.applyUniversalMod(frame, m.id, m.engine, m.modfile_path);
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });

    // ⋯ overflow → Delete
    {
        var ob = dvui.menu(@src(), .horizontal, .{ .id_extra = id_extra });
        defer ob.deinit();
        if (dvui.menuItemIcon(@src(), "mod-overflow", entypo.dots_three_horizontal, .{ .submenu = true }, .{
            .id_extra = id_extra,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .min_size_content = style.icon_size,
            .gravity_y = 0.5,
        })) |anchor| {
            var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
            defer fw.deinit();
            if (dvui.menuItemLabel(@src(), "Delete\u{2026}", .{}, .{ .expand = .horizontal }) != null) {
                want_delete = true;
                ob.close();
            }
        }
    }

    return want_delete;
}

/// "+ Add universal mod" slide-over: Name + Engine + choose-modfile. Centered
/// modal popup (auto-positioned). Closed via the header ✕.
fn renderAddSlideover(frame: *Frame) void {
    const state = frame.state;
    if (!state.universal_mod_add_open) return;

    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.universal_mod_add_open,
    }, .{
        .min_size_content = .{ .w = 460, .h = 0 },
        .max_size_content = .{ .w = 560, .h = 420 },
    });
    defer win.deinit();
    _ = dvui.windowHeader("Add universal mod", "", &state.universal_mod_add_open);

    var b = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .{ .x = 16, .y = 12, .w = 16, .h = 16 } });
    defer b.deinit();

    components.settingsHelpText("Applies to every game of the chosen engine. Turn it off for a specific game from that game's detail page.");
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });

    dvui.labelNoFmt(@src(), "Name", .{}, .{ .color_text = .{ .color = style.labelDim() } });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    const te = style.textEntry(@src(), .{
        .text = .{ .buffer = &state.universal_mod_name_buf },
        .placeholder = "(optional — defaults to the filename)",
    }, .{ .expand = .horizontal, .min_size_content = .{ .w = 0, .h = 28 } });
    te.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });

    dvui.labelNoFmt(@src(), "Engine", .{}, .{ .color_text = .{ .color = style.labelDim() } });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    _ = style.dropdown(@src(), &ENGINE_LABELS, .{ .choice = &state.universal_mod_engine_idx }, .{}, .{
        .min_size_content = .{ .w = 200, .h = 28 },
    });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 16 } });

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (components.iconButton(@src(), "Cancel", entypo.cross, .{})) state.universal_mod_add_open = false;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (components.iconButton(@src(), "Choose modfile\u{2026}", entypo.folder, .{ .style = .highlight, .tag = "mod-add-confirm" })) {
            actions.doAddUniversalMod(frame, actions.universalModEngineForIndex(state.universal_mod_engine_idx));
            state.universal_mod_add_open = false;
        }
    }
}
