//! Capture orchestration: spawns the target in its own process group, ingests
//! backend-neutral lifecycle events and cumulative self-CPU snapshots, and
//! owns the process timeline until the target exits.
//! Ownership: `Session` owns every `Process` record and the pid index;
//! `start(collector, argv)` borrows `argv` only for the call.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const signals = @import("signals.zig");
const Process = @import("Process.zig");
const capture = @import("capture.zig");
const process_ops = @import("process_ops.zig");
const perf = @import("../perf.zig");

const log = std.log.scoped(.tracer);

const Session = @This();

gpa: Allocator,
io: std.Io,
processes: std.ArrayList(Process) = .empty,
metadata: Process.MetadataStore = .empty,
/// tgid → index into `processes`. Unmanaged: takes `gpa` per mutation.
by_pid: std.AutoHashMapUnmanaged(std.posix.pid_t, usize) = .empty,
child: ?std.process.Child = null,
root_pid: ?std.posix.pid_t = null,
started_at: std.Io.Timestamp = .zero,
elapsed_ns: u64 = 0,
running: bool = false,
exit_code: ?u8 = null,
exit_signal: ?u8 = null,
active_count: usize = 0,
/// Kernel event reservations or tracked-child admissions that failed.
lost_events: u64 = 0,
/// True after lifecycle loss or inferred recovery; the session is not complete.
incomplete: bool = false,
/// Recovered parent/exec/exit stubs created because a lifecycle record was missing.
recovered_count: u64 = 0,
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
pub const cpu_sample_period_ns: u64 = 16 * std.time.ns_per_ms;

const NameKind = Process.NameKind;
const Named = Process.Named;
const max_name_len = Process.max_name_len;
const max_path_len = Process.max_path_len;

