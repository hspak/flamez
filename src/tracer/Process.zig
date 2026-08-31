//! One captured process record: identity, argv/exe/cwd snapshots, and the
//! lifetime interval shown in the timeline. `Session.processes` owns records
//! for the duration of a capture.

const std = @import("std");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.process);

const Process = @This();

pid: std.posix.pid_t,
/// Kernel-reported parent TGID, or the session root for recovered stubs.
/// Tree geometry uses `parent_index`; this field is the identity shown as PPID.
parent_pid: ?std.posix.pid_t = null,
/// Stable index of the tracked parent, avoiding repeated pid-map lookups in UI builds.
parent_index: ?usize = null,
depth: u16 = 0,
start_ns: u64 = 0,
end_ns: ?u64 = null,
/// How this record entered the session. Inferred starts are not exact observations.
origin: Origin = .observed,
/// How an open lifetime was closed. Capture-clipped ends are not observed exits.
end_kind: EndKind = .open,
/// Cumulative on-CPU time for every thread in this process, excluding descendants.
cpu_time_ns: u64 = 0,
/// True only when a natural-exit observation supplied the final cumulative total.
cpu_final: bool = false,
cpu_snapshot_at_ns: u64 = 0,
cpu_snapshot_initialized: bool = false,
/// Peak average-core occupancy across retained slices; maintained while recording.
cpu_peak_cores: f64 = 0,
/// Canonical activity history for this process. Long captures keep every
/// coalesced slice; pixel aggregation is a derived render view, not a
/// replacement for these samples.
cpu_slices: std.ArrayList(CpuSlice) = .empty,
/// Completed exec intervals, in execution order. The current exec remains
/// in the fields below so timeline rendering stays allocation-free.
execs: std.ArrayList(Exec) = .empty,
exec_start_ns: u64 = 0,
name: [max_name_len]u8 = [_]u8{0} ** max_name_len,
name_len: u8 = 0,
name_kind: NameKind = .other,
/// NUL-separated argv captured at exec, inherited at fork, or read from procfs.
args_offset: usize = 0,
args_len: usize = 0,
args_count: usize = 0,
args_source: MetadataSource = .unavailable,
exe_offset: usize = 0,
exe_len: u16 = 0,
exe_source: MetadataSource = .unavailable,
exe_truncated: bool = false,
cwd_offset: usize = 0,
cwd_len: u16 = 0,
cwd_source: MetadataSource = .unavailable,
cwd_truncated: bool = false,
/// Slot in the async-signal-safe teardown table; null when capacity is exhausted.
signal_slot: ?u16 = null,
/// Changes whenever cached UI-visible process data changes.
revision: u64 = 0,

pub const max_name_len = 48;
pub const max_path_len = 512;

pub const NameKind = enum { process, other };

pub const MetadataSource = enum {
    unavailable,
    inherited,
    launch,
    kernel,
    procfs,
    process_inspection,
};

/// How a process record was created. Recovered rows keep a visible tree, but
/// their start time (and sometimes parentage) is inferred.
pub const Origin = enum {
    observed,
    recovered_parent,
    recovered_exec,
    recovered_exit,
};

/// How a lifetime ended. Forced Stop and root-exit close descendants at the
/// capture boundary without proving each one exited then.
pub const EndKind = enum {
    open,
    observed_exit,
    capture_clipped,
};

/// One exec that occupied a process PID during a bounded interval.
/// Variable-length fields borrow the owning session's metadata store.
pub const Exec = struct {
    start_ns: u64,
    end_ns: ?u64,
    name: [max_name_len]u8 = [_]u8{0} ** max_name_len,
    name_len: u8 = 0,
    name_kind: NameKind = .other,
    args_offset: usize = 0,
    args_len: usize = 0,
    args_count: usize = 0,
    args_source: MetadataSource = .unavailable,
    exe_offset: usize = 0,
    exe_len: u16 = 0,
    exe_source: MetadataSource = .unavailable,
    exe_truncated: bool = false,
    cwd_offset: usize = 0,
    cwd_len: u16 = 0,
    cwd_source: MetadataSource = .unavailable,
    cwd_truncated: bool = false,
    /// Retained only to keep the original row command stable; omitted from history.
    row_only: bool = false,

    /// Returns the exec's captured process name.
    pub fn nameSlice(self: *const Exec) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Iterates this exec's borrowed argv slices.
    pub fn argsIter(self: *const Exec, metadata: []const u8) ArgIter {
        return .{
            .bytes = metadataSlice(metadata, self.args_offset, self.args_len),
            .remaining = self.args_count,
        };
    }

    /// Returns argv[0], or an empty slice when no arguments were captured.
    pub fn argv0(self: *const Exec, metadata: []const u8) []const u8 {
        var args = self.argsIter(metadata);
        return args.next() orelse "";
    }

    /// Returns this exec's executable path, or an empty slice.
    pub fn exeSlice(self: *const Exec, metadata: []const u8) []const u8 {
        return metadataSlice(metadata, self.exe_offset, self.exe_len);
    }

    /// Returns this exec's working directory, or an empty slice.
    pub fn cwdSlice(self: *const Exec, metadata: []const u8) []const u8 {
        return metadataSlice(metadata, self.cwd_offset, self.cwd_len);
    }

    /// Space-joins the complete recorded argv into `dest`.
    pub fn copyCmdline(self: *const Exec, metadata: []const u8, dest: []u8) []const u8 {
        const args = metadataSlice(metadata, self.args_offset, self.args_len);
        std.debug.assert(dest.len >= args.len);
        for (args, 0..) |byte, index| dest[index] = if (byte == 0) ' ' else byte;
        return std.mem.trim(u8, dest[0..args.len], " ");
    }

    /// Returns a short argv-derived suffix that distinguishes similar execs.
    pub fn argSummary(self: *const Exec, metadata: []const u8, buffer: []u8) []const u8 {
        return argSummaryFor(Exec, self, metadata, buffer);
    }
};

pub const MetadataStore = std.ArrayList(u8);

pub const CpuSlice = struct {
    start_ns: u64,
    end_ns: u64,
    cpu_ns: u64,
    /// Quarter-core occupancy band, capped at sixteen cores.
    band: u8,

    pub fn durationNs(self: CpuSlice) u64 {
        return self.end_ns -| self.start_ns;
    }

    pub fn averageCores(self: CpuSlice) f64 {
        const duration = self.durationNs();
        if (duration == 0) return 0;
        return @as(f64, @floatFromInt(self.cpu_ns)) /
            @as(f64, @floatFromInt(duration));
    }
};

