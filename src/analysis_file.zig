//! Versioned, human-readable JSON for automated performance analysis.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Process = @import("tracer/Process.zig");
const Session = @import("tracer/Session.zig");

const log = std.log.scoped(.analysis_file);

const max_preview_head_args: usize = 4;
const max_preview_tail_args: usize = 4;
const max_preview_arg_bytes: usize = 160;
const max_ranked_processes: usize = 10;
const label_bytes = Process.max_name_len + 2 + 64;

pub const WriteError = Allocator.Error || std.Io.Writer.Error || error{InvalidSession};

pub const WriteFileError =
    WriteError ||
    std.Io.Dir.CreateFileAtomicError ||
    std.Io.File.Writer.Error ||
    std.Io.File.Atomic.ReplaceError;

pub const WriteOptions = struct {
    formatting: Formatting = .pretty,
    privacy: Privacy = .full,

    pub const Formatting = enum {
        pretty,
        minified,
    };

    pub const Privacy = enum {
        full,
        redacted,
    };
};

const DerivedProcess = struct {
    id: usize,
    self_cpu_time_ns: u64,
    wall_time_ns: u64,
    inclusive_cpu_time_ns: u128,
    inclusive_process_count: usize = 1,
    peak_cpu_millicores: u128,
    cpu_activity_span_ns: u64 = 0,
    child_lifetime_span_ns: u64 = 0,
    explained_wall_time_ns: u64 = 0,
    unexplained_wall_time_ns: u64 = 0,
    dominant_child_id: ?usize = null,
};

const Totals = struct {
    self_cpu_time_ns: u128 = 0,
    unexplained_wall_time_ns: u128 = 0,
    command_interval_count: usize = 0,
    exec_transition_count: usize = 0,
    exec_transition_count_complete: bool = true,
    recovered_process_count: usize = 0,
    capture_clipped_process_count: usize = 0,
    partial_cpu_process_count: usize = 0,
};

const Analysis = struct {
    processes: []DerivedProcess,
    longest_process_chain: []usize,
    commands: []CommandRef,
    command_ids: []usize,
    command_offsets: []usize,
    peak_leaf_processes: usize,
    peak_leaf_processes_at_ns: u64,
    totals: Totals,

    fn deinit(self: *Analysis, gpa: Allocator) void {
        gpa.free(self.command_offsets);
        gpa.free(self.command_ids);
        gpa.free(self.commands);
        gpa.free(self.longest_process_chain);
        gpa.free(self.processes);
        self.* = undefined;
    }

    fn commandId(self: *const Analysis, process_id: usize, exec_index: usize) usize {
        return self.command_ids[self.command_offsets[process_id] + exec_index];
    }
};

const CommandRef = struct {
    process_id: usize,
    exec_index: usize,
};

const CommandIndex = struct {
    items: []CommandRef,
    ids: []usize,
    offsets: []usize,

    fn deinit(self: *CommandIndex, gpa: Allocator) void {
        gpa.free(self.offsets);
        gpa.free(self.ids);
        gpa.free(self.items);
        self.* = undefined;
    }
};

const Classification = struct {
    tool: []const u8,
    action: []const u8,
    component: ?[]const u8 = null,
    primary_input: ?[]const u8 = null,
    language: ?[]const u8 = null,
    output_kind: ?[]const u8 = null,
    method: []const u8,
    confidence_permyriad: ?u16 = null,
};

const LeafEvent = struct {
    at_ns: u64,
    delta: i8,
};

const Component = enum {
    flamez,
    raylib,
    clay,
    system,
};

const ComponentSummary = struct {
    process_count: usize = 0,
    start_ns: u64 = std.math.maxInt(u64),
    end_ns: u64 = 0,
    self_cpu_sum_ns: u128 = 0,
    critical_path_candidate: bool = false,
};

const component_order = [_]Component{
    .flamez,
    .raylib,
    .clay,
    .system,
};

const ChildIndex = struct {
    offsets: []usize,
    ids: []usize,

    fn deinit(self: *ChildIndex, gpa: Allocator) void {
        gpa.free(self.ids);
        gpa.free(self.offsets);
        self.* = undefined;
    }

    fn childrenOf(self: *const ChildIndex, process_id: usize) []const usize {
        return self.ids[self.offsets[process_id]..self.offsets[process_id + 1]];
    }
};

const Interval = struct {
    start_ns: u64,
    end_ns: u64,
};

const Ranking = enum {
    self_cpu_time,
    wall_time,
    unexplained_wall_time,
};

/// Writes an analysis view of a validated, finished session.
pub fn write(
    gpa: Allocator,
    session: *const Session,
    writer: *std.Io.Writer,
) WriteError!void {
    return writeWithOptions(gpa, session, writer, .{});
}

/// Writes an analysis view using the selected transport formatting.
pub fn writeWithOptions(
    gpa: Allocator,
    session: *const Session,
    writer: *std.Io.Writer,
    options: WriteOptions,
) WriteError!void {
    if (!session.finished or session.processes.items.len == 0) return error.InvalidSession;

    var analysis = try prepare(gpa, session);
    defer analysis.deinit(gpa);
    const redact = options.privacy == .redacted;

    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .whitespace = switch (options.formatting) {
            .pretty => .indent_2,
            .minified => .minified,
        } },
    };
    try json.beginObject();
    try field(
        &json,
        "$schema",
        "https://raw.githubusercontent.com/hspak/flamez/main/schema/" ++
            "flamez-analysis-v1.schema.json",
    );
    try json.objectField("schema");
    try json.beginObject();
    try field(&json, "name", "flamez-analysis");
    try field(&json, "version", @as(u8, 1));
    try field(&json, "source_name", "flamez-capture");
    try field(&json, "source_version", @as(u8, 1));
    try json.endObject();
    try json.objectField("capture");
    try writeCapture(&json, session, analysis.totals);
    try json.objectField("environment");
    try writeEnvironment(&json, session, redact);
    try json.objectField("target");
    try writeTarget(&json, session, &analysis, redact);
    try json.objectField("cache");
    try writeCache(&json, session, redact);
    try json.objectField("units");
    try json.beginObject();
    try field(&json, "time", "nanoseconds");
    try field(&json, "cpu_rate", "millicores");
    try field(&json, "ratio", "permyriad");
    try json.endObject();
    try json.objectField("totals");
    try writeTotals(&json, session, analysis.totals);
    try json.objectField("commands");
    try writeCommands(&json, session, &analysis, redact);
    try json.objectField("processes");
    try json.beginArray();
    for (analysis.processes) |item| try writeProcess(&json, session, &analysis, item);
    try json.endArray();
    try json.objectField("analysis");
    try json.beginObject();
    try json.objectField("bottlenecks");
    try writeBottlenecks(&json, session, &analysis, redact);
    try json.objectField("component_aggregates");
    try writeComponentAggregates(&json, session, &analysis);
    try json.objectField("phases");
    try writePhases(&json, session);
    try json.objectField("parallelism");
    try writeParallelism(&json, session, &analysis);
    try json.objectField("hotspots");
    try writeRanking(
        &json,
        session,
        analysis.processes,
        analysis.totals,
        .self_cpu_time,
        redact,
    );
    try json.objectField("stall_candidates");
    try writeRanking(
        &json,
        session,
        analysis.processes,
        analysis.totals,
        .unexplained_wall_time,
        redact,
    );
    try json.endObject();
    try json.objectField("diagnostics");
    try writeDiagnostics(&json, session, analysis.totals);
    try json.endObject();
    try writer.writeByte('\n');
}

/// Atomically replaces `path` with an analysis file after a successful write.
pub fn writeFile(
    gpa: Allocator,
    io: std.Io,
    session: *const Session,
    path: []const u8,
) WriteFileError!void {
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic_file.deinit(io);

    var buffer: [16 * 1024]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &buffer);
    try write(gpa, session, &file_writer.interface);
    try file_writer.flush();
    try atomic_file.replace(io);
}

