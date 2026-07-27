// F95Service — public use cases. All hits to f95zone.to go through here
// so the rate limit is centrally enforced.

const std = @import("std");
const errs = @import("errors.zig");
const domain = @import("domain.zig");
const Client = @import("client.zig").Client;
const thread = @import("thread.zig");
const bookmarks = @import("bookmarks.zig");
const auth = @import("auth.zig");

pub const Service = struct {
    alloc: std.mem.Allocator,
    client: *Client,

    pub fn init(alloc: std.mem.Allocator, client: *Client) Service {
        return .{ .alloc = alloc, .client = client };
    }

    pub fn scrapeThread(self: *Service, url: []const u8) errs.Error!domain.ScrapedThread {
        return thread.scrape(self.client, self.alloc, url);
    }

    pub fn fetchBookmarks(self: *Service, progress: bookmarks.Progress) errs.Error![]domain.BookmarkEntry {
        return bookmarks.fetchAll(self.client, self.alloc, progress);
    }

    pub fn login(self: *Service, io: std.Io, creds: auth.Credentials) errs.Error!auth.LoginResult {
        // `auth.login` calls `client.setCookie` on the `.ok` variant; `.two_step`
        // returns challenge cookies for `submitTwoStep`.
        return auth.login(self.client, self.alloc, io, creds);
    }

    /// Complete a two-step (TOTP) challenge started by `login`. Returns the
    /// authenticated cookie (applied to the client) for the caller to persist.
    pub fn submitTwoStep(self: *Service, io: std.Io, carry_cookies: []const u8, code: []const u8) errs.Error![]u8 {
        return auth.submitTwoStep(self.client, self.alloc, io, carry_cookies, code);
    }

    /// Sign in with a session cookie the user copied from their browser (the
    /// 2FA / passkey workaround). Verifies + applies it; returns the owned
    /// cookie for the caller to persist. See `auth.loginWithCookie`.
    pub fn loginWithCookie(self: *Service, io: std.Io, xf_user: []const u8, xf_session: []const u8) errs.Error![]u8 {
        return auth.loginWithCookie(self.client, self.alloc, io, xf_user, xf_session);
    }
};
