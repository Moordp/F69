// Import screens — three separate dialogs:
//
//   - `importUrlsScreen`       paste F95 thread URLs/IDs
//   - `importF95CheckerScreen` scan an F95Checker / xLibrary games dir
//   - `importFolderScreen`     scan any flat games directory
//
// The two folder-scan screens share the same scan/resolve backend but
// carry different intro copy so the user can pick the path that
// matches what they actually have on disk. All three wrap their body
// in `dvui.scrollArea` so cramped windows scroll instead of clipping.

const std = @import("std");
const dvui = @import("dvui");
const library = @import("library");
const f95 = @import("f95");
const importers = @import("importers");

const types = @import("../types.zig");
const style = @import("../style.zig");
const actions = @import("../actions.zig");
const state_mod = @import("../state.zig");
const components = @import("../components.zig");
const file_picker = @import("util_file_picker");
const tokens = @import("ui_tokens");
const entypo = dvui.entypo;

const Frame = types.Frame;
const State = state_mod.State;

const LINK_PREVIEW_MAX_SUGGESTIONS: usize = 3;

// ============================================================
//  Screen 1 — paste F95 thread URLs / IDs
// ============================================================

pub fn importUrlsScreen(frame: *Frame) !bool {
    const state = frame.state;

    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();
        if (components.iconButton(@src(), "Back", entypo.chevron_left, .{})) state.screen = .library;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.label(@src(), "Import by F95 URL / ID", .{}, .{ .gravity_y = 0.5, .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "Import", .{}, .{ .style = .highlight })) {
            const result = doImport(frame, state.importBufSlice());
            var msg_buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&msg_buf, "imported {d}, skipped {d}", .{ result.ok, result.skipped }) catch "imported";
            state.setImportMsg(m);
            if (result.ok > 0) {
                // Manual paste import: same rule as the bookmark
                // worker — never auto-sync. Just reload so the grid
                // shows the new placeholders; the user starts syncs
                // explicitly via Sync All / Updates / per-game Sync.
                state.reload_requested = true;
                @memset(&state.import_buf, 0);
                state.screen = .library;
            }
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 24, .y = 16, .w = 24, .h = 16 },
    });
    defer body.deinit();

    dvui.label(@src(), "Paste F95Zone thread URLs or numeric IDs (one per line):", .{}, .{});
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    const te = style.textEntry(@src(), .{
        .text = .{ .buffer = &state.import_buf },
        .multiline = true,
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 600, .h = 300 },
    });
    te.deinit();

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    if (!state.import_msg.isEmpty()) {
        dvui.labelNoFmt(@src(), state.importMsg(), .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    } else {
        dvui.label(@src(), "Imported games show up as \"(unsynced)\". Click Sync on each to populate.", .{}, .{});
    }

    return true;
}

// ============================================================
//  Screen 2 — generic folder scan
//
//  (A second entry that targeted F95Checker / xLibrary games dirs
//  specifically existed here once. It routed to the same folder
//  scanner with different intro copy — pure duplication. Removed
//  along with `Tab.import_f95checker`. The Settings → Library
//  "Import from F95Checker…" button is the real F95Checker
//  migration path; it reads the upstream DB.)
// ============================================================

pub fn importFolderScreen(frame: *Frame) !bool {
    return renderFolderScanScreen(frame, .{
        .title = "Import from a folder",
        .intro =
        "Point at any directory of installed games. Each subfolder is parsed for " ++
            "a name + version using common patterns. For each entry you'll then " ++
            "paste an F95Zone URL or add it as a custom row.",
        .placeholder = "/path/to/games",
    });
}

// ============================================================
//  Screen 3 — F95Checker review (mode picker + game list)
// ============================================================
//
// Surfaced after the user clicks Settings → "Import from F95Checker…"
// (and after the games-base-dir picker). Lists every game read out of
// the F95Checker DB, shows the mode picker right at the top so the
// user picks Move / Copy / Link at the moment of import. Apply spawns
// the existing import worker; Cancel discards.

pub fn importF95CheckerReviewScreen(frame: *Frame) !bool {
    const state = frame.state;

    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();
        if (components.iconButton(@src(), "Back", entypo.chevron_left, .{})) {
            actions.doCancelF95CheckerReview(frame);
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.labelNoFmt(@src(), "Import from F95Checker — review", .{}, .{ .gravity_y = 0.5, .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .min_size_content = .{ .w = 720, .h = 400 },
        .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
    });
    defer body.deinit();

    // Read-only-source assurance. This is the load-bearing UX claim
    // for users wary of the 2026-05-28 data-loss incident — spell it
    // out so the user doesn't have to read the code to trust it.
    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
        tl.addText(
            "Your F95Checker database is opened READ-ONLY. Nothing in " ++
                "~/.config/f95checker/ is modified — including in Move mode. " ++
                "Move/Copy/Link only affects the game folders themselves.",
            .{ .font = dvui.Font.theme(.body).withSize(11) },
        );
        tl.deinit();
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // Mode picker — same three-button layout as Settings, but right
    // next to the game list so the user makes the choice in context.
    renderFolderScanModeToggle(state);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // Counts row + Apply/Cancel buttons.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        var summary_buf: [128]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "Games: {d}  ·  Installed: {d}", .{
            state.f95_review_game_count,
            state.f95_review_installed_count,
        }) catch "Games: ?";
        dvui.labelNoFmt(@src(), summary, .{}, .{ .gravity_y = 0.5 });

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        if (style.button(@src(), "Cancel", .{}, .{})) {
            actions.doCancelF95CheckerReview(frame);
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });

        var apply_buf: [64]u8 = undefined;
        const apply_label = std.fmt.bufPrint(&apply_buf, "Apply ({d})", .{state.f95_review_game_count}) catch "Apply";
        if (style.button(@src(), apply_label, .{}, .{ .style = .highlight })) {
            actions.doApplyF95CheckerReview(frame);
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    const bundle = actions.f95ReviewBundle(state) orelse {
        dvui.label(@src(), "(no review bundle — try re-opening the import)", .{}, .{});
        return true;
    };

    renderF95ReviewList(state, bundle.games);
    return true;
}

const F95_REVIEW_NAME_W: f32 = 280;
const F95_REVIEW_VERSION_W: f32 = 100;
const F95_REVIEW_ROW_H: f32 = 24;
const F95_REVIEW_FONT_SIZE: f32 = 11;

