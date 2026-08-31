//! Flamez entry point and raylib/Clay renderer for live process timelines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const clay = @import("zclay");
const rl = @import("raylib");
const footer_font = @import("footer_font");
const tracer = @import("tracer.zig");
const App = @import("App.zig");
const detail_pane = @import("detail_pane.zig");
const page_layout = @import("layout.zig");
const process_tree = @import("process_tree.zig");
const theme = @import("theme.zig");
const text = @import("text.zig");
const perf = @import("perf.zig");

const log = std.log.scoped(.flamez);

const canvas = theme.canvas;
const panel_raised = theme.panel_raised;
const border = theme.border;
const accent = theme.accent;
const blue = theme.blue;
const blue_bright = theme.blue_bright;
const yellow = theme.yellow;
const yellow_bright = theme.yellow_bright;
const cpu_hot = theme.cpu_hot;
const ink = theme.ink;
const muted = theme.muted;
const faint = theme.faint;
const toRaylibColor = theme.toRaylibColor;

const text_buffer_capacity = text.text_buffer_capacity;
const ui_glyph_spacing = text.ui_glyph_spacing;
const nullTerminate = text.nullTerminate;
const formatDuration = text.formatDuration;
const measureTextSlice = text.measureTextSlice;
const drawTextSlice = text.drawTextSlice;
const drawTextSliceClipped = text.drawTextSliceClipped;

const min_view_span_ns = App.min_view_span_ns;
const TimeWindow = App.TimeWindow;
const visibleTimeWindow = App.visibleTimeWindow;
const zoomTimeView = App.zoomTimeView;
const resetTimeView = App.resetTimeView;
const setTimeViewStart = App.setTimeViewStart;
const panTimeView = App.panTimeView;

const window_width = 1180;
const window_height = 760;
/// Software cap used when vsync is off (screenshot clock). `0` means no CPU wait.
const screenshot_fps = 60;
/// Completed captures poll for input without rebuilding or presenting unchanged frames.
const idle_poll_interval_ms: i64 = 32;
/// FPS-enabled idle captures present only often enough to keep the diagnostic visibly live.
const idle_fps_refresh_polls: usize = @intCast(@divTrunc(1000, idle_poll_interval_ms));
const ui_font_id: u16 = 0;
const footer_font_id: u16 = 1;

const FontBook = struct {
    ui: rl.Font,
    row: rl.Font,
    footer: rl.Font,

    fn get(self: *const FontBook, font_id: u16) rl.Font {
        return switch (font_id) {
            footer_font_id => self.footer,
            ui_font_id => self.ui,
            else => self.ui,
        };
    }

    fn deinit(self: *FontBook) void {
        unloadEmbeddedFont(self.footer);
        unloadEmbeddedFont(self.row);
        unloadEmbeddedFont(self.ui);
        self.* = undefined;
    }
};

const FrameInput = struct {
    font: rl.Font,
    row_font: rl.Font,
    mouse: rl.Vector2,
    wheel: f32,
    pinch_zoom: f32,
    clicked: bool,
    host_cpu_count: usize,
};

const TrackpadGestures = struct {
    pinch_distance: ?f32 = null,

    fn samplePinch(self: *TrackpadGestures) f32 {
        const pinching = rl.isGestureDetected(.{ .pinch_in = true }) or
            rl.isGestureDetected(.{ .pinch_out = true });
        if (!pinching) {
            self.pinch_distance = null;
            return 0;
        }

        const vector = rl.getGesturePinchVector();
        const distance = @sqrt(vector.x * vector.x + vector.y * vector.y);
        const previous = self.pinch_distance orelse {
            self.pinch_distance = distance;
            return 0;
        };
        self.pinch_distance = distance;
        return (distance - previous) * 24;
    }
};

pub fn main(init: std.process.Init) !void {
    // Must exist before the target can be spawned: without these handlers any
    // Ctrl+C / terminal close kills flamez alone and orphans the target group,
    // because the target deliberately runs in its own process group.
    tracer.installFatalSignalHandlers();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    var target_argv: std.ArrayList([]const u8) = .empty;
    defer target_argv.deinit(init.gpa);
    while (args.next()) |arg| {
        const owned = try init.arena.allocator().dupe(u8, arg);
        try target_argv.append(init.gpa, owned);
    }
    if (target_argv.items.len == 0) {
        std.debug.print(
            "Usage: flamez <target> [target args...]\n" ++
                "Example: flamez zig build -Doptimize=ReleaseFast\n",
            .{},
        );
        return;
    }

    // Live capture is mandatory: fail fast with backend diagnostics before any
    // window is opened. Session-file import can bypass this when implemented.
    var collector = tracer.Collector.init(init.gpa);
    if (!collector.available()) {
        std.debug.print(
            \\flamez: cannot start — process-event capture is required.
            \\
            \\Failed because: {s}
            \\
            \\
        , .{collector.diagnosticSlice()});
        if (comptime tracer.capture_backend == .linux_ebpf) {
            std.debug.print(
                \\Fixes:
                \\  • run ./build.sh to install flamez with
                \\    cap_bpf,cap_perfmon
                \\
            , .{});
        }
        std.process.exit(1);
    }
    var collector_attached = true;
    defer if (collector_attached) collector.deinit();

    collector.dropPrivileges() catch {
        std.debug.print("flamez: could not drop capture privileges after attach\n", .{});
        std.process.exit(1);
    };
    var session = tracer.Session.init(init.gpa, init.io);
    defer session.deinit();
    var start_error: ?tracer.Session.StartError = null;
    session.start(&collector, target_argv.items) catch |err| {
        start_error = err;
    };
    var app = try App.init(init.gpa);
    defer app.deinit();
    const host_cpu_count = @max(std.Thread.getCpuCount() catch 1, 1);
    if (start_error) |err| {
        if (comptime tracer.capture_backend == .macos) {
            if (err == error.ExactCaptureUnavailable) {
                app.setMessage(
                    "Exact macOS capture unavailable: {s}",
                    .{collector.exactDiagnosticSlice()},
                );
            } else {
                app.setMessage("Could not start target: {s}", .{@errorName(err)});
            }
        } else {
            app.setMessage("Could not start target: {s}", .{@errorName(err)});
        }
    }

    const screenshot_path: ?[:0]const u8 = if (std.c.getenv("FLAMEZ_SCREENSHOT")) |path|
        std.mem.span(path)
    else
        null;
    rl.setConfigFlags(.{
        .window_resizable = true,
        .msaa_4x_hint = build_options.msaa,
        .vsync_hint = screenshot_path == null,
        .window_highdpi = screenshot_path == null,
    });
    rl.initWindow(window_width, window_height, "Flamez");
    if (!rl.isWindowReady()) {
        log.err("raylib could not create a window", .{});
        return;
    }
    defer rl.closeWindow();
    rl.setGesturesEnabled(.{
        .tap = true,
        .doubletap = true,
        .pinch_in = true,
        .pinch_out = true,
    });
    rl.setWindowMinSize(760, 520);
    // Screenshots disable vsync and need a fixed clock. Interactive frames
    // use `setTargetFPS(0)` so the swap interval is the cap.
    var fps_cap: i32 = if (screenshot_path != null) screenshot_fps else 0;
    rl.setTargetFPS(fps_cap);

    var fonts = loadFonts();
    defer fonts.deinit();
    const font = fonts.ui;
    const clay_memory = try init.arena.allocator().alloc(u8, clay.minMemorySize());
    _ = clay.initialize(
        .init(clay_memory),
        .{ .w = window_width, .h = window_height },
        .{ .error_handler_function = handleClayError },
    );
    clay.setMeasureTextFunction(*const FontBook, &fonts, measureText);

    var frame_number: usize = 0;
    var trackpad_gestures: TrackpadGestures = .{};
    var last_drawn_mouse = rl.getMousePosition();
    var idle_polls_since_draw: usize = 0;
    perf.beginSession(init.io);

    while (!rl.windowShouldClose()) {
        const frame_time = rl.getFrameTime();
        const mouse = rl.getMousePosition();
        const wheel = rl.getMouseWheelMoveV();
        const tapped = rl.isGestureDetected(.{ .tap = true }) or
            rl.isGestureDetected(.{ .doubletap = true });
        const clicked = rl.isMouseButtonPressed(.left) or tapped;
        const pointer_active = clicked or
            rl.isMouseButtonDown(.left) or
            rl.isMouseButtonReleased(.left);
        const pinch_zoom = trackpad_gestures.samplePinch();
        const width = rl.getScreenWidth();
        const height = rl.getScreenHeight();
        const wanted_fps: i32 = if (screenshot_path != null)
            screenshot_fps
        else
            0; // 0 == vsync

        if (wanted_fps != fps_cap) {
            fps_cap = wanted_fps;
            rl.setTargetFPS(fps_cap);
        }

        const mouse_moved = mouse.x != last_drawn_mouse.x or mouse.y != last_drawn_mouse.y;
        const input_changed = mouse_moved or
            wheel.x != 0 or
            wheel.y != 0 or
            pointer_active or
            trackpad_gestures.pinch_distance != null or
            hasKeyboardActivity() or
            rl.isWindowResized();
        const fps_refresh_due = if (comptime build_options.fps_counter)
            idle_polls_since_draw >= idle_fps_refresh_polls
        else
            false;
        const redraw = session.running or
            screenshot_path != null or
            frame_number == 0 or
            input_changed or
            fps_refresh_due;
        if (!redraw) {
            init.io.sleep(.fromMilliseconds(idle_poll_interval_ms), .awake) catch {};
            // EndDrawing normally polls events; idle frames deliberately skip it.
            rl.pollInputEvents();
            idle_polls_since_draw +|= 1;
            continue;
        }
        idle_polls_since_draw = 0;
        perf.beginFrame();

        clay.setLayoutDimensions(.{
            .w = @floatFromInt(width),
            .h = @floatFromInt(height),
        });
        clay.setPointerState(.{ .x = mouse.x, .y = mouse.y }, rl.isMouseButtonDown(.left));
        clay.updateScrollContainers(false, .{ .x = wheel.x, .y = wheel.y }, frame_time);

        if (clicked and session.running and clay.pointerOver(.ID("StopButton"))) {
            session.stop();
            app.setMessage("Capture stopped", .{});
        }
        if (clicked and app.selected_process != null and
            clay.pointerOver(.ID("DetailCloseButton")))
        {
            app.selected_process = null;
        }
        if (rl.isKeyPressed(.f5)) clay.setDebugModeEnabled(!clay.isDebugModeEnabled());

        if (session.running) {
            session.update(&collector);
            perf.noteSnapshot(collector.last_cpu_samples, collector.last_ring_events);
        }
        if (!session.running and collector_attached) {
            collector.deinit();
            collector_attached = false;
        }
        const frame_input = FrameInput{
            .font = font,
            .row_font = fonts.row,
            .mouse = mouse,
            .wheel = wheel.y,
            .pinch_zoom = pinch_zoom,
            .clicked = clicked,
            .host_cpu_count = host_cpu_count,
        };
        if (comptime perf.enabled) {
            perf.noteSessionShape(
                session.processes.items.len,
                session.metadata.items.len,
                countSlices(&session),
            );
        }
        const view_text = page_layout.makeViewText(&session);
        perf.enter(.clay_layout);
        const commands = page_layout.create(&app, &session, &view_text);
        perf.leave();

        rl.beginDrawing();
        rl.clearBackground(toRaylibColor(canvas));
        rl.setMouseCursor(.default);
        perf.enter(.clay_playback);
        renderClay(commands, &fonts);
        perf.leave();
        perf.enter(.timeline);
        const hovered = try renderTimeline(&app, &session, frame_input);
        perf.leave();
        perf.enter(.detail);
        try detail_pane.render(&app, &session, .{
            .font = frame_input.font,
            .bold_font = frame_input.row_font,
            .mouse = frame_input.mouse,
            .wheel = frame_input.wheel,
            .clicked = frame_input.clicked,
            .host_cpu_count = frame_input.host_cpu_count,
        });
        perf.leave();
        // Draw last so the hover tooltip is never covered by the detail pane.
        if (hovered) |target| {
            detail_pane.renderTooltip(&app, &session, target.process_index, font, mouse);
        }
        perf.enter(.end_drawing);
        rl.endDrawing();
        perf.leave();
        perf.endFrame();
        last_drawn_mouse = mouse;
        frame_number += 1;
        if (screenshot_path) |path| {
            if (frame_number == 40) {
                rl.takeScreenshot(path);
                break;
            }
        }
    }
    perf.sessionSummary();
}

