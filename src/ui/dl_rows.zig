// Download rows: the step trail (Resolve › Download › Verify › …) and the
// one-job row used by the Downloads page (`.full`) and the Activity drawer
// (`.compact`).

const std = @import("std");
const dvui = @import("dvui");
const tokens = @import("ui_tokens");
const entypo = dvui.entypo;
const downloads = @import("downloads");

const types = @import("types.zig");
const style = @import("style.zig");
const components = @import("components.zig");
const comp = @import("ui_comp");

const Frame = types.Frame;
const JobView = downloads.JobView;
const model = downloads.model;
const Job = model.Job;
const Step = model.Step;

pub const TrailChip = struct {
    label: []const u8,
    state: enum { done, current, future, failed },
};

const Stage = enum { resolve, peers, download, verify, extract, install, seed };

/// The chip that owns `step` (null for `done` / `cancelled`).
fn stageOf(engine: model.EngineKind, step: Step, fail: ?model.FailReason) ?Stage {
    return switch (step) {
        .queued, .resolving, .awaiting_user => .resolve,
        .fetching_metadata, .finding_peers => if (engine == .aria2_torrent) .peers else .resolve,
        .downloading, .paused => .download,
        .verifying => .verify,
        .extracting => .extract,
        .installing => .install,
        .seeding => .seed,
        .failed => switch (fail orelse .unknown) {
            .install_failed => .install,
            .checksum_mismatch => .verify,
            .bad_archive => .extract,
            else => .download,
        },
        .done, .cancelled => null,
    };
}

/// The step trail of a job: Resolve (Browser for browser jobs), Peers
/// (torrents), Download, Verify, Extract, Install, Seed (torrents), each
/// done / current / future, or failed for the step a failure belongs to.
pub fn trailFor(engine: model.EngineKind, step: Step, fail: ?model.FailReason, out: *[8]TrailChip) []const TrailChip {
    const torrent = engine == .aria2_torrent;
    const cur = stageOf(engine, step, fail);
    const order = [_]Stage{ .resolve, .peers, .download, .verify, .extract, .install, .seed };
    var n: usize = 0;
    for (order) |st| {
        if (st == .peers and !torrent) continue;
        if (st == .seed and !torrent) continue;
        const label: []const u8 = switch (st) {
            .resolve => if (engine == .browser) "Browser" else "Resolve",
            .peers => "Peers",
            .download => "Download",
            .verify => "Verify",
            .extract => "Extract",
            .install => "Install",
            .seed => "Seed",
        };
        const state: @TypeOf(out[0].state) = blk: {
            if (step == .cancelled) break :blk .future;
            const c = cur orelse break :blk .done; // done
            if (@intFromEnum(st) < @intFromEnum(c)) break :blk .done;
            if (st == c) break :blk if (step == .failed) .failed else .current;
            break :blk .future;
        };
        out[n] = .{ .label = label, .state = state };
        n += 1;
    }
    return out[0..n];
}

fn currentChip(trail: []const TrailChip) ?usize {
    for (trail, 0..) |c, i| {
        if (c.state == .current or c.state == .failed) return i;
    }
    return null;
}

fn trailChip(c: TrailChip, id: u64) void {
    const t = tokens.active;
    const white: tokens.Color = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff };
    const red: tokens.Color = .{ .r = 0xB7, .g = 0x1C, .b = 0x1C, .a = 0xff };
    const spec: comp.ChipSpec = switch (c.state) {
        .done => .{ .label = c.label, .fill = t.acc_dim, .text = white, .border = t.acc_dim, .scale = 0.8 },
        .current => .{ .label = c.label, .fill = t.acc, .text = white, .border = t.ink, .scale = 0.8 },
        .future => .{ .label = c.label, .fill = t.bg1, .text = t.ink2, .border = t.line, .scale = 0.8 },
        .failed => .{ .label = c.label, .fill = red, .text = white, .border = red, .scale = 0.8 },
    };
    comp.chip(@src(), spec, .{
        .id_extra = @intCast(id),
        .gravity_y = 0.5,
        .padding = .{ .x = 7, .y = 2, .w = 7, .h = 2 },
        .corners = .all(3),
    });
}

