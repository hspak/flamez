//! Clay page structure and footer presentation for the Flamez window.

const std = @import("std");
const build_options = @import("build_options");

const log = std.log.scoped(.layout);

const clay = @import("zclay");
const rl = @import("raylib");
const App = @import("App.zig");
const theme = @import("theme.zig");
const text = @import("text.zig");
const tracer = @import("tracer.zig");

const footer_font_id: u16 = 1;
const max_elapsed_text = "99999.99 s";
const max_process_count_text = "999999";
const max_active_count_text = "9999";
pub const process_row_height: f32 = 28;
pub const detail_pane_fraction: f32 = 0.6;

pub const ViewText = struct {
    fps: [32]u8 = [_]u8{0} ** 32,
    fps_len: usize = 0,
    status: [64]u8 = [_]u8{0} ** 64,
    status_len: usize = 0,
    elapsed: [32]u8 = [_]u8{0} ** 32,
    elapsed_len: usize = 0,
    process_count: [32]u8 = [_]u8{0} ** 32,
    process_count_len: usize = 0,
    active_count: [32]u8 = [_]u8{0} ** 32,
    active_count_len: usize = 0,
    dropped: [32]u8 = [_]u8{0} ** 32,
    dropped_len: usize = 0,

    fn fpsSlice(self: *const ViewText) []const u8 {
        return self.fps[0..self.fps_len];
    }
    fn statusSlice(self: *const ViewText) []const u8 {
        return self.status[0..self.status_len];
    }
    fn elapsedSlice(self: *const ViewText) []const u8 {
        return self.elapsed[0..self.elapsed_len];
    }
    fn processCount(self: *const ViewText) []const u8 {
        return self.process_count[0..self.process_count_len];
    }
    fn activeCount(self: *const ViewText) []const u8 {
        return self.active_count[0..self.active_count_len];
    }
    fn droppedSlice(self: *const ViewText) []const u8 {
        return self.dropped[0..self.dropped_len];
    }
};

pub fn makeViewText(session: *const tracer.Session) ViewText {
    var view_text = ViewText{};
    if (comptime build_options.fps_counter) {
        const fps = std.fmt.bufPrint(&view_text.fps, "{d} FPS", .{rl.getFPS()}) catch "0 FPS";
        view_text.fps_len = fps.len;
    }
    const incomplete = session.isIncomplete();
    const status = if (incomplete and session.running)
        "INCOMPLETE"
    else if (session.running)
        "RUNNING"
    else if (incomplete) switch (session.root_exit) {
        .exited => |code| std.fmt.bufPrint(
            &view_text.status,
            "INCOMPLETE · EXIT {d}",
            .{code},
        ) catch "INCOMPLETE",
        .signaled => |signal| std.fmt.bufPrint(
            &view_text.status,
            "INCOMPLETE · SIGNAL {d}",
            .{signal},
        ) catch "INCOMPLETE",
        .unknown => "INCOMPLETE",
    } else switch (session.root_exit) {
        .exited => |code| std.fmt.bufPrint(
            &view_text.status,
            "FINISHED · EXIT {d}",
            .{code},
        ) catch "FINISHED",
        .signaled => |signal| std.fmt.bufPrint(
            &view_text.status,
            "STOPPED · SIGNAL {d}",
            .{signal},
        ) catch "STOPPED",
        .unknown => if (session.finished) "FINISHED" else "READY",
    };
    std.mem.copyForwards(u8, view_text.status[0..status.len], status);
    view_text.status_len = status.len;
    const elapsed = text.formatDuration(session.timelineNs(), &view_text.elapsed);
    view_text.elapsed_len = reserveWidth(&view_text.elapsed, elapsed.len, max_elapsed_text.len);
    const process_count = std.fmt.bufPrint(
        &view_text.process_count,
        "{d}",
        .{session.processes.items.len},
    ) catch "0";
    view_text.process_count_len = reserveWidth(
        &view_text.process_count,
        process_count.len,
        max_process_count_text.len,
    );
    const active_count = std.fmt.bufPrint(
        &view_text.active_count,
        "{d}",
        .{session.activeCount()},
    ) catch "0";
    view_text.active_count_len = reserveWidth(
        &view_text.active_count,
        active_count.len,
        max_active_count_text.len,
    );
    if (session.loss_count > 0) {
        const dropped = std.fmt.bufPrint(
            &view_text.dropped,
            "{d}",
            .{session.loss_count},
        ) catch "1";
        view_text.dropped_len = dropped.len;
    }
    return view_text;
}

