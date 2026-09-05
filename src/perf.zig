//! Compile-time performance telemetry. Enabled with `-Dperf-telemetry=true`.
//! Emits at most one summary line per second plus a final session summary.

const std = @import("std");
const build_options = @import("build_options");
const tracer = @import("tracer.zig");

const log = std.log.scoped(.perf);

pub const enabled = build_options.perf_telemetry;

pub const Phase = enum {
    ring_poll,
    cpu_snapshot,
    tree_rebuild,
    clay_layout,
    clay_playback,
    timeline,
    detail,
    end_drawing,
};

const phase_count = @typeInfo(Phase).@"enum".fields.len;

const Histogram = struct {
    count: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    samples: [64]u64 = [_]u64{0} ** 64,
    sample_len: usize = 0,

    fn add(self: *Histogram, ns: u64) void {
        self.count += 1;
        self.total_ns +|= ns;
        self.max_ns = @max(self.max_ns, ns);
        if (self.sample_len < self.samples.len) {
            self.samples[self.sample_len] = ns;
            self.sample_len += 1;
        } else {
            self.samples[(self.count - 1) % self.samples.len] = ns;
        }
    }

    fn percentile(self: *const Histogram, fraction: f64) u64 {
        if (self.sample_len == 0) return 0;
        var copy = self.samples;
        const slice = copy[0..self.sample_len];
        std.mem.sort(u64, slice, {}, std.sort.asc(u64));
        const idx = @min(
            self.sample_len - 1,
            @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.sample_len - 1)) * fraction)),
        );
        return slice[idx];
    }
};

var phase_ns: [phase_count]u64 = [_]u64{0} ** phase_count;
var frame_hist: Histogram = .{};
var second_hist: Histogram = .{};
var last_log_ns: u64 = 0;
var frames: u32 = 0;
var rebuilds: u32 = 0;
var rebuild_jobs: u64 = 0;
var slices_scanned: u64 = 0;
var slices_drawn: u64 = 0;
var cpu_samples: u64 = 0;
var ring_events: u64 = 0;
var metadata_bytes: usize = 0;
var process_count: usize = 0;
var slice_count: usize = 0;
var coalesced_slices: u64 = 0;
var new_slices: u64 = 0;
var current_phase: ?Phase = null;
var clock_io: ?std.Io = null;
var phase_started: ?std.Io.Timestamp = null;
var frame_started: ?std.Io.Timestamp = null;
var session_started: ?std.Io.Timestamp = null;

fn phaseIndex(phase: Phase) usize {
    return @intFromEnum(phase);
}

fn now() ?std.Io.Timestamp {
    const io = clock_io orelse return null;
    return std.Io.Clock.awake.now(io);
}

pub fn beginSession(io: std.Io) void {
    if (comptime !enabled) return;
    clock_io = io;
    session_started = now();
    last_log_ns = 0;
    frames = 0;
    rebuilds = 0;
    rebuild_jobs = 0;
    slices_scanned = 0;
    slices_drawn = 0;
    cpu_samples = 0;
    ring_events = 0;
    metadata_bytes = 0;
    process_count = 0;
    slice_count = 0;
    coalesced_slices = 0;
    new_slices = 0;
    frame_hist = .{};
    second_hist = .{};
    current_phase = null;
    phase_started = null;
    frame_started = null;
    @memset(&phase_ns, 0);
}

pub fn beginFrame() void {
    if (comptime !enabled) return;
    frame_started = now();
    current_phase = null;
    phase_started = null;
}

pub fn enter(phase: Phase) void {
    if (comptime !enabled) return;
    leave();
    current_phase = phase;
    phase_started = now();
}

pub fn leave() void {
    if (comptime !enabled) return;
    const phase = current_phase orelse return;
    const started = phase_started orelse return;
    current_phase = null;
    phase_started = null;
    const current = now() orelse return;
    const elapsed = started.durationTo(current).nanoseconds;
    if (elapsed > 0) phase_ns[phaseIndex(phase)] +|= @intCast(elapsed);
}

pub fn noteRebuild(jobs: usize) void {
    if (comptime !enabled) return;
    rebuilds += 1;
    rebuild_jobs += jobs;
}

