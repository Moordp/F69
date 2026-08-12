//! Layer-2 GUI integration tests — the dvui-testing-backend suite.
//!
//! Split from integration.zig (2026-08-12): the headless suite's io-heavy
//! tests are the std.Io Windows park risk, and a park in one exe must never
//! eat the GUI coverage — scripts/test-windows-vm.sh runs each exe under its
//! own watchdog. Run with: `zig build test-integration` (runs both roots).

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui");
const dvui = @import("dvui");
const library = @import("library");
const TestEnv = @import("util_test_env").TestEnv;
const file_picker = @import("util_file_picker");

// Same hang-trace file as the headless root — see integration.zig's tlog.
fn tlog(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[gui] " ++ fmt ++ "\n", args) catch return;
    std.debug.print("{s}", .{line}); // shown when running the test binary directly
    const f = std.c.fopen("/tmp/f69-int.log", "a") orelse return;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(line.ptr, 1, line.len, f);
}

// === LAYER 2: drive the real GUI render via dvui's testing backend ========
//
// Layer 1 drives the action layer directly; Layer 2 renders the ACTUAL UI
// (ui.guiFrame) headlessly via dvui.testing and captures the frame to a PNG.
// First slice: an EMPTY library (no cards → no async cover-image workers, so
// no teardown races) — proves the whole render pipeline (rail, filters,
// toolbar, status bar) draws with no display. Widget-tagged interaction
// (click/type/expectVisible by tag) is the next step.

var g_frame: ?*ui.Frame = null;
fn renderFrame() !dvui.App.Result {
    if (g_frame) |fr| _ = ui.guiFrame(fr) catch return .close;
    return .ok;
}

test "layer2: empty library renders via guiFrame on the testing backend (F0)" {
    tlog("START: L2-render", .{});
    const gpa = std.testing.allocator;
    // Render may touch io.async (font/texture/refresh paths) — use a
    // threadsafe smp-backed io like the network slices, not the TestEnv io.
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();

    var env = try TestEnv.init(gpa, "layer2-render");
    defer env.deinit();

    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    // Register the bundled Design-B fonts (runMainLoop does this) so the
    // theme's font families resolve instead of logging err-level fallbacks.
    ui.registerBundledFonts(t.window);

    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;

    // Run one UI frame. The testing backend doesn't rasterize to pixels (so
    // capturePng is unsupported), but `step` drives the REAL render path —
    // theme, screen dispatch, every widget's layout + draw-command emission.
    // If the library screen builds without erroring, the GUI renders headless.
    tlog("L2-render: step ...", .{});
    _ = try dvui.testing.step(renderFrame);
    tlog("L2-render: one frame OK", .{});
}

test "layer2: every primary screen renders without error (F0)" {
    tlog("START: L2-screens", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2-screens");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;

    // Screens that render from default state (no selected game / no async).
    const screens = [_]ui.Screen{ .library, .settings, .downloads, .diagnostics, .universal_mods, .import_urls, .import_folder };
    for (screens) |scr| {
        h.state.screen = scr;
        tlog("L2-screens: {s}", .{@tagName(scr)});
        _ = try dvui.testing.step(renderFrame);
    }
    tlog("L2-screens: all OK", .{});
}

test "layer2: library renders a game card (F0/F3)" {
    tlog("START: L2-card", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2-card");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    // A game with NO cover_url → no async image fetch; renders a card.
    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 99, .name = "Test Game", .developer = "Dev", .engine = .renpy, .rating = 4.3 });
    try h.reloadGames();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .library;
    _ = try dvui.testing.step(renderFrame);
    tlog("L2-card: rendered card OK", .{});
}

test "layer2: typing in the search box drives filter state (F3 interaction)" {
    tlog("START: L2-search", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2-search");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    // Two games, neither named "Zzz" — a search for "Zzz" must filter both out.
    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 1, .name = "Alpha", .developer = "Dev", .engine = .renpy });
    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 2, .name = "Beta", .developer = "Dev", .engine = .renpy });
    try h.reloadGames();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .library;

    // Settle the initial layout so the tagged search box has a real rect.
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    tlog("L2-search: settled, both games visible={d}", .{h.state.lib_filter_cache_indices.?.len});

    // Focus the search box by clicking it, then type.
    try dvui.testing.moveTo("lib-search");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame); // process focus
    try dvui.testing.writeText("Zzz");
    _ = try dvui.testing.step(renderFrame); // process text → buffer
    _ = try dvui.testing.step(renderFrame); // re-render → refilter
    tlog("L2-search: typed, searchSlice=\"{s}\" visible={d}", .{ h.state.searchSlice(), h.state.lib_filter_cache_indices.?.len });

    // Widget → state: the keystrokes reached state.search_buf.
    try std.testing.expectEqualStrings("Zzz", h.state.searchSlice());
    // State → filter: no game matches "Zzz", so the filtered list is empty.
    try std.testing.expectEqual(@as(usize, 0), h.state.lib_filter_cache_indices.?.len);
    tlog("L2-search: OK", .{});
}

