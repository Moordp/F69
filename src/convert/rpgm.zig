// RPGM MV/MZ Win→Linux conversion. Ports `fix-linux-games.sh`'s RPGM
// path. Like the Ren'Py module, this assumes the nwjs SDK has been
// pre-extracted to `<cache>/f69/convert/sdks/nwjs-<version>/`.
//
// Round-20 in-scope: Chrome→nwjs version selection, SDK copy, launcher.
// Round-21 follow-ups:
//   - Network fetch of the nwjs tarball from dl.nwjs.io.
//   - Replacement of `lib/libffmpeg.so` with the codec-enabled build
//     from nwjs-ffmpeg-prebuilt (so MV4/MZ games that use mp4 audio
//     don't crash on a missing codec).
//   - `bundle_syslibs` ldd-driven host lib copy.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.convert_rpgm);
const errs = @import("errors.zig");
const dom = @import("domain.zig");
const sdk_cache_mod = @import("sdk_cache.zig");
const syslibs = @import("syslibs.zig");

/// Map Chrome major → nwjs version per https://nwjs.io/versions.json.
/// Keep the table here; new RPGM-era games extend it.
///
/// Mapping ported verbatim from the field-tested `fix-linux-games.sh`
/// — every Chrome major from 80 through 131 has a matching nwjs
/// release on dl.nwjs.io. Stick with these exact pairings; reaching
/// for "close enough" versions breaks games (Chromium 95 game on
/// nwjs 0.55 boots fine, on nwjs 0.50 crashes on icudtl version
/// skew — every Chrome major rebuilds icudtl).
pub fn chromeToNwjs(chrome_major: u16) ?[]const u8 {
    return switch (chrome_major) {
        // ----- pre-0.44 era (older RPGM MV titles) -------------
        // Mapping per https://nwjs.io/versions/. dl.nwjs.io
        // keeps the historical builds, so the SDK cache can
        // still pull these for the convert step.
        41 => "0.12.3",
        50 => "0.15.4",
        53 => "0.18.4",
        55 => "0.20.3",
        56 => "0.21.6",
        57 => "0.22.3",
        58 => "0.23.7",
        59 => "0.24.4",
        60 => "0.25.4",
        61 => "0.26.6",
        62 => "0.27.6",
        63 => "0.28.3",
        64 => "0.28.4",
        65 => "0.29.4",
        66 => "0.30.5",
        67 => "0.31.6",
        68 => "0.32.4",
        69 => "0.33.4",
        70 => "0.34.5",
        71 => "0.35.5",
        72 => "0.36.5",
        73 => "0.37.4",
        75 => "0.38.5",
        76 => "0.39.3",
        77 => "0.40.1",
        78 => "0.41.2",
        79 => "0.42.6",
        // ----- 0.44+ (modern RPGM MV / MZ) ---------------------
        80 => "0.44.6",
        85 => "0.48.4",
        86 => "0.49.2",
        87 => "0.50.3",
        88 => "0.51.2",
        89 => "0.52.2",
        90 => "0.53.1",
        91 => "0.54.1",
        92 => "0.55.0",
        93 => "0.56.1",
        94 => "0.57.1",
        95 => "0.58.0",
        96 => "0.59.1",
        97 => "0.60.0",
        98 => "0.61.1",
        99 => "0.62.2",
        100 => "0.63.1",
        101 => "0.64.1",
        102 => "0.65.1",
        103 => "0.66.1",
        104 => "0.67.1",
        105 => "0.68.1",
        106 => "0.69.1",
        107 => "0.70.1",
        108 => "0.71.1",
        109 => "0.72.0",
        110 => "0.73.0",
        111 => "0.74.0",
        112 => "0.75.0",
        113 => "0.76.1",
        114 => "0.77.0",
        115 => "0.78.1",
        116 => "0.79.1",
        117 => "0.80.0",
        118 => "0.81.0",
        119 => "0.82.0",
        120 => "0.83.0",
        121 => "0.84.0",
        122 => "0.85.0",
        123 => "0.86.0",
        124 => "0.87.0",
        125 => "0.88.0",
        126 => "0.89.0",
        127 => "0.90.0",
        128 => "0.91.0",
        129 => "0.92.0",
        130 => "0.93.0",
        131 => "0.94.0",
        else => null,
    };
}

/// Scan the game's bundled nwjs binary for its embedded Chrome version
/// string. Tries `nw.dll` then `nw_elf.dll`. Returns null when no
/// recognizable `Chrome/<digits>` string is found in the first 8 MiB.
pub fn detectChromeMajor(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
) errs.Error!?u16 {
    const candidates = [_][]const u8{ "nw.dll", "nw_elf.dll" };
    for (candidates) |name| {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ install_dir, name }) catch continue;
        if (findChromeInFile(alloc, io, path) catch null) |v| return v;
    }
    return null;
}

/// Prefix of nw.dll we scan for the ASCII `Chrome/<N>` user-agent
/// string. Modern nwjs builds (0.44+) embed this near the start of
/// the binary in Chromium's UA-string section.
pub const CHROME_SCAN_BYTES: usize = 8 * 1024 * 1024;

/// Tail of nw.dll we scan for the UTF-16LE PE VS_VERSION_INFO
/// resource. PE binaries lay their `.rsrc` section near the end of
/// the file by virtual-address ordering — on a typical ~80-130 MiB
/// nw.dll, the FileVersion string lives ~60-90 MiB into the file
/// (well past CHROME_SCAN_BYTES). 32 MiB covers every nwjs build
/// we've seen with margin. Only consulted when the ASCII fast
/// path fails.
pub const CHROME_TAIL_BYTES: usize = 32 * 1024 * 1024;

fn findChromeInFile(alloc: std.mem.Allocator, io: Io, path: []const u8) !?u16 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer f.close(io);

    // ---- Fast path: ASCII `Chrome/<N>` in the first 8 MiB. ----
    {
        const head_len = CHROME_SCAN_BYTES;
        const head = alloc.alloc(u8, head_len) catch return errs.Error.OutOfMemory;
        defer alloc.free(head);
        const got = f.readPositionalAll(io, head, 0) catch 0;
        if (got > 0) {
            if (parseChromeMajor(head[0..got])) |v| return v;
        }
    }

    // ---- Slow path: UTF-16LE PE FileVersion in the last 32 MiB. ----
    //
    // Older nwjs builds (Chrome 42-79 era) strip the `Chrome/<N>`
    // user-agent literal from data segments, but the PE
    // VS_VERSION_INFO resource still carries the chromium version
    // as a UTF-16LE FileVersion in the `.rsrc` section near the
    // end of the file.
    const st = f.stat(io) catch return null;
    const size = st.size;
    if (size == 0) return null;

    const tail_len: u64 = @min(@as(u64, CHROME_TAIL_BYTES), size);
    const offset: u64 = size - tail_len;

    const tail = alloc.alloc(u8, @intCast(tail_len)) catch return errs.Error.OutOfMemory;
    defer alloc.free(tail);
    const got = f.readPositionalAll(io, tail, offset) catch 0;
    if (got == 0) return null;
    return parseChromeMajorUtf16(tail[0..got]);
}

/// Pure. UTF-16LE scan for a Chromium `<major>.0.<build>.<patch>`
/// version string. PE binaries embed the FileVersion resource this
/// way; nwjs / Chromium derivatives always shape it as
/// `<chrome_major>.0.<build>.<patch>`, so the leading u16 IS the
/// chrome major. The `.0.` middle segment is the discriminator that
/// keeps this from matching arbitrary other 4-segment version
/// strings present in the binary's resource section.
///
/// `major` is clamped to [30, 200] — anything outside that range
/// is almost certainly noise. Chromium major numbers in real-world
/// nwjs builds run roughly 41..130.
pub fn parseChromeMajorUtf16(bytes: []const u8) ?u16 {
    if (bytes.len < 16) return null;
    var i: usize = 0;
    while (i + 16 < bytes.len) : (i += 1) {
        if (!std.ascii.isDigit(bytes[i]) or bytes[i + 1] != 0) continue;
        // Walk the major's digit run; require alternating <digit>\0.
        var end = i;
        while (end + 1 < bytes.len and std.ascii.isDigit(bytes[end]) and bytes[end + 1] == 0) {
            end += 2;
        }
        // Need: ".\0" "0\0" ".\0" right after.
        if (end + 6 > bytes.len) continue;
        if (bytes[end] != '.' or bytes[end + 1] != 0) continue;
        if (bytes[end + 2] != '0' or bytes[end + 3] != 0) continue;
        if (bytes[end + 4] != '.' or bytes[end + 5] != 0) continue;

        var digits: [8]u8 = undefined;
        var k: usize = 0;
        var p = i;
        while (p < end and k < digits.len) : (p += 2) {
            digits[k] = bytes[p];
            k += 1;
        }
        if (std.fmt.parseInt(u16, digits[0..k], 10)) |v| {
            if (v >= 30 and v <= 200) return v;
        } else |_| {}
    }
    return null;
}

/// Pure. Find the first `Chrome/<digits>` substring and return the
/// integer that follows. Skips matches whose digit run doesn't parse
/// as a u16.
pub fn parseChromeMajor(bytes: []const u8) ?u16 {
    const needle = "Chrome/";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, cursor, needle)) |pos| {
        const after = pos + needle.len;
        var end = after;
        while (end < bytes.len and std.ascii.isDigit(bytes[end])) : (end += 1) {}
        if (end > after) {
            if (std.fmt.parseInt(u16, bytes[after..end], 10)) |v| {
                return v;
            } else |_| {}
        }
        cursor = pos + 1;
    }
    return null;
}

/// Resolve the nwjs version to install for this game. Recipe pin wins;
/// otherwise scan the bundled nw.dll for its Chrome major then map
/// through `chromeToNwjs`. Returns null when neither yields a hit.
pub fn nwjsVersionFor(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    recipe_pin: ?[]const u8,
) errs.Error!?[]const u8 {
    if (recipe_pin) |v| return v;
    const chrome = try detectChromeMajor(alloc, io, install_dir);
    if (chrome) |c| return chromeToNwjs(c);
    return null;
}

// ============================================================
//  install: copy nwjs runtime into the install dir
// ============================================================

