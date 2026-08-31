//! Builds styled process information for the hover tooltip and detail pane.

const std = @import("std");
const rl = @import("raylib");
const tracer = @import("tracer.zig");
const text = @import("text.zig");
const theme = @import("theme.zig");

const log = std.log.scoped(.process_info);

const toRaylibColor = theme.toRaylibColor;
const ink = theme.ink;
const muted = theme.muted;

/// Trailing overflow marker when an info block exceeds its row budget.
pub const tooltip_more_marker = "…";
/// Visible hover-tooltip rows, including a trailing overflow marker when needed.
pub const tooltip_max_rows: usize = 7;

pub const TextSpan = struct {
    start: usize,
    end: usize,
};

const LineStyles = struct {
    bold: ?TextSpan = null,
    accent: ?TextSpan = null,
};

pub const TooltipLine = struct {
    text: []const u8,
    size: f32,
    color: rl.Color,
    bold: ?TextSpan = null,
    accent: ?TextSpan = null,
    /// Copying joins wrapped continuations and preserves only logical row breaks.
    break_after: bool = true,
};

fn spanWithin(span: ?TextSpan, offset: usize, len: usize) ?TextSpan {
    const source = span orelse return null;
    const start = @max(source.start, offset);
    const end = @min(source.end, offset + len);
    if (start >= end) return null;
    return .{
        .start = start - offset,
        .end = end - offset,
    };
}

/// Caller-backed builder for process-detail lines. It never allocates; text
/// and line storage must outlive every slice returned through `lines`.
pub const TooltipBuilder = struct {
    font: rl.Font,
    inner_w: f32,
    /// Caller-owned scratch space; `intern` stops accepting text once full.
    store: []u8,
    store_len: usize = 0,
    /// Caller-owned output; lines past the end are dropped.
    lines: []TooltipLine,
    line_count: usize = 0,
    overflowed: bool = false,

    fn intern(self: *TooltipBuilder, value: []const u8) ?[]const u8 {
        if (value.len + 1 > self.store.len - self.store_len) {
            self.overflowed = true;
            return null;
        }
        const start = self.store_len;
        @memcpy(self.store[start..][0..value.len], value);
        self.store_len += value.len;
        return self.store[start..self.store_len];
    }

    fn internFmt(self: *TooltipBuilder, comptime fmt: []const u8, args: anytype) ?[]const u8 {
        var buf: [512]u8 = undefined;
        const value = std.fmt.bufPrint(&buf, fmt, args) catch return null;
        return self.intern(value);
    }

    fn add(self: *TooltipBuilder, value: []const u8, size: f32, color: rl.Color) void {
        if (self.line_count >= self.lines.len) {
            self.overflowed = true;
            return;
        }
        const stored = self.intern(value) orelse return;
        self.lines[self.line_count] = .{
            .text = stored,
            .size = size,
            .color = color,
        };
        self.line_count += 1;
    }

    fn addFmt(
        self: *TooltipBuilder,
        comptime fmt: []const u8,
        args: anytype,
        size: f32,
        color: rl.Color,
    ) void {
        if (self.line_count >= self.lines.len) {
            self.overflowed = true;
            return;
        }
        const stored = self.internFmt(fmt, args) orelse return;
        self.lines[self.line_count] = .{
            .text = stored,
            .size = size,
            .color = color,
        };
        self.line_count += 1;
    }

    fn addWrapped(self: *TooltipBuilder, value: []const u8, size: f32, color: rl.Color) void {
        self.addWrappedStyled(value, size, color, .{});
    }

    fn addWrappedStyled(
        self: *TooltipBuilder,
        value: []const u8,
        size: f32,
        color: rl.Color,
        styles: LineStyles,
    ) void {
        if (self.line_count >= self.lines.len) {
            self.overflowed = true;
            return;
        }
        var rest = value;
        var offset: usize = 0;
        while (rest.len > 0 and self.line_count < self.lines.len) {
            const take = wrapPrefix(self.font, rest, size, self.inner_w);
            const remaining = std.mem.trimStart(u8, rest[take..], " ");
            const line_index = self.line_count;
            self.add(rest[0..take], size, color);
            if (self.line_count > line_index) {
                self.lines[line_index].bold = spanWithin(styles.bold, offset, take);
                self.lines[line_index].accent = spanWithin(styles.accent, offset, take);
                self.lines[line_index].break_after = remaining.len == 0;
            }
            offset += take + rest[take..].len - remaining.len;
            rest = remaining;
        }
        if (rest.len > 0) self.overflowed = true;
    }

    fn addStoredWrappedStyled(
        self: *TooltipBuilder,
        value: []const u8,
        size: f32,
        color: rl.Color,
        styles: LineStyles,
    ) void {
        if (self.line_count >= self.lines.len) {
            self.overflowed = true;
            return;
        }
        var rest = value;
        var offset: usize = 0;
        while (rest.len > 0 and self.line_count < self.lines.len) {
            const take = wrapPrefix(self.font, rest, size, self.inner_w);
            const remaining = std.mem.trimStart(u8, rest[take..], " ");
            self.lines[self.line_count] = .{
                .text = rest[0..take],
                .size = size,
                .color = color,
                .bold = spanWithin(styles.bold, offset, take),
                .accent = spanWithin(styles.accent, offset, take),
                .break_after = remaining.len == 0,
            };
            self.line_count += 1;
            offset += take + rest[take..].len - remaining.len;
            rest = remaining;
        }
        if (rest.len > 0) self.overflowed = true;
    }
};

