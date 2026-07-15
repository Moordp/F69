// Thread page scraper. Pulls everything from a single thread URL:
// rating, votes, version, cover, screenshots, tags, download links.
//
// Phase 1 covers: name, rating, vote count. Version/developer/cover/links
// follow once we have offline fixtures captured (see docs/PLAN.md).

const std = @import("std");
const errs = @import("errors.zig");
const domain = @import("domain.zig");
const cli = @import("client.zig");
const Client = cli.Client;

const log = std.log.scoped(.f95_scrape);

/// Fetch a thread page and pull whatever scraping we currently support.
/// Caller owns every non-null []const u8 in the returned struct.
pub fn scrape(client: *Client, alloc: std.mem.Allocator, url: []const u8) errs.Error!domain.ScrapedThread {
    const body = try client.get(url);
    defer alloc.free(body);

    var out: domain.ScrapedThread = .{};
    // Free everything we already dup'd if a later allocation OOMs.
    // ScrapedThread is value-returned — caller never sees a partially
    // populated struct, so we own cleanup right up to the success path.
    errdefer freeScraped(alloc, &out);

    out.rating = extractRating(body);
    out.vote_count = extractVoteCount(body);

    // Diagnostic: when rating is non-null but vote count is missing,
    // F95 changed the markup again. Dump 200 bytes around the rating
    // attribute so we can see what they're using now.
    if (out.rating != null and out.vote_count == null) {
        const anchor: ?usize = blk: {
            const m1 = "data-initial-rating=\"";
            if (std.mem.indexOf(u8, body, m1)) |i| break :blk i;
            const m2 = "data-rating=\"";
            if (std.mem.indexOf(u8, body, m2)) |i| break :blk i;
            break :blk null;
        };
        if (anchor) |a| {
            const start = if (a > 80) a - 80 else 0;
            const end = @min(body.len, a + 200);
            log.warn("vote count missing — rating widget snippet: '{s}'", .{body[start..end]});
        } else {
            log.warn("vote count missing — no rating-attr anchor found", .{});
        }
    }
    if (extractName(body)) |slice| {
        // Decode HTML entities (&#039; / &amp; / &nbsp; etc.) before
        // parsing so the parser sees `Ren'Py` instead of `Ren&#039;Py`.
        // The decode buffer is sized for typical title lengths; titles
        // longer than 512 chars fall back to the raw HTML-escaped form.
        var decode_buf: [512]u8 = undefined;
        const decoded = decodeHtmlEntities(&decode_buf, slice);
        const parts = parseTitleParts(decoded);
        out.name = alloc.dupe(u8, parts.name) catch return errs.Error.OutOfMemory;
        if (parts.version) |v| {
            out.version = alloc.dupe(u8, v) catch return errs.Error.OutOfMemory;
        }
        if (parts.developer) |d| {
            out.developer = alloc.dupe(u8, d) catch return errs.Error.OutOfMemory;
        }
        if (parts.engine_str) |e| {
            out.engine_str = alloc.dupe(u8, e) catch return errs.Error.OutOfMemory;
        }
        if (parts.status_str) |s| {
            out.dev_status_str = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
        }
    }
    if (extractCoverUrl(body)) |slice| {
        // Strip /thumb/ if F95 served the thumbnail URL via og:image
        // (some skin/version combos do). The full-size lives at the
        // same path with the segment removed.
        var buf: [1024]u8 = undefined;
        const upgraded = upgradeFromThumb(&buf, slice);
        out.cover_url = alloc.dupe(u8, upgraded) catch return errs.Error.OutOfMemory;
    }
    // tags is non-critical: an OOM here drops the tag list rather than
    // failing the whole scrape. Numeric fields are still useful.
    out.tags = extractTags(alloc, body) catch &.{};
    out.screenshots = extractScreenshots(alloc, body, out.cover_url) catch &.{};

    // OP-derived plain-text sections. Each scraper returns null on
    // miss; sync persists whatever was found and leaves the rest
    // untouched.
    out.description_md = extractOverview(alloc, body) catch null;
    out.changelog_md = extractChangelog(alloc, body) catch null;
    out.reviews_md = extractReviews(alloc, body) catch null;
    out.downloads_md = extractDownloadsSection(alloc, body) catch null;
    out.download_links = extractDownloadLinks(alloc, body) catch &.{};
    out.last_updated_at = extractLastUpdatedAt(body);
    out.thread_info_md = extractThreadInfo(alloc, body) catch null;
    // Re-derive the "Censored:" value from the formatted info block
    // so we have a structured copy for filtering. Cheap — it just
    // does a substring scan on the small thread_info_md blob.
    if (out.thread_info_md) |info| {
        if (findKeyValueInPlain(info, "Censored")) |raw| {
            out.censored_str = alloc.dupe(u8, raw) catch null;
        }
    }

    // Cover fallback: when og:image is missing or invalid, promote
    // the first OP image to cover so the carousel always has a slide
    // 0 worth showing. Shift the rest of the list down so we don't
    // duplicate it as a screenshot.
    if (out.cover_url == null and out.screenshots.len > 0) {
        out.cover_url = out.screenshots[0];
        const new_len = out.screenshots.len - 1;
        const rest: [][]const u8 = alloc.alloc([]const u8, new_len) catch return errs.Error.OutOfMemory;
        for (out.screenshots[1..], 0..) |s, k| rest[k] = s;
        // Old element [0] was transferred to cover_url, so don't free
        // the inner string. Free the old outer slice; replace with
        // the shifted one.
        alloc.free(out.screenshots);
        out.screenshots = rest;
    }

    return out;
}

/// Cap on screenshots per thread. Real F95 OPs rarely exceed ~15
/// screenshots; 20 covers virtually all cases. At JPEG q90 (~150 KB
/// avg) the worst case for a 1500-game library is ~4.5 GB, which is
/// acceptable. Bumping or removing this cap is fine if disk pressure
/// stops mattering.
const MAX_SCREENSHOTS: usize = 20;

/// Pull image URLs from the OP body. F95 hosts thread images on
/// `attachments.f95zone.to`, so we whitelist that origin to avoid
/// accidentally collecting avatars / smilies / forum chrome.
///
/// Strategy mirrors XLibrary's browser-extension scraper:
///   - Scope to the thread-starter article so quoted replies and
///     signatures don't pollute the list.
///   - Pull URLs from `<a href=...>` (full-size) AND `<img>` srcs,
///     but always upgrade `/thumb/` → `/` so the carousel never
///     shows a 100×100 thumbnail blown up to 480×270.
///   - Filter by file extension so non-image attachments (.zip,
///     .mp4, save files) don't get queued as screenshots.
///
/// `exclude` is the cover URL; skip it so the carousel doesn't
/// double-show the OP banner.
///
/// Caller owns the outer slice and every inner string; free via
/// `freeStringList`.
fn extractScreenshots(
    alloc: std.mem.Allocator,
    html: []const u8,
    exclude: ?[]const u8,
) ![]const []const u8 {
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit(); // keys borrow from out; freed there

    var out: std.ArrayList([]const u8) = .empty;
    errdefer freeStringList(alloc, &out);

    // Restrict the search to the OP article. F95's XenForo emits the
    // thread starter as the first `<article ... class="...message-threadStarterPost...">`.
    // If the marker isn't found (forum skin churn), fall back to the
    // full HTML — we still rely on the host whitelist + extension
    // filter, so worst case is a few extra duplicates.
    const scope = opBodyRange(html) orelse html;

    // Markers we accept. Each one's value is a URL we URL-clean and
    // route through `attachments.f95zone.to/.../<file>.<img-ext>`.
    //   <a href="https://attachments.f95zone.to/...">    full size, lightbox link
    //   <img src="...">                                  inline image (often a thumb)
    //   <img data-src="...">                             lazy-loaded inline (also often thumb)
    //   data-src="..."                                   bbCode/lightbox attribute on wrappers
    const markers = [_][]const u8{
        "href=\"https://attachments.f95zone.to/",
        "<img src=\"",
        "<img data-src=\"",
        " data-src=\"",
    };

    for (markers) |marker| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, scope, pos, marker)) |i| {
            const v_start = i + marker.len;
            const close = std.mem.indexOfScalarPos(u8, scope, v_start, '"') orelse break;
            pos = close + 1;

            // For the href flavor, the marker already swallowed the
            // origin prefix; rebuild the absolute URL to feed the
            // common path below.
            const raw = scope[v_start..close];
            var rebuilt_buf: [1024]u8 = undefined;
            const abs_url: []const u8 = if (std.mem.startsWith(u8, marker, "href="))
                std.fmt.bufPrint(&rebuilt_buf, "https://attachments.f95zone.to/{s}", .{raw}) catch continue
            else
                raw;

            // Host whitelist — drops avatars (`xenforo-avatar.s3...`),
            // smilies, forum chrome.
            if (!std.mem.startsWith(u8, abs_url, "https://attachments.f95zone.to/")) continue;

            // Extension filter — drops .zip, .mp4, save files, .torrent.
            if (!isImageUrlByExtension(abs_url)) continue;

            // Upgrade thumbnails to full-size. F95 stores thumbs at
            // `/YYYY/MM/thumb/<filename>` and full at
            // `/YYYY/MM/<filename>` — same filename, just no segment.
            var upgrade_buf: [1024]u8 = undefined;
            const url = upgradeFromThumb(&upgrade_buf, abs_url);

            // Skip the cover; we render it as carousel slide 0.
            if (exclude) |c| if (std.mem.eql(u8, url, c)) continue;

            if (seen.contains(url)) continue;

            const owned = try alloc.dupe(u8, url);
            errdefer alloc.free(owned);
            try seen.put(owned, {});
            try out.append(alloc, owned);

            if (out.items.len >= MAX_SCREENSHOTS) break;
        }
        if (out.items.len >= MAX_SCREENSHOTS) break;
    }
    return out.toOwnedSlice(alloc);
}

/// Locate the OP article's body in F95's XenForo HTML. The thread
/// starter post carries `class="...message-threadStarterPost..."` on
/// its `<article>`; we slice from that marker to the next `</article>`.
/// Returns null if the marker isn't found (callers should fall back
/// to scanning the full document).
fn opBodyRange(html: []const u8) ?[]const u8 {
    const marker = "message-threadStarterPost";
    const start = std.mem.indexOf(u8, html, marker) orelse return null;
    const end = std.mem.indexOfPos(u8, html, start, "</article>") orelse return null;
    return html[start..end];
}

/// Convert `https://attachments.f95zone.to/2018/10/thumb/171170_…png`
/// → `https://attachments.f95zone.to/2018/10/171170_…png`.
/// Returns the upgraded URL written into `buf`, or `url` unchanged
/// if no `/thumb/` segment is present (or buf is too small).
fn upgradeFromThumb(buf: []u8, url: []const u8) []const u8 {
    const seg = "/thumb/";
    const at = std.mem.indexOf(u8, url, seg) orelse return url;
    const before = url[0..at];
    const after = url[at + seg.len ..];
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ before, after }) catch return url;
}

/// Reject anything that isn't an image by URL suffix. Cheap defense
/// against F95 OPs that link translation patches, save files, demo
/// videos etc. via `attachments.f95zone.to`. Case-insensitive — F95
/// preserves uploader-supplied filenames.
fn isImageUrlByExtension(url: []const u8) bool {
    const exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp" };
    // Lowercase the tail (last 8 bytes is enough to cover all our
    // extensions) into a small stack buffer.
    if (url.len < 4) return false;
    const tail_start = if (url.len > 8) url.len - 8 else 0;
    var tail_buf: [8]u8 = undefined;
    const tail = url[tail_start..];
    for (tail, 0..) |c, j| tail_buf[j] = std.ascii.toLower(c);
    const tail_lower = tail_buf[0..tail.len];
    inline for (exts) |ext| {
        if (std.mem.endsWith(u8, tail_lower, ext)) return true;
    }
    return false;
}

fn freeStringList(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |s| alloc.free(s);
    list.deinit(alloc);
}

