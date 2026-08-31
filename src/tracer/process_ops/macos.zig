//! macOS process operations. Public libc handles process control while the
//! platform shim isolates best-effort metadata calls to private libproc/sysctl APIs.

const std = @import("std");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.process_ops);

pub const args_source = .process_inspection;

pub const ResumeError = error{TargetResumeRejected};

extern "c" fn flamez_macos_spawn_suspended(
    argv: [*:null]const ?[*:0]const u8,
    pid: *std.posix.pid_t,
) c_int;
extern "c" fn flamez_macos_resume_process(pid: std.posix.pid_t) c_int;

extern "c" fn flamez_macos_read_cwd(
    pid: i32,
    buffer: [*]u8,
    buffer_size: usize,
) c_int;
extern "c" fn flamez_macos_read_executable(
    pid: i32,
    buffer: [*]u8,
    buffer_size: usize,
) c_int;
extern "c" fn flamez_macos_read_procargs(
    pid: i32,
    buffer: ?*anyopaque,
    buffer_size: *usize,
) c_int;

/// Result of a nonblocking wait on the target root.
pub const WaitNowait = union(enum) {
    still_running,
    interrupted,
    no_child,
    reaped: u32,
};

/// Uses Darwin `posix_spawn` to create a new process-group leader that cannot
/// execute target code until `resumeTarget` runs after collector registration.
pub fn spawnTarget(
    gpa: Allocator,
    _: std.Io,
    argv: []const []const u8,
) std.process.SpawnError!std.process.Child {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const temporary = arena.allocator();
    const argv_z = try temporary.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |argument, index| {
        if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidName;
        argv_z[index] = (try temporary.dupeZ(u8, argument)).ptr;
    }

    var pid: std.posix.pid_t = 0;
    const result = flamez_macos_spawn_suspended(argv_z.ptr, &pid);
    if (result != 0) return spawnError(result);
    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
}

/// Resumes the target only after kqueue registration or exact ES root admission.
pub fn resumeTarget(pid: std.posix.pid_t) ResumeError!void {
    if (flamez_macos_resume_process(pid) != 0) return error.TargetResumeRejected;
}

extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffer_size: u32) c_int;

fn spawnError(result: c_int) std.process.SpawnError {
    const code: std.c.E = @enumFromInt(@as(u16, @intCast(result)));
    return switch (code) {
        .@"2BIG", .AGAIN, .NOMEM, .PROCLIM => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .INVAL, .NOEXEC, .BADEXEC, .BADARCH, .SHLIBVERS, .BADMACHO => error.InvalidExe,
        .IO => error.FileSystem,
        .LOOP => error.SymLinkLoop,
        .ISDIR => error.IsDir,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .TXTBSY => error.FileBusy,
        else => error.Unexpected,
    };
}

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

/// Returns owned NUL-separated argv bytes from `KERN_PROCARGS2`, or null when
/// process inspection is denied or races process exit.
pub fn readArgs(
    gpa: Allocator,
    pid: std.posix.pid_t,
) Allocator.Error!?std.ArrayList(u8) {
    var raw_size: usize = 0;
    if (flamez_macos_read_procargs(pid, null, &raw_size) != 0 or
        raw_size < @sizeOf(c_int)) return null;

    const raw = try gpa.alloc(u8, raw_size);
    defer gpa.free(raw);
    var amount = raw.len;
    if (flamez_macos_read_procargs(pid, raw.ptr, &amount) != 0 or
        amount < @sizeOf(c_int)) return null;
    return parseProcArgs(gpa, raw[0..amount]);
}

/// Reads a best-effort executable path into `buffer`; the result aliases `buffer`.
pub fn readExecutable(pid: std.posix.pid_t, buffer: []u8) ?[]const u8 {
    if (buffer.len == 0) return null;
    const amount = flamez_macos_read_executable(pid, buffer.ptr, buffer.len);
    return if (amount > 0) buffer[0..@intCast(amount)] else null;
}

/// Reads the best-effort current working directory; the result aliases `buffer`.
pub fn readCwd(pid: std.posix.pid_t, buffer: []u8) ?[]const u8 {
    if (buffer.len == 0) return null;
    const amount = flamez_macos_read_cwd(pid, buffer.ptr, buffer.len);
    return if (amount > 0) buffer[0..@intCast(amount)] else null;
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

fn parseProcArgs(gpa: Allocator, raw: []const u8) Allocator.Error!?std.ArrayList(u8) {
    if (raw.len < @sizeOf(c_int)) return null;
    const argc_signed = std.mem.readInt(c_int, raw[0..@sizeOf(c_int)], .little);
    if (argc_signed <= 0) return null;
    const argc: usize = @intCast(argc_signed);

    var position: usize = @sizeOf(c_int);
    const executable_end = std.mem.indexOfScalarPos(u8, raw, position, 0) orelse return null;
    position = executable_end + 1;
    while (position < raw.len and raw[position] == 0) position += 1;

    const arguments_start = position;
    var argument_index: usize = 0;
    while (argument_index < argc) : (argument_index += 1) {
        const end = std.mem.indexOfScalarPos(u8, raw, position, 0) orelse return null;
        position = end + 1;
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    try result.appendSlice(gpa, raw[arguments_start..position]);
    return result;
}

test "reads current process metadata" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const pid = currentPid();

    var args = (try readArgs(gpa, pid)) orelse return error.TestUnexpectedResult;
    defer args.deinit(gpa);
    try testing.expect(args.items.len > 1);
    try testing.expect(args.items[args.items.len - 1] == 0);

    var buffer: [4096]u8 = undefined;
    const executable = readExecutable(pid, &buffer) orelse return error.TestUnexpectedResult;
    try testing.expect(executable.len > 0);
    const cwd = readCwd(pid, &buffer) orelse return error.TestUnexpectedResult;
    try testing.expect(cwd.len > 0);
    try testing.expect(cwd[0] == '/');
}

test "parses empty arguments after argv zero" {
    const testing = std.testing;
    const raw = "\x04\x00\x00\x00/bin/tool\x00\x00tool\x00\x00value\x00\x00";
    var args = (try parseProcArgs(testing.allocator, raw)) orelse
        return error.TestUnexpectedResult;
    defer args.deinit(testing.allocator);
    try testing.expectEqualStrings("tool\x00\x00value\x00\x00", args.items);
}

test "rejects a truncated later process argument without retaining storage" {
    const raw = "\x02\x00\x00\x00/bin/tool\x00\x00tool\x00truncated";
    try std.testing.expectEqual(null, try parseProcArgs(std.testing.allocator, raw));
}

test "suspended target cannot execute before collector registration" {
    const testing = std.testing;
    var child = try spawnTarget(
        testing.allocator,
        testing.io,
        &.{
            "sh",
            "-c",
            "exit 37",
        },
    );
    errdefer child.kill(testing.io);
    const pid = child.id.?;

    switch (waitNowait(pid)) {
        .still_running => {},
        .interrupted, .no_child, .reaped => return error.TestUnexpectedResult,
    }

    try resumeTarget(pid);
    const termination = try child.wait(testing.io);
    switch (termination) {
        .exited => |code| try testing.expectEqual(@as(u8, 37), code),
        .signal, .stopped, .unknown => return error.TestUnexpectedResult,
    }
}