fn hasKeyboardActivity() bool {
    return rl.isKeyPressed(.f5) or
        rl.isKeyPressed(.zero) or
        rl.isKeyPressed(.kp_0) or
        rl.isKeyPressed(.minus) or
        rl.isKeyPressed(.kp_subtract) or
        rl.isKeyPressed(.equal) or
        rl.isKeyPressed(.kp_equal) or
        rl.isKeyPressed(.kp_add) or
        rl.isKeyPressed(.up) or
        rl.isKeyPressed(.down) or
        rl.isKeyPressed(.page_up) or
        rl.isKeyPressed(.page_down) or
        rl.isKeyPressed(.home) or
        rl.isKeyPressed(.end) or
        rl.isKeyPressed(.left) or
        rl.isKeyPressed(.right) or
        rl.isKeyPressed(.a) or
        rl.isKeyPressed(.c);
}

fn countSlices(session: *const tracer.Session) usize {
    var total: usize = 0;
    for (session.processes.items) |process| total += process.cpu_slices.items.len;
    return total;
}

fn handleClayError(error_data: clay.ErrorData) callconv(.c) void {
    const message = error_data.error_text.chars[0..@intCast(error_data.error_text.length)];
    log.err("clay layout ({s}): {s}", .{ @tagName(error_data.error_type), message });
}

const process_row_height = page_layout.process_row_height;
const process_row_gap: f32 = 1;
const min_cpu_slice_height: f32 = 2;
/// Timeline CPU bars fill the row at this fraction of host logical cores.
const cpu_bar_full_core_fraction: f64 = 0.75;
const scrollbar_width: f32 = 12;
const scrollbar_min_thumb_size: f32 = 24;

fn ctrlHeld() bool {
    return rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
}

fn shiftHeld() bool {
    return rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
}

fn applyTimeViewHotkeys(app: *App, total_ns: u64) void {
    if (!ctrlHeld()) return;
    if (rl.isKeyPressed(.zero) or rl.isKeyPressed(.kp_0)) {
        resetTimeView(app);
    } else if (rl.isKeyPressed(.minus) or rl.isKeyPressed(.kp_subtract)) {
        zoomTimeView(app, total_ns, 0.5, -1);
    } else if (rl.isKeyPressed(.equal) or
        rl.isKeyPressed(.kp_equal) or
        rl.isKeyPressed(.kp_add))
    {
        zoomTimeView(app, total_ns, 0.5, 1);
    }
}

fn ratio(numerator: usize, denominator: usize) f32 {
    if (denominator == 0) return 0;
    const numerator_f: f64 = @floatFromInt(numerator);
    const denominator_f: f64 = @floatFromInt(denominator);
    return @floatCast(numerator_f / denominator_f);
}

// Where and how a lifetime bar is drawn for one timeline row. Bundled so
// the bar math takes one layout argument instead of six loose values.
const BarLayout = struct {
    window: TimeWindow,
    view_span: u64,
    timeline_x: f32,
    timeline_width: f32,
    y: f32,
    row_height: f32,
};

const TimelineHover = struct {
    process_index: usize,
};

fn lifetimeBar(process: *const tracer.Process, now_ns: u64, layout: BarLayout) ?rl.Rectangle {
    const window = layout.window;
    const bar_start_ns = process.start_ns;
    const bar_end_ns = process.end_ns orelse now_ns;
    const view_end_ns = window.start_ns + layout.view_span;
    if (bar_end_ns <= window.start_ns or bar_start_ns >= view_end_ns) return null;
    const clipped_start = @max(bar_start_ns, window.start_ns);
    const clipped_end = @min(bar_end_ns, view_end_ns);
    const span_seconds: f64 = @floatFromInt(layout.view_span);
    const start_fraction = @as(f64, @floatFromInt(clipped_start - window.start_ns)) / span_seconds;
    const end_fraction = @as(f64, @floatFromInt(clipped_end - window.start_ns)) / span_seconds;
    const bar_x = layout.timeline_x + layout.timeline_width * @as(f32, @floatCast(start_fraction));
    const bar_width = @max(
        2,
        layout.timeline_width * @as(f32, @floatCast(end_fraction - start_fraction)),
    );
    return rl.Rectangle.init(bar_x, layout.y, bar_width, layout.row_height - process_row_gap);
}

fn cpuSliceHeight(
    slice: tracer.Process.CpuSlice,
    row_height: f32,
    host_cpu_count: usize,
) f32 {
    const available_height = @max(@as(f32, 1), row_height - process_row_gap);
    const host_cores: f64 = @floatFromInt(@max(host_cpu_count, 1));
    const full_at_cores = @max(host_cores * cpu_bar_full_core_fraction, 1);
    const occupancy = @min(slice.averageCores() / full_at_cores, 1);
    return @min(
        available_height,
        @max(min_cpu_slice_height, available_height * @as(f32, @floatCast(occupancy))),
    );
}

