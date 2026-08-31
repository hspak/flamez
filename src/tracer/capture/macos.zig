//! macOS process capture using descendant-scoped Endpoint Security when
//! available, with a dedicated kqueue/libproc recovery worker otherwise.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const Process = @import("../Process.zig");
const capture = @import("../capture.zig");
const process_ops = @import("../process_ops.zig");

const log = std.log.scoped(.macos_capture);

const pending_event_queue_bytes = 16 * 1024 * 1024;
const pid_snapshot_slack = 16;
const pid_snapshot_retry_limit = 4;

comptime {
    if (builtin.cpu.arch != .aarch64) {
        @compileError("the macOS capture backend targets Apple silicon (aarch64) only");
    }
}

const ProcessIdentity = extern struct {
    parent_pid: std.posix.pid_t,
    pid_version: i32,
    start_seconds: u64,
    start_microseconds: u64,
    unique_id: u64,
    parent_unique_id: u64,
    parent_pid_version: i32,
    reserved: u32,

    fn eql(a: ProcessIdentity, b: ProcessIdentity) bool {
        return a.unique_id == b.unique_id and
            a.start_seconds == b.start_seconds and
            a.start_microseconds == b.start_microseconds;
    }

    fn sameImage(a: ProcessIdentity, b: ProcessIdentity) bool {
        return eql(a, b) and a.pid_version == b.pid_version;
    }
};

const IdentityCandidate = struct {
    pid: std.posix.pid_t,
    identity: ProcessIdentity,
};

const Tracked = struct {
    identity: ProcessIdentity,
    generation: usize,
    cpu_ns: u64 = 0,
    needs_metadata: bool = true,
    name: [48]u8 = [_]u8{0} ** 48,
    name_len: u8 = 0,

    fn nameSlice(self: *const Tracked) []const u8 {
        return self.name[0..self.name_len];
    }
};

const StoredName = struct {
    bytes: [Process.max_name_len]u8 = [_]u8{0} ** Process.max_name_len,
    len: u8 = 0,

    fn init(value: []const u8) StoredName {
        var result = StoredName{};
        const amount = @min(value.len, result.bytes.len);
        @memcpy(result.bytes[0..amount], value[0..amount]);
        result.len = @intCast(amount);
        return result;
    }

    fn slice(self: *const StoredName) []const u8 {
        return self.bytes[0..self.len];
    }
};

const StoredPath = struct {
    bytes: [Process.max_path_len]u8 = [_]u8{0} ** Process.max_path_len,
    len: u16 = 0,
    truncated: bool = false,

    fn set(self: *StoredPath, value: []const u8) void {
        const amount = @min(value.len, self.bytes.len);
        @memcpy(self.bytes[0..amount], value[0..amount]);
        self.len = @intCast(amount);
        self.truncated = value.len >= self.bytes.len;
    }

    fn optionalSlice(self: *const StoredPath) ?[]const u8 {
        if (self.len == 0) return null;
        return self.bytes[0..self.len];
    }
};

const PendingFork = struct {
    pid: std.posix.pid_t,
    parent_pid: std.posix.pid_t,
    name: StoredName,
};

const PendingExec = struct {
    pid: std.posix.pid_t,
    name: StoredName,
    exe: StoredPath = .{},
    args: std.ArrayList(u8) = .empty,
    args_present: bool = false,
    cwd: StoredPath = .{},

    fn deinit(self: *PendingExec, gpa: Allocator) void {
        self.args.deinit(gpa);
        self.* = undefined;
    }
};

const PendingExit = struct {
    pid: std.posix.pid_t,
    name: StoredName,
    cpu_ns: u64,
    cpu_final: bool,
};

const PendingEvent = struct {
    timestamp_ns: u64,
    payload: union(enum) {
        fork: PendingFork,
        exec: PendingExec,
        exit: PendingExit,
    },

    fn deinit(self: *PendingEvent, gpa: Allocator) void {
        switch (self.payload) {
            .exec => |*event| event.deinit(gpa),
            .fork, .exit => {},
        }
        self.* = undefined;
    }

    fn allocationBytes(self: *const PendingEvent) usize {
        return @sizeOf(PendingEvent) + switch (self.payload) {
            .exec => |exec| exec.args.capacity,
            .fork, .exit => 0,
        };
    }

    fn deliver(self: *const PendingEvent, sink: capture.Sink) void {
        const event: capture.Event = switch (self.payload) {
            .fork => |*fork| .{
                .timestamp_ns = self.timestamp_ns,
                .payload = .{ .fork = .{
                    .pid = fork.pid,
                    .parent_pid = fork.parent_pid,
                    .name = fork.name.slice(),
                } },
            },
            .exec => |*exec| .{
                .timestamp_ns = self.timestamp_ns,
                .payload = .{ .exec = .{
                    .pid = exec.pid,
                    .name = exec.name.slice(),
                    .exe = exec.exe.optionalSlice(),
                    .args = if (exec.args_present) exec.args.items else null,
                    .cwd = exec.cwd.optionalSlice(),
                    .exe_truncated = exec.exe.truncated,
                    .cwd_truncated = exec.cwd.truncated,
                    .metadata_source = .process_inspection,
                    .inspect_missing = false,
                } },
            },
            .exit => |*exit_event| .{
                .timestamp_ns = self.timestamp_ns,
                .payload = .{ .exit = .{
                    .pid = exit_event.pid,
                    .name = exit_event.name.slice(),
                    .cpu_ns = exit_event.cpu_ns,
                    .cpu_final = exit_event.cpu_final,
                } },
            },
        };
        sink.event(event);
    }
};

const CpuTarget = struct {
    pid: std.posix.pid_t,
    identity: ProcessIdentity,
    generation: usize,
};

const PidList = enum {
    all,
    children,
    process_group,
};

const PidListFn = *const fn (
    context: ?*anyopaque,
    kind: PidList,
    identifier: std.posix.pid_t,
    buffer: ?*anyopaque,
    buffer_size: c_int,
) c_int;

const CpuTimeFn = *const fn (
    context: ?*anyopaque,
    pid: std.posix.pid_t,
    total_ns: *u64,
) c_int;

const IdentityFn = *const fn (
    context: ?*anyopaque,
    pid: std.posix.pid_t,
    identity: *ProcessIdentity,
) c_int;

const TimestampFn = *const fn (context: ?*anyopaque) u64;

const EsHandle = opaque {};

const EsOpenResult = enum(c_int) {
    active = 0,
    unavailable = 1,
    not_entitled = 2,
    rejected = 3,
};

const EsEventKind = enum(c_int) {
    fork = 1,
    exec = 2,
    exit = 3,
};

const EsEvent = extern struct {
    kind: EsEventKind,
    pid: std.posix.pid_t,
    parent_pid: std.posix.pid_t,
    pid_version: i32,
    parent_pid_version: i32,
    timestamp_ns: u64,
    cpu_ns: u64,
    name: ?[*]const u8,
    name_len: usize,
    executable: ?[*]const u8,
    executable_len: usize,
    executable_truncated: u8,
    args: ?[*]const u8,
    args_len: usize,
    cwd: ?[*]const u8,
    cwd_len: usize,
    cwd_truncated: u8,
    cpu_final: u8,
};

const EsPoll = struct {
    collector: *Collector,
    sink: capture.Sink,
};

extern "c" fn proc_listchildpids(
    parent_pid: std.posix.pid_t,
    buffer: ?*anyopaque,
    buffer_size: c_int,
) c_int;
extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffer_size: c_int) c_int;
extern "c" fn proc_listpgrppids(
    process_group: std.posix.pid_t,
    buffer: ?*anyopaque,
    buffer_size: c_int,
) c_int;
extern "c" fn flamez_macos_process_identity(
    pid: std.posix.pid_t,
    identity: *ProcessIdentity,
) c_int;
extern "c" fn flamez_macos_cpu_time(pid: std.posix.pid_t, total_ns: *u64) c_int;
extern "c" fn flamez_macos_es_open(
    collector: *?*EsHandle,
    diagnostic: [*]u8,
    diagnostic_size: usize,
) EsOpenResult;
extern "c" fn flamez_macos_es_close(collector: *EsHandle) void;
extern "c" fn flamez_macos_es_poll(
    collector: *EsHandle,
    callback: *const fn (?*anyopaque, *const EsEvent) callconv(.c) void,
    context: ?*anyopaque,
) c_int;
extern "c" fn flamez_macos_es_sync(collector: *EsHandle) c_int;
extern "c" fn flamez_macos_es_lost_events(collector: *EsHandle) u64;
extern "c" fn flamez_macos_es_test_create(queue_limit: usize) ?*EsHandle;
extern "c" fn flamez_macos_es_test_destroy(collector: *EsHandle) void;
extern "c" fn flamez_macos_es_test_record_size() usize;
extern "c" fn flamez_macos_es_test_enqueue(
    collector: *EsHandle,
    event: *const EsEvent,
) c_int;
extern "c" fn flamez_macos_es_test_capture_sequence(
    collector: *EsHandle,
    message_version: u32,
    global_sequence: u64,
) void;
extern "c" fn flamez_macos_es_test_capture_fixture(collector: *EsHandle) void;
extern "c" fn flamez_macos_es_test_mach_time_to_ns(value: u64) u64;
extern "c" fn flamez_macos_es_test_mach_now_to_ns() u64;
extern "c" fn flamez_macos_es_test_prepare_sync(
    collector: *EsHandle,
    reject: c_int,
) void;
extern "c" fn flamez_macos_es_test_complete_sync(collector: *EsHandle) void;

fn systemListPids(
    _: ?*anyopaque,
    kind: PidList,
    identifier: std.posix.pid_t,
    buffer: ?*anyopaque,
    buffer_size: c_int,
) c_int {
    return switch (kind) {
        .all => proc_listallpids(buffer, buffer_size),
        .children => proc_listchildpids(identifier, buffer, buffer_size),
        .process_group => proc_listpgrppids(identifier, buffer, buffer_size),
    };
}

fn systemCpuTime(
    _: ?*anyopaque,
    pid: std.posix.pid_t,
    total_ns: *u64,
) c_int {
    return flamez_macos_cpu_time(pid, total_ns);
}

fn systemIdentity(
    _: ?*anyopaque,
    pid: std.posix.pid_t,
    identity: *ProcessIdentity,
) c_int {
    return flamez_macos_process_identity(pid, identity);
}

fn systemTimestamp(_: ?*anyopaque) u64 {
    return nowNs();
}

