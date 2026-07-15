// Recipe editor screen — full-page replacement for the modal wizard.
// Stacked panels for metadata / install steps / relations / save.

const std = @import("std");
const dvui = @import("dvui");
const entypo = dvui.entypo;
const library = @import("library");
const recipe = @import("recipe");
const installer_mod = @import("installer");

const types = @import("../types.zig");
const state_mod = @import("../state.zig");
const actions = @import("../actions.zig");
const style = @import("../style.zig");
const components = @import("../components.zig");
const tokens = @import("ui_tokens");

const Frame = types.Frame;
// Recipe content (captions, sublines, help copy) reads ink2 here, not the
// app-wide ink3 hint colour — on the dark recipe cards ink3 was ~3:1 and
// unreadable. `style.labelText` is ink2 (~7:1).
const helpTextColor = style.labelText;

/// Width of the wizard's left (controls) pane. Right pane takes the
/// remainder. Hard-clamped via `max_size_content.w` so the scrollArea
/// inside doesn't push horizontally.
const LEFT_PANE_W: f32 = 560;

/// Visual styling for the block card containers (step 1) — bordered
/// box with a darker fill than the page background so the cards stand
/// out as discrete units rather than a wall of text.
// Theme-driven cards (were a hardcoded dark maroon that clashed with the app
// and tanked text contrast). These follow the theme set in Settings.
fn cardFill() dvui.Color {
    return tokens.toDvui(tokens.active.bg1, dvui.Color);
}
fn cardBorder() dvui.Color {
    return tokens.toDvui(tokens.active.line, dvui.Color);
}
fn cardFillHi() dvui.Color {
    return tokens.toDvui(tokens.active.bg2, dvui.Color);
}

// ============================================================
//  Recipe wizard modal
// ============================================================

/// Full-page recipe editor — replaces the old modal wizard. All four
/// sections (metadata, install steps, relations, save) render as
/// stacked panels on a single scrolling page. The user can see the
/// preview pane in context with the install plan without juggling
/// modal "Next/Back" navigation.
pub fn recipeEditorScreen(frame: *Frame) !bool {
    const state = frame.state;

    // No wizard state in flight → the user got here via stale state or
    // a back-nav after closeWizard. Bounce home.
    if (state.wizard == null) {
        state.screen = .detail;
        return true;
    }

    // Resolve the parent game from the wizard's thread id; needed by
    // most of the section renderers.
    const w_ptr = &state.wizard.?;
    const game_opt = components.gameByThreadId(frame, w_ptr.game_thread_id);
    const game = game_opt orelse {
        // Game vanished (deleted mid-edit). Drop the wizard.
        actions.closeWizard(frame);
        return true;
    };

    // Linear wizard with 2 user-visible steps. Internally we reuse the
    // existing WizardStep enum but only ever resolve to .install or
    // .meta — the old .review / .relations pages were redundant with
    // the right-pane preview, so they're collapsed into step 2.
    //
    //   step display | state.step
    //   ─────────────┼───────────
    //   1 of 2       | .install   — wrapper-folder + destination
    //   2 of 2       | .meta      — name / version / source URL +
    //                              Save & Install button
    //
    // Older wizard state with .relations / .review gets redirected
    // to .meta so the user always lands on a real page.
    if (w_ptr.step == .relations or w_ptr.step == .review) w_ptr.step = .meta;

    const step_num: u8 = switch (w_ptr.step) {
        .install => 1,
        .meta => 2,
        .review, .relations => 2,
    };
    const step_title: []const u8 = switch (w_ptr.step) {
        .install => "Install plan",
        .meta, .review, .relations => "Mod info",
    };

    // ---- header bar ----
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        });
        defer hdr.deinit();
        if (style.button(@src(), "< Back to mods", .{}, .{})) {
            actions.closeWizard(frame);
            return true;
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        var title_buf: [256]u8 = undefined;
        const title = std.fmt.bufPrint(
            &title_buf,
            "Set up plan · step {d} of 2 · {s}",
            .{ step_num, step_title },
        ) catch "Set up plan";
        dvui.labelNoFmt(@src(), title, .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color), .gravity_y = 0.5 });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // ---- two-pane body ----
    // Hard-clamp left to LEFT_PANE_W (horizontal) AND clamp the body's
    // height (vertical) so the trailing footer row below always has
    // room to render. dvui's box layout is greedy — without an
    // explicit `max_size_content.h`, a child with `expand = both`
    // claims every pixel of vertical space the parent has and the
    // footer's Save/Cancel/Back row gets pushed off the bottom of
    // the OS window.
    const win_h = dvui.windowRect().h;
    // ~50 px header + ~60 px footer + 4 px of separators + a margin.
    const body_max_h: f32 = @max(200.0, win_h - 140.0);
    {
        // Stacked layout: step controls on top, the live preview BELOW at
        // full width. The preview (archive tree + impact diff) was cramped in
        // a narrow right column — long archive paths truncated. Full width
        // gives it room horizontally; it keeps the larger share of the height
        // and scrolls.
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .max_size_content = .{ .w = std.math.floatMax(f32), .h = body_max_h },
        });
        defer body.deinit();

        // Top: step controls (full width, bounded height + scroll so the
        // preview below always gets the larger share).
        {
            var top = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .max_size_content = .{ .w = std.math.floatMax(f32), .h = @max(170.0, body_max_h * 0.42) },
                .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
            });
            defer top.deinit();
            var top_scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer top_scroll.deinit();
            renderWizardStep(frame, game, w_ptr);
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        // Below: live preview — full width + the remaining height, scrollable.
        {
            var bottom = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .both,
                .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
            });
            defer bottom.deinit();
            renderWizardPreviewPane(frame, game, w_ptr);
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // ---- error line + footer (Cancel / Back / Next or Save) ----
    if (w_ptr.err_msg_len > 0) {
        const err_txt = w_ptr.err_msg_buf[0..w_ptr.err_msg_len];
        dvui.label(@src(), "Error: {s}", .{err_txt}, .{ .style = .err });
    }
    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 8, .w = 16, .h = 8 },
        });
        defer btn_row.deinit();
        if (components.iconButton(@src(), "Cancel", entypo.cross, .{ .style = .err })) {
            actions.closeWizard(frame);
            return true;
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (step_num > 1) {
            if (components.iconButton(@src(), "Back", entypo.chevron_left, .{})) {
                w_ptr.step = .install;
            }
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        }
        if (step_num < 2) {
            if (components.iconButton(@src(), "Next", entypo.chevron_right, .{ .style = .highlight })) {
                w_ptr.step = .meta;
            }
        } else {
            if (components.iconButton(@src(), "Save & Install", entypo.check, .{ .style = .highlight })) {
                actions.wizardSave(frame, game);
            }
        }
    }

    return true;
}

/// Render the controls for the currently active step in the left pane.
/// `state.step` is the source of truth; relations content is folded
/// into the review step behind a "Show advanced" toggle (not yet
/// implemented; relations renders inline for now).
fn renderWizardStep(frame: *Frame, game: *const library.Game, w_ptr: *state_mod.WizardState) void {
    switch (w_ptr.step) {
        .install => {
            renderStepIntro(
                "Install plan",
                "Each card moves files from the archive into the game folder. Flip the wrapper-folder toggle if the preview on the right doesn't look right yet.",
            );
            renderWizardInstallBlocks(frame, game, w_ptr);
        },
        .meta, .review, .relations => {
            renderStepIntro(
                "Mod info",
                "Names this mod in your library and on disk. Defaults to the archive's filename and version 1.0.",
            );
            renderMetaStepFresh(w_ptr);
        },
    }
}

