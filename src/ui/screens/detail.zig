// Detail screen — per-game page with carousel, action toolbar,
// facts grid, tabs (Description / Changelog / Notes / Downloads),
// install picker / management popups, image popup, clash modal.

const std = @import("std");
const dvui = @import("dvui");
const entypo = dvui.entypo;
const library = @import("library");
const downloads = @import("downloads");
const file_picker = @import("util_file_picker");
const version_mod = @import("util_version");
const convert_mod = @import("convert");

const types = @import("../types.zig");
const state_mod = @import("../state.zig");
const actions = @import("../actions.zig");
const style = @import("../style.zig");
const components = @import("../components.zig");
const comp = @import("ui_comp");
const tokens = @import("ui_tokens");

const Frame = types.Frame;
const helpTextColor = components.helpTextColor;

// ============================================================
//  detail screen
// ============================================================

pub fn detailScreen(frame: *Frame) !bool {
    const state = frame.state;
    const games = frame.games;
    // Keep the per-frame install-set snapshot fresh so the InstallDot
    // and "Installed" affordances on the detail page flip green the
    // instant a post-install commits, without the user having to
    // navigate away.
    actions.refreshInstalledSet(frame);
    const tid = state.selected_thread orelse {
        state.screen = .library;
        return true;
    };

    if (state.detail_state_for_thread != tid) {
        state.resetDetailViewState();
        state.detail_state_for_thread = tid;
    }

    const game = blk: {
        if (frame.games_by_thread) |map| {
            if (map.get(tid)) |gg| break :blk gg;
        } else {
            for (games) |*gg| if (gg.f95_thread_id == tid) break :blk gg;
        }
        state.screen = .library;
        state.selected_thread = null;
        return true;
    };

    // ---- top action bar ----
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();

        // ← Library ghost back button (design-B detail head).
        if (components.iconButton(@src(), "Library", entypo.chevron_left, .{ .gravity_y = 0.5, .tag = "detail-back" })) {
            state.screen = .library;
            state.selected_thread = null;
            state.clearTransientToasts();
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // ⋯ overflow — Delete (and future per-game actions) tucked away.
        var ob = dvui.menu(@src(), .horizontal, .{});
        defer ob.deinit();
        if (dvui.menuItemIcon(@src(), "detail-overflow", entypo.dots_three_horizontal, .{ .submenu = true }, .{
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .min_size_content = style.icon_size,
            .gravity_y = 0.5,
            .tag = "detail-overflow",
        })) |anchor| {
            var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
            defer fw.deinit();
            // Files
            if (dvui.menuItemLabel(@src(), "Open install folder", .{}, .{ .expand = .horizontal }) != null) {
                actions.doOpenGameFolder(frame, game);
                ob.close();
            }
            if (dvui.menuItemLabel(@src(), "Set install folder\u{2026}", .{}, .{ .expand = .horizontal }) != null) {
                actions.setInstallFolder(frame, game);
                ob.close();
            }
            if (dvui.menuItemLabel(@src(), "Open saves", .{}, .{ .expand = .horizontal }) != null) {
                actions.doOpenSaves(frame, game);
                ob.close();
            }
            if (dvui.menuItemLabel(@src(), "Backup saves", .{}, .{ .expand = .horizontal }) != null) {
                actions.doBackupSaves(frame, game);
                ob.close();
            }
            if (dvui.menuItemLabel(@src(), "Import saves…", .{}, .{ .expand = .horizontal }) != null) {
                actions.doImportSaves(frame, game);
                ob.close();
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal });
            // (Convert + Fix Compat + engine tools live in the Tools tab.)
            if (dvui.menuItemLabel(@src(), "Sync now", .{}, .{ .expand = .horizontal }) != null) {
                actions.syncGame(frame, game);
                ob.close();
            }
            if (dvui.menuItemLabel(@src(), "Set F95 thread URL\u{2026}", .{}, .{ .expand = .horizontal }) != null) {
                @memset(&state.set_url_buf, 0);
                _ = std.fmt.bufPrint(&state.set_url_buf, "https://f95zone.to/threads/{d}/", .{game.f95_thread_id}) catch {};
                state.set_url_for = game.f95_thread_id;
                ob.close();
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal });
            if (dvui.menuItemLabel(@src(), "Delete game\u{2026}", .{}, .{ .expand = .horizontal, .tag = "detail-delete" }) != null) {
                state.confirm_delete = true;
                ob.close();
            }
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    if (state.confirm_delete) {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
            .background = true,
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .color_fill = style.cardFill(),
            .color_border = style.borderColor(),
        });
        defer bar.deinit();
        var conf_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&conf_buf, "Really delete \"{s}\"?", .{game.name}) catch "Really delete?";
        dvui.labelNoFmt(@src(), msg, .{}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (components.iconButton(@src(), "Cancel", entypo.cross, .{ .tag = "detail-delete-cancel" })) state.confirm_delete = false;
        if (components.iconButton(@src(), "Delete", entypo.trash, .{ .style = .err })) {
            actions.deleteGameAndReturn(frame, game.f95_thread_id);
            return true;
        }
    }

    // Inline "Set F95 thread URL" bar — opened from the ⋯ menu. Paste a thread
    // URL/id and re-sync; a different id re-keys the game (installs/mods/saves
    // move with it) via actions.applySetThreadUrl.
    if (state.set_url_for != null) {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
            .background = true,
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .color_fill = style.cardFill(),
            .color_border = style.borderColor(),
        });
        defer bar.deinit();
        dvui.labelNoFmt(@src(), "F95 thread URL / id:", .{}, .{ .gravity_y = 0.5, .color_text = style.labelDim() });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.set_url_buf } }, .{ .expand = .horizontal, .min_size_content = .{ .w = 240, .h = 26 }, .gravity_y = 0.5 });
        te.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (components.iconButton(@src(), "Cancel", entypo.cross, .{ .tag = "detail-seturl-cancel" })) state.set_url_for = null;
        if (components.iconButton(@src(), "Set & sync", entypo.check, .{ .style = .highlight })) {
            actions.applySetThreadUrl(frame, game.f95_thread_id, nulSlice(&state.set_url_buf));
            return true;
        }
    }

    var page_scroll = dvui.scrollArea(@src(), .{ .scroll_info = &state.detail_scroll }, .{ .expand = .both });

    // Full-bleed banner spans the whole detail column (no side padding).
    renderBannerHero(frame, game);
    {
        var hdr = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
        });
        defer hdr.deinit();

        renderRibbon(frame, game); // V3 filmstrip under the hero
        renderCompactMeta(frame, game); // V3 compact meta bar (incl. Download · Install · Mods)
    }

    if (game.tags.len > 0) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
        var tag_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 4, .w = 16, .h = 4 },
        });
        defer tag_box.deinit();
        renderTagChips(frame, game.tags);
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    {
        var tabs = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 4 },
        });
        defer tabs.deinit();

        if (components.tabButton("Overview", state.detail_tab == .overview)) state.detail_tab = .overview;
        if (components.tabButton("Changelog", state.detail_tab == .changelog)) state.detail_tab = .changelog;
        if (components.tabButton("Downloads", state.detail_tab == .downloads)) state.detail_tab = .downloads;
        // Tools sits with the version-related tabs — it operates on the
        // selected install (see renderToolsTab's version picker).
        if (components.tabButton("Tools", state.detail_tab == .tools)) state.detail_tab = .tools;
        if (components.tabButton("Notes", state.detail_tab == .notes)) state.detail_tab = .notes;
        if (components.tabButton("Journal", state.detail_tab == .journal)) state.detail_tab = .journal;
        if (components.tabButton("Guides", state.detail_tab == .guides)) state.detail_tab = .guides;
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    {
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{
            .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 500 },
        });
        defer body.deinit();

        switch (state.detail_tab) {
            .overview => renderOverview(frame, game),
            .changelog => renderChangelogTab(frame, game),
            .downloads => renderDownloadsTab(frame, game),
            .notes => renderNotesTab(frame, game),
            .guides => renderGuidesTab(frame, game),
            .journal => renderJournalTab(frame, game),
            .tools => renderToolsTab(frame, game),
        }
    }

    page_scroll.deinit();

    renderImagePopup(frame, game);

    renderInstallManagePopups(frame, game);

    renderClashModal(frame, game);

    return true;
}

// ============================================================
//  Detail-screen meta layout helpers
// ============================================================

fn renderRatingStars(rating: f32) void {
    const accent: dvui.Color = tokens.toDvui(tokens.active.acc, dvui.Color);
    var n: u8 = 1;
    while (n <= 5) : (n += 1) {
        const filled = rating >= @as(f32, @floatFromInt(n)) - 0.5;
        const tvg = if (filled) entypo.star else entypo.star_outlined;
        dvui.icon(@src(), "rate", tvg, .{}, .{
            .id_extra = n,
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_y = 0.5,
            .color_text = if (filled) accent else null,
        });
    }
}

/// V3 banner hero (detail-variants.html, the CHOSEN design): the screenshot
/// gallery IS the headline. A big full-bleed banner shows the current
/// shot/cover with ‹ › nav arrows + dots overlaid; the cover inset + title +
/// chips + ▶ Play sit over a bottom scrim. Clicking the banner opens the V4
/// lightbox (renderImagePopup). A filmstrip + compact meta bar render below it
/// (see detailScreen).
fn renderBannerHero(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const t = tokens.active;
    const HERO_H: f32 = 346; // +20% taller banner

    // Per-game gallery reset + thumbnail prewarm (mirrors the old carousel).
    if (state.carousel_for_thread != game.f95_thread_id) {
        state.carousel_index = 0;
        state.carousel_for_thread = game.f95_thread_id;
        actions.freeSlideCache(state, frame.lib.alloc);
        actions.spawnThumbPrewarm(frame.lib.alloc, frame.io, frame.info.covers_dir, game.f95_thread_id, game.screenshots.len);
    }
    const total: usize = 1 + game.screenshots.len; // slot 0 = cover, 1.. = screenshots
    const idx = @min(state.carousel_index, total - 1);

    var hero = dvui.overlay(@src(), .{
        .id_extra = game.f95_thread_id,
        .tag = "hero-banner",
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = HERO_H },
        .max_size_content = .height(HERO_H),
        .background = true,
        // near-black so the letterbox bars read as black, not graphite.
        .color_fill = .{ .r = 0x04, .g = 0x06, .b = 0x09 },
    });
    defer hero.deinit();

    // 1. gallery image — fit by RATIO (letterbox) + centred. The hero's black
    //    fill shows as bars when the shot is narrower than the full-width band.
    const bytes_opt: ?[]const u8 = if (idx == 0)
        actions.coverFullBytes(frame, game.f95_thread_id)
    else
        actions.slideBytes(frame, game.f95_thread_id, idx);
    if (bytes_opt) |bytes| {
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{ .bytes = bytes, .name = "hero" } },
            .shrink = .ratio,
        }, .{
            .id_extra = idx,
            .expand = .ratio, // keep aspect, fit within → letterbox
            .gravity_x = 0.5, // centre horizontally
            .gravity_y = 0.5,
        });
    }

    // 2. (no full-width scrim — contrast comes from an opaque block behind the
    //    title/chips group in the bottom-left, see the content row below.)

    // 3. nav arrows overlaid on the edges + dots (only with >1 image).
    if (total > 1) {
        if (heroNavArrow(@src(), "hero-prev", entypo.chevron_left, 0.0)) state.carousel_index = (idx + total - 1) % total;
        if (heroNavArrow(@src(), "hero-next", entypo.chevron_right, 1.0)) state.carousel_index = (idx + 1) % total;
        heroCounter(idx, total, bytes_opt); // Cinemascope: one counter chip, not a dot cluster
    }

    // 4. bottom overlay row: cover inset + title/chips (left) … ▶ Play (right).
    {
        var crow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 1.0,
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 10, .w = 16, .h = 14 },
        });
        defer crow.deinit();

        {
            // mostly-opaque block in the bottom-left for contrast behind the
            // title + chips (replaces the full-width scrim).
            var ti = dvui.box(@src(), .{ .dir = .vertical }, .{
                .gravity_y = 1.0,
                .background = true,
                .color_fill = .{ .r = 0x06, .g = 0x09, .b = 0x0d, .a = 0x55 },
                .padding = .{ .x = 12, .y = 9, .w = 16, .h = 11 },
                .corner_radius = dvui.Rect.all(8),
            });
            defer ti.deinit();
            dvui.labelNoFmt(@src(), game.name, .{}, .{ .color_text = tokens.toDvui(t.ink, dvui.Color), .font = dvui.Font.theme(.title) });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
            renderHeroChips(game);
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        {
            var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 1.0 });
            defer acts.deinit();
            renderHeroUpdate(frame, game);
            renderHeroPlay(frame, game);
        }
    }

    // Click the banner (not the arrows/Play, which consume their own clicks) →
    // V4 lightbox.
    if (dvui.clicked(hero.data(), .{})) {
        state.image_popup_open = true;
    }
}

