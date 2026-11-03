// Mods page state + helpers:
//   - `doRegisterModArchive` / `findRegisteredModArchive`
//   - modfile cache + mods-page cache + their teardowns
//   - per-game modfile listing, refresh, scan, delete
//   - presets (`getMergedPresets`, `doSaveModRecipeAsPreset`,
//     `doSetModfilePreset`, user-preset delete, cache invalidation,
//     `detectAndPinPreset`)
//   - resolve helpers used by mods page + launch + installer
//     (`resolveModsPageInstall`, `resolveConvertSpec`,
//     `resolveGameRoot`, `modTrackerLayout`, `archiveTopDirs`,
//     `installTopDirs`, `simulateCurrentPlan`, `modfileArchivePath`).
//   - recipe wizard (`openWizardForModfile`, `wizardAddBlock`,
//     `wizardRemoveBlock`, `wizardSave`, `closeWizard` + internals).
//   - mod-recipe delete (armed + unarmed) + `clearPendingDelete`.
//   - `openSettingsTab` — shared screen-router helper.

const std = @import("std");
const log = std.log.scoped(.ui_actions);
const library = @import("library");
const recipe = @import("recipe");
const convert_mod = @import("convert");
const resolver = @import("resolver");
const installer_mod = @import("installer");
const types = @import("../types.zig");
const state_mod = @import("../state.zig");
const owned_types = @import("../owned.zig");
const common = @import("common.zig");
const threads_act = @import("threads.zig");
const launch_act = @import("launch.zig");
const reanalyse_job = @import("../threads/jobs/reanalyse.zig");

const Frame = types.Frame;
const State = types.State;

pub const ModfileCache = owned_types.ModfileCache;
pub const ModsTabCounts = owned_types.ModsTabCounts;
pub const ModsPageCache = owned_types.ModsPageCache;

/// id in one shot — preserves the click-to-install UX while the
/// Modfiles tab is being built out.
pub fn doRegisterModArchive(
    frame: *Frame,
    parent_game: *const library.Game,
    mod_recipe: *const recipe.ModRecipe,
    src_path: []const u8,
) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;

    const res = ma.addForGame(
        alloc,
        frame.io,
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
        src_path,
    ) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Add modfile failed: {s}", .{@errorName(e)}) catch "Add modfile failed";
        state.setDownloadMsg(msg);
        return;
    };

    switch (res) {
        .added => |m| {
            defer ma.freeModfile(alloc, m);
            ma.linkRecipe(
                alloc,
                frame.io,
                frame.info.mod_archives_dir,
                parent_game.f95_thread_id,
                m.id,
                mod_recipe.id,
            ) catch |e| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Link failed: {s}", .{@errorName(e)}) catch "Link failed";
                state.setDownloadMsg(msg);
                return;
            };
            // Even when the recipe is being authored alongside the
            // archive (wizard finishing in the same flow), record the
            // detected preset id so a later "what pattern is this?"
            // query — or a future Save-as-preset round-trip — has the
            // attribution. Failures are best-effort.
            const dest_path = ma.diskPathOf(alloc, frame.info.mod_archives_dir, parent_game.f95_thread_id, m) catch null;
            defer if (dest_path) |p| alloc.free(p);
            if (dest_path) |path| {
                detectAndPinPreset(frame, parent_game, m.id, path);
            }

            var ok_buf: [256]u8 = undefined;
            const ok_msg = std.fmt.bufPrint(&ok_buf, "Mod archive stored — ready to install `{s}`.", .{mod_recipe.name}) catch "Mod archive stored.";
            state.setDownloadMsg(ok_msg);
        },
        .duplicate => |d| {
            defer ma.freeModfile(alloc, d.existing);
            // Same content already managed — append-link to this recipe.
            // `linkRecipe` is idempotent so the existing links survive.
            if (d.game_thread_id == parent_game.f95_thread_id) {
                ma.linkRecipe(
                    alloc,
                    frame.io,
                    frame.info.mod_archives_dir,
                    parent_game.f95_thread_id,
                    d.existing.id,
                    mod_recipe.id,
                ) catch {};
                state.setDownloadMsg("Already managed - linked to this recipe.");
            } else {
                var buf: [320]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Already managed as `{s}` (game {d}).", .{ d.existing.filename, d.game_thread_id }) catch "Already managed.";
                state.setDownloadMsg(msg);
            }
        },
    }
}

/// Locate the disk path of the modfile linked to this mod recipe.
/// Returns allocator-owned path or null.
pub fn findRegisteredModArchive(frame: *Frame, parent_game: *const library.Game, mod_recipe: *const recipe.ModRecipe) ?[]u8 {
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;
    const found = ma.findByRecipe(
        alloc,
        frame.io,
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
        mod_recipe.id,
    ) catch return null;
    if (found == null) return null;
    defer ma.freeModfile(alloc, found.?);
    return ma.diskPathOf(alloc, frame.info.mod_archives_dir, parent_game.f95_thread_id, found.?) catch null;
}

// ============================================================
//  Modfiles tab — per-game modfile store management
// ============================================================
//
// `state.modfile_cache` is a typed pointer to a heap-allocated

// `owned.ModfileCache` (see `src/ui/owned.zig`) that owns the loaded
// list. The struct lives in `owned.zig` so `state.zig` can hold a
// concrete `?*ModfileCache` instead of `?*anyopaque`.

/// Free + null the cached modfile list, if any.
pub fn dropModfileCache(frame: *Frame) void {
    freeModfileCacheState(frame.state, frame.lib.alloc);
}

/// State-only variant used by the shutdown teardown path (where no
/// Frame is constructed). Idempotent.
pub fn freeModfileCacheState(state: *State, alloc: std.mem.Allocator) void {
    if (state.modfile_cache) |cache| {
        installer_mod.mod_archives.freeModfileList(alloc, cache.mods);
        alloc.destroy(cache);
        state.modfile_cache = null;
        state.modfile_cache_thread = null;
    }
    // The mods-page cache piggybacks on the modfile cache's lifetime:
    // every mutating action that calls `refreshModfileCache` /
    // `dropModfileCache` already invalidates this too. Free here so
    // shutdown paths don't leak the parsed-recipe arenas.
    freeModsPageCacheState(state, alloc);
}

// ----- Mods page render-data cache -----
// Built once per (thread_id, install_id) and reused across frames
// until a mutating action drops it. Lets the mouse-move-driven
// rerenders skip the full recipes-dir scan + per-mod tracker load.

// `ModsTabCounts` + `ModsPageCache` live in `owned.zig` so
// `state.mods_page_cache` can hold a typed pointer. Aliased here so
// existing call sites keep their short type names.

pub fn dropModsPageCache(frame: *Frame) void {
    freeModsPageCacheState(frame.state, frame.lib.alloc);
}

pub fn freeModsPageCacheState(state: *State, alloc: std.mem.Allocator) void {
    if (state.mods_page_cache) |c| {
        // Recipe arenas + duped strings.
        if (c.game_parsed) |*gp| gp.deinit();
        for (c.mods) |*pm| pm.deinit();
        if (c.mods.len > 0) alloc.free(c.mods);
        // Parallel arrays — archive_paths owns its strings.
        for (c.archive_paths) |maybe_p| if (maybe_p) |s| alloc.free(s);
        if (c.archive_paths.len > 0) alloc.free(c.archive_paths);
        if (c.have_archive.len > 0) alloc.free(c.have_archive);
        if (c.installed.len > 0) alloc.free(c.installed);
        if (c.load_index.len > 0) alloc.free(c.load_index);
        if (c.resolve_explanation) |e| alloc.free(e);
        alloc.destroy(c);
        state.mods_page_cache = null;
        state.mods_page_cache_thread = null;
        state.mods_page_cache_install_id_len = 0;
    }
}

