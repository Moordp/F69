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

/// `full`: the page (whole step trail). `compact`: the drawer (current
/// step chip only). `history`: a terminal job in the History section —
/// compact header, no bars or stats, and the history line (host · engine ·
/// size · duration · fail reason) instead of the step line.
pub const RowMode = enum { full, compact, history };

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

/// What the UI-side install worker of a job is doing right now (the
/// downloader hands the file over for the Install step). `files` = the
/// counts are files applied (a mod), else bytes moved.
pub const LiveInstall = struct {
    running: bool = false,
    done: u64 = 0,
    total: u64 = 0,
    files: bool = false,
};

/// One measured bar: `done / total` with a short label.
pub const BarSpec = struct {
    label: []const u8,
    done: u64,
    total: u64,
    files: bool = false,

    pub fn frac(self: BarSpec) f32 {
        if (self.total == 0) return 0;
        const d: f64 = @floatFromInt(self.done);
        const t: f64 = @floatFromInt(self.total);
        return @floatCast(@min(d / t, 1.0));
    }

    pub fn pct(self: BarSpec) u8 {
        return downloads.progress.percent(self.done, self.total);
    }
};

/// The measured bar of the job's current step, or null when the step
/// has nothing to measure yet (then `isBusy` decides whether a sweep
/// shows instead).
pub fn stepBar(job: *const Job, live: LiveInstall) ?BarSpec {
    return switch (job.step) {
        .downloading, .paused, .fetching_metadata, .finding_peers => blk: {
            const total = job.bytes_total orelse 0;
            if (total == 0) break :blk null;
            break :blk .{ .label = "Download", .done = job.bytes_done, .total = total };
        },
        .verifying => if (job.step_total > 0) .{ .label = "Verify", .done = job.step_done, .total = job.step_total } else null,
        .extracting => if (job.step_total > 0) .{ .label = "Extract", .done = job.step_done, .total = job.step_total } else null,
        .installing => if (live.running and live.total > 0) .{
            .label = if (live.files) "Apply" else "Install",
            .done = live.done,
            .total = live.total,
            .files = live.files,
        } else null,
        .queued, .resolving, .awaiting_user, .seeding, .done, .failed, .cancelled => null,
    };
}

/// A step that is working with nothing to measure: shows the sweep bar.
pub fn isBusy(step: Step) bool {
    return switch (step) {
        .queued, .resolving, .awaiting_user, .fetching_metadata, .finding_peers, .downloading, .verifying, .extracting, .installing => true,
        .paused, .seeding, .done, .failed, .cancelled => false,
    };
}

/// Seconds since `since` (0 when unknown or in the future).
pub fn elapsedSeconds(now: i64, since: i64) u64 {
    if (since <= 0 or now < since) return 0;
    return @intCast(now - since);
}

test "stepBar: download needs a size; verify/extract use the step counters; install uses the live worker; busy steps sweep" {
    var j: Job = .{ .id = 1, .group_id = 1, .kind = .game, .game_thread_id = 0, .source_href = "x", .engine = .aria2_http, .step = .downloading, .dest_dir = "" };
    try std.testing.expect(stepBar(&j, .{}) == null);
    try std.testing.expect(isBusy(j.step));
    j.bytes_total = 200;
    j.bytes_done = 50;
    const dl = stepBar(&j, .{}).?;
    try std.testing.expectEqualStrings("Download", dl.label);
    try std.testing.expectEqual(@as(u8, 25), dl.pct());
    try std.testing.expectEqual(@as(f32, 0.25), dl.frac());

    j.step = .verifying;
    try std.testing.expect(stepBar(&j, .{}) == null);
    j.step_done = 30;
    j.step_total = 40;
    try std.testing.expectEqualStrings("Verify", stepBar(&j, .{}).?.label);
    try std.testing.expectEqual(@as(u8, 75), stepBar(&j, .{}).?.pct());
    j.step = .extracting;
    try std.testing.expectEqualStrings("Extract", stepBar(&j, .{}).?.label);

    j.step = .installing;
    try std.testing.expect(stepBar(&j, .{}) == null);
    try std.testing.expectEqualStrings("Install", stepBar(&j, .{ .running = true, .done = 1, .total = 4 }).?.label);
    const ap = stepBar(&j, .{ .running = true, .done = 48, .total = 212, .files = true }).?;
    try std.testing.expectEqualStrings("Apply", ap.label);
    try std.testing.expect(ap.files);

    j.step = .paused;
    try std.testing.expect(!isBusy(j.step));
    try std.testing.expectEqualStrings("Download", stepBar(&j, .{}).?.label);
    j.step = .queued;
    try std.testing.expect(stepBar(&j, .{}) == null);
    try std.testing.expect(isBusy(j.step));
    j.step = .done;
    try std.testing.expect(!isBusy(j.step));

    try std.testing.expectEqual(@as(u64, 0), elapsedSeconds(100, 0));
    try std.testing.expectEqual(@as(u64, 0), elapsedSeconds(100, 200));
    try std.testing.expectEqual(@as(u64, 42), elapsedSeconds(142, 100));
}

