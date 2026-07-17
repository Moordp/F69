// Map indexer `ThreadData` → fields the f69 sync worker hands to
// `library.applyScrape`. F95Checker's `/full/{id}` response carries
// integer Type / Status / Tag enum IDs and a nested downloads
// structure; this file converts each into f69's domain shape so the
// indexer refresh path lands the same Game fields the HTML scraper
// would have produced.

const std = @import("std");
const library = @import("library");
const client = @import("client.zig");
const tag_table = @import("tag_table.zig");

pub const ThreadData = client.ThreadData;
pub const DownloadGroup = client.DownloadGroup;
pub const DownloadEntry = client.DownloadEntry;

/// F95Checker `Type` enum int → f69 `Engine`. Source of truth:
/// `~/projects/F95Checker/common/structs.py` `Type = IntEnumHack(...)`.
/// Types that aren't a recognizable engine (`Tool`, `Misc`, `Tutorial`,
/// media types like `Comics` / `GIF` / `SiteRip`) collapse to
/// `.unknown` — f69's Engine column is for game engines only.
pub fn engineFromTypeInt(t: u32) library.Engine {
    return switch (t) {
        14 => .renpy,
        13 => .rpgm_mv, // generic RPGM → MV (most common modern variant)
        19 => .unity,
        20 => .unreal,
        5 => .html,
        4 => .flash,
        6 => .java,
        22 => .wolf_rpg,
        10 => .qsp,
        21 => .webgl,
        2 => .adrift,
        11 => .rags,
        16 => .tads,
        9 => .other, // Others (F95Checker bucket)
        else => .unknown, // Misc / Tool / Mod / Comics / GIF / etc.
    };
}

/// F95Checker `Status` enum int → f69 `DevStatus`.
///   1 Normal     → .in_progress
///   2 Completed  → .completed
///   3 OnHold     → .on_hold
///   4 Abandoned  → .abandoned
///   5 Unchecked  → .unknown
///   6 Custom     → .unknown (F95Checker-specific user tag)
pub fn devStatusFromStatusInt(s: u32) library.DevStatus {
    return switch (s) {
        1 => .in_progress,
        2 => .completed,
        3 => .on_hold,
        4 => .abandoned,
        else => .unknown,
    };
}

/// Translate F95Checker tag-IDs into the human-readable label strings
/// f69 stores in `Game.tags`. Unknown IDs are dropped (rare, but
/// possible if F95 adds a new tag and the indexer ships before f69's
/// embedded table catches up). `unknown_tags` flow through verbatim
/// since the indexer already gave us strings.
///
/// Returns a fresh slice owned by `alloc`; each inner string is also
/// `alloc`-owned. Caller frees outer + each inner.
pub fn translateTags(
    alloc: std.mem.Allocator,
    tag_ids: []const u32,
    unknown_tags: []const []const u8,
) ![]const []const u8 {
    const total_cap = tag_ids.len + unknown_tags.len;
    if (total_cap == 0) return &.{};

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    try out.ensureTotalCapacity(alloc, total_cap);

    for (tag_ids) |id| {
        if (tag_table.lookup(id)) |label| {
            const dup = try alloc.dupe(u8, label);
            errdefer alloc.free(dup);
            try out.append(alloc, dup);
        }
    }
    for (unknown_tags) |t| {
        if (t.len == 0) continue;
        const dup = try alloc.dupe(u8, t);
        errdefer alloc.free(dup);
        try out.append(alloc, dup);
    }
    return try out.toOwnedSlice(alloc);
}

/// Encode the indexer's grouped downloads into the same
/// `<host>\t<url>\t<label>` line format the scraper path produces
/// (see `actions/sync.zig:encodeDownloadLinks`). The `label` carries
/// the version / variant context (indexer's outer group key). Empty
/// labels — the common case for a single download group — stay empty.
///
/// Returns a freshly-`alloc`-owned outer slice + inner strings.
pub fn encodeDownloadLinks(
    alloc: std.mem.Allocator,
    groups: []const DownloadGroup,
) ![]const []const u8 {
    if (groups.len == 0) return &.{};

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }

    for (groups) |g| {
        for (g.links) |link| {
            // XPath stubs aren't real URLs — would just confuse the
            // download manager. See `isXPathStub` above.
            if (isXPathStub(link.url)) continue;
            const host_token = normalizeHost(link.host);
            const line = try std.fmt.allocPrint(alloc, "{s}\t{s}\t{s}", .{
                host_token,
                link.url,
                g.label,
            });
            errdefer alloc.free(line);
            try out.append(alloc, line);
        }
    }
    return try out.toOwnedSlice(alloc);
}

