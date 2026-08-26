//! eBPF ingestion: loads the BPF object through the C shim and turns
//! ring-buffer events into `Session` mutations. The collector is inert
//! off-Linux or when built without eBPF; callers check `available()`.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const log = std.log.scoped(.ebpf);

const Session = @import("Session.zig");

const Kind = enum(u32) {
    fork = 1,
    exec = 2,
    exit = 3,
};

pub const max_exec_path_len = 512;

pub const metadata_args: u32 = 1 << 0;
pub const metadata_exe: u32 = 1 << 1;
pub const metadata_exe_truncated: u32 = 1 << 3;

pub const Event = extern struct {
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

pub const ExecEvent = extern struct {
    base: Event,
    exe: [max_exec_path_len]u8,
};

pub const ExecMetadata = struct {
    exe: ?[]const u8,
    args: ?[]const u8,
    exe_truncated: bool,
};

const Handle = opaque {};
const EbpfCallback = *const fn (*const Event, usize, ?*anyopaque) callconv(.c) void;
const CpuCallback = *const fn (std.posix.pid_t, u64, u64, ?*anyopaque) callconv(.c) void;

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
    callback: CpuCallback,
    userdata: ?*anyopaque,
) c_int;
extern fn flamez_ebpf_track_pid(handle: *Handle, pid: std.posix.pid_t) c_int;
extern fn flamez_ebpf_seed_parent(handle: *Handle, pid: std.posix.pid_t) c_int;
extern fn flamez_ebpf_untrack_pid(handle: *Handle, pid: std.posix.pid_t) void;
extern fn flamez_ebpf_close(handle: *Handle) void;

comptime {
    std.debug.assert(@sizeOf(Event) == 56);
    std.debug.assert(@sizeOf(ExecEvent) == 568);
}

/// Borrows the metadata attached to a successful exec event.
/// Returns null for non-exec or malformed records.
pub fn execMetadata(event: *const Event, record_size: usize) ?ExecMetadata {
    if (event.kind != .exec or record_size < @sizeOf(ExecEvent)) return null;
    const record: *const ExecEvent = @ptrCast(event);
    const exe_len: usize = event.exe_len;
    if (exe_len > record.exe.len) return null;
    const args_len: usize = event.args_len;
    if (args_len != record_size - @sizeOf(ExecEvent)) return null;
    const record_bytes: [*]const u8 = @ptrCast(event);
    return .{
        .exe = if (event.metadata_flags & metadata_exe != 0)
            record.exe[0..exe_len]
        else
            null,
        .args = if (event.metadata_flags & metadata_args != 0)
            record_bytes[@sizeOf(ExecEvent)..][0..args_len]
        else
            null,
        .exe_truncated = event.metadata_flags & metadata_exe_truncated != 0,
    };
}

/// Returns whether this build includes the Linux eBPF bridge.
pub fn ebpfSupported() bool {
    return builtin.os.tag == .linux and build_options.ebpf;
}

