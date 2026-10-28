// Classifier for catalogued download links. Reads the raw fields that
// `dl_scan.zig` stored (href, text, lead, ctx) and works out what a link
// is. It never touches the network or the database, so a better rule set
// applies to every stored link without a re-scrape.
//
// Everything is best-effort: when a rule does not match, the field stays
// "unknown" and the link is still offered. OP layouts are not uniform.

const std = @import("std");

pub const Host = enum {
    mega,
    pixeldrain,
    gofile,
    buzzheavier,
    datanodes,
    mixdrop,
    vikingfile,
    akirabox,
    workupload,
    nopy,
    mediafire,
    uploadhaven,
    google_drive,
    onedrive,
    dropbox,
    one_fichier,
    f95_attachment,
    f95_thread,
    /// F95's own `/dl/…` wrapper — the real host is only known after the
    /// redirect, so the link text is the best hint.
    f95_wrapped,
    /// Some other http(s) site.
    other,
    /// Not a link we can use at all.
    unknown,

    pub fn label(self: Host) []const u8 {
        return switch (self) {
            .mega => "MEGA",
            .pixeldrain => "Pixeldrain",
            .gofile => "Gofile",
            .buzzheavier => "Buzzheavier",
            .datanodes => "Datanodes",
            .mixdrop => "Mixdrop",
            .vikingfile => "Vikingfile",
            .akirabox => "Akirabox",
            .workupload => "Workupload",
            .nopy => "Nopy",
            .mediafire => "MediaFire",
            .uploadhaven => "Uploadhaven",
            .google_drive => "Google Drive",
            .onedrive => "OneDrive",
            .dropbox => "Dropbox",
            .one_fichier => "1fichier",
            .f95_attachment => "F95 attachment",
            .f95_thread => "F95 thread",
            .f95_wrapped => "F95 link",
            .other => "Other",
            .unknown => "Unknown",
        };
    }

    /// True for hosts that serve a downloadable file (not an F95 page).
    pub fn isFileHost(self: Host) bool {
        return switch (self) {
            .f95_thread, .f95_wrapped, .other, .unknown => false,
            else => true,
        };
    }
};

pub const Wrapper = enum {
    /// The href is the host's own URL.
    none,
    /// `https://f95zone.to/masked/<host>/…` — needs F95 to redirect it.
    masked,
    /// `https://f95zone.to/dl/<thread>/?…` — signed, per-user, expiring.
    dl,
    /// F95 blanked the host (`https://********abc/file.rar`); the link
    /// text is the only hint to the real host.
    hidden,
};

pub const Parsed = struct {
    host: Host,
    wrapper: Wrapper,
};

const DomainRule = struct { suffix: []const u8, host: Host };

const DOMAINS = [_]DomainRule{
    .{ .suffix = "mega.nz", .host = .mega },
    .{ .suffix = "mega.co.nz", .host = .mega },
    .{ .suffix = "pixeldrain.com", .host = .pixeldrain },
    .{ .suffix = "pixeldrain.net", .host = .pixeldrain },
    .{ .suffix = "gofile.io", .host = .gofile },
    .{ .suffix = "buzzheavier.com", .host = .buzzheavier },
    .{ .suffix = "bzzhr.to", .host = .buzzheavier },
    .{ .suffix = "bzzhr.co", .host = .buzzheavier },
    .{ .suffix = "datanodes.to", .host = .datanodes },
    .{ .suffix = "mixdrop.ag", .host = .mixdrop },
    .{ .suffix = "mixdrop.co", .host = .mixdrop },
    .{ .suffix = "mixdrop.to", .host = .mixdrop },
    .{ .suffix = "mixdrop.ps", .host = .mixdrop },
    .{ .suffix = "mixdrop.is", .host = .mixdrop },
    .{ .suffix = "vikingfile.com", .host = .vikingfile },
    .{ .suffix = "akirabox.com", .host = .akirabox },
    .{ .suffix = "akirabox.to", .host = .akirabox },
    .{ .suffix = "krakencloud.net", .host = .akirabox },
    .{ .suffix = "workupload.com", .host = .workupload },
    .{ .suffix = "nopy.to", .host = .nopy },
    .{ .suffix = "nopy.net", .host = .nopy },
    .{ .suffix = "mediafire.com", .host = .mediafire },
    .{ .suffix = "uploadhaven.com", .host = .uploadhaven },
    .{ .suffix = "drive.google.com", .host = .google_drive },
    .{ .suffix = "docs.google.com", .host = .google_drive },
    .{ .suffix = "1drv.ms", .host = .onedrive },
    .{ .suffix = "onedrive.live.com", .host = .onedrive },
    .{ .suffix = "dropbox.com", .host = .dropbox },
    .{ .suffix = "1fichier.com", .host = .one_fichier },
};