/// Fresh step 2 — mod info card. Drops the previous renderWizardMeta
/// (which had random labels, a manual for_game preview line, and no
/// connection to the install-plan card's visual language). One card,
/// four labeled rows, the same border + fill + corner radius as the
/// step-1 blocks so the wizard feels like one app instead of two
/// glued together.
fn renderMetaStepFresh(w: *state_mod.WizardState) void {
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 14, .y = 12, .w = 14, .h = 12 },
        .background = true,
        .color_fill = cardFill(),
        .border = style.border_thin,
        .color_border = cardBorder(),
        .corner_radius = style.corner_radius,
    });
    defer card.deinit();

    metaFormRow("Mod name", &w.name_buf, 0);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    metaFormRow("Version", &w.version_buf, 1);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    metaTargetVersionRow(w);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    metaFormRow("Source URL (optional)", &w.post_url_buf, 2);
}

const META_LABEL_COL_W: f32 = 200;

fn metaFormRow(label: []const u8, buf: []u8, id_extra: usize) void {
    var row = dvui.box(@src(), .{
        .dir = .horizontal,
    }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
    });
    defer row.deinit();
    dvui.labelNoFmt(@src(), label, .{}, .{
        .id_extra = id_extra,
        .min_size_content = .{ .w = META_LABEL_COL_W, .h = 26 },
        .max_size_content = .{ .w = META_LABEL_COL_W, .h = std.math.floatMax(f32) },
        .gravity_y = 0.5,
        .color_text = helpTextColor(),
    });
    const te = style.textEntry(@src(), .{ .text = .{ .buffer = buf } }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .min_size_content = .{ .w = 1, .h = 28 },
        .gravity_y = 0.5,
    });
    te.deinit();
}

/// Target-game-version row — dropdown over the game's installed
/// versions, since the resolver matches mod-recipes to installs via
/// this field. Mirrors the picked label into `for_game_version_buf`
/// so wizardSave picks it up.
fn metaTargetVersionRow(w: *state_mod.WizardState) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = 3,
        .expand = .horizontal,
    });
    defer row.deinit();
    dvui.labelNoFmt(@src(), "Targets game version", .{}, .{
        .id_extra = 3,
        .min_size_content = .{ .w = META_LABEL_COL_W, .h = 26 },
        .max_size_content = .{ .w = META_LABEL_COL_W, .h = std.math.floatMax(f32) },
        .gravity_y = 0.5,
        .color_text = helpTextColor(),
    });

    var labels_buf: [state_mod.WIZARD_MAX_INSTALL_VERSIONS][]const u8 = undefined;
    var labels_n: usize = 0;
    while (labels_n < w.install_versions_count) : (labels_n += 1) {
        const v = w.install_versions_buf[labels_n];
        const end = std.mem.indexOfScalar(u8, &v, 0) orelse v.len;
        labels_buf[labels_n] = w.install_versions_buf[labels_n][0..end];
    }
    if (labels_n == 0) {
        dvui.label(@src(), "(no installs)", .{}, .{
            .id_extra = 3,
            .gravity_y = 0.5,
            .color_text = helpTextColor(),
        });
        return;
    }
    const labels = labels_buf[0..labels_n];
    var pick: usize = w.install_versions_pick;
    if (style.dropdown(@src(), labels, .{ .choice = &pick }, .{}, .{
        .id_extra = 3,
        .expand = .horizontal,
        .min_size_content = .{ .w = 1, .h = 28 },
        .gravity_y = 0.5,
    })) {
        w.install_versions_pick = pick;
        @memset(&w.for_game_version_buf, 0);
        const picked_label = labels[pick];
        const n = @min(picked_label.len, w.for_game_version_buf.len);
        @memcpy(w.for_game_version_buf[0..n], picked_label[0..n]);
    }
}

/// Consistent header + one-line help for every step. Centralises the
/// spacing so the three steps look related instead of each cooking up
/// their own intro layout.
fn renderStepIntro(title: []const u8, help: []const u8) void {
    const title_key = std.hash.Wyhash.hash(0, title);
    dvui.labelNoFmt(@src(), title, .{}, .{
        .id_extra = title_key,
        .color_text = tokens.toDvui(tokens.active.acc, dvui.Color),
    });
    _ = dvui.spacer(@src(), .{
        .id_extra = title_key,
        .min_size_content = .{ .w = 1, .h = 4 },
    });
    dvui.labelNoFmt(@src(), help, .{}, .{
        .id_extra = title_key ^ 1,
        .color_text = helpTextColor(),
    });
    _ = dvui.spacer(@src(), .{
        .id_extra = title_key ^ 2,
        .min_size_content = .{ .w = 1, .h = 12 },
    });
}

fn editorSectionHeader(title: []const u8) void {
    const key = std.hash.Wyhash.hash(0, title);
    _ = dvui.spacer(@src(), .{ .id_extra = key, .min_size_content = .{ .w = 1, .h = 8 } });
    dvui.labelNoFmt(@src(), title, .{}, .{
        .color_text = tokens.toDvui(tokens.active.acc, dvui.Color),
        .id_extra = key,
    });
    _ = dvui.spacer(@src(), .{ .id_extra = key, .min_size_content = .{ .w = 1, .h = 4 } });
}

fn editorSectionDivider(key: []const u8) void {
    const k = std.hash.Wyhash.hash(0, key);
    _ = dvui.spacer(@src(), .{ .id_extra = k, .min_size_content = .{ .w = 1, .h = 12 } });
    _ = dvui.separator(@src(), .{ .id_extra = k, .expand = .horizontal });
}

fn renderWizardMeta(w: *state_mod.WizardState) void {
    dvui.label(@src(), "Mod metadata. Required: Name, Version, Targets game version.", .{}, .{ .color_text = helpTextColor() });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    wizardTextRow(@src(), "Name", &w.name_buf);
    wizardTextRow(@src(), "Version", &w.version_buf);
    wizardTextRow(@src(), "F95 post URL", &w.post_url_buf);

    // Target-game-version: dropdown over installed builds. The wizard
    // refuses to open when there are no installs (in actions/mods.zig), so
    // we always have ≥1 entry here. Selecting a row mirrors it into
    // `for_game_version_buf` so the serializer doesn't have to know
    // about the dropdown indirection.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .y = 2, .h = 2 } });
        defer row.deinit();
        dvui.label(@src(), "Targets game version", .{}, .{
            .min_size_content = .{ .w = 160, .h = 24 },
            .gravity_y = 0.5,
            .color_text = helpTextColor(),
        });

        // Build a list of `[]const u8` slices into the wizard's
        // 32-byte fixed-size buffers — dvui.dropdown takes the slice
        // of slices and shows them as menu entries.
        var labels_buf: [state_mod.WIZARD_MAX_INSTALL_VERSIONS][]const u8 = undefined;
        var labels_n: usize = 0;
        while (labels_n < w.install_versions_count) : (labels_n += 1) {
            const v = w.install_versions_buf[labels_n];
            const end = std.mem.indexOfScalar(u8, &v, 0) orelse v.len;
            labels_buf[labels_n] = w.install_versions_buf[labels_n][0..end];
        }
        const labels = labels_buf[0..labels_n];

        var pick: usize = w.install_versions_pick;
        if (style.dropdown(@src(), labels, .{ .choice = &pick }, .{}, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 280, .h = 26 },
            .gravity_y = 0.5,
        })) {
            w.install_versions_pick = pick;
            // Mirror the picked label into for_game_version_buf so
            // wizardSave reads it without poking at the buffers array.
            @memset(&w.for_game_version_buf, 0);
            const picked_label = labels[pick];
            const n = @min(picked_label.len, w.for_game_version_buf.len);
            @memcpy(w.for_game_version_buf[0..n], picked_label[0..n]);
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    dvui.label(@src(), "for_game (auto): {s}", .{w.for_game_buf[0..w.for_game_len]}, .{ .color_text = helpTextColor() });
}