pub const Named = struct {
    text: []const u8,
    kind: NameKind,

    pub fn fromComm(text: []const u8) Named {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return .{ .text = "process", .kind = .other };
        return .{ .text = trimmed, .kind = .process };
    }

    pub fn fromOther(text: []const u8) Named {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return .{ .text = "process", .kind = .other };
        return .{ .text = trimmed, .kind = .other };
    }
};

pub const ArgIter = struct {
    bytes: []const u8,
    remaining: usize,
    pos: usize = 0,

    pub fn next(self: *ArgIter) ?[]const u8 {
        if (self.remaining == 0) return null;
        const start = self.pos;
        while (self.pos < self.bytes.len and self.bytes[self.pos] != 0) self.pos += 1;
        const slice = self.bytes[start..self.pos];
        if (self.pos < self.bytes.len) self.pos += 1;
        self.remaining -= 1;
        return slice;
    }
};

const StoredPath = struct {
    offset: usize,
    len: u16,
    truncated: bool,
};

/// Releases CPU activity storage owned by this process and invalidates it.
pub fn deinit(self: *Process, gpa: Allocator) void {
    self.cpu_slices.deinit(gpa);
    self.execs.deinit(gpa);
    self.* = undefined;
}

/// Adds a cumulative self-CPU snapshot at a monotonic session timestamp.
/// Active intervals are retained in quarter-core bands and adjacent buckets
/// in the same band coalesce into one render slice.
pub fn recordCpuSnapshot(
    self: *Process,
    gpa: Allocator,
    at_ns: u64,
    total_ns: u64,
) Allocator.Error!void {
    const end_ns = @max(at_ns, self.start_ns);
    const start_ns = if (self.cpu_snapshot_initialized)
        self.cpu_snapshot_at_ns
    else
        self.start_ns;
    const monotonic_total = @max(total_ns, self.cpu_time_ns);
    const delta_ns = monotonic_total - self.cpu_time_ns;

    if (delta_ns == 0 or end_ns <= start_ns) {
        self.cpu_time_ns = monotonic_total;
        self.cpu_snapshot_at_ns = @max(end_ns, start_ns);
        self.cpu_snapshot_initialized = true;
        return;
    }

    const band = cpuBand(delta_ns, end_ns - start_ns);
    if (self.cpu_slices.items.len > 0) {
        const previous = &self.cpu_slices.items[self.cpu_slices.items.len - 1];
        if (previous.end_ns == start_ns and previous.band == band) {
            previous.end_ns = end_ns;
            previous.cpu_ns +|= delta_ns;
            self.cpu_time_ns = monotonic_total;
            self.cpu_snapshot_at_ns = end_ns;
            self.cpu_snapshot_initialized = true;
            self.cpu_peak_cores = @max(self.cpu_peak_cores, previous.averageCores());
            return;
        }
    }
    try self.cpu_slices.ensureUnusedCapacity(gpa, 1);
    self.cpu_time_ns = monotonic_total;
    self.cpu_snapshot_at_ns = end_ns;
    self.cpu_snapshot_initialized = true;
    self.cpu_slices.appendAssumeCapacity(.{
        .start_ns = start_ns,
        .end_ns = end_ns,
        .cpu_ns = delta_ns,
        .band = band,
    });
    self.cpu_peak_cores = @max(
        self.cpu_peak_cores,
        self.cpu_slices.items[self.cpu_slices.items.len - 1].averageCores(),
    );
}

/// Recomputes CPU slice bands and peak occupancy from canonical slice triples.
pub fn rebuildCpuCaches(self: *Process) void {
    self.cpu_peak_cores = 0;
    for (self.cpu_slices.items) |*slice| {
        slice.band = cpuBand(slice.cpu_ns, slice.durationNs());
        self.cpu_peak_cores = @max(self.cpu_peak_cores, slice.averageCores());
    }
}