fn prepare(gpa: Allocator, session: *const Session) WriteError!Analysis {
    const derived = try gpa.alloc(DerivedProcess, session.processes.items.len);
    errdefer gpa.free(derived);
    var totals: Totals = .{
        .exec_transition_count_complete = !session.isIncomplete(),
    };

    for (session.processes.items, 0..) |process, id| {
        if (process.end_ns == null or process.end_kind == .open) return error.InvalidSession;
        try validateProcessIntervals(&process, !session.isIncomplete());
        derived[id] = .{
            .id = id,
            .self_cpu_time_ns = process.cpu_time_ns,
            .wall_time_ns = process.end_ns.? - process.start_ns,
            .inclusive_cpu_time_ns = process.cpu_time_ns,
            .peak_cpu_millicores = peakCpuMillicores(&process),
        };
        totals.self_cpu_time_ns = std.math.add(
            u128,
            totals.self_cpu_time_ns,
            process.cpu_time_ns,
        ) catch
            return error.InvalidSession;
        totals.command_interval_count = std.math.add(
            usize,
            totals.command_interval_count,
            process.execCount(),
        ) catch
            return error.InvalidSession;
        if (process.origin == .observed) {
            totals.exec_transition_count = std.math.add(
                usize,
                totals.exec_transition_count,
                process.execCount() - 1,
            ) catch return error.InvalidSession;
        } else {
            totals.exec_transition_count_complete = false;
        }
        if (process.origin != .observed) totals.recovered_process_count += 1;
        if (process.end_kind == .capture_clipped) totals.capture_clipped_process_count += 1;
        if (!process.cpu_final) totals.partial_cpu_process_count += 1;
    }

    var children = try buildChildIndex(gpa, session);
    defer children.deinit(gpa);
    for (derived, 0..) |*item, process_id| {
        const process = &session.processes.items[process_id];
        const child_ids = children.childrenOf(process_id);
        item.cpu_activity_span_ns = cpuActivitySpan(process);
        item.child_lifetime_span_ns = childLifetimeSpan(
            process,
            child_ids,
            session.processes.items,
        );
        item.explained_wall_time_ns = explainedWallTime(
            process,
            child_ids,
            session.processes.items,
        );
        item.unexplained_wall_time_ns = item.wall_time_ns -| item.explained_wall_time_ns;
        totals.unexplained_wall_time_ns = std.math.add(
            u128,
            totals.unexplained_wall_time_ns,
            item.unexplained_wall_time_ns,
        ) catch return error.InvalidSession;
        for (child_ids) |child_id| {
            const dominant_id = item.dominant_child_id orelse {
                item.dominant_child_id = child_id;
                continue;
            };
            if (derived[child_id].wall_time_ns > derived[dominant_id].wall_time_ns or
                (derived[child_id].wall_time_ns == derived[dominant_id].wall_time_ns and
                    child_id < dominant_id))
            {
                item.dominant_child_id = child_id;
            }
        }
    }

    var index = derived.len;
    while (index > 0) {
        index -= 1;
        const parent_id = session.processes.items[index].parent_index orelse continue;
        if (parent_id >= index) return error.InvalidSession;
        derived[parent_id].inclusive_cpu_time_ns = std.math.add(
            u128,
            derived[parent_id].inclusive_cpu_time_ns,
            derived[index].inclusive_cpu_time_ns,
        ) catch return error.InvalidSession;
        derived[parent_id].inclusive_process_count = std.math.add(
            usize,
            derived[parent_id].inclusive_process_count,
            derived[index].inclusive_process_count,
        ) catch return error.InvalidSession;
    }

    const leaf_peak = try peakLeafProcesses(gpa, session, &children);

    var chain: std.ArrayList(usize) = .empty;
    defer chain.deinit(gpa);
    var process_id: ?usize = 0;
    while (process_id) |id| {
        try chain.append(gpa, id);
        process_id = derived[id].dominant_child_id;
    }

    var commands = try buildCommandIndex(gpa, session, totals.command_interval_count);
    errdefer commands.deinit(gpa);

    return .{
        .processes = derived,
        .longest_process_chain = try chain.toOwnedSlice(gpa),
        .commands = commands.items,
        .command_ids = commands.ids,
        .command_offsets = commands.offsets,
        .peak_leaf_processes = leaf_peak.count,
        .peak_leaf_processes_at_ns = leaf_peak.at_ns,
        .totals = totals,
    };
}

fn validateProcessIntervals(
    process: *const Process,
    require_complete_coverage: bool,
) error{InvalidSession}!void {
    const process_end_ns = process.end_ns orelse return error.InvalidSession;
    var previous_end_ns: ?u64 = null;
    for (0..process.execCount()) |exec_index| {
        const exec = process.execAt(exec_index);
        const end_ns = exec.end_ns orelse return error.InvalidSession;
        if (exec.start_ns < process.start_ns or end_ns < exec.start_ns or end_ns > process_end_ns) {
            return error.InvalidSession;
        }
        if (previous_end_ns) |previous| {
            if (previous > exec.start_ns) return error.InvalidSession;
            if (require_complete_coverage and
                process.origin == .observed and
                process.end_kind == .observed_exit and
                previous != exec.start_ns)
            {
                return error.InvalidSession;
            }
        } else if (require_complete_coverage and
            process.origin == .observed and
            process.end_kind == .observed_exit and
            exec.start_ns != process.start_ns)
        {
            return error.InvalidSession;
        }
        previous_end_ns = end_ns;
    }
    if (require_complete_coverage and
        process.origin == .observed and
        process.end_kind == .observed_exit and
        previous_end_ns != process_end_ns)
    {
        return error.InvalidSession;
    }
}

fn peakLeafProcesses(
    gpa: Allocator,
    session: *const Session,
    children: *const ChildIndex,
) Allocator.Error!struct { count: usize, at_ns: u64 } {
    var leaf_count: usize = 0;
    for (session.processes.items, 0..) |_, process_id| {
        if (children.childrenOf(process_id).len == 0) leaf_count += 1;
    }
    const events = try gpa.alloc(LeafEvent, leaf_count * 2);
    defer gpa.free(events);
    var event_count: usize = 0;
    for (session.processes.items, 0..) |process, process_id| {
        if (children.childrenOf(process_id).len != 0 or process.end_ns.? <= process.start_ns) {
            continue;
        }
        events[event_count] = .{ .at_ns = process.start_ns, .delta = 1 };
        events[event_count + 1] = .{ .at_ns = process.end_ns.?, .delta = -1 };
        event_count += 2;
    }
    std.mem.sort(LeafEvent, events[0..event_count], {}, leafEventEarlierThan);

    var current: usize = 0;
    var peak: usize = 0;
    var peak_at_ns: u64 = 0;
    for (events[0..event_count]) |event| {
        if (event.delta < 0) {
            current -= 1;
        } else {
            current += 1;
            if (current > peak) {
                peak = current;
                peak_at_ns = event.at_ns;
            }
        }
    }
    return .{ .count = peak, .at_ns = peak_at_ns };
}

fn leafEventEarlierThan(_: void, lhs: LeafEvent, rhs: LeafEvent) bool {
    if (lhs.at_ns != rhs.at_ns) return lhs.at_ns < rhs.at_ns;
    return lhs.delta < rhs.delta;
}

fn buildCommandIndex(
    gpa: Allocator,
    session: *const Session,
    interval_count: usize,
) Allocator.Error!CommandIndex {
    const offsets = try gpa.alloc(usize, session.processes.items.len + 1);
    errdefer gpa.free(offsets);
    offsets[0] = 0;
    for (session.processes.items, 0..) |process, process_id| {
        offsets[process_id + 1] = offsets[process_id] + process.execCount();
    }
    std.debug.assert(offsets[offsets.len - 1] == interval_count);

    const ids = try gpa.alloc(usize, interval_count);
    errdefer gpa.free(ids);
    var items: std.ArrayList(CommandRef) = .empty;
    errdefer items.deinit(gpa);
    var by_digest: std.AutoHashMapUnmanaged([32]u8, usize) = .empty;
    defer by_digest.deinit(gpa);

    for (session.processes.items, 0..) |process, process_id| {
        for (0..process.execCount()) |exec_index| {
            const digest = commandDigest(process.execAt(exec_index), session.metadata.items);
            const entry = try by_digest.getOrPut(gpa, digest);
            if (!entry.found_existing) {
                errdefer std.debug.assert(by_digest.remove(digest));
                entry.value_ptr.* = items.items.len;
                try items.append(gpa, .{
                    .process_id = process_id,
                    .exec_index = exec_index,
                });
            }
            ids[offsets[process_id] + exec_index] = entry.value_ptr.*;
        }
    }
    return .{
        .items = try items.toOwnedSlice(gpa),
        .ids = ids,
        .offsets = offsets,
    };
}