fn cpuSliceRect(
    slice: tracer.Process.CpuSlice,
    layout: BarLayout,
    host_cpu_count: usize,
) ?rl.Rectangle {
    const view_end_ns = layout.window.start_ns + layout.view_span;
    if (slice.end_ns <= layout.window.start_ns or slice.start_ns >= view_end_ns) return null;
    const clipped_start = @max(slice.start_ns, layout.window.start_ns);
    const clipped_end = @min(slice.end_ns, view_end_ns);
    if (clipped_end <= clipped_start) return null;
    const span: f64 = @floatFromInt(layout.view_span);
    const start_fraction = @as(
        f64,
        @floatFromInt(clipped_start - layout.window.start_ns),
    ) / span;
    const end_fraction = @as(
        f64,
        @floatFromInt(clipped_end - layout.window.start_ns),
    ) / span;
    const x = layout.timeline_x +
        layout.timeline_width * @as(f32, @floatCast(start_fraction));
    const width = @max(
        1,
        layout.timeline_width * @as(f32, @floatCast(end_fraction - start_fraction)),
    );
    const height = cpuSliceHeight(slice, layout.row_height, host_cpu_count);
    const bar_height = layout.row_height - process_row_gap;
    return .init(
        x,
        layout.y + bar_height - height,
        width,
        height,
    );
}

fn paintCpuSlice(slice: tracer.Process.CpuSlice, rect: rl.Rectangle) void {
    const base = toRaylibColor(cpu_hot);
    rl.drawRectangleRec(rect, .init(base.r, base.g, base.b, cpuSliceAlpha(slice.band)));
    if (slice.band > 4) {
        rl.drawRectangleRec(
            .init(rect.x, rect.y, rect.width, 1),
            rl.Color.init(255, 178, 178, 255),
        );
    }
}

fn mergeCpuColumn(column: *App.CpuColumn, slice: tracer.Process.CpuSlice) void {
    if (!column.occupied) {
        column.* = .{
            .band = slice.band,
            .cpu_ns = slice.cpu_ns,
            .start_ns = slice.start_ns,
            .end_ns = slice.end_ns,
            .occupied = true,
        };
        return;
    }
    if (slice.band > column.band) column.band = slice.band;
    column.cpu_ns +|= slice.cpu_ns;
    column.start_ns = @min(column.start_ns, slice.start_ns);
    column.end_ns = @max(column.end_ns, slice.end_ns);
}

fn paintCpuSlices(
    app: *App,
    process: *const tracer.Process,
    layout: BarLayout,
    host_cpu_count: usize,
) Allocator.Error!void {
    const slices = process.cpu_slices.items;
    if (slices.len == 0) return;

    const view_end_ns = layout.window.start_ns + layout.view_span;
    const first = tracer.Process.firstVisibleSlice(slices, layout.window.start_ns, view_end_ns);
    if (first == slices.len or slices[first].start_ns >= view_end_ns) return;

    const width = @max(1, @as(usize, @intFromFloat(@floor(layout.timeline_width))));
    var columns_ready = false;
    var scanned: usize = 0;
    var drawn: usize = 0;
    for (slices[first..]) |slice| {
        if (slice.start_ns >= view_end_ns) break;
        scanned += 1;
        const rect = cpuSliceRect(slice, layout, host_cpu_count) orelse continue;
        if (rect.width >= 1.5) {
            paintCpuSlice(slice, rect);
            drawn += 1;
            continue;
        }
        if (!columns_ready) {
            for (app.cpu_touched_columns.items) |px| app.cpu_columns.items[px] = .{};
            app.cpu_touched_columns.clearRetainingCapacity();
            const old_width = app.cpu_columns.items.len;
            try app.cpu_columns.resize(app.gpa, width);
            if (width > old_width) @memset(app.cpu_columns.items[old_width..], .{});
            columns_ready = true;
        }
        const px_f = @floor(rect.x - layout.timeline_x);
        if (px_f < 0) continue;
        const px: usize = @intFromFloat(px_f);
        if (px >= width) continue;
        if (!app.cpu_columns.items[px].occupied) {
            try app.cpu_touched_columns.append(app.gpa, px);
        }
        mergeCpuColumn(&app.cpu_columns.items[px], slice);
    }
    if (columns_ready) {
        for (app.cpu_touched_columns.items) |px| {
            const column = app.cpu_columns.items[px];
            const synthetic = tracer.Process.CpuSlice{
                .start_ns = column.start_ns,
                .end_ns = column.end_ns,
                .cpu_ns = column.cpu_ns,
                .band = column.band,
            };
            const rect = cpuSliceRect(synthetic, layout, host_cpu_count) orelse continue;
            paintCpuSlice(synthetic, rect);
            drawn += 1;
        }
    }
    perf.noteSlices(scanned, drawn);
}

fn cpuSliceAlpha(band: u8) u8 {
    const scaled: u32 = 110 + @as(u32, band) * 16;
    return @intCast(@min(scaled, 220));
}

fn pointInRect(point: rl.Vector2, rect: rl.Rectangle) bool {
    return point.x >= rect.x and point.x <= rect.x + rect.width and
        point.y >= rect.y and point.y <= rect.y + rect.height;
}

// Visual treatment for a painted lifetime bar.
const BarLook = struct {
    color: rl.Color,
    font: rl.Font,
    ink: rl.Color,
    rounded: bool,
};

const CollapseButton = struct {
    hit_box: rl.Rectangle,
    visual_box: rl.Rectangle,
};

const TimelineClick = union(enum) {
    collapse: process_tree.RowCollapseTarget,
    select: usize,
};

const bar_label_inset: f32 = 5;
const bar_label_right_padding: f32 = 5;
const bar_label_size: u16 = 12;
const collapse_button_size: f32 = 20;
const collapse_button_hit_width: f32 = 28;
const collapse_button_padding: f32 = 8;

fn timelineTickLabelX(
    tick_x: f32,
    label_width: f32,
    timeline_x: f32,
    timeline_width: f32,
) f32 {
    const centered_x = tick_x - label_width / 2;
    const rightmost_x = @max(timeline_x, timeline_x + timeline_width - label_width);
    return std.math.clamp(centered_x, timeline_x, rightmost_x);
}

fn needsHorizontalScrollbar(window: TimeWindow, total_ns: u64, track_width: f32) bool {
    if (total_ns == 0 or
        window.span_ns >= total_ns or
        track_width <= scrollbar_min_thumb_size)
    {
        return false;
    }
    const visible_fraction = @as(f64, @floatFromInt(window.span_ns)) /
        @as(f64, @floatFromInt(total_ns));
    const thumb_width = @min(
        track_width,
        @max(scrollbar_min_thumb_size, track_width * @as(f32, @floatCast(visible_fraction))),
    );
    return track_width - thumb_width >= 1;
}

fn collapseButton(gutter: rl.Rectangle) CollapseButton {
    const hit_box = rl.Rectangle.init(
        gutter.x + (gutter.width - collapse_button_hit_width) / 2,
        gutter.y,
        collapse_button_hit_width,
        gutter.height,
    );
    return .{
        .hit_box = hit_box,
        .visual_box = .init(
            hit_box.x + (hit_box.width - collapse_button_size) / 2,
            hit_box.y + (hit_box.height - collapse_button_size) / 2,
            collapse_button_size,
            collapse_button_size,
        ),
    };
}

fn paintCollapseButton(button: CollapseButton, collapsed: bool, hovered: bool) void {
    if (hovered) {
        rl.drawRectangleRoundedLinesEx(
            button.visual_box,
            0.25,
            4,
            1,
            toRaylibColor(accent),
        );
    }

    const center = rl.Vector2{
        .x = button.visual_box.x + button.visual_box.width / 2,
        .y = button.visual_box.y + button.visual_box.height / 2,
    };
    const color = toRaylibColor(muted);
    if (collapsed) {
        rl.drawLineEx(
            .{ .x = center.x - 2, .y = center.y - 4 },
            .{ .x = center.x + 2, .y = center.y },
            2,
            color,
        );
        rl.drawLineEx(
            .{ .x = center.x + 2, .y = center.y },
            .{ .x = center.x - 2, .y = center.y + 4 },
            2,
            color,
        );
    } else {
        rl.drawLineEx(
            .{ .x = center.x - 4, .y = center.y - 2 },
            .{ .x = center.x, .y = center.y + 2 },
            2,
            color,
        );
        rl.drawLineEx(
            .{ .x = center.x, .y = center.y + 2 },
            .{ .x = center.x + 4, .y = center.y - 2 },
            2,
            color,
        );
    }
}