fn freeScraped(alloc: std.mem.Allocator, s: *domain.ScrapedThread) void {
    if (s.name) |n| alloc.free(n);
    if (s.version) |v| alloc.free(v);
    if (s.developer) |d| alloc.free(d);
    if (s.engine_str) |e| alloc.free(e);
    if (s.dev_status_str) |d| alloc.free(d);
    if (s.thread_info_md) |t| alloc.free(t);
    if (s.censored_str) |c| alloc.free(c);
    if (s.cover_url) |c| alloc.free(c);
    if (s.description_md) |m| alloc.free(m);
    if (s.changelog_md) |m| alloc.free(m);
    if (s.reviews_md) |m| alloc.free(m);
    if (s.downloads_md) |m| alloc.free(m);
    if (s.tags.len > 0) {
        for (s.tags) |t| alloc.free(t);
        alloc.free(s.tags);
    }
    if (s.screenshots.len > 0) {
        for (s.screenshots) |u| alloc.free(u);
        alloc.free(s.screenshots);
    }
    if (s.download_links.len > 0) {
        for (s.download_links) |link| {
            alloc.free(link.url);
            if (link.label) |lab| alloc.free(lab);
        }
        alloc.free(s.download_links);
    }
}

/// XenForo emits each tag as `<a ... class="tagItem">TagName</a>`. We
/// scan linearly for the marker, slice the inner text. Bounded so a
/// pathological page can't blow up the slice. Caller owns the outer
/// slice and every inner string.
fn extractTags(alloc: std.mem.Allocator, html: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |t| alloc.free(t);
        out.deinit(alloc);
    }

    var rest = html;
    const marker = "class=\"tagItem\"";
    while (std.mem.indexOf(u8, rest, marker)) |i| {
        const after = rest[i + marker.len ..];
        const gt = std.mem.indexOfScalar(u8, after, '>') orelse {
            rest = after;
            continue;
        };
        const inner_start = gt + 1;
        const close = std.mem.indexOfPos(u8, after, inner_start, "</a>") orelse {
            rest = after;
            continue;
        };
        const text = std.mem.trim(u8, after[inner_start..close], " \t\n\r");
        if (text.len > 0 and text.len < 64) {
            const dup = try alloc.dupe(u8, text);
            errdefer alloc.free(dup);
            try out.append(alloc, dup);
        }
        rest = after[close + 4 ..];
        if (out.items.len >= 64) break; // sanity cap
    }
    return out.toOwnedSlice(alloc);
}

/// XenForo's rating widget exposes the average rating through several
/// markers depending on skin/version.
fn extractRating(html: []const u8) ?f32 {
    const markers = [_][]const u8{
        "data-initial-rating=\"",
        "data-rating=\"",
        "itemprop=\"ratingValue\" content=\"",
    };
    for (markers) |marker| {
        const start = std.mem.indexOf(u8, html, marker) orelse continue;
        const value_start = start + marker.len;
        const end = std.mem.indexOfScalarPos(u8, html, value_start, '"') orelse continue;
        const v = std.fmt.parseFloat(f32, html[value_start..end]) catch continue;
        return v;
    }
    return null;
}

/// XenForo's rating widget exposes the count through several markers
/// depending on skin/version. Try each in order — first hit wins.
fn extractVoteCount(html: []const u8) ?u32 {
    // F95's BetterRatings tooltip — the actual server-side source on
    // every thread page. Lives inside the `data-vote-content`
    // attribute on the rating <select>, HTML-double-escaped:
    //
    //   data-vote-content="&lt;div ...&gt;14 Votes&lt;/div&gt;"
    //
    // We scan for the encoded ` Votes&lt;` tail (case-insensitive on
    // "Votes" because some F95 skins capitalize differently) and walk
    // backwards over digits to read the count. This works across every
    // skin we've seen because BetterRatings emits the same template.
    {
        const tail_markers = [_][]const u8{ " Votes&lt;", " votes&lt;" };
        for (tail_markers) |tail| {
            if (std.mem.indexOf(u8, html, tail)) |i| {
                var end = i;
                while (end > 0 and (html[end - 1] == ' ' or html[end - 1] == '\t')) end -= 1;
                var start = end;
                while (start > 0 and std.ascii.isDigit(html[start - 1])) start -= 1;
                if (start < end) {
                    if (std.fmt.parseInt(u32, html[start..end], 10)) |n| return n else |_| {}
                }
            }
        }
    }

    // Attribute markers — most reliable when present.
    const attr_markers = [_][]const u8{
        "data-vote-count=\"",
        "data-rating-count=\"",
        "data-num-ratings=\"",
        "data-num-votes=\"",
    };
    for (attr_markers) |m| if (extractAttrU32(html, m)) |n| return n;

    // Schema.org microdata: `<meta itemprop="ratingCount" content="52">`.
    {
        const marker = "itemprop=\"ratingCount\" content=\"";
        if (std.mem.indexOf(u8, html, marker)) |start| {
            const value_start = start + marker.len;
            if (std.mem.indexOfScalarPos(u8, html, value_start, '"')) |end| {
                if (std.fmt.parseInt(u32, std.mem.trim(u8, html[value_start..end], " \t"), 10)) |n| {
                    return n;
                } else |_| {}
            }
        }
    }

    // Legacy span: `<span class="ratingStars--meta-value">52</span>`.
    {
        const marker = "ratingStars--meta-value\">";
        if (std.mem.indexOf(u8, html, marker)) |start| {
            const value_start = start + marker.len;
            if (std.mem.indexOfScalarPos(u8, html, value_start, '<')) |end| {
                if (std.fmt.parseInt(u32, std.mem.trim(u8, html[value_start..end], " \t\n\r"), 10)) |n| {
                    return n;
                } else |_| {}
            }
        }
    }

    // Last-resort text-scrape: scan for the rendered "(N votes)" /
    // "N votes" / "N ratings" patterns. F95 always shows the count
    // visibly in the rating widget on threads with at least one
    // vote, so this catches any skin we don't recognize attribute-
    // wise. Walk back from the marker over digits.
    const text_markers = [_][]const u8{ " votes", " ratings" };
    for (text_markers) |marker_text| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, html, pos, marker_text)) |i| {
            // Walk back over whitespace then digits.
            var end = i;
            while (end > pos and (html[end - 1] == ' ' or html[end - 1] == '\t')) end -= 1;
            var start = end;
            while (start > pos and std.ascii.isDigit(html[start - 1])) start -= 1;
            if (start < end) {
                if (std.fmt.parseInt(u32, html[start..end], 10)) |n| {
                    return n;
                } else |_| {}
            }
            pos = i + marker_text.len;
        }
    }
    return null;
}

/// Decomposed F95 thread title: "Game Name [v1.2.3] [Engine] [Developer]".
pub const TitleParts = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    developer: ?[]const u8 = null,
    /// Raw engine token like "Ren'Py" / "RPGM MV"; library maps to enum.
    engine_str: ?[]const u8 = null,
    /// Raw status token like "Completed" / "Abandoned" / "On Hold";
    /// library maps to `DevStatus`.
    status_str: ?[]const u8 = null,
};

/// Split a stripped title into name/version/developer.
///
/// F95 emits `<title>` in two patterns:
///   1. `Engine - Status - Game Name [Version] [Developer]`  (current)
///   2. `Game Name [Version] [Engine] [Developer]`           (older)
///
/// Pattern 1 is the prevalent one. We peel `X - ` prefix tokens off
/// the head whenever X matches a known engine or status word; the
/// rest of the head is the actual game name. Bracketed metadata
/// after the head is parsed for version + developer + engine fallback.
///
/// All returned slices borrow `title`; caller dupes if it needs to outlive.
pub fn parseTitleParts(title: []const u8) TitleParts {
    const trimmed = std.mem.trim(u8, title, " \t\n\r");
    const first_bracket_or_end: usize = std.mem.indexOfScalar(u8, trimmed, '[') orelse trimmed.len;
    const head = std.mem.trim(u8, trimmed[0..first_bracket_or_end], " \t\n\r");

    var parts: TitleParts = .{ .name = head };

    // Peel ` - `-separated leading tokens that match a known engine
    // or status. Stop at the first unrecognized token — the rest is
    // the actual game name. This is robust against game names that
    // themselves contain " - " (e.g. "Game - Subtitle") because the
    // peel only happens for recognized prefix words.
    {
        var work = head;
        while (true) {
            const sep_pos = std.mem.indexOf(u8, work, " - ") orelse break;
            const token = std.mem.trim(u8, work[0..sep_pos], " \t\n\r");
            if (token.len == 0) break;
            if (parts.engine_str == null and looksLikeEngine(token)) {
                parts.engine_str = token;
                work = std.mem.trim(u8, work[sep_pos + 3 ..], " \t\n\r");
                continue;
            }
            if (looksLikeStatus(token)) {
                if (parts.status_str == null) parts.status_str = token;
                work = std.mem.trim(u8, work[sep_pos + 3 ..], " \t\n\r");
                continue;
            }
            if (looksLikeCategoryPrefix(token)) {
                // F95 prefixes thread titles with the section name —
                // "VN - Ren'Py - Game" / "Comics - Title" / etc. Consume
                // it the same way as engine/status; we don't store the
                // category from the title because it's already implicit
                // in the thread's forum node.
                work = std.mem.trim(u8, work[sep_pos + 3 ..], " \t\n\r");
                continue;
            }
            break;
        }
        // Some F95 skins wrap the `<title>` element's text in single
        // quotes; the bookmark page sometimes does the same. Trim
        // them off so the displayed name doesn't read as
        // `'Game Name`. Also covers double quotes for completeness.
        parts.name = std.mem.trim(u8, work, "'\" \t");
    }

    // Bracketed metadata after the head: version + developer (+ engine
    // fallback for the older pattern).
    var rest = trimmed[first_bracket_or_end..];
    var last_other: ?[]const u8 = null;
    while (std.mem.indexOfScalar(u8, rest, '[')) |bs| {
        const after = rest[bs + 1 ..];
        const be = std.mem.indexOfScalar(u8, after, ']') orelse break;
        const raw = std.mem.trim(u8, after[0..be], " \t\n\r");
        rest = after[be + 1 ..];
        if (raw.len == 0) continue;

        if (parts.version == null and looksLikeVersion(raw)) {
            const v = if (raw.len >= 2 and (raw[0] == 'v' or raw[0] == 'V'))
                std.mem.trim(u8, raw[1..], " \t\n\r")
            else
                raw;
            parts.version = v;
        } else if (parts.engine_str == null and looksLikeEngine(raw)) {
            parts.engine_str = raw;
        } else if (looksLikeStatus(raw)) {
            if (parts.status_str == null) parts.status_str = raw;
        } else {
            last_other = raw;
        }
    }
    parts.developer = last_other;
    return parts;
}

/// Decode HTML character entities into UTF-8 text.
///
/// Handles:
///   - The named entities F95 actually uses: `amp` / `quot` / `apos`
///     / `nbsp` / `lt` / `gt` plus a handful of common Latin-1 +
///     punctuation entities (`hellip`, `mdash`, `ndash`, `ldquo`,
///     `rdquo`, `lsquo`, `rsquo`, `bull`, `copy`, `reg`, `trade`,
///     `deg`, `middot`, `euro`).
///   - Numeric refs in both forms: `&#NNN;` (decimal) and `&#xNN;`
///     (hex). Any Unicode codepoint up to U+10FFFF is emitted as
///     correctly-encoded UTF-8 (1..4 bytes). Codepoints that are
///     invisible formatting characters (zero-width space / joiner /
///     non-joiner / BOM, etc) are dropped so they don't leak into
///     the rendered string as silent layout glitches — see
///     `isInvisibleFormatChar`.
///
/// Returns a slice of `out_buf` containing the decoded text. Falls
/// back to returning the original `src` verbatim whenever the output
/// would overflow — caller never sees a truncated/garbled result.
const HTML_ENTITIES = std.StaticStringMap(u21).initComptime(.{
    .{ "amp", '&' },
    .{ "quot", '"' },
    .{ "apos", '\'' },
    .{ "nbsp", ' ' },
    .{ "lt", '<' },
    .{ "gt", '>' },
    .{ "hellip", 0x2026 },
    .{ "mdash", 0x2014 },
    .{ "ndash", 0x2013 },
    .{ "ldquo", 0x201C },
    .{ "rdquo", 0x201D },
    .{ "lsquo", 0x2018 },
    .{ "rsquo", 0x2019 },
    .{ "sbquo", 0x201A },
    .{ "bdquo", 0x201E },
    .{ "bull", 0x2022 },
    .{ "copy", 0x00A9 },
    .{ "reg", 0x00AE },
    .{ "trade", 0x2122 },
    .{ "deg", 0x00B0 },
    .{ "middot", 0x00B7 },
    .{ "euro", 0x20AC },
});

