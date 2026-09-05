//! Capture orchestration: spawns the target in its own process group, ingests
//! backend-neutral lifecycle events and cumulative self-CPU snapshots, and
//! owns the process timeline until the target exits.
//! Ownership: `Session` owns every `Process` record and the pid index;
//! `start(collector, argv, options)` borrows `argv` only for the call.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const CaptureEnvironment = @import("CaptureEnvironment.zig");
const signals = @import("signals.zig");
const Process = @import("Process.zig");
const capture = @import("capture.zig");
const process_ops = @import("process_ops.zig");
const perf = @import("../perf.zig");
const session_file = @import("../session_file.zig");
const analysis_file = @import("../analysis_file.zig");

const log = std.log.scoped(.tracer);

const Session = @This();

gpa: Allocator,
io: std.Io,
processes: std.ArrayList(Process) = .empty,
/// Reserved with each capture record so final clipping cannot fail to allocate.
/// After finalization, maps old process indices to retained indices (null when removed).
process_remap: std.ArrayList(?usize) = .empty,
metadata: Process.MetadataStore = .empty,
/// tgid → index into `processes`. Unmanaged: takes `gpa` per mutation.
by_pid: std.AutoHashMapUnmanaged(std.posix.pid_t, usize) = .empty,
child: ?std.process.Child = null,
root_pid: ?std.posix.pid_t = null,
started_at: std.Io.Timestamp = .zero,
elapsed_ns: u64 = 0,
running: bool = false,
/// True only after capture reached an orderly, writable boundary.
finished: bool = false,
root_exit: RootExit = .unknown,
active_count: usize = 0,
/// Saturating count of known kernel and userspace capture loss.
loss_count: u64 = 0,
/// Live-only baseline for the collector's cumulative loss counter.
collector_loss_seen: u64 = 0,
/// Lifecycle guarantee selected when the current target was launched.
capture_fidelity: capture.Fidelity = capture.default_fidelity,
/// Recovered parent/exec/exit stubs created because a lifecycle record was missing.
recovered_count: u64 = 0,
/// Logical CPU count on the tracing host when this target was launched.
host_cpu_count: usize = 1,
/// Cumulative CPU snapshot cadence retained with this session.
sample_period_ns: u64 = default_cpu_sample_period_ns,
/// Capture-time host and Flamez provenance.
environment: CaptureEnvironment = .{},
/// Exact launch argv stored as one NUL-separated metadata arena range.
target_argv_offset: usize = 0,
target_argv_len: usize = 0,
target_argv_count: usize = 0,
/// Session time of the last cumulative CPU map snapshot.
last_cpu_sample_ns: u64 = 0,
/// Parentage and process-record count. Exec and finish do not change this.
topology_revision: u64 = 0,
/// Lifetime end times. Packing can ignore this while capture is live.
interval_revision: u64 = 0,
/// Display names and metadata. Does not rebuild tree geometry.
label_revision: u64 = 0,

/// Documented CPU-activity temporal resolution. Snapshots run on this cadence
/// independently of render FPS. Lifecycle ring polling stays per live frame.
pub const default_cpu_sample_period_ns: u64 = 16 * std.time.ns_per_ms;

pub const RootExit = union(enum) {
    unknown,
    exited: u8,
    signaled: u8,
};

/// Destination for the launched target's standard output.
pub const TargetStdout = enum {
    inherit,
    stderr,
};

/// Per-launch process behavior independent of capture backend selection.
pub const StartOptions = struct {
    target_stdout: TargetStdout = .inherit,
};

const NameKind = Process.NameKind;
const Named = Process.Named;
const max_name_len = Process.max_name_len;
const max_path_len = Process.max_path_len;

/// Errors from `start`. `MissingTarget` means argv was empty; `StopRequested`
/// prevents a termination signal observed before launch completion from
/// becoming a live capture.
pub const StartError =
    std.process.SpawnError ||
    process_ops.ResumeError ||
    Allocator.Error ||
    capture.ArmLaunchError ||
    capture.TrackRootError ||
    error{
        MissingTarget,
        StopRequested,
    };

const ProcessSpec = struct {
    pid: std.posix.pid_t,
    named: Named,
    parent_pid: ?std.posix.pid_t = null,
    depth: u16 = 0,
    start_ns: u64 = 0,
    // Forked children copy parent argv/exe/cwd offsets. Recovered stubs must not.
    inherit_metadata: bool = true,
    origin: Process.Origin = .observed,
};

/// Initializes an empty session that will allocate through `gpa` and spawn
/// children through `io`.
pub fn init(gpa: Allocator, io: std.Io) Session {
    return .{ .gpa = gpa, .io = io };
}

/// Stops a live target, releases owned process storage, and invalidates `self`.
pub fn deinit(self: *Session) void {
    self.abort();
    self.clearProcesses();
    self.processes.deinit(self.gpa);
    self.process_remap.deinit(self.gpa);
    self.metadata.deinit(self.gpa);
    self.by_pid.deinit(self.gpa);
    self.* = undefined;
}

/// Spawns `argv[0]` in its own process group and begins capturing.
/// `argv` is borrowed only for the duration of the call; process records
/// own their copies. Fails with `error.MissingTarget` on an empty argv;
/// spawn and allocator errors propagate unchanged. A previous session on
/// `self` is stopped first.
pub fn start(
    self: *Session,
    collector: *capture.Collector,
    argv: []const []const u8,
    options: StartOptions,
) StartError!void {
    if (argv.len == 0 or argv[0].len == 0) return error.MissingTarget;
    if (self.running) self.stop(collector);
    if (signals.stopRequested()) return error.StopRequested;
    self.clearProcesses();
    self.metadata.clearRetainingCapacity();
    self.by_pid.clearRetainingCapacity();
    self.elapsed_ns = 0;
    self.finished = false;
    self.root_exit = .unknown;
    self.active_count = 0;
    self.loss_count = 0;
    self.collector_loss_seen = 0;
    self.recovered_count = 0;
    self.host_cpu_count = @max(std.Thread.getCpuCount() catch 1, 1);
    self.sample_period_ns = default_cpu_sample_period_ns;
    self.environment = CaptureEnvironment.capture(self.io);
    self.target_argv_offset = 0;
    self.target_argv_len = 0;
    self.target_argv_count = 0;
    self.last_cpu_sample_ns = 0;
    self.topology_revision +%= 1;
    self.interval_revision +%= 1;
    self.label_revision +%= 1;
    signals.clearTrackedPids();
    try self.processes.ensureUnusedCapacity(self.gpa, 1);
    try self.by_pid.ensureUnusedCapacity(self.gpa, 1);

    self.started_at = std.Io.Clock.awake.now(self.io);
    const launcher_pid = process_ops.currentPid();
    try collector.armLaunch(launcher_pid);
    self.capture_fidelity = collector.fidelity();
    self.collector_loss_seen = collector.lost_events;
    defer collector.untrack(launcher_pid);
    if (signals.stopRequested()) return error.StopRequested;

    var child = try process_ops.spawnTarget(self.gpa, self.io, argv, .{
        .target_stdout = switch (options.target_stdout) {
            .inherit => .inherit,
            .stderr => .stderr,
        },
    });
    errdefer child.kill(self.io);

    const pid = child.id.?;
    errdefer collector.untrack(pid);
    // Arm the signal-handler escape hatch immediately: if flamez is killed
    // from here on (Ctrl+C, closed terminal, ...), the handler tears down
    // the target group instead of orphaning it.
    signals.armTargetGroup(pid);
    errdefer {
        signals.terminateTargetGroup(pid);
        signals.disarmTargetGroup();
        signals.clearTrackedPids();
    }
    if (signals.stopRequested()) return error.StopRequested;
    var comm_buf: [max_name_len]u8 = undefined;
    const root_index = try self.addProcess(.{
        .pid = pid,
        .named = Session.rootLabel(pid, argv[0], &comm_buf),
    });
    try self.processes.items[root_index].setArgsFromArgv(&self.metadata, self.gpa, argv);
    const root = self.processes.items[root_index];
    self.target_argv_offset = root.args_offset;
    self.target_argv_len = root.args_len;
    self.target_argv_count = root.args_count;
    try self.refreshCwd(root_index);
    try collector.trackRoot(pid);
    if (signals.stopRequested()) return error.StopRequested;
    try process_ops.resumeTarget(pid);
    self.child = child;
    self.root_pid = pid;
    self.running = true;
    errdefer {
        self.finishOpenProcesses(0);
        self.child = null;
        self.root_pid = null;
        self.running = false;
    }
}

/// Closes capture before terminating and reaping a live target.
/// Calling this on an idle session is harmless.
pub fn stop(self: *Session, collector: *capture.Collector) void {
    if (!self.running) return;
    defer {
        signals.disarmTargetGroup();
        signals.clearTrackedPids();
    }
    // Freeze observations before our signals generate exit events. Those exits
    // belong to teardown; live records retain partial CPU and a clipped lifetime.
    collector.flushEvents(self.captureSink());
    collector.snapshotCpu(self.captureSink());
    self.mergeCollectorLoss(collector.lost_events);
    const boundary_ns = self.observedRootEndNs() orelse self.nowElapsedNs();
    const pgid = signals.armedTargetPgid();
    signals.termTargetTree(pgid);
    // `Child.kill` sends TERM and then waits without a timeout. Sweep the
    // entire tree with KILL first so a target that ignores TERM or was stopped
    // by terminal job control cannot block the UI before the force-kill phase.
    signals.killTargetTree(pgid);
    if (self.child) |*child| {
        if (child.id != null) {
            if (child.wait(self.io)) |term| {
                self.recordRootTerm(term);
            } else |err| {
                @branchHint(.cold);
                if (comptime !builtin.is_test) {
                    log.warn("could not reap target root: {s}", .{@errorName(err)});
                }
                child.kill(self.io);
            }
        }
    }
    self.elapsed_ns = boundary_ns;
    self.last_cpu_sample_ns = boundary_ns;
    self.onRootExited(null);
}

fn abort(self: *Session) void {
    defer {
        signals.disarmTargetGroup();
        signals.clearTrackedPids();
    }
    const pgid = signals.armedTargetPgid();
    signals.termTargetTree(pgid);
    signals.killTargetTree(pgid);
    if (self.child) |*child| child.kill(self.io);
    self.child = null;
    self.root_pid = null;
    self.running = false;
    self.finished = false;
}

