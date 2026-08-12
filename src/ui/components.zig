// Shared UI widgets and helpers used by multiple screen files.
//
// Anything called from 2+ screens lives here. Per-screen widgets stay
// next to their screen. Functions in this file should not reach into
// screen-private state — they take primitives or `*Frame`.

const std = @import("std");
const dvui = @import("dvui");
const entypo = dvui.entypo;
const library = @import("library");
const downloads = @import("downloads");

const types = @import("types.zig");
const state_mod = @import("state.zig");
const actions = @import("actions.zig");
const style = @import("style.zig");
const tokens = @import("ui_tokens");
const engine_palette = @import("ui_engine_palette");

const Frame = types.Frame;

/// Resolve a Game by thread id from the frame's game array. Shared
/// helper — both `recipeEditorScreen` and `modsScreen` arrive at a
/// screen carrying only the thread id (wizard state / selected thread
/// respectively). Hits `frame.games_by_thread` (per-frame snapshot
/// built at the top of `guiFrame`) for O(1) lookup; falls back to a
/// linear scan if the snapshot is missing (e.g. arena-alloc OOM).
pub fn gameByThreadId(frame: *Frame, thread_id: u64) ?*const library.Game {
    if (frame.games_by_thread) |map| return map.get(thread_id);
    for (frame.games) |*g| {
        if (g.f95_thread_id == thread_id) return g;
    }
    return null;
}

/// Short labels that fit in a corner chip. The full enum name is
/// fine in the sidebar filter, but at card scale we need ~6 chars max.
pub fn engineShortLabel(e: library.Engine) []const u8 {
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
        .wolf_rpg => "Wolf",
        .qsp => "QSP",
        .tyranobuilder => "Tyrano",
        .twine => "Twine",
        .adrift => "ADRIFT",
        .rags => "RAGS",
        .tads => "TADS",
        .webgl => "WebGL",
        .other => "Other",
        .unknown => "?",
    };
}

/// Short label for the dev-status chip — kept terse so a card or
/// list row can fit one alongside the engine badge.
pub fn devStatusShortLabel(s: library.DevStatus) []const u8 {
    return switch (s) {
        .completed => "Completed",
        .abandoned => "Abandoned",
        .on_hold => "On Hold",
        .in_progress => "Ongoing",
        .orphaned => "Orphaned",
        .unknown => "?",
    };
}

/// Short label for the player's completion/progress status — the
/// kanban column headers and any progress chip. Terser than the detail
/// dropdown's prose labels so it fits a chip.
pub fn completionStatusShortLabel(s: library.CompletionStatus) []const u8 {
    return switch (s) {
        .not_started => "Backlog",
        .in_queue => "Queued",
        .in_progress => "Playing",
        .completed => "Completed",
        .replaying => "Replaying",
        .abandoned => "Dropped",
        .waiting_for_update => "Wait Update",
    };
}

/// Per-progress-status color. Distinct hues so the kanban columns read
/// apart at a glance: grey backlog → blue playing → green completed,
/// with amber for "waiting" and red for "dropped".
pub fn completionStatusColor(s: library.CompletionStatus) dvui.Color {
    return switch (s) {
        .not_started => .{ .r = 0x6F, .g = 0x6F, .b = 0x6F }, // grey
        .in_queue => .{ .r = 0x55, .g = 0x6A, .b = 0x8A }, // slate
        .in_progress => .{ .r = 0x1F, .g = 0x6A, .b = 0xA0 }, // blue
        .completed => .{ .r = 0x2E, .g = 0x7D, .b = 0x32 }, // green
        .replaying => .{ .r = 0x2A, .g = 0x8A, .b = 0x82 }, // teal
        .abandoned => .{ .r = 0xB7, .g = 0x1C, .b = 0x1C }, // red
        .waiting_for_update => .{ .r = 0xC0, .g = 0x84, .b = 0x1F }, // amber
    };
}

/// Per-status pill color. Mirrors a "traffic light" semantic: green
/// for completed, red for abandoned, amber for on hold, blue for
/// ongoing. Orphaned (thread gone from F95) reads as muted purple —
/// distinct from "abandoned" (dev gave up) without screaming red.
pub fn devStatusColor(s: library.DevStatus) dvui.Color {
    return switch (s) {
        .completed => .{ .r = 0x2E, .g = 0x7D, .b = 0x32 }, // green
        .abandoned => .{ .r = 0xB7, .g = 0x1C, .b = 0x1C }, // red
        .on_hold => .{ .r = 0xC0, .g = 0x84, .b = 0x1F }, // amber
        .in_progress => .{ .r = 0x1F, .g = 0x6A, .b = 0xA0 }, // blue
        .orphaned => .{ .r = 0x6E, .g = 0x4A, .b = 0x8A }, // muted purple
        .unknown => .{ .r = 0x6F, .g = 0x6F, .b = 0x6F }, // grey
    };
}

/// Per-engine accent colors. Loosely chosen to evoke each engine's
/// branding (Ren'Py teal, Unity dark, Unreal navy, etc.) while staying
/// distinguishable at chip scale on top of an arbitrary cover image.
pub fn engineBadgeColor(e: library.Engine) dvui.Color {
    const c = engine_palette.badgeColor(e);
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// dvui fill/border/text colors for a tag chip. `override_rgb` (0xRRGGBB)
/// is the user's chosen color when set; otherwise the stable per-name hue.
pub const TagChipColors = struct { fill: dvui.Color, border: dvui.Color, text: dvui.Color };
pub fn tagChipColors(tag: []const u8, override_rgb: ?u32) TagChipColors {
    const c = if (override_rgb) |rgb| engine_palette.tagChipFromRgb(rgb) else engine_palette.tagChip(tag);
    const cv = struct {
        fn f(x: anytype) dvui.Color {
            return .{ .r = x.r, .g = x.g, .b = x.b, .a = x.a };
        }
    }.f;
    return .{ .fill = cv(c.fill), .border = cv(c.border), .text = cv(c.text) };
}

/// Toolbar icon size — pinned to the global style so every icon
/// button matches every text button / dropdown / text entry.
const ICON_SIZE: dvui.Size = style.icon_size;
const ICON_OPTS: dvui.IconRenderOptions = .{};

/// Sugar: button with a leading icon + a text label. Returns true on
/// click. Builds the ButtonWidget by hand instead of using dvui's
/// `buttonLabelAndIcon` so we can drop a fixed-width spacer between
/// icon and label — dvui's default puts them flush together which
/// reads cramped at any reasonable font size.
pub fn iconButton(
    src: std.builtin.SourceLocation,
    label: []const u8,
    tvg: []const u8,
    opts: dvui.Options,
) bool {
    // Widget census for the test sweep — see style.zig.
    style.widgets_built += 1;
    if (opts.tag != null) style.widgets_tagged += 1;
    const defaults: dvui.Options = .{
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
    };
    const merged = defaults.override(opts);

    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{}, merged);
    bw.processEvents();
    bw.drawBackground();

    // Inner row: icon, spacer, label. Each child strips parent
    // options so we don't double-pad. The label gets `expand =
    // .both` + `.align_x = 0` so left-aligns flush against the
    // spacer — the row reads "[icon] [gap] [label]".
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        const child_opts = merged.strip().override(bw.style());
        dvui.icon(@src(), label, tvg, .{}, child_opts.override(.{
            .gravity_y = 0.5,
            .color_text = opts.color_text,
        }));
        // ICON_TEXT_GAP: physical px between glyph and first label
        // char. 8 reads as a single comfortable space without
        // stretching the row.
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        dvui.labelEx(@src(), "{s}", .{label}, .{ .align_x = 0, .align_y = 0.5 }, child_opts.override(.{
            .expand = .both,
            .gravity_y = 0.5,
        }));
    }

    const click = bw.clicked();
    bw.drawFocus();
    bw.deinit();
    return click;
}

