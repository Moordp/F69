// Library screen — main grid/list view with sidebar filters,
// virtualized scrolling, sort comparator, top toolbar buttons.

const std = @import("std");
const dvui = @import("dvui");
const entypo = dvui.entypo;
const library = @import("library");

const version_mod = @import("util_version");

const types = @import("../types.zig");
const state_mod = @import("../state.zig");
const actions = @import("../actions.zig");
const style = @import("../style.zig");
const components = @import("../components.zig");
const comp = @import("ui_comp");
const tokens = @import("ui_tokens");
const reltime = @import("util_reltime");

const State = types.State;
const Frame = types.Frame;

// ============================================================
//  library screen
// ============================================================

/// One cell of the segmented view-toggle group (design-B .viewtoggle):
/// flush cells, active = acc-wash bg + acc text, inactive = dim icon.
fn segToggleOpts(on: bool, id: u64, tag: []const u8) dvui.Options {
    const t = tokens.active;
    return .{
        .id_extra = id,
        .tag = tag,
        .gravity_y = 0.5,
        .margin = dvui.Rect.all(0),
        .corner_radius = dvui.Rect.all(0),
        .background = on,
        .color_fill = tokens.toDvui(t.acc_wash, dvui.Color),
        .color_text = tokens.toDvui(if (on) t.acc else t.ink3, dvui.Color),
    };
}

pub fn libraryScreen(frame: *Frame) !bool {
    const state = frame.state;
    const games = frame.games;

    // Refresh the installed-set once per frame. Cheap SELECT DISTINCT
    // over the installs table; powers the "installed" indicator on
    // cards/list rows and the installed-state filter below.
    actions.refreshInstalledSet(frame);

    // Re-sort the snapshot if user changed the sort or we just reloaded.
    if (state.sort_applied_column != state.sort_column or state.sort_applied_dir != state.sort_dir) {
        sortGames(games, state.sort_column, state.sort_dir);
        state.sort_applied_column = state.sort_column;
        state.sort_applied_dir = state.sort_dir;
    }
    // ---- top bar ----
    // Top bar 1/2 — actions only. Layout:
    //   "f69 — N games" label takes the leading slack on the left,
    //   the button cluster lives in a `dvui.flexbox(.justify_content
    //   = .end)` on the right so the buttons anchor to the right
    //   edge. When the window is too narrow to fit everything on
    //   one row, the flexbox wraps the buttons onto subsequent
    //   rows (still right-aligned).
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 4 },
        });
        defer top.deinit();

        // Design-B single top bar: title · games count …… [view toggles]
        // [search] [Sync ▼] [+Add] [account]. (Quit removed — the window
        // controls close; sort moved to clickable list headers; Global Mods
        // lives on the icon rail.)
        dvui.labelNoFmt(@src(), "Library", .{}, .{
            .gravity_y = 0.5,
            .color_text = tokens.toDvui(tokens.active.ink, dvui.Color),
            .font = dvui.Font.theme(.title),
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
        {
            // "N games · M updates" (design-B: muted mono). The updates tail
            // only shows when something can actually be updated.
            var upd: usize = 0;
            if (frame.install_versions) |m| {
                for (games) |*g| {
                    if (hasUpdateAvailable(g, m.get(g.f95_thread_id))) upd += 1;
                }
            }
            var cnt_buf: [64]u8 = undefined;
            const cnt = if (upd > 0)
                std.fmt.bufPrint(&cnt_buf, "{d} games \u{00b7} {d} updates", .{ games.len, upd }) catch ""
            else
                std.fmt.bufPrint(&cnt_buf, "{d} games", .{games.len}) catch "";
            const mono = dvui.Font.theme(.mono);
            dvui.labelNoFmt(@src(), cnt, .{}, .{
                .gravity_y = 0.5,
                .color_text = style.labelDim(),
                .font = mono.withSize(mono.size * 0.85),
            });
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // Sort control — applies to EVERY view. The Design-B top-bar rework
        // dropped it and left sorting only on the list view's column headers,
        // so grid + kanban had no way to change the sort. Column dropdown +
        // asc/desc toggle, restored here.
        {
            const sort_labels = &[_][]const u8{ "Name", "Rating", "Weighted", "Votes", "Last updated", "Sync state", "Last played version" };
            var sort_picked: usize = @intFromEnum(state.sort_column);
            if (style.dropdown(@src(), sort_labels, .{ .choice = &sort_picked }, .{}, .{
                .min_size_content = .{ .w = 170, .h = style.button_h },
                .gravity_y = 0.5,
                .tag = "lib-sort",
            })) {
                state.sort_column = @enumFromInt(sort_picked);
            }
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
            const dir_tvg = if (state.sort_dir == .asc) entypo.chevron_up else entypo.chevron_down;
            if (components.iconOnly(@src(), "sort-dir", dir_tvg, .{ .style = .highlight, .gravity_y = 0.5, .tag = "lib-sort-dir" })) {
                state.sort_dir = if (state.sort_dir == .asc) .desc else .asc;
            }
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });

        // view toggle (grid / list / kanban) — segmented control in one
        // bordered group (design-B .viewtoggle); active = acc-wash bg + acc
        // text, not a solid block.
        {
            var seg = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .gravity_y = 0.5,
                .border = style.border_thin,
                .color_border = style.borderColor(),
                .corner_radius = style.corner_radius,
            });
            defer seg.deinit();
            if (components.iconOnly(@src(), "grid", entypo.grid, segToggleOpts(state.view == .grid, 1, "view-grid"))) state.view = .grid;
            if (components.iconOnly(@src(), "list", entypo.list, segToggleOpts(state.view == .list, 2, "view-list"))) state.view = .list;
            if (components.iconOnly(@src(), "kanban", entypo.browser, segToggleOpts(state.view == .kanban, 3, "view-kanban"))) state.view = .kanban;
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });

        // search — magnifier + entry inside one bordered box (design-B .search),
        // with a "Search…" placeholder.
        {
            var sb = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .gravity_y = 0.5,
                .background = true,
                .color_fill = tokens.toDvui(tokens.active.bg0, dvui.Color),
                .border = style.border_thin,
                .color_border = style.borderColor(),
                .corner_radius = style.corner_radius,
                .padding = .{ .x = 9, .y = 0, .w = 6, .h = 0 },
            });
            defer sb.deinit();
            dvui.icon(@src(), "search", entypo.magnifying_glass, .{}, .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 14, .h = 14 },
                .color_text = style.labelDim(),
            });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
            const te = style.textEntry(@src(), .{
                .text = .{ .buffer = &state.search_buf },
                .placeholder = "Search\u{2026}",
            }, .{
                .min_size_content = .{ .w = 200, .h = style.button_h },
                .gravity_y = 0.5,
                .tag = "lib-search",
                .background = false,
                .border = dvui.Rect.all(0),
            });
            te.deinit();
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });

        renderSyncSplitButton(frame);
        renderAddSplitButton(frame);

        // (account moved to the left icon rail — see renderIconRail.)
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // ---- bookmarks-pull progress strip (visible only while pulling
    // or while the post-pull message is fresh) ----
    renderBookmarksProgress(frame);

    // ---- body: sidebar + main ----
    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
    });
    defer body.deinit();

    sidebar(frame);

    _ = dvui.separator(@src(), .{
        .min_size_content = .{ .w = 1, .h = 1 },
    });

    var main_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
    });
    defer main_box.deinit();

    const query = state.searchSlice();
    renderVirtualizedList(frame, games, query);

    return true;
}

// ============================================================
//  library top-bar split buttons + bookmark progress
// ============================================================

/// Split-button "Sync" — primary action runs the cheap
/// latest-updates walker; a chevron next to it opens a floating
/// menu where the user can pick either flavor explicitly. Lives
/// inside the library top bar.
fn renderSyncSplitButton(frame: *Frame) void {
    const state = frame.state;

    const checking = state.pending_update_check != null;
    const importing = state.pending_bookmarks != null;
    const syncing = state.anyActiveSync() or state.sync_queue != null;
    const busy = checking or importing or syncing;

    var bar = dvui.menu(@src(), .horizontal, .{});
    defer bar.deinit();

    // ----- primary half: "Check for updates" (default = updates walker) -----
    const primary_label: []const u8 = if (checking) "Syncing\u{2026}" else "Sync";
    const primary_opts: dvui.Options = if (busy)
        .{ .style = .control, .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 } }
    else
        .{};
    if (components.iconButton(@src(), primary_label, entypo.cycle, primary_opts) and !busy) {
        actions.startUpdateCheck(frame);
    }

    // ----- chevron half: opens the scope menu -----
    if (dvui.menuItemIcon(@src(), "sync-scope", entypo.chevron_down, .{ .submenu = true }, .{
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .min_size_content = style.icon_size,
        .gravity_y = 0.5,
        .background = true,
        .style = .control,
        .corner_radius = style.corner_radius,
    })) |anchor| {
        var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Check for updates since last run", .{}, .{
            .expand = .horizontal,
        }) != null) {
            if (!busy) actions.startUpdateCheck(frame);
            bar.close();
        }

        if (dvui.menuItemLabel(@src(), "Sync all unsynced games", .{}, .{
            .expand = .horizontal,
        }) != null) {
            if (!busy) actions.startSyncAllUnsynced(frame);
            bar.close();
        }

        if (dvui.menuItemLabel(@src(), "Sync all games", .{}, .{
            .expand = .horizontal,
        }) != null) {
            if (!busy) actions.startSyncAll(frame);
            bar.close();
        }
    }
}

/// "Add" split-button mirroring `renderSyncSplitButton`. Primary
/// click jumps to the paste-import screen (the everyday "add some
/// thread URLs" flow). The chevron menu carries the bigger-batch
/// option: pulling every F95 bookmark in one go. Both end at the
/// same import worker — the split exists so the bookmarks pull
/// stops needing its own top-bar slot (one fewer permanent button)
/// without burying it from logged-in users who use it regularly.
fn renderAddSplitButton(frame: *Frame) void {
    const state = frame.state;
    const logged_in = state.login_status == .logged_in;
    const pulling = state.pending_bookmarks != null;

    var bar = dvui.menu(@src(), .horizontal, .{ .id_extra = 0xADD });
    defer bar.deinit();

    if (components.iconButton(@src(), "Add", entypo.plus, .{ .style = .highlight })) {
        state.screen = .import_urls;
    }

    if (dvui.menuItemIcon(@src(), "add-source", entypo.chevron_down, .{ .submenu = true }, .{
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .min_size_content = style.icon_size,
        .gravity_y = 0.5,
        .background = true,
        .style = .control,
        .corner_radius = style.corner_radius,
    })) |anchor| {
        var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Add by F95 URL / ID…", .{}, .{
            .expand = .horizontal,
        }) != null) {
            state.screen = .import_urls;
            bar.close();
        }

        if (dvui.menuItemLabel(@src(), "Import from a folder…", .{}, .{
            .expand = .horizontal,
        }) != null) {
            state.screen = .import_folder;
            bar.close();
        }

        const bookmarks_label: []const u8 = if (!logged_in)
            "Import all bookmarks (sign in to F95 first)"
        else if (pulling)
            "Pulling bookmarks\u{2026}"
        else
            "Import all bookmarks (F95)";
        if (dvui.menuItemLabel(@src(), bookmarks_label, .{}, .{
            .expand = .horizontal,
        }) != null) {
            if (logged_in and !pulling) actions.startPullBookmarks(frame);
            bar.close();
        }
    }
}

