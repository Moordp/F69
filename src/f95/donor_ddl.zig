// F95 donor DDL — Tier 1 download flow. Confirmed against
// F95Checker's `modules/api.py::ddl_file_list` + `::ddl_file_link`
// (upstream WillyJL/F95Checker, 2026-05-13 snapshot).
//
// `/sam/dddl.php?raw=1` is a TWO-step JSON protocol, not a single
// "give me a URL" call:
//
//   Step 1 — file list:
//     POST /sam/dddl.php?raw=1
//     body: thread_id=<id>
//     ok:   {"status":"ok","msg":{
//             "files": { "<Section>": [<FileEntry>, …], … },
//             "session": "<opaque session token>"
//           }}
//     err:  {"status":"error","msg":"<reason string>"}
//
//   Step 2 — file link:
//     POST /sam/dddl.php?raw=1
//     body: thread_id=<id>&file=<file_id>&session=<session>
//     ok:   {"status":"ok","msg":{
//             "url":    "https://attachments.f95zone.to/.../<file>",
//             "cookie": { "<name>": "<value>", … }
//           }}
//
// The cookie object on step 2 carries the per-download auth cookies
// the CDN expects on the GET — without sending them back as a
// `Cookie:` header, the URL 403s. We flatten the dict into a
// `name=value; name=value` string suitable for aria2's `--header`.
//
// First-cut auto-pick policy: walk every section in iteration order
// and return the first file with a non-empty file_id. F95 often
// groups by platform ("Windows", "Mac", "Linux", "Android") — the
// first section is almost always the one you want, but a future UI
// picker should let the user choose explicitly.

const std = @import("std");
const log = std.log.scoped(.f95_donor);
const errs = @import("errors.zig");
const Client = @import("client.zig").Client;

pub const ENDPOINT_URL = "https://f95zone.to/sam/dddl.php?raw=1";

/// One downloadable file inside a section. All slices borrow from the
/// underlying parsed JSON arena; copy them out before the arena dies.
pub const FileEntry = struct {
    file_id: []const u8,
    filename: []const u8,
    section: []const u8,
};

/// Final outcome of the two-step dance: a ready-to-pass-to-aria2 URL
/// plus the cookie value the CDN needs on the GET. Both alloc-owned.
pub const Download = struct {
    url: []u8,
    /// Flat `name=value; name=value` string. Alloc-owned, may be
    /// empty when F95's step-2 response carried no cookies (rare).
    cookie: []u8,
    /// Filename hint scraped from the file entry — useful for
    /// logging and for the post-install path to label the install.
    filename: []u8,
};

pub fn freeDownload(alloc: std.mem.Allocator, d: Download) void {
    alloc.free(d.url);
    alloc.free(d.cookie);
    alloc.free(d.filename);
}

/// Step-1-only probe to learn whether the logged-in F95 account has
/// donor eligibility for DDL. Useful at startup so the UI can gray
/// out the Download button before the user clicks it. Returns
/// `true` on a normal step-1 success (msg is an object with files
/// or notes), `false` on `DonorNotEligible`, and propagates other
/// errors (network, malformed response, etc.) — caller can treat
/// those as "unknown" rather than as a firm "not a donor".
///
/// Picks an arbitrary thread id; the API doesn't care which thread
/// is asked, only whether the caller has donor status. Any thread
/// that exists works — we use the F95Zone announcement thread (id
/// `1`) which is guaranteed-stable.
pub fn checkDonorStatus(
    alloc: std.mem.Allocator,
    client: *Client,
) errs.Error!bool {
    const probe_tid: u64 = 1;
    var step1_buf: [64]u8 = undefined;
    const step1_body = std.fmt.bufPrint(&step1_buf, "thread_id={d}", .{probe_tid}) catch
        return errs.Error.DonorInvalidResponse;
    log.info("donor probe: POST file-list thread_id={d}", .{probe_tid});
    const raw = client.postForm(ENDPOINT_URL, step1_body) catch |e| return e;
    defer alloc.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{
        .ignore_unknown_fields = true,
    }) catch return errs.Error.DonorInvalidResponse;
    defer parsed.deinit();
    _ = unwrapStatusMsg(parsed.value) catch |e| switch (e) {
        errs.Error.DonorNotEligible => return false,
        errs.Error.DonorNoDdl, errs.Error.NotFound => {
            // The probe thread happens not to have DDLs, OR the
            // thread id we picked is gone. Both mean the donor
            // check didn't return DonorNotEligible, so the user IS
            // a donor — they just can't download THIS thread.
            return true;
        },
        else => return e,
    };
    return true;
}

