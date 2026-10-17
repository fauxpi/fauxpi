//! Software 2D anti-aliased canvas for FauxPi's window decorations and
//! Board & GPIO drop-down sheet, matching dazzle's `gfx.Canvas`, `ui.Theme`,
//! and `ui.icons` APIs.

const std = @import("std");
const text_mod = @import("../font/text.zig");

pub const Font = text_mod.Font;
pub const GlyphCache = text_mod.GlyphCache;
pub const Style = text_mod.Style;

pub const fira_ttf = @embedFile("../fonts/FiraSans-Regular.ttf");
pub const icons_ttf = @embedFile("../fonts/MaterialIcons-Regular.ttf");

pub const Point = [2]f32;

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    /// From 0xRRGGBB.
    pub fn rgb(hex: u24) Color {
        return .{
            .r = @as(f32, @floatFromInt((hex >> 16) & 0xff)) / 255.0,
            .g = @as(f32, @floatFromInt((hex >> 8) & 0xff)) / 255.0,
            .b = @as(f32, @floatFromInt(hex & 0xff)) / 255.0,
        };
    }

    /// From 0xAARRGGBB.
    pub fn argb(hex: u32) Color {
        var c = rgb(@truncate(hex));
        c.a = @as(f32, @floatFromInt(hex >> 24)) / 255.0;
        return c;
    }

    pub fn withAlpha(c: Color, a: f32) Color {
        var out = c;
        out.a = a;
        return out;
    }

    /// As 0xAARRGGBB.
    pub fn toArgb(c: Color) u32 {
        const a: u32 = @intFromFloat(@round(std.math.clamp(c.a, 0, 1) * 255.0));
        const r: u32 = @intFromFloat(@round(std.math.clamp(c.r, 0, 1) * 255.0));
        const g: u32 = @intFromFloat(@round(std.math.clamp(c.g, 0, 1) * 255.0));
        const b: u32 = @intFromFloat(@round(std.math.clamp(c.b, 0, 1) * 255.0));
        return (a << 24) | (r << 16) | (g << 8) | b;
    }
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(r: Rect, p: Point) bool {
        return p[0] >= r.x and p[0] < r.x + r.w and p[1] >= r.y and p[1] < r.y + r.h;
    }

    pub fn intersects(a: Rect, b: Rect) bool {
        return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
    }

    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn unite(a: Rect, b: Rect) Rect {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{
            .x = x0,
            .y = y0,
            .w = @max(a.x + a.w, b.x + b.w) - x0,
            .h = @max(a.y + a.h, b.y + b.h) - y0,
        };
    }

    pub fn outset(r: Rect, d: f32) Rect {
        return .{ .x = r.x - d, .y = r.y - d, .w = r.w + 2 * d, .h = r.h + 2 * d };
    }
};

/// Corner radii: top left, top right, bottom right, bottom left.
pub const Radii = struct {
    tl: f32 = 0,
    tr: f32 = 0,
    br: f32 = 0,
    bl: f32 = 0,

    pub fn all(r: f32) Radii {
        return .{ .tl = r, .tr = r, .br = r, .bl = r };
    }

    pub fn max(r: Radii) f32 {
        return @max(@max(r.tl, r.tr), @max(r.br, r.bl));
    }
};

/// Material Icons codepoints in `MaterialIcons-Regular.ttf`.
pub const Icon = enum(u21) {
    bolt = 0xea0b,
    check = 0xe5ca,
    close = 0xe5cd,
    crop_square = 0xe3c6,
    desktop_windows = 0xe30c,
    developer_board = 0xe30d,
    device_hub = 0xe335,
    expand_less = 0xe5ce,
    expand_more = 0xe5cf,
    filter_none = 0xe3e0,
    headphones = 0xf01f,
    keyboard = 0xe312,
    lan = 0xeb2f,
    monitor = 0xef5b,
    mouse = 0xe323,
    power = 0xe63c,
    power_settings_new = 0xe8ac,
    print = 0xe8ad,
    priority_high = 0xe645,
    sports_esports = 0xea28,
    tv = 0xe333,
    usb = 0xe1e0,
    videocam = 0xe04b,
    wifi = 0xe63e,

    pub fn text(icon: Icon, buf: *[4]u8) []const u8 {
        const len = std.unicode.utf8Encode(@intFromEnum(icon), buf) catch return "";
        return buf[0..len];
    }
};

