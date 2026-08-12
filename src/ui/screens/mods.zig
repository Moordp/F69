// Per-game Mods screen — two-pane manager.
//
//   Left pane:  filter checkboxes, scrollable list of modfiles
//               (archives) and orphan recipes, "+ Add modfile" /
//               "Import recipe" buttons.
//   Right pane: detail view for the selected entry — name + status
//               pill, primary action (Install / Uninstall / Set up
//               plan), Edit plan, plan summary, file impact, source
//               metadata.
//
// Replaces the previous tab-strip layout where every mod row carried
// every action and the user had to expand each row to see the install
// plan.

const std = @import("std");
const dvui = @import("dvui");
const library = @import("library");
const recipe = @import("recipe");
const file_picker = @import("util_file_picker");
const version_mod = @import("util_version");

const types = @import("../types.zig");
const owned_types = @import("../owned.zig");
const state_mod = @import("../state.zig");
const actions = @import("../actions.zig");
const style = @import("../style.zig");
const mod_job_queue = @import("../mod_job_queue.zig");
const components = @import("../components.zig");
const tokens = @import("ui_tokens");
const installer_mod = @import("installer");

const Frame = types.Frame;
// Readable secondary text (ink2) — the recipe version/status sublines and
// filter captions were ink3 (~3:1) and washed out. See style.labelText.
const helpTextColor = style.labelText;

/// Width of the left list pane. Right pane takes the remainder.
const LEFT_PANE_W: f32 = 360;

// ============================================================
//  Screen entry
// ============================================================

pub fn modsScreen(frame: *Frame) !bool {
    const state = frame.state;
    const game_opt = currentGameForMods(frame);
    const game = game_opt orelse {
        // No game in context (selected_thread gone). Bounce home.
        state.screen = .library;
        return true;
    };

    renderModsHeader(frame, game);
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // Page-level controls — apply to the whole game, not per-mod.
    // Sit above the two-pane body so switching selection in the list
    // doesn't reset them.
    {
        var page = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 8, .w = 16, .h = 4 },
        });
        defer page.deinit();
        renderModsInstallPicker(frame, game);
        renderModsBackupModePicker(frame, game);
        renderModJobBanner(frame);

        // Resolver explanation — why the installed mod set won't resolve.
        if (actions.modsPageCache(frame, game)) |cache| {
            if (cache.resolve_explanation) |msg| {
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
                var warn = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
                    .background = true,
                    .corner_radius = .all(4),
                    .color_fill = .{ .r = 0x3A, .g = 0x22, .b = 0x14 },
                });
                defer warn.deinit();
                dvui.icon(@src(), "resolve-warn", dvui.entypo.help, .{}, .{
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .color_text = tokens.toDvui(tokens.active.warn, dvui.Color),
                });
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
                dvui.labelNoFmt(@src(), msg, .{}, .{
                    .gravity_y = 0.5,
                    .color_text = tokens.toDvui(tokens.active.ink2, dvui.Color),
                });
            }
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // Two-pane body.
    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
    });
    defer body.deinit();

    renderModsLeftPane(frame, game);
    _ = dvui.separator(@src(), .{ .expand = .vertical });
    renderModsRightPane(frame, game);

    return true;
}

fn renderModsHeader(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer hdr.deinit();
    if (style.button(@src(), "< Back", .{}, .{})) {
        state.screen = .detail;
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Mods — {s}", .{game.name}) catch "Mods";
    dvui.labelNoFmt(@src(), title, .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color), .gravity_y = 0.5 });
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (style.button(@src(), "Open game folder", .{}, .{ .gravity_y = 0.5 })) {
        actions.doOpenInstallFolder(frame, game);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
    if (style.button(@src(), "Manage install patterns...", .{}, .{ .gravity_y = 0.5 })) {
        actions.openSettingsTab(state, .presets);
    }
}

// ============================================================
//  List item types + selection
// ============================================================

const ListItemKind = enum { modfile, orphan_recipe };

/// One entry in the left-pane list. Either a modfile (an on-disk
/// archive in the game's mods dir, optionally linked to a recipe)
/// or an orphan recipe (a `.mod.zon` not yet linked to an archive —
/// usually from `Import recipe...`).
const ListItem = union(ListItemKind) {
    modfile: struct {
        modfile_idx: usize,
        recipe_idx: ?usize,
    },
    orphan_recipe: struct {
        recipe_idx: usize,
    },
};

