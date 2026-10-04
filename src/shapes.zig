//! Antialiased logical UI paths submitted as indexed SDL geometry.
const std = @import("std");
const graphics = @import("graphics.zig");

const Path = struct {
    // At most 64 chords per quarter circle; shared endpoints also join straight edges.
    points: [260]graphics.Point = undefined,
    normals: [260]graphics.Point = undefined,
    count: usize = 0,
    closed: bool = true,

    fn arc(path: *Path, center: graphics.Point, radius: f32, start: f32, end: f32, segments: usize) void {
        for (0..segments + 1) |i| {
            const angle = start + (end - start) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            const normal = graphics.Point{ .x = @cos(angle), .y = @sin(angle) };
            path.points[path.count] = center.add(normal.scale(radius));
            path.normals[path.count] = normal;
            path.count += 1;
        }
    }
};

fn cornerSegments(radius: f32) usize {
    const scale = graphics.scale();
    const physical_radius = radius * @max(scale.x, scale.y);
    // Bound chord deviation to 1/8 pixel for ordinary UI radii.
    return @intFromFloat(std.math.clamp(@ceil(std.math.pi / 2.0 * @sqrt(physical_radius)), 8, 64));
}

fn roundedPath(bounds: graphics.Rect, requested_radius: f32) Path {
    const radius = std.math.clamp(requested_radius, 0, @min(bounds.width, bounds.height) / 2);
    const centers = [_]graphics.Point{
        .{ .x = bounds.x + radius, .y = bounds.y + radius },
        .{ .x = bounds.x + bounds.width - radius, .y = bounds.y + radius },
        .{ .x = bounds.x + bounds.width - radius, .y = bounds.y + bounds.height - radius },
        .{ .x = bounds.x + radius, .y = bounds.y + bounds.height - radius },
    };
    var path = Path{};
    for (centers, 0..) |center, i| {
        const start = std.math.pi + @as(f32, @floatFromInt(i)) * std.math.pi / 2.0;
        path.arc(center, radius, start, start + std.math.pi / 2.0, cornerSegments(radius));
    }
    return path;
}

fn expanded(bounds: graphics.Rect, amount: f32) graphics.Rect {
    return .{
        .x = bounds.x - amount,
        .y = bounds.y - amount,
        .width = bounds.width + 2 * amount,
        .height = bounds.height + 2 * amount,
    };
}

/// Fill bounds with a corner radius measured in logical pixels, clamped to half the shorter side.
pub fn drawRectangle(bounds: graphics.Rect, radius: f32, color: graphics.Color) void {
    if (bounds.width <= 0 or bounds.height <= 0) return;
    if (radius <= 0) return graphics.rectangle(bounds, color);
    paint(roundedPath(bounds, radius), null, color);
}

/// Draw an outline outside bounds. Radius and thickness are logical pixels.
pub fn drawRectangleLines(bounds: graphics.Rect, radius: f32, thickness: f32, color: graphics.Color) void {
    if (bounds.width <= 0 or bounds.height <= 0 or thickness <= 0) return;
    paint(roundedPath(expanded(bounds, thickness / 2), radius + thickness / 2), thickness, color);
}

// Each contour has a half-pixel coverage fringe on either side of its geometric
// boundary. SDL interpolates coverage in vertex alpha, independent of backend MSAA.
fn paint(path: Path, stroke: ?f32, color: graphics.Color) void {
    var vertices: [1041]graphics.Vertex = undefined;
    var indices: [6240]u16 = undefined;
    const scale = graphics.scale();
    const n = path.count;
    const bands: usize = if (stroke != null) 4 else 2;
    for (path.points[0..n], path.normals[0..n], 0..) |point, normal, i| {
        const physical_normal = graphics.Point{ .x = normal.x / scale.x, .y = normal.y / scale.y };
        const fringe = physical_normal.scale(0.5);
        for (0..bands) |band| {
            var tint = color;
            const position = if (stroke) |width| position: {
                const outer = band >= 2;
                const covered = band == 1 or band == 2;
                const half = normal.scale(width / 2);
                const edge = if (outer) point.add(half) else point.subtract(half);
                if (!covered) tint.a = 0;
                break :position if (band == 0 or band == 2) edge.subtract(fringe) else edge.add(fringe);
            } else position: {
                if (band == 1) tint.a = 0;
                break :position if (band == 0) point.subtract(fringe) else point.add(fringe);
            };
            vertices[band * n + i] = graphics.vertex(position, .{ .x = 0, .y = 0 }, tint);
        }
    }
    var count: usize = 0;
    const edges = if (path.closed) n else n - 1;
    for (0..bands - 1) |band| for (0..edges) |i| {
        const next = (i + 1) % n;
        const a: u16 = @intCast(band * n + i);
        const b: u16 = @intCast(band * n + next);
        const c: u16 = @intCast((band + 1) * n + i);
        const d: u16 = @intCast((band + 1) * n + next);
        indices[count..][0..6].* = .{
            a,
            b,
            d,
            a,
            d,
            c,
        };
        count += 6;
    };
    if (stroke == null) {
        var center = graphics.Point{ .x = 0, .y = 0 };
        for (path.points[0..n]) |point| center = center.add(point.scale(1 / @as(f32, @floatFromInt(n))));
        vertices[bands * n] = graphics.vertex(center, .{ .x = 0, .y = 0 }, color);
        for (0..n) |i| {
            indices[count..][0..3].* = .{
                @intCast(bands * n),
                @intCast(i),
                @intCast((i + 1) % n),
            };
            count += 3;
        }
    }
    graphics.mesh(null, vertices[0 .. bands * n + @intFromBool(stroke == null)], indices[0..count]);
}