/// Material 3 colour scheme from `dazzle/src/ui/theme.zig`.
pub const Theme = struct {
    primary: Color,
    on_primary: Color,
    primary_container: Color,
    on_primary_container: Color,
    secondary_container: Color,
    surface: Color,
    surface_container: Color,
    surface_container_highest: Color,
    on_surface: Color,
    on_surface_variant: Color,
    outline: Color,
    outline_variant: Color,
    @"error": Color,
    body_size: f32 = 14,
    label_size: f32 = 14,
    title_size: f32 = 22,

    pub const dark: Theme = .{
        .primary = .rgb(0xd0bcff),
        .on_primary = .rgb(0x381e72),
        .primary_container = .rgb(0x4f378b),
        .on_primary_container = .rgb(0xeaddff),
        .secondary_container = .rgb(0x4a4458),
        .surface = .rgb(0x141218),
        .surface_container = .rgb(0x211f26),
        .surface_container_highest = .rgb(0x36343b),
        .on_surface = .rgb(0xe6e0e9),
        .on_surface_variant = .rgb(0xcac4d0),
        .outline = .rgb(0x938f99),
        .outline_variant = .rgb(0x49454f),
        .@"error" = .rgb(0xf2b8b5),
    };
};

const fill_stroke: f32 = 1e6;

inline fn shapeCoverage(d: f32, sx: f32, sy: f32, inset: f32) f32 {
    const by_distance = std.math.clamp(0.5 - (d + inset), 0.0, 1.0);
    const cx = std.math.clamp(0.5 - (sx + inset), 0.0, 1.0);
    const cy = std.math.clamp(0.5 - (sy + inset), 0.0, 1.0);
    return @min(by_distance, cx * cy);
}