test "trailFor: http job at extracting → Resolve/Download/Verify done, Extract current, Install future; torrent includes Peers and Seed; failed at downloading marks Download failed; cancelled all future; browser label" {
    var buf: [8]TrailChip = undefined;
    const S = @TypeOf(buf[0].state);

    const http = trailFor(.aria2_http, .extracting, null, &buf);
    try std.testing.expectEqual(@as(usize, 5), http.len);
    const want_http = [_]struct { []const u8, S }{
        .{ "Resolve", .done }, .{ "Download", .done }, .{ "Verify", .done }, .{ "Extract", .current }, .{ "Install", .future },
    };
    for (want_http, http) |w, c| {
        try std.testing.expectEqualStrings(w[0], c.label);
        try std.testing.expectEqual(w[1], c.state);
    }

    const bt = trailFor(.aria2_torrent, .finding_peers, null, &buf);
    try std.testing.expectEqual(@as(usize, 7), bt.len);
    try std.testing.expectEqualStrings("Peers", bt[1].label);
    try std.testing.expectEqual(S.current, bt[1].state);
    try std.testing.expectEqual(S.done, bt[0].state);
    try std.testing.expectEqualStrings("Seed", bt[6].label);
    try std.testing.expectEqual(S.future, bt[6].state);
    const seeding = trailFor(.aria2_torrent, .seeding, null, &buf);
    try std.testing.expectEqual(S.done, seeding[5].state);
    try std.testing.expectEqual(S.current, seeding[6].state);

    const failed = trailFor(.aria2_http, .failed, .network, &buf);
    try std.testing.expectEqual(S.done, failed[0].state);
    try std.testing.expectEqualStrings("Download", failed[1].label);
    try std.testing.expectEqual(S.failed, failed[1].state);
    try std.testing.expectEqual(S.future, failed[2].state);
    const inst = trailFor(.aria2_http, .failed, .install_failed, &buf);
    try std.testing.expectEqual(S.failed, inst[4].state);

    for (trailFor(.aria2_torrent, .cancelled, .user_cancelled, &buf)) |c| try std.testing.expectEqual(S.future, c.state);
    for (trailFor(.aria2_http, .done, null, &buf)) |c| try std.testing.expectEqual(S.done, c.state);

    const br = trailFor(.browser, .awaiting_user, null, &buf);
    try std.testing.expectEqualStrings("Browser", br[0].label);
    try std.testing.expectEqual(S.current, br[0].state);
}

pub const RowMode = enum { full, compact };

pub const RowAction = union(enum) {
    none,
    cancel: u64,
    remove: u64,
    retry: u64,
    retry_install: u64,
    pause: u64,
    unpause: u64,
    stop_seeding: u64,
    /// `path` lives in the frame arena.
    open_folder: []const u8,
    // Needs you.
    open_again: u64,
    /// Open (or close) the "Paste link…" entry of this job.
    paste_toggle: u64,
    /// `url` lives in the frame arena.
    paste: struct { id: u64, url: []const u8 },
    pick: u64,
    accept: struct { id: u64, ok: bool },
};

/// Display label + chip color for a download job's step (Design B chips).
/// Labels come from `Step.label()`.
pub fn statusChipSpec(step: Step, extracting: bool) struct { label: []const u8, color: tokens.Color } {
    if (extracting) return .{ .label = Step.extracting.label(), .color = .{ .r = 0xC0, .g = 0x84, .b = 0x1F, .a = 0xff } };
    const color: tokens.Color = switch (step) {
        .queued, .resolving, .fetching_metadata, .finding_peers => .{ .r = 0x55, .g = 0x6A, .b = 0x8A, .a = 0xff },
        .awaiting_user => .{ .r = 0xC0, .g = 0x84, .b = 0x1F, .a = 0xff },
        .downloading => .{ .r = 0x1F, .g = 0x6A, .b = 0xA0, .a = 0xff },
        .verifying => .{ .r = 0x6A, .g = 0x4A, .b = 0xB0, .a = 0xff },
        .extracting => .{ .r = 0xC0, .g = 0x84, .b = 0x1F, .a = 0xff },
        .installing => .{ .r = 0x2A, .g = 0x8A, .b = 0x82, .a = 0xff },
        .seeding => .{ .r = 0x2F, .g = 0x9E, .b = 0x4F, .a = 0xff },
        .paused, .cancelled => .{ .r = 0x6F, .g = 0x6F, .b = 0x6F, .a = 0xff },
        .done => .{ .r = 0x2E, .g = 0x7D, .b = 0x32, .a = 0xff },
        .failed => .{ .r = 0xB7, .g = 0x1C, .b = 0x1C, .a = 0xff },
    };
    return .{ .label = step.label(), .color = color };
}

