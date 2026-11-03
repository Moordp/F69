// ConvertService — orchestrates engine detection → SDK lookup →
// libs install → launcher generation. Idempotent.

const std = @import("std");
const log = std.log.scoped(.convert);
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const detect_mod = @import("detect.zig");
const renpy = @import("renpy.zig");
const rpgm = @import("rpgm.zig");
const sdk_cache_mod = @import("sdk_cache.zig");

pub const Service = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    distro: dom.Distro,
    cache: sdk_cache_mod.Cache,

    /// `cache_root` is `<XDG_CACHE_HOME>/f69` — `Cache` appends
    /// `/convert/sdks/` itself.
    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        cache_root: []const u8,
    ) errs.Error!Service {
        return .{
            .alloc = alloc,
            .io = io,
            .distro = dom.Distro.detect(io, alloc),
            .cache = try sdk_cache_mod.Cache.init(alloc, io, cache_root),
        };
    }

    pub fn deinit(self: *Service) void {
        self.cache.deinit();
        self.* = undefined;
    }

    /// Run the convert step on `install_dir` per `spec`. Idempotent —
    /// the Ren'Py path bails fast when the launcher + a `lib/*linux*`
    /// dir already exist. Set `force = true` to re-run anyway.
    ///
    /// `prog` gets the phases (SDK download, unpack, runtime copy,
    /// library patching, launcher) and per-phase ticks; `prog.stop()`
    /// is polled between files/chunks and returns `Cancelled`. The
    /// launcher is always the last thing written, so a cancelled run
    /// never leaves one pointing at a half-copied runtime. Pass
    /// `.none` for a silent, uncancellable run.
    pub fn convert(
        self: *Service,
        install_dir: []const u8,
        spec: dom.ConvertSpec,
        force: bool,
        prog: dom.Progress,
    ) errs.Error!void {
        // Bail fast when the recipe explicitly says "no convert needed".
        switch (spec) {
            .none => {
                log.debug("convert: .none, skipping ({s})", .{install_dir});
                return;
            },
            .renpy => |r| return self.convertRenpy(install_dir, r.sdk_version, force, prog),
            .rpgm => |r| return rpgm.convert(
                self.alloc,
                self.io,
                install_dir,
                &self.cache,
                self.distro,
                r.nwjs_version,
                r.ffmpeg_codecs,
                r.bundle_syslibs,
                force,
                prog,
            ),
            .mkxp_z => |m| return rpgm.convertVxAce(
                self.alloc,
                self.io,
                install_dir,
                m.mkxp_z_dir,
                m.extra_libs_dir,
                m.zoom,
                force,
                prog,
            ),
        }
    }

    fn convertRenpy(
        self: *Service,
        install_dir: []const u8,
        recipe_sdk_version: ?[]const u8,
        force: bool,
        prog: dom.Progress,
    ) errs.Error!void {
        // ---- existence ----
        std.Io.Dir.cwd().access(self.io, install_dir, .{}) catch return errs.Error.InstallNotFound;

        // ---- engine sanity ----
        const engine = detect_mod.detectEngine(self.io, install_dir);
        if (engine != .renpy) {
            log.warn("convert: spec says Ren'Py but detected {s}", .{@tagName(engine)});
            return errs.Error.EngineMismatch;
        }

        // ---- version ----
        const detected_version_opt = try renpy.detectVersion(self.alloc, self.io, install_dir);
        defer if (detected_version_opt) |v| self.alloc.free(v);

        const version = recipe_sdk_version orelse (detected_version_opt orelse {
            log.warn("convert: no SDK version pinned + couldn't detect from install dir", .{});
            return errs.Error.VersionDetectFailed;
        });
        log.info("convert: Ren'Py {s} ({s})", .{ version, install_dir });

        // ---- launcher base ----
        const launcher = try renpy.findLauncherName(self.alloc, self.io, install_dir) orelse {
            log.warn("convert: no <name>.py / <name>.exe to base the launcher on", .{});
            return errs.Error.LauncherNotFound;
        };
        defer self.alloc.free(launcher);

        // ---- idempotency ----
        if (!force and renpy.alreadyConverted(self.io, install_dir, launcher)) {
            log.info("convert: install already converted ({s}.sh exists + lib/*linux*); use force=true to rebuild", .{launcher});
            return;
        }

        // ---- SDK cache lookup, with auto-fetch on miss ----
        const sdk_path = self.cache.locate("renpy", version) catch |e| switch (e) {
            errs.Error.SdkNotCached => blk: {
                log.info("Ren'Py {s} SDK not cached; fetching", .{version});
                break :blk try self.cache.fetch("renpy", version, prog);
            },
            else => return e,
        };
        defer self.alloc.free(sdk_path);

        // ---- copy libs ----
        // Drop any launcher from a previous convert first: a cancel or
        // failure mid-copy must not leave one pointing at a half-copied
        // runtime. The launcher is written last.
        if (prog.stop()) return errs.Error.Cancelled;
        var sh_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&sh_buf, "{s}/{s}.sh", .{ install_dir, launcher })) |sh_path| {
            std.Io.Dir.cwd().deleteFile(self.io, sh_path) catch {};
        } else |_| {}
        try renpy.installLinuxLibs(self.alloc, self.io, install_dir, sdk_path, prog);

        // ---- launcher ----
        if (prog.stop()) return errs.Error.Cancelled;
        prog.setPhase("Writing launcher");
        try renpy.writeLauncher(self.alloc, self.io, install_dir, launcher, self.distro == .nixos);
        log.info("convert: wrote {s}.sh (steam-run wrap: {})", .{ launcher, self.distro == .nixos });
    }
};

// Test discovery — pull in the nested files' `test {}` blocks since
// Zig 0.16 doesn't walk transitive imports for tests.
test {
    _ = detect_mod;
    _ = renpy;
    _ = rpgm;
    _ = sdk_cache_mod;
    _ = @import("domain.zig");
}