/// Hero Play control. A split button: the primary half launches the active
/// install (the Overview-picked one, else the newest); a ▾ caret lists every
/// installed version to pick + launch. Shows Stop while the game runs.
/// Hero "Update to X" — shown next to Play when an install is outdated and
/// nothing's already downloading/installing. Secondary styling (Play stays the
/// teal primary). Moved here from the action row (design-B: ▶ Play · ⤓ Update).
fn renderHeroUpdate(frame: *Frame, game: *const library.Game) void {
    if (actions.isGameRunning(frame, game.f95_thread_id)) return;
    if (actions.hasActiveDownloadForGame(frame, game.f95_thread_id)) return;
    if (actions.isInstallingForGame(frame, game.f95_thread_id)) return;
    if (actions.installDotState(frame, game) != .outdated) return;
    const newer = game.latest_version orelse "latest";
    var buf: [48]u8 = undefined;
    const lbl = std.fmt.bufPrint(&buf, "Update to {s}", .{newer}) catch "Update";
    if (components.iconButton(@src(), lbl, entypo.cloud, .{ .gravity_y = 0.5, .tag = "hero-update" })) {
        if (actions.hasAutoFetchableSource(frame, game.f95_thread_id)) {
            actions.doDownloadGame(frame, game);
        } else {
            actions.openManualInstallForUpdate(frame.state, newer);
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
}

fn renderHeroPlay(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

    if (actions.isGameRunning(frame, game.f95_thread_id)) {
        if (components.iconButton(@src(), "Stop", entypo.cross, .{ .style = .err, .gravity_y = 0.5, .tag = "hero-stop" })) {
            actions.doStopGame(frame, game);
        }
        return;
    }
    if (actions.installDotState(frame, game) == .none) return; // nothing to launch yet

    const installs = frame.lib.listInstalls(game.f95_thread_id) catch &[_]library.Install{};
    defer frame.lib.freeInstalls(@constCast(installs));
    if (installs.len == 0) return;

    // active = the Overview picker's choice, else newest (installs[0]).
    var active: usize = 0;
    if (state.detail_picker_install_id) |sel| {
        for (installs, 0..) |inst, i| {
            if (std.mem.eql(u8, inst.id[0..], sel[0..])) {
                active = i;
                break;
            }
        }
    }

    var bar = dvui.menu(@src(), .horizontal, .{ .id_extra = game.f95_thread_id });
    defer bar.deinit();

    var lbl_buf: [56]u8 = undefined;
    const lbl = std.fmt.bufPrint(&lbl_buf, "Play  {s}", .{installs[active].version}) catch "Play";
    if (components.iconButton(@src(), lbl, entypo.controller_play, .{ .style = .highlight, .gravity_y = 0.5, .tag = "hero-play" })) {
        state.detail_picker_install_id = installs[active].id;
        actions.doLaunchGame(frame, game);
    }

    if (installs.len > 1) {
        if (dvui.menuItemIcon(@src(), "hero-play-menu", entypo.chevron_down, .{ .submenu = true }, .{
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .min_size_content = style.icon_size,
            .gravity_y = 0.5,
            .background = true,
            .style = .highlight,
            .corner_radius = style.corner_radius,
            .tag = "hero-play-caret",
        })) |anchor| {
            var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
            defer fw.deinit();
            for (installs, 0..) |inst, i| {
                var ib: [96]u8 = undefined;
                const suffix = if (i == 0) "  (newest)" else "";
                const it_lbl = std.fmt.bufPrint(&ib, "{s}{s}{s}", .{ sourceTag(inst.source), inst.version, suffix }) catch inst.version;
                if (dvui.menuItemLabel(@src(), it_lbl, .{}, .{ .expand = .horizontal, .id_extra = i }) != null) {
                    state.detail_picker_install_id = inst.id;
                    actions.doLaunchGame(frame, game);
                    bar.close();
                }
            }
        }
    }
}

/// Overlaid edge nav arrow for the V3 hero. `gx` = 0 (left) or 1 (right).
fn heroNavArrow(src: std.builtin.SourceLocation, tag: []const u8, tvg: []const u8, gx: f32) bool {
    // Bigger than the toolbar icons — call buttonIcon directly so we can set a
    // larger content size + generous vertical padding for a tall hit target.
    return dvui.buttonIcon(src, "hero-nav", tvg, .{}, .{}, .{
        .id_extra = if (gx < 0.5) @as(u64, 1) else @as(u64, 8),
        .tag = tag,
        .gravity_x = gx,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 30, .h = 30 },
        .margin = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        .padding = .{ .x = 11, .y = 18, .w = 11, .h = 18 },
        .background = true,
        .color_fill = .{ .r = 0x0a, .g = 0x0e, .b = 0x12, .a = 0xB0 },
        .corner_radius = dvui.Rect.all(8),
    });
}

/// Cinemascope counter chip, top-right — replaces the dot cluster. Shows
/// `idx / total · W×H` (resolution from the current image when available).
fn heroCounter(idx: usize, total: usize, bytes_opt: ?[]const u8) void {
    var buf: [56]u8 = undefined;
    const txt = blk: {
        if (bytes_opt) |b| {
            const sz = dvui.imageSize(.{ .imageFile = .{ .bytes = b, .name = "hc" } }) catch dvui.Size{ .w = 0, .h = 0 };
            if (sz.w > 0) break :blk std.fmt.bufPrint(&buf, "{d} / {d} · {d}×{d}", .{ idx + 1, total, @as(u32, @intFromFloat(sz.w)), @as(u32, @intFromFloat(sz.h)) }) catch "";
        }
        break :blk std.fmt.bufPrint(&buf, "{d} / {d}", .{ idx + 1, total }) catch "";
    };
    var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 1.0,
        .gravity_y = 0.0,
        .margin = .{ .x = 0, .y = 12, .w = 14, .h = 0 },
        .background = true,
        .color_fill = .{ .r = 0x0a, .g = 0x0f, .b = 0x14, .a = 0xD9 },
        .border = dvui.Rect.all(1),
        .color_border = .{ .r = 0x2b, .g = 0x37, .b = 0x42 },
        .corner_radius = dvui.Rect.all(10),
        .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
    });
    defer pill.deinit();
    dvui.labelNoFmt(@src(), txt, .{}, .{ .color_text = tokens.toDvui(tokens.active.ink2, dvui.Color), .font = dvui.Font.theme(.mono) });
}

/// Small cover thumbnail inset for the V3 hero bottom row.
fn heroCoverInset(bytes_opt: ?[]const u8, thread_id: u64) void {
    const ring = tokens.toDvui(tokens.active.acc_dim, dvui.Color); // teal hairline (Cinemascope)
    if (bytes_opt) |bytes| {
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{ .bytes = bytes, .name = "hero-cover" } },
            .shrink = .ratio,
        }, .{
            .id_extra = thread_id,
            .gravity_x = 0.5,
            .gravity_y = 1.0,
            .min_size_content = .{ .w = 92, .h = 124 },
            .max_size_content = .{ .w = 92, .h = 124 },
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(5),
            .color_border = ring,
        });
        return;
    }
    var box = dvui.box(@src(), .{}, .{
        .id_extra = thread_id,
        .gravity_x = 0.5,
        .gravity_y = 1.0,
        .min_size_content = .{ .w = 92, .h = 124 },
        .max_size_content = .{ .w = 92, .h = 124 },
        .background = true,
        .color_fill = .{ .r = 0x16, .g = 0x0c, .b = 0x12 },
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(5),
        .color_border = ring,
    });
    box.deinit();
}

/// V3 hero chip row: engine · status · NEW update · stars.
fn renderHeroChips(game: *const library.Game) void {
    const t = tokens.active;
    var chips = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    defer chips.deinit();
    if (game.engine != .unknown) {
        const fill = components.engineBadgeColor(game.engine);
        comp.chip(@src(), .{
            .label = components.engineShortLabel(game.engine),
            .fill = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
            .text = .{ .r = 0xff, .g = 0xff, .b = 0xff },
            .border = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
        }, .{ .id_extra = game.f95_thread_id ^ 0xE1, .gravity_y = 0.5, .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 } });
    }
    if (game.dev_status != .unknown) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        const fill = components.devStatusColor(game.dev_status);
        comp.chip(@src(), .{
            .label = components.devStatusShortLabel(game.dev_status),
            .fill = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
            .text = .{ .r = 0xff, .g = 0xff, .b = 0xff },
            .border = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = fill.a },
        }, .{ .id_extra = game.f95_thread_id ^ 0xE2, .gravity_y = 0.5, .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 } });
    }
    if (game.rating) |r| {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        renderRatingStars(r);
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        var lbl_buf: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&lbl_buf, "{d:.1} ({d})", .{ r, game.vote_count orelse 0 }) catch "";
        dvui.labelNoFmt(@src(), s, .{}, .{ .gravity_y = 0.5, .color_text = tokens.toDvui(t.ink2, dvui.Color) });
    }
}

/// Wrap a Library mutation in toast surfacing. The previous pattern
/// `frame.lib.upsertGame(game) catch {};` silently dropped DB write
/// errors — user changes notes / rating / sandbox, click does
/// nothing, no feedback. Push an error toast on failure so the user
/// at least sees that the save didn't stick.
fn saveOrToast(frame: *Frame, what: []const u8, err_opt: anyerror!void) void {
    err_opt catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Save failed ({s}): {s}", .{ what, @errorName(e) }) catch "Save failed";
        frame.state.notifyErr(msg);
    };
}

fn findLabelById(all: []const library.UserLabel, id: i64) ?library.UserLabel {
    for (all) |l| {
        if (l.id == id) return l;
    }
    return null;
}

/// Create (or re-use by name) the label in the input buffer and assign it to
/// `game`, then clear the buffer. No-op on a blank input.
fn addLabelFromInput(frame: *Frame, game: *library.Game) void {
    const buf = &frame.state.label_input_buf;
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    const name = std.mem.trim(u8, buf[0..end], " \t\r\n");
    if (name.len == 0) return;
    const id = frame.lib.createLabel(name, null) catch |e| {
        saveOrToast(frame, "label", e);
        return;
    };
    saveOrToast(frame, "label", frame.lib.addGameLabel(game.f95_thread_id, id));
    @memset(buf, 0);
}

/// "Labels" config row — assigned label chips (removable) + an add box. Part
/// of the Overview "Your settings · Tracking" group.
fn renderLabelsRow(frame: *Frame, game: *library.Game) void {
    const all_opt: ?[]library.UserLabel = frame.lib.listLabels() catch null;
    defer if (all_opt) |a| frame.lib.freeLabels(a);
    const all: []const library.UserLabel = all_opt orelse &.{};
    const assigned_opt: ?[]i64 = frame.lib.labelsForGame(game.f95_thread_id) catch null;
    defer if (assigned_opt) |a| frame.lib.alloc.free(a);
    const assigned: []const i64 = assigned_opt orelse &.{};

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = game.f95_thread_id ^ 0x1AB5,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
    });
    defer row.deinit();
    dvui.label(@src(), "Labels", .{}, .{
        .min_size_content = .{ .w = 120, .h = 20 },
        .gravity_y = 0.5,
        .color_text = style.labelDim(),
    });

    var flow = dvui.flexbox(@src(), .{}, .{ .expand = .horizontal });
    defer flow.deinit();

    for (assigned) |lid| {
        const lbl = findLabelById(all, lid) orelse continue;
        const id_extra: u64 = @bitCast(lid);
        var chip_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id_extra,
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 4 },
        });
        defer chip_row.deinit();
        const col = if (lbl.color) |c| (tokens.parseHex(c) orelse tokens.active.acc) else tokens.active.acc;
        comp.chip(@src(), .{
            .label = lbl.name,
            .fill = col,
            .text = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
            .border = col,
            .scale = 0.8,
        }, .{
            .id_extra = id_extra,
            .gravity_y = 0.5,
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            .corner_radius = .all(3),
        });
        if (components.iconOnly(@src(), "remove-label", entypo.cross, .{ .id_extra = id_extra, .gravity_y = 0.5 })) {
            saveOrToast(frame, "label", frame.lib.removeGameLabel(game.f95_thread_id, lid));
        }
    }

    const te = style.textEntry(@src(), .{ .text = .{ .buffer = &frame.state.label_input_buf } }, .{
        .min_size_content = .{ .w = 150, .h = 26 },
        .gravity_y = 0.5,
    });
    te.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
    if (components.iconButton(@src(), "Add", entypo.plus, .{ .style = .highlight, .gravity_y = 0.5 })) {
        addLabelFromInput(frame, game);
    }
}

/// User-selectable engines for the manual "edit details" form — every
/// real engine plus `other`, excluding the `unknown` sentinel.
const EDITABLE_ENGINES = [_]library.Engine{
    .renpy,  .rpgm_mv,       .rpgm_mz, .rpgm_vx, .unity,
    .unreal, .html,          .flash,   .java,    .wolf_rpg,
    .qsp,    .tyranobuilder, .twine,   .adrift,  .rags,
    .tads,   .webgl,         .other,
};

fn engineEditLabels() []const []const u8 {
    const S = struct {
        const labels = blk: {
            var l: [EDITABLE_ENGINES.len][]const u8 = undefined;
            for (EDITABLE_ENGINES, 0..) |e, i| l[i] = components.engineShortLabel(e);
            break :blk l;
        };
    };
    return &S.labels;
}

fn engineIndex(e: library.Engine) usize {
    for (EDITABLE_ENGINES, 0..) |cand, i| if (cand == e) return i;
    return EDITABLE_ENGINES.len - 1; // .other
}

/// Trimmed view of a NUL-terminated text-entry buffer.
fn nulSlice(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return std.mem.trim(u8, buf[0..end], " \t\r\n");
}

/// Seed the edit-form buffers from the game's current fields and open it.
fn openDetailEdit(state: *state_mod.State, game: *const library.Game) void {
    @memset(&state.edit_name_buf, 0);
    @memset(&state.edit_dev_buf, 0);
    @memset(&state.edit_ver_buf, 0);
    const nn = @min(game.name.len, state.edit_name_buf.len - 1);
    @memcpy(state.edit_name_buf[0..nn], game.name[0..nn]);
    if (game.developer) |d| {
        const dn = @min(d.len, state.edit_dev_buf.len - 1);
        @memcpy(state.edit_dev_buf[0..dn], d[0..dn]);
    }
    if (game.latest_version) |v| {
        const vn = @min(v.len, state.edit_ver_buf.len - 1);
        @memcpy(state.edit_ver_buf[0..vn], v[0..vn]);
    }
    state.edit_engine_idx = engineIndex(game.engine);
    state.edit_details_for = game.f95_thread_id;
}

/// Manual edit form for a game's identity fields (name/dev/version/engine).
/// Shown in place of the byline while `state.edit_details_for` matches.
fn renderDetailEditForm(frame: *Frame, game: *library.Game) void {
    const state = frame.state;
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = game.f95_thread_id ^ 0xED,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 9, .w = 0, .h = 9 },
        .border = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        .color_border = style.borderColor(),
    });
    defer box.deinit();

    editField(@src(), "Name", &state.edit_name_buf);
    editField(@src(), "Developer", &state.edit_dev_buf);
    editField(@src(), "Version", &state.edit_ver_buf);
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 } });
        defer row.deinit();
        dvui.label(@src(), "Engine", .{}, .{ .min_size_content = .{ .w = 90, .h = 26 }, .gravity_y = 0.5, .color_text = style.labelDim() });
        var picked: usize = state.edit_engine_idx;
        if (style.dropdown(@src(), engineEditLabels(), .{ .choice = &picked }, .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 200, .h = 26 } })) {
            state.edit_engine_idx = picked;
        }
    }
    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 0, .y = 6, .w = 0, .h = 0 } });
        defer btns.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (components.iconButton(@src(), "Cancel", entypo.cross, .{})) {
            state.edit_details_for = null;
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (components.iconButton(@src(), "Save", entypo.check, .{ .style = .highlight })) {
            const eng = EDITABLE_ENGINES[@min(state.edit_engine_idx, EDITABLE_ENGINES.len - 1)];
            saveOrToast(frame, "game", frame.lib.setGameInfo(game, nulSlice(&state.edit_name_buf), nulSlice(&state.edit_dev_buf), nulSlice(&state.edit_ver_buf), eng));
            state.game_edit_gen +%= 1; // in-place edit → refresh the library filter cache
            state.edit_details_for = null;
        }
    }
}

/// One labelled text-entry row in the edit form.
fn editField(src: std.builtin.SourceLocation, label: []const u8, buf: []u8) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 } });
    defer row.deinit();
    dvui.label(@src(), "{s}", .{label}, .{ .min_size_content = .{ .w = 90, .h = 26 }, .gravity_y = 0.5, .color_text = style.labelDim() });
    const te = style.textEntry(@src(), .{ .text = .{ .buffer = buf } }, .{ .expand = .horizontal, .min_size_content = .{ .w = 240, .h = 26 }, .gravity_y = 0.5 });
    te.deinit();
}