/// Drains capture events into the process tree, advances the clock, and
/// non-blockingly checks for target exit. Capture ends with the target;
/// descendants still running at that point are closed at the same timestamp.
/// Cumulative CPU maps are snapshotted on `sample_period_ns`, not the
/// render frame rate.
pub fn update(self: *Session, collector: *capture.Collector) void {
    if (!self.running) return;

    self.elapsed_ns = self.nowElapsedNs();
    perf.enter(.ring_poll);
    collector.pollEvents(self.captureSink());
    self.mergeCollectorLoss(collector.lost_events);
    self.elapsed_ns = self.nowElapsedNs();
    const due = self.last_cpu_sample_ns == 0 or
        self.elapsed_ns -| self.last_cpu_sample_ns >= self.sample_period_ns;
    if (due) {
        perf.enter(.cpu_snapshot);
        collector.snapshotCpu(self.captureSink());
        self.mergeCollectorLoss(collector.lost_events);
        self.last_cpu_sample_ns = self.elapsed_ns;
    }
    perf.leave();
    self.pollSession(collector);
}

fn captureSink(self: *Session) capture.Sink {
    return .{
        .ptr = self,
        .event_fn = consumeCaptureEvent,
        .cpu_sample_fn = consumeCaptureCpuSample,
    };
}

fn consumeCaptureEvent(ptr: *anyopaque, event: capture.Event) void {
    const self: *Session = @ptrCast(@alignCast(ptr));
    self.consumeEvent(event);
}

fn consumeCaptureCpuSample(
    ptr: *anyopaque,
    pid: std.posix.pid_t,
    total_ns: u64,
    timestamp_ns: u64,
) void {
    const self: *Session = @ptrCast(@alignCast(ptr));
    self.consumeCpuSnapshot(pid, total_ns, timestamp_ns);
}

fn clearProcesses(self: *Session) void {
    for (self.processes.items) |*process| process.deinit(self.gpa);
    self.processes.clearRetainingCapacity();
    self.process_remap.clearRetainingCapacity();
}

/// Counts process records whose lifetime remains open.
pub fn activeCount(self: *const Session) usize {
    return self.active_count;
}

/// Borrowed backing bytes for every process's compact metadata offsets.
pub fn metadataBytes(self: *const Session) []const u8 {
    return self.metadata.items;
}

/// Iterates the exact argv passed to `start`; returned slices borrow `metadata`.
pub fn targetArgvIter(self: *const Session) Process.ArgIter {
    if (self.target_argv_offset > self.metadata.items.len or
        self.target_argv_len > self.metadata.items.len - self.target_argv_offset)
    {
        return .{ .bytes = "", .remaining = 0 };
    }
    return .{
        .bytes = self.metadata.items[self.target_argv_offset..][0..self.target_argv_len],
        .remaining = self.target_argv_count,
    };
}

/// Returns whether known loss or inferred process records make capture incomplete.
pub fn isIncomplete(self: *const Session) bool {
    return self.loss_count != 0 or self.recovered_count != 0;
}

/// Domain of the flamegraph: elapsed target runtime.
pub fn timelineNs(self: *const Session) u64 {
    return self.elapsed_ns;
}

fn nowElapsedNs(self: *const Session) u64 {
    const now = std.Io.Clock.awake.now(self.io);
    const delta = self.started_at.durationTo(now).nanoseconds;
    return if (delta <= 0) 0 else @intCast(delta);
}

fn addProcess(self: *Session, spec: ProcessSpec) !usize {
    if (self.liveIndex(spec.pid)) |index| return index;
    try self.by_pid.ensureUnusedCapacity(self.gpa, 1);
    try self.processes.ensureUnusedCapacity(self.gpa, 1);
    try self.process_remap.ensureTotalCapacity(self.gpa, self.processes.items.len + 1);

    const index = self.processes.items.len;
    var process = Process{
        .pid = spec.pid,
        .parent_pid = spec.parent_pid,
        .depth = spec.depth,
        .start_ns = spec.start_ns,
        .exec_start_ns = spec.start_ns,
        .origin = spec.origin,
    };
    var named = spec.named;
    if (spec.parent_pid) |parent_pid| {
        if (self.by_pid.get(parent_pid) orelse
            (if (self.root_pid == parent_pid) self.rootIndex() else null)) |parent_index|
        {
            process.parent_index = parent_index;
            if (spec.inherit_metadata) {
                const parent = &self.processes.items[parent_index];
                process.inheritMetadata(parent);
                if (parent.origin != .recovered_parent) {
                    named = .{ .text = parent.nameSlice(), .kind = parent.name_kind };
                }
            }
        }
    }
    process.setName(named.text, named.kind);
    process.signal_slot = signals.rememberPid(spec.pid);
    if (process.signal_slot == null and comptime !builtin.is_test) {
        log.warn("teardown pid table is full; pid {d} may survive Stop/Ctrl+C", .{spec.pid});
    }
    self.processes.appendAssumeCapacity(process);
    self.by_pid.putAssumeCapacity(spec.pid, index);
    self.active_count += 1;
    self.topology_revision +%= 1;
    return index;
}

fn finishProcess(self: *Session, index: usize, at_ns: u64, kind: Process.EndKind) void {
    const process = &self.processes.items[index];
    if (!process.finish(at_ns, kind)) return;
    signals.forgetPid(process.signal_slot, process.pid);
    process.signal_slot = null;
    self.active_count -|= 1;
    if (self.by_pid.get(process.pid) == index) {
        _ = self.by_pid.remove(process.pid);
    }
    self.interval_revision +%= 1;
}

fn refreshCwd(self: *Session, index: usize) Allocator.Error!void {
    const pid = self.processes.items[index].pid;
    var buf: [max_path_len + 1]u8 = undefined;
    if (process_ops.readCwd(pid, &buf)) |cwd| {
        switch (process_ops.args_source) {
            .procfs => try self.processes.items[index].setCwd(&self.metadata, self.gpa, cwd),
            .process_inspection => try self.processes.items[index].setCwdFromProcessInspection(
                &self.metadata,
                self.gpa,
                cwd,
            ),
            else => comptime unreachable,
        }
    }
}

fn captureMissingMetadata(self: *Session, index: usize) Allocator.Error!void {
    const pid = self.processes.items[index].pid;
    if (self.processes.items[index].args_len == 0) {
        if (try process_ops.readArgs(self.gpa, pid)) |cmdline| {
            var owned = cmdline;
            defer owned.deinit(self.gpa);
            switch (process_ops.args_source) {
                .procfs => try self.processes.items[index].setArgsFromCmdline(
                    &self.metadata,
                    self.gpa,
                    owned.items,
                ),
                .process_inspection => try self.processes.items[index].setArgsFromProcessInspection(
                    &self.metadata,
                    self.gpa,
                    owned.items,
                ),
                else => comptime unreachable,
            }
        }
    }
    var path_buf: [max_path_len + 1]u8 = undefined;
    if (self.processes.items[index].exe_len == 0) {
        if (process_ops.readExecutable(pid, &path_buf)) |exe| {
            switch (process_ops.args_source) {
                .procfs => try self.processes.items[index].setExe(
                    &self.metadata,
                    self.gpa,
                    exe,
                ),
                .process_inspection => try self.processes.items[index].setExeFromProcessInspection(
                    &self.metadata,
                    self.gpa,
                    exe,
                ),
                else => comptime unreachable,
            }
        }
    }
    if (self.processes.items[index].cwd_len == 0) {
        if (process_ops.readCwd(pid, &path_buf)) |cwd| {
            switch (process_ops.args_source) {
                .procfs => try self.processes.items[index].setCwd(
                    &self.metadata,
                    self.gpa,
                    cwd,
                ),
                .process_inspection => try self.processes.items[index].setCwdFromProcessInspection(
                    &self.metadata,
                    self.gpa,
                    cwd,
                ),
                else => comptime unreachable,
            }
        }
    }
}

fn rootLabel(pid: std.posix.pid_t, argv0: []const u8, comm_buf: *[max_name_len]u8) Named {
    const argv_name = std.fs.path.basename(argv0);
    if (process_ops.readName(pid, comm_buf)) |comm| {
        if (std.mem.eql(u8, argv_name, comm)) return .fromComm(comm);
    }
    return .fromOther(argv_name);
}

fn recordRootStatus(self: *Session, status: u32) void {
    if (process_ops.exitCode(status)) |code| {
        self.root_exit = .{ .exited = code };
    } else if (process_ops.exitSignal(status)) |signal| {
        self.root_exit = .{ .signaled = signal };
        // The UI shows STOPPED · SIGNAL n; the log keeps the detail.
        // Suppressed in test binaries: their stderr garbles `zig build`
        // IPC progress output even when every test passes.
        if (comptime !builtin.is_test) {
            log.warn("target root terminated by signal {d}", .{
                signal,
            });
        }
    } else {
        self.root_exit = .unknown;
    }
}

fn recordRootTerm(self: *Session, term: std.process.Child.Term) void {
    self.root_exit = switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |signal| root_exit: {
            const number = std.math.cast(u8, @intFromEnum(signal)) orelse
                break :root_exit .unknown;
            break :root_exit .{ .signaled = number };
        },
        .stopped, .unknown => .unknown,
    };
}

fn onRootExited(self: *Session, status: ?u32) void {
    if (status) |s| self.recordRootStatus(s);
    if (self.child) |*child| child.id = null;
    self.child = null;
    self.clipToBoundary(self.elapsed_ns);
    self.root_pid = null;
    self.running = false;
    self.rebuildDerivedCaches();
    self.finished = true;
    signals.disarmTargetGroup();
    signals.clearTrackedPids();
    self.compactMetadata() catch {};
}

fn pollSession(self: *Session, collector: *capture.Collector) void {
    const child = if (self.child) |*child| child else return;
    const pid = child.id orelse return;
    switch (process_ops.waitNowait(pid)) {
        .still_running, .interrupted => {},
        .reaped => |status| {
            self.finishRootCapture(collector, status);
            return;
        },
        .no_child => {
            // ECHILD while the pid still exists means we do not own it (or a
            // race), so wait for an observable exit before ending capture.
            if (!signals.pidAlive(pid)) {
                self.finishRootCapture(collector, null);
                return;
            }
        },
    }
}

fn finishRootCapture(
    self: *Session,
    collector: *capture.Collector,
    status: ?u32,
) void {
    // The exit is already enqueued by both kernels, but delivery can race the
    // ordinary poll at the start of this update. Flush that boundary before
    // closing open intervals, then sample descendants that remain alive at
    // the capture boundary one final time.
    collector.flushEvents(self.captureSink());
    self.elapsed_ns = self.nowElapsedNs();
    const boundary_ns = self.observedRootEndNs() orelse self.elapsed_ns;
    collector.snapshotCpu(self.captureSink());
    self.elapsed_ns = boundary_ns;
    self.last_cpu_sample_ns = boundary_ns;
    self.mergeCollectorLoss(collector.lost_events);
    self.onRootExited(status);
}

fn observedRootEndNs(self: *const Session) ?u64 {
    if (self.processes.items.len == 0) return null;
    const root = self.processes.items[0];
    if (root.end_kind != .observed_exit) return null;
    return root.end_ns;
}

fn finishOpenProcesses(self: *Session, at_ns: u64) void {
    for (self.processes.items, 0..) |process, index| {
        if (process.end_ns == null) self.finishProcess(index, at_ns, .capture_clipped);
    }
}