const ItemStatus = enum {
    installed,
    ready,
    needs_setup,

    fn pillColor(s: ItemStatus) dvui.Color {
        return switch (s) {
            .installed => .{ .r = 0x2D, .g = 0x6A, .b = 0x4F },
            .ready => .{ .r = 0x3C, .g = 0x55, .b = 0x77 },
            .needs_setup => .{ .r = 0x55, .g = 0x55, .b = 0x55 },
        };
    }

    fn label(s: ItemStatus) []const u8 {
        return switch (s) {
            .installed => "Installed",
            .ready => "Ready",
            .needs_setup => "Needs setup",
        };
    }

    fn allowedBy(s: ItemStatus, f: state_mod.ModsViewFilter) bool {
        return switch (s) {
            .installed => f.installed,
            .ready => f.ready,
            .needs_setup => f.needs_setup,
        };
    }
};

fn itemStatus(cache: *const owned_types.ModsPageCache, item: ListItem) ItemStatus {
    switch (item) {
        .modfile => |m| {
            if (m.recipe_idx == null) return .needs_setup;
            const idx = m.recipe_idx.?;
            if (cache.installed.len > idx and cache.installed[idx]) return .installed;
            return .ready;
        },
        .orphan_recipe => return .needs_setup,
    }
}

/// Stable selection key. Modfile id is sha256 hex (up to 64 chars);
/// orphan recipe id is the recipe slug. Prefix distinguishes the
/// kind through a single buffer in State.
fn itemSelectionId(
    buf: []u8,
    item: ListItem,
    modfiles: []const installer_mod.mod_archives.Modfile,
    cache: *const owned_types.ModsPageCache,
) []const u8 {
    return switch (item) {
        .modfile => |m| std.fmt.bufPrint(buf, "m:{s}", .{modfiles[m.modfile_idx].id}) catch "",
        .orphan_recipe => |r| std.fmt.bufPrint(buf, "r:{s}", .{cache.mods[r.recipe_idx].recipe.id}) catch "",
    };
}

fn isSelected(state: *const types.State, id: []const u8) bool {
    const cur = state.mods_selected_id_buf[0..state.mods_selected_id_len];
    return std.mem.eql(u8, cur, id);
}

fn setSelected(state: *types.State, id: []const u8) void {
    const n = @min(id.len, state.mods_selected_id_buf.len);
    @memcpy(state.mods_selected_id_buf[0..n], id[0..n]);
    state.mods_selected_id_len = n;
}

fn clearSelection(state: *types.State) void {
    state.mods_selected_id_len = 0;
}

/// Resolve the currently-selected list item by parsing the prefixed
/// id buffer and searching modfiles + cache. Returns null when no
/// selection or the target has been deleted underneath us.
fn resolveSelection(
    state: *const types.State,
    modfiles: []const installer_mod.mod_archives.Modfile,
    cache: *const owned_types.ModsPageCache,
) ?ListItem {
    const cur = state.mods_selected_id_buf[0..state.mods_selected_id_len];
    if (cur.len < 3) return null; // "m:" / "r:" + at least one char
    const kind_tag = cur[0..2];
    const id_part = cur[2..];
    if (std.mem.eql(u8, kind_tag, "m:")) {
        for (modfiles, 0..) |m, i| {
            if (std.mem.eql(u8, m.id, id_part)) {
                var ridx: ?usize = null;
                if (m.recipe_ids.len > 0) {
                    const target = m.recipe_ids[0];
                    for (cache.mods, 0..) |*pm, j| {
                        if (std.mem.eql(u8, pm.recipe.id, target)) {
                            ridx = j;
                            break;
                        }
                    }
                }
                return .{ .modfile = .{ .modfile_idx = i, .recipe_idx = ridx } };
            }
        }
        return null;
    }
    if (std.mem.eql(u8, kind_tag, "r:")) {
        for (cache.mods, 0..) |*pm, i| {
            if (std.mem.eql(u8, pm.recipe.id, id_part)) {
                if (i >= cache.have_archive.len or cache.have_archive[i]) return null;
                return .{ .orphan_recipe = .{ .recipe_idx = i } };
            }
        }
        return null;
    }
    return null;
}

// ============================================================
//  Left pane — filter + list + add buttons
// ============================================================