/// Copy the nwjs runtime files from `nwjs_sdk_dir` into `install_dir`.
/// Walks the SDK tree, copies everything except the noise list. We
/// reuse the same symlink-preserving / streaming / mode-preserving
/// copyTree shape as Ren'Py.
///
/// One walk counts the files + symlinks to copy, the second copies
/// them under phase "Copying runtime file i / n" with `tick(i, n)`.
/// `prog.stop()` is polled before each item → `Cancelled`.
pub fn installNwjs(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    nwjs_sdk_dir: []const u8,
    prog: dom.Progress,
) errs.Error!void {
    var sdk_dir = std.Io.Dir.cwd().openDir(io, nwjs_sdk_dir, .{ .access_sub_paths = true, .iterate = true }) catch return errs.Error.SdkLayoutInvalid;
    defer sdk_dir.close(io);

    std.Io.Dir.cwd().createDirPath(io, install_dir) catch return errs.Error.InstallNotFound;

    // ---- pass 1: count ----
    var total: u64 = 0;
    {
        var walker = sdk_dir.walk(alloc) catch return errs.Error.OutOfMemory;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (isSdkNoise(entry.path)) continue;
            switch (entry.kind) {
                .file, .sym_link => total += 1,
                else => {},
            }
        }
    }

    // ---- pass 2: copy ----
    var walker = sdk_dir.walk(alloc) catch return errs.Error.OutOfMemory;
    defer walker.deinit();

    var copied: u32 = 0;
    var done: u64 = 0;
    prog.tick(0, total);
    while (walker.next(io) catch null) |entry| {
        if (isSdkNoise(entry.path)) continue;

        var dst_buf: [1024]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ install_dir, entry.path }) catch return errs.Error.OutOfMemory;
        var src_buf: [1024]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ nwjs_sdk_dir, entry.path }) catch return errs.Error.OutOfMemory;

        switch (entry.kind) {
            .directory => std.Io.Dir.cwd().createDirPath(io, dest_path) catch return errs.Error.LauncherWriteFailed,
            .file, .sym_link => {
                if (prog.stop()) return errs.Error.Cancelled;
                setCopyPhase(prog, done + 1, total);
                if (entry.kind == .file) {
                    copyFile(io, src_path, dest_path) catch return errs.Error.LauncherWriteFailed;
                    copied += 1;
                } else {
                    copySymlink(alloc, io, src_path, dest_path) catch return errs.Error.LauncherWriteFailed;
                }
                done += 1;
                prog.tick(done, total);
            },
            else => {},
        }
    }

    if (copied == 0) {
        log.warn("nwjs SDK at {s} produced 0 file copies — layout suspect", .{nwjs_sdk_dir});
        return errs.Error.SdkLayoutInvalid;
    }
    log.info("installNwjs: copied {d} file(s) from {s} → {s}", .{ copied, nwjs_sdk_dir, install_dir });
}

/// Phase label for the i-th of n runtime copies.
fn setCopyPhase(prog: dom.Progress, i: u64, n: u64) void {
    var buf: [64]u8 = undefined;
    prog.setPhase(std.fmt.bufPrint(&buf, "Copying runtime file {d} / {d}", .{ i, n }) catch "Copying runtime file");
}

/// Remove `<install_dir>/<name>.sh` if present. Called right before a
/// (re-)convert starts overwriting the runtime: a launcher must never
/// point at a runtime that a cancelled or failed copy left half-done.
/// The new launcher is written as the last step.
pub fn dropLauncher(io: Io, install_dir: []const u8, name: []const u8) void {
    var buf: [512]u8 = undefined;
    const sh_path = std.fmt.bufPrint(&buf, "{s}/{s}.sh", .{ install_dir, name }) catch return;
    std.Io.Dir.cwd().deleteFile(io, sh_path) catch {};
}

/// Delete files left in `install_dir` from the original Windows nwjs
/// build that our Linux SDK didn't overwrite AND that would actively
/// break the runtime. Conservative list — limited to known offenders.
///
/// `v8_context_snapshot.bin` is the main culprit: ships with nwjs
/// ≥ 0.37 (Chromium 73+, V8 7.3+) but absent from older SDKs like
/// 0.29.4. When the older nwjs binary finds this file at startup it
/// reads it as a V8 snapshot, the header version disagrees with the
/// binary's V8 version, and the process FATALs with "Version
/// mismatch between V8 binary and snapshot." Deleting it (when our
/// SDK doesn't supply one) lets V8 fall back to the matching
/// `natives_blob.bin` + `snapshot_blob.bin` pair that we DID install.
fn pruneStaleNwjsFiles(io: Io, install_dir: []const u8, sdk_path: []const u8) !void {
    const STALE_IF_NOT_IN_SDK = [_][]const u8{
        "v8_context_snapshot.bin",
    };

    for (STALE_IF_NOT_IN_SDK) |name| {
        var sdk_buf: [640]u8 = undefined;
        const sdk_file = std.fmt.bufPrint(&sdk_buf, "{s}/{s}", .{ sdk_path, name }) catch continue;
        const sdk_has = (std.Io.Dir.cwd().access(io, sdk_file, .{}) catch null) != null;
        if (sdk_has) continue;

        var inst_buf: [640]u8 = undefined;
        const inst_file = std.fmt.bufPrint(&inst_buf, "{s}/{s}", .{ install_dir, name }) catch continue;
        const inst_has = (std.Io.Dir.cwd().access(io, inst_file, .{}) catch null) != null;
        if (!inst_has) continue;

        std.Io.Dir.cwd().deleteFile(io, inst_file) catch |e| {
            log.warn("prune-stale: failed to delete {s}: {s}", .{ inst_file, @errorName(e) });
            continue;
        };
        log.info("prune-stale: removed {s} (left by Windows nwjs, our SDK doesn't ship it)", .{name});
    }
}

/// Strip the executable-stack bit from every `*.so` inside `install_dir`
/// (recursively). Linux kernels ≥ 5.8 refuse to honor `PT_GNU_STACK = RWX`
/// on shared libraries at dlopen() time, with:
///
///   FATAL nw_content_renderer_hooks.cc: Failed to load node library
///     (libnode.so: cannot enable executable stack as shared object
///      requires: Invalid argument)
///
/// Older nwjs builds (Chrome 65 era and earlier) shipped `libnode.so`
/// with the bit set. We could shell out to `patchelf --clear-execstack`
/// — but that landed in 0.16 and nixpkgs has 0.15.2 right now. The
/// surgery is 4 bytes at a known offset, so do it in-process. Safe to
/// run unconditionally — `patchSoExecStack` no-ops on `.so` files that
/// already have the bit clear, or that have no PT_GNU_STACK segment.
fn clearExecstackOnSos(alloc: std.mem.Allocator, io: Io, install_dir: []const u8, prog: dom.Progress) !void {
    var dir = std.Io.Dir.cwd().openDir(io, install_dir, .{ .iterate = true, .access_sub_paths = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(alloc) catch return;
    defer walker.deinit();

    var patched: u32 = 0;
    var skipped: u32 = 0;
    var failed: u32 = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .unknown) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".so") and
            std.mem.indexOf(u8, entry.basename, ".so.") == null) continue;
        if (prog.stop()) return errs.Error.Cancelled;

        var path_buf: [640]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ install_dir, entry.path }) catch continue;
        switch (patchSoExecStack(io, full) catch .err) {
            .patched => patched += 1,
            .already_clear, .no_gnu_stack => skipped += 1,
            .not_elf, .err => failed += 1,
        }
    }
    log.info("clearExecstackOnSos: patched {d} so file(s), skipped {d}, failed {d}", .{ patched, skipped, failed });
}

const PatchSoResult = enum { patched, already_clear, no_gnu_stack, not_elf, err };

/// In-place ELF surgery: locate the `PT_GNU_STACK` program header
/// (`p_type == 0x6474e551`) and clear the X bit (`0x1`) in `p_flags`.
/// Supports ELF32 + ELF64, little-endian only (the universe of nwjs).
///
/// Reads the ELF header (max 64 bytes) and the single 4-byte p_flags
/// field that needs to change — no full-file read, no copy. Idempotent.
fn patchSoExecStack(io: Io, path: []const u8) !PatchSoResult {
    var f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch return .err;
    defer f.close(io);

    var ehdr: [64]u8 = undefined;
    const got = f.readPositionalAll(io, &ehdr, 0) catch return .err;
    if (got < 16) return .not_elf;
    if (!std.mem.eql(u8, ehdr[0..4], "\x7fELF")) return .not_elf;

    const ei_class = ehdr[4]; // 1 = ELF32, 2 = ELF64
    const ei_data = ehdr[5]; // 1 = LE, 2 = BE
    if (ei_data != 1) return .not_elf;

    var phoff: u64 = 0;
    var phentsize: u16 = 0;
    var phnum: u16 = 0;
    var p_flags_off_in_phdr: u32 = 0;

    if (ei_class == 2) {
        // ELF64: e_phoff @ 32 (u64), e_phentsize @ 54 (u16), e_phnum @ 56 (u16).
        // Phdr64: p_type(u32, off 0) p_flags(u32, off 4) p_offset(u64, off 8) ...
        if (got < 58) return .not_elf;
        phoff = std.mem.readInt(u64, ehdr[32..40], .little);
        phentsize = std.mem.readInt(u16, ehdr[54..56], .little);
        phnum = std.mem.readInt(u16, ehdr[56..58], .little);
        p_flags_off_in_phdr = 4;
    } else if (ei_class == 1) {
        // ELF32: e_phoff @ 28 (u32), e_phentsize @ 42 (u16), e_phnum @ 44 (u16).
        // Phdr32: p_type(u32, off 0) p_offset(u32, off 4) p_vaddr(u32, off 8)
        //         p_paddr(u32, off 12) p_filesz(u32, off 16) p_memsz(u32, off 20)
        //         p_flags(u32, off 24) p_align(u32, off 28)
        if (got < 46) return .not_elf;
        phoff = std.mem.readInt(u32, ehdr[28..32], .little);
        phentsize = std.mem.readInt(u16, ehdr[42..44], .little);
        phnum = std.mem.readInt(u16, ehdr[44..46], .little);
        p_flags_off_in_phdr = 24;
    } else return .not_elf;

    const PT_GNU_STACK: u32 = 0x6474e551;
    var i: u16 = 0;
    while (i < phnum) : (i += 1) {
        const phdr_pos: u64 = phoff + @as(u64, i) * @as(u64, phentsize);
        var ptype_buf: [4]u8 = undefined;
        if ((f.readPositionalAll(io, &ptype_buf, phdr_pos) catch 0) < 4) return .err;
        const p_type = std.mem.readInt(u32, &ptype_buf, .little);
        if (p_type != PT_GNU_STACK) continue;

        const flags_pos = phdr_pos + @as(u64, p_flags_off_in_phdr);
        var flags_buf: [4]u8 = undefined;
        if ((f.readPositionalAll(io, &flags_buf, flags_pos) catch 0) < 4) return .err;
        var p_flags = std.mem.readInt(u32, &flags_buf, .little);
        if ((p_flags & 0x1) == 0) return .already_clear;

        p_flags &= ~@as(u32, 0x1);
        std.mem.writeInt(u32, &flags_buf, p_flags, .little);
        f.writePositionalAll(io, &flags_buf, flags_pos) catch return .err;
        return .patched;
    }
    return .no_gnu_stack;
}