/// Host part of an http(s) URL, lowercased into `buf`. Null when the URL
/// has no usable host.
fn hostOf(url: []const u8, buf: []u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[scheme_end + 3 ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] != '/' and rest[end] != '?' and rest[end] != '#') : (end += 1) {}
    var h = rest[0..end];
    if (std.mem.lastIndexOfScalar(u8, h, '@')) |at| h = h[at + 1 ..];
    if (std.mem.indexOfScalar(u8, h, ':')) |c| h = h[0..c];
    if (h.len == 0 or h.len > buf.len) return null;
    return std.ascii.lowerString(buf, h);
}

fn hostFromDomain(domain: []const u8) ?Host {
    for (DOMAINS) |r| {
        if (std.mem.eql(u8, domain, r.suffix)) return r.host;
        // Subdomain: "phs5.krakencloud.net" matches "krakencloud.net".
        if (domain.len > r.suffix.len and
            std.mem.endsWith(u8, domain, r.suffix) and
            domain[domain.len - r.suffix.len - 1] == '.') return r.host;
    }
    return null;
}

fn isF95Domain(domain: []const u8) bool {
    return std.mem.eql(u8, domain, "f95zone.to") or
        std.mem.eql(u8, domain, "www.f95zone.to") or
        std.mem.eql(u8, domain, "f95zone.com") or
        std.mem.eql(u8, domain, "www.f95zone.com");
}

/// Work out the host and wrapper of a stored href.
pub fn parseHref(href: []const u8) Parsed {
    var buf: [256]u8 = undefined;
    const domain = hostOf(href, &buf) orelse return .{ .host = .unknown, .wrapper = .none };
    if (domain[0] == '*') return .{ .host = .unknown, .wrapper = .hidden };

    if (std.mem.eql(u8, domain, "attachments.f95zone.to")) {
        return .{ .host = .f95_attachment, .wrapper = .none };
    }
    if (isF95Domain(domain)) {
        // Path case matters for tokens, so slice the original href.
        const after_authority = skipToPath(href);
        if (std.mem.startsWith(u8, after_authority, "/masked/")) {
            const rest = after_authority["/masked/".len..];
            const seg_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            var seg_buf: [128]u8 = undefined;
            if (seg_end > 0 and seg_end <= seg_buf.len) {
                const seg = std.ascii.lowerString(&seg_buf, rest[0..seg_end]);
                return .{ .host = hostFromDomain(seg) orelse .other, .wrapper = .masked };
            }
            return .{ .host = .other, .wrapper = .masked };
        }
        if (std.mem.startsWith(u8, after_authority, "/dl/")) {
            return .{ .host = .f95_wrapped, .wrapper = .dl };
        }
        return .{ .host = .f95_thread, .wrapper = .none };
    }
    if (hostFromDomain(domain)) |h| return .{ .host = h, .wrapper = .none };
    return .{ .host = .other, .wrapper = .none };
}

/// The part of `url` from the first '/' after the authority.
fn skipToPath(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return "";
    const rest = url[scheme_end + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "";
    return rest[slash..];
}

/// Best-effort host from a link's visible text ("MEGA", "PIXELDRAIN"),
/// used for `/dl/` wrappers whose href says nothing about the target.
pub fn hostFromText(text: []const u8) ?Host {
    const names = [_]struct { word: []const u8, host: Host }{
        .{ .word = "mega", .host = .mega },
        .{ .word = "pixeldrain", .host = .pixeldrain },
        .{ .word = "gofile", .host = .gofile },
        .{ .word = "buzzheavier", .host = .buzzheavier },
        .{ .word = "bzzhr", .host = .buzzheavier },
        .{ .word = "datanodes", .host = .datanodes },
        .{ .word = "mixdrop", .host = .mixdrop },
        .{ .word = "vikingfile", .host = .vikingfile },
        .{ .word = "akirabox", .host = .akirabox },
        .{ .word = "workupload", .host = .workupload },
        .{ .word = "nopy", .host = .nopy },
        .{ .word = "mediafire", .host = .mediafire },
        .{ .word = "uploadhaven", .host = .uploadhaven },
        .{ .word = "drive", .host = .google_drive },
    };
    for (names) |n| {
        if (std.ascii.findIgnoreCase(text, n.word) != null) return n.host;
    }
    return null;
}

/// True when `href` is plausibly a download: a known file host (direct or
/// masked), an F95 `/dl/` wrapper, or a non-image F95 attachment.
pub fn looksLikeDownload(href: []const u8) bool {
    const p = parseHref(href);
    if (p.wrapper == .hidden) return true;
    return switch (p.host) {
        .f95_wrapped => true,
        .f95_attachment => !isImageUrl(href),
        else => p.host.isFileHost(),
    };
}

fn isImageUrl(url: []const u8) bool {
    const q = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..q];
    const exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".avif" };
    for (exts) |e| {
        if (path.len >= e.len and std.ascii.eqlIgnoreCase(path[path.len - e.len ..], e)) return true;
    }
    return false;
}