fn renderModsLeftPane(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = LEFT_PANE_W, .h = 1 },
        .expand = .vertical,
        .padding = .{ .x = 12, .y = 12, .w = 12, .h = 12 },
    });
    defer pane.deinit();

    // Add buttons row.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .y = 0, .h = 6 },
        });
        defer row.deinit();
        if (style.button(@src(), "+ Add modfile\u{2026}", .{}, .{ .style = .highlight })) {
            actions.clearPendingDelete(frame);
            pickAndAddModfile(frame, game);
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        if (style.button(@src(), "Import recipe\u{2026}", .{}, .{})) {
            actions.clearPendingDelete(frame);
            pickAndImportModRecipe(frame);
        }
    }

    // Filter checkboxes.
    {
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .y = 4, .h = 4 },
        });
        defer box.deinit();
        dvui.labelNoFmt(@src(), "Show:", .{}, .{ .color_text = helpTextColor() });
        _ = dvui.checkbox(@src(), &state.mods_view_filter.installed, "Installed", .{});
        _ = dvui.checkbox(@src(), &state.mods_view_filter.ready, "Ready", .{});
        _ = dvui.checkbox(@src(), &state.mods_view_filter.needs_setup, "Needs setup", .{});
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // Scrollable list.
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .padding = .{ .y = 4, .h = 4 },
    });
    defer scroll.deinit();

    const cache = actions.modsPageCache(frame, game) orelse {
        dvui.label(@src(), "(failed to load mods)", .{}, .{ .style = .err });
        return;
    };
    const modfiles = actions.modfilesForGame(frame, game);

    var rendered: usize = 0;
    var key_buf: [80]u8 = undefined;

    // Pass 1: modfiles (archives present on disk). Insertion order.
    for (modfiles, 0..) |m, i| {
        var ridx: ?usize = null;
        if (m.recipe_ids.len > 0) {
            const target = m.recipe_ids[0];
            for (cache.mods, 0..) |*pm, j| {
                if (std.mem.eql(u8, pm.recipe.id, target)) {
                    ridx = j;
                    break;
                }
            }
        }
        const item: ListItem = .{ .modfile = .{ .modfile_idx = i, .recipe_idx = ridx } };
        const status = itemStatus(cache, item);
        if (!status.allowedBy(state.mods_view_filter)) continue;
        const id = itemSelectionId(&key_buf, item, modfiles, cache);
        renderListRow(frame, item, status, id, modfiles, cache);
        rendered += 1;
        // Click handlers inside the row may have freed the cache via
        // refreshModfileCache; bail out of the iteration if so.
        if (frame.state.mods_page_cache == null) return;
    }

    // Pass 2: orphan recipes (no archive linked). Only shown when the
    // "needs setup" filter is on.
    if (state.mods_view_filter.needs_setup) {
        for (cache.mods, 0..) |_, i| {
            if (i >= cache.have_archive.len) break;
            if (cache.have_archive[i]) continue;
            const item: ListItem = .{ .orphan_recipe = .{ .recipe_idx = i } };
            const id = itemSelectionId(&key_buf, item, modfiles, cache);
            renderListRow(frame, item, .needs_setup, id, modfiles, cache);
            rendered += 1;
            if (frame.state.mods_page_cache == null) return;
        }
    }

    if (rendered == 0) {
        dvui.label(@src(), "(no mods match the current filter)", .{}, .{ .color_text = helpTextColor() });
    }
}

fn renderListRow(
    frame: *Frame,
    item: ListItem,
    status: ItemStatus,
    id: []const u8,
    modfiles: []const installer_mod.mod_archives.Modfile,
    cache: *const owned_types.ModsPageCache,
) void {
    const state = frame.state;
    const selected = isSelected(state, id);
    const id_key = std.hash.Wyhash.hash(0, id);

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_key,
        .expand = .horizontal,
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .background = true,
        .corner_radius = .{ .x = 3, .y = 3, .w = 3, .h = 3 },
        // Theme-driven (follows the accent set in Settings → Appearance):
        // selected = accent wash, unselected = neutral card. Was a hardcoded
        // maroon that didn't track the theme and killed text contrast.
        .color_fill = if (selected)
            tokens.toDvui(tokens.active.acc_wash, dvui.Color)
        else
            tokens.toDvui(tokens.active.bg2, dvui.Color),
    });
    defer row.deinit();

    // Status dot (10×10 circle).
    {
        var dot = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = id_key,
            .min_size_content = .{ .w = 10, .h = 10 },
            .max_size_content = .{ .w = 10, .h = 10 },
            .background = true,
            .corner_radius = .{ .x = 5, .y = 5, .w = 5, .h = 5 },
            .color_fill = status.pillColor(),
            .gravity_y = 0.5,
        });
        defer dot.deinit();
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });

    // Info column.
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = id_key,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });
        defer info.deinit();

        const name: []const u8 = switch (item) {
            .modfile => |m| modfiles[m.modfile_idx].filename,
            .orphan_recipe => |r| cache.mods[r.recipe_idx].recipe.name,
        };
        // Bright theme ink — NOT `.style = .highlight`, which sets the
        // dark on-accent text colour (only legible on an accent fill).
        dvui.labelNoFmt(@src(), name, .{}, .{ .color_text = tokens.toDvui(tokens.active.ink, dvui.Color) });

        var version_buf: [128]u8 = undefined;
        const sub: []const u8 = switch (item) {
            .modfile => |m| blk: {
                if (m.recipe_idx) |ri| {
                    if (ri < cache.mods.len) {
                        const v = cache.mods[ri].recipe.version;
                        break :blk std.fmt.bufPrint(&version_buf, "v{s} · {s}", .{ version_mod.stripVPrefix(v), status.label() }) catch status.label();
                    }
                }
                break :blk status.label();
            },
            .orphan_recipe => |r| std.fmt.bufPrint(&version_buf, "v{s} · needs archive", .{version_mod.stripVPrefix(cache.mods[r.recipe_idx].recipe.version)}) catch "needs archive",
        };
        dvui.labelNoFmt(@src(), sub, .{}, .{ .color_text = helpTextColor() });
    }

    // Whole-row click → select.
    if (dvui.clicked(row.data(), .{})) {
        setSelected(state, id);
    }
}

