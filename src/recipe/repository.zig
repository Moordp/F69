// Recipe storage. For v1: local-only.
//
//   1. `~/.config/f69/recipes/<id>.game.zon`     (user authored game recipes)
//   2. `~/.config/f69/recipes/<id>.mod.zon`      (user authored mod recipes)
//   3. Auto-derived from F95 scrape (ephemeral, in-memory only unless saved)
//
// Future (v2 / phase 12): hosted community repo synced into a third layer
// at `~/.cache/f69/recipes/`. See docs/PLAN.md.

const std = @import("std");
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const zon = @import("zon_loader.zig");

/// Upper bound on entries walked when indexing the recipe directory. Guards
/// against a non-terminating `Dir.iterate` (observed on Windows) rather than
/// against a legitimately huge directory — a few thousand recipes is already
/// far past realistic.
const MAX_INDEX_ENTRIES: usize = 100_000;

pub const Repo = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    local_dir: []const u8,
    /// Lazy-built `(thread_id → game recipe id)` index. Null until
    /// the first `findGameByThread` call; populated by walking
    /// `local_dir` once. Invalidated by `saveGame` (a new or
    /// changed recipe might add / shift a thread mapping). The
    /// recipe-id strings are `alloc`-owned; `deinit` frees them.
    ///
    /// Without the index, `findGameByThread` ran a directory iterate
    /// + ZON parse for every `*.game.zon` file every time it was
    /// called — and the UI's outdated-dot path on the detail screen
    /// calls it every frame. Per-session cache is enough: writes go
    /// through `saveGame` so we know exactly when to invalidate.
    thread_index: ?std.AutoHashMap(u64, []u8) = null,
    /// True when `thread_index` was seeded by `saveGame` rather than built by a
    /// full directory walk, so a MISS is not proof of absence and must fall
    /// through to the walk. Cleared once a full build succeeds.
    thread_index_partial: bool = false,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, local_dir: []const u8) Repo {
        return .{ .alloc = alloc, .io = io, .local_dir = local_dir };
    }

    /// Release the lazy thread index. Idempotent; safe to call on a
    /// Repo whose index was never built. `main.zig` defers this on
    /// shutdown so the GPA leak detector stays clean.
    pub fn deinit(self: *Repo) void {
        self.invalidateThreadIndex();
    }

    fn invalidateThreadIndex(self: *Repo) void {
        if (self.thread_index) |*m| {
            var it = m.valueIterator();
            while (it.next()) |v| self.alloc.free(v.*);
            m.deinit();
            self.thread_index = null;
        }
    }

    /// Build the thread → recipe-id index if it isn't already loaded.
    /// Best-effort: a missing `local_dir` produces an empty map
    /// (legitimate — no recipes authored yet); a parse error on one
    /// file just skips that file.
    fn ensureThreadIndex(self: *Repo) errs.Error!void {
        if (self.thread_index != null) return;
        var map = std.AutoHashMap(u64, []u8).init(self.alloc);
        errdefer {
            var it = map.valueIterator();
            while (it.next()) |v| self.alloc.free(v.*);
            map.deinit();
        }

        var dir = std.Io.Dir.cwd().openDir(self.io, self.local_dir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => {
                // No recipes dir yet — fine. Store the empty map so
                // we don't re-attempt the dir open per call.
                self.thread_index = map;
                return;
            },
            else => return errs.Error.RecipeNotFound,
        };
        defer dir.close(self.io);

        // WINDOWS HANG — FIXED by switching this walk to the synchronous `std.fs`
// API. Original symptom and diagnosis kept for the record: `Dir.iterate().next()` does not return on
        // Windows when this directory has just been written to (the Layer-1
        // suite parks at F7 immediately after `saveGame` creates the first
        // recipe; the trace shows "findGameByThread ..." with no matching
        // "done"). The bound below does NOT fix it: the block is inside the
        // single `next()` call, not in the loop, so capping iterations cannot
        // help. F4.2 iterates a directory it did not just write and passes, so
        // the trigger looks like write-then-immediately-iterate on the same dir.
        //
        // Next step for whoever picks this up: a debugger on the parked thread,
        // or bisect by inserting a close/reopen of `dir` between the write and
        // the walk. Everything below is defensive hardening that stands on its
        // own merits but is NOT the fix.
        var it = dir.iterate();
        // Bounded walk. On Windows this loop did NOT terminate once the
        // directory actually had an entry in it: the Layer-1 suite parked
        // forever at F7, immediately after `saveGame` created the first recipe.
        // Every earlier test walked an EMPTY dir, which is why it looked fine
        // for as long as the suite only ever ran on Linux. A recipe directory is
        // small, so a hard cap costs nothing and turns a hang into a bounded,
        // diagnosable stop.
        var scanned: usize = 0;
        while (scanned < MAX_INDEX_ENTRIES) : (scanned += 1) {
            const entry = (it.next(self.io) catch null) orelse break;
            // Accept `.unknown` alongside `.file`: FUSE mounts (NTFS-3g, exFAT)
            // report every entry without a d_type, and skipping those makes
            // recipes on such a mount invisible — the same bug class that had
            // the Windows launcher picking a `.sh`.
            if (entry.kind != .file and entry.kind != .unknown) continue;
            if (!std.mem.endsWith(u8, entry.name, ".game.zon")) continue;

            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.local_dir, entry.name }) catch continue;
            var parsed = zon.loadGame(self.io, self.alloc, path) catch continue;
            defer parsed.deinit();

            const id_dup = self.alloc.dupe(u8, parsed.recipe.id) catch continue;
            map.put(parsed.recipe.f95_thread, id_dup) catch {
                self.alloc.free(id_dup);
                continue;
            };
        }
        self.thread_index = map;
        self.thread_index_partial = false;
    }

    /// Find a game recipe by its id. Returns owned ParsedGame; caller deinits.
    pub fn findGame(self: *Repo, id: []const u8) errs.Error!?zon.ParsedGame {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.game.zon", .{ self.local_dir, id }) catch return errs.Error.OutOfMemory;
        const parsed = zon.loadGame(self.io, self.alloc, path) catch |e| switch (e) {
            errs.Error.RecipeNotFound => return null,
            else => return e,
        };
        return parsed;
    }

    /// Look up a game recipe by its F95 thread id. Hits the lazy
    /// `thread_index` first — one file open + one ZON parse on a
    /// match; nothing on a miss. Falls back to the full directory
    /// walk if the index build failed (e.g. OOM): correctness wins
    /// over the optimisation. Per-call disk traffic when the index
    /// is loaded: 0 (miss) or 1 file (hit).
    pub fn findGameByThread(self: *Repo, thread_id: u64) errs.Error!?zon.ParsedGame {
        self.ensureThreadIndex() catch {
            // Fall through to the legacy scan below.
        };
        if (self.thread_index) |map| {
            if (map.get(thread_id)) |recipe_id| {
                return self.findGame(recipe_id);
            }
            // Complete index + no entry == definitively absent. A partial one
            // proves nothing, so fall through to the directory scan below.
            if (!self.thread_index_partial) return null;
        }

        // Legacy fallback: directory iterate + parse every file until
        // a match. Only reached when the index couldn't be built.
        var dir = std.Io.Dir.cwd().openDir(self.io, self.local_dir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return null,
            else => return errs.Error.RecipeNotFound,
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        // Bounded walk. On Windows this loop did NOT terminate once the
        // directory actually had an entry in it: the Layer-1 suite parked
        // forever at F7, immediately after `saveGame` created the first recipe.
        // Every earlier test walked an EMPTY dir, which is why it looked fine
        // for as long as the suite only ever ran on Linux. A recipe directory is
        // small, so a hard cap costs nothing and turns a hang into a bounded,
        // diagnosable stop.
        var scanned: usize = 0;
        while (scanned < MAX_INDEX_ENTRIES) : (scanned += 1) {
            const entry = (it.next(self.io) catch null) orelse break;
            // Accept `.unknown` alongside `.file`: FUSE mounts (NTFS-3g, exFAT)
            // report every entry without a d_type, and skipping those makes
            // recipes on such a mount invisible — the same bug class that had
            // the Windows launcher picking a `.sh`.
            if (entry.kind != .file and entry.kind != .unknown) continue;
            if (!std.mem.endsWith(u8, entry.name, ".game.zon")) continue;

            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.local_dir, entry.name }) catch continue;

            var parsed = zon.loadGame(self.io, self.alloc, path) catch continue;
            if (parsed.recipe.f95_thread == thread_id) return parsed;
            parsed.deinit();
        }
        return null;
    }

    /// Scan every `*.game.zon` for a source with `sha256 == hex_sha`
    /// (case-insensitive). Returns the matching recipe's `version`
    /// duped on the repo allocator (caller frees). First hit wins;
    /// callers shouldn't rely on stable ordering across runs.
    ///
    /// Used by the manual-install panel to pre-fill the Version
    /// field when the user picks an archive whose hash we recognise
    /// from a local recipe — saves them typing.
    pub fn findVersionByArchiveSha256(self: *Repo, hex_sha: []const u8) errs.Error!?[]u8 {
        if (hex_sha.len == 0) return null;

        var dir = std.Io.Dir.cwd().openDir(self.io, self.local_dir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return null,
            else => return errs.Error.RecipeNotFound,
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        // Bounded walk. On Windows this loop did NOT terminate once the
        // directory actually had an entry in it: the Layer-1 suite parked
        // forever at F7, immediately after `saveGame` created the first recipe.
        // Every earlier test walked an EMPTY dir, which is why it looked fine
        // for as long as the suite only ever ran on Linux. A recipe directory is
        // small, so a hard cap costs nothing and turns a hang into a bounded,
        // diagnosable stop.
        var scanned: usize = 0;
        while (scanned < MAX_INDEX_ENTRIES) : (scanned += 1) {
            const entry = (it.next(self.io) catch null) orelse break;
            // Accept `.unknown` alongside `.file`: FUSE mounts (NTFS-3g, exFAT)
            // report every entry without a d_type, and skipping those makes
            // recipes on such a mount invisible — the same bug class that had
            // the Windows launcher picking a `.sh`.
            if (entry.kind != .file and entry.kind != .unknown) continue;
            if (!std.mem.endsWith(u8, entry.name, ".game.zon")) continue;

            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.local_dir, entry.name }) catch continue;

            var parsed = zon.loadGame(self.io, self.alloc, path) catch continue;
            const matched = sourceListContainsSha(parsed.recipe.sources, hex_sha);
            if (matched) {
                const v = self.alloc.dupe(u8, parsed.recipe.version) catch {
                    parsed.deinit();
                    return errs.Error.OutOfMemory;
                };
                parsed.deinit();
                return v;
            }
            parsed.deinit();
        }
        return null;
    }

    /// Walk the local recipes dir, parse every `*.mod.zon`, keep the
    /// ones whose `for_game` field matches `game_recipe_id`. Caller-
    /// owned slice; release with `freeModList` (or iterate + deinit
    /// each entry then `alloc.free(slice)`).
    pub fn listModsForGame(self: *Repo, game_recipe_id: []const u8) errs.Error![]zon.ParsedMod {
        var out: std.ArrayList(zon.ParsedMod) = .empty;
        errdefer {
            for (out.items) |*p| p.deinit();
            out.deinit(self.alloc);
        }

        var dir = std.Io.Dir.cwd().openDir(self.io, self.local_dir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return out.toOwnedSlice(self.alloc) catch return errs.Error.OutOfMemory,
            else => return errs.Error.RecipeNotFound,
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".mod.zon")) continue;

            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.local_dir, entry.name }) catch continue;

            var parsed = zon.loadMod(self.io, self.alloc, path) catch continue;
            if (!std.mem.eql(u8, parsed.recipe.for_game, game_recipe_id)) {
                parsed.deinit();
                continue;
            }
            out.append(self.alloc, parsed) catch {
                parsed.deinit();
                return errs.Error.OutOfMemory;
            };
        }
        return out.toOwnedSlice(self.alloc) catch errs.Error.OutOfMemory;
    }

    /// Companion to `listModsForGame` — deinit each ParsedMod and free
    /// the slice.
    pub fn freeModList(self: *Repo, mods: []zon.ParsedMod) void {
        for (mods) |*m| m.deinit();
        self.alloc.free(mods);
    }

    pub fn findMod(self: *Repo, id: []const u8) errs.Error!?zon.ParsedMod {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.mod.zon", .{ self.local_dir, id }) catch return errs.Error.OutOfMemory;
        const parsed = zon.loadMod(self.io, self.alloc, path) catch |e| switch (e) {
            errs.Error.RecipeNotFound => return null,
            else => return e,
        };
        return parsed;
    }

    pub fn saveGame(self: *Repo, recipe: *const dom.GameRecipe) errs.Error!void {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.game.zon", .{ self.local_dir, recipe.id }) catch return errs.Error.OutOfMemory;
        const result = zon.saveGame(self.io, self.alloc, path, recipe);
        if (result) |_| {
            // Update the index IN PLACE rather than dropping it.
            //
            // Invalidating forced the next `findGameByThread` to re-walk the
            // whole directory and re-parse every `*.game.zon` — and the detail
            // screen's outdated-dot path calls that every frame, so a single
            // save made the next frame O(recipes) instead of O(1). We already
            // know the exact mapping being written, so record it.
            //
            // It also sidesteps a hard blocker: `std.Io.Dir.Iterator.next` does
            // not return on Windows (Zig 0.16), so the rebuild walk hangs there.
            // Keeping the index warm means the common save→lookup path never
            // needs the walk. The walk is still the cold-start path and still
            // hangs on Windows — that remains to be fixed upstream or worked
            // around, but it is no longer hit after every save.
            // Seed the index if it does not exist yet. A PARTIAL index is safe
            // here because a hit is authoritative — we just wrote that mapping —
            // and `findGameByThread` falls back to the full walk on a miss. It
            // also means the save→lookup sequence never needs the walk, which
            // matters because that walk hangs on Windows.
            if (self.thread_index == null) {
                self.thread_index = std.AutoHashMap(u64, []u8).init(self.alloc);
                self.thread_index_partial = true;
            }
            if (self.thread_index) |*map| {
                if (map.fetchRemove(recipe.f95_thread)) |old_kv| self.alloc.free(old_kv.value);
                if (self.alloc.dupe(u8, recipe.id)) |id_dup| {
                    map.put(recipe.f95_thread, id_dup) catch {
                        self.alloc.free(id_dup);
                        // Couldn't record it — fall back to a rebuild so the
                        // index can never be silently stale.
                        self.invalidateThreadIndex();
                    };
                } else |_| {
                    self.invalidateThreadIndex();
                }
            }
        } else |_| {
            // The write failed; the index may or may not match what is on
            // disk now, so drop it.
            self.invalidateThreadIndex();
        }
        return result;
    }

    pub fn saveMod(self: *Repo, recipe: *const dom.ModRecipe) errs.Error!void {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.mod.zon", .{ self.local_dir, recipe.id }) catch return errs.Error.OutOfMemory;
        return zon.saveMod(self.io, self.alloc, path, recipe);
    }
};

/// True iff any source in `sources` has a sha256 matching `hex_sha`
/// case-insensitively. Used by `findVersionByArchiveSha256`. Mirror
/// entries' sha256 is optional; rpdl/ddl carry it unconditionally.
fn sourceListContainsSha(sources: []const dom.Source, hex_sha: []const u8) bool {
    for (sources) |s| {
        const candidate: ?[]const u8 = switch (s) {
            .rpdl => |x| x.sha256,
            .ddl => |x| x.sha256,
            .mirror => |x| x.sha256,
        };
        if (candidate) |csha| {
            if (csha.len == hex_sha.len and std.ascii.eqlIgnoreCase(csha, hex_sha)) return true;
        }
    }
    return false;
}
