//! Drawing text: a glyph cache of rasterized coverage masks, horizontal
//! layout with kerning, and blending into 32-bit pixels.
//!
//! Glyphs are positioned to a quarter of a pixel horizontally (each glyph
//! is cached at four subpixel offsets as needed), so spacing stays even at
//! small sizes without hinting. Baselines snap to whole pixels.

const std = @import("std");
const opentype = @import("opentype.zig");
const Rasterizer = @import("raster.zig").Rasterizer;

pub const Font = opentype.Font;

/// 0xAARRGGBB pixels, as the display and the GPU render target use.
pub const Canvas = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    /// Distance between rows, in pixels.
    stride: u32,

    /// Blends `color` into the canvas through a coverage mask whose top left
    /// is at (x, y).
    pub fn blendMask(c: Canvas, x: i32, y: i32, mask: []const u8, mask_w: u32, mask_h: u32, color: u32) void {
        const color_alpha: u32 = color >> 24;
        if (color_alpha == 0) return;
        // Clip the mask to the canvas once, not per pixel.
        const mx0: u32 = @intCast(std.math.clamp(-x, 0, @as(i32, @intCast(mask_w))));
        const mx1: u32 = @intCast(std.math.clamp(@as(i32, @intCast(c.width)) - x, 0, @as(i32, @intCast(mask_w))));
        const my0: u32 = @intCast(std.math.clamp(-y, 0, @as(i32, @intCast(mask_h))));
        const my1: u32 = @intCast(std.math.clamp(@as(i32, @intCast(c.height)) - y, 0, @as(i32, @intCast(mask_h))));
        if (mx0 >= mx1 or my0 >= my1) return;

        const span_w: usize = mx1 - mx0;
        const color_opaque: u32 = color | 0xff000000;
        const v_src_rb: @Vector(4, u32) = @splat(color & 0x00ff00ff);
        const v_src_g: @Vector(4, u32) = @splat(color & 0x0000ff00);

        for (my0..my1) |my| {
            const cy: usize = @intCast(y + @as(i32, @intCast(my)));
            const row = c.pixels[cy * c.stride + @as(usize, @intCast(x + @as(i32, @intCast(mx0)))) ..][0..span_w];
            const covs = mask[my * mask_w + mx0 ..][0..span_w];
            var i: usize = 0;
            while (i + 4 <= span_w) : (i += 4) {
                blendCov4(row[i..][0..4], covs[i..][0..4].*, color_opaque, color_alpha, v_src_rb, v_src_g);
            }
            if (color_alpha == 255) {
                while (i < span_w) : (i += 1) {
                    const cov = covs[i];
                    if (cov != 0) row[i] = blend(row[i], color, cov);
                }
            } else {
                while (i < span_w) : (i += 1) {
                    const cov = covs[i];
                    if (cov != 0) row[i] = blend(row[i], color, div255(@as(u32, cov) * color_alpha));
                }
            }
        }
    }

    /// Blends `color` into the canvas through a coverage mask rotated 90 degrees
    /// counter-clockwise around the glyph pen at `(base_x, pen_y)`, where `mask_left`
    /// and `mask_top` are the unrotated bitmap's `left` and `top` offsets.
    pub fn blendMaskRotated90Ccw(
        c: Canvas,
        base_x: i32,
        pen_y: i32,
        mask_left: i32,
        mask_top: i32,
        mask: []const u8,
        mask_w: u32,
        mask_h: u32,
        color: u32,
    ) void {
        const color_alpha: u32 = color >> 24;
        if (color_alpha == 0) return;
        const x0: i32 = base_x + mask_top;
        const y_bottom: i32 = pen_y - mask_left;

        const my0: u32 = @intCast(std.math.clamp(-x0, 0, @as(i32, @intCast(mask_h))));
        const my1: u32 = @intCast(std.math.clamp(@as(i32, @intCast(c.width)) - x0, 0, @as(i32, @intCast(mask_h))));
        const mx0: u32 = @intCast(std.math.clamp(y_bottom - @as(i32, @intCast(c.height)) + 1, 0, @as(i32, @intCast(mask_w))));
        const mx1: u32 = @intCast(std.math.clamp(y_bottom + 1, 0, @as(i32, @intCast(mask_w))));
        if (mx0 >= mx1 or my0 >= my1) return;

        const color_opaque: u32 = color | 0xff000000;
        const v_src_rb: @Vector(4, u32) = @splat(color & 0x00ff00ff);
        const v_src_g: @Vector(4, u32) = @splat(color & 0x0000ff00);

        var my: usize = my0;
        while (my + 4 <= my1) : (my += 4) {
            const cx: usize = @intCast(x0 + @as(i32, @intCast(my)));
            const row0 = mask[(my + 0) * mask_w ..];
            const row1 = mask[(my + 1) * mask_w ..];
            const row2 = mask[(my + 2) * mask_w ..];
            const row3 = mask[(my + 3) * mask_w ..];
            for (mx0..mx1) |mx| {
                const cov4 = [4]u8{ row0[mx], row1[mx], row2[mx], row3[mx] };
                if (@as(u32, @bitCast(cov4)) != 0) {
                    const cy: usize = @intCast(y_bottom - @as(i32, @intCast(mx)));
                    blendCov4(c.pixels[cy * c.stride + cx ..][0..4], cov4, color_opaque, color_alpha, v_src_rb, v_src_g);
                }
            }
        }
        while (my < my1) : (my += 1) {
            const cx: usize = @intCast(x0 + @as(i32, @intCast(my)));
            const mask_row = mask[my * mask_w ..];
            if (color_alpha == 255) {
                for (mx0..mx1) |mx| {
                    const cov = mask_row[mx];
                    if (cov != 0) {
                        const cy: usize = @intCast(y_bottom - @as(i32, @intCast(mx)));
                        const dst = &c.pixels[cy * c.stride + cx];
                        dst.* = blend(dst.*, color, cov);
                    }
                }
            } else {
                for (mx0..mx1) |mx| {
                    const cov = mask_row[mx];
                    if (cov != 0) {
                        const cy: usize = @intCast(y_bottom - @as(i32, @intCast(mx)));
                        const dst = &c.pixels[cy * c.stride + cx];
                        dst.* = blend(dst.*, color, div255(@as(u32, cov) * color_alpha));
                    }
                }
            }
        }
    }
};

