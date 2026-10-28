// Pure entity types — no IO, no allocator-bound state. Thread id (the F95
// thread's numeric id) is the natural key for both Game and Mod since
// every game/mod is 1:1 with an F95 thread. Only Install carries a
// synthetic UUID since (game_thread_id, version) would be awkward to FK
// from `mod_installs`.

const std = @import("std");

/// User-defined label. Distinct from F95 `tags` (scraped) — these are the
/// user's own organizational buckets ("favorites", "to play", "finished
/// 100%"), assigned to games via the `game_labels` join table and usable as
/// library filters. `color` is an optional hex string ("#1FA39A") for the chip.
pub const UserLabel = struct {
    id: i64,
    name: []const u8,
    color: ?[]const u8 = null,
};

pub const CompletionStatus = enum {
    not_started,
    in_queue,
    in_progress,
    completed,
    replaying,
    abandoned,
    waiting_for_update,
};

/// Whether the game has censored content. Sourced from the OP's
/// "Censored:" line. F95 uses "Yes" / "No" / "Partial" in practice;
/// anything else maps to `.unknown`.
pub const CensoredState = enum {
    unknown,
    no,
    yes,
    partial,

    pub fn fromStr(s: []const u8) CensoredState {
        return std.meta.stringToEnum(CensoredState, s) orelse .unknown;
    }

    /// Parse a "Censored:" value as F95 publishes it (case-insensitive,
    /// permissive on whitespace + extra prose).
    pub fn fromText(raw: []const u8) CensoredState {
        const trimmed = std.mem.trim(u8, raw, " \t\n\r");
        if (trimmed.len == 0) return .unknown;
        // Normalize: lowercase the first word.
        var buf: [16]u8 = undefined;
        var n: usize = 0;
        for (trimmed) |c| {
            if (c == ' ' or c == '\t' or c == ',' or c == '/' or c == '-' or c == '.') break;
            if (n >= buf.len) break;
            buf[n] = std.ascii.toLower(c);
            n += 1;
        }
        const word = buf[0..n];
        if (std.mem.eql(u8, word, "no")) return .no;
        if (std.mem.eql(u8, word, "yes")) return .yes;
        if (std.mem.eql(u8, word, "partial")) return .partial;
        return .unknown;
    }
};

test "CensoredState.fromText" {
    const testing = std.testing;
    try testing.expectEqual(CensoredState.no, CensoredState.fromText("No"));
    try testing.expectEqual(CensoredState.yes, CensoredState.fromText("Yes"));
    try testing.expectEqual(CensoredState.yes, CensoredState.fromText("Yes (mosaic)"));
    try testing.expectEqual(CensoredState.partial, CensoredState.fromText("Partial"));
    try testing.expectEqual(CensoredState.unknown, CensoredState.fromText("optional"));
    try testing.expectEqual(CensoredState.unknown, CensoredState.fromText(""));
}