/// Map an indexer host token (e.g. "MEGA", "MEDIAFIRE") to the
/// snake-case enum tag f69's `DownloadHost` expects. Anything we
/// don't recognise falls through to `"other"`.
fn normalizeHost(raw: []const u8) []const u8 {
    var lower_buf: [32]u8 = undefined;
    const n = @min(raw.len, lower_buf.len);
    for (raw[0..n], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lower = lower_buf[0..n];

    if (std.mem.startsWith(u8, lower, "mega")) return "mega";
    if (std.mem.startsWith(u8, lower, "mediafire")) return "mediafire";
    if (std.mem.startsWith(u8, lower, "gofile")) return "gofile";
    if (std.mem.startsWith(u8, lower, "pixeldrain")) return "pixeldrain";
    if (std.mem.startsWith(u8, lower, "workupload")) return "workupload";
    if (std.mem.startsWith(u8, lower, "nopy")) return "nopy";
    if (std.mem.startsWith(u8, lower, "zippy")) return "zippyshare";
    if (std.mem.startsWith(u8, lower, "f95") or std.mem.startsWith(u8, lower, "attach")) return "f95_attachment";
    return "other";
}

/// Reconstruct the "Key: Value" header block that the scraper path
/// stores in `Game.thread_info_md` (the verbatim OP-body lines —
/// Thread Updated / Release Date / Developer / Censored / Version /
/// OS / Language / etc).
///
/// The indexer parses the OP into typed fields rather than preserving
/// the raw text, so we synthesize a best-effort approximation from
/// what's available: `last_updated`, `developer`, `version`, `type`,
/// `status`, plus a Censored marker mined from the tag list. Fields
/// the indexer flat-out doesn't expose (Release Date, OS, Language)
/// are omitted — a previously-scraper-synced game keeps its richer
/// block since `applyScrape` only overwrites when the new value is
/// non-null, but a never-scraped indexer-only row gets at least the
/// 5-line core block instead of an empty info panel.
///
/// Returns a freshly-`alloc`-owned multi-line string; empty slice
/// when there's literally nothing to display (no developer, no
/// version, no last_updated). Caller frees.
pub fn buildThreadInfoMd(
    alloc: std.mem.Allocator,
    data: *const ThreadData,
    translated_tags: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    if (data.last_updated) |ts| try appendLine(&buf, alloc, "Thread Updated", utcDate(ts));
    if (data.developer) |d| {
        if (d.len > 0) try appendLine(&buf, alloc, "Developer", d);
    }
    if (data.version) |v| {
        if (v.len > 0) try appendLine(&buf, alloc, "Version", v);
    }
    if (data.type_int) |t| try appendLine(&buf, alloc, "Engine", typeLabel(t));
    if (data.status_int) |s| try appendLine(&buf, alloc, "Status", statusLabel(s));
    if (censoredLabel(translated_tags)) |label| try appendLine(&buf, alloc, "Censored", label);
    if (languageLabel(translated_tags)) |label| try appendLine(&buf, alloc, "Language", label);

    if (buf.items.len == 0) return alloc.alloc(u8, 0);
    return try buf.toOwnedSlice(alloc);
}

fn appendLine(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) !void {
    try buf.appendSlice(alloc, key);
    try buf.appendSlice(alloc, ": ");
    try buf.appendSlice(alloc, value);
    try buf.append(alloc, '\n');
}

/// UTC `YYYY-MM-DD` from unix-seconds. Embedded so we don't pull a
/// time-formatting dependency into `f95_indexer`. Buffer reused via
/// `std.fmt.bufPrint` into a per-call scratch (returned by reference;
/// callers must use immediately — fine for a single `w.print`).
fn utcDate(ts: i64) []const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(ts, 0)) };
    const day_secs = epoch.getDaySeconds();
    _ = day_secs;
    const ed = epoch.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const buf = struct {
        threadlocal var s: [16]u8 = undefined;
    };
    return std.fmt.bufPrint(&buf.s, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year,
        @intFromEnum(md.month),
        md.day_index + 1,
    }) catch "????-??-??";
}

fn typeLabel(t: u32) []const u8 {
    return switch (t) {
        14 => "Ren'Py",
        13 => "RPGM",
        19 => "Unity",
        20 => "Unreal",
        5 => "HTML",
        4 => "Flash",
        6 => "Java",
        22 => "Wolf RPG",
        10 => "QSP",
        21 => "WebGL",
        2 => "ADRIFT",
        11 => "RAGS",
        16 => "Tads",
        9 => "Other",
        17 => "Tool",
        else => "Unknown",
    };
}

