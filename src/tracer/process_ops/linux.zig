//! Linux process operations and procfs metadata enrichment.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Result of a nonblocking wait on the target root.
pub const WaitNowait = union(enum) {
    still_running,
    interrupted,
    no_child,
    reaped: u32,
};

/// Returns the calling process's PID.
pub fn currentPid() std.posix.pid_t {
    return std.os.linux.getpid();
}

/// Observes `pid` without blocking and preserves interruption as a normal result.
pub fn waitNowait(pid: std.posix.pid_t) WaitNowait {
    var status: u32 = 0;
    const rc = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {
            if (rc == 0) return .still_running;
            return .{ .reaped = status };
        },
        .INTR => return .interrupted,
        .CHILD => return .no_child,
        .INVAL => unreachable,
        else => unreachable,
    }
}

/// Returns the normal exit code encoded by `status`, or null otherwise.
pub fn exitCode(status: u32) ?u8 {
    return if (std.os.linux.W.IFEXITED(status)) std.os.linux.W.EXITSTATUS(status) else null;
}

/// Returns the terminating signal encoded by `status`, or null otherwise.
pub fn exitSignal(status: u32) ?u8 {
    if (!std.os.linux.W.IFSIGNALED(status)) return null;
    return @intCast(@intFromEnum(std.os.linux.W.TERMSIG(status)));
}

fn readSmallFile(path: [*:0]const u8, buffer: []u8) ?[]u8 {
    const rc = std.os.linux.open(path, .{ .CLOEXEC = true }, 0);
    const fd: i32 = switch (std.os.linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => return null,
    };
    defer _ = std.os.linux.close(fd);
    const n = std.os.linux.read(fd, buffer.ptr, buffer.len);
    if (std.os.linux.errno(n) != .SUCCESS) return null;
    return buffer[0..n];
}

/// Reads a best-effort process name into `buffer`; the result aliases `buffer`.
pub fn readName(pid: std.posix.pid_t, buffer: []u8) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/comm", .{pid}) catch unreachable;
    const contents = readSmallFile(path, buffer) orelse return null;
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// Returns owned NUL-separated argv bytes, or null when procfs cannot provide them.
/// The caller must deinitialize a returned list with `gpa`.
pub fn readArgs(
    gpa: Allocator,
    pid: std.posix.pid_t,
) Allocator.Error!?std.ArrayList(u8) {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/cmdline", .{pid}) catch unreachable;
    const rc = std.os.linux.open(path, .{ .CLOEXEC = true }, 0);
    const fd: i32 = switch (std.os.linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => return null,
    };
    defer _ = std.os.linux.close(fd);

    var contents: std.ArrayList(u8) = .empty;
    errdefer contents.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.os.linux.read(fd, &chunk, chunk.len);
        switch (std.os.linux.errno(n)) {
            .SUCCESS => {
                if (n == 0) break;
                try contents.appendSlice(gpa, chunk[0..n]);
            },
            .INTR => continue,
            else => {
                contents.deinit(gpa);
                return null;
            },
        }
    }
    if (contents.items.len == 0) {
        contents.deinit(gpa);
        return null;
    }
    return contents;
}

fn readLink(pid: std.posix.pid_t, field: []const u8, buffer: []u8) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/{s}", .{ pid, field }) catch unreachable;
    const n = std.os.linux.readlink(path, buffer.ptr, buffer.len);
    return switch (std.os.linux.errno(n)) {
        .SUCCESS => buffer[0..@min(n, buffer.len)],
        else => null,
    };
}

/// Reads a best-effort executable path into `buffer`; the result aliases `buffer`.
pub fn readExecutable(pid: std.posix.pid_t, buffer: []u8) ?[]const u8 {
    return readLink(pid, "exe", buffer);
}

/// Reads a best-effort working directory into `buffer`; the result aliases `buffer`.
pub fn readCwd(pid: std.posix.pid_t, buffer: []u8) ?[]const u8 {
    return readLink(pid, "cwd", buffer);
}

/// Sends `sig` on a best-effort basis; an already exited target is harmless.
pub fn safeKill(pid: std.posix.pid_t, sig: std.posix.SIG) void {
    _ = std.os.linux.kill(pid, sig);
}

/// Returns whether `pid` exists; EPERM still means the process exists.
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

/// Sleeps for the fixed TERM grace period, retrying an interrupted nanosleep.
pub fn sleepTerminationGrace() void {
    var req: std.os.linux.timespec = .{ .sec = 0, .nsec = 120 * std.time.ns_per_ms };
    var rest: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    while (true) {
        const rc = std.os.linux.nanosleep(&req, &rest);
        if (rc != @intFromEnum(std.os.linux.E.INTR)) return;
        req = rest;
    }
}