test "layer2: clicking a toolbar button navigates screens (F0 interaction)" {
    tlog("START: L2-nav", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2-nav");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .library;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try std.testing.expectEqual(ui.Screen.library, h.state.screen);

    // Click the icon-rail "Mods" item → screen flips to universal_mods.
    // (Global Mods moved from a toolbar button to the rail in the Design-B
    // single-row top bar.)
    try dvui.testing.moveTo("rail-universal_mods");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame); // process click → state.screen mutates
    tlog("L2-nav: after click screen={s}", .{@tagName(h.state.screen)});
    try std.testing.expectEqual(ui.Screen.universal_mods, h.state.screen);
    tlog("L2-nav: OK", .{});
}

test "layer2: detail screen renders + tab click switches tab (F0 interaction)" {
    tlog("START: L2-detail", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2-detail");
    defer env.deinit();
    // Tall window so the V3 hero (288px) + facts + tabs all fit on-screen for
    // the tab-click interaction (moveTo requires the tab to be visible).
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 1200 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    // Game with no cover_url → detail page renders without an async fetch.
    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 7, .name = "Detail Game", .developer = "Dev", .engine = .renpy });
    try h.reloadGames();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.selected_thread = 7;
    h.state.screen = .detail;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    // Default tab is Description (overview); we never left the detail screen.
    try std.testing.expectEqual(ui.Screen.detail, h.state.screen);
    try std.testing.expect(h.state.detail_tab == .overview);
    tlog("L2-detail: rendered, tab={s}", .{@tagName(h.state.detail_tab)});

    // Click the "Journal" tab → detail_tab flips to .journal.
    try dvui.testing.moveTo("Journal");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    tlog("L2-detail: after Journal click tab={s}", .{@tagName(h.state.detail_tab)});
    try std.testing.expect(h.state.detail_tab == .journal);

    // Click the "Tools" tab → detail_tab flips to .tools (version picker +
    // engine tools; per-game settings now live in Overview).
    try dvui.testing.moveTo("Tools");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    try std.testing.expect(h.state.detail_tab == .tools);
    tlog("L2-detail: OK", .{});
}

test "layer2: universal mods screen renders + add slide-over opens" {
    tlog("START: L2-mods", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2-mods");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    _ = try h.lib.createUniversalMod("Skip Splash", .renpy, "/mods/skip.zip", 100);
    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 9, .name = "G", .engine = .renpy });
    try h.reloadGames();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .universal_mods;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.expectVisible("mod-add");
    try std.testing.expect(!h.state.universal_mod_add_open);

    // Open the add slide-over.
    try dvui.testing.moveTo("mod-add");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try std.testing.expect(h.state.universal_mod_add_open);
    try dvui.testing.expectVisible("mod-add-confirm");
    tlog("L2-mods: OK", .{});
}

test "layer2: activity dock toggles the downloads drawer" {
    tlog("START: L2-dock", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2-dock");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .library;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try std.testing.expect(!h.state.dock_expanded);

    // Click the dock → the Downloads drawer opens.
    try dvui.testing.moveTo("activity-dock");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try std.testing.expect(h.state.dock_expanded);
    try dvui.testing.expectVisible("drawer-close");
    tlog("L2-dock: drawer open", .{});

    // Collapse via the drawer's chevron.
    try dvui.testing.moveTo("drawer-close");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    try std.testing.expect(!h.state.dock_expanded);
    tlog("L2-dock: OK", .{});
}

test "layer2: activity dock stays on-screen on every screen (regression)" {
    tlog("START: L2-dock-always", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2-dock-always");
    defer env.deinit();
    // Normal window height (not the artificially tall 1200 used elsewhere) —
    // no screen's tall scrollable content may push the bottom activity dock
    // off the window. The dock must ALWAYS be visible with non-zero height.
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    // Seed a game so the detail screen has something to render.
    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 7, .name = "Detail Game", .developer = "Dev", .engine = .renpy });
    _ = try h.lib.createUniversalMod("Skip Splash", .renpy, "/mods/skip.zip", 100);
    try h.reloadGames();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.selected_thread = 7; // honoured only by the detail screen

    // Every primary screen — including the tall ones (detail hero + body,
    // settings/downloads/diagnostics scroll bodies) — must keep the dock on
    // screen. `visible` is true only if the dock's border rect intersects the
    // window clip, so a dock pushed off the bottom reports false; the tall
    // content used to squeeze it to zero height (h=0). Both must hold.
    const screens = [_]ui.Screen{ .library, .detail, .settings, .downloads, .diagnostics, .universal_mods };
    for (screens) |scr| {
        h.state.screen = scr;
        _ = try dvui.testing.step(renderFrame);
        _ = try dvui.testing.step(renderFrame);
        const dock = try dvui.testing.tagGet("activity-dock");
        tlog("L2-dock-always: {s} dock y={d} h={d} visible={}", .{ @tagName(scr), dock.rect.y, dock.rect.h, dock.visible });
        try std.testing.expect(dock.visible);
        try std.testing.expect(dock.rect.h > 0);
    }
    tlog("L2-dock-always: OK", .{});
}

