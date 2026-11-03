// SDK cache abstraction. Engines look up their pre-fetched archives
// under `<cache>/f69/convert/sdks/<engine>-<version>/`. On miss the
// cache streams the archive from the engine's public mirror (renpy.org /
// dl.nwjs.io / nwjs-ffmpeg-prebuilt) to `<dir>.part`, extracts into
// `<dir>.unpack/`, then renames that into place.
//
// Layout:
//   <cache>/f69/convert/sdks/renpy-7.5.3/   ← extracted renpy-7.5.3-sdk.tar.gz
//   <cache>/f69/convert/sdks/nwjs-0.83.0/   ← extracted nwjs-v0.83.0-linux-x64.tar.gz
//
// `renpy-` / `nwjs-` prefixes keep the directory walkable in a single
// flat namespace — easier to inspect than per-engine subdirs.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.sdk_cache);
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const util_http = @import("util_http");
const util_archive = @import("util_archive");

/// Cap on a single SDK download. Ren'Py SDKs run ~95 MiB compressed
/// (~250 MiB uncompressed); nwjs ~50 MiB compressed. 1 GiB is the
/// safety net against pulling a wrong URL that returns something huge.
pub const MAX_SDK_BYTES: usize = 1024 * 1024 * 1024;

pub const Cache = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Allocator-owned `<cache>/f69/convert/sdks` path.
    sdks_dir: []u8,

    /// Initialize with the cache *root* (`<cache>/f69`); we append
    /// `/convert/sdks` ourselves. Creates the dir.
    pub fn init(alloc: std.mem.Allocator, io: std.Io, cache_root: []const u8) errs.Error!Cache {
        const sdks_dir = std.fmt.allocPrint(alloc, "{s}/convert/sdks", .{cache_root}) catch return errs.Error.OutOfMemory;
        errdefer alloc.free(sdks_dir);
        std.Io.Dir.cwd().createDirPath(io, sdks_dir) catch {};
        return .{ .alloc = alloc, .io = io, .sdks_dir = sdks_dir };
    }

    pub fn deinit(self: *Cache) void {
        self.alloc.free(self.sdks_dir);
        self.* = undefined;
    }

    /// Resolve a `<engine>-<version>` SDK directory. Returns the
    /// allocator-owned absolute path if the dir exists, `SdkNotCached`
    /// otherwise. Caller frees on success.
    ///
    /// `engine_tag` is the URL-friendly tag we use as the SDK dir prefix:
    /// "renpy" / "nwjs" / etc. Distinct from `dom.Engine` since one
    /// engine (RPGM) uses nwjs as its SDK.
    pub fn locate(self: *Cache, engine_tag: []const u8, version: []const u8) errs.Error![]u8 {
        const path = std.fmt.allocPrint(self.alloc, "{s}/{s}-{s}", .{ self.sdks_dir, engine_tag, version }) catch return errs.Error.OutOfMemory;
        errdefer self.alloc.free(path);
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return errs.Error.SdkNotCached;
        return path;
    }

    /// Build the path an SDK *would* land at when fetched. Allocator-
    /// owned. Used by error messages + as the target for `fetch`.
    pub fn expectedPath(self: *Cache, engine_tag: []const u8, version: []const u8) errs.Error![]u8 {
        return std.fmt.allocPrint(self.alloc, "{s}/{s}-{s}", .{ self.sdks_dir, engine_tag, version }) catch errs.Error.OutOfMemory;
    }

    /// Download + extract the `<engine_tag>-<version>` SDK from its
    /// public mirror. URL resolved via `sdkUrl()`. The archive streams
    /// to `<dest>.part` (phase "Downloading <engine_tag> SDK", ticks =
    /// bytes received / Content-Length), then unpacks (phase "Unpacking
    /// SDK", ticks = compressed bytes consumed / archive size) into
    /// `<dest>.unpack/`, which is renamed to `<dest>/` only once the
    /// extract finished — so an interrupted or cancelled run never
    /// leaves a half-extracted dir that `locate` would accept.
    ///
    /// `prog.stop()` is polled per download chunk and around the
    /// unpack; a stop returns `Cancelled` and removes the partial files.
    ///
    /// Caller frees the returned absolute path on success.
    ///
    /// Idempotent: if the SDK is already cached, returns its path
    /// without re-fetching.
    pub fn fetch(self: *Cache, engine_tag: []const u8, version: []const u8, prog: dom.Progress) errs.Error![]u8 {
        if (self.locate(engine_tag, version)) |existing| {
            return existing;
        } else |e| switch (e) {
            errs.Error.SdkNotCached => {},
            else => return e,
        }

        const url = try sdkUrl(self.alloc, engine_tag, version);
        defer self.alloc.free(url);

        const dest_dir = try self.expectedPath(engine_tag, version);
        errdefer self.alloc.free(dest_dir);

        if (prog.stop()) return errs.Error.Cancelled;

        // ---- 1. download to <dest>.part ----
        var phase_buf: [96]u8 = undefined;
        prog.setPhase(std.fmt.bufPrint(&phase_buf, "Downloading {s} SDK", .{engine_tag}) catch "Downloading SDK");
        prog.tick(0, 0);
        log.info("fetching {s}-{s} from {s}", .{ engine_tag, version, url });

        const part_path = std.fmt.allocPrint(self.alloc, "{s}.part", .{dest_dir}) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(part_path);
        // The .part is scratch on every path — success or failure.
        defer std.Io.Dir.cwd().deleteFile(self.io, part_path) catch {};

        const extra_headers = [_]util_http.Header{
            .{ .name = "accept", .value = "application/gzip, application/octet-stream, */*" },
        };
        const Dl = struct {
            fn chunk(ctx: ?*anyopaque, received: u64, total: ?u64) void {
                const p: *const dom.Progress = @ptrCast(@alignCast(ctx.?));
                p.tick(received, total orelse 0);
            }
            fn cancelled(ctx: ?*anyopaque) bool {
                const p: *const dom.Progress = @ptrCast(@alignCast(ctx.?));
                return p.stop();
            }
        };
        const status = util_http.fetchToFile(self.alloc, self.io, url, part_path, .{
            .extra_headers = &extra_headers,
            .max_response_bytes = MAX_SDK_BYTES,
            .cancelled = Dl.cancelled,
        }, Dl.chunk, @constCast(&prog)) catch |e| switch (e) {
            util_http.Error.Cancelled => return errs.Error.Cancelled,
            util_http.Error.OutOfMemory => return errs.Error.OutOfMemory,
            else => {
                log.warn("SDK fetch error: {s}", .{@errorName(e)});
                return errs.Error.NetworkError;
            },
        };
        if (status != 200) {
            log.warn("SDK fetch status {d} for {s}", .{ status, url });
            return switch (status) {
                404 => errs.Error.NotFound,
                else => errs.Error.NetworkError,
            };
        }
        const archive_size: u64 = if (std.Io.Dir.cwd().statFile(self.io, part_path, .{})) |st| st.size else |_| 0;
        log.info("SDK download done: {d} bytes compressed", .{archive_size});

        if (prog.stop()) return errs.Error.Cancelled;

        // ---- 2. unpack into <dest>.unpack, then rename into place ----
        prog.setPhase("Unpacking SDK");
        prog.tick(0, archive_size);

        const unpack_dir = std.fmt.allocPrint(self.alloc, "{s}.unpack", .{dest_dir}) catch return errs.Error.OutOfMemory;
        defer self.alloc.free(unpack_dir);
        std.Io.Dir.cwd().deleteTree(self.io, unpack_dir) catch {};
        std.Io.Dir.cwd().createDirPath(self.io, unpack_dir) catch return errs.Error.SdkLayoutInvalid;
        var unpacked = false;
        defer if (!unpacked) std.Io.Dir.cwd().deleteTree(self.io, unpack_dir) catch {};

        const strip = sdkStripComponents(engine_tag);
        const extract_result = switch (sdkArchiveFormat(engine_tag)) {
            .tar_gz => extractTarGzFile(self.alloc, self.io, part_path, unpack_dir, strip, archive_size, .{ .ctx = prog.ctx, .cb = prog.report }),
            .zip => util_archive.extractFile(part_path, unpack_dir, .{
                .strip = @intCast(strip),
                .progress_cb = prog.report,
                .progress_ctx = prog.ctx,
                .progress_total = archive_size,
            }),
        };
        extract_result catch |e| {
            log.warn("SDK extract failed: {s}", .{@errorName(e)});
            return errs.Error.SdkLayoutInvalid;
        };
        prog.tick(archive_size, archive_size);

        // Neither extractor can stop mid-stream; honour a stop that came
        // in while it ran before the SDK becomes visible to `locate`.
        if (prog.stop()) return errs.Error.Cancelled;

        std.Io.Dir.cwd().rename(unpack_dir, std.Io.Dir.cwd(), dest_dir, self.io) catch |e| {
            log.warn("SDK move into place failed: {s}", .{@errorName(e)});
            return errs.Error.SdkLayoutInvalid;
        };
        unpacked = true;

        log.info("SDK installed at {s}", .{dest_dir});
        return dest_dir;
    }
};

