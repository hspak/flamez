//! SDL renderer for logical window coordinates, with ordered geometry and texture submission.
const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.graphics);
const desktop = @import("desktop.zig");
const geometry = @import("geometry.zig");
const shapes = @import("shapes.zig");
pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
pub const Color = geometry.Color;
const c = desktop.c;
const png = @cImport({
    @cInclude("png.h");
});
pub const Texture = *c.SDL_Texture;
pub const Vertex = c.SDL_Vertex;
pub const RectangleBatch = @import("graphics/RectangleBatch.zig");
pub const ResourceError = error{GraphicsUnavailable};
pub const SaveError = ResourceError || error{ImageOutputUnavailable};

var renderer: ?*c.SDL_Renderer = null;
var transform: Point = .{ .x = 1, .y = 1 };
var clips: [32]c.SDL_Rect = undefined;
var clip_count: usize = 0;
var failed = false;

/// Owns the renderer until deinit. Release fonts and textures before deinit.
pub fn init(vsync: bool) ResourceError!void {
    // Keep explicit SDL_RENDER_DRIVER overrides available for diagnostics.
    if (comptime builtin.os.tag == .linux)
        _ = c.SDL_SetHintWithPriority(c.SDL_HINT_RENDER_DRIVER, "vulkan", c.SDL_HINT_DEFAULT);
    renderer = c.SDL_CreateRenderer(desktop.window(), null) orelse {
        log.err("SDL renderer: {s}", .{c.SDL_GetError()});
        return error.GraphicsUnavailable;
    };
    errdefer deinit();
    if (!c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND)) return error.GraphicsUnavailable;
    if (!c.SDL_SetRenderVSync(renderer, if (vsync) 1 else 0))
        log.warn("SDL VSync unavailable; using frame deadlines: {s}", .{c.SDL_GetError()});
    log.info("SDL {d}.{d}.{d}, renderer: {s}", .{
        c.SDL_VERSIONNUM_MAJOR(c.SDL_GetVersion()),
        c.SDL_VERSIONNUM_MINOR(c.SDL_GetVersion()),
        c.SDL_VERSIONNUM_MICRO(c.SDL_GetVersion()),
        c.SDL_GetRendererName(renderer),
    });
    beginFrame();
}
pub fn deinit() void {
    c.SDL_DestroyRenderer(renderer);
    renderer = null;
}
pub fn flush() void {
    check(c.SDL_FlushRenderer(renderer));
}
fn check(ok: bool) void {
    if (!ok and !failed) log.err("SDL rendering: {s}", .{c.SDL_GetError()});
    failed = failed or !ok;
}
pub fn beginFrame() void {
    failed = false;
    transform = .{ .x = desktop.density(), .y = desktop.density() };
    clip_count = 0;
    check(c.SDL_SetRenderClipRect(renderer, null));
}
pub fn endFrame() ResourceError!void {
    check(c.SDL_RenderPresent(renderer));
    if (failed) return error.GraphicsUnavailable;
}
pub fn clear(color: Color) void {
    setColor(color);
    check(c.SDL_RenderClear(renderer));
}
fn setColor(color: Color) void {
    check(c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a));
}
pub fn scale() Point {
    return transform;
}

