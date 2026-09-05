//! Linux eBPF capture backend: object loading, raw-event normalization, and
//! cumulative CPU snapshots delivered through the shared capture contract.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const capture = @import("../capture.zig");
const Event = capture.Event;

const log = std.log.scoped(.ebpf);

const Kind = enum(u32) {
    fork = 1,
    exec = 2,
    exit = 3,
};

const max_exec_path_len = 512;

const metadata_args: u32 = 1 << 0;
const metadata_exe: u32 = 1 << 1;
const metadata_exe_truncated: u32 = 1 << 3;

const RawEvent = extern struct {
    kind: Kind,
    pid: std.posix.pid_t,
    parent_pid: std.posix.pid_t,
    metadata_flags: u32,
    timestamp_ns: u64,
    comm: [16]u8,
    args_len: u32,
    exe_len: u16,
    reserved: u16,
    /// Final process self CPU on exit; zero for fork and exec records.
    cpu_ns: u64 = 0,
};

const RawExecEvent = extern struct {
    base: RawEvent,
    exe: [max_exec_path_len]u8,
};

const ExecMetadata = struct {
    exe: ?[]const u8,
    args: ?[]const u8,
    exe_truncated: bool,
};

const Handle = opaque {};
const EbpfCallback = *const fn (*const RawEvent, usize, ?*anyopaque) callconv(.c) void;

/// One cumulative self-CPU sample from the C snapshot buffer. Layout matches
/// `struct flamez_cpu_total` in `ebpf_shim.c`.
const RawCpuTotal = extern struct {
    tgid: u32,
    reserved: u32 = 0,
    total_ns: u64,
};

extern fn flamez_ebpf_open(
    callback: EbpfCallback,
    userdata: ?*anyopaque,
    err_buf: [*]u8,
    err_size: usize,
) ?*Handle;
extern fn flamez_ebpf_drop_capabilities() c_int;
extern fn flamez_ebpf_poll(handle: *Handle) c_int;
extern fn flamez_ebpf_lost_events(handle: *Handle) u64;
extern fn flamez_ebpf_snapshot_cpu(
    handle: *Handle,
    out_samples: *?[*]const RawCpuTotal,
    out_count: *usize,
    out_timestamp_ns: *u64,
) c_int;
extern fn flamez_ebpf_track_pid(handle: *Handle, pid: std.posix.pid_t) c_int;
extern fn flamez_ebpf_seed_parent(handle: *Handle, pid: std.posix.pid_t) c_int;
extern fn flamez_ebpf_untrack_pid(handle: *Handle, pid: std.posix.pid_t) void;
extern fn flamez_ebpf_close(handle: *Handle) void;
extern fn flamez_bpf_test_exit_order(final_first: c_int, io_worker: c_int) c_int;
extern fn flamez_bpf_test_thread_lifecycle() c_int;

comptime {
    std.debug.assert(@sizeOf(RawEvent) == 56);
    std.debug.assert(@sizeOf(RawExecEvent) == 568);
    std.debug.assert(@sizeOf(RawCpuTotal) == 16);
}

/// Borrows the metadata attached to a successful exec event.
/// Returns null for non-exec or malformed records.
fn execMetadata(event: *const RawEvent, record_size: usize) ?ExecMetadata {
    if (event.kind != .exec or record_size < @sizeOf(RawExecEvent)) return null;
    const record: *const RawExecEvent = @ptrCast(event);
    const exe_len: usize = event.exe_len;
    if (exe_len > record.exe.len) return null;
    const args_len: usize = event.args_len;
    if (args_len != record_size - @sizeOf(RawExecEvent)) return null;
    const record_bytes: [*]const u8 = @ptrCast(event);
    return .{
        .exe = if (event.metadata_flags & metadata_exe != 0)
            record.exe[0..exe_len]
        else
            null,
        .args = if (event.metadata_flags & metadata_args != 0)
            record_bytes[@sizeOf(RawExecEvent)..][0..args_len]
        else
            null,
        .exe_truncated = event.metadata_flags & metadata_exe_truncated != 0,
    };
}

fn supported() bool {
    return builtin.os.tag == .linux and build_options.ebpf;
}

