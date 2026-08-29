//! Flamez entry point and raylib/Clay renderer for live process timelines.

const std = @import("std");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;

const clay = @import("zclay");
const rl = @import("raylib");
const footer_font = @import("footer_font");
const tracer = @import("tracer.zig");
const App = @import("App.zig");
const page_layout = @import("layout.zig");
const theme = @import("theme.zig");
const text = @import("text.zig");
const process_info = @import("process_info.zig");
const perf = @import("perf.zig");

const log = std.log.scoped(.flamez);

const canvas = theme.canvas;
const panel_raised = theme.panel_raised;
const border = theme.border;
const accent = theme.accent;
const blue = theme.blue;
const yellow = theme.yellow;
const cpu_hot = theme.cpu_hot;
const ink = theme.ink;
const muted = theme.muted;
const faint = theme.faint;
const danger = theme.danger;
const toRaylibColor = theme.toRaylibColor;

const text_buffer_capacity = text.text_buffer_capacity;
const ui_glyph_spacing = text.ui_glyph_spacing;
const nullTerminate = text.nullTerminate;
const formatDuration = text.formatDuration;
const measureTextSlice = text.measureTextSlice;
const drawTextSlice = text.drawTextSlice;
const drawClippedAt = text.drawClippedAt;
const drawTextSliceClipped = text.drawTextSliceClipped;

