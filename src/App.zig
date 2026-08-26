//! UI session state and timeline view-window math. `App` owns every piece of
//! per-session UI state (selection, scroll, collapse, the precomputed row
//! model); renderers borrow it per frame.

const std = @import("std");

const Allocator = std.mem.Allocator;

const process_info = @import("process_info.zig");

const TooltipLine = process_info.TooltipLine;
const log = std.log.scoped(.app);

const App = @This();

gpa: Allocator,
graph_scroll: usize = 0,
selected_process: ?usize = null,
/// Bottom detail pane: pixel scroll offset into the selected process's graph and info.
detail_scroll_px: f32 = 0,
/// Process index that `detail_scroll_px` belongs to; resets on selection change.
detail_for: ?usize = null,
detail_dragging: bool = false,
detail_grab: f32 = 0,
/// Builder storage for the detail pane, allocated once in `init`.
detail_store: []u8 = &.{},
detail_lines: []TooltipLine = &.{},
detail_line_heights: []f32 = &.{},
detail_line_count: usize = 0,
detail_content_height: f32 = 0,
detail_cache_process: ?usize = null,
detail_cache_revision: u64 = std.math.maxInt(u64),
detail_cache_width: f32 = -1,
detail_timing_line: ?usize = null,
detail_timing: [160]u8 = [_]u8{0} ** 160,
detail_timing_len: usize = 0,
detail_selection_anchor: ?DetailTextPosition = null,
detail_selection_focus: ?DetailTextPosition = null,
detail_text_selecting: bool = false,
detail_text_focused: bool = false,
/// NUL-terminated staging storage for system clipboard writes.
detail_clipboard: []u8 = &.{},
message: [192]u8 = [_]u8{0} ** 192,
message_len: usize = 0,
row_order: std.ArrayList(GraphRow) = .empty,
first_child: std.ArrayList(?usize) = .empty,
next_sibling: std.ArrayList(?usize) = .empty,
visual_parent: std.ArrayList(?usize) = .empty,
visual_depth: std.ArrayList(u16) = .empty,
pack_root: std.ArrayList(?usize) = .empty,
pack_job: std.ArrayList(?usize) = .empty,
pack_slot: std.ArrayList(u16) = .empty,
/// Intrusive next links for processes assigned to the same packed row.
slot_next: std.ArrayList(?usize) = .empty,
slot_count: std.ArrayList(u16) = .empty,
lane_height_off: std.ArrayList(u16) = .empty,
lane_heights: std.ArrayList(u16) = .empty,
last_child_scratch: std.ArrayList(?usize) = .empty,
roots_scratch: std.ArrayList(usize) = .empty,
jobs_scratch: std.ArrayList(JobSpan) = .empty,
heights_scratch: std.ArrayList(u16) = .empty,
free_at_scratch: std.ArrayList(u64) = .empty,
lane_offsets_scratch: std.ArrayList(usize) = .empty,
tree_revision_seen: u64 = std.math.maxInt(u64),
collapse_revision: u64 = 0,
collapse_revision_seen: u64 = std.math.maxInt(u64),
scrollbar_dragging: bool = false,
scrollbar_grab: f32 = 0,
hscroll_dragging: bool = false,
hscroll_grab: f32 = 0,
/// Visible time window. `view_span_ns == null` means the full run.
view_start_ns: u64 = 0,
view_span_ns: ?u64 = null,
follow_live: bool = true,
collapsed: std.ArrayList(bool) = .empty,

/// One row of the rendered tree: either a process bar or a packed lane slot.
pub const GraphRow = union(enum) {
    process: usize,
    slot: struct {
        parent: usize,
        lane: u16,
        subrow: u16,
        head: ?usize = null,
        tail: ?usize = null,
    },
};

pub const JobSpan = struct {
    root: usize,
    start_ns: u64,
    end_ns: u64,
    height: u16,
};

pub const DetailTextPosition = struct {
    line: usize,
    byte: usize,
};

pub const TimeWindow = struct { start_ns: u64, span_ns: u64 };
pub const InitError = Allocator.Error;

const detail_store_initial_capacity = 8192;
const detail_line_initial_capacity = 1024;
const detail_clipboard_initial_capacity = 8192;

pub const min_view_span_ns: u64 = 1 * std.time.ns_per_ms;
const zoom_step: f64 = 1.25;
// How far past a fit-to-run view Ctrl+wheel may zoom out.
const max_zoom_out: f64 = 8;