fn renderF95ReviewList(state: *State, games: []importers.ImportedGame) void {
    var scroll = dvui.scrollArea(@src(), .{
        .scroll_info = &state.f95_review_scroll_info,
    }, .{
        .expand = .both,
        .min_size_content = .{ .w = 720, .h = 240 },
    });
    defer scroll.deinit();

    for (games, 0..) |g, idx| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx,
            .expand = .horizontal,
            .min_size_content = .{ .w = 700, .h = F95_REVIEW_ROW_H },
        });
        defer row.deinit();

        // Name (truncated to fit the fixed column).
        var name_buf: [256]u8 = undefined;
        const name_shown = truncStr(&name_buf, g.name, 60);
        dvui.labelNoFmt(@src(), name_shown, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = F95_REVIEW_NAME_W, .h = 1 },
            .font = dvui.Font.theme(.body).withSize(F95_REVIEW_FONT_SIZE),
        });

        // Version.
        const ver: []const u8 = g.version orelse "(no ver)";
        var ver_buf: [128]u8 = undefined;
        const ver_shown = truncStr(&ver_buf, ver, 20);
        dvui.labelNoFmt(@src(), ver_shown, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = F95_REVIEW_VERSION_W, .h = 1 },
            .font = dvui.Font.theme(.body).withSize(F95_REVIEW_FONT_SIZE),
        });

        // Install dir (or "(not installed)" grey).
        if (g.installDirRel()) |rel| {
            var dir_buf: [256]u8 = undefined;
            const dir_shown = truncStr(&dir_buf, rel, 80);
            dvui.labelNoFmt(@src(), dir_shown, .{}, .{
                .gravity_y = 0.5,
                .font = dvui.Font.theme(.body).withSize(F95_REVIEW_FONT_SIZE),
                .expand = .horizontal,
            });
        } else {
            dvui.labelNoFmt(@src(), "(not installed — metadata only)", .{}, .{
                .gravity_y = 0.5,
                .font = dvui.Font.theme(.body).withSize(F95_REVIEW_FONT_SIZE),
                .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 },
                .expand = .horizontal,
            });
        }
    }
}


// ============================================================
//  shared folder-scan rendering
// ============================================================

const FolderScanCopy = struct {
    title: []const u8,
    intro: []const u8,
    placeholder: []const u8,
};