fn clipToBoundary(self: *Session, at_ns: u64) void {
    const processes = self.processes.items;
    std.debug.assert(self.process_remap.capacity >= processes.len);
    self.process_remap.items.len = processes.len;
    var retained: usize = 0;
    for (processes, 0..) |*process, index| {
        signals.forgetPid(process.signal_slot, process.pid);
        process.signal_slot = null;
        if (process.start_ns > at_ns) {
            process.deinit(self.gpa);
            self.process_remap.items[index] = null;
            continue;
        }
        self.process_remap.items[index] = retained;
        process.clipToCapture(at_ns);
        if (process.parent_index) |parent| {
            process.parent_index = self.process_remap.items[parent].?;
        }
        processes[retained] = process.*;
        retained += 1;
    }
    self.processes.items.len = retained;
    self.by_pid.clearRetainingCapacity();
    self.active_count = 0;
    if (retained == processes.len) self.process_remap.clearRetainingCapacity();
    self.topology_revision +%= 1;
    self.interval_revision +%= 1;
    self.label_revision +%= 1;
}

/// Latest record for `pid`, including finished generations. `by_pid` is live-only.
pub fn latestIndex(self: *const Session, pid: std.posix.pid_t) ?usize {
    var i = self.processes.items.len;
    while (i > 0) {
        i -= 1;
        if (self.processes.items[i].pid == pid) return i;
    }
    return null;
}

fn noteRecovery(self: *Session) void {
    self.recovered_count +|= 1;
}

fn noteLoss(self: *Session) void {
    self.loss_count +|= 1;
}

fn mergeCollectorLoss(self: *Session, current: u64) void {
    if (current >= self.collector_loss_seen) {
        self.loss_count +|= current - self.collector_loss_seen;
    }
    self.collector_loss_seen = current;
}

/// Rebuilds topology, recovery, and CPU caches from canonical session fields.
pub fn rebuildDerivedCaches(self: *Session) void {
    self.recovered_count = 0;
    for (self.processes.items, 0..) |*process, index| {
        if (process.origin != .observed) self.recovered_count +|= 1;
        if (process.parent_index) |parent_index| {
            std.debug.assert(parent_index < index);
            const parent = self.processes.items[parent_index];
            process.parent_pid = parent.pid;
            process.depth = parent.depth + 1;
        } else {
            process.parent_pid = null;
            process.depth = 0;
        }
        process.rebuildCpuCaches();
    }
}

/// Rebuilds the append-only metadata arena so only bytes still referenced by
/// process records remain. Intended for capture completion, not the live path.
fn compactMetadata(self: *Session) Allocator.Error!void {
    var next: Process.MetadataStore = .empty;
    errdefer next.deinit(self.gpa);
    try next.ensureTotalCapacity(self.gpa, self.metadata.items.len);

    var remap: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    defer remap.deinit(self.gpa);
    var metadata_exec_count: usize = 0;
    for (self.processes.items) |process| {
        const retained_count = std.math.add(usize, process.execs.items.len, 1) catch
            return error.OutOfMemory;
        metadata_exec_count = std.math.add(
            usize,
            metadata_exec_count,
            retained_count,
        ) catch return error.OutOfMemory;
    }
    const metadata_range_count = std.math.add(usize, metadata_exec_count, 1) catch
        return error.OutOfMemory;
    const remap_capacity_usize = std.math.mul(usize, metadata_range_count, 3) catch
        return error.OutOfMemory;
    const remap_capacity = std.math.cast(u32, remap_capacity_usize) orelse
        return error.OutOfMemory;
    try remap.ensureTotalCapacity(self.gpa, remap_capacity);

    // Reserve both destinations before rewriting offsets so OOM leaves the session untouched.
    remapMetadata(
        &next,
        &remap,
        self.metadata.items,
        &self.target_argv_offset,
        self.target_argv_len,
    );
    for (self.processes.items) |*process| {
        for (process.execs.items) |*exec| {
            remapMetadata(
                &next,
                &remap,
                self.metadata.items,
                &exec.args_offset,
                exec.args_len,
            );
            remapMetadata(
                &next,
                &remap,
                self.metadata.items,
                &exec.exe_offset,
                exec.exe_len,
            );
            remapMetadata(
                &next,
                &remap,
                self.metadata.items,
                &exec.cwd_offset,
                exec.cwd_len,
            );
        }
        remapMetadata(
            &next,
            &remap,
            self.metadata.items,
            &process.args_offset,
            process.args_len,
        );
        remapMetadata(
            &next,
            &remap,
            self.metadata.items,
            &process.exe_offset,
            process.exe_len,
        );
        remapMetadata(
            &next,
            &remap,
            self.metadata.items,
            &process.cwd_offset,
            process.cwd_len,
        );
    }

    self.metadata.deinit(self.gpa);
    self.metadata = next;
}

fn remapMetadata(
    dest: *Process.MetadataStore,
    remap: *std.AutoHashMapUnmanaged(usize, usize),
    src: []const u8,
    offset: *usize,
    len: usize,
) void {
    if (len == 0) return;
    if (remap.get(offset.*)) |copied| {
        offset.* = copied;
        return;
    }
    const old = offset.*;
    if (old >= src.len or len > src.len - old) {
        offset.* = 0;
        return;
    }
    const copied = dest.items.len;
    std.debug.assert(len <= dest.capacity - dest.items.len);
    dest.appendSliceAssumeCapacity(src[old..][0..len]);
    remap.putAssumeCapacity(old, copied);
    offset.* = copied;
}

fn rootIndex(self: *const Session) ?usize {
    return if (self.root_pid) |pid| self.by_pid.get(pid) orelse self.latestIndex(pid) else null;
}

fn liveIndex(self: *const Session, pid: std.posix.pid_t) ?usize {
    const index = self.by_pid.get(pid) orelse return null;
    if (self.processes.items[index].end_ns != null) return null;
    return index;
}

fn eventElapsedNs(self: *const Session, timestamp_ns: u64) u64 {
    if (timestamp_ns >= @as(u64, @intCast(self.started_at.nanoseconds)))
        return timestamp_ns - @as(u64, @intCast(self.started_at.nanoseconds));
    return self.elapsed_ns;
}

// Lost fork of the parent: stub under the root so this child (and a later
// exec of the parent) still have a node to attach to.
fn ensureParent(self: *Session, parent_pid: std.posix.pid_t, at_ns: u64) ?usize {
    if (self.liveIndex(parent_pid)) |index| return index;
    const root_index = self.rootIndex() orelse return null;
    if (parent_pid == self.root_pid) return root_index;
    const stub = self.addProcess(.{
        .pid = parent_pid,
        .parent_pid = self.root_pid,
        .named = .fromOther("process"),
        .depth = self.processes.items[root_index].depth + 1,
        .start_ns = at_ns,
        .inherit_metadata = false,
        .origin = .recovered_parent,
    }) catch |err| {
        @branchHint(.cold);
        self.noteLoss();
        if (comptime !builtin.is_test) {
            log.warn("could not recover missing parent pid {d}: {s}", .{
                parent_pid,
                @errorName(err),
            });
        }
        return null;
    };
    if (comptime !builtin.is_test) {
        log.warn("recovered missing parent pid {d} under the session root", .{parent_pid});
    }
    self.noteRecovery();
    return stub;
}

// Lost fork of this pid: create it under the root and let applyExec fill
// kernel metadata.
fn recoverFromExec(
    self: *Session,
    pid: std.posix.pid_t,
    name: []const u8,
    at_ns: u64,
) ?usize {
    const parent_index = self.rootIndex();
    const named: Named = if (name.len > 0) .fromComm(name) else .fromOther("process");
    const index = self.addProcess(.{
        .pid = pid,
        .parent_pid = self.root_pid,
        .named = named,
        .depth = if (parent_index) |parent| self.processes.items[parent].depth + 1 else 0,
        .start_ns = at_ns,
        .inherit_metadata = false,
        .origin = .recovered_exec,
    }) catch |err| {
        @branchHint(.cold);
        self.noteLoss();
        if (comptime !builtin.is_test) {
            log.warn("could not recover pid {d} from exec: {s}", .{ pid, @errorName(err) });
        }
        return null;
    };
    if (comptime !builtin.is_test) {
        log.warn("recovered pid {d} from exec without a fork event", .{pid});
    }
    self.noteRecovery();
    return index;
}

// Lost fork of a process that never exec'd: keep a zero-width bar at death
// so the tgid is not invisible. Duplicate exits of a known pid are ignored.
fn recoverFromExit(
    self: *Session,
    pid: std.posix.pid_t,
    name: []const u8,
    at_ns: u64,
) ?usize {
    if (self.liveIndex(pid) != null) return null;
    if (self.latestIndex(pid)) |index| {
        if (self.processes.items[index].end_ns == at_ns) return null;
    }
    const parent_index = self.rootIndex();
    const named: Named = if (name.len > 0) .fromComm(name) else .fromOther("process");
    const index = self.addProcess(.{
        .pid = pid,
        .parent_pid = self.root_pid,
        .named = named,
        .depth = if (parent_index) |parent| self.processes.items[parent].depth + 1 else 0,
        .start_ns = at_ns,
        .inherit_metadata = false,
        .origin = .recovered_exit,
    }) catch |err| {
        @branchHint(.cold);
        self.noteLoss();
        if (comptime !builtin.is_test) {
            log.warn("could not recover pid {d} from exit: {s}", .{ pid, @errorName(err) });
        }
        return null;
    };
    if (comptime !builtin.is_test) {
        log.warn("recovered pid {d} from exit without a fork event", .{pid});
    }
    self.noteRecovery();
    return index;
}