/// Owns one attached eBPF capture and normalizes its records for `Session`.
pub const Collector = struct {
    /// Owned libbpf handle; `deinit` closes it when non-null.
    handle: ?*Handle = null,
    /// Cumulative kernel loss plus failed userspace CPU snapshots.
    lost_events: u64 = 0,
    kernel_loss_seen: u64 = 0,
    diagnostic_buffer: [512]u8 = [_]u8{0} ** 512,
    diagnostic_len: usize = 0,
    cpu_snapshot_error: c_int = 0,
    /// Result of the latest nonblocking ring-buffer poll.
    last_ring_events: i32 = 0,
    /// Number of samples delivered by the latest successful CPU snapshot.
    last_cpu_samples: usize = 0,

    // Rendering and collection share one thread, so the callback target only
    // needs to remain set while the ring buffer is polled.
    var active_sink: ?capture.Sink = null;

    /// Loads the BPF object. On failure `available()` returns false and
    /// `diagnosticSlice()` explains why; callers are expected to abort startup.
    pub fn init(_: std.mem.Allocator) Collector {
        var self = Collector{};
        if (comptime !supported()) {
            self.setDiagnostic("the Linux eBPF collector is not included in this build");
            return self;
        }
        if (comptime builtin.is_test) pointShimAtCompiledObject();
        self.handle = flamez_ebpf_open(
            onEvent,
            null,
            &self.diagnostic_buffer,
            self.diagnostic_buffer.len,
        );
        if (self.handle == null) {
            const nul = std.mem.indexOfScalar(u8, &self.diagnostic_buffer, 0);
            self.diagnostic_len = nul orelse self.diagnostic_buffer.len;
        }
        return self;
    }

    /// Detaches every program, closes the BPF object, and invalidates `self`.
    pub fn deinit(self: *Collector) void {
        if (comptime supported()) {
            if (self.handle) |handle| flamez_ebpf_close(handle);
        }
        self.* = undefined;
    }

    /// Returns whether initialization produced a live collector handle.
    pub fn available(self: *const Collector) bool {
        return self.handle != null;
    }

    /// Clears the process's effective, permitted, and inheritable capability
    /// sets after the programs attach and before the target is spawned.
    pub fn dropPrivileges(self: *const Collector) capture.DropPrivilegesError!void {
        if (comptime supported()) {
            if (self.handle != null and flamez_ebpf_drop_capabilities() != 0)
                return error.PrivilegeDropRejected;
        }
    }

    /// Returns collector-owned initialization or capture diagnostics.
    pub fn diagnosticSlice(self: *const Collector) []const u8 {
        return self.diagnostic_buffer[0..self.diagnostic_len];
    }

    /// Linux eBPF delivers every admitted lifecycle transition or reports loss.
    pub fn fidelity(_: *const Collector) capture.Fidelity {
        return .exact;
    }

    /// Ensures the spawned root belongs to this capture.
    pub fn trackRoot(self: *Collector, pid: std.posix.pid_t) capture.TrackRootError!void {
        if (comptime supported()) {
            if (self.handle) |handle| {
                if (flamez_ebpf_track_pid(handle, pid) != 0)
                    return error.LaunchTrackingRejected;
            }
        }
    }

    /// Arms exactly the next process spawned by `pid` as a tracked root.
    pub fn armLaunch(self: *Collector, pid: std.posix.pid_t) capture.ArmLaunchError!void {
        if (comptime supported()) {
            if (self.handle) |handle| {
                if (flamez_ebpf_seed_parent(handle, pid) != 0)
                    return error.LaunchTrackingRejected;
            }
        }
    }

    /// Removes a launcher or process from backend tracking.
    pub fn untrack(self: *Collector, pid: std.posix.pid_t) void {
        if (comptime supported()) {
            if (self.handle) |handle| flamez_ebpf_untrack_pid(handle, pid);
        }
    }

    fn setDiagnostic(self: *Collector, value: []const u8) void {
        const amount = @min(value.len, self.diagnostic_buffer.len);
        @memcpy(self.diagnostic_buffer[0..amount], value[0..amount]);
        self.diagnostic_len = amount;
    }

    /// Drains pending lifecycle events without blocking and delivers them to `sink`.
    pub fn pollEvents(self: *Collector, sink: capture.Sink) void {
        if (comptime supported()) {
            active_sink = sink;
            defer active_sink = null;
            if (self.handle) |handle| {
                self.last_ring_events = flamez_ebpf_poll(handle);
                const lost = flamez_ebpf_lost_events(handle);
                if (lost > self.kernel_loss_seen) {
                    log.warn(
                        "eBPF capture dropped {d} events or accounting updates",
                        .{lost - self.kernel_loss_seen},
                    );
                    self.lost_events +|= lost - self.kernel_loss_seen;
                    self.kernel_loss_seen = lost;
                }
            }
        }
    }

    /// Drains lifecycle records enqueued before the root was observed reaped.
    pub fn flushEvents(self: *Collector, sink: capture.Sink) void {
        self.pollEvents(sink);
    }

    /// Reads cumulative process CPU totals once and delivers them to `sink`.
    pub fn snapshotCpu(self: *Collector, sink: capture.Sink) void {
        if (comptime !supported()) return;
        const handle = self.handle orelse return;
        var samples_ptr: ?[*]const RawCpuTotal = null;
        var count: usize = 0;
        var timestamp_ns: u64 = 0;
        const snapshot_result = flamez_ebpf_snapshot_cpu(
            handle,
            &samples_ptr,
            &count,
            &timestamp_ns,
        );
        if (snapshot_result != 0 and snapshot_result != self.cpu_snapshot_error) {
            log.warn("could not snapshot process CPU accounting: {d}", .{snapshot_result});
        }
        self.cpu_snapshot_error = snapshot_result;
        self.last_cpu_samples = if (snapshot_result == 0) count else 0;
        if (snapshot_result != 0) {
            self.lost_events +|= 1;
            self.setDiagnostic("a CPU accounting snapshot failed; capture is incomplete");
            return;
        }
        // The C shim owns this buffer until the next snapshot or collector teardown.
        const samples = (samples_ptr orelse return)[0..count];
        for (samples) |sample| {
            sink.cpuSample(@intCast(sample.tgid), sample.total_ns, timestamp_ns);
        }
    }

    fn onEvent(raw: *const RawEvent, record_size: usize, _: ?*anyopaque) callconv(.c) void {
        const sink = active_sink orelse return;
        const name = std.mem.sliceTo(&raw.comm, 0);
        const payload: Event.Payload = switch (raw.kind) {
            .fork => .{ .fork = .{
                .pid = raw.pid,
                .parent_pid = raw.parent_pid,
                .name = name,
            } },
            .exec => exec: {
                const metadata = execMetadata(raw, record_size);
                break :exec .{ .exec = .{
                    .pid = raw.pid,
                    .name = name,
                    .exe = if (metadata) |value| value.exe else null,
                    .args = if (metadata) |value| value.args else null,
                    .exe_truncated = if (metadata) |value| value.exe_truncated else false,
                } };
            },
            .exit => .{ .exit = .{
                .pid = raw.pid,
                .name = name,
                .cpu_ns = raw.cpu_ns,
                .cpu_final = true,
            } },
        };
        sink.event(.{ .timestamp_ns = raw.timestamp_ns, .payload = payload });
    }

    // Test binaries live in the cache, not next to share/flamez.
    fn pointShimAtCompiledObject() void {
        if (comptime !@hasDecl(build_options, "bpf_object")) return;
        const path = build_options.bpf_object;
        if (path.len == 0) return;
        const path_z: [:0]const u8 = path ++ "\x00";
        const setenv = struct {
            extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        }.setenv;
        _ = setenv("FLAMEZ_BPF_OBJECT", path_z, 1);
    }
};

