//! Embedded-font metrics and immutable SDL glyph atlas. Measurement and drawing share advances.
const std = @import("std");
const Allocator = std.mem.Allocator;
const graphics = @import("graphics.zig");
const ft = @cImport({
    @cInclude("freetype/freetype.h");
});
const Font = @This();

texture: graphics.Texture,
glyphs: [glyph_count]Glyph,

const atlas_size = 1024;
const pixel_size = 64;
const extra_codepoints = [_]u21{
    0x2013,
    0x2014,
    0x2022,
    0x2026,
    0x2192,
    0x25b8,
    0x2260,
};
const glyph_count = 95 + 96 + extra_codepoints.len;
const Glyph = struct {
    source: graphics.Rect,
    x: f32,
    y: f32,
    advance: f32,
};
pub const Prefix = struct { len: usize, width: f32 };
pub const InitError = Allocator.Error || graphics.ResourceError || error{ InvalidFont, AtlasFull };

/// Rasterizes embedded bytes once. Does not retain bytes or allocator; owns the SDL texture.
pub fn init(gpa: Allocator, bytes: []const u8) InitError!Font {
    var library: ft.FT_Library = undefined;
    try checkFont(ft.FT_Init_FreeType(&library));
    defer _ = ft.FT_Done_FreeType(library);
    var face: ft.FT_Face = undefined;
    try checkFont(ft.FT_New_Memory_Face(library, bytes.ptr, @intCast(bytes.len), 0, &face));
    defer _ = ft.FT_Done_Face(face);
    // Preserve the former ascent-to-descent pixel height, rather than treating
    // the requested height as an em size. FreeType accepts 1/64-point sizes at 72 DPI.
    const font_height = @as(i32, face.*.ascender) - face.*.descender;
    if (font_height <= 0) return error.InvalidFont;
    const em_size = @divTrunc(pixel_size * 64 * @as(i32, face.*.units_per_EM), font_height);
    try checkFont(ft.FT_Set_Char_Size(face, 0, em_size, 72, 72));
    const pixels = try gpa.alloc(u8, atlas_size * atlas_size * 4);
    defer gpa.free(pixels);
    // Straight-alpha filtering needs white RGB even in transparent atlas gutters.
    for (0..atlas_size * atlas_size) |index| pixels[index * 4 ..][0..4].* = .{
        255,
        255,
        255,
        0,
    };
    var glyphs: [glyph_count]Glyph = undefined;
    var x: usize = 1;
    var y: usize = 1;
    var row_height: usize = 0;
    const ascent = @as(f32, @floatFromInt(face.*.ascender)) * pixel_size /
        @as(f32, @floatFromInt(font_height));
    for (&glyphs, 0..) |*glyph, index| {
        try checkFont(ft.FT_Load_Char(face, codepoint(index), ft.FT_LOAD_RENDER | ft.FT_LOAD_NO_HINTING));
        const slot = face.*.glyph;
        const bitmap = slot.*.bitmap;
        if (bitmap.pixel_mode != ft.FT_PIXEL_MODE_GRAY and bitmap.width > 0) return error.InvalidFont;
        const w: usize = bitmap.width;
        const h: usize = bitmap.rows;
        if (x + w + 1 > atlas_size) {
            x = 1;
            y += row_height + 2;
            row_height = 0;
        }
        if (w + 2 > atlas_size or y + h + 1 > atlas_size) return error.AtlasFull;
        for (0..h) |row| {
            const pitch: usize = @intCast(@abs(bitmap.pitch));
            const source_row = if (bitmap.pitch >= 0) row else h - row - 1;
            for (0..w) |column| {
                const offset = ((y + row) * atlas_size + x + column) * 4;
                pixels[offset..][0..4].* = .{
                    255,
                    255,
                    255,
                    bitmap.buffer[source_row * pitch + column],
                };
            }
        }
        glyph.* = .{
            .source = .init(@floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h)),
            .x = @floatFromInt(slot.*.bitmap_left),
            .y = ascent - @as(f32, @floatFromInt(slot.*.bitmap_top)),
            .advance = @as(f32, @floatFromInt(slot.*.advance.x)) / 64,
        };
        x += w + 2;
        row_height = @max(row_height, h);
    }
    return .{ .texture = try graphics.upload(pixels, atlas_size, atlas_size), .glyphs = glyphs };
}
pub fn deinit(self: *Font) void {
    graphics.destroyTexture(self.texture);
    self.* = undefined;
}
fn checkFont(result: ft.FT_Error) error{ OutOfMemory, InvalidFont }!void {
    if (result == ft.FT_Err_Out_Of_Memory) return error.OutOfMemory;
    if (result != 0) return error.InvalidFont;
}
fn codepoint(index: usize) u21 {
    if (index < 95) return @intCast(index + 32);
    if (index < 191) return @intCast(index - 95 + 160);
    return extra_codepoints[index - 191];
}
fn glyphIndex(cp: u21) usize {
    if (cp >= 32 and cp < 127) return cp - 32;
    if (cp >= 160 and cp < 256) return cp - 160 + 95;
    for (extra_codepoints, 191..) |extra, index| if (extra == cp) return index;
    return '?' - 32;
}
fn nextCodepoint(bytes: []const u8, offset: *usize) u21 {
    const length = std.unicode.utf8ByteSequenceLength(bytes[offset.*]) catch 1;
    const end = @min(bytes.len, offset.* + length);
    const cp = std.unicode.utf8Decode(bytes[offset.*..end]) catch '?';
    offset.* = end;
    return cp;
}
/// Measures UTF-8 without allocation. Unsupported or malformed codepoints use the '?' glyph.
pub fn measure(self: *const Font, value: []const u8, size: f32, spacing: f32) graphics.Point {
    if (value.len == 0) return .{ .x = 0, .y = 0 };
    var width: f32 = 0;
    var line_width: f32 = 0;
    var height = size;
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < value.len) {
        const cp = nextCodepoint(value, &offset);
        if (cp == '\n') {
            width = @max(width, line_width);
            line_width = 0;
            count = 0;
            height += size * 1.5;
            continue;
        }
        if (count > 0) line_width += spacing;
        line_width += self.glyphs[glyphIndex(cp)].advance * size / pixel_size;
        count += 1;
    }
    return .{ .x = @max(width, line_width), .y = height };
}