fn reserveWidth(buffer: []u8, value_len: usize, width: usize) usize {
    std.debug.assert(value_len <= buffer.len);
    const value_width = std.unicode.utf8CountCodepoints(buffer[0..value_len]) catch value_len;
    if (value_width >= width) return value_len;

    const padding = width - value_width;
    std.debug.assert(value_len + padding <= buffer.len);
    var index = value_len;
    while (index > 0) {
        index -= 1;
        buffer[index + padding] = buffer[index];
    }
    @memset(buffer[0..padding], ' ');
    return value_len + padding;
}

pub fn create(
    app: *const App,
    session: *const tracer.Session,
    view_text: *const ViewText,
) []clay.RenderCommand {
    const compact = rl.getScreenWidth() < 900;
    clay.beginLayout();
    clay.UI()(.{
        .id = .ID("Page"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .grow },
        .background_color = theme.canvas,
    })({
        clay.UI()(.{
            .layout = .{
                .direction = .top_to_bottom,
                .sizing = .grow,
                .child_gap = 1,
            },
        })({
            clay.UI()(.{
                .id = .ID("TimelineViewport"),
                .layout = .{ .sizing = .{ .w = .grow, .h = .growMinMax(.{ .min = 180 }) } },
                .background_color = theme.panel,
            })({});
            if (app.selected_process != null) {
                clay.UI()(.{
                    .id = .ID("DetailPane"),
                    .layout = .{
                        .direction = .top_to_bottom,
                        .sizing = .{ .w = .grow, .h = if (app.detail_pane_height > 0)
                            .fixed(app.detail_pane_height)
                        else
                            .percent(detail_pane_fraction) },
                    },
                    .background_color = theme.panel,
                })({
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .fixed(42) },
                            .padding = .{ .right = 8 },
                            .child_alignment = .{ .x = .right, .y = .center },
                        },
                    })({
                        clay.UI()(.{
                            .id = .ID("DetailCloseButton"),
                            .layout = .{ .sizing = .{ .w = .fixed(20), .h = .fixed(20) } },
                        })({});
                    });
                });
            }
        });
        clay.UI()(.{
            .id = .ID("Footer"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(process_row_height) },
                .padding = .axes(0, 8),
                .child_alignment = .{ .x = .left, .y = .center },
                .child_gap = if (compact) 8 else 12,
            },
            .background_color = theme.panel,
            .border = .{ .color = theme.border, .width = .{ .top = 1 } },
        })({
            clay.text("FLAMEZ", .{
                .font_size = 12,
                .color = theme.ink,
                .wrap_mode = .none,
                .letter_spacing = 1,
            });
            if (comptime build_options.fps_counter) {
                clay.text(view_text.fpsSlice(), .{
                    .font_id = footer_font_id,
                    .font_size = 12,
                    .color = theme.fps_green,
                    .wrap_mode = .none,
                });
            }
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fit },
                    .child_alignment = .{ .x = .left, .y = .center },
                    .child_gap = if (compact) 8 else 14,
                },
                .clip = .{ .horizontal = true },
            })({
                legendItem("PARENT PROCESS", theme.blue);
                legendItem("LEAF PROCESS", theme.yellow);
                if (app.message_len > 0) {
                    clay.text(app.messageSlice(), .{
                        .font_size = 12,
                        .color = theme.danger,
                        .wrap_mode = .none,
                    });
                }
            });
            stat("ELAPSED", view_text.elapsedSlice(), theme.accent);
            stat("PROCESSES", view_text.processCount(), theme.blue);
            stat("ACTIVE", view_text.activeCount(), theme.danger);
            stat("", view_text.statusSlice(), theme.muted);
            if (session.capture_fidelity == .snapshot_recovery) {
                stat("CAPTURE", "BEST EFFORT", theme.yellow);
            }
            if (view_text.dropped_len > 0) stat("DROPPED", view_text.droppedSlice(), theme.danger);
            if (session.running) {
                clay.UI()(.{
                    .id = .ID("StopButton"),
                    .layout = .{
                        .sizing = .{ .w = .fixed(54), .h = .fixed(22) },
                        .child_alignment = .center,
                    },
                    .background_color = if (clay.hovered()) .{
                        255,
                        132,
                        145,
                        255,
                    } else theme.danger,
                    .corner_radius = .all(5),
                })({
                    clay.text("STOP", .{
                        .font_id = footer_font_id,
                        .font_size = 12,
                        .color = theme.canvas,
                        .wrap_mode = .none,
                    });
                });
            } else if (session.finished) {
                clay.UI()(.{
                    .id = .ID("ExportButton"),
                    .layout = .{
                        .sizing = .{ .w = .fixed(68), .h = .fixed(22) },
                        .child_alignment = .center,
                    },
                    .background_color = if (clay.hovered()) .{
                        122,
                        240,
                        160,
                        255,
                    } else theme.fps_green,
                    .corner_radius = .all(5),
                })({
                    clay.text("EXPORT", .{
                        .font_id = footer_font_id,
                        .font_size = 12,
                        .color = theme.canvas,
                        .wrap_mode = .none,
                    });
                });
            }
        });
    });
    return clay.endLayout();
}