test "collector attaches when privileges and object are present" {
    if (!supported()) return error.SkipZigTest;
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();
    if (collector.available()) return;
    if (std.mem.startsWith(
        u8,
        collector.diagnosticSlice(),
        "effective capabilities lack",
    )) return error.SkipZigTest;
    if (std.os.linux.geteuid() == 0) {
        // Root must attach once the build has handed us the object path.
        std.debug.print("root but eBPF unavailable: {s}\n", .{collector.diagnosticSlice()});
        return error.TestUnexpectedResult;
    }
    return error.SkipZigTest;
}

test "exec metadata validates size and exposes variable-length fields" {
    const args = "clang\x00-c\x00source.c\x00";
    const exe = "/usr/bin/clang";
    var storage: [@sizeOf(RawExecEvent) + args.len]u8 align(@alignOf(RawExecEvent)) =
        [_]u8{0} ** (@sizeOf(RawExecEvent) + args.len);
    const record: *RawExecEvent = @ptrCast(&storage);
    record.* = .{
        .base = .{
            .kind = .exec,
            .pid = 42,
            .parent_pid = 0,
            .metadata_flags = metadata_args | metadata_exe,
            .timestamp_ns = 10,
            .comm = [_]u8{0} ** 16,
            .args_len = args.len,
            .exe_len = exe.len,
            .reserved = 0,
        },
        .exe = [_]u8{0} ** max_exec_path_len,
    };
    @memcpy(record.exe[0..exe.len], exe);
    @memcpy(storage[@sizeOf(RawExecEvent)..], args);

    try std.testing.expect(execMetadata(&record.base, @sizeOf(RawEvent)) == null);
    try std.testing.expect(execMetadata(&record.base, storage.len - 1) == null);
    const metadata = execMetadata(&record.base, storage.len).?;
    try std.testing.expectEqualStrings(exe, metadata.exe.?);
    try std.testing.expectEqualStrings(args, metadata.args.?);
    try std.testing.expect(!metadata.exe_truncated);
}

