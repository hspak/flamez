//! Clay page structure and footer presentation for the Flamez window.

const std = @import("std");
const build_options = @import("build_options");

const clay = @import("zclay");
const rl = @import("raylib");
const App = @import("App.zig");
const theme = @import("theme.zig");
const text = @import("text.zig");
const tracer = @import("tracer.zig");

const footer_font_id: u16 = 1;
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
    const status = if (session.incomplete and session.running)
        "INCOMPLETE"
    else if (session.running)
        "RUNNING"
    else if (session.incomplete) status: {
        if (session.exit_code) |code|
            break :status std.fmt.bufPrint(
                &view_text.status,
                "INCOMPLETE · EXIT {d}",
                .{code},
            ) catch "INCOMPLETE";
        if (session.exit_signal) |signal|
            break :status std.fmt.bufPrint(
                &view_text.status,
                "INCOMPLETE · SIGNAL {d}",
                .{signal},
            ) catch "INCOMPLETE";
        break :status "INCOMPLETE";
    } else if (session.exit_code) |code|
        std.fmt.bufPrint(&view_text.status, "FINISHED · EXIT {d}", .{code}) catch "FINISHED"
    else if (session.exit_signal) |signal|
        std.fmt.bufPrint(&view_text.status, "STOPPED · SIGNAL {d}", .{signal}) catch "STOPPED"
    else
        "READY";
    view_text.status_len = status.len;
    view_text.elapsed_len = text.formatDuration(session.timelineNs(), &view_text.elapsed).len;
    const process_count = std.fmt.bufPrint(
        &view_text.process_count,
        "{d}",
        .{session.processes.items.len},
    ) catch "0";
    view_text.process_count_len = process_count.len;
    const active_count = std.fmt.bufPrint(
        &view_text.active_count,
        "{d}",
        .{session.activeCount()},
    ) catch "0";
    view_text.active_count_len = active_count.len;
    if (session.lost_events > 0) {
        const dropped = std.fmt.bufPrint(&view_text.dropped, "{d}", .{session.lost_events}) catch "1";
        view_text.dropped_len = dropped.len;
    }
    return view_text;
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
                clay.UI()(.{ .layout = .{
                    .sizing = .{ .w = .fixed(54), .h = .fit },
                    .child_alignment = .{ .x = .left, .y = .center },
                } })({
                    clay.text(view_text.fpsSlice(), .{
                        .font_id = footer_font_id,
                        .font_size = 12,
                        .color = theme.fps_green,
                        .wrap_mode = .none,
                    });
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
            if (view_text.dropped_len > 0) stat("DROPPED", view_text.droppedSlice(), theme.danger);
            if (session.running) {
                clay.UI()(.{
                    .id = .ID("StopButton"),
                    .layout = .{
                        .sizing = .{ .w = .fixed(54), .h = .fixed(22) },
                        .child_alignment = .center,
                    },
                    .background_color = if (clay.hovered()) .{ 255, 132, 145, 255 } else theme.danger,
                    .corner_radius = .all(5),
                })({
                    clay.text("STOP", .{
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
    clay.UI()(.{ .layout = .{ .child_gap = 4, .child_alignment = .{ .x = .left, .y = .center } } })({
        clay.text(label, .{ .font_id = footer_font_id, .font_size = 12, .color = theme.muted, .wrap_mode = .none, .letter_spacing = 1 });
        clay.text(value, .{ .font_id = footer_font_id, .font_size = 12, .color = value_color, .wrap_mode = .none });
    });
}

fn legendItem(label: []const u8, color: clay.Color) void {
    clay.UI()(.{ .layout = .{ .child_gap = 5, .child_alignment = .{ .x = .left, .y = .center } } })({
        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(10), .h = .fixed(10) } }, .background_color = color })({});
        clay.text(label, .{ .font_id = footer_font_id, .font_size = 12, .color = theme.muted, .wrap_mode = .none });
    });
}