fn renderFolderScanScreen(frame: *Frame, copy: FolderScanCopy) !bool {
    const state = frame.state;

    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();
        if (components.iconButton(@src(), "Back", entypo.chevron_left, .{})) state.screen = .library;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.labelNoFmt(@src(), copy.title, .{}, .{ .gravity_y = 0.5, .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // Body fills the whole window vertically — no outer scrollArea.
    // Static-height controls at the top; the rows scrollArea below
    // takes the remaining viewport height so the table grows with
    // the window instead of being capped at a fixed 360 px.
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .min_size_content = .{ .w = 720, .h = 400 },
        .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
    });
    defer body.deinit();

    // ---- Top section: intro, controls, mode, status (no scroll) ----
    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
        tl.addText(copy.intro, .{ .font = font(.body).withSize(11) });
        tl.deinit();
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.folder_scan_path_buf },
            .placeholder = copy.placeholder,
        }, .{ .expand = .horizontal, .min_size_content = .{ .w = 400, .h = 26 } });
        te.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        if (components.iconButton(@src(), "Browse...", entypo.folder, .{})) {
            const picked = file_picker.openFolder(frame.lib.alloc, null) catch |e| blk: {
                var buf: [192]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Folder picker failed: {s}", .{@errorName(e)}) catch "Folder picker failed";
                state.pushToast(.err, msg);
                break :blk null;
            };
            if (picked) |p| {
                defer frame.lib.alloc.free(p);
                @memset(&state.folder_scan_path_buf, 0);
                const n = @min(p.len, state.folder_scan_path_buf.len);
                @memcpy(state.folder_scan_path_buf[0..n], p[0..n]);
            }
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        if (style.button(@src(), "Scan", .{}, .{ .style = .highlight })) {
            actions.doFolderScan(frame, state.folderScanPathSlice());
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
        if (style.button(@src(), "Clear", .{}, .{})) {
            actions.freeFolderScan(state, frame.lib, frame.io);
            state.setFolderScanMsg("");
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    renderFolderScanModeToggle(state);

    if (!state.folder_scan_msg.isEmpty()) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
        dvui.labelNoFmt(@src(), state.folderScanMsg(), .{}, .{ .font = font(.body).withSize(11) });
    }

    // Auto-tick the incremental scan each frame while active.
    if (actions.folderScanInProgress(state)) {
        actions.tickFolderScan(frame);
        dvui.refresh(null, @src(), null);
    }

    // ---- Bottom section: rows table (expands to fill viewport) ----
    if (actions.folderScanBundle(state)) |bundle| {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        renderScanResults(frame, bundle);
    }

    renderResolvePopup(frame);

    return true;
}

/// Compact label font helper. Default theme body sits around 14 px;
/// label cells in the preview table use 11 px so a row's worth of
/// cells fits on a 720-px-wide window without overflow.
fn font(which: dvui.Font.ThemeFontName) dvui.Font {
    return dvui.Font.theme(which);
}

// ---- row sizing ---------------------------------------------
//
// New layout (2 or 3 sub-rows per row):
//
//   Line 1 — identity (always):
//     [✓]  FolderName             [engine] [issue-chips...]  [▼]
//
//   Line 2 — editor (always):
//     Name [____]   Ver [__]   Link [____search____]   → chip
//
//   Line 3 — suggestions (only when `typeahead_open`):
//     ↳ top fuzzy matches + "+ custom new" + (F95 URL if URL-ish)
//
// Width philosophy:
//   - Folder gets `.expand = .horizontal` so it eats whatever's left
//     after the fixed cells (engine + issues + toggle). Bigger window
//     → more folder name visible.
//   - Editor line uses fixed cells that always fit on a 720+ px window.
//   - All strings shown read-only go through `truncStr` so they can't
//     bleed past their reserved space.
//
// Height philosophy:
//   - Widths are locked via `min_size_content.w` only — dvui is free
//     to grow heights for descenders. The cell's `gravity_y = 0.5`
//     vertically centres it within whatever the row's natural height
//     turns out to be.

const COL_CHECK_W: f32 = 22;
const COL_ENGINE_W: f32 = 80;
const COL_ISSUES_W: f32 = 220; // inline next to engine; truncated to fit
const COL_TOGGLE_W: f32 = 28;

const EDITOR_NAME_W: f32 = 220;
const EDITOR_VERSION_W: f32 = 90;
const EDITOR_CHIP_W: f32 = 160;

const COL_GAP: f32 = 6;
const ROW_PADDING_H: f32 = 6;
const ROW_PADDING_V: f32 = 4;
const ROW_GAP_V: f32 = 4;

const SUBROW_H: f32 = 26;

const ROW_FONT_SIZE: f32 = 11;

fn renderScanResults(frame: *Frame, bundle: anytype) void {
    const state = frame.state;
    const row_states = actions.folderScanRowStates(state) orelse {
        dvui.label(@src(), "(preview rows not initialised — try Clear + Scan again)", .{}, .{});
        return;
    };
    if (row_states.len != bundle.games.len) {
        dvui.label(@src(), "(row state out of sync with scan; Clear + re-Scan)", .{}, .{});
        return;
    }

    const lib_games = actions.folderScanLibSnapshot(state);

    renderBulkApplyRow(state, row_states);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // Per-row variable pitch culler. Two heights:
    //   - closed (row in steady state)              → ROW_H_CLOSED
    //   - open (row's typeahead expanded with query) → ROW_H_OPEN
    //
    // The SAME `rowHeight` helper is used for both `virtual_size.h`
    // (drives the scrollbar) and the cull-walk Y accumulator (places
    // each row at its correct position). They must agree or the
    // scrollbar gets out of sync with the actual content — which is
    // exactly the bug the user hit when toggling ▼ on a row.
    const total_rows: usize = bundle.games.len;
    const OVERSCAN_PX: f32 = 300;

    var virtual_h: f32 = 0;
    {
        var i: usize = 0;
        while (i < total_rows) : (i += 1) virtual_h += rowHeight(&row_states[i]);
    }
    if (virtual_h < 1.0) virtual_h = 1.0;
    state.folder_scan_scroll_info.vertical = .given;
    state.folder_scan_scroll_info.virtual_size.h = virtual_h;

    {
        var scroll = dvui.scrollArea(@src(), .{
            .scroll_info = &state.folder_scan_scroll_info,
        }, .{
            .expand = .both,
            .min_size_content = .{ .w = 720, .h = 240 },
        });
        defer scroll.deinit();

        const viewport_y: f32 = state.folder_scan_scroll_info.viewport.y;
        const viewport_h: f32 = @max(state.folder_scan_scroll_info.viewport.h, 1.0);
        const visible_top: f32 = @max(0.0, viewport_y - OVERSCAN_PX);
        const visible_bot: f32 = viewport_y + viewport_h + OVERSCAN_PX;

        var acc: f32 = 0;
        var top_spacer_h: f32 = 0;
        var bot_spacer_h: f32 = 0;
        var top_spacer_emitted: bool = false;

        var idx: usize = 0;
        while (idx < total_rows) : (idx += 1) {
            const h = rowHeight(&row_states[idx]);
            const row_top = acc;
            const row_bot = acc + h;
            acc = row_bot;

            if (row_bot < visible_top) {
                top_spacer_h += h;
                continue;
            }
            if (row_top > visible_bot) {
                bot_spacer_h += h;
                continue;
            }
            if (!top_spacer_emitted) {
                if (top_spacer_h > 0.5) {
                    _ = dvui.spacer(@src(), .{
                        .expand = .horizontal,
                        .min_size_content = .{ .w = 1, .h = top_spacer_h },
                    });
                }
                top_spacer_emitted = true;
            }
            renderPreviewRow(state, idx, bundle.games[idx], &row_states[idx], lib_games);
        }
        if (bot_spacer_h > 0.5) {
            _ = dvui.spacer(@src(), .{
                .expand = .horizontal,
                .min_size_content = .{ .w = 1, .h = bot_spacer_h },
            });
        }
    }

    // Commit row pinned below the scrollArea.
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    renderCommitRow(frame, row_states);
}

/// Mass-edit affordance per PLAN §2.13: tick rows, type a name suffix
/// and/or a version, hit Apply to write the values across every
/// ticked row. Leaves untouched cells alone (blank input = no-op for
/// that field).
fn renderBulkApplyRow(state: *State, rows: []state_mod.FolderImportRowState) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = style.cardFill(),
        .color_border = style.borderColor(),
    });
    defer bar.deinit();

    dvui.label(@src(), "Bulk apply to ticked rows:", .{}, .{ .gravity_y = 0.5 });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });

    const te_name = style.textEntry(@src(), .{
        .text = .{ .buffer = &state.folder_bulk_name_buf },
        .placeholder = "name suffix (optional)",
    }, .{ .min_size_content = .{ .w = 240, .h = 26 } });
    te_name.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });

    const te_ver = style.textEntry(@src(), .{
        .text = .{ .buffer = &state.folder_bulk_version_buf },
        .placeholder = "version (optional)",
    }, .{ .min_size_content = .{ .w = 160, .h = 26 } });
    te_ver.deinit();
    // Push Apply to the right edge of the bar so it lines up with
    // the row-table's right-side ▼ buttons.
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    if (style.button(@src(), "Apply", .{}, .{ .style = .highlight })) {
        const suffix = sliceBuf(&state.folder_bulk_name_buf);
        const new_version = sliceBuf(&state.folder_bulk_version_buf);
        for (rows) |*r| {
            if (!r.checked) continue;
            if (suffix.len > 0) {
                // Append the suffix to whatever name is currently there
                // (after a single space). Don't replace; the suffix is
                // an *addition* per PLAN §2.13 ("name suffix").
                const cur = sliceBuf(&r.name_buf);
                if (cur.len + 1 + suffix.len + 1 < r.name_buf.len) {
                    @memset(&r.name_buf, 0);
                    @memcpy(r.name_buf[0..cur.len], cur);
                    r.name_buf[cur.len] = ' ';
                    @memcpy(r.name_buf[cur.len + 1 .. cur.len + 1 + suffix.len], suffix);
                }
            }
            if (new_version.len > 0) {
                @memset(&r.version_buf, 0);
                const n = @min(new_version.len, r.version_buf.len);
                @memcpy(r.version_buf[0..n], new_version[0..n]);
            }
        }
    }
}

// (No table header — each row is self-describing: dominant folder
// name, coloured engine + issue chips on the right, plus editor
// placeholders that label themselves.)

