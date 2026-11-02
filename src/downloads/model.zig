//! Downloader v2 job model and its pure state machine.
//!
//! `advance` maps (job, input) to a `Transition`. It does no I/O, takes no
//! locks and allocates nothing, so every edge is unit-testable. The
//! downloader thread applies the returned transition and performs the
//! `side_effect`. Spec: docs/superpowers/specs/2026-11-02-downloader-v2-design.md §3.2.

const std = @import("std");
const testing = std.testing;

/// Where a job is in its life. Terminal steps are `done`, `failed`, `cancelled`.
pub const Step = enum {
    /// Accepted, waiting for a slot.
    queued,
    /// Turning the catalogue link into something an engine can fetch.
    resolving,
    /// Browser flow: page opened, waiting for file/link.
    awaiting_user,
    /// Torrent: .torrent/magnet metadata.
    fetching_metadata,
    /// Torrent: active, 0 peers.
    finding_peers,
    downloading,
    /// User pause (any engine); the job remembers `resume_step`.
    paused,
    /// sha256 when known; else size/format sanity.
    verifying,
    extracting,
    /// UI-side upsert + optional convert; waits for ack.
    installing,
    /// Torrent payload complete; install already triggered.
    seeding,
    done,
    failed,
    cancelled,

    /// True for steps before any bytes flow: queued, resolving, awaiting_user,
    /// fetching_metadata, finding_peers.
    pub fn isPreDownload(self: Step) bool {
        return switch (self) {
            .queued, .resolving, .awaiting_user, .fetching_metadata, .finding_peers => true,
            else => false,
        };
    }

    /// True for done, failed, cancelled.
    pub fn isTerminal(self: Step) bool {
        return switch (self) {
            .done, .failed, .cancelled => true,
            else => false,
        };
    }

    /// True for verifying, extracting, installing.
    pub fn isPostTransfer(self: Step) bool {
        return switch (self) {
            .verifying, .extracting, .installing => true,
            else => false,
        };
    }

    /// Plain-language label for the UI.
    pub fn label(self: Step) []const u8 {
        return switch (self) {
            .queued => "Queued",
            .resolving => "Resolving link",
            .awaiting_user => "Waiting for you",
            .fetching_metadata => "Fetching metadata",
            .finding_peers => "Finding peers",
            .downloading => "Downloading",
            .paused => "Paused",
            .verifying => "Verifying",
            .extracting => "Extracting",
            .installing => "Installing",
            .seeding => "Seeding",
            .done => "Done",
            .failed => "Failed",
            .cancelled => "Cancelled",
        };
    }
};

pub const EngineKind = enum { aria2_http, aria2_torrent, megacmd, browser };
pub const Kind = enum { game, mod, extra };
pub const FailReason = enum { network, host_gone, auth_required, captcha, quota_exceeded, no_peers, checksum_mismatch, bad_archive, disk_full, engine_missing, user_cancelled, install_failed, unknown };

/// One download. `dl_speed` through `seeders` are live only (not stored);
/// every other field, including `created_at`/`updated_at`, is stored.
pub const Job = struct {
    /// Group = multi-part set; a single job has `group_id == id`.
    id: u64,
    group_id: u64,
    kind: Kind,
    game_thread_id: u64,
    mod_id: ?u64 = null,
    /// Game name (+ " · Part 2" etc.).
    title: []const u8 = "",
    /// What the user clicked or pasted.
    source_href: []const u8,
    /// dl_classify.Host label or "raw".
    host: []const u8 = "",
    engine: EngineKind,
    platform: ?[]const u8 = null,
    part: ?u8 = null,
    version: ?[]const u8 = null,
    step: Step,
    /// Human line, e.g. "0 seeders, retrying in 30 s".
    step_detail: []const u8 = "",
    /// Where to go back to after a pause.
    resume_step: ?Step = null,
    fail: ?FailReason = null,
    fail_msg: []const u8 = "",
    attempts: u8 = 0,
    next_retry_at: ?i64 = null,
    resolved_url: ?[]const u8 = null,
    resolved_headers: []const []const u8 = &.{},
    resolved_at: ?i64 = null,
    /// aria2 gid / mega destination path / null.
    engine_ref: ?[]const u8 = null,
    /// `<downloads_root>/<engine>/<job_id>/`.
    dest_dir: []const u8,
    /// The archive once it exists.
    final_path: ?[]const u8 = null,
    expected_sha256: ?[32]u8 = null,
    bytes_done: u64 = 0,
    bytes_total: ?u64 = null,
    bytes_uploaded: u64 = 0,
    // Live only, not stored: dl_speed .. seeders.
    dl_speed: u64 = 0,
    ul_speed: u64 = 0,
    peers: u32 = 0,
    seeders: u32 = 0,
    created_at: i64 = 0,
    updated_at: i64 = 0,
    finished_at: ?i64 = null,
};