test "layer2: settings toggle click flips bound state (F10 interaction)" {
    tlog("START: L2-settings", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2-settings");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .settings;
    h.state.settings_tab = .games_launch; // category that renders the sandbox toggle

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    const before = h.state.sandbox_default;
    tlog("L2-settings: rendered, sandbox_default={}", .{before});

    // Click the "Sandbox games by default" toggle → bound bool inverts.
    try dvui.testing.moveTo("set-sandbox-default");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    tlog("L2-settings: after click sandbox_default={}", .{h.state.sandbox_default});
    try std.testing.expectEqual(!before, h.state.sandbox_default);
    tlog("L2-settings: OK", .{});
}

test "layer2: delete-confirm bar appears on click + cancels (F0 conditional)" {
    tlog("START: L2-confirm", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2-confirm");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 8, .name = "Confirm Game", .developer = "Dev", .engine = .renpy });
    try h.reloadGames();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.selected_thread = 8;
    h.state.screen = .detail;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try std.testing.expect(!h.state.confirm_delete);
    tlog("L2-confirm: rendered, confirm_delete={}", .{h.state.confirm_delete});

    // Open the ⋯ overflow menu, then click Delete → the confirm bar appears.
    try dvui.testing.moveTo("detail-overflow");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame); // open the floating menu
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.moveTo("detail-delete");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame); // process click → confirm_delete = true
    _ = try dvui.testing.step(renderFrame); // render the now-visible confirm bar
    try std.testing.expect(h.state.confirm_delete);
    try dvui.testing.expectVisible("detail-delete-cancel");
    tlog("L2-confirm: confirm bar visible", .{});

    // Click Cancel → bar dismisses, game untouched.
    try dvui.testing.moveTo("detail-delete-cancel");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    try std.testing.expect(!h.state.confirm_delete);
    try std.testing.expectEqual(ui.Screen.detail, h.state.screen); // never deleted/left
    tlog("L2-confirm: OK", .{});
}

test "layer2: sidebar filter checkbox click flips bound state (F3 interaction)" {
    tlog("START: L2-checkbox", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2-checkbox");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .library;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    const before = h.state.filter_unplayed_updates;
    tlog("L2-checkbox: rendered, filter_unplayed={}", .{before});

    // Click the "Unplayed updates" sidebar checkbox → bound bool inverts.
    try dvui.testing.moveTo("filter-unplayed");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    tlog("L2-checkbox: after click filter_unplayed={}", .{h.state.filter_unplayed_updates});
    try std.testing.expectEqual(!before, h.state.filter_unplayed_updates);
    tlog("L2-checkbox: OK", .{});
}

test "layer2: sidebar engine filter row toggles the engine set (F3 interaction)" {
    tlog("START: L2-engine", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2-engine");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    // A Ren'Py game → the flat ENGINE filter list shows a "Ren'Py" row.
    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 1, .name = "Alpha", .developer = "Dev", .engine = .renpy });
    try h.reloadGames();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .library;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);

    // Design-B sidebar: engine filter is an always-visible flat counted list.
    try dvui.testing.expectVisible("filter-eng-renpy");
    try std.testing.expect(!h.state.filters.engine.contains(.renpy));
    tlog("L2-engine: Ren'Py row visible, not selected", .{});

    // Click the Ren'Py row → it enters the engine filter set.
    try dvui.testing.moveTo("filter-eng-renpy");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    try std.testing.expect(h.state.filters.engine.contains(.renpy));
    tlog("L2-engine: clicked → Ren'Py selected — OK", .{});
}

test "layer2: sync dropdown opens + keyboard-selects an entry (F3 interaction)" {
    tlog("START: L2-dropdown", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2-dropdown");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .library;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try std.testing.expect(h.state.filters.sync_state == .all); // default
    tlog("L2-dropdown: rendered, sync_state={s}", .{@tagName(h.state.filters.sync_state)});

    // Open the dropdown, move down to the next entry, confirm with Enter.
    try dvui.testing.moveTo("filter-sync");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame); // menu drops
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.pressKey(.down, .none);
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.pressKey(.enter, .none);
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    tlog("L2-dropdown: after select sync_state={s}", .{@tagName(h.state.filters.sync_state)});
    // Moved off the default → some non-.all entry is now selected.
    try std.testing.expect(h.state.filters.sync_state != .all);
    tlog("L2-dropdown: OK", .{});
}

// === LAYER 2b: the widget sweep + tag census =============================
//
// "Touches every button" cannot be a matter of authoring discipline — a new
// button ships uncovered and nothing notices. These two tests make it
// measurable and then enforceable:
//
//   sweep   : clicks EVERY tagged widget on a screen, each from a fresh
//             harness, and asserts the app is still healthy afterwards.
//   census  : counts interactive widgets built per frame vs. how many carry a
//             `.tag`. Untagged widgets are unreachable by the sweep, so the
//             gap is exactly the set of buttons no test can ever click.
//
// See docs/superpowers/specs/2026-08-10-exhaustive-test-harness-design.md.