/// Initializes UI state and allocates reusable detail-pane storage.
/// The returned value owns all buffers allocated with `gpa`.
pub fn init(gpa: Allocator) InitError!App {
    var app = App{ .gpa = gpa };
    app.detail_store = try gpa.alloc(u8, detail_store_initial_capacity);
    errdefer gpa.free(app.detail_store);

    app.detail_lines = try gpa.alloc(TooltipLine, detail_line_initial_capacity);
    errdefer gpa.free(app.detail_lines);

    app.detail_line_heights = try gpa.alloc(f32, detail_line_initial_capacity);
    errdefer gpa.free(app.detail_line_heights);

    app.detail_clipboard = try gpa.alloc(u8, detail_clipboard_initial_capacity);
    errdefer gpa.free(app.detail_clipboard);

    return app;
}

/// Releases every buffer owned by `self`; using `self` afterward is invalid.
pub fn deinit(self: *App) void {
    self.row_order.deinit(self.gpa);
    self.first_child.deinit(self.gpa);
    self.next_sibling.deinit(self.gpa);
    self.visual_parent.deinit(self.gpa);
    self.visual_depth.deinit(self.gpa);
    self.pack_root.deinit(self.gpa);
    self.pack_job.deinit(self.gpa);
    self.pack_slot.deinit(self.gpa);
    self.slot_next.deinit(self.gpa);
    self.slot_count.deinit(self.gpa);
    self.lane_height_off.deinit(self.gpa);
    self.lane_heights.deinit(self.gpa);
    self.last_child_scratch.deinit(self.gpa);
    self.roots_scratch.deinit(self.gpa);
    self.jobs_scratch.deinit(self.gpa);
    self.heights_scratch.deinit(self.gpa);
    self.free_at_scratch.deinit(self.gpa);
    self.lane_offsets_scratch.deinit(self.gpa);
    self.collapsed.deinit(self.gpa);
    if (self.detail_store.len > 0) self.gpa.free(self.detail_store);
    if (self.detail_lines.len > 0) self.gpa.free(self.detail_lines);
    if (self.detail_line_heights.len > 0) self.gpa.free(self.detail_line_heights);
    if (self.detail_clipboard.len > 0) self.gpa.free(self.detail_clipboard);
    self.* = undefined;
}

/// Grows selected-process text storage so builders never drop arguments.
pub fn ensureDetailCapacity(
    self: *App,
    store_capacity: usize,
    line_capacity: usize,
    clipboard_capacity: usize,
) Allocator.Error!void {
    if (self.detail_store.len < store_capacity) {
        self.detail_store = try self.gpa.realloc(self.detail_store, store_capacity);
    }
    if (self.detail_lines.len < line_capacity) {
        self.detail_lines = try self.gpa.realloc(self.detail_lines, line_capacity);
    }
    if (self.detail_line_heights.len < line_capacity) {
        self.detail_line_heights = try self.gpa.realloc(
            self.detail_line_heights,
            line_capacity,
        );
    }
    if (self.detail_clipboard.len < clipboard_capacity) {
        self.detail_clipboard = try self.gpa.realloc(
            self.detail_clipboard,
            clipboard_capacity,
        );
    }
}

/// Replaces the transient status message, using a fixed fallback if formatting
/// exceeds its internal buffer.
pub fn setMessage(self: *App, comptime format: []const u8, args: anytype) void {
    const value = std.fmt.bufPrint(&self.message, format, args) catch "Unable to format status";
    self.message_len = value.len;
}

/// Returns the message bytes owned by `self`.
pub fn messageSlice(self: *const App) []const u8 {
    return self.message[0..self.message_len];
}

// Widest span the Ctrl+wheel zoom-out may show relative to a fit-to-run view.
fn maxViewSpanNs(total: u64) u64 {
    const t: f64 = @floatFromInt(@max(total, min_view_span_ns));
    return @intFromFloat(t * max_zoom_out);
}

/// Resolves the current visible interval, including follow-live behavior.
pub fn visibleTimeWindow(self: *const App, total_ns: u64) TimeWindow {
    const total = @max(total_ns, min_view_span_ns);
    const span = @min(self.view_span_ns orelse total, maxViewSpanNs(total));
    if (span > total) return .{ .start_ns = 0, .span_ns = span };
    var start = self.view_start_ns;
    if (self.follow_live and self.view_span_ns != null) start = total -| span;
    if (start + span > total) start = total -| span;
    return .{ .start_ns = start, .span_ns = span };
}