/// Errors from `start`. `MissingTarget` means argv was empty.
pub const StartError =
    std.process.SpawnError ||
    Allocator.Error ||
    error{
        MissingTarget,
        LaunchTrackingRejected,
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
    self.stop();
    self.clearProcesses();
    self.processes.deinit(self.gpa);
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
) StartError!void {
    if (argv.len == 0 or argv[0].len == 0) return error.MissingTarget;
    if (self.running) self.stop();
    self.clearProcesses();
    self.metadata.clearRetainingCapacity();
    self.by_pid.clearRetainingCapacity();
    self.exit_code = null;
    self.exit_signal = null;
    self.elapsed_ns = 0;
    self.active_count = 0;
    self.lost_events = 0;
    self.incomplete = false;
    self.recovered_count = 0;
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
    defer collector.untrack(launcher_pid);

    var child = try std.process.spawn(self.io, .{
        .argv = argv,
        .pgid = 0,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
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
    var comm_buf: [max_name_len]u8 = undefined;
    const root_index = try self.addProcess(.{
        .pid = pid,
        .named = Session.rootLabel(pid, argv[0], &comm_buf),
    });
    try self.processes.items[root_index].setArgsFromArgv(&self.metadata, self.gpa, argv);
    try self.refreshCwd(root_index);
    try collector.trackRoot(pid);
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

/// Terminates the live target tree and closes every open process at the
/// current session timestamp. Calling this on an idle session is harmless.
pub fn stop(self: *Session) void {
    defer {
        signals.disarmTargetGroup();
        signals.clearTrackedPids();
    }
    const pgid = signals.armedTargetPgid();
    signals.termTargetTree(pgid);
    // `Child.kill` sends TERM and then waits without a timeout. Sweep the
    // entire tree with KILL first so a target that ignores TERM or was stopped
    // by terminal job control cannot block the UI before the force-kill phase.
    signals.killTargetTree(pgid);
    if (self.child) |*child| {
        if (child.id != null) child.kill(self.io);
    }
    self.finishOpenProcesses(self.elapsed_ns);
    self.child = null;
    self.root_pid = null;
    self.running = false;
    self.compactMetadata() catch {};
}

/// Drains capture events into the process tree, advances the clock, and
/// non-blockingly checks for target exit. Capture ends with the target;
/// descendants still running at that point are closed at the same timestamp.
/// Cumulative CPU maps are snapshotted on `cpu_sample_period_ns`, not the
/// render frame rate.
pub fn update(self: *Session, collector: *capture.Collector) void {
    if (!self.running) return;

    self.elapsed_ns = self.nowElapsedNs();
    perf.enter(.ring_poll);
    collector.pollEvents(self.captureSink());
    self.lost_events = collector.lost_events;
    if (self.lost_events > 0) self.incomplete = true;
    self.elapsed_ns = self.nowElapsedNs();
    const due = self.last_cpu_sample_ns == 0 or
        self.elapsed_ns -| self.last_cpu_sample_ns >= cpu_sample_period_ns;
    if (due) {
        perf.enter(.cpu_snapshot);
        collector.snapshotCpu(self.captureSink());
        self.last_cpu_sample_ns = self.elapsed_ns;
    }
    perf.leave();
    self.pollSession();
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
}

/// Counts process records whose lifetime remains open.
pub fn activeCount(self: *const Session) usize {
    return self.active_count;
}

/// Borrowed backing bytes for every process's compact metadata offsets.
pub fn metadataBytes(self: *const Session) []const u8 {
    return self.metadata.items;
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

    const index = self.processes.items.len;
    var process = Process{
        .pid = spec.pid,
        .parent_pid = spec.parent_pid,
        .depth = spec.depth,
        .start_ns = spec.start_ns,
        .origin = spec.origin,
    };
    process.setName(spec.named.text, spec.named.kind);
    if (spec.parent_pid) |parent_pid| {
        if (self.by_pid.get(parent_pid)) |parent_index| {
            process.parent_index = parent_index;
            if (spec.inherit_metadata) {
                process.inheritMetadata(&self.processes.items[parent_index]);
            }
        }
    }
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
    var buf: [max_path_len]u8 = undefined;
    if (process_ops.readCwd(pid, &buf)) |cwd| {
        try self.processes.items[index].setCwd(&self.metadata, self.gpa, cwd);
    }
}

fn captureMissingMetadata(self: *Session, index: usize) Allocator.Error!void {
    const pid = self.processes.items[index].pid;
    if (self.processes.items[index].args_len == 0) {
        if (try process_ops.readArgs(self.gpa, pid)) |cmdline| {
            var owned = cmdline;
            defer owned.deinit(self.gpa);
            try self.processes.items[index].setArgsFromCmdline(
                &self.metadata,
                self.gpa,
                owned.items,
            );
        }
    }
    var path_buf: [max_path_len]u8 = undefined;
    if (self.processes.items[index].exe_len == 0) {
        if (process_ops.readExecutable(pid, &path_buf)) |exe| {
            try self.processes.items[index].setExe(&self.metadata, self.gpa, exe);
        }
    }
    if (self.processes.items[index].cwd_len == 0) {
        if (process_ops.readCwd(pid, &path_buf)) |cwd| {
            try self.processes.items[index].setCwd(&self.metadata, self.gpa, cwd);
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
        self.exit_code = code;
    } else if (process_ops.exitSignal(status)) |signal| {
        self.exit_signal = signal;
        // The UI shows STOPPED · SIGNAL n; the log keeps the detail.
        // Suppressed in test binaries: their stderr garbles `zig build`
        // IPC progress output even when every test passes.
        if (comptime !builtin.is_test) {
            log.warn("target root terminated by signal {d}", .{
                signal,
            });
        }
    }
}

fn onRootExited(self: *Session, status: ?u32) void {
    if (status) |s| self.recordRootStatus(s);
    if (self.child) |*child| child.id = null;
    self.child = null;
    self.finishOpenProcesses(self.elapsed_ns);
    self.root_pid = null;
    self.running = false;
    signals.disarmTargetGroup();
    signals.clearTrackedPids();
    self.compactMetadata() catch {};
}

fn pollSession(self: *Session) void {
    const child = if (self.child) |*child| child else return;
    const pid = child.id orelse return;
    switch (process_ops.waitNowait(pid)) {
        .still_running, .interrupted => {},
        .reaped => |status| {
            self.onRootExited(status);
            return;
        },
        .no_child => {
            // ECHILD while the pid still exists means we do not own it (or a
            // race), so wait for an observable exit before ending capture.
            if (!signals.pidAlive(pid)) {
                self.onRootExited(null);
                return;
            }
        },
    }
}

fn finishOpenProcesses(self: *Session, at_ns: u64) void {
    for (self.processes.items, 0..) |process, index| {
        if (process.end_ns == null) self.finishProcess(index, at_ns, .capture_clipped);
    }
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
    self.recovered_count +%= 1;
    self.incomplete = true;
}

/// Rebuilds the append-only metadata arena so only bytes still referenced by
/// process records remain. Intended for capture completion, not the live path.
fn compactMetadata(self: *Session) Allocator.Error!void {
    var next = Process.MetadataStore.empty;
    errdefer next.deinit(self.gpa);
    try next.ensureTotalCapacity(self.gpa, self.metadata.items.len);

    var remap: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    defer remap.deinit(self.gpa);

    for (self.processes.items) |*process| {
        try remapMetadata(
            self.gpa,
            &next,
            &remap,
            self.metadata.items,
            &process.args_offset,
            process.args_len,
        );
        try remapMetadata(
            self.gpa,
            &next,
            &remap,
            self.metadata.items,
            &process.exe_offset,
            process.exe_len,
        );
        try remapMetadata(
            self.gpa,
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
    gpa: Allocator,
    dest: *Process.MetadataStore,
    remap: *std.AutoHashMapUnmanaged(usize, usize),
    src: []const u8,
    offset: *usize,
    len: usize,
) Allocator.Error!void {
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
    try dest.appendSlice(gpa, src[old..][0..len]);
    try remap.put(gpa, old, copied);
    offset.* = copied;
}

fn rootIndex(self: *const Session) ?usize {
    return if (self.root_pid) |pid| self.by_pid.get(pid) else null;
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
) void {
    if (event.name.len > 0) self.processes.items[index].setName(event.name, .process);
    self.processes.items[index].clearExecMetadata();
    self.label_revision +%= 1;
    if (event.exe) |exe| {
        self.processes.items[index].setExeFromKernel(
            &self.metadata,
            self.gpa,
            exe,
            event.exe_truncated,
        ) catch |err| {
            @branchHint(.cold);
            log.warn("could not store executable metadata: {s}", .{@errorName(err)});
        };
    }
    if (event.args) |args| {
        self.processes.items[index].setArgsFromKernel(
            &self.metadata,
            self.gpa,
            args,
        ) catch |err| {
            @branchHint(.cold);
            log.warn("could not store argv metadata: {s}", .{@errorName(err)});
        };
    }
    // A child may chdir between fork and exec. Refresh when platform metadata
    // is available, retaining the fork-time snapshot if it is not.
    self.refreshCwd(index) catch {};
    self.captureMissingMetadata(index) catch |err| {
        @branchHint(.cold);
        log.warn("could not store process metadata: {s}", .{@errorName(err)});
    };
}

/// Folds one capture event into the process tree. The event is borrowed only
/// for this call. A live tgid is updated in place; a finished tgid that
/// reappears becomes a new record. A fork whose parent is missing, an exec
/// whose pid is missing, or an exit whose pid was never seen, is recovered
/// under the session root so a lost backend record cannot hide that
/// subtree.
pub fn consumeEvent(self: *Session, event: capture.Event) void {
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
                log.warn(
                    "dropped process record for pid {d}: {s}",
                    .{ fork.pid, @errorName(err) },
                );
                return;
            };
        },
        .exec => |exec| {
            const index = self.liveIndex(exec.pid) orelse
                self.recoverFromExec(exec.pid, exec.name, event_ns) orelse return;
            self.applyExec(index, exec);
        },
        .exit => |exit| {
            const index = self.liveIndex(exit.pid) orelse
                self.recoverFromExit(exit.pid, exit.name, event_ns) orelse return;
            self.processes.items[index].recordFinalCpuSnapshot(
                self.gpa,
                event_ns,
                exit.cpu_ns,
            ) catch |err| {
                @branchHint(.cold);
                log.warn("could not store final CPU slice for pid {d}: {s}", .{
                    exit.pid,
                    @errorName(err),
                });
            };
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
    if (!self.running) return;
    const index = self.liveIndex(pid) orelse return;
    self.processes.items[index].recordCpuSnapshot(
        self.gpa,
        self.eventElapsedNs(timestamp_ns),
        cpu_ns,
    ) catch |err| {
        @branchHint(.cold);
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

test "terminateTargetGroup tears down the whole spawned group" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var collector = capture.Collector{}; // Default collector does not load the kernel backend.
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, &.{ "sh", "-c", "sleep 30 & sleep 30 & wait" });
    const root_pid = session.root_pid.?;

    try std.testing.expectEqual(root_pid, signals.armedTargetPgid());

    signals.terminateTargetGroup(root_pid);

    var spins: usize = 0;
    while (session.running and spins < 200) : (spins += 1) {
        session.update(&collector);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(!session.running);
    try std.testing.expectEqual(@as(std.posix.pid_t, 0), signals.armedTargetPgid());
    try std.testing.expectEqual(@as(usize, 0), session.activeCount());
}

test "stop reaps a job-control-stopped target" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "sh",
        "-c",
        "trap '' TERM; kill -STOP $$",
    });

    // Give the shell time to stop itself as a target reading from a background
    // terminal process group would after receiving SIGTTIN.
    try std.Io.sleep(std.testing.io, .fromMilliseconds(30), .awake);
    session.stop();

    try std.testing.expect(!session.running);
    try std.testing.expect(session.child == null);
    try std.testing.expectEqual(@as(usize, 0), session.activeCount());
    try std.testing.expectEqual(@as(std.posix.pid_t, 0), signals.armedTargetPgid());
}

test "session stops when the root exits while a descendant is still running" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, &.{ "sh", "-c", "sleep 2 & exec true" });
    const root_pid = session.root_pid.?;
    defer signals.terminateTargetGroup(root_pid);

    while (session.running and session.elapsed_ns < 5 * std.time.ns_per_s) {
        session.update(&collector);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(!session.running);
    try std.testing.expect(session.elapsed_ns < 1500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), session.activeCount());
    try std.testing.expectEqual(@as(std.posix.pid_t, 0), signals.armedTargetPgid());
}

test "session ends cleanly across a build-like churn of children" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, &.{
        "sh", "-c",
        \\i=0
        \\while [ "$i" -lt 200 ]; do
        \\  sh -c 'sleep 0.4' &
        \\  sh -c 'exec true' &
        \\  i=$((i+1))
        \\done
        \\wait
    });
    while (session.running and session.elapsed_ns < 15 * std.time.ns_per_s) {
        session.update(&collector);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
        if (session.running) {
            try std.testing.expectEqual(session.root_pid.?, signals.armedTargetPgid());
        }
    }
    try std.testing.expect(!session.running);
    try std.testing.expect(session.exit_code != null or session.exit_signal != null);
    try std.testing.expectEqual(@as(std.posix.pid_t, 0), signals.armedTargetPgid());
}