/// Widgets the sweep must not actuate, with the reason. Anything that leaves
/// the process — spawning a real browser/file-manager or a game — would escape
/// the test sandbox, so it is excluded here rather than silently skipped.
const sweep_skip = [_]struct { tag: []const u8, why: []const u8 }{
    .{ .tag = "hero-play", .why = "spawns a real process via the sandbox backend" },
    .{ .tag = "hero-stop", .why = "signals a real pid" },
};

fn skipReason(tag: []const u8) ?[]const u8 {
    for (sweep_skip) |s| if (std.mem.eql(u8, s.tag, tag)) return s.why;
    return null;
}

/// Every visible tag in the current frame, duped into `out`.
fn collectVisibleTags(
    gpa: std.mem.Allocator,
    win: *dvui.Window,
    out: *std.ArrayList([]u8),
) !void {
    var it = win.tags.iterator();
    while (it.next()) |e| {
        if (!e.value_ptr.*.visible) continue;
        try out.append(gpa, try gpa.dupe(u8, e.key_ptr.*));
    }
}

fn sweepInvariants(h: *ui.Harness) !void {
    // The DB still opens AND still accepts writes: a click that corrupted the
    // schema or left a transaction open fails here rather than three tests later.
    _ = try h.lib.insertIfMissing(&.{
        .f95_thread_id = 424242,
        .name = "post-click probe",
    });
}

test "layer2b: tag census — how many interactive widgets are reachable by tests" {
    tlog("START: L2b-census", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "layer2b-census");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();
    // Seed a REALISTIC state. Without reloadGames() the harness's games
    // snapshot stays empty, the library renders its empty state, and the census
    // counts a blank app — no cards, so no detail page, no download controls,
    // no per-game options. Signed-in likewise: the signed-out library hides the
    // sync controls behind a sign-in card.
    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 501, .name = "Census Game", .engine = .renpy, .developer = "Dev", .rating = 4.0 });
    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 502, .name = "Second Game", .developer = "Dev2" });
    try h.reloadGames();
    h.state.login_status = .logged_in;

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;

    var total_built: usize = 0;
    var total_tagged: usize = 0;
    h.state.selected_thread = 501; // so the detail screen has a subject
    for ([_]ui.Screen{ .library, .detail, .settings, .downloads, .diagnostics }) |scr| {
        h.state.screen = scr;
        ui.style.resetWidgetCensus();
        _ = try dvui.testing.step(renderFrame);
        const built = ui.style.widgets_built;
        const tagged = ui.style.widgets_tagged;
        total_built += built;
        total_tagged += tagged;
        tlog("census {s}: {d} interactive widgets, {d} tagged", .{ @tagName(scr), built, tagged });
    }
    tlog("census TOTAL: {d} built, {d} tagged", .{ total_built, total_tagged });

    // Ratchet, not a pass/fail on perfection. Measured 2026-08-10:
    //
    //   library 0 · settings 6 · downloads 4 · diagnostics 0  =  10 built
    //   0 of them tagged
    //
    // Two things that says, both actionable:
    //   1. `style.button` is only one of several interactive constructors.
    //      library/diagnostics report 0 because they build their controls from
    //      components.iconButton, text entries and list rows instead. Those need
    //      the same census hook before "every button" can be claimed.
    //   2. Not one style.button carries a `.tag`, so the sweep cannot reach any
    //      of them. The 20 tags that do exist are all on other widget types.
    //
    // Raise BASELINE_TAGGED as widgets get tagged; it must never go down.
    // 2026-08-11: after instrumenting components.iconButton/iconOnly and
    // tagging the library screen's controls.
    const BASELINE_BUILT = 27;
    const BASELINE_TAGGED = 6;
    try std.testing.expect(total_built >= BASELINE_BUILT);
    try std.testing.expect(total_tagged >= BASELINE_TAGGED);
}

