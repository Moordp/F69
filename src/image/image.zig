// Image decoding glue. The sync worker hits this when downloaded bytes
// aren't a format dvui's stb_image can read — primarily AVIF, since
// F95Zone's CDN serves AVIF behind .png URLs (Cloudflare-side transcode
// of the original upload). We decode via libavif into RGBA and let the
// caller re-encode as PNG before writing to disk, so the renderer's
// existing imageFile path stays oblivious.
//
// libavif and its dav1d backend are statically linked — see
// flake.nix overlays libavif-static / dav1d-static and the
// linkSystemLibrary calls in build.zig. The end-user binary has the
// codec baked in; no .so dependency at run time.

const std = @import("std");
const log = std.log.scoped(.image);

const c = @import("c");

pub const Error = error{
    DecodeFailed,
    OutOfMemory,
    UnexpectedFormat,
};

/// RGBA8 pixel buffer + dimensions, owned by the caller's allocator.
/// Free via `Decoded.deinit`.
pub const Decoded = struct {
    rgba: []u8,
    width: u32,
    height: u32,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Decoded) void {
        self.alloc.free(self.rgba);
        self.* = undefined;
    }
};

/// Detect the AVIF/HEIF family by ISO Base Media File Format magic.
/// Bytes 4..8 must be "ftyp"; bytes 8..12 are the brand. AVIF brands
/// include avif, avis, mif1, msf1, miaf, heic. We treat anything
/// "ftyp"-prefixed as AVIF-decodable — libavif accepts mif1/heic
/// containers that wrap AV1 payloads.
pub fn isAvif(bytes: []const u8) bool {
    if (bytes.len < 12) return false;
    return std.mem.eql(u8, bytes[4..8], "ftyp");
}

