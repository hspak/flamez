//! SDL window and event ownership. Input edges survive waits until a frame consumes them.
const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.desktop);
const app_icon = @import("app_icon");
const Point = @import("geometry.zig").Point;
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

comptime {
    if (!@hasDecl(c, "SDL_EVENT_PINCH_UPDATE")) @compileError("Flamez requires SDL 3.4 or newer headers");
}

var handle: ?*c.SDL_Window = null;
var input: Input = .{};
var metrics: Metrics = .{};
var cursors: [4]?*c.SDL_Cursor = @splat(null);
var cursor_kind: ?Cursor = null;
var requested_cursor: Cursor = .default;
var last_frame: u64 = 0;
var frame_seconds: f32 = 1.0 / 60.0;
var frame_rate: u32 = 0;
pub var idle = false;

pub const OpenError = error{WindowUnavailable};
const Metrics = struct {
    width: i32 = 0,
    height: i32 = 0,
    pixel_width: i32 = 0,
    pixel_height: i32 = 0,
    density: f32 = 1,
    interval_ns: u64 = std.time.ns_per_s / 120,
};
pub const Key = enum(c.SDL_Scancode) {
    a = c.SDL_SCANCODE_A,
    c = c.SDL_SCANCODE_C,
    s = c.SDL_SCANCODE_S,
    zero = c.SDL_SCANCODE_0,
    minus = c.SDL_SCANCODE_MINUS,
    equal = c.SDL_SCANCODE_EQUALS,
    f5 = c.SDL_SCANCODE_F5,
    escape = c.SDL_SCANCODE_ESCAPE,
    left_control = c.SDL_SCANCODE_LCTRL,
    right_control = c.SDL_SCANCODE_RCTRL,
    left_shift = c.SDL_SCANCODE_LSHIFT,
    right_shift = c.SDL_SCANCODE_RSHIFT,
    left_super = c.SDL_SCANCODE_LGUI,
    right_super = c.SDL_SCANCODE_RGUI,
    up = c.SDL_SCANCODE_UP,
    down = c.SDL_SCANCODE_DOWN,
    left = c.SDL_SCANCODE_LEFT,
    right = c.SDL_SCANCODE_RIGHT,
    page_up = c.SDL_SCANCODE_PAGEUP,
    page_down = c.SDL_SCANCODE_PAGEDOWN,
    home = c.SDL_SCANCODE_HOME,
    end = c.SDL_SCANCODE_END,
    kp_0 = c.SDL_SCANCODE_KP_0,
    kp_subtract = c.SDL_SCANCODE_KP_MINUS,
    kp_equal = c.SDL_SCANCODE_KP_EQUALS,
    kp_add = c.SDL_SCANCODE_KP_PLUS,
};
pub const Button = enum(u5) {
    left = c.SDL_BUTTON_LEFT,
    middle = c.SDL_BUTTON_MIDDLE,
    right = c.SDL_BUTTON_RIGHT,
};
pub const Cursor = enum {
    default,
    pointing_hand,
    resize_ns,
    ibeam,
};
const Keys = std.StaticBitSet(c.SDL_SCANCODE_COUNT);
const Input = struct {
    keys: Keys = .initEmpty(),
    pressed_keys: Keys = .initEmpty(),
    action_modifiers: c.SDL_Keymod = 0,
    buttons: u32 = 0,
    pressed_buttons: u32 = 0,
    released_buttons: u32 = 0,
    pointer: Point = .{ .x = 0, .y = 0 },
    press_pointer: Point = .{ .x = 0, .y = 0 },
    scroll: Point = .{ .x = 0, .y = 0 },
    pinch: f32 = 0,
    changed: bool = false,
    closing: bool = false,
    renderer_lost: bool = false,

    fn consume(self: *Input) void {
        self.pressed_keys = .initEmpty();
        self.action_modifiers = 0;
        self.pressed_buttons = 0;
        self.released_buttons = 0;
        self.scroll = .{ .x = 0, .y = 0 };
        self.pinch = 0;
        self.changed = false;
    }

    fn event(self: *Input, e: c.SDL_Event) void {
        switch (e.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => self.closing = true,
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                const key = e.key.scancode;
                if (key > 0 and key < c.SDL_SCANCODE_COUNT) {
                    self.keys.setValue(@intCast(key), e.key.down);
                    if (e.key.down and !e.key.repeat) {
                        self.pressed_keys.set(@intCast(key));
                        self.action_modifiers |= e.key.mod;
                    }
                }
                self.changed = true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                self.pointer = .{ .x = e.motion.x, .y = e.motion.y };
                self.changed = true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
                self.pointer = .{ .x = e.button.x, .y = e.button.y };
                if (e.button.button > 0 and e.button.button <= 32) {
                    const mask = @as(u32, 1) << @as(u5, @intCast(e.button.button - 1));
                    if (e.button.down) {
                        self.buttons |= mask;
                        self.pressed_buttons |= mask;
                        if (e.button.button == c.SDL_BUTTON_LEFT) self.press_pointer = self.pointer;
                    } else {
                        self.buttons &= ~mask;
                        self.released_buttons |= mask;
                    }
                }
                self.changed = true;
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                const sign: f32 = if (e.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1 else 1;
                self.scroll.x += e.wheel.x * sign;
                self.scroll.y += e.wheel.y * sign;
                // The wheel carries no modifiers: snapshot the ordered key state.
                if (self.keys.isSet(c.SDL_SCANCODE_LCTRL)) self.action_modifiers |= c.SDL_KMOD_LCTRL;
                if (self.keys.isSet(c.SDL_SCANCODE_RCTRL)) self.action_modifiers |= c.SDL_KMOD_RCTRL;
                if (self.keys.isSet(c.SDL_SCANCODE_LSHIFT)) self.action_modifiers |= c.SDL_KMOD_LSHIFT;
                if (self.keys.isSet(c.SDL_SCANCODE_RSHIFT)) self.action_modifiers |= c.SDL_KMOD_RSHIFT;
                self.changed = true;
            },
            c.SDL_EVENT_PINCH_UPDATE => {
                if (std.math.isFinite(e.pinch.scale) and e.pinch.scale > 0)
                    self.pinch += @log(e.pinch.scale) / @log(@as(f32, 1.25));
                self.changed = true;
            },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                self.keys = .initEmpty();
                self.buttons = 0;
                self.consume();
                self.changed = true;
            },
            c.SDL_EVENT_WINDOW_MOUSE_LEAVE => {
                self.pointer = .{ .x = -1, .y = -1 };
                self.changed = true;
            },
            c.SDL_EVENT_WINDOW_RESIZED,
            c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
            c.SDL_EVENT_WINDOW_DISPLAY_CHANGED,
            c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED,
            c.SDL_EVENT_WINDOW_EXPOSED,
            c.SDL_EVENT_WINDOW_RESTORED,
            c.SDL_EVENT_WINDOW_FOCUS_GAINED,
            => {
                self.changed = true;
            },
            c.SDL_EVENT_RENDER_DEVICE_RESET, c.SDL_EVENT_RENDER_TARGETS_RESET => self.renderer_lost = true,
            else => {}, // SDL's event type is an open integer namespace.
        }
    }

    fn framePointer(self: *const Input) Point {
        // Hit testing and drag initialization must use the press location even
        // when later motion arrives while waiting for the next frame deadline.
        return if (self.pressed_buttons & c.SDL_BUTTON_LMASK != 0) self.press_pointer else self.pointer;
    }
};