fn wizardTextRow(src: std.builtin.SourceLocation, label: []const u8, buf: []u8) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .y = 2, .h = 2 } });
    defer row.deinit();
    dvui.labelNoFmt(@src(), label, .{}, .{ .min_size_content = .{ .w = 160, .h = 24 }, .gravity_y = 0.5, .color_text = helpTextColor() });
    const te = style.textEntry(@src(), .{ .text = .{ .buffer = buf } }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 280, .h = 26 },
        .gravity_y = 0.5,
    });
    te.deinit();
}

/// Wizard text input + Browse popups for archive- and install-side
/// suggestions. Each non-empty list gets its own folder-icon button.
/// Click an item → fills `buf` (with a trailing `/`). Empty lists hide
/// the corresponding button. `block_idx` + `field_idx` ensure every
/// menu has a unique id_extra so multiple browse menus on the same
/// page don't collide.
fn wizardPathRow(
    src: std.builtin.SourceLocation,
    label: []const u8,
    buf: []u8,
    archive_dirs: []const []const u8,
    install_dirs: []const []const u8,
    block_idx: usize,
    field_idx: usize,
) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .y = 2, .h = 2 } });
    defer row.deinit();
    dvui.labelNoFmt(@src(), label, .{}, .{ .min_size_content = .{ .w = 160, .h = 24 }, .gravity_y = 0.5, .color_text = helpTextColor() });
    const te = style.textEntry(@src(), .{ .text = .{ .buffer = buf } }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 280, .h = 26 },
        .gravity_y = 0.5,
    });
    te.deinit();

    if (archive_dirs.len > 0) {
        wizardBrowseMenu(buf, archive_dirs, "Pick from archive", "browse-arch", block_idx, field_idx, 0);
    }
    if (install_dirs.len > 0) {
        wizardBrowseMenu(buf, install_dirs, "Pick from install", "browse-inst", block_idx, field_idx, 1);
    }
}

/// Render one Browse menu (folder icon with submenu of suggestions).
/// `salt` differentiates archive vs install menus on the same row.
fn wizardBrowseMenu(
    buf: []u8,
    suggestions: []const []const u8,
    tooltip: []const u8,
    id_tag: []const u8,
    block_idx: usize,
    field_idx: usize,
    salt: u8,
) void {
    _ = tooltip;
    const menu_key: u32 = @intCast(((block_idx & 0xFFFF) << 16) | ((field_idx & 0xFF) << 8) | salt);
    var m = dvui.menu(@src(), .horizontal, .{ .id_extra = menu_key, .gravity_y = 0.5 });
    defer m.deinit();
    if (dvui.menuItemIcon(@src(), id_tag, entypo.folder, .{ .submenu = true }, .{
        .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
        .min_size_content = .{ .w = 28, .h = style.button_h },
        .gravity_y = 0.5,
        .background = true,
        .style = .control,
        .corner_radius = style.corner_radius,
    })) |anchor| {
        var fw = dvui.floatingMenu(@src(), .{ .from = anchor }, .{});
        defer fw.deinit();
        for (suggestions, 0..) |s, i| {
            var sbuf: [256]u8 = undefined;
            const item = std.fmt.bufPrint(&sbuf, "{s}/", .{s}) catch s;
            if (dvui.menuItemLabel(@src(), item, .{}, .{
                .id_extra = @intCast(i),
                .expand = .horizontal,
            }) != null) {
                @memset(buf, 0);
                const n = @min(item.len, buf.len);
                @memcpy(buf[0..n], item[0..n]);
                m.close();
            }
        }
    }
}

fn renderWizardInstallBlocks(frame: *Frame, game: *const library.Game, w: *state_mod.WizardState) void {
    // Simulate the current plan once per paint. Block cards pull
    // per-step impact lines from the result.
    var sim_opt = actions.simulateCurrentPlan(frame, game);
    defer if (sim_opt) |*s| s.deinit();
    const sim_ptr: ?*const installer_mod.SimulationResult = if (sim_opt) |*s| s else null;

    // Suggestion sources for the Browse… menus on each path field.
    const modfile_id = w.modfile_id_buf[0..w.modfile_id_len];
    const archive_path_opt = actions.modfileArchivePath(frame, game, modfile_id);
    defer if (archive_path_opt) |p| frame.lib.alloc.free(p);
    const archive_dirs_opt = if (archive_path_opt) |p| actions.archiveTopDirs(frame, p) else null;
    defer if (archive_dirs_opt) |d| actions.freeTopDirs(frame.lib.alloc, d);
    const archive_dirs: []const []const u8 = if (archive_dirs_opt) |d| @as([]const []const u8, d) else &.{};

    const install_dirs_opt = actions.installTopDirs(frame, game);
    defer if (install_dirs_opt) |d| actions.freeTopDirs(frame.lib.alloc, d);
    const install_dirs: []const []const u8 = if (install_dirs_opt) |d| @as([]const []const u8, d) else &.{};

    // Block stack. Each block renders as a self-contained card with
    // its own border / background so the user can see them as
    // discrete units (the previous flat-list rendering blurred them
    // into one wall of text).
    var i: usize = 0;
    while (i < w.block_count) : (i += 1) {
        renderWizardBlockRow(frame, w, i, sim_ptr, archive_dirs, install_dirs);
        _ = dvui.spacer(@src(), .{
            .id_extra = i,
            .min_size_content = .{ .w = 1, .h = 8 },
        });
    }

    // Single "+ Add step" dropdown replaces the six bare buttons. The
    // first entry is a placeholder that picks nothing — same trick the
    // install-version dropdown uses elsewhere.
    {
        const labels = [_][]const u8{
            "+ Add another step\u{2026}",
            "Drop more files in (extract)",
            "Unpack a nested archive",
            "Copy a file",
            "Rename or move a file",
            "Remove a file from the install",
            "Mark a file as executable",
        };
        const kinds = [_]state_mod.WizardBlockKind{ .extract, .extract_inner, .copy, .move, .delete, .chmod_x };
        var pick: usize = 0;
        if (style.dropdown(@src(), &labels, .{ .choice = &pick }, .{}, .{
            .min_size_content = .{ .w = 260, .h = style.button_h },
        })) {
            if (pick > 0 and pick <= kinds.len) {
                actions.wizardAddBlock(frame, kinds[pick - 1]);
            }
        }
    }
}

/// Aggregate preview + collapsible per-file detail. Pulled out of the
/// install-blocks step so the Review step can render the same panel
/// without re-running the simulation.
fn renderSimulationPanel(
    frame: *Frame,
    w: *state_mod.WizardState,
    sim_opt: ?*const installer_mod.SimulationResult,
) void {
    if (sim_opt == null) {
        dvui.label(@src(), "Preview: not available yet (need an install + an archive on disk).", .{}, .{ .color_text = helpTextColor() });
        return;
    }
    const sim = sim_opt.?;

    // Aggregate summary first (one-line per category), then the
    // detailed file tree underneath. The previous Show/Hide-details
    // toggle is gone — the preview should always be visible without
    // the user having to expand it.
    renderSimulationAggregate(sim);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    renderSimulationDetail(frame, w, sim);
}