fn commandDigest(exec: Process.Exec, metadata: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(exec.nameSlice());
    hasher.update("\x00");
    var args = exec.argsIter(metadata);
    while (args.next()) |arg| {
        hasher.update(arg);
        hasher.update("\x00");
    }
    hasher.update("\xff");
    hasher.update(exec.exeSlice(metadata));
    hasher.update("\x00");
    hasher.update(exec.cwdSlice(metadata));
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn buildChildIndex(gpa: Allocator, session: *const Session) WriteError!ChildIndex {
    const process_count = session.processes.items.len;
    const offsets = try gpa.alloc(usize, process_count + 1);
    errdefer gpa.free(offsets);
    @memset(offsets, 0);

    for (session.processes.items, 0..) |process, child_id| {
        if (child_id == 0) {
            if (process.parent_index != null) return error.InvalidSession;
            continue;
        }
        const parent_id = process.parent_index orelse return error.InvalidSession;
        if (parent_id >= child_id) return error.InvalidSession;
        const parent = session.processes.items[parent_id];
        if (!session.isIncomplete() and
            process.origin == .observed and
            process.end_kind == .observed_exit and
            parent.origin == .observed and
            parent.end_kind == .observed_exit and
            (process.start_ns < parent.start_ns or process.start_ns > parent.end_ns.?))
        {
            return error.InvalidSession;
        }
        offsets[parent_id + 1] = std.math.add(usize, offsets[parent_id + 1], 1) catch
            return error.InvalidSession;
    }
    for (1..offsets.len) |index| {
        offsets[index] = std.math.add(usize, offsets[index], offsets[index - 1]) catch
            return error.InvalidSession;
    }

    const ids = try gpa.alloc(usize, process_count - 1);
    errdefer gpa.free(ids);
    const cursors = try gpa.dupe(usize, offsets[0..process_count]);
    defer gpa.free(cursors);
    for (session.processes.items[1..], 1..) |process, child_id| {
        const parent_id = process.parent_index.?;
        ids[cursors[parent_id]] = child_id;
        cursors[parent_id] += 1;
    }
    for (0..process_count) |parent_id| {
        std.mem.sort(
            usize,
            ids[offsets[parent_id]..offsets[parent_id + 1]],
            session.processes.items,
            childEarlierThan,
        );
    }
    return .{ .offsets = offsets, .ids = ids };
}

fn childEarlierThan(processes: []Process, lhs: usize, rhs: usize) bool {
    if (processes[lhs].start_ns != processes[rhs].start_ns) {
        return processes[lhs].start_ns < processes[rhs].start_ns;
    }
    const lhs_end = processes[lhs].end_ns.?;
    const rhs_end = processes[rhs].end_ns.?;
    if (lhs_end != rhs_end) return lhs_end < rhs_end;
    return lhs < rhs;
}

fn cpuActivitySpan(process: *const Process) u64 {
    var total: u64 = 0;
    for (process.cpu_slices.items) |slice| total += slice.durationNs();
    return total;
}

fn childLifetimeSpan(
    process: *const Process,
    child_ids: []const usize,
    processes: []const Process,
) u64 {
    var total: u64 = 0;
    var covered_until: ?u64 = null;
    for (child_ids) |child_id| {
        const interval = clippedChildInterval(process, &processes[child_id]) orelse continue;
        addToUnion(&total, &covered_until, interval);
    }
    return total;
}

fn explainedWallTime(
    process: *const Process,
    child_ids: []const usize,
    processes: []const Process,
) u64 {
    var total: u64 = 0;
    var covered_until: ?u64 = null;
    var cpu_index: usize = 0;
    var child_index: usize = 0;
    var cpu_interval = nextCpuInterval(process, &cpu_index);
    var child_interval = nextChildInterval(process, child_ids, processes, &child_index);
    while (cpu_interval != null or child_interval != null) {
        const take_cpu = child_interval == null or
            (cpu_interval != null and cpu_interval.?.start_ns <= child_interval.?.start_ns);
        const interval = if (take_cpu) cpu_interval.? else child_interval.?;
        addToUnion(&total, &covered_until, interval);
        if (take_cpu) {
            cpu_interval = nextCpuInterval(process, &cpu_index);
        } else {
            child_interval = nextChildInterval(process, child_ids, processes, &child_index);
        }
    }
    return total;
}

fn nextCpuInterval(process: *const Process, index: *usize) ?Interval {
    if (index.* >= process.cpu_slices.items.len) return null;
    const slice = process.cpu_slices.items[index.*];
    index.* += 1;
    return .{ .start_ns = slice.start_ns, .end_ns = slice.end_ns };
}

fn nextChildInterval(
    process: *const Process,
    child_ids: []const usize,
    processes: []const Process,
    index: *usize,
) ?Interval {
    while (index.* < child_ids.len) {
        const child_id = child_ids[index.*];
        index.* += 1;
        if (clippedChildInterval(process, &processes[child_id])) |interval| return interval;
    }
    return null;
}

fn clippedChildInterval(process: *const Process, child: *const Process) ?Interval {
    const start_ns = @max(process.start_ns, child.start_ns);
    const end_ns = @min(process.end_ns.?, child.end_ns.?);
    if (end_ns <= start_ns) return null;
    return .{ .start_ns = start_ns, .end_ns = end_ns };
}

fn addToUnion(total: *u64, covered_until: *?u64, interval: Interval) void {
    const previous_end = covered_until.* orelse {
        total.* += interval.end_ns - interval.start_ns;
        covered_until.* = interval.end_ns;
        return;
    };
    if (interval.end_ns <= previous_end) return;
    total.* += interval.end_ns - @max(interval.start_ns, previous_end);
    covered_until.* = interval.end_ns;
}

fn writeCapture(json: *std.json.Stringify, session: *const Session, totals: Totals) !void {
    try json.beginObject();
    try field(json, "fidelity", @tagName(session.capture_fidelity));
    try field(json, "incomplete", session.isIncomplete());
    try field(json, "loss_count", session.loss_count);
    try field(json, "recovered_process_count", totals.recovered_process_count);
    try field(
        json,
        "capture_clipped_process_count",
        totals.capture_clipped_process_count,
    );
    try field(json, "partial_cpu_process_count", totals.partial_cpu_process_count);
    try field(json, "elapsed_ns", session.elapsed_ns);
    try field(json, "cpu_sample_period_ns", session.sample_period_ns);
    try field(json, "interval_semantics", "half_open");
    try json.objectField("root_exit");
    try writeRootExit(json, session.root_exit);
    try json.objectField("invariants");
    try writeInvariantStatus(json, session, totals);
    try json.endObject();
}

fn writeInvariantStatus(
    json: *std.json.Stringify,
    session: *const Session,
    totals: Totals,
) !void {
    const complete_lifecycle = !session.isIncomplete() and
        totals.capture_clipped_process_count == 0;
    const complete_cpu = !session.isIncomplete() and totals.partial_cpu_process_count == 0;
    try json.beginObject();
    try json.objectField("checked");
    try json.beginArray();
    try json.write("process_and_command_interval_durations");
    try json.write("command_interval_order_and_count");
    try json.write("parent_resolution");
    try json.write("unexplained_wall_aggregation");
    try json.write("inclusive_descendant_aggregation");
    try json.write("ratio_floor_rounding");
    try json.write("component_process_uniqueness");
    try json.write("inference_separation");
    if (complete_lifecycle) {
        try json.write("command_lifetime_coverage");
        try json.write("child_birth_within_parent_lifetime");
    }
    if (complete_cpu) try json.write("total_self_cpu");
    try json.endArray();
    try json.objectField("not_checked");
    try json.beginArray();
    if (!complete_lifecycle) {
        try json.write("command_lifetime_coverage");
        try json.write("child_birth_within_parent_lifetime");
    }
    if (!complete_cpu) try json.write("total_self_cpu");
    try json.endArray();
    try json.endObject();
}

fn writeTotals(json: *std.json.Stringify, session: *const Session, totals: Totals) !void {
    try json.beginObject();
    try field(json, "process_count", session.processes.items.len);
    try field(json, "command_interval_count", totals.command_interval_count);
    try json.objectField("exec_transition_count");
    if (totals.exec_transition_count_complete) {
        try json.write(totals.exec_transition_count);
    } else {
        try json.write(@as(?usize, null));
    }
    try field(json, "observed_exec_transition_count", totals.exec_transition_count);
    try field(
        json,
        "exec_transition_count_complete",
        totals.exec_transition_count_complete,
    );
    try field(json, "self_cpu_time_ns", totals.self_cpu_time_ns);
    try field(
        json,
        "average_cpu_millicores",
        try cpuMillicores(totals.self_cpu_time_ns, session.elapsed_ns),
    );
    try field(json, "unexplained_wall_time_ns", totals.unexplained_wall_time_ns);
    try json.endObject();
}

fn writeEnvironment(
    json: *std.json.Stringify,
    session: *const Session,
    redact: bool,
) !void {
    const environment = session.environment;
    try json.beginObject();
    try json.objectField("generated_at");
    try writeGeneratedAt(json, if (redact) null else environment.started_at_unix_seconds);
    try json.objectField("flamez_version");
    try writeOptionalString(json, environment.flamezVersion());
    try json.objectField("flamez_build_zig_version");
    try writeOptionalString(json, environment.flamezBuildZigVersion());
    try json.objectField("zig_version");
    try json.write(@as(?[]const u8, null));
    try json.objectField("os");
    try writeOptionalTag(json, environment.host_os);
    try json.objectField("architecture");
    try writeOptionalTag(json, environment.architecture);
    try json.objectField("kernel_version");
    try writeOptionalString(json, if (redact) "" else environment.kernelVersion());
    try json.objectField("optimize_mode");
    if (findOptimizeMode(session)) |mode| {
        _ = try writeDisplay(json, mode, 32);
    } else {
        try json.write(@as(?[]const u8, null));
    }
    try field(json, "host_cpu_count", session.host_cpu_count);
    try json.endObject();
}

fn writeGeneratedAt(json: *std.json.Stringify, unix_seconds: ?i64) !void {
    const seconds = unix_seconds orelse {
        try json.write(@as(?[]const u8, null));
        return;
    };
    if (seconds < 0) {
        try json.write(@as(?[]const u8, null));
        return;
    }
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    var buffer: [32]u8 = undefined;
    const timestamp = std.fmt.bufPrint(
        &buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    ) catch unreachable;
    try json.write(timestamp);
}

fn writeOptionalString(json: *std.json.Stringify, value: []const u8) !void {
    if (value.len == 0) {
        try json.write(@as(?[]const u8, null));
    } else {
        try json.write(value);
    }
}

fn writeOptionalTag(json: *std.json.Stringify, value: anytype) !void {
    if (value == .unknown) {
        try json.write(@as(?[]const u8, null));
    } else {
        try json.write(@tagName(value));
    }
}

fn writeTarget(
    json: *std.json.Stringify,
    session: *const Session,
    analysis: *const Analysis,
    redact: bool,
) !void {
    const root = &session.processes.items[0];
    const requested = root.rowExec();
    const observed = analysisExec(root);
    try json.beginObject();
    try json.objectField("requested");
    try json.beginObject();
    try json.objectField("argv");
    try writeArgv(json, requested, session.metadata.items, redact);
    try json.objectField("cwd");
    if (redact) {
        try json.write(@as(?[]const u8, null));
    } else {
        try writeOptionalPath(
            json,
            requested.cwd_source,
            requested.cwdSlice(session.metadata.items),
        );
    }
    try json.endObject();
    try json.objectField("observed");
    try json.beginObject();
    try field(json, "process_id", @as(usize, 0));
    try field(
        json,
        "final_command_id",
        analysis.commandId(0, root.execCount() - 1),
    );
    try json.objectField("command");
    try writeCommand(json, observed, session.metadata.items, redact);
    try json.endObject();
    try json.endObject();
}

fn writeCommands(
    json: *std.json.Stringify,
    session: *const Session,
    analysis: *const Analysis,
    redact: bool,
) !void {
    try json.beginObject();
    for (analysis.commands, 0..) |command_ref, command_id| {
        var id_buffer: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buffer, "{d}", .{command_id}) catch unreachable;
        try json.objectField(id);
        const exec = session.processes.items[command_ref.process_id].execAt(
            command_ref.exec_index,
        );
        try writeCommand(json, exec, session.metadata.items, redact);
    }
    try json.endObject();
}