/// Upper bound on bytes worth measuring for one wrapped line. Glyphs are at
/// least 1px wide at the sizes Flamez uses, so prefixes longer than `max_width`
/// cannot fit and must not be walked by `measureTextEx`.
pub fn wrapProbeLimit(input_len: usize, max_width: f32) usize {
    const pixel_bound = @as(usize, @intFromFloat(@floor(@max(max_width, 1)))) + 1;
    return @min(input_len, @min(pixel_bound, text.text_buffer_capacity - 1));
}

fn wrapPrefix(font: rl.Font, input: []const u8, size: f32, max_width: f32) usize {
    if (input.len == 0) return 0;
    const measurable_len = wrapProbeLimit(input.len, max_width);
    if (measurable_len == input.len and
        text.measureTextSlice(font, input, size).x <= max_width)
    {
        return input.len;
    }
    var lo: usize = 1;
    var hi: usize = measurable_len;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (text.measureTextSlice(font, input[0..mid], size).x <= max_width) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    var cut = lo;
    if (cut < input.len and cut > 8) {
        var i = cut;
        while (i > cut / 2) {
            i -= 1;
            if (input[i] == ' ' or input[i] == '/' or input[i] == '=') {
                cut = i + 1;
                break;
            }
        }
    }
    return @max(cut, @as(usize, 1));
}

fn addArguments(
    tip: *TooltipBuilder,
    exec: *const tracer.Process.Exec,
    metadata: []const u8,
    arg_count: usize,
    size: f32,
    color: rl.Color,
) void {
    if (tip.line_count >= tip.lines.len) {
        tip.overflowed = true;
        return;
    }
    const remaining = tip.store[tip.store_len..];
    const arguments = if (formatArguments(exec, metadata, arg_count, remaining)) |full|
        full
    else partial_arguments: {
        tip.overflowed = true;
        break :partial_arguments formatArgumentsPrefix(exec, metadata, arg_count, remaining);
    };
    if (arguments.len == 0) {
        tip.overflowed = true;
        return;
    }
    const start = tip.store_len;
    tip.store_len += arguments.len;
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "Command (args: {d}): ", .{arg_count}) catch
        unreachable;
    const argv0_end = prefix.len +| exec.argv0(metadata).len;
    tip.addStoredWrappedStyled(tip.store[start..tip.store_len], size, color, .{
        .bold = .{ .start = 0, .end = "Command".len },
        .accent = .{ .start = prefix.len, .end = argv0_end },
    });
}

fn formatArguments(
    exec: *const tracer.Process.Exec,
    metadata: []const u8,
    arg_count: usize,
    output: []u8,
) ?[]const u8 {
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "Command (args: {d}): ", .{arg_count}) catch
        unreachable;
    const required = std.math.add(usize, prefix.len, exec.args_len) catch return null;
    if (required > output.len) return null;
    @memcpy(output[0..prefix.len], prefix);
    const arguments = exec.copyCmdline(
        metadata,
        output[prefix.len..][0..exec.args_len],
    );
    return output[0 .. prefix.len + arguments.len];
}

