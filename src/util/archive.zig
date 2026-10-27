// Thin Zig wrapper around libarchive's read API for the formats
// stdlib doesn't cover: .7z, .tar.bz2, .tar.xz, .rar. The system
// libarchive (statically linked via flake.nix's libarchive-static)
// already bundles bz2 + xz + zlib decompressors, so this module
// adds zero runtime deps.
//
// Public API mirrors `downloads/archive.zig`'s extract entry point:
//     pub fn extractFile(io, archive_path, dest_dir, opts) Error!void
// `opts.strip` peels leading path components — matches the tar
// helper's contract.

const std = @import("std");

const c = @import("c");

pub const Error = error{
    /// libarchive returned ARCHIVE_FATAL during open / read header /
    /// read data. The error string from libarchive is logged.
    ExtractionFailed,
    /// The destination directory couldn't be created or the
    /// archive file couldn't be opened.
    IoFailed,
    OutOfMemory,
};

pub const ExtractOpts = struct {
    /// Drop this many leading path components from each archive
    /// entry's pathname before writing to disk. Mirrors `tar
    /// --strip-components=N`. 0 = preserve full archive structure.
    strip: u8 = 0,
};

/// Extract `archive_path` into `dest_dir`. Creates `dest_dir` if
/// missing. Auto-detects the format + filter chain — libarchive's
/// `archive_read_support_format_all` + `archive_read_support_filter_all`
/// handle every format the static lib was built with.
pub fn extractFile(
    archive_path: []const u8,
    dest_dir: []const u8,
    opts: ExtractOpts,
) Error!void {
    // libarchive needs C-string paths. ~~Stack-allocated~~ heap-allocated
    // (path lengths can exceed any reasonable stack buffer for nested
    // game installs).
    var path_buf: [4096]u8 = undefined;
    if (archive_path.len + 1 > path_buf.len) return Error.IoFailed;
    @memcpy(path_buf[0..archive_path.len], archive_path);
    path_buf[archive_path.len] = 0;
    const c_archive_path: [*:0]const u8 = @ptrCast(&path_buf);

    // libarchive reads via a struct archive*, writes to disk via
    // a separate struct archive* configured with
    // archive_write_disk_set_options. Linking them: read each entry's
    // header, write to disk, then loop copying data blocks.
    const a = c.archive_read_new() orelse return Error.OutOfMemory;
    defer _ = c.archive_read_free(a);

    _ = c.archive_read_support_format_all(a);
    _ = c.archive_read_support_filter_all(a);

    const ext = c.archive_write_disk_new() orelse return Error.OutOfMemory;
    defer _ = c.archive_write_free(ext);

    // Restore permissions + timestamps + extract sub-paths.
    // ACL/xattr disabled in the flake build so leave them off here.
    _ = c.archive_write_disk_set_options(ext, c.ARCHIVE_EXTRACT_TIME |
        c.ARCHIVE_EXTRACT_PERM |
        c.ARCHIVE_EXTRACT_FFLAGS |
        c.ARCHIVE_EXTRACT_SECURE_NODOTDOT |
        c.ARCHIVE_EXTRACT_SECURE_SYMLINKS);
    _ = c.archive_write_disk_set_standard_lookup(ext);

    if (c.archive_read_open_filename(a, c_archive_path, 16 * 1024) != c.ARCHIVE_OK) {
        std.log.warn("libarchive: open failed: {s}", .{c.archive_error_string(a)});
        return Error.IoFailed;
    }

    while (true) {
        var entry: ?*c.archive_entry = null;
        const rc = c.archive_read_next_header(a, &entry);
        if (rc == c.ARCHIVE_EOF) break;
        if (rc < c.ARCHIVE_OK) {
            std.log.warn("libarchive: header read: {s}", .{c.archive_error_string(a)});
        }
        if (rc < c.ARCHIVE_WARN) return Error.ExtractionFailed;

        // Apply strip + prefix the destination dir. Entry pathname is
        // a UTF-8 (or platform-native) string allocated inside the
        // entry; we rewrite it before handing to archive_write_header.
        //
        // Both `_utf8` and the plain accessor can return NULL when
        // libarchive can't decode the source pathname (e.g. Windows
        // zips with UTF-16LE filenames and no UTF-8 BOM under a
        // non-UTF-8 locale). The orelse chain in earlier code yielded
        // a still-null optional that crashed when coerced; we now
        // skip these entries with a warning instead of panicking.
        const orig_path: [*:0]const u8 = if (c.archive_entry_pathname_utf8(entry)) |p|
            p
        else if (c.archive_entry_pathname(entry)) |p|
            p
        else {
            std.log.warn("libarchive: skipping entry — pathname not decodable (likely UTF-16LE zip; set LC_ALL=C.UTF-8 or repack the archive)", .{});
            continue;
        };
        const stripped = stripComponents(orig_path, opts.strip) orelse continue;

        var combined_buf: [4096]u8 = undefined;
        const written = std.fmt.bufPrint(&combined_buf, "{s}/{s}", .{ dest_dir, std.mem.span(stripped) }) catch return Error.IoFailed;
        if (written.len >= combined_buf.len) return Error.IoFailed;
        combined_buf[written.len] = 0;
        const combined_z: [*:0]const u8 = @ptrCast(&combined_buf);
        c.archive_entry_set_pathname_utf8(entry, combined_z);

        if (c.archive_write_header(ext, entry) < c.ARCHIVE_OK) {
            std.log.warn("libarchive: write header: {s}", .{c.archive_error_string(ext)});
            continue;
        }
        // Copy data blocks. Skipped for entries with no data
        // (directories, symlinks).
        if (c.archive_entry_size(entry) > 0) {
            try copyData(a, ext);
        }
        if (c.archive_write_finish_entry(ext) < c.ARCHIVE_OK) {
            std.log.warn("libarchive: finish entry: {s}", .{c.archive_error_string(ext)});
        }
    }

    if (c.archive_read_close(a) != c.ARCHIVE_OK) {
        std.log.warn("libarchive: close: {s}", .{c.archive_error_string(a)});
    }
}