/// First index of a time-ordered slice list that can overlap `[window_start, window_end)`.
/// Returns `slices.len` when nothing in the list is visible.
pub fn firstVisibleSlice(slices: []const CpuSlice, window_start_ns: u64, window_end_ns: u64) usize {
    if (slices.len == 0 or window_end_ns <= window_start_ns) return 0;
    var lo: usize = 0;
    var hi: usize = slices.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (slices[mid].end_ns <= window_start_ns) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/// Records the exact kernel-side total carried by a natural process exit.
/// A map snapshot can briefly overestimate a still-running thread because its
/// userspace timestamp is taken after the running-thread map read. Reconcile
/// that bounded skew from the newest slices before closing the process.
pub fn recordFinalCpuSnapshot(
    self: *Process,
    gpa: Allocator,
    at_ns: u64,
    total_ns: u64,
) Allocator.Error!void {
    if (total_ns >= self.cpu_time_ns) {
        return self.recordCpuSnapshot(gpa, at_ns, total_ns);
    }

    var correction_ns = self.cpu_time_ns - total_ns;
    while (correction_ns > 0 and self.cpu_slices.items.len > 0) {
        const last = &self.cpu_slices.items[self.cpu_slices.items.len - 1];
        if (correction_ns >= last.cpu_ns) {
            correction_ns -= last.cpu_ns;
            self.cpu_slices.items.len -= 1;
            continue;
        }
        last.cpu_ns -= correction_ns;
        last.band = cpuBand(last.cpu_ns, last.durationNs());
        correction_ns = 0;
    }
    coalesceLastCpuSlices(self);
    self.cpu_time_ns = total_ns;
    self.cpu_snapshot_at_ns = @max(at_ns, self.start_ns);
    self.cpu_snapshot_initialized = true;
    self.cpu_peak_cores = 0;
    for (self.cpu_slices.items) |slice| {
        self.cpu_peak_cores = @max(self.cpu_peak_cores, slice.averageCores());
    }
}

fn coalesceLastCpuSlices(self: *Process) void {
    if (self.cpu_slices.items.len < 2) return;
    const last_index = self.cpu_slices.items.len - 1;
    const previous = &self.cpu_slices.items[last_index - 1];
    const last = self.cpu_slices.items[last_index];
    if (previous.end_ns != last.start_ns or previous.band != last.band) return;
    previous.end_ns = last.end_ns;
    previous.cpu_ns +|= last.cpu_ns;
    self.cpu_slices.items.len -= 1;
}

fn clipCpuSlices(self: *Process, end_ns: u64) void {
    if (self.cpu_snapshot_initialized) {
        self.cpu_snapshot_at_ns = @min(self.cpu_snapshot_at_ns, end_ns);
    }
    if (self.cpu_slices.items.len == 0 or
        self.cpu_slices.items[self.cpu_slices.items.len - 1].end_ns <= end_ns)
    {
        return;
    }
    for (self.cpu_slices.items, 0..) |*slice, index| {
        if (slice.start_ns >= end_ns) {
            self.cpu_slices.items.len = index;
            break;
        }
        if (slice.end_ns > end_ns) {
            slice.end_ns = end_ns;
            self.cpu_slices.items.len = index + 1;
            break;
        }
    }
    self.rebuildCpuCaches();
    coalesceLastCpuSlices(self);
    self.rebuildCpuCaches();
}

fn cpuBand(cpu_ns: u64, duration_ns: u64) u8 {
    if (cpu_ns == 0 or duration_ns == 0) return 0;
    const numerator = @as(u128, cpu_ns) * 4;
    const band = (numerator + duration_ns - 1) / duration_ns;
    return @intCast(@min(band, 64));
}

/// Returns the process-owned display-name bytes.
pub fn nameSlice(self: *const Process) []const u8 {
    return self.name[0..self.name_len];
}

/// Returns a value snapshot of the current exec occupying this PID.
pub fn currentExec(self: *const Process) Exec {
    return .{
        .start_ns = self.exec_start_ns,
        .end_ns = self.end_ns,
        .name = self.name,
        .name_len = self.name_len,
        .name_kind = self.name_kind,
        .args_offset = self.args_offset,
        .args_len = self.args_len,
        .args_count = self.args_count,
        .args_source = self.args_source,
        .exe_offset = self.exe_offset,
        .exe_len = self.exe_len,
        .exe_source = self.exe_source,
        .exe_truncated = self.exe_truncated,
        .cwd_offset = self.cwd_offset,
        .cwd_len = self.cwd_len,
        .cwd_source = self.cwd_source,
        .cwd_truncated = self.cwd_truncated,
    };
}

/// Number of completed execs plus the current exec.
pub fn execCount(self: *const Process) usize {
    return self.execs.items.len - execHistoryOffset(self) + 1;
}

/// Returns one chronological exec snapshot. `index` must be less than `execCount()`.
pub fn execAt(self: *const Process, index: usize) Exec {
    std.debug.assert(index < self.execCount());
    const stored_index = index + execHistoryOffset(self);
    if (stored_index < self.execs.items.len) return self.execs.items[stored_index];
    return self.currentExec();
}

fn execHistoryOffset(self: *const Process) usize {
    if (self.execs.items.len > 0 and self.execs.items[0].row_only) return 1;
    return 0;
}

/// Returns the exec whose command remains fixed on the timeline row.
pub fn rowExec(self: *const Process) Exec {
    if (self.execs.items.len > 0) return self.execs.items[0];
    return self.currentExec();
}

/// Returns the stable process name used by the timeline row.
pub fn rowNameSlice(self: *const Process) []const u8 {
    if (self.execs.items.len > 0) return self.execs.items[0].nameSlice();
    return self.nameSlice();
}

/// Returns the provenance of the stable timeline-row name.
pub fn rowNameKind(self: *const Process) NameKind {
    if (self.execs.items.len > 0) return self.execs.items[0].name_kind;
    return self.name_kind;
}

/// Returns the stable argv-derived suffix used by the timeline row.
pub fn rowArgSummary(self: *const Process, metadata: []const u8, buffer: []u8) []const u8 {
    if (self.execs.items.len > 0) {
        return self.execs.items[0].argSummary(metadata, buffer);
    }
    return self.argSummary(metadata, buffer);
}

/// Retains the current launch command for row rendering without adding a
/// second entry to exec history.
pub fn retainCurrentExecForRow(self: *Process, gpa: Allocator) Allocator.Error!void {
    std.debug.assert(self.execs.items.len == 0);
    var exec = self.currentExec();
    exec.row_only = true;
    try self.execs.append(gpa, exec);
}

/// Closes the current exec at `at_ns` and starts a new exec interval.
/// On allocation failure the new interval still begins, leaving a visible gap
/// rather than assigning the replacement exec to the previous interval.
pub fn archiveCurrentExec(
    self: *Process,
    gpa: Allocator,
    at_ns: u64,
) Allocator.Error!void {
    const next_start_ns = @max(self.exec_start_ns, at_ns);
    var exec = self.currentExec();
    exec.end_ns = next_start_ns;
    self.execs.append(gpa, exec) catch |err| {
        self.exec_start_ns = next_start_ns;
        return err;
    };
    self.exec_start_ns = next_start_ns;
}

/// Returns the recorded lifetime, using `now_ns` when the process is open.
pub fn durationNs(self: *const Process, now_ns: u64) u64 {
    return (self.end_ns orelse now_ns) -| self.start_ns;
}

fn metadataSlice(metadata: []const u8, offset: usize, len: usize) []const u8 {
    if (offset > metadata.len or len > metadata.len - offset) return "";
    return metadata[offset..][0..len];
}

/// Iterates borrowed argv slices from the session metadata store.
pub fn argsIter(self: *const Process, metadata: []const u8) ArgIter {
    return .{
        .bytes = metadataSlice(metadata, self.args_offset, self.args_len),
        .remaining = self.args_count,
    };
}

/// Returns the process-owned executable-path bytes, or an empty slice.
pub fn exeSlice(self: *const Process, metadata: []const u8) []const u8 {
    return metadataSlice(metadata, self.exe_offset, self.exe_len);
}

/// Returns the process-owned working-directory bytes, or an empty slice.
pub fn cwdSlice(self: *const Process, metadata: []const u8) []const u8 {
    return metadataSlice(metadata, self.cwd_offset, self.cwd_len);
}

/// Returns argv[0], or an empty slice when no arguments were captured.
pub fn argv0(self: *const Process, metadata: []const u8) []const u8 {
    var it = self.argsIter(metadata);
    return it.next() orelse "";
}

/// Space-joined cmdline. `dest` must hold the complete recorded argv block.
pub fn copyCmdline(self: *const Process, metadata: []const u8, dest: []u8) []const u8 {
    const args = metadataSlice(metadata, self.args_offset, self.args_len);
    std.debug.assert(dest.len >= args.len);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        dest[i] = if (args[i] == 0) ' ' else args[i];
    }
    return std.mem.trim(u8, dest[0..args.len], " ");
}