fn writeCache(json: *std.json.Stringify, session: *const Session, redact: bool) !void {
    const local_directory = if (redact) null else findCacheDirectory(session, false);
    const global_directory = if (redact) null else findCacheDirectory(session, true);
    try json.beginObject();
    try field(json, "state", "unknown");
    try json.objectField("local_directory");
    if (local_directory) |directory| {
        _ = try writeDisplay(json, directory, Process.max_path_len);
    } else {
        try json.write(@as(?[]const u8, null));
    }
    try json.objectField("global_directory");
    if (global_directory) |directory| {
        _ = try writeDisplay(json, directory, Process.max_path_len);
    } else {
        try json.write(@as(?[]const u8, null));
    }
    try json.objectField("steps");
    try json.beginArray();
    try json.endArray();
    try json.endObject();
}

fn findOptimizeMode(session: *const Session) ?[]const u8 {
    const root = session.processes.items[0].rowExec();
    if (argumentValue(root, session.metadata.items, "-Doptimize")) |mode| return mode;
    if (argumentValue(root, session.metadata.items, "--release")) |mode| return mode;

    var result: ?[]const u8 = null;
    for (session.processes.items) |process| {
        const exec = analysisExec(&process);
        var args = exec.argsIter(session.metadata.items);
        while (args.next()) |arg| {
            const mode = normalizeOptimizeArgument(arg) orelse continue;
            if (result) |previous| {
                if (!std.mem.eql(u8, previous, mode)) return "mixed";
            } else {
                result = mode;
            }
        }
    }
    return result;
}

fn normalizeOptimizeArgument(argument: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, argument, "-ODebug")) return "Debug";
    if (std.mem.eql(u8, argument, "-OReleaseSafe")) return "ReleaseSafe";
    if (std.mem.eql(u8, argument, "-OReleaseFast")) return "ReleaseFast";
    if (std.mem.eql(u8, argument, "-OReleaseSmall")) return "ReleaseSmall";
    return null;
}

fn findCacheDirectory(session: *const Session, global: bool) ?[]const u8 {
    const metadata = session.metadata.items;
    const root = session.processes.items[0].rowExec();
    const flag = if (global) "--global-cache-dir" else "--cache-dir";
    if (argumentValue(root, metadata, flag)) |directory| return directory;

    for (session.processes.items) |process| {
        const exec = analysisExec(&process);
        if (!std.mem.eql(u8, normalizedTool(exec, metadata), "zig-build-runner")) continue;
        var args = exec.argsIter(metadata);
        _ = args.next();
        _ = args.next();
        _ = args.next();
        _ = args.next();
        const local_directory = args.next() orelse continue;
        const global_directory = args.next() orelse continue;
        return if (global) global_directory else local_directory;
    }
    return null;
}

fn writeParallelism(
    json: *std.json.Stringify,
    session: *const Session,
    analysis: *const Analysis,
) !void {
    const capacity_ns = std.math.mul(
        u128,
        session.elapsed_ns,
        session.host_cpu_count,
    ) catch return error.InvalidSession;
    try json.beginObject();
    try field(json, "host_cpu_count", session.host_cpu_count);
    try field(json, "total_cpu_capacity_ns", capacity_ns);
    try field(
        json,
        "average_cpu_millicores",
        try cpuMillicores(analysis.totals.self_cpu_time_ns, session.elapsed_ns),
    );
    try field(
        json,
        "host_capacity_utilization_permyriad",
        ratioPermyriadWide(analysis.totals.self_cpu_time_ns, capacity_ns),
    );
    try field(json, "peak_leaf_processes", analysis.peak_leaf_processes);
    try field(json, "peak_leaf_processes_at_ns", analysis.peak_leaf_processes_at_ns);
    try field(json, "leaf_definition", "process_record_without_children");
    try field(json, "includes_recovered_and_clipped", true);
    try json.endObject();
}