fn copyData(a: ?*c.archive, ext: ?*c.archive) Error!void {
    while (true) {
        var block: ?*const anyopaque = null;
        var size: usize = 0;
        var offset: c.la_int64_t = 0;
        const rc = c.archive_read_data_block(a, &block, &size, &offset);
        if (rc == c.ARCHIVE_EOF) return;
        if (rc < c.ARCHIVE_OK) {
            std.log.warn("libarchive: read block: {s}", .{c.archive_error_string(a)});
            return Error.ExtractionFailed;
        }
        if (c.archive_write_data_block(ext, block, size, offset) < c.ARCHIVE_OK) {
            std.log.warn("libarchive: write block: {s}", .{c.archive_error_string(ext)});
            return Error.ExtractionFailed;
        }
    }
}

/// Cap on how many entries `listEntries` returns. Real-world mod
/// archives are tens-to-low-thousands of files; the cap is a safety
/// net against pathological inputs slowing the preset matcher.
pub const LIST_ENTRIES_CAP: usize = 10_000;

/// Read every entry header in `archive_path` and return their
/// pathnames as an owned `[][]u8`. Does NOT extract — purely walks the
/// header chain. Used by the preset matcher to decide which install
/// pattern an archive looks like.
///
/// Paths are libarchive-decoded (UTF-8 when available, platform-native
/// fallback); the caller treats them as forward-slash separated.
/// Caller owns the returned slice + each inner string and must free
/// via `freeEntryList`.
pub fn listEntries(alloc: std.mem.Allocator, archive_path: []const u8) Error![][]u8 {
    var path_buf: [4096]u8 = undefined;
    if (archive_path.len + 1 > path_buf.len) return Error.IoFailed;
    @memcpy(path_buf[0..archive_path.len], archive_path);
    path_buf[archive_path.len] = 0;
    const c_archive_path: [*:0]const u8 = @ptrCast(&path_buf);

    const a = c.archive_read_new() orelse return Error.OutOfMemory;
    defer _ = c.archive_read_free(a);

    _ = c.archive_read_support_format_all(a);
    _ = c.archive_read_support_filter_all(a);

    if (c.archive_read_open_filename(a, c_archive_path, 16 * 1024) != c.ARCHIVE_OK) {
        std.log.warn("libarchive: open failed: {s}", .{c.archive_error_string(a)});
        return Error.IoFailed;
    }

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }

    while (out.items.len < LIST_ENTRIES_CAP) {
        var entry: ?*c.archive_entry = null;
        const rc = c.archive_read_next_header(a, &entry);
        if (rc == c.ARCHIVE_EOF) break;
        if (rc < c.ARCHIVE_OK) {
            std.log.warn("libarchive: header read: {s}", .{c.archive_error_string(a)});
        }
        if (rc < c.ARCHIVE_WARN) return Error.ExtractionFailed;

        const raw: [*:0]const u8 = if (c.archive_entry_pathname_utf8(entry)) |p|
            p
        else if (c.archive_entry_pathname(entry)) |p|
            p
        else continue;
        const slice = std.mem.span(raw);
        const owned = alloc.dupe(u8, slice) catch return Error.OutOfMemory;
        out.append(alloc, owned) catch {
            alloc.free(owned);
            return Error.OutOfMemory;
        };
    }

    _ = c.archive_read_close(a);
    return out.toOwnedSlice(alloc) catch Error.OutOfMemory;
}