/// Space-joins argv[1..], excluding the executable identity in argv[0].
pub fn copyArguments(self: *const Process, metadata: []const u8, dest: []u8) []const u8 {
    std.debug.assert(dest.len >= self.args_len);
    var args = self.argsIter(metadata);
    _ = args.next();
    var len: usize = 0;
    var argument_index: usize = 0;
    while (args.next()) |arg| {
        if (argument_index > 0) {
            dest[len] = ' ';
            len += 1;
        }
        @memcpy(dest[len..][0..arg.len], arg);
        len += arg.len;
        argument_index += 1;
    }
    return dest[0..len];
}

/// Short distinguishing suffix: rustc crate, compiler source, cargo subcommand.
pub fn argSummary(self: *const Process, metadata: []const u8, buffer: []u8) []const u8 {
    return argSummaryFor(Process, self, metadata, buffer);
}

fn argSummaryFor(
    comptime Subject: type,
    subject: *const Subject,
    metadata: []const u8,
    buffer: []u8,
) []const u8 {
    const comm = subject.nameSlice();
    if (isRustc(comm)) {
        if (flagValue(Subject, subject, metadata, "--crate-name")) |crate|
            return copyShort(buffer, crate);
        if (lastSourceBasename(Subject, subject, metadata)) |src| return copyShort(buffer, src);
    } else if (isLinker(comm)) {
        if (flagValue(Subject, subject, metadata, "-o")) |out| {
            return copyShort(buffer, std.fs.path.basename(out));
        }
    } else if (isCompiler(comm)) {
        if (lastSourceBasename(Subject, subject, metadata)) |src| return copyShort(buffer, src);
    } else if (isCargo(comm)) {
        return cargoSummary(Subject, subject, metadata, buffer);
    } else if (isNinja(comm)) {
        const dir = flagValue(Subject, subject, metadata, "-C");
        const target = firstPositional(Subject, subject, metadata);
        if (dir) |d| {
            if (target) |t| return copyShortJoin(buffer, std.fs.path.basename(d), t);
            return copyShort(buffer, std.fs.path.basename(d));
        }
        if (target) |t| return copyShort(buffer, t);
    } else if (firstPositional(Subject, subject, metadata)) |pos| {
        const base = std.fs.path.basename(pos);
        if (!std.mem.eql(u8, base, comm)) return copyShort(buffer, base);
    }
    return "";
}

fn cargoSummary(
    comptime Subject: type,
    subject: *const Subject,
    metadata: []const u8,
    buffer: []u8,
) []const u8 {
    const sub = firstPositional(Subject, subject, metadata) orelse "";
    const pkg = flagValue(Subject, subject, metadata, "-p") orelse
        flagValue(Subject, subject, metadata, "--package") orelse "";
    if (sub.len != 0 and pkg.len != 0) return copyShortJoin(buffer, sub, pkg);
    if (pkg.len != 0) return copyShort(buffer, pkg);
    if (sub.len != 0) return copyShort(buffer, sub);
    return "";
}

fn flagValue(
    comptime Subject: type,
    subject: *const Subject,
    metadata: []const u8,
    flag: []const u8,
) ?[]const u8 {
    var it = subject.argsIter(metadata);
    _ = it.next();
    var pending = false;
    while (it.next()) |arg| {
        if (pending) return arg;
        if (std.mem.eql(u8, arg, flag)) {
            pending = true;
            continue;
        }
        if (arg.len > flag.len + 1 and std.mem.startsWith(u8, arg, flag) and arg[flag.len] == '=') {
            return arg[flag.len + 1 ..];
        }
    }
    return null;
}

fn firstPositional(
    comptime Subject: type,
    subject: *const Subject,
    metadata: []const u8,
) ?[]const u8 {
    var it = subject.argsIter(metadata);
    _ = it.next();
    var skip_next = false;
    while (it.next()) |arg| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        if (arg.len == 0) continue;
        if (arg[0] == '-') {
            if (takesValue(arg)) skip_next = true;
            continue;
        }
        return arg;
    }
    return null;
}

fn lastSourceBasename(
    comptime Subject: type,
    subject: *const Subject,
    metadata: []const u8,
) ?[]const u8 {
    var it = subject.argsIter(metadata);
    _ = it.next();
    var last: ?[]const u8 = null;
    var skip_next = false;
    while (it.next()) |arg| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            skip_next = true;
            continue;
        }
        if (isSourcePath(arg)) last = arg;
    }
    return if (last) |path| std.fs.path.basename(path) else null;
}

/// Stores a trimmed, bounded display name and its provenance.
pub fn setName(self: *Process, value: []const u8, kind: NameKind) void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) {
        const fallback = "process";
        @memcpy(self.name[0..fallback.len], fallback);
        self.name_len = fallback.len;
        self.name_kind = .other;
        // Font measurement caches key off `revision` and layout width;
        // a name-only revision is intentionally not retained.
        self.revision +%= 1;
        return;
    }
    const length = @min(trimmed.len, self.name.len);
    @memcpy(self.name[0..length], trimmed[0..length]);
    self.name_len = @intCast(length);
    self.name_kind = kind;
    self.revision +%= 1;
}

fn setArgs(
    self: *Process,
    store: *MetadataStore,
    gpa: Allocator,
    raw: []const u8,
    source: MetadataSource,
) Allocator.Error!void {
    const offset = store.items.len;
    try store.appendSlice(gpa, raw);
    self.args_offset = offset;
    self.args_len = raw.len;
    self.args_count = std.mem.count(u8, raw, "\x00") +
        @intFromBool(raw.len > 0 and raw[raw.len - 1] != 0);
    self.args_source = source;
    self.revision +%= 1;
}

/// Copies a NUL-separated procfs command line into session metadata storage.
pub fn setArgsFromCmdline(
    self: *Process,
    store: *MetadataStore,
    gpa: Allocator,
    raw: []const u8,
) Allocator.Error!void {
    try self.setArgs(store, gpa, raw, .procfs);
}

/// Copies a NUL-separated argument list obtained from a platform process-inspection API.
pub fn setArgsFromProcessInspection(
    self: *Process,
    store: *MetadataStore,
    gpa: Allocator,
    raw: []const u8,
) Allocator.Error!void {
    try self.setArgs(store, gpa, raw, .process_inspection);
}

/// Copies argv captured synchronously by the exec tracepoint.
pub fn setArgsFromKernel(
    self: *Process,
    store: *MetadataStore,
    gpa: Allocator,
    raw: []const u8,
) Allocator.Error!void {
    try self.setArgs(store, gpa, raw, .kernel);
}