/// Game's development state as scraped from the F95 thread title.
/// Distinct from `CompletionStatus` — that one tracks the *user's*
/// progress through the game (have I played it?), while this one
/// reflects the *developer's* state (is the game shipped/dead/etc).
///
/// Source tokens from F95 title brackets / dash-prefix:
///   "Completed" / "Complete" / "Final"   → .completed
///   "Abandoned"                          → .abandoned
///   "On Hold" / "Onhold" / "On-hold"     → .on_hold
///   "Ongoing"                            → .in_progress
///   (no token)                           → .in_progress
pub const DevStatus = enum {
    unknown,
    in_progress,
    on_hold,
    completed,
    abandoned,
    /// Thread is gone from F95 (HTTP 404 on the last sync attempt).
    /// We keep the existing library row so the user's notes / rating
    /// / installs don't disappear, but flag it so the UI can label
    /// it clearly and sync workers can skip re-fetching the OP.
    orphaned,

    pub fn fromStr(s: []const u8) DevStatus {
        return std.meta.stringToEnum(DevStatus, s) orelse .unknown;
    }

    /// Map a raw status token (case-insensitive, dashes ignored) from
    /// an F95 title to a `DevStatus`. Unknown tokens stay `.unknown`
    /// so the caller can preserve the old value rather than clobber
    /// with a wrong guess.
    pub fn fromBracket(token: []const u8) DevStatus {
        var buf: [16]u8 = undefined;
        var n: usize = 0;
        for (token) |c| {
            if ((std.ascii.isAlphanumeric(c)) and n < buf.len) {
                buf[n] = std.ascii.toLower(c);
                n += 1;
            }
        }
        const norm = buf[0..n];
        if (std.mem.eql(u8, norm, "completed") or
            std.mem.eql(u8, norm, "complete") or
            std.mem.eql(u8, norm, "final")) return .completed;
        if (std.mem.eql(u8, norm, "abandoned")) return .abandoned;
        if (std.mem.eql(u8, norm, "onhold")) return .on_hold;
        if (std.mem.eql(u8, norm, "ongoing")) return .in_progress;
        return .unknown;
    }
};

test "DevStatus.fromBracket" {
    const testing = std.testing;
    try testing.expectEqual(DevStatus.completed, DevStatus.fromBracket("Completed"));
    try testing.expectEqual(DevStatus.completed, DevStatus.fromBracket("Final"));
    try testing.expectEqual(DevStatus.abandoned, DevStatus.fromBracket("Abandoned"));
    try testing.expectEqual(DevStatus.on_hold, DevStatus.fromBracket("On Hold"));
    try testing.expectEqual(DevStatus.on_hold, DevStatus.fromBracket("On-hold"));
    try testing.expectEqual(DevStatus.on_hold, DevStatus.fromBracket("Onhold"));
    try testing.expectEqual(DevStatus.in_progress, DevStatus.fromBracket("Ongoing"));
    try testing.expectEqual(DevStatus.unknown, DevStatus.fromBracket("Demo"));
}

/// Canonical Engine lives in `util_domain` so every context shares
/// the same variants (and the same `fromStr`/`fromBracket` parsers).
pub const Engine = @import("util_domain").Engine;

/// Per-game tri-state for the sandbox setting; overrides AppConfig.sandbox_default.
pub const SandboxOverride = enum { use_default, always, never };

/// Per-game tri-state for the auto-update behaviour. `.use_default`
/// defers to `state.auto_update_default`; `.always` / `.never`
/// override regardless of the global toggle. Same shape as
/// `SandboxOverride` on purpose — the resolver in actions/launch.zig
/// (`shouldAutoUpdate`) parallels `shouldSandbox`.
pub const AutoUpdateOverride = enum { use_default, always, never };

/// Persisted per-game backup policy for mod installs. Mirrors
/// `installer.BackupMode` — the library layer can't import installer
/// without a layer inversion, so this enum is a small parallel. UI
/// code translates one to the other when handing a job to the queue.
pub const BackupModePref = enum { none, copy };

/// Save data location declared in recipe — used by the "Open saves folder"
/// UI button, backup/migrate-save flows, and pre-create on install.
/// Engine-specific defaults are filled in by recipe/derive.zig if omitted.
pub const SavesPaths = struct {
    /// Linux path. Env vars expanded: $HOME, $XDG_DATA_HOME.
    /// Resolved under sandbox HOME if game is sandboxed.
    linux: ?[]const u8 = null,
    /// Windows path. Expands %APPDATA%, %LOCALAPPDATA%, %USERPROFILE%.
    windows: ?[]const u8 = null,
};