fn writeComponentAggregates(
    json: *std.json.Stringify,
    session: *const Session,
    analysis: *const Analysis,
) !void {
    try json.beginObject();
    try field(json, "method", "final_command_classification");
    try json.objectField("items");
    try json.beginArray();
    for (component_order) |component| {
        const summary = try summarizeComponent(session, analysis, component);
        if (summary.process_count == 0) continue;
        try json.beginObject();
        try field(json, "component", componentName(component));
        try json.objectField("process_ids");
        try json.beginArray();
        for (session.processes.items, 0..) |_, process_id| {
            if (processComponent(session, process_id) == component) try json.write(process_id);
        }
        try json.endArray();
        try field(json, "start_ns", summary.start_ns);
        try field(json, "end_ns", summary.end_ns);
        try field(json, "wall_envelope_ns", summary.end_ns - summary.start_ns);
        try field(json, "self_cpu_sum_ns", summary.self_cpu_sum_ns);
        try field(
            json,
            "cpu_share_permyriad",
            ratioPermyriadWide(summary.self_cpu_sum_ns, analysis.totals.self_cpu_time_ns),
        );
        try field(
            json,
            "root_elapsed_share_permyriad",
            ratioPermyriad(summary.end_ns - summary.start_ns, session.elapsed_ns),
        );
        try field(json, "critical_path_candidate", summary.critical_path_candidate);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

fn summarizeComponent(
    session: *const Session,
    analysis: *const Analysis,
    component: Component,
) error{InvalidSession}!ComponentSummary {
    var summary: ComponentSummary = .{};
    for (session.processes.items, 0..) |process, process_id| {
        if (processComponent(session, process_id) != component) continue;
        summary.process_count += 1;
        summary.start_ns = @min(summary.start_ns, process.start_ns);
        summary.end_ns = @max(summary.end_ns, process.end_ns.?);
        summary.self_cpu_sum_ns = std.math.add(
            u128,
            summary.self_cpu_sum_ns,
            process.cpu_time_ns,
        ) catch return error.InvalidSession;
        if (std.mem.indexOfScalar(usize, analysis.longest_process_chain, process_id) != null) {
            summary.critical_path_candidate = true;
        }
    }
    return summary;
}

fn writePhases(json: *std.json.Stringify, session: *const Session) !void {
    try json.beginObject();
    try field(json, "overlap_allowed", true);
    try json.objectField("items");
    try json.beginArray();

    var first_child_start_ns: ?u64 = null;
    for (session.processes.items[1..]) |process| {
        if (process.parent_index != 0) continue;
        first_child_start_ns = @min(first_child_start_ns orelse process.start_ns, process.start_ns);
    }
    if (first_child_start_ns) |end_ns| {
        if (end_ns > session.processes.items[0].start_ns) {
            try json.beginObject();
            try field(json, "name", "build_driver_startup");
            try field(json, "start_ns", session.processes.items[0].start_ns);
            try field(json, "end_ns", end_ns);
            try field(json, "method", "first_child_start");
            try json.endObject();
        }
    }
    for (component_order) |component| {
        var start_ns: u64 = std.math.maxInt(u64);
        var end_ns: u64 = 0;
        for (session.processes.items, 0..) |process, process_id| {
            if (processComponent(session, process_id) != component) continue;
            start_ns = @min(start_ns, process.start_ns);
            end_ns = @max(end_ns, process.end_ns.?);
        }
        if (start_ns == std.math.maxInt(u64)) continue;
        try json.beginObject();
        try field(json, "name", componentName(component));
        try field(json, "start_ns", start_ns);
        try field(json, "end_ns", end_ns);
        try field(json, "method", "classified_process_envelope");
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

fn processComponent(session: *const Session, process_id: usize) ?Component {
    const process = &session.processes.items[process_id];
    const classification = classifyCommand(analysisExec(process), session.metadata.items);
    const name = classification.component orelse return null;
    inline for (component_order) |component| {
        if (std.mem.eql(u8, name, componentName(component))) return component;
    }
    return null;
}

fn componentName(component: Component) []const u8 {
    return @tagName(component);
}

fn writeDiagnostics(
    json: *std.json.Stringify,
    session: *const Session,
    totals: Totals,
) !void {
    try json.beginArray();
    const environment = session.environment;
    if (environment.started_at_unix_seconds == null or
        environment.host_os == .unknown or
        environment.architecture == .unknown)
    {
        try writeDiagnostic(json, "capture_environment_unavailable", "info");
    }
    try writeDiagnostic(json, "critical_path_inferred", "info");
    try writeDiagnostic(json, "single_sample", "info");
    try writeDiagnostic(json, "cache_state_unknown", "info");
    const root_command = analysisExec(&session.processes.items[0]);
    if (std.mem.eql(u8, normalizedTool(root_command, session.metadata.items), "zig")) {
        try writeDiagnostic(json, "target_zig_version_unknown", "info");
    }
    if (findOptimizeMode(session) == null) {
        try writeDiagnostic(json, "optimize_mode_unknown", "info");
    }
    if (session.isIncomplete()) try writeDiagnostic(json, "capture_incomplete", "warning");
    if (totals.recovered_process_count != 0) {
        try writeDiagnostic(json, "process_recovered", "warning");
    }
    if (totals.partial_cpu_process_count != 0) {
        try writeDiagnostic(json, "cpu_partial", "warning");
    }
    var has_truncated_arguments = false;
    for (session.processes.items) |process| {
        for (0..process.execCount()) |exec_index| {
            if (argvPreviewTruncated(process.execAt(exec_index), session.metadata.items)) {
                has_truncated_arguments = true;
                break;
            }
        }
    }
    if (has_truncated_arguments) {
        try json.beginObject();
        try field(json, "code", "arguments_truncated");
        try field(json, "severity", "info");
        try json.objectField("process_ids");
        try json.beginArray();
        for (session.processes.items, 0..) |process, process_id| {
            var truncated = false;
            for (0..process.execCount()) |exec_index| {
                if (argvPreviewTruncated(process.execAt(exec_index), session.metadata.items)) {
                    truncated = true;
                    break;
                }
            }
            if (truncated) try json.write(process_id);
        }
        try json.endArray();
        try json.endObject();
    }
    if (totals.unexplained_wall_time_ns != 0) {
        try writeDiagnostic(json, "stall_cause_unknown", "info");
    }
    const root = analysisExec(&session.processes.items[0]);
    if (root.exe_source == .unavailable) {
        try writeDiagnostic(json, "target_executable_unresolved", "info");
    }
    try json.endArray();
}

fn argvPreviewTruncated(exec: Process.Exec, metadata: []const u8) bool {
    if (exec.args_source == .unavailable) return false;
    if (exec.args_count > max_preview_head_args + max_preview_tail_args) return true;
    var args = exec.argsIter(metadata);
    while (args.next()) |arg| if (arg.len > max_preview_arg_bytes) return true;
    return false;
}

fn writeDiagnostic(json: *std.json.Stringify, code: []const u8, severity: []const u8) !void {
    try json.beginObject();
    try field(json, "code", code);
    try field(json, "severity", severity);
    try json.endObject();
}

fn writeBottlenecks(
    json: *std.json.Stringify,
    session: *const Session,
    analysis: *const Analysis,
    redact: bool,
) !void {
    try json.beginObject();
    try json.objectField("longest_process_chain");
    try json.beginObject();
    try field(json, "method", "process_ancestry_and_exit_order");
    try field(json, "additive", false);
    try field(json, "inferred", true);
    try json.objectField("process_ids");
    try json.beginArray();
    for (analysis.longest_process_chain) |process_id| try json.write(process_id);
    try json.endArray();
    try json.objectField("entries");
    try json.beginArray();
    for (analysis.longest_process_chain) |process_id| {
        const item = analysis.processes[process_id];
        try json.beginObject();
        try field(json, "process_id", process_id);
        try json.objectField("label");
        try writeAnalysisLabel(
            json,
            analysisExec(&session.processes.items[process_id]),
            session.metadata.items,
            redact,
        );
        const process = session.processes.items[process_id];
        try field(json, "start_ns", process.start_ns);
        try field(json, "end_ns", process.end_ns.?);
        try field(json, "wall_time_ns", item.wall_time_ns);
        try field(json, "self_cpu_time_ns", item.self_cpu_time_ns);
        try field(
            json,
            "root_elapsed_share_permyriad",
            ratioPermyriad(item.wall_time_ns, session.elapsed_ns),
        );
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try json.objectField("wall_time_stragglers");
    try writeRanking(
        json,
        session,
        analysis.processes,
        analysis.totals,
        .wall_time,
        redact,
    );
    try json.endObject();
}

fn writeRanking(
    json: *std.json.Stringify,
    session: *const Session,
    processes: []const DerivedProcess,
    totals: Totals,
    ranking: Ranking,
    redact: bool,
) !void {
    var top: [max_ranked_processes]DerivedProcess = undefined;
    var top_len: usize = 0;
    for (processes) |candidate| {
        if (rankingMetric(candidate, ranking) == 0) continue;
        var position: usize = 0;
        while (position < top_len and !ranksBefore(candidate, top[position], ranking)) {
            position += 1;
        }
        if (position >= max_ranked_processes) continue;
        const new_len = @min(top_len + 1, max_ranked_processes);
        var move_index = new_len;
        while (move_index > position + 1) {
            move_index -= 1;
            top[move_index] = top[move_index - 1];
        }
        top[position] = candidate;
        top_len = new_len;
    }

    try json.beginArray();
    for (top[0..top_len]) |item| {
        const process = session.processes.items[item.id];
        const classification = classifyCommand(analysisExec(&process), session.metadata.items);
        try json.beginObject();
        try field(json, "process_id", item.id);
        try json.objectField("label");
        try writeAnalysisLabel(
            json,
            analysisExec(&session.processes.items[item.id]),
            session.metadata.items,
            redact,
        );
        try field(json, "start_ns", process.start_ns);
        try field(json, "end_ns", process.end_ns.?);
        try field(json, "wall_time_ns", item.wall_time_ns);
        try field(json, "self_cpu_time_ns", item.self_cpu_time_ns);
        try field(json, "inclusive_cpu_time_ns", item.inclusive_cpu_time_ns);
        try field(
            json,
            "total_cpu_share_permyriad",
            ratioPermyriadWide(item.self_cpu_time_ns, totals.self_cpu_time_ns),
        );
        try field(
            json,
            "root_elapsed_share_permyriad",
            ratioPermyriad(item.wall_time_ns, session.elapsed_ns),
        );
        try json.objectField("component");
        try json.write(classification.component);
        try json.objectField("primary_input");
        if (!redact and classification.primary_input != null) {
            const primary_input = classification.primary_input.?;
            _ = try writeDisplay(json, primary_input, Process.max_path_len);
        } else {
            try json.write(@as(?[]const u8, null));
        }
        if (ranking == .unexplained_wall_time) {
            try field(json, "inferred", true);
            try field(json, "unexplained_wall_time_ns", item.unexplained_wall_time_ns);
            try field(
                json,
                "unexplained_wall_permyriad",
                ratioPermyriad(item.unexplained_wall_time_ns, item.wall_time_ns),
            );
            try json.objectField("possible_causes");
            try json.beginArray();
            try json.write("io_wait");
            try json.write("scheduler_delay");
            try json.write("synchronization");
            try json.write("timer_or_sleep");
            try json.write("sampling_boundary");
            try json.endArray();
            try field(json, "evidence", "unexplained_wall_time");
            try field(json, "confidence", "low");
        } else {
            try field(json, "inferred", false);
        }
        try json.endObject();
    }
    try json.endArray();
}

fn ranksBefore(lhs: DerivedProcess, rhs: DerivedProcess, ranking: Ranking) bool {
    const lhs_metric = rankingMetric(lhs, ranking);
    const rhs_metric = rankingMetric(rhs, ranking);
    if (lhs_metric != rhs_metric) return lhs_metric > rhs_metric;
    return lhs.id < rhs.id;
}

fn rankingMetric(process: DerivedProcess, ranking: Ranking) u128 {
    return switch (ranking) {
        .self_cpu_time => process.self_cpu_time_ns,
        .wall_time => process.wall_time_ns,
        .unexplained_wall_time => process.unexplained_wall_time_ns,
    };
}

fn writeProcess(
    json: *std.json.Stringify,
    session: *const Session,
    analysis: *const Analysis,
    derived: DerivedProcess,
) !void {
    const process = &session.processes.items[derived.id];
    const end_ns = process.end_ns.?;
    const wall_time_ns = derived.wall_time_ns;

    try json.beginObject();
    try field(json, "id", derived.id);
    try json.objectField("parent_id");
    try json.write(process.parent_index);
    try field(json, "depth", process.depth);
    try field(json, "pid", process.pid);
    try field(json, "start_ns", process.start_ns);
    try field(json, "end_ns", end_ns);
    try field(json, "wall_time_ns", wall_time_ns);
    try field(json, "self_cpu_time_ns", process.cpu_time_ns);
    try field(
        json,
        "self_average_cpu_millicores",
        try cpuMillicores(process.cpu_time_ns, wall_time_ns),
    );
    try field(json, "peak_cpu_millicores", derived.peak_cpu_millicores);
    try field(json, "cpu_activity_span_ns", derived.cpu_activity_span_ns);
    try field(json, "child_lifetime_span_ns", derived.child_lifetime_span_ns);
    try field(json, "explained_wall_time_ns", derived.explained_wall_time_ns);
    try field(json, "unexplained_wall_time_ns", derived.unexplained_wall_time_ns);
    try field(
        json,
        "unexplained_wall_permyriad",
        ratioPermyriad(derived.unexplained_wall_time_ns, wall_time_ns),
    );
    try field(json, "inclusive_cpu_time_ns", derived.inclusive_cpu_time_ns);
    try field(json, "inclusive_process_count", derived.inclusive_process_count);
    try field(json, "origin", @tagName(process.origin));
    try field(json, "end_kind", @tagName(process.end_kind));
    try field(json, "cpu_final", process.cpu_final);
    try field(json, "command_interval_count", process.execCount());
    try json.objectField("exec_transition_count");
    if (process.origin == .observed and session.loss_count == 0) {
        try json.write(process.execCount() - 1);
    } else {
        try json.write(@as(?usize, null));
    }
    try field(
        json,
        "final_command_id",
        analysis.commandId(derived.id, process.execCount() - 1),
    );
    try json.objectField("command_intervals");
    try json.beginArray();
    for (0..process.execCount()) |exec_index| {
        const exec = process.execAt(exec_index);
        try json.beginObject();
        try field(json, "kind", commandIntervalKind(process, exec, exec_index));
        try field(json, "kind_inferred", true);
        try field(json, "start_ns", exec.start_ns);
        try field(json, "end_ns", exec.end_ns.?);
        try field(json, "wall_time_ns", exec.end_ns.? - exec.start_ns);
        try field(json, "command_id", analysis.commandId(derived.id, exec_index));
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

fn writeCommand(
    json: *std.json.Stringify,
    exec: Process.Exec,
    metadata: []const u8,
    redact: bool,
) !void {
    const classification = classifyCommand(exec, metadata);
    try json.beginObject();
    try field(json, "tool", classification.tool);
    try field(json, "action", classification.action);
    try json.objectField("component");
    try json.write(classification.component);
    try json.objectField("primary_input");
    if (!redact and classification.primary_input != null) {
        const primary_input = classification.primary_input.?;
        _ = try writeDisplay(json, primary_input, Process.max_path_len);
    } else {
        try json.write(@as(?[]const u8, null));
    }
    try json.objectField("language");
    try json.write(classification.language);
    try json.objectField("output_kind");
    try json.write(classification.output_kind);
    try field(json, "classification_method", classification.method);
    if (classification.confidence_permyriad) |confidence| {
        try field(json, "classification_confidence_permyriad", confidence);
    }
    try json.objectField("label");
    try writeAnalysisLabel(json, exec, metadata, redact);
    try json.objectField("name");
    if (redact) {
        try json.write(classification.tool);
    } else {
        _ = try writeDisplay(json, exec.nameSlice(), Process.max_name_len);
    }
    try json.objectField("argv");
    try writeArgv(json, exec, metadata, redact);
    try json.objectField("exe");
    if (redact or exec.exe_source == .unavailable) {
        try json.write(@as(?[]const u8, null));
    } else {
        _ = try writeDisplay(json, exec.exeSlice(metadata), Process.max_path_len);
    }
    try field(json, "exe_truncated", exec.exe_truncated);
    try json.objectField("cwd");
    if (redact or exec.cwd_source == .unavailable) {
        try json.write(@as(?[]const u8, null));
    } else {
        _ = try writeDisplay(json, exec.cwdSlice(metadata), Process.max_path_len);
    }
    try field(json, "cwd_truncated", exec.cwd_truncated);
    try json.endObject();
}

fn writeAnalysisLabel(
    json: *std.json.Stringify,
    exec: Process.Exec,
    metadata: []const u8,
    redact: bool,
) !void {
    if (!redact) return writeCommandLabel(json, exec, metadata);
    const classification = classifyCommand(exec, metadata);
    if (std.mem.eql(u8, classification.action, "unknown")) {
        try json.write(classification.tool);
        return;
    }
    var buffer: [96]u8 = undefined;
    const label = std.fmt.bufPrint(
        &buffer,
        "{s} {s}",
        .{ classification.tool, classification.action },
    ) catch classification.tool;
    try json.write(label);
}

fn classifyCommand(exec: Process.Exec, metadata: []const u8) Classification {
    const tool = normalizedTool(exec, metadata);
    if (std.mem.eql(u8, tool, "unknown")) {
        return .{ .tool = tool, .action = "unknown", .method = "unknown" };
    }

    var result = Classification{
        .tool = tool,
        .action = "unknown",
        .method = if (exec.args_source == .unavailable) "path" else "arguments",
    };
    var args = exec.argsIter(metadata);
    _ = args.next();
    if (std.mem.eql(u8, tool, "zig")) {
        const subcommand = args.next() orelse return result;
        if (std.mem.eql(u8, subcommand, "build") or
            std.mem.eql(u8, subcommand, "build-lib") or
            std.mem.eql(u8, subcommand, "build-exe") or
            std.mem.eql(u8, subcommand, "build-obj") or
            std.mem.eql(u8, subcommand, "test") or
            std.mem.eql(u8, subcommand, "clang") or
            std.mem.eql(u8, subcommand, "cc") or
            std.mem.eql(u8, subcommand, "c++"))
        {
            result.action = subcommand;
        }
        result.primary_input = findPrimaryInput(exec, metadata);
        result.language = if (result.primary_input) |input| sourceLanguage(input) else null;
        result.output_kind = zigOutputKind(subcommand, exec, metadata);
    } else if (std.mem.eql(u8, tool, "clang") or
        std.mem.eql(u8, tool, "gcc") or
        std.mem.eql(u8, tool, "cc"))
    {
        result.action = if (hasArgumentPrefix(exec, metadata, "-print-"))
            "query"
        else if (hasArgument(exec, metadata, "-E"))
            "preprocess"
        else
            "compile";
        result.primary_input = findSourceInput(exec, metadata);
        result.language = if (result.primary_input) |input| sourceLanguage(input) else null;
        result.output_kind = if (hasArgument(exec, metadata, "-c"))
            "object"
        else if (hasArgument(exec, metadata, "-E"))
            "preprocessed_source"
        else
            null;
    } else if (std.mem.eql(u8, tool, "pkg-config")) {
        result.action = "query";
        result.primary_input = firstPositionalArgument(exec, metadata);
    } else if (std.mem.eql(u8, tool, "wayland-scanner")) {
        result.action = "scan";
        var scanner_args = exec.argsIter(metadata);
        _ = scanner_args.next();
        const mode = scanner_args.next();
        result.primary_input = scanner_args.next();
        result.output_kind = if (mode) |value|
            if (std.mem.eql(u8, value, "client-header"))
                "header"
            else if (std.mem.eql(u8, value, "private-code"))
                "source"
            else
                null
        else
            null;
    } else if (std.mem.eql(u8, tool, "zig-build-runner")) {
        result.action = "build";
        var runner_args = exec.argsIter(metadata);
        _ = runner_args.next();
        _ = runner_args.next();
        _ = runner_args.next();
        result.primary_input = runner_args.next();
    } else if (std.mem.eql(u8, tool, "ninja") or
        std.mem.eql(u8, tool, "make") or
        std.mem.eql(u8, tool, "cmake"))
    {
        result.action = "build";
        result.primary_input = firstPositionalArgument(exec, metadata);
    }
    result.component = classifyComponent(result.primary_input);
    return result;
}

fn normalizedTool(exec: Process.Exec, metadata: []const u8) []const u8 {
    const candidate = candidate: {
        if (exec.args_source != .unavailable) {
            var args = exec.argsIter(metadata);
            if (args.next()) |argv0| break :candidate std.fs.path.basename(argv0);
        }
        if (exec.exe_source != .unavailable) {
            break :candidate std.fs.path.basename(exec.exeSlice(metadata));
        }
        break :candidate exec.nameSlice();
    };
    if (std.mem.eql(u8, candidate, "zig")) return "zig";
    if (std.mem.startsWith(u8, candidate, "clang")) return "clang";
    if (std.mem.startsWith(u8, candidate, "gcc")) return "gcc";
    if (std.mem.eql(u8, candidate, "cc")) return "cc";
    if (std.mem.eql(u8, candidate, "pkg-config")) return "pkg-config";
    if (std.mem.eql(u8, candidate, "wayland-scanner")) return "wayland-scanner";
    if (std.mem.eql(u8, candidate, "cc1")) return "gcc";
    if (std.mem.eql(u8, candidate, "build")) {
        var args = exec.argsIter(metadata);
        _ = args.next();
        const zig_exe = args.next() orelse return "unknown";
        if (std.mem.eql(u8, std.fs.path.basename(zig_exe), "zig")) {
            return "zig-build-runner";
        }
    }
    if (std.mem.eql(u8, candidate, "ninja")) return "ninja";
    if (std.mem.eql(u8, candidate, "make") or std.mem.startsWith(u8, candidate, "gmake")) {
        return "make";
    }
    if (std.mem.eql(u8, candidate, "cmake")) return "cmake";
    return "unknown";
}

fn findPrimaryInput(exec: Process.Exec, metadata: []const u8) ?[]const u8 {
    var args = exec.argsIter(metadata);
    _ = args.next();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-Mroot=") and arg.len > "-Mroot=".len) {
            return arg["-Mroot=".len..];
        }
        if (sourceLanguage(arg) != null) return arg;
    }
    return null;
}

fn findSourceInput(exec: Process.Exec, metadata: []const u8) ?[]const u8 {
    var args = exec.argsIter(metadata);
    _ = args.next();
    while (args.next()) |arg| if (sourceLanguage(arg) != null) return arg;
    return null;
}

fn sourceLanguage(path: []const u8) ?[]const u8 {
    const extension = std.fs.path.extension(path);
    if (std.mem.eql(u8, extension, ".c")) return "c";
    if (std.mem.eql(u8, extension, ".cc") or
        std.mem.eql(u8, extension, ".cpp") or
        std.mem.eql(u8, extension, ".cxx"))
    {
        return "cpp";
    }
    if (std.mem.eql(u8, extension, ".m")) return "objective-c";
    if (std.mem.eql(u8, extension, ".mm")) return "objective-cpp";
    if (std.mem.eql(u8, extension, ".zig")) return "zig";
    if (std.mem.eql(u8, extension, ".rs")) return "rust";
    return null;
}

fn zigOutputKind(
    subcommand: []const u8,
    exec: Process.Exec,
    metadata: []const u8,
) ?[]const u8 {
    if (std.mem.eql(u8, subcommand, "build-lib")) return "library";
    if (std.mem.eql(u8, subcommand, "build-exe")) return "executable";
    if (std.mem.eql(u8, subcommand, "build-obj")) return "object";
    if ((std.mem.eql(u8, subcommand, "clang") or
        std.mem.eql(u8, subcommand, "cc") or
        std.mem.eql(u8, subcommand, "c++")) and hasArgument(exec, metadata, "-c"))
    {
        return "object";
    }
    return null;
}

fn hasArgument(exec: Process.Exec, metadata: []const u8, expected: []const u8) bool {
    var args = exec.argsIter(metadata);
    while (args.next()) |arg| if (std.mem.eql(u8, arg, expected)) return true;
    return false;
}

fn hasArgumentPrefix(exec: Process.Exec, metadata: []const u8, prefix: []const u8) bool {
    var args = exec.argsIter(metadata);
    while (args.next()) |arg| if (std.mem.startsWith(u8, arg, prefix)) return true;
    return false;
}

fn argumentValue(
    exec: Process.Exec,
    metadata: []const u8,
    expected: []const u8,
) ?[]const u8 {
    var args = exec.argsIter(metadata);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, expected)) return args.next();
        if (arg.len > expected.len + 1 and
            std.mem.startsWith(u8, arg, expected) and
            arg[expected.len] == '=')
        {
            return arg[expected.len + 1 ..];
        }
    }
    return null;
}

fn firstPositionalArgument(exec: Process.Exec, metadata: []const u8) ?[]const u8 {
    var args = exec.argsIter(metadata);
    _ = args.next();
    while (args.next()) |arg| {
        if (arg.len != 0 and arg[0] != '-') return arg;
    }
    return null;
}

fn classifyComponent(primary_input: ?[]const u8) ?[]const u8 {
    const input = primary_input orelse return null;
    if (std.mem.indexOf(u8, input, "raylib") != null or
        std.mem.eql(u8, std.fs.path.basename(input), "raygui.c"))
    {
        return "raylib";
    }
    if (std.mem.indexOf(u8, input, "zclay") != null or
        std.mem.indexOf(u8, input, "/clay") != null)
    {
        return "clay";
    }
    if (std.mem.indexOf(u8, input, "flamez") != null) return "flamez";
    if (std.mem.startsWith(u8, input, "/usr/") or
        std.mem.startsWith(u8, input, "/System/"))
    {
        return "system";
    }
    return null;
}

fn writeCommandLabel(
    json: *std.json.Stringify,
    exec: Process.Exec,
    metadata: []const u8,
) !void {
    var specialized_buffer: [label_bytes]u8 = undefined;
    if (zigCompilerLabel(exec, metadata, &specialized_buffer)) |label| {
        _ = try writeDisplay(json, label, label_bytes);
        return;
    }
    var summary_buffer: [64]u8 = undefined;
    const summary = exec.argSummary(metadata, &summary_buffer);
    var label_buffer: [label_bytes]u8 = undefined;
    const label = if (summary.len == 0)
        exec.nameSlice()
    else
        std.fmt.bufPrint(
            &label_buffer,
            "{s} {s}",
            .{ exec.nameSlice(), summary },
        ) catch exec.nameSlice();
    _ = try writeDisplay(json, label, label_bytes);
}

fn analysisExec(process: *const Process) Process.Exec {
    return process.execAt(process.execCount() - 1);
}

fn commandIntervalKind(
    process: *const Process,
    exec: Process.Exec,
    exec_index: usize,
) []const u8 {
    if (process.origin != .observed) return "recovered";
    if (exec_index != 0) return "exec";
    return switch (exec.args_source) {
        .inherited => "inherited",
        .launch => "launch",
        else => "initial_observation",
    };
}

fn zigCompilerLabel(
    exec: Process.Exec,
    metadata: []const u8,
    output: []u8,
) ?[]const u8 {
    if (!std.mem.eql(u8, exec.nameSlice(), "zig")) return null;
    var args = exec.argsIter(metadata);
    _ = args.next();
    const subcommand = args.next() orelse return null;
    if (!std.mem.eql(u8, subcommand, "clang") and
        !std.mem.eql(u8, subcommand, "cc") and
        !std.mem.eql(u8, subcommand, "c++"))
    {
        return null;
    }
    const source = args.next() orelse return null;
    return std.fmt.bufPrint(
        output,
        "zig {s} {s}",
        .{ subcommand, std.fs.path.basename(source) },
    ) catch null;
}

fn writeArgv(
    json: *std.json.Stringify,
    exec: Process.Exec,
    metadata: []const u8,
    redact: bool,
) !void {
    if (exec.args_source == .unavailable) {
        try json.write(@as(?usize, null));
        return;
    }

    try json.beginObject();
    try field(json, "count", exec.args_count);
    const preview_all = exec.args_count <= max_preview_head_args + max_preview_tail_args;
    const head_count = if (preview_all) exec.args_count else max_preview_head_args;
    try json.objectField("head");
    try json.beginArray();
    var args = exec.argsIter(metadata);
    var emitted: usize = 0;
    var shortened = false;
    if (!redact) {
        while (emitted < head_count) : (emitted += 1) {
            const arg = args.next() orelse break;
            shortened = (try writeDisplay(json, arg, max_preview_arg_bytes)) or shortened;
        }
    }
    try json.endArray();
    try json.objectField("tail");
    try json.beginArray();
    if (!redact and !preview_all) {
        args = exec.argsIter(metadata);
        for (0..exec.args_count - max_preview_tail_args) |_| _ = args.next();
        for (0..max_preview_tail_args) |_| {
            const arg = args.next() orelse break;
            shortened = (try writeDisplay(json, arg, max_preview_arg_bytes)) or shortened;
        }
    }
    try json.endArray();
    try json.objectField("digest");
    if (redact) {
        try json.write(@as(?[]const u8, null));
    } else {
        try writeArgvDigest(json, exec, metadata);
    }
    try field(json, "truncated", redact or shortened or !preview_all);
    try field(json, "redacted", redact);
    try json.endObject();
}

fn writeArgvDigest(
    json: *std.json.Stringify,
    exec: Process.Exec,
    metadata: []const u8,
) !void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var args = exec.argsIter(metadata);
    while (args.next()) |arg| {
        hasher.update(arg);
        hasher.update("\x00");
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    var text: ["sha256:".len + hex.len]u8 = undefined;
    @memcpy(text[0.."sha256:".len], "sha256:");
    @memcpy(text["sha256:".len..], &hex);
    try json.write(&text);
}

fn writeOptionalPath(
    json: *std.json.Stringify,
    source: Process.MetadataSource,
    path: []const u8,
) !void {
    if (source == .unavailable) {
        try json.write(@as(?[]const u8, null));
        return;
    }
    _ = try writeDisplay(json, path, Process.max_path_len);
}

fn writeDisplay(
    json: *std.json.Stringify,
    bytes: []const u8,
    comptime max_bytes: usize,
) !bool {
    const truncated = bytes.len > max_bytes;
    const source = bytes[0..@min(bytes.len, max_bytes)];
    var buffer: [max_bytes * 4 + 3]u8 = undefined;
    var len = displayBytes(source, &buffer);
    if (truncated) {
        @memcpy(buffer[len..][0..3], "…");
        len += 3;
    }
    try json.write(buffer[0..len]);
    return truncated;
}

fn displayBytes(bytes: []const u8, output: []u8) usize {
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < bytes.len) {
        const byte = bytes[input_index];
        if (byte >= 0x20 and byte < 0x7f) {
            output[output_index] = byte;
            output_index += 1;
            input_index += 1;
            continue;
        }
        if (byte >= 0x80) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch 0;
            if (sequence_len > 0 and sequence_len <= bytes.len - input_index and
                std.unicode.utf8ValidateSlice(bytes[input_index..][0..sequence_len]))
            {
                @memcpy(
                    output[output_index..][0..sequence_len],
                    bytes[input_index..][0..sequence_len],
                );
                output_index += sequence_len;
                input_index += sequence_len;
                continue;
            }
        }
        output[output_index] = '\\';
        output[output_index + 1] = 'x';
        output[output_index + 2] = hexDigit(byte >> 4);
        output[output_index + 3] = hexDigit(byte & 0x0f);
        output_index += 4;
        input_index += 1;
    }
    return output_index;
}