comptime {
    std.debug.assert(@sizeOf(ProcessIdentity) == 48);
    std.debug.assert(@offsetOf(ProcessIdentity, "parent_pid") == 0);
    std.debug.assert(@offsetOf(ProcessIdentity, "pid_version") == 4);
    std.debug.assert(@offsetOf(ProcessIdentity, "start_seconds") == 8);
    std.debug.assert(@offsetOf(ProcessIdentity, "start_microseconds") == 16);
    std.debug.assert(@offsetOf(ProcessIdentity, "unique_id") == 24);
    std.debug.assert(@offsetOf(ProcessIdentity, "parent_unique_id") == 32);
    std.debug.assert(@offsetOf(ProcessIdentity, "parent_pid_version") == 40);
    std.debug.assert(@offsetOf(ProcessIdentity, "reserved") == 44);
    std.debug.assert(@sizeOf(EsEvent) == 120);
    std.debug.assert(@offsetOf(EsEvent, "kind") == 0);
    std.debug.assert(@offsetOf(EsEvent, "pid") == 4);
    std.debug.assert(@offsetOf(EsEvent, "parent_pid") == 8);
    std.debug.assert(@offsetOf(EsEvent, "pid_version") == 12);
    std.debug.assert(@offsetOf(EsEvent, "parent_pid_version") == 16);
    std.debug.assert(@offsetOf(EsEvent, "timestamp_ns") == 24);
    std.debug.assert(@offsetOf(EsEvent, "cpu_ns") == 32);
    std.debug.assert(@offsetOf(EsEvent, "name") == 40);
    std.debug.assert(@offsetOf(EsEvent, "name_len") == 48);
    std.debug.assert(@offsetOf(EsEvent, "executable") == 56);
    std.debug.assert(@offsetOf(EsEvent, "executable_len") == 64);
    std.debug.assert(@offsetOf(EsEvent, "executable_truncated") == 72);
    std.debug.assert(@offsetOf(EsEvent, "args") == 80);
    std.debug.assert(@offsetOf(EsEvent, "args_len") == 88);
    std.debug.assert(@offsetOf(EsEvent, "cwd") == 96);
    std.debug.assert(@offsetOf(EsEvent, "cwd_len") == 104);
    std.debug.assert(@offsetOf(EsEvent, "cwd_truncated") == 112);
    std.debug.assert(@offsetOf(EsEvent, "cpu_final") == 113);
    std.debug.assert(@intFromEnum(EsOpenResult.active) == 0);
    std.debug.assert(@intFromEnum(EsOpenResult.unavailable) == 1);
    std.debug.assert(@intFromEnum(EsOpenResult.not_entitled) == 2);
    std.debug.assert(@intFromEnum(EsOpenResult.rejected) == 3);
    std.debug.assert(@intFromEnum(EsEventKind.fork) == 1);
    std.debug.assert(@intFromEnum(EsEventKind.exec) == 2);
    std.debug.assert(@intFromEnum(EsEventKind.exit) == 3);
}