pub fn decodeHtmlEntities(out_buf: []u8, src: []const u8) []const u8 {
    if (src.len > out_buf.len) return src;
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] != '&') {
            if (n >= out_buf.len) return src;
            out_buf[n] = src[i];
            n += 1;
            i += 1;
            continue;
        }
        // Find the matching ';' within a small window. Real entities
        // are short (≤10 chars: longest we care about is `&trade;`
        // / `&hellip;`).
        const end = std.mem.indexOfScalarPos(u8, src, i + 1, ';') orelse {
            if (n >= out_buf.len) return src;
            out_buf[n] = src[i];
            n += 1;
            i += 1;
            continue;
        };
        if (end - i > 10) {
            if (n >= out_buf.len) return src;
            out_buf[n] = src[i];
            n += 1;
            i += 1;
            continue;
        }
        const entity = src[i + 1 .. end];

        // Decide on a codepoint (or null for "unknown"). We then go
        // through a single UTF-8 emit at the bottom so both named
        // and numeric refs handle multi-byte output identically.
        // Named entities resolve through a comptime perfect-hash map
        // (`HTML_ENTITIES`) so each lookup is one probe instead of
        // the 22-arm mem.eql cascade the table replaced.
        const codepoint: ?u21 = blk: {
            if (HTML_ENTITIES.get(entity)) |cp| break :blk cp;
            // Numeric: `&#NNN;` (decimal) or `&#xNN;` (hex).
            if (entity.len >= 2 and entity[0] == '#') {
                const num_start: usize = if (entity[1] == 'x' or entity[1] == 'X') 2 else 1;
                const base: u8 = if (num_start == 2) 16 else 10;
                const code = std.fmt.parseInt(u32, entity[num_start..], base) catch break :blk null;
                if (code > 0x10FFFF) break :blk null; // outside Unicode
                break :blk @intCast(code);
            }
            break :blk null;
        };

        if (codepoint) |cp| {
            // Invisible formatting chars (zero-width space etc) are
            // dropped — they bloat byte counts and confuse text
            // measurement without contributing any visible content.
            if (isInvisibleFormatChar(cp)) {
                i = end + 1;
                continue;
            }
            // Encode as 1..4 UTF-8 bytes.
            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(cp, &utf8_buf) catch {
                // Codepoint not a valid scalar (surrogate / out of
                // range). Treat as unknown and keep the literal.
                const span = src[i .. end + 1];
                if (n + span.len > out_buf.len) return src;
                @memcpy(out_buf[n .. n + span.len], span);
                n += span.len;
                i = end + 1;
                continue;
            };
            if (n + utf8_len > out_buf.len) return src;
            @memcpy(out_buf[n .. n + utf8_len], utf8_buf[0..utf8_len]);
            n += utf8_len;
            i = end + 1;
        } else {
            // Unknown entity — keep the literal text so we never lie
            // about what the OP contained.
            const span = src[i .. end + 1];
            if (n + span.len > out_buf.len) return src;
            @memcpy(out_buf[n .. n + span.len], span);
            n += span.len;
            i = end + 1;
        }
    }
    return out_buf[0..n];
}

/// True for codepoints that render as nothing but bloat downstream
/// byte counts and confuse the text renderer's whitespace handling.
/// Decoder strips these so a `&#8203;` sprinkled by F95's editor
/// doesn't leak through as an invisible mystery byte.
fn isInvisibleFormatChar(cp: u21) bool {
    return switch (cp) {
        0x200B, // zero-width space
        0x200C, // zero-width non-joiner
        0x200D, // zero-width joiner
        0x2060, // word joiner
        0xFEFF, // BOM / zero-width no-break space
        => true,
        else => false,
    };
}

test "decodeHtmlEntities: numeric Unicode → UTF-8" {
    var buf: [64]u8 = undefined;
    // U+2026 horizontal ellipsis → E2 80 A6
    try std.testing.expectEqualStrings("Hello…", decodeHtmlEntities(&buf, "Hello&#8230;"));
    try std.testing.expectEqualStrings("Hello…", decodeHtmlEntities(&buf, "Hello&#x2026;"));
}

test "decodeHtmlEntities: zero-width space dropped" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ab", decodeHtmlEntities(&buf, "a&#8203;b"));
}

test "decodeHtmlEntities: named non-ASCII entities" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("—", decodeHtmlEntities(&buf, "&mdash;"));
    try std.testing.expectEqualStrings("…", decodeHtmlEntities(&buf, "&hellip;"));
    try std.testing.expectEqualStrings("\u{2018}x\u{2019}", decodeHtmlEntities(&buf, "&lsquo;x&rsquo;"));
}

/// Match F95's forum-section prefix words. Threads in the "Games"
/// section start with the engine alone, but the other sections
/// (Comics, Animations, ASMR, Mods, Cheat Mods, Manga, etc.) prepend
/// the section name as the very first " - "-separated token, e.g.
/// "VN - Ren'Py - Innocent Witches [v0.12B] [Sad Crab]" for the
/// Visual Novel section. We strip those so the parsed name never
/// inherits the section noise.
fn looksLikeCategoryPrefix(token: []const u8) bool {
    const words = [_][]const u8{
        "VN",
        "Comics",
        "Comic",
        "Animation",
        "Animations",
        "Manga",
        "ASMR",
        "Cheat Mod",
        "Cheat Mods",
        "Mod",
        "Mods",
        "Others",
        "Other",
        "3DCG",
        "2DCG",
        "CG",
    };
    for (words) |w| {
        if (std.ascii.eqlIgnoreCase(token, w)) return true;
    }
    return false;
}

/// Match F95's status/state words used as title prefixes — covers the
/// header peel for "QSP - Completed - Game Name" plus pre-bracketed
/// `[Completed]` for older threads.
fn looksLikeStatus(token: []const u8) bool {
    const words = [_][]const u8{
        "Completed", "Complete",
        "Abandoned", "Onhold",
        "On hold",   "On-hold",
        "Ongoing",   "Demo",
        "Final",
    };
    for (words) |w| {
        if (std.ascii.eqlIgnoreCase(token, w)) return true;
    }
    return false;
}

/// Comptime perfect-hash set of engine tokens (alphabetic-only,
/// lowercased) that `looksLikeEngine` accepts. The previous hand-rolled
/// list carried `"ue4"`, `"ue5"`, and `"html5"` keys that the
/// alphabetic-only normalisation stripped before comparison — they
/// were dead letters and are omitted here. `"html"` still catches
/// `html5` input (digit stripped); `ue4`/`ue5` inputs normalise to
/// `"ue"` which the original cascade also never accepted.
const ENGINE_TOKENS = std.StaticStringMap(void).initComptime(.{
    .{ "renpy", {} },
    .{ "rpgm", {} },
    .{ "rpgmaker", {} },
    .{ "rpgmmv", {} },
    .{ "rpgmakermv", {} },
    .{ "rpgmmz", {} },
    .{ "rpgmakermz", {} },
    .{ "rpgmvx", {} },
    .{ "rpgmakervx", {} },
    .{ "rpgmakervxace", {} },
    .{ "unity", {} },
    .{ "unreal", {} },
    .{ "unrealengine", {} },
    .{ "html", {} },
    .{ "flash", {} },
    .{ "java", {} },
    .{ "wolfrpg", {} },
    .{ "wolfrpgeditor", {} },
    .{ "qsp", {} },
    .{ "tyranobuilder", {} },
    .{ "tyrano", {} },
    .{ "twine", {} },
    .{ "others", {} },
    .{ "other", {} },
});

/// Match common F95 engine bracket tokens. Engine.fromBracket has the
/// authoritative mapping; this is a coarse pre-filter so we don't claim
/// random bracket text (genres, "Voyeur", etc.) as the engine.
fn looksLikeEngine(token: []const u8) bool {
    var lc_buf: [32]u8 = undefined;
    var n: usize = 0;
    for (token) |c| {
        if (std.ascii.isAlphabetic(c) and n < lc_buf.len) {
            lc_buf[n] = std.ascii.toLower(c);
            n += 1;
        }
    }
    return ENGINE_TOKENS.has(lc_buf[0..n]);
}

/// Heuristic: is this bracket token a version string?
/// - Starts with 'v'/'V' followed by digit (`v0.20`, `V1.0a`)
/// - Starts with a digit (`0.5.1`)
/// - Matches a known end-state word
fn looksLikeVersion(token: []const u8) bool {
    if (token.len == 0) return false;
    if (token.len >= 2 and (token[0] == 'v' or token[0] == 'V') and std.ascii.isDigit(token[1])) return true;
    if (std.ascii.isDigit(token[0])) return true;
    const end_states = [_][]const u8{ "Final", "Demo", "Complete", "Completed", "Beta", "Alpha", "Done" };
    for (end_states) |s| {
        if (std.ascii.eqlIgnoreCase(token, s)) return true;
    }
    return false;
}

/// Pull the page title — the first `<title>...</title>` block. F95
/// titles look like "Game Name [v1.2] [Developer] | F95zone"; strip the
/// trailing site suffix but keep the rest as-is for now.
fn extractName(html: []const u8) ?[]const u8 {
    const open = "<title>";
    const start = std.mem.indexOf(u8, html, open) orelse return null;
    const value_start = start + open.len;
    const close = std.mem.indexOfPos(u8, html, value_start, "</title>") orelse return null;
    var slice = html[value_start..close];
    // Drop a single " | F95zone" / " | F95Zone" / " - F95zone" suffix.
    const seps = [_][]const u8{ " | ", " - " };
    for (seps) |sep| {
        if (std.mem.lastIndexOf(u8, slice, sep)) |idx| {
            const tail = slice[idx + sep.len ..];
            if (std.ascii.startsWithIgnoreCase(tail, "f95")) {
                slice = std.mem.trim(u8, slice[0..idx], " \t\n\r");
                break;
            }
        }
    }
    return slice;
}

/// Pull the cover image URL — F95's OG metadata exposes it as
/// `<meta property="og:image" content="https://...">`.
///
/// Pages without a thread-specific banner emit the site-default logo
/// (`/assets/favicon-32x32.png` and similar) under the same property.
/// Walk every match and return the first that *isn't* obviously a
/// site asset; if every candidate looks like a logo/favicon we
/// return null and the UI falls back to the placeholder.
fn extractCoverUrl(html: []const u8) ?[]const u8 {
    // Primary strategy (matches XLibrary): the cover IS the first
    // image in the OP body. F95 OPs always lead with the banner, so
    // grabbing the first `attachments.f95zone.to` image inside the
    // thread-starter article gives us the right thing — even when
    // `og:image` points elsewhere (sometimes a screenshot, sometimes
    // a generic site banner). Caller is responsible for stripping
    // any `/thumb/` segment.
    if (firstOpBodyImageUrl(html)) |u| return u;

    // Fallback for skins where the OP scope marker isn't found.
    const markers = [_][]const u8{
        "property=\"og:image\" content=\"",
        "property=\"og:image:secure_url\" content=\"",
    };
    for (markers) |marker| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, html, pos, marker)) |i| {
            const value_start = i + marker.len;
            const end = std.mem.indexOfScalarPos(u8, html, value_start, '"') orelse break;
            const url = html[value_start..end];
            if (looksLikeCover(url)) return url;
            pos = end + 1;
        }
    }
    return null;
}

/// Walk the OP body in a single pass; return the first URL that
/// points at `attachments.f95zone.to/...<image-ext>`. Mirrors
/// XLibrary's `extractCover` — F95 OPs lead with the banner.
///
/// We look for the marker `https://attachments.f95zone.to/` directly
/// (anywhere in the document is an attachments URL — `<img src=`,
/// `<img data-src=`, `<a href=`, all of those embed it). The very
/// first occurrence whose URL ends in an image extension is the
/// banner. The slice returned borrows from `html` so it's stable
/// for caller's `dupe`.
fn firstOpBodyImageUrl(html: []const u8) ?[]const u8 {
    const scope = opBodyRange(html) orelse return null;
    const prefix = "https://attachments.f95zone.to/";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, scope, pos, prefix)) |i| {
        // Find the closing quote that bounds this URL.
        const end = std.mem.indexOfAnyPos(u8, scope, i, "\"' ") orelse break;
        const url = scope[i..end];
        pos = end;
        if (isImageUrlByExtension(url)) return url;
    }
    return null;
}