/// Files we don't want to drag into the game install. credits.html is
/// the nwjs license bundle — not load-bearing. The .nwb/.so/.exe-only
/// SDK-development bits aren't shipped to begin with.
fn isSdkNoise(path: []const u8) bool {
    return std.mem.eql(u8, path, "credits.html");
}

fn copyFile(io: Io, src: []const u8, dest: []const u8) !void {
    var in = try std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only });
    defer in.close(io);

    if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var out = try std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true });
    defer out.close(io);

    var rd_buf: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var wr_buf: [64 * 1024]u8 = undefined;
    var in_reader = in.reader(io, &rd_buf);
    var out_writer = out.writer(io, &wr_buf);
    while (true) {
        // readSliceShort aliases its source if the destination is the
        // reader's own backing buffer — keep them distinct.
        const got = in_reader.interface.readSliceShort(&chunk) catch break;
        if (got == 0) break;
        try out_writer.interface.writeAll(chunk[0..got]);
    }
    try out_writer.interface.flush();

    const st = in.stat(io) catch return;
    try out.setPermissions(io, st.permissions);
}

fn copySymlink(alloc: std.mem.Allocator, io: Io, src: []const u8, dest: []const u8) !void {
    const buf = try alloc.alloc(u8, 4096);
    defer alloc.free(buf);
    const n = try std.Io.Dir.cwd().readLink(io, src, buf);
    const target = buf[0..n];

    if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    std.Io.Dir.cwd().deleteFile(io, dest) catch {};
    try std.Io.Dir.cwd().symLink(io, target, dest, .{});
}

// ============================================================
//  launcher
// ============================================================

/// Pick the launcher base name. RPGM convention is `Game.exe`; some
/// games rename. Strategy:
///   1. First `Game.exe` (case-sensitive) wins.
///   2. Otherwise the first non-noise `*.exe` (skip crash handlers).
///   3. Fall back to "Game" if nothing matched.
pub fn findLauncherName(alloc: std.mem.Allocator, io: Io, install_dir: []const u8) errs.Error!?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, install_dir, .{ .access_sub_paths = true, .iterate = true }) catch return errs.Error.InstallNotFound;
    defer dir.close(io);

    var it = dir.iterate();
    var fallback: ?[]u8 = null;
    errdefer if (fallback) |x| alloc.free(x);

    while (it.next(io) catch null) |entry| {
        // Accept `.unknown` alongside `.file` — FUSE NTFS / exFAT
        // mounts surface every readdir entry as `.unknown`.
        if (entry.kind != .file and entry.kind != .unknown) continue;
        if (!std.mem.endsWith(u8, entry.name, ".exe")) continue;
        if (std.mem.startsWith(u8, entry.name, "notification_helper")) continue;
        if (std.mem.startsWith(u8, entry.name, "crashpad_handler")) continue;
        if (std.mem.eql(u8, entry.name, "nw.exe")) continue; // nwjs runtime, not the game

        const base = entry.name[0 .. entry.name.len - 4];
        if (std.mem.eql(u8, base, "Game")) {
            if (fallback) |x| alloc.free(x);
            return alloc.dupe(u8, base) catch errs.Error.OutOfMemory;
        }
        if (fallback == null) {
            fallback = alloc.dupe(u8, base) catch return errs.Error.OutOfMemory;
        }
    }
    if (fallback) |x| return x;
    return alloc.dupe(u8, "Game") catch errs.Error.OutOfMemory;
}

/// Minimal fonts.conf the launcher hands to legacy-Chromium nwjs
/// (anything below ~0.44, where Chromium bundled fontconfig 2.13+).
/// Older nwjs (Chrome 65 era) bundles fontconfig ~2.11; that parser
/// chokes on the `<description>` element NixOS's modern
/// `/etc/fonts/fonts.conf` uses → InitDefaultFont fails → FATAL.
///
/// This config uses only elements present in fontconfig 2.10 (the
/// universal-old baseline), points at the FHS font dirs steam-run
/// exposes, plus user-local dirs. Modern distros provide
/// `/usr/share/fonts` natively; under steam-run NixOS also exposes
/// it through the FHS env. Either way fonts get resolved.
const LEGACY_FONTS_CONF: []const u8 =
    \\<?xml version="1.0"?>
    \\<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    \\<!-- f69-generated fontconfig for legacy-Chromium nwjs (~Chrome 65 era).
    \\     The system fonts.conf uses elements added in fontconfig 2.13+
    \\     ('<description>' etc.) which chromium-65's bundled parser fails
    \\     on; replacing it with this minimal config restores font lookup. -->
    \\<fontconfig>
    \\    <dir>/usr/share/fonts</dir>
    \\    <dir>/usr/local/share/fonts</dir>
    \\    <dir>~/.fonts</dir>
    \\    <dir>~/.local/share/fonts</dir>
    \\    <cachedir>~/.cache/fontconfig</cachedir>
    \\    <cachedir>/var/cache/fontconfig</cachedir>
    \\</fontconfig>
    \\
;

/// nwjs 0.44 is the cutoff: ships Chromium 80, whose bundled
/// fontconfig is 2.13+ (handles modern `<description>` etc.). Below
/// that we need the legacy compat fonts.conf shipped next to the
/// launcher.
pub fn nwjsIsLegacyChromium(nwjs_version: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, nwjs_version, '.');
    _ = it.next() orelse return false; // skip leading "0"
    const minor_str = it.next() orelse return false;
    const minor = std.fmt.parseInt(u32, minor_str, 10) catch return false;
    return minor < 44;
}

/// Write the Linux launcher script. The same template covers MV and
/// MZ — nwjs `./nw .` reads `package.json`'s `main` and figures the
/// rest out itself. When `legacy_chromium`, a compat fonts.conf is
/// also written next to the launcher and the script exports
/// `FONTCONFIG_FILE` to point at it.
pub fn writeLauncher(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    name: []const u8,
    wrap_steam_run: bool,
    legacy_chromium: bool,
) errs.Error!void {
    const content = renderLauncher(alloc, wrap_steam_run, legacy_chromium) catch return errs.Error.OutOfMemory;
    defer alloc.free(content);

    var path_buf: [512]u8 = undefined;
    const sh_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.sh", .{ install_dir, name }) catch return errs.Error.OutOfMemory;

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sh_path, .data = content }) catch return errs.Error.LauncherWriteFailed;

    var f = std.Io.Dir.cwd().openFile(io, sh_path, .{ .mode = .read_write }) catch return errs.Error.LauncherWriteFailed;
    defer f.close(io);
    f.setPermissions(io, .executable_file) catch return errs.Error.LauncherWriteFailed;

    if (legacy_chromium) {
        var fc_buf: [512]u8 = undefined;
        const fc_path = std.fmt.bufPrint(&fc_buf, "{s}/f69-fonts.conf", .{install_dir}) catch return errs.Error.OutOfMemory;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fc_path, .data = LEGACY_FONTS_CONF }) catch return errs.Error.LauncherWriteFailed;
    }
}

/// Pure. Returns the launcher script body. GDK_BACKEND=x11 is forced
/// when Wayland is in use because older nwjs (pre-0.50) lacks Wayland
/// support; for newer nwjs the override is harmless (chromium honors
/// the env var as a hint, then negotiates).
pub fn renderLauncher(alloc: std.mem.Allocator, wrap_steam_run: bool, legacy_chromium: bool) ![]u8 {
    const exec_prefix = if (wrap_steam_run) "exec steam-run " else "exec ";
    const fontconfig_export: []const u8 = if (legacy_chromium)
        "# Legacy Chromium (nwjs < 0.44) ships fontconfig ~2.11 which can't\n" ++
            "# parse modern system fonts.conf. Point it at a compatibility config\n" ++
            "# f69's convert step wrote next to this launcher.\n" ++
            "export FONTCONFIG_FILE=\"$(pwd)/f69-fonts.conf\"\n\n"
    else
        "";
    return std.fmt.allocPrint(alloc,
        \\#!/usr/bin/env bash
        \\# auto-generated RPGM (nwjs) Linux launcher (f69)
        \\cd "$(dirname "$(readlink -f "$0")")"
        \\
        \\export LD_LIBRARY_PATH="$(pwd):${{LD_LIBRARY_PATH:-}}"
        \\
        \\# Strip 32-bit-only LD_PRELOAD entries (NixOS systemwide
        \\# `extest` is 32-bit only; nwjs / mkxp-z are 64-bit so the
        \\# loader logs noisy "wrong ELF class" warnings for every
        \\# subprocess. Filter them out instead of inheriting the env
        \\# unmodified.)
        \\if [ -n "${{LD_PRELOAD:-}}" ]; then
        \\  filtered=$(printf "%s" "$LD_PRELOAD" | tr ' :' '\n\n' | grep -v extest | tr '\n' ' ')
        \\  export LD_PRELOAD="${{filtered% }}"
        \\fi
        \\
        \\# Force X11 on Wayland — older nwjs has no Wayland support; newer
        \\# (≥ 0.50) safely accepts the hint.
        \\if [ -n "${{WAYLAND_DISPLAY:-}}" ]; then
        \\  export GDK_BACKEND="x11"
        \\fi
        \\
        \\# Per-install nwjs profile dir. Without this, nwjs falls back to
        \\# `~/.config/<chromium-app-name>/` which is shared with every
        \\# other chromium-based app the user has run; old nwjs builds
        \\# (Chrome 65 era) print "profile is from a newer version of
        \\# NW.js" because newer chromiums migrated the schema forward
        \\# in-place. Anchoring the profile here keeps each game's state
        \\# self-contained and avoids the mismatch.
        \\PROFILE_DIR="$(pwd)/.nwjs-profile"
        \\mkdir -p "$PROFILE_DIR"
        \\
        \\{s}if [ ! -x "./nw" ]; then echo "nw binary missing — convert step incomplete" >&2; exit 1; fi
        \\
        \\{s}"./nw" --user-data-dir="$PROFILE_DIR" . "$@"
        \\
    , .{ fontconfig_export, exec_prefix });
}

