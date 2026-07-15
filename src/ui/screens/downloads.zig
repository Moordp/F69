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

const Frame = types.Frame;

/// Display label + chip color for a download job's status (Design B chips).
fn statusChipSpec(status: downloads.JobStatus, extracting: bool) struct { label: []const u8, color: tokens.Color } {
    if (extracting) return .{ .label = "Extracting", .color = .{ .r = 0xC0, .g = 0x84, .b = 0x1F, .a = 0xff } };
    return switch (status) {
        .queued => .{ .label = "Queued", .color = .{ .r = 0x55, .g = 0x6A, .b = 0x8A, .a = 0xff } },
        .fetching_metadata => .{ .label = "Metadata", .color = .{ .r = 0x55, .g = 0x6A, .b = 0x8A, .a = 0xff } },
        .downloading => .{ .label = "Downloading", .color = .{ .r = 0x1F, .g = 0x6A, .b = 0xA0, .a = 0xff } },
        .verifying => .{ .label = "Verifying", .color = .{ .r = 0x6A, .g = 0x4A, .b = 0xB0, .a = 0xff } },
        .extracting => .{ .label = "Extracting", .color = .{ .r = 0xC0, .g = 0x84, .b = 0x1F, .a = 0xff } },
        .applying => .{ .label = "Applying", .color = .{ .r = 0x2A, .g = 0x8A, .b = 0x82, .a = 0xff } },
        .seeding => .{ .label = "Seeding", .color = .{ .r = 0x2F, .g = 0x9E, .b = 0x4F, .a = 0xff } },
        .paused => .{ .label = "Paused", .color = .{ .r = 0x6F, .g = 0x6F, .b = 0x6F, .a = 0xff } },
        .done => .{ .label = "Done", .color = .{ .r = 0x2E, .g = 0x7D, .b = 0x32, .a = 0xff } },
        .failed => .{ .label = "Failed", .color = .{ .r = 0xB7, .g = 0x1C, .b = 0x1C, .a = 0xff } },
        .cancelled => .{ .label = "Cancelled", .color = .{ .r = 0x6F, .g = 0x6F, .b = 0x6F, .a = 0xff } },
    };
}

// ============================================================
//  downloads screen — paste-URL prototype + active jobs list
// ============================================================

/// Seed-ratio target the running aria2 daemon was configured with.
/// The UI's seed-ratio bar fills toward this number so the user sees
/// the finish line. Falls back to the daemon-wide default (5.0) when
/// the daemon hasn't been spawned yet (e.g. first frame of the app).
pub fn seedRatioTarget(frame: *Frame) f32 {
    if (frame.dl_mgr.daemon) |d| return d.seed_ratio;
    return 5.0;
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
        dvui.label(@src(), "Downloads & Seeding", .{}, .{ .gravity_y = 0.5, .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // Compute live totals across all jobs — gives the user a
        // single glanceable "what's happening" number even before
        // they scroll.
        var live = LiveTotals{};
        var it = frame.dl_mgr.jobs.iterator();
        while (it.next()) |entry| live.fold(entry.value_ptr.*);

        var dl_buf: [24]u8 = undefined;
        var up_buf: [24]u8 = undefined;
        var totals_buf: [192]u8 = undefined;
        const dl_s = components.humanRate(&dl_buf, live.dl_speed);
        const up_s = components.humanRate(&up_buf, live.up_speed);
        const totals_s = std.fmt.bufPrint(
            &totals_buf,
            "↓ {s}  ↑ {s}  · {d} dl · {d} seed · {d} done",
            .{ dl_s, up_s, live.n_downloading, live.n_seeding, live.n_done },
        ) catch "";
        dvui.labelNoFmt(@src(), totals_s, .{}, .{ .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        // Pause all / Resume all — global controls. The buttons are
        // greyed when there's nothing for them to act on (e.g.
        // "Resume all" with no paused jobs); we keep them rendered
        // so the row layout stays stable.
        const has_paused = frame.dl_mgr.anyPaused();
        const has_resumable = frame.dl_mgr.anyResumable();
        const pause_opts: dvui.Options = if (has_resumable)
            .{}
        else
            .{ .style = .control, .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 } };
        if (style.button(@src(), "Pause all", .{}, pause_opts) and has_resumable) {
            frame.dl_mgr.pauseAll();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        const resume_opts: dvui.Options = if (has_paused)
            .{ .style = .highlight }
        else
            .{ .style = .control, .color_text = .{ .r = 0x80, .g = 0x80, .b = 0x80 } };
        if (style.button(@src(), "Resume all", .{}, resume_opts) and has_paused) {
            frame.dl_mgr.resumeAll();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 } });
        if (style.button(@src(), "Clear completed", .{}, .{})) {
            _ = frame.dl_mgr.clearCompleted();
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
                _ = frame.dl_mgr.enqueueUrl(url, .game, 0, null, null, null, .{}) catch |e| {
                    std.log.scoped(.ui).warn("enqueue failed: {s}", .{@errorName(e)});
                };
                @memset(&state.dl_url_buf, 0);
            }
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });
    var dst_buf: [256]u8 = undefined;
    const dst_msg = std.fmt.bufPrint(&dst_buf, "Files land in {s}. Torrents seed to a {d:.1}× ratio.", .{
        frame.info.library_root, seedRatioTarget(frame),
    }) catch "Files land in the library root.";
    dvui.labelNoFmt(@src(), dst_msg, .{}, .{
        .color_text = style.labelDim(),
    });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 12 } });

    renderDownloadsBody(frame);
    return true;
}