/// Display label + chip color for a download job's step (Design B chips).
/// Labels come from `Step.label()`.
pub fn statusChipSpec(step: Step) struct { label: []const u8, color: tokens.Color } {
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
/// Cancel is offered for every job that is still running, except a
/// seeding torrent (Stop seeding / Remove cover that one).
pub fn showsCancel(step: Step) bool {
    return !step.isTerminal() and step != .seeding;
}

test "showsCancel: every running step but seeding; never a finished row" {
    for (std.enums.values(Step)) |st| {
        const want = switch (st) {
            .seeding, .done, .failed, .cancelled => false,
            else => true,
        };
        try std.testing.expectEqual(want, showsCancel(st));
    }
}

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
    live: LiveInstall,
    ratio_target: f32,
    mode: RowMode,
    tagged: bool,
) RowAction {
    const job = &view.job;
    const tg = struct {
        fn f(on: bool, name: []const u8) ?[]const u8 {
            return if (on) name else null;
        }
    }.f;
    var action: RowAction = .none;
    const now = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();
    const bar = stepBar(job, live);
    var trail_buf: [8]TrailChip = undefined;
    const trail = trailFor(job.engine, job.step, job.fail, &trail_buf);
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
        const own_chip: ?usize = if (mode != .full and job.step != .paused) currentChip(trail) else null;
        if (own_chip) |ci| {
            // The drawer chip carries the percentage: "Extract 52%".
            var chip = trail[ci];
            var lbl_buf: [32]u8 = undefined;
            if (bar) |b| {
                if (b.total > 0 and chip.state == .current) {
                    chip.label = std.fmt.bufPrint(&lbl_buf, "{s} {d}%", .{ chip.label, b.pct() }) catch chip.label;
                }
            }
            trailChip(chip, job.id ^ @as(u64, @intCast(ci + 1)));
        } else {
            const spec = statusChipSpec(job.step);
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
        //   - Anything else still running (queued … installing, any
        //     engine) → Cancel; Remove once it is cancelled.
        const ratio_met = ratioMet(job, ratio_target);
        const removable = switch (job.step) {
            .failed, .cancelled, .done => true,
            .seeding => ratio_met,
            else => false,
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
        // Cancel every job that is still running, except a seeding
        // torrent (that one has the ratio-gated Stop seeding below).
        if (showsCancel(job.step)) {
            if (components.iconButton(@src(), "Cancel", entypo.cross, .{ .id_extra = job.id, .tag = tg(tagged, "dl-cancel"), .style = .err })) {
                action = .{ .cancel = job.id };
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

    // History rows: one meta line, then done.
    if (mode == .history) {
        renderHistoryLine(job, tagged, now);
        return action;
    }

    // The current step's bar: measured when the step has a total
    // (download, verify, extract, install), a sweep while it is working
    // on something that has no measure (resolving, finding peers, …).
    // Seeding rows skip it: the payload is complete.
    if (bar) |b| {
        renderBar(b.label, b.frac(), stepFill(job.step), job.id);
    } else if (isBusy(job.step)) {
        renderSweep(frame.io, job.step, job.id);
    }

    // Seed-ratio bar — shown for torrents (any status). Lets the user
    // see how close we are to the ratio target both while leeching
    // (early progress) and while seeding (the finish line).
    if (isTorrent(job)) {
        const total = job.bytes_total orelse 0;
        const denom: f64 = @as(f64, @floatFromInt(total)) * ratio_target;
        const frac: f32 = if (denom == 0) 0 else @floatCast(@min(@as(f64, @floatFromInt(job.bytes_uploaded)) / denom, 1.0));
        renderBar("Seed", frac, .{ .r = 0x6D, .g = 0xC0, .b = 0x8B }, job.id ^ 0x5EED);
    }

    // Live counters line — what the step is doing, how far, how long.
    {
        var info = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer info.deinit();
        var line_buf: [256]u8 = undefined;
        const line = composeStatsLine(&line_buf, job, bar, ratio_target, now) catch "";
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

/// "host · engine · size · duration" + " · " + the fail reason, the
/// reason in its own label (tag `dl-history-reason` on the tagged row).
fn renderHistoryLine(job: *const Job, tagged: bool, now: i64) void {
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer line.deinit();
    var meta_buf: [192]u8 = undefined;
    dvui.labelNoFmt(@src(), historyMeta(&meta_buf, job), .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = style.labelDim() } });
    if (failReasonText(job)) |reason| {
        dvui.labelNoFmt(@src(), " \u{00B7} ", .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = style.labelDim() } });
        dvui.labelNoFmt(@src(), reason, .{}, .{ .gravity_y = 0.5, .style = .err, .tag = if (tagged) "dl-history-reason" else null });
    }
    // An automatic retry is pending: count it down live.
    var retry_buf: [48]u8 = undefined;
    if (retryCountdown(&retry_buf, job, now)) |txt| {
        dvui.labelNoFmt(@src(), " \u{00B7} ", .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = style.labelDim() } });
        dvui.labelNoFmt(@src(), txt, .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = tokens.toDvui(tokens.active.acc, dvui.Color) } });
    }
}