fn spacerW(w: f32, extra: u32) void {
    _ = dvui.spacer(@src(), .{
        .id_extra = extra,
        .min_size_content = .{ .w = w, .h = 1 },
    });
}

fn renderPreviewRow(
    state: *State,
    idx: usize,
    game: importers.ImportedGame,
    row_state: *state_mod.FolderImportRowState,
    lib_games: []library.Game,
) void {
    _ = state;
    // Row card. Vertical so it stacks 2 or 3 sub-rows:
    //   Line 1 — identity: [✓] folder · engine · issue chip · [▼]
    //   Line 2 — editor:   Name [_] Ver [_] Link [____] chip
    //   Line 3 — suggestions (only when typeahead_open + query set)
    // Highlight the border red when this row is ticked AND still
    // unresolved — gives a visible "you need to fix me before commit"
    // signal up front, rather than the user clicking Import and
    // getting a generic "some ticked rows are still unresolved" toast
    // with no indication of which ones.
    const needs_attention = row_state.checked and row_state.link_state == .unresolved;
    const row_border_color: dvui.Color = if (needs_attention)
        .{ .r = 0xCC, .g = 0x55, .b = 0x66 }
    else
        style.borderColor();

    var row = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = @intCast(idx),
        .expand = .horizontal,
        .padding = .{ .x = ROW_PADDING_H, .y = ROW_PADDING_V, .w = ROW_PADDING_H, .h = ROW_PADDING_V },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = ROW_GAP_V },
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = style.cardFill(),
        .color_border = row_border_color,
    });
    defer row.deinit();

    const cell_font = font(.body).withSize(ROW_FONT_SIZE);
    const row_id_base: u32 = @as(u32, @intCast(idx)) * 100;

    // The rightmost region of both lines spans `RIGHT_BLOCK_W` so the
    // two sub-rows share a clean right edge:
    //   line 1: issue-chip occupies that block
    //   line 2: status-chip + ▼ occupies it (chip + gap + toggle)
    const RIGHT_BLOCK_W: f32 = EDITOR_CHIP_W + COL_GAP + COL_TOGGLE_W; // 160+6+28 = 194

    // ===== LINE 1 — identity =====
    {
        var line1 = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_id_base,
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = SUBROW_H },
        });
        defer line1.deinit();

        _ = dvui.checkbox(@src(), &row_state.checked, null, .{
            .id_extra = row_id_base + 1,
            .min_size_content = .{ .w = COL_CHECK_W, .h = SUBROW_H },
            .max_size_content = .{ .w = COL_CHECK_W, .h = 9999 },
            .gravity_y = 0.5,
        });
        spacerW(COL_GAP, row_id_base + 2);

        // Folder — expands to fill remaining space.
        var folder_buf: [256]u8 = undefined;
        const folder_text = truncStr(&folder_buf, installDirRelOrName(game), 80);
        dvui.labelNoFmt(@src(), folder_text, .{}, .{
            .id_extra = row_id_base + 3,
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = SUBROW_H },
            .max_size_content = .{ .w = 9999, .h = 9999 },
            .gravity_y = 0.5,
            .style = .highlight,
            .font = cell_font,
        });
        spacerW(COL_GAP, row_id_base + 4);

        // Engine chip
        clippedLabel(row_id_base + 5, engineLabel(game.engine), COL_ENGINE_W, .{
            .color_text = engineColor(game.engine),
            .font = cell_font,
        });
        spacerW(COL_GAP, row_id_base + 6);

        // Issue chip occupies the RIGHT_BLOCK so its right edge lines
        // up exactly with the ▼ on line 2. Wrapped in a Box so we can
        // attach a hover tooltip with the full title.
        {
            var chip_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = row_id_base + 7,
                .min_size_content = .{ .w = RIGHT_BLOCK_W, .h = SUBROW_H },
                .max_size_content = .{ .w = RIGHT_BLOCK_W, .h = 9999 },
                .gravity_y = 0.5,
            });
            if (row_state.issue_count > 0) {
                const iss = &row_state.issues[0];
                var label_buf: [96]u8 = undefined;
                const short = shortIssueLabel(iss.id());
                const issue_text = truncStr(&label_buf, short, charsForWidth(RIGHT_BLOCK_W - 8));
                dvui.labelNoFmt(@src(), issue_text, .{}, .{
                    .id_extra = row_id_base + 8,
                    .color_text = tokens.toDvui(tokens.active.warn, dvui.Color),
                    .font = cell_font,
                    .gravity_y = 0.5,
                });
                // Hover tooltip — full recipe title (untruncated).
                // dvui.tooltip is a no-op when the mouse isn't over
                // `active_rect`, so this is essentially free in the
                // steady state.
                dvui.tooltip(@src(), .{
                    .active_rect = chip_box.data().borderRectScale().r,
                }, "{s}", .{iss.title()}, .{ .id_extra = row_id_base + 9 });
            }
            chip_box.deinit();
        }
    }

    // ===== LINE 2 — editor =====
    {
        var line2 = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_id_base + 20,
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = SUBROW_H },
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
        });
        defer line2.deinit();

        // Indent line 2 by the checkbox column so the editor visually
        // nests under the folder identity on line 1.
        spacerW(COL_CHECK_W + COL_GAP, row_id_base + 21);

        const LABEL_COLOR: dvui.Color = .{ .r = 0xA0, .g = 0x80, .b = 0x90 };

        // Only Ver gets a prefix label — "1.0" placeholder alone
        // isn't self-explanatory. Other fields describe themselves
        // via their placeholder text and the status chip on the
        // right (no more truncated "Li..." / "Se..." labels).
        const VER_LABEL_W: f32 = 30;

        switch (row_state.link_state) {
            .unresolved => {
                fieldLabel(row_id_base + 22, "Ver", VER_LABEL_W, LABEL_COLOR, cell_font);
                versionEntry(row_id_base + 23, row_state);
                spacerW(COL_GAP, row_id_base + 24);
                // Search field — placeholder explains its purpose.
                const te = style.textEntry(@src(), .{
                    .text = .{ .buffer = &row_state.link_buf },
                    .placeholder = "type to search library, or paste F95 URL",
                }, .{
                    .id_extra = row_id_base + 26,
                    .expand = .horizontal,
                    .min_size_content = .{ .w = 150, .h = SUBROW_H - 2 },
                });
                te.deinit();
            },
            .custom_new => {
                {
                    const te_n = style.textEntry(@src(), .{
                        .text = .{ .buffer = &row_state.name_buf },
                        .placeholder = "name for the new game",
                    }, .{
                        .id_extra = row_id_base + 23,
                        .expand = .horizontal,
                        .min_size_content = .{ .w = 150, .h = SUBROW_H - 2 },
                    });
                    te_n.deinit();
                }
                spacerW(COL_GAP, row_id_base + 24);
                fieldLabel(row_id_base + 25, "Ver", VER_LABEL_W, LABEL_COLOR, cell_font);
                versionEntry(row_id_base + 26, row_state);
            },
            .linked_existing, .f95_url => {
                fieldLabel(row_id_base + 22, "Ver", VER_LABEL_W, LABEL_COLOR, cell_font);
                versionEntry(row_id_base + 23, row_state);
                spacerW(COL_GAP, row_id_base + 24);
                // Linked-name readonly display + Unlink button.
                var display_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = row_id_base + 26,
                    .expand = .horizontal,
                    .min_size_content = .{ .w = 150, .h = SUBROW_H },
                    .gravity_y = 0.5,
                });
                defer display_box.deinit();
                const linked_text = sliceBuf(&row_state.link_buf);
                var linked_buf: [128]u8 = undefined;
                const shown = truncStr(&linked_buf, linked_text, 50);
                // "→ <name>" so the user reads "linked to <name>".
                var prefixed_buf: [148]u8 = undefined;
                const prefixed = std.fmt.bufPrint(&prefixed_buf, "→ {s}", .{shown}) catch shown;
                dvui.labelNoFmt(@src(), prefixed, .{}, .{
                    .id_extra = row_id_base + 27,
                    .expand = .horizontal,
                    .gravity_y = 0.5,
                    .color_text = .{ .r = 0x4F, .g = 0xC3, .b = 0x6F },
                    .font = cell_font,
                });
                if (style.button(@src(), "Unlink", .{}, .{
                    .id_extra = row_id_base + 28,
                    .min_size_content = .{ .w = 56, .h = SUBROW_H - 2 },
                    .max_size_content = .{ .w = 56, .h = 9999 },
                    .gravity_y = 0.5,
                })) {
                    row_state.link_state = .unresolved;
                    row_state.link_thread_id = null;
                    @memset(&row_state.link_buf, 0);
                    const n = @min(sliceBuf(&row_state.name_buf).len, row_state.link_buf.len);
                    @memcpy(row_state.link_buf[0..n], row_state.name_buf[0..n]);
                    row_state.typeahead_open = true;
                }
            },
        }
        spacerW(COL_GAP, row_id_base + 30);

        // Right block — chip + toggle. Right edge = line 1's issue
        // chip right edge so the two sub-rows share a clean column.
        renderChipInline(row_id_base + 31, row_state, cell_font);
        spacerW(COL_GAP, row_id_base + 32);

        const toggle_label: []const u8 = if (row_state.typeahead_open) "▲" else "▼";
        if (style.button(@src(), toggle_label, .{}, .{
            .id_extra = row_id_base + 33,
            .min_size_content = .{ .w = COL_TOGGLE_W, .h = SUBROW_H - 2 },
            .max_size_content = .{ .w = COL_TOGGLE_W, .h = 9999 },
            .gravity_y = 0.5,
        })) {
            row_state.typeahead_open = !row_state.typeahead_open;
        }
    }

    // ===== LINE 3 — suggestions (only when open + non-empty) =====
    const query = sliceBuf(&row_state.link_buf);
    if (row_state.typeahead_open and query.len > 0) {
        renderLinkSuggestions(idx, row_state, lib_games, query);
    }
}