/// Sugar: icon-only button (no text). Used for toolbar-style buttons
/// where space is tight and the icon is self-explanatory.
pub fn iconOnly(
    src: std.builtin.SourceLocation,
    name: []const u8,
    tvg: []const u8,
    opts: dvui.Options,
) bool {
    style.widgets_built += 1;
    if (opts.tag != null) style.widgets_tagged += 1;
    // Pass through gravity / margin / padding / colors so callers
    // can vertical-align the button in a toolbar row, etc. We still
    // override `min_size_content` to ICON_SIZE for visual consistency
    // across the rest of the UI; callers that need a non-default size
    // (e.g. carousel chevrons) call `dvui.buttonIcon` directly.
    return dvui.buttonIcon(src, name, tvg, .{}, ICON_OPTS, .{
        .min_size_content = ICON_SIZE,
        .id_extra = opts.id_extra orelse 0,
        .tag = opts.tag, // forward so the live GUI driver can address toolbar/rail icons
        .style = opts.style,
        .gravity_x = opts.gravity_x,
        .gravity_y = opts.gravity_y,
        .margin = opts.margin,
        .padding = opts.padding,
        .color_text = opts.color_text,
        .color_fill = opts.color_fill,
        .color_border = opts.color_border,
        .border = opts.border,
        .corner_radius = opts.corner_radius,
        .background = opts.background,
    });
}

/// Centered empty-state card (Design-B): a dim icon + title + subtitle in a
/// card, vertically centered in the available space. For screens with no
/// content yet (mods / downloads / import) so they don't read as half-built.
pub fn emptyState(icon: []const u8, title: []const u8, subtitle: []const u8) void {
    const t = tokens.active;
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer outer.deinit();
    _ = dvui.spacer(@src(), .{ .expand = .vertical });
    {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .gravity_x = 0.5,
            .background = true,
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .color_fill = style.cardFill(),
            .color_border = style.borderColor(),
            .padding = .{ .x = 36, .y = 30, .w = 36, .h = 30 },
            .min_size_content = .{ .w = 380, .h = 0 },
        });
        defer card.deinit();
        dvui.icon(@src(), "empty", icon, .{}, .{
            .gravity_x = 0.5,
            .min_size_content = .{ .w = 44, .h = 44 },
            .color_text = td(t.ink3),
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 14 } });
        dvui.labelNoFmt(@src(), title, .{}, .{
            .gravity_x = 0.5,
            .color_text = td(t.ink),
            .font = dvui.Font.theme(.title),
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        dvui.labelNoFmt(@src(), subtitle, .{}, .{ .gravity_x = 0.5, .color_text = td(t.ink3) });
    }
    _ = dvui.spacer(@src(), .{ .expand = .vertical });
}

/// Underline tab (Design-B): plain text — teal + bold when active, dim
/// otherwise — with a teal underline bar under the active tab. Click anywhere
/// on the column selects it.
pub fn tabButton(label: []const u8, active: bool) bool {
    const t = tokens.active;
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = @intFromPtr(label.ptr),
        .margin = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
        // Tab labels are unique per detail page → use the label as a stable
        // widget tag so the headless + live GUI drivers can click a given tab.
        .tag = label,
    });
    defer col.deinit();

    dvui.labelNoFmt(@src(), label, .{}, .{
        .padding = .{ .x = 4, .y = 8, .w = 4, .h = 7 },
        .gravity_x = 0.5,
        .min_size_content = .{ .w = 72, .h = 0 },
        .color_text = td(if (active) t.acc else t.ink2),
        .style = if (active) .highlight else .control,
    });

    // teal underline under the active tab; blends into the bg otherwise.
    var bar = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 2 },
        .background = true,
        .color_fill = td(if (active) t.acc else t.bg1),
        .corner_radius = dvui.Rect.all(1),
    });
    bar.deinit();

    return dvui.clicked(col.data(), .{});
}

/// Pink-muted, wrapping help text for Settings sections + other
/// prose-under-heading slots. `dvui.label` doesn't wrap — long
/// explanations overflow the panel at narrow window widths. Using
/// `textLayout` with `.expand = .horizontal` lets the text reflow.
pub fn helpTextColor() dvui.Color {
    return style.labelDim();
}

pub fn settingsHelpText(text: []const u8) void {
    // dvui's textLayout draws a selection / focus ring by default
    // which renders as a red box at our theme's error colour. Override
    // border + colour explicitly so the help text reads as the dim
    // grey-pink it always meant to be.
    //
    // Every call site uses the same `@src()` so widget ids collide
    // when more than one help block lives on a single screen. Hash
    // the text into `id_extra` so each unique snippet gets a stable,
    // distinct id without callers having to thread an index.
    //
    // cache_layout: help-text strings are compile-time constants —
    // safe to skip the per-frame relayout.
    var tl = dvui.textLayout(@src(), .{ .cache_layout = true }, .{
        .id_extra = std.hash.Wyhash.hash(0, text),
        .expand = .horizontal,
        .background = false,
        .border = .all(0),
        .color_border = helpTextColor(),
        .color_text = helpTextColor(),
    });
    defer tl.deinit();
    tl.addText(text, .{});
}

/// Render a unix-seconds timestamp as `YYYY-MM-DD HH:MM` UTC. No
/// seconds — matches the granularity F95 publishes in its OP info
/// block so the detail page reads consistently.
pub fn formatUtcDateTime(buf: []u8, ts: i64) ![]const u8 {
    if (ts <= 0) return std.fmt.bufPrint(buf, "—", .{});
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day = es.getEpochDay();
    const day_secs = es.getDaySeconds();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}",
        .{
            @as(u32, yd.year),
            md.month.numeric(),
            @as(u32, md.day_index) + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
        },
    );
}

/// Format a byte count to "12.3 MB" / "456 KB" / "789 B". Pure
/// formatter, no allocation — works on a caller-provided buffer.
pub fn humanBytes(buf: []u8, n: u64) []const u8 {
    const KB: f32 = 1024.0;
    const MB: f32 = 1024.0 * 1024.0;
    const GB: f32 = 1024.0 * 1024.0 * 1024.0;
    const f: f32 = @floatFromInt(n);
    if (f >= GB) return std.fmt.bufPrint(buf, "{d:.2} GB", .{f / GB}) catch "?";
    if (f >= MB) return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / MB}) catch "?";
    if (f >= KB) return std.fmt.bufPrint(buf, "{d:.1} KB", .{f / KB}) catch "?";
    return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
}

pub fn humanRate(buf: []u8, bytes_per_sec: u64) []const u8 {
    if (bytes_per_sec == 0) return "—";
    var inner_buf: [24]u8 = undefined;
    const human = humanBytes(&inner_buf, bytes_per_sec);
    return std.fmt.bufPrint(buf, "{s}/s", .{human}) catch "?";
}

