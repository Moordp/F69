// Raw download-link scanner. Walks the HTML of a thread's download
// region and emits ONE record per `<a>`, in page order, with the text the
// author put around it. It does not decide what a link means — that is
// `dl_classify.zig`, which reads the stored records and can be improved
// without a re-scrape. OP layouts vary a lot (headings, bold labels,
// nested spoilers, bare link rows), so nothing here relies on structure.
//
// For every link we keep:
//   href    — exactly as written (masked / wrapped / direct)
//   text    — the link's own visible text (may be empty or obscured)
//   lead    — the other text on the same line ("Win/Linux:", "Part 2")
//   ctx     — the last few link-free lines above it, '\n'-joined
//             ("Chapter 3 (Beta)", "Spoiler", "Extras")
//   spoiler — how many spoiler blocks it sits inside
//   line    — line number, so links on one line can be grouped
//
// Pure: no I/O, no globals.

const std = @import("std");
const domain = @import("domain.zig");

pub const Record = domain.DlRecord;

pub const MAX_RECORDS: usize = 400;
const MAX_HREF: usize = 2048;
const MAX_TEXT: usize = 120;
const MAX_LEAD: usize = 160;
const MAX_CTX_LINES: usize = 4;
const MAX_CTX_LINE: usize = 100;
const MAX_DIV_DEPTH: usize = 64;

const FLAG_SPOILER: u8 = 1;
const FLAG_CHROME: u8 = 2;

pub fn freeRecords(alloc: std.mem.Allocator, recs: []const Record) void {
    for (recs) |r| {
        alloc.free(r.href);
        alloc.free(r.text);
        alloc.free(r.lead);
        alloc.free(r.ctx);
    }
    alloc.free(recs);
}

const Pending = struct {
    href: []const u8, // borrows from `html`
    text: []u8, // owned
};