/// Read-only game facts (Overview tab): version · developer · last-updated ·
/// last-synced + Sync now.
/// One mono fact in the About byline: `LABEL value`, with a right divider.
fn bylineItem(label: []const u8, value: []const u8, acc: bool) void {
    const t = tokens.active;
    const mono = dvui.Font.theme(.mono);
    var item = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = @intFromPtr(label.ptr),
        .gravity_y = 0.5,
        .padding = .{ .x = 14, .y = 0, .w = 14, .h = 0 },
        .border = .{ .x = 0, .y = 0, .w = 1, .h = 0 },
        .color_border = style.borderColor(),
    });
    defer item.deinit();
    dvui.labelNoFmt(@src(), label, .{}, .{ .gravity_y = 0.5, .color_text = style.labelDim(), .font = mono.withSize(mono.size * 0.72) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
    dvui.labelNoFmt(@src(), value, .{}, .{ .gravity_y = 0.5, .color_text = tokens.toDvui(if (acc) t.acc else t.ink, dvui.Color), .font = mono.withSize(mono.size * 0.85) });
}

/// "About" — one glanceable byline of facts on a divider rule (Overview
/// layout A), replacing the old vertical key/value grid.
fn renderDetailFacts(frame: *Frame, game: *library.Game) void {
    const t = tokens.active;
    if (frame.state.edit_details_for == game.f95_thread_id) {
        renderDetailEditForm(frame, game);
        return;
    }
    var bar = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .id_extra = game.f95_thread_id ^ 0xF9,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 9, .w = 0, .h = 9 },
        .border = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        .color_border = style.borderColor(),
    });
    defer bar.deinit();

    if (game.developer) |d| {
        if (d.len > 0) bylineItem("DEV", d, false);
    }
    bylineItem("ENGINE", components.engineShortLabel(game.engine), true);
    if (game.latest_version) |v| bylineItem("VERSION", v, false);
    if (game.last_updated_at) |ts| {
        var buf: [32]u8 = undefined;
        const dt = components.formatUtcDateTime(&buf, ts) catch "—";
        bylineItem("UPDATED", dt, false);
    }
    // SYNCED + Sync button (no divider after).
    {
        var item = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .padding = .{ .x = 14, .y = 0, .w = 0, .h = 0 } });
        defer item.deinit();
        const mono = dvui.Font.theme(.mono);
        dvui.labelNoFmt(@src(), "SYNCED", .{}, .{ .gravity_y = 0.5, .color_text = style.labelDim(), .font = mono.withSize(mono.size * 0.72) });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        var dt_buf: [40]u8 = undefined;
        const dt = if (game.last_scraped_at) |ts| components.formatUtcDateTime(&dt_buf, ts) catch "—" else "never";
        dvui.labelNoFmt(@src(), dt, .{}, .{ .gravity_y = 0.5, .color_text = tokens.toDvui(t.ink, dvui.Color), .font = mono.withSize(mono.size * 0.85) });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (components.iconButton(@src(), "Sync now", entypo.cycle, .{ .style = .control, .gravity_y = 0.5, .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 } })) {
            actions.syncGame(frame, game);
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        // Manual edit — for orphaned imports / non-F95 games the scraper
        // can't fill in (name/developer/version/engine).
        if (components.iconButton(@src(), "Edit", entypo.pencil, .{ .style = .control, .gravity_y = 0.5, .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 } })) {
            openDetailEdit(frame.state, game);
        }
    }
}

/// Per-game CONFIG form (Settings tab): status · rating · sandbox · version
/// pin · labels · engine tools · universal-mod opt-outs · auto-update ·
/// custom launch. No facts, no file/launch actions — those moved out.
fn renderGameConfig(frame: *Frame, game: *library.Game) void {
    var row_id: u32 = 1;

    // Two columns (Overview layout A): Tracking | Launch & updates.
    var cols = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = game.f95_thread_id ^ 0xFA,
        .expand = .horizontal,
    });
    defer cols.deinit();

    var leftcol = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    detailSectionHeader("Tracking", false);
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_id,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        });
        defer row.deinit();
        row_id += 1;
        dvui.label(@src(), "Your status", .{}, .{
            .min_size_content = .{ .w = 120, .h = 20 },
            .gravity_y = 0.5,
            .color_text = style.labelDim(),
        });
        const labels = completionStatusLabels();
        var picked: usize = @intFromEnum(game.completion_status);
        if (style.dropdown(@src(), labels, .{ .choice = &picked }, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 200, .h = 26 },
        })) {
            game.completion_status = @enumFromInt(picked);
            saveOrToast(frame, "game", frame.lib.upsertGame(game));
            // In-place edit: force the library filter cache to re-evaluate so
            // a status change drops the game out of an active status filter
            // this frame instead of lingering until an unrelated refresh.
            frame.state.game_edit_gen +%= 1;
        }
    }
    {
        var row = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
            .id_extra = row_id,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        });
        defer row.deinit();
        row_id += 1;
        dvui.label(@src(), "Your rating", .{}, .{
            .min_size_content = .{ .w = 120, .h = 20 },
            .gravity_y = 0.5,
            .color_text = style.labelDim(),
        });
        const ur_int: u8 = if (game.user_rating) |r| @as(u8, @intFromFloat(@round(r))) else 0;
        var n: u8 = 1;
        while (n <= 5) : (n += 1) {
            const filled = ur_int >= n;
            const tvg = if (filled) entypo.star else entypo.star_outlined;
            if (dvui.buttonIcon(@src(), "rate", tvg, .{}, .{}, .{
                .id_extra = n,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 22, .h = 22 },
                .color_text = if (filled)
                    tokens.toDvui(tokens.active.acc, dvui.Color)
                else
                    null,
            })) {
                if (ur_int == n) game.user_rating = null else game.user_rating = @floatFromInt(n);
                saveOrToast(frame, "game", frame.lib.upsertGame(game));
            }
        }
    }
    renderLabelsRow(frame, game);
    leftcol.deinit();

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 28, .h = 1 } });

    var rightcol = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    detailSectionHeader("Launch & updates", false);
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_id,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        });
        defer row.deinit();
        row_id += 1;
        dvui.label(@src(), "Sandbox", .{}, .{
            .min_size_content = .{ .w = 120, .h = 20 },
            .gravity_y = 0.5,
            .color_text = style.labelDim(),
        });
        const labels = sandboxOverrideLabels(frame.state.sandbox_default);
        var picked: usize = @intFromEnum(game.sandbox);
        if (style.dropdown(@src(), labels, .{ .choice = &picked }, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 220, .h = 26 },
        })) {
            game.sandbox = @enumFromInt(picked);
            saveOrToast(frame, "game", frame.lib.upsertGame(game));
        }
    }

    // Version pin — hold the game on its current version (suppresses
    // auto-update). Pin/unpin writes a single column; we mirror the change
    // in the in-memory snapshot so the row updates without a reload.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_id,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        });
        defer row.deinit();
        row_id += 1;
        dvui.label(@src(), "Version pin", .{}, .{
            .min_size_content = .{ .w = 120, .h = 20 },
            .gravity_y = 0.5,
            .color_text = style.labelDim(),
        });
        if (game.pinned_version) |pv| {
            var pbuf: [80]u8 = undefined;
            const lbl = std.fmt.bufPrint(&pbuf, "Pinned to v{s}", .{version_mod.stripVPrefix(pv)}) catch "Pinned";
            dvui.labelNoFmt(@src(), lbl, .{}, .{ .gravity_y = 0.5 });
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
            if (components.iconButton(@src(), "Unpin", entypo.cross, .{ .gravity_y = 0.5 })) {
                saveOrToast(frame, "pin", frame.lib.setPinnedVersion(game.f95_thread_id, null));
                frame.lib.alloc.free(pv);
                game.pinned_version = null;
            }
        } else if (game.latest_version) |lv| {
            var pbuf: [80]u8 = undefined;
            const lbl = std.fmt.bufPrint(&pbuf, "Pin to v{s}", .{version_mod.stripVPrefix(lv)}) catch "Pin";
            if (components.iconButton(@src(), lbl, entypo.bookmark, .{ .gravity_y = 0.5 })) {
                saveOrToast(frame, "pin", frame.lib.setPinnedVersion(game.f95_thread_id, lv));
                game.pinned_version = frame.lib.alloc.dupe(u8, lv) catch null;
            }
        } else {
            dvui.label(@src(), "no version known yet", .{}, .{ .gravity_y = 0.5, .color_text = style.labelDim() });
        }
    }

    // (Labels moved up into the Tracking group — see renderLabelsRow.)
    // (Engine tools moved to the Tools tab — renderEngineTools.)

    // Per-game universal-mod opt-outs — list the engine's universal mods with
    // a checkbox each (checked = applied to this game).
    {
        const umods_opt: ?[]library.UniversalMod = frame.lib.listUniversalMods(game.engine) catch null;
        defer if (umods_opt) |m| frame.lib.freeUniversalMods(m);
        const umods = umods_opt orelse &.{};
        if (umods.len > 0) {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = row_id,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
            });
            defer row.deinit();
            row_id += 1;
            dvui.label(@src(), "Universal mods", .{}, .{
                .min_size_content = .{ .w = 120, .h = 20 },
                .gravity_y = 0.5,
                .color_text = style.labelDim(),
            });
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
            defer col.deinit();
            for (umods) |m| {
                const disabled = frame.lib.isUniversalModDisabled(game.f95_thread_id, m.id) catch false;
                var enabled = !disabled;
                if (dvui.checkbox(@src(), &enabled, m.name, .{ .id_extra = @as(u64, @bitCast(m.id)) })) {
                    saveOrToast(frame, "mod toggle", frame.lib.setUniversalModDisabled(game.f95_thread_id, m.id, !enabled));
                }
            }
        }
    }

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_id,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        });
        defer row.deinit();
        row_id += 1;
        dvui.label(@src(), "Auto-update", .{}, .{
            .min_size_content = .{ .w = 120, .h = 20 },
            .gravity_y = 0.5,
            .color_text = style.labelDim(),
        });
        const labels = autoUpdateOverrideLabels(frame.state.auto_update_default);
        var picked: usize = @intFromEnum(game.auto_update);
        if (style.dropdown(@src(), labels, .{ .choice = &picked }, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 220, .h = 26 },
        })) {
            game.auto_update = @enumFromInt(picked);
            saveOrToast(frame, "game", frame.lib.upsertGame(game));
        }
    }

    renderCustomLaunchRow(frame, game);
    rightcol.deinit();
}

/// Per-install custom launch override editor (applies to the latest install).
/// Empty fields clear the override (back to the heuristic launcher).
fn renderCustomLaunchRow(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    if (state.launch_cfg_for_thread != game.f95_thread_id) {
        @memset(&state.launch_exec_buf, 0);
        @memset(&state.launch_args_buf, 0);
        state.launch_cfg_has_install = false;
        if (frame.lib.latestInstallForGame(game.f95_thread_id) catch null) |inst| {
            defer frame.lib.freeInstall(inst);
            state.launch_cfg_install_id = inst.id;
            state.launch_cfg_has_install = true;
            if (inst.executable) |e| {
                const n = @min(e.len, state.launch_exec_buf.len - 1);
                @memcpy(state.launch_exec_buf[0..n], e[0..n]);
            }
            if (inst.launch_args) |a| {
                const n = @min(a.len, state.launch_args_buf.len - 1);
                @memcpy(state.launch_args_buf[0..n], a[0..n]);
            }
        }
        state.launch_cfg_for_thread = game.f95_thread_id;
    }
    if (!state.launch_cfg_has_install) return;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
    });
    defer row.deinit();
    dvui.label(@src(), "Custom launch", .{}, .{
        .min_size_content = .{ .w = 120, .h = 20 },
        .gravity_y = 0.5,
        .color_text = style.labelDim(),
    });
    const te_exe = style.textEntry(@src(), .{
        .text = .{ .buffer = &state.launch_exec_buf },
        .placeholder = "executable (e.g. wine game.exe)",
    }, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 170, .h = 26 },
    });
    te_exe.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
    const te_args = style.textEntry(@src(), .{
        .text = .{ .buffer = &state.launch_args_buf },
        .placeholder = "arguments (e.g. --fullscreen --skip-intro)",
    }, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 170, .h = 26 },
        .id_extra = 1,
    });
    te_args.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
    if (style.button(@src(), "Save", .{}, .{ .gravity_y = 0.5 })) {
        const exe = std.mem.trim(u8, std.mem.sliceTo(&state.launch_exec_buf, 0), " \t");
        const args = std.mem.trim(u8, std.mem.sliceTo(&state.launch_args_buf, 0), " \t");
        const id: []const u8 = &state.launch_cfg_install_id;
        saveOrToast(frame, "launch", frame.lib.setInstallExecutable(id, if (exe.len > 0) exe else null));
        saveOrToast(frame, "launch", frame.lib.setInstallLaunchArgs(id, if (args.len > 0) args else null));
    }
}

fn autoUpdateOverrideLabels(global_default_on: bool) []const []const u8 {
    if (global_default_on) {
        return &[_][]const u8{
            "Use default (on)",
            "Always auto-update",
            "Never auto-update",
        };
    }
    return &[_][]const u8{
        "Use default (off)",
        "Always auto-update",
        "Never auto-update",
    };
}

fn sandboxOverrideLabels(global_default_on: bool) []const []const u8 {
    if (global_default_on) {
        return &[_][]const u8{
            "Use default (on)",
            "Always sandbox",
            "Never sandbox",
        };
    }
    return &[_][]const u8{
        "Use default (off)",
        "Always sandbox",
        "Never sandbox",
    };
}

const FactsValue = union(enum) {
    text: []const u8,
};

fn factsRow(row_id: *u32, label: []const u8, value: FactsValue) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = row_id.*,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
    });
    defer row.deinit();
    row_id.* += 1;
    dvui.labelNoFmt(@src(), label, .{}, .{
        .min_size_content = .{ .w = 120, .h = 18 },
        .gravity_y = 0.5,
        .color_text = style.labelDim(),
    });
    switch (value) {
        .text => |t| dvui.labelNoFmt(@src(), t, .{}, .{
            .gravity_y = 0.5,
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 18 },
        }),
    }
}

/// Human-friendly labels for `library.CompletionStatus`.
fn completionStatusLabels() []const []const u8 {
    const labels = &[_][]const u8{
        "Not started",
        "In queue",
        "In progress",
        "Completed",
        "Replaying",
        "Abandoned",
        "Waiting for update",
    };
    return labels;
}

/// Short ASCII source-of-install tag prepended to install picker
/// entries. Recipe entries get no prefix.
fn sourceTag(s: library.InstallSource) []const u8 {
    return switch (s) {
        .recipe => "",
        .manual => "[file] ",
        .rpdl => "[rpdl] ",
        .imported => "[imported] ",
    };
}