fn applyExec(
    self: *Session,
    index: usize,
    event: capture.Event.Exec,
    at_ns: u64,
    initial_observation: bool,
) void {
    const process = &self.processes.items[index];
    const coalesce_launch = process.execs.items.len == 0 and
        process.args_source == .launch;
    if (coalesce_launch) {
        process.retainCurrentExecForRow(self.gpa) catch |err| {
            @branchHint(.cold);
            self.noteLoss();
            log.warn("could not retain the original row command: {s}", .{@errorName(err)});
        };
    } else if (!initial_observation) {
        process.archiveCurrentExec(self.gpa, at_ns) catch |err| {
            @branchHint(.cold);
            self.noteLoss();
            log.warn("could not retain exec history: {s}", .{@errorName(err)});
        };
    }
    if (event.name.len > 0) {
        process.setName(event.name, .process);
    } else if (!event.inspect_missing) {
        process.setName("process", .other);
    }
    process.clearExecMetadata();
    self.label_revision +%= 1;
    if (event.exe) |exe| {
        (switch (event.metadata_source) {
            .kernel => self.processes.items[index].setExeFromKernel(
                &self.metadata,
                self.gpa,
                exe,
                event.exe_truncated,
            ),
            .process_inspection => self.processes.items[index].setExeFromProcessInspection(
                &self.metadata,
                self.gpa,
                exe,
            ),
        }) catch |err| {
            @branchHint(.cold);
            self.noteLoss();
            log.warn("could not store executable metadata: {s}", .{@errorName(err)});
        };
    }
    if (event.args) |args| {
        (switch (event.metadata_source) {
            .kernel => self.processes.items[index].setArgsFromKernel(
                &self.metadata,
                self.gpa,
                args,
            ),
            .process_inspection => self.processes.items[index].setArgsFromProcessInspection(
                &self.metadata,
                self.gpa,
                args,
            ),
        }) catch |err| {
            @branchHint(.cold);
            self.noteLoss();
            log.warn("could not store argv metadata: {s}", .{@errorName(err)});
        };
    }
    if (event.cwd) |cwd| {
        (switch (event.metadata_source) {
            .kernel => self.processes.items[index].setCwdFromKernel(
                &self.metadata,
                self.gpa,
                cwd,
                event.cwd_truncated,
            ),
            .process_inspection => self.processes.items[index].setCwdFromProcessInspection(
                &self.metadata,
                self.gpa,
                cwd,
            ),
        }) catch |err| {
            @branchHint(.cold);
            self.noteLoss();
            log.warn("could not store working-directory metadata: {s}", .{@errorName(err)});
        };
    } else if (event.inspect_missing) {
        // A child may chdir between fork and exec. Refresh when platform
        // metadata is available, retaining the fork snapshot if it is not.
        self.refreshCwd(index) catch self.noteLoss();
    }
    if (event.inspect_missing) {
        self.captureMissingMetadata(index) catch |err| {
            @branchHint(.cold);
            self.noteLoss();
            log.warn("could not store process metadata: {s}", .{@errorName(err)});
        };
    }
}

/// Folds one capture event into the process tree. The event is borrowed only
/// for this call. A live tgid is updated in place; a finished tgid that
/// reappears becomes a new record. A fork whose parent is missing, an exec
/// whose pid is missing, or an exit whose pid was never seen, is recovered
/// under the session root so a lost backend record cannot hide that
/// subtree.
pub fn consumeEvent(self: *Session, event: capture.Event) void {
    perf.noteSnapshot(0, 1);
    if (!self.running) return;
    const event_ns = self.eventElapsedNs(event.timestamp_ns);

    switch (event.payload) {
        .fork => |fork| {
            const parent_index = self.ensureParent(fork.parent_pid, event_ns) orelse return;
            _ = self.addProcess(.{
                .pid = fork.pid,
                .parent_pid = fork.parent_pid,
                .named = .fromComm(fork.name),
                .depth = self.processes.items[parent_index].depth + 1,
                .start_ns = event_ns,
            }) catch |err| {
                @branchHint(.cold);
                self.noteLoss();
                log.warn(
                    "dropped process record for pid {d}: {s}",
                    .{ fork.pid, @errorName(err) },
                );
                return;
            };
        },
        .exec => |exec| {
            if (self.liveIndex(exec.pid)) |index| {
                self.applyExec(index, exec, event_ns, false);
            } else {
                const index = self.recoverFromExec(exec.pid, exec.name, event_ns) orelse return;
                self.applyExec(index, exec, event_ns, true);
            }
        },
        .exit => |exit| {
            const index = self.liveIndex(exit.pid) orelse
                self.recoverFromExit(exit.pid, exit.name, event_ns) orelse return;
            const process = &self.processes.items[index];
            const stored_cpu = stored_cpu: {
                if (exit.cpu_final) {
                    process.recordFinalCpuSnapshot(self.gpa, event_ns, exit.cpu_ns) catch |err| {
                        @branchHint(.cold);
                        self.noteLoss();
                        log.warn("could not store final CPU slice for pid {d}: {s}", .{
                            exit.pid,
                            @errorName(err),
                        });
                        break :stored_cpu false;
                    };
                } else {
                    process.recordCpuSnapshot(self.gpa, event_ns, exit.cpu_ns) catch |err| {
                        @branchHint(.cold);
                        self.noteLoss();
                        log.warn("could not store partial exit CPU slice for pid {d}: {s}", .{
                            exit.pid,
                            @errorName(err),
                        });
                        break :stored_cpu false;
                    };
                }
                break :stored_cpu true;
            };
            if (stored_cpu) process.cpu_final = exit.cpu_final;
            self.finishProcess(index, event_ns, .observed_exit);
        },
    }
}

/// Records one cumulative process self-CPU snapshot from the capture backend.
/// Unknown and already-finished TGIDs are ignored; a later lifecycle event can
/// still recover them without attributing CPU to the wrong PID generation.
pub fn consumeCpuSnapshot(
    self: *Session,
    pid: std.posix.pid_t,
    cpu_ns: u64,
    timestamp_ns: u64,
) void {
    perf.noteSnapshot(1, 0);
    if (!self.running) return;
    const index = self.liveIndex(pid) orelse return;
    const observed_ns = self.eventElapsedNs(timestamp_ns);
    self.processes.items[index].recordCpuSnapshot(
        self.gpa,
        observed_ns,
        cpu_ns,
    ) catch |err| {
        @branchHint(.cold);
        self.noteLoss();
        log.warn("could not store CPU slice for pid {d}: {s}", .{ pid, @errorName(err) });
    };
}

fn forkEvent(
    pid: std.posix.pid_t,
    parent_pid: std.posix.pid_t,
    timestamp_ns: u64,
    name: []const u8,
) capture.Event {
    return .{
        .timestamp_ns = timestamp_ns,
        .payload = .{ .fork = .{
            .pid = pid,
            .parent_pid = parent_pid,
            .name = name,
        } },
    };
}

fn execEvent(
    pid: std.posix.pid_t,
    timestamp_ns: u64,
    name: []const u8,
    exe: ?[]const u8,
    args: ?[]const u8,
) capture.Event {
    return .{
        .timestamp_ns = timestamp_ns,
        .payload = .{ .exec = .{
            .pid = pid,
            .name = name,
            .exe = exe,
            .args = args,
        } },
    };
}

fn exitEvent(
    pid: std.posix.pid_t,
    timestamp_ns: u64,
    name: []const u8,
    cpu_ns: u64,
) capture.Event {
    return .{
        .timestamp_ns = timestamp_ns,
        .payload = .{ .exit = .{
            .pid = pid,
            .name = name,
            .cpu_ns = cpu_ns,
        } },
    };
}

const held_target_argv = &.{
    "sh",
    "-c",
    "kill -STOP $$",
};

// Block before fork so a release sent immediately after admission stays pending
// until sigwait; checking a Python flag before signal.pause can miss that wakeup.
const fork_gate_script =
    \\import os,signal,sys
    \\release = {signal.SIGUSR1}
    \\signal.pthread_sigmask(signal.SIG_BLOCK, release)
    \\children = []
    \\for _ in range(int(sys.argv[1])):
    \\    child = os.fork()
    \\    if child == 0:
    \\        signal.sigwait(release)
    \\        os._exit(0)
    \\    children.append(child)
    \\signal.sigwait(release)
    \\for child in children: os.kill(child, signal.SIGUSR1)
    \\for child in children: os.waitpid(child, 0)
;

const escaped_gate_script =
    \\import os,signal
    \\release = {signal.SIGUSR1}
    \\signal.pthread_sigmask(signal.SIG_BLOCK, release)
    \\child = os.fork()
    \\if child == 0:
    \\    os.setsid()
    \\    signal.pause()
    \\    os._exit(0)
    \\signal.sigwait(release)
;

fn updateUntilStopped(session: *Session, collector: *capture.Collector) !void {
    const started = std.Io.Clock.awake.now(session.io);
    while (session.running) {
        session.update(collector);
        if (!session.running) return;
        if (started.durationTo(std.Io.Clock.awake.now(session.io)).nanoseconds >=
            10 * std.time.ns_per_s) return error.TestUnexpectedResult;
        try std.Thread.yield();
    }
}

fn updateUntilProcessCount(
    session: *Session,
    collector: *capture.Collector,
    process_count: usize,
) !void {
    const started = std.Io.Clock.awake.now(session.io);
    while (session.processes.items.len < process_count) {
        if (!session.running) return error.TestUnexpectedResult;
        session.update(collector);
        if (started.durationTo(std.Io.Clock.awake.now(session.io)).nanoseconds >=
            10 * std.time.ns_per_s) return error.TestUnexpectedResult;
        try std.Thread.yield();
    }
}

fn waitForFile(dir: std.Io.Dir, io: std.Io, sub_path: []const u8) !void {
    const started = std.Io.Clock.awake.now(io);
    while (true) {
        var file = dir.openFile(io, sub_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds >=
                    5 * std.time.ns_per_s) return error.TestUnexpectedResult;
                try std.Thread.yield();
                continue;
            },
            else => return err,
        };
        file.close(io);
        return;
    }
}

fn waitForProcessExit(pid: std.posix.pid_t, io: std.Io) !void {
    const started = std.Io.Clock.awake.now(io);
    while (process_ops.pidAlive(pid)) {
        if (started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds >=
            5 * std.time.ns_per_s) return error.TestUnexpectedResult;
        try std.Thread.yield();
    }
}

test "loss count merges collector deltas without overwriting userspace loss" {
    const testing = std.testing;
    var session = Session.init(testing.allocator, testing.io);
    defer session.deinit();

    session.collector_loss_seen = 5;
    session.mergeCollectorLoss(8);
    try testing.expectEqual(@as(u64, 3), session.loss_count);
    session.noteLoss();
    session.mergeCollectorLoss(10);
    try testing.expectEqual(@as(u64, 6), session.loss_count);
    try testing.expect(session.isIncomplete());

    session.mergeCollectorLoss(2);
    try testing.expectEqual(@as(u64, 6), session.loss_count);
    session.mergeCollectorLoss(5);
    try testing.expectEqual(@as(u64, 9), session.loss_count);

    session.loss_count = std.math.maxInt(u64);
    session.noteLoss();
    try testing.expectEqual(std.math.maxInt(u64), session.loss_count);
}

test "terminateTargetGroup tears down the whole spawned group" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var ready_path_buffer: [128]u8 = undefined;
    const ready_path = try std.fmt.bufPrint(
        &ready_path_buffer,
        ".zig-cache/tmp/{s}/ready",
        .{temporary.sub_path[0..]},
    );
    var collector = capture.Collector{}; // Default collector does not load the kernel backend.
    var session = Session.init(testing.allocator, testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "sh",
        "-c",
        "sh -c 'kill -STOP $$' & sh -c 'kill -STOP $$' & : > \"$1\"; " ++
            "kill -STOP $$; wait",
        "sh",
        ready_path,
    }, .{});
    const root_pid = session.root_pid.?;

    try waitForFile(temporary.dir, testing.io, "ready");
    try testing.expectEqual(root_pid, signals.armedTargetPgid());

    signals.terminateTargetGroup(root_pid);
    try updateUntilStopped(&session, &collector);
    try testing.expectEqual(@as(std.posix.pid_t, 0), signals.armedTargetPgid());
    try testing.expectEqual(@as(usize, 0), session.activeCount());
}

