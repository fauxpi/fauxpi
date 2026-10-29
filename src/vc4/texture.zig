const std = @import("std");
const vc_bus = @import("../soc/vc_bus.zig");
const format_mod = @import("format.zig");
const Format = format_mod.Format;

pub const Type = enum(u5) {
    rgba8888 = 0,
    rgbx8888 = 1,
    rgba4444 = 2,
    rgba5551 = 3,
    rgb565 = 4,
    luminance = 5,
    alpha = 6,
    lumalpha = 7,
    etc1 = 8,
    s16f = 9,
    s8 = 10,
    s16 = 11,
    bw1 = 12,
    a4 = 13,
    a1 = 14,
    rgba64 = 15,
    rgba32r = 16,
    yuv422r = 17,
    _,
};

pub const Filter = enum { linear, nearest };
pub const MipFilter = enum { none, nearest, linear };
pub const Wrap = enum(u2) { repeat = 0, clamp = 1, mirror = 2, border = 3 };

pub const Config = struct {
    offset: u32 = 0,
    type: Type = .rgba8888,
    width: u32,
    height: u32,
    mag_filter: Filter = .linear,
    min_filter: Filter = .linear,
    wrap_s: Wrap = .repeat,
    wrap_t: Wrap = .repeat,
    mip_levels: u4 = 0,
    mip_filter: MipFilter = .none,
};

pub fn p0(c: Config) u32 {
    std.debug.assert(c.offset & 0xfff == 0);
    return c.offset | (@as(u32, @intFromEnum(c.type)) & 0xf) << 4 | c.mip_levels;
}

pub fn p1(c: Config) u32 {
    const mipmapped = c.mip_levels > 0 and c.mip_filter != .none;
    const min: u32 = if (!mipmapped) switch (c.min_filter) {
        .linear => 0,
        .nearest => 1,
    } else switch (c.min_filter) {
        .nearest => if (c.mip_filter == .nearest) 2 else 3,
        .linear => if (c.mip_filter == .nearest) 4 else 5,
    };
    const mag: u32 = switch (c.mag_filter) {
        .linear => 0,
        .nearest => 1,
    };
    return (@as(u32, @intFromEnum(c.type)) >> 4) << 31 |
        (c.height & 2047) << 20 |
        (c.width & 2047) << 8 |
        mag << 7 |
        min << 4 |
        @as(u32, @intFromEnum(c.wrap_t)) << 2 |
        @as(u32, @intFromEnum(c.wrap_s));
}

pub fn decodeConfig(param0: u32, param1: u32) Config {
    const w = (param1 >> 8) & 2047;
    const h = (param1 >> 20) & 2047;
    return .{
        .offset = param0 & 0xfffff000,
        .type = @enumFromInt(((param0 >> 4) & 0xf) | ((param1 >> 31) << 4)),
        .width = if (w == 0) 2048 else w,
        .height = if (h == 0) 2048 else h,
        .mag_filter = if ((param1 >> 7) & 1 != 0) .nearest else .linear,
        .min_filter = switch ((param1 >> 4) & 7) {
            1, 2, 3 => .nearest,
            else => .linear,
        },
        .wrap_t = @enumFromInt(@as(u2, @truncate(param1 >> 2))),
        .wrap_s = @enumFromInt(@as(u2, @truncate(param1))),
        .mip_levels = @truncate(param0),
        .mip_filter = switch ((param1 >> 4) & 7) {
            2, 4 => .nearest,
            3, 5 => .linear,
            else => .none,
        },
    };
}

pub fn isLt(width: u32, height: u32) bool {
    return isLtOf(.xrgb8888, width, height);
}

pub fn isLtOf(format: Format, width: u32, height: u32) bool {
    return width <= 4 * format.utileWidth() or height <= 4 * format.utileHeight();
}

pub fn imageSize(width: u32, height: u32) u32 {
    return imageSizeOf(.xrgb8888, width, height);
}

pub fn imageSizeOf(format: Format, width: u32, height: u32) u32 {
    const uw = format.utileWidth();
    const uh = format.utileHeight();
    const cpp = format.bytesPerPixel();
    if (isLtOf(format, width, height)) {
        return std.mem.alignForward(u32, width, uw) * std.mem.alignForward(u32, height, uh) * cpp;
    }
    return std.mem.alignForward(u32, width, 8 * uw) * std.mem.alignForward(u32, height, 8 * uh) * cpp;
}

