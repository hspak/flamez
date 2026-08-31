//! Selected-process detail and hover-tooltip rendering.

const std = @import("std");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.detail_pane);

const clay = @import("zclay");
const rl = @import("raylib");
const App = @import("App.zig");
const page_layout = @import("layout.zig");
const process_info = @import("process_info.zig");
const text = @import("text.zig");
const theme = @import("theme.zig");
const tracer = @import("tracer.zig");

const TooltipLine = process_info.TooltipLine;
const TooltipBuilder = process_info.TooltipBuilder;
const InfoSizes = process_info.InfoSizes;
const buildProcessInfo = process_info.buildProcessInfo;
const tooltip_more_marker = process_info.tooltip_more_marker;
const tooltip_max_rows = process_info.tooltip_max_rows;

const scrollbar_width: f32 = 12;
const tooltip_max_width: f32 = 560;
const tooltip_corner_radius: f32 = 4;
const canvas = theme.canvas;
const accent = theme.accent;
const cpu_hot = theme.cpu_hot;
const panel_raised = theme.panel_raised;
const border = theme.border;
const danger = theme.danger;
const faint = theme.faint;
const ink = theme.ink;
const muted = theme.muted;
const toRaylibColor = theme.toRaylibColor;
const drawClippedAt = text.drawClippedAt;
const drawTextSlice = text.drawTextSlice;
const drawTextSliceClipped = text.drawTextSliceClipped;
const formatDuration = text.formatDuration;
const measureTextSlice = text.measureTextSlice;

pub const Input = struct {
    font: rl.Font,
    bold_font: rl.Font,
    mouse: rl.Vector2,
    wheel: f32,
    clicked: bool,
    host_cpu_count: usize,
};

pub fn ratio(numerator: usize, denominator: usize) f32 {
    if (denominator == 0) return 0;
    const numerator_f: f64 = @floatFromInt(numerator);
    const denominator_f: f64 = @floatFromInt(denominator);
    return @floatCast(numerator_f / denominator_f);
}

const detail_line_gap: f32 = 5;
const detail_min_line_glyphs: usize = 8;
const detail_cpu_graph_height: f32 = 174;
const detail_cpu_graph_gap: f32 = 16;
const detail_cpu_graph_label_size: f32 = 12;
const detail_resize_handle_height: f32 = 8;
const detail_min_height: f32 = 160;
const timeline_min_height: f32 = 180;

const tooltip_sizes = InfoSizes{ .title = 14, .body = 13 };
const detail_sizes = InfoSizes{ .title = 16, .body = 15 };
const DetailTextPosition = App.DetailTextPosition;

const DetailTextSelection = struct {
    start: DetailTextPosition,
    end: DetailTextPosition,
};

const DetailCapacity = struct {
    store: usize,
    lines: usize,
};

pub const CpuGraphRange = struct {
    start_ns: u64,
    end_ns: u64,

    pub fn spanNs(self: CpuGraphRange) u64 {
        return @max(self.end_ns -| self.start_ns, 1);
    }
};

fn detailCapacity(process: *const tracer.Process, metadata: []const u8) DetailCapacity {
    const path_bytes = process.exeSlice(metadata).len +| process.cwdSlice(metadata).len;
    const store = process.args_len +| process.args_count +| path_bytes +| 1024;
    const wrapped_args = process.args_len / detail_min_line_glyphs;
    const wrapped_paths = path_bytes / detail_min_line_glyphs;
    const lines = 64 +| wrapped_args +| process.args_count +| wrapped_paths;
    return .{
        .store = store,
        .lines = lines,
    };
}

pub fn detailCpuGraphRange(process: *const tracer.Process, now_ns: u64) CpuGraphRange {
    return .{
        .start_ns = process.start_ns,
        .end_ns = @max(process.start_ns, process.end_ns orelse now_ns),
    };
}

pub fn detailCpuGraphCoreScale(process: *const tracer.Process, host_cpu_count: usize) f64 {
    var observed_cores = process.cpu_peak_cores;
    if (observed_cores <= 0) {
        for (process.cpu_slices.items) |slice| {
            observed_cores = @max(observed_cores, slice.averageCores());
        }
    }
    const host_cores: f64 = @floatFromInt(@max(host_cpu_count, 1));
    return @min(@ceil(@max(observed_cores, 1)), host_cores);
}

pub fn detailCpuGraphX(range: CpuGraphRange, at_ns: u64, plot: rl.Rectangle) f32 {
    const clipped_ns = std.math.clamp(at_ns, range.start_ns, range.end_ns);
    const offset: f64 = @floatFromInt(clipped_ns -| range.start_ns);
    const span: f64 = @floatFromInt(range.spanNs());
    return plot.x + plot.width * @as(f32, @floatCast(offset / span));
}

fn detailCpuGraphY(cores: f64, core_scale: f64, plot: rl.Rectangle) f32 {
    const fraction = std.math.clamp(cores / core_scale, 0, 1);
    return plot.y + plot.height * (1 - @as(f32, @floatCast(fraction)));
}

