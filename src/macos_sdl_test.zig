//! Opt-in native desktop integration checks; requires an unlocked macOS GUI session.
const std = @import("std");
const log = std.log.scoped(.macos_sdl_test);
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const desktop = @import("desktop.zig");
const graphics = @import("graphics.zig");
const Font = @import("Font.zig");
const footer_font = @import("footer_font");
const c = desktop.c;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const output = if (args.len > 1) args[1] else "artifacts/macos-sdl";
    try std.Io.Dir.cwd().createDirPath(init.io, output);
    for ([_]bool{ false, true }) |high_density| {
        const path = try std.fmt.allocPrintSentinel(init.arena.allocator(), "{s}/native-{s}.png", .{
            output,
            if (high_density) "high-density" else "low-density",
        }, 0);
        try validateWindow(init.gpa, high_density, path);
    }
    log.info("PASS: native window lifecycle, metrics, input, fonts, clips, alpha and PNG readback", .{});
}

fn validateWindow(gpa: std.mem.Allocator, high_density: bool, path: [:0]const u8) !void {
    try desktop.open(900, 600, "Flamez native SDL validation", high_density);
    defer desktop.close();
    try graphics.init(true);
    defer graphics.deinit();
    const window = desktop.window();
    const renderer = c.SDL_GetRenderer(window);
    const expected = std.c.getenv("SDL_RENDER_DRIVER") orelse "metal";
    try std.testing.expectEqualStrings(std.mem.span(expected), std.mem.span(c.SDL_GetRendererName(renderer)));
    try std.testing.expectEqualStrings("cocoa", std.mem.span(c.SDL_GetCurrentVideoDriver()));
    var minimum_width: c_int = 0;
    var minimum_height: c_int = 0;
    try expect(c.SDL_GetWindowMinimumSize(window, &minimum_width, &minimum_height));
    try expectEqual(@as(c_int, 760), minimum_width);
    try expectEqual(@as(c_int, 520), minimum_height);

    try expect(c.SDL_SetWindowSize(window, 1000, 700));
    try expect(c.SDL_SyncWindow(window));
    desktop.poll();
    try expectEqual(@as(i32, 1000), desktop.width());
    try expectEqual(@as(i32, 700), desktop.height());
    var render_width: c_int = 0;
    var render_height: c_int = 0;
    try expect(c.SDL_GetRenderOutputSize(renderer, &render_width, &render_height));
    try expectEqual(desktop.pixelWidth(), render_width);
    try expectEqual(desktop.pixelHeight(), render_height);
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(render_width)),
        @as(f32, @floatFromInt(desktop.width())) * desktop.density(),
        1,
    );
    if (!high_density) try expectEqual(@as(f32, 1), desktop.density());
    log.info("high_density={} logical={d}x{d} pixels={d}x{d} density={d} interval_ns={d}", .{
        high_density,
        desktop.width(),
        desktop.height(),
        render_width,
        render_height,
        desktop.density(),
        desktop.intervalNs(),
    });

    try expect(c.SDL_HideWindow(window));
    try expect(c.SDL_SyncWindow(window));
    try expect(c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_HIDDEN != 0);
    try expect(c.SDL_ShowWindow(window));
    try expect(c.SDL_SyncWindow(window));
    try expect(c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_HIDDEN == 0);
    try expect(c.SDL_MinimizeWindow(window));
    try waitMinimized(true);
    try expect(c.SDL_RestoreWindow(window));
    try waitMinimized(false);

    var fonts = [_]Font{
        try Font.init(gpa, @embedFile("fonts/Inter-Regular.ttf")),
        undefined,
        undefined,
    };
    defer fonts[0].deinit();
    fonts[1] = try Font.init(gpa, @embedFile("fonts/Inter-Bold.ttf"));
    defer fonts[1].deinit();
    fonts[2] = try Font.init(gpa, footer_font.ttf);
    defer fonts[2].deinit();
    graphics.beginFrame();
    graphics.clear(.black);
    graphics.beginClip(.init(10, 10, 100, 100));
    graphics.rectangle(.init(0, 0, 900, 600), .init(255, 0, 0, 255));
    graphics.beginClip(.init(30, 30, 200, 100));
    graphics.rectangle(.init(0, 0, 900, 600), .init(0, 0, 255, 128));
    graphics.endClip();
    graphics.rectangle(.init(15, 15, 5, 5), .white);
    graphics.endClip();
    graphics.roundedRectangle(.init(200, 20, 80, 40), 1, .white);
    for (&fonts, 0..) |*font, index| {
        font.draw("Flamez Aµ→B — native SDL", .{
            .x = 20,
            .y = @floatFromInt(160 + index * 40),
        }, 24, 0, .init(0, 255, 0, 255));
    }
    graphics.flush();
    const surface = c.SDL_RenderReadPixels(renderer, null) orelse return error.ReadbackUnavailable;
    defer c.SDL_DestroySurface(surface);
    try expectEqual(render_width, surface.*.w);
    try expectEqual(render_height, surface.*.h);
    try expectEqual(graphics.Color.black, try pixel(surface, 5, 5));
    try expectEqual(graphics.Color.black, try pixel(surface, 120, 50));
    try expectEqual(graphics.Color.white, try pixel(surface, 16, 16));
    try expectEqual(graphics.Color.white, try pixel(surface, 240, 40));
    try expectEqual(graphics.Color.black, try pixel(surface, 200, 20));
    const mixed = try pixel(surface, 50, 50);
    try expect(mixed.r >= 126 and mixed.r <= 128 and mixed.b >= 127 and mixed.b <= 128);
    try expectEqual(@as(u8, 0), mixed.g);
    for (0..fonts.len) |index| {
        var ink: usize = 0;
        for (160 + index * 40..190 + index * 40) |y| {
            for (20..340) |x| {
                const color = try pixel(surface, @intCast(x), @intCast(y));
                if (color.g > 0 and color.r == 0 and color.b == 0) ink += 1;
            }
        }
        try expect(ink > 100);
    }
    try graphics.saveScreenshot(path);
    try std.testing.expectError(error.ImageOutputUnavailable, graphics.saveScreenshot("/nonexistent/flamez.png"));
    try graphics.endFrame();
    try validateInput();
}

