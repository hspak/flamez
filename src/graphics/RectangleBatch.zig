//! Bounded, ordered rectangle geometry. Submit before changing clips or drawing other content.
const graphics = @import("../graphics.zig");
const RectangleBatch = @This();

vertices: [capacity * 4]graphics.Vertex = undefined,
count: usize = 0,

const capacity = 256;
const indices = indices: {
    var result: [capacity * 6]u16 = undefined;
    for (0..capacity) |i| {
        const base: u16 = @intCast(i * 4);
        result[i * 6 ..][0..6].* = .{
            base,
            base + 1,
            base + 2,
            base,
            base + 2,
            base + 3,
        };
    }
    break :indices result;
};

pub fn rectangle(batch: *RectangleBatch, bounds: graphics.Rect, color: graphics.Color) void {
    if (bounds.width <= 0 or bounds.height <= 0) return;
    if (batch.count == capacity) batch.submit();
    const uv = graphics.Point{ .x = 0, .y = 0 };
    batch.vertices[batch.count * 4 ..][0..4].* = .{
        graphics.vertex(.{ .x = bounds.x, .y = bounds.y }, uv, color),
        graphics.vertex(.{ .x = bounds.x + bounds.width, .y = bounds.y }, uv, color),
        graphics.vertex(.{ .x = bounds.x + bounds.width, .y = bounds.y + bounds.height }, uv, color),
        graphics.vertex(.{ .x = bounds.x, .y = bounds.y + bounds.height }, uv, color),
    };
    batch.count += 1;
}

pub fn submit(batch: *RectangleBatch) void {
    graphics.mesh(null, batch.vertices[0 .. batch.count * 4], indices[0 .. batch.count * 6]);
    batch.count = 0;
}