fn hexDigit(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'A' + nibble - 10;
}

fn peakCpuMillicores(process: *const Process) u128 {
    var peak: u128 = 0;
    for (process.cpu_slices.items) |slice| {
        peak = @max(peak, cpuMillicores(slice.cpu_ns, slice.durationNs()) catch 0);
    }
    return peak;
}

fn cpuMillicores(cpu_time_ns: anytype, wall_time_ns: u64) error{InvalidSession}!u128 {
    if (wall_time_ns == 0) return 0;
    const cpu_ns: u128 = @intCast(cpu_time_ns);
    const numerator = std.math.mul(u128, cpu_ns, 1000) catch return error.InvalidSession;
    return numerator / wall_time_ns;
}

fn ratioPermyriad(part: u64, whole: u64) u64 {
    if (whole == 0) return 0;
    return @intCast((@as(u128, part) * 10_000) / whole);
}

fn ratioPermyriadWide(part: u128, whole: u128) u64 {
    if (whole == 0) return 0;
    const scaled = std.math.mul(u128, part, 10_000) catch return 10_000;
    return @intCast(@min(scaled / whole, std.math.maxInt(u64)));
}

fn writeRootExit(json: *std.json.Stringify, root_exit: Session.RootExit) !void {
    try json.beginObject();
    switch (root_exit) {
        .unknown => try field(json, "kind", "unknown"),
        .exited => |code| {
            try field(json, "kind", "exited");
            try field(json, "code", code);
        },
        .signaled => |signal| {
            try field(json, "kind", "signaled");
            try field(json, "signal", signal);
        },
    }
    try json.endObject();
}

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