pub fn noteSlices(scanned: usize, drawn: usize) void {
    if (comptime !enabled) return;
    slices_scanned += scanned;
    slices_drawn += drawn;
}

/// Counts observations delivered to Session, including ones it cannot attribute.
/// Call only on delivery; collectors retain their last snapshot size between polls.
pub fn noteSnapshot(samples: usize, events: i32) void {
    if (comptime !enabled) return;
    cpu_samples += samples;
    if (events > 0) ring_events += @as(u64, @intCast(events));
}

pub fn noteSessionShape(processes: usize, metadata: usize, slices: usize) void {
    if (comptime !enabled) return;
    process_count = processes;
    metadata_bytes = metadata;
    slice_count = slices;
}

pub fn noteSliceGrowth(coalesced: bool) void {
    if (comptime !enabled) return;
    if (coalesced) coalesced_slices += 1 else new_slices += 1;
}

pub fn endFrame() void {
    if (comptime !enabled) return;
    leave();
    const started = frame_started orelse return;
    const current = now() orelse return;
    const elapsed = started.durationTo(current).nanoseconds;
    if (elapsed <= 0) return;
    const ns: u64 = @intCast(elapsed);
    frame_hist.add(ns);
    second_hist.add(ns);
    frames += 1;
    const session_start = session_started orelse return;
    const session_ns = session_start.durationTo(current).nanoseconds;
    if (session_ns >= 0) maybeLog(@intCast(session_ns));
}

fn maybeLog(session_ns: u64) void {
    if (session_ns -| last_log_ns < std.time.ns_per_s) return;
    log.info(
        "interval frames={d} recent_p50={d}us recent_p95={d}us max={d}us " ++
            "ring_avg={d}us cpu_avg={d}us tree_avg={d}us clay_avg={d}us play_avg={d}us " ++
            "tl_avg={d}us det_avg={d}us draw_avg={d}us procs={d} slices={d} meta={d}B " ++
            "rebuilds={d} jobs={d} events={d} cpu_n={d} scanned={d} drawn={d}",
        .{
            frames,
            second_hist.percentile(0.50) / 1000,
            second_hist.percentile(0.95) / 1000,
            second_hist.max_ns / 1000,
            phase_ns[phaseIndex(.ring_poll)] / frames / 1000,
            phase_ns[phaseIndex(.cpu_snapshot)] / frames / 1000,
            phase_ns[phaseIndex(.tree_rebuild)] / frames / 1000,
            phase_ns[phaseIndex(.clay_layout)] / frames / 1000,
            phase_ns[phaseIndex(.clay_playback)] / frames / 1000,
            phase_ns[phaseIndex(.timeline)] / frames / 1000,
            phase_ns[phaseIndex(.detail)] / frames / 1000,
            phase_ns[phaseIndex(.end_drawing)] / frames / 1000,
            process_count,
            slice_count,
            metadata_bytes,
            rebuilds,
            rebuild_jobs,
            ring_events,
            cpu_samples,
            slices_scanned,
            slices_drawn,
        },
    );
    last_log_ns = session_ns;
    @memset(&phase_ns, 0);
    frames = 0;
    second_hist = .{};
    rebuilds = 0;
    rebuild_jobs = 0;
    slices_scanned = 0;
    slices_drawn = 0;
    cpu_samples = 0;
    ring_events = 0;
}

pub fn sessionSummary() void {
    if (comptime !enabled) return;
    leave();
    log.info(
        "session frames={d} recent_p50={d}us recent_p95={d}us recent_p99={d}us " ++
            "max={d}us procs={d} slices={d} meta={d}B new_slices={d} coalesced={d}",
        .{
            frame_hist.count,
            frame_hist.percentile(0.50) / 1000,
            frame_hist.percentile(0.95) / 1000,
            frame_hist.percentile(0.99) / 1000,
            frame_hist.max_ns / 1000,
            process_count,
            slice_count,
            metadata_bytes,
            new_slices,
            coalesced_slices,
        },
    );
}