/// Build (or rebuild) the mods page cache for `(game, current install)`.
/// Always returns a valid pointer — on disk-iter errors it falls back
/// to an empty cache (counts.needs_recipe still counts orphan archives,
/// which are read from the already-cached modfile list).
pub fn modsPageCache(frame: *Frame, game: *const library.Game) ?*ModsPageCache {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // Resolve current install (used as cache key + for installed/load_index).
    const install_opt = resolveModsPageInstall(frame, game.f95_thread_id);
    defer if (install_opt) |i| frame.lib.freeInstall(i);
    const install_id_slice: []const u8 = if (install_opt) |i| i.id[0..] else &[_]u8{};

    // Cache hit check: same thread + same install id.
    if (state.mods_page_cache) |cached| {
        const same_thread = (state.mods_page_cache_thread orelse 0) == game.f95_thread_id and
            state.mods_page_cache_thread != null;
        const cached_install = state.mods_page_cache_install_id_buf[0..state.mods_page_cache_install_id_len];
        if (same_thread and std.mem.eql(u8, cached_install, install_id_slice)) {
            return cached;
        }
        // Different game / install — drop and rebuild.
        freeModsPageCacheState(state, alloc);
    }

    const cache = alloc.create(ModsPageCache) catch return makeEmptyModsPageCache(state, alloc);
    cache.* = .{
        .game_parsed = null,
        .mods = &.{},
        .counts = .{},
        .have_archive = &.{},
        .archive_paths = &.{},
        .installed = &.{},
        .load_index = &.{},
        .alloc = alloc,
    };

    // Orphan archive count is recipe-independent — read from the
    // (already-cached) modfile list.
    const modfiles = modfilesForGame(frame, game);
    for (modfiles) |m| {
        if (m.recipe_ids.len == 0) cache.counts.needs_recipe += 1;
    }

    // Load game recipe + mod recipes.
    cache.game_parsed = frame.recipe_repo.findGameByThread(game.f95_thread_id) catch null;
    if (cache.game_parsed) |gp| {
        cache.mods = frame.recipe_repo.listModsForGame(gp.recipe.id) catch blk: {
            const empty: []recipe.ParsedMod = &.{};
            break :blk empty;
        };

        if (cache.mods.len > 0) {
            cache.have_archive = alloc.alloc(bool, cache.mods.len) catch &.{};
            cache.archive_paths = alloc.alloc(?[]u8, cache.mods.len) catch &.{};
            cache.installed = alloc.alloc(bool, cache.mods.len) catch &.{};
            cache.load_index = alloc.alloc(?u32, cache.mods.len) catch &.{};
            // Defaults — any alloc that returned `&.{}` is detected by
            // checking length; we tolerate length-mismatch downstream
            // by treating empty arrays as "all false / null".
            if (cache.have_archive.len == cache.mods.len) @memset(cache.have_archive, false);
            if (cache.archive_paths.len == cache.mods.len) @memset(cache.archive_paths, null);
            if (cache.installed.len == cache.mods.len) @memset(cache.installed, false);
            if (cache.load_index.len == cache.mods.len) @memset(cache.load_index, null);

            // Archive presence per mod (also captures path so row
            // renderer can show it without another disk scan).
            for (cache.mods, 0..) |*pm, i| {
                if (findRegisteredModArchive(frame, game, &pm.recipe)) |path| {
                    if (cache.archive_paths.len == cache.mods.len) cache.archive_paths[i] = path else alloc.free(path);
                    if (cache.have_archive.len == cache.mods.len) cache.have_archive[i] = true;
                }
            }

            // Install-dependent: tracker load (once) + resolver run.
            var any_installed: bool = false;
            if (install_opt) |install| {
                const layout_opt = modTrackerLayout(frame.io, alloc, install.install_path) catch null;
                defer if (layout_opt) |l| freeModTrackerLayout(alloc, l);
                if (layout_opt) |layout| {
                    var log_obj = installer_mod.Tracker.load(alloc, frame.io, layout.tracker_path) catch installer_mod.InstallLog{ .entries = &.{} };
                    defer log_obj.deinit(alloc);
                    // Tracker writes use the recipe slug going
                    // forward; older trackers stored the integer
                    // f95_thread as a string. Match both so older
                    // installs still light up "Installed" after the
                    // upgrade without forcing a reinstall.
                    for (log_obj.entries) |e| {
                        if (e.mod_id.len == 0) continue;
                        for (cache.mods, 0..) |*pm, i| {
                            const slug_match = std.mem.eql(u8, pm.recipe.id, e.mod_id);
                            const legacy_match = blk: {
                                var lbuf: [32]u8 = undefined;
                                const lid = std.fmt.bufPrint(&lbuf, "{d}", .{pm.recipe.f95_thread}) catch break :blk false;
                                break :blk std.mem.eql(u8, lid, e.mod_id);
                            };
                            if (slug_match or legacy_match) {
                                if (cache.installed.len == cache.mods.len and !cache.installed[i]) {
                                    cache.installed[i] = true;
                                    any_installed = true;
                                }
                                break;
                            }
                        }
                    }
                }

                if (any_installed) {
                    // Throwaway arena for resolver scratch.
                    var arena = std.heap.ArenaAllocator.init(alloc);
                    defer arena.deinit();
                    const aalloc = arena.allocator();

                    var requested: std.ArrayList(recipe.ModRecipe) = .empty;
                    var available: std.ArrayList(recipe.ModRecipe) = .empty;
                    for (cache.mods, 0..) |*pm, i| {
                        available.append(aalloc, pm.recipe) catch {};
                        if (cache.installed.len == cache.mods.len and cache.installed[i]) {
                            requested.append(aalloc, pm.recipe) catch {};
                        }
                    }
                    var result = resolver.solveExplained(aalloc, .{
                        .requested = requested.items,
                        .available = available.items,
                        .game_version = install.version,
                    }) catch null;
                    if (result) |*r| {
                        switch (r.*) {
                            .ok => |plan| {
                                for (plan.steps) |step| {
                                    // Match by recipe.id back to the cache slot.
                                    for (cache.mods, 0..) |*pm2, j| {
                                        if (std.mem.eql(u8, pm2.recipe.id, step.mod_id)) {
                                            if (cache.load_index.len == cache.mods.len) cache.load_index[j] = step.load_index;
                                            break;
                                        }
                                    }
                                }
                            },
                            else => {
                                // The installed set won't resolve — surface why.
                                var ebuf: [256]u8 = undefined;
                                if (resolver.explain(&ebuf, r.*)) |msg| {
                                    cache.resolve_explanation = cache.alloc.dupe(u8, msg) catch null;
                                }
                            },
                        }
                        r.deinit(aalloc);
                    }
                }
            }

            // Tab counts roll up the flags.
            for (cache.mods, 0..) |_, i| {
                const inst = cache.installed.len == cache.mods.len and cache.installed[i];
                const have = cache.have_archive.len == cache.mods.len and cache.have_archive[i];
                if (inst) {
                    cache.counts.installed += 1;
                } else if (have) {
                    cache.counts.ready += 1;
                } else {
                    cache.counts.needs_archive += 1;
                }
            }
        }
    }

    // Publish to state + remember cache keys.
    state.mods_page_cache = cache;
    state.mods_page_cache_thread = game.f95_thread_id;
    const n = @min(install_id_slice.len, state.mods_page_cache_install_id_buf.len);
    @memcpy(state.mods_page_cache_install_id_buf[0..n], install_id_slice[0..n]);
    state.mods_page_cache_install_id_len = n;
    return cache;
}

/// Fallback path for OOM during cache build — returns a stub cache
/// that's harmless to render against. NOT published to state so the
/// next frame will try to rebuild.
fn makeEmptyModsPageCache(state: *State, alloc: std.mem.Allocator) ?*ModsPageCache {
    _ = state;
    const c = alloc.create(ModsPageCache) catch return null;
    c.* = .{
        .game_parsed = null,
        .mods = &.{},
        .counts = .{},
        .have_archive = &.{},
        .archive_paths = &.{},
        .installed = &.{},
        .load_index = &.{},
        .alloc = alloc,
    };
    return c;
}

/// Unlink any modfile index entry whose `recipe_id` no longer points
/// at a real `.mod.zon` on disk. Called from `refreshModfileCache`
/// so stale "linked: …" labels disappear after the user manually
/// removes a recipe file from the recipes dir (or our own
/// `doDeleteModRecipe` runs).
fn pruneOrphanRecipeLinks(frame: *Frame, parent_game: *const library.Game) void {
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;
    const mods = ma.loadIndex(alloc, frame.io, frame.info.mod_archives_dir, parent_game.f95_thread_id) catch return;
    defer ma.freeModfileList(alloc, mods);

    for (mods) |m| {
        for (m.recipe_ids) |rid| {
            var p = frame.recipe_repo.findMod(rid) catch |e| {
                log.warn("pruneOrphanRecipeLinks: findMod({s}) failed: {s}", .{ rid, @errorName(e) });
                continue;
            };
            if (p) |*pp| {
                pp.deinit();
                continue;
            }
            // Recipe is gone — unlink this id from the modfile's
            // list. Other links stay intact.
            ma.unlinkRecipe(alloc, frame.io, frame.info.mod_archives_dir, parent_game.f95_thread_id, m.id, rid) catch |e| {
                log.warn("pruneOrphanRecipeLinks: unlink {s} failed: {s}", .{ m.id, @errorName(e) });
                continue;
            };
            log.info("pruneOrphanRecipeLinks: cleared orphan link modfile={s} recipe={s}", .{ m.id, rid });
        }
    }
}

/// Refresh the per-game modfile list cache. Loads the index from disk.
pub fn refreshModfileCache(frame: *Frame, parent_game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    // Clear orphan recipe links *before* dropping the cache so the
    // post-refresh listing reflects the cleanup in one round trip.
    pruneOrphanRecipeLinks(frame, parent_game);
    dropModfileCache(frame);

    const mods = installer_mod.mod_archives.loadIndex(
        alloc,
        frame.io,
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
    ) catch {
        state.setDownloadMsg("Failed to load modfile index.");
        return;
    };

    const cache = alloc.create(ModfileCache) catch {
        installer_mod.mod_archives.freeModfileList(alloc, mods);
        return;
    };
    cache.* = .{ .mods = mods };
    state.modfile_cache = cache;
    state.modfile_cache_thread = parent_game.f95_thread_id;
}

/// Returns the cached modfile list, refreshing if it belongs to a
/// different game or hasn't been loaded yet.
pub fn modfilesForGame(frame: *Frame, parent_game: *const library.Game) []const installer_mod.mod_archives.Modfile {
    const state = frame.state;
    const need_reload = state.modfile_cache_thread == null or
        state.modfile_cache_thread.? != parent_game.f95_thread_id or
        state.modfile_cache == null;
    if (need_reload) refreshModfileCache(frame, parent_game);
    if (state.modfile_cache) |cache| return cache.mods;
    return &.{};
}

/// Picker → add archive (file picker is opened by screens.zig; this
/// just consumes the picked path). Source file is copied, not moved.
pub fn doAddModfile(frame: *Frame, parent_game: *const library.Game, src_path: []const u8) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;

    const res = ma.addForGame(
        alloc,
        frame.io,
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
        src_path,
    ) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Add modfile failed: {s}", .{@errorName(e)}) catch "Add modfile failed";
        state.setDownloadMsg(msg);
        return;
    };

    switch (res) {
        .added => |m| {
            defer ma.freeModfile(alloc, m);
            // Auto-detect install preset by peeking at archive contents.
            // Best-effort — failures log a warning but don't block the
            // add. The user can still author a recipe manually.
            const dest_path = ma.diskPathOf(alloc, frame.info.mod_archives_dir, parent_game.f95_thread_id, m) catch null;
            defer if (dest_path) |p| alloc.free(p);
            if (dest_path) |path| {
                detectAndPinPreset(frame, parent_game, m.id, path);
            }

            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Added `{s}` ({d} bytes).", .{ m.filename, m.size_bytes }) catch "Added.";
            state.setDownloadMsg(msg);
        },
        .duplicate => |d| {
            defer ma.freeModfile(alloc, d.existing);
            var buf: [320]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Already managed as `{s}` for game {d}.", .{ d.existing.filename, d.game_thread_id }) catch "Already managed.";
            state.setDownloadMsg(msg);
        },
    }
    refreshModfileCache(frame, parent_game);
}


