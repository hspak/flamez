//! Text glue over raylib fonts: measure/draw helpers that take plain slices
//! (raylib wants NUL-terminated strings), plus duration labels shared by the
//! header stats, timeline ticks, and process info blocks.

const std = @import("std");
const rl = @import("raylib");

const log = std.log.scoped(.text);

pub const text_buffer_capacity = 8192;

pub const ui_glyph_spacing: f32 = 0;

pub const ClipOptions = struct {
    font: rl.Font,
    position: rl.Vector2,
    size: f32,
    color: rl.Color,
    max_width: f32,
};

pub const ClipLineOptions = struct {
    x: *f32,
    right: f32,
    font: rl.Font,
    y: f32,
    size: f32,
    color: rl.Color,
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

/// Measures a plain slice through raylib's sentinel-based API.
pub fn measureTextSlice(font: rl.Font, value: []const u8, size: f32) rl.Vector2 {
    var buffer: [text_buffer_capacity]u8 = undefined;
    return rl.measureTextEx(font, nullTerminate(value, &buffer), size, ui_glyph_spacing);
}

/// Draws a plain slice through raylib's sentinel-based API.
pub fn drawTextSlice(
    font: rl.Font,
    value: []const u8,
    position: rl.Vector2,
    size: f32,
    color: rl.Color,
) void {
    var buffer: [text_buffer_capacity]u8 = undefined;
    rl.drawTextEx(font, nullTerminate(value, &buffer), position, size, ui_glyph_spacing, color);
}

/// Draws as much of `value` as fits and advances `options.x` by the visible width.
pub fn drawClippedAt(value: []const u8, options: ClipLineOptions) void {
    const max_width = options.right - options.x.*;
    if (max_width <= 4 or value.len == 0) return;
    options.x.* += drawTextSliceClippedWidth(value, .{
        .font = options.font,
        .position = .{ .x = options.x.*, .y = options.y },
        .size = options.size,
        .color = options.color,
        .max_width = max_width,
    });
}

/// Draws the longest byte prefix that fits within `options.max_width`.
pub fn drawTextSliceClipped(value: []const u8, options: ClipOptions) void {
    _ = drawTextSliceClippedWidth(value, options);
}

fn drawTextSliceClippedWidth(value: []const u8, options: ClipOptions) f32 {
    if (options.max_width <= 4 or value.len == 0) return 0;
    var buffer: [text_buffer_capacity]u8 = undefined;
    const max_len: usize = @min(value.len, buffer.len - 1);
    var low: usize = 0;
    var high: usize = max_len;
    var width: f32 = 0;
    while (low < high) {
        const length = low + (high - low + 1) / 2;
        const measured = rl.measureTextEx(
            options.font,
            nullTerminate(value[0..length], &buffer),
            options.size,
            ui_glyph_spacing,
        ).x;
        if (measured <= options.max_width) {
            low = length;
            width = measured;
        } else {
            high = length - 1;
        }
    }
    while (low > 0 and low < value.len and (value[low] & 0xc0) == 0x80) low -= 1;
    if (low == 0) return 0;
    const slice = value[0..low];
    width = rl.measureTextEx(
        options.font,
        nullTerminate(slice, &buffer),
        options.size,
        ui_glyph_spacing,
    ).x;
    rl.drawTextEx(
        options.font,
        nullTerminate(slice, &buffer),
        options.position,
        options.size,
        ui_glyph_spacing,
        options.color,
    );
    return width;
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