/// Plain-English aggregate (one labeled line per category). Hidden
/// when the plan is empty.
fn renderSimulationAggregate(sim: *const installer_mod.SimulationResult) void {
    const add_n = sim.addCount();
    const ow_van = sim.overwriteVanillaCount();
    const ow_mod = sim.overwriteModCount();
    const total_bytes = sim.totalBytes();
    const mode_n = sim.mode_changes.len;
    const del_n = sim.deletions.len;

    if (add_n + ow_van + ow_mod == 0 and mode_n == 0 and del_n == 0) {
        dvui.label(@src(), "This plan won't touch any files. Add at least one step above.", .{}, .{ .color_text = helpTextColor() });
        return;
    }

    if (add_n > 0) {
        var size_buf: [32]u8 = undefined;
        const size_txt = components.humanBytes(&size_buf, total_bytes);
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "+ Adds {d} new file(s)  ({s})", .{ add_n, size_txt }) catch "+ Adds files";
        dvui.labelNoFmt(@src(), txt, .{}, .{ .color_text = .{ .r = 0x4F, .g = 0xC3, .b = 0x6F } });
    }
    if (ow_van > 0) {
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "~ Overwrites {d} vanilla file(s)", .{ow_van}) catch "~ Overwrites vanilla";
        dvui.labelNoFmt(@src(), txt, .{}, .{ .color_text = .{ .r = 0xE0, .g = 0xC0, .b = 0x70 } });
    }
    if (ow_mod > 0) {
        var buf: [160]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "[!] Conflicts: {d} file(s) already owned by another mod", .{ow_mod}) catch "Conflicts with another mod";
        dvui.labelNoFmt(@src(), txt, .{}, .{ .color_text = .{ .r = 0xFF, .g = 0x80, .b = 0x80 } });
    }
    if (mode_n > 0) {
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "* Marks {d} file(s) as runnable", .{mode_n}) catch "Marks file(s) runnable";
        dvui.labelNoFmt(@src(), txt, .{}, .{ .color_text = helpTextColor() });
    }
    if (del_n > 0) {
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "- Removes {d} file(s)", .{del_n}) catch "Removes file(s)";
        dvui.labelNoFmt(@src(), txt, .{}, .{ .color_text = .{ .r = 0xE0, .g = 0xC0, .b = 0x70 } });
    }

    if (sim.diagnostics.len > 0) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
        for (sim.diagnostics) |d| {
            // Step-scoped diagnostics show next to their block; this
            // panel only renders the global ones (no source step).
            if (d.source_step_index != null) continue;
            const color: dvui.Color = switch (d.severity) {
                .info => helpTextColor(),
                .warn => .{ .r = 0xE0, .g = 0xC0, .b = 0x70 },
                .err => .{ .r = 0xFF, .g = 0x80, .b = 0x80 },
            };
            dvui.labelNoFmt(@src(), d.msg, .{}, .{ .color_text = color, .id_extra = std.hash.Wyhash.hash(0, d.msg) });
        }
    }
}

/// Tree-view detail with the install dir as the root header. Wraps
/// the rows in a `scrollArea` so long mod installs scroll instead of
/// stretching the wizard. Each directory rolls up file count + total
/// bytes from its descendants; files show action / size / step index.
/// 600-row hard cap to keep the renderer's worst case bounded.
fn renderSimulationDetail(frame: *Frame, w: *state_mod.WizardState, sim: *const installer_mod.SimulationResult) void {
    // Frame allocator (DebugAllocator-backed in debug builds) so the
    // per-paint tree's lifetime can be reported / leak-checked. Arena
    // sits on top of it for cheap one-deinit cleanup of the per-node
    // strings.
    var arena = std.heap.ArenaAllocator.init(frame.lib.alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    // Build the tree once per paint. Small enough (one allocation per
    // path segment, max a few thousand) that we don't bother caching.
    const root = TreeNode.init(aalloc, "", "", false) catch return;
    for (sim.writes) |*wr| insertWrite(aalloc, root, wr) catch {};
    for (sim.mode_changes) |*mc| annotateMode(aalloc, root, mc) catch {};
    for (sim.deletions) |*d| annotateDeletion(aalloc, root, d) catch {};
    rollupAggregates(root);
    sortTree(root);

    // Apply the preview pane's live search filter. Empty needle is a
    // no-op (everything stays visible). Non-empty filters out subtrees
    // that don't contain a matching name — directories stay visible
    // when any descendant matches so the path to a hit is preserved.
    const needle_raw = w.preview_search_buf[0..(std.mem.indexOfScalar(u8, &w.preview_search_buf, 0) orelse w.preview_search_buf.len)];
    const needle = std.mem.trim(u8, needle_raw, " \t");
    _ = markVisibleByQuery(root, needle);

    // Outer pane — same look as before but the inner column lives in
    // a scrollArea so long trees scroll inside a bounded height.
    // `expand = .both` lets the pane consume any vertical room the
    // wizard modal hands down past the aggregate / button rows; the
    // `min_size_content.h` floor keeps it usable even when the modal
    // is shrunk by the user.
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        .color_fill = tokens.toDvui(tokens.active.bg0, dvui.Color),
        .color_border = style.borderColor(),
        .min_size_content = .{ .w = 1, .h = 240 },
    });
    defer pane.deinit();

    // Root header — "<install_path>/" with aggregate counts. The
    // path here is the GAME ROOT (after wrapper-folder detection in
    // `simulateCurrentPlan`), so it matches where files will actually
    // land on disk.
    {
        var hdr_buf: [768]u8 = undefined;
        var counts_buf: [128]u8 = undefined;
        const counts_txt = std.fmt.bufPrint(&counts_buf, " ({d} file(s), {s})", .{
            root.sub_files,
            humanBytesLocal(root.sub_bytes),
        }) catch "";
        // Show just "Game folder/" instead of the absolute on-disk path
        // (`/media/shared/backup/.../library/79758/0.8/...`). The user
        // doesn't care where the game lives — they care about what the
        // mod drops *into* it. Sub-row paths below are already
        // relative to this root.
        _ = sim.install_dir;
        const hdr = std.fmt.bufPrint(&hdr_buf, "Game folder/{s}", .{counts_txt}) catch "Game folder/";
        dvui.labelNoFmt(@src(), hdr, .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color), .font = .theme(.mono) });
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
    });
    defer scroll.deinit();

    var rendered: usize = 0;
    const ROW_CAP: usize = 600;
    renderTreeNode(w, root, 1, &rendered, ROW_CAP);

    if (rendered >= ROW_CAP) {
        dvui.label(@src(), "... (more rows hidden; cap reached)", .{}, .{ .color_text = helpTextColor() });
    }
}