/// Two-step happy path: list → auto-pick → link. Returns the URL +
/// cookie ready for `Command.enqueue_url`. Errors carry the same
/// taxonomy as before (`AuthRequired` / `DonorNotEligible` / etc.).
pub fn requestDownload(
    alloc: std.mem.Allocator,
    client: *Client,
    thread_id: u64,
) errs.Error!Download {
    // ----- step 1: file list -----
    var step1_buf: [64]u8 = undefined;
    const step1_body = std.fmt.bufPrint(&step1_buf, "thread_id={d}", .{thread_id}) catch
        return errs.Error.DonorInvalidResponse;

    log.info("donor DDL step 1: POST file-list thread_id={d}", .{thread_id});
    const raw1 = try client.postForm(ENDPOINT_URL, step1_body);
    defer alloc.free(raw1);
    log.info(
        "donor DDL step 1 response: {d} bytes (head: '{s}')",
        .{ raw1.len, raw1[0..@min(raw1.len, 120)] },
    );

    var parsed1 = std.json.parseFromSlice(std.json.Value, alloc, raw1, .{
        .ignore_unknown_fields = true,
    }) catch |e| {
        log.warn("donor DDL step 1: JSON parse failed ({s}); body head: '{s}'", .{
            @errorName(e),
            raw1[0..@min(raw1.len, 200)],
        });
        return errs.Error.DonorInvalidResponse;
    };
    defer parsed1.deinit();

    const msg1 = unwrapStatusMsg(parsed1.value) catch |e| return e;
    if (msg1 != .object) {
        log.warn("donor DDL step 1: msg is not an object (got {s})", .{@tagName(msg1)});
        return errs.Error.DonorInvalidResponse;
    }

    // Pull the session token + files map.
    const session_v = msg1.object.get("session") orelse return errs.Error.DonorInvalidResponse;
    if (session_v != .string) return errs.Error.DonorInvalidResponse;
    const session = session_v.string;

    const files_v = msg1.object.get("files") orelse return errs.Error.DonorInvalidResponse;
    if (files_v != .object) return errs.Error.DonorInvalidResponse;

    const picked = pickFirstFile(files_v.object) orelse {
        log.warn("donor DDL step 1: no downloadable file in {d} section(s)", .{files_v.object.count()});
        return errs.Error.DonorNoDdl;
    };
    log.info(
        "donor DDL step 1 OK: tid={d}, session-len={d}, picked '{s}/{s}' (file_id={s})",
        .{ thread_id, session.len, picked.section, picked.filename, picked.file_id },
    );

    // ----- step 2: file link -----
    // file_id and session should be URL-safe (hex / base64-ish), but
    // we URL-encode defensively just in case F95 sneaks a `&` in.
    var step2_body: std.ArrayList(u8) = .empty;
    defer step2_body.deinit(alloc);
    step2_body.appendSlice(alloc, "thread_id=") catch return errs.Error.OutOfMemory;
    var tid_buf: [32]u8 = undefined;
    const tid_str = std.fmt.bufPrint(&tid_buf, "{d}", .{thread_id}) catch return errs.Error.DonorInvalidResponse;
    step2_body.appendSlice(alloc, tid_str) catch return errs.Error.OutOfMemory;
    step2_body.appendSlice(alloc, "&file=") catch return errs.Error.OutOfMemory;
    appendUrlEncoded(&step2_body, alloc, picked.file_id) catch return errs.Error.OutOfMemory;
    step2_body.appendSlice(alloc, "&session=") catch return errs.Error.OutOfMemory;
    appendUrlEncoded(&step2_body, alloc, session) catch return errs.Error.OutOfMemory;

    log.info("donor DDL step 2: POST file-link (body={d} bytes)", .{step2_body.items.len});
    const raw2 = try client.postForm(ENDPOINT_URL, step2_body.items);
    defer alloc.free(raw2);
    log.info(
        "donor DDL step 2 response: {d} bytes (head: '{s}')",
        .{ raw2.len, raw2[0..@min(raw2.len, 120)] },
    );

    var parsed2 = std.json.parseFromSlice(std.json.Value, alloc, raw2, .{
        .ignore_unknown_fields = true,
    }) catch |e| {
        log.warn("donor DDL step 2: JSON parse failed ({s}); body head: '{s}'", .{
            @errorName(e),
            raw2[0..@min(raw2.len, 200)],
        });
        return errs.Error.DonorInvalidResponse;
    };
    defer parsed2.deinit();

    const msg2 = unwrapStatusMsg(parsed2.value) catch |e| return e;
    if (msg2 != .object) return errs.Error.DonorInvalidResponse;

    const url_v = msg2.object.get("url") orelse return errs.Error.DonorInvalidResponse;
    if (url_v != .string) return errs.Error.DonorInvalidResponse;
    const url = url_v.string;

    // The "cookie" field is normally an object {name: value}. Some
    // F95 responses send a plain string ("name=value; name=value")
    // — accept both shapes.
    var cookie_buf: std.ArrayList(u8) = .empty;
    defer cookie_buf.deinit(alloc);
    if (msg2.object.get("cookie")) |c| switch (c) {
        .object => |o| {
            var it = o.iterator();
            var first = true;
            while (it.next()) |entry| {
                const v = entry.value_ptr.*;
                const val_str: []const u8 = switch (v) {
                    .string, .number_string => |s| s,
                    else => continue,
                };
                if (!first) cookie_buf.appendSlice(alloc, "; ") catch return errs.Error.OutOfMemory;
                first = false;
                cookie_buf.appendSlice(alloc, entry.key_ptr.*) catch return errs.Error.OutOfMemory;
                cookie_buf.append(alloc, '=') catch return errs.Error.OutOfMemory;
                cookie_buf.appendSlice(alloc, val_str) catch return errs.Error.OutOfMemory;
            }
        },
        .string => |s| cookie_buf.appendSlice(alloc, s) catch return errs.Error.OutOfMemory,
        else => {},
    };

    const url_owned = alloc.dupe(u8, url) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(url_owned);
    const cookie_owned = cookie_buf.toOwnedSlice(alloc) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(cookie_owned);
    const filename_owned = alloc.dupe(u8, picked.filename) catch return errs.Error.OutOfMemory;

    log.info(
        "donor DDL step 2 OK: tid={d} url-len={d} cookie-len={d} filename='{s}'",
        .{ thread_id, url_owned.len, cookie_owned.len, filename_owned },
    );

    return .{
        .url = url_owned,
        .cookie = cookie_owned,
        .filename = filename_owned,
    };
}