/// Copies argv into session metadata storage as NUL-separated strings.
pub fn setArgsFromArgv(
    self: *Process,
    store: *MetadataStore,
    gpa: Allocator,
    argv: []const []const u8,
) Allocator.Error!void {
    var total_len: usize = 0;
    for (argv) |arg| {
        total_len = std.math.add(usize, total_len, arg.len) catch
            return error.OutOfMemory;
        total_len = std.math.add(usize, total_len, 1) catch
            return error.OutOfMemory;
    }
    try store.ensureUnusedCapacity(gpa, total_len);
    const offset = store.items.len;
    for (argv) |arg| {
        store.appendSliceAssumeCapacity(arg);
        store.appendAssumeCapacity(0);
    }
    self.args_offset = offset;
    self.args_len = total_len;
    self.args_count = argv.len;
    self.args_source = .launch;
    self.revision +%= 1;
}

fn storePath(
    store: *MetadataStore,
    gpa: Allocator,
    value: []const u8,
) Allocator.Error!StoredPath {
    const n = @min(value.len, max_path_len);
    const offset = store.items.len;
    try store.appendSlice(gpa, value[0..n]);
    return .{
        .offset = offset,
        .len = @intCast(n),
        .truncated = value.len > max_path_len,
    };
}

fn pathUnchanged(current: []const u8, value: []const u8, truncated: bool) bool {
    const n = @min(value.len, max_path_len);
    return current.len == n and
        truncated == (value.len > max_path_len) and
        std.mem.eql(u8, current, value[0..n]);
}

/// Stores a bounded executable path in this record.
pub fn setExe(
    self: *Process,
    store: *MetadataStore,
    gpa: Allocator,
    value: []const u8,
) Allocator.Error!void {
    if (pathUnchanged(self.exeSlice(store.items), value, self.exe_truncated)) return;
    const stored = try storePath(store, gpa, value);
    self.exe_offset = stored.offset;
    self.exe_len = stored.len;
    self.exe_truncated = stored.truncated;
    self.exe_source = .procfs;
    self.revision +%= 1;
}

/// Stores a bounded executable path obtained from a platform process-inspection API.
pub fn setExeFromProcessInspection(
    self: *Process,
    store: *MetadataStore,
    gpa: Allocator,
    value: []const u8,
) Allocator.Error!void {
    if (pathUnchanged(self.exeSlice(store.items), value, self.exe_truncated) and
        self.exe_source == .process_inspection)
    {
        return;
    }
    const stored = try storePath(store, gpa, value);
    self.exe_offset = stored.offset;
    self.exe_len = stored.len;
    self.exe_truncated = stored.truncated;
    self.exe_source = .process_inspection;
    self.revision +%= 1;
}

/// Stores an executable filename captured by the exec tracepoint.
pub fn setExeFromKernel(
    self: *Process,
    store: *MetadataStore,
    gpa: Allocator,
    value: []const u8,
    truncated: bool,
) Allocator.Error!void {
    const will_truncate = truncated or value.len > max_path_len;
    if (pathUnchanged(self.exeSlice(store.items), value, will_truncate) and
        self.exe_source == .kernel)
    {
        return;
    }
    const stored = try storePath(store, gpa, value);
    self.exe_offset = stored.offset;
    self.exe_len = stored.len;
    self.exe_source = .kernel;
    self.exe_truncated = truncated or stored.truncated;
    self.revision +%= 1;
}

/// Stores a bounded working directory in this record.
pub fn setCwd(
    self: *Process,
    store: *MetadataStore,
    gpa: Allocator,
    value: []const u8,
) Allocator.Error!void {
    if (pathUnchanged(self.cwdSlice(store.items), value, self.cwd_truncated)) return;
    const stored = try storePath(store, gpa, value);
    self.cwd_offset = stored.offset;
    self.cwd_len = stored.len;
    self.cwd_truncated = stored.truncated;
    self.cwd_source = .procfs;
    self.revision +%= 1;
}

/// Stores a bounded working directory obtained from a platform process-inspection API.
pub fn setCwdFromProcessInspection(
    self: *Process,
    store: *MetadataStore,
    gpa: Allocator,
    value: []const u8,
) Allocator.Error!void {
    if (pathUnchanged(self.cwdSlice(store.items), value, self.cwd_truncated) and
        self.cwd_source == .process_inspection)
    {
        return;
    }
    const stored = try storePath(store, gpa, value);
    self.cwd_offset = stored.offset;
    self.cwd_len = stored.len;
    self.cwd_truncated = stored.truncated;
    self.cwd_source = .process_inspection;
    self.revision +%= 1;
}

/// Stores a working directory captured with a kernel exec event.
pub fn setCwdFromKernel(
    self: *Process,
    store: *MetadataStore,
    gpa: Allocator,
    value: []const u8,
    truncated: bool,
) Allocator.Error!void {
    const will_truncate = truncated or value.len > max_path_len;
    if (pathUnchanged(self.cwdSlice(store.items), value, will_truncate) and
        self.cwd_source == .kernel)
    {
        return;
    }
    const stored = try storePath(store, gpa, value);
    self.cwd_offset = stored.offset;
    self.cwd_len = stored.len;
    self.cwd_truncated = truncated or stored.truncated;
    self.cwd_source = .kernel;
    self.revision +%= 1;
}

/// Copies the current exec metadata inherited by a newly forked child.
pub fn inheritMetadata(self: *Process, parent: *const Process) void {
    if (parent.args_len > 0) {
        self.args_offset = parent.args_offset;
        self.args_len = parent.args_len;
        self.args_count = parent.args_count;
        self.args_source = .inherited;
    }
    if (parent.exe_len > 0) {
        self.exe_offset = parent.exe_offset;
        self.exe_len = parent.exe_len;
        self.exe_source = .inherited;
        self.exe_truncated = parent.exe_truncated;
    }
    if (parent.cwd_len > 0) {
        self.cwd_offset = parent.cwd_offset;
        self.cwd_len = parent.cwd_len;
        self.cwd_source = .inherited;
        self.cwd_truncated = parent.cwd_truncated;
    }
    self.revision +%= 1;
}

/// Clears fields replaced by exec; the working directory survives exec.
pub fn clearExecMetadata(self: *Process) void {
    self.args_offset = 0;
    self.args_len = 0;
    self.args_count = 0;
    self.args_source = .unavailable;
    self.exe_offset = 0;
    self.exe_len = 0;
    self.exe_source = .unavailable;
    self.exe_truncated = false;
    self.revision +%= 1;
}

