//! Compile-time performance telemetry. Enabled with `-Dperf-telemetry=true`.
//! Emits at most one summary line per second plus a final session summary.

const std = @import("std");

const log = std.log.scoped(.perf);
const build_options = @import("build_options");

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

const Recording = struct {
    phase_ns: [phase_count]u64 = [_]u64{0} ** phase_count,
    frame_hist: Histogram = .{},
    second_hist: Histogram = .{},
    last_log_ns: u64 = 0,
    frames: u32 = 0,
    rebuilds: u32 = 0,
    rebuild_jobs: u64 = 0,
    slices_scanned: u64 = 0,
    slices_drawn: u64 = 0,
    cpu_samples: u64 = 0,
    ring_events: u64 = 0,
    metadata_bytes: usize = 0,
    process_count: usize = 0,
    slice_count: usize = 0,
    coalesced_slices: u64 = 0,
    new_slices: u64 = 0,
    current_phase: ?Phase = null,
    clock_io: ?std.Io = null,
    phase_started: ?std.Io.Timestamp = null,
    frame_started: ?std.Io.Timestamp = null,
    session_started: ?std.Io.Timestamp = null,
};

var recording: if (enabled) Recording else void = if (enabled) .{} else {};

fn phaseIndex(phase: Phase) usize {
    return @intFromEnum(phase);
}

fn now() ?std.Io.Timestamp {
    const io = recording.clock_io orelse return null;
    return std.Io.Clock.awake.now(io);
}

pub fn beginSession(io: std.Io) void {
    if (comptime !enabled) return;
    recording.clock_io = io;
    recording.session_started = now();
    recording.last_log_ns = 0;
    recording.frames = 0;
    recording.rebuilds = 0;
    recording.rebuild_jobs = 0;
    recording.slices_scanned = 0;
    recording.slices_drawn = 0;
    recording.cpu_samples = 0;
    recording.ring_events = 0;
    recording.metadata_bytes = 0;
    recording.process_count = 0;
    recording.slice_count = 0;
    recording.coalesced_slices = 0;
    recording.new_slices = 0;
    recording.frame_hist = .{};
    recording.second_hist = .{};
    recording.current_phase = null;
    recording.phase_started = null;
    recording.frame_started = null;
    @memset(&recording.phase_ns, 0);
}

pub fn beginFrame() void {
    if (comptime !enabled) return;
    recording.frame_started = now();
    recording.current_phase = null;
    recording.phase_started = null;
}

pub fn enter(phase: Phase) void {
    if (comptime !enabled) return;
    leave();
    recording.current_phase = phase;
    recording.phase_started = now();
}

pub fn leave() void {
    if (comptime !enabled) return;
    const phase = recording.current_phase orelse return;
    const started = recording.phase_started orelse return;
    recording.current_phase = null;
    recording.phase_started = null;
    const current = now() orelse return;
    const elapsed = started.durationTo(current).nanoseconds;
    if (elapsed > 0) recording.phase_ns[phaseIndex(phase)] +|= @intCast(elapsed);
}

pub fn noteRebuild(jobs: usize) void {
    if (comptime !enabled) return;
    recording.rebuilds += 1;
    recording.rebuild_jobs += jobs;
}

pub fn noteSlices(scanned: usize, drawn: usize) void {
    if (comptime !enabled) return;
    recording.slices_scanned += scanned;
    recording.slices_drawn += drawn;
}

/// Counts observations delivered to Session, including ones it cannot attribute.
/// Call only on delivery; collectors retain their last snapshot size between polls.
pub fn noteSnapshot(samples: usize, events: i32) void {
    if (comptime !enabled) return;
    recording.cpu_samples += samples;
    if (events > 0) recording.ring_events += @as(u64, @intCast(events));
}

pub fn noteSessionShape(processes: usize, metadata: usize, slices: usize) void {
    if (comptime !enabled) return;
    recording.process_count = processes;
    recording.metadata_bytes = metadata;
    recording.slice_count = slices;
}