fn resolveTimelineClick(
    collapse_target: ?process_tree.RowCollapseTarget,
    process_index: ?usize,
) ?TimelineClick {
    if (collapse_target) |target| return .{ .collapse = target };
    if (process_index) |index| return .{ .select = index };
    return null;
}

fn applyTimelineClick(app: *App, target: TimelineClick) void {
    switch (target) {
        .collapse => |collapse_target| process_tree.toggleRowCollapsed(app, collapse_target),
        .select => |index| {
            app.selected_process = if (app.selected_process == index) null else index;
        },
    }
}

fn paintLifetimeBar(
    app: *const App,
    index: usize,
    bar: rl.Rectangle,
    look: BarLook,
) void {
    if (look.rounded) {
        rl.drawRectangleRounded(bar, 0.22, 4, look.color);
        if (app.selected_process == index) {
            rl.drawRectangleRoundedLinesEx(bar, 0.22, 4, 2, rl.Color.white);
        }
    } else {
        rl.drawRectangleRec(bar, look.color);
        if (app.selected_process == index) {
            rl.drawRectangleLinesEx(bar, 2, rl.Color.white);
        }
    }
}

fn paintBarLabel(
    app: *App,
    process: *const tracer.Process,
    process_index: usize,
    metadata: []const u8,
    bar: rl.Rectangle,
    look: BarLook,
) void {
    const name = process.rowNameSlice();
    const name_hash = std.hash.Wyhash.hash(name.len, name);
    if (app.bar_name_widths.items[process_index] < 0 or
        app.bar_name_hashes.items[process_index] != name_hash)
    {
        app.bar_name_widths.items[process_index] = measureTextSlice(
            look.font,
            name,
            bar_label_size,
        ).x;
        app.bar_name_hashes.items[process_index] = name_hash;
    }
    const name_width = app.bar_name_widths.items[process_index];
    if (bar.width < name_width + bar_label_inset * 2) return;
    var summary_buf: [64]u8 = undefined;
    const summary = process.rowArgSummary(metadata, &summary_buf);
    var bar_label_buf: [96]u8 = undefined;
    const bar_label = if (summary.len == 0) name else std.fmt.bufPrint(
        &bar_label_buf,
        "{s}  {s}",
        .{ name, summary },
    ) catch name;
    const label_height = measureTextSlice(look.font, bar_label, bar_label_size).y;
    const label_position = rl.Vector2{
        // Bar positions are time-derived and commonly fractional. Sampling a
        // glyph atlas between screen pixels makes the small row labels fuzzy.
        .x = @round(bar.x + bar_label_inset),
        .y = @round(bar.y + (bar.height - label_height) / 2),
    };
    const max_width = bar.width - bar_label_inset - bar_label_right_padding;
    drawTextSliceClipped(bar_label, .{
        .font = look.font,
        .position = label_position,
        .size = bar_label_size,
        .color = look.ink,
        .max_width = max_width,
    });
}