/// "retrying in 23 s" / "retrying now" for a failed job with an automatic
/// retry pending; null otherwise.
pub fn retryCountdown(buf: []u8, job: *const Job, now: i64) ?[]const u8 {
    if (job.step != .failed) return null;
    const at = job.next_retry_at orelse return null;
    if (at <= now) return "retrying now";
    var e_buf: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "retrying in {s}", .{components.humanElapsed(&e_buf, @intCast(at - now))}) catch null;
}

test "retryCountdown: only failed jobs with a retry pending" {
    var j: Job = .{ .id = 1, .group_id = 1, .kind = .game, .game_thread_id = 0, .source_href = "x", .engine = .aria2_http, .step = .failed, .dest_dir = "" };
    var buf: [48]u8 = undefined;
    try std.testing.expect(retryCountdown(&buf, &j, 100) == null);
    j.next_retry_at = 123;
    try std.testing.expectEqualStrings("retrying in 23 s", retryCountdown(&buf, &j, 100).?);
    try std.testing.expectEqualStrings("retrying now", retryCountdown(&buf, &j, 130).?);
    j.step = .done;
    try std.testing.expect(retryCountdown(&buf, &j, 100) == null);
}

/// Short label of the engine that ran a job.
pub fn engineLabel(e: model.EngineKind) []const u8 {
    return switch (e) {
        .aria2_http => "Direct",
        .aria2_torrent => "Torrent",
        .megacmd => "MEGA",
        .browser => "Browser",
    };
}

/// Plain text for a failure reason without a message of its own.
pub fn failLabel(f: model.FailReason) []const u8 {
    return switch (f) {
        .network => "Network error",
        .host_gone => "The file is gone from the host",
        .auth_required => "Sign-in needed",
        .captcha => "Captcha needed",
        .quota_exceeded => "Transfer quota exceeded",
        .no_peers => "No peers",
        .checksum_mismatch => "Checksum mismatch",
        .bad_archive => "Broken archive",
        .disk_full => "Disk full",
        .engine_missing => "Download engine missing",
        .user_cancelled => "Cancelled",
        .install_failed => "Install failed",
        .unknown => "Unknown error",
    };
}