/// Zooms around `anchor_frac`, which is clamped to the inclusive range 0...1.
pub fn zoomTimeView(self: *App, total_ns: u64, anchor_frac: f32, wheel: f32) void {
    const total = @max(total_ns, min_view_span_ns);
    const window = self.visibleTimeWindow(total);
    const notches = @as(f64, @floatCast(@abs(wheel)));
    const factor = std.math.pow(f64, zoom_step, notches);
    const new_span_f = if (wheel > 0)
        @as(f64, @floatFromInt(window.span_ns)) / factor
    else
        @as(f64, @floatFromInt(window.span_ns)) * factor;
    const min_span: f64 = @floatFromInt(min_view_span_ns);
    const max_span: f64 = @floatFromInt(maxViewSpanNs(total));
    const new_span: u64 = @intFromFloat(std.math.clamp(new_span_f, min_span, max_span));
    if (new_span >= total) {
        self.view_start_ns = 0;
        self.view_span_ns = if (new_span > total) new_span else null;
        self.follow_live = true;
        return;
    }
    const frac = @as(f64, @floatCast(std.math.clamp(anchor_frac, 0, 1)));
    const anchor = @as(f64, @floatFromInt(window.start_ns)) +
        frac * @as(f64, @floatFromInt(window.span_ns));
    var signed_start: i64 = @intFromFloat(anchor - frac * @as(f64, @floatFromInt(new_span)));
    if (signed_start < 0) signed_start = 0;
    var new_start: u64 = @intCast(signed_start);
    if (new_start + new_span > total) new_start = total -| new_span;
    self.view_start_ns = new_start;
    self.view_span_ns = new_span;
    self.follow_live = new_start + new_span >= total;
}

/// Restores the full-run view and follows the live tail as the capture grows.
pub fn resetTimeView(self: *App) void {
    self.view_start_ns = 0;
    self.view_span_ns = null;
    self.follow_live = true;
}

/// Moves a zoomed view to `start`, clamped within the captured interval.
pub fn setTimeViewStart(self: *App, total: u64, start: u64) void {
    const span = self.view_span_ns orelse return;
    if (span >= total) return;
    const max_start = total - span;
    self.view_start_ns = @min(start, max_start);
    self.follow_live = self.view_start_ns >= max_start;
}

/// Pans a zoomed view by a signed number of nanoseconds.
pub fn panTimeView(self: *App, total: u64, delta_ns: i64) void {
    const start_i = @as(i64, @intCast(self.view_start_ns)) + delta_ns;
    const start: u64 = if (start_i < 0) 0 else @intCast(start_i);
    self.setTimeViewStart(total, start);
}

test "zoom narrows the span and keeps the anchor point stable" {
    const testing = std.testing;
    const total_ns: u64 = 100 * std.time.ns_per_ms;

    var app = App{ .gpa = std.testing.failing_allocator };
    app.view_start_ns = 20 * std.time.ns_per_ms;
    app.view_span_ns = total_ns; // full view: zooming in is the first change
    zoomTimeView(&app, total_ns, 0.5, 1);

    const span = app.view_span_ns.?;
    try testing.expect(span < total_ns);
    // With the full run visible, the anchor sits mid-window (50ms); that
    // point must remain at fraction 0.5 of the narrowed window.
    const half: u64 = @intFromFloat(0.5 * @as(f64, @floatFromInt(span)));
    const new_middle = app.view_start_ns + half;
    try testing.expectApproxEqAbs(
        @as(f64, 50 * std.time.ns_per_ms),
        @as(f64, @floatFromInt(new_middle)),
        3e6,
    );
}

test "zooming out past a fit-to-run view follows the live tail again" {
    const testing = std.testing;
    const total_ns: u64 = 100 * std.time.ns_per_ms;

    var app = App{ .gpa = std.testing.failing_allocator };
    app.follow_live = false;
    app.view_span_ns = total_ns / 4;
    zoomTimeView(&app, total_ns, 0.5, -8);

    try testing.expect(app.view_span_ns == null or app.view_span_ns.? >= total_ns);
    try testing.expect(app.follow_live);
}

test "resetTimeView restores the full live view" {
    const testing = std.testing;
    var app = App{ .gpa = testing.failing_allocator };
    app.view_start_ns = 25 * std.time.ns_per_ms;
    app.view_span_ns = 10 * std.time.ns_per_ms;
    app.follow_live = false;

    resetTimeView(&app);

    try testing.expectEqual(@as(u64, 0), app.view_start_ns);
    try testing.expectEqual(@as(?u64, null), app.view_span_ns);
    try testing.expect(app.follow_live);
}

test "setTimeViewStart clamps the window inside the run" {
    const testing = std.testing;
    const total_ns: u64 = 100 * std.time.ns_per_ms;

    var app = App{ .gpa = std.testing.failing_allocator };
    app.view_span_ns = total_ns / 4;

    // Pinned to the tail of the run ⇔ following the live tail:
    setTimeViewStart(&app, total_ns, 99 * std.time.ns_per_ms);
    try testing.expectEqual(total_ns - total_ns / 4, app.view_start_ns);
    try testing.expect(app.follow_live);

    setTimeViewStart(&app, total_ns, 10 * std.time.ns_per_ms);
    try testing.expectEqual(10 * std.time.ns_per_ms, app.view_start_ns);
    try testing.expect(!app.follow_live);
}
