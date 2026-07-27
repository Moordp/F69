// F95 + RPDL login / logout — synchronous on the UI thread (~1-2s
// for the GET-token + POST-creds dance). Phase 6+ will move these
// onto worker threads with the same atomic-flag pattern as
// `syncGame`. Cookies / tokens are persisted to disk on success so
// the next launch picks them up without a re-login.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.ui_actions);
const f95 = @import("f95");
const downloads = @import("downloads");
const types = @import("../types.zig");
const owned_types = @import("../owned.zig");
const job_mod = @import("../job.zig");
const launch_act = @import("launch.zig");

const Frame = types.Frame;
const State = types.State;

// ============================================================
//  F95 login / logout
// ============================================================

/// Synchronous login from the UI thread. Blocks for ~1-2s while the
/// GET-token + POST-creds dance runs. Phase 6+ moves this onto a
/// worker thread with the same atomic-flag pattern as `syncGame`.
///
/// Persists the cookie to `frame.info.cookie_path` on success so the
/// next launch comes up authenticated.
pub fn doLogin(frame: *Frame, username: []const u8, password: []const u8) void {
    const state = frame.state;
    if (username.len == 0 or password.len == 0) {
        state.login_status = .err;
        state.setLoginMsg("username and password required");
        return;
    }
    log.info("doLogin start (user='{s}')", .{username});
    state.login_status = .logging_in;
    state.setLoginMsg("contacting F95Zone…");

    const cookie = frame.f95_svc.login(frame.io, .{
        .username = username,
        .password = password,
    }) catch |e| {
        state.login_status = .err;
        const friendly: []const u8 = switch (e) {
            // Bad password AND a 2FA/passkey challenge both collapse to
            // AuthRequired here (F95 just withholds xf_user). Point users at
            // the cookie workaround, which is the only thing that clears a
            // passkey.
            error.AuthRequired => "wrong password, or your account uses 2FA/passkey — try \"Sign in with cookie\"",
            error.NetworkError => "network error — check connection",
            error.HttpStatusError => "F95Zone returned an unexpected status",
            else => @errorName(e),
        };
        var emsg: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "login failed: {s}", .{friendly}) catch "login failed";
        state.setLoginMsg(m);
        return;
    };
    defer frame.lib.alloc.free(cookie);

    persistCookie(frame.io, frame.info.cookie_path, cookie) catch |e| {
        std.log.scoped(.ui).warn("could not persist cookie: {s}", .{@errorName(e)});
    };

    // Wipe the password buffer so it doesn't linger in State.
    @memset(&state.f95_pass_buf, 0);
    state.login_status = .logged_in;
    state.setLoginMsg("logged in");
    // Login popup self-dismisses on successful auth so the user goes
    // straight back to the library; donor-status probe runs fresh so
    // the Download button reflects current eligibility.
    state.login_popup_open = false;
    state.is_donor = null;
    checkDonorStatus(frame);
}

/// Sign in with a session cookie the user copied from their browser — the
/// only path that works for a 2FA / passkey-protected account (password login
/// can't answer the challenge; see doLogin). Verifies the cookie against F95
/// before accepting, then persists it exactly like a password login.
pub fn doLoginWithCookie(frame: *Frame, xf_user: []const u8, xf_session: []const u8) void {
    const state = frame.state;
    if (xf_user.len == 0) {
        state.login_status = .err;
        state.setLoginMsg("paste your xf_user cookie value");
        return;
    }
    log.info("doLoginWithCookie start (xf_user len={d}, xf_session len={d})", .{ xf_user.len, xf_session.len });
    state.login_status = .logging_in;
    state.setLoginMsg("verifying cookie…");

    const cookie = frame.f95_svc.loginWithCookie(frame.io, xf_user, xf_session) catch |e| {
        state.login_status = .err;
        const friendly: []const u8 = switch (e) {
            error.AuthRequired => "that cookie didn't work — copy a fresh xf_user + xf_session from your browser",
            error.NetworkError => "network error — check connection",
            else => @errorName(e),
        };
        var emsg: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "cookie sign-in failed: {s}", .{friendly}) catch "cookie sign-in failed";
        state.setLoginMsg(m);
        return;
    };
    defer frame.lib.alloc.free(cookie);

    persistCookie(frame.io, frame.info.cookie_path, cookie) catch |e| {
        std.log.scoped(.ui).warn("could not persist cookie: {s}", .{@errorName(e)});
    };

    // Wipe the pasted cookie values — they're a live session token.
    @memset(&state.f95_cookie_user_buf, 0);
    @memset(&state.f95_cookie_session_buf, 0);
    state.login_status = .logged_in;
    state.setLoginMsg("logged in (cookie)");
    state.login_popup_open = false;
    state.is_donor = null;
    checkDonorStatus(frame);
}