const TreeNode = struct {
    /// Last segment of the path (file or dir name).
    name: []const u8,
    /// Full path relative to install_dir. Used as a stable id_extra
    /// key for the row's dvui widget.
    rel_path: []const u8,
    /// True when this node represents a single file (leaf); false for
    /// directories.
    is_file: bool,
    /// Set for leaves that came from `sim.writes`.
    file: ?*const installer_mod.simulate_mod.FileWrite = null,
    /// Set for leaves that came from `sim.mode_changes` (chmod_x).
    /// May coexist with `file` (chmod on an extracted file).
    mode_change: ?*const installer_mod.simulate_mod.ModeChange = null,
    /// Set for leaves from `sim.deletions`.
    deletion: ?*const installer_mod.simulate_mod.PathDel = null,
    children: std.ArrayList(*TreeNode) = .empty,
    sub_files: usize = 0,
    sub_bytes: u64 = 0,
    /// Driven by `markVisibleByQuery` — false hides this node (and its
    /// subtree) from `renderTreeNode`. Defaults to true so a fresh
    /// build with an empty search query shows everything.
    visible: bool = true,

    pub fn init(a: std.mem.Allocator, name: []const u8, rel_path: []const u8, is_file: bool) !*TreeNode {
        const n = try a.create(TreeNode);
        n.* = .{ .name = name, .rel_path = rel_path, .is_file = is_file };
        return n;
    }
};

fn ensureChild(a: std.mem.Allocator, parent: *TreeNode, name: []const u8, rel_path: []const u8, is_file: bool) !*TreeNode {
    for (parent.children.items) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    const child = try TreeNode.init(a, name, rel_path, is_file);
    try parent.children.append(a, child);
    return child;
}

fn insertWrite(a: std.mem.Allocator, root: *TreeNode, w: *const installer_mod.simulate_mod.FileWrite) !void {
    const node = try walkOrCreate(a, root, w.rel_path);
    node.is_file = true;
    node.file = w;
}

fn annotateMode(a: std.mem.Allocator, root: *TreeNode, mc: *const installer_mod.simulate_mod.ModeChange) !void {
    const node = try walkOrCreate(a, root, mc.rel_path);
    if (node.file == null and node.deletion == null) node.is_file = true;
    node.mode_change = mc;
}

fn annotateDeletion(a: std.mem.Allocator, root: *TreeNode, d: *const installer_mod.simulate_mod.PathDel) !void {
    const node = try walkOrCreate(a, root, d.rel_path);
    if (node.file == null and node.mode_change == null) node.is_file = true;
    node.deletion = d;
}

fn walkOrCreate(a: std.mem.Allocator, root: *TreeNode, rel: []const u8) !*TreeNode {
    var cursor = root;
    var rest = rel;
    while (rest.len > 0) {
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        if (slash) |s| {
            const seg = rest[0..s];
            // Build the full path-to-here so the node carries it.
            const here = if (cursor.rel_path.len == 0)
                try a.dupe(u8, seg)
            else
                try std.fmt.allocPrint(a, "{s}/{s}", .{ cursor.rel_path, seg });
            cursor = try ensureChild(a, cursor, try a.dupe(u8, seg), here, false);
            rest = rest[s + 1 ..];
        } else {
            const here = if (cursor.rel_path.len == 0)
                try a.dupe(u8, rest)
            else
                try std.fmt.allocPrint(a, "{s}/{s}", .{ cursor.rel_path, rest });
            const leaf = try ensureChild(a, cursor, try a.dupe(u8, rest), here, true);
            return leaf;
        }
    }
    return cursor;
}

fn rollupAggregates(node: *TreeNode) void {
    for (node.children.items) |c| rollupAggregates(c);
    if (node.is_file) {
        node.sub_files = 1;
        node.sub_bytes = if (node.file) |f| f.size_bytes else 0;
        return;
    }
    var files: usize = 0;
    var bytes: u64 = 0;
    for (node.children.items) |c| {
        files += c.sub_files;
        bytes += c.sub_bytes;
    }
    node.sub_files = files;
    node.sub_bytes = bytes;
}

/// Recursive: a node is visible if its own name contains `needle`
/// (case-insensitive) OR any descendant is visible. With an empty
/// needle everything stays visible. Returns the resolved visibility
/// so the caller doesn't have to re-check `node.visible`.
fn markVisibleByQuery(node: *TreeNode, needle: []const u8) bool {
    if (needle.len == 0) {
        node.visible = true;
        for (node.children.items) |c| _ = markVisibleByQuery(c, needle);
        return true;
    }
    var any_child_match = false;
    for (node.children.items) |c| {
        if (markVisibleByQuery(c, needle)) any_child_match = true;
    }
    const self_match = types.asciiContainsIgnoreCase(node.name, needle);
    node.visible = self_match or any_child_match;
    return node.visible;
}

fn sortTree(node: *TreeNode) void {
    std.mem.sort(*TreeNode, node.children.items, {}, struct {
        fn lessThan(_: void, a: *TreeNode, b: *TreeNode) bool {
            // Dirs (non-leaf) before files; otherwise name-asc.
            const a_dir = !a.is_file;
            const b_dir = !b.is_file;
            if (a_dir != b_dir) return a_dir;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    for (node.children.items) |c| sortTree(c);
}

fn renderTreeNode(
    w: *state_mod.WizardState,
    node: *TreeNode,
    depth: usize,
    rendered: *usize,
    cap: usize,
) void {
    for (node.children.items) |c| {
        if (rendered.* >= cap) return;
        if (!c.visible) continue;
        renderOneRow(w, c, depth, rendered);
        if (!c.is_file) {
            renderTreeNode(w, c, depth + 1, rendered, cap);
        }
    }
}

fn renderOneRow(
    w: *state_mod.WizardState,
    node: *TreeNode,
    depth: usize,
    rendered: *usize,
) void {
    // Indent via leading spaces. Two spaces per depth level — mono
    // font is set on the labels so the columns line up.
    var indent_buf: [128]u8 = undefined;
    const indent_count = @min(depth * 2, indent_buf.len);
    @memset(indent_buf[0..indent_count], ' ');
    const indent = indent_buf[0..indent_count];

    const highlight = w.sim_highlight_step;
    const id_extra = std.hash.Wyhash.hash(3, node.rel_path);

    // Mono font at typical wizard widths fits ~60 chars per line
    // before the right edge clips. Reserve room for indent + suffix
    // metadata and middle-truncate names longer than the remainder.
    const max_name_len: usize = if (depth >= 4) 38 else 50;
    var name_buf: [128]u8 = undefined;
    const name_shown = truncMiddle(&name_buf, node.name, max_name_len);

    if (!node.is_file) {
        // Directory row — name + aggregate counts, dim.
        var line_buf: [320]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}/  ({d} file(s), {s})", .{
            indent, name_shown, node.sub_files, humanBytesLocal(node.sub_bytes),
        }) catch node.name;
        dvui.labelNoFmt(@src(), line, .{}, .{
            .id_extra = id_extra,
            .color_text = .{ .r = 0xA0, .g = 0x80, .b = 0x90 },
            .font = .theme(.mono),
        });
        rendered.* += 1;
        return;
    }

    // File row — action + name + size + step idx + extras.
    var action_glyph: []const u8 = "* "; // chmod-only by default
    var action_color: dvui.Color = style.labelDim();
    var step_idx: usize = 0;
    var dimmed = false;
    var extra_buf: [192]u8 = undefined;
    var extras: []const u8 = "";
    var size_bytes: u64 = 0;

    if (node.file) |f| {
        size_bytes = f.size_bytes;
        step_idx = f.source_step_index;
        action_glyph = switch (f.action) {
            .add => "+ ",
            .overwrite_vanilla => "~ ",
            .overwrite_mod => "! ",
        };
        action_color = switch (f.action) {
            .add => .{ .r = 0x4F, .g = 0xC3, .b = 0x6F },
            .overwrite_vanilla => .{ .r = 0xE0, .g = 0xC0, .b = 0x70 },
            .overwrite_mod => .{ .r = 0xFF, .g = 0x80, .b = 0x80 },
        };
        if (f.conflicting_mod) |m| {
            extras = std.fmt.bufPrint(&extra_buf, "   (owned by `{s}`)", .{m}) catch "";
        }
    } else if (node.deletion) |d| {
        step_idx = d.source_step_index;
        action_glyph = "- ";
        action_color = if (!d.existed)
            style.labelDim()
        else
            .{ .r = 0xE0, .g = 0xC0, .b = 0x70 };
        if (!d.existed) extras = "   (no matching file in plan)";
    } else if (node.mode_change) |mc| {
        step_idx = mc.source_step_index;
        if (mc.missing) {
            extras = "   (no-op - file not produced)";
            action_color = style.labelDim();
        }
    }

    if (highlight) |h| dimmed = h != step_idx;
    const eff_color = if (dimmed) helpTextColor() else action_color;

    var line_buf: [320]u8 = undefined;
    const size_txt = humanBytesLocal(size_bytes);
    const line = std.fmt.bufPrint(&line_buf, "{s}{s}{s}   {s}   step #{d}{s}", .{
        indent,
        action_glyph,
        name_shown,
        size_txt,
        step_idx + 1,
        extras,
    }) catch node.name;
    dvui.labelNoFmt(@src(), line, .{}, .{
        .id_extra = id_extra,
        .color_text = eff_color,
        .font = .theme(.mono),
    });
    rendered.* += 1;
}