fn renderTimeline(
    app: *App,
    session: *const tracer.Session,
    input: FrameInput,
) Allocator.Error!?TimelineHover {
    const font = input.font;
    const row_font = input.row_font;
    const mouse = input.mouse;
    const wheel = input.wheel;
    const pinch_zoom = input.pinch_zoom;
    const clicked = input.clicked;
    const element = clay.getElementData(.ID("TimelineViewport"));
    if (!element.found) return null;
    const box = element.bounding_box;
    if (box.width < 100 or box.height < 80) return null;

    try process_tree.ensureProcessTree(app, session);
    var row_count = app.row_order.items.len;

    const inside = pointInBox(mouse, box);
    const header_height = process_row_height;
    const row_height = process_row_height;
    const total_ns = @max(session.timelineNs(), min_view_span_ns);
    applyTimeViewHotkeys(app, total_ns);
    var window = visibleTimeWindow(app, total_ns);
    const timeline_x = box.x + collapse_button_size + collapse_button_padding * 2;
    const min_inner_width = box.width - 24 - scrollbar_width + 8;
    const min_timeline_width = @max(0, box.x + 12 + min_inner_width - timeline_x);
    const needs_hscroll = needsHorizontalScrollbar(window, total_ns, min_timeline_width);
    const hscroll_reserve: f32 = if (needs_hscroll) scrollbar_width + 10 else 8;
    const visible_rows: usize = @intFromFloat(@max(1, @floor(
        (box.height - header_height - hscroll_reserve) / row_height,
    )));
    const max_scroll = row_count -| visible_rows;
    const needs_scroll = max_scroll > 0;

    const inner_x = box.x + 12;
    const inner_width = box.width - 24 - if (needs_scroll) scrollbar_width + 8 else 0;
    const timeline_width = @max(0, inner_x + inner_width - timeline_x);

    const h_track = clay.BoundingBox{
        .x = timeline_x,
        .y = box.y + box.height - scrollbar_width - 6,
        .width = @max(0, timeline_width),
        .height = scrollbar_width,
    };
    const h_thumb_width: f32 = if (needs_hscroll and total_ns > 0)
        @min(
            h_track.width,
            @max(
                scrollbar_min_thumb_size,
                h_track.width * ratio(window.span_ns, total_ns),
            ),
        )
    else
        h_track.width;
    const h_thumb_travel = @max(0, h_track.width - h_thumb_width);
    const h_max_start = if (needs_hscroll) total_ns - window.span_ns else 0;
    const h_thumb_x = h_track.x + if (h_max_start == 0)
        0
    else
        h_thumb_travel * ratio(window.start_ns, h_max_start);
    const h_thumb = clay.BoundingBox{
        .x = h_thumb_x,
        .y = h_track.y,
        .width = h_thumb_width,
        .height = h_track.height,
    };
    const over_hscroll = needs_hscroll and pointInBox(mouse, h_track);

    const track = clay.BoundingBox{
        .x = box.x + box.width - scrollbar_width - 6,
        .y = box.y + header_height + 6,
        .width = scrollbar_width,
        .height = @max(0, (if (needs_hscroll) h_track.y - 6 else box.y + box.height - 6) -
            (box.y + header_height + 6)),
    };
    const thumb_height: f32 = if (needs_scroll)
        @max(scrollbar_min_thumb_size, track.height * ratio(visible_rows, row_count))
    else
        track.height;
    const thumb_travel = @max(0, track.height - thumb_height);
    const thumb_y = track.y + if (max_scroll == 0)
        0
    else
        thumb_travel * ratio(app.graph_scroll, max_scroll);
    const thumb = clay.BoundingBox{
        .x = track.x,
        .y = thumb_y,
        .width = track.width,
        .height = thumb_height,
    };
    const over_scrollbar = needs_scroll and pointInBox(mouse, track);

    if (!rl.isMouseButtonDown(.left)) {
        app.scrollbar_dragging = false;
        app.hscroll_dragging = false;
    }
    if (clicked and over_hscroll and !ctrlHeld()) {
        app.hscroll_dragging = true;
        if (pointInBox(mouse, h_thumb)) {
            app.hscroll_grab = mouse.x - h_thumb.x;
        } else {
            app.hscroll_grab = h_thumb_width / 2;
            const jumped = std.math.clamp(
                mouse.x - h_track.x - app.hscroll_grab,
                0,
                h_thumb_travel,
            );
            const start: u64 = if (h_thumb_travel <= 0)
                0
            else
                @intFromFloat(@as(f64, @floatFromInt(h_max_start)) * jumped / h_thumb_travel);
            setTimeViewStart(app, total_ns, start);
        }
    } else if (clicked and over_scrollbar and !ctrlHeld()) {
        app.scrollbar_dragging = true;
        if (pointInBox(mouse, thumb)) {
            app.scrollbar_grab = mouse.y - thumb.y;
        } else {
            app.scrollbar_grab = thumb_height / 2;
            const jumped = std.math.clamp(mouse.y - track.y - app.scrollbar_grab, 0, thumb_travel);
            app.graph_scroll = if (thumb_travel <= 0)
                0
            else
                @intFromFloat(@round(jumped / thumb_travel * @as(f32, @floatFromInt(max_scroll))));
        }
    }
    if (app.hscroll_dragging and needs_hscroll) {
        const jumped = std.math.clamp(mouse.x - h_track.x - app.hscroll_grab, 0, h_thumb_travel);
        const start: u64 = if (h_thumb_travel <= 0)
            0
        else
            @intFromFloat(@as(f64, @floatFromInt(h_max_start)) * jumped / h_thumb_travel);
        setTimeViewStart(app, total_ns, start);
    } else if (app.scrollbar_dragging and needs_scroll and !ctrlHeld()) {
        const jumped = std.math.clamp(mouse.y - track.y - app.scrollbar_grab, 0, thumb_travel);
        app.graph_scroll = if (thumb_travel <= 0)
            0
        else
            @intFromFloat(@round(jumped / thumb_travel * @as(f32, @floatFromInt(max_scroll))));
    } else if (inside and pinch_zoom != 0) {
        const frac: f32 = if (timeline_width > 0)
            (mouse.x - timeline_x) / timeline_width
        else
            0.5;
        zoomTimeView(app, total_ns, frac, pinch_zoom);
    } else if (inside and wheel != 0) {
        if (ctrlHeld()) {
            const frac: f32 = if (timeline_width > 0)
                (mouse.x - timeline_x) / timeline_width
            else
                0.5;
            zoomTimeView(app, total_ns, frac, wheel);
        } else if ((shiftHeld() or over_hscroll) and needs_hscroll) {
            const step: i64 = @intCast(@max(@as(u64, 1), window.span_ns / 8));
            panTimeView(app, total_ns, if (wheel > 0) -step else step);
        } else if (wheel > 0) {
            app.graph_scroll -|= @min(app.graph_scroll, 3);
        } else {
            app.graph_scroll = @min(max_scroll, app.graph_scroll + 3);
        }
    }
    window = visibleTimeWindow(app, total_ns);
    const h_thumb_draw_x = h_track.x + if (h_max_start == 0)
        0
    else
        h_thumb_travel * ratio(window.start_ns, h_max_start);
    if (inside) {
        if (rl.isKeyPressed(.up)) app.graph_scroll -|= 1;
        if (rl.isKeyPressed(.down)) app.graph_scroll = @min(max_scroll, app.graph_scroll + 1);
        if (rl.isKeyPressed(.page_up)) app.graph_scroll -|= visible_rows -| 1;
        if (rl.isKeyPressed(.page_down)) {
            app.graph_scroll = @min(max_scroll, app.graph_scroll + (visible_rows -| 1));
        }
        if (rl.isKeyPressed(.home)) app.graph_scroll = 0;
        if (rl.isKeyPressed(.end)) app.graph_scroll = max_scroll;
        if (app.selected_process) |idx| {
            const can_toggle = idx < app.first_child.items.len and
                app.first_child.items[idx] != null;
            if (can_toggle and idx < app.collapsed.items.len) {
                if (rl.isKeyPressed(.left) and !app.collapsed.items[idx]) {
                    process_tree.toggleCollapsed(app, idx);
                }
                if (rl.isKeyPressed(.right) and app.collapsed.items[idx]) {
                    process_tree.toggleCollapsed(app, idx);
                }
            }
        }
    }
    try process_tree.ensureProcessTree(app, session);
    row_count = app.row_order.items.len;
    app.graph_scroll = @min(app.graph_scroll, row_count -| visible_rows);

    rl.beginScissorMode(
        @intFromFloat(box.x),
        @intFromFloat(box.y),
        @intFromFloat(box.width),
        @intFromFloat(box.height),
    );
    rl.drawRectangleRec(
        .init(box.x, box.y, box.width, header_height),
        toRaylibColor(panel_raised),
    );
    const master_button = collapseButton(.init(
        box.x,
        box.y,
        timeline_x - box.x,
        header_height,
    ));
    const over_master_button = !app.scrollbar_dragging and
        !app.hscroll_dragging and
        pointInRect(mouse, master_button.hit_box);
    if (over_master_button) rl.setMouseCursor(.pointing_hand);
    if (clicked and over_master_button) process_tree.toggleAllRowsCollapsed(app);
    paintCollapseButton(
        master_button,
        process_tree.allCollapsibleRowsCollapsed(app),
        over_master_button,
    );
    const view_span = @max(window.span_ns, 1);
    for (0..5) |tick| {
        const fraction = @as(f32, @floatFromInt(tick)) / 4.0;
        const x = timeline_x + timeline_width * fraction;
        var tick_buffer: [32]u8 = undefined;
        const tick_ns = window.start_ns + @as(
            u64,
            @intFromFloat(@as(f64, @floatFromInt(view_span)) * fraction),
        );
        const label = formatDuration(tick_ns, &tick_buffer);
        const measured = measureTextSlice(font, label, 12);
        drawTextSlice(
            font,
            label,
            .{
                .x = timelineTickLabelX(x, measured.x, timeline_x, timeline_width),
                .y = box.y + (header_height - measured.y) / 2,
            },
            12,
            toRaylibColor(muted),
        );
    }

    if (row_count == 0) {
        const empty = "Waiting for target process data";
        const size = measureTextSlice(font, empty, 17);
        drawTextSlice(font, empty, .{
            .x = box.x + (box.width - size.x) / 2,
            .y = box.y + header_height + (box.height - header_height - size.y) / 2,
        }, 17, toRaylibColor(faint));
        rl.endScissorMode();
        return null;
    }

    var hovered: ?TimelineHover = null;
    const now_ns = session.timelineNs();
    const end_row = @min(row_count, app.graph_scroll + visible_rows + 1);
    for (app.graph_scroll..end_row) |row| {
        const visible_index = row - app.graph_scroll;
        const y = box.y + header_height + @as(f32, @floatFromInt(visible_index)) * row_height;
        const row_width = box.width - if (needs_scroll) scrollbar_width + 8 else 0;
        const row_box = clay.BoundingBox{
            .x = box.x,
            .y = y,
            .width = row_width,
            .height = row_height,
        };
        const collapse_gutter = rl.Rectangle.init(
            box.x,
            y,
            timeline_x - box.x,
            row_height - process_row_gap,
        );
        const over_row = !app.scrollbar_dragging and !app.hscroll_dragging and
            !over_scrollbar and !over_hscroll and pointInBox(mouse, row_box);

        switch (app.row_order.items[row]) {
            .process => |index| {
                if (visible_index % 2 == 1) {
                    rl.drawRectangleRec(
                        .init(row_box.x, row_box.y, row_box.width, row_box.height),
                        toRaylibColor(.{
                            14,
                            21,
                            38,
                            255,
                        }),
                    );
                }
                const process = &session.processes.items[index];
                const has_children = process_tree.hasChildren(app, index);
                const color = processColor(has_children, process.end_ns == null);
                const bar = lifetimeBar(process, now_ns, .{
                    .window = window,
                    .view_span = view_span,
                    .timeline_x = timeline_x,
                    .timeline_width = timeline_width,
                    .y = y,
                    .row_height = row_height,
                });
                const collapse_target = process_tree.RowCollapseTarget{ .process = index };
                const button = if (has_children)
                    collapseButton(collapse_gutter)
                else
                    null;
                const over_button = if (button) |control|
                    over_row and pointInRect(mouse, control.hit_box)
                else
                    false;
                if (over_row) {
                    rl.drawRectangleRec(
                        .init(row_box.x, row_box.y, row_box.width, row_box.height),
                        toRaylibColor(.{
                            30,
                            42,
                            66,
                            255,
                        }),
                    );
                }
                if (over_button) {
                    rl.setMouseCursor(.pointing_hand);
                } else if (over_row) {
                    hovered = .{ .process_index = index };
                }
                if (clicked) {
                    const target = resolveTimelineClick(
                        if (over_button) collapse_target else null,
                        if (over_row) index else null,
                    );
                    if (target) |click_target| applyTimelineClick(app, click_target);
                }
                if (bar) |b| {
                    const look = BarLook{
                        .color = color,
                        .font = row_font,
                        .ink = barNameInk(process.rowNameKind(), has_children),
                        .rounded = b.width >= 8,
                    };
                    paintLifetimeBar(app, index, b, look);
                    try paintCpuSlices(app, process, .{
                        .window = window,
                        .view_span = view_span,
                        .timeline_x = timeline_x,
                        .timeline_width = timeline_width,
                        .y = y,
                        .row_height = row_height,
                    }, input.host_cpu_count);
                    paintBarLabel(app, process, index, session.metadataBytes(), b, look);
                }
                if (button) |control| {
                    paintCollapseButton(
                        control,
                        process_tree.isRowCollapsed(app, collapse_target),
                        over_button,
                    );
                }
            },
            .slot => |slot| {
                const parent = slot.parent;
                const lane_h = process_tree.laneHeight(app, parent, slot.lane);
                const multi = lane_h > 1;
                const slot_bg: clay.Color = if (slot.lane % 2 == 1)
                    .{
                        14,
                        21,
                        38,
                        255,
                    }
                else
                    .{
                        20,
                        28,
                        48,
                        255,
                    };
                const slot_top = y - @as(f32, @floatFromInt(slot.subrow)) * row_height;
                const slot_h = @as(f32, @floatFromInt(lane_h)) * row_height;
                const over_slot = !app.scrollbar_dragging and !app.hscroll_dragging and
                    !over_scrollbar and !over_hscroll and
                    mouse.x >= row_box.x and mouse.x <= row_box.x + row_box.width and
                    mouse.y >= slot_top and mouse.y < slot_top + slot_h;
                rl.drawRectangleRec(
                    .init(row_box.x, row_box.y, row_box.width, row_box.height),
                    toRaylibColor(if (over_slot) .{
                        30,
                        42,
                        66,
                        255,
                    } else slot_bg),
                );
                var hit_index: ?usize = null;
                for (app.packed_touched_columns.items) |px| {
                    app.packed_columns.items[px] = null;
                }
                app.packed_touched_columns.clearRetainingCapacity();
                const packed_width = @max(
                    1,
                    @as(usize, @intFromFloat(@floor(timeline_width))),
                );
                const old_packed_width = app.packed_columns.items.len;
                try app.packed_columns.resize(app.gpa, packed_width);
                if (packed_width > old_packed_width) {
                    @memset(app.packed_columns.items[old_packed_width..], null);
                }
                const members = process_tree.slotMembers(app, slot);
                const first_visible = process_tree.firstPackedVisible(
                    members,
                    session.processes.items,
                    window.start_ns,
                    now_ns,
                );
                const view_end_ns = window.start_ns + view_span;
                for (members[first_visible..]) |index| {
                    const process = &session.processes.items[index];
                    if (process.start_ns >= view_end_ns) break;
                    const has_kids = process_tree.hasChildren(app, index);
                    // Same bar geometry as regular process rows; lanes keep
                    // their normal row spacing instead of stretching bars.
                    const bar = lifetimeBar(process, now_ns, .{
                        .window = window,
                        .view_span = view_span,
                        .timeline_x = timeline_x,
                        .timeline_width = timeline_width,
                        .y = y,
                        .row_height = row_height,
                    });
                    if (bar) |b| {
                        if (b.width <= 2) {
                            const px_f = @floor(b.x - timeline_x);
                            if (px_f >= 0) {
                                const px: usize = @intFromFloat(px_f);
                                if (px < packed_width) {
                                    if (app.packed_columns.items[px] == null) {
                                        try app.packed_touched_columns.append(app.gpa, px);
                                    }
                                    app.packed_columns.items[px] = index;
                                }
                            }
                            if (over_slot and pointInRect(mouse, b)) hit_index = index;
                            continue;
                        }
                        const look = BarLook{
                            .color = processColor(has_kids, process.end_ns == null),
                            .font = row_font,
                            .ink = barNameInk(process.rowNameKind(), has_kids),
                            .rounded = !multi and b.width >= 8,
                        };
                        paintLifetimeBar(app, index, b, look);
                        try paintCpuSlices(app, process, .{
                            .window = window,
                            .view_span = view_span,
                            .timeline_x = timeline_x,
                            .timeline_width = timeline_width,
                            .y = y,
                            .row_height = row_height,
                        }, input.host_cpu_count);
                        paintBarLabel(app, process, index, session.metadataBytes(), b, look);
                        if (over_slot and pointInRect(mouse, b)) {
                            hit_index = index;
                        }
                    }
                }
                for (app.packed_touched_columns.items) |px| {
                    const index = app.packed_columns.items[px] orelse continue;
                    rl.drawRectangleRec(
                        .init(
                            timeline_x + @as(f32, @floatFromInt(px)),
                            y,
                            1,
                            row_height - process_row_gap,
                        ),
                        processColor(
                            process_tree.hasChildren(app, index),
                            session.processes.items[index].end_ns == null,
                        ),
                    );
                }

                const collapse_target: ?process_tree.RowCollapseTarget = target: {
                    if (slot.subrow != 0) break :target null;
                    const head = slot.head orelse break :target null;
                    const target = process_tree.RowCollapseTarget{ .packed_row = head };
                    if (!process_tree.canCollapseRow(app, target)) break :target null;
                    break :target target;
                };
                const button = if (collapse_target != null)
                    collapseButton(collapse_gutter)
                else
                    null;
                const over_button = if (button) |control|
                    over_row and pointInRect(mouse, control.hit_box)
                else
                    false;
                if (over_button) rl.setMouseCursor(.pointing_hand);
                if (button) |control| {
                    paintCollapseButton(
                        control,
                        process_tree.isRowCollapsed(app, collapse_target.?),
                        over_button,
                    );
                }

                if (!over_button) {
                    if (hit_index) |index| {
                        hovered = .{ .process_index = index };
                    }
                }
                if (clicked) {
                    const target = resolveTimelineClick(
                        if (over_button) collapse_target else null,
                        hit_index,
                    );
                    if (target) |click_target| applyTimelineClick(app, click_target);
                }
            },
        }
    }

    if (needs_hscroll) {
        rl.drawRectangleRounded(
            .init(h_track.x, h_track.y, h_track.width, h_track.height),
            0.5,
            4,
            toRaylibColor(.{
                12,
                18,
                32,
                255,
            }),
        );
        const h_color: clay.Color = if (app.hscroll_dragging)
            .{
                92,
                151,
                255,
                255,
            }
        else if (over_hscroll)
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
        rl.drawRectangleRounded(
            .init(h_thumb_draw_x, h_thumb.y, h_thumb.width, h_thumb.height),
            0.5,
            4,
            toRaylibColor(h_color),
        );
    }
    if (needs_scroll) {
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
        const thumb_color: clay.Color = if (app.scrollbar_dragging)
            .{
                92,
                151,
                255,
                255,
            }
        else if (over_scrollbar)
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
        rl.drawRectangleRounded(
            .init(thumb.x, thumb.y, thumb.width, thumb.height),
            0.5,
            4,
            toRaylibColor(thumb_color),
        );
    }
    rl.endScissorMode();
    // The caller draws the tooltip after every other layer so it stays on top.
    return hovered;
}

