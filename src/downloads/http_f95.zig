//! `resolve.Http` backed by the app's F95 client. The resolver runs on
//! downloader worker threads; `f95.Client` already serializes its HTTP and
//! guards its cookie, so this adapter only converts types and errors.
//!
//! Cookie rule: the F95 session goes only to f95zone.to hosts
//! (`Client.getScoped`, `Client.postFormWith`). The `Cookie:` header for
//! attachments is formatted into a per-thread buffer, so two resolve
//! workers never write over each other's copy; the resolver dupes it at
//! once. Nothing here logs a header.

const std = @import("std");
const f95 = @import("f95");
const resolve = @import("resolve.zig");
const errs = @import("errors.zig");

/// `cookieHeader` result storage, one per thread (see the file comment).
threadlocal var cookie_buf: [1024]u8 = undefined;

pub const F95Http = struct {
    client: *f95.Client,

    pub fn http(self: *F95Http) resolve.Http {
        return .{ .ctx = self, .get = get, .postForm = postForm, .cookieHeader = cookieHeader };
    }

    fn cast(ctx: *anyopaque) *F95Http {
        return @ptrCast(@alignCast(ctx));
    }

    fn get(ctx: *anyopaque, alloc: std.mem.Allocator, url: []const u8) errs.Error![]u8 {
        const c = cast(ctx).client;
        const body = c.getScoped(url) catch |e| return mapErr(e);
        defer c.alloc.free(body);
        return alloc.dupe(u8, body) catch errs.Error.OutOfMemory;
    }

    fn postForm(ctx: *anyopaque, alloc: std.mem.Allocator, url: []const u8, body: []const u8, extra_headers: []const []const u8) errs.Error!resolve.Http.Reply {
        const c = cast(ctx).client;
        const reply = c.postFormWith(url, body, extra_headers) catch |e| return mapErr(e);
        defer c.alloc.free(reply.body);
        return .{ .status = reply.status, .body = alloc.dupe(u8, reply.body) catch return errs.Error.OutOfMemory };
    }

    fn cookieHeader(ctx: *anyopaque) ?[]const u8 {
        return cast(ctx).client.cookieHeader(&cookie_buf);
    }
};

fn mapErr(e: f95.errors.Error) errs.Error {
    return switch (e) {
        error.AuthRequired => errs.Error.AuthRequired,
        error.NotFound => errs.Error.NotFound,
        error.OutOfMemory => errs.Error.OutOfMemory,
        else => errs.Error.NetworkError,
    };
}