// ============================================================
//  idempotency
// ============================================================

/// Already-converted check: launcher exists AND `./nw` is present +
/// executable.
pub fn alreadyConverted(io: Io, install_dir: []const u8, launcher_base: []const u8) bool {
    var sh_buf: [512]u8 = undefined;
    const sh_path = std.fmt.bufPrint(&sh_buf, "{s}/{s}.sh", .{ install_dir, launcher_base }) catch return false;
    std.Io.Dir.cwd().access(io, sh_path, .{}) catch return false;

    var nw_buf: [512]u8 = undefined;
    const nw_path = std.fmt.bufPrint(&nw_buf, "{s}/nw", .{install_dir}) catch return false;
    std.Io.Dir.cwd().access(io, nw_path, .{ .execute = true }) catch return false;
    return true;
}

// ============================================================
//  orchestrator — called from convert/service.zig
// ============================================================

pub fn convert(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    cache: *sdk_cache_mod.Cache,
    distro: dom.Distro,
    recipe_pin_nwjs: ?[]const u8,
    ffmpeg_codecs: bool,
    bundle_syslibs: bool,
    force: bool,
    prog: dom.Progress,
) errs.Error!void {
    std.Io.Dir.cwd().access(io, install_dir, .{}) catch return errs.Error.InstallNotFound;

    const version = try nwjsVersionFor(alloc, io, install_dir, recipe_pin_nwjs) orelse {
        log.warn("convert: no nwjs version pinned + couldn't detect from nw.dll", .{});
        return errs.Error.VersionDetectFailed;
    };
    log.info("convert: nwjs {s} ({s})", .{ version, install_dir });

    const launcher = try findLauncherName(alloc, io, install_dir) orelse {
        log.warn("convert: no <name>.exe to base the launcher on", .{});
        return errs.Error.LauncherNotFound;
    };
    defer alloc.free(launcher);

    if (!force and alreadyConverted(io, install_dir, launcher)) {
        log.info("convert: install already converted ({s}.sh + ./nw exist); use force=true to rebuild", .{launcher});
        return;
    }

    const sdk_path = cache.locate("nwjs", version) catch |e| switch (e) {
        errs.Error.SdkNotCached => blk: {
            log.info("nwjs {s} SDK not cached; fetching", .{version});
            break :blk try cache.fetch("nwjs", version, prog);
        },
        else => return e,
    };
    defer alloc.free(sdk_path);

    if (prog.stop()) return errs.Error.Cancelled;
    // From here the runtime is being replaced — drop any launcher from a
    // previous convert so a cancel/failure can't leave one pointing at a
    // half-copied runtime. `writeLauncher` below is the last step.
    dropLauncher(io, install_dir, launcher);
    try installNwjs(alloc, io, install_dir, sdk_path, prog);

    // Prune stale nwjs files left from the original Windows install
    // that our (older-era) Linux SDK didn't overwrite. Specifically:
    // `v8_context_snapshot.bin` ships with nwjs ≥ 0.37 (Chromium 73+)
    // but the V8 6.5 binary in nwjs 0.29.4 also tries to load it if
    // present — and fails with "Version mismatch between V8 binary
    // and snapshot" because the file's V8 8.0+ header doesn't match.
    // Best-effort: missing patchelf-style spawn, just delete the file.
    pruneStaleNwjsFiles(io, install_dir, sdk_path) catch |e| {
        log.warn("prune-stale: {s} (game may FATAL on V8 snapshot mismatch)", .{@errorName(e)});
    };

    // Linux kernel ≥ 5.8 rejects dlopen of shared libs with
    // PT_GNU_STACK=RWX. Older nwjs (Chrome 65 era) ships libnode.so
    // with that bit set; strip it from every .so we just dropped.
    // No-op when patchelf isn't available — best-effort.
    prog.setPhase("Patching libraries");
    clearExecstackOnSos(alloc, io, install_dir, prog) catch |e| {
        if (e == errs.Error.Cancelled) return errs.Error.Cancelled;
        log.warn("clear-execstack pass failed ({s}); old nwjs libs may fail to load on modern kernels", .{@errorName(e)});
    };

    // Optional codec-enabled libffmpeg.so swap. Many F95 RPGM MZ games
    // ship .m4a / .mp4 assets that the stripped libffmpeg can't decode
    // — without this they crash on first audio cue. Recipe opts out
    // via `ffmpeg_codecs: false`.
    if (ffmpeg_codecs) {
        installFfmpegCodecs(alloc, io, cache, install_dir, version, prog) catch |e| {
            if (e == errs.Error.Cancelled) return errs.Error.Cancelled;
            log.warn("ffmpeg codec swap failed: {s} (game may crash on .mp4 / .m4a audio)", .{@errorName(e)});
        };
    }

    if (bundle_syslibs) {
        if (prog.stop()) return errs.Error.Cancelled;
        prog.setPhase("Patching libraries");
        syslibs.bundle(alloc, io, install_dir, "nw", distro) catch |e| {
            log.warn("syslib bundle failed: {s} (game may crash on missing libs)", .{@errorName(e)});
        };
    }

    if (prog.stop()) return errs.Error.Cancelled;
    prog.setPhase("Writing launcher");
    const legacy = nwjsIsLegacyChromium(version);
    try writeLauncher(alloc, io, install_dir, launcher, distro == .nixos, legacy);
    log.info("convert: wrote {s}.sh (steam-run wrap: {}, legacy fontconfig: {})", .{ launcher, distro == .nixos, legacy });
}

// ============================================================
//  RPG Maker XP / VX / VX Ace via vendored mkxp-z
// ============================================================
//
// Unlike the MV/MZ path (which copies an nwjs SDK INTO the game),
// mkxp-z is a shared binary that lives in f69's install tree. The
// per-game convert step just writes a small bash launcher that
// `cd`s into the game directory and execs the bundled binary —
// mkxp-z then reads `Game.rgss3a` / `*.rvdata2` / `Data/` from the
// cwd just like RGSS does on Windows.
//
// Engine probe is best-effort: we look for any of the canonical
// VX/VX Ace markers and bail with a clear log line if none match.
// The launcher is named `run-mkxp-z.sh` rather than re-using the
// `<exe-basename>.sh` convention so a future re-detection (e.g.
// engine miscalled VX Ace when it was actually MV) doesn't clobber
// a nwjs launcher.

/// Probe paths for VX Ace (RGSS3). `Game.rvproj2` is the unencrypted
/// project file present in non-archived installs; `Game.rgss3a` is the
/// encrypted archive variant; `System/RGSS3xx.dll` is the runtime DLL
/// (always in the `System/` subdir, NOT at install root — easy to miss).
/// Including all three covers every layout we've seen in F95 archives.
const VX_ACE_MARKERS = [_][]const u8{
    "Game.rvproj2",
    "Game.rgss3a",
    "System/RGSS300.dll",
    "System/RGSS301.dll",
    "System/RGSS302.dll",
    "RGSS300.dll",
    "RGSS301.dll",
    "RGSS302.dll",
};
const VX_MARKERS = [_][]const u8{
    "Game.rvproj",
    "Game.rgssad",
    "System/RGSS202E.dll",
    "System/RGSS202J.dll",
    "System/RGSS200E.dll",
    "RGSS202E.dll",
    "RGSS202J.dll",
    "RGSS200E.dll",
};
const XP_MARKERS = [_][]const u8{
    "Game.rxproj",
    "System/RGSS104E.dll",
    "System/RGSS103E.dll",
    "System/RGSS102E.dll",
    "RGSS104E.dll",
    "RGSS103E.dll",
    "RGSS102E.dll",
};

/// Marker probe — supports both flat names ("Game.rgss3a") and
/// subdir paths ("System/RGSS300.dll"). Stat-only, no walks.
fn anyMarkerPresent(io: Io, install_dir: []const u8, markers: []const []const u8) bool {
    for (markers) |m| {
        var buf: [640]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ install_dir, m }) catch continue;
        std.Io.Dir.cwd().access(io, full, .{}) catch continue;
        return true;
    }
    return false;
}

/// Convert an RPG Maker XP / VX / VX Ace install for Linux launch via
/// the vendored mkxp-z binary at `mkxp_z_dir`. Writes
/// `<install_dir>/run-mkxp-z.sh` + chmod +x; mkxp-z reads game data
/// from the cwd at launch time.
///
/// `extra_libs_dir`: optional directory whose `.so` files supplement
/// the launcher's LD_LIBRARY_PATH. NixOS hosts use this to provide
/// `libstdc++.so.6` (the only system dep mkxp-z doesn't statically
/// link); other distros pass null.
///
/// Idempotent — re-runs overwrite the launcher with the current
/// `mkxp_z_dir`, which is correct: if f69 moved, the absolute path
/// inside the previous launcher would be stale and re-convert is the
/// right answer.
pub const MKXP_ZOOM_MIN: f32 = 0.5;
pub const MKXP_ZOOM_MAX: f32 = 4.0;
pub const MKXP_ZOOM_DEFAULT: f32 = 2.0;
pub const MKXP_ZOOM_STATE_FILE: []const u8 = ".mkxp-zoom";