/// Open the F95Zone login page in the user's real browser so they can log in
/// (passkey / 2FA works natively there) and then copy their cookie back.
pub fn doOpenF95Login(frame: *Frame) void {
    launch_act.spawnXdgOpen(frame.lib.alloc, frame.io, "https://f95zone.to/login/") catch |e| {
        frame.state.setLoginMsg("couldn't open browser — go to f95zone.to/login");
        std.log.scoped(.ui).warn("open F95 login failed: {s}", .{@errorName(e)});
    };
}

// ============================================================
//  donor-status probe
// ============================================================
//
// Hits F95's donor DDL step-1 endpoint with a known-stable thread to
// learn whether the current login has donor eligibility. The UI uses
// the result to gate the Download button: non-donors see it grayed.
//
// Off-UI HTTP probe via a `DonorProbeJob`. The probe takes 1–2 s for
// the GET-token + scrape dance — running it on the UI thread froze
// the first post-login frame. Worker version: spawn detached, drain
// next frame; UI thread stays responsive throughout.

fn donorProbeWorker(job: *owned_types.DonorProbeJob) void {
    const p = &job.payload;
    const is_donor = f95.donor_ddl.checkDonorStatus(job.alloc, p.client) catch |e| {
        p.err_name = @errorName(e);
        job.markFailed();
        return;
    };
    p.is_donor = is_donor;
    job.markDone();
}

fn onDonorProbeDone(state: *State, job: *owned_types.DonorProbeJob) void {
    if (job.payload.is_donor) |v| state.is_donor = v;
    state.donor_check_in_flight = false;
    state.donor_check_attempted = true;
    log.info("donor probe: is_donor={?}", .{state.is_donor});
}

fn onDonorProbeFailed(state: *State, job: *owned_types.DonorProbeJob) void {
    log.warn("donor probe failed: {s} — leaving is_donor unset", .{job.payload.err_name orelse "?"});
    state.donor_check_in_flight = false;
    state.donor_check_attempted = true;
}

/// Reap any completed donor-probe job and write its outcome into
/// State. Called once per frame from `guiFrame`. Safe to call when
/// the slot is null or the job is still pending — `drainBackgroundJob`
/// short-circuits.
pub fn drainDonorProbe(frame: *Frame) void {
    job_mod.drainBackgroundJob(
        owned_types.DonorProbePayload,
        onDonorProbeDone,
        onDonorProbeFailed,
        frame.state,
        &frame.state.donor_probe_job,
    );
}

pub fn checkDonorStatus(frame: *Frame) void {
    const state = frame.state;
    if (state.donor_check_in_flight) return;
    if (state.donor_probe_job != null) return;
    if (!frame.f95_svc.client.hasCookie()) {
        // No cookie = not logged in; can't probe. Leave is_donor null.
        return;
    }
    state.donor_check_in_flight = true;
    _ = job_mod.spawnJob(
        owned_types.DonorProbePayload,
        donorProbeWorker,
        frame.lib.alloc,
        frame.win,
        .{ .client = frame.f95_svc.client },
        &state.donor_probe_job,
    ) catch |e| {
        // Spawn failure (alloc / thread create) — record as
        // attempted so we don't churn re-firing every frame.
        log.warn("donor probe spawn failed: {s}", .{@errorName(e)});
        state.donor_check_in_flight = false;
        state.donor_check_attempted = true;
    };
}