// ============================================================
//  Right pane — detail for the selected entry
// ============================================================

fn renderModsRightPane(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
    });
    defer pane.deinit();

    const cache = actions.modsPageCache(frame, game) orelse {
        dvui.label(@src(), "(failed to load mod details)", .{}, .{ .style = .err });
        return;
    };
    const modfiles = actions.modfilesForGame(frame, game);
    const item_opt = resolveSelection(state, modfiles, cache);

    const item = item_opt orelse {
        renderEmptyDetail();
        return;
    };

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    const status = itemStatus(cache, item);
    renderDetailHeader(item, status, modfiles, cache);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    renderDetailActions(frame, game, item, status, modfiles, cache);
    if (frame.state.mods_page_cache == null) return;
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });
    renderDetailPlan(item, cache);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });
    renderDetailImpact(item, cache);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });
    renderDetailMetadata(frame, item, cache);
}

fn renderEmptyDetail() void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    defer box.deinit();
    dvui.label(@src(), "Select a mod from the left to see its details.", .{}, .{
        .color_text = helpTextColor(),
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
}

fn renderDetailHeader(
    item: ListItem,
    status: ItemStatus,
    modfiles: []const installer_mod.mod_archives.Modfile,
    cache: *const owned_types.ModsPageCache,
) void {
    var hdr = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer hdr.deinit();

    // Name + status pill row.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        const title: []const u8 = switch (item) {
            .modfile => |m| modfiles[m.modfile_idx].filename,
            .orphan_recipe => |r| cache.mods[r.recipe_idx].recipe.name,
        };
        dvui.labelNoFmt(@src(), title, .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color), .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        renderStatusPill(status);
    }

    var sub_buf: [256]u8 = undefined;
    const subtitle = formatSubtitle(&sub_buf, item, modfiles, cache);
    dvui.labelNoFmt(@src(), subtitle, .{}, .{ .color_text = helpTextColor() });
}

fn renderStatusPill(status: ItemStatus) void {
    var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
        .background = true,
        .corner_radius = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .color_fill = status.pillColor(),
        .gravity_y = 0.5,
    });
    defer pill.deinit();
    dvui.labelNoFmt(@src(), status.label(), .{}, .{
        .color_text = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
    });
}

fn formatSubtitle(
    buf: []u8,
    item: ListItem,
    modfiles: []const installer_mod.mod_archives.Modfile,
    cache: *const owned_types.ModsPageCache,
) []const u8 {
    switch (item) {
        .modfile => |m| {
            const mf = modfiles[m.modfile_idx];
            const version: []const u8 = if (m.recipe_idx) |ri|
                (if (ri < cache.mods.len) cache.mods[ri].recipe.version else "?")
            else
                "no recipe";
            const sha_prefix = mf.id[0..@min(12, mf.id.len)];
            if (mf.size_bytes >= 1024 * 1024) {
                return std.fmt.bufPrint(buf, "v{s} · {d:.1} MiB · sha:{s}...", .{
                    version_mod.stripVPrefix(version),
                    @as(f64, @floatFromInt(mf.size_bytes)) / (1024.0 * 1024.0),
                    sha_prefix,
                }) catch "";
            }
            return std.fmt.bufPrint(buf, "v{s} · {d:.1} KiB · sha:{s}...", .{
                version_mod.stripVPrefix(version),
                @as(f64, @floatFromInt(mf.size_bytes)) / 1024.0,
                sha_prefix,
            }) catch "";
        },
        .orphan_recipe => |r| {
            return std.fmt.bufPrint(buf, "v{s} · no archive linked yet", .{version_mod.stripVPrefix(cache.mods[r.recipe_idx].recipe.version)}) catch "";
        },
    }
}