/// Closes an open lifetime and returns whether the record changed.
pub fn finish(self: *Process, at_ns: u64, kind: EndKind) bool {
    if (self.end_ns != null) return false;
    self.end_ns = @max(at_ns, self.start_ns);
    self.end_kind = kind;
    self.clipCpuSlices(self.end_ns.?);
    self.revision +%= 1;
    return true;
}

fn copyShort(buffer: []u8, value: []const u8) []const u8 {
    const n = @min(value.len, buffer.len);
    @memcpy(buffer[0..n], value[0..n]);
    return buffer[0..n];
}

fn copyShortJoin(buffer: []u8, a: []const u8, b: []const u8) []const u8 {
    var off: usize = 0;
    const n_a = @min(a.len, buffer.len);
    @memcpy(buffer[0..n_a], a[0..n_a]);
    off = n_a;
    if (off + 1 < buffer.len) {
        buffer[off] = ' ';
        off += 1;
    }
    const n_b = @min(b.len, buffer.len - off);
    @memcpy(buffer[off..][0..n_b], b[0..n_b]);
    return buffer[0 .. off + n_b];
}

fn isRustc(name: []const u8) bool {
    return std.mem.eql(u8, name, "rustc") or
        std.mem.eql(u8, name, "clippy-driver") or
        std.mem.eql(u8, name, "rustdoc");
}

fn isCompiler(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "clang") or
        std.mem.startsWith(u8, name, "gcc") or
        std.mem.startsWith(u8, name, "g++") or
        std.mem.startsWith(u8, name, "cc1"))
        return true;
    return std.mem.eql(u8, name, "cc") or
        std.mem.eql(u8, name, "c++") or
        std.mem.eql(u8, name, "as");
}

fn isLinker(name: []const u8) bool {
    return std.mem.eql(u8, name, "ld") or
        std.mem.eql(u8, name, "lld") or
        std.mem.eql(u8, name, "ld.lld") or
        std.mem.eql(u8, name, "rust-lld") or
        std.mem.eql(u8, name, "wasm-ld") or
        std.mem.eql(u8, name, "collect2") or
        std.mem.eql(u8, name, "mold") or
        std.mem.eql(u8, name, "gold");
}

fn isCargo(name: []const u8) bool {
    return std.mem.eql(u8, name, "cargo");
}

fn isNinja(name: []const u8) bool {
    return std.mem.eql(u8, name, "ninja");
}

fn isSourcePath(arg: []const u8) bool {
    if (arg.len < 3 or arg[0] == '-') return false;
    const ext = pathExt(arg);
    inline for (.{
        ".rs",  ".c", ".cc", ".cpp", ".cxx", ".h",
        ".hpp", ".s", ".S",  ".go",  ".zig",
    }) |want| {
        if (std.ascii.eqlIgnoreCase(ext, want)) return true;
    }
    return false;
}

fn pathExt(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    if (dot == 0 or dot + 1 == base.len) return "";
    return base[dot..];
}

fn takesValue(flag: []const u8) bool {
    if (flag.len < 2 or flag[0] != '-') return false;
    if (std.mem.indexOfScalar(u8, flag, '=') != null) return false;
    inline for (.{
        "-o",
        "-C",
        "-p",
        "-I",
        "-L",
        "-D",
        "-U",
        "-B",
        "-x",
        "--crate-name",
        "--edition",
        "--extern",
        "--package",
        "--output",
        "--target",
        "--manifest-path",
    }) |known| {
        if (std.mem.eql(u8, flag, known)) return true;
    }
    return false;
}

test "process duration stops at its end" {
    var process = Process{ .pid = 7, .parent_pid = null, .depth = 0, .start_ns = 10 };
    process.end_ns = 40;
    try std.testing.expectEqual(@as(u64, 30), process.durationNs(100));
}

test "CPU snapshots coalesce adjacent buckets in the same occupancy band" {
    var process = Process{ .pid = 7, .start_ns = 10 };
    defer process.deinit(std.testing.allocator);

    try process.recordCpuSnapshot(std.testing.allocator, 110, 100);
    try process.recordCpuSnapshot(std.testing.allocator, 210, 200);

    try std.testing.expectEqual(@as(usize, 1), process.cpu_slices.items.len);
    const slice = process.cpu_slices.items[0];
    try std.testing.expectEqual(@as(u64, 10), slice.start_ns);
    try std.testing.expectEqual(@as(u64, 210), slice.end_ns);
    try std.testing.expectEqual(@as(u64, 200), slice.cpu_ns);
    try std.testing.expectApproxEqAbs(@as(f64, 1), slice.averageCores(), 0.0001);
}

test "idle CPU buckets separate busy slices" {
    var process = Process{ .pid = 7 };
    defer process.deinit(std.testing.allocator);

    try process.recordCpuSnapshot(std.testing.allocator, 100, 50);
    try process.recordCpuSnapshot(std.testing.allocator, 200, 50);
    try process.recordCpuSnapshot(std.testing.allocator, 300, 250);

    try std.testing.expectEqual(@as(usize, 2), process.cpu_slices.items.len);
    try std.testing.expectEqual(@as(u64, 100), process.cpu_slices.items[0].end_ns);
    try std.testing.expectEqual(@as(u64, 200), process.cpu_slices.items[1].start_ns);
    try std.testing.expectApproxEqAbs(
        @as(f64, 2),
        process.cpu_slices.items[1].averageCores(),
        0.0001,
    );
}

test "final CPU snapshot reconciles map sampling skew" {
    var process = Process{ .pid = 7 };
    defer process.deinit(std.testing.allocator);

    try process.recordCpuSnapshot(std.testing.allocator, 100, 105);
    try process.recordFinalCpuSnapshot(std.testing.allocator, 100, 100);

    try std.testing.expectEqual(@as(u64, 100), process.cpu_time_ns);
    try std.testing.expectEqual(@as(u64, 100), process.cpu_slices.items[0].cpu_ns);
    try std.testing.expectApproxEqAbs(
        @as(f64, 1),
        process.cpu_slices.items[0].averageCores(),
        0.0001,
    );
}

test "finishing clips delayed CPU samples to the process lifetime" {
    const testing = std.testing;
    var process = Process{ .pid = 7 };
    defer process.deinit(testing.allocator);

    try process.recordCpuSnapshot(testing.allocator, 80, 20);
    try process.recordCpuSnapshot(testing.allocator, 120, 60);
    try testing.expect(process.finish(100, .observed_exit));

    try testing.expectEqual(@as(usize, 2), process.cpu_slices.items.len);
    try testing.expectEqual(@as(u64, 100), process.cpu_slices.items[1].end_ns);
    try testing.expectEqual(@as(u8, 8), process.cpu_slices.items[1].band);
    try testing.expectApproxEqAbs(@as(f64, 2), process.cpu_peak_cores, 0.0001);
}