fn drawDetailCpuGraphText(
    font: rl.Font,
    value: []const u8,
    position: rl.Vector2,
    size: f32,
    color: rl.Color,
) void {
    drawTextSlice(font, value, .{
        .x = @round(position.x),
        .y = @round(position.y),
    }, size, color);
}

fn drawDetailCpuGraph(
    app: *App,
    process: *const tracer.Process,
    process_index: usize,
    now_ns: u64,
    host_cpu_count: usize,
    font: rl.Font,
    card: rl.Rectangle,
) Allocator.Error!void {
    rl.drawRectangleRounded(card, 0.04, 4, toRaylibColor(panel_raised));
    rl.drawRectangleRoundedLinesEx(card, 0.04, 4, 1, toRaylibColor(border));

    drawDetailCpuGraphText(
        font,
        "THREAD CPU",
        .{ .x = card.x + 10, .y = card.y + 8 },
        detail_cpu_graph_label_size,
        toRaylibColor(ink),
    );
    const core_scale = detailCpuGraphCoreScale(process, host_cpu_count);
    var scale_buffer: [32]u8 = undefined;
    const scale_label = std.fmt.bufPrint(
        &scale_buffer,
        "0–{d:.0} CORES",
        .{core_scale},
    ) catch "CORES";
    const scale_size = measureTextSlice(font, scale_label, detail_cpu_graph_label_size);
    drawDetailCpuGraphText(
        font,
        scale_label,
        .{ .x = card.x + card.width - scale_size.x - 10, .y = card.y + 8 },
        detail_cpu_graph_label_size,
        toRaylibColor(cpu_hot),
    );
    drawTextSliceClipped(
        "ALL THREADS · FULL PROCESS RANGE · SESSION TIME",
        .{
            .font = font,
            .position = .{ .x = @round(card.x + 10), .y = @round(card.y + 25) },
            .size = detail_cpu_graph_label_size,
            .color = toRaylibColor(faint),
            .max_width = card.width - 20,
        },
    );

    const plot = rl.Rectangle.init(card.x + 42, card.y + 49, card.width - 52, 88);
    rl.drawRectangleRec(plot, toRaylibColor(canvas));
    const grid_color = toRaylibColor(border);
    for (0..3) |tick| {
        const fraction = @as(f32, @floatFromInt(tick)) / 2;
        const y = plot.y + plot.height * fraction;
        rl.drawLineEx(
            .{ .x = plot.x, .y = y },
            .{ .x = plot.x + plot.width, .y = y },
            1,
            grid_color,
        );
        const x = plot.x + plot.width * fraction;
        rl.drawLineEx(
            .{ .x = x, .y = plot.y },
            .{ .x = x, .y = plot.y + plot.height },
            1,
            grid_color,
        );
    }

    var top_core_buffer: [16]u8 = undefined;
    const top_core = std.fmt.bufPrint(&top_core_buffer, "{d:.0}", .{core_scale}) catch "";
    const top_core_size = measureTextSlice(font, top_core, detail_cpu_graph_label_size);
    drawDetailCpuGraphText(
        font,
        top_core,
        .{ .x = plot.x - top_core_size.x - 7, .y = plot.y - top_core_size.y / 2 },
        detail_cpu_graph_label_size,
        toRaylibColor(muted),
    );
    const zero_size = measureTextSlice(font, "0", detail_cpu_graph_label_size);
    drawDetailCpuGraphText(
        font,
        "0",
        .{
            .x = plot.x - zero_size.x - 7,
            .y = plot.y + plot.height - zero_size.y / 2,
        },
        detail_cpu_graph_label_size,
        toRaylibColor(muted),
    );

    const range = detailCpuGraphRange(process, now_ns);
    const baseline_y = plot.y + plot.height;
    const fill_color = toRaylibColor(cpu_hot);
    const area_color = rl.Color.init(fill_color.r, fill_color.g, fill_color.b, 58);
    const width = @max(1, @as(usize, @intFromFloat(@floor(plot.width))));
    const rebuild_columns = app.graph_cache_process != process_index or
        app.graph_cache_process_revision != process.revision or
        app.graph_cache_start_ns != range.start_ns or
        app.graph_cache_end_ns != range.end_ns or
        app.graph_cache_width != width;
    if (rebuild_columns) {
        try app.graph_columns.resize(app.gpa, width);
        @memset(app.graph_columns.items, -1);
        const first = tracer.Process.firstVisibleSlice(
            process.cpu_slices.items,
            range.start_ns,
            range.end_ns,
        );
        for (process.cpu_slices.items[first..]) |slice| {
            if (slice.start_ns >= range.end_ns) break;
            if (slice.end_ns <= range.start_ns) continue;
            const start_ns = @max(slice.start_ns, range.start_ns);
            const end_ns = @min(slice.end_ns, range.end_ns);
            if (end_ns <= start_ns) continue;
            const start_x = detailCpuGraphX(range, start_ns, plot);
            const end_x = detailCpuGraphX(range, end_ns, plot);
            var px0: usize = 0;
            if (start_x > plot.x) {
                px0 = @min(width, @as(usize, @intFromFloat(@floor(start_x - plot.x))));
            }
            var px1: usize = width;
            if (end_x > plot.x) {
                px1 = @min(width, @as(usize, @intFromFloat(@ceil(end_x - plot.x))));
            }
            if (px1 <= px0) px1 = @min(width, px0 + 1);
            const cores: f32 = @floatCast(slice.averageCores());
            for (px0..px1) |px| {
                app.graph_columns.items[px] = @max(app.graph_columns.items[px], cores);
            }
        }
        app.graph_cache_process = process_index;
        app.graph_cache_process_revision = process.revision;
        app.graph_cache_start_ns = range.start_ns;
        app.graph_cache_end_ns = range.end_ns;
        app.graph_cache_width = width;
    }
    var drew_slice = false;
    var col: usize = 0;
    while (col < width) {
        const cores = app.graph_columns.items[col];
        var run: usize = 1;
        while (col + run < width and app.graph_columns.items[col + run] == cores) run += 1;
        if (cores > 0) {
            const start_x = plot.x + @as(f32, @floatFromInt(col));
            const end_x = plot.x + @as(f32, @floatFromInt(col + run));
            const y = detailCpuGraphY(@floatCast(cores), core_scale, plot);
            rl.drawRectangleRec(
                .init(start_x, y, @max(1, end_x - start_x), baseline_y - y),
                area_color,
            );
            rl.drawLineEx(
                .{ .x = start_x, .y = y },
                .{ .x = end_x, .y = y },
                2,
                fill_color,
            );
            rl.drawLineEx(
                .{ .x = start_x, .y = baseline_y },
                .{ .x = start_x, .y = y },
                2,
                fill_color,
            );
            rl.drawLineEx(
                .{ .x = end_x, .y = y },
                .{ .x = end_x, .y = baseline_y },
                2,
                fill_color,
            );
            drew_slice = true;
        }
        col += run;
    }
    if (!drew_slice) {
        const no_samples = "NO CPU SAMPLES";
        const no_samples_size = measureTextSlice(font, no_samples, detail_cpu_graph_label_size);
        drawDetailCpuGraphText(
            font,
            no_samples,
            .{
                .x = plot.x + (plot.width - no_samples_size.x) / 2,
                .y = plot.y + (plot.height - no_samples_size.y) / 2,
            },
            detail_cpu_graph_label_size,
            toRaylibColor(faint),
        );
    }

    const middle_ns = range.start_ns + range.spanNs() / 2;
    var start_label_buffer: [48]u8 = undefined;
    var start_time_buffer: [32]u8 = undefined;
    var middle_buffer: [48]u8 = undefined;
    var end_label_buffer: [48]u8 = undefined;
    var end_time_buffer: [32]u8 = undefined;
    const start_label = std.fmt.bufPrint(
        &start_label_buffer,
        "START {s}",
        .{formatDuration(range.start_ns, &start_time_buffer)},
    ) catch "START";
    const middle_label = formatDuration(middle_ns, &middle_buffer);
    const end_label = std.fmt.bufPrint(
        &end_label_buffer,
        "END {s}",
        .{formatDuration(range.end_ns, &end_time_buffer)},
    ) catch "END";
    const label_y = plot.y + plot.height + 8;
    drawDetailCpuGraphText(
        font,
        start_label,
        .{ .x = plot.x, .y = label_y },
        detail_cpu_graph_label_size,
        toRaylibColor(muted),
    );
    if (plot.width >= 300) {
        const middle_size = measureTextSlice(font, middle_label, detail_cpu_graph_label_size);
        drawDetailCpuGraphText(
            font,
            middle_label,
            .{ .x = plot.x + (plot.width - middle_size.x) / 2, .y = label_y },
            detail_cpu_graph_label_size,
            toRaylibColor(muted),
        );
    }
    const end_size = measureTextSlice(font, end_label, detail_cpu_graph_label_size);
    drawDetailCpuGraphText(
        font,
        end_label,
        .{ .x = plot.x + plot.width - end_size.x, .y = label_y },
        detail_cpu_graph_label_size,
        toRaylibColor(muted),
    );
}