/// Import a `.mod.zon` from anywhere on disk into the user's recipes
/// dir. Parses + validates first so a corrupt or unsafe file never
/// lands. Surfaces success/failure as a toast.
pub fn doImportModRecipe(frame: *Frame, src_path: []const u8) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // 1. Load + validate the source file.
    var parsed = recipe.loadMod(frame.io, alloc, src_path) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Import: parse failed: {s}", .{@errorName(e)}) catch "Import: parse failed";
        state.pushToast(.err, msg);
        return;
    };
    defer parsed.deinit();

    const wrapped: recipe.Recipe = .{ .mod = parsed.recipe };
    recipe.validate(&wrapped) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Import: validator: {s}", .{@errorName(e)}) catch "Import: validator failed";
        state.pushToast(.err, msg);
        return;
    };

    // 2. Save into the user's recipes dir. saveMod's atomic tmp+rename
    //    handles the case where a same-id file already exists — that
    //    overwrite is intentional ("re-import updates the recipe").
    frame.recipe_repo.saveMod(&parsed.recipe) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Import: save failed: {s}", .{@errorName(e)}) catch "Import: save failed";
        state.pushToast(.err, msg);
        return;
    };

    var ok_buf: [240]u8 = undefined;
    const ok = std.fmt.bufPrint(&ok_buf, "Imported recipe `{s}`.", .{parsed.recipe.id}) catch "Recipe imported.";
    state.pushToast(.success, ok);
}

/// Resolve which install the Mods page is currently operating on.
/// Honours `state.mods_page_install_id` when set (user explicitly
/// picked a version from the page header dropdown) and falls back to
/// `latestInstallForGame` otherwise. Returns null when no install
/// exists for this game.
///
/// Caller frees with `frame.lib.freeInstall`.
pub fn resolveModsPageInstall(frame: *Frame, thread_id: u64) ?library.Install {
    const state = frame.state;
    if (state.mods_page_install_id) |sel| {
        // listInstalls returns alloc-owned rows. We keep the one we
        // want by detaching its index from the slice (so freeInstalls
        // skips it) and freeing the rest manually.
        const installs = frame.lib.listInstalls(thread_id) catch return frame.lib.latestInstallForGame(thread_id) catch null;
        if (installs.len > 0) {
            var match_idx: ?usize = null;
            for (installs, 0..) |inst, i| {
                if (std.mem.eql(u8, inst.id[0..], sel[0..])) {
                    match_idx = i;
                    break;
                }
            }
            if (match_idx) |hit| {
                // Free siblings; keep the matched row.
                for (installs, 0..) |inst, i| {
                    if (i == hit) continue;
                    frame.lib.freeInstall(inst);
                }
                const out = installs[hit];
                frame.lib.alloc.free(installs);
                return out;
            }
            // Stale id — drop the whole list and fall back below.
            frame.lib.freeInstalls(installs);
        }
    }
    return frame.lib.latestInstallForGame(thread_id) catch null;
}

/// Pick a convert spec for `game` by detecting the engine of the
/// install dir, then matching against the merged convert-preset set
/// (built-ins + `<data_root>/convert-presets/`). Returns `.none` when
/// the engine isn't detectable (game is Linux-native or unknown) so
/// callers can short-circuit cleanly. Replaces the old
/// `recipe.convert_linux` block — convert is engine-keyed dispatch,
/// not per-game data.
pub fn resolveConvertSpec(frame: *Frame, install_dir: []const u8) convert_mod.ConvertSpec {
    const detected = convert_mod.detectEngine(frame.io, install_dir);
    if (detected == .unknown) return .none;

    var bundle = convert_mod.loadMergedPresets(frame.lib.alloc, frame.io, frame.info.convert_presets_dir) catch return .none;
    defer bundle.deinit();
    const matched = convert_mod.pickPresetForEngine(bundle.presets, detected) orelse return .none;
    return matched.preset.spec;
}

/// File / dir names that strongly indicate "this is the game's
/// install root" — used by `resolveGameRoot` to peel away wrapper
/// folders that archives commonly ship at the top level.
const GAME_ROOT_TELLTALES = [_][]const u8{
    "www",                  // RPGM MV/MZ
    "game",                 // Ren'Py / Unity assets
    "BepInEx",              // Unity mod loader
    "renpy",                // Ren'Py SDK dir
    "nw.exe",               // RPGM MV Windows launcher
    "nw",                   // RPGM MV Linux launcher
    "nw.dll",               // RPGM MV Windows DLL
    "data.win",             // GameMaker
    "package.json",         // RPGM (sometimes)
};

/// Inspect `install_dir` looking for the actual game root. Many F95
/// archives ship a wrapper folder (`Game_v1.2/...`) so the bare
/// install dir is one level too shallow for the mod plan to land in
/// the right place. We probe for telltale files / dirs at depth 0;
/// if absent, we descend one level when there's exactly one
/// candidate subdir.
///
/// Caller frees the returned string. Returns a fresh dupe even when
/// no descent happens — uniform ownership for the caller.
pub fn resolveGameRoot(
    io: std.Io,
    install_dir: []const u8,
    alloc: std.mem.Allocator,
) ![]u8 {
    if (hasGameTelltale(io, install_dir)) {
        return alloc.dupe(u8, install_dir);
    }

    // Descend one level if there's exactly one non-hidden subdir.
    var dir = std.Io.Dir.cwd().openDir(io, install_dir, .{ .iterate = true }) catch {
        return alloc.dupe(u8, install_dir);
    };
    defer dir.close(io);

    var found_name: ?[]u8 = null;
    var multiple = false;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue; // skip .f69-home etc.
        if (found_name != null) {
            multiple = true;
            break;
        }
        found_name = alloc.dupe(u8, entry.name) catch null;
    }
    defer if (found_name) |n| alloc.free(n);

    if (multiple or found_name == null) return alloc.dupe(u8, install_dir);

    const candidate = std.fmt.allocPrint(alloc, "{s}/{s}", .{ install_dir, found_name.? }) catch {
        return alloc.dupe(u8, install_dir);
    };
    if (hasGameTelltale(io, candidate)) return candidate;
    alloc.free(candidate);
    return alloc.dupe(u8, install_dir);
}

fn hasGameTelltale(io: std.Io, path: []const u8) bool {
    for (GAME_ROOT_TELLTALES) |name| {
        var probe_buf: [1024]u8 = undefined;
        const probe = std.fmt.bufPrint(&probe_buf, "{s}/{s}", .{ path, name }) catch continue;
        if ((std.Io.Dir.cwd().access(io, probe, .{}) catch null) != null) return true;
    }
    // Fallback: any .exe / .sh / .x86_64 at this level → likely a root.
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".exe")) return true;
        if (std.mem.endsWith(u8, entry.name, ".sh")) return true;
        if (std.mem.endsWith(u8, entry.name, ".x86_64")) return true;
        if (std.mem.endsWith(u8, entry.name, ".AppImage")) return true;
    }
    return false;
}

// ============================================================
//  Bulk engine re-detection (Settings → Library)
// ============================================================

pub const EngineReanalyseStats = struct {
    scanned: u32 = 0, // games with at least one install on disk
    changed: u32 = 0, // games whose stored engine label was updated
    skipped_no_install: u32 = 0,
    skipped_detect_unknown: u32 = 0,

    // Per-engine counts of `changed` (read off in the summary line).
    to_renpy: u32 = 0,
    to_rpgm_mv: u32 = 0,
    to_rpgm_mz: u32 = 0,
    to_rpgm_vx: u32 = 0,
    to_unity: u32 = 0,
};

/// Settings → Library → "Re-detect engines". On click the UI thread reads
/// one install row per game (`latestInstallForGame`; Stage A accepts
/// these on-click queries) and copies the game id, name, stored engine
/// and install path into a `ReanalyseJob`. The wrapper peel and engine
/// detection run on the compute thread (`threads/jobs/reanalyse.zig`)
/// with "Game i / n · <name>" progress; `handleWorkDone` writes the
/// changed labels with `applyScrape` and shows the summary
/// (`applyReanalyseOutcome`).
///
/// Engine coverage: Ren'Py, RPGM MV/MZ, Unity (via convert/detect.zig);
/// RPGM XP/VX/VX Ace (via convert/rpgm.detectRgssVariant — all roll up
/// to library's `rpgm_vx` since the Engine enum doesn't carve XP out).
/// Engines without a Linux fingerprint here (Unreal, HTML, GameMaker,
/// Wolf RPG) are left alone — they need their own walker.
pub fn doReanalyseAllEngines(frame: *Frame) void {
    const alloc = frame.lib.alloc;
    // Library-wide: activity tid 0, so `liveForGame(0)` blocks a second run.
    const a = threads_act.startTool(frame, .reanalyse, 0, "Re-analyse engines") orelse return;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var in: std.ArrayList(reanalyse_job.ReanalyseJob.In) = .empty;
    var no_install: u32 = 0;
    for (frame.games) |*game| {
        const install = (frame.lib.latestInstallForGame(game.f95_thread_id) catch null) orelse {
            no_install += 1;
            continue;
        };
        defer frame.lib.freeInstall(install);
        const path = arena.dupe(u8, install.install_path) catch {
            threads_act.failTool(frame, a, "Out of memory.");
            return;
        };
        in.append(arena, .{
            .tid = game.f95_thread_id,
            .name = game.name,
            .engine = game.engine,
            .install_path = path,
        }) catch {
            threads_act.failTool(frame, a, "Out of memory.");
            return;
        };
    }

    const job = reanalyse_job.ReanalyseJob.create(alloc, in.items, no_install) catch {
        threads_act.failTool(frame, a, "Out of memory.");
        return;
    };
    frame.work.submit(.{ .reanalyse = job }, a) catch {
        threads_act.failTool(frame, a, "Out of memory.");
        return;
    };
}

