//! Compact derived JSON for automated performance analysis.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Process = @import("tracer/Process.zig");
const Session = @import("tracer/Session.zig");

const log = std.log.scoped(.analysis_file);

const max_preview_args: usize = 8;
const max_preview_arg_bytes: usize = 160;
const max_ranked_processes: usize = 10;
const label_bytes = Process.max_name_len + 2 + 64;

pub const WriteError = Allocator.Error || std.Io.Writer.Error || error{InvalidSession};

pub const WriteFileError =
    WriteError ||
    std.Io.Dir.CreateFileAtomicError ||
    std.Io.File.Writer.Error ||
    std.Io.File.Atomic.ReplaceError;

const DerivedProcess = struct {
    id: usize,
    cpu_time_ns: u64,
    wall_time_ns: u64,
    subtree_cpu_time_ns: u128,
    subtree_process_count: usize = 1,
    peak_cpu_millicores: u128,
    cpu_activity_span_ns: u64 = 0,
    child_lifetime_span_ns: u64 = 0,
    explained_wall_time_ns: u64 = 0,
    unexplained_wall_time_ns: u64 = 0,
    dominant_child_id: ?usize = null,
};

const Totals = struct {
    cpu_time_ns: u128 = 0,
    unexplained_wall_time_ns: u128 = 0,
    exec_count: usize = 0,
    recovered_process_count: usize = 0,
    capture_clipped_process_count: usize = 0,
    partial_cpu_process_count: usize = 0,
};

const Analysis = struct {
    processes: []DerivedProcess,
    longest_dependency_chain: []usize,
    totals: Totals,

    fn deinit(self: *Analysis, gpa: Allocator) void {
        gpa.free(self.longest_dependency_chain);
        gpa.free(self.processes);
        self.* = undefined;
    }
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
    cpu_time,
    wall_time,
    unexplained_wall_time,
};

/// Writes an analysis view of a validated, finished session.
pub fn write(
    gpa: Allocator,
    session: *const Session,
    writer: *std.Io.Writer,
) WriteError!void {
    if (!session.finished or session.processes.items.len == 0) return error.InvalidSession;

    var analysis = try prepare(gpa, session);
    defer analysis.deinit(gpa);

    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try field(&json, "flamez_analysis", @as(u8, 1));
    try field(&json, "source_flamez", @as(u8, 1));
    try field(&json, "time_unit", "nanoseconds");
    try field(&json, "cpu_rate_unit", "millicores");
    try json.objectField("capture");
    try writeCapture(&json, session, analysis.totals);
    try json.objectField("totals");
    try writeTotals(&json, session, analysis.totals);
    try json.objectField("target");
    try writeCommand(&json, session.processes.items[0].rowExec(), session.metadata.items);
    try json.objectField("bottlenecks");
    try writeBottlenecks(&json, session, &analysis);
    try json.objectField("processes");
    try json.beginArray();
    for (analysis.processes) |item| try writeProcess(&json, session, item);
    try json.endArray();
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
    var totals: Totals = .{};

    for (session.processes.items, 0..) |process, id| {
        if (process.end_ns == null or process.end_kind == .open) return error.InvalidSession;
        derived[id] = .{
            .id = id,
            .cpu_time_ns = process.cpu_time_ns,
            .wall_time_ns = process.end_ns.? - process.start_ns,
            .subtree_cpu_time_ns = process.cpu_time_ns,
            .peak_cpu_millicores = peakCpuMillicores(&process),
        };
        totals.cpu_time_ns = std.math.add(u128, totals.cpu_time_ns, process.cpu_time_ns) catch
            return error.InvalidSession;
        totals.exec_count = std.math.add(usize, totals.exec_count, process.execCount()) catch
            return error.InvalidSession;
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
        derived[parent_id].subtree_cpu_time_ns = std.math.add(
            u128,
            derived[parent_id].subtree_cpu_time_ns,
            derived[index].subtree_cpu_time_ns,
        ) catch return error.InvalidSession;
        derived[parent_id].subtree_process_count = std.math.add(
            usize,
            derived[parent_id].subtree_process_count,
            derived[index].subtree_process_count,
        ) catch return error.InvalidSession;
    }

    var chain: std.ArrayList(usize) = .empty;
    defer chain.deinit(gpa);
    var process_id: ?usize = 0;
    while (process_id) |id| {
        try chain.append(gpa, id);
        process_id = derived[id].dominant_child_id;
    }

    return .{
        .processes = derived,
        .longest_dependency_chain = try chain.toOwnedSlice(gpa),
        .totals = totals,
    };
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
    try field(json, "host_cpu_count", session.host_cpu_count);
    try field(json, "elapsed_ns", session.elapsed_ns);
    try json.objectField("root_exit");
    try writeRootExit(json, session.root_exit);
    try json.endObject();
}

