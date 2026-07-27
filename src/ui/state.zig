// UI state. Single struct lives in main; UI mutates it in event
// handlers; render reads it each frame.

const std = @import("std");
const library = @import("library");
const dvui = @import("dvui");
const buf_mod = @import("buf.zig");
const owned = @import("owned.zig");
const import_job_mod = @import("import_job.zig");
const folder_import_job_mod = @import("folder_import_job.zig");
pub const MessageBuf = buf_mod.MessageBuf;

pub const Screen = enum {
    library,
    detail,
    settings,
    /// Paste F95Zone thread URLs / IDs — bulk-create library rows.
    import_urls,
    /// Scan any flat directory of game subfolders.
    import_folder,
    /// Review F95Checker DB rows before committing. Mode picker
    /// lives here so the user picks Move/Copy/Link at the moment
    /// of import (instead of having to set it in Settings first).
    /// Source DB is opened READ-ONLY; nothing in `~/.config/f95checker`
    /// is mutated regardless of the chosen mode.
    import_f95_review,
    downloads,
    diagnostics,
    recipe_editor,
    mods_for_game,
    /// Engine-wide ("universal") mods registry — add/list/delete mods that
    /// apply across all games of an engine. Reached from the library top bar.
    universal_mods,
};

/// Per-import transfer mode. Applies to every import path: folder
/// scan (main menu), F95Checker / xLibrary DB import (Settings →
/// Library), etc.
///
/// `move`  — cut + paste. Cheap rename on same FS, or copy-verify-
///           delete cross-FS. Final disk use is 1x.
/// `copy`  — leaves source intact. Final disk use is 2x.
/// `link`  — leaves source intact AND doesn't copy. f69 just records
///           a library row whose install_path points at the source
///           directory. Final disk use is 0 extra bytes; the safest
///           mode (no file mutation, ever) but means f69's launcher
///           reaches into the original location every time, so moving
///           or deleting the source orphans the install.
pub const ImportMode = enum { move, copy, link };

/// Which target the import preview row's Link cell points at. The
/// preview rebuilds the user's intent each frame from this enum +
/// `link_thread_id`; the commit path branches on it.
pub const FolderImportLinkState = enum(u8) {
    /// User hasn't decided yet (or typed text doesn't resolve to a
    /// known library game and isn't an F95 URL). Commit refuses.
    unresolved,
    /// `link_thread_id` is set and points at an existing
    /// `library.Game.f95_thread_id`. Commit attaches the install to
    /// that game.
    linked_existing,
    /// New library row with a random high-bit-set thread id
    /// (`name_match.customNewThreadId`). Used for games without an
    /// F95 thread.
    custom_new,
    /// `link_buf` holds an F95Zone thread URL. Commit resolves it
    /// (scrape thread → upsert library row) before attaching install.
    f95_url,
};

/// Max compat issues per preview row that we surface. Recipes
/// matching the same install are rare (typically 0 or 1 — the
/// renpy7 X11 fix on a NixOS host); cap at 4 so the row table stays
/// readable even when something weird hits.
pub const FOLDER_IMPORT_MAX_ISSUES: u8 = 4;
pub const FOLDER_IMPORT_ISSUE_ID_LEN: usize = 64;