pub fn doLogout(frame: *Frame) void {
    const state = frame.state;
    // Wipe in-memory cookie on the f95 client via the lock-protected
    // helper. Workers snapshot the cookie under cookie_lock; doing the
    // clear via that helper closes the UAF window where a worker
    // could read a freed slice if logout ran between snapshot dup
    // and snapshot use. Also frees with the client's own allocator
    // rather than lib.alloc (currently the same gpa, but no longer
    // a load-bearing assumption).
    frame.f95_svc.client.clearCookie();
    // Best-effort delete the on-disk cookie.
    std.Io.Dir.cwd().deleteFile(frame.io, frame.info.cookie_path) catch {};
    @memset(&state.f95_user_buf, 0);
    @memset(&state.f95_pass_buf, 0);
    state.login_status = .logged_out;
    state.is_donor = null;
    state.donor_check_attempted = false;
    state.setLoginMsg("logged out");
}

// ============================================================
//  RPDL login — mirrors doLogin / doLogout but for dl.rpdl.net
// ============================================================

pub fn doRpdlLogin(frame: *Frame, username: []const u8, password: []const u8) void {
    const state = frame.state;
    if (username.len == 0 or password.len == 0) {
        state.rpdl_status = .err;
        state.setRpdlMsg("username and password required");
        return;
    }
    log.info("doRpdlLogin start (user='{s}')", .{username});
    state.rpdl_status = .logging_in;
    state.setRpdlMsg("contacting RPDL…");

    const token = downloads.rpdl.login(frame.lib.alloc, frame.io, username, password) catch |e| {
        state.rpdl_status = .err;
        const friendly: []const u8 = switch (e) {
            error.AuthRequired => "incorrect username or password",
            error.NetworkError => "network error — check connection",
            else => @errorName(e),
        };
        var emsg: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "login failed: {s}", .{friendly}) catch "login failed";
        state.setRpdlMsg(m);
        return;
    };

    persistRpdlToken(frame.io, frame.info.rpdl_token_path, token) catch |e| {
        std.log.scoped(.ui).warn("could not persist rpdl token: {s}", .{@errorName(e)});
    };

    // Drop any prior token + take ownership of the new one.
    if (state.rpdl_token) |old| frame.lib.alloc.free(old);
    state.rpdl_token = token;

    @memset(&state.rpdl_pass_buf, 0);
    state.rpdl_status = .logged_in;
    state.setRpdlMsg("logged in");
}

pub fn doRpdlLogout(frame: *Frame) void {
    const state = frame.state;
    if (state.rpdl_token) |old| {
        frame.lib.alloc.free(old);
        state.rpdl_token = null;
    }
    std.Io.Dir.cwd().deleteFile(frame.io, frame.info.rpdl_token_path) catch {};
    @memset(&state.rpdl_user_buf, 0);
    @memset(&state.rpdl_pass_buf, 0);
    state.rpdl_status = .logged_out;
    state.setRpdlMsg("logged out");
}

fn persistRpdlToken(io: std.Io, path: []const u8, token: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    var tmp_buf: [1024]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    var tmp = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
    defer tmp.close(io);
    // 0600 is a POSIX file-mode nicety for the token file; not applicable on Windows.
    if (builtin.os.tag != .windows) try tmp.setPermissions(io, std.Io.File.Permissions.fromMode(0o600));
    var fw_buf: [4096]u8 = undefined;
    var fw = tmp.writer(io, &fw_buf);
    try fw.interface.writeAll(token);
    try fw.interface.flush();
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

/// Atomically write the cookie to disk with mode 0600. Tmp+rename
/// keeps a half-written file from confusing the next startup.
fn persistCookie(io: std.Io, path: []const u8, cookie: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    var tmp_buf: [512]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    var f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
    defer f.close(io);
    // 0600 — POSIX file mode; Windows uses default ACLs.
    if (builtin.os.tag != .windows) try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o600));
    var fw_buf: [1024]u8 = undefined;
    var fw = f.writer(io, &fw_buf);
    try fw.interface.writeAll(cookie);
    try fw.interface.flush();
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}