pub fn tiledPitch(format: Format, width: u32, height: u32) u32 {
    const uw = format.utileWidth();
    const align_w = if (isLtOf(format, width, height)) uw else 8 * uw;
    return std.mem.alignForward(u32, width, align_w) * format.bytesPerPixel();
}

pub inline fn tSubtileOffset(utile_x: u32, utile_y: u32, utile_stride: u32) u32 {
    const tile_stride = utile_stride >> 3;
    var tile_x = utile_x >> 3;
    const tile_y = utile_y >> 3;
    const odd_row = (tile_y & 1) != 0;
    if (odd_row) tile_x = tile_stride - tile_x - 1;
    const tile_offset = (tile_y * tile_stride + tile_x) << 12;

    const stile_index = ((utile_y >> 2) & 1) << 1 | ((utile_x >> 2) & 1);
    const odd_map = [4]u32{ 2, 1, 3, 0 };
    const even_map = [4]u32{ 0, 3, 1, 2 };
    return tile_offset + ((if (odd_row) odd_map else even_map)[stile_index] << 10);
}

/// Returns the byte offset of the 4-utile horizontal group starting at `(ux_aligned4, uy)`
/// for a format with `uh == 4` (`argb8888`, `xrgb8888`, `rgb565`).
/// Within this 4-utile group (`k = ux & 3` in `0..4`), each 64-byte utile is at `return_value + k * 64`.
pub inline fn utileGroupOffset(
    is_lt: bool,
    lt_row_stride: u32,
    utile_stride: u32,
    ux_aligned4: u32,
    uy: u32,
) u32 {
    if (is_lt) {
        return (uy << 2) * lt_row_stride + (ux_aligned4 << 6);
    }
    return tSubtileOffset(ux_aligned4, uy & ~@as(u32, 3), utile_stride) + ((uy & 3) << 8);
}

pub fn texelOffset(width: u32, height: u32, x: u32, y: u32) u32 {
    return texelOffsetOf(.xrgb8888, width, height, x, y);
}

pub inline fn texelOffsetOf(format: Format, width: u32, height: u32, x: u32, y: u32) u32 {
    const cpp = format.bytesPerPixel();
    const uw_shift: u5 = if (cpp == 4) 2 else 3;
    const uh_shift: u5 = if (cpp == 1) 3 else 2;
    const uw: u32 = @as(u32, 1) << uw_shift;
    const uh: u32 = @as(u32, 1) << uh_shift;
    const cpp_shift: u5 = switch (cpp) {
        4 => 2,
        2 => 1,
        else => 0,
    };
    const in_utile = (((y & (uh - 1)) << uw_shift) | (x & (uw - 1))) << cpp_shift;
    if (width <= (uw << 2) or height <= (uh << 2)) {
        const row_stride = ((width + uw - 1) & ~(uw - 1)) << cpp_shift;
        return (y & ~(uh - 1)) * row_stride + ((x >> uw_shift) << 6) + in_utile;
    }
    const tile_w = uw << 3;
    const utile_stride = ((width + tile_w - 1) & ~(tile_w - 1)) >> uw_shift;
    const utile_x = x >> uw_shift;
    const utile_y = y >> uh_shift;
    const in_subtile = (((utile_y & 3) << 2) | (utile_x & 3)) << 6;
    return tSubtileOffset(utile_x & ~@as(u32, 3), utile_y & ~@as(u32, 3), utile_stride) + in_subtile + in_utile;
}

pub fn upload(dst: []u8, pixels: []const u32, width: u32, height: u32) void {
    uploadRect(dst, width, height, .{ .x = 0, .y = 0, .width = width, .height = height }, pixels, width);
}

pub const Rect = struct { x: u32, y: u32, width: u32, height: u32 };

pub fn uploadRect(dst: []u8, width: u32, height: u32, rect: Rect, pixels: []align(1) const u32, stride: u32) void {
    uploadRectOf(.xrgb8888, dst, width, height, rect, std.mem.sliceAsBytes(pixels), stride * 4);
}