/// Read the per-install mkxp zoom override from `<install>/.mkxp-zoom`.
/// Returns null when the file is missing or unparseable, in which
/// case the caller substitutes `MKXP_ZOOM_DEFAULT`. Out-of-range
/// values are clamped, not rejected.
pub fn readMkxpZoom(io: Io, install_dir: []const u8) ?f32 {
    var path_buf: [640]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ install_dir, MKXP_ZOOM_STATE_FILE }) catch return null;
    var f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer f.close(io);
    var buf: [32]u8 = undefined;
    const got = f.readPositionalAll(io, &buf, 0) catch return null;
    if (got == 0) return null;
    const text = std.mem.trim(u8, buf[0..got], " \t\r\n");
    const v = std.fmt.parseFloat(f32, text) catch return null;
    return std.math.clamp(v, MKXP_ZOOM_MIN, MKXP_ZOOM_MAX);
}

/// Write the zoom override. Clamps the value to the allowed range
/// so a stray UI value can't poison the file. Same idempotency as
/// the launcher write — overwrites in place.
pub fn writeMkxpZoom(io: Io, install_dir: []const u8, zoom: f32) errs.Error!void {
    const clamped = std.math.clamp(zoom, MKXP_ZOOM_MIN, MKXP_ZOOM_MAX);
    var text_buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "{d:.2}\n", .{clamped}) catch return errs.Error.OutOfMemory;
    var path_buf: [640]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ install_dir, MKXP_ZOOM_STATE_FILE }) catch return errs.Error.OutOfMemory;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch return errs.Error.LauncherWriteFailed;
}

pub fn convertVxAce(
    alloc: std.mem.Allocator,
    io: Io,
    install_dir: []const u8,
    mkxp_z_dir: []const u8,
    extra_libs_dir: ?[]const u8,
    zoom: f32,
    force: bool,
    prog: dom.Progress,
) errs.Error!void {
    _ = force; // re-running is always safe (single file write)

    std.Io.Dir.cwd().access(io, install_dir, .{}) catch return errs.Error.InstallNotFound;

    // Bundle sanity. If the build didn't copy third_party/mkxp-z/ in
    // (non-Linux build, or vendored tree absent) bail with a clear
    // error rather than write a launcher that points at nothing.
    var bin_buf: [640]u8 = undefined;
    const bin_path = std.fmt.bufPrint(&bin_buf, "{s}/mkxp-z.x86_64", .{mkxp_z_dir}) catch return errs.Error.OutOfMemory;
    std.Io.Dir.cwd().access(io, bin_path, .{}) catch {
        log.warn("convertVxAce: mkxp-z bundle missing at {s}", .{bin_path});
        return errs.Error.MkxpZNotBundled;
    };

    const variant = detectRgssVariant(io, install_dir);
    log.info("convertVxAce: detected RGSS variant {s} ({s})", .{ @tagName(variant), install_dir });

    if (prog.stop()) return errs.Error.Cancelled;
    prog.setPhase("Patching libraries");

    // mkxp.json overrides mkxp-z's Game.ini auto-detect. Some F95
    // RPGM VX Ace archives ship a Game.ini that mkxp-z's INI parser
    // mis-reads (encoding probe fails, falls back to RGSS1 / XP). An
    // explicit `rgssVersion` here forces the right runtime regardless
    // of what the parser concludes from Game.ini.
    if (variant != .unknown) {
        const clamped_zoom = std.math.clamp(zoom, MKXP_ZOOM_MIN, MKXP_ZOOM_MAX);
        const json = try renderMkxpJson(alloc, variant, clamped_zoom);
        defer alloc.free(json);
        var json_buf: [640]u8 = undefined;
        const json_path = std.fmt.bufPrint(&json_buf, "{s}/mkxp.json", .{install_dir}) catch return errs.Error.OutOfMemory;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = json_path, .data = json }) catch return errs.Error.LauncherWriteFailed;
        log.info("convertVxAce: wrote {s} (rgssVersion pinned, zoom {d:.2}x)", .{ json_path, clamped_zoom });

        // Persist the zoom alongside the install so re-Converts pick
        // up the user's choice (and so the UI dropdown can read it
        // back to render the current selection).
        writeMkxpZoom(io, install_dir, clamped_zoom) catch |e| {
            log.warn("convertVxAce: write .mkxp-zoom failed: {s}", .{@errorName(e)});
        };
    }

    // Make mkxp-z's `SDL_GetBasePath()` resolve to the install dir
    // so it picks up the per-game `mkxp.json` we just wrote. mkxp-z
    // reads its config from the BINARY's dir (via /proc/self/exe →
    // dirname), NOT the cwd, so the launcher's `cd $GAME_DIR + exec
    // <bundle>/mkxp-z.x86_64` pattern reads from the SHARED bundle's
    // mkxp.json (the commented-out template → rgssVersion defaults
    // to 0 → fallback to RGSS1).
    //
    // Fix: hardlink the binary into the install dir AND symlink the
    // sibling resource dirs (scripts/, stdlib/). When the launcher
    // execs `./mkxp-z.x86_64`, /proc/self/exe resolves to the
    // hardlink's path → SDL_GetBasePath returns the install dir →
    // mkxp-z reads `<install>/mkxp.json` and honors rgssVersion.
    //
    // Hardlink (not symlink) on the binary: symlinks would resolve
    // back to the bundle path. Hardlinks share an inode, and the
    // exec-time path is what /proc/self/exe surfaces. Both NTFS-3g
    // and ext4 support cross-name hardlinks within the same mount.
    try ensureLocalMkxpZBinary(io, install_dir, mkxp_z_dir);

    // Launcher last, so a stop or failure above never leaves a fresh
    // launcher next to an incomplete setup.
    if (prog.stop()) return errs.Error.Cancelled;
    prog.setPhase("Writing launcher");

    const content = try renderMkxpZLauncher(alloc, mkxp_z_dir, extra_libs_dir);
    defer alloc.free(content);

    var path_buf: [640]u8 = undefined;
    const sh_path = std.fmt.bufPrint(&path_buf, "{s}/run-mkxp-z.sh", .{install_dir}) catch return errs.Error.OutOfMemory;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sh_path, .data = content }) catch return errs.Error.LauncherWriteFailed;

    var f = std.Io.Dir.cwd().openFile(io, sh_path, .{ .mode = .read_write }) catch return errs.Error.LauncherWriteFailed;
    defer f.close(io);
    f.setPermissions(io, .executable_file) catch return errs.Error.LauncherWriteFailed;

    log.info("convertVxAce: wrote {s}", .{sh_path});
}

/// Idempotent linker. Creates (or replaces) `<install>/mkxp-z.x86_64`
/// as a hardlink of the bundle binary, and `<install>/scripts` +
/// `<install>/stdlib` as symlinks into the bundle. Best-effort — any
/// individual failure is logged and `convertVxAce` continues, because
/// the older "exec from bundle" launcher path still mostly works
/// (just without the per-game config benefit).
fn ensureLocalMkxpZBinary(io: Io, install_dir: []const u8, mkxp_z_dir: []const u8) errs.Error!void {
    const cwd = std.Io.Dir.cwd();

    // 1. Hardlink the binary. `linkAt` with replace doesn't exist
    // in std; emulate by deleteFile-then-link. Failures bubble.
    var src_buf: [640]u8 = undefined;
    const src_bin = std.fmt.bufPrint(&src_buf, "{s}/mkxp-z.x86_64", .{mkxp_z_dir}) catch return errs.Error.OutOfMemory;
    var dst_buf: [640]u8 = undefined;
    const dst_bin = std.fmt.bufPrint(&dst_buf, "{s}/mkxp-z.x86_64", .{install_dir}) catch return errs.Error.OutOfMemory;
    cwd.deleteFile(io, dst_bin) catch {}; // ignore "not found"
    cwd.hardLink(src_bin, cwd, dst_bin, io, .{}) catch |e| {
        log.warn("convertVxAce: hardlink {s} → {s} failed: {s}", .{ src_bin, dst_bin, @errorName(e) });
        return; // soft failure — game will still launch off bundle binary
    };

    // 2. Symlink scripts/ and stdlib/. Symlinks fine here — mkxp-z
    // reads these via standard path resolution (relative to cwd or
    // SDL_GetBasePath), which transparently follows symlinks. Using
    // absolute targets so the launcher's cwd change doesn't matter.
    inline for (.{ "scripts", "stdlib" }) |name| {
        var s_buf: [640]u8 = undefined;
        const target = std.fmt.bufPrint(&s_buf, "{s}/{s}", .{ mkxp_z_dir, name }) catch return errs.Error.OutOfMemory;
        var d_buf: [640]u8 = undefined;
        const linkpath = std.fmt.bufPrint(&d_buf, "{s}/{s}", .{ install_dir, name }) catch return errs.Error.OutOfMemory;
        cwd.deleteFile(io, linkpath) catch {};
        cwd.symLink(io, target, linkpath, .{}) catch |e| {
            log.warn("convertVxAce: symlink {s} → {s} failed: {s}", .{ target, linkpath, @errorName(e) });
        };
    }

    log.info("convertVxAce: linked mkxp-z + sibs into {s} (per-game mkxp.json now active)", .{install_dir});
}

