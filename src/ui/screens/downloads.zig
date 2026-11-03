// Downloads screen — paste-URL prototype + active jobs list.

const std = @import("std");
const dvui = @import("dvui");
const tokens = @import("ui_tokens");
const entypo = dvui.entypo;
const library = @import("library");
const downloads = @import("downloads");

const types = @import("../types.zig");
const actions = @import("../actions.zig");
const style = @import("../style.zig");
const components = @import("../components.zig");
const comp = @import("ui_comp");
const dl_rows = @import("../dl_rows.zig");
const dl_controls = @import("../dl_controls.zig");

const Frame = types.Frame;
const JobView = downloads.JobView;
const Job = downloads.model.Job;
const Step = downloads.model.Step;
const RowAction = dl_rows.RowAction;
const RowMode = dl_rows.RowMode;
const statusChipSpec = dl_rows.statusChipSpec;
const isTorrent = dl_rows.isTorrent;

/// The snapshot copied into the dvui per-frame arena (no lock held while
/// widgets are built).
fn snapCopy(frame: *Frame) actions.SnapCopy {
    return actions.copySnapshot(frame, dvui.currentWindow().arena());
}

// ============================================================
//  downloads screen — paste-URL prototype + active jobs list
// ============================================================

/// Seed-ratio target from the downloader settings. The UI's seed-ratio
/// bar fills toward this number so the user sees the finish line.
pub fn seedRatioTarget(frame: *Frame) f32 {
    return frame.state.dl_settings.seed_ratio;
}