test "stop reaps a job-control-stopped target" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var ready_path_buffer: [128]u8 = undefined;
    const ready_path = try std.fmt.bufPrint(
        &ready_path_buffer,
        ".zig-cache/tmp/{s}/ready",
        .{temporary.sub_path[0..]},
    );
    var collector = capture.Collector{};
    var session = Session.init(testing.allocator, testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "sh",
        "-c",
        "trap '' TERM; : > \"$1\"; kill -STOP $$",
        "sh",
        ready_path,
    }, .{});

    try waitForFile(temporary.dir, testing.io, "ready");
    session.stop(&collector);

    try testing.expect(!session.running);
    try testing.expect(session.finished);
    try testing.expect(session.child == null);
    try testing.expectEqual(@as(usize, 0), session.activeCount());
    try testing.expectEqual(@as(std.posix.pid_t, 0), signals.armedTargetPgid());
    switch (session.root_exit) {
        .signaled => |signal| try testing.expect(signal > 0),
        .unknown, .exited => return error.TestUnexpectedResult,
    }
    for (session.processes.items) |process| {
        try testing.expect(process.end_ns != null);
        try testing.expect(process.end_kind != .open);
        try testing.expectEqual(process.end_ns, process.execAt(process.execCount() - 1).end_ns);
    }
}

test "session stops when the root exits while a descendant is still running" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "sh",
        "-c",
        "sh -c 'kill -STOP $$' & exec true",
    }, .{});
    const root_pid = session.root_pid.?;
    defer signals.terminateTargetGroup(root_pid);

    try updateUntilStopped(&session, &collector);
    try std.testing.expect(!session.running);
    try std.testing.expect(session.elapsed_ns < 1500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), session.activeCount());
    try std.testing.expectEqual(@as(std.posix.pid_t, 0), signals.armedTargetPgid());
}

test "session ends cleanly across a build-like churn of children" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "sh", "-c",
        \\i=0
        \\while [ "$i" -lt 200 ]; do
        \\  sh -c 'exec true' &
        \\  sh -c 'exit 0' &
        \\  i=$((i+1))
        \\done
        \\wait
    }, .{});
    try updateUntilStopped(&session, &collector);
    try std.testing.expect(!session.running);
    try std.testing.expect(session.finished);
    switch (session.root_exit) {
        .unknown => return error.TestUnexpectedResult,
        .exited, .signaled => {},
    }
    try std.testing.expectEqual(@as(std.posix.pid_t, 0), signals.armedTargetPgid());
}

test "capture events drive the process tree" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, held_target_argv, .{});

    const root_pid = session.root_pid.?;
    try std.testing.expect(!session.finished);
    try std.testing.expect(session.host_cpu_count >= 1);
    try std.testing.expectEqual(default_cpu_sample_period_ns, session.sample_period_ns);
    var target_argv = session.targetArgvIter();
    try std.testing.expectEqualStrings("sh", target_argv.next().?);
    try std.testing.expectEqualStrings("-c", target_argv.next().?);
    try std.testing.expectEqualStrings("kill -STOP $$", target_argv.next().?);
    try std.testing.expect(target_argv.next() == null);
    try std.testing.expectEqualStrings("sh", session.processes.items[0].nameSlice());
    try std.testing.expectEqual(NameKind.process, session.processes.items[0].name_kind);
    var arg_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "kill -STOP $$",
        session.processes.items[0].argSummary(session.metadataBytes(), &arg_buf),
    );
    try std.testing.expectEqualStrings(
        "sh -c kill -STOP $$",
        session.processes.items[0].copyCmdline(session.metadataBytes(), &arg_buf),
    );
    const base_ns: u64 = @intCast(@max(0, session.started_at.nanoseconds));

    const fork_event = forkEvent(
        4242,
        root_pid,
        base_ns + 10 * std.time.ns_per_ms,
        "io",
    );
    session.consumeEvent(fork_event);

    try std.testing.expectEqual(@as(usize, 2), session.processes.items.len);
    const child_index = session.by_pid.get(4242).?;
    const child = session.processes.items[child_index];
    try std.testing.expectEqual(root_pid, child.parent_pid.?);
    try std.testing.expectEqualStrings("sh", child.nameSlice());
    try std.testing.expectEqual(NameKind.process, child.name_kind);
    try std.testing.expectEqual(@as(u16, 1), child.depth);
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_ms), child.start_ns);
    try std.testing.expect(child.end_ns == null);
    try std.testing.expectEqual(Process.MetadataSource.inherited, child.args_source);
    try std.testing.expectEqualStrings(
        "sh -c kill -STOP $$",
        child.copyCmdline(session.metadataBytes(), &arg_buf),
    );

    session.consumeEvent(fork_event);
    try std.testing.expectEqual(@as(usize, 2), session.processes.items.len);
    try std.testing.expectEqual(child_index, session.by_pid.get(4242).?);

    const exec_args = "clang\x00-c\x00source.c\x00";
    const exec_exe = "/usr/bin/clang";
    session.consumeEvent(execEvent(
        4242,
        base_ns + 12 * std.time.ns_per_ms,
        "clang",
        exec_exe,
        exec_args,
    ));
    try std.testing.expectEqualStrings("clang", session.processes.items[child_index].nameSlice());
    try std.testing.expectEqual(NameKind.process, session.processes.items[child_index].name_kind);
    try std.testing.expectEqualStrings(
        exec_exe,
        session.processes.items[child_index].exeSlice(session.metadataBytes()),
    );
    try std.testing.expectEqualStrings(
        "clang -c source.c",
        session.processes.items[child_index].copyCmdline(session.metadataBytes(), &arg_buf),
    );
    const inherited_exec = session.processes.items[child_index].execAt(0);
    try std.testing.expectEqualStrings("sh", inherited_exec.nameSlice());
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_ms), inherited_exec.start_ns);
    try std.testing.expectEqual(@as(u64, 12 * std.time.ns_per_ms), inherited_exec.end_ns.?);
    try std.testing.expectEqualStrings(
        "sh -c kill -STOP $$",
        inherited_exec.copyCmdline(session.metadataBytes(), &arg_buf),
    );
    try std.testing.expectEqual(
        @as(u64, 12 * std.time.ns_per_ms),
        session.processes.items[child_index].currentExec().start_ns,
    );
    try std.testing.expectEqual(
        Process.MetadataSource.kernel,
        session.processes.items[child_index].args_source,
    );
    try std.testing.expectEqualStrings(
        "clang",
        session.processes.items[child_index].rowNameSlice(),
    );

    session.consumeCpuSnapshot(
        4242,
        2 * std.time.ns_per_ms,
        base_ns + 13 * std.time.ns_per_ms,
    );
    session.consumeCpuSnapshot(
        4242,
        4 * std.time.ns_per_ms,
        base_ns + 14 * std.time.ns_per_ms,
    );
    session.consumeEvent(execEvent(
        4242,
        base_ns + 14 * std.time.ns_per_ms,
        "ld",
        "/usr/bin/ld",
        "ld\x00-o\x00app\x00",
    ));
    try std.testing.expectEqualStrings("ld", session.processes.items[child_index].nameSlice());
    try std.testing.expectEqualStrings(
        "clang",
        session.processes.items[child_index].rowNameSlice(),
    );

    session.consumeEvent(exitEvent(
        4242,
        base_ns + 15 * std.time.ns_per_ms,
        "ld",
        6 * std.time.ns_per_ms,
    ));
    try std.testing.expectEqual(
        @as(u64, 5 * std.time.ns_per_ms),
        session.processes.items[child_index].durationNs(session.elapsed_ns),
    );
    try std.testing.expectEqual(
        @as(u64, 6 * std.time.ns_per_ms),
        session.processes.items[child_index].cpu_time_ns,
    );
    try std.testing.expect(session.processes.items[child_index].cpu_slices.items.len > 0);
}

test "root exec history coalesces launch and survives metadata compaction" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, held_target_argv, .{});

    const root_pid = session.root_pid.?;
    const base_ns: u64 = @intCast(@max(0, session.started_at.nanoseconds));
    session.consumeEvent(execEvent(
        root_pid,
        base_ns + 1 * std.time.ns_per_ms,
        "dash",
        "/usr/bin/dash",
        "dash\x00-c\x00kill -STOP $$\x00",
    ));
    try std.testing.expectEqual(@as(usize, 1), session.processes.items[0].execCount());
    try std.testing.expectEqual(@as(u64, 0), session.processes.items[0].currentExec().start_ns);
    var command_buffer: [64]u8 = undefined;
    const launch_exec = session.processes.items[0].rowExec();
    try std.testing.expectEqualStrings("sh", launch_exec.nameSlice());
    try std.testing.expectEqualStrings("sh", session.processes.items[0].rowNameSlice());
    try std.testing.expectEqualStrings("dash", session.processes.items[0].nameSlice());
    try std.testing.expectEqualStrings(
        "sh -c kill -STOP $$",
        launch_exec.copyCmdline(session.metadataBytes(), &command_buffer),
    );

    session.consumeEvent(execEvent(
        root_pid,
        base_ns + 10 * std.time.ns_per_ms,
        "echo",
        "/usr/bin/echo",
        "echo\x00done\x00",
    ));
    try std.testing.expectEqual(@as(usize, 2), session.processes.items[0].execCount());
    try session.compactMetadata();

    var target_argv = session.targetArgvIter();
    try std.testing.expectEqualStrings("sh", target_argv.next().?);
    try std.testing.expectEqualStrings("-c", target_argv.next().?);
    try std.testing.expectEqualStrings("kill -STOP $$", target_argv.next().?);
    try std.testing.expect(target_argv.next() == null);

    const shell_exec = session.processes.items[0].execAt(0);
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_ms), shell_exec.end_ns.?);
    try std.testing.expectEqualStrings(
        "dash -c kill -STOP $$",
        shell_exec.copyCmdline(session.metadataBytes(), &command_buffer),
    );
    const retained_launch = session.processes.items[0].rowExec();
    try std.testing.expectEqualStrings(
        "sh -c kill -STOP $$",
        retained_launch.copyCmdline(session.metadataBytes(), &command_buffer),
    );
    const echo = session.processes.items[0].currentExec();
    try std.testing.expectEqualStrings(
        "echo done",
        echo.copyCmdline(session.metadataBytes(), &command_buffer),
    );
    try std.testing.expectEqualStrings("/usr/bin/echo", echo.exeSlice(session.metadataBytes()));
}