fn renderManualInstallPanel(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

    {
        const path = state.manualInstallPathSlice();
        const version = state.manualInstallVersionSlice();
        // Derive the version from the archive the user pointed at, when the
        // field is empty OR still holds the auto-filled `latest_version`
        // placeholder. A real user edit (autofilled=false, non-empty) is
        // never clobbered. Fixes §2.12 #10: installing an older archive
        // while the row was pre-filled with the thread's latest version.
        if (path.len > 0 and (version.len == 0 or state.manual_install_version_autofilled)) {
            if (version_mod.fromArchivePath(path)) |guess| {
                const n = @min(guess.len, state.manual_install_version_buf.len - 1);
                @memcpy(state.manual_install_version_buf[0..n], guess[0..n]);
                state.manual_install_version_buf[n] = 0;
                state.manual_install_version_autofilled = false;
            }
        }
    }

    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = style.cardFill(),
        .color_border = style.borderColor(),
    });
    defer panel.deinit();

    dvui.label(@src(), "Install from file", .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    components.settingsHelpText(
        "Point at any .zip / .7z / .tar.gz on disk and we'll extract it as a new install. " ++
            "The version is required and lives on the install row; the name is optional and lets " ++
            "you keep multiple installs of the same version apart (e.g. \"vanilla\", \"modded\").",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    manualInstallPathRow(frame);
    manualInstallRow("Version", &state.manual_install_version_buf, 2, &state.manual_install_version_autofilled);
    manualInstallRow("Name (optional)", &state.manual_install_name_buf, 3, null);

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
    });
    defer btn_row.deinit();
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (components.iconButton(@src(), "Cancel", entypo.cross, .{})) {
        state.manual_install_open = false;
    }
    if (components.iconButton(@src(), "Install", entypo.upload, .{ .style = .highlight })) {
        actions.startManualInstall(
            frame,
            game.f95_thread_id,
            state.manualInstallPathSlice(),
            state.manualInstallVersionSlice(),
            state.manualInstallNameSlice(),
        );
        if (frame.state.manual_install_jobs) |list_ptr| {
            if (list_ptr.items.len > 0) {
                state.resetManualInstallFields();
                state.manual_install_open = false;
            }
        }
    }
}

fn manualInstallPathRow(frame: *Frame) void {
    const state = frame.state;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = 1,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
    });
    defer row.deinit();
    dvui.label(@src(), "Archive path", .{}, .{
        .min_size_content = .{ .w = 120, .h = 22 },
        .gravity_y = 0.5,
        .color_text = helpTextColor(),
    });
    const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.manual_install_path_buf } }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 240, .h = 24 },
        .gravity_y = 0.5,
    });
    te.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
    if (components.iconButton(@src(), "Browse\u{2026}", entypo.folder, .{
        .gravity_y = 0.5,
    })) {
        const filters = [_]file_picker.FilterItem{
            .{ .name = "Archives", .spec = "zip,7z,tar.gz,tgz,rar" },
        };
        const picked = file_picker.open(frame.lib.alloc, &filters, null) catch |e| blk: {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "File picker failed: {s}", .{@errorName(e)}) catch "File picker failed.";
            state.setDownloadMsg(msg);
            break :blk null;
        };
        if (picked) |p| {
            defer frame.lib.alloc.free(p);
            @memset(&state.manual_install_path_buf, 0);
            const n = @min(p.len, state.manual_install_path_buf.len - 1);
            @memcpy(state.manual_install_path_buf[0..n], p[0..n]);

            // Exact recipe match by archive hash wins (authoritative) over
            // both the latest-version placeholder and the filename guess the
            // render block derives. Skip only when the user typed a version.
            if (state.manualInstallVersionSlice().len == 0 or state.manual_install_version_autofilled) {
                if (actions.lookupVersionFromArchiveSha(frame, p)) |hit| {
                    defer frame.lib.alloc.free(hit);
                    const vn = @min(hit.len, state.manual_install_version_buf.len - 1);
                    @memcpy(state.manual_install_version_buf[0..vn], hit[0..vn]);
                    state.manual_install_version_buf[vn] = 0;
                    state.manual_install_version_autofilled = false;
                }
            }
        }
    }
}

fn manualInstallRow(label: []const u8, buf: []u8, id_extra: u32, autofill_flag: ?*bool) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
    });
    defer row.deinit();
    dvui.labelNoFmt(@src(), label, .{}, .{
        .min_size_content = .{ .w = 120, .h = 22 },
        .gravity_y = 0.5,
        .color_text = style.labelDim(),
    });
    const te = style.textEntry(@src(), .{ .text = .{ .buffer = buf } }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 240, .h = 24 },
        .gravity_y = 0.5,
    });
    // A keystroke in this field means the value is now a user choice —
    // stop archive detection from overriding it.
    if (autofill_flag) |f| {
        if (te.text_changed) f.* = false;
    }
    te.deinit();
}

fn renderConvertHelp() void {
    var help = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = style.cardFill(),
        .color_border = style.borderColor(),
    });
    defer help.deinit();

    dvui.label(@src(), "What the toolbar buttons do", .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    const help_lines = [_][]const u8{
        "Launch / Stop - run or kill the picked install. Grayed when there's no install.",
        "Download - fetch the game via RPDL torrent (with donor-DDL fallback when you're logged in to F95).",
        "Manual install - point at a file you already downloaded and install it.",
        "Convert - extract + patch a Windows build into a Linux-native install. Idempotent.",
        "Folder - open the picked install's directory in your file manager.",
        "Saves / Backup - open or snapshot the per-game save directory.",
        "Mods - per-game mods page (queue installs, manage recipes, pick uninstall safety).",
    };
    for (help_lines) |line| {
        dvui.label(@src(), "- {s}", .{line}, .{
            .id_extra = std.hash.Wyhash.hash(0, line),
            .color_text = helpTextColor(),
        });
    }
}

// ============================================================
//  Image popup + install management popups
// ============================================================

/// V4 lightbox (detail-variants.html) — opened by clicking the V3 banner.
/// Full-window carousel: "<name> — screenshot" + "N / total · W×H" counter + ✕
/// in the header, the big image with ‹ › arrows, and a centred filmstrip below.
fn renderImagePopup(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    if (!state.image_popup_open) return;
    if (state.carousel_for_thread != game.f95_thread_id) {
        state.image_popup_open = false;
        return;
    }

    const total: usize = 1 + game.screenshots.len;
    const idx = @min(state.carousel_index, total - 1);
    const bytes_opt: ?[]const u8 = if (idx == 0)
        actions.coverFullBytes(frame, game.f95_thread_id)
    else
        actions.slideBytes(frame, game.f95_thread_id, idx);

    // Track the OS window: fill it minus a small margin, every frame, so the
    // lightbox scales with window resizes (and never drifts off-screen).
    const m: f32 = 20;
    const wr = dvui.windowRect();
    state.image_popup_rect = .{
        .x = m,
        .y = m,
        .w = @max(320, wr.w - 2 * m),
        .h = @max(240, wr.h - 2 * m),
    };
    var fw = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.image_popup_open,
        .rect = &state.image_popup_rect,
        .resize = .none, // it's a fixed full-window lightbox — no edge resize
    }, .{
        .background = true,
        .color_fill = .{ .r = 0x06, .g = 0x0a, .b = 0x0e, .a = 0xF2 },
    });
    defer fw.deinit();
    fw.dragAreaSet(.{}); // and no click-drag move (default drag area = whole window)

    // header: subject (left) · counter+resolution (right) · ✕
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 14, .y = 10, .w = 10, .h = 8 } });
        defer hdr.deinit();
        var nb: [160]u8 = undefined;
        const subj = std.fmt.bufPrint(&nb, "{s} — {s}", .{ game.name, if (idx == 0) "cover" else "screenshot" }) catch game.name;
        dvui.labelNoFmt(@src(), subj, .{}, .{ .gravity_y = 0.5, .color_text = style.labelDim(), .font = dvui.Font.theme(.mono) });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        var cb: [64]u8 = undefined;
        const ctr = blk: {
            if (bytes_opt) |b| {
                const sz = dvui.imageSize(.{ .imageFile = .{ .bytes = b, .name = "lb-sz" } }) catch dvui.Size{ .w = 0, .h = 0 };
                if (sz.w > 0) break :blk std.fmt.bufPrint(&cb, "{d} / {d} · {d}×{d}", .{ idx + 1, total, @as(u32, @intFromFloat(sz.w)), @as(u32, @intFromFloat(sz.h)) }) catch "";
            }
            break :blk std.fmt.bufPrint(&cb, "{d} / {d}", .{ idx + 1, total }) catch "";
        };
        dvui.labelNoFmt(@src(), ctr, .{}, .{ .gravity_y = 0.5, .color_text = style.labelDim(), .font = dvui.Font.theme(.mono) });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
        if (components.iconOnly(@src(), "lb-close", entypo.cross, .{ .gravity_y = 0.5 })) state.image_popup_open = false;
    }

    // body: image fit-by-ratio + centred (like the hero), with big edge arrows
    // overlaid — not a flex row (which left-anchors the image).
    {
        var body = dvui.overlay(@src(), .{ .expand = .both, .padding = .{ .x = 8, .y = 0, .w = 8, .h = 8 } });
        defer body.deinit();
        if (bytes_opt) |b| {
            _ = dvui.image(@src(), .{ .source = .{ .imageFile = .{ .bytes = b, .name = "lb-img" } }, .shrink = .ratio }, .{
                .id_extra = idx,
                .expand = .ratio,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
        } else {
            dvui.label(@src(), "(image not available)", .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        }
        if (total > 1) {
            if (heroNavArrow(@src(), "lb-prev", entypo.chevron_left, 0.0)) state.carousel_index = (idx + total - 1) % total;
            if (heroNavArrow(@src(), "lb-next", entypo.chevron_right, 1.0)) state.carousel_index = (idx + 1) % total;
        }
    }

    // bottom filmstrip (centred)
    if (total > 1) {
        var strip = dvui.flexbox(@src(), .{ .justify_content = .center }, .{ .expand = .horizontal, .padding = .{ .x = 8, .y = 8, .w = 8, .h = 10 } });
        defer strip.deinit();
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const tb = actions.thumbBytes(frame, game.f95_thread_id, i);
            if (renderRibbonThumb(tb, i, i == idx, game.f95_thread_id)) state.carousel_index = i;
        }
    }
}

fn renderInstallManagePopups(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    if (state.manage_action == .none) return;
    const sel_id = state.manage_install_id orelse {
        state.manage_action = .none;
        return;
    };

    const installs = frame.lib.listInstalls(game.f95_thread_id) catch &[_]library.Install{};
    defer frame.lib.freeInstalls(@constCast(installs));
    var found_idx: ?usize = null;
    for (installs, 0..) |inst, i| {
        if (std.mem.eql(u8, inst.id[0..], sel_id[0..])) {
            found_idx = i;
            break;
        }
    }
    const idx = found_idx orelse {
        state.manage_action = .none;
        state.manage_install_id = null;
        return;
    };
    const inst = installs[idx];

    switch (state.manage_action) {
        .none => unreachable,
        .rename => renderRenameInstallPopup(frame, &inst),
        .delete => renderDeleteInstallPopup(frame, &inst),
    }
}

fn renderRenameInstallPopup(frame: *Frame, inst: *const library.Install) void {
    const state = frame.state;
    var open: bool = true;
    var fw = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &open,
    }, .{
        .min_size_content = .{ .w = 420, .h = 180 },
    });
    defer fw.deinit();

    _ = dvui.windowHeader("Rename install", "", &open);

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer body.deinit();

    var ver_buf: [128]u8 = undefined;
    const ver_text = std.fmt.bufPrint(&ver_buf, "Version: {s} ({s})", .{ inst.version, @tagName(inst.source) }) catch inst.version;
    dvui.labelNoFmt(@src(), ver_text, .{}, .{ .color_text = helpTextColor() });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    components.settingsHelpText(
        "A name disambiguates two installs of the same version (e.g. \"vanilla\", \"modded\"). " ++
            "Leave blank to clear and fall back to the bare version in the picker.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.label(@src(), "Name", .{}, .{
            .min_size_content = .{ .w = 80, .h = 24 },
            .gravity_y = 0.5,
            .color_text = helpTextColor(),
        });
        const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.manage_rename_buf } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 240, .h = 26 },
            .gravity_y = 0.5,
        });
        te.deinit();
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer btn_row.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (components.iconButton(@src(), "Cancel", entypo.cross, .{})) {
            open = false;
        }
        if (components.iconButton(@src(), "Save", entypo.check, .{ .style = .highlight })) {
            actions.doRenameInstall(frame, inst.id, state.manageRenameSlice());
            open = false;
        }
    }

    if (!open) {
        state.manage_action = .none;
        state.manage_install_id = null;
        @memset(&state.manage_rename_buf, 0);
    }
}

fn renderDeleteInstallPopup(frame: *Frame, inst: *const library.Install) void {
    const state = frame.state;
    var open: bool = true;
    var fw = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &open,
    }, .{
        .min_size_content = .{ .w = 460, .h = 200 },
    });
    defer fw.deinit();

    _ = dvui.windowHeader("Delete install", "", &open);

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer body.deinit();

    var ver_buf: [192]u8 = undefined;
    const have_name = if (inst.name) |n| n.len > 0 else false;
    const ver_text = if (have_name)
        std.fmt.bufPrint(&ver_buf, "{s} \u{2014} {s}  ({s})", .{ inst.version, inst.name.?, @tagName(inst.source) }) catch inst.version
    else
        std.fmt.bufPrint(&ver_buf, "{s}  ({s})", .{ inst.version, @tagName(inst.source) }) catch inst.version;
    dvui.labelNoFmt(@src(), ver_text, .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    components.settingsHelpText(
        "Deletes the install folder from disk AND removes the install record from the database. " ++
            "This cannot be undone — the path below will be `rm -rf`'d.",
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });

    var path_buf: [320]u8 = undefined;
    const path_text = std.fmt.bufPrint(&path_buf, "Path: {s}", .{inst.install_path}) catch inst.install_path;
    dvui.labelNoFmt(@src(), path_text, .{}, .{ .color_text = helpTextColor() });

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });
    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer btn_row.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (components.iconButton(@src(), "Cancel", entypo.cross, .{})) {
            open = false;
        }
        if (components.iconButton(@src(), "Delete from disk", entypo.trash, .{ .style = .err })) {
            actions.doDeleteInstall(frame, inst.id, inst.install_path);
            open = false;
        }
    }

    if (!open) {
        state.manage_action = .none;
        state.manage_install_id = null;
    }
}

// ============================================================
//  Tab bodies — Description / Changelog / Notes / Downloads
// ============================================================

/// A teal section heading with a trailing hairline (e.g. "About",
/// "Your settings"). `accent=false` is a dimmer subsection label.
fn detailSectionHeader(label: []const u8, accent: bool) void {
    const t = tokens.active;
    const mono = dvui.Font.theme(.mono);
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = @intFromPtr(label.ptr),
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 4, .w = 0, .h = 8 },
    });
    defer row.deinit();
    const factor: f32 = if (accent) 0.84 else 0.78;
    dvui.labelNoFmt(@src(), label, .{}, .{
        .gravity_y = 0.5,
        .color_text = tokens.toDvui(if (accent) t.acc else t.ink3, dvui.Color),
        .font = mono.withSize(mono.size * factor),
    });
    if (accent) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .gravity_y = 0.5 });
    }
}

/// Overview tab — reads top-to-bottom as a story: the description (what the
/// game IS) → an "About" facts block → the per-game settings, grouped.
fn renderOverview(frame: *Frame, game: *library.Game) void {
    // 1. Description — leads.
    renderWrappedText(game.description_md, "No description yet. Sync this game to populate.");

    // 2. About — a one-line byline of facts on a divider rule.
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 14 } });
    renderDetailFacts(frame, game);

    // 3. Your settings — two columns (Tracking | Launch & updates).
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 18 } });
    renderGameConfig(frame, game);
}