pub inline fn blendCov4(
    dst_ptr: *[4]u32,
    cov4: [4]u8,
    color_opaque: u32,
    color_alpha: u32,
    v_src_rb: @Vector(4, u32),
    v_src_g: @Vector(4, u32),
) void {
    const cov_bits: u32 = @bitCast(cov4);
    if (cov_bits == 0) return;
    if (color_alpha == 255 and cov_bits == 0xffffffff) {
        dst_ptr.* = @splat(color_opaque);
        return;
    }
    const v_cov8: @Vector(4, u8) = cov4;
    var v_a: @Vector(4, u32) = v_cov8;
    if (color_alpha != 255) {
        const prod = v_a * @as(@Vector(4, u32), @splat(color_alpha)) + @as(@Vector(4, u32), @splat(128));
        v_a = (prod + (prod >> @splat(8))) >> @splat(8);
    }
    const v_ia = @as(@Vector(4, u32), @splat(255)) - v_a;
    const v_dst: @Vector(4, u32) = dst_ptr.*;
    const v_mask_rb: @Vector(4, u32) = @splat(0x00ff00ff);
    const v_mask_g: @Vector(4, u32) = @splat(0x0000ff00);
    const v_bias_rb: @Vector(4, u32) = @splat(0x00800080);
    const v_bias_g: @Vector(4, u32) = @splat(0x00008000);
    const v_alpha: @Vector(4, u32) = @splat(0xff000000);
    const v_shift8: @Vector(4, u5) = @splat(8);

    const v_rb = v_src_rb * v_a + (v_dst & v_mask_rb) * v_ia + v_bias_rb;
    const v_g = v_src_g * v_a + (v_dst & v_mask_g) * v_ia + v_bias_g;
    const v_rb_out = ((v_rb + ((v_rb >> v_shift8) & v_mask_rb)) >> v_shift8) & v_mask_rb;
    const v_g_out = ((v_g + ((v_g >> v_shift8) & v_mask_g)) >> v_shift8) & v_mask_g;
    const v_blended = v_alpha | v_rb_out | v_g_out;
    dst_ptr.* = @select(u32, v_a == @as(@Vector(4, u32), @splat(0)), v_dst, v_blended);
}