test "capture events drive the process tree" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, &.{ "sleep", "30" });

    const root_pid = session.root_pid.?;
    try std.testing.expectEqualStrings("sleep", session.processes.items[0].nameSlice());
    try std.testing.expectEqual(NameKind.process, session.processes.items[0].name_kind);
    var arg_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "30",
        session.processes.items[0].argSummary(session.metadataBytes(), &arg_buf),
    );
    try std.testing.expectEqualStrings(
        "sleep 30",
        session.processes.items[0].copyCmdline(session.metadataBytes(), &arg_buf),
    );
    const base_ns: u64 = @intCast(@max(0, session.started_at.nanoseconds));

    const fork_event = forkEvent(
        4242,
        root_pid,
        base_ns + 10 * std.time.ns_per_ms,
        "cc1plus",
    );
    session.consumeEvent(fork_event);

    try std.testing.expectEqual(@as(usize, 2), session.processes.items.len);
    const child_index = session.by_pid.get(4242).?;
    const child = session.processes.items[child_index];
    try std.testing.expectEqual(root_pid, child.parent_pid.?);
    try std.testing.expectEqualStrings("cc1plus", child.nameSlice());
    try std.testing.expectEqual(NameKind.process, child.name_kind);
    try std.testing.expectEqual(@as(u16, 1), child.depth);
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_ms), child.start_ns);
    try std.testing.expect(child.end_ns == null);
    try std.testing.expectEqual(Process.MetadataSource.inherited, child.args_source);
    try std.testing.expectEqualStrings(
        "sleep 30",
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
    try std.testing.expectEqual(
        Process.MetadataSource.kernel,
        session.processes.items[child_index].args_source,
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

    session.consumeEvent(exitEvent(
        4242,
        base_ns + 15 * std.time.ns_per_ms,
        "clang",
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

test "fork after exit reuses a tgid as a new record" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, &.{ "sleep", "30" });
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
    try session.start(&collector, &.{ "sleep", "30" });
    const root_pid = session.root_pid.?;
    const base_ns: u64 = @intCast(@max(0, session.started_at.nanoseconds));

    session.consumeEvent(exitEvent(
        root_pid,
        base_ns + 5 * std.time.ns_per_ms,
        "sleep",
        0,
    ));

    try std.testing.expectEqual(
        @as(u64, 5 * std.time.ns_per_ms),
        session.processes.items[0].end_ns.?,
    );
}

test "fork with unknown parent recovers a stub under the root" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, &.{ "sleep", "30" });
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
    try std.testing.expect(session.incomplete);
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
    try session.start(&collector, &.{ "sleep", "30" });
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
    try session.start(&collector, &.{ "sleep", "30" });
    const root_pid = session.root_pid.?;
    const base_ns: u64 = @intCast(@max(0, session.started_at.nanoseconds));

    var exit_event = exitEvent(8888, base_ns + 6 * std.time.ns_per_ms, "sleep", 0);
    session.consumeEvent(exit_event);

    try std.testing.expectEqual(@as(usize, 2), session.processes.items.len);
    try std.testing.expect(session.by_pid.get(8888) == null);
    const index = session.latestIndex(8888).?;
    const process = session.processes.items[index];
    try std.testing.expectEqual(root_pid, process.parent_pid.?);
    try std.testing.expectEqual(Process.Origin.recovered_exit, process.origin);
    try std.testing.expectEqual(Process.EndKind.observed_exit, process.end_kind);
    try std.testing.expectEqualStrings("sleep", process.nameSlice());
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
    if (capture.backend != .linux_ebpf) return error.SkipZigTest;
    var collector = capture.Collector.init();
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
    try session.start(&collector, &.{ "sh", "-c", "sleep 0.05 & wait" });

    var spins: usize = 0;
    while (session.running and spins < 200) : (spins += 1) {
        session.update(&collector);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(!session.running);
    try std.testing.expect(session.processes.items.len >= 2);
}

test "exec does not rebuild tree topology" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, &.{ "sleep", "30" });
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