pub const Phase = enum { queued, fetching_metadata, finding_peers, downloading, paused, seeding, transfer_done, failed, removed, daemon_gone };

/// An engine's report from `poll`.
pub const Progress = struct {
    phase: Phase,
    bytes_done: u64 = 0,
    bytes_total: ?u64 = null,
    bytes_uploaded: u64 = 0,
    dl_speed: u64 = 0,
    ul_speed: u64 = 0,
    peers: u32 = 0,
    seeders: u32 = 0,
    fail: ?FailReason = null,
    msg: []const u8 = "",
    final_path: ?[]const u8 = null,
};

pub const Input = union(enum) {
    /// From `engine.poll`; `now` (unix seconds) times the retry.
    engine_progress: struct { p: Progress, now: i64 },
    resolved: struct { engine: EngineKind },
    needs_browser,
    dead: []const u8,
    auth_required,
    captcha,
    /// final_path
    file_arrived: []const u8,
    verify_ok,
    verify_err: FailReason,
    extract_ok,
    extract_err: FailReason,
    install_ack,
    install_err: []const u8,
    user_pause,
    user_resume,
    user_cancel,
    user_retry,
    /// A scheduler slot opened for a queued job.
    slot_free,
    /// now (unix seconds) — retry timers.
    tick: i64,
};

pub const SideEffect = enum { none, start_engine, cancel_engine, pause_engine, resume_engine, start_verify, start_extract, raise_install, delete_file_and_restart, open_browser };

/// What to apply to the job. `resume_step` is only meaningful when
/// `step == .paused`.
pub const Transition = struct {
    step: Step,
    detail: []const u8 = "",
    fail: ?FailReason = null,
    next_retry_at: ?i64 = null,
    attempts: u8,
    side_effect: SideEffect = .none,
    resume_step: ?Step = null,
};

/// Seconds to wait before automatic retry number `attempt` (0-based);
/// null once automatic retries are used up.
pub fn retryDelaySeconds(attempt: u8) ?u32 {
    return switch (attempt) {
        0 => 30,
        1 => 120,
        2 => 600,
        else => null,
    };
}

fn isRetryable(reason: FailReason) bool {
    return reason == .network or reason == .no_peers;
}

/// Step is one where an engine is moving (or about to move) bytes.
fn isActive(step: Step) bool {
    return step == .downloading or step == .fetching_metadata or step == .finding_peers;
}

fn unchanged(job: *const Job) Transition {
    return .{
        .step = job.step,
        .detail = job.step_detail,
        .fail = job.fail,
        .next_retry_at = job.next_retry_at,
        .attempts = job.attempts,
        .resume_step = job.resume_step,
    };
}

fn to(job: *const Job, step: Step, effect: SideEffect) Transition {
    return .{ .step = step, .attempts = job.attempts, .side_effect = effect };
}

fn failedNoRetry(job: *const Job, reason: FailReason, detail: []const u8) Transition {
    return .{ .step = .failed, .detail = detail, .fail = reason, .attempts = job.attempts };
}

fn failedFromEngine(job: *const Job, p: Progress, now: i64) Transition {
    const reason = p.fail orelse .unknown;
    var t = failedNoRetry(job, reason, p.msg);
    if (isRetryable(reason)) {
        if (retryDelaySeconds(job.attempts)) |delay| t.next_retry_at = now + @as(i64, delay);
    }
    return t;
}

/// Engine lost the job: `removed` cancels it, `daemon_gone` is a retryable
/// network failure. Null for any other phase.
fn engineGone(job: *const Job, p: Progress, now: i64) ?Transition {
    return switch (p.phase) {
        .removed => to(job, .cancelled, .none),
        .daemon_gone => blk: {
            var q = p;
            q.fail = .network;
            break :blk failedFromEngine(job, q, now);
        },
        else => null,
    };
}