const bottleneck_fixture = @embedFile("testdata/session-v1-analysis-bottleneck.json");
const classification_fixture = @embedFile("testdata/session-v1-analysis-classification.json");

test "writer emits pretty v1 derived data without canonical bulk" {
    const testing = std.testing;
    const session_file = @import("session_file.zig");
    var input: std.Io.Reader = .fixed(@embedFile("testdata/session-v1-exec-history.json"));
    var diagnostics: session_file.Diagnostics = .{};
    var session = try session_file.read(testing.allocator, testing.io, &input, &diagnostics);
    defer session.deinit();

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &session, &output.writer);
    const json = output.written();

    try testing.expect(std.mem.startsWith(u8, json, "{\n  \"$schema\":"));
    try testing.expect(std.mem.endsWith(u8, json, "}\n"));
    try testing.expect(std.mem.indexOf(u8, json, "\"version\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"self_cpu_time_ns\": 200000") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"self_average_cpu_millicores\": 13",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"wall_time_ns\": 15000000") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"command_interval_count\": 2") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"label\": \"clang source.c\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"metadata\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"slices\"") == null);
}

test "writer optionally emits minified transport JSON" {
    const testing = std.testing;
    const session_file = @import("session_file.zig");
    var input: std.Io.Reader = .fixed(@embedFile("testdata/session-v1-minimal.json"));
    var diagnostics: session_file.Diagnostics = .{};
    var session = try session_file.read(testing.allocator, testing.io, &input, &diagnostics);
    defer session.deinit();

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try writeWithOptions(testing.allocator, &session, &output.writer, .{
        .formatting = .minified,
    });
    try testing.expect(std.mem.startsWith(u8, output.written(), "{\"$schema\":"));
    try testing.expectEqual(
        output.written().len - 1,
        std.mem.indexOfScalar(u8, output.written(), '\n').?,
    );
}