fn formatArgumentsPrefix(
    exec: *const tracer.Process.Exec,
    metadata: []const u8,
    arg_count: usize,
    output: []u8,
) []const u8 {
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "Command (args: {d}): ", .{arg_count}) catch
        unreachable;
    if (output.len <= prefix.len) return output[0..0];
    @memcpy(output[0..prefix.len], prefix);
    var len = prefix.len;
    var args = exec.argsIter(metadata);
    var argument_index: usize = 0;
    while (args.next()) |arg| {
        if (argument_index > 0) {
            if (len >= output.len) return output[0..len];
            output[len] = ' ';
            len += 1;
        }
        const take = @min(arg.len, output.len - len);
        @memcpy(output[len..][0..take], arg[0..take]);
        len += take;
        if (take < arg.len) return output[0..len];
        argument_index += 1;
    }
    return output[0..len];
}

/// Font sizes for a process info block. The hover tooltip uses the compact set;
/// the bottom detail pane renders the same lines slightly larger.
pub const InfoSizes = struct {
    title: f32,
    body: f32,
};

pub const BuildOptions = struct {
    include_exec_history: bool = false,
};

pub const InfoLayout = struct {
    timing_line: ?usize = null,
};

/// Formats the only detail row whose value changes while a process is live.
pub fn formatTimingLine(
    process: *const tracer.Process,
    now_ns: u64,
    buffer: []u8,
) []const u8 {
    var duration_buf: [32]u8 = undefined;
    var cpu_buf: [32]u8 = undefined;
    var start_buf: [32]u8 = undefined;
    var end_buf: [32]u8 = undefined;
    const inferred_start = process.origin == .recovered_parent or
        process.origin == .recovered_exec or
        process.origin == .recovered_exit;
    const duration = if (inferred_start and process.origin == .recovered_exit)
        "unknown"
    else
        text.formatDuration(process.durationNs(now_ns), &duration_buf);
    const cpu_partial = process.end_kind == .capture_clipped or
        (process.end_kind == .observed_exit and !process.cpu_final);
    const cpu = text.formatDuration(process.cpu_time_ns, &cpu_buf);
    const average_cores = if (process.durationNs(now_ns) == 0 or inferred_start)
        0
    else
        @as(f64, @floatFromInt(process.cpu_time_ns)) /
            @as(f64, @floatFromInt(process.durationNs(now_ns)));
    const start = if (inferred_start)
        "inferred"
    else
        text.formatDuration(process.start_ns, &start_buf);
    const end = if (process.end_kind == .capture_clipped) capture_edge: {
        var edge_buf: [32]u8 = undefined;
        const at = process.end_ns orelse now_ns;
        break :capture_edge std.fmt.bufPrint(&end_buf, "{s} (edge)", .{
            text.formatDuration(at, &edge_buf),
        }) catch "capture edge";
    } else if (process.end_ns) |at|
        text.formatDuration(at, &end_buf)
    else
        "running";
    const cpu_label: []const u8 = if (cpu_partial) "CPU~" else "CPU";
    return std.fmt.bufPrint(
        buffer,
        "START  {s}  ·  END  {s}  ·  WALL  {s}  ·  {s}  {s}  ·  AVG  {d:.2} CORES",
        .{
            start,
            end,
            duration,
            cpu_label,
            cpu,
            average_cores,
        },
    ) catch "START  —  ·  END  —  ·  WALL  —  ·  CPU  —";
}