fn stat(label: []const u8, value: []const u8, value_color: clay.Color) void {
    clay.UI()(.{
        .layout = .{
            .child_gap = 4,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.text(label, .{
            .font_id = footer_font_id,
            .font_size = 12,
            .color = theme.muted,
            .wrap_mode = .none,
            .letter_spacing = 1,
        });
        clay.text(value, .{
            .font_id = footer_font_id,
            .font_size = 12,
            .color = value_color,
            .wrap_mode = .none,
        });
    });
}

fn legendItem(label: []const u8, color: clay.Color) void {
    clay.UI()(.{
        .layout = .{
            .child_gap = 5,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.UI()(.{
            .layout = .{ .sizing = .{ .w = .fixed(10), .h = .fixed(10) } },
            .background_color = color,
        })({});
        clay.text(label, .{
            .font_id = footer_font_id,
            .font_size = 12,
            .color = theme.muted,
            .wrap_mode = .none,
        });
    });
}

test "FPS counter build option controls footer text" {
    const testing = std.testing;

    var session = tracer.Session.init(testing.allocator, testing.io);
    defer session.deinit();
    const view_text = makeViewText(&session);
    if (comptime build_options.fps_counter) {
        try testing.expect(std.mem.endsWith(u8, view_text.fpsSlice(), " FPS"));
        try testing.expect(view_text.fps_len > " FPS".len);
    } else {
        try testing.expectEqual(@as(usize, 0), view_text.fps_len);
    }
}

test "footer values reserve their maximum widths" {
    const testing = std.testing;

    var buffer: [32]u8 = [_]u8{0} ** 32;
    @memcpy(buffer[0.."9.00 s".len], "9.00 s");
    const elapsed_len = reserveWidth(&buffer, "9.00 s".len, max_elapsed_text.len);
    try testing.expectEqualStrings("    9.00 s", buffer[0..elapsed_len]);

    @memcpy(buffer[0.."0 µs".len], "0 µs");
    const microseconds_len = reserveWidth(&buffer, "0 µs".len, max_elapsed_text.len);
    try testing.expectEqualStrings("      0 µs", buffer[0..microseconds_len]);

    @memcpy(buffer[0..1], "9");
    const process_len = reserveWidth(&buffer, 1, max_process_count_text.len);
    try testing.expectEqualStrings("     9", buffer[0..process_len]);

    @memcpy(buffer[0..2], "99");
    const active_len = reserveWidth(&buffer, 2, max_active_count_text.len);
    try testing.expectEqualStrings("  99", buffer[0..active_len]);
}

test "footer status owns static and formatted text" {
    const testing = std.testing;
    const Case = struct {
        running: bool = false,
        finished: bool = false,
        loss_count: u64 = 0,
        root_exit: tracer.Session.RootExit = .unknown,
        expected: []const u8,
    };
    const cases: []const Case = &.{
        .{ .expected = "READY" },
        .{ .running = true, .expected = "RUNNING" },
        .{ .finished = true, .expected = "FINISHED" },
        .{ .running = true, .loss_count = 1, .expected = "INCOMPLETE" },
        .{ .finished = true, .loss_count = 1, .expected = "INCOMPLETE" },
        .{ .finished = true, .root_exit = .{ .exited = 2 }, .expected = "FINISHED · EXIT 2" },
        .{ .finished = true, .root_exit = .{ .signaled = 9 }, .expected = "STOPPED · SIGNAL 9" },
        .{ .loss_count = 1, .root_exit = .{ .exited = 2 }, .expected = "INCOMPLETE · EXIT 2" },
    };
    for (cases) |case| {
        var session = tracer.Session.init(testing.allocator, testing.io);
        defer session.deinit();
        session.running = case.running;
        session.finished = case.finished;
        session.loss_count = case.loss_count;
        session.root_exit = case.root_exit;
        const view = makeViewText(&session);
        try testing.expectEqualStrings(case.expected, view.statusSlice());
    }
}
