//! The 2D canvas FauxPi's title bar and Board & GPIO sheet draw with: kete's,
//! through the painter of the widget being painted. Coordinates are logical
//! pixels from the window's top left.

const std = @import("std");
const kete = @import("kete");

pub const Font = kete.font.Font;
pub const Style = kete.font.Style;

/// The text font, the same as kete draws text in.
pub const fira_ttf = kete.font.default_font_data;

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

    fn toKete(c: Color) kete.Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
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

    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn outset(r: Rect, d: f32) Rect {
        return .{ .x = r.x - d, .y = r.y - d, .w = r.w + 2 * d, .h = r.h + 2 * d };
    }

    fn toKete(r: Rect) kete.Rect {
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
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

    fn toKete(r: Radii) kete.CornerRadii {
        return .{ .tl = r.tl, .tr = r.tr, .br = r.br, .bl = r.bl };
    }
};

/// Material Icons, by kete's names for them.
pub const Icon = enum {
    bolt,
    check,
    close,
    crop_square,
    delete,
    developer_board,
    edit,
    expand_less,
    expand_more,
    filter_none,
    headphones,
    keyboard,
    lan,
    monitor,
    mouse,
    priority_high,
    thermostat,
    usb,

    fn toKete(icon: Icon) kete.IconName {
        return switch (icon) {
            inline else => |i| @field(kete.IconName, @tagName(i)),
        };
    }
};

/// Material 3 dark colour scheme.
pub const Theme = struct {
    primary: Color,
    on_primary: Color,
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

    pub const dark: Theme = .{
        .primary = .rgb(0xd0bcff),
        .on_primary = .rgb(0x381e72),
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

pub const Canvas = struct {
    /// The painter of the widget drawn in, whose top left is the window's.
    painter: *kete.Painter,
    /// The font text is measured in (the one kete draws it in).
    font: *const Font,

    /// Limits drawing to `r` until `restoreClip` with what this returns.
    pub fn clipTo(c: *Canvas, r: Rect) ?kete.Rect {
        return c.painter.clipTo(r.toKete());
    }

    pub fn restoreClip(c: *Canvas, old: ?kete.Rect) void {
        c.painter.restoreClip(old);
    }

    pub fn fillRect(c: *Canvas, r: Rect, color: Color) void {
        c.painter.canvas().fillRect(r.toKete(), color.toKete());
    }

    pub fn strokeRect(c: *Canvas, r: Rect, width: f32, color: Color) void {
        c.painter.canvas().strokeRect(r.toKete(), width, color.toKete());
    }

    /// Strokes the inside edge of `r` as dashes `dash` long, with gaps as long.
    pub fn strokeDashedRect(c: *Canvas, r: Rect, width: f32, dash: f32, color: Color) void {
        if (dash <= 0) return c.strokeRect(r, width, color);
        const pattern = [2]f32{ dash, dash };
        // Kete strokes centred on the edge: inset by half the width.
        const inner = r.outset(-width / 2);
        c.painter.canvas().strokeDashedRect(inner.toKete(), width, .{ .pattern = &pattern }, color.toKete());
    }

    pub fn fillRoundedRect(c: *Canvas, r: Rect, radii: Radii, color: Color) void {
        c.painter.canvas().fillRoundedRect(r.toKete(), radii.toKete(), color.toKete());
    }

    pub fn strokeRoundedRect(c: *Canvas, r: Rect, radii: Radii, width: f32, color: Color) void {
        c.painter.canvas().strokeRoundedRect(r.toKete(), radii.toKete(), width, color.toKete());
    }

    pub fn fillCircle(c: *Canvas, center: Point, radius: f32, color: Color) void {
        c.painter.canvas().fillCircle(center, radius, color.toKete());
    }

    pub fn strokeCircle(c: *Canvas, center: Point, radius: f32, width: f32, color: Color) void {
        c.painter.canvas().strokeCircle(center, radius, width, color.toKete());
    }

    pub fn measureText(c: *const Canvas, size: f32, str: []const u8) f32 {
        return kete.font.measure(.{ .font = c.font, .size = size }, str);
    }

    /// Draws `str` with its baseline at `baseline`; the pen position after it.
    pub fn drawText(c: *Canvas, size: f32, x: f32, baseline: f32, str: []const u8, color: Color) f32 {
        return c.painter.text(size, x, baseline, str, color.toKete());
    }

    /// Draws `str` turned a quarter counter-clockwise, running up from `y`
    /// with its baseline at `baseline_x`; where it ends.
    pub fn drawTextRotated90(c: *Canvas, size: f32, baseline_x: f32, y: f32, str: []const u8, color: Color) f32 {
        return c.painter.textRunning(size, .{ baseline_x, y }, .up, str, color.toKete())[1];
    }

    pub fn drawIcon(c: *Canvas, icon: Icon, x: f32, y: f32, size: f32, color: Color) void {
        c.painter.icon(icon.toKete(), x, y, size, color.toKete());
    }
};
