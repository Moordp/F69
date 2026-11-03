//! Pure helpers for driving MEGAcmd 2.7.0: output parsers, exit-code
//! mapping, and the client locator. No process spawning here (that is
//! `engine_megacmd.zig`).
const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;

pub const EXIT_QUOTA: u8 = 17;
pub const EXIT_ALREADY_LOGGED_IN: u8 = 54;
pub const EXIT_NOT_LOGGED_IN: u8 = 57;

pub const Progress = struct { done: u64, total: u64, pct: f32 };

/// Parse the `(<done>/<total> <unit>: <pct> %)` group of a `mega-get`
/// stderr progress line. The group may sit anywhere in the line.
pub fn parseProgressLine(line: []const u8) ?Progress {
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, from, '(')) |open| {
        from = open + 1;
        const close = std.mem.indexOfScalarPos(u8, line, open, ')') orelse return null;
        if (parseGroup(line[open + 1 .. close])) |p| return p;
    }
    return null;
}

fn parseGroup(g: []const u8) ?Progress {
    const slash = std.mem.indexOfScalar(u8, g, '/') orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, g, slash, ':') orelse return null;
    const done_n = std.fmt.parseInt(u64, std.mem.trim(u8, g[0..slash], " "), 10) catch return null;
    // "<total> <unit>"
    const mid = std.mem.trim(u8, g[slash + 1 .. colon], " ");
    const sp = std.mem.indexOfScalar(u8, mid, ' ') orelse return null;
    const total_n = std.fmt.parseInt(u64, mid[0..sp], 10) catch return null;
    const unit = std.mem.trim(u8, mid[sp..], " ");
    const mult: u64 = if (std.mem.eql(u8, unit, "B"))
        1
    else if (std.mem.eql(u8, unit, "KB"))
        1024
    else if (std.mem.eql(u8, unit, "MB"))
        1024 * 1024
    else if (std.mem.eql(u8, unit, "GB"))
        1024 * 1024 * 1024
    else
        return null;
    var pct_s = std.mem.trim(u8, g[colon + 1 ..], " ");
    if (std.mem.endsWith(u8, pct_s, "%")) pct_s = std.mem.trim(u8, pct_s[0 .. pct_s.len - 1], " ");
    const pct = std.fmt.parseFloat(f32, pct_s) catch return null;
    if (!std.math.isFinite(pct)) return null;
    return .{ .done = done_n *| mult, .total = total_n *| mult, .pct = pct };
}

/// `Download finished: <path>` -> trimmed path.
pub fn parseDownloadFinished(line: []const u8) ?[]const u8 {
    const key = "Download finished:";
    const i = std.mem.indexOf(u8, line, key) orelse return null;
    const p = std.mem.trim(u8, line[i + key.len ..], " \t\r\n");
    return if (p.len == 0) null else p;
}

pub const State = enum { QUEUED, ACTIVE, PAUSED, RETRYING, COMPLETING, COMPLETED, CANCELLED, FAILED };

pub const Transfer = struct {
    tag: u32,
    /// Owned copy; freed by `freeTransfers`.
    dest: []const u8,
    state: State,
    pct: ?f32,
};

pub fn freeTransfers(alloc: Allocator, ts: []Transfer) void {
    for (ts) |t| alloc.free(t.dest);
    alloc.free(ts);
}

/// Parse `mega-transfers --col-separator='|' --output-cols=TAG,DESTINYPATH,PROGRESS,STATE`.
/// Header, blank lines, short rows and rows with an unknown tag or state are skipped.
pub fn parseTransfersTable(text: []const u8, alloc: Allocator) ![]Transfer {
    var out: std.ArrayList(Transfer) = .empty;
    errdefer {
        for (out.items) |t| alloc.free(t.dest);
        out.deinit(alloc);
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // tag = first field, state = last, progress = second-to-last,
        // dest = everything between (so a `|` in a path survives).
        const first = std.mem.indexOfScalar(u8, line, '|') orelse continue;
        const last = std.mem.lastIndexOfScalar(u8, line, '|').?;
        if (last == first) continue;
        const mid = std.mem.lastIndexOfScalar(u8, line[0..last], '|').?;
        if (mid == first) continue;
        const f = [4][]const u8{
            std.mem.trim(u8, line[0..first], " \t"),
            std.mem.trim(u8, line[first + 1 .. mid], " \t"),
            std.mem.trim(u8, line[mid + 1 .. last], " \t"),
            std.mem.trim(u8, line[last + 1 ..], " \t"),
        };
        const tag = std.fmt.parseInt(u32, f[0], 10) catch continue; // header
        const state = std.meta.stringToEnum(State, f[3]) orelse continue;
        const dest = try alloc.dupe(u8, f[1]);
        errdefer alloc.free(dest);
        try out.append(alloc, .{ .tag = tag, .dest = dest, .state = state, .pct = trailingPct(f[2]) });
    }
    return out.toOwnedSlice(alloc);
}