pub fn renderTooltip(
    app: *App,
    session: *const tracer.Session,
    index: usize,
    font: rl.Font,
    mouse: rl.Vector2,
) void {
    const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
    const box_w = @min(tooltip_max_width, screen_w - 40);
    const inner_w = box_w - 20;
    const process = &session.processes.items[index];
    const line_gap: f32 = 4;

    const cache_hit = app.tooltip_cache_process == index and
        app.tooltip_cache_revision == process.revision and
        @abs(app.tooltip_cache_width - inner_w) <= 0.5;
    if (!cache_hit) {
        var tip = TooltipBuilder{
            .font = font,
            .inner_w = inner_w,
            .store = &app.tooltip_store,
            .lines = &app.tooltip_lines,
        };
        const layout = buildProcessInfo(
            &tip,
            session,
            index,
            tooltip_sizes,
        );
        app.tooltip_line_count = tip.line_count;
        app.tooltip_overflowed = tip.overflowed;
        app.tooltip_timing_line = layout.timing_line;
        var shown = tip.line_count;
        var truncated = tip.overflowed;
        if (shown > tooltip_max_rows or (truncated and shown == tooltip_max_rows)) {
            shown = tooltip_max_rows - 1;
            truncated = true;
        }
        var content_h: f32 = 0;
        for (app.tooltip_lines[0..shown], 0..) |line, line_index| {
            const measured = measureTextSlice(
                font,
                if (line.text.len == 0) " " else line.text,
                line.size,
            );
            app.tooltip_row_heights[line_index] = measured.y;
            content_h += measured.y + line_gap;
        }
        if (truncated) {
            content_h += measureTextSlice(font, tooltip_more_marker, tooltip_sizes.body).y +
                line_gap;
        }
        app.tooltip_shown = shown;
        app.tooltip_truncated = truncated;
        app.tooltip_content_h = content_h;
        app.tooltip_cache_process = index;
        app.tooltip_cache_revision = process.revision;
        app.tooltip_cache_width = inner_w;
    }

    if (app.tooltip_timing_line) |timing_index| {
        if (timing_index < app.tooltip_shown) {
            const timing = process_info.formatTimingLine(
                process,
                session.timelineNs(),
                &app.tooltip_timing,
            );
            app.tooltip_timing_len = timing.len;
            app.tooltip_lines[timing_index].text = app.tooltip_timing[0..app.tooltip_timing_len];
        }
    }

    const box_h = @min(app.tooltip_content_h + 16, screen_h - 16);
    var x = mouse.x + 14;
    var y = mouse.y + 14;
    if (x + box_w > screen_w) x = @max(8, mouse.x - box_w - 12);
    if (y + box_h + 8 > screen_h) y = @max(8, screen_h - box_h - 8);
    const tooltip = rl.Rectangle.init(x, y, box_w, box_h);
    const roundness = rectangleRoundness(
        .{
            .x = x,
            .y = y,
            .width = box_w,
            .height = box_h,
        },
        tooltip_corner_radius,
    );
    rl.drawRectangleRounded(tooltip, roundness, 4, toRaylibColor(panel_raised));
    rl.drawRectangleRoundedLinesEx(tooltip, roundness, 4, 1, toRaylibColor(border));
    rl.beginScissorMode(
        @intFromFloat(x + 1),
        @intFromFloat(y + 1),
        @intFromFloat(box_w - 2),
        @intFromFloat(box_h - 2),
    );
    var text_y = y + 8;
    for (app.tooltip_lines[0..app.tooltip_shown], 0..) |line, line_index| {
        if (text_y > y + box_h - 8) break;
        drawTextSlice(font, line.text, .{ .x = x + 10, .y = text_y }, line.size, line.color);
        text_y += app.tooltip_row_heights[line_index] + line_gap;
    }
    if (app.tooltip_truncated and text_y <= y + box_h - 8) {
        drawTextSlice(
            font,
            tooltip_more_marker,
            .{ .x = x + 10, .y = text_y },
            tooltip_sizes.body,
            toRaylibColor(muted),
        );
    }
    rl.endScissorMode();
}