/// Reject the obvious "this thread has no banner, here's our site
/// default" cases. Real F95 covers live at `attachments.f95zone.to`,
/// not under `/assets/`.
fn looksLikeCover(url: []const u8) bool {
    if (url.len == 0) return false;
    if (std.mem.indexOf(u8, url, "favicon") != null) return false;
    if (std.mem.indexOf(u8, url, "/assets/") != null) return false;
    if (std.mem.endsWith(u8, url, ".ico")) return false;
    return true;
}

fn extractAttrU32(html: []const u8, marker: []const u8) ?u32 {
    const start = std.mem.indexOf(u8, html, marker) orelse return null;
    const value_start = start + marker.len;
    const end = std.mem.indexOfScalarPos(u8, html, value_start, '"') orelse return null;
    return std.fmt.parseInt(u32, html[value_start..end], 10) catch null;
}

test "extractRating" {
    const html = "<select name=\"rating\" data-initial-rating=\"4.30\">";
    try std.testing.expectApproxEqAbs(@as(f32, 4.30), extractRating(html).?, 0.001);
    try std.testing.expect(extractRating("nothing") == null);
}

test "extractVoteCount via meta-value" {
    const html = "<em><span class=\"ratingStars--meta-value\">152</span> votes</em>";
    try std.testing.expectEqual(@as(u32, 152), extractVoteCount(html).?);
}

test "extractVoteCount via BetterRatings tooltip (encoded)" {
    const html = "data-vote-content=\"&lt;div ...&gt;14 Votes&lt;/div&gt;\"";
    try std.testing.expectEqual(@as(u32, 14), extractVoteCount(html).?);
}

test "extractVoteCount tooltip with zero" {
    const html = "data-vote-content=\"&lt;div&gt;0 Votes&lt;/div&gt;\"";
    try std.testing.expectEqual(@as(u32, 0), extractVoteCount(html).?);
}

test "extractVoteCount via data-rating-count" {
    const html = "<div data-rating-count=\"99\">";
    try std.testing.expectEqual(@as(u32, 99), extractVoteCount(html).?);
}

test "extractName strips F95 suffix" {
    const html = "<title>Some Game [v1.0] [Dev] | F95zone</title>";
    try std.testing.expectEqualStrings("Some Game [v1.0] [Dev]", extractName(html).?);
}

test "extractName keeps title without separator" {
    const html = "<title>Just A Page</title>";
    try std.testing.expectEqualStrings("Just A Page", extractName(html).?);
}

test "extractCoverUrl from og:image" {
    const html = "<meta property=\"og:image\" content=\"https://attachments.f95zone.to/2024/banner.jpg\">";
    try std.testing.expectEqualStrings(
        "https://attachments.f95zone.to/2024/banner.jpg",
        extractCoverUrl(html).?,
    );
}

test "extractCoverUrl falls back to secure_url" {
    const html = "<meta property=\"og:image:secure_url\" content=\"https://x/y.png\">";
    try std.testing.expectEqualStrings("https://x/y.png", extractCoverUrl(html).?);
}

test "decodeHtmlEntities common entities" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Ren'Py", decodeHtmlEntities(&buf, "Ren&#039;Py"));
    try std.testing.expectEqualStrings("A & B", decodeHtmlEntities(&buf, "A &amp; B"));
    try std.testing.expectEqualStrings("\"quoted\"", decodeHtmlEntities(&buf, "&quot;quoted&quot;"));
    try std.testing.expectEqualStrings("a b", decodeHtmlEntities(&buf, "a&nbsp;b"));
    try std.testing.expectEqualStrings("plain text", decodeHtmlEntities(&buf, "plain text"));
}

test "parseTitleParts: dash-prefixed engine + status" {
    const p = parseTitleParts("QSP - Completed - No Escape [Final] [Retro Kaktus]");
    try std.testing.expectEqualStrings("No Escape", p.name);
    try std.testing.expectEqualStrings("QSP", p.engine_str.?);
    try std.testing.expectEqualStrings("Final", p.version.?);
    try std.testing.expectEqualStrings("Retro Kaktus", p.developer.?);
}

test "parseTitleParts: dash-prefixed engine only" {
    const p = parseTitleParts("Ren'Py - Innocent Witches [v0.13J] [Sad Crab Company]");
    try std.testing.expectEqualStrings("Innocent Witches", p.name);
    try std.testing.expectEqualStrings("Ren'Py", p.engine_str.?);
    try std.testing.expectEqualStrings("0.13J", p.version.?);
    try std.testing.expectEqualStrings("Sad Crab Company", p.developer.?);
}

test "parseTitleParts: VN section prefix + engine" {
    const p = parseTitleParts("VN - Ren'Py - Innocent Witches [v0.12B] [Sad Crab]");
    try std.testing.expectEqualStrings("Innocent Witches", p.name);
    try std.testing.expectEqualStrings("Ren'Py", p.engine_str.?);
    try std.testing.expectEqualStrings("0.12B", p.version.?);
    try std.testing.expectEqualStrings("Sad Crab", p.developer.?);
}

test "parseTitleParts: Comics section + status" {
    const p = parseTitleParts("Comics - Completed - Some Series [v1.0] [Author]");
    try std.testing.expectEqualStrings("Some Series", p.name);
    try std.testing.expectEqualStrings("1.0", p.version.?);
    try std.testing.expectEqualStrings("Author", p.developer.?);
}

test "parseTitleParts: name with dash is preserved" {
    // Stop peeling at first unrecognized token. "Game" is not an engine
    // or status, so "Game - Subtitle" stays as the name.
    const p = parseTitleParts("Game - Subtitle [v1.0] [Studio]");
    try std.testing.expectEqualStrings("Game - Subtitle", p.name);
    try std.testing.expectEqualStrings("1.0", p.version.?);
    try std.testing.expectEqualStrings("Studio", p.developer.?);
}

test "upgradeFromThumb strips /thumb/" {
    var buf: [256]u8 = undefined;
    const u = upgradeFromThumb(&buf, "https://attachments.f95zone.to/2018/10/thumb/171170_x.png");
    try std.testing.expectEqualStrings(
        "https://attachments.f95zone.to/2018/10/171170_x.png",
        u,
    );
}

test "upgradeFromThumb passthrough on non-thumb url" {
    var buf: [256]u8 = undefined;
    const u = upgradeFromThumb(&buf, "https://attachments.f95zone.to/2018/10/171170_x.png");
    try std.testing.expectEqualStrings(
        "https://attachments.f95zone.to/2018/10/171170_x.png",
        u,
    );
}

test "isImageUrlByExtension accepts common image suffixes" {
    try std.testing.expect(isImageUrlByExtension("https://x/y.jpg"));
    try std.testing.expect(isImageUrlByExtension("https://x/y.JPEG"));
    try std.testing.expect(isImageUrlByExtension("https://x/y.png"));
    try std.testing.expect(isImageUrlByExtension("https://x/y.GIF"));
    try std.testing.expect(isImageUrlByExtension("https://x/y.WebP"));
    try std.testing.expect(!isImageUrlByExtension("https://x/y.zip"));
    try std.testing.expect(!isImageUrlByExtension("https://x/y.mp4"));
    try std.testing.expect(!isImageUrlByExtension("https://x/y"));
}

test "extractScreenshots upgrades thumbs and skips zips" {
    const html =
        "<article class=\"message-threadStarterPost\">" ++
        "<a href=\"https://attachments.f95zone.to/2018/10/171170_GS.png\">" ++
        "<img src=\"https://attachments.f95zone.to/2018/10/thumb/171170_GS.png\" /></a>" ++
        "<a href=\"https://attachments.f95zone.to/2017/06/19133_translation_pic.zip\">patch</a>" ++
        "<img data-src=\"https://attachments.f95zone.to/2019/05/323315_jade.gif\" />" ++
        "</article>";
    const got = try extractScreenshots(std.testing.allocator, html, null);
    defer {
        for (got) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(got);
    }
    // Expect: full-size png (not thumb), gif. Not zip.
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings(
        "https://attachments.f95zone.to/2018/10/171170_GS.png",
        got[0],
    );
    try std.testing.expectEqualStrings(
        "https://attachments.f95zone.to/2019/05/323315_jade.gif",
        got[1],
    );
}

test "extractScreenshots skips images outside the OP article" {
    const html =
        "<article class=\"message-threadStarterPost\">" ++
        "<img src=\"https://attachments.f95zone.to/2020/01/op.png\">" ++
        "</article>" ++
        "<article class=\"message message-comment\">" ++
        "<img src=\"https://attachments.f95zone.to/2020/01/comment.png\">" ++
        "</article>";
    const got = try extractScreenshots(std.testing.allocator, html, null);
    defer {
        for (got) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(got);
    }
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("https://attachments.f95zone.to/2020/01/op.png", got[0]);
}

test "extractCoverUrl skips site-default favicon" {
    const html =
        \\<meta property="og:image" content="https://f95zone.to/assets/favicon-32x32.png">
        \\<meta property="og:image" content="https://attachments.f95zone.to/2024/real-cover.jpg">
    ;
    try std.testing.expectEqualStrings(
        "https://attachments.f95zone.to/2024/real-cover.jpg",
        extractCoverUrl(html).?,
    );
}

test "extractCoverUrl: only favicon → null" {
    const html = "<meta property=\"og:image\" content=\"https://f95zone.to/assets/logo.png\">";
    try std.testing.expect(extractCoverUrl(html) == null);
}

test "parseTitleParts: name + version + dev" {
    const p = parseTitleParts("Some Game [v0.20.17] [Ren'Py] [Kompas]");
    try std.testing.expectEqualStrings("Some Game", p.name);
    try std.testing.expectEqualStrings("0.20.17", p.version.?);
    try std.testing.expectEqualStrings("Kompas", p.developer.?);
}

test "parseTitleParts: end-state version" {
    const p = parseTitleParts("Old Game [Final] [Dev]");
    try std.testing.expectEqualStrings("Old Game", p.name);
    try std.testing.expectEqualStrings("Final", p.version.?);
    try std.testing.expectEqualStrings("Dev", p.developer.?);
}

test "parseTitleParts: no brackets" {
    const p = parseTitleParts("Just A Name");
    try std.testing.expectEqualStrings("Just A Name", p.name);
    try std.testing.expect(p.version == null);
    try std.testing.expect(p.developer == null);
}

test "parseTitleParts: bare numeric version" {
    const p = parseTitleParts("Game [0.5.1] [Studio]");
    try std.testing.expectEqualStrings("0.5.1", p.version.?);
    try std.testing.expectEqualStrings("Studio", p.developer.?);
}

test "parseTitleParts: ignores non-version V-words" {
    const p = parseTitleParts("Game [Voyeur] [Vampire] [v1.0] [Studio]");
    try std.testing.expectEqualStrings("1.0", p.version.?);
    try std.testing.expectEqualStrings("Studio", p.developer.?);
}

test "parseTitleParts: trims wrapping apostrophes" {
    const p = parseTitleParts("'Some Game'");
    try std.testing.expectEqualStrings("Some Game", p.name);
}

test "parseTitleParts: trims wrapping double-quotes" {
    const p = parseTitleParts("\"Some Game\"");
    try std.testing.expectEqualStrings("Some Game", p.name);
}

test "parseTitleParts: keeps internal apostrophes" {
    const p = parseTitleParts("Game's Story");
    try std.testing.expectEqualStrings("Game's Story", p.name);
}

test "extractTags: simple two tags" {
    const html =
        \\<a href="/tags/x/" class="tagItem">romance</a>
        \\<a class="tagItem" href="/tags/y/">vn</a>
    ;
    const tags = try extractTags(std.testing.allocator, html);
    defer {
        for (tags) |t| std.testing.allocator.free(t);
        std.testing.allocator.free(tags);
    }
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("romance", tags[0]);
    try std.testing.expectEqualStrings("vn", tags[1]);
}

test "extractTags: no tags" {
    const tags = try extractTags(std.testing.allocator, "<html>nothing</html>");
    defer std.testing.allocator.free(tags);
    try std.testing.expectEqual(@as(usize, 0), tags.len);
}