/// The job-list body: three grouped sections (Downloading / Seeding /
/// Completed) + per-row actions, or an empty state. Shared by the
/// Downloads screen and the bottom Activity drawer (`renderActivityDrawer`).
pub fn renderDownloadsBody(frame: *Frame) void {
    if (frame.dl_mgr.jobCount() == 0) {
        components.emptyState(entypo.download, "No downloads yet", "Start one from a game's Download button, or paste a URL via + Add.");
        return;
    }

    var list = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer list.deinit();

    // Buttons inside the rows can't mutate the jobs map mid-iteration
    // (HashMap iterator gets invalidated). Collect the click + apply
    // after the loop.
    var pending: RowAction = .none;

    // Render in three sections. Per-section count is computed up
    // front so we can skip the header entirely for empty groups (a
    // lone "Seeding" header with nothing under it just adds noise).
    const groups = [_]struct { name: []const u8, group: JobGroup }{
        .{ .name = "Downloading", .group = .downloading },
        .{ .name = "Seeding", .group = .seeding },
        .{ .name = "Completed", .group = .done },
    };
    for (groups) |section| {
        var section_n: u32 = 0;
        var iter = frame.dl_mgr.jobs.iterator();
        while (iter.next()) |entry| {
            if (classifyJob(entry.value_ptr.*) == section.group) section_n += 1;
        }
        if (section_n == 0) continue;

        downloadsSectionHeader(section.name, section_n, @intFromEnum(section.group));
        var it = frame.dl_mgr.jobs.iterator();
        while (it.next()) |entry| {
            const job = entry.value_ptr.*;
            if (classifyJob(job) != section.group) continue;
            const title = resolveJobTitle(frame.games, job);
            // .done jobs that are mid-extract get a separate render
            // path so the user sees "[extracting]" instead of a stale
            // "done" pill on the row. The check is read-only and
            // O(active workers) — typically 0–2.
            const extracting = actions.isExtracting(frame, job.id);
            const is_donor = actions.isDonorJob(frame, job.id);
            const action = renderJobRow(job, title, extracting, seedRatioTarget(frame), is_donor);
            switch (action) {
                .none => {},
                else => pending = action,
            }
        }
    }

    switch (pending) {
        .none => {},
        .cancel => |id| frame.dl_mgr.cancel(id),
        .remove => |id| frame.dl_mgr.removeJob(id),
        .retry => |id| actions.retryDownload(frame, id),
        .pause => |id| frame.dl_mgr.pauseJob(id),
        .unpause => |id| frame.dl_mgr.resumeJob(id),
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
        .color_fill = tokens.toDvui(t.bg1, dvui.Color),
        .border = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
        .color_border = tokens.toDvui(t.acc_dim, dvui.Color),
    });
    defer fw.deinit();
    fw.dragAreaSet(.{}); // pinned — no drag/resize

    // header: Activity · spacer · Pause all · Clear finished · collapse
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 14, .y = 7, .w = 10, .h = 7 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .color_border = style.borderColor(),
        });
        defer hdr.deinit();
        const title = dvui.Font.theme(.title);
        dvui.labelNoFmt(@src(), "Activity", .{}, .{
            .gravity_y = 0.5,
            .color_text = tokens.toDvui(t.ink, dvui.Color),
            .font = title.withSize(title.size * 0.92),
        });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (frame.dl_mgr.anyResumable()) {
            if (style.button(@src(), "Pause all", .{}, .{ .gravity_y = 0.5 })) frame.dl_mgr.pauseAll();
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        }
        if (frame.dl_mgr.anyPaused()) {
            if (style.button(@src(), "Resume all", .{}, .{ .gravity_y = 0.5, .style = .highlight })) frame.dl_mgr.resumeAll();
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        }
        if (style.button(@src(), "Clear finished", .{}, .{ .gravity_y = 0.5 })) _ = frame.dl_mgr.clearCompleted();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6, .h = 1 } });
        if (components.iconOnly(@src(), "drawer-close", entypo.chevron_down, .{ .gravity_y = 0.5, .tag = "drawer-close" })) state.dock_expanded = false;
    }

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 6, .y = 4, .w = 6, .h = 6 } });
    defer body.deinit();
    renderDownloadsBody(frame);
}

