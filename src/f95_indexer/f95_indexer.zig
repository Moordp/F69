// F95Indexer cache API client. Two endpoints, exactly mirroring the
// way F95Checker uses them — chunks of 10 for /fast, /full/{id}?ts=
// only for changed threads.
//
// User-Agent identifies f69 specifically (see client.USER_AGENT) so
// the indexer maintainer can differentiate our traffic.
//
// See `docs/F95CHECKER-DATA-FLOW.md` for the full protocol context
// and `docs/superpowers/specs/2026-05-26-f95-indexer-backend-design.md`
// for the f69-side design decisions.

const cli = @import("client.zig");
const map = @import("mapping.zig");

pub const Client = cli.Client;
pub const FastResult = cli.FastResult;
pub const ThreadData = cli.ThreadData;
pub const DownloadGroup = cli.DownloadGroup;
pub const DownloadEntry = cli.DownloadEntry;
pub const USER_AGENT = cli.USER_AGENT;
pub const DEFAULT_BASE_URL = cli.DEFAULT_BASE_URL;
pub const MAX_IDS_PER_FAST = cli.MAX_IDS_PER_FAST;

/// Stamp a row with this value after every successful `/full`. Bump
/// the integer whenever the mapping evolves (new field parsed, an
/// existing field's translation changes, etc.). The refresh path
/// force-/full's any row whose stored version != this constant.
///
/// Mirrors F95Checker's `last_check_version` mechanism (see
/// `last_check_before("10.1.1", game.last_check_version)` in
/// `~/projects/F95Checker/modules/api.py:full_check`).
///
/// Version log:
///   1 — original mapping. Filled: name, version, developer, rating,
///       vote_count, description_md, changelog_md, screenshots,
///       last_updated_at, last_indexer_change, last_scraped_at.
///       Missing: engine, dev_status, tags, download_links,
///       downloads_md, thread_info_md.
///   2 — adds: engine (from type_int), dev_status (from status_int),
///       tags (via tag_table.lookup), download_links + downloads_md
///       (from indexer's grouped downloads), synthesized
///       thread_info_md header block.
///   3 — downloads_md uses f69's structured-text format
///       (`[B]label[/B]\n• [LINK=url]host[/LINK]` per row) instead of
///       markdown. The Downloads tab's `renderStructuredText` only
///       recognizes that format; v2 rows rendered as inert text.
///   4 — downloads_md emits two-level hierarchy with bulleted links
///       per bucket.
///   5 — current. downloads_md mimics F95's native layout: each
///       bucket is a single `[B]Win/Linux:[/B] HOST - HOST - HOST`
///       inline line. Section banners stay `## H2`. Much closer to
///       what the forum's OP actually shows.
pub const PARSER_VERSION: u32 = 5;

pub const Error = @import("errors.zig").Error;

pub const engineFromTypeInt = map.engineFromTypeInt;
pub const devStatusFromStatusInt = map.devStatusFromStatusInt;
pub const translateTags = map.translateTags;
pub const encodeDownloadLinks = map.encodeDownloadLinks;
pub const buildDownloadsMd = map.buildDownloadsMd;
pub const buildThreadInfoMd = map.buildThreadInfoMd;

// Pull nested tests into this module's test binary (same idiom as
// downloads.zig / importers.zig roots).
test {
    _ = @import("client.zig");
    _ = @import("errors.zig");
    _ = @import("mapping.zig");
    _ = @import("tag_table.zig");
}