pub fn downloadsScreen(frame: *Frame) !bool {
    const state = frame.state;

    // Top bar.
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        });
        defer top.deinit();
        if (components.iconButton(@src(), "Back", entypo.chevron_left, .{})) state.screen = .library;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        dvui.label(@src(), "Downloads & Seeding", .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = tokens.toDvui(tokens.active.acc, dvui.Color) } });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // Compute live totals across all jobs — gives the user a
        // single glanceable "what's happening" number even before
        // they scroll.
        const snap = snapCopy(frame);
        var live = LiveTotals{};
        for (snap.jobs) |*v| live.fold(&v.job);

        var dl_buf: [24]u8 = undefined;
        var up_buf: [24]u8 = undefined;
        var totals_buf: [192]u8 = undefined;
        var waiting_buf: [32]u8 = undefined;
        const waiting_s: []const u8 = if (live.n_waiting > 0)
            std.fmt.bufPrint(&waiting_buf, " · {d} waiting for you", .{live.n_waiting}) catch ""
        else
            "";
        const dl_s = components.humanRate(&dl_buf, live.dl_speed);
        const up_s = components.humanRate(&up_buf, live.up_speed);
        const totals_s = std.fmt.bufPrint(
            &totals_buf,
            "↓ {s}  ↑ {s}  · {d} active · {d} seeding · {d} in history{s}",
            .{ dl_s, up_s, live.n_active, live.n_seeding, live.n_history, waiting_s },
        ) catch "";
        dvui.labelNoFmt(@src(), totals_s, .{}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        // Pause all / Resume all — global controls. The buttons are
        // greyed when there's nothing for them to act on (e.g.
        // "Resume all" with no paused jobs); we keep them rendered
        // so the row layout stays stable.
        const pr = actions.pauseResumeState(snap.jobs);
        const has_paused = pr.any_paused;
        const has_resumable = pr.any_pausable;
        const pause_opts: dvui.Options = if (has_resumable)
            .{}
        else
            .{ .style = .control, .color_text = .{ .color = .{ .r = 0x80, .g = 0x80, .b = 0x80 } } };
        if (style.button(@src(), "Pause all", .{}, pause_opts) and has_resumable) {
            frame.dl.send(.pause_all);
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        const resume_opts: dvui.Options = if (has_paused)
            .{ .style = .highlight }
        else
            .{ .style = .control, .color_text = .{ .color = .{ .r = 0x80, .g = 0x80, .b = 0x80 } } };
        if (style.button(@src(), "Resume all", .{}, resume_opts) and has_paused) {
            frame.dl.send(.unpause_all);
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        if (style.button(@src(), "Clear history", .{}, .{ .tag = "dl-clear-history" })) {
            frame.dl.send(.clear_history);
        }
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 24, .y = 16, .w = 24, .h = 16 },
    });
    defer body.deinit();

    // URL paste row + Download button.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
        });
        defer row.deinit();
        const te = style.textEntry(@src(), .{ .text = .{ .buffer = &state.dl_url_buf } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 600, .h = 28 },
        });
        te.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        if (style.button(@src(), "Download", .{}, .{ .style = .highlight })) {
            const url = std.mem.trim(u8, state.dlUrlSlice(), " \t\n\r");
            if (url.len > 0) {
                frame.dl.send(.{ .enqueue_url = .{ .url = url, .kind = .game, .game_thread_id = 0, .title = url, .host = downloads.downloader.HOST_RAW } });
                @memset(&state.dl_url_buf, 0);
            }
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    var dst_buf: [256]u8 = undefined;
    const dst_msg = std.fmt.bufPrint(&dst_buf, "Files land in {s}. Torrents seed to a {d:.1}× ratio.", .{
        frame.info.downloads_root, seedRatioTarget(frame),
    }) catch "Files land in the downloads folder.";
    dvui.labelNoFmt(@src(), dst_msg, .{}, .{
        .color_text = .{ .color = style.labelDim() },
    });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    // Controls (slots, caps, upload, seeding, watched folder, MEGA) —
    // collapsed by default; the same panel as Settings → Downloads.
    if (dvui.expander(@src(), "Controls", .{ .expanded = &state.dl_controls_open }, .{ .expand = .horizontal, .tag = "dl-controls" })) {
        var panel = dvui.scrollArea(@src(), .{}, .{
            .expand = .horizontal,
            .max_size_content = .height(360),
            .padding = .{ .x = 16, .y = 0, .w = 8, .h = 4 },
        });
        defer panel.deinit();
        dvui.labelNoFmt(@src(), "Changes apply at once to running downloads.", .{}, .{ .color_text = .{ .color = style.labelDim() } });
        dl_controls.renderControls(frame);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    renderDownloadsBody(frame, .full);
    return true;
}

/// The job-list body: sections Needs you / Active / Seeding / History +
/// per-row actions, or an empty state. Shared by the
/// Downloads screen and the bottom Activity drawer (`renderActivityDrawer`).
pub fn renderDownloadsBody(frame: *Frame, mode: RowMode) void {
    const snap = snapCopy(frame);
    if (snap.jobs.len == 0) {
        components.emptyState(entypo.download, "No downloads yet", "Start one from a game's Download button, or paste a URL via + Add.");
        return;
    }

    var list = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer list.deinit();

    // Rows render from a copy of the snapshot; the click is collected and
    // sent as one command after the loop.
    var pending: RowAction = .none;

    // Needs you: jobs waiting in the browser, at the top. The open
    // "Paste link…" entry closes when its job no longer waits.
    {
        var n_waiting: u32 = 0;
        var paste_open = false;
        for (snap.jobs) |*v| {
            if (classifyJob(&v.job) != .needs_you) continue;
            n_waiting += 1;
            if (frame.state.dl_paste_job == v.job.id) paste_open = true;
        }
        if (!paste_open and frame.state.dl_paste_job != null) closePaste(frame.state);
        if (n_waiting > 0) {
            downloadsSectionHeader("Needs you", n_waiting, @intFromEnum(JobGroup.needs_you));
            var first = true;
            for (snap.jobs) |*v| {
                if (classifyJob(&v.job) != .needs_you) continue;
                const action = renderNeedsYouRow(frame, v, resolveJobTitle(frame.games, &v.job), first);
                first = false;
                switch (action) {
                    .none => {},
                    else => pending = action,
                }
            }
        }
    }

    // dvui logs an error for a tag used twice in one frame, so only the
    // first job row of the page carries the test tags.
    var first_row = true;

    // Active and Seeding. Per-section count is computed up front so we
    // can skip the header entirely for empty groups (a lone "Seeding"
    // header with nothing under it just adds noise).
    const groups = [_]struct { name: []const u8, group: JobGroup }{
        .{ .name = "Active", .group = .active },
        .{ .name = "Seeding", .group = .seeding },
    };
    for (groups) |section| {
        var section_n: u32 = 0;
        for (snap.jobs) |*v| {
            if (classifyJob(&v.job) == section.group) section_n += 1;
        }
        if (section_n == 0) continue;

        downloadsSectionHeader(section.name, section_n, @intFromEnum(section.group));
        for (snap.jobs) |*v| {
            const job = &v.job;
            if (classifyJob(job) != section.group) continue;
            const title = resolveJobTitle(frame.games, job);
            // An install worker still moving the file / applying a mod
            // shows "Extracting" instead of a stale "Installing" pill.
            const extracting = actions.isExtracting(frame, job.id);
            const action = dl_rows.renderJobRow(frame, v, title, extracting, seedRatioTarget(frame), mode, first_row);
            first_row = false;
            switch (action) {
                .none => {},
                else => pending = action,
            }
        }
    }

    // History: done / failed / cancelled, newest first.
    {
        const order = historyOrder(dvui.currentWindow().arena(), snap.jobs);
        if (order.len > 0) {
            downloadsSectionHeader("History", @intCast(order.len), @intFromEnum(JobGroup.history));
            for (order) |i| {
                const v = &snap.jobs[i];
                const action = dl_rows.renderJobRow(frame, v, resolveJobTitle(frame.games, &v.job), false, seedRatioTarget(frame), .history, first_row);
                first_row = false;
                switch (action) {
                    .none => {},
                    else => pending = action,
                }
            }
        }
    }

    // `snap` is an arena copy: no snapshot lock is held here, so the
    // native file dialog below may block.
    switch (pending) {
        .none => {},
        .open_again => |id| actions.dlOpenAgain(frame, id),
        .paste_toggle => |id| {
            const was_open = frame.state.dl_paste_job == id;
            closePaste(frame.state);
            if (!was_open) frame.state.dl_paste_job = id;
        },
        .paste => |p| {
            actions.dlPasteLink(frame, p.id, p.url);
            closePaste(frame.state);
        },
        .pick => |id| actions.dlPickFileDialog(frame, id),
        .accept => |a| actions.dlAcceptMatch(frame, a.id, a.ok),
        .cancel => |id| frame.dl.send(.{ .cancel = id }),
        .remove => |id| frame.dl.send(.{ .remove = id }),
        .retry => |id| actions.retryDownload(frame, id),
        // The file is on disk; only the install step failed.
        .retry_install => |id| frame.dl.send(.{ .retry_install = id }),
        // The OS file manager, never the custom browser.
        .open_folder => |path| actions.openFolder(frame, path),
        .pause => |id| frame.dl.send(.{ .pause = id }),
        .unpause => |id| frame.dl.send(.{ .unpause = id }),
        .stop_seeding => |id| frame.dl.send(.{ .stop_seeding = id }),
    }
}

/// The Activity dock expanded: a bottom-anchored drawer over the current
/// screen with the full Downloads & Seeding body. Tracks the window each
/// frame (so it follows resizes); not movable or resizable. Opened by
/// clicking the dock (`renderStatusBar`).
pub fn renderActivityDrawer(frame: *Frame) void {
    const state = frame.state;
    if (!state.dock_expanded) return;
    const t = tokens.active;

    const dock_h: f32 = 30;
    const rail_w: f32 = 54;
    const wr = dvui.windowRect();
    const h: f32 = @min(340, wr.h * 0.6);
    state.activity_drawer_rect = .{
        .x = rail_w,
        .y = @max(0, wr.h - dock_h - h),
        .w = @max(220, wr.w - rail_w),
        .h = h,
    };
    var fw = dvui.floatingWindow(@src(), .{
        .open_flag = &state.dock_expanded,
        .rect = &state.activity_drawer_rect,
        .resize = .none,
    }, .{
        .background = true,
        .color_fill = .{ .color = tokens.toDvui(t.bg1, dvui.Color) },
        .border = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
        .color_border = .{ .color = tokens.toDvui(t.acc_dim, dvui.Color) },
    });
    defer fw.deinit();
    fw.dragAreaSet(.{}); // pinned — no drag/resize

    // header: Activity · spacer · Pause all · Clear finished · collapse
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 14, .y = 7, .w = 10, .h = 7 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .color_border = .{ .color = style.borderColor() },
        });
        defer hdr.deinit();
        const title = dvui.Font.theme(.title);
        dvui.labelNoFmt(@src(), "Activity", .{}, .{
            .gravity_y = 0.5,
            .color_text = .{ .color = tokens.toDvui(t.ink, dvui.Color) },
            .font = title.withSize(title.size * 0.92),
        });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        const pr = actions.pauseResumeState(snapCopy(frame).jobs);
        if (pr.any_pausable) {
            if (style.button(@src(), "Pause all", .{}, .{ .gravity_y = 0.5 })) frame.dl.send(.pause_all);
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        }
        if (pr.any_paused) {
            if (style.button(@src(), "Resume all", .{}, .{ .gravity_y = 0.5, .style = .highlight })) frame.dl.send(.unpause_all);
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        }
        if (style.button(@src(), "Clear finished", .{}, .{ .gravity_y = 0.5 })) frame.dl.send(.clear_history);
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        if (components.iconOnly(@src(), "drawer-close", entypo.chevron_down, .{ .gravity_y = 0.5, .tag = "drawer-close" })) state.dock_expanded = false;
    }

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 6, .y = 4, .w = 6, .h = 6 } });
    defer body.deinit();
    renderDownloadsBody(frame, .compact);
}

