// Cross-domain helpers shared between the per-domain action modules.
// After R9 the original `src/ui/actions.zig` was split into ten
// per-domain files; whatever didn't fit cleanly into one bucket landed
// here. Contents:
//
//   - `cancelAllWorkers` / `workersBusy` — global worker shutdown +
//     liveness probe.
//   - `installedSetPtr` / `refreshInstalledSet` / `isInstalled` /
//     `retryDownload` / `installDotState` / `freeInstalledSet` —
//     installed-set + download-retry glue between installer.zig and
//     downloads.zig.
//   - `attemptsMap` / `resetAttempt` — per-game download-attempt
//     counter, shared by downloads.zig and installer.zig.
//   - Settings persistence + browser launch — every dirty-flag
//     debounced disk write pre-R9 lived here; no single domain owns
//     "settings".
//   - `persistTextFile`, `friendlyError` — file-private helpers used
//     across sync.zig / imports.zig / tags.zig / bookmarks.zig /
//     auth.zig.
//   - `exeExistsUnder` / `freePostInstalled` — orphan tear-down
//     helpers that touch state owned by three domains.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.ui_actions);
const library = @import("library");
const version_mod = @import("util_version");
const types = @import("../types.zig");
const owned_types = @import("../owned.zig");

const Frame = types.Frame;
const State = types.State;

const InstalledSet = owned_types.InstalledSet;
const AttemptsMap = owned_types.AttemptsMap;

// Imports of sibling action modules. Routed through pointers-to-pubs
// so the explicit cross-file calls below resolve.
const sync_mod = @import("sync.zig");
const downloads_mod = @import("downloads.zig");
const installer_mod = @import("installer.zig");
const imports_mod = @import("imports.zig");
const launch_mod = @import("launch.zig");

/// Flip the cancel flag on every in-flight worker. Used by the
/// graceful-shutdown path to nudge detached workers toward their
/// next phase boundary so the HTTP client + DB can be torn down
/// cleanly. Idempotent. Every slot listed in `workersBusy` below
/// MUST also flip its cancel flag here, otherwise the shutdown
/// spin loop will time out on a worker that nobody asked to stop.
pub fn cancelAllWorkers(state: *types.State) void {
    for (state.active_syncs) |maybe_slot| {
        if (maybe_slot) |j| j.cancel.store(true, .release);
    }
    if (state.pending_fast_check) |j| j.cancel.store(true, .release);
    // Phase-2 image worker: shared cancel flag covers both the active
    // job and any tids still queued.
    state.image_cancel.store(true, .release);
    if (state.pending_bookmarks) |j| j.cancel.store(true, .release);
    if (state.pending_update_check) |j| j.cancel.store(true, .release);
    if (state.pending_rpdl_download) |j| j.cancel.store(true, .release);
    if (state.pending_donor_download) |j| j.cancel.store(true, .release);
    if (state.pending_tags_refresh) |j| j.cancel.store(true, .release);
    if (state.donor_probe_job) |j| j.cancel.store(true, .release);
    if (state.slide_load_job) |j| j.cancel.store(true, .release);
    if (state.launch_watch_job) |j| j.cancel.store(true, .release);
    if (state.test_install_job) |j| j.cancel.store(true, .release);
    if (state.import_job) |j| j.cancel.store(true, .release);
    if (state.folder_import_job) |j| j.cancel.store(true, .release);
}

/// True when any async worker is still occupying its state slot.
/// The graceful-shutdown loop spins on this until everything clears
/// (with a 6s budget; if it expires, the process hard-exits and the
/// OS reaps anything left).
///
/// Every long-running worker slot on `State` MUST be listed here.
/// If a slot is missed, `workersBusy` returns false while the worker
/// thread is still mid-syscall → the defer chain in `runMainLoop`
/// races `f95_client.deinit` against the worker's next HTTP call →
/// UAF. The companion `cancelAllWorkers` must cover every slot too.
pub fn workersBusy(state: *const types.State) bool {
    if (state.anyActiveSync()) return true;
    if (state.pending_fast_check != null) return true;
    if (state.anyActiveImage()) return true;
    if (state.image_queue != null and state.image_queue_head < state.image_queue_len) return true;
    if (state.pending_bookmarks != null) return true;
    if (state.pending_update_check != null) return true;
    if (state.pending_rpdl_download != null) return true;
    if (state.pending_donor_download != null) return true;
    if (state.pending_tags_refresh != null) return true;
    if (state.donor_probe_job != null) return true;
    if (state.slide_load_job != null) return true;
    if (state.launch_watch_job != null) return true;
    if (state.test_install_job != null) return true;
    if (state.import_job != null) return true;
    if (state.folder_import_job != null) return true;
    if (state.post_install_jobs) |list_ptr| {
        if (list_ptr.items.len > 0) return true;
    }
    if (installer_mod.manualInstallsRunning(state)) return true;
    return false;
}

// ============================================================
//  open thread in system browser — non-blocking
// ============================================================

const BrowserJob = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    exe: []u8,
    url: []u8,
};

pub fn openInBrowser(frame: *Frame, thread_id: u64) void {
    const alloc = frame.lib.alloc;
    const io = frame.io;

    // Resolve the browser executable from the user's saved choice.
    // Falls back to "xdg-open" if the saved path is empty (first run
    // before they touched Settings).
    const chosen = frame.state.browserPathSlice();
    const exe_src: []const u8 = if (chosen.len == 0) "xdg-open" else chosen;

    const job = alloc.create(BrowserJob) catch return;
    var url_buf: [128]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://f95zone.to/threads/{d}/", .{thread_id}) catch {
        alloc.destroy(job);
        return;
    };
    const url_owned = alloc.dupe(u8, url) catch {
        alloc.destroy(job);
        return;
    };
    const exe_owned = alloc.dupe(u8, exe_src) catch {
        alloc.free(url_owned);
        alloc.destroy(job);
        return;
    };
    job.* = .{ .alloc = alloc, .io = io, .exe = exe_owned, .url = url_owned };

    const thr = std.Thread.spawn(.{}, browserWorker, .{job}) catch {
        alloc.free(exe_owned);
        alloc.free(url_owned);
        alloc.destroy(job);
        return;
    };
    thr.detach();
}