pub fn uploadRectOf(format: Format, dst: []u8, width: u32, height: u32, rect: Rect, src: []const u8, stride: u32) void {
    std.debug.assert(dst.len >= imageSizeOf(format, width, height));
    std.debug.assert(rect.x + rect.width <= width and rect.y + rect.height <= height);
    if (rect.width == 0 or rect.height == 0) return;
    const uw = format.utileWidth();
    const uh = format.utileHeight();
    const cpp = format.bytesPerPixel();
    const x_end = rect.x + rect.width;
    const y_end = rect.y + rect.height;

    if (uh == 4) {
        const uw_mask = uw - 1;
        const cpp_shift: u5 = if (cpp == 4) 2 else 1;
        const uw_shift: u5 = if (cpp == 4) 2 else 3;
        const is_lt = isLtOf(format, width, height);
        const lt_row_stride = ((width + uw_mask) & ~uw_mask) << cpp_shift;
        const tile_w = uw << 3;
        const utile_stride = ((width + tile_w - 1) & ~(tile_w - 1)) >> uw_shift;

        var uy = rect.y >> 2;
        while ((uy << 2) < y_end) : (uy += 1) {
            var ux = rect.x >> uw_shift;
            var group_base: u32 = 0;
            var group_valid = false;
            while ((ux << uw_shift) < x_end) : (ux += 1) {
                if (!group_valid or (ux & 3) == 0) {
                    group_base = utileGroupOffset(is_lt, lt_row_stride, utile_stride, ux & ~@as(u32, 3), uy);
                    group_valid = true;
                }
                const base = group_base + ((ux & 3) << 6);
                const x0 = @max(ux << uw_shift, rect.x);
                const x1 = @min((ux << uw_shift) + uw, x_end);
                const y0 = @max(uy << 2, rect.y);
                const y1 = @min((uy << 2) + 4, y_end);
                const n = (x1 - x0) << cpp_shift;
                for (y0..y1) |y| {
                    const d = base + (((@as(u32, @intCast(y)) & 3) << uw_shift) + (x0 & uw_mask)) * cpp;
                    const sidx = (@as(u32, @intCast(y)) - rect.y) * stride + ((x0 - rect.x) << cpp_shift);
                    @memcpy(dst[d..][0..n], src[sidx..][0..n]);
                }
            }
        }
        return;
    }

    var uy = rect.y / uh;
    while (uy * uh < y_end) : (uy += 1) {
        var ux = rect.x / uw;
        while (ux * uw < x_end) : (ux += 1) {
            const base = texelOffsetOf(format, width, height, ux * uw, uy * uh);
            const x0 = @max(ux * uw, rect.x);
            const x1 = @min(ux * uw + uw, x_end);
            const y0 = @max(uy * uh, rect.y);
            const y1 = @min(uy * uh + uh, y_end);
            const n = (x1 - x0) * cpp;
            for (y0..y1) |y| {
                const d = base + ((@as(u32, @intCast(y)) % uh) * uw + x0 % uw) * cpp;
                const sidx = (@as(u32, @intCast(y)) - rect.y) * stride + (x0 - rect.x) * cpp;
                @memcpy(dst[d..][0..n], src[sidx..][0..n]);
            }
        }
    }
}