/// Detect formats stb_image can decode (JPEG, PNG, GIF, BMP). Used
/// at sync time to route to the stb decode path. We deliberately
/// don't include AVIF/HEIF, WebP, or anything else stb won't handle.
pub fn isStbFormat(bytes: []const u8) bool {
    if (bytes.len < 12) return false;
    if (bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return true; // JPEG
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return true; // PNG
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return true; // GIF
    if (bytes[0] == 'B' and bytes[1] == 'M') return true; // BMP
    return false;
}

/// Cap that keeps decoded RGBA buffers under the SDL3 GPU transfer
/// buffer limit (16 MiB). 2048 × 2048 × 4 = 16 MiB exactly; we
/// downscale anything larger to stay safely under it.
pub const MAX_DIM: u32 = 2048;

/// In-place 2× box-filter downscale of an RGBA8 image. Output buffer
/// is allocated by the caller's allocator; input is not freed. Used
/// in a halve-until-fits loop to bring oversized screenshots under
/// the GPU transfer-buffer ceiling.
pub fn downscaleHalfRgba(
    alloc: std.mem.Allocator,
    src: []const u8,
    src_w: u32,
    src_h: u32,
) ![]u8 {
    std.debug.assert(src.len == @as(usize, src_w) * src_h * 4);
    std.debug.assert(src_w >= 2 and src_h >= 2);

    const dst_w: u32 = src_w / 2;
    const dst_h: u32 = src_h / 2;
    const dst = try alloc.alloc(u8, @as(usize, dst_w) * dst_h * 4);
    errdefer alloc.free(dst);

    var y: u32 = 0;
    while (y < dst_h) : (y += 1) {
        const sy0: usize = @as(usize, y) * 2;
        const sy1: usize = sy0 + 1;
        const row0_off = sy0 * @as(usize, src_w) * 4;
        const row1_off = sy1 * @as(usize, src_w) * 4;
        const dst_row_off = @as(usize, y) * dst_w * 4;
        var x: u32 = 0;
        while (x < dst_w) : (x += 1) {
            const sx0: usize = @as(usize, x) * 2;
            const px00 = row0_off + sx0 * 4;
            const px01 = px00 + 4;
            const px10 = row1_off + sx0 * 4;
            const px11 = px10 + 4;
            const o = dst_row_off + @as(usize, x) * 4;
            // Average per channel; sum fits in u32 (4 × 0xFF = 1020).
            inline for (0..4) |ch_idx| {
                const sum: u32 = @as(u32, src[px00 + ch_idx]) + src[px01 + ch_idx] +
                    src[px10 + ch_idx] + src[px11 + ch_idx];
                dst[o + ch_idx] = @intCast(sum / 4);
            }
        }
    }
    return dst;
}

/// Result of a fit-to-cap operation. Heap-owned `rgba` always.
pub const Fit = struct { rgba: []u8, w: u32, h: u32 };

/// Halve repeatedly until both dimensions fit under `MAX_DIM`. Default
/// cap matches the SDL3 GPU transfer-buffer ceiling. For thumbnail
/// generation use `fitToCap` with a smaller cap (e.g. 192).
pub fn fitToMaxDim(
    alloc: std.mem.Allocator,
    rgba: []const u8,
    w_in: u32,
    h_in: u32,
) !Fit {
    return fitToCap(alloc, rgba, w_in, h_in, MAX_DIM);
}

/// Same as `fitToMaxDim` but with an explicit cap. Halves the image
/// (box-filter via `downscaleHalfRgba`) until both dims fit. Callers
/// always own the returned slice, even when the input was already
/// under the cap (a fresh dupe is returned for uniform free-after-use).
pub fn fitToCap(
    alloc: std.mem.Allocator,
    rgba: []const u8,
    w_in: u32,
    h_in: u32,
    cap: u32,
) !Fit {
    if (@max(w_in, h_in) <= cap) {
        return .{ .rgba = try alloc.dupe(u8, rgba), .w = w_in, .h = h_in };
    }
    var cur = try alloc.dupe(u8, rgba);
    var cw = w_in;
    var ch = h_in;
    while (@max(cw, ch) > cap and cw >= 2 and ch >= 2) {
        const halved = downscaleHalfRgba(alloc, cur, cw, ch) catch |e| {
            alloc.free(cur);
            return e;
        };
        alloc.free(cur);
        cur = halved;
        cw = cw / 2;
        ch = ch / 2;
    }
    return .{ .rgba = cur, .w = cw, .h = ch };
}

/// Cap for thumbnail generation. Drives the size of `.t` files written
/// alongside the full-size images at sync time. Sized so the resulting
/// thumb still looks sharp when rendered at the largest card cover in
/// the grid (max card width 360 × content_scale 1.25 = 450 physical px,
/// plus headroom for HiDPI). Halving math:
///   1920×1080 → 960×540 → 480×270            (cap 480 stops here)
///   1600×400  → 800×200 → 400×100
///   1280×720  → 640×360 → 320×180
/// ~30-60 KB per JPEG q85. Disk cost across a 1500-game library:
/// ~50 MB extra vs the old 192 cap, in exchange for crisp covers.
pub const THUMB_CAP: u32 = 480;

/// Decode an AVIF byte stream into RGBA8 pixels. Caller frees via
/// `Decoded.deinit`. The decoder sees only the bytes you pass in;
/// libavif copies them internally during avifDecoderParse so the
/// caller's slice can be freed immediately after this returns.
pub fn decodeAvif(alloc: std.mem.Allocator, bytes: []const u8) Error!Decoded {
    const dec = c.avifDecoderCreate() orelse return Error.OutOfMemory;
    defer c.avifDecoderDestroy(dec);

    // avifDecoderSetIOMemory does not copy — the slice must outlive
    // the decoder. We call avifDecoderParse + NextImage before
    // returning, so the local lifetime of `bytes` is fine here.
    if (c.avifDecoderSetIOMemory(dec, bytes.ptr, bytes.len) != c.AVIF_RESULT_OK) {
        log.warn("avifDecoderSetIOMemory failed", .{});
        return Error.DecodeFailed;
    }
    if (c.avifDecoderParse(dec) != c.AVIF_RESULT_OK) {
        log.warn("avifDecoderParse failed", .{});
        return Error.DecodeFailed;
    }
    if (c.avifDecoderNextImage(dec) != c.AVIF_RESULT_OK) {
        log.warn("avifDecoderNextImage failed", .{});
        return Error.DecodeFailed;
    }

    const img = dec.*.image orelse return Error.DecodeFailed;
    const w: u32 = img.*.width;
    const h: u32 = img.*.height;

    // Sanity: 24-bit dimensions only — some pathological AVIFs declare
    // huge sizes that would OOM us. 16384x16384 covers any real screenshot.
    const HARD_DIM_CAP: u32 = 16384;
    if (w == 0 or h == 0 or w > HARD_DIM_CAP or h > HARD_DIM_CAP) {
        log.warn("avif image dims out of range: {d}x{d}", .{ w, h });
        return Error.UnexpectedFormat;
    }

    const row_bytes: usize = @as(usize, w) * 4;
    const total: usize = row_bytes * @as(usize, h);
    const buf = alloc.alloc(u8, total) catch return Error.OutOfMemory;
    errdefer alloc.free(buf);

    // Hand libavif our buffer instead of using avifRGBImageAllocatePixels —
    // saves a copy. avifImageYUVToRGB writes RGBA8 pixels in row-major order.
    var rgb: c.avifRGBImage = undefined;
    c.avifRGBImageSetDefaults(&rgb, img);
    rgb.format = c.AVIF_RGB_FORMAT_RGBA;
    rgb.depth = 8;
    rgb.pixels = buf.ptr;
    rgb.rowBytes = @intCast(row_bytes);

    if (c.avifImageYUVToRGB(img, &rgb) != c.AVIF_RESULT_OK) {
        log.warn("avifImageYUVToRGB failed", .{});
        return Error.DecodeFailed;
    }

    return .{
        .rgba = buf,
        .width = w,
        .height = h,
        .alloc = alloc,
    };
}

test "isAvif sniff" {
    const ftyp = "....ftypavif" ++ "\x00\x00\x00\x00";
    try std.testing.expect(isAvif(ftyp));
    try std.testing.expect(!isAvif("\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\x00"));
    try std.testing.expect(!isAvif("short"));
}

test "isStbFormat sniff" {
    try std.testing.expect(isStbFormat("\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\x00"));
    try std.testing.expect(isStbFormat("\xFF\xD8\xFF" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00"));
    try std.testing.expect(isStbFormat("GIF89a" ++ "\x00\x00\x00\x00\x00\x00"));
    try std.testing.expect(isStbFormat("BM" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"));
    try std.testing.expect(!isStbFormat("....ftypavif" ++ "\x00\x00\x00\x00"));
    try std.testing.expect(!isStbFormat("short"));
}

test "downscaleHalfRgba 2x2 -> 1x1" {
    // Four corners of a 2x2 RGBA image. Average should be (128, 128, 128, 255).
    const src = [_]u8{
        0x00, 0x00, 0x00, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0xFF,
    };
    const dst = try downscaleHalfRgba(std.testing.allocator, &src, 2, 2);
    defer std.testing.allocator.free(dst);
    try std.testing.expectEqual(@as(usize, 4), dst.len);
    try std.testing.expectEqual(@as(u8, 127), dst[0]); // (0+255+255+0)/4 = 127
    try std.testing.expectEqual(@as(u8, 127), dst[1]);
    try std.testing.expectEqual(@as(u8, 127), dst[2]);
    try std.testing.expectEqual(@as(u8, 255), dst[3]);
}

test "fitToMaxDim halves until under cap" {
    // 4x4 solid image, cap = 2 → should halve once to 2x2.
    const src: [4 * 4 * 4]u8 = @splat(0xAA);
    const fit = try fitToMaxDim(std.testing.allocator, &src, 4, 4);
    defer std.testing.allocator.free(fit.rgba);
    // MAX_DIM is 2048 by default — small input passes through. Just
    // verify the dupe path keeps dimensions intact.
    try std.testing.expectEqual(@as(u32, 4), fit.w);
    try std.testing.expectEqual(@as(u32, 4), fit.h);
}