pub const Canvas = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    stride: u32,
    scale: f32 = 1.0,
    clip: ?Rect = null,
    origin: Point = .{ 0, 0 },
    font: *const Font,
    icon_font: *const Font,
    cache: *GlyphCache,

    pub fn clipTo(c: *Canvas, r: Rect) ?Rect {
        const old = c.clip;
        const moved: Rect = .{ .x = r.x + c.origin[0], .y = r.y + c.origin[1], .w = r.w, .h = r.h };
        c.clip = if (old) |o| (o.intersect(moved) orelse .{ .x = 0, .y = 0, .w = 0, .h = 0 }) else moved;
        return old;
    }

    pub fn restoreClip(c: *Canvas, old: ?Rect) void {
        c.clip = old;
    }

    pub fn fillRect(c: *Canvas, r: Rect, color: Color) void {
        c.roundedRect(r, .{}, fill_stroke, color);
    }

    pub fn strokeRect(c: *Canvas, r: Rect, width: f32, color: Color) void {
        c.roundedRect(r, .{}, width, color);
    }

    pub fn fillRoundedRect(c: *Canvas, r: Rect, radii: Radii, color: Color) void {
        c.roundedRect(r, radii, fill_stroke, color);
    }

    pub fn strokeRoundedRect(c: *Canvas, r: Rect, radii: Radii, width: f32, color: Color) void {
        c.roundedRect(r, radii, width, color);
    }

    pub fn fillCircle(c: *Canvas, center: Point, radius: f32, color: Color) void {
        c.roundedRect(
            .{ .x = center[0] - radius, .y = center[1] - radius, .w = 2 * radius, .h = 2 * radius },
            .all(radius),
            fill_stroke,
            color,
        );
    }

    pub fn strokeCircle(c: *Canvas, center: Point, radius: f32, width: f32, color: Color) void {
        c.roundedRect(
            .{ .x = center[0] - radius, .y = center[1] - radius, .w = 2 * radius, .h = 2 * radius },
            .all(radius),
            width,
            color,
        );
    }

    pub fn measureText(c: *const Canvas, size: f32, str: []const u8) f32 {
        return text_mod.measure(.{ .font = c.font, .size = size }, str);
    }

    pub fn drawText(c: *Canvas, size: f32, x: f32, baseline: f32, str: []const u8, color: Color) f32 {
        return c.drawTextWithFont(c.font, size, x, baseline, str, color);
    }

    pub fn drawTextRotated90(c: *Canvas, size: f32, baseline_x: f32, y: f32, str: []const u8, color: Color) f32 {
        return c.drawTextRotated90WithFont(c.font, size, baseline_x, y, str, color);
    }

    pub fn drawIcon(c: *Canvas, icon: Icon, x: f32, y: f32, size: f32, color: Color) void {
        var buf: [4]u8 = undefined;
        _ = c.drawTextWithFont(c.icon_font, size, x, y + size, icon.text(&buf), color);
    }

    fn drawTextWithFont(c: *Canvas, f: *const Font, size: f32, x: f32, baseline: f32, str: []const u8, color: Color) f32 {
        if (str.len == 0) return x;
        const sc = @max(c.scale, 1.0);
        const argb = color.toArgb();
        if (color.a <= 0) {
            return x + text_mod.measure(.{ .font = f, .size = size, .color = argb }, str);
        }

        const phys_style: Style = .{
            .font = f,
            .size = size * sc,
            .color = argb,
        };
        const ox = (x + c.origin[0]) * sc;
        const oy = (baseline + c.origin[1]) * sc;

        const tc: text_mod.Canvas = .{
            .pixels = c.pixels,
            .width = c.width,
            .height = c.height,
            .stride = c.stride,
        };
        const end_phys = text_mod.draw(tc, c.cache, phys_style, ox, oy, str) catch
            (ox + text_mod.measure(.{ .font = f, .size = size, .color = argb }, str) * sc);
        return (end_phys / sc) - c.origin[0];
    }

    fn drawTextRotated90WithFont(c: *Canvas, f: *const Font, size: f32, baseline_x: f32, y: f32, str: []const u8, color: Color) f32 {
        if (str.len == 0) return y;
        const sc = @max(c.scale, 1.0);
        const argb = color.toArgb();
        if (color.a <= 0) {
            return y - text_mod.measure(.{ .font = f, .size = size, .color = argb }, str);
        }

        const phys_style: Style = .{
            .font = f,
            .size = size * sc,
            .color = argb,
        };
        const ox = (baseline_x + c.origin[0]) * sc;
        const oy = (y + c.origin[1]) * sc;

        const tc: text_mod.Canvas = .{
            .pixels = c.pixels,
            .width = c.width,
            .height = c.height,
            .stride = c.stride,
        };
        const end_phys = text_mod.drawRotated90Ccw(tc, c.cache, phys_style, ox, oy, str) catch
            (oy - text_mod.measure(.{ .font = f, .size = size, .color = argb }, str) * sc);
        return (end_phys / sc) - c.origin[1];
    }

    fn roundedRect(c: *Canvas, r_in: Rect, radii_in: Radii, stroke_in: f32, color: Color) void {
        const sc = @max(c.scale, 1.0);
        const r: Rect = .{
            .x = (r_in.x + c.origin[0]) * sc,
            .y = (r_in.y + c.origin[1]) * sc,
            .w = r_in.w * sc,
            .h = r_in.h * sc,
        };
        if (r.w <= 0 or r.h <= 0 or color.a <= 0 or stroke_in <= 0) return;

        const screen_rect: Rect = .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(c.width),
            .h = @floatFromInt(c.height),
        };
        const active_clip = if (c.clip) |cl| blk: {
            const scaled_clip: Rect = .{
                .x = cl.x * sc,
                .y = cl.y * sc,
                .w = cl.w * sc,
                .h = cl.h * sc,
            };
            break :blk screen_rect.intersect(scaled_clip) orelse return;
        } else screen_rect;
        const box = r.outset(1.0).intersect(active_clip) orelse return;

        const x0: u32 = @intFromFloat(@max(0.0, @floor(box.x)));
        const y0: u32 = @intFromFloat(@max(0.0, @floor(box.y)));
        const x1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(c.width)), @ceil(box.x + box.w)));
        const y1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(c.height)), @ceil(box.y + box.h)));
        if (x0 >= x1 or y0 >= y1) return;

        const hw = r.w * 0.5;
        const hh = r.h * 0.5;
        const cx = r.x + hw;
        const cy = r.y + hh;
        const limit = @min(hw, hh);
        const radii: Radii = .{
            .tl = std.math.clamp(radii_in.tl * sc, 0.0, limit),
            .tr = std.math.clamp(radii_in.tr * sc, 0.0, limit),
            .br = std.math.clamp(radii_in.br * sc, 0.0, limit),
            .bl = std.math.clamp(radii_in.bl * sc, 0.0, limit),
        };
        const max_r = radii.max();
        const filled = stroke_in >= fill_stroke;
        const stroke = if (filled) fill_stroke else stroke_in * sc;
        const argb = color.toArgb();
        const base_alpha: f32 = color.a * 255.0;

        // Horizontal span `inner_x0..inner_x1` where `ax <= hw - inner_margin` (`mx == 0` and `cx == 1.0`)
        const inner_margin = @max(max_r, if (filled) 0.0 else stroke) + 1.0;
        const has_inner_x = hw > inner_margin;
        const inner_x0: u32 = if (has_inner_x) @intFromFloat(@max(@as(f32, @floatFromInt(x0)), @ceil(cx - (hw - inner_margin)))) else x1;
        const inner_x1: u32 = if (has_inner_x) @intFromFloat(@min(@as(f32, @floatFromInt(x1)), @floor(cx + (hw - inner_margin)))) else x0;
        const has_mid_span = has_inner_x and (inner_x0 < inner_x1);
        const full_a_u32: u32 = @intFromFloat(@round(base_alpha));

        for (y0..y1) |py| {
            const fy = @as(f32, @floatFromInt(py)) + 0.5 - cy;
            const ay = @abs(fy);
            const sy = ay - hh;
            const row = c.pixels[py * c.stride ..];
            const in_inner_y = (hh > inner_margin) and (ay <= hh - inner_margin);

            var px: u32 = x0;
            while (px < x1) {
                if (has_mid_span and px == inner_x0) {
                    if (in_inner_y) {
                        if (filled) {
                            text_mod.blendSpan(row[inner_x0..inner_x1], argb, full_a_u32);
                        }
                    } else {
                        const span_cov = std.math.clamp(0.5 - sy, 0.0, 1.0) -
                            (if (filled) @as(f32, 0.0) else std.math.clamp(0.5 - (sy + stroke), 0.0, 1.0));
                        if (span_cov > 0.0) {
                            const span_a: u32 = @intFromFloat(@round(base_alpha * span_cov));
                            text_mod.blendSpan(row[inner_x0..inner_x1], argb, span_a);
                        }
                    }
                    px = inner_x1;
                    continue;
                }

                const fx = @as(f32, @floatFromInt(px)) + 0.5 - cx;
                const ax = @abs(fx);
                const rad = if (fx < 0.0)
                    (if (fy < 0.0) radii.tl else radii.bl)
                else
                    (if (fy < 0.0) radii.tr else radii.br);

                const qx = ax - (hw - rad);
                const qy = ay - (hh - rad);
                const mx = @max(qx, 0.0);
                const my = @max(qy, 0.0);
                const d = @sqrt(mx * mx + my * my) + @min(@max(qx, qy), 0.0) - rad;
                const sx = ax - hw;

                const cov = shapeCoverage(d, sx, sy, 0.0) - (if (filled) 0.0 else shapeCoverage(d, sx, sy, stroke));
                if (cov > 0.0) {
                    const a_u32: u32 = @intFromFloat(@round(base_alpha * cov));
                    if (a_u32 > 0) {
                        row[px] = text_mod.blend(row[px], argb, a_u32);
                    }
                }
                px += 1;
            }
        }
    }
};