fn renderDetailActions(
    frame: *Frame,
    game: *const library.Game,
    item: ListItem,
    status: ItemStatus,
    modfiles: []const installer_mod.mod_archives.Modfile,
    cache: *const owned_types.ModsPageCache,
) void {
    const state = frame.state;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    switch (item) {
        .modfile => |m| {
            const mf = modfiles[m.modfile_idx];
            if (m.recipe_idx) |ri| {
                if (ri >= cache.mods.len) return;
                const pm = &cache.mods[ri];
                const busy = frame.mod_jobs.isModBusy(game.f95_thread_id, pm.recipe.f95_thread);
                switch (status) {
                    .installed => {
                        const label: []const u8 = if (busy) "Uninstalling\u{2026}" else "Uninstall";
                        if (style.button(@src(), label, .{}, .{ .style = .err })) {
                            if (!busy) actions.doUninstallMod(frame, game, &pm.recipe);
                        }
                    },
                    .ready => {
                        const label: []const u8 = if (busy) "Installing\u{2026}" else "Install";
                        if (style.button(@src(), label, .{}, .{ .style = .highlight })) {
                            if (!busy) actions.doInstallMod(frame, game, &pm.recipe);
                        }
                    },
                    .needs_setup => {},
                }
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
                if (style.button(@src(), "Edit plan\u{2026}", .{}, .{})) {
                    actions.clearPendingDelete(frame);
                    actions.openWizardForModfile(frame, game, mf.id);
                }
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
                if (style.button(@src(), "Save as preset\u{2026}", .{}, .{})) {
                    actions.doSaveModRecipeAsPreset(frame, game, &pm.recipe);
                }
                _ = dvui.spacer(@src(), .{ .expand = .horizontal });

                const pending_slice = state.modfile_pending_delete_id_buf[0..state.modfile_pending_delete_id_len];
                const armed = std.mem.eql(u8, pending_slice, pm.recipe.id);
                const del_label: []const u8 = if (armed) "Confirm delete recipe" else "Delete recipe";
                if (style.button(@src(), del_label, .{}, .{ .style = .err })) {
                    actions.doDeleteModRecipeArmed(frame, game, pm.recipe.id);
                    if (frame.state.mods_page_cache == null) {
                        clearSelection(frame.state);
                        return;
                    }
                }
            } else {
                // Modfile present but no recipe yet — primary action
                // is "Set up plan" via the wizard. Delete archive is
                // available behind the same two-click arm as a recipe
                // delete.
                if (style.button(@src(), "Set up plan\u{2026}", .{}, .{ .style = .highlight })) {
                    actions.clearPendingDelete(frame);
                    actions.openWizardForModfile(frame, game, mf.id);
                }
                _ = dvui.spacer(@src(), .{ .expand = .horizontal });
                const pending_slice = state.modfile_pending_delete_id_buf[0..state.modfile_pending_delete_id_len];
                const armed = std.mem.eql(u8, pending_slice, mf.id);
                const del_label: []const u8 = if (armed) "Confirm delete archive" else "Delete archive";
                if (style.button(@src(), del_label, .{}, .{ .style = .err })) {
                    actions.doDeleteModfile(frame, game, mf.id);
                }
            }
        },
        .orphan_recipe => |r| {
            const pm = &cache.mods[r.recipe_idx];
            if (style.button(@src(), "Add archive\u{2026}", .{}, .{ .style = .highlight })) {
                actions.clearPendingDelete(frame);
                pickAndRegisterModArchive(frame, game, &pm.recipe);
            }
            _ = dvui.spacer(@src(), .{ .expand = .horizontal });
            const pending_slice = state.modfile_pending_delete_id_buf[0..state.modfile_pending_delete_id_len];
            const armed = std.mem.eql(u8, pending_slice, pm.recipe.id);
            const del_label: []const u8 = if (armed) "Confirm delete recipe" else "Delete recipe";
            if (style.button(@src(), del_label, .{}, .{ .style = .err })) {
                actions.doDeleteModRecipeArmed(frame, game, pm.recipe.id);
                if (frame.state.mods_page_cache == null) {
                    clearSelection(frame.state);
                    return;
                }
            }
        },
    }
}

