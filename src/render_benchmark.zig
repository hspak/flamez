//! Opt-in steady-state frame measurements, including presentation and main-thread CPU time.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const desktop = @import("desktop.zig");
const log = std.log.scoped(.render_benchmark);

pub const enabled = build_options.render_benchmark;
const warmup_frames = 120;
const sample_count = 600;
const Sample = struct {
    wall: u64,
    cpu: u64,
    prepare: u64,
    present: u64,
};
const Recording = struct {
    frames: usize = 0,
    samples: [sample_count]Sample = undefined,
    wall_start: std.Io.Timestamp = undefined,
    cpu_start: std.Io.Timestamp = undefined,
    present_start: std.Io.Timestamp = undefined,
};
var recording: if (enabled) Recording else void = if (enabled) .{} else {};

pub fn beginFrame(io: std.Io) void {
    if (comptime !enabled) return;
    recording.cpu_start = std.Io.Clock.cpu_thread.now(io);
    recording.wall_start = std.Io.Clock.awake.now(io);
}

pub fn beginPresent(io: std.Io) void {
    if (comptime !enabled) return;
    recording.present_start = std.Io.Clock.awake.now(io);
}

/// Returns true after reporting all measured frames. No sample I/O occurs while measuring.
pub fn endFrame(io: std.Io) bool {
    if (comptime !enabled) return false;
    const wall_end = std.Io.Clock.awake.now(io);
    const cpu_end = std.Io.Clock.cpu_thread.now(io);
    if (recording.frames >= warmup_frames) {
        recording.samples[recording.frames - warmup_frames] = .{
            .wall = @intCast(recording.wall_start.durationTo(wall_end).nanoseconds),
            .cpu = @intCast(recording.cpu_start.durationTo(cpu_end).nanoseconds),
            .prepare = @intCast(recording.wall_start.durationTo(recording.present_start).nanoseconds),
            .present = @intCast(recording.present_start.durationTo(wall_end).nanoseconds),
        };
    }
    recording.frames += 1;
    if (recording.frames != warmup_frames + sample_count) return false;
    log.info("profile mode={t} automation={} telemetry={} logical={d}x{d} pixels={d}x{d}", .{
        builtin.mode,
        build_options.automation,
        build_options.perf_telemetry,
        desktop.width(),
        desktop.height(),
        desktop.pixelWidth(),
        desktop.pixelHeight(),
    });
    inline for (std.meta.fields(Sample)) |field| {
        var values: [sample_count]u64 = undefined;
        var total: u64 = 0;
        for (recording.samples, 0..) |sample, i| {
            values[i] = @field(sample, field.name);
            total += values[i];
        }
        std.mem.sort(u64, &values, {}, std.sort.asc(u64));
        log.info("{s} frames={d} mean_ns={d} p50_ns={d} p95_ns={d}", .{
            field.name,
            sample_count,
            total / sample_count,
            values[sample_count / 2],
            values[sample_count * 95 / 100],
        });
    }
    return true;
}