/// UI-thread end of "Re-detect engines": writes each engine change with
/// `applyScrape` (games deleted meanwhile, or already relabelled, are
/// skipped), recounts `changed` from the writes that succeeded, writes
/// the Settings summary line, toasts it, and drops the library filter
/// cache when anything changed.
pub fn applyReanalyseOutcome(frame: *Frame, out: reanalyse_job.ReanalyseOutcome) void {
    var stats = out.stats;
    stats.changed = 0;
    stats.to_renpy = 0;
    stats.to_rpgm_mv = 0;
    stats.to_rpgm_mz = 0;
    stats.to_rpgm_vx = 0;
    stats.to_unity = 0;
    for (out.updates) |u| {
        const game = gameByTid(frame, u.tid) orelse continue;
        if (game.engine == u.engine) continue;
        const old_engine = game.engine;
        frame.lib.applyScrape(game, .{ .engine = u.engine }) catch |e| {
            log.warn("reanalyseEngines: applyScrape failed for tid={d}: {s}", .{ u.tid, @errorName(e) });
            continue;
        };
        log.info("reanalyseEngines: tid={d} {s} → {s}", .{ u.tid, @tagName(old_engine), @tagName(u.engine) });
        reanalyse_job.countChange(&stats, u.engine);
    }

    // Surface the result in the settings tab and as a toast.
    writeReanalyseSummary(frame.state, stats);
    frame.state.pushToast(.success, frame.state.engine_reanalyse_msg_buf[0..frame.state.engine_reanalyse_msg_len]);

    // Drop the library filter cache. Its signature doesn't hash
    // per-game data, so a fresh engine label on a game caught by an
    // active engine filter wouldn't otherwise re-evaluate inclusion
    // until something else dirtied the signature.
    if (stats.changed > 0) {
        if (frame.state.lib_filter_cache_indices) |old| {
            frame.lib.alloc.free(old);
            frame.state.lib_filter_cache_indices = null;
        }
        frame.state.lib_filter_cache_sig = 0;
    }
}

fn gameByTid(frame: *Frame, tid: u64) ?*library.Game {
    for (frame.games) |*g| if (g.f95_thread_id == tid) return g;
    return null;
}

fn writeReanalyseSummary(state: *State, stats: EngineReanalyseStats) void {
    const written = std.fmt.bufPrint(&state.engine_reanalyse_msg_buf,
        "Scanned {d}. Updated {d}: Ren'Py {d} \xC2\xB7 RPGM {d}/{d}/{d} \xC2\xB7 Unity {d}. Unknown: {d}. No install: {d}.",
        .{
            stats.scanned, stats.changed,
            stats.to_renpy, stats.to_rpgm_mv, stats.to_rpgm_mz, stats.to_rpgm_vx,
            stats.to_unity,
            stats.skipped_detect_unknown,
            stats.skipped_no_install,
        },
    ) catch state.engine_reanalyse_msg_buf[0..0];
    state.engine_reanalyse_msg_len = written.len;
}

/// Resolved on-disk layout for the per-install mod tracker. `doInstallMod`
/// writes the file inside `game_root` (the peeled wrapper folder) — every
/// reader must resolve the same way or it'll look in the wrong directory
/// and miss installed mods. This helper centralises that and returns both
/// paths so callers can also feed `game_root` to `uninstallMod`'s file
/// resolver, which is rooted at the same place.
pub const ModTrackerLayout = struct {
    game_root: []u8,
    tracker_path: []u8,
};

pub fn modTrackerLayout(
    io: std.Io,
    alloc: std.mem.Allocator,
    install_path: []const u8,
) !ModTrackerLayout {
    const game_root = try resolveGameRoot(io, install_path, alloc);
    errdefer alloc.free(game_root);
    const tracker_path = try std.fmt.allocPrint(alloc, "{s}/.f69-mods.json", .{game_root});
    return .{ .game_root = game_root, .tracker_path = tracker_path };
}

pub fn freeModTrackerLayout(alloc: std.mem.Allocator, layout: ModTrackerLayout) void {
    alloc.free(layout.game_root);
    alloc.free(layout.tracker_path);
}

/// "Test install (real)" — kicks off a worker thread that runs the
/// actual installer against a throwaway scratch dir. Verifies the
/// plan extracts cleanly against a real filesystem. UI stays
/// responsive while it runs; `drainTestInstall` per-frame posts the

pub fn modfileArchivePath(
    frame: *Frame,
    parent_game: *const library.Game,
    modfile_id: []const u8,
) ?[]u8 {
    const ma = installer_mod.mod_archives;
    const alloc = frame.lib.alloc;
    if (modfile_id.len == 0) return null;
    const mods = modfilesForGame(frame, parent_game);
    for (mods) |m| {
        if (!std.mem.eql(u8, m.id, modfile_id)) continue;
        return ma.diskPathOf(alloc, frame.info.mod_archives_dir, parent_game.f95_thread_id, m) catch null;
    }
    return null;
}

/// Sorted, deduped list of top-level directory names present in
/// `archive_path`. Used to seed the Browse… menu on `to` / `dest`
/// fields — most mods install into one of a handful of well-known
/// roots (`game/`, `BepInEx/`, etc.), so the picker gives the user
/// real labels to pick instead of asking them to remember paths.
///
/// Caller frees with `freeTopDirs`.
pub fn archiveTopDirs(frame: *Frame, archive_path: []const u8) ?[][]u8 {
    const archive = installer_mod.preset_detect; // re-exports listEntries/freeEntryList
    const alloc = frame.lib.alloc;
    const entries = archive.listEntries(alloc, archive_path) catch return null;
    defer archive.freeEntryList(alloc, entries);

    var seen: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = seen.iterator();
        while (it.next()) |e| alloc.free(e.key_ptr.*);
        seen.deinit();
    }
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    for (entries) |e| {
        const slash = std.mem.indexOfScalar(u8, e, '/') orelse continue;
        if (slash == 0) continue;
        const top = e[0..slash];
        if (seen.contains(top)) continue;
        const owned_key = alloc.dupe(u8, top) catch continue;
        seen.put(owned_key, {}) catch {
            alloc.free(owned_key);
            continue;
        };
        const for_out = alloc.dupe(u8, top) catch continue;
        out.append(alloc, for_out) catch {
            alloc.free(for_out);
            continue;
        };
    }
    // Lexicographic sort so the menu ordering is stable across paints.
    std.mem.sort([]u8, out.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return out.toOwnedSlice(alloc) catch null;
}

pub fn freeTopDirs(alloc: std.mem.Allocator, dirs: [][]u8) void {
    for (dirs) |d| alloc.free(d);
    if (dirs.len > 0) alloc.free(dirs);
}