/// Settings / Manage tab — the per-game action set + configuration that used
/// to crowd the Overview pane: launch & version management, file + tool
/// actions, status/rating/sandbox/version-pin/labels/auto-update/custom-launch,
/// and the facts grid.
/// Tools tab — operates on the SELECTED install. Version picker up top (so the
/// tools below clearly apply to that version), then mkxp-z zoom + the engine
/// tools (Convert / Fix Compat / Ren'Py console / Extract / Decrypt).
fn renderToolsTab(frame: *Frame, game: *library.Game) void {
    const state = frame.state;
    renderActionRow(frame, game); // install picker + manage
    renderMkxpZSettingsRow(frame, game); // mkxp-z window zoom (engine config)
    renderDetailStatusLine(frame, game);
    if (state.convert_help_open) renderConvertHelp();
    if (state.manual_install_open) renderManualInstallPanel(frame, game);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 14 } });
    renderEngineTools(frame, game);
}

/// V3 compact meta bar — read-only `installed · dev · played` key/values, with
/// a Mods button on the right. Sits between the filmstrip and the tabs.
fn renderCompactMeta(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 2, .y = 8, .w = 2, .h = 10 },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = style.borderColor(),
    });
    defer bar.deinit();

    // INSTALLED — newest version, plus a "+N more" tail when several are
    // installed (the hero Play ▾ and the Overview list manage them).
    var inst_buf: [64]u8 = undefined;
    const inst_label: []const u8 = label: {
        const installs = frame.lib.listInstalls(game.f95_thread_id) catch {
            break :label if (frame.install_versions) |m| (m.get(game.f95_thread_id) orelse "—") else "—";
        };
        defer frame.lib.freeInstalls(@constCast(installs));
        if (installs.len == 0) break :label "—";
        if (installs.len == 1) break :label std.fmt.bufPrint(&inst_buf, "{s}", .{installs[0].version}) catch "—";
        break :label std.fmt.bufPrint(&inst_buf, "{s} \u{00b7} +{d} more", .{ installs[0].version, installs.len - 1 }) catch "—";
    };
    metaKv(@src(), "INSTALLED", inst_label);
    metaSep(@src());
    metaKv(@src(), "DEV", if (game.developer) |d| (if (d.len > 0) d else "—") else "—");
    metaSep(@src());
    {
        var pb: [40]u8 = undefined;
        const ps = if (game.last_played_at) |lp|
            components.formatUtcDateTime(&pb, lp) catch "—"
        else
            "never";
        metaKv(@src(), "PLAYED", ps);
    }
    metaSep(@src());
    // F95Zone identifier — the thread id is this game's primary key. Shown
    // as a clickable control that opens https://f95zone.to/threads/<id>/ in
    // the browser (actions.openInBrowser). Mirrors the pill used elsewhere.
    {
        var tid_buf: [32]u8 = undefined;
        const tid_str = std.fmt.bufPrint(&tid_buf, "F95 #{d}", .{game.f95_thread_id}) catch "F95";
        if (style.button(@src(), tid_str, .{}, .{
            .gravity_y = 0.5,
            .style = .control,
            .color_text = style.labelDim(),
        })) {
            actions.openInBrowser(frame, game.f95_thread_id);
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    // (Sandbox is a per-game setting — it lives in the Overview settings, not
    // here in the main GUI.)

    // Download / Install — acquisition, right beside Mods in the main GUI.
    renderDetailDownloadButton(frame, game);
    renderDetailInstallButton(frame, game);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });

    // ⊞ Mods (n) → per-game mods screen. n = enabled universal mods of this
    // engine that this game hasn't opted out of.
    const n_mods = gameModCount(frame, game);
    var mods_buf: [24]u8 = undefined;
    const mods_label = if (n_mods > 0)
        std.fmt.bufPrint(&mods_buf, "Mods ({d})", .{n_mods}) catch "Mods"
    else
        "Mods";
    if (components.iconButton(@src(), mods_label, entypo.tools, .{ .gravity_y = 0.5 })) {
        state.screen = .mods_for_game;
    }
}

/// Count of universal mods currently active on this game: enabled, of the
/// game's engine, and not opted-out for this game.
fn gameModCount(frame: *Frame, game: *const library.Game) usize {
    const mods = frame.lib.listUniversalMods(game.engine) catch return 0;
    defer frame.lib.freeUniversalMods(mods);
    var n: usize = 0;
    for (mods) |m| {
        if (!m.enabled) continue;
        const disabled = frame.lib.isUniversalModDisabled(game.f95_thread_id, m.id) catch false;
        if (!disabled) n += 1;
    }
    return n;
}

/// One `LABEL value` pair (mono) for the compact meta bar. `src` unique per call.
fn metaKv(src: std.builtin.SourceLocation, label: []const u8, value: []const u8) void {
    const t = tokens.active;
    const mono = dvui.Font.theme(.mono);
    var b = dvui.box(src, .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .padding = .{ .x = 14, .y = 0, .w = 14, .h = 0 } });
    defer b.deinit();
    dvui.labelNoFmt(@src(), label, .{}, .{
        .gravity_y = 0.5,
        .color_text = style.labelDim(),
        .font = mono.withSize(mono.size * 0.82),
    });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
    dvui.labelNoFmt(@src(), value, .{}, .{ .gravity_y = 0.5, .color_text = tokens.toDvui(t.ink, dvui.Color), .font = mono });
}

/// Small teal dot separating meta key/values (Cinemascope).
fn metaSep(src: std.builtin.SourceLocation) void {
    var d = dvui.box(src, .{}, .{
        .background = true,
        .color_fill = tokens.toDvui(tokens.active.acc_dim, dvui.Color),
        .corner_radius = dvui.Rect.all(2),
        .min_size_content = .{ .w = 3, .h = 3 },
        .gravity_y = 0.5,
    });
    d.deinit();
}

fn renderChangelogTab(frame: *Frame, game: *const library.Game) void {
    if (game.changelog_md) |text| {
        renderStructuredText(frame, text, game.f95_thread_id);
    } else {
        dvui.label(@src(), "No changelog scraped yet. Sync this game to populate.", .{}, .{});
    }
}

fn renderWrappedText(text: ?[]const u8, placeholder: []const u8) void {
    // cache_layout: text is immutable between frames (description /
    // reviews payload only changes on re-sync). Without the cache,
    // dvui re-runs line-break + glyph layout every frame — that's
    // what put `addTextEx` at 70 ms on `render detail` in the
    // earlier latency log.
    //
    // dvui's cache asserts that `bytes_seen` matches between frames
    // when `cache_layout` is on. A re-sync that swaps `description_md`
    // for a different-length string would trip that assertion and
    // panic. Mixing the text-content hash into `id_extra` makes a
    // different-content textLayout a different *widget identity* — the
    // cache for the old widget is discarded, the new widget starts
    // fresh. Same cost when the text doesn't change.
    const payload: []const u8 = if (text) |md| md else placeholder;
    const widget_id: u64 = std.hash.Wyhash.hash(0, payload);
    var tl = dvui.textLayout(@src(), .{ .cache_layout = true }, .{
        .id_extra = widget_id,
        .expand = .horizontal,
        .background = false,
    });
    defer tl.deinit();
    if (text) |md| {
        if (std.unicode.utf8ValidateSlice(md)) {
            tl.addText(md, .{});
        } else {
            tl.addText("(text contains invalid UTF-8 — re-sync to refresh)", .{});
        }
    } else {
        tl.addText(placeholder, .{});
    }
}

fn renderStructuredText(frame: *Frame, text: []const u8, base_id: u64) void {
    if (!std.unicode.utf8ValidateSlice(text)) {
        dvui.label(@src(), "(text contains invalid UTF-8 — re-sync to refresh)", .{}, .{});
        return;
    }
    renderStructuredLines(frame, text, base_id, 0);
}

fn renderStructuredLines(frame: *Frame, text: []const u8, base_id: u64, depth: u32) void {
    var i: usize = 0;
    var iter_idx: usize = 0;
    while (i <= text.len) {
        if (i == text.len) break;
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = text[i..nl];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const line_id: u64 = base_id +% (@as(u64, iter_idx) << @intCast(@min(depth * 4, 56)));
        iter_idx += 1;
        i = nl + 1;

        if (trimmed.len == 0) {
            _ = dvui.spacer(@src(), .{ .id_extra = line_id, .min_size_content = .{ .w = 1, .h = 4 } });
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "[SPOILER=") and std.mem.endsWith(u8, trimmed, "]")) {
            const title = trimmed["[SPOILER=".len .. trimmed.len - 1];
            const close_marker = "[/SPOILER]";
            const close_at = std.mem.indexOfPos(u8, text, i, close_marker) orelse text.len;
            const body = text[i..close_at];
            i = close_at + close_marker.len;
            if (i < text.len and text[i] == '\n') i += 1;

            if (dvui.expander(@src(), title, .{}, .{
                .id_extra = line_id,
                .expand = .horizontal,
            })) {
                var inner = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .id_extra = line_id,
                    .expand = .horizontal,
                    .padding = .{ .x = 16, .y = 4, .w = 0, .h = 4 },
                });
                defer inner.deinit();
                renderStructuredLines(frame, body, line_id, depth + 1);
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "## ")) {
            const body = trimmed[3..];
            dvui.labelNoFmt(@src(), body, .{}, .{
                .id_extra = line_id,
                .style = .highlight,
                .expand = .horizontal,
            });
            continue;
        }

        const BULLET = "• ";
        if (std.mem.startsWith(u8, trimmed, BULLET)) {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = line_id,
                .expand = .horizontal,
            });
            defer row.deinit();
            dvui.label(@src(), "•", .{}, .{
                .id_extra = line_id,
                .min_size_content = .{ .w = 14, .h = 1 },
            });
            renderInlineLineWithLinks(frame, trimmed[BULLET.len..], line_id);
            continue;
        }

        renderInlineLineWithLinks(frame, trimmed, line_id);
    }
}

fn renderInlineLineWithLinks(frame: *Frame, line: []const u8, id: u64) void {
    // Same cache-layout invalidation trick as `renderWrappedText`:
    // mix the line-content hash into the widget id so a line whose
    // text changed (re-sync delivers different downloads / changelog
    // content) becomes a fresh widget with no stale cache assertions.
    // `id` alone is position-based — a line at the same position with
    // different content would trip dvui's `bytes_seen` assert and
    // panic in TextLayoutWidget.addTextDone.
    const widget_id: u64 = id ^ std.hash.Wyhash.hash(0, line);
    // cache_layout: line content is keyed by `widget_id` (position
    // hash xor content hash) and only changes when scraped text
    // changes. The structured-text walker rebuilds one textLayout
    // per line of changelog / downloads / overview — 30-200
    // textLayouts per Detail render. Without the cache every one
    // re-runs line-break + glyph layout each frame.
    var tl = dvui.textLayout(@src(), .{ .cache_layout = true }, .{
        .id_extra = widget_id,
        .expand = .horizontal,
        .background = false,
    });
    defer tl.deinit();

    const body = dvui.Font.theme(.body);
    const bold_font = body.withWeight(.bold);
    const link_color: dvui.Color = tokens.toDvui(tokens.active.acc, dvui.Color);

    var cursor: usize = 0;
    while (cursor < line.len) {
        const link_at = std.mem.indexOfPos(u8, line, cursor, "[LINK=");
        const bold_at = std.mem.indexOfPos(u8, line, cursor, "[B]");
        const next: usize = blk: {
            const la = link_at orelse std.math.maxInt(usize);
            const ba = bold_at orelse std.math.maxInt(usize);
            const n = @min(la, ba);
            break :blk if (n == std.math.maxInt(usize)) line.len else n;
        };
        if (next > cursor) tl.addText(line[cursor..next], .{});
        if (next == line.len) return;

        if (link_at != null and next == link_at.?) {
            const open = link_at.?;
            const url_start = open + "[LINK=".len;
            const url_end = std.mem.indexOfScalarPos(u8, line, url_start, ']') orelse {
                tl.addText(line[open..], .{});
                return;
            };
            const url = line[url_start..url_end];
            const label_start = url_end + 1;
            const close_marker = "[/LINK]";
            const close_at = std.mem.indexOfPos(u8, line, label_start, close_marker) orelse {
                tl.addText(line[open..], .{});
                return;
            };
            const label_text = line[label_start..close_at];
            const shown = if (label_text.len == 0) url else label_text;
            if (tl.addTextClick(shown, .{ .color_text = link_color })) |_| {
                actions.openExternalUrl(frame, url);
            }
            cursor = close_at + close_marker.len;
        } else {
            const open = bold_at.?;
            const body_start = open + "[B]".len;
            const close_marker = "[/B]";
            const close_at = std.mem.indexOfPos(u8, line, body_start, close_marker) orelse {
                tl.addText(line[open..], .{});
                return;
            };
            const body_text = line[body_start..close_at];
            tl.addText(body_text, .{ .font = bold_font });
            cursor = close_at + close_marker.len;
        }
    }
}

fn renderDownloadsTab(frame: *Frame, game: *const library.Game) void {
    if (game.downloads_md) |text| {
        renderStructuredText(frame, text, game.f95_thread_id);
        return;
    }
    dvui.label(@src(), "No download links scraped yet. Sync this game to populate.", .{}, .{});
}

// ============================================================
//  Guides tab — user-managed walkthroughs / PDFs / etc.
// ============================================================
//
// Files live under `<library_root>/<thread_id>/guides/`. No DB row —
// the directory IS the source of truth. Crud actions live in
// `actions/common.zig` (`addGuideForGame`, `openGuide`, `removeGuide`,
// `listGuides`). The tab lists every file in that dir each render
// (small N, cheap walk) and lets the user open files in their own
// PDF/EPUB/HTML viewer via xdg-open (reuses `openExternalUrl`).
fn renderGuidesTab(frame: *Frame, game: *const library.Game) void {
    const alloc = frame.lib.alloc;

    // Header row: title blurb + "Add guide" button.
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer bar.deinit();
        dvui.label(@src(), "Walkthroughs, guides, cheats, notes — managed copies in your library.", .{}, .{
            .gravity_y = 0.5,
            .color_text = helpTextColor(),
        });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (components.iconButton(@src(), "Add guide", entypo.plus, .{ .style = .highlight })) {
            actions.addGuideForGame(frame, game.f95_thread_id);
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // List of guides — re-walked every frame. Cheap because guides
    // dirs hold a handful of files at most.
    const guides = actions.listGuides(frame, game.f95_thread_id) catch {
        dvui.label(@src(), "Couldn't read the guides directory.", .{}, .{ .color_text = helpTextColor() });
        return;
    };
    defer actions.freeGuides(alloc, guides);

    if (guides.len == 0) {
        dvui.label(
            @src(),
            "No guides yet. Click \"Add guide\" to pick a PDF / EPUB / HTML / TXT from anywhere — f69 will copy it into the game's library folder so it stays with the install.",
            .{},
            .{ .color_text = helpTextColor() },
        );
        return;
    }

    for (guides, 0..) |g, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = @intCast(i),
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
            .background = true,
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .color_fill = style.cardFill(),
            .color_border = style.borderColor(),
        });
        defer row.deinit();

        dvui.labelNoFmt(@src(), g.name, .{}, .{
            .id_extra = @intCast(i),
            .gravity_y = 0.5,
            .expand = .horizontal,
        });

        if (components.iconButton(@src(), "Open", entypo.eye, .{ .id_extra = @intCast(i), .style = .highlight })) {
            actions.openGuide(frame, game.f95_thread_id, g.name);
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        if (components.iconButton(@src(), "Remove", entypo.trash, .{ .id_extra = @intCast(i), .style = .err })) {
            actions.removeGuide(frame, game.f95_thread_id, g.name);
        }
    }
}