/// Tiny humanBytes wrapper that returns a static-buffer string. Used
/// by the tree row formatter; each call has its own scratch.
fn humanBytesLocal(n: u64) []const u8 {
    const Static = struct {
        var buf: [32]u8 = undefined;
    };
    return components.humanBytes(&Static.buf, n);
}

/// Middle-ellipsize a string longer than `max_len` so it fits on a
/// tree row without sliding off the right edge of the scroll area.
/// Returns either the original slice (when short enough) or a view
/// into `out_buf` containing `<head>…<tail>`. UTF-8-naive — fine for
/// archive paths which are conventionally ASCII.
fn truncMiddle(out_buf: []u8, s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    if (out_buf.len < max_len) return s;
    if (max_len < 5) return s; // not enough room for "a…b"
    const ellipsis = "...";
    const head_len = (max_len - ellipsis.len) / 2;
    const tail_len = max_len - ellipsis.len - head_len;
    @memcpy(out_buf[0..head_len], s[0..head_len]);
    @memcpy(out_buf[head_len .. head_len + ellipsis.len], ellipsis);
    @memcpy(out_buf[head_len + ellipsis.len .. head_len + ellipsis.len + tail_len], s[s.len - tail_len ..]);
    return out_buf[0 .. head_len + ellipsis.len + tail_len];
}

/// Right pane content for every wizard step. Top section shows the
/// archive's top-level layout (so the user can decide what the
/// "wrapper folder" question is actually referring to). Bottom section
/// is the existing simulation panel — what the install dir will look
/// like after the plan runs.
fn renderWizardPreviewPane(frame: *Frame, game: *const library.Game, w: *state_mod.WizardState) void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    // -- Archive tree (top-level entries only) --
    dvui.labelNoFmt(@src(), "Archive contents", .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });

    const modfile_id = w.modfile_id_buf[0..w.modfile_id_len];
    const archive_path_opt = actions.modfileArchivePath(frame, game, modfile_id);
    defer if (archive_path_opt) |p| frame.lib.alloc.free(p);

    if (archive_path_opt) |archive_path| {
        if (actions.archiveTopDirs(frame, archive_path)) |dirs| {
            defer actions.freeTopDirs(frame.lib.alloc, dirs);
            if (dirs.len == 0) {
                dvui.label(@src(), "  (archive has no top-level folders — files sit at the root)", .{}, .{
                    .color_text = helpTextColor(),
                });
            } else if (dirs.len == 1) {
                // Single top-level dir → almost always the "wrapper"
                // the user wants to skip. Surface that interpretation
                // here so step 1's checkbox label makes sense. Plain
                // ASCII so we don't depend on emoji font fallback.
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .id_extra = std.hash.Wyhash.hash(0, dirs[0]),
                });
                defer row.deinit();
                dvui.icon(@src(), "wrapper-dir", entypo.folder, .{}, .{ .gravity_y = 0.5 });
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
                var buf: [320]u8 = undefined;
                const txt = std.fmt.bufPrint(&buf, "{s}/  — likely wrapper folder", .{dirs[0]}) catch dirs[0];
                dvui.labelNoFmt(@src(), txt, .{}, .{ .gravity_y = 0.5 });
            } else {
                for (dirs) |d| {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .expand = .horizontal,
                        .id_extra = std.hash.Wyhash.hash(0, d),
                    });
                    defer row.deinit();
                    dvui.icon(@src(), "dir", entypo.folder, .{}, .{
                        .gravity_y = 0.5,
                        .id_extra = std.hash.Wyhash.hash(1, d),
                    });
                    _ = dvui.spacer(@src(), .{
                        .id_extra = std.hash.Wyhash.hash(2, d),
                        .min_size_content = .{ .w = 6, .h = 1 },
                    });
                    var buf: [256]u8 = undefined;
                    const txt = std.fmt.bufPrint(&buf, "{s}/", .{d}) catch d;
                    dvui.labelNoFmt(@src(), txt, .{}, .{
                        .gravity_y = 0.5,
                        .id_extra = std.hash.Wyhash.hash(3, d),
                    });
                }
            }
        } else {
            dvui.label(@src(), "  (archive not readable from disk)", .{}, .{ .style = .err });
        }
    } else {
        dvui.label(@src(), "  (no archive linked to this recipe yet)", .{}, .{ .color_text = helpTextColor() });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });

    // -- Impact diff (existing simulation panel) --
    dvui.labelNoFmt(@src(), "After install", .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });

    // Search bar — filters the tree below by file/dir name (case-
    // insensitive substring). Empty query passes everything through.
    {
        var search_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .y = 0, .h = 6 },
        });
        defer search_row.deinit();
        dvui.icon(@src(), "search", entypo.magnifying_glass, .{}, .{
            .gravity_y = 0.5,
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &w.preview_search_buf },
            .placeholder = "Filter files (e.g. `.rpy`, `game/`)",
        }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = 26 },
            .gravity_y = 0.5,
        });
        te.deinit();
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    var sim_opt = actions.simulateCurrentPlan(frame, game);
    defer if (sim_opt) |*s| s.deinit();
    const sim_ptr: ?*const installer_mod.SimulationResult = if (sim_opt) |*s| s else null;
    {
        var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .id_extra = std.hash.Wyhash.hash(0, "sim-panel-rightpane"),
        });
        defer wrap.deinit();
        renderSimulationPanel(frame, w, sim_ptr);
    }
}

/// Back-compat helper — used by other call sites that still want the
/// embedded simulation panel without the archive-tree header.
fn renderSimulationSummary(frame: *Frame, game: *const library.Game) void {
    var sim_opt = actions.simulateCurrentPlan(frame, game);
    defer if (sim_opt) |*s| s.deinit();
    const sim_ptr: ?*const installer_mod.SimulationResult = if (sim_opt) |*s| s else null;

    // Use the same panel as the install-blocks step so Review reads
    // identically — same details toggle, same aggregate counts.
    const w = &(frame.state.wizard orelse return);
    {
        // Distinct parent so the Review preview's widget ids don't
        // collide with the Install-blocks preview (same code, different
        // call site, both rendered on the same paint).
        var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .id_extra = std.hash.Wyhash.hash(0, "sim-panel-review"),
        });
        defer wrap.deinit();
        renderSimulationPanel(frame, w, sim_ptr);
    }
}