fn trailingPct(s: []const u8) ?f32 {
    if (!std.mem.endsWith(u8, s, "%")) return null;
    const body = s[0 .. s.len - 1];
    var start = body.len;
    while (start > 0 and (std.ascii.isDigit(body[start - 1]) or body[start - 1] == '.')) start -= 1;
    if (start == body.len) return null;
    const v = std.fmt.parseFloat(f32, body[start..]) catch return null;
    return if (std.math.isFinite(v)) v else null;
}

/// `Account e-mail: <email>` -> trimmed email.
pub fn parseWhoami(stdout: []const u8) ?[]const u8 {
    const key = "Account e-mail:";
    const i = std.mem.indexOf(u8, stdout, key) orelse return null;
    const rest = stdout[i + key.len ..];
    const eol = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const e = std.mem.trim(u8, rest[0..eol], " \t\r");
    return if (e.len == 0) null else e;
}

/// Text between `wait for ` and ` until` in the quota-exceeded message.
pub fn parseQuotaWait(stdout: []const u8) ?[]const u8 {
    const key = "wait for ";
    const i = std.mem.indexOf(u8, stdout, key) orelse return null;
    const rest = stdout[i + key.len ..];
    const j = std.mem.indexOf(u8, rest, " until") orelse return null;
    const t = std.mem.trim(u8, rest[0..j], " \t\r\n");
    return if (t.len == 0) null else t;
}

/// Map a MEGAcmd client exit code to a failure reason. 54 (already
/// logged in) is not a failure.
pub fn exitToFail(code: u8) ?model.FailReason {
    return switch (code) {
        0, EXIT_ALREADY_LOGGED_IN => null,
        EXIT_QUOTA => .quota_exceeded,
        EXIT_NOT_LOGGED_IN => .auth_required,
        else => .network,
    };
}

pub const Located = struct {
    client: []const u8,
    server: ?[]const u8,
    dir: []const u8,
    is_windows_direct: bool,
};

/// Free the strings of a `Located` returned by `locate`/`locateIn`.
pub fn freeLocated(alloc: Allocator, l: Located) void {
    alloc.free(l.client);
    if (l.server) |s| alloc.free(s);
    alloc.free(l.dir);
}

/// Pure locator. Returned strings are allocated (free with `freeLocated`).
/// `exists` reports whether a file exists at an absolute path.
pub fn locateIn(
    alloc: Allocator,
    path_entries: []const []const u8,
    localappdata: ?[]const u8,
    os: std.Target.Os.Tag,
    exists: *const fn (path: []const u8) bool,
) ?Located {
    return locateInErr(alloc, path_entries, localappdata, os, exists) catch null;
}

fn locateInErr(
    alloc: Allocator,
    path_entries: []const []const u8,
    localappdata: ?[]const u8,
    os: std.Target.Os.Tag,
    exists: *const fn (path: []const u8) bool,
) !?Located {
    // Candidates are built with `defer free`; the result owns separate dupes.
    if (os == .windows) {
        const lad = localappdata orelse return null;
        const dir_p = try std.fmt.allocPrint(alloc, "{s}\\MEGAcmd", .{lad});
        defer alloc.free(dir_p);
        const client_p = try std.fmt.allocPrint(alloc, "{s}\\MegaClient.exe", .{dir_p});
        defer alloc.free(client_p);
        if (!exists(client_p)) return null;
        const server_p = try std.fmt.allocPrint(alloc, "{s}\\MEGAcmdServer.exe", .{dir_p});
        defer alloc.free(server_p);
        return try buildLocated(alloc, client_p, if (exists(server_p)) server_p else null, dir_p, true);
    }
    for (path_entries) |entry| {
        if (entry.len == 0) continue;
        const get = try std.fs.path.join(alloc, &.{ entry, "mega-get" });
        defer alloc.free(get);
        if (!exists(get)) continue;
        const exec_p = try std.fs.path.join(alloc, &.{ entry, "mega-exec" });
        defer alloc.free(exec_p);
        const server_p = try std.fs.path.join(alloc, &.{ entry, "mega-cmd-server" });
        defer alloc.free(server_p);
        return try buildLocated(alloc, if (exists(exec_p)) exec_p else get, if (exists(server_p)) server_p else null, entry, false);
    }
    return null;
}

