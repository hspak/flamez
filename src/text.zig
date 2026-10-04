//! Shared UTF-8 measurement, drawing, clipping, and duration labels.

const std = @import("std");
const graphics = @import("graphics.zig");
const Font = @import("Font.zig");

pub const buffer_capacity = 8192;

pub const ui_glyph_spacing: f32 = 0;

pub const ClipOptions = struct {
    font: *const Font,
    position: graphics.Point,
    size: f32,
    color: graphics.Color,
    max_width: f32,
};

pub const ClipLineOptions = struct {
    x: *f32,
    right: f32,
    font: *const Font,
    y: f32,
    size: f32,
    color: graphics.Color,
};

/// Copies `text` and appends a sentinel. Asserts that `buffer` has at least
/// `text.len + 1` bytes.
pub fn nullTerminate(text: []const u8, buffer: []u8) [:0]const u8 {
    std.debug.assert(text.len < buffer.len);
    @memcpy(buffer[0..text.len], text);
    buffer[text.len] = 0;
    return buffer[0..text.len :0];
}

/// Formats a compact duration into caller-owned storage.
pub fn formatDuration(ns: u64, buffer: []u8) []const u8 {
    if (ns < std.time.ns_per_ms) {
        return std.fmt.bufPrint(buffer, "{d} µs", .{ns / std.time.ns_per_us}) catch "0 µs";
    }
    if (ns < std.time.ns_per_s) {
        const milliseconds = @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
        return std.fmt.bufPrint(buffer, "{d:.1} ms", .{milliseconds}) catch "0 ms";
    }
    const seconds = @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_s);
    return std.fmt.bufPrint(buffer, "{d:.2} s", .{seconds}) catch "0 s";
}

/// Measures a UTF-8 slice with the same glyph metrics used for drawing.
pub fn measure(font: *const Font, value: []const u8, size: f32) graphics.Point {
    return font.measure(value, size, ui_glyph_spacing);
}

/// Draws a UTF-8 slice using the embedded font atlas.
pub fn draw(
    font: *const Font,
    value: []const u8,
    position: graphics.Point,
    size: f32,
    color: graphics.Color,
) void {
    font.draw(value, position, size, ui_glyph_spacing, color);
}

/// Draws as much of `value` as fits and advances `options.x` by the visible width.
pub fn drawClippedAt(value: []const u8, options: ClipLineOptions) void {
    const max_width = options.right - options.x.*;
    if (max_width <= 4 or value.len == 0) return;
    options.x.* += drawClippedWidth(value, .{
        .font = options.font,
        .position = .{ .x = options.x.*, .y = options.y },
        .size = options.size,
        .color = options.color,
        .max_width = max_width,
    });
}

/// Draws the longest byte prefix that fits within `options.max_width`.
pub fn drawClipped(value: []const u8, options: ClipOptions) void {
    _ = drawClippedWidth(value, options);
}

fn drawClippedWidth(value: []const u8, options: ClipOptions) f32 {
    if (options.max_width <= 4 or value.len == 0) return 0;
    const prefix = options.font.fit(value, options.size, options.max_width);
    options.font.draw(value[0..prefix.len], options.position, options.size, ui_glyph_spacing, options.color);
    return prefix.width;
}

test "formatDuration renders µs, ms, and s" {
    const testing = std.testing;
    var buf: [32]u8 = undefined;

    try testing.expectEqualStrings("5 µs", formatDuration(5_000, &buf));
    try testing.expectEqualStrings("1000.0 ms", formatDuration(std.time.ns_per_s - 1, &buf));
    try testing.expectEqualStrings("1.0 ms", formatDuration(std.time.ns_per_ms, &buf));
    try testing.expectEqualStrings("2.00 s", formatDuration(2 * std.time.ns_per_s, &buf));
}

test "nullTerminate fits and terminates within the buffer" {
    const testing = std.testing;
    var buffer: [8]u8 = undefined;
    const terminated = nullTerminate("flamez", &buffer);
    try testing.expectEqualStrings("flamez", terminated);
    try testing.expectEqual(@as(u8, 0), buffer[6]);
}