/// Companion free for `listEntries`. Frees each entry + the outer slice.
pub fn freeEntryList(alloc: std.mem.Allocator, entries: [][]u8) void {
    for (entries) |s| alloc.free(s);
    alloc.free(entries);
}

/// One archive entry's metadata. Same path field as `listEntries`
/// but carries the libarchive-reported size + dir flag. Used by the
/// wizard's install simulator to compute per-step write counts and
/// per-file size annotations in the preview.
pub const EntryMeta = struct {
    path: []u8,
    /// Bytes the entry will write on extract. 0 for directories,
    /// symlinks, hardlinks, and any other zero-payload entry.
    size_bytes: u64,
    is_dir: bool,
};

/// Like `listEntries` but also captures size + dir flag per entry.
/// Same `LIST_ENTRIES_CAP` ceiling. Caller frees via `freeEntryMetas`.
pub fn listEntriesMeta(alloc: std.mem.Allocator, archive_path: []const u8) Error![]EntryMeta {
    var path_buf: [4096]u8 = undefined;
    if (archive_path.len + 1 > path_buf.len) return Error.IoFailed;
    @memcpy(path_buf[0..archive_path.len], archive_path);
    path_buf[archive_path.len] = 0;
    const c_archive_path: [*:0]const u8 = @ptrCast(&path_buf);

    const a = c.archive_read_new() orelse return Error.OutOfMemory;
    defer _ = c.archive_read_free(a);

    _ = c.archive_read_support_format_all(a);
    _ = c.archive_read_support_filter_all(a);

    if (c.archive_read_open_filename(a, c_archive_path, 16 * 1024) != c.ARCHIVE_OK) {
        std.log.warn("libarchive: open failed: {s}", .{c.archive_error_string(a)});
        return Error.IoFailed;
    }

    var out: std.ArrayList(EntryMeta) = .empty;
    errdefer {
        for (out.items) |m| alloc.free(m.path);
        out.deinit(alloc);
    }

    while (out.items.len < LIST_ENTRIES_CAP) {
        var entry: ?*c.archive_entry = null;
        const rc = c.archive_read_next_header(a, &entry);
        if (rc == c.ARCHIVE_EOF) break;
        if (rc < c.ARCHIVE_OK) {
            std.log.warn("libarchive: header read: {s}", .{c.archive_error_string(a)});
        }
        if (rc < c.ARCHIVE_WARN) return Error.ExtractionFailed;

        const raw: [*:0]const u8 = if (c.archive_entry_pathname_utf8(entry)) |p|
            p
        else if (c.archive_entry_pathname(entry)) |p|
            p
        else continue;
        const slice = std.mem.span(raw);
        const owned = alloc.dupe(u8, slice) catch return Error.OutOfMemory;

        const size_raw = c.archive_entry_size(entry);
        const ftype = c.archive_entry_filetype(entry);
        // `AE_IFDIR` is `040000` in libarchive's header; translate-c
        // chokes on the octal literal so we hardcode the value here.
        // Matches `<sys/stat.h>`'s `S_IFDIR`.
        const AE_IFDIR: c_int = 0o40000;
        const meta: EntryMeta = .{
            .path = owned,
            .size_bytes = if (size_raw > 0) @intCast(size_raw) else 0,
            .is_dir = ftype == AE_IFDIR,
        };
        out.append(alloc, meta) catch {
            alloc.free(owned);
            return Error.OutOfMemory;
        };
    }

    _ = c.archive_read_close(a);
    return out.toOwnedSlice(alloc) catch Error.OutOfMemory;
}

pub fn freeEntryMetas(alloc: std.mem.Allocator, entries: []EntryMeta) void {
    for (entries) |m| alloc.free(m.path);
    alloc.free(entries);
}

/// Strip N leading path components from a C string. Returns null when
/// stripping leaves nothing (skip the entry — happens for parent dirs
/// of the strip cut). Returned pointer aliases `path`.
fn stripComponents(path: [*:0]const u8, n: u8) ?[*:0]const u8 {
    if (n == 0) return path;
    var p: [*:0]const u8 = path;
    var stripped: u8 = 0;
    while (stripped < n) : (stripped += 1) {
        // Walk to the next `/`.
        var i: usize = 0;
        while (p[i] != 0 and p[i] != '/') : (i += 1) {}
        if (p[i] == 0) return null; // hit end before stripping enough
        p = p + i + 1;
        if (p[0] == 0) return null;
    }
    return p;
}