/// Pushes a logical clip, intersecting with any enclosing Clay or application clip.
pub fn beginClip(bounds: Rect) void {
    std.debug.assert(clip_count < clips.len);
    const left = @floor(bounds.x * transform.x);
    const top = @floor(bounds.y * transform.y);
    var rect: c.SDL_Rect = .{
        .x = @intFromFloat(left),
        .y = @intFromFloat(top),
        .w = @intFromFloat(@max(0, @ceil((bounds.x + bounds.width) * transform.x) - left)),
        .h = @intFromFloat(@max(0, @ceil((bounds.y + bounds.height) * transform.y) - top)),
    };
    if (clip_count > 0) {
        const parent = clips[clip_count - 1];
        const right = @min(rect.x + rect.w, parent.x + parent.w);
        const bottom = @min(rect.y + rect.h, parent.y + parent.h);
        rect.x = @max(rect.x, parent.x);
        rect.y = @max(rect.y, parent.y);
        rect.w = @max(0, right - rect.x);
        rect.h = @max(0, bottom - rect.y);
    }
    clips[clip_count] = rect;
    clip_count += 1;
    check(c.SDL_SetRenderClipRect(renderer, &rect));
}
pub fn endClip() void {
    std.debug.assert(clip_count > 0);
    clip_count -= 1;
    check(c.SDL_SetRenderClipRect(renderer, if (clip_count > 0) &clips[clip_count - 1] else null));
}
fn physical(bounds: Rect) c.SDL_FRect {
    return .{
        .x = bounds.x * transform.x,
        .y = bounds.y * transform.y,
        .w = bounds.width * transform.x,
        .h = bounds.height * transform.y,
    };
}
pub fn vertex(position: Point, uv: Point, color: Color) Vertex {
    return .{
        .position = .{ .x = position.x * transform.x, .y = position.y * transform.y },
        .tex_coord = .{ .x = uv.x, .y = uv.y },
        .color = .{
            .r = @as(f32, @floatFromInt(color.r)) / 255,
            .g = @as(f32, @floatFromInt(color.g)) / 255,
            .b = @as(f32, @floatFromInt(color.b)) / 255,
            .a = @as(f32, @floatFromInt(color.a)) / 255,
        },
    };
}
/// SDL copies the submitted vertices and indices; texture ownership stays with the caller.
pub fn mesh(texture: ?Texture, vertices: []const Vertex, indices: []const u16) void {
    if (vertices.len == 0) return;
    check(c.SDL_RenderGeometryRaw(
        renderer,
        texture,
        &vertices[0].position.x,
        @sizeOf(Vertex),
        &vertices[0].color,
        @sizeOf(Vertex),
        &vertices[0].tex_coord.x,
        @sizeOf(Vertex),
        @intCast(vertices.len),
        indices.ptr,
        @intCast(indices.len),
        @sizeOf(u16),
    ));
}
pub fn rectangle(bounds: Rect, color: Color) void {
    if (bounds.width <= 0 or bounds.height <= 0) return;
    setColor(color);
    const rect = physical(bounds);
    check(c.SDL_RenderFillRect(renderer, &rect));
}
pub fn outline(r: Rect, thickness: f32, color: Color) void {
    const t = @min(thickness, @min(r.width, r.height) / 2);
    rectangle(.init(r.x, r.y, r.width, t), color);
    rectangle(.init(r.x, r.y + r.height - t, r.width, t), color);
    rectangle(.init(r.x, r.y + t, t, r.height - 2 * t), color);
    rectangle(.init(r.x + r.width - t, r.y + t, t, r.height - 2 * t), color);
}
/// Roundness is the fraction of half the shorter side occupied by each corner.
pub fn roundedRectangle(bounds: Rect, roundness: f32, color: Color) void {
    shapes.drawRectangle(bounds, roundness * @min(bounds.width, bounds.height) / 2, color);
}
pub fn roundedOutline(bounds: Rect, roundness: f32, thickness: f32, color: Color) void {
    shapes.drawRectangleLines(bounds, roundness * @min(bounds.width, bounds.height) / 2, thickness, color);
}
pub fn line(start: Point, end: Point, thickness: f32, color: Color) void {
    const delta = end.subtract(start);
    const length = @sqrt(delta.x * delta.x + delta.y * delta.y);
    if (length == 0 or thickness <= 0) return;
    const side: Point = .{
        .x = -delta.y * thickness / (2 * length),
        .y = delta.x * thickness / (2 * length),
    };
    const points = [_]Vertex{
        vertex(start.subtract(side), .{ .x = 0, .y = 0 }, color),
        vertex(start.add(side), .{ .x = 0, .y = 0 }, color),
        vertex(end.add(side), .{ .x = 0, .y = 0 }, color),
        vertex(end.subtract(side), .{ .x = 0, .y = 0 }, color),
    };
    mesh(null, &points, &.{
        0,
        1,
        2,
        0,
        2,
        3,
    });
}
/// Uploads tightly packed straight RGBA; the caller owns the returned texture.
pub fn upload(pixels: []const u8, width: i32, height: i32) ResourceError!Texture {
    std.debug.assert(width > 0 and height > 0 and pixels.len == @as(usize, @intCast(width * height)) * 4);
    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_RGBA32,
        c.SDL_TEXTUREACCESS_STATIC,
        width,
        height,
    ) orelse return error.GraphicsUnavailable;
    errdefer c.SDL_DestroyTexture(texture);
    if (!c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND) or
        !c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_LINEAR) or
        !c.SDL_UpdateTexture(texture, null, pixels.ptr, width * 4)) return error.GraphicsUnavailable;
    return texture;
}
pub const destroyTexture = c.SDL_DestroyTexture;