const TooltipLine = process_info.TooltipLine;
const TooltipBuilder = process_info.TooltipBuilder;
const InfoSizes = process_info.InfoSizes;
const buildProcessInfo = process_info.buildProcessInfo;
const tooltip_more_marker = process_info.tooltip_more_marker;
const tooltip_max_rows = process_info.tooltip_max_rows;

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

    // eBPF capture is mandatory: fail fast with guidance, before any window
    // is opened. There is no procfs lifecycle fallback.
    var ebpf = tracer.EbpfCollector.init();
    if (!ebpf.available()) {
        std.debug.print(
            \\flamez: cannot start — eBPF process-event capture is required.
            \\
            \\Failed because: {s}
            \\
            \\Fixes:
            \\  • run ./build.sh to install flamez with
            \\    cap_bpf,cap_perfmon
            \\
        , .{ebpf.diagnosticSlice()});
        std.process.exit(1);
    }
    var ebpf_attached = true;
    defer if (ebpf_attached) ebpf.deinit();

    ebpf.dropCapabilities() catch {
        std.debug.print("flamez: could not drop eBPF capabilities after attach\n", .{});
        std.process.exit(1);
    };
    var session = tracer.Session.init(init.gpa, init.io);
    defer session.deinit();
    var start_error: ?tracer.Session.StartError = null;
    session.start(&ebpf, target_argv.items) catch |err| {
        start_error = err;
    };
    var app = try App.init(init.gpa);
    defer app.deinit();
    const host_cpu_count = @max(std.Thread.getCpuCount() catch 1, 1);
    if (start_error) |err| {
        app.setMessage("Could not start target: {s}", .{@errorName(err)});
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
    rl.initWindow(window_width, window_height, "Flamez — process lifetime profiler");
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
    perf.beginSession(init.io);

    while (!rl.windowShouldClose()) {
        perf.beginFrame();
        const frame_time = rl.getFrameTime();
        const mouse = rl.getMousePosition();
        const wheel = rl.getMouseWheelMoveV();
        const tapped = rl.isGestureDetected(.{ .tap = true }) or
            rl.isGestureDetected(.{ .doubletap = true });
        const clicked = rl.isMouseButtonPressed(.left) or tapped;
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
            session.update(&ebpf);
            perf.noteSnapshot(ebpf.last_cpu_samples, ebpf.last_ring_events);
        }
        if (!session.running and ebpf_attached) {
            ebpf.deinit();
            ebpf_attached = false;
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
        try renderDetailPane(&app, &session, frame_input);
        perf.leave();
        // Draw last so the hover tooltip is never covered by the detail pane.
        if (hovered) |target| renderProcessTooltip(&app, &session, target, font, mouse);
        perf.enter(.end_drawing);
        rl.endDrawing();
        perf.leave();
        perf.endFrame();
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

fn ensureProcessTree(
    app: *App,
    session: *const tracer.Session,
) Allocator.Error!void {
    const topology_stale = app.topology_revision_seen != session.topology_revision;
    const collapse_stale = app.collapse_revision_seen != app.collapse_revision;
    const pack_stale = topology_stale or collapse_stale or
        (!session.running and app.interval_revision_seen != session.interval_revision);
    if (!topology_stale and !collapse_stale and !pack_stale) return;
    perf.enter(.tree_rebuild);
    defer perf.leave();
    try rebuildProcessTree(app, session);
    app.topology_revision_seen = session.topology_revision;
    app.interval_revision_seen = session.interval_revision;
    app.collapse_revision_seen = app.collapse_revision;
}

fn rebuildProcessTree(
    app: *App,
    session: *const tracer.Session,
) Allocator.Error!void {
    const n = session.processes.items.len;
    try app.first_child.ensureTotalCapacity(app.gpa, n);
    try app.next_sibling.ensureTotalCapacity(app.gpa, n);
    try app.visual_depth.ensureTotalCapacity(app.gpa, n);
    try app.pack_slot.ensureTotalCapacity(app.gpa, n);
    try app.slot_next.ensureTotalCapacity(app.gpa, n);
    try app.lane_height_off.ensureTotalCapacity(app.gpa, n);
    try app.last_child_scratch.ensureTotalCapacity(app.gpa, n);
    try app.bar_name_widths.ensureTotalCapacity(app.gpa, n);
    try app.bar_name_hashes.ensureTotalCapacity(app.gpa, n);
    if (app.bar_name_widths.items.len < n) {
        const old_len = app.bar_name_widths.items.len;
        try app.bar_name_widths.resize(app.gpa, n);
        @memset(app.bar_name_widths.items[old_len..], -1);
        try app.bar_name_hashes.resize(app.gpa, n);
        @memset(app.bar_name_hashes.items[old_len..], 0);
    }
    if (app.collapsed.items.len < n) {
        try app.collapsed.ensureTotalCapacity(app.gpa, n);
    }

    app.row_order.clearRetainingCapacity();
    app.first_child.clearRetainingCapacity();
    app.next_sibling.clearRetainingCapacity();
    app.visual_depth.clearRetainingCapacity();
    app.pack_slot.clearRetainingCapacity();
    app.slot_next.clearRetainingCapacity();
    app.packed_members.clearRetainingCapacity();
    app.lane_height_off.clearRetainingCapacity();
    app.lane_heights.clearRetainingCapacity();
    app.last_child_scratch.clearRetainingCapacity();
    app.roots_scratch.clearRetainingCapacity();
    if (n == 0) return;
    app.first_child.appendNTimesAssumeCapacity(null, n);
    app.next_sibling.appendNTimesAssumeCapacity(null, n);
    app.visual_depth.appendNTimesAssumeCapacity(0, n);
    app.pack_slot.appendNTimesAssumeCapacity(0, n);
    app.slot_next.appendNTimesAssumeCapacity(null, n);
    app.lane_height_off.appendNTimesAssumeCapacity(0, n);
    app.last_child_scratch.appendNTimesAssumeCapacity(null, n);
    if (app.collapsed.items.len < n) {
        app.collapsed.appendNTimesAssumeCapacity(false, n - app.collapsed.items.len);
    }

    // Parent identity is Process.parent_index; Flamez does not retain a
    // parallel visual-parent array. pack_root/pack_job/slot_count are derived
    // from the packed row model and are not stored.
    for (0..n) |index| {
        const process = &session.processes.items[index];
        if (process.parent_index) |parent| {
            app.visual_depth.items[index] = app.visual_depth.items[parent] + 1;
            if (app.first_child.items[parent] == null) {
                app.first_child.items[parent] = index;
            } else if (app.last_child_scratch.items[parent]) |prev| {
                app.next_sibling.items[prev] = index;
            }
            app.last_child_scratch.items[parent] = index;
        } else {
            try app.roots_scratch.append(app.gpa, index);
        }
    }

    const now_ns = session.timelineNs();
    for (app.roots_scratch.items) |root| try appendSubtree(app, session, root, now_ns);
}

fn isCollapsed(app: *const App, index: usize) bool {
    return index < app.collapsed.items.len and app.collapsed.items[index];
}

const RowCollapseTarget = union(enum) {
    process: usize,
    packed_row: usize,
};

fn hasChildren(app: *const App, index: usize) bool {
    return index < app.first_child.items.len and app.first_child.items[index] != null;
}

fn canCollapseRow(app: *const App, target: RowCollapseTarget) bool {
    switch (target) {
        .process => |index| return hasChildren(app, index),
        .packed_row => |head| {
            var member: ?usize = head;
            while (member) |index| : (member = app.slot_next.items[index]) {
                if (hasChildren(app, index)) return true;
            }
            return false;
        },
    }
}

fn isRowCollapsed(app: *const App, target: RowCollapseTarget) bool {
    switch (target) {
        .process => |index| return isCollapsed(app, index),
        .packed_row => |head| {
            var found = false;
            var member: ?usize = head;
            while (member) |index| : (member = app.slot_next.items[index]) {
                if (!hasChildren(app, index)) continue;
                found = true;
                if (!isCollapsed(app, index)) return false;
            }
            return found;
        },
    }
}

fn setCollapsed(app: *App, index: usize, collapsed: bool) bool {
    if (index >= app.collapsed.items.len or app.collapsed.items[index] == collapsed) return false;
    app.collapsed.items[index] = collapsed;
    return true;
}

fn toggleRowCollapsed(app: *App, target: RowCollapseTarget) void {
    const collapsed = !isRowCollapsed(app, target);
    var changed = false;
    switch (target) {
        .process => |index| changed = setCollapsed(app, index, collapsed),
        .packed_row => |head| {
            var member: ?usize = head;
            while (member) |index| : (member = app.slot_next.items[index]) {
                if (!hasChildren(app, index)) continue;
                changed = setCollapsed(app, index, collapsed) or changed;
            }
        },
    }
    if (changed) app.collapse_revision +%= 1;
}

fn allCollapsibleRowsCollapsed(app: *const App) bool {
    var found = false;
    for (app.first_child.items, 0..) |first_child, index| {
        if (first_child == null) continue;
        found = true;
        if (!isCollapsed(app, index)) return false;
    }
    return found;
}

fn toggleAllRowsCollapsed(app: *App) void {
    const collapsed = !allCollapsibleRowsCollapsed(app);
    var changed = false;
    for (app.first_child.items, 0..) |first_child, index| {
        if (first_child == null) continue;
        changed = setCollapsed(app, index, collapsed) or changed;
    }
    if (changed) app.collapse_revision +%= 1;
}

fn toggleCollapsed(app: *App, index: usize) void {
    toggleRowCollapsed(app, .{ .process = index });
}

const JobSpan = App.JobSpan;

const JobBounds = struct {
    start_ns: u64,
    end_ns: u64,
    height: u16 = 1,
};

const JobWalk = struct {
    base_depth: u16,
    now_ns: u64,
    bounds: *JobBounds,
};

fn appendSubtree(
    app: *App,
    session: *const tracer.Session,
    index: usize,
    now_ns: u64,
) Allocator.Error!void {
    try app.row_order.append(app.gpa, .{ .process = index });
    if (isCollapsed(app, index)) return;
    const first = if (index < app.first_child.items.len) app.first_child.items[index] else null;
    const child_index = first orelse return;
    const unary = app.next_sibling.items[child_index] == null;
    const child_has_kids = child_index < app.first_child.items.len and
        app.first_child.items[child_index] != null;
    if (unary and child_has_kids) {
        try appendSubtree(app, session, child_index, now_ns);
        return;
    }

    var job_count: usize = 0;
    var child = first;
    while (child) |job_root| : (child = app.next_sibling.items[job_root]) job_count += 1;
    app.jobs_scratch.clearRetainingCapacity();
    try app.jobs_scratch.ensureTotalCapacity(app.gpa, job_count);

    child = first;
    while (child) |job_root| {
        app.jobs_scratch.appendAssumeCapacity(collectJob(app, session, job_root, now_ns));
        child = app.next_sibling.items[job_root];
    }
    if (app.jobs_scratch.items.len == 0) return;

    const lanes = try assignJobSlots(app, app.jobs_scratch.items);
    try app.lane_heights.ensureUnusedCapacity(app.gpa, app.heights_scratch.items.len);
    var slot_rows: usize = 0;
    for (app.heights_scratch.items) |height| slot_rows += height;
    try app.row_order.ensureUnusedCapacity(app.gpa, slot_rows);
    app.lane_offsets_scratch.clearRetainingCapacity();
    try app.lane_offsets_scratch.ensureTotalCapacity(app.gpa, lanes);
    var row_offset: usize = 0;
    for (app.heights_scratch.items) |height| {
        app.lane_offsets_scratch.appendAssumeCapacity(row_offset);
        row_offset += height;
    }

    if (index < app.lane_height_off.items.len)
        app.lane_height_off.items[index] = @intCast(app.lane_heights.items.len);
    for (app.heights_scratch.items) |height| app.lane_heights.appendAssumeCapacity(height);
    const row_base = app.row_order.items.len;
    var lane: u16 = 0;
    while (lane < lanes) : (lane += 1) {
        const height = if (lane < app.heights_scratch.items.len)
            app.heights_scratch.items[lane]
        else
            1;
        var subrow: u16 = 0;
        while (subrow < height) : (subrow += 1) {
            app.row_order.appendAssumeCapacity(.{
                .slot = .{ .parent = index, .lane = lane, .subrow = subrow },
            });
        }
    }
    for (app.jobs_scratch.items) |job| {
        linkPackedSubtree(app, job.root, visualDepth(app, job.root), row_base);
    }
    try flattenPackedMembers(app, session, row_base, slot_rows);
}

fn collectJob(
    app: *App,
    session: *const tracer.Session,
    job_root: usize,
    now_ns: u64,
) JobSpan {
    var bounds = JobBounds{
        .start_ns = session.processes.items[job_root].start_ns,
        .end_ns = session.processes.items[job_root].end_ns orelse now_ns,
    };
    markJobTree(app, session, job_root, .{
        .base_depth = visualDepth(app, job_root),
        .now_ns = now_ns,
        .bounds = &bounds,
    });
    return .{
        .root = job_root,
        .start_ns = bounds.start_ns,
        .end_ns = bounds.end_ns,
        .height = bounds.height,
    };
}

fn markJobTree(
    app: *App,
    session: *const tracer.Session,
    index: usize,
    walk: JobWalk,
) void {
    const proc = session.processes.items[index];
    if (proc.start_ns < walk.bounds.start_ns) walk.bounds.start_ns = proc.start_ns;
    const proc_end = proc.end_ns orelse walk.now_ns;
    if (proc_end > walk.bounds.end_ns) walk.bounds.end_ns = proc_end;
    const rel = visualDepth(app, index) -| walk.base_depth;
    if (rel + 1 > walk.bounds.height) walk.bounds.height = rel + 1;
    if (isCollapsed(app, index)) return;
    var child = if (index < app.first_child.items.len) app.first_child.items[index] else null;
    while (child) |child_index| {
        markJobTree(app, session, child_index, walk);
        child = app.next_sibling.items[child_index];
    }
}

fn jobLessThan(_: void, a: JobSpan, b: JobSpan) bool {
    if (a.start_ns != b.start_ns) return a.start_ns < b.start_ns;
    return a.root < b.root;
}

fn laneOccLess(_: void, a: App.LaneOcc, b: App.LaneOcc) bool {
    if (a.end_ns != b.end_ns) return a.end_ns < b.end_ns;
    return a.lane < b.lane;
}

fn siftUpOcc(items: []App.LaneOcc, start: usize) void {
    var i = start;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (!laneOccLess({}, items[i], items[parent])) break;
        const tmp = items[i];
        items[i] = items[parent];
        items[parent] = tmp;
        i = parent;
    }
}

fn siftDownOcc(items: []App.LaneOcc, start: usize) void {
    var i = start;
    while (true) {
        var best = i;
        const left = 2 * i + 1;
        const right = 2 * i + 2;
        if (left < items.len and laneOccLess({}, items[left], items[best])) best = left;
        if (right < items.len and laneOccLess({}, items[right], items[best])) best = right;
        if (best == i) break;
        const tmp = items[i];
        items[i] = items[best];
        items[best] = tmp;
        i = best;
    }
}

fn siftUpLane(items: []u16, start: usize) void {
    var i = start;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (items[i] >= items[parent]) break;
        const tmp = items[i];
        items[i] = items[parent];
        items[parent] = tmp;
        i = parent;
    }
}

