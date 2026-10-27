// Library column registry + user layout (visibility, order, widths, sort keys).
//
// Pure module (no dvui). Defines WHICH columns exist and the user's current
// arrangement; `sortx` does the sorting, the table component does the drawing,
// and a later `columns_game.zig` supplies the per-column comparators/renderers
// for `library.Game`. Layout uses fixed arrays (≤ column count) — no allocation.

const std = @import("std");

pub const Dir = enum { asc, desc };

pub const ColumnId = enum {
    name,
    rating,
    weighted,
    votes,
    last_update,
    last_launched,
    date_added,
    dev_status,
    completion,
    engine,
    playtime,
    installed_version,
    available_version,
    install_state,
};

pub const count = std.meta.fieldNames(ColumnId).len;

pub const Meta = struct { label: []const u8, default_width: f32, default_visible: bool };

pub fn meta(id: ColumnId) Meta {
    return switch (id) {
        .name => .{ .label = "Name", .default_width = 360, .default_visible = true },
        .rating => .{ .label = "Rating", .default_width = 90, .default_visible = true },
        .weighted => .{ .label = "Weighted", .default_width = 96, .default_visible = false },
        .votes => .{ .label = "Votes", .default_width = 80, .default_visible = false },
        .last_update => .{ .label = "Last update", .default_width = 118, .default_visible = false },
        .last_launched => .{ .label = "Last played", .default_width = 118, .default_visible = false },
        .date_added => .{ .label = "Added", .default_width = 110, .default_visible = false },
        .dev_status => .{ .label = "Status", .default_width = 110, .default_visible = true },
        .completion => .{ .label = "Completion", .default_width = 110, .default_visible = false },
        .engine => .{ .label = "Engine", .default_width = 120, .default_visible = true },
        .playtime => .{ .label = "Playtime", .default_width = 90, .default_visible = false },
        .installed_version => .{ .label = "Installed", .default_width = 120, .default_visible = false },
        .available_version => .{ .label = "Version", .default_width = 130, .default_visible = true },
        .install_state => .{ .label = "", .default_width = 70, .default_visible = true },
    };
}

pub const SortKey = struct { col: ColumnId, dir: Dir = .asc };
pub const ColumnState = struct { id: ColumnId, width: f32, visible: bool };

pub const Layout = struct {
    cols: [count]ColumnState,
    sort: [2]?SortKey = .{ null, null },

    /// All columns in enum order, widths + visibility from `meta`.
    pub fn default() Layout {
        var cols: [count]ColumnState = undefined;
        inline for (comptime std.meta.fieldNames(ColumnId), 0..) |name, i| {
            const id = @field(ColumnId, name);
            const m = meta(id);
            cols[i] = .{ .id = id, .width = m.default_width, .visible = m.default_visible };
        }
        return .{ .cols = cols };
    }

    pub fn toggle(self: *Layout, id: ColumnId) void {
        for (&self.cols) |*c| if (c.id == id) {
            c.visible = !c.visible;
            return;
        };
    }

    pub fn moveLeft(self: *Layout, id: ColumnId) void {
        for (self.cols, 0..) |c, i| if (c.id == id) {
            if (i > 0) std.mem.swap(ColumnState, &self.cols[i - 1], &self.cols[i]);
            return;
        };
    }

    /// Make `col` the primary sort key, demoting the old primary to secondary.
    pub fn setSort(self: *Layout, col: ColumnId, dir: Dir) void {
        self.sort[1] = self.sort[0];
        self.sort[0] = .{ .col = col, .dir = dir };
    }
};

// ----- persistence (column_layout: `col <id> <width> <0|1>` + `sort`/`sort2` lines) -----

/// Serialize a layout into `out` (caller sizes ≥ ~1 KB); returns the written slice.
pub fn formatLayout(lay: Layout, out: []u8) []const u8 {
    var len: usize = 0;
    for (lay.cols) |c| {
        const line = std.fmt.bufPrint(out[len..], "col {s} {d} {d}\n", .{ @tagName(c.id), c.width, @intFromBool(c.visible) }) catch unreachable;
        len += line.len;
    }
    inline for (.{ .{ "sort", 0 }, .{ "sort2", 1 } }) |pair| {
        if (lay.sort[pair[1]]) |s| {
            const line = std.fmt.bufPrint(out[len..], "{s} {s} {s}\n", .{ pair[0], @tagName(s.col), @tagName(s.dir) }) catch unreachable;
            len += line.len;
        }
    }
    return out[0..len];
}