// ============================================================
//  Login popup — shown at startup when the user isn't logged into
//  F95. Combines F95 + RPDL forms with a Skip button so the user
//  can dismiss for the session. Layout is responsive: side-by-side
//  on wide windows, stacked on narrow.
// ============================================================

/// Modal login overlay. Idempotent — render every frame while
/// `state.login_popup_open` is true; close via Skip, RPDL login, or
/// successful F95 login (auth.zig auto-closes on the latter).
/// Accounts popup — compact floating panel opened from the toolbar account
/// button (no longer a startup modal). Stacks the two account cards (F95Zone +
/// RPDL); each shows its signed-in identity + Sign out, or an inline sign-in
/// form.
pub fn renderLoginPopup(frame: *Frame) void {
    const state = frame.state;
    if (!state.login_popup_open) return;

    var win = dvui.floatingWindow(@src(), .{ .open_flag = &state.login_popup_open }, .{
        // Compact card panel (Design-B), not a full-width modal.
        .min_size_content = .{ .w = 360, .h = 0 },
        .max_size_content = .{ .w = 380, .h = 900 },
    });
    defer win.deinit();
    _ = dvui.windowHeader("Accounts", "", &state.login_popup_open);

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 12 },
    });
    defer col.deinit();

    renderF95LoginCard(frame);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    renderRpdlLoginCard(frame);
}

// ============================================================
//  Launch diagnostic dialog
// ============================================================

/// Modal popup shown when a launch attempt fails or pre-launch
/// diagnostics flag an actionable issue. Three buttons always:
///   - OK              : close + clear
///   - Copy to clipboard: paste the full log
///   - Fix issue       : only when `launch_diag_fix_id` is non-null;
///                       applies the recognised remedy and re-tries
///                       the launch for the stashed thread_id.
pub fn renderLaunchDiagPopup(frame: *Frame) void {
    const state = frame.state;
    if (!state.launch_diag_open) return;

    // Bound the window in BOTH directions. The log body can grow to
    // hundreds of lines for a Ren'Py traceback; without a max the
    // window grew past the viewport and pushed the footer (OK / Copy
    // / Apply) off-screen. Cap the height and let an inner scrollArea
    // handle overflow.
    var win = dvui.floatingWindow(@src(), .{ .open_flag = &state.launch_diag_open }, .{
        .min_size_content = .{ .w = 640, .h = 460 },
        .max_size_content = .{ .w = 1024, .h = 640 },
    });
    defer win.deinit();
    _ = dvui.windowHeader("Launch issue", "", &state.launch_diag_open);

    // Summary line. When the user has applied a fix this frame the
    // banner flips green + tells them to close + try Launch again
    // (we deliberately don't auto-relaunch from the dialog).
    {
        var msg_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 8, .w = 16, .h = 4 },
        });
        defer msg_box.deinit();
        if (state.launch_diag_fix_applied) {
            dvui.labelNoFmt(
                @src(),
                "Fix applied. Close this window and click Launch again.",
                .{},
                .{
                    .color_text = .{ .r = 0x4F, .g = 0xC3, .b = 0x6F },
                    .style = .highlight,
                    .expand = .horizontal,
                },
            );
        } else {
            const summary = state.launch_diag_summary_buf[0..state.launch_diag_summary_len];
            dvui.labelNoFmt(@src(), summary, .{}, .{
                .style = .err,
                .expand = .horizontal,
            });
        }
    }

    // Scrollable log body. Bound the box height — `.expand = .both`
    // alone lets the inner textLayout's natural size balloon the
    // floatingWindow past the viewport, hiding the footer. Capping
    // the log box at a known height keeps the OK / Apply buttons
    // pinned and gives the scrollArea something to clip against.
    {
        var log_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = 340 },
            .max_size_content = .{ .w = 99999, .h = 340 },
            .padding = .{ .x = 16, .y = 4, .w = 16, .h = 4 },
        });
        defer log_box.deinit();
        dvui.labelNoFmt(@src(), "Log", .{}, .{
            .color_text = helpTextColor(),
        });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 4 } });

        var border = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .color_fill = .{ .r = 0x14, .g = 0x0A, .b = 0x10 },
            .color_border = style.borderColor(),
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer border.deinit();

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();
        const log_text = state.launch_diag_log_buf[0..state.launch_diag_log_len];
        if (log_text.len == 0) {
            dvui.label(@src(), "(no further detail)", .{}, .{ .color_text = helpTextColor() });
        } else {
            // `labelNoFmt` is single-line and clips at the right edge.
            // `textLayout` wraps long lines + handles user text
            // selection — which the user can drag-select and copy
            // even before clicking the Copy to clipboard button.
            var tl = dvui.textLayout(@src(), .{}, .{
                .expand = .horizontal,
                .font = .theme(.mono),
            });
            tl.addText(log_text, .{});
            tl.deinit();
        }
    }

    // Footer buttons.
    {
        var footer = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 8, .w = 16, .h = 12 },
        });
        defer footer.deinit();

        if (iconButton(@src(), "Copy to clipboard", entypo.copy, .{})) {
            const log_text = state.launch_diag_log_buf[0..state.launch_diag_log_len];
            const summary = state.launch_diag_summary_buf[0..state.launch_diag_summary_len];
            // Build "summary\n\nlog" on the frame arena so dvui can
            // own it for the clipboard set.
            const arena = dvui.currentWindow().arena();
            var buf: std.ArrayList(u8) = .empty;
            buf.appendSlice(arena, summary) catch {};
            buf.appendSlice(arena, "\n\n") catch {};
            buf.appendSlice(arena, log_text) catch {};
            dvui.clipboardTextSet(buf.items);
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // Fix button — shown ONLY when we have a recognised fix AND
        // the user hasn't already applied it this dialog session.
        // Applying the fix does NOT auto-relaunch the game — the
        // dialog flips into "Fix applied" mode (banner above) and
        // the user closes the window + clicks Launch themselves.
        const can_show_fix = state.launch_diag_fix_id != null and !state.launch_diag_fix_applied;
        if (can_show_fix) {
            const fix_id = state.launch_diag_fix_id.?;
            const label = switch (fix_id) {
                .host_gpu_paths => "Fix: retry with host GPU paths",
                .compat_recipe => "Apply compat recipe",
            };
            if (iconButton(@src(), label, entypo.tools, .{ .style = .highlight })) {
                var apply_ok = true;
                switch (fix_id) {
                    .host_gpu_paths => {
                        state.launch_force_host_gpu = true;
                    },
                    .compat_recipe => {
                        if (state.launch_diag_install_id_set and state.launch_diag_compat_recipe_len > 0) {
                            const rid = state.launch_diag_compat_recipe_buf[0..state.launch_diag_compat_recipe_len];
                            const install_id_ptr = &state.launch_diag_install_id_buf;
                            actions.applyCompatFixForGame(frame, state.launch_diag_thread_id, install_id_ptr, rid) catch |e| {
                                var buf: [192]u8 = undefined;
                                const msg = std.fmt.bufPrint(&buf, "Apply compat fix failed: {s}", .{@errorName(e)}) catch "Apply compat fix failed.";
                                state.notifyErr(msg);
                                apply_ok = false;
                            };
                        }
                    },
                }
                if (apply_ok) {
                    state.launch_diag_fix_applied = true;
                }
            }
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        }

        if (iconButton(@src(), "OK", entypo.check, .{ .style = if (state.launch_diag_fix_applied) .highlight else .control })) {
            actions.clearLaunchDiag(state);
        }
    }
}