/// Owns SDL and its window until close; all calls must stay on the main thread.
pub fn open(w: i32, h: i32, title: [:0]const u8, high_density: bool) OpenError!void {
    _ = c.SDL_SetHint(c.SDL_HINT_APP_ID, "flamez");
    if (comptime builtin.os.tag == .linux)
        _ = c.SDL_SetHintWithPriority(c.SDL_HINT_VIDEO_DRIVER, "wayland", c.SDL_HINT_DEFAULT);
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return unavailable();
    errdefer c.SDL_Quit();
    handle = c.SDL_CreateWindow(title, w, h, c.SDL_WINDOW_RESIZABLE |
        @as(c.SDL_WindowFlags, if (high_density) c.SDL_WINDOW_HIGH_PIXEL_DENSITY else 0)) orelse return unavailable();
    setIcon();
    input = .{};
    last_frame = 0;
    frame_rate = 0;
    idle = false;
    _ = c.SDL_SetWindowMinimumSize(handle, 760, 520);
    refreshMetrics();
}
fn setIcon() void {
    // Embedding also gives command-line launches a macOS Dock / X11 window icon.
    // Wayland compositors can instead resolve flamez.desktop through the app ID.
    const png = app_icon.png;
    const stream = c.SDL_IOFromConstMem(png.ptr, png.len) orelse {
        log.warn("Icon stream: {s}", .{c.SDL_GetError()});
        return;
    };
    const surface = c.SDL_LoadPNG_IO(stream, true) orelse {
        log.warn("Icon PNG: {s}", .{c.SDL_GetError()});
        return;
    };
    defer c.SDL_DestroySurface(surface);
    if (!c.SDL_SetWindowIcon(handle, surface))
        log.debug("Window icon: {s}", .{c.SDL_GetError()});
}
fn unavailable() OpenError {
    log.err("SDL window: {s}", .{c.SDL_GetError()});
    return error.WindowUnavailable;
}
pub fn close() void {
    for (&cursors) |*cursor| {
        if (cursor.*) |owned| c.SDL_DestroyCursor(owned);
        cursor.* = null;
    }
    cursor_kind = null;
    c.SDL_DestroyWindow(handle);
    handle = null;
    c.SDL_Quit();
}
pub fn window() ?*c.SDL_Window {
    return handle;
}
pub fn poll() void {
    c.SDL_PumpEvents();
    var event: c.SDL_Event = undefined;
    while (c.SDL_PeepEvents(&event, 1, c.SDL_GETEVENT, c.SDL_EVENT_FIRST, c.SDL_EVENT_LAST) > 0)
        input.event(event);
    refreshMetrics();
}
/// Wait without removing queued events. Services are revisited at least every 25 ms.
pub fn waitNs(ns: u64) void {
    if (ns >= std.time.ns_per_ms) {
        _ = c.SDL_WaitEventTimeout(null, @intCast(@min(25, ns / std.time.ns_per_ms)));
    } else if (ns > 0) c.SDL_DelayNS(ns);
}
fn refreshMetrics() void {
    _ = c.SDL_GetWindowSize(handle, &metrics.width, &metrics.height);
    _ = c.SDL_GetWindowSizeInPixels(handle, &metrics.pixel_width, &metrics.pixel_height);
    // UI and automation use native window coordinates. Density is stable across
    // fractional-size rounding, unlike framebuffer_width / window_width.
    const pixel_density = c.SDL_GetWindowPixelDensity(handle);
    metrics.density = if (std.math.isFinite(pixel_density) and pixel_density > 0) pixel_density else 1;
    metrics.interval_ns = std.time.ns_per_s / 120;
    if (c.SDL_GetCurrentDisplayMode(c.SDL_GetDisplayForWindow(handle))) |mode| {
        const hz = mode.*.refresh_rate;
        if (std.math.isFinite(hz) and hz >= 1 and hz <= 1000)
            metrics.interval_ns = @intFromFloat(std.time.ns_per_s / @as(f64, hz));
    }
}
pub const ticks = c.SDL_GetTicksNS;
pub fn consumeInput() void {
    input.consume();
}
pub fn changed() bool {
    return input.changed;
}
pub fn shouldClose() bool {
    return input.closing;
}
pub fn rendererLost() bool {
    return input.renderer_lost;
}
pub fn inputHeld() bool {
    return input.keys.count() != 0 or input.buttons != 0;
}
pub fn minimized() bool {
    return c.SDL_GetWindowFlags(handle) & c.SDL_WINDOW_MINIMIZED != 0;
}
pub fn width() i32 {
    return metrics.width;
}
pub fn height() i32 {
    return metrics.height;
}
pub fn pixelWidth() i32 {
    return metrics.pixel_width;
}
pub fn pixelHeight() i32 {
    return metrics.pixel_height;
}
pub fn density() f32 {
    return metrics.density;
}
pub fn intervalNs() u64 {
    return metrics.interval_ns;
}
/// Uses a pending left press for its first frame, then the latest pointer position.
pub fn mouse() Point {
    return input.framePointer();
}
pub fn wheel() Point {
    return input.scroll;
}
pub fn pinchZoom() f32 {
    return input.pinch;
}
pub fn keyPressed(key: Key) bool {
    return input.pressed_keys.isSet(@intCast(@intFromEnum(key)));
}
pub fn keyDown(key: Key) bool {
    if (input.keys.isSet(@intCast(@intFromEnum(key)))) return true;
    const modifier: c.SDL_Keymod = switch (key) {
        .left_control => c.SDL_KMOD_LCTRL,
        .right_control => c.SDL_KMOD_RCTRL,
        .left_shift => c.SDL_KMOD_LSHIFT,
        .right_shift => c.SDL_KMOD_RSHIFT,
        .left_super => c.SDL_KMOD_LGUI,
        .right_super => c.SDL_KMOD_RGUI,
        .a,
        .c,
        .s,
        .zero,
        .minus,
        .equal,
        .f5,
        .escape,
        .up,
        .down,
        .left,
        .right,
        .page_up,
        .page_down,
        .home,
        .end,
        .kp_0,
        .kp_subtract,
        .kp_equal,
        .kp_add,
        => return false,
    };
    return input.action_modifiers & modifier != 0;
}
fn buttonMask(button: Button) u32 {
    return @as(u32, 1) << (@intFromEnum(button) - 1);
}
pub fn buttonDown(button: Button) bool {
    return input.buttons & buttonMask(button) != 0;
}
pub fn buttonPressed(button: Button) bool {
    return input.pressed_buttons & buttonMask(button) != 0;
}
pub fn buttonReleased(button: Button) bool {
    return input.released_buttons & buttonMask(button) != 0;
}
pub fn setClipboardText(value: [:0]const u8) void {
    if (!c.SDL_SetClipboardText(value)) log.err("SDL clipboard: {s}", .{c.SDL_GetError()});
}
pub fn setCursor(kind: Cursor) void {
    requested_cursor = kind;
}
/// Applies the final hover cursor once, avoiding default/hover transitions within one frame.
pub fn commitCursor() void {
    const kind = requested_cursor;
    if (cursor_kind == kind) return;
    const slot = &cursors[@intFromEnum(kind)];
    if (slot.* == null) slot.* = c.SDL_CreateSystemCursor(switch (kind) {
        .default => c.SDL_SYSTEM_CURSOR_DEFAULT,
        .pointing_hand => c.SDL_SYSTEM_CURSOR_POINTER,
        .resize_ns => c.SDL_SYSTEM_CURSOR_NS_RESIZE,
        .ibeam => c.SDL_SYSTEM_CURSOR_TEXT,
    });
    if (slot.*) |cursor| {
        _ = c.SDL_SetCursor(cursor);
        cursor_kind = kind;
    }
}
/// Frame-start diagnostics exclude intentional idle time; delta is bounded for Clay scrolling.
pub fn beginFrame(now: u64, active: bool) void {
    const delta = now -| last_frame;
    frame_seconds = if (last_frame == 0) 1.0 / 60.0 else @min(0.05, @as(f32, @floatFromInt(delta)) / 1e9);
    if (!idle and active and last_frame != 0 and delta > 0) frame_rate = @intCast(std.time.ns_per_s / delta);
    idle = !active;
    last_frame = now;
}
pub fn frameTime() f32 {
    return frame_seconds;
}
pub fn fps() u32 {
    return frame_rate;
}