const tooltip_max_width: f32 = 560;
// Fixed pixel radius. A proportional radius made tall tooltips' corners round
// enough to swallow the first and last text rows.
const tooltip_corner_radius: f32 = 4;
// `numerator / denominator` as f32 for scrollbar geometry; 0 when empty.
fn processColor(has_children: bool, active: bool) rl.Color {
    return toRaylibColor(if (has_children)
        if (active) blue_bright else blue
    else if (active)
        yellow_bright
    else
        yellow);
}

fn barNameInk(kind: tracer.NameKind, has_children: bool) rl.Color {
    var color = toRaylibColor(if (has_children) ink else canvas);
    if (kind == .other) color.a = 205;
    return color;
}

fn pointInBox(point: rl.Vector2, box: clay.BoundingBox) bool {
    return point.x >= box.x and point.x <= box.x + box.width and
        point.y >= box.y and point.y <= box.y + box.height;
}

fn measureText(
    value: []const u8,
    config: *clay.TextElementConfig,
    fonts: *const FontBook,
) clay.Dimensions {
    const font = fonts.get(config.font_id);
    var buffer: [text_buffer_capacity]u8 = undefined;
    const measured = rl.measureTextEx(
        font,
        nullTerminate(value, &buffer),
        @floatFromInt(config.font_size),
        raylibSpacing(font, config.font_size, config.letter_spacing),
    );
    return .{ .w = measured.x, .h = measured.y };
}

fn renderClay(commands: []const clay.RenderCommand, fonts: *const FontBook) void {
    for (commands) |command| {
        const box = command.bounding_box;
        const rectangle = rl.Rectangle.init(box.x, box.y, box.width, box.height);
        switch (command.command_type) {
            .none, .image, .custom => {},
            .rectangle => {
                const data = command.render_data.rectangle;
                const radius = @max(
                    @max(data.corner_radius.top_left, data.corner_radius.top_right),
                    @max(data.corner_radius.bottom_left, data.corner_radius.bottom_right),
                );
                if (radius > 0) {
                    rl.drawRectangleRounded(
                        rectangle,
                        rectangleRoundness(box, radius),
                        12,
                        toRaylibColor(data.background_color),
                    );
                } else {
                    rl.drawRectangleRec(rectangle, toRaylibColor(data.background_color));
                }
            },
            .text => {
                const data = command.render_data.text;
                const font = fonts.get(data.font_id);
                const value = data.string_contents.chars[0..@intCast(data.string_contents.length)];
                var buffer: [text_buffer_capacity]u8 = undefined;
                rl.drawTextEx(
                    font,
                    nullTerminate(value, &buffer),
                    .{ .x = box.x, .y = box.y },
                    @floatFromInt(data.font_size),
                    raylibSpacing(font, data.font_size, data.letter_spacing),
                    toRaylibColor(data.text_color),
                );
            },
            .border => renderBorder(box, command.render_data.border),
            .scissor_start => rl.beginScissorMode(
                @intFromFloat(box.x),
                @intFromFloat(box.y),
                @intFromFloat(box.width),
                @intFromFloat(box.height),
            ),
            .scissor_end => rl.endScissorMode(),
        }
    }
}