/// Read the completed backbuffer before presentation; owns no resources on return.
pub fn saveScreenshot(path: [:0]const u8) SaveError!void {
    const surface = c.SDL_RenderReadPixels(renderer, null) orelse return error.GraphicsUnavailable;
    defer c.SDL_DestroySurface(surface);
    const rgba = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_RGBA32) orelse return error.GraphicsUnavailable;
    defer c.SDL_DestroySurface(rgba);
    var output = std.mem.zeroes(png.png_image);
    output.version = png.PNG_IMAGE_VERSION;
    output.width = @intCast(rgba.*.w);
    output.height = @intCast(rgba.*.h);
    output.format = png.PNG_FORMAT_RGBA;
    if (png.png_image_write_to_file(&output, path, 0, rgba.*.pixels, rgba.*.pitch, null) == 0)
        return error.ImageOutputUnavailable;
}

fn testRenderer() !*c.SDL_Surface {
    const surface = c.SDL_CreateSurface(320, 200, c.SDL_PIXELFORMAT_RGBA32) orelse return error.GraphicsUnavailable;
    errdefer c.SDL_DestroySurface(surface);
    renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.GraphicsUnavailable;
    beginFrame();
    check(c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND));
    return surface;
}
fn testPixel(surface: *c.SDL_Surface, x: i32, y: i32) Color {
    var color: Color = undefined;
    std.debug.assert(c.SDL_ReadSurfacePixel(surface, x, y, &color.r, &color.g, &color.b, &color.a));
    return color;
}

test "SDL nested clips restore their parent and preserve translucent draw order" {
    const testing = std.testing;
    const surface = try testRenderer();
    defer c.SDL_DestroySurface(surface);
    defer deinit();
    clear(.black);
    beginClip(.init(10, 10, 100, 100));
    rectangle(.init(0, 0, 320, 200), .init(255, 0, 0, 255));
    beginClip(.init(30, 30, 200, 100));
    rectangle(.init(0, 0, 320, 200), .init(0, 0, 255, 128));
    endClip();
    rectangle(.init(15, 15, 5, 5), .white);
    endClip();
    rectangle(.init(200, 20, 8, 8), .white);
    flush();
    try testing.expect(!failed);
    try testing.expectEqual(Color.black, testPixel(surface, 5, 5));
    try testing.expectEqual(Color.black, testPixel(surface, 120, 50));
    try testing.expectEqual(Color.white, testPixel(surface, 16, 16));
    try testing.expectEqual(Color.white, testPixel(surface, 202, 22));
    const mixed = testPixel(surface, 50, 50);
    try testing.expect(mixed.r >= 126 and mixed.r <= 128);
    try testing.expect(mixed.b >= 127 and mixed.b <= 128);
    try testing.expectEqual(@as(u8, 0), mixed.g);
}