const Scanner = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayList(Record) = .empty,
    line_text: std.ArrayList(u8) = .empty,
    anchor_text: std.ArrayList(u8) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    ctx: std.ArrayList([]u8) = .empty,
    div_flags: [MAX_DIV_DEPTH]u8 = undefined,
    div_depth: usize = 0,
    /// Divs nested deeper than MAX_DIV_DEPTH still count here so the
    /// matching `</div>` pops the right thing.
    div_overflow: usize = 0,
    spoilers: u8 = 0,
    chrome: u8 = 0,
    in_anchor: bool = false,
    cur_href: []const u8 = "",
    line_no: u32 = 0,

    fn deinit(self: *Scanner) void {
        freeRecordList(self.alloc, &self.out);
        self.line_text.deinit(self.alloc);
        self.anchor_text.deinit(self.alloc);
        for (self.pending.items) |p| self.alloc.free(p.text);
        self.pending.deinit(self.alloc);
        for (self.ctx.items) |c| self.alloc.free(c);
        self.ctx.deinit(self.alloc);
    }

    fn pushDiv(self: *Scanner, class: []const u8) void {
        var flag: u8 = 0;
        if (std.mem.indexOf(u8, class, "bbCodeSpoiler-content") != null) flag |= FLAG_SPOILER;
        if (std.mem.indexOf(u8, class, "sf95-ddl") != null) flag |= FLAG_CHROME;
        if (self.div_depth >= MAX_DIV_DEPTH) {
            self.div_overflow += 1;
            return;
        }
        self.div_flags[self.div_depth] = flag;
        self.div_depth += 1;
        if (flag & FLAG_SPOILER != 0) self.spoilers +|= 1;
        if (flag & FLAG_CHROME != 0) self.chrome +|= 1;
    }

    fn popDiv(self: *Scanner) void {
        if (self.div_overflow > 0) {
            self.div_overflow -= 1;
            return;
        }
        if (self.div_depth == 0) return;
        self.div_depth -= 1;
        const flag = self.div_flags[self.div_depth];
        if (flag & FLAG_SPOILER != 0 and self.spoilers > 0) self.spoilers -= 1;
        if (flag & FLAG_CHROME != 0 and self.chrome > 0) self.chrome -= 1;
    }

    fn addText(self: *Scanner, chunk: []const u8) !void {
        if (self.chrome > 0) return;
        const list = if (self.in_anchor) &self.anchor_text else &self.line_text;
        try appendDecoded(self.alloc, list, chunk);
    }

    fn startAnchor(self: *Scanner, href: []const u8) void {
        self.in_anchor = true;
        self.cur_href = href;
        self.anchor_text.clearRetainingCapacity();
    }

    fn endAnchor(self: *Scanner) !void {
        if (!self.in_anchor) return;
        self.in_anchor = false;
        const text = try normalizeText(self.alloc, self.anchor_text.items, MAX_TEXT);
        errdefer self.alloc.free(text);
        try self.pending.append(self.alloc, .{ .href = self.cur_href, .text = text });
        // Keep neighbouring words from fusing in `line_text`.
        try self.line_text.append(self.alloc, ' ');
    }

    fn flushLine(self: *Scanner) !void {
        if (self.in_anchor) return;
        defer self.line_text.clearRetainingCapacity();

        if (self.pending.items.len == 0) {
            const t = try normalizeText(self.alloc, self.line_text.items, MAX_CTX_LINE);
            if (t.len == 0) {
                self.alloc.free(t);
                return;
            }
            errdefer self.alloc.free(t);
            if (self.ctx.items.len >= MAX_CTX_LINES) {
                self.alloc.free(self.ctx.orderedRemove(0));
            }
            try self.ctx.append(self.alloc, t);
            return;
        }

        const lead = try leadText(self.alloc, self.line_text.items);
        defer self.alloc.free(lead);
        const ctx = try joinCtx(self.alloc, self.ctx.items);
        defer self.alloc.free(ctx);

        for (self.pending.items) |p| {
            defer self.alloc.free(p.text);
            if (self.out.items.len >= MAX_RECORDS) continue;
            const rec = try self.makeRecord(p, lead, ctx);
            errdefer freeOne(self.alloc, rec);
            try self.out.append(self.alloc, rec);
        }
        self.pending.clearRetainingCapacity();
        self.line_no += 1;
    }

    fn makeRecord(self: *Scanner, p: Pending, lead: []const u8, ctx: []const u8) !Record {
        const href = try self.alloc.dupe(u8, p.href);
        errdefer self.alloc.free(href);
        const text = try self.alloc.dupe(u8, p.text);
        errdefer self.alloc.free(text);
        const lead_d = try self.alloc.dupe(u8, lead);
        errdefer self.alloc.free(lead_d);
        const ctx_d = try self.alloc.dupe(u8, ctx);
        return .{
            .href = href,
            .text = text,
            .lead = lead_d,
            .ctx = ctx_d,
            .spoiler = self.spoilers,
            .line = self.line_no,
        };
    }
};

fn freeOne(alloc: std.mem.Allocator, r: Record) void {
    alloc.free(r.href);
    alloc.free(r.text);
    alloc.free(r.lead);
    alloc.free(r.ctx);
}

fn freeRecordList(alloc: std.mem.Allocator, list: *std.ArrayList(Record)) void {
    for (list.items) |r| freeOne(alloc, r);
    list.deinit(alloc);
}

/// Keep only records whose href passes `keep`; frees the rest and the old
/// outer slice. Takes ownership of `recs` (freed on error too).
pub fn filter(
    alloc: std.mem.Allocator,
    recs: []const Record,
    keep: *const fn (href: []const u8) bool,
) std.mem.Allocator.Error![]const Record {
    var n: usize = 0;
    for (recs) |r| {
        if (keep(r.href)) n += 1;
    }
    const out = alloc.alloc(Record, n) catch |e| {
        freeRecords(alloc, recs);
        return e;
    };
    var k: usize = 0;
    for (recs) |r| {
        if (keep(r.href)) {
            out[k] = r;
            k += 1;
        } else freeOne(alloc, r);
    }
    alloc.free(recs);
    return out;
}