/// Open an arbitrary URL in the user's chosen browser. Same fire-and-
/// forget worker as `openInBrowser`, but the URL is provided directly
/// rather than synthesised from a thread id. Used by the Downloads
/// tab's per-link "Open" button.
pub fn openExternalUrl(frame: *Frame, url: []const u8) void {
    const alloc = frame.lib.alloc;
    const io = frame.io;

    const chosen = frame.state.browserPathSlice();
    const exe_src: []const u8 = if (chosen.len == 0) "xdg-open" else chosen;

    const job = alloc.create(BrowserJob) catch return;
    const url_owned = alloc.dupe(u8, url) catch {
        alloc.destroy(job);
        return;
    };
    const exe_owned = alloc.dupe(u8, exe_src) catch {
        alloc.free(url_owned);
        alloc.destroy(job);
        return;
    };
    job.* = .{ .alloc = alloc, .io = io, .exe = exe_owned, .url = url_owned };

    const thr = std.Thread.spawn(.{}, browserWorker, .{job}) catch {
        alloc.free(exe_owned);
        alloc.free(url_owned);
        alloc.destroy(job);
        return;
    };
    thr.detach();
}

fn browserWorker(job: *BrowserJob) void {
    defer {
        job.alloc.free(job.exe);
        job.alloc.free(job.url);
        job.alloc.destroy(job);
    }
    var argv_buf: [5][]const u8 = undefined;
    if (external_open_hook.active) {
        external_open_hook.record(job.url);
        return;
    }
    const argv = systemOpenArgv(job.exe, job.url, &argv_buf);
    var child = std.process.spawn(job.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(job.io) catch {};
}

/// Build the argv to open `target` (a URL or filesystem path). When
/// `custom_exe` is a real user-chosen browser/opener it's used verbatim
/// (`{exe, target}`); the sentinel "xdg-open" (the cross-platform default)
/// and the empty string both map to the OS's native opener instead —
/// Windows `cmd /c start "" <t>`, macOS `open <t>`, Linux `xdg-open <t>`.
/// Without this, every open-in-external-app action spawned a literal
/// `xdg-open` that doesn't exist on Windows/macOS. `buf` backs the result.

// --- external-open test seam ---------------------------------------------
// Opening a URL or a folder spawns a REAL browser / file manager. In an
// automated flow that leaks processes onto the test machine and asserts
// nothing. When active, the spawn is skipped and the target is RECORDED
// instead, so a flow can assert "clicking Open folder would have opened
// exactly this path" — coverage rather than a silenced no-op.
//
// Inactive in production: one bool check.
pub const external_open_hook = struct {
    pub var active: bool = false;
    var buf: [16][256]u8 = undefined;
    var lens: [16]usize = @splat(0);
    pub var count: usize = 0;

    pub fn install() void {
        active = true;
        count = 0;
    }
    pub fn reset() void {
        active = false;
        count = 0;
    }
    pub fn record(target: []const u8) void {
        if (count >= buf.len) return;
        const n = @min(target.len, buf[count].len);
        @memcpy(buf[count][0..n], target[0..n]);
        lens[count] = n;
        count += 1;
    }
    /// Targets recorded so far, oldest first.
    pub fn get(i: usize) []const u8 {
        if (i >= count) return "";
        return buf[i][0..lens[i]];
    }
    pub fn sawTarget(needle: []const u8) bool {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (std.mem.indexOf(u8, get(i), needle) != null) return true;
        }
        return false;
    }
};

pub fn systemOpenArgv(custom_exe: []const u8, target: []const u8, buf: *[5][]const u8) []const []const u8 {
    const use_default = custom_exe.len == 0 or std.mem.eql(u8, custom_exe, "xdg-open");
    if (!use_default) {
        buf[0] = custom_exe;
        buf[1] = target;
        return buf[0..2];
    }
    switch (builtin.os.tag) {
        .windows => {
            // `start` treats its first quoted arg as a window title, so pass
            // an empty title before the target (works for URLs and folders).
            buf[0] = "cmd";
            buf[1] = "/c";
            buf[2] = "start";
            buf[3] = "";
            buf[4] = target;
            return buf[0..5];
        },
        .macos => {
            buf[0] = "open";
            buf[1] = target;
            return buf[0..2];
        },
        else => {
            buf[0] = "xdg-open";
            buf[1] = target;
            return buf[0..2];
        },
    }
}

// ============================================================
//  Guides: walkthroughs / PDFs / EPUBs / HTML files the user
//  drops onto a game. Stored under
//  `<library_root>/<thread_id>/guides/<original-filename>`.
//  No DB row — the directory IS the source of truth. CRUD:
//    - add:    file picker → copy into the guides dir
//    - list:   walked on demand by `listGuides`
//    - open:   reuses `openExternalUrl` to invoke xdg-open
//    - remove: delete the file from disk
// ============================================================

/// Absolute path to the guides directory for one game. Allocator-
/// owned; caller frees.
pub fn guidesDirFor(alloc: std.mem.Allocator, library_root: []const u8, thread_id: u64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{d}/guides", .{ library_root, thread_id });
}

/// Show a file picker, copy the chosen file into the game's guides
/// dir. Idempotent on the source side (file is left intact on disk).
/// On conflict (same filename already present), the new file is
/// stored with a numeric suffix `name (2).pdf`.
pub fn addGuideForGame(frame: *Frame, thread_id: u64) void {
    const alloc = frame.lib.alloc;
    const file_picker = @import("util_file_picker");
    const picked = file_picker.open(alloc, &[_]file_picker.FilterItem{
        .{ .name = "Documents", .spec = "pdf,epub,html,htm,txt,md,docx,odt" },
        .{ .name = "All files", .spec = "" },
    }, null) catch |e| {
        var buf: [192]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "Pick failed: {s}", .{@errorName(e)}) catch "Pick failed";
        frame.state.pushToast(.err, m);
        return;
    };
    const src_path = picked orelse return;
    defer alloc.free(src_path);

    const guides_dir = guidesDirFor(alloc, frame.info.library_root, thread_id) catch return;
    defer alloc.free(guides_dir);
    std.Io.Dir.cwd().createDirPath(frame.io, guides_dir) catch |e| {
        var buf: [192]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "Guides dir create failed: {s}", .{@errorName(e)}) catch "Guides dir create failed";
        frame.state.pushToast(.err, m);
        return;
    };

    // Find a unique destination filename.
    const base = std.fs.path.basename(src_path);
    const dst_path = uniqueGuidePath(alloc, frame.io, guides_dir, base) catch return;
    defer alloc.free(dst_path);

    copyFile(frame.io, src_path, dst_path) catch |e| {
        var buf: [256]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "Guide copy failed: {s}", .{@errorName(e)}) catch "Guide copy failed";
        frame.state.pushToast(.err, m);
        return;
    };
    var ok_buf: [128]u8 = undefined;
    const ok = std.fmt.bufPrint(&ok_buf, "Added: {s}", .{base}) catch "Guide added";
    frame.state.pushToast(.info, ok);
}

