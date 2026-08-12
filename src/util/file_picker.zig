// Cross-platform native file picker via NFDe
// (https://github.com/btzy/nativefiledialog-extended).
//
// Why NFDe: the Wayland-correct way to ask for a file is the XDG
// `org.freedesktop.portal.FileChooser` portal. NFDe's portal backend
// does the D-Bus dance (request token, response signal, URI → path
// translation) so we don't have to write a D-Bus client. The same
// API ships native Win32 (`IFileOpenDialog`) on Windows and Cocoa
// (`NSOpenPanel`) on macOS, so the call site stays portable.
//
// Build: NFDe sources live under `zig-pkg/nfde/`. `build.zig` picks
// the right backend file (`nfd_portal.cpp` / `nfd_win.cpp` /
// `nfd_cocoa.m`) per target OS and links the system libs each
// backend needs (Linux: `dbus-1`; Windows: `ole32`/`uuid`/`shell32`;
// macOS: `AppKit` framework).

const std = @import("std");

const c = @cImport({
    @cInclude("nfd.h");
});

/// One row in the filter dropdown shown by the picker. `spec` is
/// comma-separated extensions without leading `*.` or `.` — e.g.
/// `"zip,7z,tar.gz"`. NFDe converts each to a `*.<ext>` glob.
pub const FilterItem = struct {
    name: []const u8,
    spec: []const u8,
};

pub const Error = error{
    InitFailed,
    DialogFailed,
    OutOfMemory,
};

/// Lazy-init flag — NFDe wants `NFD_Init` once per thread before any
/// other call. We only invoke the picker from the UI thread, so a
/// single global flag is enough. Init does the platform setup
/// (D-Bus connection on Linux, COM apartment on Windows, etc.).
var initialized: bool = false;

fn ensureInit() Error!void {
    if (initialized) return;
    if (c.NFD_Init() != c.NFD_OKAY) return Error.InitFailed;
    initialized = true;
}


// --- test seam ------------------------------------------------------------
// Both entry points below normally raise a NATIVE MODAL dialog, which an
// automated flow can never dismiss — every import / add-modfile / browse-to-exe
// flow would park forever. So the harness can preload answers here.
//
// `queue` is consumed in order (one entry per picker call), which lets a single
// flow drive several pickers. An empty queue with `active` set means "the user
// cancelled", so the cancel path is testable too. `calls` records how many
// times a picker was raised, so a test can assert a picker appeared at all.
//
// Unset in production: `active` is false, so there is no behaviour change and
// no cost beyond one bool check.
pub const test_hook = struct {
    pub var active: bool = false;
    pub var queue: []const []const u8 = &.{};
    pub var calls: usize = 0;

    pub fn install(answers: []const []const u8) void {
        active = true;
        queue = answers;
        calls = 0;
    }
    pub fn reset() void {
        active = false;
        queue = &.{};
        calls = 0;
    }
    /// Next preloaded answer, or null to simulate a cancelled dialog.
    fn take(alloc: std.mem.Allocator) Error!?[]u8 {
        calls += 1;
        if (queue.len == 0) return null;
        const next = queue[0];
        queue = queue[1..];
        return alloc.dupe(u8, next) catch Error.OutOfMemory;
    }
};

/// Show a single-file open dialog. Returns the picked path (owned
/// by `alloc`, free with `alloc.free`), or `null` when the user
/// cancels. Filter items use NFDe's compact format: `spec` is a
/// comma-separated extension list (no dots, no asterisks).
pub fn open(
    alloc: std.mem.Allocator,
    filters: []const FilterItem,
    default_path: ?[]const u8,
) Error!?[]u8 {
    if (test_hook.active) return test_hook.take(alloc);
    try ensureInit();

    // Build the NUL-terminated C arrays NFDe expects. Each filter
    // contributes two heap strings (name + spec); we free them on
    // return regardless of success.
    var c_filters = alloc.alloc(c.nfdu8filteritem_t, filters.len) catch return Error.OutOfMemory;
    defer alloc.free(c_filters);

    var owned: std.ArrayList([:0]u8) = .empty;
    defer {
        for (owned.items) |s| alloc.free(s);
        owned.deinit(alloc);
    }

    for (filters, 0..) |f, i| {
        const name_z = alloc.dupeZ(u8, f.name) catch return Error.OutOfMemory;
        owned.append(alloc, name_z) catch return Error.OutOfMemory;
        const spec_z = alloc.dupeZ(u8, f.spec) catch return Error.OutOfMemory;
        owned.append(alloc, spec_z) catch return Error.OutOfMemory;
        c_filters[i] = .{
            .name = name_z.ptr,
            .spec = spec_z.ptr,
        };
    }

    var default_z_owned: ?[:0]u8 = null;
    defer if (default_z_owned) |s| alloc.free(s);
    const default_z_ptr: ?[*:0]const u8 = if (default_path) |p| blk: {
        const z = alloc.dupeZ(u8, p) catch return Error.OutOfMemory;
        default_z_owned = z;
        break :blk z.ptr;
    } else null;

    var out_path: [*c]c.nfdu8char_t = null;
    const rc = c.NFD_OpenDialogU8(
        &out_path,
        if (filters.len == 0) null else c_filters.ptr,
        @intCast(filters.len),
        default_z_ptr,
    );

    return switch (rc) {
        c.NFD_OKAY => blk: {
            const span = std.mem.span(@as([*:0]const u8, out_path));
            const dup = alloc.dupe(u8, span) catch {
                c.NFD_FreePathU8(out_path);
                break :blk Error.OutOfMemory;
            };
            c.NFD_FreePathU8(out_path);
            break :blk dup;
        },
        c.NFD_CANCEL => null,
        else => Error.DialogFailed,
    };
}

/// Show a directory-only picker. Returns the picked absolute path
/// (owned by `alloc`), or `null` when the user cancels. Used by the
/// importer flow where the user points at the games-base-dir of
/// F95Checker / xLibrary so relative install paths can be resolved.
pub fn openFolder(
    alloc: std.mem.Allocator,
    default_path: ?[]const u8,
) Error!?[]u8 {
    if (test_hook.active) return test_hook.take(alloc);
    try ensureInit();

    var default_z_owned: ?[:0]u8 = null;
    defer if (default_z_owned) |s| alloc.free(s);
    const default_z_ptr: ?[*:0]const u8 = if (default_path) |p| blk: {
        const z = alloc.dupeZ(u8, p) catch return Error.OutOfMemory;
        default_z_owned = z;
        break :blk z.ptr;
    } else null;

    var out_path: [*c]c.nfdu8char_t = null;
    const rc = c.NFD_PickFolderU8(&out_path, default_z_ptr);

    return switch (rc) {
        c.NFD_OKAY => blk: {
            const span = std.mem.span(@as([*:0]const u8, out_path));
            const dup = alloc.dupe(u8, span) catch {
                c.NFD_FreePathU8(out_path);
                break :blk Error.OutOfMemory;
            };
            c.NFD_FreePathU8(out_path);
            break :blk dup;
        },
        c.NFD_CANCEL => null,
        else => Error.DialogFailed,
    };
}

/// Tear down NFDe at app shutdown. Symmetric with the lazy
/// `ensureInit`. Called from main.zig's defer; no-op when never used.
pub fn deinit() void {
    if (initialized) {
        c.NFD_Quit();
        initialized = false;
    }
}