pub fn noteSliceGrowth(coalesced: bool) void {
    if (comptime !enabled) return;
    if (coalesced) recording.coalesced_slices += 1 else recording.new_slices += 1;
}

pub fn endFrame() void {
    if (comptime !enabled) return;
    leave();
    const started = recording.frame_started orelse return;
    const current = now() orelse return;
    const elapsed = started.durationTo(current).nanoseconds;
    if (elapsed <= 0) return;
    const ns: u64 = @intCast(elapsed);
    recording.frame_hist.add(ns);
    recording.second_hist.add(ns);
    recording.frames += 1;
    const session_start = recording.session_started orelse return;
    const session_ns = session_start.durationTo(current).nanoseconds;
    if (session_ns >= 0) maybeLog(@intCast(session_ns));
}

fn maybeLog(session_ns: u64) void {
    if (session_ns -| recording.last_log_ns < std.time.ns_per_s) return;
    log.info(
        "interval frames={d} recent_p50={d}us recent_p95={d}us max={d}us " ++
            "ring_avg={d}us cpu_avg={d}us tree_avg={d}us clay_avg={d}us play_avg={d}us " ++
            "tl_avg={d}us det_avg={d}us draw_avg={d}us procs={d} slices={d} meta={d}B " ++
            "rebuilds={d} jobs={d} events={d} cpu_n={d} scanned={d} drawn={d}",
        .{
            recording.frames,
            recording.second_hist.percentile(0.50) / 1000,
            recording.second_hist.percentile(0.95) / 1000,
            recording.second_hist.max_ns / 1000,
            recording.phase_ns[phaseIndex(.ring_poll)] / recording.frames / 1000,
            recording.phase_ns[phaseIndex(.cpu_snapshot)] / recording.frames / 1000,
            recording.phase_ns[phaseIndex(.tree_rebuild)] / recording.frames / 1000,
            recording.phase_ns[phaseIndex(.clay_layout)] / recording.frames / 1000,
            recording.phase_ns[phaseIndex(.clay_playback)] / recording.frames / 1000,
            recording.phase_ns[phaseIndex(.timeline)] / recording.frames / 1000,
            recording.phase_ns[phaseIndex(.detail)] / recording.frames / 1000,
            recording.phase_ns[phaseIndex(.end_drawing)] / recording.frames / 1000,
            recording.process_count,
            recording.slice_count,
            recording.metadata_bytes,
            recording.rebuilds,
            recording.rebuild_jobs,
            recording.ring_events,
            recording.cpu_samples,
            recording.slices_scanned,
            recording.slices_drawn,
        },
    );
    recording.last_log_ns = session_ns;
    @memset(&recording.phase_ns, 0);
    recording.frames = 0;
    recording.second_hist = .{};
    recording.rebuilds = 0;
    recording.rebuild_jobs = 0;
    recording.slices_scanned = 0;
    recording.slices_drawn = 0;
    recording.cpu_samples = 0;
    recording.ring_events = 0;
}