/// Pure transition function. Any (step, input) pair not defined returns the
/// current step unchanged with `.side_effect = .none`.
pub fn advance(job: *const Job, input: Input) Transition {
    // Cancel and retry do not depend on the step in the same way as the rest.
    switch (input) {
        .user_cancel => {
            if (job.step.isTerminal()) return unchanged(job);
            return switch (job.step) {
                .awaiting_user, .queued, .resolving => to(job, .cancelled, .none),
                else => to(job, .cancelled, .cancel_engine),
            };
        },
        .user_retry => {
            if (job.step != .failed) return unchanged(job);
            const wipe = job.fail == .checksum_mismatch or job.fail == .bad_archive;
            var t = to(job, .queued, if (wipe) .delete_file_and_restart else .none);
            t.attempts = 0;
            return t;
        },
        .tick => |now| {
            if (job.step == .failed) {
                if (job.next_retry_at) |at| {
                    if (now >= at) {
                        var t = to(job, .queued, .none);
                        t.attempts = job.attempts +| 1;
                        return t;
                    }
                }
            }
            return unchanged(job);
        },
        else => {},
    }

    switch (job.step) {
        .queued => switch (input) {
            .slot_free => return to(job, .resolving, .none),
            else => {},
        },
        .resolving => switch (input) {
            .resolved => return to(job, .downloading, .start_engine),
            .needs_browser => return to(job, .awaiting_user, .open_browser),
            .auth_required => return failedNoRetry(job, .auth_required, ""),
            .captcha => return failedNoRetry(job, .captcha, ""),
            .dead => |msg| return failedNoRetry(job, .host_gone, msg),
            else => {},
        },
        .awaiting_user => switch (input) {
            .file_arrived => return to(job, .verifying, .start_verify),
            .resolved => return to(job, .downloading, .start_engine),
            else => {},
        },
        .fetching_metadata, .finding_peers, .downloading => switch (input) {
            .engine_progress => |ep| {
                const p = ep.p;
                var t = to(job, job.step, .none);
                t.detail = p.msg;
                switch (p.phase) {
                    .fetching_metadata => t.step = .fetching_metadata,
                    .finding_peers => t.step = .finding_peers,
                    .downloading => t.step = .downloading,
                    .transfer_done, .seeding => {
                        t.step = .verifying;
                        t.side_effect = .start_verify;
                        t.detail = "";
                    },
                    .failed => return failedFromEngine(job, p, ep.now),
                    .removed, .daemon_gone => return engineGone(job, p, ep.now).?,
                    .queued, .paused => return unchanged(job),
                }
                return t;
            },
            .user_pause => {
                var t = to(job, .paused, .pause_engine);
                t.resume_step = job.step;
                return t;
            },
            else => {},
        },
        .paused => switch (input) {
            .user_resume => return to(job, job.resume_step orelse .downloading, .resume_engine),
            .engine_progress => |ep| if (engineGone(job, ep.p, ep.now)) |t| return t,
            else => {},
        },
        .verifying => switch (input) {
            .verify_ok => return to(job, .extracting, .start_extract),
            .verify_err => |r| return failedNoRetry(job, r, ""),
            else => {},
        },
        .extracting => switch (input) {
            .extract_ok => return to(job, .installing, .raise_install),
            .extract_err => |r| return failedNoRetry(job, r, ""),
            else => {},
        },
        .installing => switch (input) {
            .install_ack => return to(job, if (job.engine == .aria2_torrent) .seeding else .done, .none),
            .install_err => |msg| return failedNoRetry(job, .install_failed, msg),
            else => {},
        },
        .seeding => switch (input) {
            .engine_progress => |ep| {
                if (ep.p.phase == .transfer_done) return to(job, .done, .none);
                if (engineGone(job, ep.p, ep.now)) |t| return t;
            },
            else => {},
        },
        .done, .failed, .cancelled => {},
    }
    return unchanged(job);
}

// ---------------------------------------------------------------- tests