test "metadata compaction keeps reachable argv and drops superseded bytes" {
    var collector = capture.Collector{};
    var session = Session.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    try session.start(&collector, &.{ "sleep", "30" });
    const before = session.metadata.items.len;
    try session.processes.items[0].setArgsFromArgv(
        &session.metadata,
        std.testing.allocator,
        &.{ "replaced", "argv" },
    );
    const after_replace = session.metadata.items.len;
    try std.testing.expect(after_replace > before);
    try session.compactMetadata();
    var cmd_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "replaced argv",
        session.processes.items[0].copyCmdline(session.metadataBytes(), &cmd_buf),
    );
    try std.testing.expect(session.metadata.items.len < after_replace);
}

test "root label matches the process when argv basename equals comm" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var comm_buf: [max_name_len]u8 = undefined;
    const self_pid = process_ops.currentPid();
    const comm = process_ops.readName(self_pid, &comm_buf) orelse return;
    var argv_buf: [max_name_len]u8 = undefined;
    @memcpy(argv_buf[0..comm.len], comm);
    const named = Session.rootLabel(self_pid, argv_buf[0..comm.len], &comm_buf);
    try std.testing.expectEqual(NameKind.process, named.kind);
    try std.testing.expectEqualStrings(argv_buf[0..comm.len], named.text);
}

test "root label is other when argv basename does not match comm" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var comm_buf: [max_name_len]u8 = undefined;
    const named = Session.rootLabel(1, "build.sh", &comm_buf);
    try std.testing.expectEqual(NameKind.other, named.kind);
    try std.testing.expectEqualStrings("build.sh", named.text);
}