pub fn isTorrent(j: *const Job) bool {
    return j.engine == .aria2_torrent;
}

/// Retry for a failed job: an install failure installs again from the
/// file on disk; any other failure downloads again.
pub fn retryAction(job: *const Job) RowAction {
    return if (job.fail == .install_failed) .{ .retry_install = job.id } else .{ .retry = job.id };
}

test "retryAction: install failure re-installs, other failures re-download" {
    var j: Job = .{ .id = 7, .group_id = 7, .kind = .game, .game_thread_id = 1, .source_href = "x", .engine = .aria2_http, .step = .failed, .dest_dir = "" };
    j.fail = .install_failed;
    try std.testing.expectEqual(@as(u64, 7), retryAction(&j).retry_install);
    j.fail = .network;
    try std.testing.expectEqual(@as(u64, 7), retryAction(&j).retry);
}

/// True iff this torrent's upload count has met the configured
/// seed-ratio target. Used to gate the "Remove" button — without
/// this you can stop seeding manually, which goes against the
/// "give back what you took" RPDL contract.
pub fn ratioMet(job: *const Job, ratio_target: f32) bool {
    if (!isTorrent(job)) return true; // HTTP downloads have no obligation
    const total = job.bytes_total orelse return false;
    if (total == 0) return false;
    const target: u64 = @intFromFloat(@as(f64, @floatFromInt(total)) * ratio_target);
    return job.bytes_uploaded >= target;
}