fn renderDetailPlan(item: ListItem, cache: *const owned_types.ModsPageCache) void {
    const pm: ?*const recipe.ParsedMod = switch (item) {
        .modfile => |m| if (m.recipe_idx) |ri|
            (if (ri < cache.mods.len) &cache.mods[ri] else null)
        else
            null,
        .orphan_recipe => |r| &cache.mods[r.recipe_idx],
    };

    dvui.labelNoFmt(@src(), "Plan summary", .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });

    if (pm == null) {
        dvui.label(@src(), "  (no recipe yet — click Set up plan to create one)", .{}, .{
            .color_text = helpTextColor(),
        });
        return;
    }
    const steps = pm.?.recipe.install;
    if (steps.len == 0) {
        dvui.label(@src(), "  (no steps — install does nothing)", .{}, .{ .color_text = helpTextColor() });
        return;
    }
    var line_buf: [320]u8 = undefined;
    var bullet_buf: [380]u8 = undefined;
    for (steps) |s| {
        const txt = formatStepSummary(&line_buf, s);
        const full = std.fmt.bufPrint(&bullet_buf, "  • {s}", .{txt}) catch txt;
        dvui.labelNoFmt(@src(), full, .{}, .{});
    }
}

fn formatStepSummary(buf: []u8, step: recipe.InstallStep) []const u8 {
    return switch (step) {
        .extract => |x| std.fmt.bufPrint(buf, "Extract archive · {s} wrapper · into {s}", .{
            if (x.strip > 0) "skip" else "keep",
            if (x.to.len == 0 or std.mem.eql(u8, x.to, ".")) "(install root)" else x.to,
        }) catch "Extract",
        .extract_inner => |x| std.fmt.bufPrint(buf, "Extract inner '{s}' · {s} wrapper · into {s}", .{
            x.archive,
            if (x.strip > 0) "skip" else "keep",
            if (x.to.len == 0 or std.mem.eql(u8, x.to, ".")) "(install root)" else x.to,
        }) catch "Extract inner",
        .copy => |x| std.fmt.bufPrint(buf, "Copy {s} → {s}", .{ x.src, x.dest }) catch "Copy",
        .move => |x| std.fmt.bufPrint(buf, "Move {s} → {s}", .{ x.src, x.dest }) catch "Move",
        .delete => |x| std.fmt.bufPrint(buf, "Delete {s}", .{x.path}) catch "Delete",
        .chmod_x => |x| std.fmt.bufPrint(buf, "Mark executable: {d} path(s)", .{x.paths.len}) catch "Mark executable",
    };
}

fn renderDetailImpact(item: ListItem, cache: *const owned_types.ModsPageCache) void {
    const pm: ?*const recipe.ParsedMod = switch (item) {
        .modfile => |m| if (m.recipe_idx) |ri|
            (if (ri < cache.mods.len) &cache.mods[ri] else null)
        else
            null,
        .orphan_recipe => |r| &cache.mods[r.recipe_idx],
    };

    dvui.labelNoFmt(@src(), "File impact", .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });

    if (pm == null) {
        dvui.label(@src(), "  (no recipe to preview)", .{}, .{ .color_text = helpTextColor() });
        return;
    }
    if (pm.?.recipe.files.len > 0) {
        var buf: [160]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "  Declares {d} file(s). Open Edit plan for the full file-impact preview.", .{pm.?.recipe.files.len}) catch "  Declares files.";
        dvui.labelNoFmt(@src(), txt, .{}, .{});
    } else {
        dvui.label(@src(), "  (impact preview not computed — open Edit plan to simulate)", .{}, .{
            .color_text = helpTextColor(),
        });
    }
}

fn renderDetailMetadata(
    frame: *Frame,
    item: ListItem,
    cache: *const owned_types.ModsPageCache,
) void {
    const pm: ?*const recipe.ParsedMod = switch (item) {
        .modfile => |m| if (m.recipe_idx) |ri|
            (if (ri < cache.mods.len) &cache.mods[ri] else null)
        else
            null,
        .orphan_recipe => |r| &cache.mods[r.recipe_idx],
    };
    if (pm == null) return;

    dvui.labelNoFmt(@src(), "Details", .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    const rec = pm.?.recipe;
    if (rec.for_game_version) |fgv| {
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "  Targets game version: {s}", .{fgv}) catch "";
        dvui.labelNoFmt(@src(), txt, .{}, .{ .color_text = helpTextColor() });
    }
    if (rec.requires.len > 0) {
        var buf: [256]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "  Requires: {d} mod(s)", .{rec.requires.len}) catch "";
        dvui.labelNoFmt(@src(), txt, .{}, .{ .color_text = helpTextColor() });
    }
    if (rec.conflicts.len > 0) {
        var buf: [256]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "  Conflicts with: {d} mod(s)", .{rec.conflicts.len}) catch "";
        dvui.labelNoFmt(@src(), txt, .{}, .{ .style = .err });
    }
    if (rec.post_url) |url| {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer row.deinit();
        dvui.label(@src(), "  Source: ", .{}, .{ .color_text = helpTextColor() });
        if (style.button(@src(), url, .{}, .{
            .style = .control,
            .color_text = style.labelDim(),
        })) {
            actions.openExternalUrl(frame, url);
        }
    }
}