/// Parse a layout; unknown/malformed lines are ignored and any columns absent
/// from the text are appended in default order (so new columns keep showing up).
pub fn parseLayout(text: []const u8) Layout {
    const def = Layout.default();
    var cols: [count]ColumnState = undefined;
    var n: usize = 0;
    var seen: [count]bool = @splat(false);
    var sort: [2]?SortKey = .{ null, null };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var it = std.mem.tokenizeScalar(u8, raw, ' ');
        const kind = it.next() orelse continue;
        if (std.mem.eql(u8, kind, "col")) {
            const id = std.meta.stringToEnum(ColumnId, it.next() orelse continue) orelse continue;
            const w = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            const v = it.next() orelse continue;
            const idx = @intFromEnum(id);
            if (seen[idx]) continue;
            seen[idx] = true;
            cols[n] = .{ .id = id, .width = w, .visible = v.len > 0 and v[0] == '1' };
            n += 1;
        } else if (std.mem.eql(u8, kind, "sort") or std.mem.eql(u8, kind, "sort2")) {
            const id = std.meta.stringToEnum(ColumnId, it.next() orelse continue) orelse continue;
            const dir: Dir = if (std.mem.eql(u8, it.next() orelse "asc", "desc")) .desc else .asc;
            sort[if (std.mem.eql(u8, kind, "sort")) 0 else 1] = .{ .col = id, .dir = dir };
        }
    }
    for (def.cols) |c| {
        if (!seen[@intFromEnum(c.id)]) {
            cols[n] = c;
            n += 1;
        }
    }
    return .{ .cols = cols, .sort = sort };
}

fn find(lay: Layout, id: ColumnId) ColumnState {
    for (lay.cols) |c| if (c.id == id) return c;
    unreachable;
}

test "default layout lists every column in enum order with sensible visibility" {
    const lay = Layout.default();
    try std.testing.expectEqual(@as(usize, count), lay.cols.len);
    try std.testing.expectEqual(ColumnId.name, lay.cols[0].id);
    try std.testing.expect(find(lay, .name).visible);
    try std.testing.expect(!find(lay, .playtime).visible);
}

test "toggle flips a column's visibility" {
    var lay = Layout.default();
    const before = find(lay, .playtime).visible;
    lay.toggle(.playtime);
    try std.testing.expectEqual(!before, find(lay, .playtime).visible);
}

test "moveLeft swaps a column with its predecessor" {
    var lay = Layout.default();
    const second = lay.cols[1].id;
    lay.moveLeft(second);
    try std.testing.expectEqual(second, lay.cols[0].id);
    lay.moveLeft(lay.cols[0].id); // already first: no-op, no crash
    try std.testing.expectEqual(second, lay.cols[0].id);
}

test "setSort promotes a new primary key and demotes the old one to secondary" {
    var lay = Layout.default();
    lay.setSort(.rating, .desc);
    try std.testing.expectEqual(ColumnId.rating, lay.sort[0].?.col);
    try std.testing.expect(lay.sort[1] == null);
    lay.setSort(.name, .asc);
    try std.testing.expectEqual(ColumnId.name, lay.sort[0].?.col);
    try std.testing.expectEqual(ColumnId.rating, lay.sort[1].?.col);
}

test "formatLayout/parseLayout round-trips order, widths, visibility, and sort" {
    var lay = Layout.default();
    lay.toggle(.playtime);
    lay.moveLeft(lay.cols[3].id);
    lay.setSort(.rating, .desc);
    lay.setSort(.name, .asc);
    var buf: [2048]u8 = undefined;
    const got = parseLayout(formatLayout(lay, &buf));
    try std.testing.expectEqual(lay.sort[0].?.col, got.sort[0].?.col);
    try std.testing.expectEqual(lay.sort[0].?.dir, got.sort[0].?.dir);
    try std.testing.expectEqual(lay.sort[1].?.col, got.sort[1].?.col);
    for (lay.cols, got.cols) |a, b| {
        try std.testing.expectEqual(a.id, b.id);
        try std.testing.expectEqual(a.visible, b.visible);
        try std.testing.expectEqual(a.width, b.width);
    }
}

test "parseLayout ignores junk and still includes every column (forward-compatible)" {
    const got = parseLayout("col rating 100 1\ngarbage line\ncol bogus 50 1\n");
    try std.testing.expectEqual(@as(usize, count), got.cols.len);
    try std.testing.expectEqual(ColumnId.rating, got.cols[0].id);
    try std.testing.expectEqual(@as(f32, 100), got.cols[0].width);
}