/// Plain-language label for a wizard block kind. Used in row titles.
fn blockKindLabel(k: state_mod.WizardBlockKind) []const u8 {
    return switch (k) {
        .extract => "Extract",
        .extract_inner => "Unpack inner archive",
        .copy => "Copy",
        .move => "Move",
        .delete => "Delete",
        .chmod_x => "Make runnable",
    };
}

/// Per-block help text, shown under the kind label so the user
/// understands what this step does without leaving the wizard.
fn blockKindHelp(k: state_mod.WizardBlockKind) []const u8 {
    return switch (k) {
        .extract => "Unpack the archive into a folder of the game. Use \".\" for the install root.",
        .extract_inner => "Some mods ship as an archive inside an archive. This unpacks the inner one.",
        .copy => "Copy a file (already produced by an earlier step) to another location.",
        .move => "Rename or move a file that an earlier step put down.",
        .delete => "Remove a file (from the install dir, even a vanilla one).",
        .chmod_x => "Mark a script/binary as executable. No-op on Windows.",
    };
}

fn renderWizardBlockRow(
    frame: *Frame,
    w: *state_mod.WizardState,
    idx: usize,
    sim: ?*const installer_mod.SimulationResult,
    archive_dirs: []const []const u8,
    install_dirs: []const []const u8,
) void {
    const b = &w.blocks[idx];
    const is_highlight = w.sim_highlight_step != null and w.sim_highlight_step.? == idx;

    // Card container — bordered box with darker fill, makes each step
    // a discrete unit instead of blending into the page background.
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
        .id_extra = idx,
        .background = true,
        .color_fill = if (is_highlight) cardFillHi() else cardFill(),
        .border = style.border_thin,
        .color_border = cardBorder(),
        .corner_radius = style.corner_radius,
    });
    defer card.deinit();

    // ---- title bar: "Step N" (muted) · KIND (bold) · spacer · trash
    // Layout is intentionally identical across every block kind so a
    // user scanning multiple cards lands on the same fields in the
    // same screen position. No button-shaped affordances on labels —
    // the only clickable thing on this row is the trash icon.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = idx,
        });
        defer hdr.deinit();

        var step_buf: [16]u8 = undefined;
        const step_txt = std.fmt.bufPrint(&step_buf, "Step {d}", .{idx + 1}) catch "Step";
        dvui.labelNoFmt(@src(), step_txt, .{}, .{
            .color_text = helpTextColor(),
            .gravity_y = 0.5,
            .id_extra = idx,
        });
        _ = dvui.spacer(@src(), .{
            .id_extra = idx,
            .min_size_content = .{ .w = 8, .h = 1 },
        });
        dvui.labelNoFmt(@src(), blockKindLabel(b.kind), .{}, .{
            .color_text = tokens.toDvui(tokens.active.acc, dvui.Color),
            .gravity_y = 0.5,
            .id_extra = idx,
        });
        _ = dvui.spacer(@src(), .{
            .id_extra = idx,
            .expand = .horizontal,
        });
        if (components.iconOnly(@src(), "remove-step", entypo.trash, .{
            .style = .err,
            .gravity_y = 0.5,
            .id_extra = idx,
        })) {
            actions.wizardRemoveBlock(frame, idx);
            return;
        }
    }

    // Thin divider under the title — visually anchors the card and
    // makes the field block below feel grouped.
    _ = dvui.spacer(@src(), .{
        .id_extra = idx,
        .min_size_content = .{ .w = 1, .h = 6 },
    });
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = idx });
    _ = dvui.spacer(@src(), .{
        .id_extra = idx,
        .min_size_content = .{ .w = 1, .h = 8 },
    });

    // ---- block-specific inputs ----
    // Labels are deliberately short (one word where possible) so the
    // 160 px label column reads cleanly across every card kind. The
    // longer help text lives once at the top of the step intro, not
    // duplicated per field.
    const empty_dirs: []const []const u8 = &.{};
    switch (b.kind) {
        .extract => {
            wizardPathRow(@src(), "Destination", &b.a_buf, empty_dirs, install_dirs, idx, 0);
            _ = dvui.spacer(@src(), .{
                .id_extra = idx,
                .min_size_content = .{ .w = 1, .h = 6 },
            });
            wizardStripCheckbox(b);
        },
        .extract_inner => {
            wizardPathRow(@src(), "Inner archive", &b.a_buf, archive_dirs, empty_dirs, idx, 1);
            _ = dvui.spacer(@src(), .{ .id_extra = idx, .min_size_content = .{ .w = 1, .h = 6 } });
            wizardPathRow(@src(), "Destination", &b.b_buf, empty_dirs, install_dirs, idx, 2);
            _ = dvui.spacer(@src(), .{ .id_extra = idx, .min_size_content = .{ .w = 1, .h = 6 } });
            wizardStripCheckbox(b);
        },
        .copy, .move => {
            wizardPathRow(@src(), "From", &b.a_buf, archive_dirs, empty_dirs, idx, 3);
            _ = dvui.spacer(@src(), .{ .id_extra = idx, .min_size_content = .{ .w = 1, .h = 6 } });
            wizardPathRow(@src(), "To", &b.b_buf, empty_dirs, install_dirs, idx, 4);
        },
        .delete => {
            wizardPathRow(@src(), "Path", &b.a_buf, empty_dirs, install_dirs, idx, 5);
        },
        .chmod_x => {
            wizardPathRow(@src(), "Path", &b.a_buf, empty_dirs, install_dirs, idx, 6);
        },
    }

    // ---- per-block impact line at bottom of card ----
    if (sim) |s| {
        if (idx < s.impacts.len) {
            _ = dvui.spacer(@src(), .{ .id_extra = idx, .min_size_content = .{ .w = 1, .h = 8 } });
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = idx });
            _ = dvui.spacer(@src(), .{ .id_extra = idx, .min_size_content = .{ .w = 1, .h = 4 } });
            const imp = s.impacts[idx];
            renderBlockImpactLine(b.kind, imp);
        }
        // Inline diagnostics for THIS block under the impact line.
        for (s.diagnostics) |d| {
            if (d.source_step_index == null or d.source_step_index.? != idx) continue;
            const color: dvui.Color = switch (d.severity) {
                .info => helpTextColor(),
                .warn => .{ .r = 0xE0, .g = 0xC0, .b = 0x70 },
                .err => .{ .r = 0xFF, .g = 0x80, .b = 0x80 },
            };
            dvui.labelNoFmt(@src(), d.msg, .{}, .{
                .color_text = color,
                .id_extra = std.hash.Wyhash.hash(0, d.msg) ^ @as(u64, idx),
            });
        }
    }
}