pub const Collector = struct {
    handle: ?*Handle = null,
    lost_events: u64 = 0,
    diagnostic_buffer: [512]u8 = [_]u8{0} ** 512,
    diagnostic_len: usize = 0,
    cpu_snapshot_error: c_int = 0,

    // Rendering and collection share one thread, so the callback target only
    // needs to remain set during `poll`.
    var active_session: ?*Session = null;

    /// Loads the BPF object. On failure `available()` returns false and
    /// `diagnosticSlice()` explains why; callers are expected to abort startup.
    pub fn init() Collector {
        var self = Collector{};
        if (comptime !ebpfSupported()) {
            self.setDiagnostic("the eBPF collector is only built on Linux");
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
        if (comptime ebpfSupported()) {
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
    pub fn dropCapabilities(self: *const Collector) error{CapabilityDropRejected}!void {
        if (comptime ebpfSupported()) {
            if (self.handle != null and flamez_ebpf_drop_capabilities() != 0)
                return error.CapabilityDropRejected;
        }
    }

    /// Returns collector-owned initialization diagnostics.
    pub fn diagnosticSlice(self: *const Collector) []const u8 {
        return self.diagnostic_buffer[0..self.diagnostic_len];
    }

    /// Adds a process to the kernel-side target set before it can run.
    pub fn trackPid(self: *Collector, pid: std.posix.pid_t) error{PidTrackingRejected}!void {
        if (comptime ebpfSupported()) {
            if (self.handle) |handle| {
                if (flamez_ebpf_track_pid(handle, pid) != 0)
                    return error.PidTrackingRejected;
            }
        }
    }

    /// Arms exactly the next process spawned by `pid` as a tracked root.
    pub fn seedParent(self: *Collector, pid: std.posix.pid_t) error{PidTrackingRejected}!void {
        if (comptime ebpfSupported()) {
            if (self.handle) |handle| {
                if (flamez_ebpf_seed_parent(handle, pid) != 0)
                    return error.PidTrackingRejected;
            }
        }
    }

    /// Removes a completed process from the kernel-side target set.
    pub fn untrackPid(self: *Collector, pid: std.posix.pid_t) void {
        if (comptime ebpfSupported()) {
            if (self.handle) |handle| flamez_ebpf_untrack_pid(handle, pid);
        }
    }

    fn setDiagnostic(self: *Collector, value: []const u8) void {
        const amount = @min(value.len, self.diagnostic_buffer.len);
        @memcpy(self.diagnostic_buffer[0..amount], value[0..amount]);
        self.diagnostic_len = amount;
    }

    /// Drains pending events without blocking and applies them to `session`.
    pub fn poll(self: *Collector, session: *Session) void {
        if (comptime ebpfSupported()) {
            active_session = session;
            defer active_session = null;
            if (self.handle) |handle| {
                _ = flamez_ebpf_poll(handle);
                const snapshot_result = flamez_ebpf_snapshot_cpu(handle, onCpu, null);
                if (snapshot_result != 0 and snapshot_result != self.cpu_snapshot_error) {
                    log.warn("could not snapshot process CPU accounting: {d}", .{snapshot_result});
                }
                self.cpu_snapshot_error = snapshot_result;
                const lost = flamez_ebpf_lost_events(handle);
                if (lost > self.lost_events) {
                    log.warn(
                        "eBPF capture dropped {d} events or accounting updates",
                        .{lost - self.lost_events},
                    );
                    self.lost_events = lost;
                }
            }
        }
    }

    fn onEvent(event: *const Event, record_size: usize, _: ?*anyopaque) callconv(.c) void {
        if (active_session) |session| session.consumeEbpfEvent(event, record_size);
    }

    fn onCpu(
        pid: std.posix.pid_t,
        cpu_ns: u64,
        timestamp_ns: u64,
        _: ?*anyopaque,
    ) callconv(.c) void {
        if (active_session) |session| {
            session.consumeCpuSnapshot(pid, cpu_ns, timestamp_ns);
        }
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
    if (!ebpfSupported()) return error.SkipZigTest;
    var collector = Collector.init();
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
    var storage: [@sizeOf(ExecEvent) + args.len]u8 align(@alignOf(ExecEvent)) =
        [_]u8{0} ** (@sizeOf(ExecEvent) + args.len);
    const record: *ExecEvent = @ptrCast(&storage);
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
    @memcpy(storage[@sizeOf(ExecEvent)..], args);

    try std.testing.expect(execMetadata(&record.base, @sizeOf(Event)) == null);
    try std.testing.expect(execMetadata(&record.base, storage.len - 1) == null);
    const metadata = execMetadata(&record.base, storage.len).?;
    try std.testing.expectEqualStrings(exe, metadata.exe.?);
    try std.testing.expectEqualStrings(args, metadata.args.?);
    try std.testing.expect(!metadata.exe_truncated);
}

test "exec metadata preserves argv beyond the former fixed limit" {
    const args_len = 8 * 1024 + 1;
    var storage: [@sizeOf(ExecEvent) + args_len]u8 align(@alignOf(ExecEvent)) =
        [_]u8{0} ** (@sizeOf(ExecEvent) + args_len);
    const record: *ExecEvent = @ptrCast(&storage);
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
    @memset(storage[@sizeOf(ExecEvent) .. storage.len - 1], 'x');

    const metadata = execMetadata(&record.base, storage.len).?;
    try std.testing.expectEqual(@as(usize, args_len), metadata.args.?.len);
    try std.testing.expectEqual(@as(u8, 'x'), metadata.args.?[args_len - 2]);
    try std.testing.expectEqual(@as(u8, 0), metadata.args.?[args_len - 1]);
}