/// Sorted, deduped first-level directory names from the game's install
/// dir. Lets the wizard's Browse… menu suggest real install-side paths
/// (`game/`, `lib/`, `renpy/`, etc.) for destination fields.
///
/// Uses the latest install row's `install_path` — same source as
/// `doLaunchGame`'s fallback. Caller frees with `freeTopDirs`.
pub fn installTopDirs(frame: *Frame, parent_game: *const library.Game) ?[][]u8 {
    const alloc = frame.lib.alloc;
    const install_opt = frame.lib.latestInstallForGame(parent_game.f95_thread_id) catch null;
    const install = install_opt orelse return null;
    defer frame.lib.freeInstall(install);

    // Suggestions reflect the game-root view, not the bare extract,
    // so users see the same dirs the installer will actually target.
    const root = resolveGameRoot(frame.io, install.install_path, alloc) catch null;
    const probe = root orelse install.install_path;
    defer if (root) |r| alloc.free(r);

    var dir = std.Io.Dir.cwd().openDir(frame.io, probe, .{ .iterate = true }) catch return null;
    defer dir.close(frame.io);

    var seen: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = seen.iterator();
        while (it.next()) |e| alloc.free(e.key_ptr.*);
        seen.deinit();
    }
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }

    var iter = dir.iterate();
    while (iter.next(frame.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        // Skip f69's own bookkeeping subdirs so they don't pollute
        // the Browse menu.
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        if (seen.contains(entry.name)) continue;
        const key = alloc.dupe(u8, entry.name) catch continue;
        seen.put(key, {}) catch {
            alloc.free(key);
            continue;
        };
        const for_out = alloc.dupe(u8, entry.name) catch continue;
        out.append(alloc, for_out) catch {
            alloc.free(for_out);
            continue;
        };
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return out.toOwnedSlice(alloc) catch null;
}

/// Build a SimulationResult for the wizard's current state. Returns
/// null on lookup failure (no modfile, no install dir, no archive
/// readable). Caller owns the returned `SimulationResult` and must
/// call `deinit`. Cheap enough (~sub-ms for typical mods) to invoke
/// every paint of the install-blocks / Review steps.
pub fn simulateCurrentPlan(frame: *Frame, parent_game: *const library.Game) ?installer_mod.SimulationResult {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const w = &(state.wizard orelse return null);

    // 1. Locate the archive on disk via modfile lookup.
    const modfile_id = w.modfile_id_buf[0..w.modfile_id_len];
    if (modfile_id.len == 0) return null;
    const mods = modfilesForGame(frame, parent_game);
    var disk_name: []const u8 = "";
    for (mods) |m| {
        if (std.mem.eql(u8, m.id, modfile_id)) {
            disk_name = m.disk_name;
            break;
        }
    }
    if (disk_name.len == 0) return null;
    const archive_path = std.fmt.allocPrint(alloc, "{s}/{d}/{s}", .{
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
        disk_name,
    }) catch return null;
    defer alloc.free(archive_path);

    // 2. Resolve the install dir from the wizard's picked version,
    //    falling back to `latestInstallForGame` when the buffer is
    //    empty (e.g. before the user touched the version dropdown).
    var install_buf: [768]u8 = undefined;
    const for_game_version = w.for_game_version_buf[0..std.mem.indexOfScalar(u8, &w.for_game_version_buf, 0) orelse w.for_game_version_buf.len];
    const raw_install: []const u8 = blk: {
        if (for_game_version.len > 0) {
            const installs = frame.lib.listInstalls(parent_game.f95_thread_id) catch break :blk "";
            defer if (installs.len > 0) frame.lib.freeInstalls(installs);
            for (installs) |inst| {
                if (std.mem.eql(u8, inst.version, for_game_version)) {
                    break :blk std.fmt.bufPrint(&install_buf, "{s}", .{inst.install_path}) catch break :blk "";
                }
            }
        }
        const latest = frame.lib.latestInstallForGame(parent_game.f95_thread_id) catch null;
        if (latest) |i| {
            defer frame.lib.freeInstall(i);
            break :blk std.fmt.bufPrint(&install_buf, "{s}", .{i.install_path}) catch break :blk "";
        }
        break :blk "";
    };
    if (raw_install.len == 0) return null;

    // 2.5 Resolve the game root inside the install dir. F95 archives
    //     commonly nest the game one folder deep (`Game_v1.2/www/...`);
    //     mods target the game's content tree, not the bare extract.
    //     The simulator preview shows the resolved root in its header
    //     so the user can sanity-check.
    const game_root = resolveGameRoot(frame.io, raw_install, alloc) catch return null;
    defer alloc.free(game_root);

    // 3. Tracker path is conventional — `<game_root>/.f69-mods.json`.
    var tracker_buf: [1024]u8 = undefined;
    const tracker_path = std.fmt.bufPrint(&tracker_buf, "{s}/.f69-mods.json", .{game_root}) catch null;

    // 4. Materialize the plan from wizard blocks. We use a scratch
    //    arena so cleanup is single-deinit; the simulator copies any
    //    strings it needs into its own arena.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const scratch_alloc = scratch.allocator();

    var steps: std.ArrayList(recipe.InstallStep) = .empty;
    var i: usize = 0;
    while (i < w.block_count) : (i += 1) {
        const b = &w.blocks[i];
        const a = sliceFromBuf(&b.a_buf);
        const b_s = sliceFromBuf(&b.b_buf);
        const step: recipe.InstallStep = switch (b.kind) {
            .extract => .{ .extract = .{ .to = a, .strip = b.strip } },
            .extract_inner => .{ .extract_inner = .{ .archive = a, .to = b_s, .strip = b.strip } },
            .copy => .{ .copy = .{ .src = a, .dest = b_s } },
            .move => .{ .move = .{ .src = a, .dest = b_s } },
            .delete => .{ .delete = .{ .path = a } },
            .chmod_x => blk: {
                const paths_arr = scratch_alloc.alloc([]const u8, 1) catch return null;
                paths_arr[0] = a;
                break :blk .{ .chmod_x = .{ .paths = paths_arr } };
            },
        };
        steps.append(scratch_alloc, step) catch return null;
    }

    // 5. Run against the resolved game root, not the bare install dir.
    return installer_mod.simulateInstall(alloc, frame.io, archive_path, steps.items, game_root, tracker_path) catch null;
}

/// Two-click delete on a user preset. First call arms; second call on
/// the same id executes. Any other action between the two clears the
/// arm via `state.clearPresetDeleteArm()`. Mirrors the modfile /
/// mod-recipe delete UX.
pub fn doDeleteUserPresetArmed(frame: *Frame, preset_id: []const u8) void {
    const state = frame.state;
    const armed = state.presetPendingDeleteSlice();
    if (!std.mem.eql(u8, armed, preset_id)) {
        // First click for this id — arm and bail. Row re-renders with
        // "Confirm delete preset" label next frame.
        state.armPresetDelete(preset_id);
        return;
    }
    // Second click — clear the arm + actually delete.
    state.clearPresetDeleteArm();
    deleteUserPresetNow(frame, preset_id);
}

fn deleteUserPresetNow(frame: *Frame, preset_id: []const u8) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    const path = std.fmt.allocPrint(alloc, "{s}/{s}{s}", .{
        frame.info.mod_presets_dir,
        preset_id,
        recipe.PRESET_FILE_SUFFIX,
    }) catch return;
    defer alloc.free(path);

    std.Io.Dir.cwd().deleteFile(frame.io, path) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Delete preset failed: {s}", .{@errorName(e)}) catch "Delete preset failed";
        state.pushToast(.err, msg);
        return;
    };
    invalidatePresetCache(state);
    var ok: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&ok, "Deleted preset `{s}`.", .{preset_id}) catch "Preset deleted.";
    state.pushToast(.success, msg);
}

/// Lazily-loaded merged preset set. First call parses built-ins +
/// scans `<data_root>/mod-presets/`; subsequent calls reuse the cache
/// until `invalidatePresetCache` is invoked (after save / delete).
/// Returns null when load fails (rare — embedded data is the only
/// load that has to succeed).
///
/// Memory model: the bundle's arena owns all preset strings AND the
/// outer `MergedPresetSet` struct itself (allocated inside the arena
/// after load). Single `bundle.deinit()` reclaims everything; no
/// trailing lib-allocator outer-struct to track.
pub fn getMergedPresets(frame: *Frame) ?*recipe.MergedPresetSet {
    const state = frame.state;
    if (state.preset_cache) |bundle_ptr| return bundle_ptr;
    var bundle = recipe.loadMergedPresets(frame.lib.alloc, frame.io, frame.info.mod_presets_dir) catch return null;
    // Move the bundle into its own arena so the outer struct's
    // lifetime matches the inner arena's. After this move, calling
    // `bundle.deinit()` (via the cached pointer) frees the struct +
    // every preset payload in one shot.
    const bundle_ptr = bundle.arena.allocator().create(recipe.MergedPresetSet) catch {
        bundle.deinit();
        return null;
    };
    bundle_ptr.* = bundle;
    state.preset_cache = bundle_ptr;
    return bundle_ptr;
}

/// Tear down the cached preset bundle. Next `getMergedPresets` call
/// rebuilds. Call after any `<data_root>/mod-presets/` write so the
/// next read sees the new disk state.
pub fn invalidatePresetCache(state: *State) void {
    if (state.preset_cache) |bundle_ptr| {
        bundle_ptr.deinit(); // arena dies → bundle_ptr's memory dies too
        state.preset_cache = null;
    }
}

/// Set / clear the preset attribution on a modfile. Pass `null` for
/// `preset_id` to clear (e.g. user picked "None" in the row dropdown).
/// Surfaces a toast only on failure — happy-path is silent because
/// the row will visually reflect the new value on next paint.
pub fn doSetModfilePreset(
    frame: *Frame,
    parent_game: *const library.Game,
    modfile_id: []const u8,
    preset_id: ?[]const u8,
) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;
    ma.setPresetId(alloc, frame.io, frame.info.mod_archives_dir, parent_game.f95_thread_id, modfile_id, preset_id) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Update preset failed: {s}", .{@errorName(e)}) catch "Update preset failed";
        state.pushToast(.err, msg);
        return;
    };
    refreshModfileCache(frame, parent_game);
}

/// Derive a user preset from a working mod recipe + its registered
/// archive. Samples the archive's top-level dirs to build a
/// `requires` pattern list, copies the recipe's `install` steps
/// verbatim, and writes the result to `<data_root>/mod-presets/`.
/// Surfaces a toast on success/failure.
pub fn doSaveModRecipeAsPreset(
    frame: *Frame,
    parent_game: *const library.Game,
    mod_recipe: *const recipe.ModRecipe,
) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // 1. Locate the archive — needed to sample paths for `requires`.
    const archive_path_opt = findRegisteredModArchive(frame, parent_game, mod_recipe);
    const archive_path = archive_path_opt orelse {
        state.pushToast(.err, "Save as preset: no archive registered for this mod.");
        return;
    };
    defer alloc.free(archive_path);

    // 2. List entries; build a sorted set of distinct first-segment
    // directory names (e.g. {"game", "BepInEx"} for an archive that
    // ships both). Routed through `preset_detect` so the UI module
    // doesn't grow a direct util_archive dep.
    const pd = installer_mod.preset_detect;
    const entries = pd.listEntries(alloc, archive_path) catch {
        state.pushToast(.err, "Save as preset: failed to read archive contents.");
        return;
    };
    defer pd.freeEntryList(alloc, entries);

    var top_dirs: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = top_dirs.iterator();
        while (it.next()) |e| alloc.free(e.key_ptr.*);
        top_dirs.deinit();
    }
    for (entries) |e| {
        const slash = std.mem.indexOfScalar(u8, e, '/') orelse continue;
        if (slash == 0) continue;
        const top = e[0..slash];
        if (top_dirs.contains(top)) continue;
        const dup = alloc.dupe(u8, top) catch continue;
        top_dirs.put(dup, {}) catch {
            alloc.free(dup);
            continue;
        };
    }

    // 3. Build the Preset in an arena so writing + stringifying is
    // single-deinit cleanup.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const preset_id = std.fmt.allocPrint(aalloc, "{s}-pattern", .{mod_recipe.id}) catch {
        state.pushToast(.err, "Save as preset: out of memory.");
        return;
    };
    const preset_name = std.fmt.allocPrint(aalloc, "User: {s}", .{mod_recipe.name}) catch mod_recipe.name;

    var requires_list: std.ArrayList([]const u8) = .empty;
    var it = top_dirs.iterator();
    while (it.next()) |e| {
        const pat = std.fmt.allocPrint(aalloc, "{s}/**/*", .{e.key_ptr.*}) catch continue;
        requires_list.append(aalloc, pat) catch break;
    }
    const requires_slice = requires_list.toOwnedSlice(aalloc) catch &[_][]const u8{};

    const preset: recipe.Preset = .{
        .id = preset_id,
        .name = preset_name,
        .description = "Derived from a working user recipe via Save as preset",
        .engine_hint = libEngineToRecipe(parent_game.engine),
        .match = .{
            .requires = requires_slice,
            .forbids = &.{},
            .min_confidence = if (requires_slice.len > 0) 0.5 else 0.0,
        },
        .install = mod_recipe.install,
        // Weight 1.5 → wins over the bundled built-ins (weight 1.0)
        // when both match, so the user's authored pattern is preferred.
        .weight = 1.5,
    };

    recipe.saveUserPreset(alloc, frame.io, frame.info.mod_presets_dir, &preset) catch |e| {
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Save as preset failed: {s}", .{@errorName(e)}) catch "Save as preset failed";
        state.pushToast(.err, msg);
        return;
    };
    invalidatePresetCache(state);

    var buf: [240]u8 = undefined;
    const ok = std.fmt.bufPrint(&buf, "Saved preset `{s}` ({d} pattern(s)).", .{ preset_id, requires_slice.len }) catch "Preset saved.";
    state.pushToast(.success, ok);
    log.info("user preset saved: {s} ({d} requires patterns)", .{ preset_id, requires_slice.len });
}