const LiveTotals = struct {
    dl_speed: u64 = 0,
    up_speed: u64 = 0,
    n_downloading: u32 = 0,
    n_seeding: u32 = 0,
    n_done: u32 = 0,

    fn fold(self: *LiveTotals, j: downloads.Job) void {
        switch (classifyJob(j)) {
            .downloading => {
                self.n_downloading += 1;
                self.dl_speed += j.download_speed;
                self.up_speed += j.upload_speed;
            },
            .seeding => {
                self.n_seeding += 1;
                self.up_speed += j.upload_speed;
            },
            .done => self.n_done += 1,
        }
    }
};

/// 3-way bucket for the downloads-screen sections. `downloading`
/// includes anything still pulling bytes; `seeding` is post-payload
/// upload-only; `done` is everything terminal (success / failure /
/// cancel) plus pending HTTP jobs that complete fast enough we don't
/// want a separate "queued" header. Keep the int repr stable —
/// downloadsSectionHeader uses it as the dvui id_extra key.
const JobGroup = enum(u8) { downloading = 1, seeding = 2, done = 3 };

fn classifyJob(j: downloads.Job) JobGroup {
    return switch (j.status) {
        .seeding => .seeding,
        .done, .failed, .cancelled => .done,
        else => .downloading,
    };
}

fn downloadsSectionHeader(label_text: []const u8, count: u32, key: u8) void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = key,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 6, .w = 0, .h = 4 },
    });
    defer box.deinit();
    comp.sectionHeader(@src(), label_text, .{ .id_extra = key, .gravity_y = 0.5, .color_text = tokens.toDvui(tokens.active.acc, dvui.Color) });
    _ = dvui.spacer(@src(), .{ .id_extra = key, .min_size_content = .{ .w = 8, .h = 1 } });
    var n_buf: [16]u8 = undefined;
    const n_s = std.fmt.bufPrint(&n_buf, "({d})", .{count}) catch "(?)";
    dvui.labelNoFmt(@src(), n_s, .{}, .{
        .id_extra = key,
        .gravity_y = 0.5,
        .color_text = style.labelDim(),
    });
}

const RowAction = union(enum) { none, cancel: u64, remove: u64, retry: u64, pause: u64, unpause: u64 };

/// True iff this torrent's upload count has met the configured
/// seed-ratio target. Used to gate the "Remove" button — without
/// this you can stop seeding manually, which goes against the
/// "give back what you took" RPDL contract.
fn ratioMet(job: downloads.Job, ratio_target: f32) bool {
    if (!job.is_torrent) return true; // HTTP downloads have no obligation
    const total = job.bytes_total orelse return false;
    if (total == 0) return false;
    const target: u64 = @intFromFloat(@as(f64, @floatFromInt(total)) * ratio_target);
    return job.bytes_uploaded >= target;
}