fn siftDownLane(items: []u16, start: usize) void {
    var i = start;
    while (true) {
        var best = i;
        const left = 2 * i + 1;
        const right = 2 * i + 2;
        if (left < items.len and items[left] < items[best]) best = left;
        if (right < items.len and items[right] < items[best]) best = right;
        if (best == i) break;
        const tmp = items[i];
        items[i] = items[best];
        items[best] = tmp;
        i = best;
    }
}

fn layoutJobLanes(
    app: *App,
    jobs: []JobSpan,
) Allocator.Error!u16 {
    app.occupied_scratch.clearRetainingCapacity();
    app.free_lanes_scratch.clearRetainingCapacity();
    app.heights_scratch.clearRetainingCapacity();
    try app.occupied_scratch.ensureTotalCapacity(app.gpa, jobs.len);
    try app.free_lanes_scratch.ensureTotalCapacity(app.gpa, jobs.len);
    try app.heights_scratch.ensureTotalCapacity(app.gpa, jobs.len);

    std.sort.pdq(JobSpan, jobs, {}, jobLessThan);
    var next_lane: u16 = 0;
    for (jobs) |*job| {
        while (app.occupied_scratch.items.len > 0 and
            app.occupied_scratch.items[0].end_ns <= job.start_ns)
        {
            const freed = app.occupied_scratch.items[0];
            const last = app.occupied_scratch.items[app.occupied_scratch.items.len - 1];
            app.occupied_scratch.items.len -= 1;
            if (app.occupied_scratch.items.len > 0) {
                app.occupied_scratch.items[0] = last;
                siftDownOcc(app.occupied_scratch.items, 0);
            }
            app.free_lanes_scratch.appendAssumeCapacity(freed.lane);
            siftUpLane(app.free_lanes_scratch.items, app.free_lanes_scratch.items.len - 1);
        }

        const lane: u16 = if (app.free_lanes_scratch.items.len > 0) blk: {
            const id = app.free_lanes_scratch.items[0];
            const last = app.free_lanes_scratch.items[app.free_lanes_scratch.items.len - 1];
            app.free_lanes_scratch.items.len -= 1;
            if (app.free_lanes_scratch.items.len > 0) {
                app.free_lanes_scratch.items[0] = last;
                siftDownLane(app.free_lanes_scratch.items, 0);
            }
            break :blk id;
        } else blk: {
            const id = next_lane;
            next_lane += 1;
            app.heights_scratch.appendAssumeCapacity(0);
            break :blk id;
        };
        if (lane < app.heights_scratch.items.len and
            job.height > app.heights_scratch.items[lane])
        {
            app.heights_scratch.items[lane] = job.height;
        }
        app.occupied_scratch.appendAssumeCapacity(.{ .end_ns = job.end_ns, .lane = lane });
        siftUpOcc(app.occupied_scratch.items, app.occupied_scratch.items.len - 1);
        job.lane = lane;
    }
    return next_lane;
}