fn thumbOffset(travel: f32, max_scroll: f32, scroll: f32) f32 {
    if (travel <= 0 or max_scroll <= 0) return 0;
    return travel * scroll / max_scroll;
}

fn jumpToScroll(jumped: f32, travel: f32, max_scroll: f32) f32 {
    if (travel <= 0) return 0;
    return jumped / travel * max_scroll;
}

fn clearDetailTextSelection(app: *App) void {
    app.detail_selection_anchor = null;
    app.detail_selection_focus = null;
    app.detail_text_selecting = false;
    app.detail_text_focused = false;
}

fn utf8FloorBoundary(value: []const u8, byte_index: usize) usize {
    var index = @min(byte_index, value.len);
    while (index > 0 and index < value.len and (value[index] & 0xc0) == 0x80) index -= 1;
    return index;
}

fn measureDetailLinePrefix(
    font: rl.Font,
    bold_font: rl.Font,
    line: TooltipLine,
    byte_index: usize,
) f32 {
    const end = @min(byte_index, line.text.len);
    const bold = line.bold orelse return measureTextSlice(font, line.text[0..end], line.size).x;
    var width: f32 = 0;
    const before_end = @min(end, bold.start);
    if (before_end > 0) {
        width += measureTextSlice(font, line.text[0..before_end], line.size).x;
    }
    if (end > bold.start) {
        const bold_end = @min(end, bold.end);
        width += measureTextSlice(bold_font, line.text[bold.start..bold_end], line.size).x;
    }
    if (end > bold.end) {
        width += measureTextSlice(font, line.text[bold.end..end], line.size).x;
    }
    return width;
}

fn detailLineHeight(font: rl.Font, bold_font: rl.Font, line: TooltipLine) f32 {
    const regular_height = measureTextSlice(
        font,
        if (line.text.len == 0) " " else line.text,
        line.size,
    ).y;
    const bold = line.bold orelse return regular_height;
    return @max(
        regular_height,
        measureTextSlice(bold_font, line.text[bold.start..bold.end], line.size).y,
    );
}