/// Open one guide via the user's external app (xdg-open by default).
pub fn openGuide(frame: *Frame, thread_id: u64, filename: []const u8) void {
    const alloc = frame.lib.alloc;
    const guides_dir = guidesDirFor(alloc, frame.info.library_root, thread_id) catch return;
    defer alloc.free(guides_dir);
    const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ guides_dir, filename }) catch return;
    defer alloc.free(full);
    openExternalUrl(frame, full);
}

/// Remove one guide. Best-effort; logs a toast on failure.
pub fn removeGuide(frame: *Frame, thread_id: u64, filename: []const u8) void {
    const alloc = frame.lib.alloc;
    const guides_dir = guidesDirFor(alloc, frame.info.library_root, thread_id) catch return;
    defer alloc.free(guides_dir);
    const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ guides_dir, filename }) catch return;
    defer alloc.free(full);
    std.Io.Dir.cwd().deleteFile(frame.io, full) catch |e| {
        var buf: [192]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "Guide delete failed: {s}", .{@errorName(e)}) catch "Guide delete failed";
        frame.state.pushToast(.err, m);
        return;
    };
}

/// Pick a unique destination path inside `guides_dir`. If `<dir>/<base>`
/// is free, returns it as-is; otherwise appends ` (2)`, ` (3)`, … to
/// the stem until a free slot is found. Returns allocator-owned path.
fn uniqueGuidePath(alloc: std.mem.Allocator, io: std.Io, guides_dir: []const u8, base: []const u8) ![]u8 {
    const first = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ guides_dir, base });
    if (std.Io.Dir.cwd().access(io, first, .{})) {
        // Already exists; need a suffix.
        alloc.free(first);
        const dot = std.mem.lastIndexOfScalar(u8, base, '.');
        const stem = if (dot) |d| base[0..d] else base;
        const ext = if (dot) |d| base[d..] else "";
        var n: u32 = 2;
        while (n < 1000) : (n += 1) {
            const candidate = try std.fmt.allocPrint(alloc, "{s}/{s} ({d}){s}", .{ guides_dir, stem, n, ext });
            if (std.Io.Dir.cwd().access(io, candidate, .{})) {
                alloc.free(candidate);
                continue;
            } else |_| {
                return candidate;
            }
        }
        return error.NoSuffixFound;
    } else |_| {
        return first;
    }
}

/// Cheap stream-copy. We're typically dealing with small docs
/// (KB to MB), not big binaries, so a single allocation buffer
/// keeps the implementation simple.
fn copyFile(io: std.Io, src: []const u8, dst: []const u8) !void {
    var in = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer in.close(io);
    var out = try std.Io.Dir.cwd().createFile(io, dst, .{ .truncate = true });
    defer out.close(io);

    var chunk: [64 * 1024]u8 = undefined;
    var fr_buf: [4096]u8 = undefined;
    var fw_buf: [4096]u8 = undefined;
    var fr = in.reader(io, &fr_buf);
    var fw = out.writer(io, &fw_buf);
    while (true) {
        const got = fr.interface.readSliceShort(&chunk) catch |e| return e;
        if (got == 0) break;
        try fw.interface.writeAll(chunk[0..got]);
    }
    try fw.interface.flush();
}

/// One discovered guide file under a game's guides dir.
pub const GuideEntry = struct {
    /// Display name (filename without path). Allocator-owned.
    name: []const u8,
};