/// Read-only label cell with width locked to `w`. The caller is
/// expected to have truncated the text via `truncStr` already.
fn clippedLabel(extra: u32, text: []const u8, w: f32, base: dvui.Options) void {
    var opts = base;
    opts.id_extra = extra;
    opts.min_size_content = .{ .w = w, .h = SUBROW_H };
    opts.max_size_content = .{ .w = w, .h = 9999 };
    opts.gravity_y = 0.5;
    dvui.labelNoFmt(@src(), text, .{}, opts);
}

/// Estimated row height in pixels. Two regimes:
///   - closed (no suggestion list expanded) → `ROW_H_CLOSED`
///   - open (`typeahead_open` AND query non-empty, so the suggestion
///     list actually renders) → `ROW_H_OPEN`
///
/// Used by `renderScanResults` for BOTH the scrollbar's
/// `virtual_size.h` AND the cull-walk's per-row Y accumulator. The
/// two MUST agree — if they don't, the scrollbar reaches a position
/// that the layout doesn't, and the last few rows disappear past
/// the bottom of the viewport.
///
/// Numbers are deliberately on the generous side so dvui's internal
/// padding (~6 px each side of every widget) doesn't push real
/// heights past the estimate. If virtual_h is even 10 px short
/// per row, the bottom-most rows fall off the scrollable area.
/// Better to leave a small gap below the last row than to clip.
const ROW_H_CLOSED: f32 = 120;
const ROW_H_OPEN: f32 = 360;

fn rowHeight(row_state: *const state_mod.FolderImportRowState) f32 {
    if (!row_state.typeahead_open) return ROW_H_CLOSED;
    // typeahead_open is set; check the query is non-empty (the
    // suggestion list is gated on that in renderLinkSuggestions).
    const buf = row_state.link_buf;
    var has_query = false;
    for (buf) |c| {
        if (c == 0) break;
        if (c != ' ' and c != '\t') {
            has_query = true;
            break;
        }
    }
    if (!has_query) return ROW_H_CLOSED;
    return ROW_H_OPEN;
}

/// Version TextEntry — same shape across every link-state branch
/// of the editor line, so it lives in one helper.
fn versionEntry(extra: u32, row_state: *state_mod.FolderImportRowState) void {
    const te_v = style.textEntry(@src(), .{
        .text = .{ .buffer = &row_state.version_buf },
        .placeholder = "1.0",
    }, .{
        .id_extra = extra,
        .min_size_content = .{ .w = EDITOR_VERSION_W, .h = SUBROW_H - 2 },
        .max_size_content = .{ .w = EDITOR_VERSION_W, .h = 9999 },
        .gravity_y = 0.5,
    });
    te_v.deinit();
}