/// Look up the library row tied to this job's `game_id` (an
/// `f95_thread_id`) and return its `Game.name`. Falls back to the
/// job's source label when the row isn't loaded — manual URL pastes
/// have `game_id = 0` and never match.
fn resolveJobTitle(games: []const library.Game, job: downloads.Job) []const u8 {
    if (job.game_id != 0) {
        for (games) |*g| {
            if (g.f95_thread_id == job.game_id) return g.name;
        }
    }
    return job.source_url;
}

fn renderJobRow(job: downloads.Job, title: []const u8, extracting: bool, ratio_target: f32, is_donor: bool) RowAction {
    var action: RowAction = .none;
    var row = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = job.id,
        .expand = .horizontal,
        .background = true,
        .border = style.border_thin,
        .corner_radius = style.corner_radius,
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        .color_fill = style.cardFill(),
        .color_border = style.borderColor(),
    });
    defer row.deinit();

    // Header line: status pill + game title + action button.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hdr.deinit();
        // Design B status chip — colored by job state.
        const spec = statusChipSpec(job.status, extracting);
        comp.chip(@src(), .{
            .label = spec.label,
            .fill = spec.color,
            .text = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
            .border = spec.color,
            .scale = 0.8,
        }, .{
            .id_extra = job.id,
            .gravity_y = 0.5,
            .padding = .{ .x = 7, .y = 2, .w = 7, .h = 2 },
            .corner_radius = .all(3),
        });
        if (job.is_torrent) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 4, .h = 1 } });
            const t = tokens.active;
            comp.chip(@src(), .{
                .label = "BT",
                .fill = t.bg2,
                .text = t.ink2,
                .border = t.line,
                .scale = 0.7,
            }, .{
                .id_extra = job.id ^ 0xB7,
                .gravity_y = 0.5,
                .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
                .corner_radius = .all(3),
            });
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        // Truncate so the row stays one line — game names can be very
        // long (e.g. light-novel-style titles).
        const truncated = if (title.len > 80) title[0..80] else title;
        dvui.label(@src(), "{s}{s}", .{ truncated, if (title.len > 80) "…" else "" }, .{
            .gravity_y = 0.5,
            .color_text = tokens.toDvui(tokens.active.acc, dvui.Color),
        });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // Per-row action policy:
        //   - Failed → Retry + Remove (the only place ✕ Remove
        //     appears on a job we ourselves consider unsuccessful).
        //   - Cancelled → Remove only.
        //   - Done (HTTP non-torrent) → Remove.
        //   - Done (torrent, ratio met) → Remove.
        //   - Done (torrent, still pre-target) → no button — aria2
        //     is still seeding for us.
        //   - Seeding → no button (cannot stop seeding manually
        //     unless the ratio target has been met).
        //   - Downloading donor DDL → Cancel allowed (URLs are
        //     plain HTTP, no community obligation).
        //   - Anything else mid-flight → no button.
        const ratio_met = ratioMet(job, ratio_target);
        const removable = switch (job.status) {
            .failed, .cancelled => true,
            .done => !job.is_torrent or ratio_met,
            .seeding => ratio_met,
            // Donor DDL has no community seeding obligation, so Remove
            // is always safe on those — and necessary, because a job
            // resumed from disk with an expired signed URL sits in
            // `.queued` / `.paused` forever and Cancel→Remove was a
            // two-step the user shouldn't have to discover.
            else => is_donor,
        };
        if (job.status == .failed) {
            if (components.iconButton(@src(), "Retry", entypo.cycle, .{ .id_extra = job.id, .style = .highlight })) {
                action = .{ .retry = job.id };
            }
        }
        // Pause / Resume an in-flight download. Seeding is intentionally NOT
        // pausable here (that would break the RPDL seed obligation — use the
        // ratio-gated "Stop seeding" below for that).
        switch (job.status) {
            .queued, .fetching_metadata, .downloading, .verifying => {
                if (components.iconButton(@src(), "Pause", entypo.controller_pause, .{ .id_extra = job.id })) {
                    action = .{ .pause = job.id };
                }
            },
            .paused => {
                if (components.iconButton(@src(), "Resume", entypo.controller_play, .{ .id_extra = job.id, .style = .highlight })) {
                    action = .{ .unpause = job.id };
                }
            },
            else => {},
        }
        // Cancel button for non-terminal donor jobs — still useful when
        // the user wants to stop a download mid-flight without dropping
        // the row. Coexists with the always-visible Remove (below) so
        // the user has both "stop, keep history" and "stop, forget it".
        if (is_donor) {
            switch (job.status) {
                .queued, .fetching_metadata, .downloading, .verifying, .paused => {
                    if (components.iconButton(@src(), "Cancel", entypo.cross, .{ .id_extra = job.id, .style = .err })) {
                        action = .{ .cancel = job.id };
                    }
                },
                else => {},
            }
        }
        if (removable) {
            if (components.iconButton(@src(), "Remove", entypo.trash, .{ .id_extra = job.id })) {
                action = .{ .remove = job.id };
            }
        } else if (job.is_torrent and (job.status == .seeding or job.status == .done)) {
            // Per-torrent seed control: stop seeding before the ratio target
            // is met. The default still seeds to ratio; this is the user's
            // explicit "I'm done giving back on this one" override.
            if (components.iconButton(@src(), "Stop seeding", entypo.cross, .{ .id_extra = job.id, .style = .err })) {
                action = .{ .remove = job.id };
            }
        }
    }

    // Source label subline — `rpdl:<id>` / pasted URL / etc. Skip
    // when the title fell back to the source (we'd be repeating it).
    if (!std.mem.eql(u8, title, job.source_url)) {
        const src_truncated = if (job.source_url.len > 96) job.source_url[0..96] else job.source_url;
        dvui.label(@src(), "{s}{s}", .{ src_truncated, if (job.source_url.len > 96) "…" else "" }, .{
            .color_text = .{ .r = 0x90, .g = 0x70, .b = 0x80 },
        });
    }

    // Download-progress bar — shown for jobs that haven't finished
    // pulling bytes yet. Seeding rows skip this since the payload is
    // already complete.
    if (job.status != .seeding) {
        renderProgressBar(.download, job, ratio_target);
    }

    // Seed-ratio bar — shown for torrents (any status). Lets the user
    // see how close we are to the 2.0× target both while leeching
    // (early progress) and while seeding (the finish line).
    if (job.is_torrent) {
        renderProgressBar(.ratio, job, ratio_target);
    }

    // Live counters line — peers, speeds, ETA. Compact, single line.
    {
        var info = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer info.deinit();
        var line_buf: [256]u8 = undefined;
        const line = composeStatsLine(&line_buf, job, ratio_target) catch "";
        if (line.len > 0) {
            dvui.labelNoFmt(@src(), line, .{}, .{
                .gravity_y = 0.5,
                .color_text = style.labelDim(),
            });
        }
    }

    if (job.error_msg) |em| {
        dvui.label(@src(), "error: {s}", .{em}, .{ .style = .err });
    }
    return action;
}