/// `tagged` puts the test tags on this row and its buttons; dvui logs an
/// error for a tag used twice in one frame, so the caller sets it on the
/// first row of the page only.
pub fn renderJobRow(
    frame: *Frame,
    view: *const JobView,
    title: []const u8,
    extracting: bool,
    ratio_target: f32,
    is_donor: bool,
    mode: RowMode,
    tagged: bool,
) RowAction {
    _ = frame;
    const job = &view.job;
    const tg = struct {
        fn f(on: bool, name: []const u8) ?[]const u8 {
            return if (on) name else null;
        }
    }.f;
    var action: RowAction = .none;
    // An install worker still moving the file shows "Extracting" even
    // while the stored step says "installing".
    const shown_step: Step = if (extracting and job.step == .installing) .extracting else job.step;
    var trail_buf: [8]TrailChip = undefined;
    const trail = trailFor(job.engine, shown_step, job.fail, &trail_buf);
    var row = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = job.id,
        .expand = .horizontal,
        .background = true,
        .border = style.border_thin,
        .corners = style.corner_radius,
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        .color_fill = .{ .color = style.cardFill() },
        .color_border = .{ .color = style.borderColor() },
        .tag = tg(tagged, "dl-job-row"),
    });
    defer row.deinit();

    // Header line: status pill + game title + action button.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hdr.deinit();
        // Compact rows show only the current (or failed) step chip; steps
        // with no chip of their own (paused, done, cancelled) keep the
        // coloured status chip.
        const own_chip: ?usize = if (mode == .compact and job.step != .paused) currentChip(trail) else null;
        if (own_chip) |ci| {
            trailChip(trail[ci], job.id ^ @as(u64, @intCast(ci + 1)));
        } else {
            const spec = statusChipSpec(job.step, extracting);
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
                .corners = .all(3),
            });
        }
        if (isTorrent(job)) {
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
                .corners = .all(3),
            });
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 1 } });
        // Truncate so the row stays one line — game names can be very
        // long (e.g. light-novel-style titles).
        const truncated = if (title.len > 80) title[0..80] else title;
        dvui.label(@src(), "{s}{s}", .{ truncated, if (title.len > 80) "…" else "" }, .{
            .gravity_y = 0.5,
            .color_text = .{ .color = tokens.toDvui(tokens.active.acc, dvui.Color) },
        });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // Per-row action policy:
        //   - Failed → Retry + Remove.
        //   - Cancelled / Done → Remove (a done torrent is no longer
        //     seeding).
        //   - Seeding, ratio met → Remove; before that → Stop seeding.
        //   - Downloading donor DDL → Cancel + Remove allowed (plain
        //     HTTP, no community obligation).
        //   - Anything else mid-flight → no button.
        const ratio_met = ratioMet(job, ratio_target);
        const removable = switch (job.step) {
            .failed, .cancelled, .done => true,
            .seeding => ratio_met,
            // Donor DDL has no community seeding obligation, so Remove
            // is always safe on those — and necessary, because a job
            // resumed from disk with an expired signed URL sits in
            // `.queued` / `.paused` forever and Cancel→Remove was a
            // two-step the user shouldn't have to discover.
            else => is_donor,
        };
        if (job.step == .failed) {
            if (components.iconButton(@src(), "Retry", entypo.cycle, .{ .id_extra = job.id, .tag = tg(tagged, "dl-retry"), .style = .highlight })) {
                action = retryAction(job);
            }
        }
        // Pause / Resume an in-flight download. Seeding is intentionally NOT
        // pausable here (that would break the RPDL seed obligation — use the
        // ratio-gated "Stop seeding" below for that).
        switch (job.step) {
            .fetching_metadata, .finding_peers, .downloading => {
                if (components.iconButton(@src(), "Pause", entypo.controller_pause, .{ .id_extra = job.id, .tag = tg(tagged, "dl-pause") })) {
                    action = .{ .pause = job.id };
                }
            },
            .paused => {
                if (components.iconButton(@src(), "Resume", entypo.controller_play, .{ .id_extra = job.id, .tag = tg(tagged, "dl-resume"), .style = .highlight })) {
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
            switch (job.step) {
                .queued, .resolving, .fetching_metadata, .finding_peers, .downloading, .paused => {
                    if (components.iconButton(@src(), "Cancel", entypo.cross, .{ .id_extra = job.id, .tag = tg(tagged, "dl-cancel"), .style = .err })) {
                        action = .{ .cancel = job.id };
                    }
                },
                else => {},
            }
        }
        if (job.dest_dir.len > 0 and (!job.step.isTerminal() or job.step == .done)) {
            if (components.iconButton(@src(), "Open folder", entypo.folder, .{ .id_extra = job.id, .tag = tg(tagged, "dl-open-folder") })) {
                // Copied: the snapshot pointer must not outlive the frame.
                const path = dvui.currentWindow().arena().dupe(u8, job.dest_dir) catch "";
                if (path.len > 0) action = .{ .open_folder = path };
            }
        }
        if (removable) {
            if (components.iconButton(@src(), "Remove", entypo.trash, .{ .id_extra = job.id, .tag = tg(tagged, "dl-remove") })) {
                action = .{ .remove = job.id };
            }
        } else if (job.step == .seeding) {
            // Per-torrent seed control: stop seeding before the ratio target
            // is met. The default still seeds to ratio; this is the user's
            // explicit "I'm done giving back on this one" override.
            if (components.iconButton(@src(), "Stop seeding", entypo.cross, .{ .id_extra = job.id, .tag = tg(tagged, "dl-stop-seeding"), .style = .err })) {
                action = .{ .stop_seeding = job.id };
            }
        }
    }

    // Full rows: the whole step trail on one line.
    if (mode == .full and trail.len > 0) {
        var tl = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 } });
        defer tl.deinit();
        for (trail, 0..) |c, i| {
            if (i > 0) {
                dvui.labelNoFmt(@src(), "\u{203A}", .{}, .{
                    .id_extra = @intCast(i),
                    .gravity_y = 0.5,
                    .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
                    .color_text = .{ .color = style.labelDim() },
                });
            }
            trailChip(c, job.id ^ @as(u64, @intCast(i + 1)));
        }
    }

    // Source label subline — `rpdl:<id>` / pasted URL / etc. Skip
    // when the title fell back to the source (we'd be repeating it).
    if (!std.mem.eql(u8, title, job.source_href)) {
        const src_truncated = if (job.source_href.len > 96) job.source_href[0..96] else job.source_href;
        dvui.label(@src(), "{s}{s}", .{ src_truncated, if (job.source_href.len > 96) "…" else "" }, .{
            .color_text = .{ .color = .{ .r = 0x90, .g = 0x70, .b = 0x80 } },
        });
    }

    // Download-progress bar — shown for jobs that haven't finished
    // pulling bytes yet. Seeding rows skip this since the payload is
    // already complete.
    if (job.step != .seeding) {
        renderProgressBar(.download, job, ratio_target);
    }

    // Seed-ratio bar — shown for torrents (any status). Lets the user
    // see how close we are to the 2.0× target both while leeching
    // (early progress) and while seeding (the finish line).
    if (isTorrent(job)) {
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
                .color_text = .{ .color = style.labelDim() },
            });
        }
    }

    // The step's own line ("0 seeders, retrying in 30 s", "Not an archive
    // — will install as a file", the failure message …).
    if (job.step == .failed) {
        const em = if (job.fail_msg.len > 0) job.fail_msg else if (job.fail) |f| @tagName(f) else "unknown error";
        dvui.label(@src(), "error: {s}", .{em}, .{ .style = .err });
    } else if (job.step_detail.len > 0) {
        dvui.labelNoFmt(@src(), job.step_detail, .{}, .{ .color_text = .{ .color = style.labelDim() } });
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
fn renderProgressBar(kind: BarKind, job: *const Job, ratio_target: f32) void {
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
        .color_text = .{ .color = style.labelDim() },
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
        .corners = .all(2),
        .color_border = .{ .color = style.borderColor() },
        .color_fill = .{ .color = .{ .r = 0x16, .g = 0x0B, .b = 0x10 } },
        .padding = .all(0),
    });
}