test "fork after exit reuses a tgid as a new record" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, held_target_argv, .{});
    const root_pid = session.root_pid.?;
    const base_ns: u64 = @intCast(@max(0, session.started_at.nanoseconds));

    var fork_event = forkEvent(
        4242,
        root_pid,
        base_ns + 10 * std.time.ns_per_ms,
        "cc1plus",
    );
    session.consumeEvent(fork_event);
    const first_index = session.by_pid.get(4242).?;

    session.consumeEvent(exitEvent(
        4242,
        base_ns + 15 * std.time.ns_per_ms,
        "cc1plus",
        0,
    ));

    fork_event.timestamp_ns = base_ns + 20 * std.time.ns_per_ms;
    session.consumeEvent(fork_event);
    const reused_index = session.by_pid.get(4242).?;
    try std.testing.expectEqual(@as(usize, 3), session.processes.items.len);
    try std.testing.expect(reused_index != first_index);
    try std.testing.expect(session.processes.items[first_index].end_ns != null);
    try std.testing.expect(session.processes.items[reused_index].end_ns == null);
    try std.testing.expectEqual(root_pid, session.processes.items[reused_index].parent_pid.?);
    try std.testing.expectEqual(
        @as(u64, 20 * std.time.ns_per_ms),
        session.processes.items[reused_index].start_ns,
    );
}

test "exit closes a live tgid immediately" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, held_target_argv, .{});
    const root_pid = session.root_pid.?;
    const base_ns: u64 = @intCast(@max(0, session.started_at.nanoseconds));

    session.consumeEvent(exitEvent(
        root_pid,
        base_ns + 5 * std.time.ns_per_ms,
        "worker",
        0,
    ));

    try std.testing.expectEqual(
        @as(u64, 5 * std.time.ns_per_ms),
        session.processes.items[0].end_ns.?,
    );
}

test "partial exit CPU preserves the latest cumulative snapshot" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, held_target_argv, .{});
    const root_pid = session.root_pid.?;
    const base_ns: u64 = @intCast(@max(0, session.started_at.nanoseconds));

    session.consumeCpuSnapshot(root_pid, 10, base_ns + 2 * std.time.ns_per_ms);
    var exit_event = exitEvent(
        root_pid,
        base_ns + 5 * std.time.ns_per_ms,
        "worker",
        7,
    );
    exit_event.payload.exit.cpu_final = false;
    session.consumeEvent(exit_event);

    const process = session.processes.items[0];
    try std.testing.expectEqual(@as(u64, 10), process.cpu_time_ns);
    try std.testing.expect(!process.cpu_final);
    try std.testing.expectEqual(Process.EndKind.observed_exit, process.end_kind);
}

test "exec can clear inherited metadata without inspecting the live PID" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, held_target_argv, .{});
    const root_pid = session.root_pid.?;
    const base_ns: u64 = @intCast(@max(0, session.started_at.nanoseconds));
    try std.testing.expect(session.processes.items[0].args_len > 0);

    session.consumeEvent(.{
        .timestamp_ns = base_ns + std.time.ns_per_ms,
        .payload = .{ .exec = .{
            .pid = root_pid,
            .name = "",
            .metadata_source = .process_inspection,
            .inspect_missing = false,
        } },
    });

    const process = session.processes.items[0];
    try std.testing.expectEqualStrings("process", process.nameSlice());
    try std.testing.expectEqual(@as(usize, 0), process.args_len);
    try std.testing.expectEqual(Process.MetadataSource.unavailable, process.args_source);
}

test "fork with unknown parent recovers a stub under the root" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, held_target_argv, .{});
    const root_pid = session.root_pid.?;
    const base_ns: u64 = @intCast(@max(0, session.started_at.nanoseconds));

    session.consumeEvent(forkEvent(
        9999,
        7777,
        base_ns + 4 * std.time.ns_per_ms,
        "cc1",
    ));

    try std.testing.expectEqual(@as(usize, 3), session.processes.items.len);
    const stub_index = session.by_pid.get(7777).?;
    const child_index = session.by_pid.get(9999).?;
    const stub = session.processes.items[stub_index];
    const child = session.processes.items[child_index];
    try std.testing.expectEqual(root_pid, stub.parent_pid.?);
    try std.testing.expectEqual(Process.Origin.recovered_parent, stub.origin);
    try std.testing.expect(session.isIncomplete());
    try std.testing.expectEqual(NameKind.other, stub.name_kind);
    try std.testing.expectEqualStrings("process", stub.nameSlice());
    try std.testing.expectEqual(@as(std.posix.pid_t, 7777), child.parent_pid.?);
    try std.testing.expectEqual(stub_index, child.parent_index.?);
    try std.testing.expectEqualStrings("cc1", child.nameSlice());
}

test "exec without a fork recovers the process under the root" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, held_target_argv, .{});
    const root_pid = session.root_pid.?;
    const base_ns: u64 = @intCast(@max(0, session.started_at.nanoseconds));

    const exec_args = "clang\x00-c\x00source.c\x00";
    const exec_exe = "/usr/bin/clang";
    session.consumeEvent(execEvent(
        5555,
        base_ns + 8 * std.time.ns_per_ms,
        "clang",
        exec_exe,
        exec_args,
    ));

    try std.testing.expectEqual(@as(usize, 2), session.processes.items.len);
    const index = session.by_pid.get(5555).?;
    const process = session.processes.items[index];
    try std.testing.expectEqual(root_pid, process.parent_pid.?);
    try std.testing.expectEqual(Process.Origin.recovered_exec, process.origin);
    try std.testing.expectEqualStrings("clang", process.nameSlice());
    try std.testing.expectEqualStrings(exec_exe, process.exeSlice(session.metadataBytes()));
    var arg_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "clang -c source.c",
        process.copyCmdline(session.metadataBytes(), &arg_buf),
    );

    const long_arg_len = 8 * 1024;
    const long_args_len = "clang".len + 1 + long_arg_len + 1;
    var long_args_buffer = [_]u8{0} ** long_args_len;
    @memcpy(long_args_buffer[0.."clang".len], "clang");
    @memset(long_args_buffer["clang".len + 1 .. long_args_buffer.len - 1], 'x');
    session.consumeEvent(execEvent(
        5555,
        base_ns + 9 * std.time.ns_per_ms,
        "clang",
        null,
        &long_args_buffer,
    ));

    const updated = session.processes.items[index];
    try std.testing.expectEqual(@as(usize, 2), updated.args_count);
    var long_args = updated.argsIter(session.metadataBytes());
    try std.testing.expectEqualStrings("clang", long_args.next().?);
    try std.testing.expectEqual(@as(usize, long_arg_len), long_args.next().?.len);
    try std.testing.expect(long_args.next() == null);
}

test "exit without a fork recovers a zero-duration process" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, held_target_argv, .{});
    const root_pid = session.root_pid.?;
    const base_ns: u64 = @intCast(@max(0, session.started_at.nanoseconds));

    var exit_event = exitEvent(8888, base_ns + 6 * std.time.ns_per_ms, "worker", 0);
    session.consumeEvent(exit_event);

    try std.testing.expectEqual(@as(usize, 2), session.processes.items.len);
    try std.testing.expect(session.by_pid.get(8888) == null);
    const index = session.latestIndex(8888).?;
    const process = session.processes.items[index];
    try std.testing.expectEqual(root_pid, process.parent_pid.?);
    try std.testing.expectEqual(Process.Origin.recovered_exit, process.origin);
    try std.testing.expectEqual(Process.EndKind.observed_exit, process.end_kind);
    try std.testing.expectEqualStrings("worker", process.nameSlice());
    try std.testing.expectEqual(@as(u64, 6 * std.time.ns_per_ms), process.start_ns);
    try std.testing.expectEqual(@as(u64, 6 * std.time.ns_per_ms), process.end_ns.?);
    try std.testing.expectEqual(@as(u64, 0), process.durationNs(session.elapsed_ns));

    session.consumeEvent(exit_event);
    try std.testing.expectEqual(@as(usize, 2), session.processes.items.len);

    // A later exit for the same numeric pid represents reuse when every
    // earlier event from the new lifetime was lost.
    exit_event.timestamp_ns = base_ns + 9 * std.time.ns_per_ms;
    session.consumeEvent(exit_event);
    try std.testing.expectEqual(@as(usize, 3), session.processes.items.len);
    try std.testing.expect(session.by_pid.get(8888) == null);
    const reused = session.processes.items[session.latestIndex(8888).?];
    try std.testing.expectEqual(@as(u64, 9 * std.time.ns_per_ms), reused.start_ns);
    try std.testing.expectEqual(reused.start_ns, reused.end_ns.?);
}

test "kernel fork events reach a live collector" {
    if (comptime capture.backend != .linux_ebpf) return error.SkipZigTest;
    var collector = capture.Collector.init(std.testing.allocator);
    defer collector.deinit();
    if (!collector.available()) {
        if (std.mem.startsWith(
            u8,
            collector.diagnosticSlice(),
            "effective capabilities lack",
        )) return error.SkipZigTest;
        return error.SkipZigTest;
    }

    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "sh",
        "-c",
        "sh -c 'kill -STOP $$' & wait",
    }, .{});

    try updateUntilProcessCount(&session, &collector, 2);
    try std.testing.expect(session.processes.items.len >= 2);
    session.stop(&collector);
}

test "macOS collector captures descendant lifecycle and metadata" {
    if (comptime capture.backend != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var collector = capture.Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();
    try testing.expect(collector.available());

    var session = Session.init(testing.allocator, testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "/usr/bin/python3",
        "-c",
        fork_gate_script,
        "1",
    }, .{});
    try testing.expectEqual(collector.fidelity(), session.capture_fidelity);

    try updateUntilProcessCount(&session, &collector, 2);
    process_ops.safeKill(session.root_pid.?, .USR1);
    try updateUntilStopped(&session, &collector);
    try testing.expect(session.processes.items.len >= 2);
    const root = session.processes.items[0];
    try testing.expectEqual(Process.MetadataSource.process_inspection, root.args_source);
    try testing.expect(root.exe_len > 0);
    try testing.expect(root.cwd_len > 0);

    var observed_child = false;
    for (session.processes.items[1..]) |process| {
        if (process.origin == .observed) observed_child = true;
    }
    try testing.expect(observed_child);
}