fn testJob(step: Step) Job {
    return .{
        .id = 1,
        .group_id = 1,
        .kind = .game,
        .game_thread_id = 10,
        .source_href = "https://example.invalid/x",
        .engine = .aria2_http,
        .step = step,
        .dest_dir = "/tmp/x",
    };
}

fn progress(phase: Phase, fail: ?FailReason, now: i64) Input {
    return .{ .engine_progress = .{ .p = .{ .phase = phase, .fail = fail }, .now = now } };
}

test "advance: resolving + resolved(aria2_http) -> downloading with start_engine" {
    const t = advance(&testJob(.resolving), .{ .resolved = .{ .engine = .aria2_http } });
    try testing.expectEqual(Step.downloading, t.step);
    try testing.expectEqual(SideEffect.start_engine, t.side_effect);
}

test "advance: queued + slot_free -> resolving with no side effect" {
    const t = advance(&testJob(.queued), .slot_free);
    try testing.expectEqual(Step.resolving, t.step);
    try testing.expectEqual(SideEffect.none, t.side_effect);
}

test "advance: downloading + progress transfer_done -> verifying with start_verify" {
    const t = advance(&testJob(.downloading), progress(.transfer_done, null, 0));
    try testing.expectEqual(Step.verifying, t.step);
    try testing.expectEqual(SideEffect.start_verify, t.side_effect);
}

test "advance: downloading + progress failed(network) attempt 0 -> failed, retry at now+30, then tick -> queued attempts 1" {
    var job = testJob(.downloading);
    job.attempts = 0;
    const t = advance(&job, progress(.failed, .network, 1000));
    try testing.expectEqual(Step.failed, t.step);
    try testing.expectEqual(FailReason.network, t.fail.?);
    try testing.expectEqual(@as(?i64, 1030), t.next_retry_at);
    try testing.expectEqual(@as(u8, 0), t.attempts);

    job.step = t.step;
    job.fail = t.fail;
    job.next_retry_at = t.next_retry_at;
    job.attempts = t.attempts;

    const early = advance(&job, .{ .tick = 1029 });
    try testing.expectEqual(Step.failed, early.step);
    const due = advance(&job, .{ .tick = 1030 });
    try testing.expectEqual(Step.queued, due.step);
    try testing.expectEqual(@as(u8, 1), due.attempts);
    try testing.expectEqual(@as(?i64, null), due.next_retry_at);
    try testing.expectEqual(@as(?FailReason, null), due.fail);
}

test "advance: failed(network) after 3 attempts stays failed, next_retry_at null" {
    var job = testJob(.downloading);
    job.attempts = 3;
    const t = advance(&job, progress(.failed, .network, 1000));
    try testing.expectEqual(Step.failed, t.step);
    try testing.expectEqual(@as(?i64, null), t.next_retry_at);
}

test "advance: only network and no_peers failures are auto-retried" {
    const all = std.enums.values(FailReason);
    for (all) |r| {
        const t = advance(&testJob(.downloading), progress(.failed, r, 100));
        try testing.expectEqual(Step.failed, t.step);
        const want = r == .network or r == .no_peers;
        try testing.expectEqual(want, t.next_retry_at != null);
    }
    const t = advance(&testJob(.downloading), progress(.failed, null, 100));
    try testing.expectEqual(FailReason.unknown, t.fail.?);
    try testing.expectEqual(@as(?i64, null), t.next_retry_at);
}

test "advance: failed(checksum_mismatch) + user_retry -> queued with delete_file_and_restart" {
    var job = testJob(.failed);
    job.fail = .checksum_mismatch;
    job.attempts = 2;
    const t = advance(&job, .user_retry);
    try testing.expectEqual(Step.queued, t.step);
    try testing.expectEqual(SideEffect.delete_file_and_restart, t.side_effect);
    try testing.expectEqual(@as(u8, 0), t.attempts);

    job.fail = .network;
    const n = advance(&job, .user_retry);
    try testing.expectEqual(Step.queued, n.step);
    try testing.expectEqual(SideEffect.none, n.side_effect);
    try testing.expectEqual(@as(u8, 0), n.attempts);
}