/// Finds the longest complete UTF-8 prefix fitting a single line, without repeated scans.
pub fn fit(self: *const Font, value: []const u8, size: f32, max_width: f32) Prefix {
    var result: Prefix = .{ .len = 0, .width = 0 };
    var offset: usize = 0;
    while (offset < value.len) {
        const cp = nextCodepoint(value, &offset);
        if (cp == '\n') break;
        const width = result.width + self.glyphs[glyphIndex(cp)].advance * size / pixel_size;
        if (width > max_width) break;
        result = .{ .len = offset, .width = width };
    }
    return result;
}

/// Emits bounded indexed batches; steady-state text draws neither allocate nor upload pixels.
pub fn draw(
    self: *const Font,
    value: []const u8,
    position: graphics.Point,
    size: f32,
    spacing: f32,
    color: graphics.Color,
) void {
    var vertices: [256 * 4]graphics.Vertex = undefined;
    var indices: [256 * 6]u16 = undefined;
    var count: usize = 0;
    var offset: usize = 0;
    var pen = position;
    const factor = size / pixel_size;
    while (offset < value.len) {
        const cp = nextCodepoint(value, &offset);
        if (cp == '\n') {
            pen.x = position.x;
            pen.y += size * 1.5;
            continue;
        }
        const glyph = self.glyphs[glyphIndex(cp)];
        if (glyph.source.width > 0 and glyph.source.height > 0) {
            const x = pen.x + glyph.x * factor;
            const y = pen.y + glyph.y * factor;
            const right = x + glyph.source.width * factor;
            const bottom = y + glyph.source.height * factor;
            const u = glyph.source.x / atlas_size;
            const v = glyph.source.y / atlas_size;
            const u_end = (glyph.source.x + glyph.source.width) / atlas_size;
            const v_end = (glyph.source.y + glyph.source.height) / atlas_size;
            vertices[count * 4 ..][0..4].* = .{
                graphics.vertex(.{ .x = x, .y = y }, .{ .x = u, .y = v }, color),
                graphics.vertex(.{ .x = right, .y = y }, .{ .x = u_end, .y = v }, color),
                graphics.vertex(.{ .x = right, .y = bottom }, .{ .x = u_end, .y = v_end }, color),
                graphics.vertex(.{ .x = x, .y = bottom }, .{ .x = u, .y = v_end }, color),
            };
            const base: u16 = @intCast(count * 4);
            indices[count * 6 ..][0..6].* = .{
                base,
                base + 1,
                base + 2,
                base,
                base + 2,
                base + 3,
            };
            count += 1;
            if (count == 256) {
                graphics.mesh(self.texture, &vertices, &indices);
                count = 0;
            }
        }
        pen.x += glyph.advance * factor + spacing;
    }
    if (count > 0) graphics.mesh(self.texture, vertices[0 .. count * 4], indices[0 .. count * 6]);
}