/// Walk the guides dir for `thread_id` and collect every file
/// found. Caller frees via `freeGuides`. Missing dir → empty list,
/// not an error (guides are optional per game).
pub fn listGuides(frame: *Frame, thread_id: u64) ![]GuideEntry {
    const alloc = frame.lib.alloc;
    const guides_dir = try guidesDirFor(alloc, frame.info.library_root, thread_id);
    defer alloc.free(guides_dir);

    var dir = std.Io.Dir.cwd().openDir(frame.io, guides_dir, .{ .iterate = true }) catch return &.{};
    defer dir.close(frame.io);

    var out: std.ArrayList(GuideEntry) = .empty;
    errdefer {
        for (out.items) |g| alloc.free(g.name);
        out.deinit(alloc);
    }

    var it = dir.iterate();
    while (it.next(frame.io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .unknown) continue;
        const dup = try alloc.dupe(u8, entry.name);
        try out.append(alloc, .{ .name = dup });
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeGuides(alloc: std.mem.Allocator, guides: []GuideEntry) void {
    for (guides) |g| alloc.free(g.name);
    alloc.free(guides);
}

/// Persist the browser executable path the user picked in Settings.
/// Atomic tmp+rename. Empty input (after trimming) clears the file
/// so the next launch falls back to xdg-open.
pub fn saveBrowserPath(frame: *Frame, path: []const u8) void {
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    const file_path = frame.info.browser_path_file;

    if (trimmed.len == 0) {
        std.Io.Dir.cwd().deleteFile(frame.io, file_path) catch {};
        frame.state.setBrowserPath("xdg-open");
        frame.state.setBrowserMsg("reset to xdg-open");
        return;
    }

    persistTextFile(frame.io, file_path, trimmed) catch |e| {
        var emsg: [80]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "save failed: {s}", .{@errorName(e)}) catch "save failed";
        frame.state.setBrowserMsg(m);
        return;
    };
    frame.state.setBrowserPath(trimmed);
    frame.state.setBrowserMsg("saved");
}

/// Write the current `state.ui_scale` to disk when it differs from
/// the persisted snapshot. Called every frame from the main loop;
/// the comparison short-circuits unless the user actually moved the
/// slider, so disk writes happen at most once per change.
pub fn persistUiScaleIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.ui_scale == state.ui_scale_persisted) return;
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.2}", .{state.ui_scale}) catch return;
    persistTextFile(io, path, text) catch |e| {
        log.warn("ui_scale persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.ui_scale_persisted = state.ui_scale;
}

/// Write the auto-check preferences to disk in the simple `key=value`
/// format `loadAutoCheck` understands. Short-circuits when nothing
/// changed since the last persisted snapshot so a frame-rate persist
/// is essentially free.
pub fn persistAutoCheckIfDirty(state: *State, path: []const u8, io: std.Io) void {
    const cur = state.auto_check;
    const prev = state.auto_check_persisted;
    if (cur.on_startup == prev.on_startup and
        cur.interval_enabled == prev.interval_enabled and
        cur.interval_count == prev.interval_count and
        cur.interval_unit == prev.interval_unit) return;
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "on_startup={s}\ninterval_enabled={s}\ninterval_count={d}\ninterval_unit={s}\n",
        .{
            if (cur.on_startup) "true" else "false",
            if (cur.interval_enabled) "true" else "false",
            cur.interval_count,
            @tagName(cur.interval_unit),
        },
    ) catch return;
    persistTextFile(io, path, text) catch |e| {
        log.warn("auto_check persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.auto_check_persisted = cur;
}

/// Serialize the library view/sort/filter state into one compact
/// space-separated numeric line. Order is fixed and parsed positionally
/// by `applyLibPrefs`; appending a new field is backward-compatible
/// (older files just stop early). Enum masks are the EnumSet's raw
/// integer bitmask; `min_rating` is rating×100 (or -1 for "no filter").
pub fn serializeLibPrefs(state: *const State, buf: []u8) []const u8 {
    const f = &state.filters;
    const rating_i: i64 = if (f.min_rating) |r| @intFromFloat(r * 100) else -1;
    return std.fmt.bufPrint(buf, "{d} {d} {d} {d} {d} {d} {d} {d} {d} {d}", .{
        @intFromEnum(state.view),
        @intFromEnum(state.sort_column),
        @intFromEnum(state.sort_dir),
        @intFromEnum(f.sync_state),
        @intFromEnum(f.installed),
        rating_i,
        @as(u64, f.engine.bits.mask),
        @as(u64, f.status.bits.mask),
        @as(u64, f.dev_status.bits.mask),
        @as(u64, f.censored.bits.mask),
    }) catch buf[0..0];
}

fn nextInt(it: *std.mem.TokenIterator(u8, .scalar), comptime T: type) ?T {
    const tok = it.next() orelse return null;
    return std.fmt.parseInt(T, tok, 10) catch null;
}

/// Parse the next token as a 0-based enum tag, bounds-checked against
/// the enum's field count. Returns null on malformed / out-of-range
/// input so a stale file (e.g. an enum that lost a variant) is ignored
/// field-by-field rather than rejected wholesale.
fn nextEnum(it: *std.mem.TokenIterator(u8, .scalar), comptime E: type) ?E {
    const v = nextInt(it, u32) orelse return null;
    if (v >= @typeInfo(E).@"enum".fields.len) return null;
    return @enumFromInt(v);
}

/// Apply a line produced by `serializeLibPrefs` back onto `state`.
/// Tolerant: a short or partly-malformed line applies what it can and
/// leaves the rest at defaults. Does NOT touch the persisted mirror —
/// callers seed that separately so the first frame doesn't rewrite.
pub fn applyLibPrefs(state: *State, line: []const u8) void {
    if (line.len == 0) return;
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    state.view = nextEnum(&it, @TypeOf(state.view)) orelse return;
    if (nextEnum(&it, @TypeOf(state.sort_column))) |v| state.sort_column = v;
    if (nextEnum(&it, @TypeOf(state.sort_dir))) |v| state.sort_dir = v;
    if (nextEnum(&it, @TypeOf(state.filters.sync_state))) |v| state.filters.sync_state = v;
    if (nextEnum(&it, @TypeOf(state.filters.installed))) |v| state.filters.installed = v;
    if (nextInt(&it, i64)) |r| {
        state.filters.min_rating = if (r < 0) null else @as(f32, @floatFromInt(r)) / 100.0;
    }
    if (nextInt(&it, u64)) |m| state.filters.engine.bits.mask = @truncate(m);
    if (nextInt(&it, u64)) |m| state.filters.status.bits.mask = @truncate(m);
    if (nextInt(&it, u64)) |m| state.filters.dev_status.bits.mask = @truncate(m);
    if (nextInt(&it, u64)) |m| state.filters.censored.bits.mask = @truncate(m);
}

/// Seed the persisted mirror from the current state — call once at
/// startup after `applyLibPrefs` so `persistLibPrefsIfDirty` doesn't
/// immediately rewrite the same bytes already on disk.
pub fn seedLibPrefsMirror(state: *State) void {
    const cur = serializeLibPrefs(state, &state.lib_prefs_persisted);
    state.lib_prefs_persisted_len = cur.len;
}

/// Persist library view/sort/filter prefs when they diverge from the
/// last-saved snapshot. Called every frame; the serialize+compare is
/// cheap and short-circuits the disk write when nothing changed.
pub fn persistLibPrefsIfDirty(state: *State, path: []const u8, io: std.Io) void {
    var buf: [128]u8 = undefined;
    const cur = serializeLibPrefs(state, &buf);
    const prev = state.lib_prefs_persisted[0..state.lib_prefs_persisted_len];
    if (std.mem.eql(u8, cur, prev)) return;
    persistTextFile(io, path, cur) catch |e| {
        log.warn("lib_prefs persist failed: {s}", .{@errorName(e)});
        return;
    };
    @memcpy(state.lib_prefs_persisted[0..cur.len], cur);
    state.lib_prefs_persisted_len = cur.len;
}

/// Persist `state.auto_convert` to disk when it diverges from the
/// last-saved value. Called every frame; the comparison short-
/// circuits unless the user actually flipped the toggle.
pub fn persistAutoConvertIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.auto_convert == state.auto_convert_persisted) return;
    const text: []const u8 = if (state.auto_convert) "true" else "false";
    persistTextFile(io, path, text) catch |e| {
        log.warn("auto_convert persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.auto_convert_persisted = state.auto_convert;
}

/// Mirror `state.auto_apply_compat` to disk. Same debounce as
/// `persistAutoConvertIfDirty`.
pub fn persistAutoApplyCompatIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.auto_apply_compat == state.auto_apply_compat_persisted) return;
    const text: []const u8 = if (state.auto_apply_compat) "true" else "false";
    persistTextFile(io, path, text) catch |e| {
        log.warn("auto_apply_compat persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.auto_apply_compat_persisted = state.auto_apply_compat;
}

/// Mirror `state.sandbox_default` to `<data_root>/sandbox_default`
/// when the checkbox in Settings flips. Same debounce trick as
/// `persistAutoConvertIfDirty` — no-op when nothing changed.
pub fn persistSandboxDefaultIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.sandbox_default == state.sandbox_default_persisted) return;
    const text: []const u8 = if (state.sandbox_default) "true" else "false";
    persistTextFile(io, path, text) catch |e| {
        log.warn("sandbox_default persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.sandbox_default_persisted = state.sandbox_default;
}

/// Mirror `state.auto_update_default` to disk on toggle. Same shape
/// as `persistSandboxDefaultIfDirty`.
pub fn persistAutoUpdateDefaultIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.auto_update_default == state.auto_update_default_persisted) return;
    const text: []const u8 = if (state.auto_update_default) "true" else "false";
    persistTextFile(io, path, text) catch |e| {
        log.warn("auto_update_default persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.auto_update_default_persisted = state.auto_update_default;
}

pub fn persistDesktopNotificationsIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.desktop_notifications == state.desktop_notifications_persisted) return;
    const text: []const u8 = if (state.desktop_notifications) "true" else "false";
    persistTextFile(io, path, text) catch |e| {
        log.warn("desktop_notifications persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.desktop_notifications_persisted = state.desktop_notifications;
}

/// Mirror `state.refresh_backend` to disk on toggle. Same shape as
/// `persistAutoUpdateDefaultIfDirty`. Writes the enum tag name
/// (`indexer` / `scraper`) so the file is human-readable.
pub fn persistRefreshBackendIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.refresh_backend == state.refresh_backend_persisted) return;
    persistTextFile(io, path, @tagName(state.refresh_backend)) catch |e| {
        log.warn("refresh_backend persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.refresh_backend_persisted = state.refresh_backend;
}

/// Mirror `state.update_check_source` to disk on toggle. Writes the enum
/// tag name (`builtin` / `rss`).
pub fn persistUpdateCheckSourceIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.update_check_source == state.update_check_source_persisted) return;
    persistTextFile(io, path, @tagName(state.update_check_source)) catch |e| {
        log.warn("update_check_source persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.update_check_source_persisted = state.update_check_source;
}

/// Mirror `state.max_parallel_sync` to disk on change. Writes the
/// integer as a single line. Caller has already clamped to the
/// `[1, MAX_PARALLEL_SYNC]` range; we just persist.
pub fn persistMaxParallelSyncIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.max_parallel_sync == state.max_parallel_sync_persisted) return;
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{state.max_parallel_sync}) catch return;
    persistTextFile(io, path, text) catch |e| {
        log.warn("max_parallel_sync persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.max_parallel_sync_persisted = state.max_parallel_sync;
}

/// Mirror `state.min_session_seconds` to disk on change. Clamped to
/// `[0, 1800]` by the settings panel before this runs.
pub fn persistMinSessionSecondsIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.min_session_seconds == state.min_session_seconds_persisted) return;
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{state.min_session_seconds}) catch return;
    persistTextFile(io, path, text) catch |e| {
        log.warn("min_session_seconds persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.min_session_seconds_persisted = state.min_session_seconds;
}

/// Mirror `state.max_parallel_image` to disk on change.
pub fn persistMaxParallelImageIfDirty(state: *State, path: []const u8, io: std.Io) void {
    if (state.max_parallel_image == state.max_parallel_image_persisted) return;
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{state.max_parallel_image}) catch return;
    persistTextFile(io, path, text) catch |e| {
        log.warn("max_parallel_image persist failed: {s}", .{@errorName(e)});
        return;
    };
    state.max_parallel_image_persisted = state.max_parallel_image;
}