test "process names are trimmed and bounded" {
    var process = Process{ .pid = 7, .parent_pid = null, .depth = 0, .start_ns = 0 };
    process.setName("  compiler\n", .process);
    try std.testing.expectEqualStrings("compiler", process.nameSlice());
    try std.testing.expectEqual(NameKind.process, process.name_kind);

    process.setName("   \n", .process);
    try std.testing.expectEqualStrings("process", process.nameSlice());
    try std.testing.expectEqual(NameKind.other, process.name_kind);

    process.setName("build.sh", .other);
    try std.testing.expectEqualStrings("build.sh", process.nameSlice());
    try std.testing.expectEqual(NameKind.other, process.name_kind);
}

test "fork inheritance survives exec metadata replacement" {
    var metadata = MetadataStore.empty;
    defer metadata.deinit(std.testing.allocator);
    var parent = Process{ .pid = 1 };
    try parent.setArgsFromArgv(&metadata, std.testing.allocator, &.{
        "sh",
        "-c",
        "true",
    });
    try parent.setExe(&metadata, std.testing.allocator, "/usr/bin/sh");
    try parent.setCwd(&metadata, std.testing.allocator, "/tmp/build");
    const inherited_store_len = metadata.items.len;

    var child = Process{ .pid = 2, .parent_pid = 1 };
    child.inheritMetadata(&parent);
    try std.testing.expectEqual(inherited_store_len, metadata.items.len);
    try std.testing.expectEqual(MetadataSource.inherited, child.args_source);
    try std.testing.expectEqual(MetadataSource.inherited, child.exe_source);
    try std.testing.expectEqual(MetadataSource.inherited, child.cwd_source);

    child.clearExecMetadata();
    try std.testing.expectEqual(@as(usize, 0), child.args_len);
    try std.testing.expectEqual(@as(u16, 0), child.exe_len);
    try std.testing.expectEqualStrings("/tmp/build", child.cwdSlice(metadata.items));

    try child.setArgsFromKernel(
        &metadata,
        std.testing.allocator,
        "clang\x00-c\x00source.c\x00",
    );
    try child.setExeFromKernel(&metadata, std.testing.allocator, "clang", false);
    try std.testing.expectEqual(MetadataSource.kernel, child.args_source);
    try std.testing.expectEqual(MetadataSource.kernel, child.exe_source);
}

test "launch argv storage has no fixed byte limit" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const long_arg = try gpa.alloc(u8, 32 * 1024);
    defer gpa.free(long_arg);
    @memset(long_arg, 'x');

    var metadata = MetadataStore.empty;
    defer metadata.deinit(gpa);
    var process = Process{ .pid = 1 };
    try process.setArgsFromArgv(&metadata, gpa, &.{ "tool", long_arg });

    try testing.expectEqual("tool".len + 1 + long_arg.len + 1, process.args_len);
    try testing.expectEqual(@as(usize, 2), process.args_count);
    var args = process.argsIter(metadata.items);
    try testing.expectEqualStrings("tool", args.next().?);
    try testing.expectEqualStrings(long_arg, args.next().?);
    try testing.expect(args.next() == null);
}

test "argv storage preserves empty arguments" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var metadata = MetadataStore.empty;
    defer metadata.deinit(gpa);
    var process = Process{ .pid = 1 };

    try process.setArgsFromArgv(&metadata, gpa, &.{
        "tool",
        "",
        "value",
        "",
    });

    var args = process.argsIter(metadata.items);
    try testing.expectEqualStrings("tool", args.next().?);
    try testing.expectEqualStrings("", args.next().?);
    try testing.expectEqualStrings("value", args.next().?);
    try testing.expectEqualStrings("", args.next().?);
    try testing.expect(args.next() == null);
    var joined: [32]u8 = undefined;
    try testing.expectEqualStrings(" value ", process.copyArguments(metadata.items, &joined));
}

test "identical CWD and exe paths reuse the stored offset" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var metadata = MetadataStore.empty;
    defer metadata.deinit(gpa);
    var process = Process{ .pid = 1 };

    try process.setCwd(&metadata, gpa, "/tmp/build");
    const cwd_offset = process.cwd_offset;
    const store_len = metadata.items.len;
    try process.setCwd(&metadata, gpa, "/tmp/build");
    try testing.expectEqual(cwd_offset, process.cwd_offset);
    try testing.expectEqual(store_len, metadata.items.len);

    try process.setExe(&metadata, gpa, "/usr/bin/clang");
    const exe_offset = process.exe_offset;
    const exe_store_len = metadata.items.len;
    try process.setExe(&metadata, gpa, "/usr/bin/clang");
    try testing.expectEqual(exe_offset, process.exe_offset);
    try testing.expectEqual(exe_store_len, metadata.items.len);
}

test "paths preserve bytes and report only over-cap truncation" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var metadata = MetadataStore.empty;
    defer metadata.deinit(gpa);
    var process = Process{ .pid = 1 };

    const spaced_path = " /tmp/build\t";
    try process.setCwd(&metadata, gpa, spaced_path);
    try testing.expectEqualStrings(spaced_path, process.cwdSlice(metadata.items));
    try testing.expect(!process.cwd_truncated);

    var exact_path: [max_path_len]u8 = undefined;
    @memset(&exact_path, 'x');
    try process.setExe(&metadata, gpa, &exact_path);
    try testing.expectEqual(@as(usize, max_path_len), process.exeSlice(metadata.items).len);
    try testing.expect(!process.exe_truncated);

    var long_path: [max_path_len + 1]u8 = undefined;
    @memset(&long_path, 'y');
    try process.setCwd(&metadata, gpa, &long_path);
    try testing.expectEqual(@as(usize, max_path_len), process.cwdSlice(metadata.items).len);
    try testing.expect(process.cwd_truncated);
}