// ============================================================
//  OP body section scrapers
//  - Overview / Description
//  - Changelog
//  - Reviews (replies beneath the OP)
//  - Download links
// ============================================================

/// Hard cap on each scraped section so a runaway OP doesn't bloat
/// the DB row. 32 KiB is generous for prose, tiny on disk.
const MAX_SECTION_LEN: usize = 32 * 1024;

/// Header tokens we treat as boundaries when slicing a section out of
/// the OP. These are bold labels XenForo authors use to structure
/// posts — the section continues until the next one.
const SECTION_HEADERS = [_][]const u8{
    "Overview",  "Description",    "Story",        "Plot",
    "Updated",   "Thread Updated", "Game Updated", "Release Date",
    "Developer", "Publisher",      "Censored",     "Censorship",
    "Version",   "OS",             "Language",     "Genre",
    "Tags",      "Installation",   "Install",      "Walkthrough",
    "Notes",     "Changelog",      "Change Log",   "Change-log",
    "DOWNLOAD",  "Download",       "Downloads",
};

fn extractOverview(alloc: std.mem.Allocator, html: []const u8) !?[]u8 {
    return extractSectionByHeaders(alloc, html, &[_][]const u8{
        "Overview", "Description", "Story", "Plot",
    });
}

fn extractChangelog(alloc: std.mem.Allocator, html: []const u8) !?[]u8 {
    return extractStructuredSection(alloc, html, &[_][]const u8{
        "Changelog", "Change Log", "Change-log",
    });
}

/// Scrape the "Downloads" section preserving F95's natural line
/// layout. `<b>WINDOWS:</b>` becomes an inline bold span, `<br>` /
/// `</p>` / `</div>` cause line breaks, `<a href>` becomes a
/// clickable inline link, and `<div class="bbCodeSpoiler">…</div>`
/// becomes a collapsible foldout. No artificial group headers, no
/// one-link-per-row reformatting — the rendered tab reads the same
/// shape the OP wrote.
///
/// Header matching is intentionally permissive: many OPs use a bare
/// `<b>DOWNLOAD</b>` heading with no trailing colon. The generic
/// `locateHeader` requires a colon close by, so we use the relaxed
/// variant for the Downloads marker.
fn extractDownloadsSection(alloc: std.mem.Allocator, html: []const u8) !?[]u8 {
    const op = opBodyRange(html) orelse {
        log.warn("downloads: opBodyRange missing — couldn't scope the OP article", .{});
        return null;
    };
    const headers = [_][]const u8{
        "DOWNLOAD",  "Download", "Downloads", "Download Link", "Download Links",
        "DOWNLOADS",
    };
    const start = locateHeaderRelaxed(op, &headers) orelse {
        log.warn("downloads: no recognisable header in OP (looked for DOWNLOAD/Download/etc)", .{});
        return null;
    };

    var content_start = start;
    // Step past whatever caps the header text — typically `</b>` or
    // a `:` or just the closing punctuation. We're permissive
    // because the header may not have a colon at all.
    // The colon must cap the header text itself: only accept it when it
    // appears before the next `<`. A colonless bold header followed by a
    // bold platform label (`<b>DOWNLOAD</b><br><b>WINDOWS:</b>`) otherwise
    // gets its first label swallowed by the 32-byte window.
    if (std.mem.indexOfPos(u8, op, content_start, ":")) |colon| {
        const lt = std.mem.indexOfScalarPos(u8, op, content_start, '<');
        const colon_caps_header = lt == null or colon < lt.?;
        if (colon_caps_header and colon > content_start and colon - content_start < 32) content_start = colon + 1;
    }
    if (content_start < op.len and op[content_start] == '<') {
        if (std.mem.indexOfScalarPos(u8, op, content_start, '>')) |gt| {
            if (gt - content_start < 32) content_start = gt + 1;
        }
    }
    // If the user's header was bare ("DOWNLOAD"), the previous two
    // steps may have skipped 0 bytes and content_start still points
    // inside the literal header text. Scan past the matched word.
    inline for (headers) |h| {
        if (start + h.len <= op.len and std.mem.eql(u8, op[start .. start + h.len], h) and content_start < start + h.len) {
            content_start = start + h.len;
            break;
        }
    }
    // Also skip an immediately-following close tag like `</b>`.
    if (content_start < op.len and op[content_start] == '<') {
        if (std.mem.indexOfScalarPos(u8, op, content_start, '>')) |gt| {
            if (gt - content_start < 32) content_start = gt + 1;
        }
    }

    var content_end: usize = op.len;
    for (SECTION_HEADERS) |h| {
        if (locateHeaderAfter(op, content_start, &[_][]const u8{h})) |idx| {
            if (idx < content_end) content_end = idx;
        }
    }
    if (content_end <= content_start) {
        log.warn("downloads: empty slice after header (start={d}, end={d})", .{ content_start, content_end });
        return null;
    }

    log.info("downloads: scoped {d} bytes after header @ {d}", .{ content_end - content_start, start });
    const result = try formatStructuredHtmlOpts(
        alloc,
        op[content_start..content_end],
        .{ .bold_as_heading = false },
    );
    if (result == null) {
        log.warn("downloads: formatter produced empty result", .{});
    }
    return result;
}

/// Same as `locateHeader` but doesn't require a colon-near-by. Used
/// for the Downloads section header, which F95 OPs often render as a
/// bare `<b>DOWNLOAD</b>` with no trailing colon. Word-boundary
/// matching on the leading side still applies so "Downloads" inside
/// an unrelated word doesn't trigger.
fn locateHeaderRelaxed(scope: []const u8, headers: []const []const u8) ?usize {
    var best: ?usize = null;
    for (headers) |h| {
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, scope, search_from, h)) |i| {
            const before_ok = i == 0 or scope[i - 1] == '>' or scope[i - 1] == ' ' or scope[i - 1] == '\n' or scope[i - 1] == '\r';
            const tail_start = i + h.len;
            // After must be either end-of-buf, a non-alphanumeric byte
            // (`:` / `<` / whitespace) — guards against matching
            // inside a longer word like "DownloadGuide".
            const after_ok = tail_start >= scope.len or !std.ascii.isAlphanumeric(scope[tail_start]);
            if (before_ok and after_ok) {
                if (best == null or i < best.?) best = i;
                break;
            }
            search_from = i + 1;
        }
    }
    return best;
}

test "extractDownloadsSection: bold spans inline, links preserved" {
    const alloc = std.testing.allocator;
    const html =
        "<article class=\"message-threadStarterPost\"><div class=\"bbWrapper\">" ++
        "<b>DOWNLOAD</b><br>" ++
        "<b>WINDOWS:</b><br>" ++
        "<a href=\"https://mega.nz/a\">MEGA</a> - <a href=\"https://mediafire.com/b\">MediaFire</a><br>" ++
        "<br>" ++
        "<b>LINUX:</b><br>" ++
        "<a href=\"https://mega.nz/c\">MEGA</a>" ++
        "</div></article>";
    const out_opt = try extractDownloadsSection(alloc, html);
    defer if (out_opt) |s| alloc.free(s);
    const out = out_opt.?;
    // `<b>` should NOT have become `## ` (that was the previous bug).
    try std.testing.expect(std.mem.indexOf(u8, out, "## WINDOWS:") == null);
    // Inline bold is now dropped entirely — body text stays plain.
    try std.testing.expect(std.mem.indexOf(u8, out, "WINDOWS:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "LINUX:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[B]") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[/B]") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[LINK=https://mega.nz/a]MEGA[/LINK]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[LINK=https://mediafire.com/b]MediaFire[/LINK]") != null);
}

test "extractDownloadsSection: <br> inside <a> collapses to space (LINK span stays on one line)" {
    const alloc = std.testing.allocator;
    // F95 posts occasionally insert a `<br>` inside the anchor body
    // (e.g., a multi-line cheat-mod label). Splitting the resulting
    // `[LINK=URL]label[/LINK]` across two output lines would defeat
    // the renderer's line-by-line marker matcher and leak raw BBcode.
    const html =
        "<article class=\"message-threadStarterPost\"><div class=\"bbWrapper\">" ++
        "<b>DOWNLOAD</b><br>" ++
        "Extras: CHEAT MOD - " ++
        "<a href=\"https://example.com/x\">Shawn's<br>Walkthrough Improvements + Cheat Mod</a>" ++
        "</div></article>";
    const out_opt = try extractDownloadsSection(alloc, html);
    defer if (out_opt) |s| alloc.free(s);
    const out = out_opt.?;
    try std.testing.expect(std.mem.indexOf(u8, out, "[LINK=https://example.com/x]Shawn's Walkthrough Improvements + Cheat Mod[/LINK]") != null);
    // Sanity: the open marker must not be stranded on a line of its own.
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "[LINK=") != null) {
            try std.testing.expect(std.mem.indexOf(u8, line, "[/LINK]") != null);
        }
    }
}

/// Same as `extractSectionByHeaders` but pipes the HTML through
/// `formatStructuredHtml` instead of `stripHtmlToText`. That preserves
/// version headings, bullet items, spoiler foldouts, and hyperlinks
/// using lightweight line markers the UI renderer expands back into
/// widgets:
///   `## …`          → heading
///   `• …`           → bullet line
///   `[SPOILER=…]`   → start collapsible block
///   `[/SPOILER]`    → end collapsible block
///   `[LINK=URL]…[/LINK]` → inline clickable link
fn extractStructuredSection(
    alloc: std.mem.Allocator,
    html: []const u8,
    headers: []const []const u8,
) !?[]u8 {
    const op = opBodyRange(html) orelse return null;
    const start = locateHeader(op, headers) orelse return null;

    var content_start = start;
    if (std.mem.indexOfPos(u8, op, content_start, ":")) |colon| {
        if (colon - content_start < 64) content_start = colon + 1;
    }
    if (content_start < op.len and op[content_start] == '<') {
        if (std.mem.indexOfScalarPos(u8, op, content_start, '>')) |gt| {
            if (gt - content_start < 32) content_start = gt + 1;
        }
    }

    var content_end: usize = op.len;
    for (SECTION_HEADERS) |h| {
        if (locateHeaderAfter(op, content_start, &[_][]const u8{h})) |idx| {
            if (idx < content_end) content_end = idx;
        }
    }
    if (content_end <= content_start) return null;

    return try formatStructuredHtml(alloc, op[content_start..content_end]);
}

/// Generic helper: scope to the OP body, locate the first matching
/// header, take the slice up to the next known header, strip HTML +
/// decode entities, return a plain-text blob. Caller owns the result.
fn extractSectionByHeaders(
    alloc: std.mem.Allocator,
    html: []const u8,
    headers: []const []const u8,
) !?[]u8 {
    const op = opBodyRange(html) orelse return null;
    const start = locateHeader(op, headers) orelse return null;

    // Skip past the matched header text + its closing tag.
    var content_start = start;
    if (std.mem.indexOfPos(u8, op, content_start, ":")) |colon| {
        if (colon - content_start < 64) content_start = colon + 1;
    }
    // Skip a closing inline tag (`</b>`, `</strong>`, `</span>`) if
    // we landed inside one. Cheap: scan forward to first `>` after a
    // `<` and resume after it. Bounded so we don't accidentally
    // swallow paragraphs.
    if (content_start < op.len and op[content_start] == '<') {
        if (std.mem.indexOfScalarPos(u8, op, content_start, '>')) |gt| {
            if (gt - content_start < 32) content_start = gt + 1;
        }
    }

    // End at the next known header — anywhere after our start position.
    var content_end: usize = op.len;
    for (SECTION_HEADERS) |h| {
        if (locateHeaderAfter(op, content_start, &[_][]const u8{h})) |idx| {
            if (idx < content_end) content_end = idx;
        }
    }
    if (content_end <= content_start) return null;

    const raw = op[content_start..content_end];
    return try stripHtmlToText(alloc, raw);
}

/// Find the first index where any of `headers` appears prefixed by a
/// bold/strong tag context — we match the literal header text (case
/// sensitive, which mirrors how F95 authors title their sections).
fn locateHeader(scope: []const u8, headers: []const []const u8) ?usize {
    return locateHeaderAfter(scope, 0, headers);
}