/// Parse the aria2-port textEntry buffer + Save it. Returns the new
/// port on success (0 = "use a random ephemeral port"), or an error
/// when the buffer isn't a valid integer. Persists to `<data_root>/aria2_port`.
/// Effective on next launch — the daemon binds at spawn time.
pub fn saveAria2Port(state: *State, path: []const u8, io: std.Io) !u16 {
    const end = std.mem.indexOfScalar(u8, &state.aria2_port_buf, 0) orelse state.aria2_port_buf.len;
    const trimmed = std.mem.trim(u8, state.aria2_port_buf[0..end], " \t\r\n");
    const new_port: u16 = if (trimmed.len == 0) 0 else try std.fmt.parseInt(u16, trimmed, 10);
    // 1..1023 are privileged ports on POSIX — aria2 won't bind them
    // as a non-root user. Reject early with a clear message instead
    // of letting the next spawn fail mysteriously.
    if (new_port != 0 and new_port < 1024) return error.PrivilegedPort;

    var buf: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{new_port}) catch return error.OutOfMemory;
    try persistTextFile(io, path, text);
    state.aria2_port_persisted = new_port;
    return new_port;
}

/// Parse the seed-ratio textEntry buffer + Save it. Floor enforced
/// at 2.0; anything below is rejected so the user gets an explicit
/// "too low" message instead of a silent clamp. Persists to
/// `<data_root>/aria2_seed_ratio`. Effective on next launch (the
/// --seed-ratio flag is daemon-wide and set at spawn).
pub fn saveAria2SeedRatio(state: *State, path: []const u8, io: std.Io) !f32 {
    const end = std.mem.indexOfScalar(u8, &state.aria2_seed_ratio_buf, 0) orelse state.aria2_seed_ratio_buf.len;
    const trimmed = std.mem.trim(u8, state.aria2_seed_ratio_buf[0..end], " \t\r\n");
    if (trimmed.len == 0) return error.Empty;
    const parsed = try std.fmt.parseFloat(f32, trimmed);
    if (!std.math.isFinite(parsed)) return error.NotFinite;
    if (parsed < 2.0) return error.BelowFloor;

    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.2}", .{parsed}) catch return error.OutOfMemory;
    try persistTextFile(io, path, text);
    state.aria2_seed_ratio_persisted = parsed;
    return parsed;
}

