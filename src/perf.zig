//! Compile-time performance telemetry. Enabled with `-Dperf-telemetry=true`.
//! Emits at most one summary line per second plus a final session summary.

const std = @import("std");
const build_options = @import("build_options");

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
            self.samples[self.count % self.samples.len] = ns;
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
}

pub fn beginFrame() void {
    if (comptime !enabled) return;
    frame_started = now();
    current_phase = null;
    phase_started = null;
    @memset(&phase_ns, 0);
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
    maybeLog(ns);
}

fn maybeLog(frame_ns: u64) void {
    last_log_ns +|= frame_ns;
    if (last_log_ns < std.time.ns_per_s) return;
    log.info(
        "frame p50={d}us p95={d}us max={d}us ring={d}us cpu={d}us tree={d}us " ++
            "clay={d}us play={d}us tl={d}us det={d}us draw={d}us procs={d} " ++
            "slices={d} meta={d}B rebuilds={d} ring_ev={d} cpu_n={d} scanned={d} drawn={d}",
        .{
            second_hist.percentile(0.50) / 1000,
            second_hist.percentile(0.95) / 1000,
            second_hist.max_ns / 1000,
            phase_ns[phaseIndex(.ring_poll)] / 1000,
            phase_ns[phaseIndex(.cpu_snapshot)] / 1000,
            phase_ns[phaseIndex(.tree_rebuild)] / 1000,
            phase_ns[phaseIndex(.clay_layout)] / 1000,
            phase_ns[phaseIndex(.clay_playback)] / 1000,
            phase_ns[phaseIndex(.timeline)] / 1000,
            phase_ns[phaseIndex(.detail)] / 1000,
            phase_ns[phaseIndex(.end_drawing)] / 1000,
            process_count,
            slice_count,
            metadata_bytes,
            rebuilds,
            ring_events,
            cpu_samples,
            slices_scanned,
            slices_drawn,
        },
    );
    last_log_ns = 0;
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
        "session frames={d} p50={d}us p95={d}us p99={d}us max={d}us procs={d} " ++
            "slices={d} meta={d}B new_slices={d} coalesced={d}",
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