test "exec metadata preserves argv beyond the former fixed limit" {
    const args_len = 8 * 1024 + 1;
    var storage: [@sizeOf(RawExecEvent) + args_len]u8 align(@alignOf(RawExecEvent)) =
        [_]u8{0} ** (@sizeOf(RawExecEvent) + args_len);
    const record: *RawExecEvent = @ptrCast(&storage);
    record.* = .{
        .base = .{
            .kind = .exec,
            .pid = 42,
            .parent_pid = 0,
            .metadata_flags = metadata_args,
            .timestamp_ns = 10,
            .comm = [_]u8{0} ** 16,
            .args_len = args_len,
            .exe_len = 0,
            .reserved = 0,
        },
        .exe = [_]u8{0} ** max_exec_path_len,
    };
    @memset(storage[@sizeOf(RawExecEvent) .. storage.len - 1], 'x');

    const metadata = execMetadata(&record.base, storage.len).?;
    try std.testing.expectEqual(@as(usize, args_len), metadata.args.?.len);
    try std.testing.expectEqual(@as(u8, 'x'), metadata.args.?[args_len - 2]);
    try std.testing.expectEqual(@as(u8, 0), metadata.args.?[args_len - 1]);
}

test "final thread CPU waits for earlier exits to finish accounting" {
    if (comptime !supported()) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, 0), flamez_bpf_test_exit_order(1, 0));
    try std.testing.expectEqual(@as(c_int, 0), flamez_bpf_test_exit_order(0, 0));
}

test "final thread CPU includes io workers without sched fork events" {
    if (comptime !supported()) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, 0), flamez_bpf_test_exit_order(1, 1));
    try std.testing.expectEqual(@as(c_int, 0), flamez_bpf_test_exit_order(0, 1));
}

test "final thread CPU survives scheduling exec and PID reuse" {
    if (comptime !supported()) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, 0), flamez_bpf_test_thread_lifecycle());
}

extern fn flamez_ebpf_test_failed_batch() c_int;

test "failed CPU map batch does not consume uninitialized entries" {
    if (comptime !supported()) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, 0), flamez_ebpf_test_failed_batch());
}

extern fn flamez_ebpf_test_validate_object(
    path: [*:0]const u8,
    writable: c_int,
    diagnostic: [*]u8,
    diagnostic_size: usize,
) c_int;

test "loader accepts the compiled object including internal constant maps" {
    if (comptime !supported()) return error.SkipZigTest;
    var diagnostic: [512]u8 = @splat(0);
    const result = flamez_ebpf_test_validate_object(
        build_options.bpf_object ++ "\x00",
        0,
        &diagnostic,
        diagnostic.len,
    );
    if (result != 0) std.debug.print("BPF object validation: {s}\n", .{
        std.mem.sliceTo(&diagnostic, 0),
    });
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "loader rejects writable internal maps" {
    if (comptime !supported()) return error.SkipZigTest;
    var diagnostic: [512]u8 = @splat(0);
    const result = flamez_ebpf_test_validate_object(
        build_options.bpf_object ++ "\x00",
        1,
        &diagnostic,
        diagnostic.len,
    );
    // Some compiler versions may inline every constant instead of emitting rodata.
    if (result == -@as(c_int, @intFromEnum(std.posix.E.NOENT))) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, 1), result);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&diagnostic, 0), "unexpected map") != null);
}