/// Pure. Build the canonical download URL for an `(engine_tag, version)`
/// pair. Allocator-owned slice.
///
/// Patterns:
///   renpy       → https://www.renpy.org/dl/<v>/renpy-<v>-sdk.tar.gz
///   nwjs        → https://dl.nwjs.io/v<v>/nwjs-v<v>-linux-x64.tar.gz
///   nwjs-ffmpeg → https://github.com/nwjs-ffmpeg-prebuilt/
///                 nwjs-ffmpeg-prebuilt/releases/download/<v>/<v>-linux-x64.zip
///
/// New engine tags get added here; returns `UnknownEngine` otherwise.
pub fn sdkUrl(alloc: std.mem.Allocator, engine_tag: []const u8, version: []const u8) errs.Error![]u8 {
    if (std.mem.eql(u8, engine_tag, "renpy")) {
        return std.fmt.allocPrint(alloc, "https://www.renpy.org/dl/{s}/renpy-{s}-sdk.tar.gz", .{ version, version }) catch errs.Error.OutOfMemory;
    }
    if (std.mem.eql(u8, engine_tag, "nwjs")) {
        return std.fmt.allocPrint(alloc, "https://dl.nwjs.io/v{s}/nwjs-v{s}-linux-x64.tar.gz", .{ version, version }) catch errs.Error.OutOfMemory;
    }
    if (std.mem.eql(u8, engine_tag, "nwjs-ffmpeg")) {
        return std.fmt.allocPrint(alloc, "https://github.com/nwjs-ffmpeg-prebuilt/nwjs-ffmpeg-prebuilt/releases/download/{s}/{s}-linux-x64.zip", .{ version, version }) catch errs.Error.OutOfMemory;
    }
    return errs.Error.UnknownEngine;
}