pub const Game = struct {
    /// F95 thread id — primary key.
    f95_thread_id: u64,

    name: []const u8,
    developer: ?[]const u8 = null,
    cover_url: ?[]const u8 = null,
    description_md: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    rating: ?f32 = null,
    vote_count: ?u32 = null,
    user_rating: ?f32 = null,
    completion_status: CompletionStatus = .not_started,
    engine: Engine = .unknown,
    latest_version: ?[]const u8 = null,
    /// FK to Install.id — null if no installation yet.
    default_install_id: ?[36]u8 = null,
    sandbox: SandboxOverride = .use_default,
    /// Auto-update behaviour for this game. `.use_default` defers to
    /// `state.auto_update_default`; `.always`/`.never` override.
    auto_update: AutoUpdateOverride = .use_default,
    /// Per-game uninstall safety policy for mod installs. `.none` is
    /// today's behaviour (no backup; mods that overwrite vanilla
    /// files can't be cleanly uninstalled). `.copy` mirrors originals
    /// to `<install>/.f69-backups/<mod>/` before each overwrite so
    /// uninstall restores them. Stored on the game (not globally) so
    /// 15GB overlay-style games can stay `.none` while text-heavy
    /// games stay `.copy` — user picks once per game via the Mods
    /// page dropdown.
    mod_backup_mode: BackupModePref = .none,
    last_played_at: ?i64 = null,
    total_playtime_s: u64 = 0,
    last_scraped_at: ?i64 = null,
    created_at: i64 = 0,
    /// Free-form user note. Owned by `library.alloc` after `listGames`;
    /// caller-borrowed for `upsertGame`. Edited via the detail Notes tab.
    notes: ?[]const u8 = null,
    /// Screenshot URLs from the F95 thread OP. The sync worker fetches
    /// each one to disk under `<covers_dir>/<thread_id>.s<n>` so the
    /// carousel can render them. URLs persist across runs as JSON in
    /// the `screenshots_json` column.
    screenshots: []const []const u8 = &.{},
    /// Changelog text scraped from the OP — typically the "Changelog:"
    /// / "Updates:" spoiler.
    changelog_md: ?[]const u8 = null,
    /// Concatenated user reviews / quoted feedback pulled from the
    /// thread. Stored as a single blob with `---` between entries.
    reviews_md: ?[]const u8 = null,
    /// Download links parsed from the OP. Each line is encoded as
    /// `<host>\t<url>\t<label>` (host enum string, tab-delimited).
    /// Kept for back-compat / search indexing; the visible Downloads
    /// tab now renders `downloads_md` instead so the OP's heading +
    /// bullet + spoiler structure stays intact.
    download_links: []const []const u8 = &.{},
    /// Marked-up "Downloads" section from the OP — same vocabulary as
    /// `changelog_md`. Rendered as the Downloads tab.
    downloads_md: ?[]const u8 = null,
    /// Developer's release state — completed / abandoned / on hold /
    /// in progress. Pulled from the F95 thread title via
    /// `DevStatus.fromBracket`. Independent of `completion_status`
    /// (which is the user's play state).
    dev_status: DevStatus = .unknown,
    /// Unix seconds — when F95's OP advertises the thread was last
    /// updated (parsed from the "Thread Updated:" / "Updated:" /
    /// "Game Updated:" line in the OP body). Null when the OP didn't
    /// publish one we could parse.
    last_updated_at: ?i64 = null,
    /// Verbatim "Key: Value" lines scraped from the OP — Thread
    /// Updated / Release Date / Developer / Censored / Version / OS /
    /// Language / etc. Stored as one preformatted blob and rendered
    /// as-is on the detail page so the user sees the same format F95
    /// publishes.
    thread_info_md: ?[]const u8 = null,
    /// Parsed value of the OP's "Censored:" line — used by the
    /// sidebar filter. The display text lives in `thread_info_md`
    /// (verbatim); this column lets us filter without re-parsing.
    censored: CensoredState = .unknown,
    /// F95Indexer last-change timestamp from the `/fast` endpoint.
    /// Null = never fetched via the indexer (or scraper-only history).
    /// The indexer refresh path only calls `/full` when the server-side
    /// `last_change` is greater than this — matches F95Checker's
    /// optimization. Scraper path leaves this untouched.
    last_indexer_change: ?i64 = null,
    /// f95_indexer mapping version at the time of this row's last
    /// successful /full. Mirrors F95Checker's `last_check_version`.
    /// When `f95_indexer.PARSER_VERSION` is bumped (new fields parsed
    /// out of the indexer response), the refresh path force-/full's
    /// every row whose stored version is below the current value, so
    /// existing rows pick up the new mapping without needing a manual
    /// "force full refresh" click. Null = never indexer-synced (or
    /// synced before this column existed) → also forces /full.
    last_indexer_parser_version: ?u32 = null,
    /// Highest version string for which a session with
    /// `counts_as_played = 1` was recorded. Drives the "NEW" chip.
    /// Compared with `util_version.compare`. NULL means the user
    /// has never logged a played session against this game.
    last_played_version: ?[]const u8 = null,
    /// User-pinned version. When set, the game is held here: auto-update is
    /// suppressed (a newer release shows as available but isn't downloaded
    /// automatically). Cleared by a manual update. NULL = track latest.
    pinned_version: ?[]const u8 = null,
    /// Unix seconds of the last time `dev_status` changed during a sync
    /// (e.g. Ongoing → Completed/Abandoned). Drives the "status changed"
    /// chip + filter. NULL = never observed changing.
    status_changed_at: ?i64 = null,

    pub fn weightedRating(self: *const Game, library_mean: f32, prior_weight: f32) ?f32 {
        const r = self.rating orelse return null;
        const v: f32 = @floatFromInt(self.vote_count orelse 0);
        return (v / (v + prior_weight)) * r + (prior_weight / (v + prior_weight)) * library_mean;
    }
};