test "advance: verify -> extract -> install -> done (http) / seeding (torrent)" {
    const v = advance(&testJob(.verifying), .verify_ok);
    try testing.expectEqual(Step.extracting, v.step);
    try testing.expectEqual(SideEffect.start_extract, v.side_effect);

    const e = advance(&testJob(.extracting), .extract_ok);
    try testing.expectEqual(Step.installing, e.step);
    try testing.expectEqual(SideEffect.raise_install, e.side_effect);

    const http = advance(&testJob(.installing), .install_ack);
    try testing.expectEqual(Step.done, http.step);

    var tor = testJob(.installing);
    tor.engine = .aria2_torrent;
    try testing.expectEqual(Step.seeding, advance(&tor, .install_ack).step);
}

test "advance: verify/extract/install errors fail without retry" {
    const v = advance(&testJob(.verifying), .{ .verify_err = .checksum_mismatch });
    try testing.expectEqual(FailReason.checksum_mismatch, v.fail.?);
    try testing.expectEqual(@as(?i64, null), v.next_retry_at);
    const e = advance(&testJob(.extracting), .{ .extract_err = .bad_archive });
    try testing.expectEqual(FailReason.bad_archive, e.fail.?);
    const i = advance(&testJob(.installing), .{ .install_err = "boom" });
    try testing.expectEqual(Step.failed, i.step);
    try testing.expectEqual(FailReason.install_failed, i.fail.?);
    try testing.expectEqualStrings("boom", i.detail);
}

test "advance: user_pause from downloading -> paused remembering downloading; user_resume restores" {
    const p = advance(&testJob(.downloading), .user_pause);
    try testing.expectEqual(Step.paused, p.step);
    try testing.expectEqual(Step.downloading, p.resume_step.?);
    try testing.expectEqual(SideEffect.pause_engine, p.side_effect);

    var job = testJob(.paused);
    job.resume_step = .finding_peers;
    const r = advance(&job, .user_resume);
    try testing.expectEqual(Step.finding_peers, r.step);
    try testing.expectEqual(SideEffect.resume_engine, r.side_effect);
}

test "advance: user_cancel from non-terminal -> cancelled; engine only when one is running" {
    for (std.enums.values(Step)) |s| {
        const t = advance(&testJob(s), .user_cancel);
        if (s.isTerminal()) {
            try testing.expectEqual(s, t.step);
            try testing.expectEqual(SideEffect.none, t.side_effect);
        } else {
            try testing.expectEqual(Step.cancelled, t.step);
            const no_engine = s == .awaiting_user or s == .queued or s == .resolving;
            try testing.expectEqual(if (no_engine) SideEffect.none else SideEffect.cancel_engine, t.side_effect);
        }
    }
}

test "advance: resolving + needs_browser/auth_required/captcha/dead" {
    const b = advance(&testJob(.resolving), .needs_browser);
    try testing.expectEqual(Step.awaiting_user, b.step);
    try testing.expectEqual(SideEffect.open_browser, b.side_effect);

    const a = advance(&testJob(.resolving), .auth_required);
    try testing.expectEqual(Step.failed, a.step);
    try testing.expectEqual(FailReason.auth_required, a.fail.?);
    try testing.expectEqual(@as(?i64, null), a.next_retry_at);

    const c = advance(&testJob(.resolving), .captcha);
    try testing.expectEqual(FailReason.captcha, c.fail.?);

    const d = advance(&testJob(.resolving), .{ .dead = "404" });
    try testing.expectEqual(FailReason.host_gone, d.fail.?);
    try testing.expectEqual(@as(?i64, null), d.next_retry_at);
    try testing.expectEqualStrings("404", d.detail);
}

test "advance: awaiting_user + file_arrived -> verifying; + resolved -> downloading" {
    const f = advance(&testJob(.awaiting_user), .{ .file_arrived = "/tmp/x/a.zip" });
    try testing.expectEqual(Step.verifying, f.step);
    try testing.expectEqual(SideEffect.start_verify, f.side_effect);
    const r = advance(&testJob(.awaiting_user), .{ .resolved = .{ .engine = .aria2_http } });
    try testing.expectEqual(Step.downloading, r.step);
    try testing.expectEqual(SideEffect.start_engine, r.side_effect);
}

