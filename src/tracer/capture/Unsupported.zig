//! Inert capture backend for targets without an implemented collector.

const std = @import("std");
const builtin = @import("builtin");
const capture = @import("../capture.zig");

const Unsupported = @This();

/// Always zero because this backend cannot lose events it never observes.
lost_events: u64 = 0,
/// Always zero because this backend never polls a ring buffer.
last_ring_events: i32 = 0,
/// Always zero because this backend never samples CPU accounting.
last_cpu_samples: usize = 0,
diagnostic_buffer: [128]u8 = [_]u8{0} ** 128,
diagnostic_len: usize = 0,

/// Records that this target has no capture implementation.
pub fn init(_: std.mem.Allocator) Unsupported {
    var self = Unsupported{};
    const message = std.fmt.bufPrint(
        &self.diagnostic_buffer,
        "process capture is not implemented for {s}",
        .{@tagName(builtin.os.tag)},
    ) catch "process capture is not implemented for this operating system";
    self.diagnostic_len = message.len;
    return self;
}

/// Releases collector state and invalidates `self`.
pub fn deinit(self: *Unsupported) void {
    self.* = undefined;
}

/// Always false because this backend cannot produce process events.
pub fn available(_: *const Unsupported) bool {
    return false;
}

/// Preserves the common collector contract without changing privileges.
pub fn dropPrivileges(_: *const Unsupported) capture.DropPrivilegesError!void {}

/// Returns collector-owned storage valid until `deinit`.
pub fn diagnosticSlice(self: *const Unsupported) []const u8 {
    return self.diagnostic_buffer[0..self.diagnostic_len];
}

/// No lifecycle guarantee exists without a collector implementation.
pub fn fidelity(_: *const Unsupported) capture.Fidelity {
    return .unavailable;
}

/// Preserves the common collector contract without arming a launch.
pub fn armLaunch(_: *Unsupported, _: std.posix.pid_t) capture.ArmLaunchError!void {}

/// Preserves the common collector contract without changing tracked pids.
pub fn untrack(_: *Unsupported, _: std.posix.pid_t) void {}

/// Preserves the common collector contract without tracking a root.
pub fn trackRoot(_: *Unsupported, _: std.posix.pid_t) capture.TrackRootError!void {}

/// Produces no lifecycle events.
pub fn pollEvents(_: *Unsupported, _: capture.Sink) void {}

/// Produces no final lifecycle events.
pub fn flushEvents(_: *Unsupported, _: capture.Sink) void {}

/// Produces no CPU samples.
pub fn snapshotCpu(_: *Unsupported, _: capture.Sink) void {}