/// Tracks a launched process subtree with kqueue and private process-inspection APIs.
pub const Collector = struct {
    gpa: Allocator = std.heap.c_allocator,
    kqueue_fd: c_int = -1,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    worker: ?std.Thread = null,
    worker_stop: std.atomic.Value(bool) = .init(false),
    es_handle: ?*EsHandle = null,
    es_versions: std.AutoHashMapUnmanaged(std.posix.pid_t, i32) = .empty,
    launcher_pid: ?std.posix.pid_t = null,
    tracked: std.AutoHashMapUnmanaged(std.posix.pid_t, Tracked) = .empty,
    pid_snapshot: std.ArrayList(std.posix.pid_t) = .empty,
    identity_snapshot: std.ArrayList(IdentityCandidate) = .empty,
    pending_events: std.ArrayList(PendingEvent) = .empty,
    delivery_events: std.ArrayList(PendingEvent) = .empty,
    pending_event_bytes: usize = 0,
    delivery_event_bytes: usize = 0,
    pending_event_limit: usize = pending_event_queue_bytes,
    cpu_targets: std.ArrayList(CpuTarget) = .empty,
    root_pid: ?std.posix.pid_t = null,
    root_pgid: ?std.posix.pid_t = null,
    next_generation: usize = 0,
    worker_lost_events: u64 = 0,
    worker_ring_events: i32 = 0,
    lost_events: u64 = 0,
    last_ring_events: i32 = 0,
    last_cpu_samples: usize = 0,
    diagnostic_buffer: [256]u8 = [_]u8{0} ** 256,
    diagnostic_len: usize = 0,
    exact_diagnostic_buffer: [256]u8 = [_]u8{0} ** 256,
    exact_diagnostic_len: usize = 0,
    endpoint_security_mode: EndpointSecurityMode = .automatic,

    pub const EndpointSecurityMode = enum {
        automatic,
        required,
        disabled,
    };

    pub const Options = struct {
        endpoint_security: EndpointSecurityMode = .automatic,
    };

    /// Opens the process-event queue. Process inspection is tested lazily once
    /// the launched root PID exists. `gpa` is retained and **assume** it is safe
    /// to call concurrently from the capture worker and the session thread.
    pub fn init(gpa: Allocator) Collector {
        return initWithOptions(gpa, .{
            .endpoint_security = if (build_options.macos_require_endpoint_security)
                .required
            else
                .automatic,
        });
    }

    /// Opens capture with an explicit exact-backend policy. Disabling Endpoint
    /// Security exists for fallback validation; production defaults to automatic.
    pub fn initWithOptions(gpa: Allocator, options: Options) Collector {
        var self = Collector{
            .gpa = gpa,
            .endpoint_security_mode = options.endpoint_security,
        };
        self.kqueue_fd = std.c.kqueue();
        if (self.kqueue_fd < 0) {
            self.setDiagnostic("could not create the macOS process-event kqueue");
        }
        return self;
    }

    /// Stops the worker, releases process tracking storage, and invalidates `self`.
    pub fn deinit(self: *Collector) void {
        self.stopWorker();
        self.closeEs();
        self.lock();
        self.clearTrackedLocked();
        self.clearPendingEventsLocked();
        self.pending_events.deinit(self.gpa);
        self.delivery_events.deinit(self.gpa);
        self.cpu_targets.deinit(self.gpa);
        self.identity_snapshot.deinit(self.gpa);
        self.pid_snapshot.deinit(self.gpa);
        self.es_versions.deinit(self.gpa);
        self.tracked.deinit(self.gpa);
        self.unlock();
        if (self.kqueue_fd >= 0) _ = std.c.close(self.kqueue_fd);
        std.debug.assert(std.c.pthread_mutex_destroy(&self.mutex) == .SUCCESS);
        self.* = undefined;
    }

    /// Returns whether a process-event queue was created.
    pub fn available(self: *const Collector) bool {
        return self.kqueue_fd >= 0;
    }

    /// macOS process inspection does not require a post-attach privilege drop.
    pub fn dropPrivileges(_: *const Collector) capture.DropPrivilegesError!void {}

    /// Returns collector-owned initialization diagnostics.
    pub fn diagnosticSlice(self: *const Collector) []const u8 {
        return self.diagnostic_buffer[0..self.diagnostic_len];
    }

    /// Explains whether exact Endpoint Security capture was selected or why
    /// this launch uses snapshot recovery.
    pub fn exactDiagnosticSlice(self: *const Collector) []const u8 {
        return self.exact_diagnostic_buffer[0..self.exact_diagnostic_len];
    }

    /// Returns the lifecycle guarantee active for the current launch.
    pub fn fidelity(self: *const Collector) capture.Fidelity {
        return if (self.es_handle != null) .exact else .snapshot_recovery;
    }

    /// Clears a previous capture. The kqueue fallback cannot atomically arm an
    /// unknown future child; the first recursive snapshot begins in `trackRoot`.
    pub fn armLaunch(
        self: *Collector,
        launcher_pid: std.posix.pid_t,
    ) capture.ArmLaunchError!void {
        self.stopWorker();
        self.closeEs();
        self.lock();
        self.clearTrackedLocked();
        self.clearPendingEventsLocked();
        self.es_versions.clearRetainingCapacity();
        self.identity_snapshot.clearRetainingCapacity();
        self.lost_events = 0;
        self.last_ring_events = 0;
        self.last_cpu_samples = 0;
        self.worker_lost_events = 0;
        self.worker_ring_events = 0;
        self.root_pid = null;
        self.root_pgid = null;
        self.launcher_pid = null;
        self.worker_stop.store(false, .release);
        self.unlock();

        self.launcher_pid = launcher_pid;
        @memset(&self.exact_diagnostic_buffer, 0);
        if (self.endpoint_security_mode == .disabled) {
            self.setExactDiagnostic("Endpoint Security disabled for fallback validation");
            return;
        }
        const result = flamez_macos_es_open(
            &self.es_handle,
            &self.exact_diagnostic_buffer,
            self.exact_diagnostic_buffer.len,
        );
        self.exact_diagnostic_len = std.mem.indexOfScalar(
            u8,
            &self.exact_diagnostic_buffer,
            0,
        ) orelse self.exact_diagnostic_buffer.len;
        switch (result) {
            .active => {},
            .unavailable, .not_entitled, .rejected => {
                self.es_handle = null;
                if (self.endpoint_security_mode == .required) {
                    return error.ExactCaptureUnavailable;
                }
                log.info("{s}; using kqueue snapshot recovery", .{
                    self.exactDiagnosticSlice(),
                });
            },
        }
    }

    /// Registers the launched root and establishes its PID-generation identity.
    pub fn trackRoot(
        self: *Collector,
        pid: std.posix.pid_t,
    ) capture.TrackRootError!void {
        if (self.kqueue_fd < 0) return;
        self.lock();
        defer self.unlock();
        if (self.es_handle != null) {
            self.es_versions.put(self.gpa, pid, 0) catch
                return error.LaunchTrackingRejected;
            self.root_pid = pid;
            self.root_pgid = pid;

            // Exact lifecycle records are already queued if a tiny root has
            // exited. Live process inspection is optional CPU enrichment.
            var identity: ProcessIdentity = undefined;
            if (flamez_macos_process_identity(pid, &identity) == 0) {
                self.tracked.ensureUnusedCapacity(self.gpa, 1) catch {
                    self.noteLossLocked("could not allocate exact root CPU tracking state");
                    return;
                };
                var tracked = Tracked{
                    .identity = identity,
                    .generation = self.newGeneration(),
                };
                self.refreshName(pid, &tracked);
                self.tracked.putAssumeCapacity(pid, tracked);
            }
            return;
        }

        var identity: ProcessIdentity = undefined;
        if (flamez_macos_process_identity(pid, &identity) != 0)
            return error.LaunchTrackingRejected;
        self.tracked.ensureUnusedCapacity(self.gpa, 1) catch
            return error.LaunchTrackingRejected;
        const generation = self.newGeneration();
        if (!self.register(pid, generation)) return error.LaunchTrackingRejected;
        var tracked = Tracked{ .identity = identity, .generation = generation };
        self.refreshName(pid, &tracked);
        self.tracked.putAssumeCapacity(pid, tracked);
        // Session spawns the target with pgid=0, making the child the leader
        // of an otherwise empty process group.
        self.root_pid = pid;
        self.root_pgid = pid;
        self.worker_stop.store(false, .release);
        self.worker = std.Thread.spawn(.{}, workerMain, .{self}) catch {
            _ = self.tracked.remove(pid);
            self.deleteRegistration(pid);
            self.root_pid = null;
            self.root_pgid = null;
            return error.LaunchTrackingRejected;
        };
    }

    /// Removes a tracked PID and its kqueue registration.
    pub fn untrack(self: *Collector, pid: std.posix.pid_t) void {
        self.lock();
        defer self.unlock();
        const had_tracked = self.tracked.remove(pid);
        const had_es_version = self.es_versions.remove(pid);
        if (!had_tracked and !had_es_version) return;
        if (self.es_handle == null and had_tracked) self.deleteRegistration(pid);
        if (self.root_pid == pid) self.worker_stop.store(true, .release);
    }

    /// Delivers worker-owned lifecycle observations without inspecting live
    /// processes or blocking the render thread.
    pub fn pollEvents(self: *Collector, sink: capture.Sink) void {
        if (self.es_handle) |handle| {
            var poll = EsPoll{ .collector = self, .sink = sink };
            self.last_ring_events = flamez_macos_es_poll(handle, consumeEsEvent, &poll);
            self.lock();
            const local_lost_events = self.worker_lost_events;
            self.unlock();
            self.lost_events = flamez_macos_es_lost_events(handle) +|
                local_lost_events;
            return;
        }
        std.debug.assert(self.delivery_events.items.len == 0);
        std.debug.assert(self.delivery_event_bytes == 0);
        self.lock();
        std.mem.swap(
            std.ArrayList(PendingEvent),
            &self.pending_events,
            &self.delivery_events,
        );
        self.delivery_event_bytes = self.pending_event_bytes;
        self.pending_event_bytes = 0;
        self.lost_events = self.worker_lost_events;
        self.last_ring_events = self.worker_ring_events;
        self.worker_ring_events = 0;
        self.unlock();

        for (self.delivery_events.items) |*event| {
            event.deliver(sink);
            event.deinit(self.gpa);
        }
        self.delivery_events.clearRetainingCapacity();
        self.delivery_event_bytes = 0;
    }

    /// Flushes lifecycle work known to the kernel when the root was reaped.
    /// Exact capture places an ES queue barrier; fallback capture joins its
    /// worker after one last kqueue/recovery pass.
    pub fn flushEvents(self: *Collector, sink: capture.Sink) void {
        if (self.es_handle) |handle| {
            if (flamez_macos_es_sync(handle) != 0) {
                self.lock();
                self.noteLossLocked("could not synchronize the Endpoint Security queue");
                self.unlock();
            }
        } else {
            self.stopWorker();
        }
        self.pollEvents(sink);
    }

    /// Samples cumulative user plus system CPU nanoseconds for every live PID.
    pub fn snapshotCpu(self: *Collector, sink: capture.Sink) void {
        self.snapshotCpuWith(
            sink,
            null,
            systemCpuTime,
            systemIdentity,
            systemTimestamp,
        );
    }

    fn snapshotCpuWith(
        self: *Collector,
        sink: capture.Sink,
        context: ?*anyopaque,
        cpu_time_fn: CpuTimeFn,
        identity_fn: IdentityFn,
        timestamp_fn: TimestampFn,
    ) void {
        self.last_cpu_samples = 0;
        if (self.kqueue_fd < 0) return;
        self.cpu_targets.clearRetainingCapacity();
        self.lock();
        var iterator = self.tracked.iterator();
        while (iterator.next()) |entry| {
            self.cpu_targets.append(self.gpa, .{
                .pid = entry.key_ptr.*,
                .identity = entry.value_ptr.identity,
                .generation = entry.value_ptr.generation,
            }) catch {
                self.noteLossLocked("could not allocate the CPU snapshot target list");
                break;
            };
        }
        self.unlock();

        for (self.cpu_targets.items) |target| {
            var cpu_ns: u64 = 0;
            if (cpu_time_fn(context, target.pid, &cpu_ns) != 0) continue;
            // A large target tree can take materially longer than one frame to
            // inspect. Timestamp this PID's total at its own read boundary so
            // later totals are not projected back to the start of the scan.
            const timestamp_ns = timestamp_fn(context);
            var identity: ProcessIdentity = undefined;
            if (identity_fn(context, target.pid, &identity) != 0) continue;
            if (!ProcessIdentity.eql(target.identity, identity)) continue;

            self.lock();
            const tracked = self.tracked.getPtr(target.pid) orelse {
                self.unlock();
                continue;
            };
            if (tracked.generation != target.generation or
                !ProcessIdentity.eql(tracked.identity, identity))
            {
                self.unlock();
                continue;
            }
            tracked.cpu_ns = @max(tracked.cpu_ns, cpu_ns);
            const stored_cpu_ns = tracked.cpu_ns;
            self.unlock();

            sink.cpuSample(target.pid, stored_cpu_ns, timestamp_ns);
            self.last_cpu_samples += 1;
        }
    }

    fn consumeEndpointSecurityEvent(
        self: *Collector,
        sink: capture.Sink,
        event: *const EsEvent,
    ) void {
        const name = esSlice(event.name, event.name_len) orelse "";
        switch (event.kind) {
            .fork => self.consumeEsFork(sink, event, name),
            .exec => self.consumeEsExec(sink, event, name),
            .exit => self.consumeEsExit(sink, event, name),
        }
    }

    fn consumeEsFork(
        self: *Collector,
        sink: capture.Sink,
        event: *const EsEvent,
        name: []const u8,
    ) void {
        self.lock();
        const root_pid = self.root_pid orelse {
            self.unlock();
            return;
        };
        if (event.pid == root_pid) {
            if (self.launcher_pid != null and self.launcher_pid.? == event.parent_pid) {
                self.es_versions.put(self.gpa, event.pid, event.pid_version) catch {
                    self.noteLossLocked("could not track the exact root PID generation");
                };
            }
            self.unlock();
            return;
        }
        const parent_version = self.es_versions.get(event.parent_pid) orelse {
            self.unlock();
            return;
        };
        if (parent_version != 0 and parent_version != event.parent_pid_version) {
            self.unlock();
            return;
        }
        self.es_versions.put(self.gpa, event.pid, event.pid_version) catch {
            self.noteLossLocked("could not track an exact child PID generation");
            self.unlock();
            return;
        };
        self.admitEsCpuLocked(event.pid, name);
        self.unlock();

        sink.event(.{
            .timestamp_ns = event.timestamp_ns,
            .payload = .{ .fork = .{
                .pid = event.pid,
                .parent_pid = event.parent_pid,
                .name = name,
            } },
        });
    }

    fn consumeEsExec(
        self: *Collector,
        sink: capture.Sink,
        event: *const EsEvent,
        name: []const u8,
    ) void {
        self.lock();
        const version = self.es_versions.getPtr(event.pid) orelse {
            self.unlock();
            return;
        };
        version.* = event.pid_version;
        self.unlock();

        sink.event(.{
            .timestamp_ns = event.timestamp_ns,
            .payload = .{ .exec = .{
                .pid = event.pid,
                .name = name,
                .exe = esSlice(event.executable, event.executable_len),
                .args = esSlice(event.args, event.args_len),
                .cwd = esSlice(event.cwd, event.cwd_len),
                .exe_truncated = event.executable_truncated != 0,
                .cwd_truncated = event.cwd_truncated != 0,
                .metadata_source = .kernel,
                .inspect_missing = false,
            } },
        });
    }

    fn consumeEsExit(
        self: *Collector,
        sink: capture.Sink,
        event: *const EsEvent,
        name: []const u8,
    ) void {
        self.lock();
        const version = self.es_versions.get(event.pid) orelse {
            self.unlock();
            return;
        };
        if (version != 0 and version != event.pid_version) {
            self.unlock();
            return;
        }
        _ = self.es_versions.remove(event.pid);
        var cpu_ns = event.cpu_ns;
        if (self.tracked.fetchRemove(event.pid)) |entry| {
            if (event.cpu_final == 0) cpu_ns = @max(cpu_ns, entry.value.cpu_ns);
        }
        self.unlock();

        sink.event(.{
            .timestamp_ns = event.timestamp_ns,
            .payload = .{ .exit = .{
                .pid = event.pid,
                .name = name,
                .cpu_ns = cpu_ns,
                .cpu_final = event.cpu_final != 0,
            } },
        });
    }

    fn admitEsCpuLocked(
        self: *Collector,
        pid: std.posix.pid_t,
        name: []const u8,
    ) void {
        var identity: ProcessIdentity = undefined;
        if (flamez_macos_process_identity(pid, &identity) != 0) return;
        self.tracked.ensureUnusedCapacity(self.gpa, 1) catch {
            self.noteLossLocked("could not allocate exact CPU tracking state");
            return;
        };
        var tracked = Tracked{
            .identity = identity,
            .generation = self.newGeneration(),
            .needs_metadata = false,
        };
        const amount = @min(name.len, tracked.name.len);
        @memcpy(tracked.name[0..amount], name[0..amount]);
        tracked.name_len = @intCast(amount);
        self.tracked.putAssumeCapacity(pid, tracked);
    }

    fn workerMain(self: *Collector) void {
        self.lock();
        var timestamp_ns = nowNs();
        self.emitPendingMetadataLocked(timestamp_ns);
        self.discoverDescendantsLocked(timestamp_ns);
        self.emitPendingMetadataLocked(timestamp_ns);
        self.unlock();

        var events: [256]std.c.Kevent = undefined;
        const timeout = std.c.timespec{
            .sec = 0,
            .nsec = 4 * std.time.ns_per_ms,
        };
        const fork_drain_timeout = std.c.timespec{
            .sec = 0,
            .nsec = std.time.ns_per_ms / 4,
        };
        var escaped_scan_pending = false;
        while (!self.worker_stop.load(.acquire)) {
            const amount = std.c.kevent(
                self.kqueue_fd,
                events[0..0].ptr,
                0,
                &events,
                events.len,
                &timeout,
            );
            const stop_after_pass = self.worker_stop.load(.acquire);
            if (amount < 0 and std.c.errno(amount) == .INTR) continue;

            timestamp_ns = nowNs();
            self.lock();
            // Inspect before consuming a root-exit hint. Session needs the
            // root record to anchor a process-group recovery observation.
            self.discoverDescendantsLocked(timestamp_ns);
            self.emitPendingMetadataLocked(timestamp_ns);
            if (amount < 0) {
                self.noteLossLocked("kevent polling failed");
                self.unlock();
                continue;
            }
            self.worker_ring_events +|= amount;
            escaped_scan_pending = self.consumeReadyEventsLocked(
                events[0..@intCast(amount)],
                timestamp_ns,
            ) or escaped_scan_pending;

            var quiet = amount == 0;
            var drain_pass: usize = 0;
            while (escaped_scan_pending and !quiet and drain_pass < 8) : (drain_pass += 1) {
                const drained = std.c.kevent(
                    self.kqueue_fd,
                    events[0..0].ptr,
                    0,
                    &events,
                    events.len,
                    &fork_drain_timeout,
                );
                if (drained < 0) {
                    if (std.c.errno(drained) != .INTR) {
                        self.noteLossLocked("kevent fork-burst drain failed");
                    }
                    break;
                }
                if (drained == 0) {
                    quiet = true;
                    break;
                }
                timestamp_ns = nowNs();
                self.worker_ring_events +|= drained;
                escaped_scan_pending = self.consumeReadyEventsLocked(
                    events[0..@intCast(drained)],
                    timestamp_ns,
                ) or escaped_scan_pending;
            }
            if (escaped_scan_pending) {
                self.discoverEscapedDescendantsLocked(timestamp_ns);
                self.emitPendingMetadataLocked(timestamp_ns);
                escaped_scan_pending = false;
            }
            self.unlock();
            if (stop_after_pass) break;
        }
    }

    fn consumeReadyEventsLocked(
        self: *Collector,
        events: []const std.c.Kevent,
        timestamp_ns: u64,
    ) bool {
        const fork_hint = self.hasTrackedForkHintLocked(events);
        for (events) |event| self.consumeKeventLocked(event, timestamp_ns);
        if (self.root_pid) |root| {
            if (self.tracked.contains(root)) self.discoverDescendantsLocked(timestamp_ns);
        }
        self.emitPendingMetadataLocked(timestamp_ns);
        return fork_hint;
    }

    fn hasTrackedForkHintLocked(self: *Collector, events: []const std.c.Kevent) bool {
        for (events) |event| {
            if (event.flags & std.c.EV.ERROR != 0 or
                event.fflags & std.c.NOTE.FORK == 0)
            {
                continue;
            }
            const pid: std.posix.pid_t = @intCast(event.ident);
            const tracked = self.tracked.get(pid) orelse continue;
            if (tracked.generation == event.udata) return true;
        }
        return false;
    }

    fn consumeKeventLocked(
        self: *Collector,
        event: std.c.Kevent,
        timestamp_ns: u64,
    ) void {
        if (event.flags & std.c.EV.ERROR != 0) {
            if (event.data != 0) {
                self.noteLossLocked("a process-event registration failed");
            }
            return;
        }
        const pid: std.posix.pid_t = @intCast(event.ident);
        const tracked = self.tracked.get(pid) orelse return;
        if (tracked.generation != event.udata) return;
        if (event.fflags & std.c.NOTE.EXEC != 0) {
            self.queueExecHintLocked(pid, timestamp_ns);
        }
        if (event.fflags & std.c.NOTE.EXIT != 0) {
            self.queueExitLocked(pid, timestamp_ns);
        }
    }

    fn emitPendingMetadataLocked(self: *Collector, timestamp_ns: u64) void {
        var iterator = self.tracked.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.needs_metadata) continue;
            entry.value_ptr.needs_metadata = false;
            self.queueExecLocked(entry.key_ptr.*, timestamp_ns);
        }
    }

    fn discoverDescendantsLocked(self: *Collector, timestamp_ns: u64) void {
        var parents: std.ArrayList(std.posix.pid_t) = .empty;
        defer parents.deinit(self.gpa);
        var iterator = self.tracked.iterator();
        while (iterator.next()) |entry| {
            parents.append(self.gpa, entry.key_ptr.*) catch {
                self.noteLossLocked("could not allocate the descendant scan queue");
                return;
            };
        }

        var parent_index: usize = 0;
        while (parent_index < parents.items.len) : (parent_index += 1) {
            const parent_pid = parents.items[parent_index];
            const children = self.listChildren(parent_pid) orelse continue;
            for (children) |pid| {
                if (!self.admitChildLocked(parent_pid, pid, timestamp_ns)) continue;
                parents.append(self.gpa, pid) catch {
                    self.noteLossLocked("could not extend the descendant scan queue");
                    return;
                };
            }
        }
        self.discoverProcessGroupLocked(timestamp_ns);
    }

    fn listChildren(self: *Collector, parent_pid: std.posix.pid_t) ?[]const std.posix.pid_t {
        return self.listPids(.children, parent_pid);
    }

    fn listPids(
        self: *Collector,
        kind: PidList,
        identifier: std.posix.pid_t,
    ) ?[]const std.posix.pid_t {
        return self.listPidsWith(kind, identifier, null, systemListPids);
    }

    fn listPidsWith(
        self: *Collector,
        kind: PidList,
        identifier: std.posix.pid_t,
        context: ?*anyopaque,
        list_fn: PidListFn,
    ) ?[]const std.posix.pid_t {
        self.pid_snapshot.clearRetainingCapacity();
        const required_count = list_fn(context, kind, identifier, null, 0);
        if (required_count <= 0) return null;
        const pid_size = @sizeOf(std.posix.pid_t);
        const max_capacity = @divTrunc(
            @as(usize, @intCast(std.math.maxInt(c_int))),
            pid_size,
        );
        var requested_capacity = std.math.add(
            usize,
            @intCast(required_count),
            pid_snapshot_slack,
        ) catch {
            self.noteLossLocked("the PID snapshot size overflowed");
            return null;
        };

        for (0..pid_snapshot_retry_limit) |_| {
            if (requested_capacity > max_capacity) {
                self.noteLossLocked("the PID snapshot exceeds libproc's size limit");
                return null;
            }
            self.pid_snapshot.ensureTotalCapacity(self.gpa, requested_capacity) catch {
                self.noteLossLocked("could not allocate the PID snapshot");
                return null;
            };
            const usable_capacity = @min(self.pid_snapshot.capacity, max_capacity);
            const buffer_bytes: c_int = @intCast(usable_capacity * pid_size);
            const amount = list_fn(
                context,
                kind,
                identifier,
                @ptrCast(self.pid_snapshot.items.ptr),
                buffer_bytes,
            );
            if (amount <= 0) return null;
            const count: usize = @intCast(amount);
            if (count < usable_capacity) {
                self.pid_snapshot.items.len = count;
                return self.pid_snapshot.items;
            }
            requested_capacity = std.math.mul(usize, usable_capacity, 2) catch {
                self.noteLossLocked("the PID snapshot growth overflowed");
                return null;
            };
        }
        self.noteLossLocked("the PID snapshot remained full after bounded retries");
        return null;
    }

    fn discoverProcessGroupLocked(self: *Collector, timestamp_ns: u64) void {
        const root_pid = self.root_pid orelse return;
        const root_pgid = self.root_pgid orelse return;
        const members = self.listPids(.process_group, root_pgid) orelse return;
        for (members) |pid| {
            if (pid <= 1 or pid == root_pid) continue;
            var identity: ProcessIdentity = undefined;
            if (flamez_macos_process_identity(pid, &identity) != 0) continue;
            if (self.tracked.get(pid)) |tracked| {
                if (ProcessIdentity.eql(tracked.identity, identity)) continue;
            }
            if (self.tracked.contains(identity.parent_pid)) {
                _ = self.admitChildLocked(identity.parent_pid, pid, timestamp_ns);
            } else {
                self.admitRecoveredLocked(pid, identity, timestamp_ns);
            }
        }
    }

    fn discoverEscapedDescendantsLocked(self: *Collector, timestamp_ns: u64) void {
        const all_pids = self.listPids(.all, 0) orelse return;
        self.identity_snapshot.clearRetainingCapacity();
        self.identity_snapshot.ensureTotalCapacity(self.gpa, all_pids.len) catch {
            self.noteLossLocked("could not allocate the escaped-descendant snapshot");
            return;
        };
        for (all_pids) |pid| {
            if (pid <= 1) continue;
            var identity: ProcessIdentity = undefined;
            if (flamez_macos_process_identity(pid, &identity) != 0) continue;
            if (self.tracked.get(pid)) |tracked| {
                if (ProcessIdentity.eql(tracked.identity, identity)) continue;
            }
            self.identity_snapshot.appendAssumeCapacity(.{
                .pid = pid,
                .identity = identity,
            });
        }

        var admitted_in_pass = true;
        while (admitted_in_pass) {
            admitted_in_pass = false;
            for (self.identity_snapshot.items) |*candidate| {
                if (candidate.pid <= 1 or candidate.identity.parent_unique_id == 0) continue;
                const parent_pid = self.trackedPidByUniqueIdLocked(
                    candidate.identity.parent_unique_id,
                ) orelse continue;
                const pid = candidate.pid;
                candidate.pid = 0;
                if (self.admitChildIdentityLocked(
                    parent_pid,
                    pid,
                    candidate.identity,
                    timestamp_ns,
                )) {
                    admitted_in_pass = true;
                }
            }
        }
    }

    fn trackedPidByUniqueIdLocked(
        self: *Collector,
        unique_id: u64,
    ) ?std.posix.pid_t {
        var iterator = self.tracked.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.identity.unique_id == unique_id) return entry.key_ptr.*;
        }
        return null;
    }

    fn admitChildLocked(
        self: *Collector,
        parent_pid: std.posix.pid_t,
        pid: std.posix.pid_t,
        timestamp_ns: u64,
    ) bool {
        if (pid <= 1) return false;
        var identity: ProcessIdentity = undefined;
        if (flamez_macos_process_identity(pid, &identity) != 0) return false;
        return self.admitChildIdentityLocked(parent_pid, pid, identity, timestamp_ns);
    }

    fn admitChildIdentityLocked(
        self: *Collector,
        parent_pid: std.posix.pid_t,
        pid: std.posix.pid_t,
        identity: ProcessIdentity,
        timestamp_ns: u64,
    ) bool {
        const parent = self.tracked.get(parent_pid) orelse return false;
        if (identity.parent_unique_id != parent.identity.unique_id) return false;
        if (self.tracked.get(pid)) |tracked| {
            if (ProcessIdentity.eql(tracked.identity, identity)) return false;
            self.queueExitLocked(pid, timestamp_ns);
        }
        self.tracked.ensureUnusedCapacity(self.gpa, 1) catch {
            self.noteLossLocked("could not allocate a tracked-process record");
            return false;
        };
        const generation = self.newGeneration();
        if (!self.register(pid, generation)) {
            self.noteLossLocked("a child exited before kqueue registration");
            return false;
        }
        var registered_identity: ProcessIdentity = undefined;
        if (flamez_macos_process_identity(pid, &registered_identity) != 0 or
            !ProcessIdentity.eql(identity, registered_identity))
        {
            self.deleteRegistration(pid);
            self.noteLossLocked("a child changed identity during kqueue registration");
            return false;
        }
        var tracked = Tracked{
            .identity = registered_identity,
            .generation = generation,
        };
        self.refreshName(pid, &tracked);
        self.tracked.putAssumeCapacity(pid, tracked);
        const stored = self.tracked.getPtr(pid).?;
        self.queueEventLocked(.{
            .timestamp_ns = timestamp_ns,
            .payload = .{ .fork = .{
                .pid = pid,
                .parent_pid = parent_pid,
                .name = StoredName.init(stored.nameSlice()),
            } },
        });
        return true;
    }

    fn admitRecoveredLocked(
        self: *Collector,
        pid: std.posix.pid_t,
        identity: ProcessIdentity,
        timestamp_ns: u64,
    ) void {
        if (self.tracked.get(pid)) |tracked| {
            if (ProcessIdentity.eql(tracked.identity, identity)) return;
            self.queueExitLocked(pid, timestamp_ns);
        }
        self.tracked.ensureUnusedCapacity(self.gpa, 1) catch {
            self.noteLossLocked("could not allocate a recovered-process record");
            return;
        };
        const generation = self.newGeneration();
        if (!self.register(pid, generation)) {
            self.noteLossLocked("a recovered process exited before kqueue registration");
            return;
        }
        var registered_identity: ProcessIdentity = undefined;
        if (flamez_macos_process_identity(pid, &registered_identity) != 0 or
            !ProcessIdentity.eql(identity, registered_identity))
        {
            self.deleteRegistration(pid);
            self.noteLossLocked("a recovered process changed identity during registration");
            return;
        }
        var tracked = Tracked{
            .identity = registered_identity,
            .generation = generation,
        };
        self.refreshName(pid, &tracked);
        tracked.needs_metadata = false;
        self.tracked.putAssumeCapacity(pid, tracked);
        // An exec without a preceding fork is deliberately normalized through
        // Session's recovered-exec path, which anchors it under the root and
        // marks the capture incomplete instead of inventing exact parentage.
        self.queueExecLocked(pid, timestamp_ns);
    }

    fn queueExecLocked(
        self: *Collector,
        pid: std.posix.pid_t,
        timestamp_ns: u64,
    ) void {
        _ = self.queueExecSnapshotLocked(pid, timestamp_ns);
    }

    fn queueExecHintLocked(
        self: *Collector,
        pid: std.posix.pid_t,
        timestamp_ns: u64,
    ) void {
        const generation = (self.tracked.get(pid) orelse return).generation;
        if (self.queueExecSnapshotLocked(pid, timestamp_ns)) return;
        const tracked = self.tracked.getPtr(pid) orelse return;
        if (tracked.generation != generation) return;
        tracked.needs_metadata = true;
        self.queueEventLocked(.{
            .timestamp_ns = timestamp_ns,
            .payload = .{ .exec = .{
                .pid = pid,
                .name = StoredName.init(""),
            } },
        });
    }

    fn queueExecSnapshotLocked(
        self: *Collector,
        pid: std.posix.pid_t,
        timestamp_ns: u64,
    ) bool {
        const tracked = self.tracked.get(pid) orelse return false;
        var identity_before: ProcessIdentity = undefined;
        if (flamez_macos_process_identity(pid, &identity_before) != 0 or
            !ProcessIdentity.eql(tracked.identity, identity_before))
        {
            self.retryMetadataLocked(pid, tracked.generation);
            return false;
        }
        var snapshot = tracked;
        self.refreshName(pid, &snapshot);
        var pending = PendingExec{
            .pid = pid,
            .name = StoredName.init(snapshot.nameSlice()),
        };
        var path_buffer: [4096]u8 = undefined;
        if (process_ops.readExecutable(pid, &path_buffer)) |exe| pending.exe.set(exe);
        if (process_ops.readCwd(pid, &path_buffer)) |cwd| pending.cwd.set(cwd);
        if (process_ops.readArgs(self.gpa, pid) catch args: {
            self.noteLossLocked("could not allocate an argv snapshot");
            break :args null;
        }) |args| {
            pending.args = args;
            pending.args_present = true;
        }
        var identity_after: ProcessIdentity = undefined;
        if (flamez_macos_process_identity(pid, &identity_after) != 0 or
            !ProcessIdentity.sameImage(identity_before, identity_after))
        {
            pending.deinit(self.gpa);
            self.retryMetadataLocked(pid, tracked.generation);
            return false;
        }
        const current = self.tracked.getPtr(pid) orelse {
            pending.deinit(self.gpa);
            return false;
        };
        if (current.generation != tracked.generation or
            !ProcessIdentity.eql(current.identity, identity_after))
        {
            pending.deinit(self.gpa);
            return false;
        }
        current.identity = identity_after;
        current.needs_metadata = false;
        current.name = snapshot.name;
        current.name_len = snapshot.name_len;
        self.queueEventLocked(.{
            .timestamp_ns = timestamp_ns,
            .payload = .{ .exec = pending },
        });
        return true;
    }

    fn retryMetadataLocked(
        self: *Collector,
        pid: std.posix.pid_t,
        generation: usize,
    ) void {
        const tracked = self.tracked.getPtr(pid) orelse return;
        if (tracked.generation == generation) tracked.needs_metadata = true;
    }

    fn queueExitLocked(
        self: *Collector,
        pid: std.posix.pid_t,
        timestamp_ns: u64,
    ) void {
        var tracked = self.tracked.get(pid) orelse return;
        var cpu_ns: u64 = 0;
        var cpu_final = false;
        if (flamez_macos_cpu_time(pid, &cpu_ns) == 0) {
            cpu_final = true;
        }
        self.refreshName(pid, &tracked);
        _ = self.tracked.remove(pid);
        self.deleteRegistration(pid);
        self.queueEventLocked(.{
            .timestamp_ns = timestamp_ns,
            .payload = .{ .exit = .{
                .pid = pid,
                .name = StoredName.init(tracked.nameSlice()),
                .cpu_ns = if (cpu_final) cpu_ns else tracked.cpu_ns,
                .cpu_final = cpu_final,
            } },
        });
        if (self.root_pid == pid) self.worker_stop.store(true, .release);
    }

    fn queueEventLocked(self: *Collector, event: PendingEvent) void {
        var owned = event;
        const allocation_bytes = owned.allocationBytes();
        if (allocation_bytes > self.pending_event_limit or
            self.pending_event_bytes > self.pending_event_limit - allocation_bytes)
        {
            owned.deinit(self.gpa);
            self.noteLossLocked("the fallback lifecycle queue reached its memory limit");
            return;
        }
        self.pending_events.append(self.gpa, owned) catch {
            owned.deinit(self.gpa);
            self.noteLossLocked("could not allocate the pending lifecycle queue");
            return;
        };
        self.pending_event_bytes += allocation_bytes;
    }

    fn refreshName(_: *Collector, pid: std.posix.pid_t, tracked: *Tracked) void {
        var buffer: [48]u8 = undefined;
        const name = process_ops.readName(pid, &buffer) orelse return;
        const amount = @min(name.len, tracked.name.len);
        @memcpy(tracked.name[0..amount], name[0..amount]);
        tracked.name_len = @intCast(amount);
    }

    fn register(self: *Collector, pid: std.posix.pid_t, generation: usize) bool {
        const change = std.c.Kevent{
            .ident = @intCast(pid),
            .filter = std.c.EVFILT.PROC,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
            .fflags = std.c.NOTE.FORK | std.c.NOTE.EXEC | std.c.NOTE.EXIT,
            .data = 0,
            .udata = generation,
        };
        const rc = std.c.kevent(self.kqueue_fd, @ptrCast(&change), 1, undefined, 0, null);
        return rc == 0;
    }

    fn deleteRegistration(self: *Collector, pid: std.posix.pid_t) void {
        if (self.kqueue_fd < 0) return;
        const change = std.c.Kevent{
            .ident = @intCast(pid),
            .filter = std.c.EVFILT.PROC,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        _ = std.c.kevent(self.kqueue_fd, @ptrCast(&change), 1, undefined, 0, null);
    }

    fn clearTrackedLocked(self: *Collector) void {
        var iterator = self.tracked.keyIterator();
        while (iterator.next()) |pid| self.deleteRegistration(pid.*);
        self.tracked.clearRetainingCapacity();
    }

    fn clearPendingEventsLocked(self: *Collector) void {
        for (self.pending_events.items) |*event| event.deinit(self.gpa);
        self.pending_events.clearRetainingCapacity();
        self.pending_event_bytes = 0;
        for (self.delivery_events.items) |*event| event.deinit(self.gpa);
        self.delivery_events.clearRetainingCapacity();
        self.delivery_event_bytes = 0;
    }

    fn newGeneration(self: *Collector) usize {
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        return self.next_generation;
    }

    fn noteLossLocked(self: *Collector, message: []const u8) void {
        self.worker_lost_events +|= 1;
        if (comptime !builtin.is_test) {
            if (self.worker_lost_events == 1) log.warn("{s}", .{message});
        }
    }

    fn stopWorker(self: *Collector) void {
        self.worker_stop.store(true, .release);
        if (self.worker) |worker| {
            worker.join();
            self.worker = null;
        }
    }

    fn closeEs(self: *Collector) void {
        if (self.es_handle) |handle| {
            flamez_macos_es_close(handle);
            self.es_handle = null;
        }
    }

    fn lock(self: *Collector) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
    }

    fn unlock(self: *Collector) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
    }

    fn setDiagnostic(self: *Collector, value: []const u8) void {
        const amount = @min(value.len, self.diagnostic_buffer.len);
        @memcpy(self.diagnostic_buffer[0..amount], value[0..amount]);
        self.diagnostic_len = amount;
    }

    fn setExactDiagnostic(self: *Collector, value: []const u8) void {
        const amount = @min(value.len, self.exact_diagnostic_buffer.len);
        @memcpy(self.exact_diagnostic_buffer[0..amount], value[0..amount]);
        self.exact_diagnostic_len = amount;
    }
};