fn locateHeaderAfter(scope: []const u8, from: usize, headers: []const []const u8) ?usize {
    if (from >= scope.len) return null;
    var best: ?usize = null;
    for (headers) |h| {
        var search_from = from;
        while (std.mem.indexOfPos(u8, scope, search_from, h)) |i| {
            // Require either a `>` immediately before (i.e. inside a
            // tag like `<b>Overview`) or a space/colon — we don't
            // want random prose mentions.
            const ok = i == 0 or scope[i - 1] == '>' or scope[i - 1] == ' ' or scope[i - 1] == '\n';
            // And require a `:` close-by (within 32 bytes) so we
            // really did hit a labelled section header.
            const tail = scope[i + h.len ..];
            const has_colon = blk: {
                const upto = @min(tail.len, 32);
                if (std.mem.indexOfScalar(u8, tail[0..upto], ':')) |_| break :blk true;
                break :blk false;
            };
            if (ok and has_colon) {
                if (best == null or i < best.?) best = i;
                break;
            }
            search_from = i + h.len;
        }
    }
    return best;
}

/// Convert a slice of HTML into a plain-text blob. Strips tags,
/// converts `<br>` / `</p>` / `</div>` to newlines, collapses
/// whitespace runs, decodes HTML entities. Bounded by `MAX_SECTION_LEN`
/// so a runaway section doesn't OOM. Returns null if the result is
/// empty after trimming.
fn stripHtmlToText(alloc: std.mem.Allocator, src: []const u8) !?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var in_tag: bool = false;
    var last_was_space: bool = true; // suppress leading whitespace
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (buf.items.len >= MAX_SECTION_LEN) break;
        const c = src[i];
        if (in_tag) {
            if (c == '>') {
                in_tag = false;
                // Emit a newline for block-level tag closers so
                // paragraphs stay separated.
                if (isBlockTagEnd(src[0..i])) {
                    if (!last_was_space) {
                        try buf.append(alloc, '\n');
                        last_was_space = true;
                    }
                }
            }
            continue;
        }
        if (c == '<') {
            in_tag = true;
            continue;
        }
        // Treat any whitespace run as one space (newlines preserved
        // only via block-tag closers above).
        if (c == '\n' or c == '\r' or c == '\t' or c == ' ') {
            if (!last_was_space) try buf.append(alloc, ' ');
            last_was_space = true;
            continue;
        }
        try buf.append(alloc, c);
        last_was_space = false;
    }

    // Trim trailing whitespace.
    var end = buf.items.len;
    while (end > 0 and (buf.items[end - 1] == ' ' or buf.items[end - 1] == '\n')) : (end -= 1) {}
    buf.shrinkRetainingCapacity(end);

    if (buf.items.len == 0) {
        buf.deinit(alloc);
        return null;
    }

    // Decode entities into a heap-sized scratch (output ≤ input,
    // since every entity decodes to ≤ its source bytes). Previously
    // this fell back to a raw copy past 4 KiB — long bodies were
    // leaking `&#8203;` / `&nbsp;` through unchanged.
    const scratch = try alloc.alloc(u8, buf.items.len);
    defer alloc.free(scratch);
    const dec = decodeHtmlEntities(scratch, buf.items);
    const owned = try alloc.dupe(u8, dec);
    buf.deinit(alloc);
    return owned;
}

/// Walk an HTML fragment and emit plain text with lightweight
/// structure markers (see `extractStructuredSection` for the marker
/// vocabulary). Used for Changelog (where `<b>…</b>` reads as a
/// version heading on its own line) and Downloads (where `<b>…</b>`
/// reads as an inline bold span — `WINDOWS:` glued to its mirror
/// list on the next line). The `bold_as_heading` knob picks which.
fn formatStructuredHtml(alloc: std.mem.Allocator, src: []const u8) !?[]u8 {
    return formatStructuredHtmlOpts(alloc, src, .{ .bold_as_heading = true });
}

const StructuredFormatOpts = struct {
    /// When true, `<b>`/`<strong>` and `<h1..h4>` emit `\n## …\n`
    /// (block-level heading). When false, `<b>`/`<strong>` emit
    /// `[B]…[/B]` inline bold spans and the heading-y tags emit
    /// no special prefix — they're still bold via `[B]`, just don't
    /// force a line break. The Downloads tab uses `false` so a
    /// "WINDOWS:" `<b>` doesn't get artificially separated from its
    /// mirror list.
    bold_as_heading: bool = true,
};

fn formatStructuredHtmlOpts(
    alloc: std.mem.Allocator,
    src: []const u8,
    opts: StructuredFormatOpts,
) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // Tracking flags that affect emission:
    //   in_button         — we're inside `bbCodeSpoiler-button`; collect
    //                       its text as the spoiler title.
    //   spoiler_depth     — div nesting depth inside the outer
    //                       `bbCodeSpoiler` wrapper. 0 == not in any.
    //   pending_link_url  — when emitting an `<a href=…>`, we already
    //                       wrote `[LINK=URL]`; remember to close on
    //                       `</a>` with `[/LINK]`.
    var in_button: bool = false;
    var spoiler_depth: u32 = 0;
    var link_open: bool = false;

    var i: usize = 0;
    while (i < src.len) {
        if (out.items.len >= MAX_SECTION_LEN) break;

        if (src[i] == '<') {
            const tag_end = std.mem.indexOfScalarPos(u8, src, i + 1, '>') orelse {
                i += 1;
                continue;
            };
            const tag = src[i + 1 .. tag_end];
            i = tag_end + 1;
            if (tag.len == 0) continue;

            const is_close = tag[0] == '/';
            const name_start: usize = if (is_close) 1 else 0;
            var name_end: usize = name_start;
            while (name_end < tag.len and tag[name_end] != ' ' and tag[name_end] != '\t' and tag[name_end] != '/') : (name_end += 1) {}
            const name = tag[name_start..name_end];

            // --- Spoiler structure ---
            if (!is_close and asciiEq(name, "div") and tagHasClass(tag, "bbCodeSpoiler") and !tagHasClass(tag, "bbCodeSpoiler-button") and !tagHasClass(tag, "bbCodeSpoiler-content")) {
                ensureNewline(&out, alloc) catch {};
                try out.appendSlice(alloc, "[SPOILER=");
                spoiler_depth = 1;
                continue;
            }
            if (!is_close and asciiEq(name, "div") and spoiler_depth > 0) {
                spoiler_depth += 1;
                continue;
            }
            if (is_close and asciiEq(name, "div") and spoiler_depth > 0) {
                spoiler_depth -= 1;
                if (spoiler_depth == 0) {
                    try ensureNewline(&out, alloc);
                    try out.appendSlice(alloc, "[/SPOILER]\n");
                }
                continue;
            }
            // Spoiler-button (XenForo emits a <button>, not a div).
            if (!is_close and (asciiEq(name, "button") or asciiEq(name, "div")) and tagHasClass(tag, "bbCodeSpoiler-button")) {
                in_button = true;
                continue;
            }
            if (is_close and (asciiEq(name, "button") or asciiEq(name, "div")) and in_button) {
                in_button = false;
                try out.appendSlice(alloc, "]\n");
                continue;
            }

            // --- Hyperlinks ---
            if (!is_close and asciiEq(name, "a")) {
                if (extractHrefAttr(tag)) |href| {
                    if (!link_open) {
                        try out.appendSlice(alloc, "[LINK=");
                        try out.appendSlice(alloc, href);
                        try out.appendSlice(alloc, "]");
                        link_open = true;
                    }
                }
                continue;
            }
            if (is_close and asciiEq(name, "a") and link_open) {
                try out.appendSlice(alloc, "[/LINK]");
                link_open = false;
                continue;
            }

            // --- Lists ---
            if (!is_close and asciiEq(name, "li")) {
                try ensureNewline(&out, alloc);
                try out.appendSlice(alloc, "• ");
                continue;
            }
            if (is_close and asciiEq(name, "li")) {
                try ensureNewline(&out, alloc);
                continue;
            }
            if (asciiEq(name, "ul") or asciiEq(name, "ol")) {
                try ensureNewline(&out, alloc);
                continue;
            }

            // --- Headings / bold ---
            // Two modes (`opts.bold_as_heading`):
            //   true  → `\n## …\n` (block-level heading, used for
            //           Changelog version markers like "v0.13:")
            //   false → plain text (inline bold dropped — previously
            //           wrapped in `[B]…[/B]` but the markers leaked
            //           into rendered output; user asked to filter
            //           them out everywhere).
            const is_bold = asciiEq(name, "b") or asciiEq(name, "strong");
            const is_heading_tag = asciiEq(name, "h1") or asciiEq(name, "h2") or asciiEq(name, "h3") or asciiEq(name, "h4");
            if (!is_close and (is_bold or is_heading_tag)) {
                if (!in_button) {
                    if (opts.bold_as_heading or is_heading_tag) {
                        try ensureNewline(&out, alloc);
                        try out.appendSlice(alloc, "## ");
                    }
                }
                continue;
            }
            if (is_close and (is_bold or is_heading_tag)) {
                if (!in_button) {
                    if (opts.bold_as_heading or is_heading_tag) {
                        try ensureNewline(&out, alloc);
                    }
                }
                continue;
            }

            // --- Plain block separators ---
            if (asciiEq(name, "br") or asciiEq(name, "p") or asciiEq(name, "tr")) {
                // Inside an open `[LINK=URL]…[/LINK]` span we must not
                // emit a newline — the renderer matches markers
                // line-by-line and a split span would leak raw BBcode
                // to the user (and degenerate label text → 0-len slices
                // confuse dvui's textLayout). Collapse to a single space.
                if (link_open) {
                    const last = if (out.items.len > 0) out.items[out.items.len - 1] else ' ';
                    if (last != ' ' and last != '\n') try out.append(alloc, ' ');
                    continue;
                }
                try ensureNewline(&out, alloc);
                continue;
            }

            // Other tags (spans, attributes, scripts, …): consumed silently.
            continue;
        }

        // Text byte. Whitespace collapses to a single space unless the
        // last char is already a space or newline.
        const c = src[i];
        i += 1;
        if (c == '\n' or c == '\r' or c == '\t' or c == ' ') {
            const last = if (out.items.len > 0) out.items[out.items.len - 1] else '\n';
            if (last != ' ' and last != '\n') try out.append(alloc, ' ');
            continue;
        }
        try out.append(alloc, c);
    }

    // Trim trailing whitespace and collapse runs of 3+ newlines.
    var compact: std.ArrayList(u8) = .empty;
    errdefer compact.deinit(alloc);
    try compact.ensureTotalCapacity(alloc, out.items.len);
    var consecutive_nl: u32 = 0;
    for (out.items) |c| {
        if (c == '\n') {
            consecutive_nl += 1;
            if (consecutive_nl <= 2) try compact.append(alloc, c);
        } else {
            consecutive_nl = 0;
            try compact.append(alloc, c);
        }
    }
    out.deinit(alloc);

    // Trim trailing whitespace.
    var end = compact.items.len;
    while (end > 0 and (compact.items[end - 1] == ' ' or compact.items[end - 1] == '\n')) : (end -= 1) {}
    compact.shrinkRetainingCapacity(end);
    if (compact.items.len == 0) {
        compact.deinit(alloc);
        return null;
    }

    // Decode HTML entities. Heap-sized scratch — output ≤ input bytes,
    // so one allocation is enough. (Earlier this skipped decode past
    // 4 KiB, which let `&#8203;` / `&nbsp;` leak through on long
    // changelogs and download bodies.)
    const scratch = try alloc.alloc(u8, compact.items.len);
    defer alloc.free(scratch);
    const dec = decodeHtmlEntities(scratch, compact.items);
    const owned = try alloc.dupe(u8, dec);
    compact.deinit(alloc);
    return owned;
}

/// Pull a `href="…"` attribute value out of a tag's interior. Returns
/// the raw URL slice (caller-borrowed). Null when the attribute isn't
/// present or its value is empty.
fn extractHrefAttr(tag: []const u8) ?[]const u8 {
    const marker = "href=\"";
    const at = std.mem.indexOf(u8, tag, marker) orelse return null;
    const start = at + marker.len;
    const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
    if (end <= start) return null;
    return tag[start..end];
}

