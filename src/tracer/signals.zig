//! Cooperative termination-signal handling plus the atomic pid bookkeeping
//! used to sweep the whole target tree from an async-signal-safe handler.

const std = @import("std");
const builtin = @import("builtin");
const process_ops = @import("process_ops.zig");

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
var stop_requested: std.atomic.Value(bool) = .init(false);

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

/// Disables signal-handler teardown for the completed target group.
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
            process_ops.safeKill(pid, sig);
            process_ops.safeKill(-pid, sig);
        }
    }
}

/// Sends SIGTERM to the target tree (armed pgid + every tracked tgid/group).
pub fn termTargetTree(pgid: std.posix.pid_t) void {
    if (pgid > 1) {
        process_ops.safeKill(-pgid, .TERM);
        process_ops.safeKill(pgid, .TERM);
    }
    killTracked(.TERM);
}

/// Follow-up SIGKILL sweep; pair with `termTargetTree`.
pub fn killTargetTree(pgid: std.posix.pid_t) void {
    if (pgid > 1) {
        process_ops.safeKill(-pgid, .KILL);
        process_ops.safeKill(pgid, .KILL);
    }
    killTracked(.KILL);
}

/// True if `pid` still exists (running or zombie). EPERM means it exists but
/// we cannot signal it; ESRCH means it is gone.
pub fn pidAlive(pid: std.posix.pid_t) bool {
    return process_ops.pidAlive(pid);
}

/// TERM, short grace, then KILL. Safe for the termination-signal handler.
/// Hits the root process group **and** every remembered tgid/group, because
/// ninja's compile/link jobs live in their own process groups.
pub fn terminateTargetGroup(pgid: std.posix.pid_t) void {
    termTargetTree(pgid);
    // Test teardown must be deterministic and must not add a wall-clock delay.
    if (comptime !builtin.is_test) process_ops.sleepTerminationGrace();
    killTargetTree(pgid);
}

fn terminateLiveTargets() void {
    terminateTargetGroup(live_target_pgid.load(.acquire));
}

fn claimStopRequest() bool {
    return stop_requested.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
}

/// Returns whether a termination signal requested an orderly stop.
pub fn stopRequested() bool {
    return stop_requested.load(.acquire);
}

fn abortFromSignal(sig: std.posix.SIG) noreturn {
    // The cooperative stop is already in progress. Restore the default
    // disposition and re-raise so another signal remains an escape hatch.
    var dfl = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &dfl, null);
    process_ops.safeKill(process_ops.currentPid(), sig);
    @panic("termination signal did not terminate the process");
}

fn handleTerminationSignal(sig: std.posix.SIG) callconv(.c) void {
    if (claimStopRequest()) {
        terminateLiveTargets();
        return;
    }

    abortFromSignal(sig);
}

/// Installs cooperative handlers for termination signals and ignores SIGPIPE.
/// The first signal requests an orderly stop and sweeps the target tree; a
/// second signal restores default fatal behavior. Idempotent; a no-op on
/// non-POSIX targets.
pub fn installFatalSignalHandlers() void {
    if (comptime builtin.os.tag == .windows) return;

    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleTerminationSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    inline for (.{
        std.posix.SIG.INT,
        .TERM,
        .HUP,
        .QUIT,
    }) |sig| {
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

test "termination signal handlers install idempotently" {
    const testing = std.testing;
    const termination_signals = [_]std.posix.SIG{
        .INT,
        .TERM,
        .HUP,
        .QUIT,
    };
    var previous_actions: [termination_signals.len]std.posix.Sigaction = undefined;
    for (termination_signals, &previous_actions) |sig, *previous| {
        std.posix.sigaction(sig, null, previous);
    }
    var previous_pipe: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, null, &previous_pipe);
    defer {
        for (termination_signals, &previous_actions) |sig, *previous| {
            std.posix.sigaction(sig, previous, null);
        }
        std.posix.sigaction(.PIPE, &previous_pipe, null);
    }

    installFatalSignalHandlers();
    installFatalSignalHandlers();

    for (termination_signals) |sig| {
        var action: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &action);
        try testing.expectEqual(
            @intFromPtr(&handleTerminationSignal),
            @intFromPtr(action.handler.handler.?),
        );
    }
    var pipe_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, null, &pipe_action);
    try testing.expectEqual(
        @intFromPtr(std.posix.SIG.IGN.?),
        @intFromPtr(pipe_action.handler.handler.?),
    );
}

test "only one simultaneous signal claims the cooperative stop" {
    stop_requested.store(false, .release);
    defer stop_requested.store(false, .release);

    var winners: std.atomic.Value(usize) = .init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, countClaim, .{&winners});
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 1), winners.load(.acquire));
    try std.testing.expect(stopRequested());
}

fn countClaim(winners: *std.atomic.Value(usize)) void {
    if (claimStopRequest()) _ = winners.fetchAdd(1, .acq_rel);
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
