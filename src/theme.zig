//! UI palette: single source of truth for every color the interface draws.
//! Colors are clay colors; convert at the raylib boundary with `toRaylibColor`.

const clay = @import("zclay");
const rl = @import("raylib");

pub const canvas: clay.Color = .{
    9,
    14,
    28,
    255,
};
pub const panel: clay.Color = .{
    17,
    24,
    43,
    255,
};
pub const panel_raised: clay.Color = .{
    22,
    31,
    53,
    255,
};
pub const border: clay.Color = .{
    40,
    52,
    78,
    255,
};
pub const accent: clay.Color = .{
    61,
    214,
    181,
    255,
};
pub const blue: clay.Color = .{
    92,
    151,
    255,
    255,
};
pub const yellow: clay.Color = .{
    255,
    196,
    72,
    255,
};
pub const cpu_hot: clay.Color = .{
    239,
    68,
    68,
    255,
};
pub const fps_green: clay.Color = .{
    74,
    222,
    128,
    255,
};
pub const ink: clay.Color = .{
    235,
    241,
    251,
    255,
};
pub const muted: clay.Color = .{
    139,
    153,
    180,
    255,
};
pub const faint: clay.Color = .{
    86,
    101,
    130,
    255,
};
pub const danger: clay.Color = .{
    255,
    112,
    129,
    255,
};

/// Converts a Clay color to raylib's byte-channel representation.
pub fn toRaylibColor(color: clay.Color) rl.Color {
    return .init(
        @intFromFloat(color[0]),
        @intFromFloat(color[1]),
        @intFromFloat(color[2]),
        @intFromFloat(color[3]),
    );
}