/// True when `class="…"` on `tag` includes `cls` as a whole entry.
fn tagHasClass(tag: []const u8, cls: []const u8) bool {
    const attr = "class=\"";
    const at = std.mem.indexOf(u8, tag, attr) orelse return false;
    const start = at + attr.len;
    const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return false;
    var it = std.mem.splitScalar(u8, tag[start..end], ' ');
    while (it.next()) |name| {
        if (std.mem.eql(u8, name, cls)) return true;
    }
    return false;
}

fn asciiEq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Append a newline only if `out` doesn't already end in one. Also
/// trims a trailing space first so " \n" doesn't leak into the output.
fn ensureNewline(out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        out.shrinkRetainingCapacity(out.items.len - 1);
    }
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        try out.append(alloc, '\n');
    }
}

/// Returns true when `src[..i]` ends in a block-level closing tag.
/// Used to decide whether a `>` byte should also emit a newline.
fn isBlockTagEnd(prefix: []const u8) bool {
    if (prefix.len < 3) return false;
    // Walk back to the matching `<`. Bounded — block tags are short.
    var j: usize = prefix.len;
    const cap: usize = @min(prefix.len, 16);
    while (j > prefix.len - cap) : (j -= 1) {
        if (prefix[j - 1] == '<') {
            const tag = prefix[j..];
            const block_tags = [_][]const u8{ "/p", "/div", "br", "br/", "br /", "/li", "/h1", "/h2", "/h3", "/h4", "/h5", "/h6", "/tr" };
            for (block_tags) |bt| {
                if (std.ascii.eqlIgnoreCase(tag, bt)) return true;
            }
            return false;
        }
    }
    return false;
}

// ----- reviews -----

/// Concatenate the first few non-OP posts on the thread page — these
/// are typically community feedback. Each reply is rendered as a
/// plain-text block separated by `---`. Bounded by `MAX_SECTION_LEN`
/// and by `MAX_REVIEWS` so we don't keep an entire forum thread.
fn extractReviews(alloc: std.mem.Allocator, html: []const u8) !?[]u8 {
    const max_reviews: usize = 5;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    // F95 wraps each visible reply's prose in
    //   <div class="bbWrapper">…</div>
    // inside an <article class="message"> that is NOT the
    // threadStarterPost (that one's already in the OP block). We skip
    // past the OP, then scan for bbWrapper hits.
    const op_end_marker = "</article>";
    var cursor: usize = 0;
    if (std.mem.indexOf(u8, html, "message-threadStarterPost")) |op_at| {
        if (std.mem.indexOfPos(u8, html, op_at, op_end_marker)) |end| {
            cursor = end + op_end_marker.len;
        }
    }

    var count: usize = 0;
    const wrap_open = "class=\"bbWrapper\"";
    while (count < max_reviews) {
        const at = std.mem.indexOfPos(u8, html, cursor, wrap_open) orelse break;
        // Skip to the `>` that ends the opening tag.
        const gt = std.mem.indexOfScalarPos(u8, html, at, '>') orelse break;
        const inner_start = gt + 1;
        // Reply body ends at the next `</article>` (XenForo's per-message
        // wrapping). Bound to `</div>` if no article tag follows.
        const inner_end = std.mem.indexOfPos(u8, html, inner_start, "</article>") orelse break;
        const slice = html[inner_start..inner_end];
        cursor = inner_end;

        const text_opt = stripHtmlToText(alloc, slice) catch null;
        if (text_opt) |text| {
            defer alloc.free(text);
            const trimmed = std.mem.trim(u8, text, " \t\n\r");
            if (trimmed.len < 40) continue; // skip drive-by one-liners
            if (count > 0) try buf.appendSlice(alloc, "\n\n---\n\n");
            const want: usize = @min(trimmed.len, 1024);
            try buf.appendSlice(alloc, trimmed[0..want]);
            if (want < trimmed.len) try buf.appendSlice(alloc, " …");
            count += 1;
        }
        if (buf.items.len >= MAX_SECTION_LEN) break;
    }

    if (buf.items.len == 0) {
        buf.deinit(alloc);
        return null;
    }
    return try buf.toOwnedSlice(alloc);
}

// ----- download links -----

/// Scan the OP body for download links — known file hosts plus F95
/// attachment URLs that aren't images. Caller owns outer slice and
/// each inner `url` / `label`.
fn extractDownloadLinks(
    alloc: std.mem.Allocator,
    html: []const u8,
) ![]const domain.DownloadLink {
    var out: std.ArrayList(domain.DownloadLink) = .empty;
    errdefer {
        for (out.items) |link| {
            alloc.free(link.url);
            if (link.label) |lab| alloc.free(lab);
        }
        out.deinit(alloc);
    }
    const scope = opBodyRange(html) orelse return out.toOwnedSlice(alloc);

    var seen: std.StringHashMap(void) = .init(alloc);
    defer seen.deinit();

    var rest = scope;
    while (std.mem.indexOf(u8, rest, "href=\"")) |i| {
        const url_start = i + "href=\"".len;
        const url_end = std.mem.indexOfScalarPos(u8, rest, url_start, '"') orelse break;
        const raw_url = rest[url_start..url_end];
        rest = rest[url_end + 1 ..];

        const host = classifyDownloadHost(raw_url) orelse continue;
        // Skip F95 attachments that look like images — those are
        // already covered by `extractScreenshots`.
        if (host == .f95_attachment and isImageUrlByExtension(raw_url)) continue;

        // Dedup by URL.
        if (seen.contains(raw_url)) continue;

        const url_dup = try alloc.dupe(u8, raw_url);
        errdefer alloc.free(url_dup);
        try seen.put(url_dup, {});

        try out.append(alloc, .{ .host = host, .url = url_dup, .label = null });
        if (out.items.len >= 64) break;
    }

    return try out.toOwnedSlice(alloc);
}

/// Substring patterns mapped onto a `DownloadHost` tag. Each needle is
/// unique to one host so order doesn't matter. Kept as a comptime
/// tuple so the `inline for` below unrolls into straight-line code.
const HOST_PATTERNS = [_]struct { needle: []const u8, host: domain.DownloadHost }{
    .{ .needle = "mega.nz", .host = .mega },
    .{ .needle = "mega.co.nz", .host = .mega },
    .{ .needle = "mediafire.com", .host = .mediafire },
    .{ .needle = "gofile.io", .host = .gofile },
    .{ .needle = "pixeldrain.com", .host = .pixeldrain },
    .{ .needle = "pixeldrain.net", .host = .pixeldrain },
    .{ .needle = "workupload.com", .host = .workupload },
    .{ .needle = "nopy.to", .host = .nopy },
    .{ .needle = "nopy.net", .host = .nopy },
    .{ .needle = "zippyshare.com", .host = .zippyshare },
};

/// Classify a URL into a known download host. Returns null for things
/// we don't care about (forum chrome, mailto:, internal anchors, …).
fn classifyDownloadHost(url: []const u8) ?domain.DownloadHost {
    if (std.mem.startsWith(u8, url, "https://attachments.f95zone.to/")) return .f95_attachment;
    inline for (HOST_PATTERNS) |p| {
        if (containsHost(url, p.needle)) return p.host;
    }
    // Treat anything else with a plausible scheme as "other" so we
    // don't drop magnet / google-drive / mixdrop / etc.
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
        // Forum-internal URLs aren't downloads.
        if (containsHost(url, "f95zone.to") and !std.mem.startsWith(u8, url, "https://attachments.")) {
            return null;
        }
        return .other;
    }
    return null;
}

fn containsHost(url: []const u8, host: []const u8) bool {
    return std.mem.indexOf(u8, url, host) != null;
}

test "extractSectionByHeaders: pulls Overview text" {
    const html =
        "<article class=\"message-threadStarterPost\"><div class=\"bbWrapper\">" ++
        "<b>Overview:</b> A short summary of the game.<br>" ++
        "<b>Updated:</b> 2025-01-01" ++
        "</div></article>";
    const out = try extractOverview(std.testing.allocator, html);
    defer if (out) |s| std.testing.allocator.free(s);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "short summary") != null);
}

test "extractSectionByHeaders: Changelog after Overview" {
    const html =
        "<article class=\"message-threadStarterPost\"><div class=\"bbWrapper\">" ++
        "<b>Overview:</b> blah blah.<br>" ++
        "<b>Changelog:</b> v0.2 fixes crash.<br>" ++
        "<b>Genre:</b> rpg" ++
        "</div></article>";
    const out = try extractChangelog(std.testing.allocator, html);
    defer if (out) |s| std.testing.allocator.free(s);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "v0.2 fixes crash") != null);
    // Must not bleed into the next section.
    try std.testing.expect(std.mem.indexOf(u8, out.?, "rpg") == null);
}

test "extractDownloadLinks: dedup + host classify" {
    const html =
        "<article class=\"message-threadStarterPost\"><div>" ++
        "<a href=\"https://mega.nz/file/abc\">Win</a>" ++
        "<a href=\"https://mega.nz/file/abc\">Win-dup</a>" ++
        "<a href=\"https://attachments.f95zone.to/2024/01/foo.zip\">Patch</a>" ++
        "<a href=\"https://www.f95zone.to/threads/123\">forum-link</a>" ++
        "</div></article>";
    const links = try extractDownloadLinks(std.testing.allocator, html);
    defer {
        for (links) |l| {
            std.testing.allocator.free(l.url);
            if (l.label) |lab| std.testing.allocator.free(lab);
        }
        std.testing.allocator.free(links);
    }
    try std.testing.expectEqual(@as(usize, 2), links.len);
    try std.testing.expectEqual(domain.DownloadHost.mega, links[0].host);
    try std.testing.expectEqual(domain.DownloadHost.f95_attachment, links[1].host);
}

// ============================================================
//  "Thread Updated" date extraction
// ============================================================

/// Scan the OP body for a "Thread Updated:" / "Updated:" / "Game
/// Updated:" label and convert the date that follows into unix
/// seconds. Returns null when no marker is present or the value
/// isn't a recognisable date.
fn extractLastUpdatedAt(html: []const u8) ?i64 {
    const scope = opBodyRange(html) orelse html;
    const markers = [_][]const u8{
        "Thread Updated",
        "Game Updated",
        "Last Updated",
        "Updated",
    };
    for (markers) |m| {
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, scope, search_from, m)) |i| {
            // Require the marker to be at a word boundary so "Updated"
            // doesn't match inside "OUTDATED" etc.
            const before_ok = i == 0 or !isWordCharByte(scope[i - 1]);
            const tail = scope[i + m.len ..];
            const after_ok = tail.len == 0 or !isWordCharByte(tail[0]);
            if (!before_ok or !after_ok) {
                search_from = i + 1;
                continue;
            }
            // Skip up to a colon within a short window, then walk to
            // the first digit. Cap distance so we don't roam into the
            // next section.
            const colon = std.mem.indexOfScalarPos(u8, scope, i + m.len, ':') orelse {
                search_from = i + m.len;
                continue;
            };
            if (colon - (i + m.len) > 16) {
                search_from = i + m.len;
                continue;
            }
            const after = scope[colon + 1 ..];
            const ts_opt = parseFirstDateInWindow(after, 64);
            if (ts_opt) |ts| return ts;
            search_from = i + m.len;
        }
    }
    return null;
}

fn isWordCharByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// Look for the first plausible date in the first `window` bytes of
/// `s`. Accepts `YYYY-MM-DD`, `YYYY/MM/DD`, and `YYYY.MM.DD`. Returns
/// unix seconds for that date at 00:00 UTC.
fn parseFirstDateInWindow(s: []const u8, window: usize) ?i64 {
    const end = @min(s.len, window);
    var i: usize = 0;
    while (i + 10 <= end) : (i += 1) {
        // Heuristic: must start with 4 digits.
        if (!std.ascii.isDigit(s[i])) continue;
        const ts = dateStringToUnixSeconds(s[i .. i + 10]) orelse {
            // Try the next position; F95 sometimes pads with HTML tag
            // remnants between the colon and the date.
            continue;
        };
        return ts;
    }
    return null;
}