const BarKind = enum { download, ratio };

/// Render one labelled progress bar. `kind = .download` fills against
/// `bytes_done / bytes_total`; `kind = .ratio` fills against
/// `bytes_uploaded / (target * bytes_total)`.
///
/// Uses dvui's built-in `progress` widget so the fill follows the
/// parent's actual width (the prior hand-rolled bar fixed inner width
/// at `pct * 4px`, which capped visually at ~400px wide — so on a
/// wider Downloads pane the bar appeared to "stop at half" even when
/// the job was past 50%).
fn renderProgressBar(kind: BarKind, job: downloads.Job, ratio_target: f32) void {
    const total = job.bytes_total orelse 0;
    const frac: f32 = blk: switch (kind) {
        .download => {
            if (total == 0) break :blk 0.0;
            const done_f: f64 = @floatFromInt(job.bytes_done);
            const total_f: f64 = @floatFromInt(total);
            break :blk @floatCast(@min(done_f / total_f, 1.0));
        },
        .ratio => {
            if (total == 0) break :blk 0.0;
            const denom: f64 = @as(f64, @floatFromInt(total)) * ratio_target;
            if (denom == 0) break :blk 0.0;
            const up_f: f64 = @floatFromInt(job.bytes_uploaded);
            break :blk @floatCast(@min(up_f / denom, 1.0));
        },
    };

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = @intFromEnum(kind),
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
    });
    defer row.deinit();

    const tag_text: []const u8 = switch (kind) {
        .download => "DL ",
        .ratio => "UP ",
    };
    dvui.labelNoFmt(@src(), tag_text, .{}, .{
        .id_extra = @intFromEnum(kind),
        .min_size_content = .{ .w = 30, .h = 14 },
        .gravity_y = 0.5,
        .color_text = style.labelDim(),
    });

    const fill_color: dvui.Color = switch (kind) {
        .download => tokens.toDvui(tokens.active.acc, dvui.Color),
        .ratio => .{ .r = 0x6D, .g = 0xC0, .b = 0x8B }, // green — "giving back"
    };
    dvui.progress(@src(), .{ .percent = frac, .color = fill_color }, .{
        .id_extra = @intFromEnum(kind),
        .expand = .horizontal,
        .min_size_content = .{ .w = 1, .h = 10 },
        .gravity_y = 0.5,
        .border = style.border_thin,
        .corner_radius = .all(2),
        .color_border = style.borderColor(),
        .color_fill = .{ .r = 0x16, .g = 0x0B, .b = 0x10 },
        .padding = .all(0),
    });
}