/// Deep-link to a specific Settings tab. Wraps the two-line
/// "set tab then flip screen" so callers don't have to remember the
/// order (and the intent reads cleanly at the call site).
pub fn openSettingsTab(state: *State, tab: state_mod.SettingsTab) void {
    state.settings_tab = tab;
    state.screen = .settings;
}

/// Idempotently ensure that a `<thread_id>.game.zon` exists on disk
/// for this game. Auto-derives from the scraped live `library.Game`
/// (name + version + engine — same payload `deriveLiveRecipe` builds
/// for the Recipe tab) and writes via `recipe_repo.saveGame`. No-op
/// when a recipe is already present. The goal is to remove the
/// manual "Save the recipe before adding mods" step — once the user
/// adds a mod, intent is clear enough to commit a stub.
pub fn ensureGameRecipeOnDisk(frame: *Frame, game: *const library.Game) !void {
    var existing = frame.recipe_repo.findGameByThread(game.f95_thread_id) catch null;
    if (existing) |*p| {
        p.deinit();
        return;
    }

    var arena = std.heap.ArenaAllocator.init(frame.lib.alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const engine = libEngineToRecipe(game.engine);
    const version = game.latest_version orelse "0";
    const derived = try recipe.derive.deriveGameRecipe(aalloc, .{
        .thread_id = game.f95_thread_id,
        .name = game.name,
        .version = version,
        .download_links = &.{},
        .engine = engine,
        .engine_version = null,
    });
    try frame.recipe_repo.saveGame(&derived);
    launch_act.invalidateRecipeSource(frame.state, game.f95_thread_id);
    log.info("auto-saved game recipe for thread {d}", .{game.f95_thread_id});
}

/// Map a library-side engine enum to the (narrower) recipe-side one.
/// `library.Engine` is closed-set; the recipe enum collapses anything
/// outside the explicit list to `.unknown`. The matcher then treats
/// `.unknown` as "no engine hint" → only `engine_hint = null` presets
/// fire (notably the generic catch-all).
fn libEngineToRecipe(e: library.Engine) recipe.Engine {
    return switch (e) {
        .renpy => .renpy,
        .rpgm_mv => .rpgm_mv,
        .rpgm_mz => .rpgm_mz,
        .unity => .unity,
        else => .unknown,
    };
}

/// Run preset detection on `archive_path`, pin the matched preset id
/// (if any) on the modfile in the per-game index. Best-effort: failures
/// log and return silently — the user can still author a recipe.
fn detectAndPinPreset(
    frame: *Frame,
    parent_game: *const library.Game,
    modfile_id: []const u8,
    archive_path: []const u8,
) void {
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;

    const engine_recipe: ?recipe.Engine = blk: {
        const mapped = libEngineToRecipe(parent_game.engine);
        if (mapped == .unknown) break :blk null;
        break :blk mapped;
    };

    const detection_opt = installer_mod.preset_detect.detect(
        alloc,
        frame.io,
        archive_path,
        frame.info.mod_presets_dir,
        engine_recipe,
    ) catch |e| {
        log.warn("preset detect failed for {s}: {s}", .{ archive_path, @errorName(e) });
        return;
    };
    if (detection_opt) |d| {
        defer d.deinit(alloc);
        ma.setPresetId(
            alloc,
            frame.io,
            frame.info.mod_archives_dir,
            parent_game.f95_thread_id,
            modfile_id,
            d.preset_id,
        ) catch |e| {
            log.warn("setPresetId({s}) failed: {s}", .{ d.preset_id, @errorName(e) });
            return;
        };
        log.info("preset detected: {s} (confidence={d:.2}) for modfile {s}", .{
            d.preset_id,
            d.confidence,
            modfile_id[0..@min(12, modfile_id.len)],
        });
    } else {
        log.info("no preset matched for modfile {s}", .{modfile_id[0..@min(12, modfile_id.len)]});
    }
}

/// "Scan mods folder" — walks the per-game subdir, ingests anything
/// not yet indexed. Runs synchronously today; UI calls this on click,
/// which means large dirs block until done. (TODO: worker thread once
/// the dvui async story matures.)

pub fn doScanModfiles(frame: *Frame, parent_game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;

    state.modfile_scan_busy = true;
    defer state.modfile_scan_busy = false;

    var report = ma.scanForGame(
        alloc,
        frame.io,
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
    ) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Scan failed: {s}", .{@errorName(e)}) catch "Scan failed";
        state.setDownloadMsg(msg);
        return;
    };
    defer report.deinit(alloc);

    const summary = std.fmt.bufPrint(&state.modfile_scan_msg.bytes, "Added {d}, unchanged {d}, duplicate skipped {d}, non-archive skipped {d}, removed missing {d}", .{
        report.added.len,
        report.unchanged,
        report.duplicates_skipped.len,
        report.non_archive_skipped.len,
        report.removed_missing,
    }) catch state.modfile_scan_msg.bytes[0..0];
    state.modfile_scan_msg.len = summary.len;

    refreshModfileCache(frame, parent_game);
}

/// Two-click delete: first click arms the row, second click performs
/// the delete. The arming id lives in `state.modfile_pending_delete_id_*`.
pub fn doDeleteModfile(frame: *Frame, parent_game: *const library.Game, modfile_id: []const u8) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const ma = installer_mod.mod_archives;

    const pending = state.modfile_pending_delete_id_buf[0..state.modfile_pending_delete_id_len];
    if (!std.mem.eql(u8, pending, modfile_id)) {
        // First click — arm.
        const n = @min(modfile_id.len, state.modfile_pending_delete_id_buf.len);
        @memcpy(state.modfile_pending_delete_id_buf[0..n], modfile_id[0..n]);
        state.modfile_pending_delete_id_len = n;
        return;
    }

    // Second click — confirm.
    state.modfile_pending_delete_id_len = 0;

    ma.deleteForGame(alloc, frame.io, frame.info.mod_archives_dir, parent_game.f95_thread_id, modfile_id) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Delete failed: {s}", .{@errorName(e)}) catch "Delete failed";
        state.setDownloadMsg(msg);
        return;
    };
    state.setDownloadMsg("Modfile deleted.");
    refreshModfileCache(frame, parent_game);
}

/// Clear the pending-delete arming state. Called when the user clicks
/// any other button on the Modfiles tab (so the arming doesn't outlive
/// the intent). Clears the preset-delete arm too — same lifetime rule.
pub fn clearPendingDelete(frame: *Frame) void {
    frame.state.modfile_pending_delete_id_len = 0;
    frame.state.clearPresetDeleteArm();
}

/// Delete a mod recipe `<id>.mod.zon` from the user's local recipes
/// dir, and unlink any modfile index entries that referenced it. The
/// archive itself stays — the user can re-author or link it to a new
/// recipe later. No two-click confirm here yet (caller-side responsibility).
pub fn doDeleteModRecipe(frame: *Frame, parent_game: *const library.Game, recipe_id: []const u8) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;

    // Delete the `.mod.zon` from disk.
    var path_buf: [768]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.mod.zon", .{ frame.recipe_repo.local_dir, recipe_id }) catch {
        state.pushToast(.err, "Recipe path too long.");
        return;
    };
    std.Io.Dir.cwd().deleteFile(frame.io, path) catch |e| switch (e) {
        error.FileNotFound => {}, // already gone — proceed to cleanup
        else => {
            var buf: [240]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Delete recipe failed: {s}", .{@errorName(e)}) catch "Delete recipe failed";
            state.pushToast(.err, msg);
            return;
        },
    };
    log.info("doDeleteModRecipe: removed {s}", .{path});

    // Unlink every modfile index entry pointing at this recipe. This
    // is the cleanup pruneOrphanRecipeLinks would do anyway, but we
    // do it eagerly so the next render shows the row as "no recipe"
    // immediately.
    const ma = installer_mod.mod_archives;
    const mods = ma.loadIndex(alloc, frame.io, frame.info.mod_archives_dir, parent_game.f95_thread_id) catch {
        state.pushToast(.success, "Recipe deleted (index cleanup deferred).");
        refreshModfileCache(frame, parent_game);
        return;
    };
    defer ma.freeModfileList(alloc, mods);
    var unlinked: u32 = 0;
    for (mods) |m| {
        for (m.recipe_ids) |rid| {
            if (!std.mem.eql(u8, rid, recipe_id)) continue;
            ma.unlinkRecipe(alloc, frame.io, frame.info.mod_archives_dir, parent_game.f95_thread_id, m.id, recipe_id) catch break;
            unlinked += 1;
            break;
        }
    }
    log.info("doDeleteModRecipe: unlinked {d} modfile(s) from recipe '{s}'", .{ unlinked, recipe_id });

    var ok_buf: [192]u8 = undefined;
    const ok = std.fmt.bufPrint(&ok_buf, "Recipe '{s}' deleted (unlinked {d} modfile(s)).", .{ recipe_id, unlinked }) catch "Recipe deleted.";
    state.pushToast(.success, ok);

    refreshModfileCache(frame, parent_game);
}