test "exec history retains replaced metadata" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var metadata = MetadataStore.empty;
    defer metadata.deinit(gpa);
    var process = Process{ .pid = 7 };
    defer process.deinit(gpa);

    process.setName("sh", .process);
    try process.setArgsFromArgv(&metadata, gpa, &.{ "sh", "build.sh" });
    try process.setExe(&metadata, gpa, "/usr/bin/sh");
    try process.setCwd(&metadata, gpa, "/tmp/project");
    try process.archiveCurrentExec(gpa, 25);

    process.setName("clang", .process);
    process.clearExecMetadata();
    try process.setArgsFromKernel(&metadata, gpa, "clang\x00-c\x00main.c\x00");
    try process.setExeFromKernel(&metadata, gpa, "/usr/bin/clang", false);

    try testing.expectEqual(@as(usize, 2), process.execCount());
    const shell = process.execAt(0);
    try testing.expectEqual(@as(u64, 0), shell.start_ns);
    try testing.expectEqual(@as(u64, 25), shell.end_ns.?);
    try testing.expectEqualStrings("sh", shell.nameSlice());
    var command_buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "sh build.sh",
        shell.copyCmdline(metadata.items, &command_buffer),
    );
    try testing.expectEqualStrings("/usr/bin/sh", shell.exeSlice(metadata.items));
    try testing.expectEqualStrings("/tmp/project", shell.cwdSlice(metadata.items));
    const row_exec = process.rowExec();
    try testing.expectEqualStrings("sh", row_exec.nameSlice());
    try testing.expectEqualStrings(
        "sh build.sh",
        row_exec.copyCmdline(metadata.items, &command_buffer),
    );
    var summary_buffer: [32]u8 = undefined;
    try testing.expectEqualStrings(
        "build.sh",
        process.rowArgSummary(metadata.items, &summary_buffer),
    );

    const compiler = process.currentExec();
    try testing.expectEqual(@as(u64, 25), compiler.start_ns);
    try testing.expect(compiler.end_ns == null);
    try testing.expectEqualStrings("clang", compiler.nameSlice());
    try testing.expectEqualStrings(
        "clang -c main.c",
        compiler.copyCmdline(metadata.items, &command_buffer),
    );
    try testing.expectEqualStrings("/tmp/project", compiler.cwdSlice(metadata.items));
}

test "first visible slice is the lower bound on end time" {
    const slices = [_]CpuSlice{
        .{
            .start_ns = 0,
            .end_ns = 10,
            .cpu_ns = 1,
            .band = 1,
        },
        .{
            .start_ns = 10,
            .end_ns = 20,
            .cpu_ns = 1,
            .band = 1,
        },
        .{
            .start_ns = 20,
            .end_ns = 30,
            .cpu_ns = 1,
            .band = 1,
        },
        .{
            .start_ns = 40,
            .end_ns = 50,
            .cpu_ns = 1,
            .band = 1,
        },
    };
    try std.testing.expectEqual(@as(usize, 1), firstVisibleSlice(&slices, 10, 25));
    try std.testing.expectEqual(@as(usize, 2), firstVisibleSlice(&slices, 20, 45));
    try std.testing.expectEqual(@as(usize, 4), firstVisibleSlice(&slices, 50, 60));
    try std.testing.expectEqual(@as(usize, 0), firstVisibleSlice(&slices, 0, 5));
}

test "rebuild CPU caches derives bands and peak from slices" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var process = Process{ .pid = 1 };
    defer process.deinit(gpa);
    try process.cpu_slices.appendSlice(gpa, &.{
        .{ .start_ns = 0, .end_ns = 100, .cpu_ns = 25, .band = 64 },
        .{ .start_ns = 100, .end_ns = 200, .cpu_ns = 200, .band = 1 },
    });
    process.cpu_peak_cores = 99;

    process.rebuildCpuCaches();

    try testing.expectEqual(@as(u8, 1), process.cpu_slices.items[0].band);
    try testing.expectEqual(@as(u8, 8), process.cpu_slices.items[1].band);
    try testing.expectApproxEqAbs(@as(f64, 2), process.cpu_peak_cores, 0.0001);
}

test "process records keep bulk metadata out of the hot array" {
    try std.testing.expect(@sizeOf(Process) <= 256);
}

test "arg summary extracts rustc crate and compiler sources" {
    var metadata = MetadataStore.empty;
    defer metadata.deinit(std.testing.allocator);
    var rustc = Process{ .pid = 1, .parent_pid = null, .depth = 0, .start_ns = 0 };
    rustc.setName("rustc", .process);
    try rustc.setArgsFromArgv(&metadata, std.testing.allocator, &.{
        "/home/user/.rustup/toolchains/stable/bin/rustc",
        "--crate-name",
        "serde",
        "--edition=2021",
        "/tmp/serde-1.0.210/src/lib.rs",
    });
    var buf: [64]u8 = undefined;
    var cmd_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("serde", rustc.argSummary(metadata.items, &buf));
    try std.testing.expectEqualStrings(
        "/home/user/.rustup/toolchains/stable/bin/rustc" ++
            " --crate-name serde --edition=2021 /tmp/serde-1.0.210/src/lib.rs",
        rustc.copyCmdline(metadata.items, &cmd_buf),
    );
    try std.testing.expectEqualStrings(
        "--crate-name serde --edition=2021 /tmp/serde-1.0.210/src/lib.rs",
        rustc.copyArguments(metadata.items, &cmd_buf),
    );

    try rustc.setArgsFromArgv(
        &metadata,
        std.testing.allocator,
        &.{
            "rustc",
            "--crate-name=anyhow",
            "src/lib.rs",
        },
    );
    try std.testing.expectEqualStrings("anyhow", rustc.argSummary(metadata.items, &buf));

    var clang = Process{ .pid = 2, .parent_pid = null, .depth = 0, .start_ns = 0 };
    clang.setName("cc1plus", .process);
    try clang.setArgsFromArgv(
        &metadata,
        std.testing.allocator,
        &.{
            "cc1plus",
            "-quiet",
            "-o",
            "/tmp/foo.s",
            "/src/engine.cpp",
        },
    );
    try std.testing.expectEqualStrings("engine.cpp", clang.argSummary(metadata.items, &buf));

    var cargo = Process{ .pid = 3, .parent_pid = null, .depth = 0, .start_ns = 0 };
    cargo.setName("cargo", .process);
    try cargo.setArgsFromArgv(
        &metadata,
        std.testing.allocator,
        &.{
            "cargo",
            "build",
            "--release",
            "-p",
            "serde",
        },
    );
    try std.testing.expectEqualStrings("build serde", cargo.argSummary(metadata.items, &buf));

    var ld = Process{ .pid = 4, .parent_pid = null, .depth = 0, .start_ns = 0 };
    ld.setName("collect2", .process);
    try ld.setArgsFromArgv(
        &metadata,
        std.testing.allocator,
        &.{
            "collect2",
            "-o",
            "/build/bin/llama",
            "a.o",
            "b.o",
        },
    );
    try std.testing.expectEqualStrings("llama", ld.argSummary(metadata.items, &buf));
}