fn renderBookmarksProgress(frame: *Frame) void {
    const state = frame.state;
    const pending = state.pending_bookmarks != null;
    const has_msg = !state.bookmarks_msg.isEmpty();
    if (!pending and !has_msg) return;

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        .background = true,
        .style = .highlight,
    });
    defer bar.deinit();

    if (pending) {
        const cancelling: bool = blk: {
            const j = state.pending_bookmarks orelse break :blk false;
            break :blk j.cancel.load(.acquire);
        };

        const cur = state.bookmarks_progress_current;
        const tot = state.bookmarks_progress_total;
        var lbl_buf: [80]u8 = undefined;
        const label: []const u8 = if (cancelling)
            std.fmt.bufPrint(&lbl_buf, "Cancelling bookmarks pull\u{2026} (page {d})", .{cur}) catch "Cancelling\u{2026}"
        else if (tot > 0)
            std.fmt.bufPrint(&lbl_buf, "Pulling bookmarks: page {d}/{d}", .{ cur, tot }) catch "Pulling bookmarks…"
        else
            std.fmt.bufPrint(&lbl_buf, "Pulling bookmarks: page {d}…", .{cur}) catch "Pulling bookmarks…";
        dvui.labelNoFmt(@src(), label, .{}, .{ .gravity_y = 0.5 });

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });

        const pct: u32 = if (tot > 0) @intCast(@min(@divTrunc(@as(u64, cur) * 100, @as(u64, tot)), 100)) else 0;
        {
            var bar_outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .min_size_content = .{ .w = 240, .h = 14 },
                .border = style.border_thin,
                .corner_radius = .all(3),
                .color_border = style.borderColor(),
                .background = true,
                .color_fill = .{ .r = 0x16, .g = 0x0B, .b = 0x10 },
                .gravity_y = 0.5,
            });
            defer bar_outer.deinit();
            if (pct > 0) {
                const fill_w: f32 = (@as(f32, @floatFromInt(pct)) * 236.0) / 100.0;
                var bar_inner = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .min_size_content = .{
                        .w = @max(2.0, fill_w),
                        .h = 10,
                    },
                    .background = true,
                    .color_fill = tokens.toDvui(tokens.active.acc, dvui.Color),
                    .corner_radius = .all(2),
                    .gravity_y = 0.5,
                });
                bar_inner.deinit();
            }
        }

        if (tot > 0) {
            var pct_buf: [16]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "  {d}%", .{pct}) catch "";
            dvui.labelNoFmt(@src(), pct_str, .{}, .{ .gravity_y = 0.5 });
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        if (cancelling) {
            const dim: dvui.Options = .{
                .style = .control,
                .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 },
            };
            _ = components.iconButton(@src(), "Cancelling\u{2026}", entypo.cross, dim);
        } else {
            if (components.iconButton(@src(), "Cancel", entypo.cross, .{ .style = .err })) {
                actions.cancelBookmarks(frame);
            }
        }
    } else {
        dvui.labelNoFmt(@src(), state.bookmarksMsg(), .{}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (components.iconOnly(@src(), "dismiss", entypo.cross, .{})) {
            state.bookmarks_msg.clear();
        }
    }
}

// ============================================================
//  virtualized list / cards / sidebar
// ============================================================

/// List-row pitch (px) used for the virtual-scroll math. The grid
/// row pitch is computed dynamically per frame from `gridLayout()`
/// since cards now scale with available width.
const LIST_ROW_PITCH: f32 = 56.0;
/// Render this many extra rows above + below the viewport so scrolling
/// never reveals an unrendered row.
const OVERSCAN_ROWS: usize = 2;

/// Returns true when the game has a newer installed version than the
/// last-played version, or when the game has been installed but never
/// played. Both cases mean "there is something new the user hasn't seen".
fn hasUnplayedUpdate(g: *const library.Game, install_v: ?[]const u8) bool {
    const inst_v = install_v orelse return false;
    if (g.last_played_version) |lpv| {
        return version_mod.hasNewer(inst_v, lpv);
    }
    return true; // installed but never played → counts as unplayed update
}

/// True when the scraped latest F95 version is newer than what's installed —
/// i.e. a new release is available to download. Requires an install (you can't
/// "update" a game you don't have).
fn hasUpdateAvailable(g: *const library.Game, install_v: ?[]const u8) bool {
    const inst_v = install_v orelse return false;
    const latest = g.latest_version orelse return false;
    // hasNewer, not compare: F95 reformats version strings without shipping
    // a new build ("1.0" → "Final v1.0"); equivalence must win or every
    // completed game shows a phantom UPDATE after sync.
    return version_mod.hasNewer(latest, inst_v);
}

/// Virtualize the library scroll: only emit cards/rows for the
/// portion of the (filtered) list that's actually within the viewport
/// (plus an overscan band). Off-screen rows collapse to a single
/// spacer of equivalent height so the scrollbar tracks correctly.
fn renderVirtualizedList(frame: *Frame, games: []const library.Game, query: []const u8) void {
    const state = frame.state;
    actions.dbgResetCoverMisses(); // DIAG: count cover-cache misses this frame

    const layout = if (state.view == .grid) gridLayout() else GridLayout{
        .cols = 1,
        .card_w = 0,
        .card_h = 0,
        .cover_h = 0,
    };
    const cols: usize = layout.cols;
    const pitch: f32 = if (state.view == .grid)
        layout.card_h + CARD_CHROME_H
    else
        LIST_ROW_PITCH;

    // Snapshot which game indices pass the current filter. Mouse-
    // motion events wake dvui at ≥60 Hz, so doing substring scans
    // over every game's name/dev/description per frame turned every
    // mouse hover into a sustained >16ms render. We hash the filter
    // inputs and reuse the cached result when nothing changed —
    // mouse motion no longer triggers a refilter, only typing in the
    // search box / toggling a filter checkbox / adding a game does.
    const sig = filterSignature(state, query, games);
    if (sig != state.lib_filter_cache_sig) {
        // Label filter: build the union of games carrying any selected label
        // once per refilter (not per frame). null = no label gating.
        var label_set: ?std.AutoHashMap(u64, void) = null;
        defer if (label_set) |*s| s.deinit();
        if (state.label_filter_len > 0) {
            var set = std.AutoHashMap(u64, void).init(frame.lib.alloc);
            for (state.label_filter[0..state.label_filter_len]) |lid| {
                const gids = frame.lib.gamesForLabel(lid) catch continue;
                defer frame.lib.alloc.free(gids);
                for (gids) |gid| set.put(gid, {}) catch {};
            }
            label_set = set;
        }

        const now_s: i64 = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();
        var fresh: std.ArrayList(u32) = .empty;
        fresh.ensureTotalCapacity(frame.lib.alloc, games.len) catch {};
        for (games, 0..) |*g, i| {
            if (label_set) |s| {
                if (!s.contains(g.f95_thread_id)) continue;
            }
            if (cardVisible(state, g, query, frame.install_versions, now_s)) {
                fresh.append(frame.lib.alloc, @intCast(i)) catch break;
            }
        }
        if (state.lib_filter_cache_indices) |old| frame.lib.alloc.free(old);
        state.lib_filter_cache_indices = fresh.toOwnedSlice(frame.lib.alloc) catch null;
        state.lib_filter_cache_sig = sig;
    }
    const filtered: []const u32 = state.lib_filter_cache_indices orelse &.{};

    // List view = the dvui.grid table (sortable + resizable columns, its own
    // virtual scroller). Card/grid view keeps the manual virtualization below.
    if (state.view == .list) {
        renderListTable(frame, games, filtered);
        return;
    }
    // Kanban = one status column per DevStatus, each its own scroll.
    if (state.view == .kanban) {
        renderKanban(frame, games, filtered);
        return;
    }

    const total_visible: usize = filtered.len;

    const total_rows: usize = (total_visible + cols - 1) / cols;
    const virtual_h: f32 = @max(@as(f32, @floatFromInt(total_rows)) * pitch, 1.0);

    state.lib_scroll_info.vertical = .given;
    state.lib_scroll_info.virtual_size.h = virtual_h;

    var scroll = dvui.scrollArea(@src(), .{
        .scroll_info = &state.lib_scroll_info,
    }, .{ .expand = .both });
    defer scroll.deinit();

    const viewport_y: f32 = state.lib_scroll_info.viewport.y;
    const viewport_h: f32 = @max(state.lib_scroll_info.viewport.h, 1.0);

    const overscan_px: f32 = @as(f32, @floatFromInt(OVERSCAN_ROWS)) * pitch;
    const visible_top: f32 = @max(0.0, viewport_y - overscan_px);
    const visible_bot: f32 = viewport_y + viewport_h + overscan_px;

    const first_row: usize = @intFromFloat(@floor(visible_top / pitch));
    const last_row_unclamped: usize = @intFromFloat(@ceil(visible_bot / pitch));
    const last_row: usize = @min(total_rows, last_row_unclamped);

    const start_idx: usize = first_row * cols;
    const end_idx: usize = @min(total_visible, last_row * cols);

    const top_spacer_h: f32 = @as(f32, @floatFromInt(first_row)) * pitch;
    const remaining_rows: usize = if (last_row < total_rows) total_rows - last_row else 0;
    const bot_spacer_h: f32 = @as(f32, @floatFromInt(remaining_rows)) * pitch;

    if (top_spacer_h > 0.5) {
        _ = dvui.spacer(@src(), .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = top_spacer_h },
        });
    }

    switch (state.view) {
        .grid => renderGridWindow(frame, games, filtered, layout, start_idx, end_idx),
        .list => renderListWindow(frame, games, filtered, start_idx, end_idx),
        .kanban => unreachable, // handled by the early return above
    }

    if (bot_spacer_h > 0.5) {
        _ = dvui.spacer(@src(), .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = bot_spacer_h },
        });
    }
}

/// Small dim uppercase sidebar group header (STATUS / UPDATES / ENGINE / TAGS).
fn sideGroup(label: []const u8) void {
    const key = @intFromPtr(label.ptr);
    _ = dvui.spacer(@src(), .{ .id_extra = key, .min_size_content = .{ .w = 1, .h = 12 } });
    const body = dvui.Font.theme(.body);
    dvui.labelNoFmt(@src(), label, .{}, .{
        .id_extra = key,
        .color_text = style.labelDim(),
        .font = body.withSize(body.size * 0.80),
    });
    _ = dvui.spacer(@src(), .{ .id_extra = key, .min_size_content = .{ .w = 1, .h = 4 } });
}