/// Parse + save the seed-time cap (minutes; 0 = no cap). Persists to
/// `<data_root>/aria2_seed_time`. Applied live by the caller via
/// `Manager.setSeedTimeLive`.
pub fn saveAria2SeedTime(state: *State, path: []const u8, io: std.Io) !u32 {
    const end = std.mem.indexOfScalar(u8, &state.aria2_seed_time_buf, 0) orelse state.aria2_seed_time_buf.len;
    const trimmed = std.mem.trim(u8, state.aria2_seed_time_buf[0..end], " \t\r\n");
    if (trimmed.len == 0) return error.Empty;
    const parsed = try std.fmt.parseInt(u32, trimmed, 10);

    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{parsed}) catch return error.OutOfMemory;
    try persistTextFile(io, path, text);
    state.aria2_seed_time_persisted = parsed;
    return parsed;
}

/// Fire `startUpdateCheck` automatically based on the user's
/// preferences: once at startup (if `on_startup`) and/or on a
/// recurring interval (if `interval_enabled`). Skipped while any
/// async worker is in flight so we never race a bookmark import or
/// piggy-back on top of an already-running check.
pub fn maybeAutoUpdateCheck(frame: *Frame) void {
    const state = frame.state;
    // Indexer mode owns the "what changed?" question — `/fast` returns
    // a per-game last_change for free, so the latest-updates walker is
    // redundant AND would be direct f95zone.to scraping the user has
    // opted out of. Skip the entire auto-check pipeline here.
    if (state.refresh_backend == .indexer) return;
    // Never fire while another worker is mid-flight. The startup
    // path waits for bookmarks to drain, the recurring path waits
    // for whichever previous check finishes.
    if (state.pending_update_check != null) return;
    if (state.pending_bookmarks != null) return;
    if (state.anyActiveSync()) return;
    if (state.sync_queue != null) return;

    const settings = state.auto_check;

    // --- one-shot startup trigger ---
    if (settings.on_startup and !state.auto_check_did_startup) {
        state.auto_check_did_startup = true;
        log.info("auto-check: startup trigger firing", .{});
        imports_mod.startUpdateCheck(frame);
        return;
    }

    // --- recurring interval ---
    if (!settings.interval_enabled) return;
    if (settings.interval_count == 0) return;
    const now_s = std.Io.Clock.Timestamp.now(frame.io, .real).raw.toSeconds();
    const interval_s: i64 = @as(i64, @intCast(settings.interval_count)) * settings.interval_unit.seconds();
    // No prior check → wait for the user's first manual click, OR
    // fall into the startup trigger above. Don't auto-fire on a
    // brand new install just because the interval is "enabled".
    if (state.last_update_check_ts == 0) return;
    if (now_s - state.last_update_check_ts < interval_s) return;
    log.info(
        "auto-check: interval trigger firing ({d}{s} since last check)",
        .{ settings.interval_count, @tagName(settings.interval_unit) },
    );
    imports_mod.startUpdateCheck(frame);
}

pub fn persistTextFile(io: std.Io, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    var tmp_buf: [512]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    var f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
    defer f.close(io);
    var fw_buf: [1024]u8 = undefined;
    var fw = f.writer(io, &fw_buf);
    try fw.interface.writeAll(text);
    try fw.interface.flush();
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

/// Map raw error names from `f95.errors.Error` (or the f95.Client) to
/// short human-readable strings for status banners. Falls back to the
/// raw name on unknown values.
pub fn friendlyError(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "AuthRequired")) return "session expired — re-login";
    if (std.mem.eql(u8, name, "ServerError")) return "F95 server error (5xx) — retry later";
    if (std.mem.eql(u8, name, "RateLimited")) return "rate limited by F95 — wait + retry";
    if (std.mem.eql(u8, name, "NetworkError")) return "network error — check connection";
    if (std.mem.eql(u8, name, "NotFound")) return "endpoint not found (404)";
    if (std.mem.eql(u8, name, "HttpStatusError")) return "F95 returned an unexpected status";
    if (std.mem.eql(u8, name, "OutOfMemory")) return "out of memory";
    if (std.mem.eql(u8, name, "DatabaseError")) return "database write failed";
    if (std.mem.eql(u8, name, "Cancelled")) return "cancelled";
    return name;
}

// ============================================================
//  delete game (DB row + cover file + cache eviction)
// ============================================================

pub fn deleteGameAndReturn(frame: *Frame, thread_id: u64) void {
    const state = frame.state;
    frame.lib.deleteGame(thread_id) catch {};

    // Best-effort cover-file removal — silently ignore if missing.
    var path_buf: [256]u8 = undefined;
    if (sync_mod.coverPath(&path_buf, frame.info.covers_dir, thread_id)) |path| {
        std.Io.Dir.cwd().deleteFile(frame.io, path) catch {};
    } else |_| {}

    sync_mod.invalidateCover(state, frame.lib.alloc, thread_id);

    state.confirm_delete = false;
    state.selected_thread = null;
    state.screen = .library;
    state.reload_requested = true;
}