/// Format a one-line stats summary for a job. Adapts to plain HTTP vs
/// torrent and to active vs idle.
fn composeStatsLine(buf: []u8, job: downloads.Job, ratio_target: f32) ![]const u8 {
    const total = job.bytes_total orelse 0;
    var dl_buf: [24]u8 = undefined;
    var up_buf: [24]u8 = undefined;
    var done_buf: [24]u8 = undefined;
    var total_buf: [24]u8 = undefined;
    var up_total_buf: [24]u8 = undefined;
    const dl_s = components.humanRate(&dl_buf, job.download_speed);
    const up_s = components.humanRate(&up_buf, job.upload_speed);
    const done_s = components.humanBytes(&done_buf, job.bytes_done);
    const total_s = if (total > 0) components.humanBytes(&total_buf, total) else "?";
    const up_total_s = components.humanBytes(&up_total_buf, job.bytes_uploaded);

    if (job.is_torrent) {
        const ratio: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(job.bytes_uploaded)) / @as(f32, @floatFromInt(total));
        if (job.status == .seeding) {
            // ETA to ratio target: remaining bytes / current up speed.
            const target_bytes: u64 = @intFromFloat(@as(f64, @floatFromInt(total)) * ratio_target);
            const remaining: u64 = if (job.bytes_uploaded >= target_bytes) 0 else target_bytes - job.bytes_uploaded;
            var eta_buf: [32]u8 = undefined;
            const eta_s: []const u8 = if (job.upload_speed > 0 and remaining > 0)
                humanEta(&eta_buf, remaining / @max(job.upload_speed, 1))
            else if (remaining == 0)
                "target reached"
            else
                "idle";
            return std.fmt.bufPrint(
                buf,
                "↑ {s} · uploaded {s} · ratio {d:.2}× / {d:.1}× · peers {d} · {s}",
                .{ up_s, up_total_s, ratio, ratio_target, job.connections, eta_s },
            );
        }
        return std.fmt.bufPrint(
            buf,
            "↓ {s}  ↑ {s} · {s} / {s} · ratio {d:.2}× · seeders {d}/{d}",
            .{ dl_s, up_s, done_s, total_s, ratio, job.num_seeders, job.connections },
        );
    }
    // Plain HTTP.
    const pct: u32 = if (total == 0) 0 else @intCast(@min(@divTrunc(job.bytes_done * 100, total), 100));
    if (total > 0) {
        return std.fmt.bufPrint(buf, "↓ {s} · {s} / {s} ({d}%)", .{ dl_s, done_s, total_s, pct });
    }
    return std.fmt.bufPrint(buf, "↓ {s} · {s}", .{ dl_s, done_s });
}

/// Format an ETA in seconds → "3m 42s" / "1h 7m" / "2d 14h".
fn humanEta(buf: []u8, seconds: u64) []const u8 {
    if (seconds < 60) return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "?";
    if (seconds < 3600) {
        const m = seconds / 60;
        const s = seconds % 60;
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ m, s }) catch "?";
    }
    if (seconds < 86400) {
        const h = seconds / 3600;
        const m = (seconds % 3600) / 60;
        return std.fmt.bufPrint(buf, "{d}h {d}m", .{ h, m }) catch "?";
    }
    const d = seconds / 86400;
    const h = (seconds % 86400) / 3600;
    return std.fmt.bufPrint(buf, "{d}d {d}h", .{ d, h }) catch "?";
}