/// Convert a YYYY-MM-DD / YYYY/MM/DD / YYYY.MM.DD string to unix
/// seconds (00:00 UTC of that day). Returns null on any parse error
/// or out-of-range value. Uses Howard Hinnant's date-to-serial-day
/// algorithm — no leap-year tables, no stdlib date deps.
fn dateStringToUnixSeconds(s: []const u8) ?i64 {
    if (s.len < 10) return null;
    const sep1 = s[4];
    const sep2 = s[7];
    if (sep1 != '-' and sep1 != '/' and sep1 != '.') return null;
    if (sep2 != '-' and sep2 != '/' and sep2 != '.') return null;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    if (year < 1970 or year > 2100) return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    // Howard Hinnant's algorithm: shift March-based year so leap day
    // sits at the end of the year (simpler doy math).
    const y: i32 = if (month <= 2) year - 1 else year;
    const era: i32 = @divFloor(y, 400);
    const yoe: u32 = @intCast(y - era * 400); // 0..399
    const m: u32 = if (month > 2) month - 3 else month + 9;
    const d: u32 = day - 1;
    const doy: u32 = (153 * m + 2) / 5 + d; // 0..365
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy; // 0..146096
    const days_since_epoch: i64 = @as(i64, era) * 146097 + @as(i64, doe) - 719468;
    return days_since_epoch * 86400;
}

test "dateStringToUnixSeconds: known values" {
    const testing = std.testing;
    try testing.expectEqual(@as(?i64, 0), dateStringToUnixSeconds("1970-01-01"));
    // 2024-01-01 = 1704067200
    try testing.expectEqual(@as(?i64, 1704067200), dateStringToUnixSeconds("2024-01-01"));
    try testing.expectEqual(@as(?i64, 1704067200), dateStringToUnixSeconds("2024/01/01"));
    try testing.expectEqual(@as(?i64, 1704067200), dateStringToUnixSeconds("2024.01.01"));
    // Bad input
    try testing.expectEqual(@as(?i64, null), dateStringToUnixSeconds("xx"));
    try testing.expectEqual(@as(?i64, null), dateStringToUnixSeconds("2024-13-01"));
    try testing.expectEqual(@as(?i64, null), dateStringToUnixSeconds("2024-01-32"));
}

test "extractLastUpdatedAt: thread updated label" {
    const html =
        "<article class=\"message-threadStarterPost\"><div class=\"bbWrapper\">" ++
        "<b>Thread Updated:</b> 2024-03-15<br>" ++
        "<b>Genre:</b> RPG" ++
        "</div></article>";
    const ts = extractLastUpdatedAt(html).?;
    try std.testing.expectEqual(@as(i64, 1710460800), ts); // 2024-03-15 00:00 UTC
}

test "extractLastUpdatedAt: bare Updated label" {
    const html =
        "<article class=\"message-threadStarterPost\"><div class=\"bbWrapper\">" ++
        "<b>Updated:</b> 2023-12-01" ++
        "</div></article>";
    try std.testing.expectEqual(@as(i64, 1701388800), extractLastUpdatedAt(html).?);
}

// ============================================================
//  OP "info block" extraction
// ============================================================

/// Pull the OP's labelled facts ("Thread Updated:", "Release Date:",
/// "Developer:", "Censored:", "Version:", "OS:", "Language:" etc)
/// into a single preformatted text blob, one "Key: Value" line per
/// match. Order matches `INFO_KEYS` below.
///
/// Hyperlinks inside a value (e.g. the Developer line's
/// `Patreon - Itch.io - Discord` mirrors) are preserved as inline
/// `[LINK=URL]label[/LINK]` markers — the UI's
/// `renderStructuredText` walks lines through
/// `renderInlineLineWithLinks` and renders them as clickable spans.
fn extractThreadInfo(alloc: std.mem.Allocator, html: []const u8) !?[]u8 {
    const op = opBodyRange(html) orelse return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    for (INFO_KEYS) |key| {
        const value_html = findKeyValueHtml(op, key) orelse continue;
        // Run the value's HTML slice through the structured formatter
        // in inline-bold mode. Inline `<a href>` becomes
        // `[LINK=URL]label[/LINK]`; everything else collapses to
        // plain text on a single line.
        const formatted_opt = formatStructuredHtmlOpts(alloc, value_html, .{ .bold_as_heading = false }) catch null;
        const formatted = formatted_opt orelse continue;
        defer alloc.free(formatted);
        // Squash internal newlines — info-block values are
        // semantically single-line. Replace each `\n` with a space.
        var squashed: std.ArrayList(u8) = .empty;
        defer squashed.deinit(alloc);
        try squashed.ensureTotalCapacity(alloc, formatted.len);
        var last_was_space = false;
        for (formatted) |c| {
            if (c == '\n' or c == '\r' or c == '\t') {
                if (!last_was_space) try squashed.append(alloc, ' ');
                last_was_space = true;
            } else {
                try squashed.append(alloc, c);
                last_was_space = false;
            }
        }
        const trimmed = std.mem.trim(u8, squashed.items, " \t");
        if (trimmed.len == 0) continue;
        try out.appendSlice(alloc, key);
        try out.appendSlice(alloc, ": ");
        try out.appendSlice(alloc, trimmed);
        try out.append(alloc, '\n');
    }

    if (out.items.len == 0) {
        out.deinit(alloc);
        return null;
    }
    var end = out.items.len;
    while (end > 0 and out.items[end - 1] == '\n') : (end -= 1) {}
    out.shrinkRetainingCapacity(end);
    return try out.toOwnedSlice(alloc);
}

/// Locate `Key:` in raw HTML and return the HTML slice covering its
/// value — from the byte after the colon up to the first
/// line-breaking tag (`<br>`, `</p>`, `</div>`) or the next
/// recognised info-block key. Word-boundary protection so "Updated"
/// inside "Thread Updated" doesn't false-match.
fn findKeyValueHtml(op: []const u8, key: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, op, search_from, key)) |i| {
        const before_ok = i == 0 or !std.ascii.isAlphanumeric(op[i - 1]);
        if (!before_ok) {
            search_from = i + 1;
            continue;
        }
        const after_key = i + key.len;
        // Allow `</b>` / `</strong>` / whitespace between key and
        // colon. Find the colon within a short window.
        const tail = op[after_key..];
        const colon_off = std.mem.indexOfScalar(u8, tail, ':') orelse {
            search_from = after_key;
            continue;
        };
        if (colon_off > 24) {
            search_from = after_key;
            continue;
        }
        // Reject if the gap contains any alphanumerics (i.e. we're
        // matching a substring of a longer key).
        for (tail[0..colon_off]) |c| {
            if (std.ascii.isAlphanumeric(c)) {
                search_from = after_key;
                continue;
            }
        }
        const value_start = after_key + colon_off + 1;
        if (value_start >= op.len) return null;

        // End at the first line-breaking tag.
        const end_markers = [_][]const u8{ "<br>", "<br/>", "<br />", "<br >", "</p>", "</div>" };
        var value_end: usize = op.len;
        inline for (end_markers) |em| {
            if (std.mem.indexOfPos(u8, op, value_start, em)) |off| {
                if (off < value_end) value_end = off;
            }
        }
        return op[value_start..value_end];
    }
    return null;
}

/// Display order for the info block. Keep "Thread Updated" first so
/// the freshness signal reads top-to-bottom on the detail page.
/// Each entry must be the full label as F95 publishes it — case
/// matches the OP's casing, with no trailing colon (we append it
/// during output).
const INFO_KEYS = [_][]const u8{
    "Thread Updated",
    "Game Updated",
    "Release Date",
    "Developer",
    "Publisher",
    "Modder",
    "Original Developer",
    "Censored",
    "Censorship",
    "Version",
    "OS",
    "Platform",
    "Language",
    "Languages",
};

/// Locate `Key:` at a word boundary in stripped plain text and
/// capture the rest of that line as the value. Whitespace around the
/// value is trimmed. Returns null when the key isn't present or
/// matches only as a substring of a longer word.
fn findKeyValueInPlain(plain: []const u8, key: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, plain, search_from, key)) |i| {
        const after_i = i + key.len;
        // Word-boundary check on the leading side — `i == 0` or the
        // preceding byte must not be alphanumeric (so "Updated"
        // inside "Thread Updated" or "OUTDATED" doesn't match).
        const before_ok = i == 0 or !std.ascii.isAlphanumeric(plain[i - 1]);
        if (!before_ok) {
            search_from = i + 1;
            continue;
        }
        // Skip optional whitespace then require a colon.
        var j = after_i;
        while (j < plain.len and (plain[j] == ' ' or plain[j] == '\t')) : (j += 1) {}
        if (j >= plain.len or plain[j] != ':') {
            search_from = i + 1;
            continue;
        }
        // Skip past the colon and leading value whitespace.
        var value_start = j + 1;
        while (value_start < plain.len and (plain[value_start] == ' ' or plain[value_start] == '\t')) : (value_start += 1) {}
        var value_end = std.mem.indexOfScalarPos(u8, plain, value_start, '\n') orelse plain.len;
        while (value_end > value_start and (plain[value_end - 1] == ' ' or plain[value_end - 1] == '\t' or plain[value_end - 1] == '\r')) : (value_end -= 1) {}
        if (value_end > value_start) {
            return plain[value_start..value_end];
        }
        search_from = value_end + 1;
    }
    return null;
}

test "extractThreadInfo: typical OP block" {
    const html =
        "<article class=\"message-threadStarterPost\"><div class=\"bbWrapper\">" ++
        "<b>Thread Updated:</b> 2026-05-02<br>" ++
        "<b>Release Date:</b> 2026-05-01<br>" ++
        "<b>Developer:</b> TimeWizardStudios <a>Patreon</a> - <a>Itch.io</a> - <a>Discord</a><br>" ++
        "<b>Censored:</b> No<br>" ++
        "<b>Version:</b> 1.63<br>" ++
        "<b>OS:</b> Windows, Mac, Linux<br>" ++
        "<b>Language:</b> English<br>" ++
        "<b>Genre:</b> rpg" ++
        "</div></article>";
    const info_opt = try extractThreadInfo(std.testing.allocator, html);
    const info = info_opt.?;
    defer std.testing.allocator.free(info);
    try std.testing.expect(std.mem.indexOf(u8, info, "Thread Updated: 2026-05-02") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "Release Date: 2026-05-01") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "Censored: No") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "Version: 1.63") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "OS: Windows, Mac, Linux") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "Language: English") != null);
    // Developer line includes the inline link text run-on.
    try std.testing.expect(std.mem.indexOf(u8, info, "Developer: TimeWizardStudios") != null);
    // Genre is NOT in INFO_KEYS, so we don't include it.
    try std.testing.expect(std.mem.indexOf(u8, info, "Genre") == null);
}

test "fuzz: thread title/entity parsers survive arbitrary input" {
    try std.testing.fuzz({}, fuzzThreadParsers, .{ .corpus = &.{
        fuzzSeed("[VN] [Ren'Py] Game Name [v1.2.3] [DevName]"),
        fuzzSeed("Title &amp; more &#x27;stuff&#39; &lt;here&gt;"),
        fuzzSeed("&&&&&#"),
    } });
}

fn fuzzThreadParsers(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [FUZZ_BUF_LEN]u8 = undefined;
    const n = smith.slice(&buf);
    const src = buf[0..n];

    _ = parseTitleParts(src);

    var out_buf: [FUZZ_BUF_LEN]u8 = undefined;
    const decoded = decodeHtmlEntities(&out_buf, src);
    // Entity decoding only ever shrinks or preserves length.
    try std.testing.expect(decoded.len <= src.len);
}

/// Harness read-buffer length. fuzzSeed payloads must fit this, or Smith's
/// decode silently rejects the length and replays the seed as empty.
const FUZZ_BUF_LEN = 2048;

/// Encode one corpus entry for a testOne that makes a single smith.slice()
/// call: 4-byte LE length prefix + payload (Smith input stream format).
/// The payload must fit the harness read buffer (FUZZ_BUF_LEN): a longer
/// length is rejected by Smith's decode and the seed silently replays as
/// an empty string.
fn fuzzSeed(comptime payload: []const u8) []const u8 {
    comptime std.debug.assert(payload.len <= FUZZ_BUF_LEN);
    const S = struct {
        const entry: [4 + payload.len]u8 = blk: {
            var e: [4 + payload.len]u8 = undefined;
            std.mem.writeInt(u32, e[0..4], payload.len, .little);
            @memcpy(e[4..], payload);
            break :blk e;
        };
    };
    return &S.entry;
}