test "writer surfaces dependency and off-cpu bottleneck heuristics" {
    const testing = std.testing;
    const session_file = @import("session_file.zig");
    var input: std.Io.Reader = .fixed(bottleneck_fixture);
    var diagnostics: session_file.Diagnostics = .{};
    var session = try session_file.read(testing.allocator, testing.io, &input, &diagnostics);
    defer session.deinit();

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &session, &output.writer);
    const json = output.written();

    try testing.expect(std.mem.indexOf(u8, json, "\"longest_process_chain\": {") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"additive\": false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"label\": \"zig clang worker.c\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"cpu_activity_span_ns\": 20") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"child_lifetime_span_ns\": 40") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"explained_wall_time_ns\": 60") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"unexplained_wall_permyriad\": 4000") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"unexplained_wall_permyriad\": 10000") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"unexplained_wall_time_ns\": 80") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"confidence\": \"low\"") != null);
}

test "writer interns classified commands and keeps argument head tail and digest" {
    const testing = std.testing;
    const session_file = @import("session_file.zig");
    var input: std.Io.Reader = .fixed(classification_fixture);
    var diagnostics: session_file.Diagnostics = .{};
    var session = try session_file.read(testing.allocator, testing.io, &input, &diagnostics);
    defer session.deinit();

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &session, &output.writer);
    const json = output.written();

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(usize, 1), root.get("commands").?.object.count());
    const command = root.get("commands").?.object.get("0").?.object;
    try testing.expectEqualStrings("zig", command.get("tool").?.string);
    try testing.expectEqualStrings("clang", command.get("action").?.string);
    try testing.expectEqualStrings("raylib", command.get("component").?.string);
    try testing.expectEqualStrings("c", command.get("language").?.string);
    try testing.expectEqualStrings("object", command.get("output_kind").?.string);
    const argv = command.get("argv").?.object;
    try testing.expectEqual(@as(usize, 4), argv.get("head").?.array.items.len);
    try testing.expectEqual(@as(usize, 4), argv.get("tail").?.array.items.len);
    try testing.expect(argv.get("truncated").?.bool);
    try testing.expect(!argv.get("redacted").?.bool);
    try testing.expect(std.mem.startsWith(u8, argv.get("digest").?.string, "sha256:"));

    const processes = root.get("processes").?.array.items;
    try testing.expectEqual(processes[0].object.get("final_command_id").?.integer, 0);
    try testing.expectEqual(processes[1].object.get("final_command_id").?.integer, 0);
    try testing.expectEqualStrings(
        "launch",
        processes[0]
            .object.get("command_intervals").?.array.items[0]
            .object.get("kind").?.string,
    );
    try testing.expectEqualStrings(
        "inherited",
        processes[1]
            .object.get("command_intervals").?.array.items[0]
            .object.get("kind").?.string,
    );
    const totals = root.get("totals").?.object;
    try testing.expectEqual(@as(i64, 2), totals.get("command_interval_count").?.integer);
    try testing.expectEqual(@as(i64, 0), totals.get("exec_transition_count").?.integer);
    const component_items = root
        .get("analysis").?.object
        .get("component_aggregates").?.object
        .get("items").?.array.items;
    try testing.expectEqual(@as(usize, 1), component_items.len);
    try testing.expectEqualStrings(
        "raylib",
        component_items[0].object.get("component").?.string,
    );
    try testing.expectEqual(
        @as(i64, 20),
        component_items[0].object.get("self_cpu_sum_ns").?.integer,
    );
    const parallelism = root.get("analysis").?.object.get("parallelism").?.object;
    try testing.expectEqual(@as(i64, 1), parallelism.get("peak_leaf_processes").?.integer);
    try testing.expectEqual(@as(i64, 10), parallelism.get("peak_leaf_processes_at_ns").?.integer);
    try testing.expectEqual(
        @as(i64, 1000),
        parallelism.get("host_capacity_utilization_permyriad").?.integer,
    );
    try testing.expectEqualStrings(
        "/usr/bin/zig",
        root
            .get("target").?.object
            .get("observed").?.object
            .get("command").?.object
            .get("exe").?.string,
    );
    try testing.expectEqualStrings(
        "ReleaseFast",
        root.get("environment").?.object.get("optimize_mode").?.string,
    );
    const cache = root.get("cache").?.object;
    try testing.expectEqualStrings(
        ".zig-cache",
        cache.get("local_directory").?.string,
    );
    try testing.expectEqualStrings(
        "/cache/zig",
        cache.get("global_directory").?.string,
    );
}

test "redacted export removes captured paths previews digests and host fingerprints" {
    const testing = std.testing;
    const CaptureEnvironment = @import("tracer/CaptureEnvironment.zig");
    const session_file = @import("session_file.zig");
    var input: std.Io.Reader = .fixed(classification_fixture);
    var diagnostics: session_file.Diagnostics = .{};
    var session = try session_file.read(testing.allocator, testing.io, &input, &diagnostics);
    defer session.deinit();
    session.environment = CaptureEnvironment.capture(testing.io);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try writeWithOptions(testing.allocator, &session, &output.writer, .{
        .privacy = .redacted,
    });
    const bytes = output.written();
    try testing.expect(std.mem.indexOf(u8, bytes, "/deps/raylib") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "/workspace/flamez") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "/usr/bin/zig") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "/cache/zig") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "rtextures.c") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, session.environment.kernelVersion()) == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const command = root.get("commands").?.object.get("0").?.object;
    try testing.expect(command.get("primary_input").? == .null);
    try testing.expect(command.get("exe").? == .null);
    try testing.expect(command.get("cwd").? == .null);
    const argv = command.get("argv").?.object;
    try testing.expect(argv.get("redacted").?.bool);
    try testing.expect(argv.get("digest").? == .null);
    try testing.expectEqual(@as(usize, 0), argv.get("head").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), argv.get("tail").?.array.items.len);
    try testing.expect(root.get("environment").?.object.get("generated_at").? == .null);
    try testing.expect(root.get("environment").?.object.get("kernel_version").? == .null);
    try testing.expect(root.get("cache").?.object.get("local_directory").? == .null);
    try testing.expect(root.get("cache").?.object.get("global_directory").? == .null);
}

test "incomplete capture does not claim a complete transition count or invariants" {
    const testing = std.testing;
    const session_file = @import("session_file.zig");
    var input: std.Io.Reader = .fixed(bottleneck_fixture);
    var diagnostics: session_file.Diagnostics = .{};
    var session = try session_file.read(testing.allocator, testing.io, &input, &diagnostics);
    defer session.deinit();
    session.loss_count = 1;

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try write(testing.allocator, &session, &output.writer);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        output.written(),
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    const totals = root.get("totals").?.object;
    try testing.expect(totals.get("exec_transition_count").? == .null);
    try testing.expect(!totals.get("exec_transition_count_complete").?.bool);
    const not_checked = root
        .get("capture").?.object
        .get("invariants").?.object
        .get("not_checked").?.array.items;
    var found_command_coverage = false;
    var found_cpu_total = false;
    for (not_checked) |item| {
        if (std.mem.eql(u8, item.string, "command_lifetime_coverage")) {
            found_command_coverage = true;
        }
        if (std.mem.eql(u8, item.string, "total_self_cpu")) found_cpu_total = true;
    }
    try testing.expect(found_command_coverage);
    try testing.expect(found_cpu_total);
}

test "display text keeps one JSON string type for arbitrary bytes" {
    const testing = std.testing;
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    _ = try writeDisplay(&json, "a\x00\xffé", 16);
    try testing.expectEqualStrings("\"a\\\\x00\\\\xFFé\"", output.written());
}

test "capture timestamp uses deterministic UTC formatting" {
    const testing = std.testing;
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try writeGeneratedAt(&json, 0);
    try testing.expectEqualStrings("\"1970-01-01T00:00:00Z\"", output.written());
}
