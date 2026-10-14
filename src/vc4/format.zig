const std = @import("std");
const texture = @import("texture.zig");

pub const render_config_format_bgr565_dithered: u2 = 0;
pub const render_config_format_rgba8888: u2 = 1;
pub const render_config_format_bgr565: u2 = 2;

pub const loadstore_format_rgba8888: u2 = 0;
pub const loadstore_format_bgr565_dither: u2 = 1;
pub const loadstore_format_bgr565: u2 = 2;

pub const Format = enum {
    /// 32 bits: blue, green, red, then 8 unused, from the low byte (DRM_FORMAT_XRGB8888).
    xrgb8888,
    /// The same with alpha in the top byte (DRM_FORMAT_ARGB8888).
    argb8888,
    /// 16 bits: red in the low 5, green in the middle 6, blue in the top 5 (DRM_FORMAT_BGR565).
    rgb565,
    /// 8 bits of alpha (or coverage); textures only.
    a8,

    pub fn bytesPerPixel(f: Format) u32 {
        return switch (f) {
            .xrgb8888, .argb8888 => 4,
            .rgb565 => 2,
            .a8 => 1,
        };
    }

    pub fn fourcc(f: Format) u32 {
        return switch (f) {
            .xrgb8888 => code("XR24"),
            .argb8888 => code("AR24"),
            .rgb565 => code("BG16"),
            .a8 => code("R8  "),
        };
    }

    pub fn fromFourcc(c: u32) ?Format {
        inline for (@typeInfo(Format).@"enum".fields) |field| {
            const f: Format = @enumFromInt(field.value);
            if (f.fourcc() == c) return f;
        }
        return null;
    }

    pub fn textureType(f: Format) texture.Type {
        return switch (f) {
            .xrgb8888, .argb8888 => .rgba8888,
            .rgb565 => .rgb565,
            .a8 => .alpha,
        };
    }

    pub fn renderConfigFormat(f: Format) u2 {
        return switch (f) {
            .xrgb8888, .argb8888 => render_config_format_rgba8888,
            .rgb565 => render_config_format_bgr565,
            .a8 => unreachable,
        };
    }

    pub fn loadStoreFormat(f: Format) u2 {
        return switch (f) {
            .xrgb8888, .argb8888 => loadstore_format_rgba8888,
            .rgb565 => loadstore_format_bgr565,
            .a8 => unreachable,
        };
    }

    pub fn renderable(f: Format) bool {
        return f != .a8;
    }

    pub fn utileWidth(f: Format) u32 {
        return if (f.bytesPerPixel() == 4) 4 else 8;
    }

    pub fn utileHeight(f: Format) u32 {
        return if (f.bytesPerPixel() == 1) 8 else 4;
    }
};

fn code(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

pub fn toRgb565(argb: u32) u16 {
    const r: u32 = (argb >> 16) & 0xff;
    const g: u32 = (argb >> 8) & 0xff;
    const b: u32 = argb & 0xff;
    return @intCast(((b * 31 + 127) / 255) << 11 | ((g * 63 + 127) / 255) << 5 | (r * 31 + 127) / 255);
}

pub fn fromRgb565(p: u16) u32 {
    const b: u32 = p >> 11;
    const g: u32 = (p >> 5) & 0x3f;
    const r: u32 = p & 0x1f;
    return 0xff000000 | (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2);
}

test "formats' codes and RGB565 conversions" {
    try std.testing.expectEqual(@as(?Format, .rgb565), Format.fromFourcc(code("BG16")));
    try std.testing.expectEqual(@as(?Format, .xrgb8888), Format.fromFourcc(code("XR24")));
    try std.testing.expectEqual(@as(u16, 0x001f), toRgb565(0xffff0000));
    try std.testing.expectEqual(@as(u16, 0x07e0), toRgb565(0xff00ff00));
    try std.testing.expectEqual(@as(u16, 0xf800), toRgb565(0xff0000ff));
    try std.testing.expectEqual(@as(u32, 0xffffffff), fromRgb565(0xffff));
}