/// Flat clickable filter row (Design-B sidebar): optional colored status dot +
/// label on the left, right-aligned count. Active = teal wash + teal text.
/// Returns true the frame it's clicked. `id` must be unique within the sidebar.
fn filterRow(id: u32, label: []const u8, count: u32, active: bool, dot_color: ?dvui.Color, tag: ?[]const u8) bool {
    const t = tokens.active;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .tag = tag,
        .expand = .horizontal,
        .background = active,
        .color_fill = tokens.toDvui(t.acc_wash, dvui.Color),
        .corner_radius = dvui.Rect.all(tokens.r),
        .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
    });
    defer row.deinit();
    if (dot_color) |dc| {
        var d = dvui.box(@src(), .{}, .{
            .background = true,
            .color_fill = dc,
            .corner_radius = dvui.Rect.all(3),
            .min_size_content = .{ .w = 7, .h = 7 },
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        });
        d.deinit();
    }
    dvui.labelNoFmt(@src(), label, .{}, .{
        .gravity_y = 0.5,
        .color_text = tokens.toDvui(if (active) t.acc else t.ink2, dvui.Color),
    });
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (count > 0) {
        var cnt_buf: [16]u8 = undefined;
        const cs = std.fmt.bufPrint(&cnt_buf, "{d}", .{count}) catch "";
        dvui.labelNoFmt(@src(), cs, .{}, .{ .gravity_y = 0.5, .color_text = style.labelDim() });
    }
    return dvui.clicked(row.data(), .{});
}

fn sidebar(frame: *Frame) void {
    const state = frame.state;

    // Per-axis counts for the flat filter lists (Design-B), computed once.
    var eng_counts = std.EnumArray(library.Engine, u32).initFill(0);
    var ds_counts = std.EnumArray(library.DevStatus, u32).initFill(0);
    for (frame.games) |g| {
        eng_counts.getPtr(g.engine).* += 1;
        ds_counts.getPtr(g.dev_status).* += 1;
    }
    var side = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 200, .h = 100 },
        .padding = .{ .x = 12, .y = 12, .w = 12, .h = 12 },
        .background = true,
        .expand = .vertical,
    });
    defer side.deinit();

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .padding = .{ .x = 0, .y = 6, .w = 0, .h = 0 },
    });
    defer scroll.deinit();

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer row.deinit();
        dvui.label(@src(), "Sync:", .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 80, .h = 1 } });
        const sync_labels = &[_][]const u8{ "All", "Synced", "Unsynced" };
        var picked: usize = @intFromEnum(state.filters.sync_state);
        if (style.dropdown(@src(), sync_labels, .{ .choice = &picked }, .{}, .{ .tag = "filter-sync" })) {
            state.filters.sync_state = @enumFromInt(picked);
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 0xF11 });
        defer row.deinit();
        dvui.label(@src(), "Installed:", .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 80, .h = 1 } });
        const inst_labels = &[_][]const u8{ "All", "Installed", "Not installed" };
        var picked: usize = @intFromEnum(state.filters.installed);
        if (style.dropdown(@src(), inst_labels, .{ .choice = &picked }, .{}, .{ .id_extra = 0xF11 })) {
            state.filters.installed = @enumFromInt(picked);
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 0xF22 });
        defer row.deinit();
        _ = dvui.checkbox(@src(), &state.filter_unplayed_updates, "Unplayed updates", .{ .tag = "filter-unplayed" });
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 0xF23 });
        defer row.deinit();
        _ = dvui.checkbox(@src(), &state.filter_status_changed, "Status changed", .{});
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 0xF24 });
        defer row.deinit();
        _ = dvui.checkbox(@src(), &state.filter_update_available, "Update available", .{});
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        sideGroup("ENGINE");
        const eng = &state.filters.engine;
        const EngSpec = struct { e: library.Engine, l: []const u8 };
        const eng_specs = [_]EngSpec{
            .{ .e = .renpy, .l = "Ren'Py" },
            .{ .e = .rpgm_mv, .l = "RPGM MV" },
            .{ .e = .rpgm_mz, .l = "RPGM MZ" },
            .{ .e = .rpgm_vx, .l = "RPGM VX/Ace" },
            .{ .e = .unity, .l = "Unity" },
            .{ .e = .unreal, .l = "Unreal" },
            .{ .e = .html, .l = "HTML" },
            .{ .e = .flash, .l = "Flash" },
            .{ .e = .java, .l = "Java" },
            .{ .e = .wolf_rpg, .l = "Wolf RPG" },
            .{ .e = .qsp, .l = "QSP" },
            .{ .e = .tyranobuilder, .l = "TyranoBuilder" },
            .{ .e = .twine, .l = "Twine" },
            .{ .e = .other, .l = "Other" },
            .{ .e = .unknown, .l = "Unknown" },
        };
        var any = false;
        inline for (eng_specs) |s| {
            const cnt = eng_counts.get(s.e);
            const sel = eng.contains(s.e);
            if (cnt > 0 or sel) {
                any = true;
                const tag: ?[]const u8 = if (s.e == .renpy) "filter-eng-renpy" else null;
                if (filterRow(0x100 + @as(u32, @intFromEnum(s.e)), s.l, cnt, sel, null, tag)) {
                    if (sel) eng.remove(s.e) else eng.insert(s.e);
                }
            }
        }
        if (!any) dvui.labelNoFmt(@src(), "  (no games yet)", .{}, .{ .color_text = style.labelDim() });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        const st = &state.filters.status;
        var lbl_buf: [48]u8 = undefined;
        const lbl = if (st.count() == 0)
            @as([]const u8, "Status")
        else
            std.fmt.bufPrint(&lbl_buf, "Status ({d})", .{st.count()}) catch "Status";
        if (dvui.expander(@src(), lbl, .{}, .{ .expand = .horizontal })) {
            enumCheckbox(library.CompletionStatus, st, .not_started, "Not started");
            enumCheckbox(library.CompletionStatus, st, .in_queue, "In queue");
            enumCheckbox(library.CompletionStatus, st, .in_progress, "In progress");
            enumCheckbox(library.CompletionStatus, st, .completed, "Completed");
            enumCheckbox(library.CompletionStatus, st, .replaying, "Replaying");
            enumCheckbox(library.CompletionStatus, st, .abandoned, "Abandoned");
            enumCheckbox(library.CompletionStatus, st, .waiting_for_update, "Waiting for update");
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        var lbl_buf: [48]u8 = undefined;
        const lbl = if (state.filters.min_rating) |r|
            std.fmt.bufPrint(&lbl_buf, "Min rating ({d:.1}+)", .{r}) catch "Min rating"
        else
            @as([]const u8, "Min rating");
        if (dvui.expander(@src(), lbl, .{}, .{ .expand = .horizontal })) {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hbox.deinit();
            if (style.button(@src(), "Any", .{}, .{})) state.filters.min_rating = null;
            if (style.button(@src(), "3+", .{}, .{})) state.filters.min_rating = 3.0;
            if (style.button(@src(), "4+", .{}, .{})) state.filters.min_rating = 4.0;
            if (style.button(@src(), "4.5+", .{}, .{})) state.filters.min_rating = 4.5;
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        const dev_q = state.filters.developerSlice();
        var lbl_buf: [48]u8 = undefined;
        const lbl = if (dev_q.len > 0)
            std.fmt.bufPrint(&lbl_buf, "Developer ({s})", .{dev_q}) catch "Developer"
        else
            @as([]const u8, "Developer");
        if (dvui.expander(@src(), lbl, .{}, .{ .expand = .horizontal })) {
            const te = style.textEntry(@src(), .{
                .text = .{ .buffer = &state.filters.developer_buf },
                .placeholder = "filter by dev…",
            }, .{ .expand = .horizontal });
            te.deinit();
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        sideGroup("STATUS");
        const ds = &state.filters.dev_status;
        // "All" clears the dev-status filter (no game-state restriction).
        if (filterRow(0x200, "All", @intCast(frame.games.len), ds.count() == 0, null, "filter-status-all")) {
            ds.* = @TypeOf(ds.*).initEmpty();
        }
        const DsSpec = struct { s: library.DevStatus, l: []const u8 };
        const ds_specs = [_]DsSpec{
            .{ .s = .in_progress, .l = "Ongoing" },
            .{ .s = .completed, .l = "Completed" },
            .{ .s = .on_hold, .l = "On hold" },
            .{ .s = .abandoned, .l = "Abandoned" },
            .{ .s = .orphaned, .l = "Orphaned" },
            .{ .s = .unknown, .l = "Unknown" },
        };
        inline for (ds_specs) |s| {
            const cnt = ds_counts.get(s.s);
            const sel = ds.contains(s.s);
            if (cnt > 0 or sel) {
                if (filterRow(0x210 + @as(u32, @intFromEnum(s.s)), s.l, cnt, sel, components.devStatusColor(s.s), null)) {
                    if (sel) ds.remove(s.s) else ds.insert(s.s);
                }
            }
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        const cs = &state.filters.censored;
        var lbl_buf: [48]u8 = undefined;
        const lbl = if (cs.count() == 0)
            @as([]const u8, "Censored")
        else
            std.fmt.bufPrint(&lbl_buf, "Censored ({d})", .{cs.count()}) catch "Censored";
        if (dvui.expander(@src(), lbl, .{}, .{ .expand = .horizontal })) {
            enumCheckbox(library.CensoredState, cs, .no, "No");
            enumCheckbox(library.CensoredState, cs, .yes, "Yes");
            enumCheckbox(library.CensoredState, cs, .partial, "Partial");
            enumCheckbox(library.CensoredState, cs, .unknown, "Unknown");
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        const inc_q = state.filters.tagIncludeSlice();
        const exc_q = state.filters.tagExcludeSlice();
        const inc_count = tagListCount(inc_q);
        const exc_count = tagListCount(exc_q);
        var lbl_buf: [64]u8 = undefined;
        const lbl: []const u8 = if (inc_count > 0 and exc_count > 0)
            std.fmt.bufPrint(&lbl_buf, "Tags (+{d} / −{d})", .{ inc_count, exc_count }) catch "Tags"
        else if (inc_count > 0)
            std.fmt.bufPrint(&lbl_buf, "Tags (+{d})", .{inc_count}) catch "Tags"
        else if (exc_count > 0)
            std.fmt.bufPrint(&lbl_buf, "Tags (−{d})", .{exc_count}) catch "Tags"
        else
            @as([]const u8, "Tags");
        if (dvui.expander(@src(), lbl, .{}, .{ .expand = .horizontal })) {
            if (state.tags_master.len == 0) {
                dvui.label(
                    @src(),
                    "Master tag list not refreshed yet. Open Settings → Library → Tags → Refresh.",
                    .{},
                    .{ .color_text = style.labelDim() },
                );
            } else {
                renderTagCheckboxFilter(state);
            }
        }
    }

    // ----- user labels filter -----
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    {
        const labels_opt: ?[]library.UserLabel = frame.lib.listLabels() catch null;
        defer if (labels_opt) |l| frame.lib.freeLabels(l);
        const labels: []const library.UserLabel = labels_opt orelse &.{};
        if (labels.len > 0) {
            var lbl_buf: [48]u8 = undefined;
            const hdr = if (state.label_filter_len == 0)
                @as([]const u8, "Labels")
            else
                std.fmt.bufPrint(&lbl_buf, "Labels ({d})", .{state.label_filter_len}) catch "Labels";
            if (dvui.expander(@src(), hdr, .{}, .{ .expand = .horizontal })) {
                for (labels) |l| {
                    var checked = state.labelFilterActive(l.id);
                    if (dvui.checkbox(@src(), &checked, l.name, .{ .id_extra = @as(u64, @bitCast(l.id)) })) {
                        state.toggleLabelFilter(l.id);
                    }
                }
            }
        }
    }
}

fn tagListCount(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (t.len > 0) n += 1;
    }
    return n;
}

fn tagListContains(buf: []const u8, tag: []const u8) bool {
    var it = std.mem.splitScalar(u8, buf, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (t.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(t, tag)) return true;
    }
    return false;
}

fn addTagToBuf(buf: []u8, tag: []const u8) void {
    if (tagListContains(sliceUntilNul(buf), tag)) return;
    const cur_len = sliceUntilNul(buf).len;
    const sep_len: usize = if (cur_len == 0) 0 else 2; // ", "
    if (cur_len + sep_len + tag.len + 1 > buf.len) return;
    var write_at = cur_len;
    if (sep_len > 0) {
        buf[write_at] = ',';
        buf[write_at + 1] = ' ';
        write_at += 2;
    }
    @memcpy(buf[write_at .. write_at + tag.len], tag);
    write_at += tag.len;
    @memset(buf[write_at..], 0);
}

fn removeTagFromBuf(buf: []u8, tag: []const u8) void {
    var scratch: [256]u8 = undefined;
    var n: usize = 0;
    const cur = sliceUntilNul(buf);
    var it = std.mem.splitScalar(u8, cur, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (t.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(t, tag)) continue;
        if (n > 0) {
            if (n + 2 > scratch.len) break;
            scratch[n] = ',';
            scratch[n + 1] = ' ';
            n += 2;
        }
        if (n + t.len > scratch.len) break;
        @memcpy(scratch[n .. n + t.len], t);
        n += t.len;
    }
    if (n > buf.len) n = buf.len;
    @memcpy(buf[0..n], scratch[0..n]);
    @memset(buf[n..], 0);
}

fn sliceUntilNul(buf: []const u8) []const u8 {
    var n: usize = 0;
    while (n < buf.len and buf[n] != 0) : (n += 1) {}
    return buf[0..n];
}

fn renderTagCheckboxFilter(state: *State) void {
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.icon(@src(), "search", entypo.magnifying_glass, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 12, .h = 12 },
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.tags_filter_buf },
            .placeholder = "filter tags…",
        }, .{ .expand = .horizontal, .gravity_y = 0.5 });
        te.deinit();
    }

    const filter = sliceUntilNul(&state.tags_filter_buf);

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    dvui.label(
        @src(),
        "Click to cycle: off → include → exclude → off",
        .{},
        .{ .color_text = style.labelDim() },
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });

    const HARD_CAP: usize = 200;
    var rendered: usize = 0;

    for (state.tags_master, 0..) |tag, i| {
        if (filter.len > 0 and !types.asciiContainsIgnoreCase(tag, filter)) continue;
        if (rendered >= HARD_CAP) break;
        rendered += 1;

        const include_buf: []const u8 = sliceUntilNul(&state.filters.tag_include_buf);
        const exclude_buf: []const u8 = sliceUntilNul(&state.filters.tag_exclude_buf);
        const in_include = tagListContains(include_buf, tag);
        const in_exclude = tagListContains(exclude_buf, tag);

        const marker: []const u8 = if (in_include) "[+] " else if (in_exclude) "[-] " else "[ ] ";
        const text_color: dvui.Color = if (in_include)
            tokens.toDvui(tokens.active.ok, dvui.Color) // include
        else if (in_exclude)
            tokens.toDvui(tokens.active.danger, dvui.Color) // exclude
        else
            tokens.toDvui(tokens.active.ink3, dvui.Color);

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        });
        defer row.deinit();

        var line_buf: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}", .{ marker, tag }) catch tag;
        if (style.button(@src(), line, .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .gravity_x = 0,
            .style = .control,
            .color_text = text_color,
        })) {
            if (in_include) {
                removeTagFromBuf(&state.filters.tag_include_buf, tag);
                addTagToBuf(&state.filters.tag_exclude_buf, tag);
            } else if (in_exclude) {
                removeTagFromBuf(&state.filters.tag_exclude_buf, tag);
            } else {
                addTagToBuf(&state.filters.tag_include_buf, tag);
            }
        }
    }

    if (rendered >= HARD_CAP) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
        var more_buf: [80]u8 = undefined;
        const more = std.fmt.bufPrint(&more_buf, "showing first {d} matches — narrow with the filter above", .{HARD_CAP}) catch "…";
        dvui.labelNoFmt(@src(), more, .{}, .{
            .color_text = style.labelDim(),
        });
    }

    if (tagListCount(sliceUntilNul(&state.filters.tag_include_buf)) > 0 or
        tagListCount(sliceUntilNul(&state.filters.tag_exclude_buf)) > 0)
    {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        if (style.button(@src(), "Clear tag filters", .{}, .{ .expand = .horizontal })) {
            @memset(&state.filters.tag_include_buf, 0);
            @memset(&state.filters.tag_exclude_buf, 0);
        }
    }
}