/// `src` over `dst` with alpha `a` (0-255), per colour channel. The result
/// is opaque.
pub inline fn blend(dst: u32, src: u32, a: u32) u32 {
    if (a >= 255) return src | 0xff000000;
    const ia = 255 - a;
    // Red and blue together (16 bits each, so they cannot overflow into
    // each other), then green; each channel is divided by 255 with
    // rounding, as div255 does.
    const rb = (src & 0xff00ff) * a + (dst & 0xff00ff) * ia + 0x800080;
    const g = (src & 0x00ff00) * a + (dst & 0x00ff00) * ia + 0x008000;
    const rb_out = ((rb + ((rb >> 8) & 0xff00ff)) >> 8) & 0xff00ff;
    const g_out = ((g + ((g >> 8) & 0x00ff00)) >> 8) & 0x00ff00;
    return 0xff000000 | rb_out | g_out;
}

/// Blends `src` with uniform alpha `a` (0-255) across a horizontal span of pixels using 4-wide SIMD.
pub fn blendSpan(dst_slice: []u32, src: u32, a: u32) void {
    if (a == 0 or dst_slice.len == 0) return;
    if (a >= 255) {
        @memset(dst_slice, src | 0xff000000);
        return;
    }
    const ia: u32 = 255 - a;
    const src_rb: u32 = (src & 0xff00ff) * a + 0x800080;
    const src_g: u32 = (src & 0x00ff00) * a + 0x008000;

    const v_src_rb: @Vector(4, u32) = @splat(src_rb);
    const v_src_g: @Vector(4, u32) = @splat(src_g);
    const v_ia: @Vector(4, u32) = @splat(ia);
    const v_mask_rb: @Vector(4, u32) = @splat(0x00ff00ff);
    const v_mask_g: @Vector(4, u32) = @splat(0x0000ff00);
    const v_alpha: @Vector(4, u32) = @splat(0xff000000);
    const v_shift8: @Vector(4, u5) = @splat(8);

    var i: usize = 0;
    while (i + 4 <= dst_slice.len) : (i += 4) {
        const v_dst: @Vector(4, u32) = dst_slice[i..][0..4].*;
        const v_rb = v_src_rb + (v_dst & v_mask_rb) * v_ia;
        const v_g = v_src_g + (v_dst & v_mask_g) * v_ia;
        const v_rb_out = ((v_rb + ((v_rb >> v_shift8) & v_mask_rb)) >> v_shift8) & v_mask_rb;
        const v_g_out = ((v_g + ((v_g >> v_shift8) & v_mask_g)) >> v_shift8) & v_mask_g;
        dst_slice[i..][0..4].* = v_alpha | v_rb_out | v_g_out;
    }
    while (i < dst_slice.len) : (i += 1) {
        dst_slice[i] = blend(dst_slice[i], src, a);
    }
}

/// Rounds x / 255 to the nearest integer, for 0 <= x <= 255 * 255.
inline fn div255(x: u32) u32 {
    const y = x + 128;
    return (y + (y >> 8)) >> 8;
}

const Key = struct {
    font: usize,
    glyph: u16,
    /// Pixels per em, in 1/64ths.
    size: u32,
    /// Horizontal offset in quarter pixels (0-3).
    subpixel: u2,
};

/// A rasterized glyph.
pub const Bitmap = struct {
    /// Offset of the mask's top left from the pen position on the baseline.
    left: i32,
    top: i32,
    width: u32,
    height: u32,
    mask: []u8,
};

pub const GlyphCache = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(Key, Bitmap) = .empty,
    runs: RunCache,

    pub fn init(gpa: std.mem.Allocator) GlyphCache {
        return .{ .gpa = gpa, .runs = RunCache.init(gpa) };
    }

    pub fn deinit(cache: *GlyphCache) void {
        var it = cache.map.valueIterator();
        while (it.next()) |b| cache.gpa.free(b.mask);
        cache.map.deinit(cache.gpa);
        cache.runs.deinit();
    }

    /// The glyph rasterized at `size` pixels per em, shifted right by
    /// `subpixel` quarter pixels.
    pub fn get(cache: *GlyphCache, font: *const Font, glyph: u16, size: f32, subpixel: u2) !Bitmap {
        const key: Key = .{ .font = @intFromPtr(font), .glyph = glyph, .size = @intFromFloat(size * 64), .subpixel = subpixel };
        if (cache.map.get(key)) |b| return b;
        const b = try rasterizeGlyph(cache.gpa, font, glyph, size, @as(f32, @floatFromInt(subpixel)) / 4);
        errdefer cache.gpa.free(b.mask);
        try cache.map.put(cache.gpa, key, b);
        return b;
    }
};