pub fn sessionSummary() void {
    if (comptime !enabled) return;
    leave();
    log.info(
        "session frames={d} recent_p50={d}us recent_p95={d}us recent_p99={d}us " ++
            "max={d}us procs={d} slices={d} meta={d}B new_slices={d} coalesced={d}",
        .{
            recording.frame_hist.count,
            recording.frame_hist.percentile(0.50) / 1000,
            recording.frame_hist.percentile(0.95) / 1000,
            recording.frame_hist.percentile(0.99) / 1000,
            recording.frame_hist.max_ns / 1000,
            recording.process_count,
            recording.slice_count,
            recording.metadata_bytes,
            recording.new_slices,
            recording.coalesced_slices,
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
    recording.frame_hist.add(1234);
    recording.second_hist.add(1234);
    noteRebuild(7);
    noteSlices(11, 3);
    noteSnapshot(5, 2);
    noteSessionShape(9, 100, 11);
    noteSliceGrowth(false);
    noteSliceGrowth(true);
    enter(.detail);
    beginSession(std.testing.io);
    try std.testing.expectEqual(@as(u64, 0), recording.frame_hist.count);
    try std.testing.expectEqual(@as(u64, 0), recording.second_hist.count);
    try std.testing.expectEqual(@as(u64, 0), recording.rebuild_jobs);
    try std.testing.expectEqual(@as(u64, 0), recording.slices_scanned);
    try std.testing.expectEqual(@as(u64, 0), recording.slices_drawn);
    try std.testing.expectEqual(@as(u64, 0), recording.cpu_samples);
    try std.testing.expectEqual(@as(u64, 0), recording.ring_events);
    try std.testing.expectEqual(@as(usize, 0), recording.process_count);
    try std.testing.expectEqual(@as(usize, 0), recording.metadata_bytes);
    try std.testing.expectEqual(@as(usize, 0), recording.slice_count);
    try std.testing.expectEqual(@as(u64, 0), recording.new_slices);
    try std.testing.expectEqual(@as(u64, 0), recording.coalesced_slices);
    try std.testing.expect(recording.current_phase == null);
}

test "telemetry retains phase totals between frames" {
    if (comptime !enabled) return error.SkipZigTest;
    beginSession(std.testing.io);
    beginFrame();
    enter(.detail);
    const started = recording.phase_started.?;
    recording.phase_started = .fromNanoseconds(started.nanoseconds - std.time.ns_per_ms);
    leave();
    const first_detail = recording.phase_ns[phaseIndex(.detail)];
    try std.testing.expect(first_detail >= std.time.ns_per_ms);
    endFrame();
    beginFrame();
    try std.testing.expectEqual(first_detail, recording.phase_ns[phaseIndex(.detail)]);
    enter(.detail);
    recording.phase_started = .fromNanoseconds(
        recording.phase_started.?.nanoseconds - std.time.ns_per_ms,
    );
    leave();
    try std.testing.expect(
        recording.phase_ns[phaseIndex(.detail)] >= first_detail + std.time.ns_per_ms,
    );
}

test "telemetry counts received samples and actual CPU slice growth" {
    const tracer = @import("tracer.zig");
    if (comptime !enabled) return error.SkipZigTest;
    const testing = std.testing;
    beginSession(testing.io);
    var session = tracer.Session.init(testing.allocator, testing.io);
    defer session.deinit();
    try session.processes.append(testing.allocator, .init(.{
        .pid = 2_000_000_000,
        .start_ns = 0,
    }));
    try session.by_pid.put(testing.allocator, 2_000_000_000, 0);
    session.running = true;
    defer session.running = false;
    session.consumeCpuSnapshot(2_000_000_000, 50, 100);
    session.consumeCpuSnapshot(2_000_000_000, 100, 200);
    session.consumeCpuSnapshot(2_000_000_000, 100, 300);
    session.consumeCpuSnapshot(2_000_000_000, 125, 400);
    try testing.expectEqual(@as(u64, 4), recording.cpu_samples);
    try testing.expectEqual(@as(u64, 2), recording.new_slices);
    try testing.expectEqual(@as(u64, 1), recording.coalesced_slices);
    for (0..4) |_| {
        beginFrame();
        endFrame();
    }
    try testing.expectEqual(@as(u64, 4), recording.cpu_samples);
    try testing.expectEqual(@as(u64, 0), recording.ring_events);
    session.consumeEvent(.{ .timestamp_ns = 500, .payload = .{ .exit = .{
        .pid = 2_000_000_000,
        .name = "done",
        .cpu_ns = 125,
        .cpu_final = true,
    } } });
    try testing.expectEqual(@as(u64, 1), recording.ring_events);
    try testing.expectEqual(@as(u64, 4), recording.cpu_samples);
}