/// Detiles a VC4 T-tiled or LT-tiled texture from `ram` at `cfg.offset` into linear `0xAABBGGRR` (GL_RGBA)
/// or `0xAARRGGBB` (VC4 BGRA in memory) u32 words.
pub fn detileTextureToBgra(ram: []const u8, cfg: Config, out_bgra: []u32) void {
    const w = cfg.width;
    const h = cfg.height;
    const total_px = @as(usize, w) * @as(usize, h);
    if (w == 0 or h == 0 or out_bgra.len < total_px) return;

    const base = cfg.offset & vc_bus.ramMask(ram.len);

    // Fast path 1: Linear 32-bit RGBA32R
    if (cfg.type == .rgba32r) {
        const total_bytes = total_px * 4;
        if (@as(usize, base) + total_bytes <= ram.len) {
            @memcpy(std.mem.sliceAsBytes(out_bgra[0..total_px]), ram[base..][0..total_bytes]);
        } else {
            for (0..total_px) |i| {
                const off = @as(usize, base) + i * 4;
                out_bgra[i] = if (off + 4 <= ram.len)
                    std.mem.readInt(u32, ram[off..][0..4], .little)
                else
                    0xff000000;
            }
        }
        return;
    }

    const fmt: Format = switch (cfg.type) {
        .rgba8888, .rgbx8888 => .argb8888,
        .rgb565 => .rgb565,
        .alpha, .luminance => .a8,
        else => .argb8888,
    };
    const cpp = fmt.bytesPerPixel();

    // Fast path 2: T-tiled / LT-tiled 32-bit (4x4 utiles, hoisted utileGroupOffset + 4-wide SIMD)
    if (cpp == 4) {
        const is_lt = (w <= 16 or h <= 16);
        const lt_row_stride = ((w + 3) & ~@as(u32, 3)) << 2;
        const utile_stride = ((w + 31) & ~@as(u32, 31)) >> 2;
        const utiles_x = w >> 2;
        const utiles_y = h >> 2;
        const rem_x = w & 3;
        const rem_y = h & 3;
        const total_uy = utiles_y + @intFromBool(rem_y != 0);
        const alpha_or: u32 = if (cfg.type == .rgbx8888) 0xff000000 else 0;
        const alpha_or_v: @Vector(4, u32) = @splat(alpha_or);

        var uy: u32 = 0;
        while (uy < total_uy) : (uy += 1) {
            const y0 = uy << 2;
            const rows: u32 = if (uy < utiles_y) 4 else rem_y;
            var ux: u32 = 0;
            var group_base: u32 = 0;
            while (ux < utiles_x) : (ux += 1) {
                if ((ux & 3) == 0) {
                    group_base = base + utileGroupOffset(is_lt, lt_row_stride, utile_stride, ux, uy);
                }
                const utile_off = group_base + ((ux & 3) << 6);
                const x0 = ux << 2;
                if (@as(usize, utile_off) + 64 <= ram.len) {
                    if (rows == 4) {
                        inline for (0..4) |ry| {
                            const src_v: @Vector(4, u32) = @bitCast(ram[utile_off + ry * 16 ..][0..16].*);
                            out_bgra[(y0 + @as(u32, @intCast(ry))) * w + x0 ..][0..4].* = @bitCast(src_v | alpha_or_v);
                        }
                    } else {
                        for (0..rows) |ry| {
                            const src_v: @Vector(4, u32) = @bitCast(ram[utile_off + @as(u32, @intCast(ry)) * 16 ..][0..16].*);
                            out_bgra[(y0 + @as(u32, @intCast(ry))) * w + x0 ..][0..4].* = @bitCast(src_v | alpha_or_v);
                        }
                    }
                } else {
                    for (0..rows) |ry| {
                        const dst_row = out_bgra[(y0 + @as(u32, @intCast(ry))) * w + x0 ..][0..4];
                        for (0..4) |rx| {
                            const off = @as(usize, utile_off) + ry * 16 + rx * 4;
                            dst_row[rx] = if (off + 4 <= ram.len)
                                (std.mem.readInt(u32, ram[off..][0..4], .little) | alpha_or)
                            else
                                0xff000000;
                        }
                    }
                }
            }
            if (rem_x != 0) {
                if ((utiles_x & 3) == 0) {
                    group_base = base + utileGroupOffset(is_lt, lt_row_stride, utile_stride, utiles_x, uy);
                }
                const utile_off = group_base + ((utiles_x & 3) << 6);
                const x0 = utiles_x << 2;
                for (0..rows) |ry| {
                    const dst_row = out_bgra[(y0 + @as(u32, @intCast(ry))) * w + x0 ..][0..rem_x];
                    for (0..rem_x) |rx| {
                        const off = @as(usize, utile_off) + ry * 16 + rx * 4;
                        dst_row[rx] = if (off + 4 <= ram.len)
                            (std.mem.readInt(u32, ram[off..][0..4], .little) | alpha_or)
                        else
                            0xff000000;
                    }
                }
            }
        }
        return;
    }

    // Fast path 3: T-tiled / LT-tiled 16-bit RGB565 (8x4 utiles, hoisted utileGroupOffset + 8-wide SIMD)
    if (cpp == 2) {
        const is_lt = (w <= 32 or h <= 16);
        const lt_row_stride = ((w + 7) & ~@as(u32, 7)) << 1;
        const utile_stride = ((w + 63) & ~@as(u32, 63)) >> 3;
        const utiles_x = w >> 3;
        const utiles_y = h >> 2;
        const rem_x = w & 7;
        const rem_y = h & 3;
        const total_uy = utiles_y + @intFromBool(rem_y != 0);

        var uy: u32 = 0;
        while (uy < total_uy) : (uy += 1) {
            const y0 = uy << 2;
            const rows: u32 = if (uy < utiles_y) 4 else rem_y;
            var ux: u32 = 0;
            var group_base: u32 = 0;
            while (ux < utiles_x) : (ux += 1) {
                if ((ux & 3) == 0) {
                    group_base = base + utileGroupOffset(is_lt, lt_row_stride, utile_stride, ux, uy);
                }
                const utile_off = group_base + ((ux & 3) << 6);
                const x0 = ux << 3;
                if (@as(usize, utile_off) + 64 <= ram.len) {
                    if (rows == 4) {
                        inline for (0..4) |ry| {
                            const p16_vec: @Vector(8, u16) = @bitCast(ram[utile_off + ry * 16 ..][0..16].*);
                            out_bgra[(y0 + @as(u32, @intCast(ry))) * w + x0 ..][0..8].* = @bitCast(format_mod.fromRgb565Vec8(p16_vec));
                        }
                    } else {
                        for (0..rows) |ry| {
                            const p16_vec: @Vector(8, u16) = @bitCast(ram[utile_off + @as(u32, @intCast(ry)) * 16 ..][0..16].*);
                            out_bgra[(y0 + @as(u32, @intCast(ry))) * w + x0 ..][0..8].* = @bitCast(format_mod.fromRgb565Vec8(p16_vec));
                        }
                    }
                } else {
                    for (0..rows) |ry| {
                        const dst_row = out_bgra[(y0 + @as(u32, @intCast(ry))) * w + x0 ..][0..8];
                        for (0..8) |rx| {
                            const off = @as(usize, utile_off) + ry * 16 + rx * 2;
                            dst_row[rx] = if (off + 2 <= ram.len)
                                format_mod.fromRgb565(std.mem.readInt(u16, ram[off..][0..2], .little))
                            else
                                0xff000000;
                        }
                    }
                }
            }
            if (rem_x != 0) {
                if ((utiles_x & 3) == 0) {
                    group_base = base + utileGroupOffset(is_lt, lt_row_stride, utile_stride, utiles_x, uy);
                }
                const utile_off = group_base + ((utiles_x & 3) << 6);
                const x0 = utiles_x << 3;
                for (0..rows) |ry| {
                    const dst_row = out_bgra[(y0 + @as(u32, @intCast(ry))) * w + x0 ..][0..rem_x];
                    for (0..rem_x) |rx| {
                        const off = @as(usize, utile_off) + ry * 16 + rx * 2;
                        dst_row[rx] = if (off + 2 <= ram.len)
                            format_mod.fromRgb565(std.mem.readInt(u16, ram[off..][0..2], .little))
                        else
                            0xff000000;
                    }
                }
            }
        }
        return;
    }

    // Fast path 4: T-tiled / LT-tiled 8-bit Alpha / Luminance (8x8 utiles, 8-wide SIMD expansion)
    const utiles_x = w >> 3;
    const utiles_y = h >> 3;
    const rem_x = w & 7;
    const rem_y = h & 7;
    const total_uy = utiles_y + @intFromBool(rem_y != 0);
    const is_lum = (cfg.type == .luminance);
    const opaque_v: @Vector(8, u32) = @splat(0xff000000);

    var uy: u32 = 0;
    while (uy < total_uy) : (uy += 1) {
        const y0 = uy << 3;
        const rows: u32 = if (uy < utiles_y) 8 else rem_y;
        var ux: u32 = 0;
        while (ux < utiles_x) : (ux += 1) {
            const x0 = ux << 3;
            const utile_off = base + texelOffsetOf(.a8, w, h, x0, y0);
            if (@as(usize, utile_off) + 64 <= ram.len) {
                for (0..rows) |ry| {
                    const b_vec: @Vector(8, u8) = ram[utile_off + @as(u32, @intCast(ry)) * 8 ..][0..8].*;
                    const v32: @Vector(8, u32) = b_vec;
                    const out_v: @Vector(8, u32) = if (is_lum)
                        opaque_v | (v32 << @splat(16)) | (v32 << @splat(8)) | v32
                    else
                        v32 << @splat(24);
                    out_bgra[(y0 + @as(u32, @intCast(ry))) * w + x0 ..][0..8].* = @bitCast(out_v);
                }
            } else {
                for (0..rows) |ry| {
                    const dst_row = out_bgra[(y0 + @as(u32, @intCast(ry))) * w + x0 ..][0..8];
                    for (0..8) |rx| {
                        const off = @as(usize, utile_off) + ry * 8 + rx;
                        dst_row[rx] = if (off < ram.len) blk: {
                            const b: u32 = ram[off];
                            break :blk if (is_lum) (0xff000000 | (b << 16) | (b << 8) | b) else (b << 24);
                        } else 0xff000000;
                    }
                }
            }
        }
        if (rem_x != 0) {
            const x0 = utiles_x << 3;
            const utile_off = base + texelOffsetOf(.a8, w, h, x0, y0);
            for (0..rows) |ry| {
                const dst_row = out_bgra[(y0 + @as(u32, @intCast(ry))) * w + x0 ..][0..rem_x];
                for (0..rem_x) |rx| {
                    const off = @as(usize, utile_off) + ry * 8 + rx;
                    dst_row[rx] = if (off < ram.len) blk: {
                        const b: u32 = ram[off];
                        break :blk if (is_lum) (0xff000000 | (b << 16) | (b << 8) | b) else (b << 24);
                    } else 0xff000000;
                }
            }
        }
    }
}