test "advance: torrent progress phases map to steps; seeding holds; transfer_done while seeding -> done" {
    var job = testJob(.downloading);
    job.engine = .aria2_torrent;
    try testing.expectEqual(Step.fetching_metadata, advance(&job, progress(.fetching_metadata, null, 0)).step);
    try testing.expectEqual(Step.finding_peers, advance(&job, progress(.finding_peers, null, 0)).step);
    job.step = .finding_peers;
    try testing.expectEqual(Step.downloading, advance(&job, progress(.downloading, null, 0)).step);

    job.step = .seeding;
    const keep = advance(&job, progress(.seeding, null, 0));
    try testing.expectEqual(Step.seeding, keep.step);
    try testing.expectEqual(SideEffect.none, keep.side_effect);
    const fin = advance(&job, progress(.transfer_done, null, 0));
    try testing.expectEqual(Step.done, fin.step);
}

test "advance: undefined pairs leave the job unchanged" {
    var job = testJob(.done);
    job.step_detail = "ok";
    const t = advance(&job, .verify_ok);
    try testing.expectEqual(Step.done, t.step);
    try testing.expectEqual(SideEffect.none, t.side_effect);
    try testing.expectEqualStrings("ok", t.detail);
    try testing.expectEqual(Step.queued, advance(&testJob(.queued), .install_ack).step);
}

test "Step.isPreDownload / isTerminal / isPostTransfer" {
    const Row = struct { s: Step, pre: bool, term: bool, post: bool };
    const rows = [_]Row{
        .{ .s = .queued, .pre = true, .term = false, .post = false },
        .{ .s = .resolving, .pre = true, .term = false, .post = false },
        .{ .s = .awaiting_user, .pre = true, .term = false, .post = false },
        .{ .s = .fetching_metadata, .pre = true, .term = false, .post = false },
        .{ .s = .finding_peers, .pre = true, .term = false, .post = false },
        .{ .s = .downloading, .pre = false, .term = false, .post = false },
        .{ .s = .paused, .pre = false, .term = false, .post = false },
        .{ .s = .verifying, .pre = false, .term = false, .post = true },
        .{ .s = .extracting, .pre = false, .term = false, .post = true },
        .{ .s = .installing, .pre = false, .term = false, .post = true },
        .{ .s = .seeding, .pre = false, .term = false, .post = false },
        .{ .s = .done, .pre = false, .term = true, .post = false },
        .{ .s = .failed, .pre = false, .term = true, .post = false },
        .{ .s = .cancelled, .pre = false, .term = true, .post = false },
    };
    try testing.expectEqual(std.enums.values(Step).len, rows.len);
    for (rows) |r| {
        try testing.expectEqual(r.pre, r.s.isPreDownload());
        try testing.expectEqual(r.term, r.s.isTerminal());
        try testing.expectEqual(r.post, r.s.isPostTransfer());
    }
}

test "Step.label" {
    try testing.expectEqualStrings("Waiting for you", Step.awaiting_user.label());
    try testing.expectEqualStrings("Resolving link", Step.resolving.label());
    for (std.enums.values(Step)) |s| try testing.expect(s.label().len > 0);
}

test "retryDelaySeconds" {
    try testing.expectEqual(@as(?u32, 30), retryDelaySeconds(0));
    try testing.expectEqual(@as(?u32, 120), retryDelaySeconds(1));
    try testing.expectEqual(@as(?u32, 600), retryDelaySeconds(2));
    try testing.expectEqual(@as(?u32, null), retryDelaySeconds(3));
    try testing.expectEqual(@as(?u32, null), retryDelaySeconds(255));
}

test "advance: engine removed -> cancelled, daemon_gone -> retryable network failure (downloading, paused, seeding)" {
    for ([_]Step{ .downloading, .paused, .seeding }) |s| {
        var job = testJob(s);
        job.attempts = 0;
        const r = advance(&job, progress(.removed, null, 1000));
        try testing.expectEqual(Step.cancelled, r.step);
        try testing.expectEqual(SideEffect.none, r.side_effect);

        const g = advance(&job, progress(.daemon_gone, null, 1000));
        try testing.expectEqual(Step.failed, g.step);
        try testing.expectEqual(FailReason.network, g.fail.?);
        try testing.expectEqual(@as(?i64, 1030), g.next_retry_at);

        job.attempts = 3;
        try testing.expectEqual(@as(?i64, null), advance(&job, progress(.daemon_gone, null, 1000)).next_retry_at);
    }
}