/// F95 login sub-card inside the popup. Self-contained — owns its
/// own status line + form. Submit triggers `actions.doLogin`; the
/// auth helper auto-closes the popup on success.
/// Account-card header (Design-B): circular avatar + service name + a
/// `domain · descriptor` subtitle + a signed-in/out status pill. Shared by the
/// F95 + RPDL cards. Called once per card (distinct parent boxes) so the inner
/// `@src()` ids don't collide.
fn accountHeader(letter: []const u8, name: []const u8, subtitle: []const u8, signed_in: bool) void {
    const t = tokens.active;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    // avatar circle
    {
        var av = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = 32, .h = 32 },
            .max_size_content = .{ .w = 32, .h = 32 },
            .background = true,
            .color_fill = td(if (signed_in) t.acc else t.bg3),
            .corner_radius = dvui.Rect.all(16),
            .gravity_y = 0.5,
        });
        defer av.deinit();
        dvui.labelNoFmt(@src(), letter, .{}, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .style = .highlight,
            .color_text = td(if (signed_in) t.ink_on_acc else t.ink2),
        });
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });

    // name + subtitle
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_y = 0.5 });
        defer info.deinit();
        dvui.labelNoFmt(@src(), name, .{}, .{ .style = .highlight, .color_text = td(t.ink) });
        const body = dvui.Font.theme(.body);
        dvui.labelNoFmt(@src(), subtitle, .{}, .{
            .color_text = td(t.ink3),
            .font = body.withSize(body.size * 0.85),
        });
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    // status pill (green "signed in" with dot, else grey "signed out")
    {
        var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .background = true,
            .color_fill = td(t.bg2),
            .color_border = td(if (signed_in) t.ok else t.line),
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(11),
            .padding = .{ .x = 9, .y = 3, .w = 9, .h = 3 },
            .gravity_y = 0.5,
        });
        defer pill.deinit();
        if (signed_in) {
            var d = dvui.box(@src(), .{}, .{
                .background = true,
                .color_fill = td(t.ok),
                .corner_radius = dvui.Rect.all(3),
                .min_size_content = .{ .w = 6, .h = 6 },
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
            });
            d.deinit();
        }
        dvui.labelNoFmt(@src(), if (signed_in) "signed in" else "signed out", .{}, .{
            .color_text = td(if (signed_in) t.ok else t.ink3),
            .gravity_y = 0.5,
        });
    }
}

/// Transient status/error line under an account header (signing in… / failed).
fn accountStatusLine(msg: []const u8, is_err: bool) void {
    const t = tokens.active;
    if (msg.len == 0) return;
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    dvui.labelNoFmt(@src(), msg, .{}, .{
        .color_text = td(if (is_err) t.danger else t.ink3),
        .expand = .horizontal,
    });
}

fn renderF95LoginCard(frame: *Frame) void {
    const state = frame.state;
    const t = tokens.active;
    const signed_in = state.login_status == .logged_in;
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = 0xCB00,
        .expand = .horizontal,
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = style.cardFill(),
        .color_border = style.borderColor(),
        .padding = .{ .x = 14, .y = 12, .w = 14, .h = 12 },
        .margin = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
    });
    defer card.deinit();

    accountHeader("F", "F95Zone", "f95zone.to · donor DDL + bookmarks", signed_in);

    {
        const msg = if (!state.login_msg.isEmpty()) state.loginMsg() else switch (state.login_status) {
            .logging_in => "signing in…",
            .err => "sign-in failed",
            else => "",
        };
        accountStatusLine(msg, state.login_status == .err);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });

    // Signed in → username + Sign out on one row.
    if (signed_in) {
        var srow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer srow.deinit();
        const u = state.f95UserSlice();
        dvui.labelNoFmt(@src(), if (u.len > 0) u else "(signed in)", .{}, .{
            .gravity_y = 0.5,
            .color_text = td(t.ink),
        });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "Sign out", .{}, .{ .style = .err, .gravity_y = 0.5 })) {
            actions.doLogout(frame);
        }
        return;
    }

    // Two-step (TOTP) challenge in progress → show only the code prompt.
    if (state.two_step_pending) {
        dvui.labelNoFmt(@src(), "Enter the code from your authenticator app:", .{}, .{ .color_text = td(t.ink) });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
        {
            const te = style.textEntry(@src(), .{
                .text = .{ .buffer = &state.two_step_code_buf },
                .placeholder = "123456",
            }, .{ .expand = .horizontal, .id_extra = 0xCB05 });
            te.deinit();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });
        if (style.button(@src(), "Verify code", .{}, .{ .style = .highlight })) {
            actions.doSubmitTotp(frame, state.f95TwoStepCodeSlice());
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        if (style.button(@src(), "Cancel", .{}, .{ .expand = .horizontal })) {
            actions.cancelTwoStep(frame);
        }
        return;
    }

    // Signed out → password form, or the cookie form (the 2FA / passkey
    // workaround). A link at the bottom toggles between them.
    if (!state.f95_login_use_cookie) {
        {
            const te = style.textEntry(@src(), .{
                .text = .{ .buffer = &state.f95_user_buf },
                .placeholder = "Username",
            }, .{ .expand = .horizontal, .id_extra = 0xCB01 });
            te.deinit();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        {
            const te = style.textEntry(@src(), .{
                .text = .{ .buffer = &state.f95_pass_buf },
                .password_char = "•",
                .placeholder = "Password",
            }, .{ .expand = .horizontal, .id_extra = 0xCB02 });
            te.deinit();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });
        if (style.button(@src(), "Sign in to F95Zone", .{}, .{ .style = .highlight })) {
            actions.doLogin(frame, state.f95UserSlice(), state.f95PassSlice());
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        if (style.button(@src(), "Use browser cookie (2FA / passkey)", .{}, .{ .expand = .horizontal })) {
            state.f95_login_use_cookie = true;
            state.setLoginMsg("");
        }
    } else {
        // Cookie sign-in: password login can't clear a passkey/2FA challenge,
        // so let the user paste the session cookie from a browser that can.
        dvui.labelNoFmt(@src(), "2FA or passkey? Sign in at f95zone.to in your browser,", .{}, .{ .color_text = td(t.ink) });
        dvui.labelNoFmt(@src(), "then paste these two cookies (devtools → Application):", .{}, .{ .color_text = td(t.ink) });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        if (style.button(@src(), "Open F95 login page", .{}, .{ .expand = .horizontal })) {
            actions.doOpenF95Login(frame);
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
        {
            const te = style.textEntry(@src(), .{
                .text = .{ .buffer = &state.f95_cookie_user_buf },
                .placeholder = "xf_user cookie value",
            }, .{ .expand = .horizontal, .id_extra = 0xCB03 });
            te.deinit();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        {
            const te = style.textEntry(@src(), .{
                .text = .{ .buffer = &state.f95_cookie_session_buf },
                .placeholder = "xf_session cookie value (optional)",
            }, .{ .expand = .horizontal, .id_extra = 0xCB04 });
            te.deinit();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });
        if (style.button(@src(), "Sign in with cookie", .{}, .{ .style = .highlight })) {
            actions.doLoginWithCookie(frame, state.f95CookieUserSlice(), state.f95CookieSessionSlice());
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        if (style.button(@src(), "Use password instead", .{}, .{ .expand = .horizontal })) {
            state.f95_login_use_cookie = false;
            state.setLoginMsg("");
        }
    }
}

/// RPDL login sub-card inside the popup. Mirrors the F95 card —
/// status line + form + Sign in button. Includes a brief recommend-
/// to-create-an-account note since RPDL is community-run and many
/// users won't have heard of it.
fn renderRpdlLoginCard(frame: *Frame) void {
    const state = frame.state;
    const t = tokens.active;
    const signed_in = state.rpdl_status == .logged_in;
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = 0xCC00,
        .expand = .horizontal,
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .color_fill = style.cardFill(),
        .color_border = style.borderColor(),
        .padding = .{ .x = 14, .y = 12, .w = 14, .h = 12 },
        .margin = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
    });
    defer card.deinit();

    accountHeader("R", "RPDL", "dl.rpdl.net · torrent mirror", signed_in);

    if (!signed_in) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
        dvui.labelNoFmt(
            @src(),
            "Optional — community torrent fallback when an F95 download has no DDL.",
            .{},
            .{ .expand = .horizontal, .color_text = td(t.ink3) },
        );
    }

    {
        const msg = if (!state.rpdl_msg.isEmpty()) state.rpdlMsg() else switch (state.rpdl_status) {
            .logging_in => "signing in…",
            .err => "sign-in failed",
            else => "",
        };
        accountStatusLine(msg, state.rpdl_status == .err);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });

    if (signed_in) {
        var srow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer srow.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "Sign out", .{}, .{ .style = .err, .gravity_y = 0.5 })) {
            actions.doRpdlLogout(frame);
        }
        return;
    }

    {
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.rpdl_user_buf },
            .placeholder = "Username",
        }, .{ .expand = .horizontal, .id_extra = 0xCC11 });
        te.deinit();
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });
    {
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.rpdl_pass_buf },
            .password_char = "•",
            .placeholder = "Password",
        }, .{ .expand = .horizontal, .id_extra = 0xCC12 });
        te.deinit();
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 10 } });
    {
        var brow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer brow.deinit();
        if (style.button(@src(), "Sign in to RPDL", .{}, .{ .style = .highlight, .gravity_y = 0.5 })) {
            actions.doRpdlLogin(frame, state.rpdlUserSlice(), state.rpdlPassSlice());
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "create account ↗", .{}, .{ .gravity_y = 0.5, .color_text = td(t.acc) })) {
            actions.openExternalUrl(frame, "https://dl.rpdl.net/register");
        }
    }
}