test "config round trip and uploadRect" {
    const c: Config = .{ .offset = 0x3000, .width = 128, .height = 64, .mag_filter = .nearest, .min_filter = .nearest, .wrap_s = .clamp };
    const d = decodeConfig(p0(c), p1(c));
    try std.testing.expectEqual(c.offset, d.offset);
    try std.testing.expectEqual(c.type, d.type);
    try std.testing.expectEqual(c.width, d.width);
    try std.testing.expectEqual(c.height, d.height);
}

test "detileTextureToBgra matches per-texel reference across T-tiled, LT-tiled, and unaligned sizes" {
    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(ram);
    for (ram, 0..) |*b, i| {
        b.* = @truncate((i *% 73) ^ (i >> 5) ^ 0x5a);
    }

    const cases = [_]Config{
        .{ .offset = 0x1000, .type = .rgba8888, .width = 67, .height = 37 },
        .{ .offset = 0x1000, .type = .rgbx8888, .width = 13, .height = 19 },
        .{ .offset = 0x1000, .type = .rgb565, .width = 131, .height = 35 },
        .{ .offset = 0x1000, .type = .rgb565, .width = 21, .height = 11 },
        .{ .offset = 0x1000, .type = .luminance, .width = 75, .height = 43 },
        .{ .offset = 0x1000, .type = .alpha, .width = 19, .height = 13 },
        .{ .offset = 0x1000, .type = .rgba32r, .width = 33, .height = 17 },
    };

    var out_fast: [131 * 43]u32 = undefined;
    for (cases) |cfg| {
        const w = cfg.width;
        const h = cfg.height;
        detileTextureToBgra(ram, cfg, out_fast[0 .. w * h]);

        const fmt: Format = switch (cfg.type) {
            .rgba8888, .rgbx8888, .rgba32r => .argb8888,
            .rgb565 => .rgb565,
            .alpha, .luminance => .a8,
            else => .argb8888,
        };
        const cpp = fmt.bytesPerPixel();
        const base = cfg.offset & vc_bus.ramMask(ram.len);

        for (0..h) |y| {
            for (0..w) |x| {
                const off = base + if (cfg.type == .rgba32r)
                    (@as(u32, @intCast(y)) * w + @as(u32, @intCast(x))) * 4
                else
                    texelOffsetOf(fmt, w, h, @intCast(x), @intCast(y));

                const expected: u32 = switch (cpp) {
                    4 => blk: {
                        const raw = std.mem.readInt(u32, ram[off..][0..4], .little);
                        break :blk if (cfg.type == .rgbx8888) (raw | 0xff000000) else raw;
                    },
                    2 => format_mod.fromRgb565(std.mem.readInt(u16, ram[off..][0..2], .little)),
                    1 => if (cfg.type == .luminance) blk: {
                        const l: u32 = ram[off];
                        break :blk 0xff000000 | (l << 16) | (l << 8) | l;
                    } else (@as(u32, ram[off]) << 24),
                    else => 0xff000000,
                };
                try std.testing.expectEqual(expected, out_fast[y * w + x]);
            }
        }
    }
}