const LiveTotals = struct {
    dl_speed: u64 = 0,
    up_speed: u64 = 0,
    n_active: u32 = 0,
    n_seeding: u32 = 0,
    n_history: u32 = 0,
    n_waiting: u32 = 0,

    fn fold(self: *LiveTotals, j: *const Job) void {
        switch (classifyJob(j)) {
            .needs_you => self.n_waiting += 1,
            .active => {
                self.n_active += 1;
                self.dl_speed += j.dl_speed;
                self.up_speed += j.ul_speed;
            },
            .seeding => {
                self.n_seeding += 1;
                self.up_speed += j.ul_speed;
            },
            .history => self.n_history += 1,
        }
    }
};

/// Bucket for the downloads-screen sections. `active` is anything not
/// yet finished (queued, resolving, downloading, verifying, extracting,
/// installing, paused); `seeding` is post-payload upload-only; `history`
/// is everything terminal (done / failed / cancelled). Keep the int repr
/// stable — downloadsSectionHeader uses it as the dvui id_extra key.
const JobGroup = enum(u8) { active = 1, seeding = 2, history = 3, needs_you = 4 };

fn classifyJob(j: *const Job) JobGroup {
    return switch (j.step) {
        .awaiting_user => .needs_you,
        .seeding => .seeding,
        .done, .failed, .cancelled => .history,
        else => .active,
    };
}