/// Pure. Minimal mkxp.json that pins the RGSS version, picks a
/// reasonable default window size, and disables free window resize.
/// mkxp-z reads this from `<install>/mkxp.json` at startup
/// (resolved via `SDL_GetBasePath` against the hardlinked binary,
/// which is why convertVxAce hardlinks the binary into the install
/// dir).
///
/// `winResizable: false` is here because mkxp-z's Wayland surface
/// management has a known wp_viewport bug on resize: the source
/// rectangle keeps the pre-resize dimensions, ending up bigger than
/// the new content area → Wayland protocol error → game shuts down.
/// Disabling free resize is a low-cost workaround. The game's own
/// scripts CAN still call `Graphics.resize_screen` — that path
/// doesn't hit the same Wayland issue.
///
/// `defScreenW/H` are the INITIAL window dimensions before the
/// game's scripts run. Default to 2× the RGSS-version native
/// resolution so the game doesn't open at a tiny 544×416 / 640×480
/// box on modern monitors. Games that customize via
/// `Graphics.resize_screen` will override this anyway.
pub fn renderMkxpJson(alloc: std.mem.Allocator, variant: RgssVariant, zoom: f32) errs.Error![]u8 {
    const rgss_version: u32 = switch (variant) {
        .xp => 1,
        .vx => 2,
        .vx_ace => 3,
        .unknown => 0, // let mkxp-z auto-detect; caller should skip writing in this case
    };
    // Native RGSS resolutions × user-chosen zoom factor.
    //   RGSS1 (XP):           640 × 480
    //   RGSS2 (VX):           544 × 416
    //   RGSS3 (VX Ace):       544 × 416 (same as VX)
    // Zoom comes from the per-install `.mkxp-zoom` file (or default
    // 2.0); the UI dropdown writes that file in 0.25 increments.
    const native_w_f: f32 = switch (variant) {
        .xp => 640.0,
        .vx, .vx_ace => 544.0,
        .unknown => 640.0,
    };
    const native_h_f: f32 = switch (variant) {
        .xp => 480.0,
        .vx, .vx_ace => 416.0,
        .unknown => 480.0,
    };
    const z = std.math.clamp(zoom, MKXP_ZOOM_MIN, MKXP_ZOOM_MAX);
    const def_w: u32 = @intFromFloat(@round(native_w_f * z));
    const def_h: u32 = @intFromFloat(@round(native_h_f * z));
    return std.fmt.allocPrint(alloc,
        \\{{
        \\    "rgssVersion": {d},
        \\    "winResizable": false,
        \\    "defScreenW": {d},
        \\    "defScreenH": {d}
        \\}}
        \\
    , .{ rgss_version, def_w, def_h }) catch errs.Error.OutOfMemory;
}

pub const RgssVariant = enum { xp, vx, vx_ace, unknown };

pub fn detectRgssVariant(io: Io, install_dir: []const u8) RgssVariant {
    if (anyMarkerPresent(io, install_dir, &VX_ACE_MARKERS)) return .vx_ace;
    if (anyMarkerPresent(io, install_dir, &VX_MARKERS)) return .vx;
    if (anyMarkerPresent(io, install_dir, &XP_MARKERS)) return .xp;
    return .unknown;
}

/// Pure. Returns the mkxp-z launcher script body.
///
/// Two non-obvious bits: (1) the script captures its OWN dir via
/// readlink — symlinking the launcher into ~/.local/bin etc. then
/// still has it `cd` into the game data dir; (2) we hard-code the
/// mkxp-z absolute path at convert time, not lookup-via-PATH, so
/// the launcher works without f69 being on $PATH or running.
pub fn renderMkxpZLauncher(
    alloc: std.mem.Allocator,
    mkxp_z_dir: []const u8,
    extra_libs_dir: ?[]const u8,
) errs.Error![]u8 {
    const libs_export = if (extra_libs_dir) |d|
        std.fmt.allocPrint(alloc, "export LD_LIBRARY_PATH=\"{s}:${{LD_LIBRARY_PATH:-}}\"\n", .{d}) catch return errs.Error.OutOfMemory
    else
        alloc.dupe(u8, "") catch return errs.Error.OutOfMemory;
    defer alloc.free(libs_export);

    return std.fmt.allocPrint(alloc,
        \\#!/usr/bin/env bash
        \\# auto-generated mkxp-z launcher (f69) — RPG Maker XP / VX / VX Ace
        \\set -e
        \\
        \\GAME_DIR="$(dirname "$(readlink -f "$0")")"
        \\MKXP_Z_DIR="${{F69_MKXP_Z_DIR:-{s}}}"
        \\
        \\# Strip 32-bit-only LD_PRELOAD entries — see the nwjs launcher
        \\# for the full explanation. NixOS's `extest` LD_PRELOAD is
        \\# 32-bit; mkxp-z is 64-bit; without this each launch logs a
        \\# noisy "wrong ELF class" warning.
        \\if [ -n "${{LD_PRELOAD:-}}" ]; then
        \\  filtered=$(printf "%s" "$LD_PRELOAD" | tr ' :' '\n\n' | grep -v extest | tr '\n' ' ')
        \\  export LD_PRELOAD="${{filtered% }}"
        \\fi
        \\
        \\# Disable SDL2's HiDPI awareness. mkxp-z has a known Wayland
        \\# bug where `Graphics.resize_screen` (a Ruby-side game script
        \\# call) leaves the wp_viewport source rectangle at the HiDPI-
        \\# scaled pre-resize size, ending up bigger than the post-
        \\# resize content area. The Wayland compositor then closes
        \\# the surface ("wp_viewport error 2") and mkxp-z shuts down.
        \\# Forcing logical-pixel-size surfaces (no HiDPI scaling)
        \\# keeps the viewport math consistent across resizes.
        \\export SDL_VIDEO_HIGHDPI_DISABLED=1
        \\
        \\# Prefer the hardlinked binary the Convert step dropped into
        \\# the game dir — mkxp-z reads its mkxp.json from the binary's
        \\# own directory (via /proc/self/exe + dirname), and we wrote
        \\# a per-game mkxp.json there with the correct rgssVersion.
        \\# Without the local hardlink mkxp-z would read the shared
        \\# bundle config (rgssVersion default 0 → auto-detect fails
        \\# on the F95 Game.ini → falls back to RGSS1 / RPG Maker XP).
        \\# Fall back to the bundle binary if the local hardlink is
        \\# missing (older convert that pre-dates this fix).
        \\if [ -x "$GAME_DIR/mkxp-z.x86_64" ]; then
        \\  MKXP_BIN="$GAME_DIR/mkxp-z.x86_64"
        \\elif [ -x "$MKXP_Z_DIR/mkxp-z.x86_64" ]; then
        \\  MKXP_BIN="$MKXP_Z_DIR/mkxp-z.x86_64"
        \\else
        \\  echo "f69: mkxp-z binary missing — re-run Convert after rebuilding f69." >&2
        \\  exit 1
        \\fi
        \\
        \\{s}cd "$GAME_DIR"
        \\exec "$MKXP_BIN" "$@"
        \\
    , .{ mkxp_z_dir, libs_export }) catch errs.Error.OutOfMemory;
}

/// True when `run-mkxp-z.sh` exists and points at the current
/// `mkxp_z_dir`. f69 doesn't currently call this — convertVxAce is
/// always safe to re-run — but the predicate is here for parity with
/// the nwjs path's `alreadyConverted` helper.
pub fn alreadyConvertedMkxpZ(io: Io, install_dir: []const u8) bool {
    var sh_buf: [512]u8 = undefined;
    const sh_path = std.fmt.bufPrint(&sh_buf, "{s}/run-mkxp-z.sh", .{install_dir}) catch return false;
    std.Io.Dir.cwd().access(io, sh_path, .{}) catch return false;
    return true;
}

/// Fetch the codec-enabled libffmpeg.so from nwjs-ffmpeg-prebuilt and
/// overwrite the SDK's stripped copy at `<install>/lib/libffmpeg.so`.
/// The prebuilt release versions track nwjs versions 1:1.
pub fn installFfmpegCodecs(
    alloc: std.mem.Allocator,
    io: Io,
    cache: *sdk_cache_mod.Cache,
    install_dir: []const u8,
    nwjs_version: []const u8,
    prog: dom.Progress,
) errs.Error!void {
    const sdk_path = try cache.fetch("nwjs-ffmpeg", nwjs_version, prog);
    defer alloc.free(sdk_path);
    if (prog.stop()) return errs.Error.Cancelled;
    prog.setPhase("Patching libraries");

    var src_buf: [640]u8 = undefined;
    const src = std.fmt.bufPrint(&src_buf, "{s}/libffmpeg.so", .{sdk_path}) catch return errs.Error.OutOfMemory;
    std.Io.Dir.cwd().access(io, src, .{}) catch {
        log.warn("ffmpeg prebuilt at {s} has no libffmpeg.so — release layout changed?", .{sdk_path});
        return errs.Error.SdkLayoutInvalid;
    };

    var dst_buf: [640]u8 = undefined;
    const dst = std.fmt.bufPrint(&dst_buf, "{s}/lib/libffmpeg.so", .{install_dir}) catch return errs.Error.OutOfMemory;

    copyFile(io, src, dst) catch return errs.Error.LauncherWriteFailed;
    log.info("ffmpeg codec swap: {s} → {s}", .{ src, dst });
}

// ============================================================
//  tests
// ============================================================

const testing = std.testing;

test "chromeToNwjs: known entries" {
    try testing.expectEqualStrings("0.83.0", chromeToNwjs(120).?);
    try testing.expectEqualStrings("0.12.3", chromeToNwjs(41).?);
    try testing.expectEqualStrings("0.93.0", chromeToNwjs(130).?);
}

test "chromeToNwjs: unknown major → null" {
    try testing.expect(chromeToNwjs(7) == null);
    try testing.expect(chromeToNwjs(200) == null);
}

test "parseChromeMajor: basic" {
    try testing.expectEqual(@as(u16, 120), parseChromeMajor("blob ... Chrome/120.0.6099.123 zlib").?);
}

test "parseChromeMajor: takes first match" {
    // First "Chrome/N" wins even if a stale value appears later.
    try testing.expectEqual(@as(u16, 80), parseChromeMajor("Chrome/80\nlater Chrome/120").?);
}

test "parseChromeMajor: missing → null" {
    try testing.expect(parseChromeMajor("nothing here") == null);
}

test "parseChromeMajor: 'Chrome/' followed by non-digits → null" {
    try testing.expect(parseChromeMajor("Chrome/foo and Chrome/bar") == null);
}

test "chromeToNwjs: covers Chrome 65 (older RPGM MV)" {
    try testing.expectEqualStrings("0.29.4", chromeToNwjs(65).?);
    try testing.expectEqualStrings("0.42.6", chromeToNwjs(79).?);
}

fn utf16leLit(comptime s: []const u8) [s.len * 2]u8 {
    var out: [s.len * 2]u8 = undefined;
    for (s, 0..) |c, i| {
        out[i * 2] = c;
        out[i * 2 + 1] = 0;
    }
    return out;
}

test "parseChromeMajorUtf16: matches PE FileVersion shape" {
    const buf = utf16leLit("65.0.3325.146");
    try testing.expectEqual(@as(u16, 65), parseChromeMajorUtf16(&buf).?);
}

