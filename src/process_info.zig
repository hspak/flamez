//! Builds the styled key/value info block for one process. Shared verbatim
//! by the hover tooltip and the bottom detail pane; only font sizes differ.

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

pub const TooltipLine = struct {
    text: []const u8,
    size: f32,
    color: rl.Color,
    /// Copying joins wrapped continuations and preserves only logical row breaks.
    break_after: bool = true,
};

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
        self.lines[self.line_count] = .{ .text = stored, .size = size, .color = color };
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
        self.lines[self.line_count] = .{ .text = stored, .size = size, .color = color };
        self.line_count += 1;
    }

    fn addWrapped(self: *TooltipBuilder, value: []const u8, size: f32, color: rl.Color) void {
        if (self.line_count >= self.lines.len) {
            self.overflowed = true;
            return;
        }
        var rest = value;
        while (rest.len > 0 and self.line_count < self.lines.len) {
            const take = wrapPrefix(self.font, rest, size, self.inner_w);
            const remaining = std.mem.trimStart(u8, rest[take..], " ");
            const line_index = self.line_count;
            self.add(rest[0..take], size, color);
            if (self.line_count > line_index) {
                self.lines[line_index].break_after = remaining.len == 0;
            }
            rest = remaining;
        }
        if (rest.len > 0) self.overflowed = true;
    }

    fn addStoredWrapped(
        self: *TooltipBuilder,
        value: []const u8,
        size: f32,
        color: rl.Color,
    ) void {
        if (self.line_count >= self.lines.len) {
            self.overflowed = true;
            return;
        }
        var rest = value;
        while (rest.len > 0 and self.line_count < self.lines.len) {
            const take = wrapPrefix(self.font, rest, size, self.inner_w);
            const remaining = std.mem.trimStart(u8, rest[take..], " ");
            self.lines[self.line_count] = .{
                .text = rest[0..take],
                .size = size,
                .color = color,
                .break_after = remaining.len == 0,
            };
            self.line_count += 1;
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
    process: *const tracer.Process,
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
    const arguments = if (formatArguments(process, metadata, arg_count, remaining)) |full|
        full
    else blk: {
        tip.overflowed = true;
        break :blk formatArgumentsPrefix(process, metadata, arg_count, remaining);
    };
    if (arguments.len == 0) {
        tip.overflowed = true;
        return;
    }
    const start = tip.store_len;
    tip.store_len += arguments.len;
    tip.addStoredWrapped(tip.store[start..tip.store_len], size, color);
}

fn formatArguments(
    process: *const tracer.Process,
    metadata: []const u8,
    arg_count: usize,
    output: []u8,
) ?[]const u8 {
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "ARGS  ({d})  ·  ", .{arg_count}) catch
        unreachable;
    const required = std.math.add(usize, prefix.len, process.args_len) catch return null;
    if (required > output.len) return null;
    @memcpy(output[0..prefix.len], prefix);
    const arguments = process.copyArguments(
        metadata,
        output[prefix.len..][0..process.args_len],
    );
    return output[0 .. prefix.len + arguments.len];
}

fn formatArgumentsPrefix(
    process: *const tracer.Process,
    metadata: []const u8,
    arg_count: usize,
    output: []u8,
) []const u8 {
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "ARGS  ({d})  ·  ", .{arg_count}) catch
        unreachable;
    if (output.len <= prefix.len) return output[0..0];
    @memcpy(output[0..prefix.len], prefix);
    var len = prefix.len;
    var args = process.argsIter(metadata);
    _ = args.next();
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
    const cpu_partial = process.end_kind == .capture_clipped;
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
    const end = if (process.end_kind == .capture_clipped) blk: {
        var edge_buf: [32]u8 = undefined;
        const at = process.end_ns orelse now_ns;
        break :blk std.fmt.bufPrint(&end_buf, "{s} (edge)", .{
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
        .{ start, end, duration, cpu_label, cpu, average_cores },
    ) catch "START  —  ·  END  —  ·  WALL  —  ·  CPU  —";
}

/// Fills `tip` with the styled lines describing `session.processes.items[index]`.
/// Shared verbatim by the hover tooltip and the bottom detail pane.
pub fn buildProcessInfo(
    tip: *TooltipBuilder,
    session: *const tracer.Session,
    index: usize,
    sizes: InfoSizes,
) InfoLayout {
    const process = &session.processes.items[index];
    const metadata = session.metadataBytes();
    var layout = InfoLayout{};

    tip.addFmt("{s}{s}", .{
        process.nameSlice(),
        if (process.name_kind == .other) "  ·  not a process name" else "",
    }, sizes.title, toRaylibColor(ink));
    if (process.parent_pid) |ppid| {
        tip.addFmt(
            "PID  {d}  ·  PPID  {d}  ·  DEPTH  {d}",
            .{ process.pid, ppid, process.depth },
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
        session.incomplete)
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
                if (session.incomplete) "  ·  SESSION INCOMPLETE" else "",
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

    // Process fields are fixed-capacity; the extra bytes cover every inline
    // label and delimiter, so the following formatting cannot overflow.
    var wide_buf: [tracer.max_path_len + 128]u8 = undefined;
    const path = if (process.exeSlice(metadata).len > 0)
        process.exeSlice(metadata)
    else
        process.argv0(metadata);
    if (path.len > 0) {
        const path_line = std.fmt.bufPrint(&wide_buf, "PATH{s}  ·  {s}", .{
            if (process.exe_truncated) "  (TRUNCATED)" else "",
            path,
        }) catch unreachable;
        tip.addWrapped(path_line, sizes.body, toRaylibColor(ink));
    }
    if (process.cwdSlice(metadata).len > 0) {
        const cwd_line = std.fmt.bufPrint(
            &wide_buf,
            "CWD{s}  ·  {s}",
            .{
                if (process.cwd_truncated) "  (TRUNCATED)" else "",
                process.cwdSlice(metadata),
            },
        ) catch unreachable;
        tip.addWrapped(cwd_line, sizes.body, toRaylibColor(ink));
    }

    const arg_count = process.args_count -| 1;
    if (arg_count > 0) {
        addArguments(
            tip,
            process,
            metadata,
            arg_count,
            sizes.body,
            toRaylibColor(ink),
        );
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

test "argument prefix fills available storage without requiring the full argv" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var metadata = tracer.Process.MetadataStore.empty;
    defer metadata.deinit(gpa);
    var process = tracer.Process{ .pid = 7 };
    try process.setArgsFromArgv(&metadata, gpa, &.{ "clang", "-c", "source file.c" });
    var buffer: [24]u8 = undefined;

    const row = formatArgumentsPrefix(&process, metadata.items, 2, &buffer);
    try testing.expect(std.mem.startsWith(u8, row, "ARGS  (2)  ·  "));
    try testing.expect(row.len == buffer.len);
}

test "argument row joins argv with spaces" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var metadata = tracer.Process.MetadataStore.empty;
    defer metadata.deinit(gpa);
    var process = tracer.Process{ .pid = 7 };
    try process.setArgsFromArgv(&metadata, gpa, &.{ "clang", "-c", "source file.c" });
    var buffer: [128]u8 = undefined;

    const row = formatArguments(&process, metadata.items, 2, &buffer).?;

    try testing.expectEqualStrings("ARGS  (2)  ·  -c source file.c", row);
}