test "rectangle batches preserve clipping and blend order across capacity and reuse" {
    const testing = std.testing;
    const surface = try testRenderer();
    defer c.SDL_DestroySurface(surface);
    defer deinit();
    clear(.black);
    beginClip(.init(10, 10, 100, 100));
    var batch: RectangleBatch = .{};
    batch.rectangle(.init(0, 0, 320, 200), .init(255, 0, 0, 255));
    // The overlapping blue rectangle must follow the red one across a full batch.
    for (0..255) |_| batch.rectangle(.init(200, 150, 1, 1), .white);
    batch.rectangle(.init(30, 30, 100, 100), .init(0, 0, 255, 128));
    batch.submit();
    endClip();
    rectangle(.init(15, 15, 5, 5), .white);
    batch.rectangle(.init(200, 20, 8, 8), .white);
    batch.submit();
    batch.submit();
    flush();
    try testing.expect(!failed);
    try testing.expectEqual(Color.black, testPixel(surface, 5, 5));
    try testing.expectEqual(Color.black, testPixel(surface, 120, 50));
    try testing.expectEqual(Color.white, testPixel(surface, 16, 16));
    try testing.expectEqual(Color.white, testPixel(surface, 202, 22));
    const mixed = testPixel(surface, 50, 50);
    try testing.expect(mixed.r >= 126 and mixed.r <= 128);
    try testing.expect(mixed.b >= 127 and mixed.b <= 128);
    try testing.expectEqual(@as(u8, 0), mixed.g);
}

test "SDL rounded geometry retains filled centers and transparent corners at fractional scales" {
    const testing = std.testing;
    const surface = try testRenderer();
    defer c.SDL_DestroySurface(surface);
    defer deinit();
    for ([_]f32{
        1,
        1.25,
        2,
    }) |factor| {
        transform = .{ .x = factor, .y = factor };
        clear(.black);
        roundedRectangle(.init(20, 20, 80, 40), 1, .white);
        flush();
        try testing.expect(!failed);
        try testing.expectEqual(Color.white, testPixel(surface, @intFromFloat(60 * factor), @intFromFloat(40 * factor)));
        try testing.expectEqual(Color.black, testPixel(surface, @intFromFloat(20 * factor), @intFromFloat(20 * factor)));
        var blended: usize = 0;
        var y: i32 = @intFromFloat(20 * factor);
        while (y < @as(i32, @intFromFloat(40 * factor))) : (y += 1) {
            var x: i32 = @intFromFloat(20 * factor);
            while (x < @as(i32, @intFromFloat(40 * factor))) : (x += 1) {
                const pixel = testPixel(surface, x, y);
                if (pixel.r > 0 and pixel.r < 255) blended += 1;
            }
        }
        try testing.expect(blended > 0);
    }
}

test "SDL embedded text renders tinted UTF-8 and fits complete glyphs without recreating textures" {
    const Font = @import("Font.zig");
    const testing = std.testing;
    const surface = try testRenderer();
    defer c.SDL_DestroySurface(surface);
    defer deinit();
    var font = try Font.init(testing.allocator, @embedFile("fonts/Inter-Regular.ttf"));
    defer font.deinit();
    const texture = font.texture;
    const prefix_width = font.measure("Aµ", 24, 0).x;
    const fit = font.fit("Aµ→B", 24, prefix_width + 0.01);
    try testing.expectEqualStrings("Aµ", "Aµ→B"[0..fit.len]);
    try testing.expectApproxEqAbs(prefix_width, fit.width, 0.001);
    for (0..2) |_| {
        clear(.black);
        font.draw("Aµ→B", .{ .x = 10, .y = 10 }, 24, 0, .init(0, 255, 0, 255));
        flush();
        var ink: usize = 0;
        for (10..50) |y| for (10..100) |x| {
            const pixel = testPixel(surface, @intCast(x), @intCast(y));
            if (pixel.g > 0) ink += 1;
            try testing.expectEqual(@as(u8, 0), pixel.r);
            try testing.expectEqual(@as(u8, 0), pixel.b);
        };
        try testing.expect(ink > 50);
        try testing.expectEqual(texture, font.texture);
        try testing.expect(!failed);
    }
}

test "SDL clipping rounds physical edges after scaling fractional logical bounds" {
    const surface = try testRenderer();
    defer c.SDL_DestroySurface(surface);
    defer deinit();
    transform = .{ .x = 2, .y = 2 };
    clear(.black);
    beginClip(.init(10.75, 10.75, 1, 1));
    rectangle(.init(0, 0, 50, 50), .white);
    endClip();
    flush();
    try std.testing.expectEqual(Color.black, testPixel(surface, 20, 22));
    try std.testing.expectEqual(Color.white, testPixel(surface, 23, 23));
    try std.testing.expectEqual(Color.black, testPixel(surface, 24, 23));
}