fn assignJobSlots(
    app: *App,
    jobs: []JobSpan,
) Allocator.Error!u16 {
    const lanes = try layoutJobLanes(app, jobs);
    for (jobs) |job| setSubtreeSlot(app, job.root, job.lane);
    perf.noteRebuild(jobs.len);
    return lanes;
}

fn setSubtreeSlot(app: *App, index: usize, lane: u16) void {
    if (index < app.pack_slot.items.len) app.pack_slot.items[index] = lane;
    if (isCollapsed(app, index)) return;
    var child = if (index < app.first_child.items.len) app.first_child.items[index] else null;
    while (child) |child_index| {
        setSubtreeSlot(app, child_index, lane);
        child = app.next_sibling.items[child_index];
    }
}

fn linkPackedSubtree(app: *App, index: usize, base_depth: u16, row_base: usize) void {
    const lane = app.pack_slot.items[index];
    const subrow = visualDepth(app, index) -| base_depth;
    const row_index = row_base + app.lane_offsets_scratch.items[lane] + subrow;
    switch (app.row_order.items[row_index]) {
        .slot => {},
        .process => unreachable,
    }
    const slot = &app.row_order.items[row_index].slot;
    if (slot.tail) |tail| {
        app.slot_next.items[tail] = index;
    } else {
        slot.head = index;
    }
    slot.tail = index;
    if (isCollapsed(app, index)) return;
    var child = app.first_child.items[index];
    while (child) |child_index| {
        linkPackedSubtree(app, child_index, base_depth, row_base);
        child = app.next_sibling.items[child_index];
    }
}

fn packedMemberLessThan(processes: []const tracer.Process, a: usize, b: usize) bool {
    if (processes[a].start_ns != processes[b].start_ns) {
        return processes[a].start_ns < processes[b].start_ns;
    }
    return a < b;
}