// ============================================================
//  Global sync recap popup + toast overlay + sync banner — rendered
//  by ui.zig on every screen.
// ============================================================

pub fn renderSyncRecapPopup(frame: *Frame) void {
    const state = frame.state;
    const entries = actions.syncRecapEntries(state);
    if (entries.len == 0) {
        // Defensive — clear the show flag if we somehow got here
        // with no entries.
        state.sync_recap_show = false;
        return;
    }

    var win = dvui.floatingWindow(@src(), .{ .open_flag = &state.sync_recap_show }, .{
        .min_size_content = .{ .w = 480, .h = 320 },
    });
    defer win.deinit();
    _ = dvui.windowHeader("Updates available", "", &state.sync_recap_show);

    // Top blurb: "<N> games changed since last sync".
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        });
        defer hdr.deinit();
        var msg_buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{d} game{s} updated", .{
            entries.len, if (entries.len == 1) "" else "s",
        }) catch "";
        dvui.labelNoFmt(@src(), msg, .{}, .{ .color_text = td(tokens.active.acc) });
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // Body: scrolling list of "Name  old → new" rows. Click a row to
    // jump to that game's detail page (also dismisses the popup).
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer scroll.deinit();

    for (entries) |e| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = e.thread_id,
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 90 },
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
            .background = true,
            .border = style.border_thin,
            .corner_radius = style.corner_radius,
            .color_fill = style.cardFill(),
            .color_border = style.borderColor(),
        });
        defer row.deinit();

        // Thumbnail. `thumbBytes(... idx = 0)` returns the cover-size
        // thumb (`<covers_dir>/<tid>.t`); falls back to a placeholder
        // box when the file isn't on disk yet (e.g. the sync committed
        // but phase-2 hasn't finished writing the cover thumb).
        renderRecapThumb(frame, e.thread_id);

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });

        // Middle column: name on top, version diff below.
        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = e.thread_id,
                .expand = .both,
                .gravity_y = 0.5,
            });
            defer col.deinit();

            dvui.labelNoFmt(@src(), e.name, .{}, .{
                .id_extra = e.thread_id,
                .expand = .horizontal,
                .color_text = td(tokens.active.acc),
            });

            _ = dvui.spacer(@src(), .{ .id_extra = e.thread_id, .min_size_content = .{ .w = 1, .h = 4 } });

            // Version diff: "old [→] new". The arrow is an entypo TVG
            // icon (font has it; the U+2192 codepoint in the system
            // text font didn't) inline with two text labels.
            {
                var diff_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = e.thread_id,
                    .expand = .horizontal,
                });
                defer diff_row.deinit();

                dvui.labelNoFmt(@src(), e.old_version, .{}, .{
                    .id_extra = e.thread_id,
                    .gravity_y = 0.5,
                    .color_text = style.labelDim(),
                });
                _ = dvui.spacer(@src(), .{ .id_extra = e.thread_id, .min_size_content = .{ .w = 6, .h = 1 } });
                dvui.icon(@src(), "diff-arrow", entypo.arrow_right, .{}, .{
                    .id_extra = e.thread_id,
                    .min_size_content = .{ .w = 16, .h = 16 },
                    .gravity_y = 0.5,
                    .color_text = tokens.toDvui(tokens.active.acc, dvui.Color),
                });
                _ = dvui.spacer(@src(), .{ .id_extra = e.thread_id, .min_size_content = .{ .w = 6, .h = 1 } });
                dvui.labelNoFmt(@src(), e.new_version, .{}, .{
                    .id_extra = e.thread_id +% 1, // disambiguate from old_version label above
                    .gravity_y = 0.5,
                    .color_text = td(tokens.active.acc),
                });
                if (e.auto_downloaded) {
                    _ = dvui.spacer(@src(), .{ .id_extra = e.thread_id, .min_size_content = .{ .w = 10, .h = 1 } });
                    dvui.labelNoFmt(@src(), "auto-downloaded", .{}, .{
                        .id_extra = e.thread_id +% 2,
                        .gravity_y = 0.5,
                        .color_text = .{ .r = 0xA0, .g = 0xA0, .b = 0xC0 },
                    });
                }
            }
        }

        _ = dvui.spacer(@src(), .{ .id_extra = e.thread_id, .min_size_content = .{ .w = 8, .h = 1 } });
        if (style.button(@src(), "Open", .{}, .{
            .id_extra = e.thread_id,
            .gravity_y = 0.5,
        })) {
            state.selected_thread = e.thread_id;
            state.screen = .detail;
            state.sync_recap_show = false;
        }
    }
}

