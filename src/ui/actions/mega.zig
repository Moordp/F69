// MEGA account (Settings → Accounts → MEGA card). Every MEGAcmd call
// (`whoami`, `login`, `logout`) blocks on a child process, so each one
// runs on a `MegaAuthJob` worker and `drainMegaAuth` applies the result
// on the UI thread. The password is copied into the job once; the
// worker zeroes and frees that copy right after `login` returns, and
// the State buffers are zeroed after every attempt. Nothing here logs
// the password, the code or the argv.

const std = @import("std");
const log = std.log.scoped(.ui_actions);
const downloads = @import("downloads");
const types = @import("../types.zig");
const owned = @import("../owned.zig");
const job_mod = @import("../job.zig");

const Frame = types.Frame;
const State = types.State;
const LoginResult = downloads.engine_megacmd.LoginResult;
const MegaStatus = @import("../state.zig").MegaStatus;

pub const msg_needs_code = "Enter the code from your authenticator app";
pub const msg_bad_credentials = "Sign-in failed \u{2014} check the email and password";

/// Replace `state.mega_account` with a copy of `account` (null clears it).
/// The old value is freed here, so this is the only writer.
fn setMegaAccount(state: *State, alloc: std.mem.Allocator, account: ?[]const u8) void {
    if (state.mega_account) |old| alloc.free(old);
    state.mega_account = null;
    if (account) |a| state.mega_account = alloc.dupe(u8, a) catch null;
}

/// Free the heap part of the MEGA card state. Shutdown / harness deinit.
pub fn freeMegaState(state: *State, alloc: std.mem.Allocator) void {
    setMegaAccount(state, alloc, null);
}

fn wipeBuffers(state: *State) void {
    std.crypto.secureZero(u8, &state.mega_pass_buf);
    std.crypto.secureZero(u8, &state.mega_code_buf);
}

/// Map a `login` outcome (plus the `whoami` e-mail that followed a
/// successful login) onto the card state. Always zeroes the password and
/// code buffers. Pure apart from `alloc` (the account copy).
pub fn applyLoginResult(state: *State, alloc: std.mem.Allocator, result: LoginResult, account: ?[]const u8) void {
    wipeBuffers(state);
    switch (result) {
        .ok, .already_logged_in => {
            setMegaAccount(state, alloc, account);
            state.mega_status = .signed_in;
            state.mega_msg.clear();
        },
        .needs_auth_code => {
            state.mega_status = .needs_code;
            state.mega_msg.write(msg_needs_code);
        },
        .bad_credentials => {
            state.mega_status = .failed;
            state.mega_msg.write(msg_bad_credentials);
        },
        .not_installed => {
            setMegaAccount(state, alloc, null);
            state.mega_status = .not_installed;
            state.mega_msg.clear();
        },
    }
}

// ---------------------------------------------------------------- worker

fn freeSecret(alloc: std.mem.Allocator, s: *?[]u8) void {
    if (s.*) |v| {
        std.crypto.secureZero(u8, v);
        alloc.free(v);
        s.* = null;
    }
}

/// Zero + free the sign-in inputs. Called by the worker after `login`, or
/// by the caller when the worker never started.
fn freeInputs(alloc: std.mem.Allocator, p: *owned.MegaAuthPayload) void {
    freeSecret(alloc, &p.password);
    freeSecret(alloc, &p.code);
    if (p.email) |e| alloc.free(e);
    p.email = null;
}

fn megaAuthWorker(job: *owned.MegaAuthJob) void {
    const p = &job.payload;
    switch (p.op) {
        .check => p.account = p.engine.whoami(job.alloc),
        .sign_in => {
            const r = p.engine.login(job.alloc, p.email orelse "", p.password orelse "", p.code);
            freeInputs(job.alloc, p);
            const res = r catch {
                job.markFailed();
                return;
            };
            p.login_result = res;
            if (res == .ok or res == .already_logged_in) p.account = p.engine.whoami(job.alloc);
        },
        .sign_out => p.engine.logout(),
    }
    job.markDone();
}

fn onMegaDone(state: *State, job: *owned.MegaAuthJob) void {
    const p = &job.payload;
    // `job.alloc` is `lib.alloc` (spawn passes it), the same allocator
    // `mega_account` uses.
    defer if (p.account) |a| job.alloc.free(a);
    switch (p.op) {
        .check => {
            if (p.account) |a| {
                setMegaAccount(state, job.alloc, a);
                state.mega_status = .signed_in;
            } else {
                state.mega_status = .signed_out;
            }
            state.mega_msg.clear();
        },
        .sign_in => applyLoginResult(state, job.alloc, p.login_result orelse .bad_credentials, p.account),
        .sign_out => {
            setMegaAccount(state, job.alloc, null);
            state.mega_status = .signed_out;
            state.mega_msg.write("Signed out");
        },
    }
    log.info("mega {s}: status={s}", .{ @tagName(p.op), @tagName(state.mega_status) });
}

fn onMegaFailed(state: *State, job: *owned.MegaAuthJob) void {
    // Only sign_in can fail (login's OutOfMemory).
    if (job.payload.account) |a| job.alloc.free(a);
    wipeBuffers(state);
    state.mega_status = .failed;
    state.mega_msg.write("Sign-in failed \u{2014} out of memory");
}