fn flattenPackedMembers(
    app: *App,
    session: *const tracer.Session,
    row_base: usize,
    slot_rows: usize,
) Allocator.Error!void {
    const processes = session.processes.items;
    for (row_base..row_base + slot_rows) |row_index| {
        const slot = &app.row_order.items[row_index].slot;
        slot.members_off = @intCast(app.packed_members.items.len);
        var member = slot.head;
        while (member) |index| : (member = app.slot_next.items[index]) {
            try app.packed_members.append(app.gpa, index);
        }
        slot.members_len = @intCast(app.packed_members.items.len - slot.members_off);
        if (slot.members_len > 0) {
            const members = app.packed_members.items[slot.members_off..][0..slot.members_len];
            std.mem.sort(usize, members, processes, packedMemberLessThan);
            slot.head = members[0];
            slot.tail = members[members.len - 1];
            for (members, 0..) |index, i| {
                app.slot_next.items[index] = if (i + 1 < members.len) members[i + 1] else null;
            }
        }
    }
}

fn slotMembers(app: *const App, slot: anytype) []const usize {
    const off = slot.members_off;
    const len = slot.members_len;
    if (off >= app.packed_members.items.len) return &.{};
    return app.packed_members.items[off..@min(off + len, app.packed_members.items.len)];
}

fn firstPackedVisible(
    members: []const usize,
    processes: []const tracer.Process,
    window_start_ns: u64,
    now_ns: u64,
) usize {
    var lo: usize = 0;
    var hi: usize = members.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const process = processes[members[mid]];
        const end_ns = process.end_ns orelse now_ns;
        if (end_ns <= window_start_ns) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn laneHeight(app: *const App, parent: usize, lane: u16) u16 {
    if (parent >= app.lane_height_off.items.len) return 1;
    const idx = app.lane_height_off.items[parent] + lane;
    if (idx >= app.lane_heights.items.len) return 1;
    return @max(@as(u16, 1), app.lane_heights.items[idx]);
}

fn visualDepth(app: *const App, index: usize) u16 {
    return if (index < app.visual_depth.items.len) app.visual_depth.items[index] else 0;
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
    rounded: bool,
};

const CollapseButton = struct {
    hit_box: rl.Rectangle,
    visual_box: rl.Rectangle,
};

const TimelineClick = union(enum) {
    collapse: RowCollapseTarget,
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
    collapse_target: ?RowCollapseTarget,
    process_index: ?usize,
) ?TimelineClick {
    if (collapse_target) |target| return .{ .collapse = target };
    if (process_index) |index| return .{ .select = index };
    return null;
}

fn applyTimelineClick(app: *App, target: TimelineClick) void {
    switch (target) {
        .collapse => |collapse_target| toggleRowCollapsed(app, collapse_target),
        .select => |index| {
            app.selected_process = if (app.selected_process == index) null else index;
        },
    }
}

fn paintLifetimeBar(
    app: *const App,
    process: *const tracer.Process,
    index: usize,
    bar: rl.Rectangle,
    look: BarLook,
) void {
    if (look.rounded) {
        rl.drawRectangleRounded(bar, 0.22, 4, look.color);
        if (app.selected_process == index) {
            rl.drawRectangleRoundedLinesEx(bar, 0.22, 4, 2, rl.Color.white);
        } else if (process.end_ns == null) {
            rl.drawRectangleRoundedLinesEx(bar, 0.22, 4, 1, toRaylibColor(accent));
        }
    } else {
        rl.drawRectangleRec(bar, look.color);
        if (app.selected_process == index) {
            rl.drawRectangleLinesEx(bar, 2, rl.Color.white);
        } else if (process.end_ns == null) {
            rl.drawRectangleLinesEx(bar, 1, toRaylibColor(accent));
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
    const name = process.nameSlice();
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
    const summary = process.argSummary(metadata, &summary_buf);
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
    const outline_offsets = [_]rl.Vector2{
        .{ .x = -1, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 0, .y = -1 },
        .{ .x = 0, .y = 1 },
    };
    for (outline_offsets) |offset| {
        drawTextSliceClipped(bar_label, .{
            .font = look.font,
            .position = .{
                .x = label_position.x + offset.x,
                .y = label_position.y + offset.y,
            },
            .size = bar_label_size,
            .color = rl.Color.black,
            .max_width = max_width,
        });
    }
    drawTextSliceClipped(bar_label, .{
        .font = look.font,
        .position = label_position,
        .size = bar_label_size,
        .color = barNameInk(process.name_kind),
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

    try ensureProcessTree(app, session);
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
                    toggleCollapsed(app, idx);
                }
                if (rl.isKeyPressed(.right) and app.collapsed.items[idx]) {
                    toggleCollapsed(app, idx);
                }
            }
        }
    }
    try ensureProcessTree(app, session);
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
    if (clicked and over_master_button) toggleAllRowsCollapsed(app);
    paintCollapseButton(
        master_button,
        allCollapsibleRowsCollapsed(app),
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
                        toRaylibColor(.{ 14, 21, 38, 255 }),
                    );
                }
                const process = &session.processes.items[index];
                const has_children = hasChildren(app, index);
                const color = processColor(has_children);
                const bar = lifetimeBar(process, now_ns, .{
                    .window = window,
                    .view_span = view_span,
                    .timeline_x = timeline_x,
                    .timeline_width = timeline_width,
                    .y = y,
                    .row_height = row_height,
                });
                const collapse_target = RowCollapseTarget{ .process = index };
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
                        toRaylibColor(.{ 30, 42, 66, 255 }),
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
                        .rounded = b.width >= 8,
                    };
                    paintLifetimeBar(app, process, index, b, look);
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
                        isRowCollapsed(app, collapse_target),
                        over_button,
                    );
                }
            },
            .slot => |slot| {
                const parent = slot.parent;
                const lane_h = laneHeight(app, parent, slot.lane);
                const multi = lane_h > 1;
                const slot_bg: clay.Color = if (slot.lane % 2 == 1)
                    .{ 14, 21, 38, 255 }
                else
                    .{ 20, 28, 48, 255 };
                const slot_top = y - @as(f32, @floatFromInt(slot.subrow)) * row_height;
                const slot_h = @as(f32, @floatFromInt(lane_h)) * row_height;
                const over_slot = !app.scrollbar_dragging and !app.hscroll_dragging and
                    !over_scrollbar and !over_hscroll and
                    mouse.x >= row_box.x and mouse.x <= row_box.x + row_box.width and
                    mouse.y >= slot_top and mouse.y < slot_top + slot_h;
                rl.drawRectangleRec(
                    .init(row_box.x, row_box.y, row_box.width, row_box.height),
                    toRaylibColor(if (over_slot) .{ 30, 42, 66, 255 } else slot_bg),
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
                const members = slotMembers(app, slot);
                const first_visible = firstPackedVisible(
                    members,
                    session.processes.items,
                    window.start_ns,
                    now_ns,
                );
                const view_end_ns = window.start_ns + view_span;
                for (members[first_visible..]) |index| {
                    const process = &session.processes.items[index];
                    if (process.start_ns >= view_end_ns) break;
                    const has_kids = hasChildren(app, index);
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
                            .color = processColor(has_kids),
                            .font = row_font,
                            .rounded = !multi and b.width >= 8,
                        };
                        paintLifetimeBar(app, process, index, b, look);
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
                        processColor(hasChildren(app, index)),
                    );
                }

                const collapse_target: ?RowCollapseTarget = target: {
                    if (slot.subrow != 0) break :target null;
                    const head = slot.head orelse break :target null;
                    const target = RowCollapseTarget{ .packed_row = head };
                    if (!canCollapseRow(app, target)) break :target null;
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
                        isRowCollapsed(app, collapse_target.?),
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
            toRaylibColor(.{ 12, 18, 32, 255 }),
        );
        const h_color: clay.Color = if (app.hscroll_dragging)
            .{ 92, 151, 255, 255 }
        else if (over_hscroll)
            .{ 86, 110, 145, 255 }
        else
            .{ 61, 80, 110, 255 };
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
            toRaylibColor(.{ 12, 18, 32, 255 }),
        );
        const thumb_color: clay.Color = if (app.scrollbar_dragging)
            .{ 92, 151, 255, 255 }
        else if (over_scrollbar)
            .{ 86, 110, 145, 255 }
        else
            .{ 61, 80, 110, 255 };
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
fn ratio(numerator: usize, denominator: usize) f32 {
    if (denominator == 0) return 0;
    const numerator_f: f64 = @floatFromInt(numerator);
    const denominator_f: f64 = @floatFromInt(denominator);
    return @floatCast(numerator_f / denominator_f);
}