fn writeTotals(json: *std.json.Stringify, session: *const Session, totals: Totals) !void {
    try json.beginObject();
    try field(json, "process_count", session.processes.items.len);
    try field(json, "exec_count", totals.exec_count);
    try field(json, "cpu_time_ns", totals.cpu_time_ns);
    try field(
        json,
        "average_cpu_millicores",
        try cpuMillicores(totals.cpu_time_ns, session.elapsed_ns),
    );
    try field(json, "unexplained_wall_time_ns", totals.unexplained_wall_time_ns);
    try json.endObject();
}

fn writeBottlenecks(
    json: *std.json.Stringify,
    session: *const Session,
    analysis: *const Analysis,
) !void {
    try json.beginObject();
    try json.objectField("longest_dependency_chain");
    try json.beginArray();
    for (analysis.longest_dependency_chain) |process_id| {
        const item = analysis.processes[process_id];
        try json.beginObject();
        try field(json, "id", process_id);
        try json.objectField("label");
        try writeCommandLabel(
            json,
            analysisExec(&session.processes.items[process_id]),
            session.metadata.items,
        );
        try field(json, "wall_time_ns", item.wall_time_ns);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("cpu_hotspots");
    try writeRanking(json, session, analysis.processes, .cpu_time);
    try json.objectField("wall_time_bottlenecks");
    try writeRanking(json, session, analysis.processes, .wall_time);
    try json.objectField("io_wait_candidates");
    try writeRanking(json, session, analysis.processes, .unexplained_wall_time);
    try json.endObject();
}

fn writeRanking(
    json: *std.json.Stringify,
    session: *const Session,
    processes: []const DerivedProcess,
    ranking: Ranking,
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
        try json.beginObject();
        try field(json, "id", item.id);
        try json.objectField("label");
        try writeCommandLabel(
            json,
            analysisExec(&session.processes.items[item.id]),
            session.metadata.items,
        );
        switch (ranking) {
            .cpu_time => try field(json, "cpu_time_ns", item.cpu_time_ns),
            .wall_time => try field(json, "wall_time_ns", item.wall_time_ns),
            .unexplained_wall_time => {
                try field(json, "unexplained_wall_time_ns", item.unexplained_wall_time_ns);
                try field(
                    json,
                    "unexplained_wall_permyriad",
                    ratioPermyriad(item.unexplained_wall_time_ns, item.wall_time_ns),
                );
            },
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
        .cpu_time => process.cpu_time_ns,
        .wall_time => process.wall_time_ns,
        .unexplained_wall_time => process.unexplained_wall_time_ns,
    };
}

fn writeProcess(
    json: *std.json.Stringify,
    session: *const Session,
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
    try field(json, "cpu_time_ns", process.cpu_time_ns);
    try field(
        json,
        "average_cpu_millicores",
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
    try field(json, "subtree_cpu_time_ns", derived.subtree_cpu_time_ns);
    try field(json, "subtree_process_count", derived.subtree_process_count);
    try field(json, "origin", @tagName(process.origin));
    try field(json, "end_kind", @tagName(process.end_kind));
    try field(json, "cpu_final", process.cpu_final);
    try field(json, "exec_count", process.execCount());
    try json.objectField("command");
    const row = process.rowExec();
    try writeCommand(json, analysisExec(process), session.metadata.items);
    try json.objectField("execs");
    try json.beginArray();
    if (row.row_only or process.execCount() > 1) {
        for (0..process.execCount()) |exec_index| {
            const exec = process.execAt(exec_index);
            try json.beginObject();
            try field(json, "start_ns", exec.start_ns);
            try field(json, "end_ns", exec.end_ns.?);
            try field(json, "wall_time_ns", exec.end_ns.? - exec.start_ns);
            try json.objectField("command");
            try writeCommand(json, exec, session.metadata.items);
            try json.endObject();
        }
    }
    try json.endArray();
    try json.endObject();
}

fn writeCommand(
    json: *std.json.Stringify,
    exec: Process.Exec,
    metadata: []const u8,
) !void {
    try json.beginObject();
    try json.objectField("label");
    try writeCommandLabel(json, exec, metadata);
    try json.objectField("name");
    _ = try writeDisplay(json, exec.nameSlice(), Process.max_name_len);
    try json.objectField("argv");
    try writeArgv(json, exec, metadata);
    try json.objectField("exe");
    if (exec.exe_source == .unavailable) {
        try json.write(@as(?[]const u8, null));
    } else {
        _ = try writeDisplay(json, exec.exeSlice(metadata), Process.max_path_len);
    }
    try field(json, "exe_truncated", exec.exe_truncated);
    try json.objectField("cwd");
    if (exec.cwd_source == .unavailable) {
        try json.write(@as(?[]const u8, null));
    } else {
        _ = try writeDisplay(json, exec.cwdSlice(metadata), Process.max_path_len);
    }
    try field(json, "cwd_truncated", exec.cwd_truncated);
    try json.endObject();
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

fn writeArgv(json: *std.json.Stringify, exec: Process.Exec, metadata: []const u8) !void {
    if (exec.args_source == .unavailable) {
        try json.write(@as(?usize, null));
        return;
    }

    try json.beginObject();
    try field(json, "count", exec.args_count);
    try json.objectField("preview");
    try json.beginArray();
    var args = exec.argsIter(metadata);
    var emitted: usize = 0;
    var shortened = false;
    while (emitted < max_preview_args) : (emitted += 1) {
        const arg = args.next() orelse break;
        shortened = (try writeDisplay(json, arg, max_preview_arg_bytes)) or shortened;
    }
    try json.endArray();
    try field(json, "truncated", shortened or emitted < exec.args_count);
    try json.endObject();
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

const bottleneck_fixture =
    \\{"flamez":1,"loss_count":0,"capture_fidelity":"exact","cpu_sample_period_ns":10,"host_cpu_count":2,"target_argv":0,"elapsed_ns":100,"root_exit":{"kind":"exited","code":0},"metadata":{"argv":[["build"],["zig","clang","/tmp/worker.c"]],"paths":[]},"processes":[{"pid":1,"parent":null,"start_ns":0,"end_ns":100,"origin":"observed","end_kind":"observed_exit","row":"first_exec","execs":[{"start_ns":0,"end_ns":100,"name":"build","name_kind":"process","argv":{"ref":0,"source":"launch"},"exe":null,"cwd":null}],"cpu_time_ns":20,"cpu_final":true,"slices":[[0,20,20]]},{"pid":2,"parent":0,"start_ns":40,"end_ns":80,"origin":"observed","end_kind":"observed_exit","row":"first_exec","execs":[{"start_ns":40,"end_ns":80,"name":"zig","name_kind":"process","argv":{"ref":1,"source":"kernel"},"exe":null,"cwd":null}],"cpu_time_ns":0,"cpu_final":true,"slices":[]}]}
;

test "writer emits ranked derived data without canonical bulk" {
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

    try testing.expect(std.mem.startsWith(u8, json, "{\"flamez_analysis\":1,"));
    try testing.expect(std.mem.endsWith(u8, json, "}\n"));
    try testing.expect(std.mem.indexOf(u8, json, "\"cpu_time_ns\":200000") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"average_cpu_millicores\":13") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"wall_time_ns\":15000000") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"exec_count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"label\":\"clang source.c\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"metadata\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"slices\"") == null);
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

    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"longest_dependency_chain\":[{\"id\":0,",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"label\":\"zig clang worker.c\"") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"cpu_activity_span_ns\":20,\"child_lifetime_span_ns\":40," ++
            "\"explained_wall_time_ns\":60,\"unexplained_wall_time_ns\":40," ++
            "\"unexplained_wall_permyriad\":4000",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"cpu_activity_span_ns\":0,\"child_lifetime_span_ns\":0," ++
            "\"explained_wall_time_ns\":0,\"unexplained_wall_time_ns\":40," ++
            "\"unexplained_wall_permyriad\":10000",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"unexplained_wall_time_ns\":80") != null);
}

test "display text keeps one JSON string type for arbitrary bytes" {
    const testing = std.testing;
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    _ = try writeDisplay(&json, "a\x00\xffé", 16);
    try testing.expectEqualStrings("\"a\\\\x00\\\\xFFé\"", output.written());
}