test "parseChromeMajorUtf16: requires `.0.` middle segment" {
    // 1.2.3.4 — second segment is "2", not "0", so it isn't Chromium.
    const buf = utf16leLit("1.2.3.4");
    try testing.expect(parseChromeMajorUtf16(&buf) == null);
}

test "parseChromeMajorUtf16: clamps wild majors" {
    // "5.0.1.1" — major 5 is below the 30 floor.
    const buf = utf16leLit("5.0.1.1");
    try testing.expect(parseChromeMajorUtf16(&buf) == null);
}

test "parseChromeMajorUtf16: surrounded by noise" {
    const prefix = utf16leLit(".Global\\");
    const ver = utf16leLit("87.0.4280.66");
    const suffix = utf16leLit("\"%ls\"");
    var buf: [prefix.len + ver.len + suffix.len]u8 = undefined;
    @memcpy(buf[0..prefix.len], &prefix);
    @memcpy(buf[prefix.len..][0..ver.len], &ver);
    @memcpy(buf[prefix.len + ver.len ..][0..suffix.len], &suffix);
    try testing.expectEqual(@as(u16, 87), parseChromeMajorUtf16(&buf).?);
}

test "parseChromeMajor: skips bad match, finds good one" {
    // First match's digit run doesn't parse as u16 (too long); skip to next.
    try testing.expectEqual(@as(u16, 100), parseChromeMajor("Chrome/99999999999 then Chrome/100.0").?);
}

test "renderLauncher: NixOS steam-run wrap" {
    const out = try renderLauncher(testing.allocator, true, false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "exec steam-run") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"./nw\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "GDK_BACKEND") != null);
    try testing.expect(std.mem.indexOf(u8, out, "FONTCONFIG_FILE") == null);
    try testing.expect(std.mem.indexOf(u8, out, "--user-data-dir=\"$PROFILE_DIR\"") != null);
}

test "renderLauncher: plain exec on non-NixOS" {
    const out = try renderLauncher(testing.allocator, false, false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "steam-run") == null);
    try testing.expect(std.mem.indexOf(u8, out, "exec \"./nw\" --user-data-dir=\"$PROFILE_DIR\"") != null);
}

test "renderLauncher: cd to script dir + LD_LIBRARY_PATH" {
    const out = try renderLauncher(testing.allocator, false, false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "#!/usr/bin/env bash"));
    try testing.expect(std.mem.indexOf(u8, out, "LD_LIBRARY_PATH=\"$(pwd)") != null);
}

test "renderLauncher: legacy_chromium exports FONTCONFIG_FILE" {
    const out = try renderLauncher(testing.allocator, true, true);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "FONTCONFIG_FILE=\"$(pwd)/f69-fonts.conf\"") != null);
}

test "nwjsIsLegacyChromium: cutoff at 0.44" {
    try testing.expect(nwjsIsLegacyChromium("0.29.4"));
    try testing.expect(nwjsIsLegacyChromium("0.43.0"));
    try testing.expect(!nwjsIsLegacyChromium("0.44.6"));
    try testing.expect(!nwjsIsLegacyChromium("0.83.0"));
    try testing.expect(!nwjsIsLegacyChromium("0.93.0"));
}

test "nwjsIsLegacyChromium: malformed input → not legacy" {
    try testing.expect(!nwjsIsLegacyChromium(""));
    try testing.expect(!nwjsIsLegacyChromium("garbage"));
    try testing.expect(!nwjsIsLegacyChromium("0"));
}

test "patchSoExecStack: ELF64 RWX → RW (X bit cleared)" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "patchelf-elf64");
    defer env.deinit();

    // Hand-built minimal ELF64 LE with a single PT_GNU_STACK phdr at
    // flags=RWE (7). Layout: 64-byte ehdr + one 56-byte phdr at offset 64.
    var buf: [64 + 56]u8 = std.mem.zeroes([64 + 56]u8);
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 2; // ELF64
    buf[5] = 1; // little-endian
    std.mem.writeInt(u64, buf[32..40], 64, .little); // e_phoff
    std.mem.writeInt(u16, buf[54..56], 56, .little); // e_phentsize
    std.mem.writeInt(u16, buf[56..58], 1, .little); // e_phnum
    // phdr @ 64: p_type=PT_GNU_STACK, p_flags=7 (RWE)
    std.mem.writeInt(u32, buf[64..68], 0x6474e551, .little);
    std.mem.writeInt(u32, buf[68..72], 7, .little);

    try env.writeFile("fake.so", &buf);
    const fake_path = try env.path("fake.so");
    defer testing.allocator.free(fake_path);

    try testing.expectEqual(PatchSoResult.patched, try patchSoExecStack(env.io, fake_path));

    // Re-open + verify p_flags is now 6 (RW, X cleared).
    var f = try std.Io.Dir.cwd().openFile(env.io, fake_path, .{ .mode = .read_only });
    defer f.close(env.io);
    var probe: [4]u8 = undefined;
    _ = try f.readPositionalAll(env.io, &probe, 68);
    try testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, &probe, .little));

    // Idempotency — second call reports already_clear, doesn't toggle.
    try testing.expectEqual(PatchSoResult.already_clear, try patchSoExecStack(env.io, fake_path));
}

test "patchSoExecStack: no PT_GNU_STACK phdr → no_gnu_stack" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "patchelf-no-stack");
    defer env.deinit();

    var buf: [64 + 56]u8 = std.mem.zeroes([64 + 56]u8);
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 2;
    buf[5] = 1;
    std.mem.writeInt(u64, buf[32..40], 64, .little);
    std.mem.writeInt(u16, buf[54..56], 56, .little);
    std.mem.writeInt(u16, buf[56..58], 1, .little);
    // p_type = PT_LOAD (1), not GNU_STACK
    std.mem.writeInt(u32, buf[64..68], 1, .little);

    try env.writeFile("loadonly.so", &buf);
    const path = try env.path("loadonly.so");
    defer testing.allocator.free(path);

    try testing.expectEqual(PatchSoResult.no_gnu_stack, try patchSoExecStack(env.io, path));
}

test "patchSoExecStack: non-ELF input → not_elf" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "patchelf-not-elf");
    defer env.deinit();

    try env.writeFile("plain.so", "this is not an ELF binary at all");
    const path = try env.path("plain.so");
    defer testing.allocator.free(path);

    try testing.expectEqual(PatchSoResult.not_elf, try patchSoExecStack(env.io, path));
}

test "isSdkNoise: credits.html" {
    try testing.expect(isSdkNoise("credits.html"));
    try testing.expect(!isSdkNoise("nw"));
    try testing.expect(!isSdkNoise("lib/libffmpeg.so"));
}

test "nwjsVersionFor: recipe pin wins" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    const v = try nwjsVersionFor(testing.allocator, io, "/nonexistent", "0.83.0");
    try testing.expect(v != null);
    try testing.expectEqualStrings("0.83.0", v.?);
}

test "nwjsVersionFor: no pin + no nw.dll → null" {
    var tio = std.Io.Threaded.init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    // /tmp is unlikely to have nw.dll.
    const v = try nwjsVersionFor(testing.allocator, io, "/tmp", null);
    try testing.expect(v == null);
}

test "renderMkxpZLauncher: hard-codes mkxp_z_dir as fallback" {
    const out = try renderMkxpZLauncher(testing.allocator, "/opt/f69/data/mkxp-z", null);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "#!/usr/bin/env bash"));
    try testing.expect(std.mem.indexOf(u8, out, "MKXP_Z_DIR=\"${F69_MKXP_Z_DIR:-/opt/f69/data/mkxp-z}\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "exec \"$MKXP_BIN\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "$GAME_DIR/mkxp-z.x86_64") != null);
    try testing.expect(std.mem.indexOf(u8, out, "cd \"$GAME_DIR\"") != null);
    // Bundle binary is the FALLBACK path (when the local hardlink
    // is missing) — not the primary `exec`. Just check it's in the
    // dispatch ladder, not that it's exec'd directly.
    try testing.expect(std.mem.indexOf(u8, out, "$MKXP_Z_DIR/mkxp-z.x86_64") != null);
    // No extra LD_LIBRARY_PATH line when extra_libs_dir is null.
    try testing.expect(std.mem.indexOf(u8, out, "export LD_LIBRARY_PATH") == null);
}

test "renderMkxpZLauncher: extra_libs_dir adds LD_LIBRARY_PATH export" {
    const out = try renderMkxpZLauncher(
        testing.allocator,
        "/opt/f69/data/mkxp-z",
        "/opt/f69/data/compat-resources/mkxp-z-fhs-libs/lib",
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "export LD_LIBRARY_PATH=\"/opt/f69/data/compat-resources/mkxp-z-fhs-libs/lib") != null);
}

test "detectRgssVariant: VX Ace via flat RGSS301.dll" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "rpgm-vxace-flat");
    defer env.deinit();

    try env.touchFile("RGSS301.dll");

    try testing.expectEqual(RgssVariant.vx_ace, detectRgssVariant(env.io, env.root));
}

test "detectRgssVariant: VX Ace via System/RGSS300.dll (canonical layout)" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "rpgm-vxace-system");
    defer env.deinit();

    try env.touchFile("System/RGSS300.dll");

    try testing.expectEqual(RgssVariant.vx_ace, detectRgssVariant(env.io, env.root));
}

test "detectRgssVariant: VX Ace via Game.rvproj2" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "rpgm-vxace-proj");
    defer env.deinit();

    try env.touchFile("Game.rvproj2");

    try testing.expectEqual(RgssVariant.vx_ace, detectRgssVariant(env.io, env.root));
}

test "detectRgssVariant: VX via System/RGSS202E.dll" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "rpgm-vx-system");
    defer env.deinit();

    try env.touchFile("System/RGSS202E.dll");

    try testing.expectEqual(RgssVariant.vx, detectRgssVariant(env.io, env.root));
}

test "detectRgssVariant: XP via Game.rxproj" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "rpgm-xp-proj");
    defer env.deinit();

    try env.touchFile("Game.rxproj");

    try testing.expectEqual(RgssVariant.xp, detectRgssVariant(env.io, env.root));
}

test "detectRgssVariant: unknown when no markers" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "rpgm-empty");
    defer env.deinit();

    try testing.expectEqual(RgssVariant.unknown, detectRgssVariant(env.io, env.root));
}