/// When a history job ended (`finished_at`, else `created_at`).
fn historyKey(j: *const Job) i64 {
    return j.finished_at orelse j.created_at;
}

/// Indices into `jobs` of the History jobs, newest first (ties: higher
/// id first). In `a` (the frame arena); empty on out-of-memory.
fn historyOrder(a: std.mem.Allocator, jobs: []const JobView) []const usize {
    var n: usize = 0;
    for (jobs) |*v| {
        if (classifyJob(&v.job) == .history) n += 1;
    }
    const out = a.alloc(usize, n) catch return &.{};
    var k: usize = 0;
    for (jobs, 0..) |*v, i| {
        if (classifyJob(&v.job) != .history) continue;
        out[k] = i;
        k += 1;
    }
    const Ctx = struct {
        jobs: []const JobView,
        fn newerFirst(ctx: @This(), x: usize, y: usize) bool {
            const jx = &ctx.jobs[x].job;
            const jy = &ctx.jobs[y].job;
            const kx = historyKey(jx);
            const ky = historyKey(jy);
            if (kx != ky) return kx > ky;
            return jx.id > jy.id;
        }
    };
    std.mem.sort(usize, out, Ctx{ .jobs = jobs }, Ctx.newerFirst);
    return out;
}

test "historyOrder: terminal jobs only, newest finished first, created_at fallback" {
    const mk = struct {
        fn f(id: u64, step: Step, created: i64, finished: ?i64) JobView {
            return .{ .job = .{ .id = id, .group_id = id, .kind = .game, .game_thread_id = 0, .source_href = "x", .engine = .aria2_http, .step = step, .dest_dir = "", .created_at = created, .finished_at = finished } };
        }
    }.f;
    const jobs = [_]JobView{
        mk(1, .done, 10, 100),
        mk(2, .downloading, 20, null),
        mk(3, .failed, 30, 300),
        mk(4, .cancelled, 250, null), // no finish time: created_at 250
        mk(5, .seeding, 40, null),
    };
    const order = historyOrder(std.testing.allocator, &jobs);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3, 0 }, order);
}