fn drawDetailLinePart(
    font: rl.Font,
    value: []const u8,
    x: *f32,
    y: f32,
    size: f32,
    color: rl.Color,
) void {
    if (value.len == 0) return;
    drawTextSlice(font, value, .{ .x = x.*, .y = y }, size, color);
    x.* += measureTextSlice(font, value, size).x;
}

fn drawDetailLine(
    font: rl.Font,
    bold_font: rl.Font,
    line: TooltipLine,
    position: rl.Vector2,
) void {
    var x = position.x;
    var byte_index: usize = 0;
    if (line.bold) |bold| {
        drawDetailLinePart(
            font,
            line.text[byte_index..bold.start],
            &x,
            position.y,
            line.size,
            line.color,
        );
        drawDetailLinePart(
            bold_font,
            line.text[bold.start..bold.end],
            &x,
            position.y,
            line.size,
            line.color,
        );
        byte_index = bold.end;
    }
    if (line.accent) |highlight| {
        std.debug.assert(byte_index <= highlight.start);
        drawDetailLinePart(
            font,
            line.text[byte_index..highlight.start],
            &x,
            position.y,
            line.size,
            line.color,
        );
        drawDetailLinePart(
            font,
            line.text[highlight.start..highlight.end],
            &x,
            position.y,
            line.size,
            toRaylibColor(accent),
        );
        byte_index = highlight.end;
    }
    drawDetailLinePart(
        font,
        line.text[byte_index..],
        &x,
        position.y,
        line.size,
        line.color,
    );
}