/// Scan `html` (the download region of a thread OP) into raw records.
/// Caller owns the slice and every string in it — free with `freeRecords`.
pub fn scan(alloc: std.mem.Allocator, html: []const u8) std.mem.Allocator.Error![]const Record {
    var s: Scanner = .{ .alloc = alloc };
    errdefer s.deinit();

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] != '<') {
            const next = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
            try s.addText(html[i..next]);
            i = next;
            continue;
        }
        const gt = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
        const tag = html[i + 1 .. gt];
        i = gt + 1;
        if (tag.len == 0) continue;

        if (tag[0] == '!' or tag[0] == '?') continue; // comment / doctype

        const closing = tag[0] == '/';
        const name = tagName(if (closing) tag[1..] else tag);

        if (eqi(name, "script") or eqi(name, "style")) {
            if (!closing) {
                const close = if (eqi(name, "script")) "</script" else "</style";
                const at = std.ascii.findIgnoreCasePos(html, i, close) orelse html.len;
                i = if (std.mem.indexOfScalarPos(u8, html, at, '>')) |e| e + 1 else html.len;
            }
            continue;
        }

        if (eqi(name, "a")) {
            if (closing) {
                try s.endAnchor();
            } else if (s.chrome == 0) {
                if (attrValue(tag, "href")) |h| {
                    if (isCatalogHref(h)) s.startAnchor(h);
                }
            }
        } else if (eqi(name, "div")) {
            try s.flushLine();
            if (closing) s.popDiv() else s.pushDiv(attrValue(tag, "class") orelse "");
        } else if (isLineBreak(name)) {
            // Inside a link a break is just a word gap.
            if (s.in_anchor) try s.anchor_text.append(alloc, ' ') else try s.flushLine();
        }
    }
    // A page that ends mid-anchor still yields what it had.
    try s.endAnchor();
    try s.flushLine();

    const result = try s.out.toOwnedSlice(alloc);
    s.out = .empty;
    s.deinit();
    return result;
}

fn isLineBreak(name: []const u8) bool {
    const names = [_][]const u8{ "br", "p", "li", "ul", "ol", "tr", "hr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "button" };
    for (names) |n| if (eqi(name, n)) return true;
    return false;
}

/// Only http(s) links are catalogued; `#anchors`, `mailto:`, `javascript:`
/// and oversize values are not downloads. Whether an http link is
/// *useful* is the classifier's call.
fn isCatalogHref(h: []const u8) bool {
    if (h.len == 0 or h.len > MAX_HREF) return false;
    return std.mem.startsWith(u8, h, "https://") or std.mem.startsWith(u8, h, "http://");
}

fn eqi(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn tagName(tag: []const u8) []const u8 {
    var end: usize = 0;
    while (end < tag.len and !std.ascii.isWhitespace(tag[end]) and tag[end] != '/') : (end += 1) {}
    return tag[0..end];
}

/// Value of `key="…"` (or `'…'`) inside a tag body. Word-boundary match so
/// `data-href` is not mistaken for `href`.
fn attrValue(tag: []const u8, key: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.ascii.findIgnoreCasePos(tag, from, key)) |at| {
        from = at + 1;
        if (at == 0 or !std.ascii.isWhitespace(tag[at - 1])) continue;
        var j = at + key.len;
        while (j < tag.len and std.ascii.isWhitespace(tag[j])) : (j += 1) {}
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and std.ascii.isWhitespace(tag[j])) : (j += 1) {}
        if (j >= tag.len) return null;
        const q = tag[j];
        if (q == '"' or q == '\'') {
            const end = std.mem.indexOfScalarPos(u8, tag, j + 1, q) orelse return null;
            return tag[j + 1 .. end];
        }
        var end = j;
        while (end < tag.len and !std.ascii.isWhitespace(tag[end])) : (end += 1) {}
        return tag[j..end];
    }
    return null;
}