/// Dupe the three strings into a `Located`; each allocation has one owner.
fn buildLocated(alloc: Allocator, client: []const u8, server: ?[]const u8, dir: []const u8, win: bool) !Located {
    const c = try alloc.dupe(u8, client);
    errdefer alloc.free(c);
    const sv: ?[]u8 = if (server) |x| try alloc.dupe(u8, x) else null;
    errdefer if (sv) |x| alloc.free(x);
    const d = try alloc.dupe(u8, dir);
    return .{ .client = c, .server = sv, .dir = d, .is_windows_direct = win };
}

threadlocal var real_io: ?std.Io = null;

fn realExists(path: []const u8) bool {
    const io = real_io orelse return false;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

/// Pure core of `locate`. A non-empty `override` is authoritative: if it
/// is not an existing file the result is null (no fallback to PATH).
fn locateCore(
    alloc: Allocator,
    override: []const u8,
    path_entries: []const []const u8,
    localappdata: ?[]const u8,
    os: std.Target.Os.Tag,
    exists: *const fn (path: []const u8) bool,
) ?Located {
    if (override.len > 0) {
        if (!exists(override)) return null;
        return buildLocated(alloc, override, null, std.fs.path.dirname(override) orelse ".", os == .windows) catch null;
    }
    return locateIn(alloc, path_entries, localappdata, os, exists);
}

/// Find MEGAcmd: `override` file, else PATH (Linux) / %LOCALAPPDATA% (Windows).
/// Free with `freeLocated`.
pub fn locate(alloc: Allocator, io: std.Io, environ: std.process.Environ, override: []const u8) ?Located {
    real_io = io;
    defer real_io = null;
    if (builtin.os.tag == .windows) {
        const lad = environ.getAlloc(alloc, "LOCALAPPDATA") catch return locateCore(alloc, override, &.{}, null, .windows, realExists);
        defer alloc.free(lad);
        return locateCore(alloc, override, &.{}, lad, .windows, realExists);
    }
    const path = environ.getAlloc(alloc, "PATH") catch return locateCore(alloc, override, &.{}, null, builtin.os.tag, realExists);
    defer alloc.free(path);
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(alloc);
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |e| entries.append(alloc, e) catch return null;
    return locateCore(alloc, override, entries.items, null, builtin.os.tag, realExists);
}

/// Build the argv for one MEGAcmd command. Outer slice owned; free with
/// `freeArgv`. Only element 0 is allocated for the Linux per-command
/// wrapper case; the rest are borrowed.
pub fn argv(alloc: Allocator, l: Located, cmd: []const u8, args: []const []const u8) ![]const []const u8 {
    const direct = l.is_windows_direct or std.mem.endsWith(u8, l.client, "mega-exec");
    const out = try alloc.alloc([]const u8, (if (direct) @as(usize, 2) else 1) + args.len);
    errdefer alloc.free(out);
    var i: usize = 0;
    if (direct) {
        out[0] = try alloc.dupe(u8, l.client);
        out[1] = cmd;
        i = 2;
    } else {
        const sub = try std.fmt.allocPrint(alloc, "mega-{s}", .{cmd});
        defer alloc.free(sub);
        out[0] = try std.fs.path.join(alloc, &.{ l.dir, sub });
        i = 1;
    }
    for (args) |a| {
        out[i] = a;
        i += 1;
    }
    return out;
}

pub fn freeArgv(alloc: Allocator, v: []const []const u8) void {
    alloc.free(v[0]);
    alloc.free(v);
}

pub fn installHint() []const u8 {
    return if (builtin.os.tag == .windows)
        "Install MEGAcmd from https://mega.io/cmd, then restart f69."
    else
        "Install MEGAcmd: nix profile add nixpkgs#megacmd (or your distro's megacmd package), then restart f69.";
}

// ---- tests ----

const testing = std.testing;

test "parseProgressLine MB, KB, \\r prefix, no pattern" {
    const a = parseProgressLine("TRANSFERRING ||##########          ||( 12/56 MB:  21.73 %) ").?;
    try testing.expectEqual(@as(u64, 12 * 1024 * 1024), a.done);
    try testing.expectEqual(@as(u64, 56 * 1024 * 1024), a.total);
    try testing.expectApproxEqAbs(@as(f32, 21.73), a.pct, 0.001);
    const b = parseProgressLine("\rTRANSFERRING ||     ||(512/1024 KB:  50.00 %) ").?;
    try testing.expectEqual(@as(u64, 512 * 1024), b.done);
    try testing.expectEqual(@as(u64, 1024 * 1024), b.total);
    try testing.expectApproxEqAbs(@as(f32, 50.0), b.pct, 0.001);
    const c = parseProgressLine("x ||| (3/4 GB:   5.00 %)").?;
    try testing.expectEqual(@as(u64, 3 << 30), c.done);
    try testing.expect(parseProgressLine("Download finished: /x (nothing)") == null);
    try testing.expect(parseProgressLine("no parens at all") == null);
}

test "parseDownloadFinished" {
    try testing.expectEqualStrings("/a/b c.zip", parseDownloadFinished("Download finished: /a/b c.zip\n").?);
    try testing.expect(parseDownloadFinished("TRANSFERRING") == null);
}

test "parseTransfersTable" {
    const text =
        "TAG|DESTINYPATH|PROGRESS|STATE\n" ++
        "12|/home/u/dl/mega/7/Game.zip|13.64 MB of 13.85 MB  98.5%|ACTIVE\n" ++
        "\n" ++
        "13|/x|----%|QUEUED\n" ++
        "bad|row\n";
    const ts = try parseTransfersTable(text, testing.allocator);
    defer freeTransfers(testing.allocator, ts);
    try testing.expectEqual(@as(usize, 2), ts.len);
    try testing.expectEqual(@as(u32, 12), ts[0].tag);
    try testing.expectEqualStrings("/home/u/dl/mega/7/Game.zip", ts[0].dest);
    try testing.expectEqual(State.ACTIVE, ts[0].state);
    try testing.expectApproxEqAbs(@as(f32, 98.5), ts[0].pct.?, 0.001);
    try testing.expectEqual(State.QUEUED, ts[1].state);
    try testing.expect(ts[1].pct == null);
}

test "parseWhoami, parseQuotaWait" {
    try testing.expectEqualStrings("user@example.com", parseWhoami("Account e-mail: user@example.com\n").?);
    try testing.expect(parseWhoami("Not logged in.") == null);
    const q = "Transfer quota exceeded. You can't continue downloading as you've used all of the transfer quota available to you. Please wait for 5 hours 3 minutes until more free quota becomes available.";
    try testing.expectEqualStrings("5 hours 3 minutes", parseQuotaWait(q).?);
    try testing.expect(parseQuotaWait("nothing") == null);
}

test "exitToFail" {
    try testing.expect(exitToFail(0) == null);
    try testing.expect(exitToFail(54) == null);
    try testing.expectEqual(model.FailReason.quota_exceeded, exitToFail(17).?);
    try testing.expectEqual(model.FailReason.auth_required, exitToFail(57).?);
    try testing.expectEqual(model.FailReason.network, exitToFail(1).?);
}

test "argv linux wrapper, linux mega-exec, windows" {
    const a = testing.allocator;
    const lin: Located = .{ .client = "/opt/m/mega-get", .server = null, .dir = "/opt/m", .is_windows_direct = false };
    const v = try argv(a, lin, "get", &.{ "url", "/dest" });
    defer freeArgv(a, v);
    try testing.expectEqual(@as(usize, 3), v.len);
    try testing.expectEqualStrings("/opt/m/mega-get", v[0]);
    try testing.expectEqualStrings("/dest", v[2]);

    const ex: Located = .{ .client = "/opt/m/mega-exec", .server = null, .dir = "/opt/m", .is_windows_direct = false };
    const v2 = try argv(a, ex, "whoami", &.{});
    defer freeArgv(a, v2);
    try testing.expectEqual(@as(usize, 2), v2.len);
    try testing.expectEqualStrings("/opt/m/mega-exec", v2[0]);
    try testing.expectEqualStrings("whoami", v2[1]);

    const win: Located = .{ .client = "C:\\M\\MegaClient.exe", .server = null, .dir = "C:\\M", .is_windows_direct = true };
    const v3 = try argv(a, win, "get", &.{"u"});
    defer freeArgv(a, v3);
    try testing.expectEqualStrings("C:\\M\\MegaClient.exe", v3[0]);
    try testing.expectEqualStrings("get", v3[1]);
    try testing.expectEqualStrings("u", v3[2]);
}

const fake_files = [_][]const u8{
    "/usr/bin/other",                 "/opt/mega/mega-get",                "/opt/mega/mega-exec", "/opt/mega/mega-cmd-server",
    "C:\\L\\MEGAcmd\\MegaClient.exe", "C:\\L\\MEGAcmd\\MEGAcmdServer.exe",
};

fn fakeExists(path: []const u8) bool {
    for (fake_files) |f| if (std.mem.eql(u8, f, path)) return true;
    return false;
}

test "locateIn linux PATH" {
    const a = testing.allocator;
    const l = locateIn(a, &.{ "/usr/bin", "/opt/mega" }, null, .linux, fakeExists).?;
    defer freeLocated(a, l);
    try testing.expectEqualStrings("/opt/mega/mega-exec", l.client);
    try testing.expectEqualStrings("/opt/mega/mega-cmd-server", l.server.?);
    try testing.expectEqualStrings("/opt/mega", l.dir);
    try testing.expect(!l.is_windows_direct);
    try testing.expect(locateIn(a, &.{"/usr/bin"}, null, .linux, fakeExists) == null);
}

test "locateIn windows LOCALAPPDATA" {
    const a = testing.allocator;
    const l = locateIn(a, &.{}, "C:\\L", .windows, fakeExists).?;
    defer freeLocated(a, l);
    try testing.expectEqualStrings("C:\\L\\MEGAcmd\\MegaClient.exe", l.client);
    try testing.expectEqualStrings("C:\\L\\MEGAcmd\\MEGAcmdServer.exe", l.server.?);
    try testing.expect(l.is_windows_direct);
    try testing.expect(locateIn(a, &.{}, "C:\\Nope", .windows, fakeExists) == null);
    try testing.expect(locateIn(a, &.{}, null, .windows, fakeExists) == null);
}

test "locate override file" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mega-get", .data = "x" });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(dir);
    const p = try std.fs.path.join(a, &.{ dir, "mega-get" });
    defer a.free(p);
    const l = locate(a, testing.io, .empty, p).?;
    defer freeLocated(a, l);
    try testing.expectEqualStrings(p, l.client);
    try testing.expectEqualStrings(dir, l.dir);
    try testing.expect(l.server == null);
    try testing.expect(locate(a, testing.io, .empty, "/nonexistent/mega-get") == null);
}