test "macOS fallback preserves shebang interpreter metadata" {
    if (comptime capture.backend != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(testing.io, .{
        .sub_path = "flamez-script",
        .data = "#!/bin/sh\nkill -STOP $$\n",
        .flags = .{ .permissions = .executable_file },
    });
    var path_buffer: [128]u8 = undefined;
    const script_path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/flamez-script",
        .{temporary.sub_path[0..]},
    );

    var collector = capture.Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();
    var session = Session.init(testing.allocator, testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        script_path,
        "alpha",
        "",
        "omega",
    }, .{});

    const started = std.Io.Clock.awake.now(testing.io);
    while (true) {
        session.update(&collector);
        const root = &session.processes.items[0];
        if (root.args_count == 5 and root.exe_len > 0) break;
        if (started.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds >=
            5 * std.time.ns_per_s) return error.TestUnexpectedResult;
        try std.Thread.yield();
    }
    session.stop(&collector);
    const root = &session.processes.items[0];
    try testing.expectEqual(Process.MetadataSource.process_inspection, root.args_source);
    try testing.expectEqual(Process.MetadataSource.process_inspection, root.exe_source);
    const executable = root.exeSlice(session.metadata.items);
    try testing.expectEqualStrings(root.nameSlice(), std.fs.path.basename(executable));
    try testing.expect(!std.mem.endsWith(u8, executable, "/flamez-script"));

    var args = root.argsIter(session.metadata.items);
    try testing.expectEqualStrings("/bin/sh", args.next().?);
    try testing.expectEqualStrings(script_path, args.next().?);
    try testing.expectEqualStrings("alpha", args.next().?);
    try testing.expectEqualStrings("", args.next().?);
    try testing.expectEqualStrings("omega", args.next().?);
    try testing.expect(args.next() == null);
}

test "macOS fallback retains an admitted descendant after setsid" {
    if (comptime capture.backend != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var collector = capture.Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();
    var session = Session.init(testing.allocator, testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "/usr/bin/python3",
        "-c",
        escaped_gate_script,
    }, .{});
    try updateUntilProcessCount(&session, &collector, 2);
    process_ops.safeKill(session.root_pid.?, .USR1);
    try updateUntilStopped(&session, &collector);
    const boundary_ns = session.timelineNs();

    var escaped_pid: ?std.posix.pid_t = null;
    for (session.processes.items[1..]) |process| {
        const exe = process.exeSlice(session.metadata.items);
        if (std.mem.indexOf(u8, exe, "/Python") == null) continue;
        escaped_pid = process.pid;
        try testing.expectEqual(Process.Origin.observed, process.origin);
        try testing.expectEqual(Process.EndKind.capture_clipped, process.end_kind);
        try testing.expectEqual(boundary_ns, process.end_ns.?);
    }
    const pid = escaped_pid orelse return error.TestUnexpectedResult;
    process_ops.safeKill(pid, .KILL);
    try waitForProcessExit(pid, testing.io);
}

test "macOS fallback recovers a reparented setsid child by original parent" {
    if (comptime capture.backend != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const daemon_script =
        \\import os,signal
        \\child = os.fork()
        \\if child > 0: os._exit(0)
        \\os.setsid()
        \\signal.pause()
    ;
    var collector = capture.Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();
    var session = Session.init(testing.allocator, testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "/usr/bin/python3",
        "-c",
        daemon_script,
    }, .{});

    try updateUntilStopped(&session, &collector);
    const boundary_ns = session.timelineNs();

    var escaped_pid: ?std.posix.pid_t = null;
    for (session.processes.items[1..]) |process| {
        const exe = process.exeSlice(session.metadata.items);
        if (std.mem.indexOf(u8, exe, "/Python") == null) continue;
        escaped_pid = process.pid;
        try testing.expectEqual(session.processes.items[0].pid, process.parent_pid.?);
        try testing.expectEqual(Process.Origin.observed, process.origin);
        try testing.expectEqual(Process.EndKind.capture_clipped, process.end_kind);
        try testing.expectEqual(boundary_ns, process.end_ns.?);
    }
    const pid = escaped_pid orelse return error.TestUnexpectedResult;
    process_ops.safeKill(pid, .KILL);
    try waitForProcessExit(pid, testing.io);
}

test "macOS collector updates one root record across exec" {
    if (comptime capture.backend != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var collector = capture.Collector.init(testing.allocator);
    defer collector.deinit();

    var session = Session.init(testing.allocator, testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "sh",
        "-c",
        "exec /bin/sleep 60",
    }, .{});

    const started = std.Io.Clock.awake.now(testing.io);
    while (std.mem.indexOf(
        u8,
        session.processes.items[0].exeSlice(session.metadata.items),
        "/bin/sleep",
    ) == null) {
        session.update(&collector);
        if (started.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds >=
            5 * std.time.ns_per_s) return error.TestUnexpectedResult;
        try std.Thread.yield();
    }
    session.stop(&collector);
    try testing.expectEqual(@as(usize, 1), session.processes.items.len);
    const root = &session.processes.items[0];
    try testing.expectEqualStrings("sleep", root.nameSlice());
    var args = root.argsIter(session.metadata.items);
    const arg_zero = args.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("/bin/sleep", arg_zero);
    try testing.expectEqualStrings("60", args.next() orelse return error.TestUnexpectedResult);
    try testing.expect(args.next() == null);
    try testing.expectEqual(collector.fidelity(), session.capture_fidelity);
    switch (session.capture_fidelity) {
        .exact => try testing.expectEqual(Process.MetadataSource.kernel, root.args_source),
        .snapshot_recovery => try testing.expectEqual(
            Process.MetadataSource.process_inspection,
            root.args_source,
        ),
        .unavailable => unreachable,
    }
}

test "macOS final flush preserves immediate root exits" {
    if (comptime capture.backend != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var collector = capture.Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();

    var session = Session.init(testing.allocator, testing.io);
    defer session.deinit();
    for (0..24) |_| {
        try session.start(&collector, &.{
            "sh",
            "-c",
            "exit 37",
        }, .{});
        try updateUntilStopped(&session, &collector);
        try testing.expectEqual(RootExit{ .exited = 37 }, session.root_exit);
        try testing.expect(session.finished);
        try testing.expectEqual(@as(usize, 1), session.processes.items.len);
        try testing.expectEqual(
            Process.EndKind.observed_exit,
            session.processes.items[0].end_kind,
        );
        try testing.expectEqual(
            session.processes.items[0].end_ns.?,
            session.timelineNs(),
        );
    }
}

test "macOS root exit clips surviving descendants to the event boundary" {
    if (comptime capture.backend != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var collector = capture.Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();

    var session = Session.init(testing.allocator, testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "/usr/bin/python3",
        "-c",
        escaped_gate_script,
    }, .{});
    const root_pid = session.root_pid.?;
    defer process_ops.safeKill(-root_pid, .KILL);

    try updateUntilProcessCount(&session, &collector, 2);
    process_ops.safeKill(root_pid, .USR1);
    try updateUntilStopped(&session, &collector);
    const boundary_ns = session.processes.items[0].end_ns.?;
    try testing.expectEqual(boundary_ns, session.timelineNs());

    var survivor_pid: ?std.posix.pid_t = null;
    for (session.processes.items[1..]) |process| {
        if (process.end_kind != .capture_clipped) continue;
        survivor_pid = process.pid;
        try testing.expectEqual(boundary_ns, process.end_ns.?);
        for (process.cpu_slices.items) |slice| {
            try testing.expect(slice.end_ns <= boundary_ns);
        }
    }
    const pid = survivor_pid orelse return error.TestUnexpectedResult;
    process_ops.safeKill(pid, .KILL);
    try waitForProcessExit(pid, testing.io);
}

test "macOS fallback tracks a concurrent descendant burst" {
    if (comptime capture.backend != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var collector = capture.Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();

    var session = Session.init(testing.allocator, testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "/usr/bin/python3",
        "-c",
        fork_gate_script,
        "32",
    }, .{});

    try updateUntilProcessCount(&session, &collector, 33);
    process_ops.safeKill(session.root_pid.?, .USR1);
    try updateUntilStopped(&session, &collector);

    var child_count: usize = 0;
    for (session.processes.items[1..]) |process| {
        child_count += 1;
        try testing.expectEqual(Process.Origin.observed, process.origin);
        try testing.expectEqual(Process.EndKind.observed_exit, process.end_kind);
        try testing.expectEqual(Process.MetadataSource.process_inspection, process.args_source);
    }
    try testing.expectEqual(@as(usize, 32), child_count);
}

test "macOS collector restarts immediately after forced Stop" {
    if (comptime capture.backend != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var collector = capture.Collector.init(testing.allocator);
    defer collector.deinit();

    var session = Session.init(testing.allocator, testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "/usr/bin/python3",
        "-c",
        fork_gate_script,
        "1",
    }, .{});

    try updateUntilProcessCount(&session, &collector, 2);
    try testing.expect(session.processes.items.len >= 2);
    session.stop(&collector);
    try testing.expect(!session.running);
    try testing.expectEqual(@as(usize, 0), session.activeCount());
    for (session.processes.items) |process| {
        try testing.expectEqual(Process.EndKind.capture_clipped, process.end_kind);
    }

    try session.start(&collector, &.{
        "/usr/bin/python3",
        "-c",
        fork_gate_script,
        "1",
    }, .{});
    try updateUntilProcessCount(&session, &collector, 2);
    process_ops.safeKill(session.root_pid.?, .USR1);
    try updateUntilStopped(&session, &collector);
    try testing.expect(session.processes.items.len >= 2);
    try testing.expectEqual(@as(usize, 0), session.activeCount());
}

test "exec does not rebuild tree topology" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, held_target_argv, .{});
    const root_pid = session.root_pid.?;
    const base_ns: u64 = @intCast(@max(0, session.started_at.nanoseconds));
    const topology = session.topology_revision;
    const interval = session.interval_revision;

    session.consumeEvent(forkEvent(
        4242,
        root_pid,
        base_ns + 10 * std.time.ns_per_ms,
        "process",
    ));
    try std.testing.expect(session.topology_revision != topology);
    const after_fork_topology = session.topology_revision;
    const after_fork_labels = session.label_revision;

    session.consumeEvent(execEvent(
        4242,
        base_ns + 12 * std.time.ns_per_ms,
        "clang",
        null,
        null,
    ));
    try std.testing.expectEqual(after_fork_topology, session.topology_revision);
    try std.testing.expect(session.label_revision != after_fork_labels);
    try std.testing.expectEqual(interval, session.interval_revision);

    session.consumeEvent(exitEvent(
        4242,
        base_ns + 15 * std.time.ns_per_ms,
        "clang",
        0,
    ));
    try std.testing.expectEqual(after_fork_topology, session.topology_revision);
    try std.testing.expect(session.interval_revision != interval);
    try std.testing.expect(session.by_pid.get(4242) == null);
}

test "metadata compaction keeps target argv and drops superseded bytes" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, held_target_argv, .{});
    const before = session.metadata.items.len;
    try session.processes.items[0].setArgsFromArgv(
        &session.metadata,
        std.testing.allocator,
        &.{ "replaced", "argv" },
    );
    try session.processes.items[0].setExe(
        &session.metadata,
        std.testing.allocator,
        "/superseded/path",
    );
    try session.processes.items[0].setExe(
        &session.metadata,
        std.testing.allocator,
        "/retained/path",
    );
    const after_replace = session.metadata.items.len;
    try std.testing.expect(after_replace > before);
    try session.compactMetadata();
    var cmd_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "replaced argv",
        session.processes.items[0].copyCmdline(session.metadataBytes(), &cmd_buf),
    );
    var target_argv = session.targetArgvIter();
    try std.testing.expectEqualStrings("sh", target_argv.next().?);
    try std.testing.expectEqualStrings("-c", target_argv.next().?);
    try std.testing.expectEqualStrings("kill -STOP $$", target_argv.next().?);
    try std.testing.expect(target_argv.next() == null);
    try std.testing.expectEqualStrings(
        "/retained/path",
        session.processes.items[0].exeSlice(session.metadataBytes()),
    );
    try std.testing.expect(session.metadata.items.len < after_replace);
}