/// One matched compat recipe surfaced on a preview row. Inlined
/// (fixed-size buffers) so the row state doesn't carry an allocator
/// reference. `id` is the recipe slug for caller lookups; `title`
/// is the human-readable label rendered on the chip.
pub const FolderImportIssue = struct {
    id_buf: [FOLDER_IMPORT_ISSUE_ID_LEN]u8 = [_]u8{0} ** FOLDER_IMPORT_ISSUE_ID_LEN,
    id_len: u8 = 0,
    title_buf: [96]u8 = [_]u8{0} ** 96,
    title_len: u8 = 0,

    pub fn id(self: *const FolderImportIssue) []const u8 {
        return self.id_buf[0..self.id_len];
    }
    pub fn title(self: *const FolderImportIssue) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

/// Per-row editable state for the folder-import preview. One slot
/// per `bundle.games[idx]`. Lives in a heap-allocated slice owned by
/// `State` (see `folder_scan_row_states`). Reset on a fresh scan.
pub const FolderImportRowState = struct {
    /// Editable name. Used only when `link_state == .custom_new` —
    /// for linked rows the library game's stored name wins. Prefilled
    /// from `folder_scan.parseFolderName`.
    name_buf: [128]u8 = [_]u8{0} ** 128,
    /// Editable version. Becomes the install row's `version` (which
    /// is also the install's user-facing name). Prefilled from the
    /// folder name, or from the linked game's `latest_version` when
    /// the folder name carried no version token.
    version_buf: [64]u8 = [_]u8{0} ** 64,
    /// What the user has typed (or what we prefilled from the best
    /// library match) for the Link cell. Drives the typeahead.
    link_buf: [256]u8 = [_]u8{0} ** 256,
    /// User's committed state for this row. Determines the commit
    /// path: linked_existing / custom_new / f95_url / unresolved.
    link_state: FolderImportLinkState = .unresolved,
    /// Resolved thread id for `linked_existing`; the resolved id
    /// after F95-URL scrape for `f95_url`. Null otherwise.
    link_thread_id: ?u64 = null,
    /// True while the typeahead dropdown is open. Closes on row blur,
    /// pick, or Escape.
    typeahead_open: bool = false,
    /// User include-in-commit toggle. Defaults true so the typical
    /// "import everything in this folder" flow is one click.
    checked: bool = true,
    /// Pre-commit compat scan results. Populated by
    /// `actions.doFolderScan` after the bundle is built — the host
    /// probe is one-time at app start so per-install scans are
    /// stat-only and cheap enough to run inline. The user sees the
    /// matched recipes as chips on the row; after commit, the
    /// Apply Fix dialog on the detail screen takes over.
    issues: [FOLDER_IMPORT_MAX_ISSUES]FolderImportIssue = [_]FolderImportIssue{.{}} ** FOLDER_IMPORT_MAX_ISSUES,
    issue_count: u8 = 0,
};
/// Sort options. `weighted` uses Game.weightedRating against the
/// library's mean rating + a fixed prior weight, so games with few
/// votes don't unfairly dominate over well-rated games. `sync_state`
/// promotes already-synced rows above placeholder "(unsynced)" ones —
/// previously this was implicit, now it's an explicit pick.
pub const SortColumn = enum { name, rating, weighted, votes, last_updated, sync_state, last_played_version };
pub const SortDir = enum { asc, desc };
pub const LoginStatus = enum { unknown, logged_out, logged_in, logging_in, err };
pub const View = enum { grid, list, kanban };
pub const Tab = enum { overview, changelog, downloads, tools, notes, guides, journal };

/// Filter tabs for the Mods page. Each filters the master list of
/// (archive, recipe) pairs by state:
///   installed     — applied to the selected install
///   ready         — has archive + recipe but not installed
///   needs_archive — recipe exists, no archive yet (imported)
///   needs_recipe  — archive exists, no recipe yet (orphan)
pub const ModsTab = enum { installed, ready, needs_archive, needs_recipe };

/// Checkbox filter for the two-pane Mods view's list pane. Mods
/// matching any *unchecked* category are hidden. Default all-on so
/// the user sees every modfile on first visit.
pub const ModsViewFilter = struct {
    installed: bool = true,
    ready: bool = true,
    needs_setup: bool = true,
};

/// Known classes of launch problems that the diagnostic engine can
/// recognise and propose a "Fix issue" remedy for. `null` (in
/// `state.launch_diag_fix_id`) means we surfaced the issue but don't
/// have an automated fix — the dialog hides the Fix button.
pub const LaunchFixId = enum {
    /// Launcher's `ldd` reported missing shared libraries that look
    /// like GPU stack / GL libs. Fix: re-launch with LD_LIBRARY_PATH
    /// prepended with the host GPU driver dir + standard distro dirs.
    host_gpu_paths,
    /// A compat recipe matches the install and is currently unapplied.
    /// Fix: apply the recipe (its `apply` ops mutate env / patch the
    /// install) then relaunch. The recipe's id is stashed in
    /// `state.launch_diag_compat_recipe_buf`.
    compat_recipe,
};
pub const SettingsTab = enum { appearance, library, updates, downloads, games_launch, accounts, presets, about };

/// Recipe-wizard modal phases. The wizard renders one page per step,
/// with Back/Next driving the transition. `review` is terminal — save
/// from there closes the modal.
pub const WizardStep = enum {
    meta, // mod name, version, F95 post URL, target game version
    install, // pick install blocks (extract / extract_inner / copy / move / delete / chmod_x)
    relations, // requires / conflicts / load_after pickers
    review, // show generated ZON; save / cancel
};

/// One install-step block being built up by the wizard. The wizard's
/// "Add block" buttons append one of these; finalize converts them
/// into a `[]recipe.InstallStep` written into the saved recipe.
pub const WizardBlockKind = enum {
    extract,
    extract_inner,
    copy,
    move,
    delete,
    chmod_x,
};

/// Fixed-size scratch for a single wizard block. The wizard owns up
/// to `WIZARD_MAX_BLOCKS` of these. Strings are inline buffers so the
/// allocator stays out of the wizard's hot path.
pub const WizardBlock = struct {
    kind: WizardBlockKind,
    /// extract.to / extract_inner.to / chmod_x first path / copy.src /
    /// move.src / delete.path — the "first" path field of the block.
    a_buf: [256]u8 = [_]u8{0} ** 256,
    /// extract_inner.archive (the inner archive within main staging) /
    /// copy.dest / move.dest — the "second" path field, unused for
    /// `extract`/`delete`/`chmod_x`.
    b_buf: [256]u8 = [_]u8{0} ** 256,
    /// strip count for `extract` / `extract_inner`.
    strip: u8 = 0,
};

pub const WIZARD_MAX_BLOCKS: usize = 32;
pub const WIZARD_MAX_RELATIONS: usize = 16;
pub const WIZARD_MAX_INSTALL_VERSIONS: usize = 16;

/// Per-wizard state. Allocated/freed by `actions/mods.zig` when the
/// user clicks "Create recipe" / cancels / saves.
pub const WizardState = struct {
    step: WizardStep = .meta,
    /// Modfile this wizard is authoring a recipe for. SHA-256 hex.
    modfile_id_buf: [64]u8 = [_]u8{0} ** 64,
    modfile_id_len: usize = 0,
    /// Which game the modfile belongs to (used for recipe.for_game
    /// and to look up the modfile back at finalize time).
    game_thread_id: u64 = 0,
    /// Cached game recipe id for the current game — set when the
    /// wizard opens. Drives the `for_game` field of the output.
    for_game_buf: [128]u8 = [_]u8{0} ** 128,
    for_game_len: usize = 0,

    name_buf: [160]u8 = [_]u8{0} ** 160,
    version_buf: [32]u8 = [_]u8{0} ** 32,
    post_url_buf: [512]u8 = [_]u8{0} ** 512,
    for_game_version_buf: [64]u8 = [_]u8{0} ** 64,

    /// Versions of installed builds for this game, captured when the
    /// wizard opens. Rendered as a dropdown on the meta page so the
    /// user picks the existing install instead of typing a version
    /// by hand (and getting it subtly wrong).
    install_versions_buf: [WIZARD_MAX_INSTALL_VERSIONS][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** WIZARD_MAX_INSTALL_VERSIONS,
    install_versions_count: usize = 0,
    install_versions_pick: usize = 0,

    blocks: [WIZARD_MAX_BLOCKS]WizardBlock = [_]WizardBlock{.{ .kind = .extract }} ** WIZARD_MAX_BLOCKS,
    block_count: usize = 0,

    /// Selected requires / conflicts / load_after — each entry is a
    /// recipe id picked from the existing mod recipes for this game.
    requires_buf: [WIZARD_MAX_RELATIONS][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** WIZARD_MAX_RELATIONS,
    requires_len: usize = 0,
    conflicts_buf: [WIZARD_MAX_RELATIONS][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** WIZARD_MAX_RELATIONS,
    conflicts_len: usize = 0,
    load_after_buf: [WIZARD_MAX_RELATIONS][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** WIZARD_MAX_RELATIONS,
    load_after_len: usize = 0,

    /// Last error message (validator failure, file write failure…)
    /// shown on the review page.
    err_msg_buf: [240]u8 = [_]u8{0} ** 240,
    err_msg_len: usize = 0,

    /// True when the simulation detail-list (per-file rows) is
    /// expanded. UI button toggles. Persists across paints inside
    /// the wizard's lifetime; resets to false when wizard closes.
    sim_details_expanded: bool = false,

    /// When set, the simulation panel highlights writes produced by
    /// this step index. Set by clicking a block's title row; cleared
    /// by clicking the same block again or by re-opening the wizard.
    sim_highlight_step: ?usize = null,

    /// Screen the user was on when this wizard was opened. closeWizard
    /// pops back to it. Required field — every caller must specify
    /// where to return so the navigation can't silently drop the user
    /// in the wrong place.
    return_screen: Screen,
    /// Live-filter text for the preview pane's file tree. Empty =
    /// show everything. Non-empty = hide tree rows whose name (or any
    /// descendant's name) doesn't contain the substring,
    /// case-insensitive. The buffer is fixed-size so the wizard
    /// stays alloc-free.
    preview_search_buf: [128]u8 = [_]u8{0} ** 128,
};

/// Lifecycle of a single Sync click. Driven by the UI thread off
/// observations of the worker thread's atomic flag.
pub const SyncStatus = enum { idle, running, ok, err };

/// Hard upper bound on the sync-slot array size. The runtime-tunable
/// `state.max_parallel_sync` (Settings → Sync) clamps the *effective*
/// parallelism to a value in `[1, MAX_PARALLEL_SYNC]`. Treat this
/// constant as "ceiling Zig needs at compile time for the array",
/// not "the actual concurrency". Mirrors F95Checker's
/// `max_connections` knob — capped at 16 since beyond that we'd
/// start to risk indexer-side rate-limits with no real wall-time win.
pub const MAX_PARALLEL_SYNC: usize = 16;

/// Hard ceiling on the screenshot ImageJob slot array. Same
/// semantics as `MAX_PARALLEL_SYNC` — the effective concurrency is
/// the runtime `state.max_parallel_image`. Image bytes come from
/// `attachments.f95zone.to` (a CDN that bypasses the forum rate
/// limit), so the ceiling can match the sync pool without risk.
pub const MAX_PARALLEL_IMAGE: usize = 16;

/// Default effective parallelism on first launch. 4 is the sweet
/// spot for a typical home network and matches F95Checker's default.
pub const DEFAULT_PARALLEL: u32 = 4;

/// Source of game metadata during refresh.
///   `.indexer` — F95Indexer cache API (`api.f95checker.dev`). Default.
///                Two-call protocol (`/fast` then `/full/{id}?ts=`) used
///                exactly the way F95Checker does. Auth-free.
///   `.scraper` — direct HTML scrape of f95zone.to thread pages. The
///                original path; kept as the alternative for users who
///                don't want to rely on the third-party cache.
pub const RefreshBackend = enum {
    indexer,
    scraper,

    pub fn fromStr(s: []const u8) RefreshBackend {
        return std.meta.stringToEnum(RefreshBackend, s) orelse .indexer;
    }

    pub fn label(self: RefreshBackend) []const u8 {
        return switch (self) {
            .indexer => "F95Indexer",
            .scraper => "Direct F95 scraper",
        };
    }
};

/// Data source for the "Check for updates" walker. `builtin` uses f69's
/// own latest-updates scan (`latest_data.php?cmd=list`, paginated back to
/// the last check); `rss` uses F95's official `cmd=rss` feed (one request,
/// ~30 newest). RSS is lighter but shallower; builtin covers a longer
/// window. When `rss` is chosen it applies regardless of `refresh_backend`.
pub const UpdateCheckSource = enum {
    builtin,
    rss,

    pub fn fromStr(s: []const u8) UpdateCheckSource {
        return std.meta.stringToEnum(UpdateCheckSource, s) orelse .builtin;
    }

    pub fn label(self: UpdateCheckSource) []const u8 {
        return switch (self) {
            .builtin => "f69 latest-updates scan",
            .rss => "F95 RSS feed",
        };
    }
};

/// Severity of a toast notification. Drives the leading glyph + how
/// long the toast hangs around before auto-dismissing.
///   info    — plain "here's what happened" (no glyph). 3 s.
///   success — confirmation of a user-initiated action ("Renamed."). 3 s.
///   warn    — non-fatal hint ("Auto-update skipped: recipe lags"). 6 s.
///   err     — failure path ("Spawn failed: …"). Stays until clicked.
pub const ToastKind = enum { info, success, warn, err };

/// One toast record. Buffer is inline (no allocator) so any code
/// path can push without needing `lib.alloc` plumbing. Message
/// truncated at `MAX_TOAST_MSG`.
///
/// TTL is in *frames* (not wall-clock) to avoid threading `std.Io`
/// through every state setter. Drain decrements once per frame; at
/// ~60 fps the 180-frame default ≈ 3 seconds. Vsync-dependent so
/// 144 Hz monitors fade twice as fast — fine for transient UI.
pub const MAX_TOAST_MSG: usize = 240;
pub const Toast = struct {
    buf: [MAX_TOAST_MSG]u8 = [_]u8{0} ** MAX_TOAST_MSG,
    len: usize = 0,
    kind: ToastKind = .info,
    /// Frames remaining before this toast disappears. `maxInt(u32)`
    /// = persistent (used by `.err` so failures don't slip past).
    ttl_frames: u32 = 0,

    pub fn msg(self: *const Toast) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Per-kind default TTL in frames at 60 fps (vsync-dependent — 144 Hz
/// monitors fade roughly proportionally faster, which is fine for
/// Toast lifetimes in frames (~60 Hz target). Two buckets:
///   info / success → 3 s (transient acks, "queued X", "renamed")
///   warn / err     → 5 s (something the user might want to read /
///                    screenshot before it goes away)
/// All four are click-to-dismiss so the user can clear them
/// immediately without waiting for the timer.
const TOAST_TTL_INFO: u32 = 300;
const TOAST_TTL_SUCCESS: u32 = 300;
const TOAST_TTL_WARN: u32 = 300;
const TOAST_TTL_ERR: u32 = 300;

/// Cap on active toasts. Pushing a sixth evicts the oldest non-error.
pub const MAX_TOASTS: usize = 5;

/// Per-install management action launched from the install picker's
/// ⋯ menu. Held in `State.manage_action`; the next-frame UI renders
/// a matching modal (rename text entry, delete confirm) and clears
/// the action when the user closes it.
pub const ManageAction = enum { none, rename, delete };

/// Capacity of the cover-thumbnail round-robin cache. Holds `.t` thumbs
/// (~21 KB avg), so 512 entries ≈ 10 MB — cheap, and big enough to keep
/// many screens of scroll-back resident so scrolling doesn't re-read.
/// Eviction is FIFO via `cover_cache_next`.
pub const COVER_CACHE_CAP: usize = 512;
/// Covers warmed (page cache) at startup. Async on-demand loading
/// (`spawnCoverLoadIfRoom`) handles the rest, so this only needs to
/// cover the first screen or two.
pub const COVER_PREWARM: usize = 96;
/// Concurrent async cover-thumbnail loaders. A small pool: enough to
/// fill a fresh viewport over a few frames without flooding the FS.
pub const COVER_LOAD_WORKERS: usize = 6;
/// Capacity of the per-game thumbnail-strip cache. Cover (idx 0) +
/// up to ~127 screenshots. Some games (Max's Life: 23, popular RPGs:
/// 27+) ship enough preview images that the old 21-slot cap silently
/// returned null for thumbs past index 20, even though `.s<N>.t` was
/// on disk. 128 slots costs 1 KB of pointers in State — trivial.
pub const THUMB_CACHE_CAP: usize = 128;
/// Capacity of the per-game full-resolution slide cache. Slot 0 holds
/// the cover; 1..N hold screenshots. Capped at 32 — comfortably covers
/// the typical 0..20-screenshot range with margin, and bounds the
/// peak memory at ~32 × ~1 MB = ~32 MB per visited game (freed on
/// game switch). Games with more screenshots fall through to a null
/// read for indices >= 32.
pub const SLIDE_CACHE_SLOTS: usize = 32;

pub const CoverCacheEntry = struct {
    thread_id: u64,
    bytes: []u8,
};

pub const SyncStateFilter = enum { all, synced, unsynced };

/// Filter the library by whether the game has at least one `installs`
/// row. `unknown` is the explicit "no install on record" state — we
/// already auto-write a row in `drainPostInstall` so anything missing
/// is genuinely uninstalled.
pub const InstalledFilter = enum { all, installed, not_installed };

/// Unit for the "check for updates every X" recurring auto-check.
/// Drives the multiplier between the user's integer count and the
/// elapsed-seconds comparison the main loop runs.
pub const AutoCheckUnit = enum {
    minutes,
    hours,
    days,

    pub fn seconds(self: AutoCheckUnit) i64 {
        return switch (self) {
            .minutes => 60,
            .hours => 60 * 60,
            .days => 24 * 60 * 60,
        };
    }
};

/// Persisted preferences for the auto-update-check workflow.
pub const AutoCheckSettings = struct {
    /// True → trigger one update-check once at app start (after the
    /// library has loaded and any in-flight bookmark import wraps).
    on_startup: bool = false,
    /// True → trigger an update-check whenever
    /// `(now - last_update_check_ts) >= interval_count * unit`.
    interval_enabled: bool = false,
    /// Clamped to 1..999 on load so a bad file can't render the
    /// interval pathologically tight or unreachable.
    interval_count: u32 = 6,
    interval_unit: AutoCheckUnit = .hours,
};

pub const Filters = struct {
    engine: EngineMask = .{},
    status: StatusMask = .{},
    /// Inclusive lower bound on the community (F95) rating; null = no filter.
    min_rating: ?f32 = null,
    /// Inclusive lower bound on the user's OWN rating (`Game.user_rating`);
    /// null = no filter. Distinct from `min_rating` (community score).
    min_user_rating: ?f32 = null,
    /// Tri-state filter on whether a row has ever been synced. Default
    /// `.all` shows everything; `.synced` shows only rows where
    /// `last_scraped_at != null`, `.unsynced` shows only the placeholder
    /// "(unsynced)" rows.
    sync_state: SyncStateFilter = .all,
    /// "Installed / Not installed / All" filter. Independent of
    /// sync state — a synced row may or may not have an install.
    installed: InstalledFilter = .all,
    /// Substring match against `Game.developer`, case-insensitive.
    /// Empty buffer = no filter. ASCII-only contains check.
    developer_buf: [64]u8 = [_]u8{0} ** 64,
    /// Comma-separated tag list — game must have EVERY listed tag
    /// (case-insensitive substring of any of `Game.tags`).
    tag_include_buf: [256]u8 = [_]u8{0} ** 256,
    /// Comma-separated tag list — game must have NONE of these tags.
    tag_exclude_buf: [256]u8 = [_]u8{0} ** 256,
    /// Dev-status mask: scraped from F95 (completed / abandoned /
    /// on hold / in progress / unknown). Any-bit-set ⇒ filter active.
    dev_status: DevStatusMask = .{},
    /// Censored mask: scraped from the OP's "Censored:" line.
    censored: CensoredMask = .{},

    /// Filter masks are `std.EnumSet`s typed against the canonical
    /// domain enums. Adding a new variant becomes a one-edit change
    /// (the enum itself); the mask, match() arm, and `count()` helpers
    /// all pick it up automatically. Previously each mask was a
    /// hand-rolled bool-struct + maskAny() helper + switch arm —
    /// three coupled sites that drifted on every enum extension.
    pub const EngineMask = std.EnumSet(library.Engine);
    pub const StatusMask = std.EnumSet(library.CompletionStatus);
    pub const DevStatusMask = std.EnumSet(library.DevStatus);
    pub const CensoredMask = std.EnumSet(library.CensoredState);

    pub fn empty(self: Filters) bool {
        return self.min_rating == null and self.min_user_rating == null and self.sync_state == .all and
            self.engine.count() == 0 and
            self.status.count() == 0 and
            self.dev_status.count() == 0 and
            self.censored.count() == 0 and
            developerSliceLen(&self.developer_buf) == 0 and
            tagSliceLen(&self.tag_include_buf) == 0 and
            tagSliceLen(&self.tag_exclude_buf) == 0;
    }

    /// View the live (sentinel-trimmed) slice of a fixed-size text-input
    /// buffer. dvui's textEntry leaves the unused tail zeroed.
    pub fn developerSlice(self: *const Filters) []const u8 {
        return sliceFromBuf(u8, &self.developer_buf);
    }
    pub fn tagIncludeSlice(self: *const Filters) []const u8 {
        return sliceFromBuf(u8, &self.tag_include_buf);
    }
    pub fn tagExcludeSlice(self: *const Filters) []const u8 {
        return sliceFromBuf(u8, &self.tag_exclude_buf);
    }
    fn sliceFromBuf(comptime T: type, buf: []const T) []const T {
        var n: usize = 0;
        while (n < buf.len and buf[n] != 0) : (n += 1) {}
        return buf[0..n];
    }
    fn developerSliceLen(buf: *const [64]u8) usize {
        return sliceFromBuf(u8, buf).len;
    }
    fn tagSliceLen(buf: *const [256]u8) usize {
        return sliceFromBuf(u8, buf).len;
    }

    pub fn match(self: Filters, g: *const library.Game) bool {
        const is_unsynced = std.mem.eql(u8, g.name, "(unsynced)");
        switch (self.sync_state) {
            .all => {},
            .synced => if (is_unsynced) return false,
            .unsynced => if (!is_unsynced) return false,
        }
        if (self.min_rating) |min| {
            const r = g.rating orelse 0;
            if (r < min) return false;
        }
        if (self.min_user_rating) |min| {
            const r = g.user_rating orelse 0;
            if (r < min) return false;
        }

        // Each mask: if any bit is set, the game's tag must be a
        // member. If none are set, the filter is inactive. EnumSet
        // collapses the four hand-rolled switch arms this used to
        // carry.
        if (self.engine.count() > 0 and !self.engine.contains(g.engine)) return false;
        if (self.status.count() > 0 and !self.status.contains(g.completion_status)) return false;
        if (self.dev_status.count() > 0 and !self.dev_status.contains(g.dev_status)) return false;
        if (self.censored.count() > 0 and !self.censored.contains(g.censored)) return false;

        // Developer text filter — case-insensitive substring.
        const dev_q = sliceFromBuf(u8, &self.developer_buf);
        if (dev_q.len > 0) {
            const dev = g.developer orelse return false;
            if (!asciiContainsIgnoreCase(dev, dev_q)) return false;
        }

        // Tag include — game must match EVERY listed tag (comma-
        // separated, case-insensitive substring of any of `g.tags`).
        const inc_raw = sliceFromBuf(u8, &self.tag_include_buf);
        if (inc_raw.len > 0) {
            var it = std.mem.splitScalar(u8, inc_raw, ',');
            while (it.next()) |raw| {
                const want = std.mem.trim(u8, raw, " \t");
                if (want.len == 0) continue;
                var hit = false;
                for (g.tags) |t| {
                    if (asciiContainsIgnoreCase(t, want)) {
                        hit = true;
                        break;
                    }
                }
                if (!hit) return false;
            }
        }

        // Tag exclude — game must match NONE of the listed tags.
        const exc_raw = sliceFromBuf(u8, &self.tag_exclude_buf);
        if (exc_raw.len > 0) {
            var it = std.mem.splitScalar(u8, exc_raw, ',');
            while (it.next()) |raw| {
                const banned = std.mem.trim(u8, raw, " \t");
                if (banned.len == 0) continue;
                for (g.tags) |t| {
                    if (asciiContainsIgnoreCase(t, banned)) return false;
                }
            }
        }

        return true;
    }

    fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var ok = true;
            for (needle, 0..) |nc, k| {
                if (std.ascii.toLower(haystack[i + k]) != std.ascii.toLower(nc)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
};

pub const State = struct {
    screen: Screen = .library,
    view: View = .grid,
    sort_column: SortColumn = .name,
    sort_dir: SortDir = .asc,
    /// Last sort actually applied to the games slice; null forces a
    /// re-sort (used after `reload_requested`).
    sort_applied_column: ?SortColumn = null,
    sort_applied_dir: ?SortDir = null,
    filters: Filters = .{},
    search_buf: [64]u8 = [_]u8{0} ** 64,
    /// f95_thread_id of the game currently displayed in detail screen.
    selected_thread: ?u64 = null,
    /// Currently shown slide in the detail-screen carousel. Slide 0
    /// is the cover; 1..N are screenshots. Reset when the user
    /// navigates to a different game.
    carousel_index: usize = 0,
    /// `selected_thread` value the carousel index is currently for.
    /// Detail screen detects mismatch + resets `carousel_index = 0`.
    carousel_for_thread: ?u64 = null,
    /// True while the click-to-enlarge image popup is showing the
    /// current carousel slide at native size in a modal floating
    /// window. dvui's `windowHeader` X-button writes false here when
    /// the user closes it.
    image_popup_open: bool = false,
    /// Activity dock (bottom bar) expanded into the full Downloads &
    /// Seeding drawer. Toggled by clicking the dock.
    dock_expanded: bool = false,
    /// Universal-Mods screen: the "+ Add universal mod" slide-over is open.
    universal_mod_add_open: bool = false,
    /// Lightbox-style rect for the bottom activity drawer; rewritten each
    /// frame to (window − rail − dock) so it tracks resizes.
    activity_drawer_rect: dvui.Rect = .{},
    /// Lightbox window rect, rewritten each frame to (window − margin) so the
    /// modal tracks the OS window size. Held in state because dvui's
    /// floatingWindow wants a stable `*Rect` across frames.
    image_popup_rect: dvui.Rect = .{},
    /// Multi-slot cache for the carousel slides' on-disk bytes. Slot
    /// 0 holds the full-resolution cover (path: `covers_dir/<tid>`);
    /// slots 1..N hold screenshots (path: `covers_dir/<tid>.s<idx>`).
    /// Slots are filled lazily on first paint per (thread, idx) and
    /// freed wholesale by `freeSlideCache` on game switch. Per-slot
    /// pointer stability across frames is what makes dvui's `.ptr`
    /// texture-cache strategy safe — the previous single-slot design
    /// freed + realloc'd on every slide change, and the
    /// GeneralPurposeAllocator commonly handed back the same address
    /// for the new content, causing dvui to serve the previous
    /// slide's GPU texture for the new bytes (visible as
    /// flickering/wrong images on rapid carousel navigation).
    ///
    /// Cap = 32, enough for the typical 0..20-screenshot range. Games
    /// with more screenshots fall through to a null read (placeholder
    /// renders) for indices >= 32 — `slideBytes` checks the bound.
    slide_cache_thread: ?u64 = null,
    slide_cache_bytes: [SLIDE_CACHE_SLOTS]?[]u8 = [_]?[]u8{null} ** SLIDE_CACHE_SLOTS,
    /// In-flight off-thread loader for a slide_cache slot. Set when
    /// `slideSlotBytes` encounters a miss; cleared by `drainSlideLoads`
    /// once the worker finishes. Single-slot serialises misses — fine
    /// for sequential carousel navigation, and keeps the UI thread off
    /// the read syscall.
    slide_load_job: ?*owned.SlideLoadJob = null,
    /// Thumb-strip cache. Holds bytes for every slide of the active
    /// game so the ribbon under the carousel doesn't re-read 21 files
    /// per frame. Fixed-size array keyed by slide idx (0 = cover,
    /// 1..N = screenshots). Filled lazily on first paint, freed on
    /// thread change / detail-page exit.
    thumb_cache_thread: ?u64 = null,
    thumb_cache_bytes: [THUMB_CACHE_CAP]?[]u8 = [_]?[]u8{null} ** THUMB_CACHE_CAP,
    /// Active tab inside the detail screen.
    detail_tab: Tab = .overview,
    /// Active tab inside the Mods page. Filters which lists render
    /// below the page header. Reset to `.installed` on game-change so
    /// new game opens to the "what's currently running" view.
    ///
    /// Legacy — kept while the tab-strip UI still exists in some flows.
    /// The two-pane Mods view doesn't read this; it uses
    /// `mods_view_filter` instead.
    mods_tab: ModsTab = .installed,
    /// Currently-selected entry in the two-pane Mods view. Stores the
    /// modfile sha-id (or recipe id, prefixed with `r:` for orphan
    /// recipes that aren't yet linked to an archive). Buffer length is
    /// chosen to fit both SHA-256 hex (64 chars) and recipe slugs.
    /// Empty = nothing selected → detail pane shows the empty-state
    /// hint.
    mods_selected_id_buf: [80]u8 = [_]u8{0} ** 80,
    mods_selected_id_len: usize = 0,
    /// Filter checkboxes in the left pane of the Mods view. All three
    /// default ON so the user sees every modfile on first visit.
    /// Session-only — not persisted across restarts.
    mods_view_filter: ModsViewFilter = .{},
    /// Active tab on the Settings screen.
    settings_tab: SettingsTab = .library,
    /// dvui ScrollInfo backing the detail-screen outer scrollArea.
    /// State-owned so we preserve the user's scroll position across
    /// tab switches (the body has a 500px min-height floor so a tab
    /// switch can't strand the scroll position past the page's end).
    detail_scroll: dvui.ScrollInfo = .{},
    /// Install id the Mods page is currently operating against.
    /// Lets the user mod a non-latest version explicitly (e.g. apply
    /// a fix to v0.20 while v0.21 is also installed). Null = use the
    /// newest install. Reset when navigating between games.
    mods_page_install_id: ?[36]u8 = null,

    /// Install id the install-picker dropdown currently displays.
    /// Persisted across frames so dropdown selections stick AND so
    /// the ⋯ menu has a stable target. Null means "use the latest
    /// install" (default behaviour, matches pre-multi-install code).
    detail_picker_install_id: ?[36]u8 = null,
    /// Active install-management action (rename / delete) launched
    /// from the picker's ⋯ menu. `.none` = no modal in flight.
    manage_action: ManageAction = .none,
    /// Install id the active management action targets.
    manage_install_id: ?[36]u8 = null,
    /// Text-entry buffer for the rename modal. NUL-terminated;
    /// `manualInstallNameSlice`-style trimmed reads.
    manage_rename_buf: [64]u8 = [_]u8{0} ** 64,
    /// Manual "edit game details" form (detail screen). Non-null thread-id
    /// means the form is open for that game; the buffers are seeded from the
    /// game when it opens. NUL-terminated. `edit_engine_idx` indexes
    /// `EDITABLE_ENGINES` in detail.zig.
    edit_details_for: ?u64 = null,
    edit_name_buf: [256]u8 = [_]u8{0} ** 256,
    edit_dev_buf: [128]u8 = [_]u8{0} ** 128,
    edit_ver_buf: [64]u8 = [_]u8{0} ** 64,
    edit_engine_idx: usize = 0,

    /// User tag-color overrides (tag -> 0xRRGGBB), loaded lazily from the DB
    /// and rebuilt (freed + null) after an edit. Freed at shutdown in ui.zig.
    tag_colors: ?std.StringHashMap(u32) = null,
    /// Tag whose color picker is open (NUL-terminated; empty = none).
    tag_color_editing: [128]u8 = [_]u8{0} ** 128,
    /// Working HSV bound to the open color picker.
    tag_color_hsv: dvui.Color.HSV = .{},
    /// Thread-id the per-detail-page state is currently scoped to.
    /// `detailScreen` compares this against `selected_thread` each
    /// frame and, on mismatch, resets per-page UI state via
    /// `resetDetailViewState`. Without this the active tab + scroll +
    /// popups carry over when the user navigates from one game's
    /// detail page to another's, which surprised the user.
    detail_state_for_thread: ?u64 = null,
    /// True when the user clicked Delete and we're showing the confirm
    /// banner. Cleared on Cancel or after the row + cover are gone.
    confirm_delete: bool = false,
    /// True when the user clicked the `?` next to Convert; expands an
    /// inline help block under the action row.
    convert_help_open: bool = false,
    /// User-configurable dvui content_scale. Mirrored into
    /// `Window.content_scale` every frame so adjusting the Settings
    /// slider takes effect immediately. Persisted to
    /// Rebuilt once per library-screen render: every f95_thread_id
    /// that has at least one install row. Used by the grid/list-view
    /// installed indicator and the `installed` filter. Rebuilt only when
    /// `Library.install_generation` advances (see `installed_set_gen`), not
    /// every frame; never referenced off the library-screen render path.
    installed_set: ?*owned.InstalledSet = null,
    /// `Library.install_generation` the `installed_set` was last built at.
    /// The set only changes when an install is added/removed, so we skip the
    /// per-frame SELECT + rebuild while the generation is unchanged.
    installed_set_gen: u64 = 0,
    /// Bumped whenever a game field is edited IN PLACE (status, etc.) without
    /// replacing the `games` slice. The library filter cache keys off the
    /// slice ptr + filter state, so an in-place edit is otherwise invisible
    /// to it — a status change while a status filter is active would leave the
    /// now-non-matching game on screen until an unrelated refresh. Folded into
    /// `filterSignature`; bump via `bumpGameEdit()`.
    game_edit_gen: u64 = 0,
    /// `<data_root>/ui_scale`.
    ui_scale: f32 = 1.25,
    /// Tracks the last persisted value so we don't rewrite the file
    /// on every slider tick.
    ui_scale_persisted: f32 = 1.25,
    /// Unix-seconds timestamp of the last successful "check updates"
    /// walk. Used as the stop-condition when scanning F95's
    /// latest-updates pages. Persisted to disk on each successful
    /// scan; 0 means "never checked".
    last_update_check_ts: i64 = 0,
    /// User preferences for automatically running the update-check
    /// walker. Source-of-truth lives here; mirrored to disk via
    /// `persistAutoCheckIfDirty`.
    auto_check: AutoCheckSettings = .{},
    /// Snapshot of the last value we wrote to disk — used to debounce
    /// the persist call when nothing actually changed.
    auto_check_persisted: AutoCheckSettings = .{},
    /// `<data_root>/lib_prefs` — serialized library view/sort/filter
    /// state (see `serializeLibPrefs`). The persisted snapshot is
    /// compared against a fresh serialization each frame to debounce
    /// disk writes; only the first `_len` bytes are meaningful.
    lib_prefs_persisted: [128]u8 = [_]u8{0} ** 128,
    lib_prefs_persisted_len: usize = 0,
    /// One-shot flag — flips to true after the on-startup auto check
    /// has fired (or been skipped because workers were busy). Stays
    /// true for the rest of the run so we don't repeatedly trigger
    /// it after bookmarks finish importing.
    auto_check_did_startup: bool = false,
    /// Saved on library→detail transition, restored on Back.
    library_scroll: f32 = 0,
    /// Persistent scroll state for the library screen — `virtual_size`
    /// drives the scrollbar and `viewport.y/h` is read each frame to
    /// decide which row range to actually render. Lives across frames
    /// so the scroll position survives toggles.
    lib_scroll_info: dvui.ScrollInfo = .{},
    /// Library list-view dvui.grid: resizable per-column widths (the grid
    /// mutates these on drag) + the grid's own scroll info (VirtualScroller).
    /// Columns: Name, Engine, Rating, Version, Updated.
    lib_col_widths: [7]f32 = .{ 230, 92, 78, 82, 70, 70, 44 },
    lib_grid_scroll: dvui.ScrollInfo = .{},
    /// Kanban view: one independent scroll per status column so each
    /// column scrolls on its own (and to its own height). Indexed by
    /// `@intFromEnum(CompletionStatus)` — the player's progress, 7 variants.
    lib_kanban_scroll: [7]dvui.ScrollInfo = [_]dvui.ScrollInfo{.{}} ** 7,
    /// Last Sync action's status. Reset to `.idle` when entering detail.
    sync_status: SyncStatus = .idle,
    /// Short message describing the last sync (success or error).
    sync_msg: buf_mod.MessageBuf(128) = .{},
    /// In-flight sync workers — up to `MAX_PARALLEL_SYNC` simultaneous.
    /// `null` slot = free. drainSync iterates the whole array; new
    /// syncs go into the first empty slot via `findEmptySyncSlot`.
    /// Mirrors F95Checker's `full_checks_sem`. Each slot is held as
    /// anyopaque so `state.zig` doesn't pull in f95/library/std.Thread.
    active_syncs: [MAX_PARALLEL_SYNC]?*owned.SyncJob = [_]?*owned.SyncJob{null} ** MAX_PARALLEL_SYNC,
    /// Sync-all queue: thread_ids waiting to be synced. drainSync pops
    /// the head and spawns the next job once the current one finishes.
    /// Heap-alloc'd via `lib.alloc`; null when no batch is in flight.
    /// Heap-allocated UpdateCheckJob (defined in `actions/imports.zig`),
    /// held as anyopaque to avoid the cyclic import. `drainUpdateCheck`
    /// reads phase via atomics and frees here on completion.
    pending_update_check: ?*owned.UpdateCheckJob = null,
    /// In-flight batch `/fast` pre-flight (indexer-mode refresh-all).
    /// Walks every queued thread_id in chunks of 10, accumulates
    /// `last_change` per id. `onFastCheckDone` then builds sync_queue
    /// (with `sync_queue_known_last_change` populated in parallel) so
    /// the per-game indexer workers can skip their own `/fast` calls.
    pending_fast_check: ?*owned.FastCheckJob = null,
    /// Heap-allocated RpdlDownloadJob (defined in `actions/downloads.zig`).
    /// Tracks the search → fetch-torrent → enqueue handoff for the
    /// per-game Tier-2 auto-download.
    pending_rpdl_download: ?*owned.RpdlDownloadJob = null,
    /// Heap-allocated DonorDownloadJob (defined in `actions/downloads.zig`).
    /// Mirrors `pending_rpdl_download` for the Tier-1 donor-DDL flow:
    /// POST `/sam/dddl.php` → grab signed URL → enqueue via aria2.
    pending_donor_download: ?*owned.DonorDownloadJob = null,
    /// Tracks which in-flight aria2 jobs originated from a donor-DDL
    /// signed URL so the failure handler knows it can POST for a fresh
    /// URL and re-enqueue (handles signed-URL TTL expiry).
    donor_jobs: ?*owned.DonorJobsMap = null,
    /// Bounds the auto-retry loop on signed-URL expiry — without it a
    /// permanently dead URL would just spin forever.
    donor_retries: ?*owned.DonorRetriesMap = null,
    /// `HashMap(u64 job_id → DonorTickState)` — per-job rolling
    /// telemetry for donor downloads (last log timestamp, last
    /// observed byte count, stall-since timestamp, last seen aria2
    /// errorMessage). Drives the verbose "how is this download
    /// behaving" logging that `drainDonorTelemetry` emits.
    donor_tick_log: ?*owned.DonorTickLog = null,
    /// Heap-allocated RefreshTagsJob (defined in `actions/tags.zig`).
    /// Set while a master-tag-list refresh is in flight.
    pending_tags_refresh: ?*owned.RefreshTagsJob = null,
    /// Active post-install workers — one entry per terminal download
    /// whose archive is currently being SHA-verified + extracted on a
    /// detached thread. Held as anyopaque so `state.zig` doesn't pull
    /// in downloads / installer modules; `actions.postInstallJobsList`
    /// does the lazy ArrayList(*PostInstallJob) init. Drained every
    /// frame by `drainPostInstall`.
    post_install_jobs: ?*owned.PostInstallJobsList = null,
    /// In-flight F95Checker / xLibrary import worker. Held as
    /// anyopaque so state.zig doesn't pull in the import_job module.
    /// One at a time; `actions.startImport*` rejects a second click.
    import_job: ?*import_job_mod.Job = null,
    /// In-flight folder-import file-transfer worker (the "Import ticked
    /// rows" / per-row resolve copy/move). One at a time; commit paths
    /// reject a second start. UI-thread prep + post-transfer
    /// upsertInstall keep SQLite single-threaded; the worker only
    /// shuffles bytes. See `folder_import_job.zig`.
    folder_import_job: ?*folder_import_job_mod.Job = null,
    /// In-flight manual-install workers (user picked an archive off
    /// disk; we hash + extract + write an `installs` row). Same
    /// lifecycle as `post_install_jobs`; held as anyopaque so this
    /// file doesn't pull in `actions/installer.zig`'s `ManualInstallJob`.
    manual_install_jobs: ?*owned.ManualInstallJobsList = null,
    /// Detail-page "Install from file…" expander state: when true,
    /// renderActionRow drops an inline panel under itself with
    /// path / version / name fields. Independent of an in-flight
    /// worker so the panel can stay open while the worker runs.
    manual_install_open: bool = false,
    /// Editable text fields for the manual-install panel. Loaded
    /// from / written back to disk on enqueue.
    manual_install_path_buf: [1024]u8 = [_]u8{0} ** 1024,
    manual_install_version_buf: [64]u8 = [_]u8{0} ** 64,
    manual_install_name_buf: [64]u8 = [_]u8{0} ** 64,
    /// True while the version buffer holds an auto-filled placeholder
    /// (the thread's `latest_version`, pre-filled by the Update flow)
    /// rather than a value the user typed or one derived from the picked
    /// archive. Lets archive detection override the placeholder while
    /// never clobbering a real user edit — fixes "install older archive,
    /// row still shows latest version" (§2.12 #10).
    manual_install_version_autofilled: bool = false,
    /// Accumulated "version changed" entries collected during a
    /// sync-all / updates-check batch. Lazy-init ArrayList of
    /// `SyncRecapEntry` (defined in actions/sync.zig). When the batch
    /// finishes with `sync_recap_show = true`, the main loop renders
    /// the popup over the current screen.
    sync_recap: ?*owned.SyncRecapList = null,
    /// True while the end-of-batch recap popup should be visible.
    /// Cleared by the user (close button) or by starting a new batch.
    sync_recap_show: bool = false,
    /// Master tag list loaded from `<data_root>/tags.txt`. Owned by
    /// `lib.alloc`. Empty until either disk-load or the first
    /// refresh succeeds. Re-allocated wholesale on refresh.
    tags_master: []const []const u8 = &.{},
    /// Unix seconds when the master list was last fetched. 0 = never.
    tags_master_fetched_at: i64 = 0,
    /// Quick-filter text for the sidebar tag checkbox lists.
    tags_filter_buf: [64]u8 = [_]u8{0} ** 64,
    /// Cached library-list filter result. Without this, every frame
    /// (including each frame that wakes for a mouse-motion event)
    /// walks `frame.games` and runs `cardVisible` — three substring
    /// searches per game over potentially long description text. For
    /// any non-trivial library that's >16ms per frame and dvui logs
    /// it as slow. The cache snapshots the filter inputs at the end
    /// of a build; the next frame compares signatures and only
    /// recomputes when something actually changed (filter typed, a
    /// checkbox toggled, a sync added a game).
    lib_filter_cache_indices: ?[]u32 = null,
    /// Wyhash digest of (Filters bytes + query slice + games slice
    /// identity). 0 = not yet computed.
    lib_filter_cache_sig: u64 = 0,
    /// Snapshot cache: per-game latest-install-version map. Rebuilt
    /// only when `Library.install_generation` differs from
    /// `snapshot_install_gen`; otherwise reused across frames.
    /// Without this cache, `guiFrame` runs `latestInstallVersionMap`
    /// (one full-table SELECT + N hydrations) every frame, including
    /// idle frames where nothing has changed. Owned strings + map
    /// allocate via `lib.alloc`; freed by `freeSnapshotCache` on
    /// shutdown and on each cache miss before the rebuild.
    snapshot_install_gen: u64 = 0,
    snapshot_install_versions: ?std.AutoHashMap(u64, []const u8) = null,
    /// When true the library list only shows games where the latest
    /// installed version is newer than the last-played version (or where
    /// the game has been installed but never played). Bound to the
    /// "Unplayed updates" sidebar checkbox.
    filter_unplayed_updates: bool = false,
    /// Library filter: only games whose dev-status changed recently (sets
    /// `status_changed_at`). Pairs with the "status changed" chip.
    filter_status_changed: bool = false,
    /// Library filter: only games with a newer F95 release than what's
    /// installed. Pairs with the "UPDATE" chip.
    filter_update_available: bool = false,
    /// Snapshot cache: `thread_id → *Game` lookup map. Invalidated
    /// when the frame's `games` slice ptr or len changes (a fresh
    /// `listGames` allocation invalidates every cached pointer).
    /// Cheap to rebuild (single linear scan) but spared on idle
    /// frames so library scrolling stays steady. Map storage owned
    /// by `lib.alloc`.
    snapshot_games_ptr: usize = 0,
    snapshot_games_len: usize = 0,
    /// Sort state at the time `snapshot_games_by_thread` was built.
    /// `sortGames` mutates `games[]` IN PLACE (swap contents) without
    /// changing ptr/len, so the cached `*Game` pointers point at the
    /// SAME memory addresses but with NEW game data inside —
    /// `map.get(tid)` then returns the wrong game. We invalidate the
    /// map when sort changes by checking these alongside ptr/len.
    snapshot_games_sort_column: u32 = 0,
    snapshot_games_sort_dir: u32 = 0,
    snapshot_games_by_thread: ?std.AutoHashMap(u64, *library.Game) = null,
    sync_queue: ?[]u64 = null,
    /// Parallel slice to `sync_queue`, same length, same indexing.
    /// Non-null only after a batch `/fast` pre-flight populated each
    /// game's `last_change` timestamp; in scraper mode and for ad-hoc
    /// single-game syncs the slice stays null. Element value 0 ⇒
    /// "indexer returned no entry for this id" → worker will call
    /// `/full` with `ts=0`.
    sync_queue_known_last_change: ?[]i64 = null,
    /// 0-based pop offset into `sync_queue` — the next item to spawn
    /// once the current sync completes. Strictly an array index;
    /// progress display uses `sync_queue_started` instead.
    sync_queue_idx: usize = 0,
    /// 1-based index of the currently-running sync within the batch
    /// (1 = first item of a batch). 0 means no batch is active.
    /// Decoupled from `sync_queue_idx` so the ad-hoc "append while
    /// solo sync runs" case can count the running sync as item 1
    /// without needing it in the pending queue array.
    sync_queue_started: u32 = 0,
    sync_queue_total: u32 = 0,
    /// Name of the game whose SyncJob is currently in flight. Set by
    /// `syncGame` when it spawns the worker and cleared by the
    /// drainSync cleanup helper. Reads as a sentinel-trimmed slice via
    /// `currentSyncName()`.
    active_sync_name: buf_mod.MessageBuf(160) = .{},

    // ----- phase-2 image fetch (screenshots) -----
    /// FIFO of thread_ids whose phase-1 (text+cover) scrape just
    /// committed; a background worker will fetch their screenshots so
    /// the library stays usable while images trickle in. Owned by
    /// `lib.alloc`. Indices `image_queue_head..image_queue_len` are
    /// pending; everything before head has been spawned. When head ==
    /// len the queue is drained and (after `image_active` clears) the
    /// counters reset.
    image_queue: ?[]u64 = null,
    image_queue_head: usize = 0,
    image_queue_len: usize = 0,
    image_queue_cap: usize = 0,
    /// In-flight ImageJobs — up to `MAX_PARALLEL_IMAGE` simultaneous.
    /// `null` slot = free. drainImageQueue iterates all slots; new
    /// jobs go into the first empty slot. Mirrors the parallel sync
    /// slot pool.
    active_images: [MAX_PARALLEL_IMAGE]?*owned.ImageJob = [_]?*owned.ImageJob{null} ** MAX_PARALLEL_IMAGE,
    /// Name of the game whose ImageJob is in flight (for the second
    /// banner row). Sentinel-trimmed.
    image_active_name: buf_mod.MessageBuf(160) = .{},
    /// Cumulative images fetched / planned across the current phase-2
    /// "batch". Resets to 0 when the queue empties AND `image_active`
    /// is null, so the banner row disappears between bursts. `done`
    /// is atomic so the worker thread can bump after each fetch.
    image_done: std.atomic.Value(u32) = .init(0),
    image_total: u32 = 0,
    /// dvui frame timestamp (ns) when image work first became visible
    /// this batch; 0 = no work in flight. The banner image row waits
    /// `IMAGE_BANNER_MIN_NS` past this before rendering, so a burst
    /// that finishes near-instantly (every shot already on disk, or a
    /// lone cache-fast fetch) can't flash a 0→100% bar. Set/cleared by
    /// `components.renderSyncBanner`.
    image_work_since_ns: i128 = 0,
    /// Set by `cancelSync` (or a dedicated cancel button on the banner)
    /// to bail every in-flight + queued image fetch. Worker checks
    /// between each image; drain clears the queue + resets to false
    /// once the active job exits.
    image_cancel: std.atomic.Value(bool) = .init(false),
    /// Persistent "don't enqueue more image work" flag. Set by
    /// `cancelSync` AND `cancelImageQueue`; cleared by any "start"
    /// action (Refresh All / Check for updates / single-game sync).
    /// Distinct from the transient `image_cancel` atomic: that one
    /// drains in-flight workers and auto-resets every drain cycle,
    /// whereas this flag PREVENTS new image jobs from being enqueued
    /// at all — without it, a syncJob that finishes after cancel
    /// would re-fill the queue via `enqueueImageFetch`.
    image_fetch_suspended: bool = false,
    /// Round-robin cache of cover bytes, shared by detail screen and
    /// grid thumbs. Owned by `lib.alloc`; freed on quit and on entry
    /// eviction. Sync invalidates the entry for the synced thread.
    cover_cache: [COVER_CACHE_CAP]?CoverCacheEntry = [_]?CoverCacheEntry{null} ** COVER_CACHE_CAP,
    cover_cache_next: usize = 0,
    /// Pool of in-flight async cover-thumbnail loaders. `coverBytes`
    /// kicks one off on a cache miss and returns the placeholder;
    /// `drainCoverLoads` lands the bytes in `cover_cache` a frame later.
    /// Keeps slow FUSE/NTFS reads off the UI thread.
    cover_load_jobs: [COVER_LOAD_WORKERS]?*owned.CoverLoadJob = [_]?*owned.CoverLoadJob{null} ** COVER_LOAD_WORKERS,
    /// Edit buffer for the Notes tab — re-loaded from the DB whenever
    /// `notes_for_thread` changes. UI flushes back to DB on Save click.
    notes_buf: [4096]u8 = [_]u8{0} ** 4096,
    notes_for_thread: ?u64 = null,

    /// Custom-launch editor (detail facts grid). Re-loaded from the latest
    /// install whenever `launch_cfg_for_thread` changes; Save flushes to DB.
    launch_exec_buf: [256]u8 = [_]u8{0} ** 256,
    launch_args_buf: [256]u8 = [_]u8{0} ** 256,
    launch_cfg_for_thread: u64 = 0,
    launch_cfg_install_id: [36]u8 = [_]u8{0} ** 36,
    launch_cfg_has_install: bool = false,
    /// Paste-area for the bookmark/thread-list importer (8 KiB cap).
    import_buf: [8192]u8 = [_]u8{0} ** 8192,
    /// Imported / skipped counts shown to the user post-import.
    import_msg: buf_mod.MessageBuf(128) = .{},
    /// Folder-scan importer state. The scan walks a directory of
    /// installed games (e.g. `~/Games/`) and parses each subfolder
    /// for a name + version. Held as an opaque pointer to
    /// `*importers.Bundle` (owned by the bundle's arena) so the
    /// downstream UI can iterate `bundle.games`. Freed on a fresh
    /// scan, on screen exit, and on shutdown.
    folder_scan_path_buf: [512]u8 = [_]u8{0} ** 512,
    /// Live scan-in-progress session. Stays non-null while the UI
    /// iterator is still walking the scan root; cleared when
    /// finalized into `folder_scan_bundle` or when the user clears
    /// the screen. See `actions/imports.zig:ScanSession`.
    folder_scan_session: ?*anyopaque = null,
    folder_scan_bundle: ?*anyopaque = null,
    /// Parallel to `folder_scan_bundle`: a `?[*]FolderImportRowState`
    /// (cast through `?*anyopaque` because state.zig can't see the
    /// concrete type without pulling in actions). One slot per row in
    /// the bundle, holding the user's editable name/version + the
    /// typeahead Link cell's resolved state. Allocated by
    /// `actions.doFolderScan` after the bundle is built (so we can
    /// pre-fill from the best library match) and freed by
    /// `actions.freeFolderScan`.
    folder_scan_row_states: ?*anyopaque = null,
    /// Element count for `folder_scan_row_states`; matches
    /// `bundle.games.len` at allocation time. Kept here (rather than
    /// inferred from the bundle) so freeing doesn't need the bundle
    /// to still be live.
    folder_scan_row_count: usize = 0,
    /// Cached library snapshot for the import-preview typeahead. The
    /// preview re-renders at 30+ Hz; calling `lib.listGames()` per
    /// frame caused 1200 ms render times when the user's library
    /// grew to a few-hundred rows. Snapshot once at scan time, reuse
    /// every frame, free with the bundle. Opaque-typed for the same
    /// reason as `folder_scan_row_states` — state.zig can't import
    /// `library`. Treated as `?[*]library.Game` of length
    /// `folder_scan_lib_count`.
    folder_scan_lib_snapshot: ?*anyopaque = null,
    folder_scan_lib_count: usize = 0,
    /// dvui ScrollInfo for the preview-rows scrollArea. Used to drive
    /// viewport culling (only render visible rows + small overscan).
    folder_scan_scroll_info: dvui.ScrollInfo = .{},
    folder_scan_msg: buf_mod.MessageBuf(192) = .{},
    /// Per-bundle transfer mode. Defaults to `.move` (cut+paste) so a
    /// user with limited disk doesn't double their footprint. The UI
    /// exposes a radio next to the scan results.
    /// `link` (the safest, no file mutation) is the default after the
    /// 2026-05-28 data-loss incident. The user can opt into `move` /
    /// `copy` via the mode picker.
    folder_scan_mode: ImportMode = .link,

    // ---- F95Checker review state ----
    //
    // Populated by `doStartF95CheckerReview` when the user clicks
    // "Import from F95Checker…" in Settings. The screen renders the
    // game list straight out of `f95_review_bundle` (read-only).
    // Apply spawns the existing import worker; Cancel frees and
    // returns to Settings. Bundle is `?*importers.Bundle` opaqued so
    // state.zig doesn't pull the importer module.
    f95_review_bundle: ?*anyopaque = null,
    /// Element count for the bundle's games slice (mirrors
    /// `bundle.games.len`; kept here so callers don't have to
    /// re-typecast just to render counts).
    f95_review_game_count: usize = 0,
    /// Number of games in the bundle whose `install_executable_rel`
    /// is non-null — drives the "Installed: N" summary on the screen.
    f95_review_installed_count: usize = 0,
    /// Caller-owned absolute path to the games-base-dir picked at
    /// review start. Re-used when Apply spawns the worker so the
    /// user doesn't get prompted twice. Freed by `freeF95Review`.
    f95_review_games_base_dir: ?[]u8 = null,
    /// Alloc-owned source DB path. Reused on Apply for the same
    /// reason as `f95_review_games_base_dir`.
    f95_review_data_path: ?[]u8 = null,
    f95_review_scroll_info: dvui.ScrollInfo = .{},
    f95_review_msg: buf_mod.MessageBuf(192) = .{},

    /// Bulk-edit affordance for the preview table: name suffix and
    /// version values that the "Apply to selected" button writes
    /// across all ticked rows.
    folder_bulk_name_buf: [128]u8 = [_]u8{0} ** 128,
    folder_bulk_version_buf: [64]u8 = [_]u8{0} ** 64,
    /// Per-row resolution-popup state. `null` = no popup. Otherwise
    /// the index into `bundle.games` whose F95 association the user
    /// is editing right now. The user can paste an F95 URL/id to
    /// resolve the synthetic id, OR confirm "add as custom" to
    /// keep the synthetic id.
    folder_resolve_idx: ?usize = null,
    folder_resolve_url_buf: [256]u8 = [_]u8{0} ** 256,
    /// Set by the importer; runMainLoop checks each iteration and
    /// re-runs `lib.listGames` when true.
    reload_requested: bool = false,
    /// Editable buffer for the Downloads screen's URL paste field.
    dl_url_buf: [512]u8 = [_]u8{0} ** 512,
    /// Editable buffer for the Settings → Downloads aria2-port field.
    /// "0" or empty means "random ephemeral port". Persisted to
    /// `<data_root>/aria2_port`; effective on next launch.
    aria2_port_buf: [8]u8 = [_]u8{0} ** 8,
    /// Last-persisted port (mirrored from disk via RuntimeInfo). Used
    /// to render the "(restart required)" hint when the buffer differs.
    aria2_port_persisted: u16 = 0,
    /// Short message after Save click in the Downloads settings tab.
    aria2_port_msg_buf: [80]u8 = [_]u8{0} ** 80,
    aria2_port_msg_len: usize = 0,
    /// Editable buffer for the Settings → Downloads seed-ratio field.
    /// Float like "5.0". Floor 2.0 enforced on Save.
    aria2_seed_ratio_buf: [16]u8 = [_]u8{0} ** 16,
    /// Detail-page "add label" text entry. Typing an existing name re-uses
    /// it (createLabel is idempotent); a new name creates it.
    label_input_buf: [48]u8 = [_]u8{0} ** 48,
    /// Universal-mods screen add-form: name + selected engine (index into
    /// the screen's engine list).
    universal_mod_name_buf: [80]u8 = [_]u8{0} ** 80,
    universal_mod_engine_idx: usize = 0,
    /// Library label filter — selected label ids (union/OR semantics). Fixed
    /// cap; toggled by the sidebar checkboxes. Empty = no label filtering.
    label_filter: [64]i64 = undefined,
    label_filter_len: usize = 0,
    /// Editable seed-time cap (minutes) text buffer + last-saved value.
    aria2_seed_time_buf: [16]u8 = [_]u8{0} ** 16,
    aria2_seed_time_persisted: u32 = 0,
    aria2_seed_ratio_persisted: f32 = 5.0,
    aria2_seed_ratio_msg_buf: [80]u8 = [_]u8{0} ** 80,
    aria2_seed_ratio_msg_len: usize = 0,
    /// Status from Settings → Library → "Re-detect engines from installs".
    /// Cleared on next click. Sized for the summary line.
    engine_reanalyse_msg_buf: [256]u8 = [_]u8{0} ** 256,
    engine_reanalyse_msg_len: usize = 0,
    /// Browser path buffer (settings → "Browser"). Filled at startup
    /// from `RuntimeInfo.initial_browser_path`; the dropdown copies
    /// detected paths into it. `actions.openInBrowser` reads from here.
    browser_path_buf: [512]u8 = [_]u8{0} ** 512,
    /// "OK" / error message after a browser save click.
    browser_msg: buf_mod.MessageBuf(80) = .{},
    /// F95 login form state.
    f95_user_buf: [128]u8 = [_]u8{0} ** 128,
    f95_pass_buf: [128]u8 = [_]u8{0} ** 128,
    // Cookie sign-in (the 2FA / passkey workaround): the two values the user
    // pastes from their browser. The `xf_user` token can be long, so 512.
    f95_cookie_user_buf: [512]u8 = [_]u8{0} ** 512,
    f95_cookie_session_buf: [512]u8 = [_]u8{0} ** 512,
    /// When true, the F95 login card shows the cookie form instead of the
    /// username/password form.
    f95_login_use_cookie: bool = false,
    /// Two-step (TOTP) challenge in progress: the login card shows a code
    /// field. `two_step_carry` holds the challenge-session cookies (owned by
    /// the gpa) to hand to `submitTwoStep`; freed on submit / cancel / logout.
    two_step_pending: bool = false,
    two_step_carry: ?[]u8 = null,
    two_step_code_buf: [16]u8 = [_]u8{0} ** 16,
    login_status: LoginStatus = .unknown,
    login_msg: buf_mod.MessageBuf(128) = .{},
    /// Donor-tier check result. `null` = not yet probed (either
    /// logged out, or check hasn't completed); `true` = user can
    /// reach the donor DDL endpoint; `false` = F95 says they aren't
    /// a donor. The UI grays out the Download button when this is
    /// `.no` since the donor DDL is f69's default download path.
    is_donor: ?bool = null,
    /// True while the startup donor-status probe is in flight.
    /// Drives a "(checking…)" hint in the UI; the Download button
    /// is enabled optimistically while this is true so first-time
    /// users don't see a grayed button before the check finishes.
    donor_check_in_flight: bool = false,
    /// Launch-diagnostic dialog. Opened when a pre-launch check (or,
    /// future, a runtime stderr-capture worker) finds an actionable
    /// issue with the picked launcher. `summary` is a single-line
    /// reason ("Missing shared libraries: libGL.so.1, ..."); `log` is
    /// the raw evidence we want the user to be able to copy
    /// (multi-line stdout/stderr/ldd output). `fix_id` chooses which
    /// "Fix issue" button — if any — appears alongside OK + Copy.
    /// `thread_id` lets the Fix and Try Anyway buttons re-invoke
    /// `doLaunchGame` for the same game.
    launch_diag_open: bool = false,
    launch_diag_summary_buf: [256]u8 = [_]u8{0} ** 256,
    launch_diag_summary_len: usize = 0,
    launch_diag_log_buf: [8192]u8 = [_]u8{0} ** 8192,
    launch_diag_log_len: usize = 0,
    launch_diag_fix_id: ?LaunchFixId = null,
    launch_diag_thread_id: u64 = 0,
    /// Recipe id to apply when the user clicks the `compat_recipe`
    /// fix button. Empty when fix_id != `compat_recipe`. 64 bytes
    /// covers the longest current recipe slug comfortably.
    launch_diag_compat_recipe_buf: [64]u8 = [_]u8{0} ** 64,
    launch_diag_compat_recipe_len: usize = 0,
    /// install_id (UUID-style 36 char) the compat recipe should be
    /// applied to. Set alongside `launch_diag_compat_recipe_buf`.
    launch_diag_install_id_buf: [36]u8 = [_]u8{0} ** 36,
    launch_diag_install_id_set: bool = false,
    /// Flips true once the user clicks the Fix button and the fix
    /// succeeds. Renders the dialog into "Fix applied — close + try
    /// Launch again" mode. Reset every time the dialog opens fresh.
    launch_diag_fix_applied: bool = false,
    /// User accepted the "Retry with host GPU paths" fix on the
    /// launch diag popup. Subsequent launches of the same install
    /// reuse the override (LD_LIBRARY_PATH prepended with the host
    /// GPU dirs). Session-only.
    launch_force_host_gpu: bool = false,
    /// User dismissed the popup ("Try anyway") for the current launch
    /// attempt — proceed without the fix this once. Reset when the
    /// popup opens with a fresh diagnosis.
    launch_diag_acked: bool = false,

    /// Set once per login cycle when `checkDonorStatus` has run to
    /// completion (success OR transient failure). Without this flag
    /// the `guiFrame` gate would re-fire the probe every frame
    /// `is_donor` stayed null on a transient network error. Reset
    /// to false in `doLogout`.
    donor_check_attempted: bool = false,
    /// In-flight donor-status probe worker job. Non-null while the
    /// HTTP request is on a detached thread. Drained per-frame by
    /// `drainDonorProbe`; final result lands in `is_donor`.
    donor_probe_job: ?*owned.DonorProbeJob = null,
    /// In-flight post-launch watcher. Spawned by `doLaunchGame` after a
    /// successful spawn; polls `waitpid(pid, WNOHANG)` for ~4 s and
    /// surfaces the diagnostic dialog if the child exits inside that
    /// window. Drained per-frame by `drainLaunchWatcher`.
    launch_watch_job: ?*owned.LaunchWatchJob = null,
    /// Startup login popup. Opened by `runMainLoop` when
    /// `login_status` resolves to `.logged_out`; the user dismisses
    /// it via Skip or by completing a login. `login_popup_skipped`
    /// prevents re-opening within the same session.
    login_popup_open: bool = false,
    login_popup_skipped: bool = false,
    /// In-flight bookmarks pull (worker thread). `actions/bookmarks.zig`
    /// defines the actual job struct.
    pending_bookmarks: ?*owned.BookmarksJob = null,
    /// RPDL credentials + status, mirroring the F95 section above.
    /// `rpdl_token` is heap-owned (`lib.alloc`), populated on Login or
    /// from `<config>/f69/rpdl_token` at startup; freed on quit. The
    /// per-game Download action reads this when an `.rpdl` source is
    /// dispatched.
    rpdl_user_buf: [128]u8 = [_]u8{0} ** 128,
    rpdl_pass_buf: [128]u8 = [_]u8{0} ** 128,
    rpdl_status: LoginStatus = .unknown,
    rpdl_msg: buf_mod.MessageBuf(128) = .{},
    rpdl_token: ?[]u8 = null,
    bookmarks_msg: buf_mod.MessageBuf(160) = .{},
    /// Mirrored from the worker's atomic fields each frame so the
    /// progress widget can read plain `u32`s.
    bookmarks_progress_current: u32 = 0,
    bookmarks_progress_total: u32 = 0,
    /// Job ids whose terminal status (.done OR .failed) has been
    /// processed by the post-install / fallback drainer. Lazy-init
    /// on first use.
    post_installed: ?*owned.PostInstalledSet = null,
    /// Per-game F95-thread-id → index into `recipe.sources[]` we're
    /// currently downloading. Bumped on each `.failed` to point at the
    /// next mirror. Lazy-init like `post_installed`.
    download_attempts: ?*owned.AttemptsMap = null,
    /// "Auto-convert new installs" toggle. When true, the post-
    /// install pipeline runs Convert immediately after an extract
    /// finishes (for games that have a recipe with `convert_linux`).
    /// Default off — Convert pulls SDKs and can be slow, so let
    /// the user opt in. Persisted under `<data_root>/auto_convert`.
    auto_convert: bool = false,
    auto_convert_persisted: bool = false,
    /// Auto-apply unfixed compat recipes (and re-apply ones whose
    /// recipe sha has moved on) immediately after a successful
    /// Convert — both manual button clicks AND the post-install
    /// auto-convert path. Default on. The cycle "Convert → Launch
    /// → fail → Fix Compat → Launch" collapses into one Convert
    /// click for ~every game. Compat fixes are reversible, so this
    /// is safe-by-default. Persisted under
    /// `<data_root>/auto_apply_compat`.
    auto_apply_compat: bool = true,
    auto_apply_compat_persisted: bool = true,
    /// Global default for "sandbox on launch". Each game's per-game
    /// `SandboxOverride` (always / never / use_default) wins over this;
    /// only `use_default` consults the value here. Default on — the
    /// safer choice for unknown payloads. Persisted under
    /// `<data_root>/sandbox_default`.
    sandbox_default: bool = true,
    sandbox_default_persisted: bool = true,
    /// Global default for "auto-download updates on sync". Each game's
    /// `AutoUpdateOverride` wins; only `.use_default` consults this.
    /// Default off — auto-downloading in the background = bandwidth +
    /// disk surprises. User opts in via Settings → General. Persisted
    /// under `<data_root>/auto_update_default`.
    auto_update_default: bool = false,
    auto_update_default_persisted: bool = false,
    /// Fire a desktop notification when a sync batch finds updates.
    /// Persisted under `<data_root>/desktop_notifications`.
    desktop_notifications: bool = true,
    desktop_notifications_persisted: bool = true,
    /// Source of game metadata during refresh. `.indexer` (default) hits
    /// `api.f95checker.dev`; `.scraper` parses f95zone.to thread pages
    /// directly. Toggle lives in Settings → Sync. Persisted under
    /// `<data_root>/refresh_backend`. `_persisted` mirrors the on-disk
    /// value so the settings panel can detect a dirty toggle (matches
    /// the pattern used by `auto_update_default`).
    refresh_backend: RefreshBackend = .indexer,
    refresh_backend_persisted: RefreshBackend = .indexer,
    /// Data source for "Check for updates". Persisted under
    /// `<data_root>/update_check_source`; `_persisted` mirrors disk for
    /// dirty detection (same pattern as `refresh_backend`).
    update_check_source: UpdateCheckSource = .builtin,
    update_check_source_persisted: UpdateCheckSource = .builtin,
    /// Runtime cap on simultaneous in-flight `/full` workers (indexer)
    /// / thread scrapes (scraper). Clamped to `[1, MAX_PARALLEL_SYNC]`.
    /// Settings → Sync writes this. Default 4.
    max_parallel_sync: u32 = DEFAULT_PARALLEL,
    max_parallel_sync_persisted: u32 = DEFAULT_PARALLEL,
    /// Runtime cap on simultaneous screenshot ImageJob workers.
    /// Independent pool from `max_parallel_sync`. Clamped to
    /// `[1, MAX_PARALLEL_IMAGE]`. Default 4.
    max_parallel_image: u32 = DEFAULT_PARALLEL,
    max_parallel_image_persisted: u32 = DEFAULT_PARALLEL,
    /// Buffers for the Settings textEntry widgets (mutated live by
    /// dvui). Parsed + clamped on Save.
    max_parallel_sync_buf: [4]u8 = [_]u8{0} ** 4,
    max_parallel_image_buf: [4]u8 = [_]u8{0} ** 4,
    /// Minimum session duration in seconds for `counts_as_played` to
    /// be true. 0 = any successful launch counts; max 1800 (30 min).
    /// Evaluated at session close — past `counts_as_played` values
    /// are not re-derived when this changes.
    min_session_seconds: u32 = 60,
    min_session_seconds_persisted: u32 = 60,
    /// TextEntry buffer for the Settings → min_session_seconds widget.
    min_session_seconds_buf: [8]u8 = [_]u8{0} ** 8,
    /// Per-game F95-thread-id → host PID of the currently-launched
    /// game. Populated by `doLaunchGame`, consumed by `doStopGame` +
    /// the detail screen (Launch ↔ Stop button swap). Pruned each
    /// frame by `drainRunningGames` via `kill(pid, 0)` probe. Lazy-
    /// init.
    running_games: ?*owned.RunningGamesMap = null,
    /// Active toast notifications, newest at index 0. Three separate
    /// `launch_msg` / `convert_msg` / `download_msg` buffers used to
    /// fight for a single status-line slot — now they all push to
    /// this stack and the global `renderToasts` overlay displays them
    /// kind-appropriately. Drains via `actions.drainExpiredToasts`
    /// each frame.
    toasts: [MAX_TOASTS]Toast = [_]Toast{.{}} ** MAX_TOASTS,
    toast_count: usize = 0,
    /// Persistent rect for the toast `floatingWindow`. We overwrite
    /// it every frame to keep the strip anchored at the bottom of the
    /// dvui window — without this, `floatingWindow` would auto-center
    /// on first frame and the toasts would land in the middle of the
    /// detail page (the original complaint).
    toast_rect: dvui.Rect = .{},

    // ============================================================
    //  Modfiles tab + recipe wizard
    // ============================================================

    /// Per-game modfile list cache. Owned by `lib.alloc`. Refilled on
    /// tab open + after Add / Scan / Delete actions. Null when not
    /// loaded; empty slice means "loaded, no entries yet."
    modfile_cache_thread: ?u64 = null,
    /// Heap-allocated list of Modfile records. Lazy-init.
    modfile_cache: ?*owned.ModfileCache = null,

    /// Per-game cache of the parsed game.zon + parsed mod.zon list +
    /// per-mod install/archive flags + computed tab counts shown on
    /// the Mods page. Without this, every render frame (including
    /// mouse-move) re-iterates the recipes dir, re-parses every ZON
    /// file, AND reloads the install tracker per mod — a noticeable
    /// stutter even with a few dozen mods. Invalidated whenever the
    /// modfile cache is dropped (covers every mutating action) plus
    /// on thread/install-selection switch (handled in modsScreen).
    /// Owned by `lib.alloc`; cast in actions/mods.zig.
    mods_page_cache_thread: ?u64 = null,
    /// Buffer holding the install-id this cache was built against.
    /// Stored as a fixed buffer so we can compare without allocating.
    /// Length 0 = "no install selected" (cache built without an
    /// install context — happens when no installs exist for the game).
    mods_page_cache_install_id_buf: [64]u8 = [_]u8{0} ** 64,
    mods_page_cache_install_id_len: usize = 0,
    mods_page_cache: ?*owned.ModsPageCache = null,
    /// Scan in flight — UI greys the Scan button + shows a status row.
    modfile_scan_busy: bool = false,
    /// Last scan summary message ("Added N, skipped M, …") shown after
    /// a Scan run completes.
    modfile_scan_msg: buf_mod.MessageBuf(256) = .{},
    /// Modfile id currently waiting for a confirm-delete press. UI
    /// flips the row's button to "Confirm delete" when set; any other
    /// click clears it. `null` = idle.
    modfile_pending_delete_id_buf: [64]u8 = [_]u8{0} ** 64,
    modfile_pending_delete_id_len: usize = 0,

    /// User-preset id currently armed for delete. Separate from the
    /// modfile buffer so a preset id can't accidentally collide with
    /// a modfile id (different name spaces, but both go through the
    /// same two-click pattern).
    preset_pending_delete_id_buf: [128]u8 = [_]u8{0} ** 128,
    preset_pending_delete_id_len: usize = 0,

    /// Cached `recipe.MergedPresetSet`. Filled lazily on first access
    /// via `getMergedPresets`; invalidated by `invalidatePresetCache`
    /// after any write to `<data_root>/mod-presets/`. `null` = unloaded.
    preset_cache: ?*owned.MergedPresetSet = null,

    /// In-flight `TestInstallJob` for the wizard's Review-step "Test
    /// install (real)" button. `*anyopaque` for the same reason as
    /// `preset_cache` — keeps installer / recipe types out of state.zig.
    /// Drained per frame from `guiFrame`; null when idle.
    test_install_job: ?*owned.TestInstallJob = null,

    /// Recipe wizard — drives the multi-step modal that turns a
    /// modfile into a `.mod.zon`. Null = wizard closed.
    wizard: ?WizardState = null,

    /// File-clash modal state. Set by `doInstallMod` when the
    /// declared-files conflict scan finds collisions; cleared by the
    /// modal on cancel / accept. `*anyopaque` for the same reason as
    /// `modfile_cache` — keeps installer types out of state.zig.
    clash_modal: ?*owned.ClashModalState = null,

    pub fn importMsg(self: *const State) []const u8 {
        return self.import_msg.read();
    }
    pub fn setImportMsg(self: *State, msg: []const u8) void {
        self.import_msg.write(msg);
    }

    pub fn importBufSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.import_buf, 0) orelse self.import_buf.len;
        return self.import_buf[0..end];
    }

    pub fn folderScanPathSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.folder_scan_path_buf, 0) orelse self.folder_scan_path_buf.len;
        return self.folder_scan_path_buf[0..end];
    }
    pub fn setFolderScanMsg(self: *State, msg: []const u8) void {
        self.folder_scan_msg.write(msg);
    }
    pub fn folderScanMsg(self: *const State) []const u8 {
        return self.folder_scan_msg.read();
    }
    pub fn folderResolveUrlSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.folder_resolve_url_buf, 0) orelse self.folder_resolve_url_buf.len;
        return self.folder_resolve_url_buf[0..end];
    }

    pub fn syncMsg(self: *const State) []const u8 {
        return self.sync_msg.read();
    }
    pub fn setSyncMsg(self: *State, msg: []const u8) void {
        self.sync_msg.write(msg);
    }

    pub fn currentSyncName(self: *const State) []const u8 {
        return self.active_sync_name.read();
    }
    pub fn setCurrentSyncName(self: *State, name: []const u8) void {
        self.active_sync_name.write(name);
    }

    /// True if any sync slot is occupied. Replaces the pre-parallel
    /// `state.pending_sync != null` check.
    pub fn anyActiveSync(self: *const State) bool {
        for (self.active_syncs) |s| if (s != null) return true;
        return false;
    }

    /// Number of currently-active sync slots. Used by progress display
    /// and the spawn loop ("how many more can we spawn?").
    pub fn countActiveSyncs(self: *const State) u32 {
        var n: u32 = 0;
        for (self.active_syncs) |s| {
            if (s != null) n += 1;
        }
        return n;
    }

    /// Pointer to the first free slot within the runtime cap, or
    /// `null` if every `[0..max_parallel_sync)` slot is busy. Caller
    /// passes the result to `job_mod.spawnJob` as the `&slot` param.
    pub fn findEmptySyncSlot(self: *State) ?*?*owned.SyncJob {
        const limit = @min(@as(usize, self.max_parallel_sync), self.active_syncs.len);
        for (self.active_syncs[0..limit]) |*slot| if (slot.* == null) return slot;
        return null;
    }

    /// True iff there's room to spawn another sync within the
    /// *runtime* `max_parallel_sync` cap. Slots beyond the cap that
    /// happen to be empty don't count — they only matter for reaping
    /// workers that were spawned before the cap was lowered.
    pub fn hasFreeSyncSlot(self: *const State) bool {
        const limit = @min(@as(usize, self.max_parallel_sync), self.active_syncs.len);
        for (self.active_syncs[0..limit]) |s| if (s == null) return true;
        return false;
    }

    /// First non-null sync slot. Used by the banner widgets that
    /// want to surface a single representative job's step progress
    /// and cancel-state when multiple are in flight.
    pub fn firstActiveSync(self: *const State) ?*owned.SyncJob {
        for (self.active_syncs) |s| if (s) |j| return j;
        return null;
    }

    /// True iff cancel has been flagged on any active sync slot.
    pub fn anySyncCancelling(self: *const State) bool {
        for (self.active_syncs) |s| {
            if (s) |j| if (j.cancel.load(.acquire)) return true;
        }
        return false;
    }

    /// True if any image slot is occupied.
    pub fn anyActiveImage(self: *const State) bool {
        for (self.active_images) |s| if (s != null) return true;
        return false;
    }

    /// True iff there's room to spawn another image job within the
    /// runtime cap. See `hasFreeSyncSlot` for the cap semantics.
    pub fn hasFreeImageSlot(self: *const State) bool {
        const limit = @min(@as(usize, self.max_parallel_image), self.active_images.len);
        for (self.active_images[0..limit]) |s| if (s == null) return true;
        return false;
    }

    /// First-empty image slot pointer within the runtime cap, for
    /// handing to `job_mod.spawnJob`.
    pub fn findEmptyImageSlot(self: *State) ?*?*owned.ImageJob {
        const limit = @min(@as(usize, self.max_parallel_image), self.active_images.len);
        for (self.active_images[0..limit]) |*slot| if (slot.* == null) return slot;
        return null;
    }

    pub fn currentImageName(self: *const State) []const u8 {
        return self.image_active_name.read();
    }
    pub fn setCurrentImageName(self: *State, name: []const u8) void {
        self.image_active_name.write(name);
    }

    pub fn searchSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.search_buf, 0) orelse self.search_buf.len;
        return std.mem.trim(u8, self.search_buf[0..end], " \t");
    }

    pub fn labelFilterActive(self: *const State, id: i64) bool {
        for (self.label_filter[0..self.label_filter_len]) |x| {
            if (x == id) return true;
        }
        return false;
    }

    /// Toggle a label id in the library filter set (OR semantics). No-op
    /// when adding past the fixed cap.
    pub fn toggleLabelFilter(self: *State, id: i64) void {
        for (self.label_filter[0..self.label_filter_len], 0..) |x, i| {
            if (x == id) {
                self.label_filter[i] = self.label_filter[self.label_filter_len - 1];
                self.label_filter_len -= 1;
                return;
            }
        }
        if (self.label_filter_len < self.label_filter.len) {
            self.label_filter[self.label_filter_len] = id;
            self.label_filter_len += 1;
        }
    }

    pub fn dlUrlSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.dl_url_buf, 0) orelse self.dl_url_buf.len;
        return self.dl_url_buf[0..end];
    }

    pub fn loginMsg(self: *const State) []const u8 {
        return self.login_msg.read();
    }
    pub fn setLoginMsg(self: *State, msg: []const u8) void {
        self.login_msg.write(msg);
    }

    pub fn f95UserSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.f95_user_buf, 0) orelse self.f95_user_buf.len;
        return self.f95_user_buf[0..end];
    }
    pub fn f95TwoStepCodeSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.two_step_code_buf, 0) orelse self.two_step_code_buf.len;
        return self.two_step_code_buf[0..end];
    }
    pub fn f95CookieUserSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.f95_cookie_user_buf, 0) orelse self.f95_cookie_user_buf.len;
        return self.f95_cookie_user_buf[0..end];
    }
    pub fn f95CookieSessionSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.f95_cookie_session_buf, 0) orelse self.f95_cookie_session_buf.len;
        return self.f95_cookie_session_buf[0..end];
    }
    pub fn f95PassSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.f95_pass_buf, 0) orelse self.f95_pass_buf.len;
        return self.f95_pass_buf[0..end];
    }

    pub fn rpdlUserSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.rpdl_user_buf, 0) orelse self.rpdl_user_buf.len;
        return self.rpdl_user_buf[0..end];
    }
    pub fn rpdlPassSlice(self: *State) []u8 {
        const end = std.mem.indexOfScalar(u8, &self.rpdl_pass_buf, 0) orelse self.rpdl_pass_buf.len;
        return self.rpdl_pass_buf[0..end];
    }
    pub fn rpdlMsg(self: *const State) []const u8 {
        return self.rpdl_msg.read();
    }
    pub fn setRpdlMsg(self: *State, msg: []const u8) void {
        self.rpdl_msg.write(msg);
    }

    pub fn bookmarksMsg(self: *const State) []const u8 {
        return self.bookmarks_msg.read();
    }
    pub fn setBookmarksMsg(self: *State, msg: []const u8) void {
        self.bookmarks_msg.write(msg);
    }

    /// Push a toast onto the stack. Newest at index 0. When already
    /// at `MAX_TOASTS`, drops the oldest NON-ERR toast (errors stick
    /// until clicked); if every slot is an error, replaces the
    /// oldest error so we never lose newer error signal.
    pub fn pushToast(self: *State, kind: ToastKind, message: []const u8) void {
        var evict: usize = self.toast_count;
        if (evict >= MAX_TOASTS) {
            evict = MAX_TOASTS - 1;
            // Walk from oldest (tail) toward newest, find a non-err
            // we can stomp. Skip-err keeps user-facing errors visible.
            var i: usize = MAX_TOASTS;
            while (i > 0) : (i -= 1) {
                const idx = i - 1;
                if (self.toasts[idx].kind != .err) {
                    evict = idx;
                    break;
                }
            }
        }
        // Shift everything from 0..evict one slot down so the new
        // entry can land at index 0.
        var j: usize = evict;
        while (j > 0) : (j -= 1) {
            self.toasts[j] = self.toasts[j - 1];
        }
        var t: Toast = .{ .kind = kind };
        const n = @min(message.len, t.buf.len);
        @memcpy(t.buf[0..n], message[0..n]);
        t.len = n;
        t.ttl_frames = switch (kind) {
            .info => TOAST_TTL_INFO,
            .success => TOAST_TTL_SUCCESS,
            .warn => TOAST_TTL_WARN,
            .err => TOAST_TTL_ERR,
        };
        self.toasts[0] = t;
        if (self.toast_count < MAX_TOASTS) self.toast_count += 1;
    }

    /// Decrement every active toast's TTL by one. Removes any that
    /// hit zero. Persistent (err) toasts skipped. Called from the
    /// main loop each frame.
    pub fn ageToasts(self: *State) void {
        var i: usize = 0;
        while (i < self.toast_count) {
            const t = &self.toasts[i];
            if (t.ttl_frames == std.math.maxInt(u32)) {
                i += 1;
                continue;
            }
            if (t.ttl_frames > 1) {
                t.ttl_frames -= 1;
                i += 1;
                continue;
            }
            // Expired — drop in place.
            self.dismissToast(i);
            // Don't bump i; dismiss shifted everything up by one.
        }
    }

    // ============================================================
    //  Canonical notification service. New code should use these
    //  four entry points; everything else (pushToast, the
    //  setLaunchMsg/setDownloadMsg/setConvertMsg shims below) is
    //  kept working for legacy callers but routes through here.
    //
    //  All four are tied to the toast renderer at the bottom of the
    //  app window — auto-expire after a kind-specific TTL, click to
    //  dismiss early. Same lifecycle for every screen.
    // ============================================================

    /// Bookkeeping nudge ("Queued sync for 14014"). Shortest TTL.
    pub fn notifyInfo(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(.info, message);
    }
    /// Confirms a user-initiated action that succeeded ("Renamed.").
    pub fn notifyOk(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(.success, message);
    }
    /// Non-fatal hint the user might want to act on. Mid-length TTL.
    pub fn notifyWarn(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(.warn, message);
    }
    /// A failure the user needs to see. Long TTL, auto-clears.
    pub fn notifyErr(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(.err, message);
    }

    // ----- compatibility shims -----
    // The old launch_msg / download_msg / convert_msg pattern lived
    // for ~50 callers. Rather than churn every one we route them
    // through the new toast pipeline. Kind picked by a small sniff
    // ("failed" / "error" → err, otherwise info). Callers can opt
    // into more precise kinds by calling `notifyOk` / `notifyErr` /
    // `notifyWarn` / `notifyInfo` directly.
    pub fn setLaunchMsg(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(sniffKind(message), message);
    }
    pub fn setDownloadMsg(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(sniffKind(message), message);
    }
    pub fn setConvertMsg(self: *State, message: []const u8) void {
        if (message.len == 0) return;
        self.pushToast(sniffKind(message), message);
    }

    /// Remove the toast at `index`, shifting the rest up. UI calls
    /// this when the user clicks the ✕ on an error toast.
    pub fn dismissToast(self: *State, index: usize) void {
        if (index >= self.toast_count) return;
        var i: usize = index;
        while (i + 1 < self.toast_count) : (i += 1) {
            self.toasts[i] = self.toasts[i + 1];
        }
        self.toasts[self.toast_count - 1] = .{};
        self.toast_count -= 1;
    }

    /// Drop every active toast. Used on hard resets (app shutdown).
    /// Use `clearTransientToasts` for normal navigation — that keeps
    /// `.err` so the user doesn't lose a failure they haven't seen.
    pub fn clearToasts(self: *State) void {
        var i: usize = 0;
        while (i < MAX_TOASTS) : (i += 1) self.toasts[i] = .{};
        self.toast_count = 0;
    }

    /// Drop info / success / warn toasts; keep errors. Called on
    /// per-game navigation so transient confirmations don't bleed
    /// between games but real failures stick around until the user
    /// acknowledges them.
    pub fn clearTransientToasts(self: *State) void {
        var write: usize = 0;
        for (self.toasts[0..self.toast_count]) |t| {
            if (t.kind == .err) {
                self.toasts[write] = t;
                write += 1;
            }
        }
        var i: usize = write;
        while (i < MAX_TOASTS) : (i += 1) self.toasts[i] = .{};
        self.toast_count = write;
    }

    pub fn toastSlice(self: *const State) []const Toast {
        return self.toasts[0..self.toast_count];
    }

    pub fn browserPathSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.browser_path_buf, 0) orelse self.browser_path_buf.len;
        return self.browser_path_buf[0..end];
    }
    pub fn setBrowserPath(self: *State, p: []const u8) void {
        // `p` may alias `browser_path_buf` — `saveBrowserPath` calls
        // this with the trimmed slice from the same buffer. `memcpy`
        // forbids overlap; `copyForwards` is the documented escape
        // hatch when dst.ptr <= src.ptr (which is always our case
        // here since the dest is the buffer's head).
        const n = @min(p.len, self.browser_path_buf.len - 1);
        if (n > 0) std.mem.copyForwards(u8, self.browser_path_buf[0..n], p[0..n]);
        // Zero out everything past the new content so `browserPathSlice`
        // returns the right length on next read.
        @memset(self.browser_path_buf[n..], 0);
    }

    /// Trimmed slice of the manual-install path buffer up to the
    /// first NUL or end-of-buffer. Buffer holds a NUL-terminated
    /// string that the textEntry widget edits in place.
    pub fn manualInstallPathSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.manual_install_path_buf, 0) orelse self.manual_install_path_buf.len;
        return self.manual_install_path_buf[0..end];
    }

    pub fn manualInstallVersionSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.manual_install_version_buf, 0) orelse self.manual_install_version_buf.len;
        return self.manual_install_version_buf[0..end];
    }

    pub fn manualInstallNameSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.manual_install_name_buf, 0) orelse self.manual_install_name_buf.len;
        return self.manual_install_name_buf[0..end];
    }

    /// Reset the manual-install panel's text fields (path / version /
    /// name) back to empty. Called after a successful enqueue so the
    /// user can immediately install a second archive without having
    /// to clear three fields by hand.
    pub fn resetManualInstallFields(self: *State) void {
        @memset(&self.manual_install_path_buf, 0);
        @memset(&self.manual_install_version_buf, 0);
        @memset(&self.manual_install_name_buf, 0);
        self.manual_install_version_autofilled = false;
    }

    pub fn browserMsg(self: *const State) []const u8 {
        return self.browser_msg.read();
    }
    pub fn setBrowserMsg(self: *State, msg: []const u8) void {
        self.browser_msg.write(msg);
    }

    /// Reset every UI field scoped to a single detail page. Called
    /// when the user navigates from one game's detail to another's so
    /// the new page opens with the default tab, default scroll, no
    /// stale popups, and no leftover status lines from the previous
    /// game. `carousel_*` and `notes_*` have their own per-thread
    /// guards and reset themselves; everything else lives here.
    pub fn resetDetailViewState(self: *State) void {
        self.detail_tab = .overview;
        self.detail_scroll = .{};
        self.confirm_delete = false;
        self.convert_help_open = false;
        self.image_popup_open = false;
        // Drop info / success / warn toasts so stale per-game
        // confirmations don't bleed across navigation. Errors stick
        // — the user hasn't acknowledged them yet, and silently
        // dropping them would mask real failures.
        self.clearTransientToasts();
        self.detail_picker_install_id = null;
        self.mods_page_install_id = null;
        self.mods_tab = .installed;
        self.manage_action = .none;
        self.manage_install_id = null;
        @memset(&self.manage_rename_buf, 0);
    }

    pub fn manageRenameSlice(self: *const State) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.manage_rename_buf, 0) orelse self.manage_rename_buf.len;
        return self.manage_rename_buf[0..end];
    }

    /// Override color (0xRRGGBB) for `tag`, or null for the auto hue.
    pub fn tagColorFor(self: *const State, tag: []const u8) ?u32 {
        const m = self.tag_colors orelse return null;
        return m.get(tag);
    }

    /// Active arming target for the preset-delete two-click. Empty
    /// slice = nothing armed.
    pub fn presetPendingDeleteSlice(self: *const State) []const u8 {
        return self.preset_pending_delete_id_buf[0..self.preset_pending_delete_id_len];
    }

    pub fn armPresetDelete(self: *State, preset_id: []const u8) void {
        @memset(&self.preset_pending_delete_id_buf, 0);
        const n = @min(preset_id.len, self.preset_pending_delete_id_buf.len);
        @memcpy(self.preset_pending_delete_id_buf[0..n], preset_id[0..n]);
        self.preset_pending_delete_id_len = n;
    }

    pub fn clearPresetDeleteArm(self: *State) void {
        @memset(&self.preset_pending_delete_id_buf, 0);
        self.preset_pending_delete_id_len = 0;
    }
};