fn waitMinimized(expected: bool) !void {
    const deadline = desktop.ticks() + 3 * std.time.ns_per_s;
    while (true) {
        desktop.poll();
        if (desktop.minimized() == expected) return;
        if (desktop.ticks() >= deadline) return error.WindowTransitionTimeout;
        desktop.waitNs(10 * std.time.ns_per_ms);
    }
}

fn pixel(surface: *c.SDL_Surface, x: i32, y: i32) !graphics.Color {
    var color: graphics.Color = undefined;
    const px: c_int = @intFromFloat(@as(f32, @floatFromInt(x)) * desktop.density());
    const py: c_int = @intFromFloat(@as(f32, @floatFromInt(y)) * desktop.density());
    try expect(c.SDL_ReadSurfacePixel(surface, px, py, &color.r, &color.g, &color.b, &color.a));
    return color;
}

fn push(event: c.SDL_Event) !void {
    var owned = event;
    try expect(c.SDL_PushEvent(&owned));
}

fn validateInput() !void {
    desktop.poll();
    desktop.consumeInput();
    try push(.{ .key = .{
        .type = c.SDL_EVENT_KEY_DOWN,
        .scancode = c.SDL_SCANCODE_LCTRL,
        .down = true,
    } });
    try push(.{ .wheel = .{
        .type = c.SDL_EVENT_MOUSE_WHEEL,
        .x = 0.25,
        .y = -0.5,
    } });
    try push(.{ .key = .{
        .type = c.SDL_EVENT_KEY_UP,
        .scancode = c.SDL_SCANCODE_LCTRL,
        .down = false,
    } });
    try push(.{ .pinch = .{ .type = c.SDL_EVENT_PINCH_UPDATE, .scale = 1.25 } });
    desktop.waitNs(std.time.ns_per_ms);
    desktop.poll();
    try expect(desktop.keyDown(.left_control));
    try expectEqual(@as(f32, 0.25), desktop.wheel().x);
    try expectEqual(@as(f32, -0.5), desktop.wheel().y);
    try std.testing.expectApproxEqAbs(@as(f32, 1), desktop.pinchZoom(), 0.0001);
    desktop.consumeInput();
    try expect(!desktop.keyDown(.left_control));
    try expectEqual(@as(f32, 0), desktop.pinchZoom());
    try push(.{ .button = .{
        .type = c.SDL_EVENT_MOUSE_BUTTON_DOWN,
        .button = c.SDL_BUTTON_LEFT,
        .down = true,
        .x = 20,
        .y = 30,
    } });
    desktop.poll();
    try expect(desktop.buttonDown(.left));
    try push(.{ .type = c.SDL_EVENT_WINDOW_FOCUS_LOST });
    desktop.poll();
    try expect(!desktop.inputHeld());
    try push(.{ .type = c.SDL_EVENT_RENDER_DEVICE_RESET });
    desktop.poll();
    try expect(desktop.rendererLost());
    try push(.{ .type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED });
    desktop.poll();
    try expect(desktop.shouldClose());
}
