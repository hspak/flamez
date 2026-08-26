//! Process-group teardown policy: fatal-signal handlers plus the atomic pid
//! bookkeeping that lets flamez kill the whole target tree (ninja's
//! posix_spawn'd jobs live in groups of their own) from an async-signal-safe
//! handler.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.signals);

/// Arms the escape hatch for `pid`'s process group.
pub fn armTargetGroup(pid: std.posix.pid_t) void {
    live_target_pgid.store(pid, .release);
}

/// Current armed target pgid, or 0 when disarmed. Signal-handler read path.
pub fn armedTargetPgid() std.posix.pid_t {
    return live_target_pgid.load(.acquire);
}

// Process group of the live target root: armed at spawn, disarmed when the
// root is reaped (or the session is stopped). Read from the fatal-signal
// handler, so access stays atomic.
//
// Ninja (and similar tools) then posix_spawn compile/link jobs with
// POSIX_SPAWN_SETPGROUP, so those jobs are **not** in this group. Killing
// only `-pgid` leaves the linker running. `tracked_pids` is the signal-safe
// list of every tgid we have seen, so teardown can kill those extra groups.
var live_target_pgid: std.atomic.Value(std.posix.pid_t) = .init(0);

pub const TrackedSlot = u16;
// Same cap as the kernel `tracked_pids` map so Stop/Ctrl+C can signal
// every tgid the collector could have admitted.
const max_tracked_pids = 65536;
comptime {
    std.debug.assert(max_tracked_pids - 1 <= std.math.maxInt(TrackedSlot));
}
var tracked_pids: [max_tracked_pids]std.atomic.Value(std.posix.pid_t) =
    [_]std.atomic.Value(std.posix.pid_t){.init(0)} ** max_tracked_pids;
var next_tracked_slot: usize = 0;

/// Disables fatal-signal teardown for the completed target group.
pub fn disarmTargetGroup() void {
    live_target_pgid.store(0, .release);
}

/// Clears every remembered process id after capture or teardown completes.
pub fn clearTrackedPids() void {
    for (&tracked_pids) |*slot| slot.store(0, .monotonic);
    next_tracked_slot = 0;
}

/// Adds `pid` to the fixed signal-safe teardown set and returns its slot.
pub fn rememberPid(pid: std.posix.pid_t) ?TrackedSlot {
    if (pid <= 1) return null;
    for (0..tracked_pids.len) |offset| {
        const index = (next_tracked_slot + offset) % tracked_pids.len;
        const slot = &tracked_pids[index];
        if (slot.load(.monotonic) == 0 and
            slot.cmpxchgWeak(0, pid, .monotonic, .monotonic) == null)
        {
            next_tracked_slot = (index + 1) % tracked_pids.len;
            return @intCast(index);
        }
    }
    return null;
}

/// Clears the exact slot returned by `rememberPid`.
pub fn forgetPid(slot_index: ?TrackedSlot, pid: std.posix.pid_t) void {
    const index = slot_index orelse return;
    if (pid <= 1 or index >= tracked_pids.len) return;
    const slot = &tracked_pids[index];
    _ = slot.cmpxchgStrong(pid, 0, .monotonic, .monotonic);
    next_tracked_slot = @min(next_tracked_slot, index);
}

fn killTracked(sig: std.posix.SIG) void {
    for (&tracked_pids) |*slot| {
        const pid = slot.load(.monotonic);
        if (pid > 1) {
            safeKill(pid, sig);
            safeKill(-pid, sig);
        }
    }
}

/// Sends SIGTERM to the target tree (armed pgid + every tracked tgid/group).
pub fn termTargetTree(pgid: std.posix.pid_t) void {
    if (pgid > 1) {
        safeKill(-pgid, .TERM);
        safeKill(pgid, .TERM);
    }
    killTracked(.TERM);
}

/// Follow-up SIGKILL sweep; pair with `termTargetTree`.
pub fn killTargetTree(pgid: std.posix.pid_t) void {
    if (pgid > 1) {
        safeKill(-pgid, .KILL);
        safeKill(pgid, .KILL);
    }
    killTracked(.KILL);
}

// Best-effort kill(2). Tolerates ESRCH (target already gone) and EPERM
// instead of tripping std.posix.kill's unreachable paths: a group that fully
// exited between two frames is normal, not a programmer bug.
fn safeKill(pid: std.posix.pid_t, sig: std.posix.SIG) void {
    _ = std.os.linux.kill(pid, sig);
}

/// True if `pid` still exists (running or zombie). EPERM means it exists but
/// we cannot signal it; ESRCH means it is gone.
pub fn pidAlive(pid: std.posix.pid_t) bool {
    if (pid <= 1) return false;
    const rc = std.os.linux.kill(pid, @enumFromInt(0));
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS, .PERM => true,
        .SRCH => false,
        .INVAL => unreachable,
        else => unreachable,
    };
}

/// TERM, short grace, then KILL. Async-signal-safe: used from handleFatalSignal.
/// Hits the root process group **and** every remembered tgid/group, because
/// ninja's compile/link jobs live in their own process groups.
pub fn terminateTargetGroup(pgid: std.posix.pid_t) void {
    if (pgid > 1) {
        safeKill(-pgid, .TERM);
        safeKill(pgid, .TERM);
    }
    killTracked(.TERM);
    var req: std.os.linux.timespec = .{ .sec = 0, .nsec = 120 * std.time.ns_per_ms };
    var rest: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    while (true) {
        const rc = std.os.linux.nanosleep(&req, &rest);
        if (rc != @intFromEnum(std.os.linux.E.INTR)) break;
        req = rest;
    }
    if (pgid > 1) {
        safeKill(-pgid, .KILL);
        safeKill(pgid, .KILL);
    }
    killTracked(.KILL);
}

fn terminateLiveTargets() void {
    terminateTargetGroup(live_target_pgid.load(.acquire));
}

fn handleFatalSignal(sig: std.posix.SIG) callconv(.c) void {
    terminateLiveTargets();

    // Restore the default disposition and re-raise so flamez dies from the
    // signal it received, exactly as it would have without handlers installed.
    var dfl = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &dfl, null);
    safeKill(std.os.linux.getpid(), sig);
    @panic("fatal signal did not terminate the process");
}

/// Installs handlers for the terminal-generated and job-control signals that
/// would otherwise kill flamez instantly and orphan the whole target process
/// group (the target deliberately lives in its own process group, so Ctrl+C
/// reaches flamez alone). Idempotent; a no-op on non-POSIX targets.
pub fn installFatalSignalHandlers() void {
    if (comptime builtin.os.tag == .windows) return;

    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleFatalSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    inline for (.{ std.posix.SIG.INT, .TERM, .HUP, .QUIT }) |sig| {
        std.posix.sigaction(sig, &act, null);
    }
    // A closed pty must not turn a stray stdout write into instant death.
    const ign = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &ign, null);
}

test "fatal signal handlers install idempotently" {
    installFatalSignalHandlers();
    installFatalSignalHandlers();
}

test "tracked pid slots are released without a table scan" {
    clearTrackedPids();
    defer clearTrackedPids();

    const first = rememberPid(20_001).?;
    const second = rememberPid(20_002).?;
    try std.testing.expect(first != second);
    forgetPid(first, 20_001);
    try std.testing.expectEqual(first, rememberPid(20_003).?);
    // A stale owner cannot clear a slot that has already been reused.
    forgetPid(first, 20_001);
    try std.testing.expectEqual(
        @as(std.posix.pid_t, 20_003),
        tracked_pids[first].load(.monotonic),
    );
}