/// Render a checkbox bound to a single `std.EnumSet(E)` entry. The
/// previous filter UI took `*bool` pointers into a hand-rolled mask
/// struct; the EnumSet move requires this bridge because dvui's
/// `checkbox` API takes `*bool`. Local var → call dvui → diff against
/// the set → insert/remove. Zero allocations.
fn enumCheckbox(comptime E: type, set: *std.EnumSet(E), comptime tag: E, label: []const u8) void {
    var checked = set.contains(tag);
    // Stable comptime tag so headless tests can expectVisible/click a child.
    _ = dvui.checkbox(@src(), &checked, label, .{ .id_extra = @intFromEnum(tag), .tag = "flt-" ++ @tagName(tag) });
    if (checked) set.insert(tag) else set.remove(tag);
}

/// Card width bounds (excluding the card's own padding+border+margin).
/// Cards stretch freely between MIN and MAX; column count is the
/// smallest N such that `usable_w / N <= MAX_CARD_W + chrome`. When
/// `usable_w` would push cards past MAX, we add another column and
/// all cards drop back toward MIN.
const MIN_CARD_W: f32 = 240.0;
const MAX_CARD_W: f32 = 360.0;

/// Per-card chrome — padding (4 each side) + border (1 each side) +
/// margin (3 each side) — totals 16 px horizontally. dvui's outer
/// footprint per child = `min_size_content.w + chrome`, so the
/// column-count math has to subtract this from the available width
/// before dividing.
///
/// Keep this in sync with renderCard's box options. If you change
/// padding/border/margin there, change this too — otherwise cards
/// will overflow the row by `cols * delta` pixels and dvui shrinks
/// the rightmost card to fit (looks like "right column is smaller").
const CARD_CHROME_W: f32 = 4 + 4 + 1 + 1 + 3 + 3;
const CARD_CHROME_H: f32 = 4 + 4 + 1 + 1 + 3 + 3;

const NON_GRID_WIDTH: f32 = 240.0;

/// The grid lives inside a scroll area whose vertical scrollbar claims this
/// much width (dvui ScrollBarWidget default ~10px + a little breathing room).
/// `gridLayout` must subtract it or the row of fixed-width cards is sized to
/// the full width and the rightmost card gets clipped by the scrollbar gutter.
const GRID_SCROLLBAR_W: f32 = 14.0;

const COVER_H_PER_W: f32 = 120.0 / 280.0;

const CARD_TEXT_CHROME_H: f32 = 50.0;

const GridLayout = struct {
    cols: usize,
    card_w: f32,
    card_h: f32,
    cover_h: f32,
};

fn gridLayout() GridLayout {
    const win_w = dvui.windowRect().w;
    const usable = @max(win_w - NON_GRID_WIDTH - GRID_SCROLLBAR_W, MIN_CARD_W + CARD_CHROME_W);

    const slot_w_max = MAX_CARD_W + CARD_CHROME_W;
    var cols: usize = @intFromFloat(@ceil(usable / slot_w_max));
    if (cols < 1) cols = 1;
    if (cols > 12) cols = 12;

    const slot_w = usable / @as(f32, @floatFromInt(cols));
    var card_w = slot_w - CARD_CHROME_W;
    if (card_w < MIN_CARD_W) card_w = MIN_CARD_W;
    if (card_w > MAX_CARD_W) card_w = MAX_CARD_W;
    const cover_h = card_w * COVER_H_PER_W;
    const card_h = cover_h + CARD_TEXT_CHROME_H;
    return .{ .cols = cols, .card_w = card_w, .card_h = card_h, .cover_h = cover_h };
}

fn renderGridWindow(
    frame: *Frame,
    games: []const library.Game,
    filtered: []const u32,
    layout: GridLayout,
    start_idx: usize,
    end_idx: usize,
) void {
    const cols = layout.cols;
    var row_box: ?*dvui.BoxWidget = null;
    defer if (row_box) |rb| rb.deinit();

    var my_idx = start_idx;
    while (my_idx < end_idx and my_idx < filtered.len) : (my_idx += 1) {
        const game_i: usize = filtered[my_idx];
        const g = &games[game_i];

        const col = my_idx % cols;
        if (col == 0) {
            if (row_box) |rb| rb.deinit();
            row_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = my_idx / cols,
                .expand = .horizontal,
            });
        }
        renderCard(frame, g, layout);
    }
}

// ----- kanban view (one status column each, independently scrolled) -----

/// Width of a single kanban status column.
const KANBAN_COL_W: f32 = 244.0;

/// Card layout used inside a kanban column — full-width cards stacked
/// vertically (reuses renderCard, so the cover/title/meta match grid view).
fn kanbanCardLayout() GridLayout {
    const card_w: f32 = KANBAN_COL_W - 24.0; // column padding + scrollbar gutter
    const cover_h = card_w * COVER_H_PER_W;
    return .{ .cols = 1, .card_w = card_w, .card_h = cover_h + CARD_TEXT_CHROME_H, .cover_h = cover_h };
}

/// Kanban groups by the *player's* progress (CompletionStatus), not the
/// game's dev state. Columns left→right follow a natural backlog→done flow.
const KANBAN_ORDER = [_]library.CompletionStatus{
    .not_started, .in_queue, .in_progress, .replaying, .waiting_for_update, .completed, .abandoned,
};