/// Tiny prefix label that sits to the left of an editor TextEntry,
/// labelling what the user is editing ("Name", "Ver", "Link"). Kept
/// muted so the actual input draws the eye.
fn fieldLabel(extra: u32, text: []const u8, w: f32, color: dvui.Color, f: dvui.Font) void {
    dvui.labelNoFmt(@src(), text, .{}, .{
        .id_extra = extra,
        .min_size_content = .{ .w = w, .h = SUBROW_H },
        .max_size_content = .{ .w = w, .h = 9999 },
        .gravity_y = 0.5,
        .color_text = color,
        .font = f,
    });
}

fn renderChipInline(extra: u32, row_state: *const state_mod.FolderImportRowState, cell_font: dvui.Font) void {
    const chip_text_raw: []const u8 = switch (row_state.link_state) {
        .linked_existing => "→ existing game",
        .custom_new => "+ custom new",
        .f95_url => "F95 URL (on commit)",
        .unresolved => "no match — click ▼",
    };
    const chip_color: dvui.Color = switch (row_state.link_state) {
        .linked_existing => .{ .r = 0x4F, .g = 0xC3, .b = 0x6F },
        .custom_new => .{ .r = 0xCC, .g = 0x99, .b = 0x55 },
        .f95_url => .{ .r = 0x55, .g = 0x99, .b = 0xCC },
        .unresolved => .{ .r = 0xA0, .g = 0x80, .b = 0x90 },
    };
    var chip_buf: [96]u8 = undefined;
    const chip_text = truncStr(&chip_buf, chip_text_raw, charsForWidth(EDITOR_CHIP_W - 4));
    dvui.labelNoFmt(@src(), chip_text, .{}, .{
        .id_extra = extra,
        .min_size_content = .{ .w = EDITOR_CHIP_W, .h = SUBROW_H },
        .max_size_content = .{ .w = EDITOR_CHIP_W, .h = 9999 },
        .gravity_y = 0.5,
        .color_text = chip_color,
        .font = cell_font,
    });
}

const LinkSuggestion = struct {
    label: []const u8, // displayed (and what we copy into link_buf on click)
    score: f32,
    thread_id: u64,
};

fn renderLinkSuggestions(
    idx: usize,
    row_state: *state_mod.FolderImportRowState,
    lib_games: []library.Game,
    query: []const u8,
) void {
    // 1. Compute top suggestions.
    var top: [LINK_PREVIEW_MAX_SUGGESTIONS]LinkSuggestion = undefined;
    var top_n: usize = 0;

    if (query.len > 0) {
        for (lib_games) |g| {
            const s = importers.name_match.score(query, g.name);
            if (s < importers.name_match.MATCH_THRESHOLD) continue;
            // Insertion sort into `top[]` keeping the highest scorers.
            var insert_at: usize = top_n;
            while (insert_at > 0 and top[insert_at - 1].score < s) : (insert_at -= 1) {}
            if (insert_at < top.len) {
                // Shift right.
                if (top_n < top.len) top_n += 1;
                var j: usize = top_n;
                while (j > insert_at + 1) : (j -= 1) top[j - 1] = top[j - 2];
                top[insert_at] = .{ .label = g.name, .score = s, .thread_id = g.f95_thread_id };
            }
        }
    }

    // 2. Render. Container is a small vertical scroll so the row
    //    doesn't expand without bound. Bottom of the row stays
    //    aligned to the rest of the table.
    if (top_n == 0 and query.len == 0) return;

    var listbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = @intCast(idx),
        .min_size_content = .{ .w = 250, .h = 1 },
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = .{ .r = 0x10, .g = 0x0A, .b = 0x14 },
        .color_border = style.borderColor(),
    });
    defer listbox.deinit();

    for (top[0..top_n], 0..) |sug, i| {
        var label_buf: [192]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "→ {s}  ({d:.0}%)", .{ sug.label, sug.score * 100 }) catch sug.label;
        if (style.button(@src(), label, .{}, .{
            .id_extra = @intCast(idx * 100 + i),
            .expand = .horizontal,
        })) {
            // Pick this game: write its name into link_buf and switch
            // state to linked_existing.
            @memset(&row_state.link_buf, 0);
            const n = @min(sug.label.len, row_state.link_buf.len);
            @memcpy(row_state.link_buf[0..n], sug.label[0..n]);
            row_state.link_state = .linked_existing;
            row_state.link_thread_id = sug.thread_id;
            row_state.typeahead_open = false; // collapse — picked, no more options needed
        }
    }

    // Series siblings — same `seriesKey(query)`, but below the
    // fuzzy-match threshold. These are likely different chapters /
    // episodes / seasons of the same series. We surface them as a
    // separate group so the user can pick one if it really IS the
    // same install they meant, but we never auto-link them.
    {
        var series: [LINK_PREVIEW_MAX_SUGGESTIONS]LinkSuggestion = undefined;
        var series_n: usize = 0;
        for (lib_games) |g| {
            // Skip anything already in the fuzzy-match top list — no
            // duplicate rendering.
            var dup = false;
            for (top[0..top_n]) |t| {
                if (t.thread_id == g.f95_thread_id) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            if (!importers.name_match.isSeriesSibling(query, g.name)) continue;
            if (series_n < series.len) {
                series[series_n] = .{ .label = g.name, .score = 0, .thread_id = g.f95_thread_id };
                series_n += 1;
            }
        }
        if (series_n > 0) {
            dvui.labelNoFmt(@src(), "Related series:", .{}, .{
                .id_extra = @intCast(idx * 100 + 80),
                .color_text = .{ .r = 0xA0, .g = 0x80, .b = 0x90 },
                .font = font(.body).withSize(ROW_FONT_SIZE - 1),
            });
            for (series[0..series_n], 0..) |sug, i| {
                var label_buf: [192]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "↪ {s}", .{sug.label}) catch sug.label;
                if (style.button(@src(), label, .{}, .{
                    .id_extra = @intCast(idx * 100 + 60 + i),
                    .expand = .horizontal,
                })) {
                    @memset(&row_state.link_buf, 0);
                    const n = @min(sug.label.len, row_state.link_buf.len);
                    @memcpy(row_state.link_buf[0..n], sug.label[0..n]);
                    row_state.link_state = .linked_existing;
                    row_state.link_thread_id = sug.thread_id;
                    row_state.typeahead_open = false;
                }
            }
        }
    }

    // "+ Create custom new entry with this name" — always offered
    // when the user has typed something (or when no match was found).
    if (query.len > 0) {
        var btn_buf: [160]u8 = undefined;
        const btn_label = std.fmt.bufPrint(&btn_buf, "+ Custom new: \"{s}\"", .{query}) catch "+ Custom new entry";
        if (style.button(@src(), btn_label, .{}, .{
            .id_extra = @intCast(idx * 100 + 90),
            .expand = .horizontal,
        })) {
            row_state.link_state = .custom_new;
            row_state.link_thread_id = null;
            row_state.typeahead_open = false;
            @memset(&row_state.name_buf, 0);
            const n = @min(query.len, row_state.name_buf.len);
            @memcpy(row_state.name_buf[0..n], query[0..n]);
        }

        // F95 URL hint — only show when text looks URL-ish so we don't
        // pollute every row with an option that doesn't apply.
        if (looksLikeF95Url(query)) {
            if (style.button(@src(), "Treat as F95 URL on commit", .{}, .{
                .id_extra = @intCast(idx * 100 + 91),
                .expand = .horizontal,
                .style = .highlight,
            })) {
                row_state.link_state = .f95_url;
                row_state.link_thread_id = null;
                row_state.typeahead_open = false;
            }
        }
    }
}