test "layer2b: sweep — click every tagged widget, app stays healthy" {
    tlog("START: L2b-sweep", .{});
    const gpa = std.testing.allocator;

    // Pass 1: discover the tags each screen exposes.
    var tags: std.ArrayList([]u8) = .empty;
    defer {
        for (tags.items) |s| gpa.free(s);
        tags.deinit(gpa);
    }
    {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
        defer threaded.deinit();
        const io = threaded.io();
        var env = try TestEnv.init(gpa, "layer2b-discover");
        defer env.deinit();
        var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
        defer t.deinit();
        ui.registerBundledFonts(t.window);
        var h = try ui.Harness.init(gpa, io, t.window, env.root);
        defer h.deinit();
        _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 502, .name = "Sweep Game", .engine = .renpy, .developer = "Dev", .rating = 4.0 });
        try h.reloadGames();
        h.state.login_status = .logged_in;
        var fr = h.frame();
        g_frame = &fr;
        defer g_frame = null;
        h.state.screen = .library;
        _ = try dvui.testing.step(renderFrame);
        try collectVisibleTags(gpa, t.window, &tags);
    }
    tlog("sweep: {d} tagged widgets discovered on the library screen", .{tags.items.len});
    try std.testing.expect(tags.items.len > 0);
    // KNOWN LIMIT — the sweep is single-pass, so it only sees widgets present
    // in the FIRST frame. Many controls live inside `dvui.expander` sections
    // (the rating/tag filters) or dialogs, and an expander's open state lives
    // in dvui's own per-widget data store rather than f69's State — so no
    // amount of state seeding reveals them. They appear only after a click.
    //
    // "Touch every button" therefore needs an ITERATIVE sweep: click, re-collect
    // tags, click whatever is newly present, repeat to a fixpoint. That is the
    // next change here; 12 of the library screen's controls are already tagged
    // and waiting for it (only 1 is reachable in a single pass).

    // Pass 2: one fresh harness per widget, so a click that corrupts state
    // cannot mask the next widget's behaviour.
    var clicked: usize = 0;
    var skipped: usize = 0;
    for (tags.items) |tg| {
        if (std.mem.startsWith(u8, tg, "__")) continue; // synthetic (window rect)
        if (skipReason(tg)) |why| {
            tlog("sweep SKIP {s}: {s}", .{ tg, why });
            skipped += 1;
            continue;
        }
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
        defer threaded.deinit();
        const io = threaded.io();
        var env = try TestEnv.init(gpa, "layer2b-click");
        defer env.deinit();
        var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
        defer t.deinit();
        ui.registerBundledFonts(t.window);
        var h = try ui.Harness.init(gpa, io, t.window, env.root);
        defer h.deinit();
        _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 503, .name = "Sweep Game", .engine = .renpy, .developer = "Dev", .rating = 4.0 });
        try h.reloadGames();
        h.state.login_status = .logged_in;
        var fr = h.frame();
        g_frame = &fr;
        defer g_frame = null;
        h.state.screen = .library;
        _ = try dvui.testing.step(renderFrame);

        // The widget may not exist in this state; that's data, not a failure.
        dvui.testing.moveTo(tg) catch {
            tlog("sweep MISS {s} (not present this frame)", .{tg});
            continue;
        };
        try dvui.testing.click(.left);
        _ = try dvui.testing.step(renderFrame);
        try sweepInvariants(h);
        clicked += 1;
        tlog("sweep OK {s}", .{tg});
    }
    tlog("sweep: {d} clicked, {d} skipped", .{ clicked, skipped });
    try std.testing.expect(clicked > 0);
}

// =====================================================================
//  Windows-focused GUI flows (2026-08-11).
//
//  These run through the REAL guiFrame on the dvui testing backend, on
//  every OS target. The Windows-arm assertions execute when the suite
//  runs natively on the Win11 VM (scripts/test-windows-vm.sh); tests
//  that exercise Windows-only GUI (the Sandboxie settings section) or
//  Windows-only behavior (stop refusal) skip elsewhere.
//
//  The launch tests exist because of sandbox.spawn_hook: every backend
//  used to bottom out in std.process.spawn, which no test could allow,
//  so hero-play was permanently untestable (see the sweep_skip note).
// =====================================================================

const sandbox = @import("sandbox");

/// True when any live toast contains `needle`. Toasts are the only place
/// launch/settings feedback lands (setLaunchMsg → pushToast).
fn anyToastContains(state: *const ui.State, needle: []const u8) bool {
    for (&state.toasts) |*t| {
        if (std.mem.indexOf(u8, t.msg(), needle) != null) return true;
    }
    return false;
}

/// Shared seeding for the launch tests: game 42 with one manual install
/// whose on-disk tree ships BOTH a `Game.sh` and a `Game.exe` — so the
/// auto-pick has to choose per-OS. Returns the install path (caller frees).
fn seedLaunchableGame(h: *ui.Harness, env: *TestEnv) ![]const u8 {
    try env.writeFile("library/42/final/Game.sh", "#!/bin/sh\nexit 0\n");
    try env.writeFile("library/42/final/Game.exe", "MZ fake pe");
    const install_path = try env.path("library/42/final");
    errdefer std.testing.allocator.free(install_path);

    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 42, .name = "Launch Game", .developer = "Dev", .engine = .renpy });
    const install_id: [36]u8 = "11111111-2222-3333-4444-555555555555".*;
    try h.lib.upsertInstall(&.{
        .id = install_id,
        .game_thread_id = 42,
        .version = "1.0",
        .install_path = install_path,
        .recipe_id = "",
        .installed_at = 0,
        .source = .manual,
    });
    try h.reloadGames();
    return install_path;
}