/// Rasterizes one glyph, shifted right by `dx` pixels (0 <= dx < 1).
pub fn rasterizeGlyph(gpa: std.mem.Allocator, font: *const Font, glyph: u16, size: f32, dx: f32) !Bitmap {
    const box = font.boundingBox(glyph) orelse return .{ .left = 0, .top = 0, .width = 0, .height = 0, .mask = &.{} };
    const scale = size / @as(f32, @floatFromInt(font.units_per_em));
    const x0 = @floor(@as(f32, @floatFromInt(box.x_min)) * scale + dx);
    const x1 = @ceil(@as(f32, @floatFromInt(box.x_max)) * scale + dx);
    const y0 = @floor(-@as(f32, @floatFromInt(box.y_max)) * scale);
    const y1 = @ceil(-@as(f32, @floatFromInt(box.y_min)) * scale);
    // One pixel of margin: curves may bulge slightly past rounded bounds.
    const w: u32 = @intFromFloat(x1 - x0 + 2);
    const h: u32 = @intFromFloat(y1 - y0 + 2);
    var r = try Rasterizer.init(gpa, w, h);
    defer r.deinit(gpa);
    const sink = struct {
        r: *Rasterizer,
        started: bool = false,
        pub fn moveTo(s: *@This(), x: f32, y: f32) void {
            if (s.started) s.r.close();
            s.started = true;
            s.r.moveTo(x, y);
        }
        pub fn lineTo(s: *@This(), x: f32, y: f32) void {
            s.r.lineTo(x, y);
        }
        pub fn quadTo(s: *@This(), cx: f32, cy: f32, x: f32, y: f32) void {
            s.r.quadTo(cx, cy, x, y);
        }
    };
    var s: sink = .{ .r = &r };
    // Font units (y up) to mask pixels (y down), with the margin.
    const t: opentype.Transform = .{ .a = scale, .d = -scale, .e = dx - x0 + 1, .f = -y0 + 1 };
    try font.outline(glyph, t, &s);
    if (s.started) r.close();
    const mask = try gpa.alloc(u8, @as(usize, w) * h);
    r.coverage(mask);
    return .{
        .left = @as(i32, @intFromFloat(x0)) - 1,
        .top = @as(i32, @intFromFloat(y0)) - 1,
        .width = w,
        .height = h,
        .mask = mask,
    };
}

/// Text in one font at one size.
pub const Style = struct {
    font: *const Font,
    /// Pixels per em.
    size: f32,
    color: u32 = 0xffffffff,

    pub fn scale(s: Style) f32 {
        return s.size / @as(f32, @floatFromInt(s.font.units_per_em));
    }

    /// Distance from the baseline up to the top of the tallest glyphs.
    pub fn ascent(s: Style) f32 {
        return @as(f32, @floatFromInt(s.font.ascender)) * s.scale();
    }

    /// Distance between baselines.
    pub fn lineHeight(s: Style) f32 {
        const f = s.font;
        return @as(f32, @floatFromInt(@as(i32, f.ascender) - f.descender + f.line_gap)) * s.scale();
    }
};