/// Reap a finished MEGA worker and apply its result. Once per frame.
pub fn drainMegaAuth(frame: *Frame) void {
    job_mod.drainBackgroundJob(owned.MegaAuthPayload, onMegaDone, onMegaFailed, frame.state, &frame.state.pending_mega_job);
}

fn spawn(frame: *Frame, payload: owned.MegaAuthPayload) bool {
    _ = job_mod.spawnJob(owned.MegaAuthPayload, megaAuthWorker, frame.lib.alloc, frame.win, payload, &frame.state.pending_mega_job) catch |e| {
        log.warn("mega worker spawn failed: {s}", .{@errorName(e)});
        return false;
    };
    return true;
}

/// Startup status check: `whoami` on a worker → signed_in / signed_out.
/// No engine → not_installed at once.
pub fn megaCheckStatus(frame: *Frame) void {
    const state = frame.state;
    const engine = frame.mega orelse {
        state.mega_status = .not_installed;
        return;
    };
    if (state.pending_mega_job != null) return;
    state.mega_status = .unknown;
    if (!spawn(frame, .{ .engine = engine, .op = .check })) {
        state.mega_status = .signed_out;
        state.mega_msg.write("Couldn't check the MEGA sign-in");
    }
}

/// Sign in with the card's e-mail, password and (when filled in) code.
pub fn megaSignIn(frame: *Frame) void {
    const state = frame.state;
    const alloc = frame.lib.alloc;
    const engine = frame.mega orelse {
        applyLoginResult(state, alloc, .not_installed, null);
        return;
    };
    if (state.pending_mega_job != null) return;
    const email = std.mem.trim(u8, state.megaEmailSlice(), " \t\r\n");
    const pass = state.megaPassSlice();
    if (email.len == 0 or pass.len == 0) {
        state.mega_status = .failed;
        state.mega_msg.write("Enter your MEGA email and password");
        return;
    }
    const code = std.mem.trim(u8, state.megaCodeSlice(), " \t\r\n");

    var payload: owned.MegaAuthPayload = .{ .engine = engine, .op = .sign_in };
    var ok = false;
    defer if (!ok) {
        freeInputs(alloc, &payload);
        wipeBuffers(state);
        state.mega_status = .failed;
        state.mega_msg.write("Sign-in failed \u{2014} out of memory");
    };
    payload.email = alloc.dupe(u8, email) catch return;
    payload.password = alloc.dupe(u8, pass) catch return;
    if (code.len > 0) payload.code = alloc.dupe(u8, code) catch return;
    if (!spawn(frame, payload)) return;
    ok = true;
    // The worker owns the only copy now.
    wipeBuffers(state);
    state.mega_status = .busy;
    state.mega_msg.write("Signing in\u{2026}");
}

/// Sign out on a worker → signed_out.
pub fn megaSignOut(frame: *Frame) void {
    const state = frame.state;
    const engine = frame.mega orelse return;
    if (state.pending_mega_job != null) return;
    if (!spawn(frame, .{ .engine = engine, .op = .sign_out })) {
        state.mega_msg.write("Couldn't start sign-out");
        return;
    }
    state.mega_status = .busy;
    state.mega_msg.write("Signing out\u{2026}");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testState() !*State {
    const s = try testing.allocator.create(State);
    s.* = .{};
    return s;
}

fn fillSecrets(s: *State) void {
    @memcpy(s.mega_pass_buf[0..6], "secret");
    @memcpy(s.mega_code_buf[0..6], "123456");
}

fn expectWiped(s: *const State) !void {
    for (s.mega_pass_buf) |b| try testing.expectEqual(@as(u8, 0), b);
    for (s.mega_code_buf) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "applyLoginResult: ok and already_logged_in sign in with the whoami account" {
    const a = testing.allocator;
    const s = try testState();
    defer a.destroy(s);
    defer freeMegaState(s, a);

    fillSecrets(s);
    applyLoginResult(s, a, .ok, "me@example.com");
    try testing.expectEqual(MegaStatus.signed_in, s.mega_status);
    try testing.expectEqualStrings("me@example.com", s.mega_account.?);
    try expectWiped(s);

    // A second success replaces (and frees) the old account copy.
    fillSecrets(s);
    applyLoginResult(s, a, .already_logged_in, "other@example.com");
    try testing.expectEqual(MegaStatus.signed_in, s.mega_status);
    try testing.expectEqualStrings("other@example.com", s.mega_account.?);
    try expectWiped(s);
}

test "applyLoginResult: needs_auth_code, bad_credentials, not_installed" {
    const a = testing.allocator;
    const s = try testState();
    defer a.destroy(s);
    defer freeMegaState(s, a);

    fillSecrets(s);
    applyLoginResult(s, a, .needs_auth_code, null);
    try testing.expectEqual(MegaStatus.needs_code, s.mega_status);
    try testing.expectEqualStrings(msg_needs_code, s.mega_msg.read());
    try expectWiped(s);

    fillSecrets(s);
    applyLoginResult(s, a, .bad_credentials, null);
    try testing.expectEqual(MegaStatus.failed, s.mega_status);
    try testing.expectEqualStrings(msg_bad_credentials, s.mega_msg.read());
    try expectWiped(s);

    // not_installed also drops a stale account.
    applyLoginResult(s, a, .ok, "me@example.com");
    fillSecrets(s);
    applyLoginResult(s, a, .not_installed, null);
    try testing.expectEqual(MegaStatus.not_installed, s.mega_status);
    try testing.expect(s.mega_account == null);
    try expectWiped(s);
}