fn renderKanban(frame: *Frame, games: []const library.Game, filtered: []const u32) void {
    // Horizontal scroll across columns; each column owns its vertical scroll
    // (so columns scroll independently and to their own content height).
    var hscroll = dvui.scrollArea(@src(), .{
        .horizontal = .auto,
        .vertical = .none,
    }, .{ .expand = .both });
    defer hscroll.deinit();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .vertical });
    defer row.deinit();

    const layout = kanbanCardLayout();
    for (KANBAN_ORDER) |st| {
        renderKanbanColumn(frame, games, filtered, st, layout);
    }
}

fn renderKanbanColumn(
    frame: *Frame,
    games: []const library.Game,
    filtered: []const u32,
    status: library.CompletionStatus,
    layout: GridLayout,
) void {
    const state = frame.state;
    const sidx: usize = @intFromEnum(status);

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = sidx,
        .min_size_content = .{ .w = KANBAN_COL_W, .h = 1 },
        .max_size_content = .{ .w = KANBAN_COL_W, .h = 0 },
        .expand = .vertical,
        .margin = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
    });
    defer col.deinit();

    // Count games in this column (for the header badge).
    var count: usize = 0;
    for (filtered) |gi| {
        if (games[gi].completion_status == status) count += 1;
    }

    // Header: status chip + count.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = sidx,
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });
        defer hdr.deinit();

        const fill = components.completionStatusColor(status);
        comp.chip(@src(), .{
            .label = components.completionStatusShortLabel(status),
            .fill = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
            .text = .{ .r = 0xff, .g = 0xff, .b = 0xff },
            .border = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
            .scale = 0.85,
        }, .{
            .gravity_y = 0.5,
            .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
            .corner_radius = .all(3),
        });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        var cbuf: [16]u8 = undefined;
        const cstr = std.fmt.bufPrint(&cbuf, "{d}", .{count}) catch "?";
        dvui.labelNoFmt(@src(), cstr, .{}, .{
            .gravity_y = 0.5,
            .color_text = style.labelDim(),
        });
    }

    // Body: each column scrolls on its own AND is virtualized like the grid
    // view — otherwise kanban over the whole library renders thousands of
    // cards (with cover decodes) per frame. We render only the on-screen
    // window plus top/bottom spacers that reserve the full scroll height.
    const pitch: f32 = layout.card_h + CARD_CHROME_H;
    const virtual_h: f32 = @max(@as(f32, @floatFromInt(count)) * pitch, 1.0);
    state.lib_kanban_scroll[sidx].vertical = .given;
    state.lib_kanban_scroll[sidx].virtual_size.h = virtual_h;

    var sc = dvui.scrollArea(@src(), .{
        .scroll_info = &state.lib_kanban_scroll[sidx],
    }, .{
        .expand = .both,
        .background = true,
        .corner_radius = .all(6),
    });
    defer sc.deinit();

    const vp_y: f32 = state.lib_kanban_scroll[sidx].viewport.y;
    const vp_h: f32 = @max(state.lib_kanban_scroll[sidx].viewport.h, 1.0);
    const overscan_px: f32 = @as(f32, @floatFromInt(OVERSCAN_ROWS)) * pitch;
    const visible_top: f32 = @max(0.0, vp_y - overscan_px);
    const visible_bot: f32 = vp_y + vp_h + overscan_px;
    const start_idx: usize = @intFromFloat(@floor(visible_top / pitch));
    const end_idx: usize = @min(count, @as(usize, @intFromFloat(@ceil(visible_bot / pitch))));

    const top_h: f32 = @as(f32, @floatFromInt(@min(start_idx, count))) * pitch;
    const rem: usize = if (end_idx < count) count - end_idx else 0;
    const bot_h: f32 = @as(f32, @floatFromInt(rem)) * pitch;

    if (top_h > 0.5) _ = dvui.spacer(@src(), .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 1, .h = top_h },
    });

    // Walk the filtered set, counting matches; render only those whose
    // match-index falls in the on-screen window.
    var matched: usize = 0;
    for (filtered) |gi| {
        const g = &games[gi];
        if (g.completion_status != status) continue;
        defer matched += 1;
        if (matched < start_idx or matched >= end_idx) continue;
        renderCard(frame, g, layout);
    }

    if (bot_h > 0.5) _ = dvui.spacer(@src(), .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 1, .h = bot_h },
    });
}

// ----- dvui.grid-based list view (sortable / resizable columns) -----

fn headerDir(state: anytype, sc: state_mod.SortColumn) dvui.GridWidget.SortDirection {
    if (state.sort_column != sc) return .unsorted;
    return if (state.sort_dir == .asc) .ascending else .descending;
}

fn applyHeaderSort(state: anytype, sc: state_mod.SortColumn, d: dvui.GridWidget.SortDirection) void {
    state.sort_column = sc;
    state.sort_dir = if (d == .descending) .desc else .asc;
}

fn colResize(state: anytype, col: usize) dvui.GridWidget.HeaderResizeWidget.InitOptions {
    return .{ .sizes = &state.lib_col_widths, .num = col, .min_size = 50, .max_size = 800 };
}

/// Open the detail screen for a game. Called from every list-table cell so
/// the whole row is clickable, not just the Name cell.
fn goDetail(state: anytype, g: *const library.Game) void {
    state.screen = .detail;
    state.selected_thread = g.f95_thread_id;
}

/// Identity-keyed click surface filling a list-table cell. Grid cells are
/// keyed by (col,row) POSITION, so a press captured on row N resolves
/// against whatever game sits at N when the button is released — if a
/// background sync bumps the filter cache mid-click, the click opens the
/// WRONG game (field report). Keying the click surface by thread id makes
/// a mid-reorder release match nothing: a harmless no-op instead.
fn rowHit(src: std.builtin.SourceLocation, thread_id: u64) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = thread_id,
        .expand = .both,
    });
}