test "layer2: hero-play click launches through the spawn seam with the OS-correct launcher" {
    tlog("START: L2-heroplay", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "l2-heroplay");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    const install_path = try seedLaunchableGame(h, &env);
    defer gpa.free(install_path);

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .detail;
    h.state.selected_thread = 42;
    h.state.sandbox_default = false; // host route → NoSandbox → seam
    // Skip the pre-launch diagnostics dialog — this test is about the
    // spawn pipeline, not the diag popup. The flag resets on launch.
    h.state.launch_diag_acked = true;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.expectVisible("hero-play");

    // fake_pid = 0 on purpose: a 0 pid skips the running-games tracking, so
    // the Linux frame drain never waitpid()s a pid we don't own.
    sandbox.spawn_hook.install(0);
    defer sandbox.spawn_hook.reset();

    try dvui.testing.moveTo("hero-play");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);

    try std.testing.expectEqual(@as(usize, 1), sandbox.spawn_hook.calls);
    try std.testing.expectEqualStrings("none", sandbox.spawn_hook.backendName());
    const argv0 = sandbox.spawn_hook.arg(0) orelse return error.TestUnexpectedResult;
    if (builtin.os.tag == .windows) {
        // Picking the .sh here is the exact historical bug: a Ren'Py
        // Game.sh handed to the Windows spawn fails InvalidExe.
        try std.testing.expect(std.mem.endsWith(u8, argv0, "Game.exe"));
    } else {
        try std.testing.expect(std.mem.endsWith(u8, argv0, "Game.sh"));
    }
    // Host route → the game keeps the host env: no HOME override recorded.
    try std.testing.expectEqualStrings("", sandbox.spawn_hook.envHome());
    tlog("L2-heroplay: OK argv0 ends correctly", .{});
}

test "layer2: sandboxed hero-play redirects the game HOME (and USERPROFILE on Windows)" {
    tlog("START: L2-heroplay-sbx", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "l2-heroplay-sbx");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    const install_path = try seedLaunchableGame(h, &env);
    defer gpa.free(install_path);

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .detail;
    h.state.selected_thread = 42;
    h.state.sandbox_default = true; // sandboxed route → frame.sandbox
    h.state.launch_diag_acked = true;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.expectVisible("hero-play");

    sandbox.spawn_hook.install(0);
    defer sandbox.spawn_hook.reset();
    try dvui.testing.moveTo("hero-play");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);

    try std.testing.expectEqual(@as(usize, 1), sandbox.spawn_hook.calls);
    // The harness environ is empty so pickBackend always lands on the
    // NoSandbox fallback — which is exactly the backend whose env redirect
    // was a silent no-op for Windows saves before USERPROFILE was added.
    try std.testing.expect(std.mem.endsWith(u8, sandbox.spawn_hook.envHome(), ".f69-home"));
    try std.testing.expect(std.mem.indexOf(u8, sandbox.spawn_hook.envHome(), "42") != null);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings(sandbox.spawn_hook.envHome(), sandbox.spawn_hook.envUserProfile());
    }
    tlog("L2-heroplay-sbx: OK home={s}", .{sandbox.spawn_hook.envHome()});
}

test "layer2: launch then stop on Windows — stop is refused with a message and the entry clears" {
    // Windows-only: stop isn't supported there yet (launch.zig doStopGame),
    // and on POSIX a tracked fake pid would be waitpid()ed by the frame
    // drain / SIGTERMed by the stop — a pid this test doesn't own.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    tlog("START: L2-stop-win", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "l2-stop-win");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    const install_path = try seedLaunchableGame(h, &env);
    defer gpa.free(install_path);

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .detail;
    h.state.selected_thread = 42;
    h.state.sandbox_default = false;
    h.state.launch_diag_acked = true;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);

    // Non-zero fake pid → the game is tracked as running (the Windows
    // drainRunningGames is a no-op, so the entry survives frames).
    sandbox.spawn_hook.install(4242);
    defer sandbox.spawn_hook.reset();
    try dvui.testing.moveTo("hero-play");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try std.testing.expectEqual(@as(usize, 1), sandbox.spawn_hook.calls);
    try dvui.testing.expectVisible("hero-stop");
    tlog("L2-stop-win: running, Stop shown", .{});

    // Settle a frame so hero-stop's rect is final, process the motion
    // before the press (a click posted with the motion in the same batch
    // proved flaky on the VM), then give the click two frames to land.
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.moveTo("hero-stop");
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    for (&h.state.toasts) |*toast| if (toast.len > 0) tlog("L2-stop-win: toast: {s}", .{toast.msg()});
    try std.testing.expect(anyToastContains(&h.state, "isn't supported on Windows yet"));
    // Entry dropped: assert the state directly, then give the UI a couple
    // of frames to swap Stop back to Play before checking the widget.
    if (h.state.running_games) |m| try std.testing.expectEqual(@as(u32, 0), m.count());
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    if (dvui.tagGet("hero-play")) |td| {
        tlog("L2-stop-win: hero-play tag visible={} rect=({d},{d} {d}x{d})", .{ td.visible, td.rect.x, td.rect.y, td.rect.w, td.rect.h });
    } else tlog("L2-stop-win: hero-play tag MISSING", .{});
    if (dvui.tagGet("hero-stop")) |td| {
        tlog("L2-stop-win: hero-stop tag visible={}", .{td.visible});
    } else tlog("L2-stop-win: hero-stop tag gone (expected)", .{});
    try dvui.testing.expectVisible("hero-play");
    tlog("L2-stop-win: OK", .{});
}