/// Unwrap the `{"status":"ok|error","msg":…}` envelope into the
/// `msg` value. Maps known error messages to specific error codes;
/// anything else returns `DonorInvalidResponse`.
fn unwrapStatusMsg(root: std.json.Value) errs.Error!std.json.Value {
    if (root != .object) return errs.Error.DonorInvalidResponse;
    const status_v = root.object.get("status") orelse return errs.Error.DonorInvalidResponse;
    const msg_v = root.object.get("msg") orelse return errs.Error.DonorInvalidResponse;
    if (status_v != .string) return errs.Error.DonorInvalidResponse;
    const status = status_v.string;
    if (std.mem.eql(u8, status, "ok")) return msg_v;

    // Error path — `msg` is a human-readable string. Map known
    // values onto our typed errors.
    if (msg_v == .string) {
        const m = msg_v.string;
        log.warn("donor DDL: server reported error '{s}'", .{m});
        if (asciiContainsIgnoreCase(m, "not logged in")) return errs.Error.AuthRequired;
        if (asciiContainsIgnoreCase(m, "not a donor")) return errs.Error.DonorNotEligible;
        if (asciiContainsIgnoreCase(m, "not enough credit")) return errs.Error.DonorNotEligible;
        if (asciiContainsIgnoreCase(m, "donor")) return errs.Error.DonorNotEligible;
        if (asciiContainsIgnoreCase(m, "ddl not available")) return errs.Error.DonorNoDdl;
        if (asciiContainsIgnoreCase(m, "no ddl")) return errs.Error.DonorNoDdl;
        if (asciiContainsIgnoreCase(m, "thread not found")) return errs.Error.NotFound;
    } else {
        log.warn("donor DDL: error msg was non-string", .{});
    }
    return errs.Error.DonorInvalidResponse;
}