test "telemetry evicts the oldest timing sample" {
    var histogram: Histogram = .{};
    for (0..65) |i| histogram.add(i);
    try std.testing.expectEqual(@as(u64, 1), histogram.percentile(0));
    try std.testing.expectEqual(@as(u64, 64), histogram.percentile(1));
    try std.testing.expectEqual(@as(u64, 65), histogram.count);
}

test "telemetry resets all reporting scopes at session start" {
    if (comptime !enabled) return error.SkipZigTest;
    beginSession(std.testing.io);
    frame_hist.add(1234);
    second_hist.add(1234);
    noteRebuild(7);
    noteSlices(11, 3);
    noteSnapshot(5, 2);
    noteSessionShape(9, 100, 11);
    noteSliceGrowth(false);
    noteSliceGrowth(true);
    enter(.detail);
    beginSession(std.testing.io);
    try std.testing.expectEqual(@as(u64, 0), frame_hist.count);
    try std.testing.expectEqual(@as(u64, 0), second_hist.count);
    try std.testing.expectEqual(@as(u64, 0), rebuild_jobs);
    try std.testing.expectEqual(@as(u64, 0), slices_scanned);
    try std.testing.expectEqual(@as(u64, 0), slices_drawn);
    try std.testing.expectEqual(@as(u64, 0), cpu_samples);
    try std.testing.expectEqual(@as(u64, 0), ring_events);
    try std.testing.expectEqual(@as(usize, 0), process_count);
    try std.testing.expectEqual(@as(usize, 0), metadata_bytes);
    try std.testing.expectEqual(@as(usize, 0), slice_count);
    try std.testing.expectEqual(@as(u64, 0), new_slices);
    try std.testing.expectEqual(@as(u64, 0), coalesced_slices);
    try std.testing.expect(current_phase == null);
}

test "telemetry retains phase totals between frames" {
    if (comptime !enabled) return error.SkipZigTest;
    beginSession(std.testing.io);
    beginFrame();
    enter(.detail);
    const started = phase_started.?;
    phase_started = .fromNanoseconds(started.nanoseconds - std.time.ns_per_ms);
    leave();
    const first_detail = phase_ns[phaseIndex(.detail)];
    try std.testing.expect(first_detail >= std.time.ns_per_ms);
    endFrame();
    beginFrame();
    try std.testing.expectEqual(first_detail, phase_ns[phaseIndex(.detail)]);
    enter(.detail);
    phase_started = .fromNanoseconds(phase_started.?.nanoseconds - std.time.ns_per_ms);
    leave();
    try std.testing.expect(phase_ns[phaseIndex(.detail)] >= first_detail + std.time.ns_per_ms);
}

test "telemetry counts received samples and actual CPU slice growth" {
    if (comptime !enabled) return error.SkipZigTest;
    const testing = std.testing;
    beginSession(testing.io);
    var session = tracer.Session.init(testing.allocator, testing.io);
    defer session.deinit();
    try session.processes.append(testing.allocator, .{ .pid = 2_000_000_000 });
    try session.by_pid.put(testing.allocator, 2_000_000_000, 0);
    session.running = true;
    defer session.running = false;
    session.consumeCpuSnapshot(2_000_000_000, 50, 100);
    session.consumeCpuSnapshot(2_000_000_000, 100, 200);
    session.consumeCpuSnapshot(2_000_000_000, 100, 300);
    session.consumeCpuSnapshot(2_000_000_000, 125, 400);
    try testing.expectEqual(@as(u64, 4), cpu_samples);
    try testing.expectEqual(@as(u64, 2), new_slices);
    try testing.expectEqual(@as(u64, 1), coalesced_slices);
    for (0..4) |_| {
        beginFrame();
        endFrame();
    }
    try testing.expectEqual(@as(u64, 4), cpu_samples);
    try testing.expectEqual(@as(u64, 0), ring_events);
    session.consumeEvent(.{ .timestamp_ns = 500, .payload = .{ .exit = .{
        .pid = 2_000_000_000,
        .name = "done",
        .cpu_ns = 125,
        .cpu_final = true,
    } } });
    try testing.expectEqual(@as(u64, 1), ring_events);
    try testing.expectEqual(@as(u64, 4), cpu_samples);
}