test "pruneStaleNwjsFiles: deletes v8_context_snapshot.bin when SDK lacks it" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "prune-stale");
    defer env.deinit();

    try env.mkdirP("install");
    try env.writeFile("install/v8_context_snapshot.bin", "from-windows-nwjs");
    try env.mkdirP("sdk");
    // SDK does NOT have v8_context_snapshot.bin (mimics nwjs 0.29.4 layout).

    const install_dir = try env.path("install");
    defer testing.allocator.free(install_dir);
    const sdk_dir = try env.path("sdk");
    defer testing.allocator.free(sdk_dir);

    try pruneStaleNwjsFiles(env.io, install_dir, sdk_dir);

    const dropped = try env.path("install/v8_context_snapshot.bin");
    defer testing.allocator.free(dropped);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(env.io, dropped, .{}));
}

test "pruneStaleNwjsFiles: keeps v8_context_snapshot.bin when SDK supplies it" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "prune-keep");
    defer env.deinit();

    try env.mkdirP("install");
    try env.writeFile("install/v8_context_snapshot.bin", "from-windows-nwjs");
    try env.mkdirP("sdk");
    try env.writeFile("sdk/v8_context_snapshot.bin", "from-linux-sdk");

    const install_dir = try env.path("install");
    defer testing.allocator.free(install_dir);
    const sdk_dir = try env.path("sdk");
    defer testing.allocator.free(sdk_dir);

    try pruneStaleNwjsFiles(env.io, install_dir, sdk_dir);

    const kept = try env.path("install/v8_context_snapshot.bin");
    defer testing.allocator.free(kept);
    try std.Io.Dir.cwd().access(env.io, kept, .{}); // still there
}

test "convertVxAce: writes executable run-mkxp-z.sh + verifies bundle" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "rpgm-convert-vxace");
    defer env.deinit();

    // Stage a fake bundle.
    try env.mkdirP("mkxp-z-bundle");
    try env.writeFile("mkxp-z-bundle/mkxp-z.x86_64", "fake-elf");

    try env.mkdirP("game");
    try env.touchFile("game/RGSS301.dll");

    const game_dir = try env.path("game");
    defer testing.allocator.free(game_dir);
    const mkxp_dir = try env.path("mkxp-z-bundle");
    defer testing.allocator.free(mkxp_dir);

    try convertVxAce(testing.allocator, env.io, game_dir, mkxp_dir, null, MKXP_ZOOM_DEFAULT, false, .none);

    const sh_rel = "game/run-mkxp-z.sh";
    const sh_abs = try env.path(sh_rel);
    defer testing.allocator.free(sh_abs);
    std.Io.Dir.cwd().access(env.io, sh_abs, .{ .execute = true }) catch |e| {
        std.debug.print("expected run-mkxp-z.sh to be executable: {s} ({s})\n", .{ sh_abs, @errorName(e) });
        return e;
    };

    // alreadyConvertedMkxpZ recognises the resulting launcher.
    try testing.expect(alreadyConvertedMkxpZ(env.io, game_dir));
}

test "convertVxAce: returns MkxpZNotBundled when bundle missing" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "rpgm-no-bundle");
    defer env.deinit();

    try env.mkdirP("game");
    const game_dir = try env.path("game");
    defer testing.allocator.free(game_dir);

    try testing.expectError(
        errs.Error.MkxpZNotBundled,
        convertVxAce(testing.allocator, env.io, game_dir, "/nonexistent/bundle", null, MKXP_ZOOM_DEFAULT, false, .none),
    );
}

// ---- progress / cancel through the full MV/MZ convert ----

/// Records what a `dom.Progress` saw. `cancel_after` > 0 makes
/// `cancelled` return true once that many non-zero ticks arrived.
const ProgressRecorder = struct {
    alloc: std.mem.Allocator,
    phases: std.ArrayList([]u8) = .empty,
    last_done: u64 = 0,
    last_total: u64 = 0,
    nonzero_ticks: usize = 0,
    cancel_after: usize = 0,

    fn deinit(self: *ProgressRecorder) void {
        for (self.phases.items) |p| self.alloc.free(p);
        self.phases.deinit(self.alloc);
    }

    fn progress(self: *ProgressRecorder) dom.Progress {
        return .{ .ctx = self, .phase = onPhase, .report = onTick, .cancelled = onCancelled };
    }

    fn onPhase(ctx: ?*anyopaque, text: []const u8) void {
        const self: *ProgressRecorder = @ptrCast(@alignCast(ctx.?));
        const dup = self.alloc.dupe(u8, text) catch return;
        self.phases.append(self.alloc, dup) catch self.alloc.free(dup);
    }

    fn onTick(ctx: ?*anyopaque, done: u64, total: u64) void {
        const self: *ProgressRecorder = @ptrCast(@alignCast(ctx.?));
        self.last_done = done;
        self.last_total = total;
        if (done > 0) self.nonzero_ticks += 1;
    }

    fn onCancelled(ctx: ?*anyopaque) bool {
        const self: *ProgressRecorder = @ptrCast(@alignCast(ctx.?));
        return self.cancel_after > 0 and self.nonzero_ticks >= self.cancel_after;
    }

    fn sawPhasePrefix(self: *const ProgressRecorder, prefix: []const u8) bool {
        for (self.phases.items) |p| if (std.mem.startsWith(u8, p, prefix)) return true;
        return false;
    }
};

/// Fake nwjs SDK (20 files: `nw`, `lib/*.so`, `locales/*.pak`, misc)
/// pre-staged in the cache as nwjs-0.83.0, plus a fake MV install with
/// `Game.exe` + `www/index.html` + `package.json`.
fn stageFakeNwjsConvert(env: anytype) !void {
    const sdk = "convert/sdks/nwjs-0.83.0";
    try env.writeFile(sdk ++ "/nw", "fake-nw-binary");
    {
        // +x on the SDK's nw — copyFile carries the mode into the install.
        const nw = try env.path(sdk ++ "/nw");
        defer testing.allocator.free(nw);
        var f = try std.Io.Dir.cwd().openFile(env.io, nw, .{ .mode = .read_write });
        defer f.close(env.io);
        try f.setPermissions(env.io, .executable_file);
    }
    try env.writeFile(sdk ++ "/credits.html", "noise — must be skipped");
    try env.writeFile(sdk ++ "/icudtl.dat", "icu");
    try env.writeFile(sdk ++ "/nw.pak", "pak");
    try env.writeFile(sdk ++ "/resources.pak", "pak");
    try env.writeFile(sdk ++ "/snapshot_blob.bin", "snap");
    try env.writeFile(sdk ++ "/v8_context_snapshot.bin", "snap");
    try env.writeFile(sdk ++ "/lib/libnode.so", "not-an-elf");
    try env.writeFile(sdk ++ "/lib/libffmpeg.so", "not-an-elf");
    try env.writeFile(sdk ++ "/lib/libnw.so", "not-an-elf");
    inline for (.{ "en-US", "de", "fr", "ja", "zh-CN", "es", "it", "ko", "pt-BR", "ru", "nl" }) |loc| {
        try env.writeFile(sdk ++ "/locales/" ++ loc ++ ".pak", loc);
    }
    try env.writeFile("game/Game.exe", "MZ");
    try env.writeFile("game/www/index.html", "<html></html>");
    try env.writeFile("game/package.json", "{\"main\":\"www/index.html\"}");
}

test "convert: phases + ticks through runtime copy and launcher" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "rpgm-convert-progress");
    defer env.deinit();
    try stageFakeNwjsConvert(&env);

    var cache = try sdk_cache_mod.Cache.init(testing.allocator, env.io, env.root);
    defer cache.deinit();
    const game_dir = try env.path("game");
    defer testing.allocator.free(game_dir);

    var rec: ProgressRecorder = .{ .alloc = testing.allocator };
    defer rec.deinit();

    try convert(testing.allocator, env.io, game_dir, &cache, .other, "0.83.0", false, false, false, rec.progress());

    try testing.expect(rec.sawPhasePrefix("Copying runtime file"));
    try testing.expect(rec.sawPhasePrefix("Patching libraries"));
    try testing.expect(rec.sawPhasePrefix("Writing launcher"));
    // Launcher is the final phase.
    try testing.expectEqualStrings("Writing launcher", rec.phases.items[rec.phases.items.len - 1]);
    try testing.expectEqualStrings("Copying runtime file 20 / 20", blk: {
        var last_copy: []const u8 = "";
        for (rec.phases.items) |p| if (std.mem.startsWith(u8, p, "Copying runtime file")) {
            last_copy = p;
        };
        break :blk last_copy;
    });
    try testing.expect(rec.last_total > 0);
    try testing.expectEqual(rec.last_total, rec.last_done);
    try testing.expectEqual(@as(u64, 20), rec.last_total);

    const sh = try env.path("game/Game.sh");
    defer testing.allocator.free(sh);
    try std.Io.Dir.cwd().access(env.io, sh, .{ .execute = true });
    try testing.expect(alreadyConverted(env.io, game_dir, "Game"));
}

test "convert: cancel after the first tick → Cancelled, no launcher left behind" {
    var env = try @import("util_test_env").TestEnv.init(testing.allocator, "rpgm-convert-cancel");
    defer env.deinit();
    try stageFakeNwjsConvert(&env);
    // A launcher from an earlier convert: a cancelled re-convert must not
    // leave it pointing at the half-copied runtime.
    try env.writeFile("game/Game.sh", "#!/bin/sh\nexec ./nw .\n");

    var cache = try sdk_cache_mod.Cache.init(testing.allocator, env.io, env.root);
    defer cache.deinit();
    const game_dir = try env.path("game");
    defer testing.allocator.free(game_dir);

    var rec: ProgressRecorder = .{ .alloc = testing.allocator, .cancel_after = 1 };
    defer rec.deinit();

    try testing.expectError(
        errs.Error.Cancelled,
        convert(testing.allocator, env.io, game_dir, &cache, .other, "0.83.0", false, false, true, rec.progress()),
    );
    try testing.expectEqual(@as(usize, 1), rec.nonzero_ticks);
    try testing.expect(!rec.sawPhasePrefix("Writing launcher"));

    const sh = try env.path("game/Game.sh");
    defer testing.allocator.free(sh);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(env.io, sh, .{}));
}
