// Public API of the f95 context.

const dom = @import("domain.zig");
const cli = @import("client.zig");
const svc = @import("service.zig");
const auth_mod = @import("auth.zig");

pub const errors = @import("errors.zig");

pub const ScrapedThread = dom.ScrapedThread;
pub const DownloadHost = dom.DownloadHost;
pub const DownloadLink = dom.DownloadLink;
pub const BookmarkEntry = dom.BookmarkEntry;

pub const Client = cli.Client;
/// Login/session parsing. Exposed so the test suite can exercise the pure
/// parsers against hostile server responses without a network.
pub const auth = @import("auth.zig");
pub const Service = svc.Service;
pub const Credentials = auth_mod.Credentials;

pub const extractThreadId = cli.extractThreadId;
pub const canonicalUrl = cli.canonicalUrl;

/// Bookmark scraping helpers — exposed so action workers can free the
/// returned entries via `bookmarks.freeAll`.
pub const bookmarks = @import("bookmarks.zig");

/// Thread-page parsers — `parseTitleParts` is reused by the bookmarks
/// flow to seed game rows with name/version/developer parsed from the
/// anchor text on the bookmarks page (no need to wait for a full
/// thread sync to show real names).
pub const thread = @import("thread.zig");
pub const tags = @import("tags.zig");
/// Donor (Tier 1) DDL helpers — POST /sam/dddl.php and resolve the
/// short-lived signed URL. Caller frees the returned slice.
pub const donor_ddl = @import("donor_ddl.zig");
pub const rss = @import("rss.zig");

// Pull nested tests into this module's test binary. Without these
// references the compiler only analyzes the re-exported symbols above,
// so nested `test` blocks would silently no-op (same idiom as
// downloads.zig / importers.zig roots).
test {
    _ = @import("auth.zig");
    _ = @import("bookmarks.zig");
    _ = @import("client.zig");
    _ = @import("domain.zig");
    _ = @import("donor_ddl.zig");
    _ = @import("errors.zig");
    _ = @import("rss.zig");
    _ = @import("service.zig");
    _ = @import("tags.zig");
    _ = @import("thread.zig");
}