/// Pure. The official tarballs nest everything under a top-level
/// `renpy-<v>-sdk/` or `nwjs-v<v>-linux-x64/` directory. We strip
/// that level so files land directly in our `<tag>-<version>/` dir.
/// nwjs-ffmpeg ships a flat zip — no strip.
pub fn sdkStripComponents(engine_tag: []const u8) u32 {
    if (std.mem.eql(u8, engine_tag, "renpy")) return 1;
    if (std.mem.eql(u8, engine_tag, "nwjs")) return 1;
    return 0;
}

/// Pure. Archive format used for the canonical URL of each engine tag.
pub fn sdkArchiveFormat(engine_tag: []const u8) ArchiveFormat {
    if (std.mem.eql(u8, engine_tag, "renpy")) return .tar_gz;
    if (std.mem.eql(u8, engine_tag, "nwjs")) return .tar_gz;
    if (std.mem.eql(u8, engine_tag, "nwjs-ffmpeg")) return .zip;
    return .tar_gz;
}

pub const ArchiveFormat = enum { tar_gz, zip };

/// Stream `path` (a .tar.gz on disk) through gzip + tar into
/// `dest_dir`, reporting compressed bytes consumed via `sink`.
fn extractTarGzFile(
    alloc: std.mem.Allocator,
    io: Io,
    path: []const u8,
    dest_dir: []const u8,
    strip_components: u32,
    total: u64,
    sink: util_archive.ProgressSink,
) !void {
    var dest = try std.Io.Dir.cwd().openDir(io, dest_dir, .{});
    defer dest.close(io);

    var f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);

    // Heap buffers: ~160 KiB of reader/window state is too much stack
    // for a worker thread.
    const bufs = try alloc.alloc(u8, 2 * 64 * 1024);
    defer alloc.free(bufs);
    var fr = f.reader(io, bufs[0 .. 64 * 1024]);
    // The gzip decoder peeks through the counting reader, so it needs a
    // buffer of its own (an empty one cannot serve a peek).
    var counted = util_archive.CountingReader.init(&fr.interface, bufs[64 * 1024 ..], total, sink);

    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);

    var dec = std.compress.flate.Decompress.init(&counted.reader, .gzip, window);
    try std.tar.extract(io, dest, &dec.reader, .{ .strip_components = strip_components });
}