// ------------------------------------------------------------ meaning

pub const Platform = struct {
    windows: bool = false,
    linux: bool = false,
    mac: bool = false,
    android: bool = false,

    pub fn any(self: Platform) bool {
        return self.windows or self.linux or self.mac or self.android;
    }
};

pub const Kind = enum {
    /// The game itself (or no hint that it is anything else).
    game,
    /// Saves, wallpapers, gallery unlocks, walkthroughs, …
    extra,
    /// A mod, cheat, or fan patch.
    mod,
    /// A translation / language pack.
    translation,
};

pub const Entry = struct {
    host: Host,
    wrapper: Wrapper,
    platform: Platform,
    /// 1-based "Part N", when the label says so.
    part: ?u8,
    kind: Kind,
    /// "compressed" / "unofficial" / "remake" style variants.
    variant: bool,
};

/// Longest heading/label line still treated as a label.
const MAX_LABEL_LINE: usize = 48;

fn containsWord(hay: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.ascii.findIgnoreCasePos(hay, from, word)) |at| {
        from = at + 1;
        const before_ok = at == 0 or !std.ascii.isAlphanumeric(hay[at - 1]);
        const end = at + word.len;
        const after_ok = end >= hay.len or !std.ascii.isAlphanumeric(hay[end]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn platformOf(text: []const u8) Platform {
    var p: Platform = .{};
    if (containsWord(text, "win") or containsWord(text, "windows") or containsWord(text, "pc")) p.windows = true;
    if (containsWord(text, "linux")) p.linux = true;
    if (containsWord(text, "mac") or containsWord(text, "macos") or containsWord(text, "osx")) p.mac = true;
    if (containsWord(text, "android") or containsWord(text, "apk")) p.android = true;
    return p;
}

fn partOf(text: []const u8) ?u8 {
    var from: usize = 0;
    while (std.ascii.findIgnoreCasePos(text, from, "part")) |at| {
        from = at + 1;
        if (at > 0 and std.ascii.isAlphanumeric(text[at - 1])) continue;
        var j = at + 4;
        while (j < text.len and (text[j] == ' ' or text[j] == '.' or text[j] == '#')) : (j += 1) {}
        var n: u32 = 0;
        var digits: usize = 0;
        while (j < text.len and std.ascii.isDigit(text[j]) and digits < 3) : (j += 1) {
            n = n * 10 + (text[j] - '0');
            digits += 1;
        }
        if (digits > 0 and n > 0 and n <= 255) return @intCast(n);
    }
    return null;
}

fn kindOf(text: []const u8) Kind {
    const translation = [_][]const u8{ "translation", "language", "lang", "translated" };
    for (translation) |w| if (containsWord(text, w)) return .translation;
    const mods = [_][]const u8{ "mod", "mods", "cheat", "cheats", "patch", "unlocker", "unlock", "gallery" };
    for (mods) |w| if (containsWord(text, w)) return .mod;
    const extras = [_][]const u8{ "extra", "extras", "save", "saves", "wallpaper", "wallpapers", "walkthrough", "soundtrack", "ost", "map", "artbook", "bonus" };
    for (extras) |w| if (containsWord(text, w)) return .extra;
    return .game;
}

fn variantOf(text: []const u8) bool {
    const words = [_][]const u8{ "compressed", "unofficial", "remake", "port", "lite" };
    for (words) |w| if (containsWord(text, w)) return true;
    return false;
}

/// Classify one stored record. `text` is the link text, `lead` the text
/// on its line, `ctx` the '\n'-joined lines above it. The nearest label
/// wins: the link's own line is read before the headings above it.
pub fn classify(href: []const u8, text: []const u8, lead: []const u8, ctx: []const u8) Entry {
    var parsed = parseHref(href);
    if (parsed.host == .f95_wrapped or parsed.wrapper == .hidden) {
        if (hostFromText(text)) |h| parsed.host = h;
    }

    // The link's own text and line are read first, then the headings above
    // it (nearest first). Long lines are prose, not labels, so they are
    // skipped — a sentence mentioning "mod" must not retag every link.
    var plat: Platform = platformOf(text);
    if (!plat.any()) plat = platformOf(lead);
    var part: ?u8 = partOf(lead);
    var kind: Kind = kindOf(lead);
    var variant = variantOf(lead) or variantOf(text);
    if (kind == .game) kind = kindOf(text);

    // Attachments that aren't archives are almost never the game itself.
    if (parsed.host == .f95_attachment and kind == .game and !isArchiveName(href)) kind = .extra;

    var it = std.mem.splitBackwardsScalar(u8, ctx, '\n');
    var steps: usize = 0;
    while (it.next()) |line| : (steps += 1) {
        if (steps >= 4) break;
        if (line.len > MAX_LABEL_LINE) continue;
        // Extras and mods are not tied to the game's platform headings.
        if (!plat.any() and kind == .game) plat = platformOf(line);
        if (part == null) part = partOf(line);
        if (kind == .game) kind = kindOf(line);
        if (!variant) variant = variantOf(line);
    }

    return .{
        .host = parsed.host,
        .wrapper = parsed.wrapper,
        .platform = plat,
        .part = part,
        .kind = kind,
        .variant = variant,
    };
}

fn isArchiveName(url: []const u8) bool {
    const q = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..q];
    const exts = [_][]const u8{ ".zip", ".rar", ".7z", ".tar.gz", ".apk" };
    for (exts) |e| {
        if (path.len >= e.len and std.ascii.eqlIgnoreCase(path[path.len - e.len ..], e)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "parseHref: direct hosts" {
    try testing.expectEqual(Host.buzzheavier, parseHref("https://bzzhr.to/2xhzzuf4cff9").host);
    try testing.expectEqual(Host.datanodes, parseHref("https://datanodes.to/abc/file.zip").host);
    try testing.expectEqual(Host.mixdrop, parseHref("https://mixdrop.ag/f/l77ww6zlaqdv83n").host);
    try testing.expectEqual(Host.vikingfile, parseHref("https://vikingfile.com/f/EEh24AGCuQ").host);
    try testing.expectEqual(Host.akirabox, parseHref("https://phs5.krakencloud.net/force-download/x").host);
    try testing.expectEqual(Host.mega, parseHref("https://MEGA.NZ/file/x#y").host);
    try testing.expectEqual(Wrapper.none, parseHref("https://mega.nz/file/x").wrapper);
}

test "parseHref: masked links carry the real host in the path" {
    const p = parseHref("https://f95zone.to/masked/pixeldrain.com/2689/848344/aaa/bbb/ccc");
    try testing.expectEqual(Host.pixeldrain, p.host);
    try testing.expectEqual(Wrapper.masked, p.wrapper);
    const m = parseHref("https://f95zone.to/masked/mega.nz/2689/848344/x");
    try testing.expectEqual(Host.mega, m.host);
    const unk = parseHref("https://f95zone.to/masked/weirdhost.example/1/2/x");
    try testing.expectEqual(Host.other, unk.host);
    try testing.expectEqual(Wrapper.masked, unk.wrapper);
}

test "parseHref: /dl/ wrapper, attachments, threads, junk" {
    const d = parseHref("https://f95zone.to/dl/8/?u=1&k=2&r=3&t=4");
    try testing.expectEqual(Host.f95_wrapped, d.host);
    try testing.expectEqual(Wrapper.dl, d.wrapper);
    try testing.expectEqual(Host.f95_attachment, parseHref("https://attachments.f95zone.to/2024/01/1_x.zip").host);
    try testing.expectEqual(Host.f95_thread, parseHref("https://f95zone.to/threads/foo.12/post-3").host);
    try testing.expectEqual(Host.f95_thread, parseHref("https://f95zone.com/threads/foo.12/").host);
    try testing.expectEqual(Host.other, parseHref("https://photos.google.com/share/x").host);
    try testing.expectEqual(Host.unknown, parseHref("not a url").host);
    // A look-alike must not be taken for a real host.
    try testing.expectEqual(Host.other, parseHref("https://notmega.nz.evil.example/x").host);
    try testing.expectEqual(Host.other, parseHref("https://evilmega.nz/x").host);
}

test "looksLikeDownload" {
    try testing.expect(looksLikeDownload("https://mega.nz/file/x"));
    try testing.expect(looksLikeDownload("https://f95zone.to/masked/gofile.io/1/2/x"));
    try testing.expect(looksLikeDownload("https://f95zone.to/dl/8/?u=1"));
    try testing.expect(looksLikeDownload("https://attachments.f95zone.to/2024/01/1_save.zip"));
    try testing.expect(!looksLikeDownload("https://attachments.f95zone.to/2024/01/1_shot.PNG"));
    try testing.expect(!looksLikeDownload("https://f95zone.to/threads/foo.12/"));
    try testing.expect(!looksLikeDownload("https://patreon.com/dev"));
}

test "hostFromText hints for wrapped links" {
    try testing.expectEqual(@as(?Host, .pixeldrain), hostFromText("PIXELDRAIN"));
    try testing.expectEqual(@as(?Host, .mega), hostFromText("mega mirror"));
    try testing.expectEqual(@as(?Host, null), hostFromText("click here"));
    const e = classify("https://f95zone.to/dl/8/?u=1", "GOFILE", "Win:", "");
    try testing.expectEqual(Host.gofile, e.host);
    try testing.expectEqual(Wrapper.dl, e.wrapper);
}

test "classify: platform, part and kind from lead and headings" {
    const e = classify("https://mega.nz/x", "MEGA", "Win/Linux:", "Chapter 3 (Beta)");
    try testing.expect(e.platform.windows and e.platform.linux and !e.platform.mac);
    try testing.expectEqual(Kind.game, e.kind);

    const p = classify("https://mega.nz/x", "MEGA", "", "Win\nPart 3");
    try testing.expect(p.platform.windows);
    try testing.expectEqual(@as(?u8, 3), p.part);

    const x = classify("https://mega.nz/x", "Sandbox Save", "", "Extras");
    try testing.expectEqual(Kind.extra, x.kind);

    const t = classify("https://f95zone.to/threads/x.1/", "Italian Translation", "", "Extras");
    try testing.expectEqual(Kind.translation, t.kind);

    const g = classify("https://f95zone.to/threads/x.1/", "Gallery Mod", "", "Extras");
    try testing.expectEqual(Kind.mod, g.kind);
}

test "classify: nearest label wins; words must be whole" {
    // The link's own line says Mac; the heading above says Win.
    const e = classify("https://mega.nz/x", "MEGA", "Mac:", "Win");
    try testing.expect(e.platform.mac and !e.platform.windows);
    // "window" / "machine" / "partial" are not platforms or parts.
    const n = classify("https://mega.nz/x", "MEGA", "window machine partial", "");
    try testing.expect(!n.platform.any());
    try testing.expectEqual(@as(?u8, null), n.part);
}

test "classify: compressed and unofficial are variants; archives stay game" {
    const c = classify("https://pixeldrain.com/u/x", "PIXELDRAIN", "Compressed:", "Win");
    try testing.expect(c.variant);
    const s = classify("https://attachments.f95zone.to/2024/01/1_save.dat", "", "", "Extras");
    try testing.expectEqual(Kind.extra, s.kind);
    const a = classify("https://attachments.f95zone.to/2024/01/1_game.zip", "", "", "");
    try testing.expectEqual(Kind.game, a.kind);
}

test "classify: hidden host uses the link text; prose context is ignored" {
    const h = classify("https://********B09NMqwa/Game.rar", "NOPY", "Win:", "");
    try testing.expectEqual(Host.nopy, h.host);
    try testing.expectEqual(Wrapper.hidden, h.wrapper);
    try testing.expect(looksLikeDownload("https://********B09NMqwa/Game.rar"));

    const prose = "*This unofficial mod/version is not released by the developer. Download at your own risk";
    const e = classify("https://attachments.f95zone.to/2024/01/1_x.zip", "", "", prose);
    try testing.expect(!e.variant);
    try testing.expectEqual(Kind.game, e.kind);
}

test "classify: link text names the platform; extras do not inherit it" {
    const a = classify("https://f95zone.to/threads/x.1/", "ANDROID", "Other:", "Win(Split):");
    try testing.expect(a.platform.android and !a.platform.windows);
    const x = classify("https://mega.nz/x", "Wallpapers", "Extras:", "Win(Split):");
    try testing.expect(!x.platform.any());
}