/// Point a game at an already-installed folder on disk (detail page ⋯ → "Set
/// install folder…"). Opens a directory picker and registers the chosen folder
/// as a `.manual` install, so a game imported without a path (F95Checker
/// import, or a folder whose name didn't match) becomes launchable without any
/// name-matching. The launcher inside the folder is auto-picked at play time,
/// same as a downloaded install. Non-destructive: a folder already claimed by
/// another game, or a version already installed here, is reported and left
/// alone.
pub fn setInstallFolder(frame: *Frame, game: *const library.Game) void {
    const file_picker = @import("util_file_picker");
    const state = frame.state;
    const alloc = frame.lib.alloc;

    const picked = (file_picker.openFolder(alloc, null) catch |e| {
        var buf: [160]u8 = undefined;
        state.notifyErr(std.fmt.bufPrint(&buf, "Folder picker failed: {s}", .{@errorName(e)}) catch "Folder picker failed");
        return;
    }) orelse return; // user cancelled
    defer alloc.free(picked);

    // Version label defaults to the game's known version; "installed" when we
    // don't have one yet. The user can relabel it later on the install.
    const ver_raw = if (game.latest_version) |v| std.mem.trim(u8, v, " \t\r\n") else "";
    const version: []const u8 = if (ver_raw.len > 0) ver_raw else "installed";

    var id: [36]u8 = undefined;
    generateUuid(frame.io, &id);
    const now = std.Io.Clock.Timestamp.now(frame.io, .real);
    const now_s: i64 = @intCast(@divTrunc(now.raw.toNanoseconds(), 1_000_000_000));

    frame.lib.registerManualInstall(game.f95_thread_id, version, picked, id, now_s) catch |e| {
        switch (e) {
            error.InstallPathInUse => state.notifyErr("That folder is already registered to a game."),
            error.InstallVersionExists => {
                var buf: [160]u8 = undefined;
                state.notifyErr(std.fmt.bufPrint(&buf, "This game already has an install labelled \"{s}\".", .{version}) catch "That version is already installed.");
            },
            else => state.notifyErr("Couldn't register the folder — the library update failed."),
        }
        return;
    };
    state.reload_requested = true; // refresh library + install views
    state.notifyOk("Install folder set — the game is now marked installed.");
}

/// Set a game's saves folder manually (detail ⋯ → "Set saves folder…"). Opens
/// a directory picker; the Open/Backup/Import-saves actions then target it
/// instead of the auto sandbox-HOME location — needed for unsandboxed games or
/// engines whose saves f69 can't guess.
pub fn setSavesFolder(frame: *Frame, game: *const library.Game) void {
    const file_picker = @import("util_file_picker");
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const picked = (file_picker.openFolder(alloc, null) catch |e| {
        var buf: [160]u8 = undefined;
        state.notifyErr(std.fmt.bufPrint(&buf, "Folder picker failed: {s}", .{@errorName(e)}) catch "Folder picker failed");
        return;
    }) orelse return; // cancelled
    defer alloc.free(picked);
    frame.lib.setGameSavePath(game.f95_thread_id, picked) catch {
        state.notifyErr("Couldn't set the saves folder — the library update failed.");
        return;
    };
    state.notifyOk("Saves folder set — Open/Backup/Import saves now use it.");
}

/// Clear a game's manual saves-folder override, reverting to the auto location.
pub fn clearSavesFolder(frame: *Frame, game: *const library.Game) void {
    frame.lib.setGameSavePath(game.f95_thread_id, null) catch {
        frame.state.notifyErr("Couldn't reset the saves folder.");
        return;
    };
    frame.state.notifyInfo("Saves folder reset to the default location.");
}

/// 36-char hex+dash UUID for a manual install row, same shape as the
/// installer/import UUIDs. Local so common.zig doesn't reach across modules.
fn generateUuid(io: std.Io, out: *[36]u8) void {
    const now = std.Io.Clock.Timestamp.now(io, .real);
    const ns: u64 = @intCast(@max(0, now.raw.toNanoseconds()));
    var h = std.hash.Wyhash.init(ns);
    h.update(std.mem.asBytes(&ns));
    const a = h.final();
    const b = std.hash.Wyhash.hash(a, std.mem.asBytes(&ns));
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], a, .little);
    std.mem.writeInt(u64, bytes[8..16], b, .little);
    const hex = "0123456789abcdef";
    var pos: usize = 0;
    for (bytes, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[pos] = '-';
            pos += 1;
        }
        out[pos] = hex[byte >> 4];
        out[pos + 1] = hex[byte & 0xF];
        pos += 2;
    }
}

// ============================================================
//  installed-set + per-game install dot + retry-download glue
// ============================================================

/// Lazy-init the installed-set. `refreshInstalledSet` repopulates it
/// from the DB; callers consult `isInstalled` per game.
fn installedSetPtr(frame: *Frame) ?*InstalledSet {
    if (frame.state.installed_set) |p| return p;
    const set_ptr = frame.lib.alloc.create(InstalledSet) catch return null;
    set_ptr.* = InstalledSet.init(frame.lib.alloc);
    frame.state.installed_set = set_ptr;
    return set_ptr;
}

/// Rebuild the installed-set from the `installs` table. Cheap on a
/// reasonable library — a single SELECT DISTINCT. Call once per
/// library-screen render before any `isInstalled` lookups so the
/// indicator + filter reflect a fresh snapshot (post-install
/// completions land in the table between renders).
pub fn refreshInstalledSet(frame: *Frame) void {
    // Cache by Library.install_generation — the installed-thread set only
    // changes when an install row is added/removed, never per frame. Mirrors
    // the install_versions snapshot in ui.zig. Skips a per-frame SELECT +
    // HashMap rebuild that otherwise ran on every mouse-motion wakeup.
    const gen = frame.lib.install_generation;
    if (frame.state.installed_set != null and frame.state.installed_set_gen == gen) return;
    const set = installedSetPtr(frame) orelse return;
    set.clearRetainingCapacity();
    const ids = frame.lib.fetchInstalledThreadIds() catch |e| {
        log.warn("refreshInstalledSet: fetchInstalledThreadIds failed: {s}", .{@errorName(e)});
        return;
    };
    defer frame.lib.alloc.free(ids);
    for (ids) |tid| set.put(tid, {}) catch {};
    frame.state.installed_set_gen = gen;
}

/// Read-only probe — true iff `thread_id` had at least one install
/// row at the last `refreshInstalledSet` call this frame.
pub fn isInstalled(frame: *Frame, thread_id: u64) bool {
    if (frame.state.installed_set == null) return false;
    const set = installedSetPtr(frame) orelse return false;
    return set.contains(thread_id);
}