fn esSlice(pointer: ?[*]const u8, len: usize) ?[]const u8 {
    const bytes = pointer orelse return null;
    return bytes[0..len];
}

fn consumeEsEvent(context: ?*anyopaque, event: *const EsEvent) callconv(.c) void {
    const poll: *EsPoll = @ptrCast(@alignCast(context orelse return));
    poll.collector.consumeEndpointSecurityEvent(poll.sink, event);
}

fn nowNs() u64 {
    var time: std.c.timespec = undefined;
    if (std.c.clock_gettime(.UPTIME_RAW, &time) != 0) return 0;
    if (time.sec < 0 or time.nsec < 0) return 0;
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(time.nsec));
}

fn waitForPidFile(
    dir: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
    buffer: []u8,
) !std.posix.pid_t {
    const started = std.Io.Clock.awake.now(io);
    while (true) {
        const pid_bytes = dir.readFile(io, sub_path, buffer) catch |err| switch (err) {
            error.FileNotFound => &.{},
            else => return err,
        };
        if (pid_bytes.len > 0) {
            return std.fmt.parseInt(std.posix.pid_t, pid_bytes, 10);
        }
        if (started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds >=
            5 * std.time.ns_per_s) return error.TestUnexpectedResult;
        try std.Thread.yield();
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

test "collector initializes without special privileges" {
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();
    try std.testing.expect(collector.available());
}

test "fallback lifecycle queue is bounded and reports overflow" {
    const Probe = struct {
        events: usize = 0,

        fn event(pointer: *anyopaque, _: capture.Event) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.events += 1;
        }

        fn cpu(_: *anyopaque, _: std.posix.pid_t, _: u64, _: u64) void {}
    };
    const testing = std.testing;
    var collector = Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();
    collector.pending_event_limit = 2 * @sizeOf(PendingEvent);

    collector.lock();
    for (0..3) |index| {
        collector.queueEventLocked(.{
            .timestamp_ns = index,
            .payload = .{ .fork = .{
                .pid = @intCast(index + 10),
                .parent_pid = 1,
                .name = StoredName.init("child"),
            } },
        });
    }
    collector.unlock();

    try testing.expectEqual(@as(usize, 2), collector.pending_events.items.len);
    try testing.expectEqual(collector.pending_event_limit, collector.pending_event_bytes);
    try testing.expectEqual(@as(u64, 1), collector.worker_lost_events);

    var probe = Probe{};
    collector.pollEvents(.{
        .ptr = &probe,
        .event_fn = Probe.event,
        .cpu_sample_fn = Probe.cpu,
    });
    try testing.expectEqual(@as(usize, 2), probe.events);
    try testing.expectEqual(@as(usize, 0), collector.pending_event_bytes);
    try testing.expectEqual(@as(usize, 0), collector.delivery_event_bytes);
    try testing.expectEqual(@as(u64, 1), collector.lost_events);
}

test "fallback lifecycle queue counts owned argv storage" {
    const testing = std.testing;
    var collector = Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();

    var exec = PendingExec{
        .pid = 10,
        .name = StoredName.init("child"),
    };
    try exec.args.appendSlice(testing.allocator, "argument bytes");
    exec.args_present = true;
    collector.pending_event_limit = @sizeOf(PendingEvent) + exec.args.capacity - 1;

    collector.lock();
    collector.queueEventLocked(.{
        .timestamp_ns = 1,
        .payload = .{ .exec = exec },
    });
    collector.unlock();

    try testing.expectEqual(@as(usize, 0), collector.pending_events.items.len);
    try testing.expectEqual(@as(usize, 0), collector.pending_event_bytes);
    try testing.expectEqual(@as(u64, 1), collector.worker_lost_events);
}

test "fallback PID snapshots grow when the fill call reaches capacity" {
    const Probe = struct {
        calls: usize = 0,
        kind: ?PidList = null,
        identifier: std.posix.pid_t = 0,

        fn list(
            pointer: ?*anyopaque,
            kind: PidList,
            identifier: std.posix.pid_t,
            buffer: ?*anyopaque,
            buffer_size: c_int,
        ) c_int {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            self.calls += 1;
            self.kind = kind;
            self.identifier = identifier;
            if (buffer == null) return 1;

            const capacity = @divTrunc(
                @as(usize, @intCast(buffer_size)),
                @sizeOf(std.posix.pid_t),
            );
            const output: [*]std.posix.pid_t = @ptrCast(@alignCast(buffer.?));
            if (self.calls == 2) {
                for (0..capacity) |index| output[index] = @intCast(index + 10);
                return @intCast(capacity);
            }
            const final_count = 7;
            for (0..final_count) |index| output[index] = @intCast(index + 100);
            return final_count;
        }
    };

    const testing = std.testing;
    var collector = Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();
    var probe = Probe{};

    const pids = collector.listPidsWith(
        .children,
        42,
        &probe,
        Probe.list,
    ) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), probe.calls);
    try testing.expectEqual(PidList.children, probe.kind.?);
    try testing.expectEqual(@as(std.posix.pid_t, 42), probe.identifier);
    try testing.expectEqual(@as(usize, 7), pids.len);
    try testing.expectEqual(@as(std.posix.pid_t, 100), pids[0]);
    try testing.expectEqual(@as(std.posix.pid_t, 106), pids[6]);
    try testing.expectEqual(@as(u64, 0), collector.worker_lost_events);
}

