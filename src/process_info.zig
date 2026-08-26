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
const cpu_hot = theme.cpu_hot;

/// Trailing overflow marker when an info block exceeds its row budget.
pub const tooltip_more_marker = "…";

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

fn wrapPrefix(font: rl.Font, input: []const u8, size: f32, max_width: f32) usize {
    if (input.len == 0) return 0;
    // The raylib bridge measures through a fixed sentinel buffer. A visual
    // line cannot approach this limit, so probe long arguments in safe chunks.
    const measurable_len = @min(input.len, text.text_buffer_capacity - 1);
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
    const remaining = tip.store[tip.store_len..];
    const arguments = formatArguments(process, metadata, arg_count, remaining) orelse {
        tip.overflowed = true;
        return;
    };
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
    const duration = text.formatDuration(process.durationNs(now_ns), &duration_buf);
    const cpu = text.formatDuration(process.cpu_time_ns, &cpu_buf);
    const average_cores = if (process.durationNs(now_ns) == 0)
        0
    else
        @as(f64, @floatFromInt(process.cpu_time_ns)) /
            @as(f64, @floatFromInt(process.durationNs(now_ns)));
    const start = text.formatDuration(process.start_ns, &start_buf);
    const end = if (process.end_ns) |at|
        text.formatDuration(at, &end_buf)
    else
        "running";
    return std.fmt.bufPrint(
        buffer,
        "START  {s}  ·  END  {s}  ·  WALL  {s}  ·  CPU  {s}  ·  AVG  {d:.2} CORES",
        .{ start, end, duration, cpu, average_cores },
    ) catch "START  —  ·  END  —  ·  WALL  —  ·  CPU  —";
}

/// Fills `tip` with the styled lines describing `session.processes.items[index]`.
/// Shared verbatim by the hover tooltip and the bottom detail pane.
pub fn buildProcessInfo(
    tip: *TooltipBuilder,
    session: *const tracer.Session,
    index: usize,
    sizes: InfoSizes,
    cpu_slice_index: ?usize,
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
    var timing_buf: [160]u8 = undefined;
    const timing = formatTimingLine(process, session.timelineNs(), &timing_buf);
    const timing_index = tip.line_count;
    tip.add(timing, sizes.body, toRaylibColor(muted));
    if (tip.line_count > timing_index) layout.timing_line = timing_index;

    if (cpu_slice_index) |slice_index| {
        if (slice_index < process.cpu_slices.items.len) {
            const slice = process.cpu_slices.items[slice_index];
            var slice_start_buf: [32]u8 = undefined;
            var slice_end_buf: [32]u8 = undefined;
            var slice_wall_buf: [32]u8 = undefined;
            var slice_cpu_buf: [32]u8 = undefined;
            tip.addFmt(
                "CPU SLICE  {s}–{s}  ·  WALL  {s}  ·  CPU  {s}  ·  AVG  {d:.2} CORES",
                .{
                    text.formatDuration(slice.start_ns, &slice_start_buf),
                    text.formatDuration(slice.end_ns, &slice_end_buf),
                    text.formatDuration(slice.durationNs(), &slice_wall_buf),
                    text.formatDuration(slice.cpu_ns, &slice_cpu_buf),
                    slice.averageCores(),
                },
                sizes.body,
                toRaylibColor(cpu_hot),
            );
        }
    }

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

test "timing line reports self CPU and average cores" {
    var process = tracer.Process{ .pid = 7, .start_ns = 0 };
    process.end_ns = 2 * std.time.ns_per_s;
    process.cpu_time_ns = 5 * std.time.ns_per_s;
    var buffer: [192]u8 = undefined;

    const line = formatTimingLine(&process, process.end_ns.?, &buffer);

    try std.testing.expect(std.mem.indexOf(u8, line, "CPU  5.00 s") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "AVG  2.50 CORES") != null);
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