test "SDL input retains a short click and fractional wheel until consumed" {
    const testing = std.testing;
    var sample: Input = .{};
    var event = std.mem.zeroes(c.SDL_Event);
    event.button = .{
        .type = c.SDL_EVENT_MOUSE_BUTTON_DOWN,
        .button = c.SDL_BUTTON_LEFT,
        .down = true,
        .x = 32,
        .y = 64,
    };
    sample.event(event);
    event.button.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.down = false;
    sample.event(event);
    event = std.mem.zeroes(c.SDL_Event);
    event.wheel = .{
        .type = c.SDL_EVENT_MOUSE_WHEEL,
        .x = 0.25,
        .y = -0.5,
    };
    sample.event(event);
    sample.event(event);
    try testing.expectEqual(@as(u32, 0), sample.buttons);
    try testing.expectEqual(@as(u32, 1), sample.pressed_buttons);
    try testing.expectEqual(@as(u32, 1), sample.released_buttons);
    try testing.expectEqual(Point{ .x = 0.5, .y = -1 }, sample.scroll);
    try testing.expectEqual(Point{ .x = 32, .y = 64 }, sample.pointer);
    sample.consume();
    try testing.expect(!sample.changed);
    try testing.expectEqual(@as(u32, 0), sample.pressed_buttons);
    try testing.expectEqual(Point{ .x = 0, .y = 0 }, sample.scroll);
}