test "fallback PID snapshots report persistent truncation" {
    const Probe = struct {
        calls: usize = 0,

        fn list(
            pointer: ?*anyopaque,
            _: PidList,
            _: std.posix.pid_t,
            buffer: ?*anyopaque,
            buffer_size: c_int,
        ) c_int {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            self.calls += 1;
            if (buffer == null) return 1;

            const capacity = @divTrunc(
                @as(usize, @intCast(buffer_size)),
                @sizeOf(std.posix.pid_t),
            );
            const output: [*]std.posix.pid_t = @ptrCast(@alignCast(buffer.?));
            for (0..capacity) |index| output[index] = @intCast(index + 10);
            return @intCast(capacity);
        }
    };

    const testing = std.testing;
    var collector = Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();
    var probe = Probe{};

    try testing.expect(collector.listPidsWith(
        .all,
        0,
        &probe,
        Probe.list,
    ) == null);
    try testing.expectEqual(@as(usize, 1 + pid_snapshot_retry_limit), probe.calls);
    try testing.expectEqual(@as(usize, 0), collector.pid_snapshot.items.len);
    try testing.expectEqual(@as(u64, 1), collector.worker_lost_events);
}

test "fallback all-PID snapshot includes the current process" {
    const testing = std.testing;
    var collector = Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();

    const pids = collector.listPids(.all, 0) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOfScalar(
        std.posix.pid_t,
        pids,
        process_ops.currentPid(),
    ) != null);
    try testing.expectEqual(@as(u64, 0), collector.worker_lost_events);
}