fn renderNotesTab(frame: *Frame, game: *library.Game) void {
    const state = frame.state;

    if (state.notes_for_thread != game.f95_thread_id) {
        @memset(&state.notes_buf, 0);
        if (game.notes) |n| {
            const len = @min(n.len, state.notes_buf.len - 1);
            @memcpy(state.notes_buf[0..len], n[0..len]);
        }
        state.notes_for_thread = game.f95_thread_id;
    }

    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });
        defer bar.deinit();
        if (style.button(@src(), "Save", .{}, .{ .style = .highlight })) {
            const text_end = std.mem.indexOfScalar(u8, &state.notes_buf, 0) orelse state.notes_buf.len;
            const trimmed = std.mem.trim(u8, state.notes_buf[0..text_end], " \t\n\r");
            saveOrToast(frame, "notes", frame.lib.setNotes(game, trimmed));
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (style.button(@src(), "Clear", .{}, .{})) {
            @memset(&state.notes_buf, 0);
            saveOrToast(frame, "notes", frame.lib.setNotes(game, ""));
        }
    }

    const te = style.textEntry(@src(), .{
        .text = .{ .buffer = &state.notes_buf },
        .multiline = true,
    }, .{
        .expand = .both,
        .min_size_content = .{ .w = 600, .h = 240 },
        .id_extra = game.f95_thread_id,
    });
    te.deinit();
}

// ============================================================
//  Clash modal (file-conflict warning)
// ============================================================

fn renderClashModal(frame: *Frame, game: *const library.Game) void {
    const m = actions.clashModalState(frame) orelse return;

    var open: bool = true;
    var fw = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &open,
    }, .{
        .min_size_content = .{ .w = 520, .h = 360 },
    });
    defer fw.deinit();

    _ = dvui.windowHeader("File conflicts", "", &open);

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer body.deinit();

    dvui.label(@src(), "Mod `{s}` overwrites paths owned by other installed mods.", .{m.recipe_id}, .{ .style = .err });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    dvui.label(@src(), "Last-applied wins — earlier mods' files will be replaced.", .{}, .{ .color_text = helpTextColor() });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    {
        var list = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer list.deinit();
        for (m.conflicts) |c| {
            dvui.label(@src(), "  · {s}   ← owned by mod {s}", .{ c.path, c.with_mod_id }, .{});
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .vertical });

    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer btn_row.deinit();
        if (style.button(@src(), "Cancel", .{}, .{ .style = .err })) open = false;
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "Install anyway (accept all)", .{}, .{ .style = .highlight })) {
            actions.clashModalAcceptAll(frame, game);
            return;
        }
    }

    if (!open) actions.closeClashModal(frame);
}

// ============================================================
//  Action toolbar + status strip + idle hints
// ============================================================

fn renderActionRow(frame: *Frame, game: *library.Game) void {
    var row = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
    });
    defer row.deinit();

    // Launch / Stop / Update all live in the hero now. This row is the
    // install version picker + manage menu + Download — "versions & acquire".
    const installs = frame.lib.listInstalls(game.f95_thread_id) catch &[_]library.Install{};
    defer frame.lib.freeInstalls(@constCast(installs));
    if (installs.len == 0) {
        const versions = [_][]const u8{"(no installs)"};
        var picked: usize = 0;
        _ = style.dropdown(@src(), &versions, .{ .choice = &picked }, .{}, .{
            .min_size_content = .{ .w = 160, .h = 28 },
            .gravity_y = 0.5,
        });
    } else {
        var labels_buf: [32][]const u8 = undefined;
        var join_buf: [32 * 144]u8 = undefined;
        var join_used: usize = 0;
        const n = @min(installs.len, labels_buf.len);
        for (installs[0..n], 0..) |inst, i| {
            const tag = sourceTag(inst.source);
            const rest = join_buf[join_used..];
            const have_name = if (inst.name) |nm| nm.len > 0 else false;
            const joined_or_err = if (have_name)
                std.fmt.bufPrint(rest, "{s}{s} \u{2014} {s}", .{ tag, inst.version, inst.name.? })
            else
                std.fmt.bufPrint(rest, "{s}{s}", .{ tag, inst.version });
            if (joined_or_err) |joined| {
                labels_buf[i] = joined;
                join_used += joined.len;
            } else |_| {
                labels_buf[i] = inst.version;
            }
        }
        var picked: usize = 0;
        if (frame.state.detail_picker_install_id) |sel| {
            for (installs[0..n], 0..) |inst, i| {
                if (std.mem.eql(u8, inst.id[0..], sel[0..])) {
                    picked = i;
                    break;
                }
            }
        }
        _ = style.dropdown(@src(), labels_buf[0..n], .{ .choice = &picked }, .{}, .{
            .min_size_content = .{ .w = 220, .h = 28 },
            .gravity_y = 0.5,
        });
        if (picked < installs.len) {
            frame.state.detail_picker_install_id = installs[picked].id;
        }

        var manage_bar = dvui.menu(@src(), .horizontal, .{ .id_extra = game.f95_thread_id ^ 0xCAFE });
        defer manage_bar.deinit();
        if (dvui.menuItemIcon(@src(), "install-manage", entypo.dots_three_horizontal, .{ .submenu = true }, .{
            .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
            .min_size_content = .{ .w = 18, .h = 18 },
            .id_extra = game.f95_thread_id,
        })) |anchor| {
            var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
            defer fw.deinit();

            if (dvui.menuItemLabel(@src(), "Rename\u{2026}", .{}, .{ .expand = .horizontal }) != null) {
                const inst = &installs[picked];
                frame.state.manage_action = .rename;
                frame.state.manage_install_id = inst.id;
                @memset(&frame.state.manage_rename_buf, 0);
                if (inst.name) |nm| {
                    const len = @min(nm.len, frame.state.manage_rename_buf.len - 1);
                    @memcpy(frame.state.manage_rename_buf[0..len], nm[0..len]);
                }
                manage_bar.close();
            }
            if (dvui.menuItemLabel(@src(), "Delete install", .{}, .{ .expand = .horizontal }) != null) {
                frame.state.manage_action = .delete;
                frame.state.manage_install_id = installs[picked].id;
                manage_bar.close();
            }
        }
    }

    // (Download / Install moved to the main-GUI acquire row; file/tool verbs
    // to the top-bar ⋯; Convert + Fix Compat + engine tools to the Tools tab.)
}

/// Engine tools — operate on the SELECTED install (Tools tab, under the
/// version picker): Win→Linux convert, host-compat fix, per-engine helpers.
fn renderEngineTools(frame: *Frame, game: *library.Game) void {
    const state = frame.state;
    var row = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
    });
    defer row.deinit();
    if (components.iconButton(@src(), "Convert (Win\u{2192}Linux)", entypo.cycle, .{})) {
        actions.doConvertGame(frame, game);
    }
    if (components.iconOnly(@src(), "Help", entypo.help, .{
        .style = if (state.convert_help_open) .highlight else .control,
        .min_size_content = .{ .w = style.button_h, .h = style.button_h },
    })) {
        state.convert_help_open = !state.convert_help_open;
    }
    if (components.iconButton(@src(), "Fix Compat", entypo.tools, .{})) {
        doCompatFixForActiveInstall(frame, game);
    }
    if (game.engine == .rpgm_mv or game.engine == .rpgm_mz) {
        if (components.iconButton(@src(), "Decrypt RPGM assets", entypo.tools, .{})) {
            actions.decryptRpgmAssets(frame, game.f95_thread_id);
        }
    }
    if (game.engine == .renpy) {
        if (components.iconButton(@src(), "Enable Ren'Py console", entypo.tools, .{})) {
            actions.enableRenpyConsole(frame, game.f95_thread_id);
        }
        if (components.iconButton(@src(), "Extract .rpa", entypo.archive, .{})) {
            actions.extractRpaArchives(frame, game.f95_thread_id);
        }
    }
}

/// 0.5×, 0.75×, … 4.0× — 15 entries in 0.25 steps. Default index = 6
/// (the 2.0× slot). Labels include the literal `×` so the picker reads
/// naturally without a separate suffix.
const MKXP_ZOOM_STEPS: [15]f32 = .{
    0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0, 3.25, 3.5, 3.75, 4.0,
};
const MKXP_ZOOM_LABELS: [15][]const u8 = .{
    "0.50\xC3\x97", "0.75\xC3\x97", "1.00\xC3\x97", "1.25\xC3\x97", "1.50\xC3\x97",
    "1.75\xC3\x97", "2.00\xC3\x97", "2.25\xC3\x97", "2.50\xC3\x97", "2.75\xC3\x97",
    "3.00\xC3\x97", "3.25\xC3\x97", "3.50\xC3\x97", "3.75\xC3\x97", "4.00\xC3\x97",
};

fn zoomToStepIdx(zoom: f32) usize {
    var best_idx: usize = 6; // default to 2.0×
    var best_dist: f32 = std.math.floatMax(f32);
    for (MKXP_ZOOM_STEPS, 0..) |step, i| {
        const d = @abs(step - zoom);
        if (d < best_dist) {
            best_dist = d;
            best_idx = i;
        }
    }
    return best_idx;
}

/// Render the per-install mkxp-z window-zoom picker, but only when
/// the game's latest install is mkxp-z-converted (i.e. has
/// `run-mkxp-z.sh`). Changing the dropdown writes the new zoom to
/// `<install>/.mkxp-zoom` AND triggers a re-Convert via the standard
/// `doConvertGame` action — the convert step reads the file and
/// regenerates `mkxp.json` with the new `defScreenW/H` values.
fn renderMkxpZSettingsRow(frame: *Frame, game: *library.Game) void {
    const inst_opt = frame.lib.latestInstallForGame(game.f95_thread_id) catch null;
    defer if (inst_opt) |i| frame.lib.freeInstall(i);
    const install = inst_opt orelse return;

    // Probe for the launcher we write. No file → game isn't on the
    // mkxp-z path → don't render the dropdown.
    var probe_buf: [640]u8 = undefined;
    const sh_path = std.fmt.bufPrint(&probe_buf, "{s}/run-mkxp-z.sh", .{install.install_path}) catch return;
    std.Io.Dir.cwd().access(frame.io, sh_path, .{}) catch return;

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
    defer row.deinit();

    dvui.label(@src(), "Window zoom (mkxp-z):", .{}, .{ .gravity_y = 0.5 });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });

    const current_zoom = convert_mod.rpgm.readMkxpZoom(frame.io, install.install_path) orelse convert_mod.rpgm.MKXP_ZOOM_DEFAULT;
    var picked: usize = zoomToStepIdx(current_zoom);
    const before = picked;
    if (style.dropdown(@src(), MKXP_ZOOM_LABELS[0..], .{ .choice = &picked }, .{}, .{
        .min_size_content = .{ .w = 110, .h = style.button_h },
        .gravity_y = 0.5,
    })) {
        if (picked != before) {
            const new_zoom = MKXP_ZOOM_STEPS[picked];
            convert_mod.rpgm.writeMkxpZoom(frame.io, install.install_path, new_zoom) catch |e| {
                std.log.scoped(.ui_detail).warn("mkxp zoom: write .mkxp-zoom failed: {s}", .{@errorName(e)});
            };
            // Reuse the existing Convert dispatch — for mkxp-z that's
            // a cheap operation (relinks, re-writes launcher/json) so
            // doing the full Convert on a dropdown change is fine.
            actions.doConvertGame(frame, game);
        }
    }
}

fn doCompatFixForActiveInstall(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    const installs = frame.lib.listInstalls(game.f95_thread_id) catch {
        state.setLaunchMsg("Compat fix: can't list installs.");
        return;
    };
    defer frame.lib.freeInstalls(installs);
    if (installs.len == 0) {
        state.setLaunchMsg("Compat fix: no installs for this game.");
        return;
    }
    const picked: *const library.Install = blk: {
        if (state.detail_picker_install_id) |sel| {
            for (installs) |*inst| if (std.mem.eql(u8, inst.id[0..], sel[0..])) break :blk inst;
        }
        break :blk &installs[0];
    };

    const issues = actions.scanCompatForInstall(frame, &picked.id, picked.install_path) catch |e| {
        var buf: [200]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Compat scan failed: {s}", .{@errorName(e)}) catch "Compat scan failed";
        state.setLaunchMsg(msg);
        return;
    };
    defer actions.freeCompatIssues(frame, issues);

    var applied: usize = 0;
    var failed: usize = 0;
    var last_err_buf: [128]u8 = undefined;
    var last_err: []const u8 = "";
    for (issues) |is| {
        if (is.status != .unfixed) continue;
        actions.applyCompatFix(frame, &picked.id, picked.install_path, is.recipe_id) catch |e| {
            failed += 1;
            last_err = std.fmt.bufPrint(&last_err_buf, "{s}: {s}", .{ is.recipe_id, @errorName(e) }) catch "apply failed";
            continue;
        };
        applied += 1;
    }
    _ = alloc;

    var msg_buf: [256]u8 = undefined;
    const msg = if (failed > 0)
        std.fmt.bufPrint(&msg_buf, "Compat: {d} fix(es) applied, {d} failed ({s}).", .{ applied, failed, last_err }) catch "Compat: partial."
    else if (applied > 0)
        std.fmt.bufPrint(&msg_buf, "Compat: {d} fix(es) applied. Re-launch the game.", .{applied}) catch "Compat applied."
    else
        std.fmt.bufPrint(&msg_buf, "Compat: nothing to fix on this install.", .{}) catch "Compat: nothing to fix.";
    state.setLaunchMsg(msg);
}

