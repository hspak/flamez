//! macOS process operations. Lifecycle metadata remains collector-owned;
//! libproc supplies best-effort names and executable paths.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Result of a nonblocking wait on the target root.
pub const WaitNowait = union(enum) {
    still_running,
    interrupted,
    no_child,
    reaped: u32,
};

extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffer_size: u32) c_int;
extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffer_size: u32) c_int;

/// Returns the calling process's PID.
pub fn currentPid() std.posix.pid_t {
    return std.c.getpid();
}

/// Observes `pid` without blocking and preserves interruption as a normal result.
pub fn waitNowait(pid: std.posix.pid_t) WaitNowait {
    var status: c_int = 0;
    const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    switch (std.c.errno(rc)) {
        .SUCCESS => {
            if (rc == 0) return .still_running;
            return .{ .reaped = @bitCast(status) };
        },
        .INTR => return .interrupted,
        .CHILD => return .no_child,
        .INVAL => unreachable,
        else => unreachable,
    }
}

/// Returns the normal exit code encoded by `status`, or null otherwise.
pub fn exitCode(status: u32) ?u8 {
    return if (std.c.W.IFEXITED(status)) std.c.W.EXITSTATUS(status) else null;
}

/// Returns the terminating signal encoded by `status`, or null otherwise.
pub fn exitSignal(status: u32) ?u8 {
    if (!std.c.W.IFSIGNALED(status)) return null;
    return @intCast(@intFromEnum(std.c.W.TERMSIG(status)));
}

/// Reads a best-effort process name into `buffer`; the result aliases `buffer`.
pub fn readName(pid: std.posix.pid_t, buffer: []u8) ?[]const u8 {
    if (buffer.len == 0 or buffer.len > std.math.maxInt(u32)) return null;
    const amount = proc_name(pid, buffer.ptr, @intCast(buffer.len));
    return if (amount > 0) buffer[0..@intCast(amount)] else null;
}

/// Returns null until a macOS argv provider is implemented.
pub fn readArgs(_: Allocator, _: std.posix.pid_t) Allocator.Error!?std.ArrayList(u8) {
    return null;
}

/// Reads a best-effort executable path into `buffer`; the result aliases `buffer`.
pub fn readExecutable(pid: std.posix.pid_t, buffer: []u8) ?[]const u8 {
    if (buffer.len == 0 or buffer.len > std.math.maxInt(u32)) return null;
    const amount = proc_pidpath(pid, buffer.ptr, @intCast(buffer.len));
    return if (amount > 0) buffer[0..@intCast(amount)] else null;
}

/// Returns null until a macOS working-directory provider is implemented.
pub fn readCwd(_: std.posix.pid_t, _: []u8) ?[]const u8 {
    return null;
}

/// Sends `sig` on a best-effort basis; an already exited target is harmless.
pub fn safeKill(pid: std.posix.pid_t, sig: std.posix.SIG) void {
    _ = std.c.kill(pid, sig);
}

/// Returns whether `pid` exists; EPERM still means the process exists.
pub fn pidAlive(pid: std.posix.pid_t) bool {
    if (pid <= 1) return false;
    const rc = std.c.kill(pid, @enumFromInt(0));
    return switch (std.c.errno(rc)) {
        .SUCCESS, .PERM => true,
        .SRCH => false,
        .INVAL => unreachable,
        else => unreachable,
    };
}

/// Sleeps for the fixed TERM grace period, retrying an interrupted nanosleep.
pub fn sleepTerminationGrace() void {
    var req: std.c.timespec = .{ .sec = 0, .nsec = 120 * std.time.ns_per_ms };
    var rest: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    while (true) {
        const rc = std.c.nanosleep(&req, &rest);
        if (std.c.errno(rc) != .INTR) return;
        req = rest;
    }
}