/// One-line "Will write N file(s), X.X MiB" under the block header
/// when the simulator has data for this block. Helps the user verify
/// each step before saving.
fn renderBlockImpactLine(kind: state_mod.WizardBlockKind, imp: installer_mod.simulate_mod.StepImpact) void {
    if (imp.no_op) {
        dvui.label(@src(), "No effect from this step yet.", .{}, .{ .color_text = helpTextColor() });
        return;
    }
    switch (kind) {
        .extract, .extract_inner, .copy => {
            if (imp.files_written == 0) return;
            var size_buf: [32]u8 = undefined;
            const size_txt = components.humanBytes(&size_buf, imp.bytes_written);
            var buf: [128]u8 = undefined;
            const mod_part: []const u8 = if (imp.files_modified > 0) blk: {
                var mb: [48]u8 = undefined;
                break :blk std.fmt.bufPrint(&mb, "  ({d} overwrite existing)", .{imp.files_modified}) catch "";
            } else "";
            const line = std.fmt.bufPrint(&buf, "Will write {d} file(s), {s}{s}", .{
                imp.files_written, size_txt, mod_part,
            }) catch "";
            dvui.labelNoFmt(@src(), line, .{}, .{ .color_text = style.labelDim() });
        },
        .move => {
            if (imp.files_written == 0) return;
            dvui.label(@src(), "Will relocate 1 file.", .{}, .{ .color_text = style.labelDim() });
        },
        .delete => {
            if (imp.deletions == 0) return;
            var buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "Will remove {d} path(s).", .{imp.deletions}) catch "";
            dvui.labelNoFmt(@src(), line, .{}, .{ .color_text = style.labelDim() });
        },
        .chmod_x => {
            if (imp.mode_changes == 0) return;
            var buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "Will mark {d} file(s) runnable.", .{imp.mode_changes}) catch "";
            dvui.labelNoFmt(@src(), line, .{}, .{ .color_text = style.labelDim() });
        },
    }
}

/// Plain-checkbox replacement for the old +/- strip stepper. The
/// integer field stays on the block (recipes support strip > 1 in
/// principle), but the wizard's UI maps it to a two-state toggle —
/// 0 (off) vs 1 (on). Covers the 99% case without forcing the user
/// to parse "strip components."
fn wizardStripCheckbox(b: *state_mod.WizardBlock) void {
    // dvui.checkbox uses the label as its click target — an empty
    // label means clicking the box itself does nothing on some
    // backends (previously caused this toggle to read as ignored).
    // The label IS the click affordance; rendering a separate label
    // widget on the left wouldn't be clickable. Keep this row
    // visually distinct from the path rows above; users still get
    // that "Skip wrapper folder" is its own decision.
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .y = 2, .h = 2 },
    });
    defer row.deinit();
    // Spacer for the same 160 px indent the path-row labels use, so
    // the checkbox sits aligned with the textEntry's start column.
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 160, .h = 1 } });
    var on: bool = b.strip > 0;
    if (dvui.checkbox(@src(), &on, "Skip wrapper folder", .{ .gravity_y = 0.5 })) {
        b.strip = if (on) 1 else 0;
    }
}

fn renderWizardRelations(frame: *Frame, game: *const library.Game, w: *state_mod.WizardState) void {
    _ = frame;
    _ = game;
    dvui.label(@src(), "Relations to other mods. Comma-separated recipe ids.", .{}, .{ .color_text = helpTextColor() });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // For v1: each row is a fixed-size textbox the user types one id
    // into. Up to WIZARD_MAX_RELATIONS rows. A future polish pass can
    // turn this into a picker over `recipe_repo.listModsForGame`.
    // Each group must have a distinct id_extra on its outer box so
    // the three groups' children (label, rows, Add button) don't
    // collide on the same `@src()`. Without this dvui flags every
    // duplicate-widget error every frame.
    wizardRelationGroup(0, "Requires", &w.requires_buf, &w.requires_len);
    wizardRelationGroup(1, "Conflicts with", &w.conflicts_buf, &w.conflicts_len);
    wizardRelationGroup(2, "Load after", &w.load_after_buf, &w.load_after_len);
}

fn wizardRelationGroup(group_idx: usize, label: []const u8, bufs: [][64]u8, len: *usize) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .y = 4, .h = 4 },
        .id_extra = group_idx,
    });
    defer box.deinit();
    dvui.label(@src(), "{s}:", .{label}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    var i: usize = 0;
    while (i < len.*) : (i += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
        defer row.deinit();
        const te = style.textEntry(@src(), .{ .text = .{ .buffer = &bufs[i] } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 280, .h = 24 },
            .gravity_y = 0.5,
        });
        te.deinit();
        if (style.button(@src(), "−", .{}, .{ .style = .err })) {
            var j: usize = i;
            while (j + 1 < len.*) : (j += 1) {
                bufs[j] = bufs[j + 1];
            }
            @memset(&bufs[len.* - 1], 0);
            len.* -= 1;
            return;
        }
    }
    if (len.* < bufs.len) {
        if (style.button(@src(), "Add", .{}, .{})) {
            @memset(&bufs[len.*], 0);
            len.* += 1;
        }
    }
}

/// Trim a wizard inline buffer to the first null byte. Buffers are
/// fixed-size `[N]u8` zero-padded; raw slicing leaks the trailing
/// zeros which dvui renders as tofu/null-glyph boxes.
fn bufToSlice(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

fn renderWizardReview(frame: *Frame, game: *const library.Game, w: *state_mod.WizardState) void {
    dvui.label(@src(), "Review. Save writes <id>.mod.zon to your local recipes dir.", .{}, .{ .color_text = helpTextColor() });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // Slice the inline buffers up to the first null byte — printing
    // the raw fixed-size buffer leaks trailing zero bytes which dvui
    // renders as tofu/null-glyph boxes.
    const name = bufToSlice(&w.name_buf);
    const version = bufToSlice(&w.version_buf);
    dvui.label(@src(), "Name:    {s}", .{name}, .{});
    dvui.label(@src(), "Version: {s}", .{version}, .{});
    dvui.label(@src(), "for_game: {s}", .{w.for_game_buf[0..w.for_game_len]}, .{});

    var ver_count_buf: [64]u8 = undefined;
    const block_count_txt = std.fmt.bufPrint(&ver_count_buf, "{d}", .{w.block_count}) catch "?";
    dvui.label(@src(), "Install steps: {s}", .{block_count_txt}, .{});

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    if (w.requires_len > 0) dvui.label(@src(), "requires {d}", .{w.requires_len}, .{});
    if (w.conflicts_len > 0) dvui.label(@src(), "conflicts {d}", .{w.conflicts_len}, .{});
    if (w.load_after_len > 0) dvui.label(@src(), "load_after {d}", .{w.load_after_len}, .{});

    // Show the same preview here so the user has a final-look summary
    // before they hit Save. Game is needed for the install dir lookup.
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    renderSimulationSummary(frame, game);

    // Test install (real). Runs the actual installer against a
    // scratch dir under /tmp; surfaces file count + total bytes as
    // a toast. Trust-but-verify before committing the recipe. The
    // worker runs on a background thread so the UI stays responsive
    // for large mods; button label flips to "Testing…" + click is a
    // no-op while in flight.
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.label(@src(), "Trust-but-verify:", .{}, .{ .gravity_y = 0.5, .color_text = helpTextColor() });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        const running = actions.isTestInstallRunning(frame.state);
        const lbl: []const u8 = if (running) "Testing\u{2026}" else "Test install (real)";
        if (style.button(@src(), lbl, .{}, .{ .style = if (running) .control else null })) {
            if (!running) actions.doTestInstallPreview(frame, game);
        }
    }
    dvui.label(@src(), "Runs the actual installer against `/tmp/f69-preview-…` on a background thread. Doesn't touch your game's install dir.", .{}, .{ .color_text = helpTextColor() });
}