const detail_line_gap: f32 = 5;
const detail_min_line_glyphs: usize = 8;
const detail_cpu_graph_height: f32 = 174;
const detail_cpu_graph_gap: f32 = 16;

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

const CpuGraphRange = struct {
    start_ns: u64,
    end_ns: u64,

    fn spanNs(self: CpuGraphRange) u64 {
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

fn detailCpuGraphRange(process: *const tracer.Process, now_ns: u64) CpuGraphRange {
    return .{
        .start_ns = process.start_ns,
        .end_ns = @max(process.start_ns, process.end_ns orelse now_ns),
    };
}

fn detailCpuGraphCoreScale(process: *const tracer.Process, host_cpu_count: usize) f64 {
    var observed_cores = process.cpu_peak_cores;
    if (observed_cores <= 0) {
        for (process.cpu_slices.items) |slice| {
            observed_cores = @max(observed_cores, slice.averageCores());
        }
    }
    const host_cores: f64 = @floatFromInt(@max(host_cpu_count, 1));
    return @min(@ceil(@max(observed_cores, 1)), host_cores);
}

fn detailCpuGraphX(range: CpuGraphRange, at_ns: u64, plot: rl.Rectangle) f32 {
    const clipped_ns = std.math.clamp(at_ns, range.start_ns, range.end_ns);
    const offset: f64 = @floatFromInt(clipped_ns -| range.start_ns);
    const span: f64 = @floatFromInt(range.spanNs());
    return plot.x + plot.width * @as(f32, @floatCast(offset / span));
}

fn detailCpuGraphY(cores: f64, core_scale: f64, plot: rl.Rectangle) f32 {
    const fraction = std.math.clamp(cores / core_scale, 0, 1);
    return plot.y + plot.height * (1 - @as(f32, @floatCast(fraction)));
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

    drawTextSlice(
        font,
        "THREAD CPU",
        .{ .x = card.x + 10, .y = card.y + 8 },
        12,
        toRaylibColor(ink),
    );
    const core_scale = detailCpuGraphCoreScale(process, host_cpu_count);
    var scale_buffer: [32]u8 = undefined;
    const scale_label = std.fmt.bufPrint(
        &scale_buffer,
        "0–{d:.0} CORES",
        .{core_scale},
    ) catch "CORES";
    const scale_size = measureTextSlice(font, scale_label, 11);
    drawTextSlice(
        font,
        scale_label,
        .{ .x = card.x + card.width - scale_size.x - 10, .y = card.y + 8 },
        11,
        toRaylibColor(cpu_hot),
    );
    drawTextSliceClipped(
        "ALL THREADS · FULL PROCESS RANGE · SESSION TIME",
        .{
            .font = font,
            .position = .{ .x = card.x + 10, .y = card.y + 25 },
            .size = 11,
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
    const top_core_size = measureTextSlice(font, top_core, 10);
    drawTextSlice(
        font,
        top_core,
        .{ .x = plot.x - top_core_size.x - 7, .y = plot.y - top_core_size.y / 2 },
        10,
        toRaylibColor(muted),
    );
    const zero_size = measureTextSlice(font, "0", 10);
    drawTextSlice(
        font,
        "0",
        .{
            .x = plot.x - zero_size.x - 7,
            .y = plot.y + plot.height - zero_size.y / 2,
        },
        10,
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
        const no_samples_size = measureTextSlice(font, no_samples, 11);
        drawTextSlice(
            font,
            no_samples,
            .{
                .x = plot.x + (plot.width - no_samples_size.x) / 2,
                .y = plot.y + (plot.height - no_samples_size.y) / 2,
            },
            11,
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
    drawTextSlice(font, start_label, .{ .x = plot.x, .y = label_y }, 10, toRaylibColor(muted));
    if (plot.width >= 300) {
        const middle_size = measureTextSlice(font, middle_label, 10);
        drawTextSlice(
            font,
            middle_label,
            .{ .x = plot.x + (plot.width - middle_size.x) / 2, .y = label_y },
            10,
            toRaylibColor(muted),
        );
    }
    const end_size = measureTextSlice(font, end_label, 10);
    drawTextSlice(
        font,
        end_label,
        .{ .x = plot.x + plot.width - end_size.x, .y = label_y },
        10,
        toRaylibColor(muted),
    );
}

fn renderProcessTooltip(
    app: *App,
    session: *const tracer.Session,
    target: TimelineHover,
    font: rl.Font,
    mouse: rl.Vector2,
) void {
    const index = target.process_index;
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
        .{ .x = x, .y = y, .width = box_w, .height = box_h },
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

fn detailByteAtX(font: rl.Font, line: TooltipLine, x: f32) usize {
    if (x <= 0 or line.text.len == 0) return 0;
    if (measureTextSlice(font, line.text, line.size).x <= x) return line.text.len;
    var low: usize = 0;
    var high = line.text.len;
    while (low < high) {
        const middle = low + (high - low + 1) / 2;
        if (measureTextSlice(font, line.text[0..middle], line.size).x <= x) {
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
    mouse: rl.Vector2,
    content: clay.BoundingBox,
    pad: f32,
    leading_height: f32,
) ?DetailTextPosition {
    if (app.detail_line_count == 0) return null;
    const local_x = mouse.x - (content.x + pad);
    const local_y = mouse.y -
        (content.y + pad + leading_height - app.detail_scroll_px);
    if (local_y <= 0) return .{ .line = 0, .byte = detailByteAtX(
        font,
        app.detail_lines[0],
        local_x,
    ) };

    var line_top: f32 = 0;
    for (app.detail_lines[0..app.detail_line_count], 0..) |line, line_index| {
        const line_height = app.detail_line_heights[line_index];
        if (local_y < line_top + line_height + detail_line_gap) {
            return .{
                .line = line_index,
                .byte = if (local_y > line_top + line_height)
                    line.text.len
                else
                    detailByteAtX(font, line, local_x),
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
    const start_x = measureTextSlice(font, line.text[0..start], line.size).x;
    const end_x = measureTextSlice(font, line.text[0..end], line.size).x;
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

fn renderDetailPane(
    app: *App,
    session: *const tracer.Session,
    input: FrameInput,
) Allocator.Error!void {
    const font = input.font;
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
    const title_w = header_title_size.x;

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
    var head_buf: [128]u8 = undefined;
    const head_label = std.fmt.bufPrint(
        &head_buf,
        "{s}  ·  pid {d}",
        .{ process.nameSlice(), process.pid },
    ) catch "";

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
            const line_height = measureTextSlice(
                font,
                if (line.text.len == 0) " " else line.text,
                line.size,
            ).y;
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

    const left_down = rl.isMouseButtonDown(.left);
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
        if (detailPositionAt(app, font, mouse, content, pad, leading_height)) |position| {
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
        if (detailPositionAt(app, font, mouse, content, pad, leading_height)) |position| {
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
                line_index,
                text_x,
                text_y,
                line_h,
            );
            drawTextSlice(
                font,
                line.text,
                .{ .x = text_x, .y = text_y },
                line.size,
                line.color,
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
            toRaylibColor(.{ 12, 18, 32, 255 }),
        );
        const thumb_color: clay.Color = if (app.detail_dragging)
            .{ 92, 151, 255, 255 }
        else if (over_track)
            .{ 86, 110, 145, 255 }
        else
            .{ 61, 80, 110, 255 };
        const thumb_y = track.y + thumbOffset(thumb_travel, max_scroll, app.detail_scroll_px);
        rl.drawRectangleRounded(
            .init(track.x, thumb_y, track.width, thumb_height),
            0.5,
            4,
            toRaylibColor(thumb_color),
        );
    }

    // Draw the selected-process label last so it stays above the scissored
    // content-area edge.
    if (head_label.len > 0) {
        var head_x: f32 = box.x + pad + title_w + 16;
        drawClippedAt(head_label, .{
            .x = &head_x,
            .right = close_box.x - 8,
            .font = font,
            .y = box.y + 14,
            .size = 12,
            .color = toRaylibColor(faint),
        });
    }
    drawDetailCloseButton(font, mouse, close_box);
}

fn processColor(has_children: bool) rl.Color {
    return toRaylibColor(if (has_children) blue else yellow);
}

fn barNameInk(kind: tracer.NameKind) rl.Color {
    return if (kind == .process)
        toRaylibColor(ink)
    else
        rl.Color.init(235, 241, 251, 205);
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

// Inter Regular and Bold, SIL OFL 1.1. UI atlases use 64px for their range of
// sizes; row labels use a native 12px atlas for FreeType's pixel hinting.
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
        .row = loadEmbeddedFont(row_font_ttf, bar_label_size),
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
        rectangleRoundness(.{ .x = 0, .y = 0, .width = 100, .height = 200 }, 10),
    );
    try testing.expectEqual(
        @as(f32, 0),
        rectangleRoundness(.{ .x = 0, .y = 0, .width = 40, .height = 0 }, 10),
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

    const range = detailCpuGraphRange(&process, 900);
    try std.testing.expectEqual(@as(u64, 100), range.start_ns);
    try std.testing.expectEqual(@as(u64, 500), range.end_ns);
    try std.testing.expectEqual(@as(u64, 400), range.spanNs());
    try std.testing.expectEqual(
        @as(f32, 60),
        detailCpuGraphX(range, 300, .init(10, 0, 100, 50)),
    );
}

test "detail CPU graph rounds its scale and caps it to the host" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var process = tracer.Process{ .pid = 7 };
    defer process.deinit(gpa);

    try testing.expectEqual(@as(f64, 1), detailCpuGraphCoreScale(&process, 8));
    try process.cpu_slices.append(gpa, .{
        .start_ns = 0,
        .end_ns = 100,
        .cpu_ns = 250,
        .band = 10,
    });
    try testing.expectEqual(@as(f64, 3), detailCpuGraphCoreScale(&process, 8));
    try testing.expectEqual(@as(f64, 2), detailCpuGraphCoreScale(&process, 2));
}

test "ratio guards division by zero" {
    const testing = std.testing;
    try testing.expectEqual(@as(f32, 0.75), ratio(3, 4));
    try testing.expectEqual(@as(f32, 0), ratio(1, 0));
}

test "collapse controls win clicks over process rows" {
    const testing = std.testing;
    const collapse_target = RowCollapseTarget{ .process = 7 };

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
    try ensureProcessTree(&app, &session);
    try testing.expectEqual(@as(usize, 2), app.row_order.items.len);

    toggleCollapsed(&app, 0);
    try ensureProcessTree(&app, &session);
    try testing.expect(isCollapsed(&app, 0));
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
    try ensureProcessTree(&app, &session);

    try testing.expect(!allCollapsibleRowsCollapsed(&app));
    toggleAllRowsCollapsed(&app);
    try testing.expect(allCollapsibleRowsCollapsed(&app));
    try testing.expect(isCollapsed(&app, 0));
    try testing.expect(isCollapsed(&app, 1));

    toggleAllRowsCollapsed(&app);
    try testing.expect(!allCollapsibleRowsCollapsed(&app));
    try testing.expect(!isCollapsed(&app, 0));
    try testing.expect(!isCollapsed(&app, 1));
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
    try ensureProcessTree(&app, &session);
    try testing.expectEqual(@as(usize, 3), app.row_order.items.len);
    try testing.expect(graphRowsContainProcess(&app, 3));
    try testing.expect(graphRowsContainProcess(&app, 4));

    const target = RowCollapseTarget{ .packed_row = 1 };
    try testing.expect(canCollapseRow(&app, target));
    try testing.expect(!isRowCollapsed(&app, target));
    toggleRowCollapsed(&app, target);
    try ensureProcessTree(&app, &session);
    try testing.expect(isCollapsed(&app, 1));
    try testing.expect(isCollapsed(&app, 2));
    try testing.expect(isRowCollapsed(&app, target));
    try testing.expectEqual(@as(usize, 2), app.row_order.items.len);
    try testing.expect(graphRowsContainProcess(&app, 1));
    try testing.expect(graphRowsContainProcess(&app, 2));
    try testing.expect(!graphRowsContainProcess(&app, 3));
    try testing.expect(!graphRowsContainProcess(&app, 4));

    toggleRowCollapsed(&app, target);
    try ensureProcessTree(&app, &session);
    try testing.expect(!isCollapsed(&app, 1));
    try testing.expect(!isCollapsed(&app, 2));
    try testing.expectEqual(@as(usize, 3), app.row_order.items.len);
    try testing.expect(graphRowsContainProcess(&app, 3));
    try testing.expect(graphRowsContainProcess(&app, 4));
}

fn graphRowsContainProcess(app: *const App, target: usize) bool {
    for (app.row_order.items) |row| switch (row) {
        .process => |index| if (index == target) return true,
        .slot => |slot| {
            for (slotMembers(app, slot)) |index| {
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