fn statusLabel(s: u32) []const u8 {
    return switch (s) {
        1 => "Ongoing",
        2 => "Completed",
        3 => "On Hold",
        4 => "Abandoned",
        else => "Unknown",
    };
}

/// "Yes" / "No" / null based on tag list. F95Checker's Tag enum only
/// has a single `censored` entry (id 40 → label "censored"); absence
/// is ambiguous (could be uncensored OR could just mean the thread
/// didn't bother to tag it), so we only emit "Yes" when present.
fn censoredLabel(tags: []const []const u8) ?[]const u8 {
    for (tags) |t| {
        if (std.ascii.eqlIgnoreCase(t, "censored")) return "Yes";
    }
    return null;
}

/// Best-effort language label from tags. F95Checker's Tag table only
/// flags "japanese game" explicitly; everything else is implicit in
/// the thread title prefix, which the indexer doesn't preserve.
fn languageLabel(tags: []const []const u8) ?[]const u8 {
    for (tags) |t| {
        if (std.ascii.eqlIgnoreCase(t, "japanese game")) return "Japanese";
    }
    return null;
}

/// Render the downloads tab content using f69's structured-text
/// format (see `renderStructuredText` in `src/ui/screens/detail.zig`):
///
///   `## text`                      → H2 header span (highlight style)
///   `[B]bold[/B]`                  → bold span
///   `[LINK=url]label[/LINK]`       → clickable hyperlink
///   `• ` (U+2022 + space)          → bulleted line
///
/// F95Zone OPs commonly use two layers: outer section banners
/// ("Chapter 4 v0.45 Full") with no direct links, then download
/// buckets under them ("Win/Linux", "Mac", "Extras") that carry the
/// actual hosts. The indexer preserves both — empty-link groups are
/// the headers; non-empty groups are buckets. We render headers as
/// `## H2` and buckets as `[B]label[/B]` + bullets so the hierarchy
/// is visible at a glance instead of being a flat wall of bold rows.
///
/// XPath-stub URLs (`//a[starts-with(...)]`) are F95Checker scraper
/// hints the indexer couldn't resolve — useless to the user, dropped
/// at render. A bucket that's left with zero resolvable links after
/// the drop is skipped entirely so the user doesn't see "Win/Linux"
/// followed by nothing.
///
/// Returns a freshly-`alloc`-owned `[]u8`. Caller frees.
pub fn buildDownloadsMd(
    alloc: std.mem.Allocator,
    groups: []const DownloadGroup,
) ![]u8 {
    if (groups.len == 0) return alloc.alloc(u8, 0);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    var any_emitted: bool = false;
    for (groups) |g| {
        // Section banner — empty-links group becomes a `## H2` header.
        if (g.links.len == 0) {
            if (g.label.len == 0) continue;
            if (any_emitted) try buf.appendSlice(alloc, "\n");
            try buf.appendSlice(alloc, "## ");
            try buf.appendSlice(alloc, g.label);
            try buf.append(alloc, '\n');
            any_emitted = true;
            continue;
        }

        // Download bucket — count real links first; skip if all the
        // indexer gave us are unresolved XPath stubs.
        var resolvable: usize = 0;
        for (g.links) |link| {
            if (!isXPathStub(link.url)) resolvable += 1;
        }
        if (resolvable == 0) continue;

        if (any_emitted) try buf.appendSlice(alloc, "\n");

        // F95-native inline format:
        //    `[B]Win/Linux:[/B] [LINK=u]MEGA[/LINK] - [LINK=u]MIXDROP[/LINK] - …`
        // One line per bucket. The structured-text renderer wraps the
        // line when it exceeds the column width, which matches the
        // forum's behavior under narrow viewports.
        if (g.label.len > 0) {
            try buf.appendSlice(alloc, "[B]");
            try buf.appendSlice(alloc, g.label);
            try buf.appendSlice(alloc, ":[/B] ");
        }
        var first: bool = true;
        for (g.links) |link| {
            if (isXPathStub(link.url)) continue;
            if (!first) try buf.appendSlice(alloc, " - ");
            try buf.appendSlice(alloc, "[LINK=");
            try buf.appendSlice(alloc, link.url);
            try buf.appendSlice(alloc, "]");
            try buf.appendSlice(alloc, link.host);
            try buf.appendSlice(alloc, "[/LINK]");
            first = false;
        }
        try buf.append(alloc, '\n');
        any_emitted = true;
    }
    return try buf.toOwnedSlice(alloc);
}

/// True if a URL is an unresolved XPath placeholder from F95Checker's
/// scraper (e.g. `//a[starts-with(@href,'https://mixdrop.ag/')][1]`).
/// Real URLs always start with a scheme.
fn isXPathStub(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "//");
}