/// Append `chunk` with the common HTML entities decoded.
fn appendDecoded(alloc: std.mem.Allocator, list: *std.ArrayList(u8), chunk: []const u8) !void {
    var i: usize = 0;
    while (i < chunk.len) {
        if (chunk[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, chunk, i, ';')) |semi| {
                if (semi - i <= 8) {
                    if (decodeEntity(chunk[i + 1 .. semi])) |cp| {
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                        if (n > 0) {
                            try list.appendSlice(alloc, buf[0..n]);
                            i = semi + 1;
                            continue;
                        }
                    }
                }
            }
        }
        try list.append(alloc, chunk[i]);
        i += 1;
    }
}

fn decodeEntity(name: []const u8) ?u21 {
    if (name.len == 0) return null;
    if (name[0] == '#') {
        const body = name[1..];
        if (body.len == 0) return null;
        const v = if (body[0] == 'x' or body[0] == 'X')
            std.fmt.parseInt(u21, body[1..], 16) catch return null
        else
            std.fmt.parseInt(u21, body, 10) catch return null;
        return v;
    }
    if (std.mem.eql(u8, name, "amp")) return '&';
    if (std.mem.eql(u8, name, "lt")) return '<';
    if (std.mem.eql(u8, name, "gt")) return '>';
    if (std.mem.eql(u8, name, "quot")) return '"';
    if (std.mem.eql(u8, name, "apos")) return '\'';
    if (std.mem.eql(u8, name, "nbsp")) return ' ';
    return null;
}

/// Collapse whitespace runs to one space, trim, and cut at `max` bytes
/// (on a UTF-8 boundary). Caller owns the result.
fn normalizeText(alloc: std.mem.Allocator, raw: []const u8, max: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var pending_space = false;
    var k: usize = 0;
    while (k < raw.len) : (k += 1) {
        const c = raw[k];
        // Zero-width space / joiner / BOM (E2 80 8B..8D, EF BB BF) and
        // no-break space (C2 A0): OP authors paste these as "empty" text.
        if (c == 0xE2 and k + 2 < raw.len and raw[k + 1] == 0x80 and raw[k + 2] >= 0x8B and raw[k + 2] <= 0x8D) {
            k += 2;
            pending_space = out.items.len > 0;
            continue;
        }
        if (c == 0xEF and k + 2 < raw.len and raw[k + 1] == 0xBB and raw[k + 2] == 0xBF) {
            k += 2;
            continue;
        }
        if (c == 0xC2 and k + 1 < raw.len and raw[k + 1] == 0xA0) {
            k += 1;
            pending_space = out.items.len > 0;
            continue;
        }
        if (std.ascii.isWhitespace(c) or c == 0) {
            pending_space = out.items.len > 0;
            continue;
        }
        if (out.items.len >= max) break;
        if (pending_space) {
            try out.append(alloc, ' ');
            pending_space = false;
        }
        try out.append(alloc, c);
    }
    // Don't leave a cut-off multibyte sequence at the end.
    while (out.items.len > 0 and !std.unicode.utf8ValidateSlice(out.items)) _ = out.pop();
    return out.toOwnedSlice(alloc);
}

/// Line text with the bare separators removed (`-`, `|`, `·` …) that sit
/// between links: "Win: - - " → "Win:".
fn leadText(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const norm = try normalizeText(alloc, raw, MAX_LEAD * 2);
    defer alloc.free(norm);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.tokenizeScalar(u8, norm, ' ');
    while (it.next()) |tok| {
        if (isSeparator(tok)) continue;
        if (out.items.len + tok.len + 1 > MAX_LEAD) break;
        if (out.items.len > 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, tok);
    }
    return out.toOwnedSlice(alloc);
}