// ============================================================
//  Preserved helpers (page-level controls + pickers)
// ============================================================

fn renderModsInstallPicker(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const installs = frame.lib.listInstalls(game.f95_thread_id) catch {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .y = 0, .h = 8 },
        });
        defer row.deinit();
        dvui.label(@src(), "Applying to:", .{}, .{ .gravity_y = 0.5, .color_text = helpTextColor() });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        dvui.label(@src(), "(failed to list installs)", .{}, .{ .gravity_y = 0.5, .style = .err });
        return;
    };
    defer if (installs.len > 0) frame.lib.freeInstalls(installs);

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .y = 0, .h = 8 },
    });
    defer row.deinit();
    dvui.label(@src(), "Applying to:", .{}, .{ .gravity_y = 0.5, .color_text = helpTextColor() });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });

    if (installs.len == 0) {
        dvui.label(
            @src(),
            "no install yet - install the game first",
            .{},
            .{ .gravity_y = 0.5, .color_text = helpTextColor() },
        );
        state.mods_page_install_id = null;
        return;
    }

    var labels_buf: [16][]const u8 = undefined;
    var join_buf: [16 * 96]u8 = undefined;
    var join_used: usize = 0;
    const n = @min(installs.len, labels_buf.len);
    for (installs[0..n], 0..) |inst, i| {
        const rest = join_buf[join_used..];
        const have_name = if (inst.name) |nm| nm.len > 0 else false;
        const joined = if (have_name)
            std.fmt.bufPrint(rest, "{s}  ({s})  -  {s}", .{ inst.version, @tagName(inst.source), inst.name.? }) catch inst.version
        else
            std.fmt.bufPrint(rest, "{s}  ({s})", .{ inst.version, @tagName(inst.source) }) catch inst.version;
        labels_buf[i] = joined;
        join_used += joined.len;
    }

    if (n == 1) {
        dvui.labelNoFmt(@src(), labels_buf[0], .{}, .{ .gravity_y = 0.5, .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
        if (state.mods_page_install_id == null) {
            state.mods_page_install_id = installs[0].id;
        }
        return;
    }

    var picked: usize = 0;
    if (state.mods_page_install_id) |sel| {
        for (installs[0..n], 0..) |inst, i| {
            if (std.mem.eql(u8, inst.id[0..], sel[0..])) {
                picked = i;
                break;
            }
        }
    }

    if (style.dropdown(@src(), labels_buf[0..n], .{ .choice = &picked }, .{}, .{
        .min_size_content = .{ .w = 280, .h = style.button_h },
        .gravity_y = 0.5,
    })) {
        state.mods_page_install_id = installs[picked].id;
    } else {
        if (state.mods_page_install_id == null) {
            state.mods_page_install_id = installs[picked].id;
        }
    }
}

fn renderModsBackupModePicker(frame: *Frame, game: *const library.Game) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .y = 0, .h = 8 },
    });
    defer row.deinit();
    dvui.label(@src(), "Uninstall safety:", .{}, .{ .gravity_y = 0.5, .color_text = helpTextColor() });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });

    const labels = [_][]const u8{
        "no backup (mod modifications stick if uninstalled)",
        "back up originals (clean uninstall; doubles disk for touched files)",
    };
    var pick: usize = if (game.mod_backup_mode == .copy) 1 else 0;
    if (style.dropdown(@src(), &labels, .{ .choice = &pick }, .{}, .{
        .min_size_content = .{ .w = 420, .h = style.button_h },
        .gravity_y = 0.5,
    })) {
        const new_pref: library.BackupModePref = if (pick == 1) .copy else .none;
        frame.lib.setGameModBackupMode(game.f95_thread_id, new_pref) catch |e| {
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Failed to save uninstall safety: {s}", .{@errorName(e)}) catch "Failed to save uninstall safety";
            frame.state.notifyErr(msg);
            return;
        };
        frame.state.reload_requested = true;
    }
}