fn downloadsSectionHeader(label_text: []const u8, count: u32, key: u8) void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = key,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 6, .w = 0, .h = 4 },
    });
    defer box.deinit();
    comp.sectionHeader(@src(), label_text, .{ .id_extra = key, .gravity_y = 0.5, .color_text = .{ .color = tokens.toDvui(tokens.active.acc, dvui.Color) } });
    _ = dvui.spacer(@src(), .{ .id_extra = key, .min_size_content = .{ .w = 8, .h = 1 } });
    var n_buf: [16]u8 = undefined;
    const n_s = std.fmt.bufPrint(&n_buf, "({d})", .{count}) catch "(?)";
    dvui.labelNoFmt(@src(), n_s, .{}, .{
        .id_extra = key,
        .gravity_y = 0.5,
        .color_text = .{ .color = style.labelDim() },
    });
}


fn closePaste(state: *types.State) void {
    state.dl_paste_job = null;
    @memset(&state.dl_paste_buf, 0);
}

/// One job waiting in the browser: title + host, the step line, the
/// "use this file?" prompt when the watched folder found a candidate, and
/// the ways to hand the file over (open the page again, paste the final
/// link, pick the file) or Cancel.
///
/// Only the first row carries test tags: dvui logs an error for a tag
/// used twice in one frame.
fn renderNeedsYouRow(frame: *Frame, v: *const JobView, title: []const u8, tagged: bool) RowAction {
    const job = &v.job;
    const tg = struct {
        fn f(on: bool, name: []const u8) ?[]const u8 {
            return if (on) name else null;
        }
    }.f;
    const state = frame.state;
    const t = tokens.active;
    var action: RowAction = .none;
    var row = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = job.id,
        .expand = .horizontal,
        .background = true,
        .border = style.border_thin,
        .corners = style.corner_radius,
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        .color_fill = .{ .color = style.cardFill() },
        .color_border = .{ .color = tokens.toDvui(t.acc_dim, dvui.Color) },
        .tag = tg(tagged, "dl-needs-you"),
    });
    defer row.deinit();

    // Header: status chip + host chip + title.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hdr.deinit();
        const spec = statusChipSpec(job.step, false);
        comp.chip(@src(), .{
            .label = spec.label,
            .fill = spec.color,
            .text = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
            .border = spec.color,
            .scale = 0.8,
        }, .{ .id_extra = job.id, .gravity_y = 0.5, .padding = .{ .x = 7, .y = 2, .w = 7, .h = 2 }, .corners = .all(3) });
        if (job.host.len > 0) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
            comp.chip(@src(), .{
                .label = job.host,
                .fill = t.bg2,
                .text = t.ink2,
                .border = t.line,
                .scale = 0.7,
            }, .{ .id_extra = job.id ^ 0x4057, .gravity_y = 0.5, .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 }, .corners = .all(3) });
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        const truncated = if (title.len > 80) title[0..80] else title;
        dvui.label(@src(), "{s}{s}", .{ truncated, if (title.len > 80) "…" else "" }, .{
            .gravity_y = 0.5,
            .color_text = .{ .color = tokens.toDvui(t.acc, dvui.Color) },
        });
    }

    if (job.step_detail.len > 0) {
        dvui.labelNoFmt(@src(), job.step_detail, .{}, .{ .color_text = .{ .color = style.labelDim() } });
    }

    // "Found <file> (<size>) — use it?"
    if (v.awaiting_prompt) |prompt| {
        var pr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .border = style.border_thin,
            .corners = .all(3),
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 2 },
            .color_fill = .{ .color = tokens.toDvui(t.bg2, dvui.Color) },
            .color_border = .{ .color = tokens.toDvui(t.acc, dvui.Color) },
        });
        defer pr.deinit();
        dvui.labelNoFmt(@src(), prompt, .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = tokens.toDvui(t.ink, dvui.Color) } });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "Yes", .{}, .{ .id_extra = job.id, .gravity_y = 0.5, .style = .highlight, .tag = tg(tagged, "dl-yes") })) {
            action = .{ .accept = .{ .id = job.id, .ok = true } };
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        if (style.button(@src(), "No", .{}, .{ .id_extra = job.id, .gravity_y = 0.5, .tag = tg(tagged, "dl-no") })) {
            action = .{ .accept = .{ .id = job.id, .ok = false } };
        }
    }

    // Ways to hand the file over.
    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 } });
        defer btns.deinit();
        if (style.button(@src(), "Open page again", .{}, .{ .id_extra = job.id, .tag = tg(tagged, "dl-open-again") })) {
            action = .{ .open_again = job.id };
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        if (style.button(@src(), "Paste link\u{2026}", .{}, .{ .id_extra = job.id, .tag = tg(tagged, "dl-paste") })) {
            action = .{ .paste_toggle = job.id };
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        if (style.button(@src(), "Pick file\u{2026}", .{}, .{ .id_extra = job.id, .tag = tg(tagged, "dl-pick") })) {
            action = .{ .pick = job.id };
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (style.button(@src(), "Cancel", .{}, .{ .id_extra = job.id, .style = .err, .tag = tg(tagged, "dl-needs-cancel") })) {
            action = .{ .cancel = job.id };
        }
    }

    // Inline paste entry (its own buffer, not the page's URL box).
    if (state.dl_paste_job == job.id) {
        var pe = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 } });
        defer pe.deinit();
        const te = style.textEntry(@src(), .{
            .text = .{ .buffer = &state.dl_paste_buf },
            .placeholder = "Paste the download link from your browser",
        }, .{ .id_extra = job.id, .expand = .horizontal, .tag = "dl-paste-entry" });
        const entered = te.enter_pressed;
        te.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        const ok = style.button(@src(), "OK", .{}, .{ .id_extra = job.id, .style = .highlight, .tag = "dl-paste-ok" });
        if (entered or ok) {
            const url = std.mem.trim(u8, state.dlPasteSlice(), " \t\r\n");
            if (url.len > 0) {
                if (dvui.currentWindow().arena().dupe(u8, url)) |copy| {
                    action = .{ .paste = .{ .id = job.id, .url = copy } };
                } else |_| {}
            }
        }
    }
    return action;
}

/// Look up the library row tied to this job's `game_thread_id` and
/// return its `Game.name`. Falls back to the job's own title, then to
/// its source label — manual URL pastes have id 0 and never match.
fn resolveJobTitle(games: []const library.Game, job: *const Job) []const u8 {
    if (job.game_thread_id != 0) {
        for (games) |*g| {
            if (g.f95_thread_id == job.game_thread_id) return g.name;
        }
    }
    if (job.title.len > 0) return job.title;
    return job.source_href;
}