/// The reason a failed job shows in History: its `fail_msg`, else the
/// label of `fail`. Null for jobs that did not fail.
pub fn failReasonText(job: *const Job) ?[]const u8 {
    if (job.step != .failed) return null;
    if (job.fail_msg.len > 0) return job.fail_msg;
    return failLabel(job.fail orelse .unknown);
}

/// "host · engine · size · duration"; size and duration are "–" when
/// unknown. Duration = finished_at − created_at.
pub fn historyMeta(buf: []u8, job: *const Job) []const u8 {
    var size_buf: [24]u8 = undefined;
    const size_s: []const u8 = if (job.bytes_total) |t| components.humanBytes(&size_buf, t) else "\u{2013}";
    var dur_buf: [32]u8 = undefined;
    const dur_s: []const u8 = blk: {
        const fin = job.finished_at orelse break :blk "\u{2013}";
        if (job.created_at <= 0 or fin < job.created_at) break :blk "\u{2013}";
        break :blk humanEta(&dur_buf, @intCast(fin - job.created_at));
    };
    const host: []const u8 = if (job.host.len > 0) job.host else "\u{2013}";
    return std.fmt.bufPrint(buf, "{s} \u{00B7} {s} \u{00B7} {s} \u{00B7} {s}", .{ host, engineLabel(job.engine), size_s, dur_s }) catch host;
}

test "history line: meta parts, duration, and the fail reason (message first, then label)" {
    var j: Job = .{ .id = 1, .group_id = 1, .kind = .game, .game_thread_id = 0, .source_href = "x", .engine = .megacmd, .step = .failed, .dest_dir = "", .host = "MEGA" };
    j.bytes_total = 2048;
    j.created_at = 1000;
    j.finished_at = 1000 + 3 * 60 + 12;
    var buf: [192]u8 = undefined;
    try std.testing.expectEqualStrings("MEGA \u{00B7} MEGA \u{00B7} 2.0 KB \u{00B7} 3m 12s", historyMeta(&buf, &j));
    j.fail = .quota_exceeded;
    try std.testing.expectEqualStrings("Transfer quota exceeded", failReasonText(&j).?);
    j.fail_msg = "MEGA transfer quota exceeded \u{2014} wait 2 hours";
    try std.testing.expectEqualStrings(j.fail_msg, failReasonText(&j).?);

    // Unknown size / no finish time / no host → dashes; done has no reason.
    j.bytes_total = null;
    j.finished_at = null;
    j.host = "";
    j.engine = .aria2_torrent;
    j.step = .done;
    try std.testing.expectEqualStrings("\u{2013} \u{00B7} Torrent \u{00B7} \u{2013} \u{00B7} \u{2013}", historyMeta(&buf, &j));
    try std.testing.expect(failReasonText(&j) == null);
}

/// Fill colour of a step's bar (matches its status chip).
fn stepFill(step: Step) dvui.Color {
    return tokens.toDvui(statusChipSpec(step).color, dvui.Color);
}

const BAR_LABEL_W: f32 = 58;