/// Walk `files` and return the first entry with a non-empty
/// `file_id`. F95's shape (confirmed from F95Checker's
/// `modules/api.py::ddl_file_list`) is:
///
///   "files": {
///     "<Section Name>": {
///       "<Display Title 1>": {"file_id":"…","filename":"…","size":…,"date":"…","hash":"…"},
///       "<Display Title 2>": "<some-plain-string>",   // notes / sub-headings
///       …
///     },
///     "<Other Section>": { … }
///   }
///
/// Both `files[section]` and the title-keyed value are OBJECTS, not
/// arrays. Strings as values are sub-headings / notes (no file_id) —
/// skip them.
fn pickFirstFile(files: std.json.ObjectMap) ?FileEntry {
    var section_it = files.iterator();
    while (section_it.next()) |section_kv| {
        const section_name = section_kv.key_ptr.*;
        const section_value = section_kv.value_ptr.*;
        if (section_value != .object) continue;
        var inner_it = section_value.object.iterator();
        while (inner_it.next()) |inner_kv| {
            const entry = inner_kv.value_ptr.*;
            if (entry != .object) continue; // string → sub-heading, no file
            const obj = entry.object;
            const file_id_v = obj.get("file_id") orelse continue;
            if (file_id_v != .string) continue;
            if (file_id_v.string.len == 0) continue;
            // filename can be in `filename` OR fall back to the title
            // key (rare edge case).
            const filename: []const u8 = blk: {
                if (obj.get("filename")) |fn_v| {
                    if (fn_v == .string and fn_v.string.len > 0) break :blk fn_v.string;
                }
                break :blk inner_kv.key_ptr.*;
            };
            return .{
                .file_id = file_id_v.string,
                .filename = filename,
                .section = section_name,
            };
        }
    }
    return null;
}

fn appendUrlEncoded(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    value: []const u8,
) !void {
    for (value) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try buf.append(alloc, c),
            else => {
                var hex: [3]u8 = undefined;
                _ = std.fmt.bufPrint(&hex, "%{X:0>2}", .{c}) catch unreachable;
                try buf.appendSlice(alloc, &hex);
            },
        }
    }
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (haystack[i .. i + needle.len], needle) |a, b| {
            if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

// ============================================================
//  tests
// ============================================================

test "asciiContainsIgnoreCase: basics" {
    try std.testing.expect(asciiContainsIgnoreCase("Not Logged In", "not logged in"));
    try std.testing.expect(asciiContainsIgnoreCase("Donor required", "donor"));
    try std.testing.expect(!asciiContainsIgnoreCase("Not Logged In", "logged out"));
    try std.testing.expect(asciiContainsIgnoreCase("anything", ""));
    try std.testing.expect(!asciiContainsIgnoreCase("x", "xx"));
}

test "pickFirstFile: picks first non-empty file_id across sections" {
    // Real F95 shape: section value is a {title → entry} object, not
    // an array. Entries that are plain strings are notes / sub-
    // headings (no file_id).
    const json_text =
        \\{
        \\  "Header Section": {
        \\    "About": "Just a heading, no actual file."
        \\  },
        \\  "Windows": {
        \\    "Main build": {"file_id":"abc123","filename":"Game-Win.zip","size":12345,"date":"2026-01-01","hash":"deadbeef"},
        \\    "Patch": {"file_id":"abc456","filename":"Game-Win-Patch.zip","size":500}
        \\  },
        \\  "Mac": {
        \\    "Main build": {"file_id":"def456","filename":"Game-Mac.zip","size":12340}
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const picked = pickFirstFile(parsed.value.object).?;
    try std.testing.expectEqualStrings("abc123", picked.file_id);
    try std.testing.expectEqualStrings("Game-Win.zip", picked.filename);
    try std.testing.expectEqualStrings("Windows", picked.section);
}

test "pickFirstFile: returns null when only notes are present" {
    const json_text =
        \\{
        \\  "Notes": {
        \\    "Heading 1": "A description",
        \\    "Heading 2": "Another note"
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expect(pickFirstFile(parsed.value.object) == null);
}

test "pickFirstFile: filename falls back to title key when filename field is missing" {
    const json_text =
        \\{
        \\  "Windows": {
        \\    "Game-1.0.zip": {"file_id":"abc","size":100}
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const picked = pickFirstFile(parsed.value.object).?;
    try std.testing.expectEqualStrings("abc", picked.file_id);
    try std.testing.expectEqualStrings("Game-1.0.zip", picked.filename);
}