test "process identity distinguishes lifetime from image version" {
    const before = ProcessIdentity{
        .parent_pid = 41,
        .pid_version = 7,
        .start_seconds = 1_234,
        .start_microseconds = 567,
        .unique_id = 89,
        .parent_unique_id = 55,
        .parent_pid_version = 6,
        .reserved = 0,
    };
    var after = before;
    after.pid_version += 1;

    try std.testing.expect(ProcessIdentity.eql(before, after));
    try std.testing.expect(!ProcessIdentity.sameImage(before, after));

    after = before;
    after.unique_id += 1;
    try std.testing.expect(!ProcessIdentity.eql(before, after));
}

test "Mach absolute timestamps share the awake clock domain" {
    const testing = std.testing;
    const rounding_tolerance_ns = std.time.ns_per_us;
    const before_ns = nowNs();
    const mach_ns = flamez_macos_es_test_mach_now_to_ns();
    const after_ns = nowNs();

    try testing.expect(before_ns > 0);
    try testing.expect(mach_ns > 0);
    try testing.expect(after_ns > 0);
    try testing.expect(mach_ns +| rounding_tolerance_ns >= before_ns);
    try testing.expect(mach_ns <= after_ns +| rounding_tolerance_ns);
}

test "kqueue exec hint survives unavailable process inspection" {
    const Probe = struct {
        exec_count: usize = 0,
        metadata_unavailable: bool = false,

        fn event(pointer: *anyopaque, observation: capture.Event) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            switch (observation.payload) {
                .exec => |exec| {
                    self.exec_count += 1;
                    self.metadata_unavailable = exec.name.len == 0 and
                        exec.exe == null and
                        exec.args == null and
                        exec.cwd == null and
                        !exec.inspect_missing;
                },
                .fork, .exit => {},
            }
        }

        fn cpu(_: *anyopaque, _: std.posix.pid_t, _: u64, _: u64) void {}
    };

    const pid: std.posix.pid_t = 999_999;
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();
    try collector.tracked.put(std.testing.allocator, pid, .{
        .identity = .{
            .parent_pid = 1,
            .pid_version = 2,
            .start_seconds = 3,
            .start_microseconds = 4,
            .unique_id = 5,
            .parent_unique_id = 6,
            .parent_pid_version = 1,
            .reserved = 0,
        },
        .generation = 7,
        .needs_metadata = false,
    });

    collector.queueExecHintLocked(pid, 8);
    var probe = Probe{};
    collector.pollEvents(.{
        .ptr = &probe,
        .event_fn = Probe.event,
        .cpu_sample_fn = Probe.cpu,
    });

    try std.testing.expectEqual(@as(usize, 1), probe.exec_count);
    try std.testing.expect(probe.metadata_unavailable);
    try std.testing.expect(collector.tracked.get(pid).?.needs_metadata);
}

test "Endpoint Security bridge owns queued slices and preserves FIFO order" {
    const Probe = struct {
        count: usize = 0,
        kinds: [2]EsEventKind = undefined,
        metadata_matches: bool = false,

        fn event(pointer: ?*anyopaque, observation: *const EsEvent) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            self.kinds[self.count] = observation.kind;
            if (self.count == 0) {
                self.metadata_matches =
                    std.mem.eql(
                        u8,
                        esSlice(observation.name, observation.name_len).?,
                        "tool",
                    ) and
                    std.mem.eql(
                        u8,
                        esSlice(observation.executable, observation.executable_len).?,
                        "/bin/tool",
                    ) and
                    std.mem.eql(
                        u8,
                        esSlice(observation.args, observation.args_len).?,
                        "tool\x00arg\x00",
                    ) and
                    std.mem.eql(
                        u8,
                        esSlice(observation.cwd, observation.cwd_len).?,
                        "/tmp",
                    );
            }
            self.count += 1;
        }
    };

    const testing = std.testing;
    var name = [_]u8{ 't', 'o', 'o', 'l' };
    var executable = [_]u8{ '/', 'b', 'i', 'n', '/', 't', 'o', 'o', 'l' };
    var args = [_]u8{ 't', 'o', 'o', 'l', 0, 'a', 'r', 'g', 0 };
    var cwd = [_]u8{ '/', 't', 'm', 'p' };
    var exit_name = [_]u8{ 'd', 'o', 'n', 'e' };
    const record_size = flamez_macos_es_test_record_size();
    try testing.expect(record_size >= @sizeOf(EsEvent));
    const queue_limit = 2 * record_size +
        name.len + executable.len + args.len + cwd.len + exit_name.len;
    const handle = flamez_macos_es_test_create(queue_limit) orelse
        return error.OutOfMemory;
    defer flamez_macos_es_test_destroy(handle);

    var first = EsEvent{
        .kind = .exec,
        .pid = 41,
        .parent_pid = 0,
        .pid_version = 2,
        .parent_pid_version = 0,
        .timestamp_ns = 100,
        .cpu_ns = 0,
        .name = &name,
        .name_len = name.len,
        .executable = &executable,
        .executable_len = executable.len,
        .executable_truncated = 0,
        .args = &args,
        .args_len = args.len,
        .cwd = &cwd,
        .cwd_len = cwd.len,
        .cwd_truncated = 0,
        .cpu_final = 0,
    };
    var second = first;
    second.kind = .exit;
    second.timestamp_ns = 200;
    second.name = &exit_name;
    second.name_len = exit_name.len;
    second.executable = null;
    second.executable_len = 0;
    second.args = null;
    second.args_len = 0;
    second.cwd = null;
    second.cwd_len = 0;
    second.cpu_ns = 300;
    second.cpu_final = 1;
    try testing.expectEqual(@as(c_int, 0), flamez_macos_es_test_enqueue(handle, &first));
    try testing.expectEqual(@as(c_int, 0), flamez_macos_es_test_enqueue(handle, &second));

    @memset(&name, 'x');
    @memset(&executable, 'x');
    @memset(&args, 'x');
    @memset(&cwd, 'x');
    @memset(&exit_name, 'x');

    var probe = Probe{};
    try testing.expectEqual(
        @as(c_int, 2),
        flamez_macos_es_poll(handle, Probe.event, &probe),
    );
    try testing.expectEqual(@as(usize, 2), probe.count);
    try testing.expectEqual(EsEventKind.exec, probe.kinds[0]);
    try testing.expectEqual(EsEventKind.exit, probe.kinds[1]);
    try testing.expect(probe.metadata_matches);
    try testing.expectEqual(@as(u64, 0), flamez_macos_es_lost_events(handle));
}