fn looksLikeF95Url(text: []const u8) bool {
    // Cheap heuristic — the commit path will validate properly via
    // `f95.extractThreadId`. We just want to surface the option only
    // when it's plausibly useful.
    return std.mem.indexOf(u8, text, "f95zone.to") != null or
        std.mem.indexOf(u8, text, "threads/") != null;
}

fn renderCommitRow(frame: *Frame, rows: []state_mod.FolderImportRowState) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer bar.deinit();

    var ticked: usize = 0;
    var resolved: usize = 0;
    var first_unresolved_idx: ?usize = null;
    for (rows, 0..) |r, i| {
        if (!r.checked) continue;
        ticked += 1;
        if (r.link_state == .unresolved) {
            if (first_unresolved_idx == null) first_unresolved_idx = i;
        } else {
            resolved += 1;
        }
    }

    var msg_buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "{d} row(s) ticked, {d} ready to commit", .{ ticked, resolved }) catch "";
    dvui.labelNoFmt(@src(), msg, .{}, .{ .gravity_y = 0.5 });
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    // A background transfer is already grinding — don't let a second
    // commit pile on. The bottom bar shows its progress + a Cancel.
    if (actions.folderImportActive(frame.state)) {
        _ = style.button(@src(), "Importing… (see bottom bar)", .{}, .{});
        return;
    }

    const enabled = ticked > 0 and resolved == ticked;
    const opts: dvui.Options = if (enabled) .{ .style = .highlight } else .{};
    if (style.button(@src(), "Import ticked rows", .{}, opts)) {
        if (enabled) {
            actions.commitFolderImport(frame);
        } else {
            // Log every ticked + unresolved row so the user (and the
            // log file) can see exactly which ones are blocking, even
            // when they're scrolled off-screen and the red border
            // isn't visible.
            const bundle_opt = actions.folderScanBundle(frame.state);
            var log_buf: [256]u8 = undefined;
            var first_name: []const u8 = "(unknown)";
            var count_logged: usize = 0;
            for (rows, 0..) |r, i| {
                if (!r.checked or r.link_state != .unresolved) continue;
                const folder = if (bundle_opt) |b|
                    (if (i < b.games.len) installDirRelOrName(b.games[i]) else "(idx oob)")
                else
                    "(no bundle)";
                if (count_logged == 0) first_name = folder;
                count_logged += 1;
                std.log.scoped(.ui_actions).warn("commit blocked: row[{d}] '{s}' is .unresolved", .{ i, folder });
            }

            // Status message names the FIRST offender so the user can
            // find it; auto-scroll the table to bring it into view.
            const msg2 = std.fmt.bufPrint(&log_buf, "{d} ticked row(s) unresolved — first: row {d} '{s}'. Scrolling to it.", .{ count_logged, first_unresolved_idx orelse 0, first_name }) catch "Some ticked rows are still unresolved.";
            frame.state.setFolderScanMsg(msg2);

            if (first_unresolved_idx) |target_idx| {
                // Sum per-row heights up to the target — must match
                // the accumulator inside `renderScanResults`.
                var target_y: f32 = 0;
                var i_acc: usize = 0;
                while (i_acc < target_idx) : (i_acc += 1) {
                    target_y += rowHeight(&rows[i_acc]);
                }
                frame.state.folder_scan_scroll_info.viewport.y = target_y;
                dvui.refresh(null, @src(), null);
            }
        }
    }
}

fn installDirRelOrName(g: importers.ImportedGame) []const u8 {
    if (g.installDirRel()) |d| return d;
    return g.name;
}

fn engineLabel(e: importers.Engine) []const u8 {
    return switch (e) {
        .renpy => "Ren'Py",
        .rpgm_mv => "RPGM MV",
        .rpgm_mz => "RPGM MZ",
        .rpgm_vx => "RPGM VX",
        .unity => "Unity",
        .unreal => "Unreal",
        .html => "HTML",
        .flash => "Flash",
        .java => "Java",
        .wolf_rpg => "Wolf RPG",
        .qsp => "QSP",
        .tyranobuilder => "TyranoBuilder",
        .twine => "Twine",
        .adrift => "ADRIFT",
        .rags => "RAGS",
        .tads => "TADS",
        .webgl => "WebGL",
        .other => "other",
        .unknown => "(unknown)",
    };
}

fn engineColor(e: importers.Engine) dvui.Color {
    return switch (e) {
        .renpy => .{ .r = 0xCC, .g = 0xAA, .b = 0x55 },
        .rpgm_mv, .rpgm_mz, .rpgm_vx => .{ .r = 0x55, .g = 0x99, .b = 0xCC },
        .unity => .{ .r = 0xAA, .g = 0xCC, .b = 0x55 },
        else => .{ .r = 0xA0, .g = 0x80, .b = 0x90 },
    };
}