// ============================================================
//  tests
// ============================================================

const testing = std.testing;
const test_env = @import("util_test_env");

test "Cache.locate: hit" {
    var env = try test_env.TestEnv.init(testing.allocator, "sdk-hit");
    defer env.deinit();

    var cache = try Cache.init(testing.allocator, env.io, env.root);
    defer cache.deinit();

    // Pre-stage an SDK dir.
    try env.mkdirP("convert/sdks/renpy-7.5.3");

    const found = try cache.locate("renpy", "7.5.3");
    defer testing.allocator.free(found);
    try testing.expect(std.mem.endsWith(u8, found, "/convert/sdks/renpy-7.5.3"));
}

test "Cache.locate: miss returns SdkNotCached" {
    var env = try test_env.TestEnv.init(testing.allocator, "sdk-miss");
    defer env.deinit();

    var cache = try Cache.init(testing.allocator, env.io, env.root);
    defer cache.deinit();

    try testing.expectError(errs.Error.SdkNotCached, cache.locate("renpy", "9.9.9"));
}

test "Cache.expectedPath: format" {
    var env = try test_env.TestEnv.init(testing.allocator, "sdk-expected");
    defer env.deinit();

    var cache = try Cache.init(testing.allocator, env.io, env.root);
    defer cache.deinit();

    const ep = try cache.expectedPath("nwjs", "0.83.0");
    defer testing.allocator.free(ep);
    try testing.expect(std.mem.endsWith(u8, ep, "/convert/sdks/nwjs-0.83.0"));
}

test "sdkUrl: renpy pattern" {
    const u = try sdkUrl(testing.allocator, "renpy", "7.5.3");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("https://www.renpy.org/dl/7.5.3/renpy-7.5.3-sdk.tar.gz", u);
}

test "sdkUrl: nwjs pattern" {
    const u = try sdkUrl(testing.allocator, "nwjs", "0.83.0");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("https://dl.nwjs.io/v0.83.0/nwjs-v0.83.0-linux-x64.tar.gz", u);
}

test "sdkUrl: nwjs-ffmpeg pattern" {
    const u = try sdkUrl(testing.allocator, "nwjs-ffmpeg", "0.83.0");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("https://github.com/nwjs-ffmpeg-prebuilt/nwjs-ffmpeg-prebuilt/releases/download/0.83.0/0.83.0-linux-x64.zip", u);
}

test "sdkArchiveFormat: per-tag" {
    try testing.expectEqual(ArchiveFormat.tar_gz, sdkArchiveFormat("renpy"));
    try testing.expectEqual(ArchiveFormat.tar_gz, sdkArchiveFormat("nwjs"));
    try testing.expectEqual(ArchiveFormat.zip, sdkArchiveFormat("nwjs-ffmpeg"));
}

test "sdkUrl: unknown engine_tag → UnknownEngine" {
    try testing.expectError(errs.Error.UnknownEngine, sdkUrl(testing.allocator, "weird", "1.0"));
}

test "sdkStripComponents: known tags" {
    try testing.expectEqual(@as(u32, 1), sdkStripComponents("renpy"));
    try testing.expectEqual(@as(u32, 1), sdkStripComponents("nwjs"));
    try testing.expectEqual(@as(u32, 0), sdkStripComponents("unknown"));
}

test "Cache.fetch: idempotent — second call returns cached path without network" {
    var env = try test_env.TestEnv.init(testing.allocator, "sdk-fetch-idem");
    defer env.deinit();

    var cache = try Cache.init(testing.allocator, env.io, env.root);
    defer cache.deinit();

    // Pre-stage the dir so fetch finds it via locate() and skips
    // network entirely.
    try env.mkdirP("convert/sdks/renpy-7.5.3");

    const got = try cache.fetch("renpy", "7.5.3", .none);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.endsWith(u8, got, "/convert/sdks/renpy-7.5.3"));
}