test "Endpoint Security bridge extracts synthetic native messages" {
    const Probe = struct {
        count: usize = 0,
        fork_matches: bool = false,
        exec_matches: bool = false,
        exit_matches: bool = false,

        fn event(pointer: ?*anyopaque, observation: *const EsEvent) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            const expected_timestamp = flamez_macos_es_test_mach_time_to_ns(
                self.count + 1,
            );
            switch (observation.kind) {
                .fork => self.fork_matches =
                    self.count == 0 and
                    observation.pid == 6101 and
                    observation.parent_pid == 6100 and
                    observation.pid_version == 8 and
                    observation.parent_pid_version == 7 and
                    observation.timestamp_ns == expected_timestamp and
                    std.mem.eql(
                        u8,
                        esSlice(observation.name, observation.name_len).?,
                        "child",
                    ),
                .exec => self.exec_matches =
                    self.count == 1 and
                    observation.pid == 6101 and
                    observation.pid_version == 9 and
                    observation.timestamp_ns == expected_timestamp and
                    observation.executable_truncated == 1 and
                    observation.cwd_truncated == 1 and
                    std.mem.eql(
                        u8,
                        esSlice(observation.name, observation.name_len).?,
                        "tool",
                    ) and
                    std.mem.eql(
                        u8,
                        esSlice(observation.executable, observation.executable_len).?,
                        "/opt/bin/tool",
                    ) and
                    std.mem.eql(
                        u8,
                        esSlice(observation.args, observation.args_len).?,
                        "tool\x00argument\x00\x00",
                    ) and
                    std.mem.eql(
                        u8,
                        esSlice(observation.cwd, observation.cwd_len).?,
                        "/working/directory",
                    ),
                .exit => self.exit_matches =
                    self.count == 2 and
                    observation.pid == 6101 and
                    observation.pid_version == 9 and
                    observation.timestamp_ns == expected_timestamp and
                    observation.cpu_ns == 777 and
                    observation.cpu_final == 1 and
                    std.mem.eql(
                        u8,
                        esSlice(observation.name, observation.name_len).?,
                        "tool",
                    ),
            }
            self.count += 1;
        }
    };

    const testing = std.testing;
    const handle = flamez_macos_es_test_create(4 * 1024) orelse
        return error.OutOfMemory;
    defer flamez_macos_es_test_destroy(handle);
    flamez_macos_es_test_capture_fixture(handle);

    var probe = Probe{};
    try testing.expectEqual(
        @as(c_int, 3),
        flamez_macos_es_poll(handle, Probe.event, &probe),
    );
    try testing.expectEqual(@as(usize, 3), probe.count);
    try testing.expect(probe.fork_matches);
    try testing.expect(probe.exec_matches);
    try testing.expect(probe.exit_matches);
    try testing.expectEqual(@as(u64, 2), flamez_macos_es_lost_events(handle));
}

test "Endpoint Security bridge waits for an asynchronous queue marker" {
    const Probe = struct {
        handle: *EsHandle,
        result: c_int = -1,

        fn run(self: *@This()) void {
            self.result = flamez_macos_es_sync(self.handle);
        }
    };

    const testing = std.testing;
    const handle = flamez_macos_es_test_create(0) orelse return error.OutOfMemory;
    defer flamez_macos_es_test_destroy(handle);
    flamez_macos_es_test_prepare_sync(handle, 0);

    var probe = Probe{ .handle = handle };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    flamez_macos_es_test_complete_sync(handle);
    thread.join();
    try testing.expectEqual(@as(c_int, 0), probe.result);

    flamez_macos_es_test_prepare_sync(handle, 1);
    try testing.expect(flamez_macos_es_sync(handle) != 0);
}

test "Endpoint Security bridge reports queue overflow and sequence gaps" {
    const Probe = struct {
        count: usize = 0,

        fn event(pointer: ?*anyopaque, _: *const EsEvent) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            self.count += 1;
        }
    };

    const testing = std.testing;
    const name = "one";
    const record_size = flamez_macos_es_test_record_size();
    const handle = flamez_macos_es_test_create(record_size + name.len) orelse
        return error.OutOfMemory;
    defer flamez_macos_es_test_destroy(handle);
    const event = EsEvent{
        .kind = .fork,
        .pid = 51,
        .parent_pid = 50,
        .pid_version = 1,
        .parent_pid_version = 1,
        .timestamp_ns = 100,
        .cpu_ns = 0,
        .name = name.ptr,
        .name_len = name.len,
        .executable = null,
        .executable_len = 0,
        .executable_truncated = 0,
        .args = null,
        .args_len = 0,
        .cwd = null,
        .cwd_len = 0,
        .cwd_truncated = 0,
        .cpu_final = 0,
    };
    try testing.expectEqual(@as(c_int, 0), flamez_macos_es_test_enqueue(handle, &event));
    try testing.expectEqual(@as(c_int, 0), flamez_macos_es_test_enqueue(handle, &event));

    flamez_macos_es_test_capture_sequence(handle, 3, 90);
    flamez_macos_es_test_capture_sequence(handle, 4, 100);
    flamez_macos_es_test_capture_sequence(handle, 4, 101);
    flamez_macos_es_test_capture_sequence(handle, 4, 104);

    var probe = Probe{};
    try testing.expectEqual(
        @as(c_int, 1),
        flamez_macos_es_poll(handle, Probe.event, &probe),
    );
    try testing.expectEqual(@as(usize, 1), probe.count);
    try testing.expectEqual(@as(u64, 3), flamez_macos_es_lost_events(handle));
}

test "required Endpoint Security never silently selects fallback" {
    const testing = std.testing;
    var collector = Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .required,
    });
    defer collector.deinit();

    collector.armLaunch(process_ops.currentPid()) catch |err| {
        try testing.expectEqual(error.ExactCaptureUnavailable, err);
        try testing.expectEqual(capture.Fidelity.snapshot_recovery, collector.fidelity());
        try testing.expect(collector.exactDiagnosticSlice().len > 0);
        return;
    };
    try testing.expectEqual(capture.Fidelity.exact, collector.fidelity());
    try testing.expect(collector.es_handle != null);
}

test "arming a launch clears an earlier process generation" {
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();
    const pid = process_ops.currentPid();
    try collector.trackRoot(pid);
    collector.lock();
    const tracked_count = collector.tracked.count();
    collector.unlock();
    try std.testing.expectEqual(@as(usize, 1), tracked_count);
    try collector.armLaunch(pid);
    try std.testing.expectEqual(@as(usize, 0), collector.tracked.count());
    try std.testing.expect(collector.worker == null);
    try std.testing.expect(collector.exactDiagnosticSlice().len > 0);

    try collector.trackRoot(pid);
    switch (collector.fidelity()) {
        .exact => try std.testing.expect(collector.es_handle != null),
        .snapshot_recovery => try std.testing.expect(collector.worker != null),
        .unavailable => unreachable,
    }
    try collector.armLaunch(pid);
    try std.testing.expect(collector.worker == null);
}

test "Endpoint Security events filter and preserve PID generations" {
    const Probe = struct {
        fork_count: usize = 0,
        exec_count: usize = 0,
        exit_count: usize = 0,
        exit_cpu_ns: u64 = 0,
        exit_cpu_final: bool = false,
        metadata_matches: bool = false,

        fn event(pointer: *anyopaque, observation: capture.Event) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            switch (observation.payload) {
                .fork => self.fork_count += 1,
                .exec => |exec| {
                    self.exec_count += 1;
                    self.metadata_matches =
                        exec.metadata_source == .kernel and
                        std.mem.eql(u8, exec.exe orelse return, "/bin/tool") and
                        std.mem.eql(u8, exec.args orelse return, "tool\x00value\x00") and
                        std.mem.eql(u8, exec.cwd orelse return, "/tmp");
                },
                .exit => |exit_event| {
                    self.exit_count += 1;
                    self.exit_cpu_ns = exit_event.cpu_ns;
                    self.exit_cpu_final = exit_event.cpu_final;
                },
            }
        }

        fn cpu(_: *anyopaque, _: std.posix.pid_t, _: u64, _: u64) void {}
    };

    const root_pid: std.posix.pid_t = 7101;
    const child_pid: std.posix.pid_t = 7102;
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();
    collector.root_pid = root_pid;
    collector.launcher_pid = 7100;
    try collector.es_versions.put(std.testing.allocator, root_pid, 4);

    var probe = Probe{};
    const sink = capture.Sink{
        .ptr = &probe,
        .event_fn = Probe.event,
        .cpu_sample_fn = Probe.cpu,
    };
    var event = EsEvent{
        .kind = .fork,
        .pid = root_pid,
        .parent_pid = 7100,
        .pid_version = 4,
        .parent_pid_version = 2,
        .timestamp_ns = 10,
        .cpu_ns = 0,
        .name = "root".ptr,
        .name_len = "root".len,
        .executable = null,
        .executable_len = 0,
        .executable_truncated = 0,
        .args = null,
        .args_len = 0,
        .cwd = null,
        .cwd_len = 0,
        .cwd_truncated = 0,
        .cpu_final = 0,
    };
    collector.consumeEndpointSecurityEvent(sink, &event);
    try std.testing.expectEqual(@as(usize, 0), probe.fork_count);

    event.pid = child_pid;
    event.parent_pid = root_pid;
    event.pid_version = 5;
    event.parent_pid_version = 4;
    event.name = "tool".ptr;
    event.name_len = "tool".len;
    collector.consumeEndpointSecurityEvent(sink, &event);
    try std.testing.expectEqual(@as(usize, 1), probe.fork_count);

    event.kind = .exec;
    event.pid_version = 6;
    event.executable = "/bin/tool".ptr;
    event.executable_len = "/bin/tool".len;
    event.args = "tool\x00value\x00".ptr;
    event.args_len = "tool\x00value\x00".len;
    event.cwd = "/tmp".ptr;
    event.cwd_len = "/tmp".len;
    collector.consumeEndpointSecurityEvent(sink, &event);
    try std.testing.expectEqual(@as(usize, 1), probe.exec_count);
    try std.testing.expect(probe.metadata_matches);

    try collector.tracked.put(std.testing.allocator, child_pid, .{
        .identity = .{
            .parent_pid = root_pid,
            .pid_version = 6,
            .start_seconds = 1,
            .start_microseconds = 2,
            .unique_id = 3,
            .parent_unique_id = 4,
            .parent_pid_version = 4,
            .reserved = 0,
        },
        .generation = 1,
        .cpu_ns = 9,
    });

    event.kind = .exit;
    event.cpu_ns = 7;
    event.cpu_final = 1;
    event.pid_version = 5;
    collector.consumeEndpointSecurityEvent(sink, &event);
    try std.testing.expectEqual(@as(usize, 0), probe.exit_count);
    event.pid_version = 6;
    collector.consumeEndpointSecurityEvent(sink, &event);
    try std.testing.expectEqual(@as(usize, 1), probe.exit_count);
    try std.testing.expectEqual(@as(u64, 7), probe.exit_cpu_ns);
    try std.testing.expect(probe.exit_cpu_final);
    try std.testing.expect(!collector.es_versions.contains(child_pid));
}

test "kqueue ignores an event from an earlier PID generation" {
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();
    const pid = process_ops.currentPid();
    var identity: ProcessIdentity = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        flamez_macos_process_identity(pid, &identity),
    );
    try std.testing.expect(identity.unique_id != 0);
    try collector.tracked.put(std.testing.allocator, pid, .{
        .identity = identity,
        .generation = 29,
    });

    const stale = std.c.Kevent{
        .ident = @intCast(pid),
        .filter = std.c.EVFILT.PROC,
        .flags = 0,
        .fflags = std.c.NOTE.EXIT,
        .data = 0,
        .udata = 28,
    };
    collector.lock();
    collector.consumeKeventLocked(stale, nowNs());
    collector.unlock();
    try std.testing.expect(collector.tracked.contains(pid));
    try std.testing.expectEqual(@as(usize, 0), collector.pending_events.items.len);

    var fork_hint = stale;
    fork_hint.fflags = std.c.NOTE.FORK;
    try std.testing.expect(!collector.hasTrackedForkHintLocked(&.{fork_hint}));
    fork_hint.udata = 29;
    try std.testing.expect(collector.hasTrackedForkHintLocked(&.{fork_hint}));
    fork_hint.flags = std.c.EV.ERROR;
    try std.testing.expect(!collector.hasTrackedForkHintLocked(&.{fork_hint}));
}

