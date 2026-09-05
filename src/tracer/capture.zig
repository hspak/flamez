//! OS-neutral capture contract and compile-time backend selection.

const std = @import("std");
const builtin = @import("builtin");

/// Backend-neutral lifecycle event consumed by `Session`.
pub const Event = @import("capture/Event.zig");

/// Capture implementation selected for the compilation target.
pub const Backend = enum {
    linux_ebpf,
    macos,
    unsupported,
};

/// Whether a backend has exact lifecycle delivery or reconstructs snapshots.
pub const Fidelity = enum {
    exact,
    snapshot_recovery,
    unavailable,
};

/// Failure to remove capture privileges after attaching.
pub const DropPrivilegesError = error{PrivilegeDropRejected};

/// Failure to arm capture around a pending launch.
pub const ArmLaunchError = error{
    ExactCaptureUnavailable,
    LaunchTrackingRejected,
};

/// Failure to register a spawned root with the active backend.
pub const TrackRootError = error{LaunchTrackingRejected};

/// Compile-time backend choice for the current target.
pub const backend: Backend = switch (builtin.os.tag) {
    .linux => .linux_ebpf,
    .macos => .macos,
    else => @compileError("capture selection is implemented only for Linux and macOS"),
};

/// Fidelity shown before a runtime-selecting collector arms its first launch.
pub const default_fidelity: Fidelity = switch (backend) {
    .linux_ebpf => .exact,
    .macos => .snapshot_recovery,
    .unsupported => .unavailable,
};

const implementation = switch (backend) {
    .linux_ebpf => @import("capture/linux.zig"),
    .macos => @import("capture/macos.zig"),
    .unsupported => @import("capture/unsupported.zig"),
};

/// Target-specific collector implementing the common session-facing contract.
pub const Collector = implementation.Collector;

/// Backend-independent delivery target. Events and borrowed slices are valid
/// only for the duration of the callback.
pub const Sink = struct {
    /// Opaque receiver passed unchanged to both callbacks.
    ptr: *anyopaque,
    /// Receives one event whose slices remain valid only during the call.
    event_fn: *const fn (*anyopaque, Event) void,
    /// Receives one cumulative process self-CPU observation.
    cpu_sample_fn: *const fn (*anyopaque, std.posix.pid_t, u64, u64) void,

    /// Delivers `value` synchronously to the configured event callback.
    pub fn event(self: Sink, value: Event) void {
        self.event_fn(self.ptr, value);
    }

    /// Delivers a cumulative CPU total and its monotonic observation timestamp.
    pub fn cpuSample(
        self: Sink,
        pid: std.posix.pid_t,
        total_ns: u64,
        timestamp_ns: u64,
    ) void {
        self.cpu_sample_fn(self.ptr, pid, total_ns, timestamp_ns);
    }
};

extern fn flamez_macos_test_cpu_identity(by_version: c_int, scenario: c_uint) c_int;

test {
    _ = Event;
    _ = implementation;
}

test "unsupported collector reports the target operating system" {
    if (comptime backend != .unsupported) return error.SkipZigTest;
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();
    try std.testing.expect(!collector.available());
    try std.testing.expect(std.mem.indexOf(
        u8,
        collector.diagnosticSlice(),
        @tagName(builtin.os.tag),
    ) != null);
}

test "macOS final CPU rejects reused identities before and during the read" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    for (0..8) |scenario| {
        try std.testing.expectEqual(@as(c_int, 0), flamez_macos_test_cpu_identity(0, @intCast(scenario)));
    }
}

test "macOS final CPU binds Endpoint Security reads to the audit version" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    for (0..8) |scenario| {
        try std.testing.expectEqual(@as(c_int, 0), flamez_macos_test_cpu_identity(1, @intCast(scenario)));
    }
}