fn renderBorder(box: clay.BoundingBox, data: clay.BorderRenderData) void {
    const width = data.width;
    const radius = data.corner_radius.top_left;
    const color = toRaylibColor(data.color);
    const rectangle = rl.Rectangle.init(box.x, box.y, box.width, box.height);
    const uniform_width = width.left > 0 and
        width.left == width.right and width.left == width.top and width.left == width.bottom;
    if (radius > 0 and uniform_width) {
        rl.drawRectangleRoundedLinesEx(
            rectangle,
            rectangleRoundness(box, radius),
            12,
            @floatFromInt(width.left),
            color,
        );
        return;
    }
    if (width.left > 0) {
        rl.drawRectangleRec(
            .init(box.x, box.y, @floatFromInt(width.left), box.height),
            color,
        );
    }
    if (width.right > 0) {
        const thickness: f32 = @floatFromInt(width.right);
        rl.drawRectangleRec(
            .init(box.x + box.width - thickness, box.y, thickness, box.height),
            color,
        );
    }
    if (width.top > 0) {
        rl.drawRectangleRec(
            .init(box.x, box.y, box.width, @floatFromInt(width.top)),
            color,
        );
    }
    if (width.bottom > 0) {
        const thickness: f32 = @floatFromInt(width.bottom);
        rl.drawRectangleRec(
            .init(box.x, box.y + box.height - thickness, box.width, thickness),
            color,
        );
    }
}

fn rectangleRoundness(box: clay.BoundingBox, radius: f32) f32 {
    const shortest_side = @min(box.width, box.height);
    return if (shortest_side > 0) @min(1, (radius * 2) / shortest_side) else 0;
}

fn raylibSpacing(_: rl.Font, _: u16, letter_spacing: u16) f32 {
    return @floatFromInt(letter_spacing);
}

// Inter Regular and Bold, SIL OFL 1.1. The 64px source atlases keep small text
// sharp when raylib downsamples it to each UI size.
const ui_font_ttf = @embedFile("fonts/Inter-Regular.ttf");
const row_font_ttf = @embedFile("fonts/Inter-Bold.ttf");
const footer_font_ttf = footer_font.ttf;
const ui_font_atlas_size: i32 = 64;

const extra_codepoints = [_]i32{
    0x2013, // –
    0x2014, // —
    0x2022, // •
    0x2026, // …
    0x2192, // →
    0x25B8, // ▸
    0x2260, // ≠
};

fn loadFonts() FontBook {
    return .{
        .ui = loadEmbeddedFont(ui_font_ttf, ui_font_atlas_size),
        .row = loadEmbeddedFont(row_font_ttf, ui_font_atlas_size),
        .footer = loadEmbeddedFont(footer_font_ttf, ui_font_atlas_size),
    };
}

fn loadEmbeddedFont(ttf: []const u8, font_size: i32) rl.Font {
    var codepoints: [256]i32 = undefined;
    var count: usize = 0;
    var cp: i32 = 32;
    while (cp < 127) : (cp += 1) {
        codepoints[count] = cp;
        count += 1;
    }
    cp = 160;
    while (cp < 256) : (cp += 1) {
        codepoints[count] = cp;
        count += 1;
    }
    for (extra_codepoints) |extra| {
        codepoints[count] = extra;
        count += 1;
    }
    const font = rl.loadFontFromMemory(
        ".ttf",
        ttf,
        font_size,
        codepoints[0..count],
    ) catch {
        return rl.getFontDefault() catch unreachable;
    };
    rl.setTextureFilter(font.texture, .bilinear);
    return font;
}

fn unloadEmbeddedFont(font: rl.Font) void {
    const fallback = rl.getFontDefault() catch return;
    if (font.texture.id == fallback.texture.id) return;
    rl.unloadFont(font);
}

test "rectangleRoundness scales with the shorter side only" {
    const testing = std.testing;
    try testing.expectEqual(
        @as(f32, 0.2),
        rectangleRoundness(.{
            .x = 0,
            .y = 0,
            .width = 100,
            .height = 200,
        }, 10),
    );
    try testing.expectEqual(
        @as(f32, 0),
        rectangleRoundness(.{
            .x = 0,
            .y = 0,
            .width = 40,
            .height = 0,
        }, 10),
    );
}

test "CPU slice height scales to host capacity" {
    const testing = std.testing;
    const full_row = tracer.Process.CpuSlice{
        .start_ns = 0,
        .end_ns = 100,
        .cpu_ns = 800,
        .band = 32,
    };
    const half_row = tracer.Process.CpuSlice{
        .start_ns = 0,
        .end_ns = 100,
        .cpu_ns = 400,
        .band = 16,
    };

    try testing.expectEqual(@as(f32, 27), cpuSliceHeight(full_row, 28, 8));
    try testing.expectEqual(@as(f32, 18), cpuSliceHeight(half_row, 28, 8));
}

test "CPU slice height fills the row at three quarters of host cores" {
    const testing = std.testing;
    const three_quarter = tracer.Process.CpuSlice{
        .start_ns = 0,
        .end_ns = 100,
        .cpu_ns = 600,
        .band = 24,
    };
    const one_core = tracer.Process.CpuSlice{
        .start_ns = 0,
        .end_ns = 100,
        .cpu_ns = 100,
        .band = 4,
    };

    try testing.expectEqual(@as(f32, 27), cpuSliceHeight(three_quarter, 28, 8));
    try testing.expectEqual(@as(f32, 4.5), cpuSliceHeight(one_core, 28, 8));
}

test "CPU slice height keeps light activity visible" {
    const slice = tracer.Process.CpuSlice{
        .start_ns = 0,
        .end_ns = 100,
        .cpu_ns = 100,
        .band = 4,
    };

    try std.testing.expectEqual(min_cpu_slice_height, cpuSliceHeight(slice, 28, 64));
}

test "CPU slice alpha saturates without integer overflow" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 110), cpuSliceAlpha(0));
    try testing.expectEqual(@as(u8, 220), cpuSliceAlpha(64));
    try testing.expectEqual(@as(u8, 220), cpuSliceAlpha(std.math.maxInt(u8)));
}

test "detail CPU graph spans the selected process lifetime" {
    const process = tracer.Process{
        .pid = 7,
        .start_ns = 100,
        .end_ns = 500,
    };

    const range = detail_pane.detailCpuGraphRange(&process, 900);
    try std.testing.expectEqual(@as(u64, 100), range.start_ns);
    try std.testing.expectEqual(@as(u64, 500), range.end_ns);
    try std.testing.expectEqual(@as(u64, 400), range.spanNs());
    try std.testing.expectEqual(
        @as(f32, 60),
        detail_pane.detailCpuGraphX(range, 300, .init(10, 0, 100, 50)),
    );
}

test "detail CPU graph rounds its scale and caps it to the host" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var process = tracer.Process{ .pid = 7 };
    defer process.deinit(gpa);

    try testing.expectEqual(@as(f64, 1), detail_pane.detailCpuGraphCoreScale(&process, 8));
    try process.cpu_slices.append(gpa, .{
        .start_ns = 0,
        .end_ns = 100,
        .cpu_ns = 250,
        .band = 10,
    });
    try testing.expectEqual(@as(f64, 3), detail_pane.detailCpuGraphCoreScale(&process, 8));
    try testing.expectEqual(@as(f64, 2), detail_pane.detailCpuGraphCoreScale(&process, 2));
}

test "ratio guards division by zero" {
    const testing = std.testing;
    try testing.expectEqual(@as(f32, 0.75), detail_pane.ratio(3, 4));
    try testing.expectEqual(@as(f32, 0), detail_pane.ratio(1, 0));
}