fn addExecFields(
    tip: *TooltipBuilder,
    exec: *const tracer.Process.Exec,
    metadata: []const u8,
    size: f32,
) void {
    var wide_buf: [tracer.max_path_len + 128]u8 = undefined;
    if (exec.cwdSlice(metadata).len > 0) {
        const cwd_line = std.fmt.bufPrint(
            &wide_buf,
            "Directory{s}: {s}",
            .{
                if (exec.cwd_truncated) "  (TRUNCATED)" else "",
                exec.cwdSlice(metadata),
            },
        ) catch unreachable;
        tip.addWrappedStyled(cwd_line, size, toRaylibColor(ink), .{
            .bold = .{ .start = 0, .end = "Directory".len },
        });
    }

    // The displayed argument count excludes the program name, but the command
    // itself includes argv[0] so it can be copied and run as shown.
    const arg_count = exec.args_count -| 1;
    if (exec.args_count > 0) {
        addArguments(
            tip,
            exec,
            metadata,
            arg_count,
            size,
            toRaylibColor(ink),
        );
    }
}

fn addExecHeader(
    tip: *TooltipBuilder,
    exec: *const tracer.Process.Exec,
    ordinal: usize,
    size: f32,
) void {
    var start_buf: [32]u8 = undefined;
    var end_buf: [32]u8 = undefined;
    var label_buf: [32]u8 = undefined;
    const start = text.formatDuration(exec.start_ns, &start_buf);
    const end = if (exec.end_ns) |end_ns|
        text.formatDuration(end_ns, &end_buf)
    else
        "running";
    const label = std.fmt.bufPrint(&label_buf, "EXEC {d}", .{ordinal}) catch unreachable;
    var header_buf: [128]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "{s}  ·  START {s}  ·  END {s}",
        .{ label, start, end },
    ) catch unreachable;
    tip.addWrappedStyled(header, size, toRaylibColor(muted), .{
        .bold = .{ .start = 0, .end = label.len },
    });
}

fn addExecHistory(
    tip: *TooltipBuilder,
    process: *const tracer.Process,
    metadata: []const u8,
    sizes: InfoSizes,
) void {
    tip.addWrappedStyled(
        "EXECUTION HISTORY",
        sizes.title,
        toRaylibColor(ink),
        .{ .bold = .{ .start = 0, .end = "EXECUTION HISTORY".len } },
    );
    for (0..process.execCount()) |index| {
        const exec = process.execAt(index);
        addExecHeader(tip, &exec, index + 1, sizes.body);
        addExecFields(tip, &exec, metadata, sizes.body);
    }
}

/// Fills `tip` with styled process information. Detailed callers may include
/// every exec; compact callers receive only the current exec.
pub fn buildProcessInfo(
    tip: *TooltipBuilder,
    session: *const tracer.Session,
    index: usize,
    sizes: InfoSizes,
    options: BuildOptions,
) InfoLayout {
    const process = &session.processes.items[index];
    const metadata = session.metadataBytes();
    var layout = InfoLayout{};
    if (process.parent_pid) |ppid| {
        tip.addFmt(
            "PID  {d}  ·  PPID  {d}  ·  DEPTH  {d}",
            .{
                process.pid,
                ppid,
                process.depth,
            },
            sizes.body,
            toRaylibColor(muted),
        );
    } else {
        tip.addFmt(
            "PID  {d}  ·  PPID  —  ·  DEPTH  {d}",
            .{ process.pid, process.depth },
            sizes.body,
            toRaylibColor(muted),
        );
    }
    if (process.origin != .observed or
        process.end_kind == .capture_clipped or
        session.isIncomplete())
    {
        tip.addFmt(
            "CAPTURE  {s}  ·  END  {s}{s}",
            .{
                switch (process.origin) {
                    .observed => "observed",
                    .recovered_parent => "inferred parent",
                    .recovered_exec => "inferred exec",
                    .recovered_exit => "exit only",
                },
                switch (process.end_kind) {
                    .open => "open",
                    .observed_exit => "observed",
                    .capture_clipped => "capture edge",
                },
                if (session.isIncomplete()) "  ·  SESSION INCOMPLETE" else "",
            },
            sizes.body,
            toRaylibColor(theme.danger),
        );
    }
    var timing_buf: [160]u8 = undefined;
    const timing = formatTimingLine(process, session.timelineNs(), &timing_buf);
    const timing_index = tip.line_count;
    tip.add(timing, sizes.body, toRaylibColor(muted));
    if (tip.line_count > timing_index) layout.timing_line = timing_index;

    if (options.include_exec_history) {
        addExecHistory(tip, process, metadata, sizes);
    } else {
        const exec = process.currentExec();
        addExecFields(tip, &exec, metadata, sizes.body);
    }
    return layout;
}