/// Where an install came from. Drives the small badge in the install
/// picker (recipe / manual / rpdl) and lets the diagnostics page tell
/// the user *how* a given entry landed in their library.
pub const InstallSource = enum { recipe, manual, rpdl, imported };

pub const Install = struct {
    id: [36]u8,
    game_thread_id: u64,
    version: []const u8,
    install_path: []const u8,
    executable: ?[]const u8 = null,
    launch_args: ?[]const u8 = null,
    recipe_id: []const u8,
    installed_at: i64 = 0,
    /// Optional user-supplied label distinct from `version`. Lets the
    /// user disambiguate two installs of the same release ("modded",
    /// "from itch", …). Picker labels join name + version when set.
    name: ?[]const u8 = null,
    /// Provenance. Default `.recipe` covers the pre-existing rows
    /// from the automated download flow. Manual installs set
    /// `.manual`; RPDL torrents could be flipped to `.rpdl` later
    /// for diagnostics.
    source: InstallSource = .recipe,
    /// SHA-256 of the source archive, as 64 lowercase hex chars.
    /// Populated by the manual-install worker (and, later, by the
    /// automated download worker when we wire it up). Null for
    /// already-extracted rows + the historical fleet.
    archive_sha256: ?[64]u8 = null,

    /// `<install_path>/base/` — extracted base game.
    pub fn baseDir(self: *const Install, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/base", .{self.install_path});
    }

    /// `<install_path>/mods/` — per-mod extracted dirs.
    pub fn modsDir(self: *const Install, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/mods", .{self.install_path});
    }

    /// `<install_path>/overlay/` — merged view (overlayfs or flat-copy).
    pub fn overlayDir(self: *const Install, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/overlay", .{self.install_path});
    }

    /// `<install_path>/.install.log` — file tracker for clean uninstall.
    pub fn installLogPath(self: *const Install, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/.install.log", .{self.install_path});
    }
};

pub const Mod = struct {
    /// F95 thread id of the mod's own thread — primary key.
    f95_thread_id: u64,
    game_thread_id: u64,
    name: []const u8,
    author: ?[]const u8 = null,
    latest_version: ?[]const u8 = null,
    created_at: i64 = 0,
};