/// Render a cover thumb for a recap row. Slot is fixed-size so every
/// row has the same layout; falls back to a placeholder if the thumb
/// file isn't on disk yet (e.g. sync committed but phase-2 image
/// worker hasn't written the thumb yet).
fn renderRecapThumb(frame: *Frame, thread_id: u64) void {
    const w: f32 = 100;
    const h: f32 = 74;
    if (actions.thumbBytes(frame, thread_id, 0)) |bytes| {
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{
                .bytes = bytes,
                .name = "recap-thumb",
                .invalidation = .bytes,
            } },
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
        .color_border = style.borderColor(),
        .color_fill = .{ .r = 0x1A, .g = 0x10, .b = 0x14 },
    });
    defer slot.deinit();
}

/// Global sync banner — visible on every screen while a sync-all
/// batch is in flight (or for a brief beat after a single sync
/// completes). Compact one-line strip; styling matches the bookmark
/// progress strip so the two reuse the same vocabulary.
/// Toast overlay — vertical stack of muted-pink pills floating in
/// the bottom-right of the window. Newest on top of the stack
/// (visually = bottom of column since the latest one slides into the
/// most-prominent slot). Errors carry a ✕ dismiss; info/success/warn
/// fade on their own via `state.ageToasts`. No-op when the stack is
/// empty so the overlay is invisible most of the time.
pub fn renderToasts(frame: *Frame) void {
    const state = frame.state;
    const toasts = state.toastSlice();
    if (toasts.len == 0) return;

    // Pin a floatingWindow to the bottom-center of the dvui window.
    // Strip is sized big enough for a tall stack of pills (260px); the
    // inner stack auto-sizes and is `gravity_y = 1.0`-pinned to the
    // bottom of that strip, so a single-line toast actually sits flush
    // at the bottom edge instead of floating somewhere up in the
    // invisible padding. Width scales with the window so long error
    // messages have room to wrap.
    const win_size = dvui.windowRect().size();
    const strip_w: f32 = std.math.clamp(win_size.w * 0.6, 360, 720);
    const strip_h: f32 = 260;
    const edge_margin: f32 = 8;
    state.toast_rect = .{
        .x = @max(0, (win_size.w - strip_w) / 2),
        .y = @max(0, win_size.h - strip_h - edge_margin),
        .w = strip_w,
        .h = strip_h,
    };

    var fw = dvui.floatingWindow(@src(), .{
        .modal = false,
        .stay_above_parent_window = true,
        .window_avoid = .none,
        .rect = &state.toast_rect,
    }, .{
        .background = false,
        .border = .all(0),
        .corner_radius = .all(0),
    });
    defer fw.deinit();

    // Wrapper box: pinned to the bottom of the floatingWindow's strip
    // and auto-sized vertically. Without this, the inner column with
    // `expand = .both` filled the whole 260px strip and child pills
    // landed at the *top* of it — visually that put a single-line
    // toast ~260px above the screen edge, which is what "pops up in
    // the middle" was.
    var anchor = dvui.box(@src(), .{ .dir = .vertical }, .{
        .gravity_y = 1.0,
        .expand = .horizontal,
    });
    defer anchor.deinit();

    // Render oldest-first so the newest pill sits at the bottom of
    // the stack — closest to where the user's eye landed for the
    // last action. `toasts[]` is newest-first, so iterate in reverse.
    var to_dismiss: ?usize = null;
    var idx_back: usize = toasts.len;
    while (idx_back > 0) : (idx_back -= 1) {
        const i = idx_back - 1;
        if (renderToastPill(i, toasts[i])) to_dismiss = i;
    }
    if (to_dismiss) |i| state.dismissToast(i);
}

/// Renders one toast pill. Returns true when the user clicked anywhere
/// on it — caller dismisses to keep the loop's iteration index sane.
/// Built as a `ButtonWidget` (not a plain box) so click events are
/// captured at the pill level *before* the inner textLayout has a
/// chance to swallow them for text-selection.
fn renderToastPill(index: usize, t: state_mod.Toast) bool {
    // Plain ASCII prefixes — the default font ships only basic Latin
    // glyph coverage, so ✓ / ⚠ / ✕ render as empty boxes. A future
    // nerd-font bundle would unlock proper icons; until then, text
    // tags are the safe choice.
    const glyph: []const u8 = switch (t.kind) {
        .info => "",
        .success => "[ok] ",
        .warn => "[!] ",
        .err => "[x] ",
    };
    const text_color: dvui.Color = switch (t.kind) {
        .info => helpTextColor(),
        .success => tokens.toDvui(tokens.active.acc, dvui.Color),
        .warn => td(tokens.active.warn),
        .err => td(tokens.active.danger),
    };

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = @intCast(index),
        .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        .margin = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        .background = true,
        .border = style.border_thin,
        .corner_radius = .all(6),
        .color_fill = style.cardFill(),
        .color_border = style.borderColor(),
        .expand = .horizontal,
    });
    bw.processEvents();
    bw.drawBackground();
    defer bw.deinit();

    var label_buf: [state_mod.MAX_TOAST_MSG + 4]u8 = undefined;
    const label_text = std.fmt.bufPrint(&label_buf, "{s}{s}", .{ glyph, t.msg() }) catch t.msg();
    // textLayout wraps to the parent button's width — multi-line
    // errors no longer get clipped at the strip edge.
    var tl = dvui.textLayout(@src(), .{}, .{
        .id_extra = @intCast(index),
        .expand = .horizontal,
        .background = false,
        .border = .all(0),
        .color_text = text_color,
    });
    defer tl.deinit();
    tl.addText(label_text, .{});

    return bw.clicked();
}

/// tokens.Color → dvui.Color.
fn td(col: tokens.Color) dvui.Color {
    return tokens.toDvui(col, dvui.Color);
}

/// Design-B left icon rail — primary screen navigation. Fixed-width vertical
/// column of icon buttons that switch `state.screen`; the active screen gets the
/// accent wash + an inset accent bar. Rendered once by guiFrame, left of the
/// screen content. Screen-specific actions stay in each screen's own top bar.
pub fn renderIconRail(frame: *Frame) void {
    const state = frame.state;
    var rail = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 54, .h = 0 },
        .expand = .vertical,
        .background = true,
        .color_fill = td(tokens.active.bg1),
        .color_border = td(tokens.active.line),
        .border = .{ .x = 0, .y = 0, .w = 1, .h = 0 },
        .padding = .{ .x = 0, .y = 10, .w = 0, .h = 10 },
    });
    defer rail.deinit();

    // Brand wordmark at the rail top (design-B `.rail .logo`): teal, display
    // font, so every screen carries the same f69 mark.
    {
        const title = dvui.Font.theme(.title);
        dvui.labelNoFmt(@src(), "f69", .{}, .{
            .gravity_x = 0.5,
            .color_text = td(tokens.active.acc),
            .font = title.withSize(title.size * 1.05),
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 10 },
        });
    }

    // Only true DESTINATIONS live on the rail. Downloads → the bottom
    // Activity Dock; Import → the top-bar "+ Add ▾". (See dock-and-rail
    // redesign.)
    railItem(state, 0, "Library", entypo.home, .library);
    railItem(state, 1, "Mods", entypo.tools, .universal_mods);
    _ = dvui.spacer(@src(), .{ .expand = .vertical });
    railAccount(state);
    railItem(state, 4, "Settings", entypo.cog, .settings);
    railItem(state, 5, "Diagnostics", entypo.help, .diagnostics);
}