test "TooltipBuilder interns text into caller storage" {
    const testing = std.testing;
    var store: [64]u8 = undefined;
    var lines: [4]TooltipLine = undefined;
    var tip = TooltipBuilder{
        .font = undefined, // not touched by intern/addFmt
        .inner_w = 100,
        .store = &store,
        .lines = &lines,
    };

    tip.addFmt("pid {d}", .{42}, 12, rl.Color.white);
    tip.add("cwd", 11, rl.Color.white);

    try testing.expectEqual(@as(usize, 2), tip.line_count);
    try testing.expectEqualStrings("pid 42", tip.lines[0].text);
    try testing.expectEqualStrings("cwd", tip.lines[1].text);

    tip.store_len = store.len;
    tip.add("dropped", 12, rl.Color.white);
    try testing.expectEqual(@as(usize, 2), tip.line_count);
    try testing.expect(tip.overflowed);
}

test "text style spans clip and rebase across wrapped lines" {
    const testing = std.testing;

    try testing.expectEqual(
        TextSpan{ .start = 0, .end = 3 },
        spanWithin(.{ .start = 4, .end = 9 }, 4, 3).?,
    );
    try testing.expectEqual(
        TextSpan{ .start = 0, .end = 2 },
        spanWithin(.{ .start = 4, .end = 9 }, 7, 4).?,
    );
    try testing.expect(spanWithin(.{ .start = 4, .end = 9 }, 10, 4) == null);
}

test "wrap probe limit never exceeds the pixel budget" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 81), wrapProbeLimit(10_000, 80));
    try testing.expectEqual(@as(usize, 40), wrapProbeLimit(40, 80));
    try testing.expectEqual(@as(usize, 2), wrapProbeLimit(100, 0));
}

test "timing line reports self CPU and average cores" {
    var process = tracer.Process{ .pid = 7, .start_ns = 0 };
    process.end_ns = 2 * std.time.ns_per_s;
    process.cpu_time_ns = 5 * std.time.ns_per_s;
    var buffer: [192]u8 = undefined;

    const line = formatTimingLine(&process, process.end_ns.?, &buffer);

    try std.testing.expect(std.mem.indexOf(u8, line, "CPU  5.00 s") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "AVG  2.50 CORES") != null);
}

test "timing line labels an unavailable final CPU total as partial" {
    var process = tracer.Process{ .pid = 7, .start_ns = 0 };
    process.end_ns = 2 * std.time.ns_per_s;
    process.end_kind = .observed_exit;
    process.cpu_time_ns = std.time.ns_per_s;
    var buffer: [192]u8 = undefined;

    const partial = formatTimingLine(&process, process.end_ns.?, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, partial, "CPU~  1.00 s") != null);

    process.cpu_final = true;
    const final = formatTimingLine(&process, process.end_ns.?, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, final, "CPU  1.00 s") != null);
}

test "argument prefix fills available storage without requiring the full argv" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var metadata = tracer.Process.MetadataStore.empty;
    defer metadata.deinit(gpa);
    var process = tracer.Process{ .pid = 7 };
    try process.setArgsFromArgv(&metadata, gpa, &.{
        "clang",
        "-c",
        "source file.c",
    });
    const exec = process.currentExec();
    var buffer: [24]u8 = undefined;

    const row = formatArgumentsPrefix(&exec, metadata.items, 2, &buffer);
    try testing.expect(std.mem.startsWith(u8, row, "Command (args: 2): "));
    try testing.expect(row.len == buffer.len);
}

test "argument row joins argv with spaces" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var metadata = tracer.Process.MetadataStore.empty;
    defer metadata.deinit(gpa);
    var process = tracer.Process{ .pid = 7 };
    try process.setArgsFromArgv(&metadata, gpa, &.{
        "clang",
        "-c",
        "source file.c",
    });
    const exec = process.currentExec();
    var buffer: [128]u8 = undefined;

    const row = formatArguments(&exec, metadata.items, 2, &buffer).?;

    try testing.expectEqualStrings("Command (args: 2): clang -c source file.c", row);
}