/// Best-effort kind detection for the compat-shim setters. Looks for
/// "fail" / "error" / "denied" / "not found" / "missing" / "no recipe"
/// — sticks the toast in the persistent `err` bucket so the user
/// can't miss the failure. Anything else → `info`. Callers that know
/// better should call `pushToast(.warn|.success, ...)` directly.
fn sniffKind(message: []const u8) ToastKind {
    var lower_buf: [128]u8 = undefined;
    const n = @min(message.len, lower_buf.len);
    for (message[0..n], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lower = lower_buf[0..n];
    const err_markers = [_][]const u8{ "fail", "error", "couldn't", "denied", "not found", "missing", "no recipe", "no install" };
    for (err_markers) |m| {
        if (std.mem.indexOf(u8, lower, m) != null) return .err;
    }
    return .info;
}

test "Filters.empty" {
    const f1 = Filters{};
    try std.testing.expect(f1.empty());
    const f2 = Filters{ .min_rating = 4.0 };
    try std.testing.expect(!f2.empty());
}

test "Filters.match rating gate" {
    const g = library.Game{ .f95_thread_id = 1, .name = "x", .rating = 3.0 };
    try std.testing.expect((Filters{}).match(&g));
    try std.testing.expect(!(Filters{ .min_rating = 4.0 }).match(&g));
    try std.testing.expect((Filters{ .min_rating = 2.0 }).match(&g));
}