/// Two-click delete arming for the Mods tab recipe rows. First click
/// loads the recipe id into the same `modfile_pending_delete_id_*`
/// buffer used for modfile deletes (they never coexist on the same
/// row); second click on the same row dispatches the delete.
pub fn doDeleteModRecipeArmed(frame: *Frame, parent_game: *const library.Game, recipe_id: []const u8) void {
    const state = frame.state;
    const pending = state.modfile_pending_delete_id_buf[0..state.modfile_pending_delete_id_len];
    if (!std.mem.eql(u8, pending, recipe_id)) {
        const n = @min(recipe_id.len, state.modfile_pending_delete_id_buf.len);
        @memcpy(state.modfile_pending_delete_id_buf[0..n], recipe_id[0..n]);
        state.modfile_pending_delete_id_len = n;
        return;
    }
    state.modfile_pending_delete_id_len = 0;
    doDeleteModRecipe(frame, parent_game, recipe_id);
}

// ============================================================
//  Recipe wizard — orchestration entry points
// ============================================================

/// Open the recipe wizard, pre-filled with sensible defaults derived
/// from the current game + modfile. The wizard struct lives in
/// `state.wizard`; closing it nulls the field. The wizard is modal
/// (rendered by screens.zig over the detail page).
pub fn openWizardForModfile(frame: *Frame, parent_game: *const library.Game, modfile_id: []const u8) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    _ = alloc;

    // Auto-promote the game recipe to disk if it isn't already there.
    // Removes the "you have to Save on the Recipe tab first" friction
    // the user flagged: once they're adding mods, the recipe stub is
    // no longer a lie — they've indicated intent to mod this game.
    ensureGameRecipeOnDisk(frame, parent_game) catch |e| {
        log.warn("auto-save game recipe for {d} failed: {s}", .{ parent_game.f95_thread_id, @errorName(e) });
        // Fall through — if save failed, findGameByThread below will
        // still surface the underlying "no recipe" toast.
    };

    // Look up the game recipe id; needed for the output's `for_game`.
    var game_parsed = frame.recipe_repo.findGameByThread(parent_game.f95_thread_id) catch null orelse {
        state.pushToast(.err, "Could not author or load the game's recipe.");
        return;
    };
    defer game_parsed.deinit();

    // Mods are versioned against a CONCRETE install; you can't author
    // a recipe that "applies to game X v0.21" if v0.21 isn't on disk
    // for the user to test against. Refuse upfront so the wizard
    // doesn't open and immediately fail at save with a confusing
    // validator error.
    const installs = frame.lib.listInstalls(parent_game.f95_thread_id) catch blk: {
        // Treat lookup failure same as "no installs" so the toast
        // below explains the user-visible reason rather than a DB
        // error string.
        const empty: []library.Install = &.{};
        break :blk empty;
    };
    defer if (installs.len > 0) frame.lib.freeInstalls(installs);
    if (installs.len == 0) {
        state.pushToast(.err, "Install the base game first — recipes need a target version.");
        return;
    }

    // `return_screen` is captured up front so we never construct a
    // WizardState without a known origin (the field has no default).
    // Open on the install-plan step so the user sees the wrapper-folder
    // checkbox immediately. The new linear wizard treats `.install` as
    // step 1 of 2 (it used to start on `.meta`, which buried the most
    // important decision behind a Next click).
    var w = state_mod.WizardState{ .step = .install, .return_screen = state.screen };

    // Default version to "1.0" so the user doesn't have to type one
    // before saving. They can edit on step 2 if they have a real
    // version number from the modder.
    {
        const default_version = "1.0";
        @memcpy(w.version_buf[0..default_version.len], default_version);
    }
    w.game_thread_id = parent_game.f95_thread_id;

    const id_n = @min(modfile_id.len, w.modfile_id_buf.len);
    @memcpy(w.modfile_id_buf[0..id_n], modfile_id[0..id_n]);
    w.modfile_id_len = id_n;

    const for_game_n = @min(game_parsed.recipe.id.len, w.for_game_buf.len);
    @memcpy(w.for_game_buf[0..for_game_n], game_parsed.recipe.id[0..for_game_n]);
    w.for_game_len = for_game_n;

    // Capture install versions for the meta-page dropdown. listInstalls
    // already returns newest-first, so installs[0] is the default
    // pick (typical "the user wants to mod the build they just
    // installed" case).
    const cap = @min(installs.len, w.install_versions_buf.len);
    var seen: usize = 0;
    var i: usize = 0;
    while (i < cap) : (i += 1) {
        const v = installs[i].version;
        if (v.len == 0) continue;
        // Dedupe — two installs sharing a version (e.g. vanilla +
        // modded) shouldn't produce two identical dropdown rows.
        var dup = false;
        var j: usize = 0;
        while (j < seen) : (j += 1) {
            const prev = w.install_versions_buf[j];
            const prev_end = std.mem.indexOfScalar(u8, &prev, 0) orelse prev.len;
            if (std.mem.eql(u8, prev[0..prev_end], v)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        const n = @min(v.len, w.install_versions_buf[seen].len);
        @memcpy(w.install_versions_buf[seen][0..n], v[0..n]);
        seen += 1;
    }
    w.install_versions_count = seen;
    w.install_versions_pick = 0;

    // Mirror the default pick into the for_game_version_buf so save
    // works even if the user never opens the dropdown.
    if (seen > 0) {
        const v0 = w.install_versions_buf[0];
        const end = std.mem.indexOfScalar(u8, &v0, 0) orelse v0.len;
        const n = @min(end, w.for_game_version_buf.len);
        @memcpy(w.for_game_version_buf[0..n], v0[0..n]);
    }

    // Pre-fill install blocks from the detected preset, if any.
    // Falls back to the "extract . strip 1" generic default when the
    // modfile has no preset attribution (detection failed / no match).
    var prefilled = false;
    const mods = modfilesForGame(frame, parent_game);
    for (mods) |m| {
        if (!std.mem.eql(u8, m.id, modfile_id)) continue;

        // Pre-fill name with the modfile basename (less extension).
        const base = m.filename;
        const stem_end = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
        const stem = base[0..stem_end];
        const stem_n = @min(stem.len, w.name_buf.len);
        @memcpy(w.name_buf[0..stem_n], stem[0..stem_n]);

        if (m.preset_id) |pid| {
            prefilled = prefillWizardBlocksFromPreset(frame, &w, pid);
        }
        break;
    }
    if (!prefilled) {
        // Generic default. Same fall-back the wizard previously hardcoded.
        w.blocks[0] = .{ .kind = .extract };
        const dot_str = ".";
        @memcpy(w.blocks[0].a_buf[0..dot_str.len], dot_str);
        w.blocks[0].strip = 1;
        w.block_count = 1;
    }

    // `return_screen` was set at WizardState construction — see the
    // `var w = …` line above. closeWizard / wizardSave use it to
    // bounce back to the right page.
    state.wizard = w;
    // Navigate to the full-page recipe editor. The modal wizard has
    // been retired — the editor is its own screen so the preview pane
    // can breathe and the user has room to scroll.
    state.screen = .recipe_editor;
}

/// Hydrate the wizard's block list from a saved preset's `install`.
/// Returns true on success (caller skips the generic default).
/// Reasons to return false: preset id not found in the merged set,
/// load failure, or zero install steps to copy.
fn prefillWizardBlocksFromPreset(frame: *Frame, w: *state_mod.WizardState, preset_id: []const u8) bool {
    const alloc = frame.lib.alloc;
    var bundle = recipe.loadMergedPresets(alloc, frame.io, frame.info.mod_presets_dir) catch return false;
    defer bundle.deinit();

    var matched: ?*const recipe.Preset = null;
    for (bundle.presets) |*p| {
        if (std.mem.eql(u8, p.id, preset_id)) {
            matched = p;
            break;
        }
    }
    const preset = matched orelse return false;
    if (preset.install.len == 0) return false;

    var n: usize = 0;
    for (preset.install) |step| {
        if (n >= w.blocks.len) break;
        switch (step) {
            .extract => |x| {
                w.blocks[n] = .{ .kind = .extract, .strip = x.strip };
                copyToBuf(&w.blocks[n].a_buf, x.to);
                n += 1;
            },
            .extract_inner => |x| {
                w.blocks[n] = .{ .kind = .extract_inner, .strip = x.strip };
                copyToBuf(&w.blocks[n].a_buf, x.to);
                copyToBuf(&w.blocks[n].b_buf, x.archive);
                n += 1;
            },
            .copy => |x| {
                w.blocks[n] = .{ .kind = .copy };
                copyToBuf(&w.blocks[n].a_buf, x.src);
                copyToBuf(&w.blocks[n].b_buf, x.dest);
                n += 1;
            },
            .move => |x| {
                w.blocks[n] = .{ .kind = .move };
                copyToBuf(&w.blocks[n].a_buf, x.src);
                copyToBuf(&w.blocks[n].b_buf, x.dest);
                n += 1;
            },
            .delete => |x| {
                w.blocks[n] = .{ .kind = .delete };
                copyToBuf(&w.blocks[n].a_buf, x.path);
                n += 1;
            },
            .chmod_x => |x| {
                // Wizard's block carries one path field; emit one block
                // per path in the preset's chmod_x list.
                for (x.paths) |p| {
                    if (n >= w.blocks.len) break;
                    w.blocks[n] = .{ .kind = .chmod_x };
                    copyToBuf(&w.blocks[n].a_buf, p);
                    n += 1;
                }
            },
        }
    }
    w.block_count = n;
    return n > 0;
}

fn copyToBuf(buf: []u8, src: []const u8) void {
    @memset(buf, 0);
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
}

/// Close + free the wizard. Called on Cancel / after a successful Save.
/// Restores whichever screen the user was on when the editor opened
/// (Mods page, or — as a fallback — Detail).
pub fn closeWizard(frame: *Frame) void {
    const state = frame.state;
    const return_to: state_mod.Screen = if (state.wizard) |*w| w.return_screen else .detail;
    state.wizard = null;
    if (state.screen == .recipe_editor) state.screen = return_to;
}

/// Append a new block to the wizard's install list. Picks a safe
/// default for `a_buf`. Caller should populate fields after.
pub fn wizardAddBlock(frame: *Frame, kind: state_mod.WizardBlockKind) void {
    const w = &(frame.state.wizard orelse return);
    if (w.block_count >= w.blocks.len) return;
    w.blocks[w.block_count] = .{ .kind = kind };
    w.block_count += 1;
}

/// Remove the block at `idx`, shifting subsequent blocks down.
pub fn wizardRemoveBlock(frame: *Frame, idx: usize) void {
    const w = &(frame.state.wizard orelse return);
    if (idx >= w.block_count) return;
    var i: usize = idx;
    while (i + 1 < w.block_count) : (i += 1) {
        w.blocks[i] = w.blocks[i + 1];
    }
    w.block_count -= 1;
}

/// Finalize the wizard: validate, serialize a `.mod.zon`, save it,
/// link the modfile to the new recipe id. On success, closes the
/// wizard and refreshes caches.
pub fn wizardSave(frame: *Frame, parent_game: *const library.Game) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const w = &(state.wizard orelse return);

    // ---- collect text fields ----
    const name_slice = sliceFromBuf(&w.name_buf);
    const version_slice = sliceFromBuf(&w.version_buf);
    const post_url_slice = sliceFromBuf(&w.post_url_buf);
    const for_game_version_slice = sliceFromBuf(&w.for_game_version_buf);
    const for_game_slice = w.for_game_buf[0..w.for_game_len];
    const modfile_id_slice = w.modfile_id_buf[0..w.modfile_id_len];

    if (name_slice.len == 0 or version_slice.len == 0) {
        setWizardErr(w, "Name and Version are required.");
        return;
    }

    // ---- derive recipe id from name (lowercased, hyphenated) ----
    var id_buf: [128]u8 = undefined;
    const recipe_id = slugifyRecipeId(&id_buf, name_slice);

    // ---- parse f95_thread from post URL if possible ----
    const f95_thread = parseF95Thread(post_url_slice);

    // ---- build install steps from blocks ----
    var steps: std.ArrayList(recipe.InstallStep) = .empty;
    defer steps.deinit(alloc);
    // Defer the chmod_x.paths free BEFORE the loop so a mid-loop
    // failure still runs it. (Previously declared after the loop —
    // if `append` failed on iteration N>0 the prior chmod_x paths
    // would leak.)
    defer for (steps.items) |s| switch (s) {
        .chmod_x => |x| alloc.free(x.paths),
        else => {},
    };
    var i: usize = 0;
    while (i < w.block_count) : (i += 1) {
        // Pointer into the wizard's heap-allocated state so the
        // slices we build remain valid through saveMod. Capturing by
        // value (`const b = w.blocks[i]`) would put a_buf/b_buf on
        // the iteration stack, and the slices into them would dangle
        // after the iteration ends.
        const b = &w.blocks[i];
        const a = sliceFromBuf(&b.a_buf);
        const b_s = sliceFromBuf(&b.b_buf);
        const step: recipe.InstallStep = switch (b.kind) {
            .extract => .{ .extract = .{ .to = a, .strip = b.strip } },
            .extract_inner => .{ .extract_inner = .{ .archive = a, .to = b_s, .strip = b.strip } },
            .copy => .{ .copy = .{ .src = a, .dest = b_s } },
            .move => .{ .move = .{ .src = a, .dest = b_s } },
            .delete => .{ .delete = .{ .path = a } },
            .chmod_x => blk: {
                const paths_arr = alloc.alloc([]const u8, 1) catch return setWizardErr(w, "Out of memory.");
                paths_arr[0] = a;
                break :blk .{ .chmod_x = .{ .paths = paths_arr } };
            },
        };
        steps.append(alloc, step) catch {
            // append failed — clean up the just-built step's payload
            // (only chmod_x carries an alloc'd slice).
            switch (step) {
                .chmod_x => |x| alloc.free(x.paths),
                else => {},
            }
            return setWizardErr(w, "Out of memory.");
        };
    }

    // ---- build relations slices ----
    const requires = buildRelations(alloc, w.requires_buf[0..w.requires_len]) catch return setWizardErr(w, "Out of memory.");
    defer alloc.free(requires);
    const conflicts = buildStringList(alloc, w.conflicts_buf[0..w.conflicts_len]) catch return setWizardErr(w, "Out of memory.");
    defer alloc.free(conflicts);
    const load_after = buildStringList(alloc, w.load_after_buf[0..w.load_after_len]) catch return setWizardErr(w, "Out of memory.");
    defer alloc.free(load_after);

    // ---- assemble + validate ----
    const mod = recipe.ModRecipe{
        .id = recipe_id,
        .name = name_slice,
        .f95_thread = f95_thread,
        .post_url = if (post_url_slice.len > 0) post_url_slice else null,
        .version = version_slice,
        .for_game = for_game_slice,
        .for_game_version = if (for_game_version_slice.len > 0) for_game_version_slice else null,
        .requires = requires,
        .conflicts = conflicts,
        .load_after = load_after,
        .install = steps.items,
    };
    const validate_recipe: recipe.Recipe = .{ .mod = mod };
    recipe.validate(&validate_recipe) catch |e| {
        var buf: [240]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Validator: {s}", .{@errorName(e)}) catch "Validator failed.";
        return setWizardErr(w, msg);
    };

    // ---- save .mod.zon ----
    frame.recipe_repo.saveMod(&mod) catch |e| {
        var buf: [240]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Save failed: {s}", .{@errorName(e)}) catch "Save failed.";
        return setWizardErr(w, msg);
    };

    // ---- link modfile → recipe ----
    installer_mod.mod_archives.linkRecipe(
        alloc,
        frame.io,
        frame.info.mod_archives_dir,
        parent_game.f95_thread_id,
        modfile_id_slice,
        recipe_id,
    ) catch |e| {
        var buf: [240]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Link failed: {s}", .{@errorName(e)}) catch "Link failed.";
        return setWizardErr(w, msg);
    };

    state.setDownloadMsg("Recipe saved + linked.");
    refreshModfileCache(frame, parent_game);
    closeWizard(frame);
}