test "collapse controls win clicks over process rows" {
    const testing = std.testing;
    const collapse_target = process_tree.RowCollapseTarget{ .process = 7 };

    try testing.expectEqual(
        TimelineClick{ .collapse = collapse_target },
        resolveTimelineClick(collapse_target, 7).?,
    );
    try testing.expectEqual(
        TimelineClick{ .select = 7 },
        resolveTimelineClick(null, 7).?,
    );
    try testing.expect(resolveTimelineClick(null, null) == null);
}

test "collapse control has a full-row-height hit target" {
    const testing = std.testing;
    const button = collapseButton(
        .init(100, 200, 30, process_row_height - process_row_gap),
    );

    try testing.expect(button.hit_box.width > button.visual_box.width);
    try testing.expectEqual(process_row_height - process_row_gap, button.hit_box.height);
    try testing.expect(pointInRect(.{ .x = 107, .y = 226 }, button.hit_box));
}

test "collapse control has equal padding between the window edge and blocks" {
    const testing = std.testing;
    const height = process_row_height - process_row_gap;
    const window_x: f32 = 100;
    const block_x = window_x + collapse_button_size + collapse_button_padding * 2;
    const button = collapseButton(.init(window_x, 200, block_x - window_x, height));
    const visual_left = button.visual_box.x - window_x;
    const visual_right = block_x - (button.visual_box.x + button.visual_box.width);
    const hit_left = button.hit_box.x - window_x;
    const hit_right = block_x - (button.hit_box.x + button.hit_box.width);

    try testing.expectEqual(visual_left, visual_right);
    try testing.expectEqual(collapse_button_padding, visual_left);
    try testing.expectEqual(hit_left, hit_right);
    try testing.expectEqual(collapse_button_hit_width, button.hit_box.width);
}

test "timeline tick labels stay inside the timeline" {
    const testing = std.testing;
    const timeline_x: f32 = 40;
    const timeline_width: f32 = 200;
    const label_width: f32 = 20;

    try testing.expectEqual(
        timeline_x,
        timelineTickLabelX(timeline_x, label_width, timeline_x, timeline_width),
    );
    try testing.expectEqual(
        timeline_x + timeline_width - label_width,
        timelineTickLabelX(
            timeline_x + timeline_width,
            label_width,
            timeline_x,
            timeline_width,
        ),
    );
    try testing.expectEqual(
        @as(f32, 130),
        timelineTickLabelX(140, label_width, timeline_x, timeline_width),
    );
}

test "horizontal scrollbar requires visible thumb travel" {
    const testing = std.testing;
    const total_ns: u64 = 1_000;

    try testing.expect(!needsHorizontalScrollbar(
        .{ .start_ns = 0, .span_ns = total_ns },
        total_ns,
        200,
    ));
    try testing.expect(!needsHorizontalScrollbar(
        .{ .start_ns = 0, .span_ns = total_ns - 1 },
        total_ns,
        200,
    ));
    try testing.expect(!needsHorizontalScrollbar(
        .{ .start_ns = 0, .span_ns = total_ns / 2 },
        total_ns,
        scrollbar_min_thumb_size,
    ));
    try testing.expect(needsHorizontalScrollbar(
        .{ .start_ns = 0, .span_ns = total_ns / 2 },
        total_ns,
        200,
    ));
}

test "root collapse survives process-tree rebuild" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var session = tracer.Session.init(gpa, testing.io);
    defer session.deinit();
    try session.processes.append(gpa, .{ .pid = 1, .end_ns = 100 });
    try session.processes.append(gpa, .{
        .pid = 2,
        .parent_pid = 1,
        .parent_index = 0,
        .depth = 1,
        .end_ns = 100,
    });

    var app = try App.init(gpa);
    defer app.deinit();
    try process_tree.ensureProcessTree(&app, &session);
    try testing.expectEqual(@as(usize, 2), app.row_order.items.len);

    process_tree.toggleCollapsed(&app, 0);
    try process_tree.ensureProcessTree(&app, &session);
    try testing.expect(process_tree.isCollapsed(&app, 0));
    try testing.expectEqual(@as(usize, 1), app.row_order.items.len);
}

test "master collapse button toggles every collapsible row" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var session = tracer.Session.init(gpa, testing.io);
    defer session.deinit();
    try session.processes.append(gpa, .{ .pid = 1, .end_ns = 100 });
    try session.processes.append(gpa, .{
        .pid = 2,
        .parent_pid = 1,
        .parent_index = 0,
        .depth = 1,
        .end_ns = 100,
    });
    try session.processes.append(gpa, .{
        .pid = 3,
        .parent_pid = 2,
        .parent_index = 1,
        .depth = 2,
        .end_ns = 100,
    });

    var app = try App.init(gpa);
    defer app.deinit();
    try process_tree.ensureProcessTree(&app, &session);

    try testing.expect(!process_tree.allCollapsibleRowsCollapsed(&app));
    process_tree.toggleAllRowsCollapsed(&app);
    try testing.expect(process_tree.allCollapsibleRowsCollapsed(&app));
    try testing.expect(process_tree.isCollapsed(&app, 0));
    try testing.expect(process_tree.isCollapsed(&app, 1));

    process_tree.toggleAllRowsCollapsed(&app);
    try testing.expect(!process_tree.allCollapsibleRowsCollapsed(&app));
    try testing.expect(!process_tree.isCollapsed(&app, 0));
    try testing.expect(!process_tree.isCollapsed(&app, 1));
}

test "packed row collapse toggles every block and reduces the lane to one row" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var session = tracer.Session.init(gpa, testing.io);
    defer session.deinit();
    try session.processes.append(gpa, .{ .pid = 1, .end_ns = 200 });
    try session.processes.append(gpa, .{
        .pid = 2,
        .parent_pid = 1,
        .parent_index = 0,
        .depth = 1,
        .end_ns = 80,
    });
    try session.processes.append(gpa, .{
        .pid = 3,
        .parent_pid = 1,
        .parent_index = 0,
        .depth = 1,
        .start_ns = 100,
        .end_ns = 180,
    });
    try session.processes.append(gpa, .{
        .pid = 4,
        .parent_pid = 2,
        .parent_index = 1,
        .depth = 2,
        .start_ns = 10,
        .end_ns = 40,
    });
    try session.processes.append(gpa, .{
        .pid = 5,
        .parent_pid = 3,
        .parent_index = 2,
        .depth = 2,
        .start_ns = 110,
        .end_ns = 140,
    });

    var app = try App.init(gpa);
    defer app.deinit();
    try process_tree.ensureProcessTree(&app, &session);
    try testing.expectEqual(@as(usize, 3), app.row_order.items.len);
    try testing.expect(graphRowsContainProcess(&app, 3));
    try testing.expect(graphRowsContainProcess(&app, 4));

    const target = process_tree.RowCollapseTarget{ .packed_row = 1 };
    try testing.expect(process_tree.canCollapseRow(&app, target));
    try testing.expect(!process_tree.isRowCollapsed(&app, target));
    process_tree.toggleRowCollapsed(&app, target);
    try process_tree.ensureProcessTree(&app, &session);
    try testing.expect(process_tree.isCollapsed(&app, 1));
    try testing.expect(process_tree.isCollapsed(&app, 2));
    try testing.expect(process_tree.isRowCollapsed(&app, target));
    try testing.expectEqual(@as(usize, 2), app.row_order.items.len);
    try testing.expect(graphRowsContainProcess(&app, 1));
    try testing.expect(graphRowsContainProcess(&app, 2));
    try testing.expect(!graphRowsContainProcess(&app, 3));
    try testing.expect(!graphRowsContainProcess(&app, 4));

    process_tree.toggleRowCollapsed(&app, target);
    try process_tree.ensureProcessTree(&app, &session);
    try testing.expect(!process_tree.isCollapsed(&app, 1));
    try testing.expect(!process_tree.isCollapsed(&app, 2));
    try testing.expectEqual(@as(usize, 3), app.row_order.items.len);
    try testing.expect(graphRowsContainProcess(&app, 3));
    try testing.expect(graphRowsContainProcess(&app, 4));
}

fn graphRowsContainProcess(app: *const App, target: usize) bool {
    for (app.row_order.items) |row| switch (row) {
        .process => |index| if (index == target) return true,
        .slot => |slot| {
            for (process_tree.slotMembers(app, slot)) |index| {
                if (index == target) return true;
            }
        },
    };
    return false;
}

// Pull child files into this binary so their `test` blocks run here too
// (Zig collects `test` blocks from each step's root source file only).
test {
    _ = @import("App.zig");
    _ = @import("text.zig");
    _ = @import("process_info.zig");
    _ = @import("theme.zig");
    _ = @import("perf.zig");
}
