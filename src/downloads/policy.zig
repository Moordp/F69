//! Downloader v2 bandwidth and slot policy. Pure: no I/O.
const std = @import("std");
const model = @import("model.zig");

pub const Settings = struct {
    slots_files: u8 = 3,
    slots_torrents: u8 = 2,
    cap_total_kbs: u32 = 0,
    cap_files_kbs: u32 = 0,
    cap_torrents_kbs: u32 = 0,
    torrent_share_pct: u8 = 50,
    ul_cap_busy_kbs: u32 = 256,
    ul_cap_idle_kbs: u32 = 0,
    seed_ratio: f32 = 3.0,
    seed_time_min: u32 = 0,
    watch_dir: []const u8 = "",
    megacmd_path: []const u8 = "",
};

pub const ActiveCounts = struct {
    files_downloading: u32,
    torrents_downloading: u32,
    any_downloading: bool,
};

/// All limits are bytes per second; 0 means unlimited.
pub const Plan = struct {
    aria2_global_down: u64,
    aria2_global_up: u64,
    per_torrent_down: u64,
    per_file_down: u64,
    mega_down: u64,
    /// aria2 seed target (copied from `Settings`; applied when it changes).
    seed_ratio: f32 = 3.0,
    /// aria2 seed-time cap in minutes; 0 = no cap.
    seed_time_min: u32 = 0,
};

/// Budget for one class in bytes/s (0 = unlimited). `class_kbs` is the
/// class's own cap; `share_pct` is this class's share when both classes
/// are downloading and only a total cap exists.
fn classBudget(class_kbs: u32, total_kbs: u32, share_pct: u64, other_active: bool) u64 {
    if (class_kbs > 0) return @as(u64, class_kbs) * 1024;
    if (total_kbs == 0) return 0;
    const total = @as(u64, total_kbs) * 1024;
    return if (other_active) total * share_pct / 100 else total;
}

/// Split a budget across `n` jobs. A non-zero budget never yields 0 per job.
fn perJob(budget: u64, n: u32) u64 {
    if (budget == 0 or n == 0) return 0;
    return @max(budget / n, 1);
}

pub fn plan(s: Settings, a: ActiveCounts) Plan {
    // 0 would mean unlimited; keep at least 1 % for each class.
    const share: u64 = std.math.clamp(s.torrent_share_pct, 1, 99);
    const tb = classBudget(s.cap_torrents_kbs, s.cap_total_kbs, share, a.files_downloading > 0);
    const fb = classBudget(s.cap_files_kbs, s.cap_total_kbs, 100 - share, a.torrents_downloading > 0);
    const per_file = perJob(fb, a.files_downloading);
    return .{
        .aria2_global_down = @as(u64, s.cap_total_kbs) * 1024,
        .aria2_global_up = @as(u64, if (a.any_downloading) s.ul_cap_busy_kbs else s.ul_cap_idle_kbs) * 1024,
        .per_torrent_down = perJob(tb, a.torrents_downloading),
        .per_file_down = per_file,
        .mega_down = per_file,
        .seed_ratio = s.seed_ratio,
        .seed_time_min = s.seed_time_min,
    };
}

pub fn isFileEngine(e: model.EngineKind) bool {
    return e != .aria2_torrent;
}

pub fn hasSlot(s: Settings, a: ActiveCounts, e: model.EngineKind) bool {
    return if (isFileEngine(e)) a.files_downloading < s.slots_files else a.torrents_downloading < s.slots_torrents;
}

test "plan: all zero → all unlimited, up = busy cap when downloading else idle" {
    const s: Settings = .{};
    const busy = plan(s, .{ .files_downloading = 1, .torrents_downloading = 0, .any_downloading = true });
    try std.testing.expectEqual(@as(u64, 256 * 1024), busy.aria2_global_up);
    try std.testing.expectEqual(@as(u64, 0), busy.aria2_global_down);
    try std.testing.expectEqual(@as(u64, 0), busy.per_file_down);
    try std.testing.expectEqual(@as(u64, 0), busy.per_torrent_down);
    const idle = plan(s, .{ .files_downloading = 0, .torrents_downloading = 0, .any_downloading = false });
    try std.testing.expectEqual(@as(u64, 0), idle.aria2_global_up);
}

