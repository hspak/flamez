//! Backend-neutral process lifecycle event consumed by a capture session.

const std = @import("std");

const Event = @This();

/// Monotonic nanoseconds in the process awake-clock domain used by `Session`.
timestamp_ns: u64,
/// Lifecycle observation and its backend-owned metadata slices.
payload: Payload,

/// Closed set of lifecycle observations accepted by a capture session.
pub const Payload = union(enum) {
    fork: Fork,
    exec: Exec,
    exit: Exit,
};

/// A process admitted beneath an already tracked parent.
pub const Fork = struct {
    pid: std.posix.pid_t,
    parent_pid: std.posix.pid_t,
    /// Kernel process name, borrowed for the delivery callback.
    name: []const u8,
};

/// Replacement of a tracked process image.
pub const Exec = struct {
    pid: std.posix.pid_t,
    /// Kernel process name, borrowed for the delivery callback.
    name: []const u8,
    /// Executable path when the backend captured one.
    exe: ?[]const u8 = null,
    /// NUL-separated argv, including argv[0], when captured by the backend.
    args: ?[]const u8 = null,
    /// Whether `exe` is a known prefix rather than the complete path.
    exe_truncated: bool = false,
};

/// Final exit of a tracked process thread group.
pub const Exit = struct {
    pid: std.posix.pid_t,
    /// Kernel process name, borrowed for the delivery callback.
    name: []const u8,
    /// Final cumulative self CPU for the process and all of its threads.
    cpu_ns: u64,
};