test "SDL held keys survive repeats and frame consumption but clear on release or focus loss" {
    const testing = std.testing;
    var sample: Input = .{};
    var event = std.mem.zeroes(c.SDL_Event);
    event.key = .{
        .type = c.SDL_EVENT_KEY_DOWN,
        .scancode = c.SDL_SCANCODE_LCTRL,
        .down = true,
    };
    sample.event(event);
    event.key.repeat = true;
    sample.event(event);
    sample.consume();
    try testing.expectEqual(@as(usize, 1), sample.keys.count());
    sample.event(event);
    try testing.expectEqual(@as(usize, 0), sample.pressed_keys.count());
    event.key.type = c.SDL_EVENT_KEY_UP;
    event.key.down = false;
    sample.event(event);
    try testing.expectEqual(@as(usize, 0), sample.keys.count());
    event.key.type = c.SDL_EVENT_KEY_DOWN;
    event.key.down = true;
    sample.event(event);
    event = std.mem.zeroes(c.SDL_Event);
    event.button = .{
        .type = c.SDL_EVENT_MOUSE_BUTTON_DOWN,
        .button = c.SDL_BUTTON_RIGHT,
        .down = true,
    };
    sample.event(event);
    try testing.expect(sample.buttons != 0);
    event.type = c.SDL_EVENT_WINDOW_FOCUS_LOST;
    sample.event(event);
    try testing.expectEqual(@as(usize, 0), sample.keys.count());
    try testing.expectEqual(@as(u32, 0), sample.buttons);
    try testing.expectEqual(@as(usize, 0), sample.pressed_keys.count());
}