fn renderModJobBanner(frame: *Frame) void {
    var head_info: ?struct {
        id: u64,
        kind: mod_job_queue.Kind,
        phase: mod_job_queue.Phase,
        display: [128]u8,
        display_len: u8,
        done: u32,
        total: u32,
        depth: usize,
    } = null;

    frame.mod_jobs.lock();
    {
        const jobs = frame.mod_jobs.jobsLocked();
        if (jobs.len > 0) {
            for (jobs) |j| {
                const p = j.currentPhase();
                if (p == .done or p == .err or p == .canceled) continue;
                var info: @TypeOf(head_info.?) = undefined;
                info.id = j.id;
                info.kind = j.kind;
                info.phase = p;
                const dlen = @min(j.display.len, info.display.len);
                @memcpy(info.display[0..dlen], j.display[0..dlen]);
                info.display_len = @intCast(dlen);
                info.done = j.progress_done.load(.monotonic);
                info.total = j.progress_total.load(.monotonic);
                info.depth = jobs.len;
                head_info = info;
                break;
            }
        }
    }
    frame.mod_jobs.unlock();

    const h = head_info orelse return;

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
    });
    defer bar.deinit();

    const verb: []const u8 = if (h.kind == .install) "Installing" else "Uninstalling";
    const phase_text = mod_job_queue.phaseLabel(h.phase);
    var buf: [256]u8 = undefined;
    const disp = h.display[0..h.display_len];
    const status_txt = blk: {
        if (h.total > 0) {
            break :blk std.fmt.bufPrint(&buf, "{s}: {s} - {s} ({d}/{d})", .{ verb, disp, phase_text, h.done, h.total }) catch "Mod job in flight";
        }
        if (h.done > 0) {
            break :blk std.fmt.bufPrint(&buf, "{s}: {s} - {s} ({d} files)", .{ verb, disp, phase_text, h.done }) catch "Mod job in flight";
        }
        break :blk std.fmt.bufPrint(&buf, "{s}: {s} - {s}", .{ verb, disp, phase_text }) catch "Mod job in flight";
    };
    dvui.labelNoFmt(@src(), status_txt, .{}, .{ .gravity_y = 0.5, .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });

    if (h.depth > 1) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        var dbuf: [64]u8 = undefined;
        const dtxt = std.fmt.bufPrint(&dbuf, "(+{d} queued)", .{h.depth - 1}) catch "";
        dvui.labelNoFmt(@src(), dtxt, .{}, .{ .gravity_y = 0.5, .color_text = helpTextColor() });
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (style.button(@src(), "Cancel", .{}, .{ .style = .err, .gravity_y = 0.5 })) {
        frame.mod_jobs.cancel(h.id);
    }
}

fn currentGameForMods(frame: *Frame) ?*const library.Game {
    const tid = frame.state.selected_thread orelse return null;
    if (frame.games_by_thread) |map| {
        if (map.get(tid)) |g| return g;
    }
    for (frame.games) |*g| {
        if (g.f95_thread_id == tid) return g;
    }
    return null;
}

fn pickAndImportModRecipe(frame: *Frame) void {
    const filters = [_]file_picker.FilterItem{
        .{ .name = "Recipe (ZON)", .spec = "zon" },
    };
    const picked = file_picker.open(frame.lib.alloc, &filters, null) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Picker failed: {s}", .{@errorName(e)}) catch "Picker failed";
        frame.state.pushToast(.err, msg);
        return;
    } orelse return;
    defer frame.lib.alloc.free(picked);
    actions.doImportModRecipe(frame, picked);
}

fn pickAndRegisterModArchive(frame: *Frame, game: *const library.Game, mod_recipe: *const recipe.ModRecipe) void {
    const filters = [_]file_picker.FilterItem{
        .{ .name = "Mod archives", .spec = "zip,7z,rar,tar,tar.gz,tar.bz2,tar.xz,tar.zst,tgz,tbz2,txz,gz,bz2,xz,zst" },
    };
    const picked = file_picker.open(frame.lib.alloc, &filters, null) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Picker failed: {s}", .{@errorName(e)}) catch "Picker failed";
        frame.state.setDownloadMsg(msg);
        return;
    } orelse return;
    defer frame.lib.alloc.free(picked);
    actions.doRegisterModArchive(frame, game, mod_recipe, picked);
}

fn pickAndAddModfile(frame: *Frame, game: *const library.Game) void {
    const filters = [_]file_picker.FilterItem{
        .{ .name = "Mod archives", .spec = "zip,7z,rar,tar,tar.gz,tar.bz2,tar.xz,tar.zst,tgz,tbz2,txz,gz,bz2,xz,zst" },
    };
    const picked = file_picker.open(frame.lib.alloc, &filters, null) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Picker failed: {s}", .{@errorName(e)}) catch "Picker failed";
        frame.state.setDownloadMsg(msg);
        return;
    } orelse return;
    defer frame.lib.alloc.free(picked);
    actions.doAddModfile(frame, game, picked);
}