fn isSeparator(tok: []const u8) bool {
    if (tok.len == 0) return true;
    // Multi-byte separators (– — · •) are matched by prefix.
    const seps = [_][]const u8{ "-", "–", "—", "|", "·", "•", "/", ",", "+", "*" };
    var rest = tok;
    outer: while (rest.len > 0) {
        for (seps) |s| {
            if (std.mem.startsWith(u8, rest, s)) {
                rest = rest[s.len..];
                continue :outer;
            }
        }
        return false;
    }
    return true;
}

fn joinCtx(alloc: std.mem.Allocator, lines: []const []u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (lines, 0..) |l, k| {
        if (k > 0) try out.append(alloc, '\n');
        try out.appendSlice(alloc, l);
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectRec(r: Record, href: []const u8, text: []const u8, lead: []const u8) !void {
    try testing.expectEqualStrings(href, r.href);
    try testing.expectEqualStrings(text, r.text);
    try testing.expectEqualStrings(lead, r.lead);
}

test "scan: one record per link, lead text and separators" {
    const html = "<b>DOWNLOAD</b><br>" ++
        "<b>Win/Linux</b>: <a href=\"https://mega.nz/a\">MEGA</a> - <a href=\"https://pixeldrain.com/u/b\">PIXELDRAIN</a><br>" ++
        "<b>Mac</b>: <a href=\"https://mega.nz/c\">MEGA</a>";
    const recs = try scan(testing.allocator, html);
    defer freeRecords(testing.allocator, recs);
    try testing.expectEqual(@as(usize, 3), recs.len);
    try expectRec(recs[0], "https://mega.nz/a", "MEGA", "Win/Linux:");
    try expectRec(recs[1], "https://pixeldrain.com/u/b", "PIXELDRAIN", "Win/Linux:");
    try expectRec(recs[2], "https://mega.nz/c", "MEGA", "Mac:");
    try testing.expectEqual(recs[0].line, recs[1].line);
    try testing.expect(recs[2].line != recs[1].line);
    try testing.expectEqualStrings("DOWNLOAD", recs[0].ctx);
}

test "scan: headings above become context; links with no lead keep it" {
    const html = "<b>Chapter 3 (Beta)</b><br><b>Part 2</b><br>" ++
        "<a href=\"https://gofile.io/d/x\">GOFILE</a> - <a href=\"https://mega.nz/y\">MEGA</a><br>";
    const recs = try scan(testing.allocator, html);
    defer freeRecords(testing.allocator, recs);
    try testing.expectEqual(@as(usize, 2), recs.len);
    try testing.expectEqualStrings("", recs[0].lead);
    try testing.expectEqualStrings("Chapter 3 (Beta)\nPart 2", recs[1].ctx);
}

test "scan: spoiler depth counts nested spoilers" {
    const html = "<a href=\"https://a.example/0\">top</a><br>" ++
        "<div class=\"bbCodeSpoiler\"><button><span>Old versions</span></button>" ++
        "<div class=\"bbCodeSpoiler-content\"><div class=\"bbCodeBlock\">" ++
        "<a href=\"https://a.example/1\">one</a><br>" ++
        "<div class=\"bbCodeSpoiler-content\"><a href=\"https://a.example/2\">two</a></div>" ++
        "</div></div></div><a href=\"https://a.example/3\">after</a>";
    const recs = try scan(testing.allocator, html);
    defer freeRecords(testing.allocator, recs);
    try testing.expectEqual(@as(usize, 4), recs.len);
    try testing.expectEqual(@as(u8, 0), recs[0].spoiler);
    try testing.expectEqual(@as(u8, 1), recs[1].spoiler);
    try testing.expectEqual(@as(u8, 2), recs[2].spoiler);
    try testing.expectEqual(@as(u8, 0), recs[3].spoiler);
    try testing.expectEqualStrings("Old versions", recs[1].ctx);
}

test "scan: donor banner chrome and non-http hrefs are skipped" {
    const html = "<div class=\"sf95-ddl_op\"><div>As a Donor <a href=\"https://f95zone.to/threads/107158/\">learn more</a></div>" ++
        "<button>Download Files (13)</button></div>" ++
        "<a href=\"#top\">up</a><a href=\"mailto:x@y.z\">mail</a><a href=\"javascript:void(0)\">js</a>" ++
        "<a href=\"https://mega.nz/k\">MEGA</a>";
    const recs = try scan(testing.allocator, html);
    defer freeRecords(testing.allocator, recs);
    try testing.expectEqual(@as(usize, 1), recs.len);
    try testing.expectEqualStrings("https://mega.nz/k", recs[0].href);
    try testing.expectEqualStrings("", recs[0].ctx);
}

test "scan: empty and obscured link text are kept; entities decode" {
    const html = "<a href=\"https://attachments.f95zone.to/2024/01/9_save.zip\"></a> " ++
        "<a href=\"https://nopy.to/x\">********B09N</a> <a href=\"https://a.example/q?a=1&amp;b=2\">R&amp;D &#8211; x</a>";
    const recs = try scan(testing.allocator, html);
    defer freeRecords(testing.allocator, recs);
    try testing.expectEqual(@as(usize, 3), recs.len);
    try testing.expectEqualStrings("", recs[0].text);
    try testing.expectEqualStrings("********B09N", recs[1].text);
    // href is kept verbatim (entities and all); text is decoded.
    try testing.expectEqualStrings("https://a.example/q?a=1&amp;b=2", recs[2].href);
    try testing.expectEqualStrings("R&D \u{2013} x", recs[2].text);
}

test "scan: <br> inside an anchor does not split it; unterminated input is safe" {
    const html = "<a href=\"https://mega.nz/z\">MEGA<br>mirror</a><br><a href=\"https://mega.nz/y\">tail";
    const recs = try scan(testing.allocator, html);
    defer freeRecords(testing.allocator, recs);
    try testing.expectEqual(@as(usize, 2), recs.len);
    try testing.expectEqualStrings("MEGA mirror", recs[0].text);
    try testing.expectEqualStrings("tail", recs[1].text);
}

test "scan: no links, empty input, hostile bytes" {
    const a = try scan(testing.allocator, "");
    defer freeRecords(testing.allocator, a);
    try testing.expectEqual(@as(usize, 0), a.len);
    const b = try scan(testing.allocator, "<<<>>><a href=<a href=\"\"><div></div></div></div>");
    defer freeRecords(testing.allocator, b);
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "scan: record count is capped" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var k: usize = 0;
    while (k < MAX_RECORDS + 50) : (k += 1) {
        try buf.appendSlice(testing.allocator, "<a href=\"https://a.example/f\">x</a><br>");
    }
    const recs = try scan(testing.allocator, buf.items);
    defer freeRecords(testing.allocator, recs);
    try testing.expectEqual(MAX_RECORDS, recs.len);
}

test "filter: keeps passing records, frees the rest" {
    const html = "<a href=\"https://mega.nz/a\">A</a> <a href=\"https://a.example/b\">B</a>";
    const recs = try scan(testing.allocator, html);
    const kept = try filter(testing.allocator, recs, struct {
        fn keep(h: []const u8) bool {
            return std.mem.indexOf(u8, h, "mega") != null;
        }
    }.keep);
    defer freeRecords(testing.allocator, kept);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("A", kept[0].text);
}

test "scan: zero-width spaces and lone asterisks are not label text" {
    const html = "<b>Extras</b>: * <a href=\"https://a.example/x\">Save</a><br>\u{200B}<a href=\"https://a.example/y\"></a>";
    const recs = try scan(testing.allocator, html);
    defer freeRecords(testing.allocator, recs);
    try testing.expectEqual(@as(usize, 2), recs.len);
    try testing.expectEqualStrings("Extras:", recs[0].lead);
    try testing.expectEqualStrings("", recs[1].lead);
}