/// Steps through UTF-8 text glyph by glyph, giving each glyph's pen
/// position (kerning applied). Invalid UTF-8 shows as U+FFFD.
pub const Layout = struct {
    style: Style,
    text: []const u8,
    at: usize = 0,
    x: f32,
    prev: ?u16 = null,

    pub const Item = struct { glyph: u16, x: f32 };

    pub fn init(style: Style, text: []const u8, x: f32) Layout {
        return .{ .style = style, .text = text, .x = x };
    }

    fn decodeAt(text: []const u8, at: usize) ?struct { cp: u21, next_at: usize } {
        if (at >= text.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
        const cp: u21 = if (at + len <= text.len)
            std.unicode.utf8Decode(text[at..][0..len]) catch 0xfffd
        else
            0xfffd;
        return .{ .cp = cp, .next_at = @min(at + len, text.len) };
    }

    pub fn next(l: *Layout) ?Item {
        while (decodeAt(l.text, l.at)) |d| {
            l.at = d.next_at;
            if (d.cp == 0xfe0e or d.cp == 0xfe0f or d.cp == 0x200d) continue;

            const f: *const Font = l.style.font;
            const glyph = f.glyphIndex(d.cp);
            const scale = l.style.size / @as(f32, @floatFromInt(f.units_per_em));
            if (l.prev) |p| {
                l.x += @as(f32, @floatFromInt(f.kerning(p, glyph))) * scale;
            }
            const item: Item = .{ .glyph = glyph, .x = l.x };
            l.x += @as(f32, @floatFromInt(f.advance(glyph))) * scale;
            l.prev = glyph;
            return item;
        }
        return null;
    }
};

/// The width of `text` in pixels.
pub fn measure(style: Style, text: []const u8) f32 {
    var l: Layout = .{ .style = style, .text = text, .x = 0 };
    while (l.next()) |_| {}
    return l.x;
}

inline fn drawGlyph(canvas: Canvas, cache: *GlyphCache, style: Style, base: i32, item: Layout.Item, item_x: f32) !void {
    const quarter: i32 = @intFromFloat(@round(item_x * 4));
    const subpixel: u2 = @intCast(@mod(quarter, 4));
    const pen_x = @divFloor(quarter, 4);
    const b = try cache.get(style.font, item.glyph, style.size, subpixel);
    if (b.width == 0) return;
    canvas.blendMask(pen_x + b.left, base + b.top, b.mask, b.width, b.height, style.color);
}

inline fn drawGlyphRotated90Ccw(canvas: Canvas, cache: *GlyphCache, style: Style, base: i32, y: f32, item: Layout.Item) !void {
    const pen_y_f = y - item.x;
    const quarter: i32 = @intFromFloat(@round(pen_y_f * 4));
    const subpixel: u2 = @intCast(@mod(-quarter, 4));
    const pen_y = -@divFloor(-quarter, 4);
    const b = try cache.get(style.font, item.glyph, style.size, subpixel);
    if (b.width == 0) return;
    canvas.blendMaskRotated90Ccw(base, pen_y, b.left, b.top, b.mask, b.width, b.height, style.color);
}

/// Draws `text` with its baseline at `baseline` (rounded to a pixel),
/// starting at `x`. Returns the pen position after the text.
pub fn draw(canvas: Canvas, cache: *GlyphCache, style: Style, x: f32, baseline: f32, text: []const u8) !f32 {
    const base: i32 = @intFromFloat(@round(baseline));
    if (cache.runs.get(style, text)) |run| {
        for (run.glyphs) |item| {
            try drawGlyph(canvas, cache, style, base, item, x + item.x);
        }
        return x + run.width;
    }
    var l: Layout = .{ .style = style, .text = text, .x = x };
    while (l.next()) |item| {
        try drawGlyph(canvas, cache, style, base, item, item.x);
    }
    return l.x;
}

/// Draws `text` rotated 90 degrees counter-clockwise (reading bottom-to-top),
/// with its vertical baseline at `base_x` (rounded to a pixel), starting at `y`
/// and advancing upward (`-Y`). Returns the vertical pen position after the text.
pub fn drawRotated90Ccw(canvas: Canvas, cache: *GlyphCache, style: Style, base_x: f32, y: f32, text: []const u8) !f32 {
    const base: i32 = @intFromFloat(@round(base_x));
    if (cache.runs.get(style, text)) |run| {
        for (run.glyphs) |item| {
            try drawGlyphRotated90Ccw(canvas, cache, style, base, y, item);
        }
        return y - run.width;
    }
    var l: Layout = .{ .style = style, .text = text, .x = 0 };
    while (l.next()) |item| {
        try drawGlyphRotated90Ccw(canvas, cache, style, base, y, item);
    }
    return y - l.x;
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const fira = @embedFile("../fonts/FiraSans-Regular.ttf");

test "blend matches per-channel arithmetic exactly" {
    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();
    for (0..256) |a| for (0..64) |_| {
        const dst = rand.int(u32);
        const src = rand.int(u32);
        var want: u32 = 0xff000000;
        inline for (.{ 0, 8, 16 }) |shift| {
            const d = (dst >> shift) & 0xff;
            const s = (src >> shift) & 0xff;
            want |= ((s * @as(u32, @intCast(a)) + d * (255 - @as(u32, @intCast(a))) + 127) / 255) << shift;
        }
        try testing.expectEqual(want, blend(dst, src, @intCast(a)));
    };
    for (0..255 * 255 + 1) |x| try testing.expectEqual((@as(u32, @intCast(x)) + 127) / 255, div255(@intCast(x)));
}

test "blend" {
    try testing.expectEqual(@as(u32, 0xff102030), blend(0xff102030, 0xffffffff, 0));
    try testing.expectEqual(@as(u32, 0xffffffff), blend(0xff102030, 0xffffffff, 255));
    try testing.expectEqual(@as(u32, 0xff808080), blend(0xff000000, 0xffffffff, 128));
}

test "glyph masks have ink where the glyph is" {
    const f = try Font.init(fira);
    const b = try rasterizeGlyph(testing.allocator, &f, f.glyphIndex('l'), 40, 0);
    defer testing.allocator.free(b.mask);
    // An 'l' at 40 px: a stem about 3 px wide and as tall as an ascender.
    var full: u32 = 0;
    var ink: f32 = 0;
    for (b.mask) |v| {
        if (v == 255) full += 1;
        ink += @as(f32, @floatFromInt(v)) / 255;
    }
    try testing.expect(full > 50);
    try testing.expect(b.top < -25 and b.top > -35);
    // Ink is roughly the stem's area.
    try testing.expect(ink > 80 and ink < 200);
}

test "subpixel offsets move ink right" {
    const f = try Font.init(fira);
    const g = f.glyphIndex('I');
    const centroid = struct {
        fn x(b: Bitmap) f32 {
            var sum: f32 = 0;
            var total: f32 = 0;
            for (0..b.height) |y| for (0..b.width) |xi| {
                const v: f32 = @floatFromInt(b.mask[y * b.width + xi]);
                sum += v * (@as(f32, @floatFromInt(xi)) + 0.5 + @as(f32, @floatFromInt(b.left)));
                total += v;
            };
            return sum / total;
        }
    }.x;
    const b0 = try rasterizeGlyph(testing.allocator, &f, g, 20, 0);
    defer testing.allocator.free(b0.mask);
    const b2 = try rasterizeGlyph(testing.allocator, &f, g, 20, 0.5);
    defer testing.allocator.free(b2.mask);
    try testing.expectApproxEqAbs(centroid(b0) + 0.5, centroid(b2), 0.05);
}

test "drawing text into a canvas" {
    const f = try Font.init(fira);
    var cache = GlyphCache.init(testing.allocator);
    defer cache.deinit();
    var pixels: [200 * 40]u32 = @splat(0xff000000);
    const canvas: Canvas = .{ .pixels = &pixels, .width = 200, .height = 40, .stride = 200 };
    const style: Style = .{ .font = &f, .size = 24 };
    const end = try draw(canvas, &cache, style, 2, 28, "FauxPi AV");
    try testing.expectApproxEqAbs(measure(style, "FauxPi AV") + 2, end, 0.001);
    // Kerning pulls "To" together (by 55/1000 em).
    try testing.expectApproxEqAbs(measure(style, "T") + measure(style, "o") - 24 * 0.055, measure(style, "To"), 0.001);
    var lit: u32 = 0;
    for (pixels) |p| lit += @intFromBool(p != 0xff000000);
    try testing.expect(lit > 300);
    // Nothing is drawn above the tallest glyph or past the end of the text.
    for (0..200) |x| try testing.expectEqual(@as(u32, 0xff000000), pixels[x]);
    const end_px: usize = @intFromFloat(@ceil(end) + 2);
    for (0..40) |y| for (end_px..200) |x| try testing.expectEqual(@as(u32, 0xff000000), pixels[y * 200 + x]);
    // Drawing again reuses the cached glyphs.
    const cached = cache.map.count();
    _ = try draw(canvas, &cache, style, 2, 28, "FauxPi AV");
    try testing.expectEqual(cached, cache.map.count());

    // Drawing rotated 90 degrees CCW advances upward and draws the same number of lit pixels.
    var rot_pixels: [40 * 200]u32 = @splat(0xff000000);
    const rot_canvas: Canvas = .{ .pixels = &rot_pixels, .width = 40, .height = 200, .stride = 40 };
    const end_y = try drawRotated90Ccw(rot_canvas, &cache, style, 28, 198, "FauxPi AV");
    try testing.expectApproxEqAbs(198 - measure(style, "FauxPi AV"), end_y, 0.001);
    var rot_lit: u32 = 0;
    for (rot_pixels) |p| rot_lit += @intFromBool(p != 0xff000000);
    try testing.expectEqual(lit, rot_lit);
}

test "invalid UTF-8 draws the replacement character" {
    const f = try Font.init(fira);
    const style: Style = .{ .font = &f, .size = 16 };
    try testing.expect(measure(style, "a\xffb") > measure(style, "ab"));
}

/// A run of text laid out: its glyphs' pen positions (from 0) and width.
pub const Run = struct {
    glyphs: []const Layout.Item,
    width: f32,
};

/// Runs of text laid out once and kept while they are drawn, since laying
/// out (character map lookups and kerning) costs much more than looking
/// a run up.
pub const RunCache = struct {
    gpa: std.mem.Allocator,
    /// Keyed by font, size and text.
    map: std.StringHashMapUnmanaged(Run) = .empty,

    /// Longer texts are laid out every time.
    const max_text = 512;

    pub fn init(gpa: std.mem.Allocator) RunCache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *RunCache) void {
        var it = c.map.iterator();
        while (it.next()) |e| c.free(e.key_ptr.*, e.value_ptr.*);
        c.map.deinit(c.gpa);
    }

    fn free(c: *RunCache, key: []const u8, run: Run) void {
        c.gpa.free(key);
        c.gpa.free(run.glyphs);
    }

    /// `text` laid out in `style`, or null if it cannot be kept (too long,
    /// or out of memory).
    pub fn get(c: *RunCache, style: Style, text: []const u8) ?Run {
        if (text.len > max_text) return null;
        var buf: [max_text + @sizeOf(usize) + 4]u8 = undefined;
        const key = keyFor(&buf, style, text);
        if (c.map.get(key)) |run| return run;
        var glyphs: std.ArrayList(Layout.Item) = .empty;
        var l = Layout.init(style, text, 0);
        while (l.next()) |item| glyphs.append(c.gpa, item) catch {
            glyphs.deinit(c.gpa);
            return null;
        };
        const run: Run = .{ .glyphs = glyphs.toOwnedSlice(c.gpa) catch {
            glyphs.deinit(c.gpa);
            return null;
        }, .width = l.x };
        const owned = c.gpa.dupe(u8, key) catch {
            c.gpa.free(run.glyphs);
            return null;
        };
        c.map.put(c.gpa, owned, run) catch {
            c.free(owned, run);
            return null;
        };
        return run;
    }

    /// The width of `text` in `style`.
    pub fn measure(c: *RunCache, style: Style, text: []const u8) f32 {
        return if (c.get(style, text)) |r| r.width else text_measure(style, text);
    }

    fn keyFor(buf: []u8, style: Style, text: []const u8) []const u8 {
        std.mem.writeInt(usize, buf[0..@sizeOf(usize)], @intFromPtr(style.font), .little);
        std.mem.writeInt(u32, buf[@sizeOf(usize)..][0..4], @bitCast(style.size), .little);
        const head = @sizeOf(usize) + 4;
        @memcpy(buf[head..][0..text.len], text);
        return buf[0 .. head + text.len];
    }
};

const text_measure = measure;

test "runs are laid out once and match measuring" {
    const f = try Font.init(fira);
    var c = RunCache.init(testing.allocator);
    defer c.deinit();
    const style: Style = .{ .font = &f, .size = 20 };
    const r = c.get(style, "To be").?;
    try testing.expectApproxEqAbs(measure(style, "To be"), r.width, 0.0001);
    try testing.expectEqual(@as(usize, 5), r.glyphs.len);
    try testing.expectEqual(r.glyphs.ptr, c.get(style, "To be").?.glyphs.ptr);
    // Another size is another run.
    try testing.expect(c.get(.{ .font = &f, .size = 21 }, "To be").?.glyphs.ptr != r.glyphs.ptr);
    try testing.expectEqual(@as(u32, 2), c.map.count());
}