fn renderDetailDownloadButton(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const rpdl_busy = state.pending_rpdl_download != null;
    const donor_busy = state.pending_donor_download != null;
    const have_rpdl = state.rpdl_token != null and (state.rpdl_token.?.len > 0);
    const have_f95 = state.login_status == .logged_in;
    const busy = rpdl_busy or donor_busy;
    // is_donor == false means the startup probe definitively saw the
    // donor-DDL endpoint refuse this account. null means "not yet
    // probed" — stay optimistic; the first real download attempt
    // will surface the error if any. true means proven-donor.
    const known_not_donor = (state.is_donor orelse true) == false;

    const gray_color: dvui.Color = .{ .r = 0x80, .g = 0x80, .b = 0x80 };
    const dim_opts: dvui.Options = .{ .style = .control, .color_text = gray_color };

    var bar = dvui.menu(@src(), .horizontal, .{ .id_extra = game.f95_thread_id ^ 0xACCE });
    defer bar.deinit();

    // --- Primary button ---
    // Priority order (matches the spec):
    //   - not signed into F95 → "Sign in" link to settings/accounts
    //   - known non-donor → disabled "Not a donor"
    //   - donor (or unknown) → "Download" via donor DDL as default
    if (!have_f95) {
        if (components.iconButton(@src(), "Download (sign in first)", entypo.download, dim_opts)) {
            state.screen = .settings;
            state.settings_tab = .accounts;
        }
    } else if (known_not_donor) {
        // Disabled — click does nothing. Tooltip explains via label.
        _ = components.iconButton(@src(), "Donor required", entypo.download, dim_opts);
    } else {
        const primary_label: []const u8 = blk: {
            if (donor_busy) break :blk "Requesting…";
            if (rpdl_busy) break :blk "Searching…";
            break :blk "Download";
        };
        const primary_opts: dvui.Options = if (busy) dim_opts else .{};
        if (components.iconButton(@src(), primary_label, entypo.download, primary_opts)) {
            if (!busy) actions.startDonorDownload(frame, game);
        }
    }

    // --- Source picker chevron ---
    if (dvui.menuItemIcon(@src(), "download-source", entypo.chevron_down, .{ .submenu = true }, .{
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .min_size_content = .{ .w = 16, .h = 16 },
        .id_extra = game.f95_thread_id,
    })) |anchor| {
        var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
        defer fw.deinit();

        if (actions.hasActiveDownloadForGame(frame, game.f95_thread_id)) {
            if (dvui.menuItemLabel(@src(), "View current download", .{}, .{ .expand = .horizontal }) != null) {
                state.screen = .downloads;
                bar.close();
            }
        }

        // Donor DDL — only when signed in + not known to be a
        // non-donor. Same gate as the primary button.
        if (have_f95 and !known_not_donor) {
            if (dvui.menuItemLabel(@src(), "Download via donor DDL (HTTP)", .{}, .{ .expand = .horizontal }) != null) {
                bar.close();
                if (!busy) actions.startDonorDownload(frame, game);
            }
        }
        // RPDL — only enabled when RPDL token loaded. Otherwise
        // grayed out: shown so the user sees the option exists,
        // but clicks bounce to Settings to sign in.
        if (have_rpdl) {
            if (dvui.menuItemLabel(@src(), "Download via RPDL (torrent + seed)", .{}, .{ .expand = .horizontal }) != null) {
                bar.close();
                if (!busy) actions.startRpdlDownload(frame, game);
            }
        } else {
            if (dvui.menuItemLabel(@src(), "Download via RPDL (sign in first)", .{}, .{ .expand = .horizontal, .color_text = gray_color }) != null) {
                bar.close();
                state.screen = .settings;
                state.settings_tab = .accounts;
            }
        }
        if (dvui.menuItemLabel(@src(), "Install from file\u{2026}", .{}, .{ .expand = .horizontal }) != null) {
            state.manual_install_open = true;
            bar.close();
        }
    }
}

fn renderDetailInstallButton(frame: *Frame, game: *const library.Game) void {
    var buf: [16]actions.DownloadedEntry = undefined;
    const entries = actions.listDownloadedNotInstalled(frame, game.f95_thread_id, &buf);
    if (entries.len == 0) return;

    if (entries.len == 1) {
        if (components.iconButton(@src(), "Install", entypo.tools, .{ .style = .highlight })) {
            actions.startInstallFromDownloadJob(
                frame,
                game.f95_thread_id,
                entries[0].job_id,
                entries[0].expected_sha256,
            );
        }
        return;
    }

    var bar = dvui.menu(@src(), .horizontal, .{ .id_extra = game.f95_thread_id ^ 0xB1 });
    defer bar.deinit();

    if (components.iconButton(@src(), "Install", entypo.tools, .{ .style = .highlight })) {
        var best = entries[0];
        for (entries[1..]) |e| if (e.job_id > best.job_id) {
            best = e;
        };
        actions.startInstallFromDownloadJob(
            frame,
            game.f95_thread_id,
            best.job_id,
            best.expected_sha256,
        );
    }

    if (dvui.menuItemIcon(@src(), "install-version", entypo.chevron_down, .{ .submenu = true }, .{
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .min_size_content = .{ .w = 16, .h = 16 },
        .id_extra = game.f95_thread_id ^ 0xB2,
    })) |anchor| {
        var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
        defer fw.deinit();

        for (entries, 0..) |e, i| {
            var lbl_buf: [96]u8 = undefined;
            const label: []const u8 = if (e.version.len > 0)
                std.fmt.bufPrint(&lbl_buf, "Install version {s}", .{e.version}) catch "Install (unknown version)"
            else
                "Install (unknown version)";
            if (dvui.menuItemLabel(@src(), label, .{}, .{
                .expand = .horizontal,
                .id_extra = @intCast(i),
            }) != null) {
                actions.startInstallFromDownloadJob(
                    frame,
                    game.f95_thread_id,
                    e.job_id,
                    e.expected_sha256,
                );
                bar.close();
            }
        }
    }
}

fn renderDetailStatusLine(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

    if (state.pending_rpdl_download != null) {
        renderStatusStrip(frame, .{
            .id = @intCast(game.f95_thread_id ^ 0xA0),
            .text = "Searching RPDL for a matching torrent…",
            .accent = tokens.toDvui(tokens.active.acc, dvui.Color),
            .progress = null,
            .view_link = false,
        });
        return;
    }
    if (state.pending_donor_download != null) {
        renderStatusStrip(frame, .{
            .id = @intCast(game.f95_thread_id ^ 0xA1),
            .text = "Requesting signed URL from F95 donor DDL…",
            .accent = tokens.toDvui(tokens.active.acc, dvui.Color),
            .progress = null,
            .view_link = false,
        });
        return;
    }

    if (actions.findLeechingJobForGame(frame, game.f95_thread_id)) |job| {
        renderStatusStrip(frame, .{
            .id = @intCast(job.id),
            .text = downloadStatusText(job),
            .accent = tokens.toDvui(tokens.active.acc, dvui.Color),
            .progress = downloadProgressPct(job),
            .view_link = true,
        });
        return;
    }

    if (actions.isInstallingForGame(frame, game.f95_thread_id)) {
        const pct_opt = actions.extractProgressForGame(frame, game.f95_thread_id);
        var msg_buf: [96]u8 = undefined;
        const msg: []const u8 = if (pct_opt) |p|
            (std.fmt.bufPrint(&msg_buf, "Installing — extracting archive ({d}%).", .{p}) catch "Installing — extracting archive.")
        else
            "Installing — extracting archive in the background.";
        renderStatusStrip(frame, .{
            .id = @intCast(game.f95_thread_id),
            .text = msg,
            .accent = tokens.toDvui(tokens.active.acc, dvui.Color),
            .progress = if (pct_opt) |p| @as(u32, p) else null,
            .view_link = false,
        });
        return;
    }

    const dot = actions.installDotState(frame, game);
    const auto_on = blk: {
        if (dot == .none) break :blk false;
        break :blk actions.shouldAutoUpdate(state, game);
    };
    if (dot == .outdated) {
        const newer = game.latest_version orelse "latest";
        const has_auto = actions.hasAutoFetchableSource(frame, game.f95_thread_id);
        var msg_buf: [240]u8 = undefined;
        const msg = blk: {
            if (has_auto and auto_on) {
                break :blk std.fmt.bufPrint(&msg_buf, "Update available: {s} — click Update to fetch. \u{00B7} auto-updates on", .{newer}) catch "Update available.";
            } else if (has_auto) {
                break :blk std.fmt.bufPrint(&msg_buf, "Update available: {s} — click Update to fetch.", .{newer}) catch "Update available.";
            } else if (auto_on) {
                break :blk std.fmt.bufPrint(&msg_buf, "Update available: {s} — pick the new archive via Update. \u{00B7} auto-updates on", .{newer}) catch "Update available.";
            } else {
                break :blk std.fmt.bufPrint(&msg_buf, "Update available: {s} — pick the new archive via Update.", .{newer}) catch "Update available.";
            }
        };
        renderIdleHint(game.f95_thread_id ^ 0xB1, msg);
    } else if (auto_on) {
        renderIdleHint(game.f95_thread_id ^ 0xB2, "auto-updates on");
    }
}

fn renderIdleHint(id: u64, text: []const u8) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = @intCast(id),
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
    });
    defer row.deinit();
    dvui.labelNoFmt(@src(), text, .{}, .{
        .gravity_y = 0.5,
        .color_text = helpTextColor(),
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 20 },
    });
}

const StatusStripArgs = struct {
    id: u32,
    text: []const u8,
    accent: dvui.Color,
    progress: ?u32,
    view_link: bool,
};

fn renderStatusStrip(frame: *Frame, args: StatusStripArgs) void {
    var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = args.id,
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = style.cardFill(),
        .color_border = style.borderColor(),
    });
    defer wrap.deinit();

    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = args.id,
            .expand = .horizontal,
        });
        defer line.deinit();
        dvui.labelNoFmt(@src(), args.text, .{}, .{
            .gravity_y = 0.5,
            .color_text = style.labelDim(),
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 20 },
        });
        if (args.view_link) {
            if (components.iconButton(@src(), "View", entypo.list, .{
                .id_extra = args.id,
                .style = .control,
                .gravity_y = 0.5,
                .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            })) {
                frame.state.screen = .downloads;
            }
        }
    }

    if (args.progress) |pct| {
        const frac: f32 = @as(f32, @floatFromInt(@min(pct, 100))) / 100.0;
        dvui.progress(@src(), .{ .percent = frac, .color = args.accent }, .{
            .id_extra = args.id,
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = 10 },
            .border = style.border_thin,
            .corner_radius = .all(2),
            .color_border = style.borderColor(),
            .color_fill = .{ .r = 0x16, .g = 0x0B, .b = 0x10 },
            .padding = .all(0),
        });
        return;
    }

    var bar_outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = args.id,
        .expand = .horizontal,
        .min_size_content = .{ .w = 1, .h = 10 },
        .border = style.border_thin,
        .corner_radius = .all(2),
        .color_border = style.borderColor(),
        .background = true,
        .color_fill = .{ .r = 0x16, .g = 0x0B, .b = 0x10 },
    });
    defer bar_outer.deinit();

    {
        const now_s = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();
        const period_s: i64 = 2;
        const phase = @rem(now_s, period_s);
        const sweep_frac: f32 = @as(f32, @floatFromInt(phase)) / @as(f32, @floatFromInt(period_s));
        const slug_w_frac: f32 = 0.25;
        const left_pad_frac: f32 = sweep_frac * (1.0 - slug_w_frac);
        if (left_pad_frac > 0) {
            var pad = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = args.id ^ 0x9001,
                .min_size_content = .{ .w = @max(0.0, left_pad_frac * 400.0), .h = 8 },
            });
            pad.deinit();
        }
        var slug = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = args.id ^ 0x9002,
            .min_size_content = .{ .w = @max(8.0, slug_w_frac * 400.0), .h = 8 },
            .background = true,
            .color_fill = args.accent,
            .corner_radius = .all(1),
        });
        slug.deinit();
    }
}

fn downloadProgressPct(job: downloads.Job) ?u32 {
    const total = job.bytes_total orelse 0;
    if (total == 0) return null;
    return @intCast(@min(@divTrunc(job.bytes_done * 100, total), 100));
}

fn downloadStatusText(job: downloads.Job) []const u8 {
    const tmp = struct {
        var buf: [192]u8 = undefined;
    };
    var dl_buf: [24]u8 = undefined;
    var done_buf: [24]u8 = undefined;
    var total_buf: [24]u8 = undefined;
    const total = job.bytes_total orelse 0;
    const dl_s = components.humanRate(&dl_buf, job.download_speed);
    const done_s = components.humanBytes(&done_buf, job.bytes_done);
    const total_s = if (total > 0) components.humanBytes(&total_buf, total) else "?";
    if (total > 0) {
        const pct: u32 = @intCast(@min(@divTrunc(job.bytes_done * 100, total), 100));
        return std.fmt.bufPrint(&tmp.buf, "Downloading {d}% · ↓ {s} · {s} / {s}", .{ pct, dl_s, done_s, total_s }) catch "Downloading";
    }
    return std.fmt.bufPrint(&tmp.buf, "Downloading · ↓ {s} · {s}", .{ dl_s, done_s }) catch "Downloading";
}

// ============================================================
//  Carousel / ribbon / cover renderers
// ============================================================

const CAROUSEL_H: f32 = 360;
const RIBBON_THUMB_W: f32 = 96;
const RIBBON_THUMB_H: f32 = 54;
const RIBBON_H: f32 = RIBBON_THUMB_H + 12;

const ICON_SIZE: dvui.Size = style.icon_size;
const ICON_OPTS: dvui.IconRenderOptions = .{};

/// Tall icon button used by the carousel chevrons. Around `iconOnly`
/// because the carousel chevrons explicitly want a larger button.
fn tallChevronButton(
    src: std.builtin.SourceLocation,
    name: []const u8,
    tvg: []const u8,
    w: f32,
    h: f32,
) bool {
    return dvui.buttonIcon(src, name, tvg, .{}, ICON_OPTS, .{
        .min_size_content = .{ .w = 36, .h = 36 },
        .padding = .{ .x = (w - 36) / 2, .y = (h - 36) / 2, .w = (w - 36) / 2, .h = (h - 36) / 2 },
        .gravity_y = 0.5,
    });
}

fn renderRibbon(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;
    const total: usize = 1 + game.screenshots.len;
    if (total < 2) return;

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    var flex = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 6, .w = 0, .h = 6 },
    });
    defer flex.deinit();

    var i: usize = 0;
    while (i < total) : (i += 1) {
        const bytes = actions.thumbBytes(frame, game.f95_thread_id, i);
        const is_active = (state.carousel_index == i);
        if (renderRibbonThumb(bytes, i, is_active, game.f95_thread_id)) {
            state.carousel_index = i;
        }
    }
}

fn renderRibbonThumb(bytes_opt: ?[]const u8, idx: usize, is_active: bool, thread_id: u64) bool {
    const id_extra: usize = (@as(usize, @intCast(thread_id)) << 8) | (idx & 0xff) | 0x10000000_0000_0000;
    const border = if (is_active)
        tokens.toDvui(tokens.active.acc, dvui.Color)
    else
        dvui.Color{ .r = 0x5C, .g = 0x2A, .b = 0x3D };

    if (bytes_opt) |bytes| {
        const source: dvui.ImageSource = .{
            .imageFile = .{
                .bytes = bytes,
                .name = "ribbon-thumb",
                // Thumb-strip slots are freed when switching games; the
                // allocator may hand back the same pointer for the new
                // game's thumbs. Hash bytes so dvui detects the change.
                .invalidation = .bytes,
            },
        };
        const natural = dvui.imageSize(source) catch dvui.Size{ .w = 16, .h = 9 };
        const aspect_min = scaleToAspectMin(natural);
        const wd = dvui.image(@src(), .{
            .source = source,
            .shrink = .ratio,
        }, .{
            .id_extra = id_extra,
            .min_size_content = aspect_min,
            .max_size_content = .{ .w = RIBBON_THUMB_W, .h = RIBBON_THUMB_H },
            .expand = .ratio,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .margin = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
            .border = .all(if (is_active) 2 else 1),
            .corner_radius = .all(3),
            .color_border = border,
        });
        return dvui.clicked(&wd, .{});
    }
    var slot = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .min_size_content = .{ .w = RIBBON_THUMB_W, .h = RIBBON_THUMB_H },
        .max_size_content = .{ .w = RIBBON_THUMB_W, .h = RIBBON_THUMB_H },
        .margin = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
        .background = true,
        .border = .all(if (is_active) 2 else 1),
        .corner_radius = .all(3),
        .color_fill = .{ .r = 0x2A, .g = 0x16, .b = 0x20 },
        .color_border = border,
    });
    defer slot.deinit();
    return dvui.clicked(slot.data(), .{});
}