const testing = std.testing;

test "canvas shapes and icons draw anti-aliased pixels at 1x and 2x scale" {
    const f = try Font.init(fira_ttf);
    const ic = try Font.init(icons_ttf);
    var cache = GlyphCache.init(testing.allocator);
    defer cache.deinit();

    var pixels: [100 * 60]u32 = @splat(0xff141218);
    var c: Canvas = .{
        .pixels = &pixels,
        .width = 100,
        .height = 60,
        .stride = 100,
        .font = &f,
        .icon_font = &ic,
        .cache = &cache,
    };

    c.fillRoundedRect(.{ .x = 10, .y = 10, .w = 40, .h = 20 }, .all(6), Theme.dark.primary);
    try testing.expectEqual(Theme.dark.primary.toArgb(), pixels[20 * 100 + 30]);

    c.strokeCircle(.{ 75, 30 }, 12, 2, Theme.dark.on_surface);
    try testing.expectEqual(@as(u32, 0xff141218), pixels[30 * 100 + 75]);

    try testing.expect(ic.glyphIndex(@intFromEnum(Icon.bolt)) != 0);
    try testing.expect(ic.glyphIndex(@intFromEnum(Icon.monitor)) != 0);

    c.drawIcon(.developer_board, 10, 34, 20, Theme.dark.on_surface);
    var icon_lit: usize = 0;
    for (34..54) |y| {
        for (10..30) |x| {
            if (pixels[y * 100 + x] != 0xff141218) icon_lit += 1;
        }
    }
    try testing.expect(icon_lit > 40);

    // 2x HiDPI scale: logical 100x60 into physical 200x120 buffer
    var pixels_2x: [200 * 120]u32 = @splat(0xff141218);
    var c2: Canvas = .{
        .pixels = &pixels_2x,
        .width = 200,
        .height = 120,
        .stride = 200,
        .scale = 2.0,
        .font = &f,
        .icon_font = &ic,
        .cache = &cache,
    };
    c2.fillRoundedRect(.{ .x = 10, .y = 10, .w = 40, .h = 20 }, .all(6), Theme.dark.primary);
    // Logical center (30, 20) -> physical center (60, 40)
    try testing.expectEqual(Theme.dark.primary.toArgb(), pixels_2x[40 * 200 + 60]);

    // Translucent fillRoundedRect uses SIMD blendSpan and matches scalar text_mod.blend
    const translucent = Theme.dark.primary.withAlpha(0.5);
    c2.fillRoundedRect(.{ .x = 55, .y = 10, .w = 40, .h = 20 }, .all(6), translucent);
    const expected_blend = text_mod.blend(0xff141218, translucent.toArgb(), @intFromFloat(@round(0.5 * 255.0)));
    try testing.expectEqual(expected_blend, pixels_2x[40 * 200 + 150]);
    try testing.expectEqual(expected_blend, pixels_2x[22 * 200 + 150]);
}
