//! Logical UI coordinates and straight-alpha RGBA colors.

pub const Point = extern struct {
    x: f32,
    y: f32,

    pub fn add(p: Point, q: Point) Point {
        return .{ .x = p.x + q.x, .y = p.y + q.y };
    }
    pub fn subtract(p: Point, q: Point) Point {
        return .{ .x = p.x - q.x, .y = p.y - q.y };
    }
    pub fn scale(p: Point, factor: f32) Point {
        return .{ .x = p.x * factor, .y = p.y * factor };
    }
};
pub const Rect = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn init(x: f32, y: f32, width: f32, height: f32) Rect {
        return .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        };
    }
    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x and p.y >= r.y and p.x <= r.x + r.width and p.y <= r.y + r.height;
    }
};
pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn init(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = r,
            .g = g,
            .b = b,
            .a = a,
        };
    }
    pub const white: Color = .{
        .r = 255,
        .g = 255,
        .b = 255,
        .a = 255,
    };
    pub const black: Color = .{
        .r = 0,
        .g = 0,
        .b = 0,
        .a = 255,
    };
};