/// Re-trigger a failed download. Picks the right provider based on
/// the failed job's source: RPDL torrents re-enter the search flow,
/// donor DDL re-POSTs for a fresh signed URL, plain HTTP re-enqueues
/// the URL as-is. Removes the failed row from the manager once the
/// replacement is in flight so the downloads page doesn't show two
/// stacked entries for the same game.
pub fn retryDownload(frame: *Frame, job_id: u64) void {
    const state = frame.state;
    const job = frame.dl_mgr.jobs.get(job_id) orelse {
        log.warn("retryDownload: job {d} no longer in manager", .{job_id});
        return;
    };
    const game_id = job.game_id;
    const source = job.source_url;
    const was_donor = downloads_mod.isDonorJob(frame, job_id);

    // Find the matching library row — needed for the RPDL / donor
    // workers which take a *library.Game.
    var target: ?*library.Game = null;
    if (game_id != 0) {
        for (frame.games) |*g| {
            if (g.f95_thread_id == game_id) {
                target = g;
                break;
            }
        }
    }

    if (was_donor) {
        if (target) |g| {
            log.info("retryDownload: job {d} (tid={d}) was donor DDL — restarting flow", .{ job_id, game_id });
            frame.dl_mgr.removeJob(job_id);
            downloads_mod.startDonorDownload(frame, g);
            return;
        }
    }
    if (std.mem.startsWith(u8, source, "rpdl:")) {
        if (target) |g| {
            log.info("retryDownload: job {d} (tid={d}) was RPDL — restarting search", .{ job_id, game_id });
            frame.dl_mgr.removeJob(job_id);
            downloads_mod.startRpdlDownload(frame, g);
            return;
        }
    }
    // Plain HTTP / unrecognised — just re-enqueue the same URL.
    if (std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://")) {
        log.info("retryDownload: job {d} — re-enqueuing URL '{s}'", .{ job_id, source });
        // Duplicate before removing the job so the URL slice isn't
        // freed under us.
        const url_dup = frame.lib.alloc.dupe(u8, source) catch {
            state.setDownloadMsg("Retry failed: out of memory");
            return;
        };
        defer frame.lib.alloc.free(url_dup);
        frame.dl_mgr.removeJob(job_id);
        _ = frame.dl_mgr.enqueueUrl(url_dup, .game, game_id, null, null, null, .{}) catch |e| {
            var msg_buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&msg_buf, "Retry failed: {s}", .{@errorName(e)}) catch "Retry failed";
            state.setDownloadMsg(m);
        };
        return;
    }
    log.warn("retryDownload: job {d} source '{s}' isn't HTTP/RPDL/donor — cannot retry", .{ job_id, source });
    state.setDownloadMsg("Retry not supported for this source.");
}

/// Three-way state used to drive the install dot on grid/list cards.
pub const InstallDotState = enum {
    /// No install row for this game.
    none,
    /// Installed AND the install's recorded `version` matches the
    /// game's `latest_version` from F95 (or there's no scraped
    /// version yet to compare against — we assume up-to-date until
    /// proven otherwise).
    up_to_date,
    /// Installed but the scraped version is newer than the install
    /// row's version — yellow indicator nudges the user toward a
    /// re-download.
    outdated,
};

/// Per-game install state. Uses `installed_set` as a fast first-
/// check (1 HashMap lookup); when installed, look up the latest
/// version via `frame.install_versions` (per-frame snapshot built
/// once at the top of `guiFrame` from a single SELECT). Falls back
/// to the legacy per-game `latestInstallForGame` SQL only when the
/// snapshot is unavailable (e.g. the cache build OOM'd).
pub fn installDotState(frame: *Frame, game: *const library.Game) InstallDotState {
    if (!isInstalled(frame, game.f95_thread_id)) return .none;
    const scraped = game.latest_version orelse return .up_to_date;
    if (scraped.len == 0) return .up_to_date;
    if (frame.install_versions) |map| {
        if (map.get(game.f95_thread_id)) |installed_ver| {
            // Treat the placeholder version "unversioned" as "we don't
            // really know what's installed" — show green, since we
            // can't claim it's outdated.
            if (std.mem.eql(u8, installed_ver, "unversioned")) return .up_to_date;
            if (version_mod.equivalent(installed_ver, scraped)) return .up_to_date;
            return .outdated;
        }
        // installed_set said yes but the map has no entry — race
        // with a mid-frame uninstall. Fall through to the legacy
        // path so the indicator settles on the next frame.
    }
    const latest = frame.lib.latestInstallForGame(game.f95_thread_id) catch return .up_to_date;
    if (latest) |inst| {
        defer frame.lib.freeInstall(inst);
        if (std.mem.eql(u8, inst.version, "unversioned")) return .up_to_date;
        if (version_mod.equivalent(inst.version, scraped)) return .up_to_date;
        return .outdated;
    }
    return .up_to_date;
}

pub fn freeInstalledSet(state: *State, alloc: std.mem.Allocator) void {
    if (state.installed_set) |set_ptr| {
        set_ptr.deinit();
        alloc.destroy(set_ptr);
        state.installed_set = null;
    }
}

pub fn attemptsMap(frame: *Frame) ?*AttemptsMap {
    if (frame.state.download_attempts) |p| return p;
    const map_ptr = frame.lib.alloc.create(AttemptsMap) catch return null;
    map_ptr.* = AttemptsMap.init(frame.lib.alloc);
    frame.state.download_attempts = map_ptr;
    return map_ptr;
}

/// Record that the user just clicked Download for `game_id` — i.e. we
/// just enqueued `sources[0]` and should start counting failures from
/// index 0. Called by `doDownloadGame` before `enqueueOneSource`.
pub fn resetAttempt(frame: *Frame, game_id: u64) void {
    const m = attemptsMap(frame) orelse return;
    m.put(game_id, 0) catch {};
}

// ============================================================
//  exe-exists probe
// ============================================================

/// Probe whether `exe` (typically a recipe's `launch.linux`, like
/// `"./MyGame.sh"`) exists as a file under `install_dir`. Handles a
/// leading `./` segment that Ren'Py recipes commonly carry.
fn exeExistsUnder(io: std.Io, install_dir: []const u8, exe: []const u8) bool {
    const rel = if (std.mem.startsWith(u8, exe, "./")) exe[2..] else exe;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ install_dir, rel }) catch return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Tear-down for the post_installed set + per-game download-attempts
/// map + running-games map. Called from runMainLoop's defer block.
pub fn freePostInstalled(state: *State, alloc: std.mem.Allocator) void {
    if (state.post_installed) |set_ptr| {
        set_ptr.deinit();
        alloc.destroy(set_ptr);
        state.post_installed = null;
    }
    if (state.download_attempts) |map_ptr| {
        map_ptr.deinit();
        alloc.destroy(map_ptr);
        state.download_attempts = null;
    }
    launch_mod.freeRunningGames(state, alloc);
}