/// Account/profile rail item. Unlike `railItem` it doesn't navigate to a
/// screen — it toggles the global Accounts popup (`renderLoginPopup`).
/// Teal icon when signed in; acc-wash highlight while the popup is open.
fn railAccount(state: *state_mod.State) void {
    const t = tokens.active;
    const signed_in = state.login_status == .logged_in or state.rpdl_status == .logged_in;
    const open = state.login_popup_open;
    var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .tag = "rail-account",
        .min_size_content = .{ .w = 38, .h = 38 },
        .gravity_x = 0.5,
        .background = open,
        .color_fill = td(t.acc_wash),
        .border = if (open) .{ .x = 2, .y = 0, .w = 0, .h = 0 } else dvui.Rect.all(0),
        .color_border = td(t.acc),
        .corner_radius = dvui.Rect.all(tokens.r),
        .margin = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
    });
    defer cell.deinit();
    dvui.icon(@src(), "account", entypo.user, .{}, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 19, .h = 19 },
        .color_text = td(if (signed_in) t.acc else t.ink3),
    });
    if (dvui.clicked(cell.data(), .{})) state.login_popup_open = !state.login_popup_open;
}

fn railItem(state: *state_mod.State, key: u32, name: []const u8, icon: []const u8, screen: state_mod.Screen) void {
    const t = tokens.active;
    const on = state.screen == screen;
    // Stable per-screen tag ("rail-library", …) so the live GUI driver can
    // address each rail nav target by name (see ui.zig dumpTags).
    var tag_buf: [40]u8 = undefined;
    const tag_str = std.fmt.bufPrint(&tag_buf, "rail-{s}", .{@tagName(screen)}) catch "rail";
    var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = key,
        .tag = tag_str,
        .min_size_content = .{ .w = 38, .h = 38 },
        .gravity_x = 0.5,
        .background = on,
        .color_fill = td(t.acc_wash),
        .border = if (on) .{ .x = 2, .y = 0, .w = 0, .h = 0 } else dvui.Rect.all(0),
        .color_border = td(t.acc),
        .corner_radius = dvui.Rect.all(tokens.r),
        .margin = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
    });
    defer cell.deinit();
    dvui.icon(@src(), name, icon, .{}, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 19, .h = 19 },
        .color_text = td(if (on) t.acc else t.ink3),
    });
    if (dvui.clicked(cell.data(), .{})) state.screen = screen;
}

// ----- bottom status bar (global activity) -----

fn statusDot(col: dvui.Color) void {
    var d = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = col,
        .corner_radius = dvui.Rect.all(3),
        .min_size_content = .{ .w = 6, .h = 6 },
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 7, .h = 0 },
    });
    d.deinit();
}

fn statusMiniBar(frac: f32, w: f32) void {
    const t = tokens.active;
    const f = std.math.clamp(frac, 0, 1);
    var outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = td(t.bg3),
        .corner_radius = dvui.Rect.all(2),
        .min_size_content = .{ .w = w, .h = 5 },
        .gravity_y = 0.5,
    });
    defer outer.deinit();
    var inner = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = td(t.acc),
        .corner_radius = dvui.Rect.all(2),
        .min_size_content = .{ .w = w * f, .h = 5 },
    });
    inner.deinit();
}

/// Shared trailing cluster for a sync/image activity in the status bar:
/// a gap, the mini progress bar, another gap, then a `done/total`
/// counter. Only one activity branch renders per frame, so the repeated
/// `@src()` widget ids never collide.
fn statusProgress(frac: f32, done: u32, total: u32, font: dvui.Font) void {
    const t = tokens.active;
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 9, .h = 1 } });
    statusMiniBar(frac, 110);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 9, .h = 1 } });
    var b: [32]u8 = undefined;
    dvui.labelNoFmt(@src(), std.fmt.bufPrint(&b, "{d}/{d}", .{ done, total }) catch "", .{}, .{ .gravity_y = 0.5, .color_text = td(t.ink3), .font = font });
}

/// Cancel affordance for an in-flight sync (pre-flight or `/full`),
/// living in the status bar now that the old top banner is gone.
/// `cancelSync` already tears down the fast-check job, the `/full`
/// queue, and piggybacked image work, so one button covers every sync
/// phase. `src` is threaded from the call site so the two branches get
/// distinct widget ids.
fn statusCancelButton(frame: *Frame, src: std.builtin.SourceLocation, cancelling: bool) void {
    if (cancelling) {
        _ = iconButton(src, "Cancelling…", entypo.cross, .{ .style = .control, .gravity_y = 0.5, .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 } });
    } else {
        if (iconButton(src, "Cancel", entypo.cross, .{ .style = .err, .gravity_y = 0.5 })) actions.cancelSync(frame);
    }
}

fn statusJobTitle(frame: *Frame, job: *const downloads.Job) []const u8 {
    if (job.game_id != 0) {
        for (frame.games) |*g| {
            if (g.f95_thread_id == job.game_id) return g.name;
        }
    }
    return job.source_url;
}

fn statusSeg(key: u32, label: []const u8, n: u32, col: dvui.Color, font: dvui.Font) void {
    var seg = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = key, .padding = .{ .x = 9, .y = 0, .w = 0, .h = 0 } });
    defer seg.deinit();
    var b: [48]u8 = undefined;
    dvui.labelNoFmt(@src(), std.fmt.bufPrint(&b, "{s} {d}", .{ label, n }) catch label, .{}, .{ .gravity_y = 0.5, .color_text = col, .font = font });
}