/// Format a one-line stats summary for a job. Adapts to plain HTTP vs
/// torrent and to active vs idle.
fn composeStatsLine(buf: []u8, job: *const Job, ratio_target: f32) ![]const u8 {
    const total = job.bytes_total orelse 0;
    var dl_buf: [24]u8 = undefined;
    var up_buf: [24]u8 = undefined;
    var done_buf: [24]u8 = undefined;
    var total_buf: [24]u8 = undefined;
    var up_total_buf: [24]u8 = undefined;
    const dl_s = components.humanRate(&dl_buf, job.dl_speed);
    const up_s = components.humanRate(&up_buf, job.ul_speed);
    const done_s = components.humanBytes(&done_buf, job.bytes_done);
    const total_s = if (total > 0) components.humanBytes(&total_buf, total) else "?";
    const up_total_s = components.humanBytes(&up_total_buf, job.bytes_uploaded);

    if (isTorrent(job)) {
        const ratio: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(job.bytes_uploaded)) / @as(f32, @floatFromInt(total));
        if (job.step == .seeding) {
            // ETA to ratio target: remaining bytes / current up speed.
            const target_bytes: u64 = @intFromFloat(@as(f64, @floatFromInt(total)) * ratio_target);
            const remaining: u64 = if (job.bytes_uploaded >= target_bytes) 0 else target_bytes - job.bytes_uploaded;
            var eta_buf: [32]u8 = undefined;
            const eta_s: []const u8 = if (job.ul_speed > 0 and remaining > 0)
                humanEta(&eta_buf, remaining / @max(job.ul_speed, 1))
            else if (remaining == 0)
                "target reached"
            else
                "idle";
            return std.fmt.bufPrint(
                buf,
                "↑ {s} · uploaded {s} · ratio {d:.2}× / {d:.1}× · peers {d} · {s}",
                .{ up_s, up_total_s, ratio, ratio_target, job.peers, eta_s },
            );
        }
        return std.fmt.bufPrint(
            buf,
            "↓ {s}  ↑ {s} · {s} / {s} · ratio {d:.2}× · seeders {d}/{d}",
            .{ dl_s, up_s, done_s, total_s, ratio, job.seeders, job.peers },
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