/// One labelled bar: `label` on the left, the fill on the right. Uses
/// dvui's `progress` so the fill follows the parent's actual width.
pub fn renderBar(label: []const u8, frac: f32, fill: dvui.Color, id: u64) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = @intCast(id),
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
    });
    defer row.deinit();
    dvui.labelNoFmt(@src(), label, .{}, .{
        .id_extra = @intCast(id),
        .min_size_content = .{ .w = BAR_LABEL_W, .h = 14 },
        .gravity_y = 0.5,
        .color_text = .{ .color = style.labelDim() },
    });
    dvui.progress(@src(), .{ .percent = frac, .color = fill }, .{
        .id_extra = @intCast(id),
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

/// The busy bar of a step with nothing to measure: the step's trail
/// label on the left, a sweep on the right.
fn renderSweep(io: std.Io, step: Step, id: u64) void {
    renderSweepBar(io, busyLabel(step), stepFill(step), id);
}

/// A labelled sweep ("busy") bar in the same slot as `renderBar`.
pub fn renderSweepBar(io: std.Io, label: []const u8, fill: dvui.Color, id: u64) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = @intCast(id),
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
    });
    defer row.deinit();
    dvui.labelNoFmt(@src(), label, .{}, .{
        .id_extra = @intCast(id),
        .min_size_content = .{ .w = BAR_LABEL_W, .h = 14 },
        .gravity_y = 0.5,
        .color_text = .{ .color = style.labelDim() },
    });
    components.sweepBar(@src(), io, id, fill, .{ .expand = .horizontal, .gravity_y = 0.5 });
}

/// Short bar label of a busy step.
fn busyLabel(step: Step) []const u8 {
    return switch (step) {
        .queued => "Queued",
        .resolving => "Resolve",
        .awaiting_user => "Browser",
        .fetching_metadata => "Metadata",
        .finding_peers => "Peers",
        .downloading => "Download",
        .verifying => "Verify",
        .extracting => "Extract",
        .installing => "Install",
        else => "",
    };
}

/// Format a one-line stats summary for a job. Adapts to the step: bytes
/// and speed while downloading, "done / total (pct) · elapsed" for the
/// post-transfer steps, "step · elapsed" while waiting on something.
fn composeStatsLine(buf: []u8, job: *const Job, bar: ?BarSpec, ratio_target: f32, now: i64) ![]const u8 {
    const total = job.bytes_total orelse 0;
    var dl_buf: [24]u8 = undefined;
    var up_buf: [24]u8 = undefined;
    var done_buf: [24]u8 = undefined;
    var total_buf: [24]u8 = undefined;
    var up_total_buf: [24]u8 = undefined;
    var el_buf: [24]u8 = undefined;
    const dl_s = components.humanRate(&dl_buf, job.dl_speed);
    const up_s = components.humanRate(&up_buf, job.ul_speed);
    const done_s = components.humanBytes(&done_buf, job.bytes_done);
    const total_s = if (total > 0) components.humanBytes(&total_buf, total) else "?";
    const up_total_s = components.humanBytes(&up_total_buf, job.bytes_uploaded);
    const elapsed = components.humanElapsed(&el_buf, elapsedSeconds(now, job.step_since));

    // Post-transfer steps: what, how far, how long.
    switch (job.step) {
        .verifying, .extracting, .installing => {
            const verb: []const u8 = switch (job.step) {
                .verifying => "Checking the file",
                .extracting => "Extracting",
                else => if (bar != null and bar.?.files) "Applying the mod" else "Moving into the library",
            };
            if (bar) |b| {
                if (b.files) return std.fmt.bufPrint(buf, "{s} \u{00B7} file {d} / {d} ({d}%) \u{00B7} {s}", .{ verb, b.done, b.total, b.pct(), elapsed });
                var bd: [24]u8 = undefined;
                var bt: [24]u8 = undefined;
                return std.fmt.bufPrint(buf, "{s} \u{00B7} {s} / {s} ({d}%) \u{00B7} {s}", .{ verb, components.humanBytes(&bd, b.done), components.humanBytes(&bt, b.total), b.pct(), elapsed });
            }
            return std.fmt.bufPrint(buf, "{s} \u{00B7} {s}", .{ verb, elapsed });
        },
        .queued, .resolving, .awaiting_user => return std.fmt.bufPrint(buf, "{s} \u{00B7} {s}", .{ job.step.label(), elapsed }),
        .fetching_metadata, .finding_peers => {
            if (isTorrent(job)) return std.fmt.bufPrint(buf, "{s} \u{00B7} seeders {d}/{d} \u{00B7} {s}", .{ job.step.label(), job.seeders, job.peers, elapsed });
            return std.fmt.bufPrint(buf, "{s} \u{00B7} {s}", .{ job.step.label(), elapsed });
        },
        else => {},
    }

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
