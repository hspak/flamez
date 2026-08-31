//! Bounded host and Flamez provenance recorded when a capture starts.

const std = @import("std");
const builtin = @import("builtin");

const CaptureEnvironment = @This();

started_at_unix_seconds: ?i64 = null,
host_os: Os = .unknown,
architecture: Architecture = .unknown,
kernel_version: [max_kernel_version_len]u8 = [_]u8{0} ** max_kernel_version_len,
kernel_version_len: u16 = 0,
flamez_version: [max_tool_version_len]u8 = [_]u8{0} ** max_tool_version_len,
flamez_version_len: u8 = 0,
flamez_build_zig_version: [max_tool_version_len]u8 = [_]u8{0} ** max_tool_version_len,
flamez_build_zig_version_len: u8 = 0,

pub const max_kernel_version_len = 256;
pub const max_tool_version_len = 64;

pub const Os = enum {
    unknown,
    linux,
    macos,
};

pub const Architecture = enum {
    unknown,
    x86_64,
    aarch64,
};

pub fn capture(io: std.Io) CaptureEnvironment {
    var environment: CaptureEnvironment = .{
        .started_at_unix_seconds = std.Io.Clock.real.now(io).toSeconds(),
        .host_os = switch (builtin.os.tag) {
            .linux => .linux,
            .macos => .macos,
            else => .unknown,
        },
        .architecture = switch (builtin.cpu.arch) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            else => .unknown,
        },
    };
    environment.setFlamezVersion("0.0.0");
    environment.setFlamezBuildZigVersion(builtin.zig_version_string);
    if (comptime builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const uts = std.posix.uname();
        environment.setKernelVersion(std.mem.sliceTo(&uts.release, 0));
    }
    return environment;
}

pub fn kernelVersion(self: *const CaptureEnvironment) []const u8 {
    return self.kernel_version[0..self.kernel_version_len];
}

pub fn flamezVersion(self: *const CaptureEnvironment) []const u8 {
    return self.flamez_version[0..self.flamez_version_len];
}

pub fn flamezBuildZigVersion(self: *const CaptureEnvironment) []const u8 {
    return self.flamez_build_zig_version[0..self.flamez_build_zig_version_len];
}

pub fn setKernelVersion(self: *CaptureEnvironment, value: []const u8) void {
    self.kernel_version_len = @intCast(copyBounded(&self.kernel_version, value));
}

pub fn setFlamezVersion(self: *CaptureEnvironment, value: []const u8) void {
    self.flamez_version_len = @intCast(copyBounded(&self.flamez_version, value));
}

pub fn setFlamezBuildZigVersion(self: *CaptureEnvironment, value: []const u8) void {
    self.flamez_build_zig_version_len = @intCast(
        copyBounded(&self.flamez_build_zig_version, value),
    );
}

fn copyBounded(output: []u8, value: []const u8) usize {
    const len = @min(output.len, value.len);
    @memcpy(output[0..len], value[0..len]);
    return len;
}

test "capture records bounded static provenance" {
    const environment = CaptureEnvironment.capture(std.testing.io);
    try std.testing.expect(environment.started_at_unix_seconds != null);
    try std.testing.expect(environment.host_os != .unknown);
    try std.testing.expect(environment.architecture != .unknown);
    try std.testing.expect(environment.kernelVersion().len != 0);
    try std.testing.expectEqualStrings("0.0.0", environment.flamezVersion());
    try std.testing.expect(environment.flamezBuildZigVersion().len != 0);
}