test "SDL event waits leave queued input for the application" {
    try std.testing.expect(c.SDL_Init(c.SDL_INIT_EVENTS));
    defer c.SDL_Quit();
    var event = std.mem.zeroes(c.SDL_Event);
    event.key = .{
        .type = c.SDL_EVENT_KEY_DOWN,
        .scancode = c.SDL_SCANCODE_S,
        .down = true,
    };
    try std.testing.expect(c.SDL_PushEvent(&event));
    waitNs(std.time.ns_per_ms);
    var received: c.SDL_Event = undefined;
    try std.testing.expectEqual(@as(c_int, 1), c.SDL_PeepEvents(
        &received,
        1,
        c.SDL_GETEVENT,
        c.SDL_EVENT_KEY_DOWN,
        c.SDL_EVENT_KEY_DOWN,
    ));
    try std.testing.expectEqual(@as(c.SDL_Scancode, c.SDL_SCANCODE_S), received.key.scancode);
}

test "SDL pinch accumulates multiplicative updates and rejects invalid scales" {
    var sample: Input = .{};
    var event = std.mem.zeroes(c.SDL_Event);
    event.pinch = .{ .type = c.SDL_EVENT_PINCH_UPDATE, .scale = 1.25 };
    sample.event(event);
    sample.event(event);
    event.pinch.scale = 0;
    sample.event(event);
    event.pinch.scale = std.math.nan(f32);
    sample.event(event);
    try std.testing.expectApproxEqAbs(@as(f32, 2), sample.pinch, 0.0001);
}

test "SDL click uses its press position even when motion arrives before drawing" {
    var sample: Input = .{};
    var event = std.mem.zeroes(c.SDL_Event);
    event.button = .{
        .type = c.SDL_EVENT_MOUSE_BUTTON_DOWN,
        .button = c.SDL_BUTTON_LEFT,
        .down = true,
        .x = 590,
        .y = 42,
    };
    sample.event(event);
    event = std.mem.zeroes(c.SDL_Event);
    event.motion = .{
        .type = c.SDL_EVENT_MOUSE_MOTION,
        .x = 23,
        .y = 65,
    };
    sample.event(event);
    try std.testing.expectEqual(Point{ .x = 590, .y = 42 }, sample.framePointer());
    sample.consume();
    try std.testing.expectEqual(Point{ .x = 23, .y = 65 }, sample.framePointer());
    try std.testing.expectEqual(@as(u32, 1), sample.buttons);
}