test "parseProgressLine rejects non-finite pct" {
    try testing.expect(parseProgressLine("(1/2 MB: nan %)") == null);
    try testing.expect(parseProgressLine("(1/2 MB: inf %)") == null);
}

test "parseTransfersTable keeps a pipe inside the path" {
    const ts = try parseTransfersTable("5|/a|b/c.zip|1.0 MB of 2 MB  50.0%|PAUSED\n", testing.allocator);
    defer freeTransfers(testing.allocator, ts);
    try testing.expectEqual(@as(usize, 1), ts.len);
    try testing.expectEqualStrings("/a|b/c.zip", ts[0].dest);
    try testing.expectEqual(State.PAUSED, ts[0].state);
    try testing.expectApproxEqAbs(@as(f32, 50.0), ts[0].pct.?, 0.001);
}

test "locateCore: bad override does not fall through to PATH" {
    const a = testing.allocator;
    try testing.expect(locateCore(a, "/typo/mega-get", &.{"/opt/mega"}, null, .linux, fakeExists) == null);
    try testing.expect(locateCore(a, "/opt/mega", &.{"/opt/mega"}, null, .linux, fakeExists) == null);
    const l = locateCore(a, "", &.{"/opt/mega"}, null, .linux, fakeExists).?;
    freeLocated(a, l);
    const o = locateCore(a, "/opt/mega/mega-get", &.{}, null, .linux, fakeExists).?;
    defer freeLocated(a, o);
    try testing.expectEqualStrings("/opt/mega", o.dir);
}

fn locateOom(a: Allocator, os: std.Target.Os.Tag) !void {
    if (try locateInErr(a, &.{ "/usr/bin", "/opt/mega" }, "C:\\L", os, fakeExists)) |l| freeLocated(a, l);
}

test "locateIn is OOM-safe (Linux and Windows tables)" {
    try testing.checkAllAllocationFailures(testing.allocator, locateOom, .{std.Target.Os.Tag.linux});
    try testing.checkAllAllocationFailures(testing.allocator, locateOom, .{std.Target.Os.Tag.windows});
}

fn transfersOom(a: Allocator) !void {
    const ts = try parseTransfersTable("TAG|D|P|S\n1|/a|1%|ACTIVE\n2|/b|----%|QUEUED\n", a);
    freeTransfers(a, ts);
}

test "parseTransfersTable is OOM-safe" {
    try testing.checkAllAllocationFailures(testing.allocator, transfersOom, .{});
}

test "installHint" {
    try testing.expect(installHint().len > 0);
}