fn renderCarousel(frame: *Frame, game: *const library.Game) void {
    const state = frame.state;

    if (state.carousel_for_thread != game.f95_thread_id) {
        state.carousel_index = 0;
        state.carousel_for_thread = game.f95_thread_id;
        actions.freeSlideCache(state, frame.lib.alloc);
        // Warm the OS page cache for every thumbnail of this game so
        // the ribbon-strip's first paint doesn't burn 20+ sync reads
        // on the UI thread. The cover thumb itself goes through
        // `cover_cache` and is already warm if the user came from the
        // library grid.
        actions.spawnThumbPrewarm(
            frame.lib.alloc,
            frame.io,
            frame.info.covers_dir,
            game.f95_thread_id,
            game.screenshots.len,
        );
    }

    const total: usize = 1 + game.screenshots.len;
    const idx = @min(state.carousel_index, total - 1);

    var slot_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = game.f95_thread_id,
        .expand = .horizontal,
        .min_size_content = .{ .w = 1, .h = CAROUSEL_H },
        .max_size_content = .height(CAROUSEL_H),
    });
    defer slot_box.deinit();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
    });
    defer row.deinit();

    const NAV_COL_W: f32 = 72;
    const NAV_BTN_H: f32 = CAROUSEL_H;

    var prev_clicked = false;
    if (total > 1) {
        prev_clicked = tallChevronButton(@src(), "prev", entypo.chevron_left, NAV_COL_W, NAV_BTN_H);
    } else {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = NAV_COL_W, .h = 1 } });
    }

    const bytes_opt: ?[]const u8 = if (idx == 0)
        actions.coverFullBytes(frame, game.f95_thread_id)
    else
        actions.slideBytes(frame, game.f95_thread_id, idx);

    var img_ov = dvui.overlay(@src(), .{ .expand = .both });
    {
        defer img_ov.deinit();

        const slide_wd = renderSlideImage(frame, bytes_opt, idx, game.f95_thread_id);

        {
            var ctr_buf: [32]u8 = undefined;
            const ctr = std.fmt.bufPrint(&ctr_buf, "{d} / {d}", .{ idx + 1, total }) catch "?";
            dvui.labelNoFmt(@src(), ctr, .{}, .{
                .gravity_x = 0.5,
                .gravity_y = 1.0,
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
                .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
                .corner_radius = style.corner_radius,
                .background = true,
                .color_fill = .{ .r = 0x14, .g = 0x0A, .b = 0x10 },
                .color_text = dvui.Color.white,
            });
        }

        if (slide_wd) |wd| {
            if (dvui.clicked(&wd, .{})) {
                state.image_popup_open = true;
            }
        }
    }

    var next_clicked = false;
    if (total > 1) {
        next_clicked = tallChevronButton(@src(), "next", entypo.chevron_right, NAV_COL_W, NAV_BTN_H);
    } else {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = NAV_COL_W, .h = 1 } });
    }

    if (prev_clicked) state.carousel_index = (idx + total - 1) % total;
    if (next_clicked) state.carousel_index = (idx + 1) % total;
}

fn scaleToAspectMin(natural: dvui.Size) dvui.Size {
    const big: f32 = @max(natural.w, natural.h);
    if (big <= 0) return .{ .w = 16, .h = 9 };
    const k: f32 = 32.0 / big;
    return .{ .w = natural.w * k, .h = natural.h * k };
}

fn renderSlideImage(frame: *Frame, bytes_opt: ?[]const u8, idx: usize, thread_id: u64) ?dvui.WidgetData {
    _ = frame;
    const id_extra: usize = (@as(usize, @intCast(thread_id)) << 8) | (idx & 0xff);
    if (bytes_opt) |bytes| {
        const source: dvui.ImageSource = .{
            .imageFile = .{
                .bytes = bytes,
                .name = "carousel",
                // Multi-slot slide cache holds each idx in its own slot
                // with a stable ptr across frames — default `.ptr`
                // invalidation is safe and avoids hashing the full
                // screenshot per frame.
            },
        };
        const natural = dvui.imageSize(source) catch dvui.Size{ .w = 16, .h = 9 };
        const aspect_min = scaleToAspectMin(natural);
        const wd = dvui.image(@src(), .{
            .source = source,
            .shrink = .ratio,
        }, .{
            .id_extra = id_extra,
            .expand = .ratio,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = aspect_min,
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .color_border = style.borderColor(),
        });
        return wd;
    }
    var slot = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .expand = .both,
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = .{ .r = 0x2A, .g = 0x16, .b = 0x20 },
        .color_border = style.borderColor(),
        .padding = .{ .x = 12, .y = 12, .w = 12, .h = 12 },
    });
    defer slot.deinit();
    const txt: []const u8 = if (idx == 0) "(no cover)" else "(screenshot not yet synced)";
    dvui.labelNoFmt(@src(), txt, .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
    return null;
}

fn renderCover(bytes_opt: ?[]const u8) void {
    if (bytes_opt) |bytes| {
        _ = dvui.image(@src(), .{
            .source = .{
                .imageFile = .{
                    .bytes = bytes,
                    .name = "cover",
                    // Multi-slot slide cache: slot 0 holds the full-size
                    // cover bytes at a stable ptr for the duration of
                    // this game's detail page. Default `.ptr`
                    // invalidation is safe — game-switch wipes the slot
                    // before the next allocation, evicting dvui's cache
                    // entry alongside.
                },
            },
            .shrink = .ratio,
        }, .{
            .min_size_content = .{ .w = 220, .h = 320 },
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .color_border = style.borderColor(),
        });
        return;
    }
    var cover = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 220, .h = 320 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = .{ .r = 0x2A, .g = 0x16, .b = 0x20 },
        .color_border = style.borderColor(),
        .padding = .{ .x = 12, .y = 12, .w = 12, .h = 12 },
    });
    defer cover.deinit();
    dvui.label(@src(), "(no cover)", .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
}

fn renderCoverThumb(bytes_opt: ?[]const u8, thread_id: u64) void {
    if (bytes_opt) |bytes| {
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{
                .bytes = bytes,
                .name = "thumb",
                .invalidation = .bytes,
            } },
            .shrink = .ratio,
        }, .{
            .id_extra = thread_id,
            .min_size_content = .{ .w = 60, .h = 85 },
            .border = style.border_thin,
            .corner_radius = .all(3),
            .color_border = style.borderColor(),
        });
        return;
    }
    var thumb = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = thread_id,
        .min_size_content = .{ .w = 60, .h = 85 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = .all(3),
        .color_fill = .{ .r = 0x2A, .g = 0x16, .b = 0x20 },
        .color_border = style.borderColor(),
    });
    defer thumb.deinit();
}

fn renderTagChips(frame: *Frame, tags: []const []const u8) void {
    const state = frame.state;
    ensureTagColors(frame);

    var flex = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
    });
    defer flex.deinit();

    const body = dvui.Font.theme(.body);
    const small = body.withSize(body.size * 0.75);
    for (tags, 0..) |tag, i| {
        if (!isPrintableTag(tag)) continue;
        // F95Checker-style per-tag color: a stable hue per tag name by
        // default, overridable by the user (click a chip to pick a color).
        const override = state.tagColorFor(tag);
        const tc = components.tagChipColors(tag, override);
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .background = true,
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
            .margin = .{ .x = 0, .y = 0, .w = 2, .h = 2 },
            .color_fill = tc.fill,
            .color_border = tc.border,
        });
        dvui.labelNoFmt(@src(), tag, .{}, .{ .font = small, .color_text = tc.text });
        const clicked = dvui.clicked(chip.data(), .{});
        chip.deinit();
        if (clicked) openTagColorEditor(state, tag, tc.border);
    }

    renderTagColorPicker(frame);
}

/// Lazily load the tag-color override map on first use.
fn ensureTagColors(frame: *Frame) void {
    if (frame.state.tag_colors != null) return;
    frame.state.tag_colors = frame.lib.loadTagColors(frame.lib.alloc) catch null;
}

/// Rebuild the override map after an edit so chips reflect the change.
fn reloadTagColors(frame: *Frame) void {
    if (frame.state.tag_colors) |*m| library.Library.freeTagColors(m);
    frame.state.tag_colors = frame.lib.loadTagColors(frame.lib.alloc) catch null;
}

fn openTagColorEditor(state: *state_mod.State, tag: []const u8, current: dvui.Color) void {
    @memset(&state.tag_color_editing, 0);
    const n = @min(tag.len, state.tag_color_editing.len - 1);
    @memcpy(state.tag_color_editing[0..n], tag[0..n]);
    state.tag_color_hsv = dvui.Color.HSV.fromColor(current);
}

/// Color-picker popup for the tag whose chip was clicked. Save writes a
/// user override; Reset clears it back to the auto hue.
fn renderTagColorPicker(frame: *Frame) void {
    const state = frame.state;
    const tag = nulSlice(&state.tag_color_editing);
    if (tag.len == 0) return;

    var open: bool = true;
    var win = dvui.floatingWindow(@src(), .{ .open_flag = &open }, .{ .min_size_content = .{ .w = 320, .h = 340 } });
    defer {
        win.deinit();
        if (!open) @memset(&state.tag_color_editing, 0);
    }
    var hbuf: [160]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hbuf, "Tag color — {s}", .{tag}) catch "Tag color";
    _ = dvui.windowHeader(hdr, "", &open);

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 12, .y = 12, .w = 12, .h = 12 } });
    defer box.deinit();

    _ = dvui.colorPicker(@src(), .{ .hsv = &state.tag_color_hsv, .sliders = .hsv }, .{});

    var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 0, .y = 8, .w = 0, .h = 0 } });
    defer btns.deinit();
    if (components.iconButton(@src(), "Reset to auto", entypo.cycle, .{})) {
        frame.lib.setTagColor(tag, null) catch |e| state.notifyErr(@errorName(e));
        reloadTagColors(frame);
        open = false;
    }
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (components.iconButton(@src(), "Save", entypo.check, .{ .style = .highlight })) {
        const c = state.tag_color_hsv.toColor();
        var hex: [6]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch {};
        frame.lib.setTagColor(tag, &hex) catch |e| state.notifyErr(@errorName(e));
        reloadTagColors(frame);
        open = false;
    }
}

fn isPrintableTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > 128) return false;
    return std.unicode.utf8ValidateSlice(tag);
}

// ============================================================
//  Journal tab — per-version session history
// ============================================================

fn renderJournalTab(frame: *Frame, game: *const library.Game) void {
    const sessions = frame.lib.listPlaySessions(game.f95_thread_id) catch {
        dvui.labelNoFmt(@src(), "Failed to load journal.", .{}, .{ .color_text = helpTextColor() });
        return;
    };
    defer frame.lib.freePlaySessions(sessions);

    if (sessions.len == 0) {
        dvui.labelNoFmt(
            @src(),
            "No play sessions recorded yet. Sessions start counting from the first launch after this release.",
            .{},
            .{ .color_text = helpTextColor() },
        );
        return;
    }

    const alloc = frame.lib.alloc;
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(alloc);
    for (sessions) |s| {
        var found = false;
        for (seen.items) |v| {
            if (std.mem.eql(u8, v, s.version)) {
                found = true;
                break;
            }
        }
        if (!found) seen.append(alloc, s.version) catch break;
    }
    // Sort newest-first using util_version.compare.
    std.sort.pdq([]const u8, seen.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return version_mod.compare(a, b) == .gt;
        }
    }.lt);

    var to_delete: ?i64 = null;
    for (seen.items, 0..) |ver, vi| {
        var total_s: i64 = 0;
        var count: usize = 0;
        var last_end: ?i64 = null;
        for (sessions) |s| {
            if (!std.mem.eql(u8, s.version, ver)) continue;
            count += 1;
            if (s.counts_as_played) total_s += s.durationSeconds();
            if (s.ended_at) |e| {
                if (last_end == null or e > last_end.?) last_end = e;
            }
        }

        var header_buf: [256]u8 = undefined;
        // Raw unix-seconds for `last_end` matches the per-session row
        // rendering (v1 — no time-formatting helper yet). "no end" only
        // happens when every session for this version is still open.
        const header = if (last_end) |le| std.fmt.bufPrint(
            &header_buf,
            "{s}   {d} session{s} · {d}h {d}m · last {d}",
            .{
                ver,
                count,
                if (count == 1) @as([]const u8, "") else "s",
                @divTrunc(total_s, 3600),
                @mod(@divTrunc(total_s, 60), 60),
                le,
            },
        ) catch ver else std.fmt.bufPrint(
            &header_buf,
            "{s}   {d} session{s} · {d}h {d}m",
            .{
                ver,
                count,
                if (count == 1) @as([]const u8, "") else "s",
                @divTrunc(total_s, 3600),
                @mod(@divTrunc(total_s, 60), 60),
            },
        ) catch ver;
        dvui.labelNoFmt(@src(), header, .{}, .{ .style = .highlight, .id_extra = vi });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 2 }, .id_extra = vi });

        for (sessions) |s| {
            if (!std.mem.eql(u8, s.version, ver)) continue;
            // One row box per session, keyed by the globally-unique session id
            // (also fixes the dvui duplicate-widget-id error — every looped
            // widget now carries a distinct id_extra).
            const sid: usize = @intCast(s.id);
            var srow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = sid, .expand = .horizontal });
            defer srow.deinit();
            var row_buf: [256]u8 = undefined;
            const row = formatSessionRow(&row_buf, s);
            dvui.labelNoFmt(@src(), row, .{}, .{ .color_text = helpTextColor(), .gravity_y = 0.5 });
            _ = dvui.spacer(@src(), .{ .expand = .horizontal });
            if (components.iconButton(@src(), "Delete session", entypo.trash, .{ .id_extra = sid, .style = .err, .gravity_y = 0.5 })) {
                to_delete = s.id;
            }
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 }, .id_extra = vi });
    }

    if (to_delete) |id| {
        frame.lib.deletePlaySession(id) catch {
            frame.state.notifyErr("Couldn't delete that play session.");
        };
        // The next frame re-reads listPlaySessions, so the row vanishes and
        // the per-version header totals recompute automatically.
    }
}

fn formatSessionRow(buf: *[256]u8, s: library.PlaySession) []const u8 {
    if (s.ended_at) |end| {
        const dur_m = @divTrunc(s.durationSeconds(), 60);
        const note: []const u8 = if (s.counts_as_played) "" else "  (below threshold)";
        return std.fmt.bufPrint(buf, "  {d} → {d}   {d}m{s}", .{ s.started_at, end, dur_m, note }) catch "session";
    }
    return std.fmt.bufPrint(buf, "  {d} → in progress", .{s.started_at}) catch "session";
}