/// Bottom status bar — an always-present thin strip showing global activity
/// (download / install / sync). Idle shows "Ready". Rendered once by guiFrame
/// at the bottom of the root, full-width under the rail + content.
pub fn renderStatusBar(frame: *Frame) void {
    const state = frame.state;
    const t = tokens.active;
    const m0 = dvui.Font.theme(.mono);
    const mono = m0.withSize(m0.size * 0.82);

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 30 },
        .background = true,
        .color_fill = td(t.bg1),
        .color_border = if (state.dock_expanded) td(t.acc_dim) else td(t.line),
        .border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
        .padding = .{ .x = 12, .y = 0, .w = 10, .h = 0 },
        .tag = "activity-dock",
    });
    defer bar.deinit();

    // Scan download jobs: counts + the primary active download.
    var n_down: u32 = 0;
    var n_seed: u32 = 0;
    var n_post: u32 = 0;
    var primary: ?*const downloads.Job = null;
    var it = frame.dl_mgr.jobs.iterator();
    while (it.next()) |e| {
        switch (e.value_ptr.status) {
            .downloading => {
                n_down += 1;
                if (primary == null) primary = e.value_ptr;
            },
            .queued, .fetching_metadata, .verifying => n_down += 1,
            .extracting, .applying => n_post += 1,
            .seeding => n_seed += 1,
            else => {},
        }
    }

    // ---- left: primary activity ----
    if (primary) |j| {
        statusDot(td(t.acc));
        dvui.labelNoFmt(@src(), statusJobTitle(frame, j), .{}, .{ .gravity_y = 0.5, .color_text = td(t.ink2), .font = mono });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 9, .h = 1 } });
        const frac: f32 = if (j.bytes_total) |tot|
            (if (tot > 0) @as(f32, @floatFromInt(j.bytes_done)) / @as(f32, @floatFromInt(tot)) else 0)
        else
            0;
        statusMiniBar(frac, 110);
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 9, .h = 1 } });
        var b2: [48]u8 = undefined;
        const pct: u32 = @intFromFloat(std.math.clamp(frac, 0, 1) * 100);
        const mbps = @as(f64, @floatFromInt(j.download_speed)) / (1024.0 * 1024.0);
        dvui.labelNoFmt(@src(), std.fmt.bufPrint(&b2, "{d}% · {d:.1} MB/s", .{ pct, mbps }) catch "", .{}, .{ .gravity_y = 0.5, .color_text = td(t.ink3), .font = mono });
    } else if (n_post > 0) {
        statusDot(td(t.warn));
        dvui.labelNoFmt(@src(), "Installing…", .{}, .{ .gravity_y = 0.5, .color_text = td(t.ink2), .font = mono });
    } else if (state.folder_import_job) |fj| {
        // Background folder copy/move (cross-device or copy mode). The
        // byte total is 2× the data size (copy + verify), so a percent
        // reads cleaner than a GB counter that would show double.
        statusDot(td(t.acc));
        const p = &fj.payload;
        const ci = p.cur_index.load(.acquire);
        const name = if (ci < p.items.len) p.items[ci].name else "";
        var bimp: [96]u8 = undefined;
        const lbl = if (name.len > 0) (std.fmt.bufPrint(&bimp, "Importing {s}", .{name}) catch "Importing…") else "Importing…";
        dvui.labelNoFmt(@src(), lbl, .{}, .{ .gravity_y = 0.5, .color_text = td(t.ink2), .font = mono });
        const bd = p.bytes_done.load(.monotonic);
        const bt = p.bytes_total.load(.acquire);
        const frac: f32 = if (bt > 0) @as(f32, @floatFromInt(bd)) / @as(f32, @floatFromInt(bt)) else 0;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 9, .h = 1 } });
        statusMiniBar(frac, 110);
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 9, .h = 1 } });
        var bpct: [16]u8 = undefined;
        const pct: u32 = @intFromFloat(std.math.clamp(frac, 0, 1) * 100);
        dvui.labelNoFmt(@src(), std.fmt.bufPrint(&bpct, "{d}%", .{pct}) catch "", .{}, .{ .gravity_y = 0.5, .color_text = td(t.ink3), .font = mono });
        if (fj.cancelRequested()) {
            _ = iconButton(@src(), "Cancelling…", entypo.cross, .{ .style = .control, .gravity_y = 0.5, .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 } });
        } else {
            if (iconButton(@src(), "Cancel", entypo.cross, .{ .style = .err, .gravity_y = 0.5 })) actions.cancelFolderImport(frame);
        }
    } else if (state.pending_fast_check) |fc| {
        // Phase 0: indexer `/fast` pre-flight. No per-game name yet —
        // the bar is purely count-driven off the worker's atomics.
        statusDot(td(t.acc));
        dvui.labelNoFmt(@src(), "Checking for changes", .{}, .{ .gravity_y = 0.5, .color_text = td(t.ink2), .font = mono });
        const fd = fc.payload.fast_done.load(.acquire);
        const ftot = fc.payload.fast_total;
        const frac: f32 = if (ftot > 0) @as(f32, @floatFromInt(fd)) / @as(f32, @floatFromInt(ftot)) else 0;
        statusProgress(frac, fd, ftot, mono);
        statusCancelButton(frame, @src(), fc.cancel.load(.acquire));
    } else if (state.anyActiveSync() or state.sync_queue != null) {
        // Phase 1: per-game `/full` syncs. `sync_queue_started/total`
        // is the batch position; the name is the row in flight.
        statusDot(td(t.acc));
        const nm = state.currentSyncName();
        var b3: [96]u8 = undefined;
        const lbl = if (nm.len > 0) (std.fmt.bufPrint(&b3, "Syncing {s}", .{nm}) catch "Syncing…") else "Syncing…";
        dvui.labelNoFmt(@src(), lbl, .{}, .{ .gravity_y = 0.5, .color_text = td(t.ink2), .font = mono });
        const done = state.sync_queue_started;
        const tot = state.sync_queue_total;
        const frac: f32 = if (tot > 0) @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(tot)) else 0;
        statusProgress(frac, done, tot, mono);
        statusCancelButton(frame, @src(), state.anySyncCancelling());
    } else if (state.anyActiveImage() or
        (state.image_queue != null and state.image_queue_head < state.image_queue_len) or
        state.image_total > 0)
    {
        // Phase 2: background screenshot backfill. Lower-key dot — the
        // library is fully usable while this trickles in.
        statusDot(td(t.acc_dim));
        dvui.labelNoFmt(@src(), "Fetching screenshots", .{}, .{ .gravity_y = 0.5, .color_text = td(t.ink2), .font = mono });
        const idone = state.image_done.load(.acquire);
        const itot = state.image_total;
        const frac: f32 = if (itot > 0) @as(f32, @floatFromInt(idone)) / @as(f32, @floatFromInt(itot)) else 0;
        statusProgress(frac, idone, itot, mono);
        if (state.image_cancel.load(.acquire)) {
            _ = iconButton(@src(), "Cancelling…", entypo.cross, .{ .style = .control, .gravity_y = 0.5, .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 } });
        } else {
            if (iconButton(@src(), "Cancel", entypo.cross, .{ .style = .control, .gravity_y = 0.5 })) actions.cancelImageQueue(frame);
        }
    } else {
        // Idle: surface the last sync/tag/import status message so a
        // failed sync doesn't just silently fall back to "Ready". Errors
        // (sync_status == .err) render in the danger color and, being an
        // .err toast's peer, persist until the next action overwrites the
        // buffer. Progress is shown by the branches above; this only fires
        // when nothing is actively running.
        const smsg = state.syncMsg();
        if (smsg.len > 0) {
            const is_err = state.sync_status == .err;
            statusDot(td(if (is_err) t.danger else t.ink3));
            dvui.labelNoFmt(@src(), smsg, .{}, .{ .gravity_y = 0.5, .color_text = td(if (is_err) t.danger else t.ink3), .font = mono });
        } else {
            dvui.labelNoFmt(@src(), "Ready", .{}, .{ .gravity_y = 0.5, .color_text = td(t.ink3), .font = mono });
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    // ---- right: segment counts ----
    if (n_down > 0) statusSeg(0xD0, "\u{2913}", n_down, td(t.acc), mono);
    if (n_post > 0) statusSeg(0xD1, "install", n_post, td(t.warn), mono);
    if (n_seed > 0) statusSeg(0xD2, "\u{2191} seeding", n_seed, td(t.ink3), mono);
    {
        const syncing = state.anyActiveSync() or state.sync_queue != null or state.pending_fast_check != null;
        dvui.labelNoFmt(@src(), if (syncing) "\u{27F3} syncing" else "\u{27F3} idle", .{}, .{
            .id_extra = 0xD9,
            .gravity_y = 0.5,
            .color_text = td(if (syncing) t.acc else t.ink3),
            .font = mono,
            .padding = .{ .x = 9, .y = 0, .w = 0, .h = 0 },
        });
    }

    // Expand/collapse affordance — a click anywhere on the dock toggles the
    // Downloads & Seeding drawer (renderActivityDrawer).
    dvui.icon(@src(), "dock-chev", if (state.dock_expanded) entypo.chevron_down else entypo.chevron_up, .{}, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 14, .h = 14 },
        .color_text = td(t.ink3),
        .padding = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
    });
    if (dvui.clicked(bar.data(), .{})) state.dock_expanded = !state.dock_expanded;
}