test "root label matches the process when argv basename equals comm" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var comm_buf: [max_name_len]u8 = undefined;
    const self_pid = process_ops.currentPid();
    const comm = process_ops.readName(self_pid, &comm_buf) orelse
        return error.TestUnexpectedResult;
    var argv_buf: [max_name_len]u8 = undefined;
    @memcpy(argv_buf[0..comm.len], comm);
    const named = Session.rootLabel(self_pid, argv_buf[0..comm.len], &comm_buf);
    try std.testing.expectEqual(NameKind.process, named.kind);
    try std.testing.expectEqualStrings(argv_buf[0..comm.len], named.text);
}

test "root label is other when argv basename does not match comm" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const self_pid = process_ops.currentPid();
    var observed_buf: [max_name_len]u8 = undefined;
    const comm = process_ops.readName(self_pid, &observed_buf) orelse
        return error.TestUnexpectedResult;
    const argv0 = if (std.mem.eql(u8, comm, "build.sh")) "other.sh" else "build.sh";
    var comm_buf: [max_name_len]u8 = undefined;
    const named = Session.rootLabel(self_pid, argv0, &comm_buf);
    try std.testing.expectEqual(NameKind.other, named.kind);
    try std.testing.expectEqualStrings(argv0, named.text);
}

fn boundaryTestSession(gpa: Allocator) !Session {
    var session = Session.init(gpa, std.testing.io);
    errdefer session.deinit();
    session.running = true;
    session.root_pid = 2_000_000_000;
    const root = try session.addProcess(.{ .pid = session.root_pid.?, .named = .fromOther("root") });
    try session.processes.items[root].setArgsFromArgv(&session.metadata, gpa, &.{"root"});
    session.target_argv_offset = session.processes.items[root].args_offset;
    session.target_argv_len = session.processes.items[root].args_len;
    session.target_argv_count = session.processes.items[root].args_count;
    return session;
}

fn expectWritableBoundary(session: *const Session) !void {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try session_file.write(std.testing.allocator, session, &writer.writer);
}

test "root boundary clips a later child exit and its CPU" {
    const testing = std.testing;
    var session = try boundaryTestSession(testing.allocator);
    defer session.deinit();
    var collector = capture.Collector{};
    const child_pid = session.root_pid.? + 1;
    session.consumeEvent(forkEvent(child_pid, session.root_pid.?, 2, "child"));
    session.consumeCpuSnapshot(child_pid, 6, 8);
    session.consumeEvent(exitEvent(session.root_pid.?, 10, "root", 0));
    session.consumeEvent(exitEvent(child_pid, 10, "child", 0));
    // Reuse after the boundary must not replace the earlier generation.
    session.consumeEvent(forkEvent(child_pid, session.root_pid.?, 11, "replacement"));
    session.finishRootCapture(&collector, null);
    try expectWritableBoundary(&session);
    try testing.expectEqual(@as(usize, 2), session.processes.items.len);
    try testing.expectEqual(Process.EndKind.observed_exit, session.processes.items[1].end_kind);

    var delayed = try boundaryTestSession(testing.allocator);
    defer delayed.deinit();
    delayed.consumeEvent(forkEvent(child_pid, delayed.root_pid.?, 2, "child"));
    delayed.consumeCpuSnapshot(child_pid, 6, 8);
    delayed.consumeEvent(exitEvent(delayed.root_pid.?, 10, "root", 0));
    delayed.consumeEvent(exitEvent(child_pid, 12, "child", 10));
    delayed.finishRootCapture(&collector, null);
    try expectWritableBoundary(&delayed);
    const child = delayed.processes.items[1];
    try testing.expectEqual(@as(?u64, 10), child.end_ns);
    try testing.expectEqual(Process.EndKind.capture_clipped, child.end_kind);
    try testing.expect(!child.cpu_final);
    try testing.expectEqual(@as(u64, 8), child.cpu_time_ns);
}

test "root boundary restores the image before later child execs" {
    const testing = std.testing;
    var session = try boundaryTestSession(testing.allocator);
    defer session.deinit();
    var collector = capture.Collector{};
    const child_pid = session.root_pid.? + 1;
    session.consumeEvent(forkEvent(child_pid, session.root_pid.?, 2, "child"));
    session.consumeEvent(execEvent(child_pid, 3, "before", "/bin/before", "before\x00"));
    session.consumeEvent(execEvent(child_pid, 12, "after", "/bin/after", "after\x00"));
    session.consumeEvent(execEvent(child_pid, 14, "later", "/bin/later", "later\x00"));
    session.consumeEvent(exitEvent(child_pid, 15, "later", 0));
    session.consumeEvent(exitEvent(session.root_pid.?, 10, "root", 0));
    session.finishRootCapture(&collector, null);
    try expectWritableBoundary(&session);
    const child = session.processes.items[1];
    try testing.expectEqual(@as(usize, 2), child.execCount());
    try testing.expectEqualStrings("before", child.nameSlice());
    try testing.expectEqualStrings("/bin/before", child.exeSlice(session.metadataBytes()));
    try testing.expectEqualStrings("before", child.argv0(session.metadataBytes()));
    try testing.expectEqual(@as(?u64, 10), child.end_ns);
}

test "root boundary removes later births and remaps retained parents without allocation" {
    const testing = std.testing;
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var session = try boundaryTestSession(failing.allocator());
    defer session.deinit();
    var collector = capture.Collector{};
    const root_pid = session.root_pid.?;
    session.consumeEvent(forkEvent(root_pid + 1, root_pid, 12, "discard"));
    session.consumeEvent(forkEvent(root_pid + 2, root_pid, 4, "keep"));
    session.consumeEvent(forkEvent(root_pid + 3, root_pid + 2, 5, "grandchild"));
    session.consumeEvent(exitEvent(root_pid, 10, "root", 0));
    failing.fail_index = failing.alloc_index;
    session.finishRootCapture(&collector, null);
    try expectWritableBoundary(&session);
    try testing.expectEqual(@as(usize, 3), session.processes.items.len);
    try testing.expectEqual(root_pid + 2, session.processes.items[1].pid);
    try testing.expectEqual(@as(?usize, 1), session.processes.items[2].parent_index);
    try testing.expectEqual(root_pid + 2, session.processes.items[2].parent_pid);
    try testing.expectEqual(@as(usize, 0), session.active_count);
    try testing.expectEqual(@as(u64, 10), session.elapsed_ns);
}

test "root boundary restores a surviving child image after root exit" {
    const testing = std.testing;
    var session = try boundaryTestSession(testing.allocator);
    defer session.deinit();
    var collector = capture.Collector{};
    const child_pid = session.root_pid.? + 1;
    session.consumeEvent(forkEvent(child_pid, session.root_pid.?, 2, "child"));
    session.consumeEvent(exitEvent(session.root_pid.?, 10, "root", 0));
    session.consumeEvent(execEvent(child_pid, 12, "after", "/bin/after", "after\x00"));
    session.finishRootCapture(&collector, null);
    try expectWritableBoundary(&session);
    const child = session.processes.items[1];
    try testing.expectEqual(@as(usize, 1), child.execCount());
    try testing.expectEqual(@as(?u64, 10), child.end_ns);
    try testing.expectEqualStrings("root", child.argv0(session.metadataBytes()));
}

test "analysis accepts a child outliving its intermediate parent" {
    const testing = std.testing;
    var session = try boundaryTestSession(testing.allocator);
    defer session.deinit();
    var collector = capture.Collector{};
    const root_pid = session.root_pid.?;
    session.consumeEvent(forkEvent(root_pid + 1, root_pid, 5, "parent"));
    session.consumeEvent(forkEvent(root_pid + 2, root_pid + 1, 8, "child"));
    session.consumeEvent(exitEvent(root_pid + 1, 10, "parent", 0));
    session.consumeEvent(exitEvent(root_pid + 2, 12, "child", 0));
    session.consumeEvent(exitEvent(root_pid, 20, "root", 0));
    session.finishRootCapture(&collector, null);
    try expectWritableBoundary(&session);
    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    try analysis_file.write(testing.allocator, &session, &writer.writer);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, writer.written(), .{});
    defer parsed.deinit();
    const processes = parsed.value.object.get("processes").?.array.items;
    try testing.expectEqual(@as(i64, 2), processes[1].object.get("child_lifetime_span_ns").?.integer);
    try testing.expectEqual(@as(i64, 4), processes[2].object.get("wall_time_ns").?.integer);
    try testing.expectEqual(@as(i64, 3), processes[0].object.get("inclusive_process_count").?.integer);
    try testing.expect(std.mem.indexOf(u8, writer.written(), "complete_child_containment") == null);
}

extern fn flamez_ebpf_test_empty() ?*anyopaque;

test "failed final CPU snapshot persists loss for surviving descendants" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var session = try boundaryTestSession(testing.allocator);
    defer session.deinit();
    var collector: capture.Collector = .{};
    defer collector.deinit();
    collector.handle = @ptrCast(flamez_ebpf_test_empty() orelse return error.OutOfMemory);
    session.consumeEvent(forkEvent(2_000_000_001, 2_000_000_000, 2, "child"));
    session.consumeCpuSnapshot(2_000_000_001, 3, 8);
    session.consumeEvent(exitEvent(2_000_000_000, 10, "root", 1));
    session.finishRootCapture(&collector, null);

    try testing.expect(session.finished);
    try testing.expect(session.isIncomplete());
    try testing.expectEqual(@as(u64, 1), session.loss_count);
    try testing.expectEqual(@as(usize, 0), collector.last_cpu_samples);
    const child = session.processes.items[1];
    try testing.expectEqual(@as(u64, 3), child.cpu_time_ns);
    try testing.expectEqual(Process.EndKind.capture_clipped, child.end_kind);
    try testing.expect(!child.cpu_final);
    collector.pollEvents(session.captureSink());
    session.mergeCollectorLoss(collector.lost_events);
    try testing.expectEqual(@as(u64, 1), session.loss_count);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try session_file.write(testing.allocator, &session, &output.writer);
    var reader: std.Io.Reader = .fixed(output.written());
    var diagnostics: session_file.Diagnostics = .{};
    var replay = try session_file.read(testing.allocator, testing.io, &reader, &diagnostics);
    defer replay.deinit();
    try testing.expect(replay.isIncomplete());
    try testing.expectEqual(@as(u64, 1), replay.loss_count);
    try testing.expect(!replay.processes.items[1].cpu_final);
}