fn sliceBuf(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

/// Manually truncate `text` to ~`max_chars` characters, appending an
/// ASCII "..." when cut. dvui's label `ellipsize` flag works only
/// when its allocated rect is smaller than the natural text size —
/// in the preview table the labels' min/max are the SAME value so
/// dvui hands them their natural size and never ellipsizes. We do
/// the truncation ourselves so the Name / Issues / Folder labels
/// can't bleed past their column edges into the neighbouring cell.
fn truncStr(out: []u8, text: []const u8, max_chars: usize) []const u8 {
    if (text.len <= max_chars) return text;
    if (max_chars <= 3 or out.len < max_chars) return text[0..@min(text.len, out.len)];
    const keep = max_chars - 3;
    @memcpy(out[0..keep], text[0..keep]);
    out[keep] = '.';
    out[keep + 1] = '.';
    out[keep + 2] = '.';
    return out[0 .. keep + 3];
}

/// Roughly how many 10-px chars fit in `width_px`. Empirical avg ~6 px
/// per char for the Liberation Sans family dvui ships.
fn charsForWidth(width_px: f32) usize {
    const approx: usize = @intFromFloat(@max(width_px / 6.0, 0));
    return approx;
}

/// Short user-facing label for a compat recipe. Falls back to the
/// recipe's full title when no mapping is registered — keeps the
/// scheme additive (new recipes work without a code change, they
/// just show their full title in the chip).
fn shortIssueLabel(recipe_id: []const u8) []const u8 {
    const map = [_]struct { id: []const u8, short: []const u8 }{
        .{ .id = "linux.renpy7.sdl-fhs", .short = "Ren'Py 7 X11 fix" },
        .{ .id = "linux.renpy8.sdl-fhs", .short = "Ren'Py 8 X11 fix" },
        .{ .id = "linux.rpgm-mv.nwjs-fhs", .short = "RPGM MV nw.js fix" },
        .{ .id = "linux.unity.player-fhs", .short = "Unity player fix" },
    };
    for (map) |m| if (std.mem.eql(u8, m.id, recipe_id)) return m.short;
    return recipe_id;
}

/// Three-button mutually-exclusive toggle. The selected mode renders
/// with `.style = .highlight`; the others are plain. `link` is the
/// safest mode (no file mutation, ever) — kept rightmost so it reads
/// as "the gentle option" after the more invasive ones.
fn renderFolderScanModeToggle(state: *State) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();
    dvui.label(@src(), "Transfer mode:", .{}, .{ .gravity_y = 0.5 });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
    const move_style: dvui.Options = if (state.folder_scan_mode == .move) .{ .style = .highlight } else .{};
    if (style.button(@src(), "Move (cut+paste)", .{}, move_style)) {
        state.folder_scan_mode = .move;
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
    const copy_style: dvui.Options = if (state.folder_scan_mode == .copy) .{ .style = .highlight } else .{};
    if (style.button(@src(), "Copy (keep originals — 2x disk)", .{}, copy_style)) {
        state.folder_scan_mode = .copy;
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
    const link_style: dvui.Options = if (state.folder_scan_mode == .link) .{ .style = .highlight } else .{};
    if (style.button(@src(), "Link in place (0x disk, no file ops)", .{}, link_style)) {
        state.folder_scan_mode = .link;
    }
}

fn renderResolvePopup(frame: *Frame) void {
    const state = frame.state;
    const idx = state.folder_resolve_idx orelse return;
    const bundle = actions.folderScanBundle(state) orelse {
        state.folder_resolve_idx = null;
        return;
    };
    if (idx >= bundle.games.len) {
        state.folder_resolve_idx = null;
        return;
    }
    const game = bundle.games[idx];

    var open: bool = true;
    var win = dvui.floatingWindow(@src(), .{ .open_flag = &open }, .{
        .min_size_content = .{ .w = 480, .h = 240 },
    });
    defer {
        win.deinit();
        if (!open) state.folder_resolve_idx = null;
    }
    _ = dvui.windowHeader("Link to F95Zone thread", "", &open);

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
    });
    defer body.deinit();

    dvui.labelNoFmt(@src(), game.name, .{}, .{ .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    if (game.version) |v| {
        var vbuf: [80]u8 = undefined;
        const vmsg = std.fmt.bufPrint(&vbuf, "version: {s}", .{v}) catch v;
        dvui.labelNoFmt(@src(), vmsg, .{}, .{});
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    dvui.label(@src(), "Paste an F95Zone thread URL or numeric id:", .{}, .{});
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });
    const te = style.textEntry(@src(), .{
        .text = .{ .buffer = &state.folder_resolve_url_buf },
        .placeholder = "https://f95zone.to/threads/…/  or  12345",
    }, .{ .expand = .horizontal, .min_size_content = .{ .w = 300, .h = 24 } });
    te.deinit();

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });
    dvui.label(
        @src(),
        "(F95 search-by-name coming in a follow-up — for now, look up the thread manually and paste the URL.)",
        .{},
        .{ .color_text = .{ .r = 0xA0, .g = 0x80, .b = 0x90 } },
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });

    {
        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer btn_row.deinit();
        if (style.button(@src(), "Save & import", .{}, .{ .style = .highlight })) {
            const url_input = state.folderResolveUrlSlice();
            if (actions.parseF95ThreadInput(url_input)) |tid| {
                actions.resolveFolderEntry(frame, idx, tid);
            } else {
                state.setFolderScanMsg("Couldn't parse that F95 URL / id — try a full thread URL.");
            }
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (style.button(@src(), "Add as custom instead", .{}, .{})) {
            actions.resolveFolderEntry(frame, idx, null);
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "Cancel", .{}, .{})) {
            state.folder_resolve_idx = null;
        }
    }
}

const ImportResult = struct { ok: u32 = 0, skipped: u32 = 0 };

fn doImport(frame: *Frame, blob: []const u8) ImportResult {
    var result: ImportResult = .{};
    var iter = std.mem.tokenizeAny(u8, blob, "\n\r");
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        const tid_str: ?[]const u8 = blk: {
            if (f95.extractThreadId(trimmed)) |s| break :blk s;
            // Fallback: maybe the user pasted a bare numeric id.
            _ = std.fmt.parseInt(u64, trimmed, 10) catch break :blk null;
            break :blk trimmed;
        };
        const ts = tid_str orelse {
            result.skipped += 1;
            continue;
        };
        const tid = std.fmt.parseInt(u64, ts, 10) catch {
            result.skipped += 1;
            continue;
        };
        const g = library.Game{ .f95_thread_id = tid, .name = "(unsynced)" };
        const inserted = frame.lib.insertIfMissing(&g) catch {
            result.skipped += 1;
            continue;
        };
        if (inserted) result.ok += 1 else result.skipped += 1;
    }
    return result;
}