fn setWizardErr(w: *state_mod.WizardState, msg: []const u8) void {
    const n = @min(msg.len, w.err_msg_buf.len);
    @memcpy(w.err_msg_buf[0..n], msg[0..n]);
    w.err_msg_len = n;
}

pub fn sliceFromBuf(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return std.mem.trim(u8, buf[0..end], " \t\r\n");
}

/// "Some Mod V1.2!" → "some-mod-v1-2". Output written into `out`; the
/// returned slice borrows from it.
fn slugifyRecipeId(out: []u8, input: []const u8) []const u8 {
    var w: usize = 0;
    var prev_dash = true; // suppress leading dashes
    for (input) |c| {
        if (w >= out.len) break;
        const lower = std.ascii.toLower(c);
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) {
            out[w] = lower;
            w += 1;
            prev_dash = false;
        } else if (!prev_dash) {
            out[w] = '-';
            w += 1;
            prev_dash = true;
        }
    }
    // Trim trailing dash.
    while (w > 0 and out[w - 1] == '-') : (w -= 1) {}
    if (w == 0) {
        const fallback = "mod";
        const n = @min(fallback.len, out.len);
        @memcpy(out[0..n], fallback[0..n]);
        return out[0..n];
    }
    return out[0..w];
}

/// Pull the F95 thread id out of a thread URL. Returns 0 when no
/// id-looking segment is found.
fn parseF95Thread(url: []const u8) u64 {
    // F95 thread URLs end in `.<thread_id>/...`. Walk segments and
    // pick the last numeric one as the thread id.
    var best: u64 = 0;
    var it = std.mem.tokenizeAny(u8, url, "/.?#&");
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        const n = std.fmt.parseUnsigned(u64, seg, 10) catch continue;
        best = n;
    }
    return best;
}

fn buildRelations(alloc: std.mem.Allocator, raw: []const [64]u8) ![]const recipe.ModConstraint {
    const out = try alloc.alloc(recipe.ModConstraint, raw.len);
    // Capture by reference — `buf` as a value copy would live only
    // for the iteration, and the slices we hand into the recipe must
    // outlive the loop. Pointing at `raw[i]` (caller-owned, lives on
    // the wizard state heap) is safe through saveMod.
    for (raw, 0..) |*buf, i| {
        const s = sliceFromBuf(buf);
        out[i] = .{ .target = s };
    }
    return out;
}

fn buildStringList(alloc: std.mem.Allocator, raw: []const [64]u8) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, raw.len);
    for (raw, 0..) |*buf, i| {
        out[i] = sliceFromBuf(buf);
    }
    return out;
}

// ---- tests (moved from bookmarks.zig) ----

test "slugifyRecipeId: lowercases + hyphenates" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("some-mod-v1-2", slugifyRecipeId(&out, "Some Mod V1.2"));
    try std.testing.expectEqualStrings("ren-py-mod-loader", slugifyRecipeId(&out, "Ren'Py Mod Loader"));
    try std.testing.expectEqualStrings("mod", slugifyRecipeId(&out, "!!!"));
    try std.testing.expectEqualStrings("a-b-c", slugifyRecipeId(&out, "  a    b\nc  "));
}

test "parseF95Thread: picks the last all-numeric segment" {
    try std.testing.expectEqual(@as(u64, 0), parseF95Thread(""));
    try std.testing.expectEqual(@as(u64, 0), parseF95Thread("https://example.com/mods/cool"));
    // `/post-12345` keeps the dash in-token; parseUnsigned skips it,
    // so the thread id (`123`) is correctly returned.
    try std.testing.expectEqual(
        @as(u64, 123),
        parseF95Thread("https://f95zone.to/threads/summertime-saga.123/post-12345"),
    );
    try std.testing.expectEqual(
        @as(u64, 123),
        parseF95Thread("https://f95zone.to/threads/summertime-saga.123/"),
    );
}