test "layer2: Windows refuses a Linux-only install from hero-play with an actionable message" {
    // The install ships ONLY a Game.sh. On Windows the launch must refuse
    // with the "re-download the Windows build" toast instead of handing a
    // shell script to the spawn. NOTE: this walks a directory right after
    // writing into it — if it parks on the VM, it has hit the std.Io
    // defect documented in util/atomic_io.zig and needs that skip.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    tlog("START: L2-linuxonly-win", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "l2-linuxonly");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    try env.writeFile("library/43/final/Game.sh", "#!/bin/sh\nexit 0\n");
    const install_path = try env.path("library/43/final");
    defer gpa.free(install_path);
    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 43, .name = "Linux Only", .developer = "Dev", .engine = .renpy });
    const install_id: [36]u8 = "22222222-3333-4444-5555-666666666666".*;
    try h.lib.upsertInstall(&.{
        .id = install_id,
        .game_thread_id = 43,
        .version = "1.0",
        .install_path = install_path,
        .recipe_id = "",
        .installed_at = 0,
        .source = .manual,
    });
    try h.reloadGames();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .detail;
    h.state.selected_thread = 43;
    h.state.sandbox_default = false;
    h.state.launch_diag_acked = true;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.expectVisible("hero-play");

    sandbox.spawn_hook.install(0);
    defer sandbox.spawn_hook.reset();
    try dvui.testing.moveTo("hero-play");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);

    // Refused BEFORE the spawn seam, with the actionable message.
    try std.testing.expectEqual(@as(usize, 0), sandbox.spawn_hook.calls);
    try std.testing.expect(anyToastContains(&h.state, "can't run on Windows"));
    tlog("L2-linuxonly-win: OK", .{});
}

test "layer2: Sandboxie settings — browse applies, persists and clears (Windows)" {
    // The single most Windows-specific piece of GUI in the app
    // (settings.zig renderSandboxDefaultSection): compiled out everywhere
    // else, so this only ever runs on the Win11 VM.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    tlog("START: L2-sbie-settings", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "l2-sbie-settings");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    // A portable Start.exe under a spaced path — the exact non-standard
    // install the Browse… affordance exists for.
    try env.writeFile("Sandboxie Portable/Start.exe", "MZ fake");
    const start_exe = try env.path("Sandboxie Portable/Start.exe");
    defer gpa.free(start_exe);

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .settings;
    h.state.settings_tab = .games_launch;

    // Extra settle frames: the settings panel wraps help text, and the
    // browse button's rect must be final before moveTo samples it.
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.expectVisible("set-sandboxie-browse");

    // Browse → the harness answers the native dialog with the fake Start.exe.
    // Motion is processed in its own frame before the press — posting both
    // in one batch proved flaky on the VM.
    const answers = [_][]const u8{start_exe};
    file_picker.test_hook.install(&answers);
    defer file_picker.test_hook.reset();
    try dvui.testing.moveTo("set-sandboxie-browse");
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);

    for (&h.state.toasts) |*toast| if (toast.len > 0) tlog("L2-sbie-settings: toast: {s}", .{toast.msg()});
    tlog("L2-sbie-settings: picker calls={d} backend={s}", .{ file_picker.test_hook.calls, h.sandbox_backend.backendName() });
    try std.testing.expectEqual(@as(usize, 1), file_picker.test_hook.calls);
    // Hot-swapped in place, no restart:
    try std.testing.expectEqualStrings("sandboxie", h.sandbox_backend.backendName());
    try std.testing.expectEqualStrings(start_exe, h.sandbox_backend.sandboxiePath());
    try std.testing.expect(anyToastContains(&h.state, "games will launch sandboxed"));
    // Persisted for the next boot. Existence only — reading a file straight
    // after writing it is the open std.Io Windows defect (util/atomic_io.zig).
    const persist_path = try env.path("sandboxie_path");
    defer gpa.free(persist_path);
    try std.Io.Dir.cwd().access(io, persist_path, .{});
    tlog("L2-sbie-settings: applied + persisted", .{});

    // The override is now shown → Clear appears; clicking it deletes the file.
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.expectVisible("set-sandboxie-clear");
    try dvui.testing.moveTo("set-sandboxie-clear");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, persist_path, .{}));
    try std.testing.expect(anyToastContains(&h.state, "override cleared"));
    tlog("L2-sbie-settings: OK", .{});
}