test "plan: total 1000 KB/s, both classes active, share 50 → per_torrent 500 KB/s ÷ torrents_downloading, per_file 500 KB/s ÷ files, global_down 1000" {
    const p = plan(.{ .cap_total_kbs = 1000 }, .{ .files_downloading = 2, .torrents_downloading = 5, .any_downloading = true });
    try std.testing.expectEqual(@as(u64, 1000 * 1024), p.aria2_global_down);
    try std.testing.expectEqual(102400, p.per_torrent_down);
    try std.testing.expectEqual(256000, p.per_file_down);
}

test "plan: total cap, only torrents active → per_torrent = total ÷ n, per_file 0" {
    const p = plan(.{ .cap_total_kbs = 1000 }, .{ .files_downloading = 0, .torrents_downloading = 2, .any_downloading = true });
    try std.testing.expectEqual(@as(u64, 512000), p.per_torrent_down);
    try std.testing.expectEqual(@as(u64, 0), p.per_file_down);
}

test "plan: class caps apply without total cap" {
    const p = plan(.{ .cap_files_kbs = 300, .cap_torrents_kbs = 200 }, .{ .files_downloading = 3, .torrents_downloading = 2, .any_downloading = true });
    try std.testing.expectEqual(@as(u64, 0), p.aria2_global_down);
    try std.testing.expectEqual(@as(u64, 300 * 1024 / 3), p.per_file_down);
    try std.testing.expectEqual(@as(u64, 200 * 1024 / 2), p.per_torrent_down);
}

test "plan: tiny budget never rounds to zero per job" {
    const p = plan(.{ .cap_files_kbs = 1 }, .{ .files_downloading = 5000, .torrents_downloading = 0, .any_downloading = true });
    try std.testing.expectEqual(@as(u64, 1), p.per_file_down);
}

test "plan: mega_down == per_file_down" {
    const p = plan(.{ .cap_total_kbs = 900 }, .{ .files_downloading = 3, .torrents_downloading = 1, .any_downloading = true });
    try std.testing.expect(p.per_file_down > 0);
    try std.testing.expectEqual(p.per_file_down, p.mega_down);
}

test "plan copies seed ratio and seed time from settings" {
    const p = plan(.{ .seed_ratio = 1.5, .seed_time_min = 90 }, .{ .files_downloading = 0, .torrents_downloading = 0, .any_downloading = false });
    try std.testing.expectEqual(@as(f32, 1.5), p.seed_ratio);
    try std.testing.expectEqual(@as(u32, 90), p.seed_time_min);
}

test "hasSlot respects both counts" {
    const s: Settings = .{};
    const a: ActiveCounts = .{ .files_downloading = 3, .torrents_downloading = 1, .any_downloading = true };
    try std.testing.expect(!hasSlot(s, a, .aria2_http));
    try std.testing.expect(!hasSlot(s, a, .megacmd));
    try std.testing.expect(!hasSlot(s, a, .browser));
    try std.testing.expect(hasSlot(s, a, .aria2_torrent));
    const b: ActiveCounts = .{ .files_downloading = 2, .torrents_downloading = 2, .any_downloading = true };
    try std.testing.expect(hasSlot(s, b, .aria2_http));
    try std.testing.expect(!hasSlot(s, b, .aria2_torrent));
    try std.testing.expect(!isFileEngine(.aria2_torrent));
}

test "plan: share 0 and 100 with both classes active keep both budgets non-zero" {
    const a: ActiveCounts = .{ .files_downloading = 1, .torrents_downloading = 1, .any_downloading = true };
    for ([_]u8{ 0, 100 }) |pct| {
        const p = plan(.{ .cap_total_kbs = 1000, .torrent_share_pct = pct }, a);
        try std.testing.expect(p.per_torrent_down > 0);
        try std.testing.expect(p.per_file_down > 0);
        try std.testing.expect(p.per_torrent_down + p.per_file_down <= 1024000);
    }
}