test "fallback recovers an escaped child by immutable parent identity" {
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var pid_path_buffer: [128]u8 = undefined;
    const pid_path = try std.fmt.bufPrint(
        &pid_path_buffer,
        ".zig-cache/tmp/{s}/daemon.pid",
        .{temporary.sub_path[0..]},
    );
    const daemon_script =
        \\import os,signal,sys
        \\child = os.fork()
        \\if child > 0: os._exit(0)
        \\os.setsid()
        \\with open(sys.argv[1], "w") as output: output.write(str(os.getpid()))
        \\signal.pause()
    ;

    var collector = Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();
    try collector.armLaunch(process_ops.currentPid());
    var child = try process_ops.spawnTarget(
        testing.allocator,
        testing.io,
        &.{
            "/usr/bin/python3",
            "-c",
            daemon_script,
            pid_path,
        },
    );
    errdefer child.kill(testing.io);
    const root_pid = child.id.?;
    try collector.trackRoot(root_pid);

    collector.stopWorker();
    try process_ops.resumeTarget(root_pid);

    var pid_buffer: [32]u8 = undefined;
    const escaped_pid = try waitForPidFile(
        temporary.dir,
        testing.io,
        "daemon.pid",
        &pid_buffer,
    );
    defer process_ops.safeKill(escaped_pid, .KILL);
    _ = try child.wait(testing.io);
    try testing.expect(process_ops.pidAlive(escaped_pid));

    collector.lock();
    collector.discoverDescendantsLocked(nowNs());
    const found_by_standard_scopes = collector.tracked.contains(escaped_pid);
    collector.discoverEscapedDescendantsLocked(nowNs());
    const found_by_unique_parent = collector.tracked.contains(escaped_pid);
    collector.unlock();
    try testing.expect(!found_by_standard_scopes);
    try testing.expect(found_by_unique_parent);
    process_ops.safeKill(escaped_pid, .KILL);
    try waitForProcessExit(escaped_pid, testing.io);
}

test "fallback does not adopt a double-fork daemon without an identity chain" {
    const testing = std.testing;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var pid_path_buffer: [128]u8 = undefined;
    const pid_path = try std.fmt.bufPrint(
        &pid_path_buffer,
        ".zig-cache/tmp/{s}/daemon.pid",
        .{temporary.sub_path[0..]},
    );
    const daemon_script =
        \\import os,signal,sys
        \\first = os.fork()
        \\if first > 0: os._exit(0)
        \\os.setsid()
        \\second = os.fork()
        \\if second > 0: os._exit(0)
        \\with open(sys.argv[1], "w") as output: output.write(str(os.getpid()))
        \\signal.pause()
    ;

    var collector = Collector.initWithOptions(testing.allocator, .{
        .endpoint_security = .disabled,
    });
    defer collector.deinit();
    try collector.armLaunch(process_ops.currentPid());
    var child = try process_ops.spawnTarget(
        testing.allocator,
        testing.io,
        &.{
            "/usr/bin/python3",
            "-c",
            daemon_script,
            pid_path,
        },
    );
    errdefer child.kill(testing.io);
    const root_pid = child.id.?;
    try collector.trackRoot(root_pid);

    // Stop while the root is still suspended so the first post-resume scan is
    // deliberately later than the daemon's reparent and process-group escape.
    collector.stopWorker();
    try process_ops.resumeTarget(root_pid);

    var pid_buffer: [32]u8 = undefined;
    const escaped_pid = try waitForPidFile(
        temporary.dir,
        testing.io,
        "daemon.pid",
        &pid_buffer,
    );
    defer process_ops.safeKill(escaped_pid, .KILL);
    _ = try child.wait(testing.io);
    try testing.expect(process_ops.pidAlive(escaped_pid));

    collector.lock();
    collector.discoverDescendantsLocked(nowNs());
    collector.discoverEscapedDescendantsLocked(nowNs());
    const adopted = collector.tracked.contains(escaped_pid);
    collector.unlock();
    try testing.expect(!adopted);
    process_ops.safeKill(escaped_pid, .KILL);
    try waitForProcessExit(escaped_pid, testing.io);
}

test "snapshots cumulative CPU for a tracked process" {
    const Probe = struct {
        calls: usize = 0,
        pid: std.posix.pid_t = 0,
        timestamp_ns: u64 = 0,

        fn event(_: *anyopaque, _: capture.Event) void {}

        fn cpu(
            pointer: *anyopaque,
            pid: std.posix.pid_t,
            _: u64,
            timestamp_ns: u64,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.calls += 1;
            self.pid = pid;
            self.timestamp_ns = timestamp_ns;
        }
    };

    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();
    const pid = process_ops.currentPid();
    try collector.trackRoot(pid);
    var probe = Probe{};
    collector.snapshotCpu(.{
        .ptr = &probe,
        .event_fn = Probe.event,
        .cpu_sample_fn = Probe.cpu,
    });
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(pid, probe.pid);
    try std.testing.expect(probe.timestamp_ns > 0);
}

test "CPU snapshot timestamps each process after its cumulative read" {
    const Probe = struct {
        const Phase = enum {
            idle,
            cpu_read,
            timestamped,
        };

        phase: Phase = .idle,
        order_valid: bool = true,
        cpu_calls: usize = 0,
        timestamp_calls: usize = 0,
        identity_calls: usize = 0,
        delivered: usize = 0,
        timestamps: [2]u64 = undefined,

        fn processIdentity(pid: std.posix.pid_t) ProcessIdentity {
            return .{
                .parent_pid = 1,
                .pid_version = 1,
                .start_seconds = @intCast(pid),
                .start_microseconds = 0,
                .unique_id = @intCast(pid),
                .parent_unique_id = 1,
                .parent_pid_version = 1,
                .reserved = 0,
            };
        }

        fn readCpu(
            pointer: ?*anyopaque,
            pid: std.posix.pid_t,
            total_ns: *u64,
        ) c_int {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            if (self.phase != .idle) self.order_valid = false;
            self.phase = .cpu_read;
            self.cpu_calls += 1;
            total_ns.* = @as(u64, @intCast(pid)) * 10;
            return 0;
        }

        fn timestamp(pointer: ?*anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            if (self.phase != .cpu_read) self.order_valid = false;
            self.phase = .timestamped;
            const result = 1_000 + self.timestamp_calls * 100;
            self.timestamp_calls += 1;
            return result;
        }

        fn readIdentity(
            pointer: ?*anyopaque,
            pid: std.posix.pid_t,
            identity: *ProcessIdentity,
        ) c_int {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            if (self.phase != .timestamped) self.order_valid = false;
            self.phase = .idle;
            self.identity_calls += 1;
            identity.* = processIdentity(pid);
            return 0;
        }

        fn event(_: *anyopaque, _: capture.Event) void {}

        fn cpu(
            pointer: *anyopaque,
            _: std.posix.pid_t,
            _: u64,
            timestamp_ns: u64,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.timestamps[self.delivered] = timestamp_ns;
            self.delivered += 1;
        }
    };

    const testing = std.testing;
    var collector = Collector.init(testing.allocator);
    defer collector.deinit();
    inline for (.{ @as(std.posix.pid_t, 101), @as(std.posix.pid_t, 202) }) |pid| {
        try collector.tracked.put(testing.allocator, pid, .{
            .identity = Probe.processIdentity(pid),
            .generation = @intCast(pid),
        });
    }

    var probe = Probe{};
    collector.snapshotCpuWith(
        .{
            .ptr = &probe,
            .event_fn = Probe.event,
            .cpu_sample_fn = Probe.cpu,
        },
        &probe,
        Probe.readCpu,
        Probe.readIdentity,
        Probe.timestamp,
    );

    try testing.expect(probe.order_valid);
    try testing.expectEqual(@as(usize, 2), probe.cpu_calls);
    try testing.expectEqual(probe.cpu_calls, probe.timestamp_calls);
    try testing.expectEqual(probe.cpu_calls, probe.identity_calls);
    try testing.expectEqual(probe.cpu_calls, probe.delivered);
    try testing.expectEqual(@as(u64, 1_000), probe.timestamps[0]);
    try testing.expectEqual(@as(u64, 1_100), probe.timestamps[1]);
}

test "CPU snapshot advances after parallel thread work" {
    const Probe = struct {
        cpu_ns: u64 = 0,
        timestamp_ns: u64 = 0,

        fn event(_: *anyopaque, _: capture.Event) void {}

        fn cpu(
            pointer: *anyopaque,
            _: std.posix.pid_t,
            cpu_ns: u64,
            timestamp_ns: u64,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.cpu_ns = cpu_ns;
            self.timestamp_ns = timestamp_ns;
        }
    };
    const Busy = struct {
        fn run(
            completed_cycles: *std.atomic.Value(u64),
            seed: u64,
        ) void {
            var value = seed | 1;
            const cycle_count = 2_000;
            for (0..cycle_count) |_| {
                inline for (0..128) |_| {
                    value *%= 0x9e3779b97f4a7c15;
                    value ^= value >> 17;
                }
                std.mem.doNotOptimizeAway(value);
            }
            _ = completed_cycles.fetchAdd(cycle_count, .monotonic);
        }
    };

    const testing = std.testing;
    var collector = Collector.init(testing.allocator);
    defer collector.deinit();
    const pid = process_ops.currentPid();
    var identity: ProcessIdentity = undefined;
    try testing.expectEqual(@as(c_int, 0), flamez_macos_process_identity(pid, &identity));
    try collector.tracked.put(testing.allocator, pid, .{
        .identity = identity,
        .generation = 1,
    });

    var probe = Probe{};
    const sink = capture.Sink{
        .ptr = &probe,
        .event_fn = Probe.event,
        .cpu_sample_fn = Probe.cpu,
    };
    collector.snapshotCpu(sink);
    const baseline_cpu_ns = probe.cpu_ns;

    var completed_cycles: std.atomic.Value(u64) = .init(0);
    var threads: [4]std.Thread = undefined;
    var thread_count: usize = 0;
    var threads_joined = false;
    errdefer if (!threads_joined) {
        for (threads[0..thread_count]) |thread| thread.join();
    };
    while (thread_count < threads.len) : (thread_count += 1) {
        threads[thread_count] = try std.Thread.spawn(
            .{},
            Busy.run,
            .{ &completed_cycles, thread_count + 1 },
        );
    }
    for (threads) |thread| thread.join();
    threads_joined = true;

    collector.snapshotCpu(sink);
    try testing.expect(probe.cpu_ns > baseline_cpu_ns);
    try testing.expectEqual(@as(u64, 4 * 2_000), completed_cycles.load(.monotonic));
}