fn renderListTable(frame: *Frame, games: []const library.Game, filtered: []const u32) void {
    const state = frame.state;
    const now_s: i64 = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();

    // `.given` must be set on the scroll-info STRUCT: GridWidget only copies
    // scroll_opts.vertical onto its body scroll-info when no scroll_info is
    // passed. With `.given`, the body honors the virtual_size the
    // VirtualScroller computes from the full row count (full-length scrollbar).
    state.lib_grid_scroll.vertical = .given;
    var grid = dvui.grid(@src(), .colWidths(&state.lib_col_widths), .{
        .scroll_opts = .{ .scroll_info = &state.lib_grid_scroll, .vertical_bar = .show },
    }, .{ .expand = .both, .background = true });
    defer grid.deinit();

    const scroller = dvui.GridWidget.VirtualScroller.init(grid, .{
        .total_rows = filtered.len,
        .scroll_info = &state.lib_grid_scroll,
    });
    const first = scroller.startRow();
    const last = scroller.endRow();

    // headers: Name + Rating + Updated are sortable (map to the existing
    // SortColumn); Engine + Version are display-only. All resizable.
    {
        var d = headerDir(state, .name);
        if (dvui.gridHeadingSortable(@src(), grid, 0, "Name", &d, colResize(state, 0), .{})) applyHeaderSort(state, .name, d);
    }
    dvui.gridHeading(@src(), grid, 1, "Engine", colResize(state, 1), .{});
    {
        var d = headerDir(state, .rating);
        if (dvui.gridHeadingSortable(@src(), grid, 2, "Rating", &d, colResize(state, 2), .{})) applyHeaderSort(state, .rating, d);
    }
    dvui.gridHeading(@src(), grid, 3, "Version", colResize(state, 3), .{});
    {
        var d = headerDir(state, .last_updated);
        if (dvui.gridHeadingSortable(@src(), grid, 4, "Updated", &d, colResize(state, 4), .{})) applyHeaderSort(state, .last_updated, d);
    }
    dvui.gridHeading(@src(), grid, 5, "Played", colResize(state, 5), .{});
    dvui.gridHeading(@src(), grid, 6, "", colResize(state, 6), .{});

    var row = first;
    while (row < last and row < filtered.len) : (row += 1) {
        const g = &games[filtered[row]];
        var cell_num = dvui.GridWidget.Cell.colRow(0, row);

        // Name: progress dot + name + NEW chip (whole row clickable).
        {
            defer cell_num.col_num += 1;
            var cell = grid.bodyCell(@src(), cell_num, .{});
            defer cell.deinit();
            {
                // Per-game tag ("row-<thread_id>") for the GUI driver
                // (mirrors "card-<id>").
                var row_tag_buf: [32]u8 = undefined;
                const row_tag = std.fmt.bufPrint(&row_tag_buf, "row-{d}", .{g.f95_thread_id}) catch "row";
                // Click surface keyed by the game's identity, NOT the grid
                // cell: bodyCell ids are (col,row) positional, so a press
                // captured on row N resolves against whatever game sits at
                // N when the button is released — a background sync bumping
                // the filter cache mid-click made clicks open the WRONG
                // game (field report). With the game id in the widget id, a
                // mid-reorder release matches nothing: harmless no-op.
                var nrow = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = g.f95_thread_id,
                    .expand = .both,
                    .gravity_y = 0.5,
                    .tag = row_tag,
                });
                defer nrow.deinit();

                // Design-B list rows lead with a small cover thumbnail.
                if (actions.coverBytes(frame, g.f95_thread_id)) |cb| {
                    _ = dvui.image(@src(), .{ .source = .{ .imageFile = .{ .bytes = cb, .name = "list-cover" } }, .shrink = .ratio }, .{
                        .id_extra = g.f95_thread_id,
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .min_size_content = .{ .w = 38, .h = 50 },
                        .max_size_content = .{ .w = 38, .h = 50 },
                        .margin = .{ .x = 0, .y = 2, .w = 9, .h = 2 },
                        .corner_radius = .all(3),
                    });
                } else {
                    var ph = dvui.box(@src(), .{}, .{
                        .id_extra = g.f95_thread_id,
                        .gravity_y = 0.5,
                        .min_size_content = .{ .w = 38, .h = 50 },
                        .max_size_content = .{ .w = 38, .h = 50 },
                        .margin = .{ .x = 0, .y = 2, .w = 9, .h = 2 },
                        .background = true,
                        .color_fill = style.cardFill(),
                        .corner_radius = .all(3),
                        .border = style.border_thin,
                        .color_border = style.borderColor(),
                    });
                    ph.deinit();
                }

                const sc = components.completionStatusColor(g.completion_status);
                comp.dot(@src(), .{ .r = sc.r, .g = sc.g, .b = sc.b, .a = sc.a }, .{
                    .id_extra = g.f95_thread_id,
                    .gravity_y = 0.5,
                    .margin = .{ .x = 0, .y = 0, .w = 7, .h = 0 },
                });
                dvui.labelNoFmt(@src(), g.name, .{}, .{ .gravity_y = 0.5 });

                const inst_v: ?[]const u8 = if (frame.install_versions) |m| m.get(g.f95_thread_id) else null;
                if (hasUnplayedUpdate(g, inst_v)) {
                    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 5, .h = 1 } });
                    const t = tokens.active;
                    comp.chip(@src(), .{
                        .label = "NEW",
                        .fill = t.bg2,
                        .text = t.accent2,
                        .border = t.line,
                        .scale = 0.7,
                    }, .{
                        .id_extra = g.f95_thread_id ^ 0xBB22,
                        .gravity_y = 0.5,
                        .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
                        .corner_radius = .all(2),
                    });
                }
                if (statusRecentlyChanged(g, now_s)) {
                    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 5, .h = 1 } });
                    comp.chip(@src(), .{
                        .label = "STATUS",
                        .fill = .{ .r = 0xC0, .g = 0x84, .b = 0x1F, .a = 0xff }, // amber
                        .text = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
                        .border = .{ .r = 0xC0, .g = 0x84, .b = 0x1F, .a = 0xff },
                        .scale = 0.7,
                    }, .{
                        .id_extra = g.f95_thread_id ^ 0x57A7,
                        .gravity_y = 0.5,
                        .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
                        .corner_radius = .all(2),
                    });
                }
                if (hasUpdateAvailable(g, inst_v)) {
                    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 5, .h = 1 } });
                    comp.chip(@src(), .{
                        .label = "UPDATE",
                        .fill = .{ .r = 0x1F, .g = 0x9E, .b = 0xC0, .a = 0xff }, // cyan
                        .text = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
                        .border = .{ .r = 0x1F, .g = 0x9E, .b = 0xC0, .a = 0xff },
                        .scale = 0.7,
                    }, .{
                        .id_extra = g.f95_thread_id ^ 0x09DA,
                        .gravity_y = 0.5,
                        .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
                        .corner_radius = .all(2),
                    });
                }
                if (dvui.clicked(nrow.data(), .{})) goDetail(state, g);
            }
        }
        // Engine
        {
            defer cell_num.col_num += 1;
            var cell = grid.bodyCell(@src(), cell_num, .{});
            defer cell.deinit();
            var hit = rowHit(@src(), g.f95_thread_id);
            defer hit.deinit();
            if (g.engine != .unknown) {
                const fill = components.engineBadgeColor(g.engine);
                comp.chip(@src(), .{
                    .label = components.engineShortLabel(g.engine),
                    .fill = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
                    .text = .{ .r = 0xff, .g = 0xff, .b = 0xff },
                    .border = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
                    .scale = 0.75,
                }, .{
                    .expand = .horizontal,
                    .gravity_y = 0.5,
                    // uniform gap from the column edges + taller "label" feel
                    .margin = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
                    .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
                    .corner_radius = .all(3),
                });
            }
            if (dvui.clicked(hit.data(), .{})) goDetail(state, g);
        }
        // Rating (5 stars, filled to the rounded score)
        {
            defer cell_num.col_num += 1;
            var cell = grid.bodyCell(@src(), cell_num, .{});
            defer cell.deinit();
            var hit = rowHit(@src(), g.f95_thread_id);
            defer hit.deinit();
            if (g.rating) |r| {
                var srow = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = g.f95_thread_id,
                    .gravity_y = 0.5,
                });
                defer srow.deinit();
                const filled: usize = @intFromFloat(@round(std.math.clamp(r, 0, 5)));
                const acc = tokens.toDvui(tokens.active.acc, dvui.Color);
                const dim = style.labelDim();
                var i: usize = 0;
                while (i < 5) : (i += 1) {
                    const on = i < filled;
                    dvui.icon(@src(), "star", if (on) entypo.star else entypo.star_outlined, .{}, .{
                        .id_extra = i,
                        .gravity_y = 0.5,
                        .min_size_content = .{ .w = 12, .h = 12 },
                        .color_text = if (on) acc else dim,
                    });
                }
            }
            if (dvui.clicked(hit.data(), .{})) goDetail(state, g);
        }
        // Version
        {
            defer cell_num.col_num += 1;
            var cell = grid.bodyCell(@src(), cell_num, .{});
            defer cell.deinit();
            var hit = rowHit(@src(), g.f95_thread_id);
            defer hit.deinit();
            dvui.labelNoFmt(@src(), g.latest_version orelse "", .{}, .{ .gravity_y = 0.5, .color_text = style.labelDim() });
            if (dvui.clicked(hit.data(), .{})) goDetail(state, g);
        }
        // Updated
        {
            defer cell_num.col_num += 1;
            var cell = grid.bodyCell(@src(), cell_num, .{});
            defer cell.deinit();
            var hit = rowHit(@src(), g.f95_thread_id);
            defer hit.deinit();
            var ub: [16]u8 = undefined;
            const us = reltime.ago(now_s, g.last_updated_at orelse 0, &ub);
            dvui.labelNoFmt(@src(), us, .{}, .{ .gravity_y = 0.5, .color_text = style.labelDim() });
            if (dvui.clicked(hit.data(), .{})) goDetail(state, g);
        }
        // Played (relative time of the last launch)
        {
            defer cell_num.col_num += 1;
            var cell = grid.bodyCell(@src(), cell_num, .{});
            defer cell.deinit();
            var hit = rowHit(@src(), g.f95_thread_id);
            defer hit.deinit();
            var pb: [16]u8 = undefined;
            const ps = if (g.last_played_at) |lp| reltime.ago(now_s, lp, &pb) else "—";
            dvui.labelNoFmt(@src(), ps, .{}, .{ .gravity_y = 0.5, .color_text = style.labelDim() });
            if (dvui.clicked(hit.data(), .{})) goDetail(state, g);
        }
        // Action: ▶ play when installed, ⬇ download otherwise (Design-B row button).
        {
            defer cell_num.col_num += 1;
            var cell = grid.bodyCell(@src(), cell_num, .{});
            defer cell.deinit();
            const installed = if (frame.install_versions) |m| m.get(g.f95_thread_id) != null else false;
            if (installed) {
                if (components.iconOnly(@src(), "play", entypo.controller_play, .{
                    .id_extra = g.f95_thread_id,
                    .gravity_y = 0.5,
                    .gravity_x = 0.5,
                    .style = .highlight,
                })) actions.doLaunchGame(frame, g);
            } else {
                if (components.iconOnly(@src(), "dl", entypo.download, .{
                    .id_extra = g.f95_thread_id,
                    .gravity_y = 0.5,
                    .gravity_x = 0.5,
                })) goDetail(state, g);
            }
        }
    }
}

fn renderListWindow(
    frame: *Frame,
    games: []const library.Game,
    filtered: []const u32,
    start_idx: usize,
    end_idx: usize,
) void {
    const state = frame.state;
    var my_idx = start_idx;
    while (my_idx < end_idx and my_idx < filtered.len) : (my_idx += 1) {
        const game_i: usize = filtered[my_idx];
        const g = &games[game_i];

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = g.f95_thread_id,
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        });
        defer row.deinit();

        renderListThumb(actions.coverBytes(frame, g.f95_thread_id), g.f95_thread_id);

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });

        if (g.engine != .unknown) {
            const fill = components.engineBadgeColor(g.engine);
            comp.chip(@src(), .{
                .label = components.engineShortLabel(g.engine),
                .fill = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
                .text = .{ .r = 0xff, .g = 0xff, .b = 0xff },
                .border = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
                .scale = 0.75,
            }, .{
                .id_extra = g.f95_thread_id,
                .gravity_y = 0.5,
                .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
                .corner_radius = .all(2),
            });
        }

        if (g.dev_status != .unknown) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
            const fill = components.devStatusColor(g.dev_status);
            comp.chip(@src(), .{
                .label = components.devStatusShortLabel(g.dev_status),
                .fill = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
                .text = .{ .r = 0xff, .g = 0xff, .b = 0xff },
                .border = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
                .scale = 0.75,
            }, .{
                .id_extra = g.f95_thread_id ^ 0xD5,
                .gravity_y = 0.5,
                .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
                .corner_radius = .all(2),
            });
        }

        {
            const inst_v: ?[]const u8 = if (frame.install_versions) |m| m.get(g.f95_thread_id) else null;
            if (hasUnplayedUpdate(g, inst_v)) {
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
                // Design B "NEW" chip — theme-following accent2 (validated comp layer).
                const t = tokens.active;
                comp.chip(@src(), .{
                    .label = "NEW",
                    .fill = t.bg2,
                    .text = t.accent2,
                    .border = t.line,
                    .scale = 0.75,
                }, .{
                    .id_extra = g.f95_thread_id ^ 0xBB22,
                    .gravity_y = 0.5,
                    .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
                    .corner_radius = .all(2),
                });
            }
            const now_s: i64 = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();
            if (statusRecentlyChanged(g, now_s)) {
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
                comp.chip(@src(), .{
                    .label = "STATUS",
                    .fill = .{ .r = 0xC0, .g = 0x84, .b = 0x1F, .a = 0xff },
                    .text = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
                    .border = .{ .r = 0xC0, .g = 0x84, .b = 0x1F, .a = 0xff },
                    .scale = 0.75,
                }, .{
                    .id_extra = g.f95_thread_id ^ 0x57A7,
                    .gravity_y = 0.5,
                    .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
                    .corner_radius = .all(2),
                });
            }
            if (hasUpdateAvailable(g, inst_v)) {
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
                comp.chip(@src(), .{
                    .label = "UPDATE",
                    .fill = .{ .r = 0x1F, .g = 0x9E, .b = 0xC0, .a = 0xff },
                    .text = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
                    .border = .{ .r = 0x1F, .g = 0x9E, .b = 0xC0, .a = 0xff },
                    .scale = 0.75,
                }, .{
                    .id_extra = g.f95_thread_id ^ 0x09DA,
                    .gravity_y = 0.5,
                    .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
                    .corner_radius = .all(2),
                });
            }
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });

        dvui.labelNoFmt(@src(), g.name, .{}, .{
            .gravity_y = 0.5,
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 20 },
        });

        if (g.rating) |r| {
            dvui.icon(@src(), "rating-star", entypo.star, .{}, .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 14, .h = 14 },
                .color_text = tokens.toDvui(tokens.active.acc, dvui.Color),
            });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
            var rate_buf: [16]u8 = undefined;
            const rate_str = std.fmt.bufPrint(&rate_buf, "{d:.1}", .{r}) catch "?";
            dvui.labelNoFmt(@src(), rate_str, .{}, .{ .gravity_y = 0.5 });
        } else {
            dvui.label(@src(), "—", .{}, .{ .gravity_y = 0.5 });
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });

        const ver = if (g.latest_version) |v| v else "—";
        dvui.labelNoFmt(@src(), ver, .{}, .{ .gravity_y = 0.5 });

        const dot_state = actions.installDotState(frame, g);
        if (dot_state != .none) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
            const fill: dvui.Color = switch (dot_state) {
                .up_to_date => .{ .r = 0x2E, .g = 0x7D, .b = 0x32 },
                .outdated => .{ .r = 0xC0, .g = 0x84, .b = 0x1F },
                .none => unreachable,
            };
            const tip: []const u8 = switch (dot_state) {
                .up_to_date => "Installed",
                .outdated => "Installed (update available)",
                .none => unreachable,
            };
            const diameter: f32 = 10;
            var dot = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = g.f95_thread_id ^ 0xAA77,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = diameter, .h = diameter },
                .max_size_content = .{ .w = diameter, .h = diameter },
                .corner_radius = .all(diameter / 2),
                .background = true,
                .color_fill = fill,
                .color_border = fill,
                .border = style.border_thin,
            });
            dvui.tooltip(@src(), .{
                .active_rect = dot.data().borderRectScale().r,
            }, "{s}", .{tip}, .{ .id_extra = g.f95_thread_id ^ 0xAA77 });
            dot.deinit();
        }

        if (dvui.clicked(row.data(), .{})) {
            state.screen = .detail;
            state.selected_thread = g.f95_thread_id;
        }
    }
}