fn detailByteAtX(font: rl.Font, bold_font: rl.Font, line: TooltipLine, x: f32) usize {
    if (x <= 0 or line.text.len == 0) return 0;
    if (measureDetailLinePrefix(font, bold_font, line, line.text.len) <= x) return line.text.len;
    var low: usize = 0;
    var high = line.text.len;
    while (low < high) {
        const middle = low + (high - low + 1) / 2;
        if (measureDetailLinePrefix(font, bold_font, line, middle) <= x) {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    return utf8FloorBoundary(line.text, low);
}

fn detailPositionAt(
    app: *const App,
    font: rl.Font,
    bold_font: rl.Font,
    mouse: rl.Vector2,
    content: clay.BoundingBox,
    pad: f32,
    leading_height: f32,
) ?DetailTextPosition {
    if (app.detail_line_count == 0) return null;
    const local_x = mouse.x - (content.x + pad);
    const local_y = mouse.y -
        (content.y + pad + leading_height - app.detail_scroll_px);
    if (local_y <= 0) return .{
        .line = 0,
        .byte = detailByteAtX(font, bold_font, app.detail_lines[0], local_x),
    };

    var line_top: f32 = 0;
    for (app.detail_lines[0..app.detail_line_count], 0..) |line, line_index| {
        const line_height = app.detail_line_heights[line_index];
        if (local_y < line_top + line_height + detail_line_gap) {
            return .{
                .line = line_index,
                .byte = if (local_y > line_top + line_height)
                    line.text.len
                else
                    detailByteAtX(font, bold_font, line, local_x),
            };
        }
        line_top += line_height + detail_line_gap;
    }
    const last_index = app.detail_line_count - 1;
    return .{ .line = last_index, .byte = app.detail_lines[last_index].text.len };
}

fn detailPositionBefore(a: DetailTextPosition, b: DetailTextPosition) bool {
    return a.line < b.line or (a.line == b.line and a.byte < b.byte);
}

fn clampDetailPosition(app: *const App, position: DetailTextPosition) DetailTextPosition {
    const line = @min(position.line, app.detail_line_count - 1);
    const text_value = app.detail_lines[line].text;
    return .{
        .line = line,
        .byte = utf8FloorBoundary(text_value, @min(position.byte, text_value.len)),
    };
}

fn detailTextSelection(app: *const App) ?DetailTextSelection {
    if (app.detail_line_count == 0) return null;
    const anchor = clampDetailPosition(app, app.detail_selection_anchor orelse return null);
    const focus = clampDetailPosition(app, app.detail_selection_focus orelse return null);
    if (anchor.line == focus.line and anchor.byte == focus.byte) return null;
    return if (detailPositionBefore(anchor, focus))
        .{ .start = anchor, .end = focus }
    else
        .{ .start = focus, .end = anchor };
}

fn copyDetailTextSelection(app: *App) void {
    const selection = detailTextSelection(app) orelse return;
    var needed: usize = 1;
    for (selection.start.line..selection.end.line + 1) |line_index| {
        const line = app.detail_lines[line_index];
        const start = if (line_index == selection.start.line) selection.start.byte else 0;
        const end = if (line_index == selection.end.line) selection.end.byte else line.text.len;
        needed += end - start;
        if (line_index < selection.end.line and line.break_after) needed += 1;
    }
    app.ensureClipboardCapacity(needed) catch return;
    var clipboard_len: usize = 0;
    for (selection.start.line..selection.end.line + 1) |line_index| {
        const line = app.detail_lines[line_index];
        const start = if (line_index == selection.start.line) selection.start.byte else 0;
        const end = if (line_index == selection.end.line) selection.end.byte else line.text.len;
        const amount = end - start;
        @memcpy(
            app.detail_clipboard[clipboard_len..][0..amount],
            line.text[start..][0..amount],
        );
        clipboard_len += amount;
        if (line_index < selection.end.line and line.break_after) {
            app.detail_clipboard[clipboard_len] = '\n';
            clipboard_len += 1;
        }
    }
    if (clipboard_len == 0) return;
    app.detail_clipboard[clipboard_len] = 0;
    rl.setClipboardText(app.detail_clipboard[0..clipboard_len :0]);
}

fn drawDetailTextSelection(
    app: *const App,
    selection: ?DetailTextSelection,
    font: rl.Font,
    bold_font: rl.Font,
    line_index: usize,
    text_x: f32,
    text_y: f32,
    line_height: f32,
) void {
    const selected = selection orelse return;
    if (line_index < selected.start.line or line_index > selected.end.line) return;
    const line = app.detail_lines[line_index];
    const start = if (line_index == selected.start.line) selected.start.byte else 0;
    const end = if (line_index == selected.end.line) selected.end.byte else line.text.len;
    if (start >= end) return;
    const start_x = measureDetailLinePrefix(font, bold_font, line, start);
    const end_x = measureDetailLinePrefix(font, bold_font, line, end);
    rl.drawRectangleRec(
        .init(text_x + start_x, text_y, @max(1, end_x - start_x), line_height),
        rl.Color.init(55, 105, 170, 170),
    );
}

fn drawDetailCloseButton(font: rl.Font, mouse: rl.Vector2, box: clay.BoundingBox) void {
    const hovered = pointInBox(mouse, box);
    const color = toRaylibColor(if (hovered) danger else border);
    const button = rl.Rectangle.init(box.x, box.y, box.width, box.height);
    rl.drawRectangleRounded(button, 0.25, 4, color);

    const label = "X";
    const measured = measureTextSlice(font, label, 11);
    drawTextSlice(font, label, .{
        .x = box.x + (box.width - measured.x) / 2,
        .y = box.y + (box.height - measured.y) / 2,
    }, 11, if (hovered) toRaylibColor(canvas) else toRaylibColor(ink));
}

fn ctrlHeld() bool {
    return rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
}

fn pointInBox(point: rl.Vector2, box: clay.BoundingBox) bool {
    return point.x >= box.x and point.x <= box.x + box.width and
        point.y >= box.y and point.y <= box.y + box.height;
}

fn rectangleRoundness(box: clay.BoundingBox, radius: f32) f32 {
    const shortest_side = @min(box.width, box.height);
    return if (shortest_side > 0) @min(1, (radius * 2) / shortest_side) else 0;
}

pub fn render(
    app: *App,
    session: *const tracer.Session,
    input: Input,
) Allocator.Error!void {
    const font = input.font;
    const bold_font = input.bold_font;
    const mouse = input.mouse;
    const wheel = input.wheel;
    const clicked = input.clicked;
    const selected = app.selected_process;
    if (selected == null) {
        // No selection: the pane is absent from this frame's layout as well.
        // Drop stale scroll state so a fresh selection starts at the top.
        app.detail_for = null;
        app.detail_scroll_px = 0;
        app.detail_dragging = false;
        clearDetailTextSelection(app);
        return;
    }
    // Processes are never removed from a session, but stay defensive.
    if (selected.? >= session.processes.items.len) {
        app.selected_process = null;
        clearDetailTextSelection(app);
        return;
    }
    const element = clay.getElementData(.ID("DetailPane"));
    if (!element.found) return; // pane joins the layout on the frame after a click
    const box = element.bounding_box;
    if (box.width < 80 or box.height < 80) return;
    const resize_handle = clay.BoundingBox{
        .x = box.x,
        .y = box.y - detail_resize_handle_height / 2,
        .width = box.width,
        .height = detail_resize_handle_height,
    };
    const over_resize_handle = pointInBox(mouse, resize_handle);
    const left_down = rl.isMouseButtonDown(.left);
    if (!left_down) app.detail_resize_dragging = false;
    if (app.detail_resize_dragging or over_resize_handle) rl.setMouseCursor(.resize_ns);
    if (clicked and over_resize_handle) {
        app.detail_resize_dragging = true;
        app.detail_dragging = false;
        app.detail_text_selecting = false;
        app.detail_text_focused = false;
    }
    if (app.detail_resize_dragging) {
        const page_height = @as(f32, @floatFromInt(rl.getScreenHeight())) -
            page_layout.process_row_height;
        const max_height = @max(detail_min_height, page_height - timeline_min_height - 1);
        app.detail_pane_height = std.math.clamp(
            box.y + box.height - mouse.y,
            detail_min_height,
            max_height,
        );
    }
    const close_element = clay.getElementData(.ID("DetailCloseButton"));
    const close_box = if (close_element.found)
        close_element.bounding_box
    else
        clay.BoundingBox{
            .x = box.x + box.width - 28,
            .y = box.y + 11,
            .width = 20,
            .height = 20,
        };

    const header_height: f32 = 42;
    const pad: f32 = 12;
    const content = clay.BoundingBox{
        .x = box.x + 1,
        .y = box.y + header_height,
        .width = box.width - 2,
        .height = @max(0, box.height - header_height - 1),
    };

    rl.drawRectangleRec(
        .init(box.x, box.y, box.width, header_height),
        toRaylibColor(panel_raised),
    );
    rl.drawRectangleRec(
        .init(box.x, box.y - 1, box.width, 2),
        toRaylibColor(if (app.detail_resize_dragging or over_resize_handle)
            .{
                92,
                151,
                255,
                255,
            }
        else
            border),
    );
    const header_title = "PROCESS DETAILS";
    const header_title_size = measureTextSlice(font, header_title, 12);
    drawTextSlice(
        font,
        header_title,
        .{
            .x = box.x + pad,
            .y = box.y + (header_height - header_title_size.y) / 2,
        },
        12,
        toRaylibColor(muted),
    );
    const index = selected.?;

    // Restart at the top whenever the inspected process changes.
    if (app.detail_for != selected) {
        app.detail_for = selected;
        app.detail_scroll_px = 0;
        clearDetailTextSelection(app);
    }

    const process = &session.processes.items[index];
    const capacities = detailCapacity(process, session.metadataBytes());
    try app.ensureDetailCapacity(
        capacities.store,
        capacities.lines,
    );
    const inner_w = @max(120, content.width - pad * 2 - scrollbar_width - 6);
    const rebuild_detail = app.detail_cache_process != selected or
        app.detail_cache_revision != process.revision or
        @abs(app.detail_cache_width - inner_w) > 0.5;
    if (rebuild_detail) {
        clearDetailTextSelection(app);
        // Heap-backed builder storage sized in App.init: rebuild only when
        // selection, metadata, lifetime state, or wrapping width changes.
        while (true) {
            var tip = TooltipBuilder{
                .font = font,
                .inner_w = inner_w,
                .store = app.detail_store,
                .lines = app.detail_lines,
            };
            const layout = buildProcessInfo(&tip, session, index, detail_sizes);
            if (!tip.overflowed) {
                app.detail_line_count = tip.line_count;
                app.detail_timing_line = layout.timing_line;
                break;
            }
            const store_capacity = std.math.mul(
                usize,
                app.detail_store.len,
                2,
            ) catch return error.OutOfMemory;
            const line_capacity = std.math.mul(
                usize,
                app.detail_lines.len,
                2,
            ) catch return error.OutOfMemory;
            try app.ensureDetailCapacity(
                store_capacity,
                line_capacity,
            );
        }
        app.detail_cache_process = selected;
        app.detail_cache_revision = process.revision;
        app.detail_cache_width = inner_w;
        app.detail_content_height = 0;
        for (app.detail_lines[0..app.detail_line_count], 0..) |line, line_index| {
            const line_height = detailLineHeight(font, bold_font, line);
            app.detail_line_heights[line_index] = line_height;
            app.detail_content_height += line_height + detail_line_gap;
        }
    }
    const timing = process_info.formatTimingLine(
        process,
        session.timelineNs(),
        &app.detail_timing,
    );
    app.detail_timing_len = timing.len;
    if (app.detail_timing_line) |timing_index| {
        if (timing_index < app.detail_line_count) {
            app.detail_lines[timing_index].text = app.detail_timing[0..app.detail_timing_len];
        }
    }

    const leading_height = detail_cpu_graph_height + detail_cpu_graph_gap;
    const content_h = leading_height + app.detail_content_height;
    const view_h = @max(0, content.height - pad * 2);
    const max_scroll = @max(0, content_h - view_h);
    const needs_scrollbar = max_scroll > 0;

    const track = clay.BoundingBox{
        .x = box.x + box.width - scrollbar_width - 6,
        .y = content.y + 6,
        .width = scrollbar_width,
        .height = @max(0, content.height - 12),
    };
    const thumb_height = if (needs_scrollbar)
        @max(24, track.height * view_h / content_h)
    else
        track.height;
    const thumb_travel = @max(0, track.height - thumb_height);
    const over_track = needs_scrollbar and pointInBox(mouse, track);
    const over_content = pointInBox(mouse, content);
    const metadata_y = content.y + pad + leading_height - app.detail_scroll_px;
    const over_metadata = over_content and mouse.y >= metadata_y;
    if (over_metadata and !over_track) rl.setMouseCursor(.ibeam);
    const over_thumb = clay.BoundingBox{
        .x = track.x,
        .y = track.y + thumbOffset(thumb_travel, max_scroll, app.detail_scroll_px),
        .width = track.width,
        .height = thumb_height,
    };

    if (!left_down) {
        app.detail_dragging = false;
        app.detail_text_selecting = false;
    }
    if (clicked and (!over_metadata or over_track)) {
        app.detail_text_focused = false;
        app.detail_text_selecting = false;
    }
    if (clicked and over_track and !ctrlHeld()) {
        app.detail_dragging = true;
        if (pointInBox(mouse, over_thumb)) {
            app.detail_grab = mouse.y - over_thumb.y;
        } else {
            app.detail_grab = thumb_height / 2;
            const jumped = std.math.clamp(mouse.y - track.y - app.detail_grab, 0, thumb_travel);
            app.detail_scroll_px = jumpToScroll(jumped, thumb_travel, max_scroll);
        }
    }
    if (app.detail_dragging and needs_scrollbar) {
        const jumped = std.math.clamp(mouse.y - track.y - app.detail_grab, 0, thumb_travel);
        app.detail_scroll_px = jumpToScroll(jumped, thumb_travel, max_scroll);
    } else if (over_content and wheel != 0 and !ctrlHeld()) {
        app.detail_scroll_px = std.math.clamp(app.detail_scroll_px - wheel * 48, 0, max_scroll);
    }
    if (over_content) {
        if (rl.isKeyPressed(.page_up)) app.detail_scroll_px -= view_h;
        if (rl.isKeyPressed(.page_down)) app.detail_scroll_px += view_h;
        if (rl.isKeyPressed(.home)) app.detail_scroll_px = 0;
        if (rl.isKeyPressed(.end)) app.detail_scroll_px = max_scroll;
    }
    app.detail_scroll_px = std.math.clamp(app.detail_scroll_px, 0, max_scroll);

    if (clicked and over_metadata and !over_track) {
        if (detailPositionAt(
            app,
            font,
            bold_font,
            mouse,
            content,
            pad,
            leading_height,
        )) |position| {
            app.detail_selection_anchor = position;
            app.detail_selection_focus = position;
            app.detail_text_selecting = true;
            app.detail_text_focused = true;
        }
    }
    if (app.detail_text_selecting and left_down) {
        if (mouse.y < content.y) {
            app.detail_scroll_px -= 12;
        } else if (mouse.y > content.y + content.height) {
            app.detail_scroll_px += 12;
        }
        app.detail_scroll_px = std.math.clamp(app.detail_scroll_px, 0, max_scroll);
        if (detailPositionAt(
            app,
            font,
            bold_font,
            mouse,
            content,
            pad,
            leading_height,
        )) |position| {
            app.detail_selection_focus = position;
        }
    }
    if (app.detail_text_focused and ctrlHeld()) {
        if (rl.isKeyPressed(.a) and app.detail_line_count > 0) {
            const last_line = app.detail_line_count - 1;
            app.detail_selection_anchor = .{ .line = 0, .byte = 0 };
            app.detail_selection_focus = .{
                .line = last_line,
                .byte = app.detail_lines[last_line].text.len,
            };
        }
        if (rl.isKeyPressed(.c)) copyDetailTextSelection(app);
    }

    rl.beginScissorMode(
        @intFromFloat(content.x),
        @intFromFloat(content.y),
        @intFromFloat(content.width),
        @intFromFloat(content.height),
    );
    const selection = detailTextSelection(app);
    const graph_y = content.y + pad - app.detail_scroll_px;
    if (graph_y + detail_cpu_graph_height >= content.y and
        graph_y <= content.y + content.height)
    {
        try drawDetailCpuGraph(
            app,
            process,
            index,
            session.timelineNs(),
            input.host_cpu_count,
            font,
            .init(content.x + pad, graph_y, inner_w, detail_cpu_graph_height),
        );
    }
    var text_y = graph_y + leading_height;
    for (app.detail_lines[0..app.detail_line_count], 0..) |line, line_index| {
        const line_h = app.detail_line_heights[line_index];
        if (text_y + line_h >= content.y and text_y <= content.y + content.height) {
            const text_x = content.x + pad;
            drawDetailTextSelection(
                app,
                selection,
                font,
                bold_font,
                line_index,
                text_x,
                text_y,
                line_h,
            );
            drawDetailLine(
                font,
                bold_font,
                line,
                .{ .x = text_x, .y = text_y },
            );
        }
        text_y += line_h + detail_line_gap;
        if (text_y > content.y + content.height) break;
    }
    rl.endScissorMode();

    if (needs_scrollbar) {
        rl.drawRectangleRounded(
            .init(track.x, track.y, track.width, track.height),
            0.5,
            4,
            toRaylibColor(.{
                12,
                18,
                32,
                255,
            }),
        );
        const thumb_color: clay.Color = if (app.detail_dragging)
            .{
                92,
                151,
                255,
                255,
            }
        else if (over_track)
            .{
                86,
                110,
                145,
                255,
            }
        else
            .{
                61,
                80,
                110,
                255,
            };
        const thumb_y = track.y + thumbOffset(thumb_travel, max_scroll, app.detail_scroll_px);
        rl.drawRectangleRounded(
            .init(track.x, thumb_y, track.width, thumb_height),
            0.5,
            4,
            toRaylibColor(thumb_color),
        );
    }
    drawDetailCloseButton(font, mouse, close_box);
}