test "layer2: detail, per-game mods, recipe editor and import-review screens render (F0)" {
    // These four were missing from the primary-screen render sweep — the
    // per-game ones need a seeded selection to be meaningful.
    tlog("START: L2-screens-rest", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "l2-screens-rest");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 7, .name = "Render Game", .developer = "Dev", .engine = .renpy });
    try h.reloadGames();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.selected_thread = 7;

    const screens = [_]ui.Screen{ .detail, .mods_for_game, .recipe_editor, .import_f95_review };
    for (screens) |scr| {
        h.state.screen = scr;
        tlog("L2-screens-rest: {s}", .{@tagName(scr)});
        _ = try dvui.testing.step(renderFrame);
    }
    tlog("L2-screens-rest: all OK", .{});
}

test "layer2: hero-play performs a REAL spawn on Windows (no seam)" {
    // The only test that lets the pipeline reach an actual std.process.spawn.
    // The launcher is a .bat that exits immediately, so nothing lingers.
    // This is what proves the InvalidExe / FileNotFound class of Windows
    // launch bug can't regress silently: everything else stops at the seam.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    tlog("START: L2-realspawn", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "l2-realspawn");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    try env.writeFile("library/44/final/Game.bat", "@exit /b 0\r\n");
    const install_path = try env.path("library/44/final");
    defer gpa.free(install_path);
    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 44, .name = "Real Spawn", .developer = "Dev", .engine = .renpy });
    const install_id: [36]u8 = "33333333-4444-5555-6666-777777777777".*;
    try h.lib.upsertInstall(&.{
        .id = install_id,
        .game_thread_id = 44,
        .version = "1.0",
        .install_path = install_path,
        .recipe_id = "",
        .installed_at = 0,
        .source = .manual,
    });
    try h.reloadGames();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .detail;
    h.state.selected_thread = 44;
    h.state.sandbox_default = false;
    h.state.launch_diag_acked = true;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.expectVisible("hero-play");

    // NO spawn hook: the click goes all the way through std.process.spawn.
    try dvui.testing.moveTo("hero-play");
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);

    for (&h.state.toasts) |*toast| if (toast.len > 0) tlog("L2-realspawn: toast: {s}", .{toast.msg()});
    try std.testing.expect(anyToastContains(&h.state, "Launched (pid"));
    try std.testing.expect(!anyToastContains(&h.state, "Launch failed"));
    tlog("L2-realspawn: OK", .{});
}

test "layer2: hero-play REALLY spawns through the installed Sandboxie (Windows)" {
    // Environment-sensing: runs the real Start.exe when a genuine Sandboxie
    // install is detected, else skips. Verifies OUR side of the contract —
    // Start.exe spawns with /box:f69 and the pipeline reports success. What
    // happens inside the box afterwards (box config, the game itself) is
    // Sandboxie's business and stays manual.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    tlog("START: L2-realspawn-sbx", .{});
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try TestEnv.init(gpa, "l2-realspawn-sbx");
    defer env.deinit();
    var t = try dvui.testing.init(.{ .allocator = gpa, .io = io, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    ui.registerBundledFonts(t.window);
    var h = try ui.Harness.init(gpa, io, t.window, env.root);
    defer h.deinit();

    // Swap the harness backend (empty-environ → none) for one detected from
    // the REAL environment. No Sandboxie on this host → nothing to test.
    var probe = sandbox.pickBackend(gpa, io, .{ .block = .global }, "");
    if (!std.mem.eql(u8, probe.backendName(), "sandboxie")) {
        probe.deinit();
        tlog("L2-realspawn-sbx: no Sandboxie on this host — skipping", .{});
        return error.SkipZigTest;
    }
    h.sandbox_backend.deinit();
    h.sandbox_backend = probe;

    try env.writeFile("library/45/final/Game.bat", "@exit /b 0\r\n");
    const install_path = try env.path("library/45/final");
    defer gpa.free(install_path);
    _ = try h.lib.insertIfMissing(&.{ .f95_thread_id = 45, .name = "Boxed Spawn", .developer = "Dev", .engine = .renpy });
    const install_id: [36]u8 = "44444444-5555-6666-7777-888888888888".*;
    try h.lib.upsertInstall(&.{
        .id = install_id,
        .game_thread_id = 45,
        .version = "1.0",
        .install_path = install_path,
        .recipe_id = "",
        .installed_at = 0,
        .source = .manual,
    });
    try h.reloadGames();

    var fr = h.frame();
    g_frame = &fr;
    defer g_frame = null;
    h.state.screen = .detail;
    h.state.selected_thread = 45;
    h.state.sandbox_default = true; // sandboxed route → the real Sandboxie backend
    h.state.launch_diag_acked = true;

    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.expectVisible("hero-play");

    try dvui.testing.moveTo("hero-play");
    _ = try dvui.testing.step(renderFrame);
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(renderFrame);
    _ = try dvui.testing.step(renderFrame);

    for (&h.state.toasts) |*toast| if (toast.len > 0) tlog("L2-realspawn-sbx: toast: {s}", .{toast.msg()});
    try std.testing.expect(anyToastContains(&h.state, "Launched (pid"));
    try std.testing.expect(!anyToastContains(&h.state, "Launch failed"));
    tlog("L2-realspawn-sbx: OK", .{});
}