fn renderListThumb(bytes_opt: ?[]const u8, thread_id: u64) void {
    const w: f32 = 120;
    const h: f32 = 40;
    if (bytes_opt) |bytes| {
        _ = dvui.image(@src(), .{
            .source = .{
                .imageFile = .{
                    .bytes = bytes,
                    .name = "list-thumb",
                    // cover_cache slots get evicted+repopulated on
                    // re-sync. Allocator may hand back the same ptr,
                    // dvui's default `.ptr` invalidation would serve the
                    // stale GPU texture. Hash bytes instead.
                    .invalidation = .bytes,
                },
            },
            .shrink = .ratio,
        }, .{
            .id_extra = thread_id,
            .min_size_content = .{ .w = w, .h = h },
            .gravity_y = 0.5,
            .corner_radius = .all(3),
            .border = style.border_thin,
            .color_border = style.borderColor(),
        });
        return;
    }
    var slot = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = thread_id,
        .min_size_content = .{ .w = w, .h = h },
        .gravity_y = 0.5,
        .background = true,
        .corner_radius = .all(3),
        .border = style.border_thin,
        .color_fill = .{ .r = 0x2A, .g = 0x16, .b = 0x20 },
        .color_border = style.borderColor(),
    });
    defer slot.deinit();
}

/// Hash every input `cardVisible` reads so the renderer can detect
/// "did anything that affects the filter change?" in O(1). When the
/// signature matches last frame, we reuse the cached filtered slice
/// instead of running substring searches over every game.
///
/// Inputs that affect visibility:
///   - `state.filters` (whole struct including text buffers)
///   - `query` (current search string)
///   - `games` slice identity (ptr + len; a sync that adds a row
///      hands us a new slice so this catches that)
///   - `state.installed_set` ptr (used by `cardVisible` for
///      installed / not_installed filtering)
fn filterSignature(state: *const State, query: []const u8, games: []const library.Game) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&state.filters));
    hasher.update(query);
    hasher.update(std.mem.asBytes(&games.ptr));
    hasher.update(std.mem.asBytes(&games.len));
    // Sort state too — `sortGames` mutates `games[]` in place when
    // the column/direction changes. The filter cache stores INDICES
    // into `games[]`, so a re-sort silently invalidates them. Without
    // these two bytes in the signature, the user saw filter changes
    // and sort changes appear to "fight" each other.
    hasher.update(std.mem.asBytes(&state.sort_applied_column));
    hasher.update(std.mem.asBytes(&state.sort_applied_dir));
    const set_ptr: usize = if (state.installed_set) |s| @intFromPtr(s) else 0;
    hasher.update(std.mem.asBytes(&set_ptr));
    // Cheap proxy for "set membership changed" — adds/removes flip
    // count(). A swap (one removed, one added) is rare and only
    // causes one stale frame; acceptable.
    const set_count: usize = if (state.installed_set) |s| s.count() else 0;
    hasher.update(std.mem.asBytes(&set_count));
    // Unplayed-updates filter: hash both the toggle and the install-
    // generation counter so a new install immediately re-evaluates.
    hasher.update(std.mem.asBytes(&state.filter_unplayed_updates));
    hasher.update(std.mem.asBytes(&state.filter_status_changed));
    hasher.update(std.mem.asBytes(&state.filter_update_available));
    hasher.update(std.mem.asBytes(&state.snapshot_install_gen));
    // In-place game edits (e.g. status change from the detail screen) bump
    // this so the cached filtered slice is rebuilt immediately — otherwise an
    // edit that changes a game's filter membership wouldn't show until an
    // unrelated signature input happened to change.
    hasher.update(std.mem.asBytes(&state.game_edit_gen));
    // Label filter — selected ids. (Re-assigning a label to a game while the
    // filter is active needs a manual refresh; the common case of toggling
    // the selection is covered here.)
    hasher.update(std.mem.asBytes(&state.label_filter_len));
    hasher.update(std.mem.sliceAsBytes(state.label_filter[0..state.label_filter_len]));
    return hasher.final();
}

/// Days a dev-status change stays "recent" for the chip + filter.
const STATUS_CHANGE_RECENT_DAYS: i64 = 14;

fn statusRecentlyChanged(g: *const library.Game, now_s: i64) bool {
    const t = g.status_changed_at orelse return false;
    return (now_s - t) < STATUS_CHANGE_RECENT_DAYS * 24 * 60 * 60;
}

fn cardVisible(
    state: *const State,
    g: *const library.Game,
    query: []const u8,
    install_versions: ?*const std.AutoHashMap(u64, []const u8),
    now_s: i64,
) bool {
    if (query.len > 0) {
        const name_match = types.asciiContainsIgnoreCase(g.name, query);
        const dev_match = if (g.developer) |d| types.asciiContainsIgnoreCase(d, query) else false;
        const desc_match = if (g.description_md) |d| types.asciiContainsIgnoreCase(d, query) else false;
        if (!name_match and !dev_match and !desc_match) return false;
    }
    if (!state.filters.match(g)) return false;

    switch (state.filters.installed) {
        .all => {},
        .installed => {
            const set = state.installed_set orelse return false;
            if (!set.contains(g.f95_thread_id)) return false;
        },
        .not_installed => {
            if (state.installed_set) |set| {
                if (set.contains(g.f95_thread_id)) return false;
            }
        },
    }

    if (state.filter_unplayed_updates) {
        const inst_v: ?[]const u8 = if (install_versions) |m| m.get(g.f95_thread_id) else null;
        if (!hasUnplayedUpdate(g, inst_v)) return false;
    }

    if (state.filter_status_changed and !statusRecentlyChanged(g, now_s)) return false;

    if (state.filter_update_available) {
        const inst_v: ?[]const u8 = if (install_versions) |m| m.get(g.f95_thread_id) else null;
        if (!hasUpdateAvailable(g, inst_v)) return false;
    }

    return true;
}

fn renderCard(frame: *Frame, g: *const library.Game, layout: GridLayout) void {
    const state = frame.state;
    // Per-game tag ("card-<thread_id>") for the live GUI driver (ui.zig dumpTags).
    var card_tag_buf: [32]u8 = undefined;
    const card_tag = std.fmt.bufPrint(&card_tag_buf, "card-{d}", .{g.f95_thread_id}) catch "card";
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = g.f95_thread_id,
        .tag = card_tag,
        .background = true,
        .border = style.border_thin,
        .corner_radius = .all(6),
        .min_size_content = .{ .w = layout.card_w, .h = layout.card_h },
        .max_size_content = .{ .w = layout.card_w, .h = layout.card_h },
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        .margin = .{ .x = 3, .y = 3, .w = 3, .h = 3 },
        .color_fill = style.cardFill(),
        .color_border = style.borderColor(),
    });
    defer card.deinit();

    const install_state = actions.installDotState(frame, g);

    renderCardCover(
        actions.coverBytes(frame, g.f95_thread_id),
        g.f95_thread_id,
        g.engine,
        g.dev_status,
        layout,
    );

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 2 } });

    var name_buf: [80]u8 = undefined;
    const name_disp = truncEllipsis(&name_buf, g.name, 52);
    const heading = dvui.Font.theme(.heading);
    const title_font = heading.withSize(heading.size * style.title_font_scale);
    {
        var title_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = g.f95_thread_id,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        });
        defer title_row.deinit();
        dvui.labelNoFmt(@src(), name_disp, .{}, .{
            .expand = .horizontal,
            .max_size_content = .{ .w = 0, .h = 20 },
            .font = title_font,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
        });
        if (install_state != .none) renderInstallDot(g.f95_thread_id, install_state);
    }

    if (g.developer) |dev| {
        const body = dvui.Font.theme(.body);
        const dev_font = body.withSize(body.size * style.meta_font_scale);
        dvui.labelNoFmt(@src(), dev, .{}, .{
            .expand = .horizontal,
            .max_size_content = .{ .w = 0, .h = 14 },
            .color_text = style.labelDim(),
            .font = dev_font,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        });
    }

    var meta_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = g.f95_thread_id,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
    });
    defer meta_row.deinit();

    const meta_body = dvui.Font.theme(.body);
    const meta_font = meta_body.withSize(meta_body.size * style.meta_font_scale);
    const meta_opts: dvui.Options = .{
        .gravity_y = 0.5,
        .font = meta_font,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    };
    if (g.latest_version) |v| {
        dvui.label(@src(), "v{s}", .{v}, meta_opts);
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    if (g.rating) |r| {
        dvui.icon(@src(), "rating-star", entypo.star, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 12, .h = 12 },
            .color_text = tokens.toDvui(tokens.active.acc, dvui.Color),
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 3, .h = 1 } });

        var rate_buf: [40]u8 = undefined;
        const rate_str = if (g.vote_count) |c|
            std.fmt.bufPrint(&rate_buf, "{d:.1}  ({d})", .{ r, c }) catch "?"
        else
            std.fmt.bufPrint(&rate_buf, "{d:.1}", .{r}) catch "?";
        dvui.labelNoFmt(@src(), rate_str, .{}, meta_opts);
    } else {
        dvui.label(@src(), "(unrated)", .{}, meta_opts);
    }

    if (dvui.clicked(card.data(), .{})) {
        state.screen = .detail;
        state.selected_thread = g.f95_thread_id;
    }
}

fn truncEllipsis(buf: []u8, s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    if (buf.len < max + 3) return s;
    var cut: usize = max;
    while (cut > 0) {
        const b = s[cut];
        if ((b & 0b1100_0000) != 0b1000_0000) break;
        cut -= 1;
    }
    @memcpy(buf[0..cut], s[0..cut]);
    // U+2026 → E2 80 A6
    buf[cut] = 0xE2;
    buf[cut + 1] = 0x80;
    buf[cut + 2] = 0xA6;
    return buf[0 .. cut + 3];
}