pub const ModInstall = struct {
    install_id: [36]u8,
    mod_thread_id: u64,
    mod_version: []const u8,
    /// Position in load order (lower = applied first). Topo-sorted from
    /// recipes' load_after / load_before by the resolver.
    load_index: u32,
    applied_at: i64 = 0,
};

/// An engine-wide ("universal") mod: a stored modfile applied across every
/// game of `engine`, except games that opted out (see
/// `game_universal_mod_disabled`). The apply itself reuses the per-game mod
/// pipeline; this row is the registry entry.
pub const UniversalMod = struct {
    id: i64,
    name: []const u8,
    /// `@tagName(Engine)` — which engine's games this applies to.
    engine: Engine,
    /// Stored modfile (archive) path the apply pipeline consumes.
    modfile_path: []const u8,
    created_at: i64 = 0,
    /// User toggle: a disabled universal mod is skipped by Apply and shown
    /// muted in the list. Default on.
    enabled: bool = true,
};

/// One catalogued download link for a game, as scraped (see
/// `f95/dl_scan.zig`). Raw fields only — what a link *is* gets worked out
/// at read time by `f95/dl_classify.zig`.
pub const DownloadSource = struct {
    href: []const u8,
    text: []const u8,
    lead: []const u8,
    /// Link-free lines above the link, '\n'-joined.
    ctx: []const u8,
    spoiler: u8 = 0,
    line: u32 = 0,
};

pub const PlaySession = struct {
    id: i64,
    game_thread_id: u64,
    install_id: ?[36]u8 = null,
    version: []const u8,
    started_at: i64,
    ended_at: ?i64 = null,
    duration_s: ?i64 = null,
    counts_as_played: bool = false,

    /// Best-effort duration in seconds. Prefers the stored
    /// `duration_s` (set on close); returns 0 for still-open or
    /// abandoned rows so journal aggregates don't NaN.
    pub fn durationSeconds(self: PlaySession) i64 {
        return self.duration_s orelse 0;
    }
};

test "PlaySession: durationSeconds derives from started_at/ended_at" {
    const s: PlaySession = .{
        .id = 1,
        .game_thread_id = 1,
        .version = "1.0",
        .started_at = 100,
        .ended_at = 250,
        .duration_s = 150,
    };
    try std.testing.expectEqual(@as(i64, 150), s.durationSeconds());

    const open: PlaySession = .{
        .id = 2,
        .game_thread_id = 1,
        .version = "1.0",
        .started_at = 100,
        .ended_at = null,
        .duration_s = null,
    };
    try std.testing.expectEqual(@as(i64, 0), open.durationSeconds());
}

test "Engine.fromBracket variants" {
    try std.testing.expectEqual(Engine.renpy, Engine.fromBracket("Ren'Py"));
    try std.testing.expectEqual(Engine.renpy, Engine.fromBracket("RenPy"));
    try std.testing.expectEqual(Engine.renpy, Engine.fromBracket("renpy"));
    try std.testing.expectEqual(Engine.rpgm_mv, Engine.fromBracket("RPGM MV"));
    try std.testing.expectEqual(Engine.rpgm_mz, Engine.fromBracket("RPG Maker MZ"));
    try std.testing.expectEqual(Engine.unity, Engine.fromBracket("Unity"));
    try std.testing.expectEqual(Engine.unknown, Engine.fromBracket("Voyeur"));
}

test "weightedRating bayesian basics" {
    const g = Game{
        .f95_thread_id = 1,
        .name = "Test",
        .rating = 5.0,
        .vote_count = 1,
    };
    const w = g.weightedRating(3.5, 30).?;
    try std.testing.expectApproxEqAbs(@as(f32, 3.548), w, 0.01);
}

test "Install path methods" {
    const i = Install{
        .id = @splat('a'),
        .game_thread_id = 12345,
        .version = "v1",
        .install_path = "/games/foo/v1",
        .recipe_id = "r",
    };
    const got = try i.baseDir(std.testing.allocator);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/games/foo/v1/base", got);
}