const CoverFit = union(enum) {
    cover_center: dvui.Rect,
    cover_top: dvui.Rect,
    fit_backdrop: void,
    zoom_height: dvui.Rect,
};

fn planCoverFit(source_aspect: f32, target_aspect: f32) CoverFit {
    if (source_aspect <= 0 or target_aspect <= 0) {
        return .{ .cover_center = .{ .w = 1, .h = 1 } };
    }
    if (source_aspect >= target_aspect) {
        const uv_w = target_aspect / source_aspect;
        const uv_x = (1.0 - uv_w) * 0.5;
        return .{ .cover_center = .{ .x = uv_x, .y = 0, .w = uv_w, .h = 1 } };
    }
    if (source_aspect >= target_aspect * 0.75) {
        const uv_h = source_aspect / target_aspect;
        const uv_y = (1.0 - uv_h) * 0.2;
        return .{ .cover_top = .{ .x = 0, .y = uv_y, .w = 1, .h = uv_h } };
    }
    if (source_aspect <= 1.0) {
        return .{ .zoom_height = .{ .x = 0, .y = 0.1, .w = 1, .h = 0.8 } };
    }
    return .{ .fit_backdrop = {} };
}

fn renderCardCover(bytes_opt: ?[]const u8, thread_id: u64, engine: library.Engine, status: library.DevStatus, layout: GridLayout) void {
    const cover_h: f32 = layout.cover_h;
    var ov = dvui.overlay(@src(), .{
        .id_extra = thread_id,
        .expand = .horizontal,
        .min_size_content = .{ .w = 1, .h = cover_h },
        .max_size_content = .{ .w = layout.card_w, .h = cover_h },
    });
    defer ov.deinit();

    if (bytes_opt) |bytes| {
        const source: dvui.ImageSource = .{ .imageFile = .{
            .bytes = bytes,
            .name = "card-cover",
            .invalidation = .bytes,
        } };
        const natural = dvui.imageSize(source) catch dvui.Size{ .w = 16, .h = 9 };
        const target_aspect = (layout.card_w - 12) / cover_h;
        const source_aspect = if (natural.h > 0) natural.w / natural.h else 16.0 / 9.0;

        switch (planCoverFit(source_aspect, target_aspect)) {
            .cover_center, .cover_top => |uv| {
                _ = dvui.image(@src(), .{
                    .source = source,
                    .shrink = null,
                    .uv = uv,
                }, .{
                    .id_extra = thread_id,
                    .expand = .both,
                    .min_size_content = .{ .w = 1, .h = 1 },
                    .corner_radius = style.corner_radius,
                    .border = style.border_thin,
                    .color_border = style.borderColor(),
                });
            },
            .fit_backdrop => {
                {
                    var bg = dvui.box(@src(), .{ .dir = .vertical }, .{
                        .id_extra = thread_id ^ 0xBD,
                        .expand = .both,
                        .gravity_x = 0.5,
                        .min_size_content = .{ .w = 1, .h = 1 },
                        .max_size_content = .{ .w = layout.card_w - 12, .h = cover_h },
                        .background = true,
                        .corner_radius = style.corner_radius,
                        .border = style.border_thin,
                        .color_border = style.borderColor(),
                        .color_fill = style.letterbox_fill,
                    });
                    bg.deinit();
                }
                _ = dvui.image(@src(), .{
                    .source = source,
                    .shrink = .ratio,
                    .uv = .{ .w = 1, .h = 1 },
                }, .{
                    .id_extra = thread_id ^ 0xFE,
                    .expand = .ratio,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = natural.w, .h = natural.h },
                });
            },
            .zoom_height => |uv| {
                {
                    var bg = dvui.box(@src(), .{ .dir = .vertical }, .{
                        .id_extra = thread_id ^ 0xBD,
                        .expand = .both,
                        .gravity_x = 0.5,
                        .min_size_content = .{ .w = 1, .h = 1 },
                        .max_size_content = .{ .w = layout.card_w - 12, .h = cover_h },
                        .background = true,
                        .corner_radius = style.corner_radius,
                        .border = style.border_thin,
                        .color_border = style.borderColor(),
                        .color_fill = style.letterbox_fill,
                    });
                    bg.deinit();
                }
                _ = dvui.image(@src(), .{
                    .source = source,
                    .shrink = .ratio,
                    .uv = uv,
                }, .{
                    .id_extra = thread_id ^ 0x77,
                    .expand = .ratio,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = natural.w, .h = natural.h * uv.h },
                });
            },
        }
    } else {
        var slot = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = thread_id,
            .expand = .both,
            .background = true,
            .corner_radius = style.corner_radius,
            .border = style.border_thin,
            .color_fill = .{ .r = 0x2A, .g = 0x16, .b = 0x20 },
            .color_border = style.borderColor(),
        });
        defer slot.deinit();
        dvui.label(@src(), "(no cover)", .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
    }

    renderEngineBadge(thread_id, engine);
    renderStatusBadge(thread_id, status);
}

fn renderInstallDot(thread_id: u64, state: actions.InstallDotState) void {
    const fill: dvui.Color = switch (state) {
        .up_to_date => .{ .r = 0x2E, .g = 0x7D, .b = 0x32 },
        .outdated => .{ .r = 0xC0, .g = 0x84, .b = 0x1F },
        .none => return,
    };
    const tip: []const u8 = switch (state) {
        .up_to_date => "Installed",
        .outdated => "Installed (update available)",
        .none => "",
    };
    const diameter: f32 = 12;
    var dot = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = thread_id ^ 0xAA77,
        .gravity_x = 1.0,
        .gravity_y = 0.0,
        .min_size_content = .{ .w = diameter, .h = diameter },
        .max_size_content = .{ .w = diameter, .h = diameter },
        .background = true,
        .corner_radius = .all(diameter / 2),
        .color_fill = fill,
        .color_border = .{ .r = 0x16, .g = 0x0B, .b = 0x10 },
        .border = style.border_thin,
        .margin = .{ .x = 0, .y = 2, .w = 2, .h = 0 },
    });
    dvui.tooltip(@src(), .{
        .active_rect = dot.data().borderRectScale().r,
    }, "{s}", .{tip}, .{ .id_extra = thread_id ^ 0xAA77 });
    dot.deinit();
}

fn renderStatusBadge(thread_id: u64, status: library.DevStatus) void {
    if (status == .unknown) return;
    const fill = components.devStatusColor(status);
    comp.chip(@src(), .{
        .label = components.devStatusShortLabel(status),
        .fill = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
        .text = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .border = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
        .scale = style.chip_font_scale,
    }, .{
        .id_extra = thread_id,
        .gravity_x = 1.0,
        .gravity_y = 1.0,
        .corner_radius = .all(2),
        .padding = .all(0),
        .margin = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
    });
}

fn renderEngineBadge(thread_id: u64, engine: library.Engine) void {
    const fill = components.engineBadgeColor(engine);
    comp.chip(@src(), .{
        .label = components.engineShortLabel(engine),
        .fill = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
        .text = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .border = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
        .scale = style.chip_font_scale,
    }, .{
        .id_extra = thread_id,
        .gravity_x = 0,
        .gravity_y = 1.0,
        .corner_radius = .all(2),
        .padding = .all(0),
        .margin = .{ .x = 4, .y = 0, .w = 0, .h = 4 },
    });
}

// ============================================================
//  sorting
// ============================================================

const SortCtx = struct {
    column: state_mod.SortColumn,
    dir: state_mod.SortDir,
    library_mean: f32,
};

const WEIGHTED_PRIOR: f32 = 10.0;

fn sortGames(games: []library.Game, column: state_mod.SortColumn, dir: state_mod.SortDir) void {
    var sum: f32 = 0;
    var n: u32 = 0;
    for (games) |*g| {
        if (g.rating) |r| {
            sum += r;
            n += 1;
        }
    }
    const mean: f32 = if (n > 0) sum / @as(f32, @floatFromInt(n)) else 0;

    std.mem.sort(library.Game, games, SortCtx{ .column = column, .dir = dir, .library_mean = mean }, gameLessThan);
}

fn gameLessThan(ctx: SortCtx, a: library.Game, b: library.Game) bool {
    const asc: bool = ctx.dir == .asc;
    return switch (ctx.column) {
        .sync_state => {
            const a_synced = a.last_scraped_at != null;
            const b_synced = b.last_scraped_at != null;
            if (a_synced != b_synced) return if (asc) a_synced else b_synced;
            const al = std.ascii.lessThanIgnoreCase(a.name, b.name);
            const bl = std.ascii.lessThanIgnoreCase(b.name, a.name);
            if (al == bl) return a.f95_thread_id < b.f95_thread_id;
            return al;
        },
        .name => {
            const al = std.ascii.lessThanIgnoreCase(a.name, b.name);
            const bl = std.ascii.lessThanIgnoreCase(b.name, a.name);
            if (al == bl) return if (asc) a.f95_thread_id < b.f95_thread_id else a.f95_thread_id > b.f95_thread_id;
            return if (asc) al else bl;
        },
        .rating => {
            const ra = a.rating orelse -1.0;
            const rb = b.rating orelse -1.0;
            if (ra == rb) return a.f95_thread_id < b.f95_thread_id;
            return if (asc) ra < rb else ra > rb;
        },
        .weighted => {
            const wa = a.weightedRating(ctx.library_mean, WEIGHTED_PRIOR) orelse -1.0;
            const wb = b.weightedRating(ctx.library_mean, WEIGHTED_PRIOR) orelse -1.0;
            if (wa == wb) return a.f95_thread_id < b.f95_thread_id;
            return if (asc) wa < wb else wa > wb;
        },
        .votes => {
            const va = a.vote_count orelse 0;
            const vb = b.vote_count orelse 0;
            if (va == vb) return a.f95_thread_id < b.f95_thread_id;
            return if (asc) va < vb else va > vb;
        },
        .last_updated => {
            const ua: i64 = a.last_updated_at orelse std.math.minInt(i64);
            const ub: i64 = b.last_updated_at orelse std.math.minInt(i64);
            if (ua == ub) return a.f95_thread_id < b.f95_thread_id;
            return if (asc) ua < ub else ua > ub;
        },
        .last_played_version => blk: {
            const va = a.last_played_version;
            const vb = b.last_played_version;
            // Nulls always sort to the bottom (treated as "never played"),
            // regardless of asc/desc. Treat null as "greater than everything"
            // in the natural ascending order so desc reversal also lands
            // them at the bottom of the visible list.
            if (va == null and vb == null) break :blk a.f95_thread_id < b.f95_thread_id;
            if (va == null) break :blk false; // a is null → a is "max", sinks
            if (vb == null) break :blk true; // b is null → a beats it
            const ord = version_mod.compare(va.?, vb.?);
            if (ord == .eq) break :blk a.f95_thread_id < b.f95_thread_id;
            break :blk if (asc) ord == .lt else ord == .gt;
        },
    };
}
