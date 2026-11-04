//! The drawing of the board on the sheet: the Raspberry Pi (from
//! `board.zig`) with its connectors, and the cables, cards and peripherals
//! plugged into them, drawn from what is connected; and which of them is at a
//! point, for the drawing to toggle.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const board = @import("board.zig");
const board_state = @import("board_state.zig");

const Canvas = canvas_mod.Canvas;
const Color = canvas_mod.Color;
const Rect = canvas_mod.Rect;
const Radii = canvas_mod.Radii;
const Point = canvas_mod.Point;
const Icon = canvas_mod.Icon;
const Theme = canvas_mod.Theme;
const Font = canvas_mod.Font;
const SystemStatus = board_state.SystemStatus;

/// Status colours.
const red: Color = .rgb(0xe53935);
const orange: Color = .rgb(0xfb8c00);

/// Board drawing line widths.
const line_w: f32 = 1.25;
const heavy_w: f32 = 1.75;

pub const InteractiveTarget = enum {
    sd_connector,
    sd_card,
    gpio,
    hdmi,
    audio,
    power,
    usb_hub,
    usb_keyboard,
    usb_mouse,
    ethernet,
    cpu,
};

/// Geometry of the 3-port USB Hub with Ethernet and external cables in board millimetres (`mm`).
pub const HubLayout = struct {
    pub const sd_ext_left_mm: f32 = 21.5;
    pub const bottom_ext_mm: f32 = 18.0; // extends 18mm below board.height
    pub const right_ext_mm: f32 = 19.0; // extends 19mm past board.width on B boards

    pub const hub_rect: board.Rect = .{ .x = 73.0, .y = 14.0, .w = 50.0, .h = 16.0 };
    pub const kbd_port_rect: board.Rect = .{ .x = 75.2, .y = 14.0, .w = 8.6, .h = 5.2 };
    pub const mouse_port_rect: board.Rect = .{ .x = 85.8, .y = 14.0, .w = 8.6, .h = 5.2 };
    pub const spare_port_rect: board.Rect = .{ .x = 96.4, .y = 14.0, .w = 8.6, .h = 5.2 };
    pub const eth_port_rect: board.Rect = .{ .x = 108.6, .y = 14.0, .w = 11.6, .h = 6.8 };

    pub const gpio_cable_min_y: f32 = -11.0;
    pub const top_cable_min_y: f32 = 0.0;
    pub const bottom_cable_max_y: f32 = 48.0;
    pub const usb_cable_horiz_y: f32 = 45.2;
    pub const usb_cable_turn_r: f32 = 3.5;
    pub const hub_cable_x: f32 = 98.0;

    pub const BoardHubLayout = struct {
        has_external_hub: bool,
        right_usb_plug: bool,
        hub_rect: board.Rect,
        kbd_port_rect: board.Rect,
        mouse_port_rect: board.Rect,
        spare_port_rect: board.Rect,
        eth_port_rect: board.Rect,
        bottom_cable_max_y: f32,
        right_cable_max_x: f32,
    };

    pub fn forBoard(drawing: *const board.Board) BoardHubLayout {
        var has_onboard_eth = false;
        var has_right_usb = false;
        for (drawing.parts) |p| {
            if (p.kind == .ethernet) has_onboard_eth = true;
            if (p.kind == .usb and p.faces == .right) has_right_usb = true;
        }
        const dx: f32 = if (has_right_usb) 13.0 else 0.0;
        const dy: f32 = if (has_right_usb) 2.55 else 0.0;
        const shift = struct {
            fn f(r: board.Rect, sx: f32, sy: f32) board.Rect {
                return .{ .x = r.x + sx, .y = r.y + sy, .w = r.w, .h = r.h };
            }
        }.f;
        return .{
            .has_external_hub = !has_onboard_eth,
            .right_usb_plug = has_right_usb,
            .hub_rect = shift(hub_rect, dx, dy),
            .kbd_port_rect = shift(kbd_port_rect, dx, dy),
            .mouse_port_rect = shift(mouse_port_rect, dx, dy),
            .spare_port_rect = shift(spare_port_rect, dx, dy),
            .eth_port_rect = shift(eth_port_rect, dx, dy),
            .bottom_cable_max_y = drawing.height + bottom_ext_mm,
            .right_cable_max_x = drawing.width + right_ext_mm,
        };
    }
};

/// What the drawing shows besides the board and what is connected: the
/// target under the pointer, the CPU's temperature, and the SD card's name.
pub const Look = struct {
    theme: *const Theme,
    font: *const Font,
    hovered: ?InteractiveTarget = null,
    /// The CPU is picked (its temperature is being set).
    cpu_selected: bool = false,
    cpu_temperature_c: u8 = 42,
    /// The name of the card in (or to go in) the slot, if there is a card.
    sd_card_name: ?[]const u8 = null,
};

pub fn boardBoundsWithPeripherals(drawing: *const board.Board) board.Rect {
    var r = drawing.bounds();
    const hl = HubLayout.forBoard(drawing);
    const x0 = @min(r.x, -HubLayout.sd_ext_left_mm);
    const y0 = @min(r.y, HubLayout.gpio_cable_min_y);
    const x1 = if (hl.has_external_hub)
        @max(r.x + r.w, hl.hub_rect.x + hl.hub_rect.w + 1.0)
    else
        @max(r.x + r.w, hl.right_cable_max_x);
    const y1 = @max(r.y + r.h, hl.bottom_cable_max_y);
    r.x = x0;
    r.y = y0;
    r.w = x1 - x0;
    r.h = y1 - y0;
    return r;
}

pub fn boardTransform(drawing: *const board.Board, box: Rect) struct { scale: f32, x: f32, y: f32 } {
    const r = boardBoundsWithPeripherals(drawing);
    const scale = @min(box.w / r.w, box.h / r.h);
    const x = box.x + (box.w - r.w * scale) * 0.5 - r.x * scale;
    const y = box.y + (box.h - r.h * scale) * 0.5 - r.y * scale;
    return .{ .scale = scale, .x = x, .y = y };
}

fn rectContainsMm(r: board.Rect, pt: [2]f32) bool {
    return pt[0] >= r.x and pt[0] <= r.x + r.w and pt[1] >= r.y and pt[1] <= r.y + r.h;
}

/// Hit-tests interactive connectors and peripherals at `pt` (in board millimetres).
pub fn targetAt(drawing: *const board.Board, pt: [2]f32, sd_connected: bool) ?InteractiveTarget {
    const hl = HubLayout.forBoard(drawing);

    if (hl.has_external_hub) {
        // 1. Downstream ports & plugs on the 3-port USB Hub with Ethernet
        const kbd_hit: board.Rect = .{
            .x = hl.kbd_port_rect.x,
            .y = HubLayout.top_cable_min_y,
            .w = hl.kbd_port_rect.w,
            .h = (hl.kbd_port_rect.y + hl.kbd_port_rect.h) - HubLayout.top_cable_min_y,
        };
        if (rectContainsMm(kbd_hit, pt)) return .usb_keyboard;

        const mouse_hit: board.Rect = .{
            .x = hl.mouse_port_rect.x,
            .y = HubLayout.top_cable_min_y,
            .w = hl.mouse_port_rect.w,
            .h = (hl.mouse_port_rect.y + hl.mouse_port_rect.h) - HubLayout.top_cable_min_y,
        };
        if (rectContainsMm(mouse_hit, pt)) return .usb_mouse;

        const eth_hit: board.Rect = .{
            .x = hl.eth_port_rect.x,
            .y = HubLayout.top_cable_min_y,
            .w = hl.eth_port_rect.w,
            .h = (hl.eth_port_rect.y + hl.eth_port_rect.h) - HubLayout.top_cable_min_y,
        };
        if (rectContainsMm(eth_hit, pt)) return .ethernet;

        // 2. USB Hub connecting cable (hub body itself is not clickable)
        if (hl.right_usb_plug) {
            if (pt[0] >= drawing.width and pt[0] <= hl.hub_rect.x and
                pt[1] >= hl.hub_rect.y and pt[1] <= hl.hub_rect.y + hl.hub_rect.h)
            {
                return .usb_hub;
            }
        } else {
            if (pt[0] >= 40.0 and pt[0] <= HubLayout.hub_cable_x + 3.0 and
                pt[1] >= 42.0 and pt[1] <= hl.bottom_cable_max_y)
            {
                return .usb_hub;
            }
            if (pt[0] >= HubLayout.hub_cable_x - 3.0 and pt[0] <= HubLayout.hub_cable_x + 3.0 and
                pt[1] >= hl.hub_rect.y + hl.hub_rect.h and pt[1] <= HubLayout.usb_cable_horiz_y + 2.0)
            {
                return .usb_hub;
            }
        }
    }

    // 3. Connectors on the Raspberry Pi board itself (plus their plugs/cards)
    var usb_double_idx: usize = 0;
    for (drawing.parts) |p| {
        switch (p.kind) {
            .gpio, .gpio_holes => {
                const gpio_hit: board.Rect = .{
                    .x = p.rect.x - 0.5,
                    .y = HubLayout.gpio_cable_min_y,
                    .w = p.rect.w + 1.0,
                    .h = (p.rect.y + p.rect.h) - HubLayout.gpio_cable_min_y,
                };
                if (rectContainsMm(gpio_hit, pt)) return .gpio;
            },
            .micro_sd => {
                const ext_w: f32 = if (sd_connected) 9.0 else HubLayout.sd_ext_left_mm;
                const sd_card_hit: board.Rect = .{
                    .x = p.rect.x - ext_w,
                    .y = p.rect.y,
                    .w = ext_w,
                    .h = p.rect.h,
                };
                if (rectContainsMm(sd_card_hit, pt)) return .sd_card;
                if (rectContainsMm(p.rect, pt)) return .sd_connector;
            },
            .mini_hdmi, .hdmi => {
                const hdmi_hit: board.Rect = .{
                    .x = p.rect.x,
                    .y = p.rect.y,
                    .w = p.rect.w,
                    .h = hl.bottom_cable_max_y - p.rect.y,
                };
                if (rectContainsMm(hdmi_hit, pt)) return .hdmi;
            },
            .power => {
                const pwr_hit: board.Rect = .{
                    .x = p.rect.x,
                    .y = p.rect.y,
                    .w = p.rect.w,
                    .h = hl.bottom_cable_max_y - p.rect.y,
                };
                if (rectContainsMm(pwr_hit, pt)) return .power;
            },
            .audio => {
                const audio_hit: board.Rect = .{
                    .x = p.rect.x,
                    .y = p.rect.y,
                    .w = p.rect.w,
                    .h = hl.bottom_cable_max_y - p.rect.y,
                };
                if (rectContainsMm(audio_hit, pt)) return .audio;
            },
            .usb_otg => {
                const usb_hit: board.Rect = .{
                    .x = p.rect.x,
                    .y = p.rect.y,
                    .w = p.rect.w,
                    .h = hl.bottom_cable_max_y - p.rect.y,
                };
                if (rectContainsMm(usb_hit, pt)) return .usb_hub;
            },
            .usb => {
                if (hl.has_external_hub) {
                    const usb_hit: board.Rect = .{
                        .x = p.rect.x,
                        .y = p.rect.y,
                        .w = hl.hub_rect.x - p.rect.x,
                        .h = p.rect.h,
                    };
                    if (rectContainsMm(usb_hit, pt)) return .usb_hub;
                }
            },
            .usb_double => {
                const idx = usb_double_idx;
                usb_double_idx += 1;
                if (!hl.has_external_hub) {
                    const usb_hit: board.Rect = .{
                        .x = p.rect.x,
                        .y = p.rect.y,
                        .w = hl.right_cable_max_x - p.rect.x,
                        .h = p.rect.h,
                    };
                    if (rectContainsMm(usb_hit, pt)) {
                        return if (idx == 0) .usb_keyboard else .usb_mouse;
                    }
                }
            },
            .ethernet => {
                if (!hl.has_external_hub) {
                    const eth_hit: board.Rect = .{
                        .x = p.rect.x,
                        .y = p.rect.y,
                        .w = hl.right_cable_max_x - p.rect.x,
                        .h = p.rect.h,
                    };
                    if (rectContainsMm(eth_hit, pt)) return .ethernet;
                }
            },
            .soc, .soc_with_ram => {
                if (!p.underside and rectContainsMm(p.rect, pt)) return .cpu;
            },
            else => {},
        }
    }
    return null;
}

/// Draws board `b` fitted into `box`, with what `status` has connected.
pub fn paintBoard(
    c: *Canvas,
    b: *const board.Board,
    box: Rect,
    status: SystemStatus,
    look: Look,
) void {
    const t = look.theme;
    const tr = boardTransform(b, box);
    const s = tr.scale;
    const ink = t.on_surface_variant;

    const map = struct {
        fn f(trans: @TypeOf(tr), r: board.Rect) Rect {
            return .{
                .x = trans.x + r.x * trans.scale,
                .y = trans.y + r.y * trans.scale,
                .w = r.w * trans.scale,
                .h = r.h * trans.scale,
            };
        }
    }.f;

    const outline = map(tr, .{ .x = 0, .y = 0, .w = b.width, .h = b.height });
    c.fillRoundedRect(outline, .all(b.corner * s), t.on_surface.withAlpha(0.04));
    c.strokeRoundedRect(outline, .all(b.corner * s), heavy_w, ink);

    for (b.holes) |h| {
        c.strokeCircle(.{ tr.x + h[0] * s, tr.y + h[1] * s }, b.hole_diameter * 0.5 * s, line_w, ink);
    }

    // Underside parts (faint), then top parts
    for (b.parts) |part| {
        if (part.underside) drawPart(c, &part, map(tr, part.rect), s, ink.withAlpha(0.35));
    }
    const hl = HubLayout.forBoard(b);
    var usb_double_idx: usize = 0;
    for (b.parts) |part| {
        const part_hovered = switch (part.kind) {
            .micro_sd => look.hovered == .sd_connector or (status.sd_connected and look.hovered == .sd_card),
            .mini_hdmi, .hdmi => look.hovered == .hdmi,
            .audio => look.hovered == .audio,
            .power => look.hovered == .power,
            .usb_otg => look.hovered == .usb_hub,
            .usb => hl.has_external_hub and look.hovered == .usb_hub,
            .usb_double => blk: {
                const idx = usb_double_idx;
                usb_double_idx += 1;
                break :blk !hl.has_external_hub and (look.hovered == if (idx == 0) InteractiveTarget.usb_keyboard else InteractiveTarget.usb_mouse);
            },
            .ethernet => !hl.has_external_hub and look.hovered == .ethernet,
            .gpio, .gpio_holes => look.hovered == .gpio,
            .soc, .soc_with_ram => !part.underside and (look.hovered == .cpu or look.cpu_selected),
            else => false,
        };
        const pr = map(tr, part.rect);
        if (!part.underside) {
            if (partOverhangsBoard(b, &part)) {
                fillOverhangingPart(c, &part, pr, s, t.surface, t.on_surface.withAlpha(0.04));
            }
            if (part.kind == .act_led and status.power_connected and status.act_led_on) {
                const led_col = Color.rgb(0x22E55E);
                c.fillRoundedRect(pr.outset(1.0 * s), .all(0.9 * s), led_col.withAlpha(0.36));
                c.fillRoundedRect(pr, .all(0.25 * s), led_col);
            } else if (part.kind == .pwr_led and status.power_connected and status.pwr_led_on) {
                const led_col = Color.rgb(0xF83B3B);
                c.fillRoundedRect(pr.outset(1.0 * s), .all(0.9 * s), led_col.withAlpha(0.36));
                c.fillRoundedRect(pr, .all(0.25 * s), led_col);
            }
            const fg = if (part_hovered) t.primary else ink;
            drawPart(c, &part, pr, s, fg);
            if (part.kind == .soc or part.kind == .soc_with_ram) {
                const temp_c = look.cpu_temperature_c;
                var temp_buf: [16]u8 = undefined;
                const temp_str = std.fmt.bufPrint(&temp_buf, "{d}°C", .{temp_c}) catch "42°C";
                const icon_sz = 4.2 * s;
                var font_sz = 2.5 * s;
                const max_tw = @max(4.0 * s, pr.w - (if (part.lidded) 3.2 * s else 2.0 * s));
                var tw = c.measureText(font_sz, temp_str);
                if (tw > max_tw and tw > 0) {
                    font_sz *= max_tw / tw;
                    tw = c.measureText(font_sz, temp_str);
                }
                const style: canvas_mod.Style = .{ .font = look.font, .size = font_sz };
                const text_h = style.ascent();
                const gap = 0.6 * s;
                const group_h = icon_sz + gap + text_h;
                const top_y = pr.y + (pr.h - group_h) * 0.5;
                c.drawIcon(
                    .thermostat,
                    @round(pr.x + (pr.w - icon_sz) * 0.5),
                    @round(top_y),
                    icon_sz,
                    fg,
                );
                _ = c.drawText(
                    font_sz,
                    @round(pr.x + (pr.w - tw) * 0.5),
                    @round(top_y + icon_sz + gap + text_h),
                    temp_str,
                    fg,
                );
            }
        }
        if (part_hovered) {
            c.fillRoundedRect(pr, partRadius(&part, s), t.primary.withAlpha(0.22));
        }
    }

    const max_y = tr.y + hl.bottom_cable_max_y * s;
    const max_x = tr.x + hl.right_cable_max_x * s;

    // 0. 40-pin GPIO IDC ribbon cable connector on the top edge of the board
    for (b.parts) |part| {
        if (part.kind == .gpio or part.kind == .gpio_holes) {
            const hovered = (look.hovered == .gpio);
            drawGpioRibbonCable(
                c,
                map(tr, part.rect),
                tr.y + HubLayout.gpio_cable_min_y * s,
                s,
                if (hovered) t.primary else ink,
                t.primary,
                t.surface,
                status.gpio_connected,
                hovered,
            );
        }
    }

    // 1. Micro-SD card (connected into slot or pulled out to the left)
    const sd_card_name = look.sd_card_name orelse "";
    const show_sd_warning = !status.sd_connected and (status.power_connected or look.hovered == .power);
    for (b.parts) |part| {
        if (part.kind == .micro_sd) {
            const hovered = (look.hovered == .sd_card) or (status.sd_connected and look.hovered == .sd_connector);
            const slot_r = map(tr, part.rect);
            drawSdCard(
                c,
                slot_r,
                tr.y + HubLayout.top_cable_min_y * s,
                max_y,
                s,
                if (hovered) t.primary else ink,
                t.primary,
                t.surface,
                status.sd_connected,
                hovered,
                sd_card_name,
                look.sd_card_name != null,
            );
            if (show_sd_warning) {
                drawSdSocketWarning(c, slot_r, s, part.underside);
            }
        }
    }

    // 2. USB peripherals:
    //    - On Zero / A+ boards (`hl.has_external_hub`): external 3-port USB Hub with Ethernet
    //    - On B boards (`!hl.has_external_hub`): direct USB Keyboard, USB Mouse, and Ethernet plugs on the board's sockets
    if (hl.has_external_hub) {
        for (b.parts) |part| {
            if (part.kind == .usb_otg or (part.kind == .usb and part.faces == .right)) {
                drawUsbHubAndPeripherals(
                    c,
                    tr.x,
                    tr.y,
                    s,
                    map(tr, part.rect),
                    hl,
                    ink,
                    t.primary,
                    t.surface,
                    status,
                    look.hovered,
                );
            }
        }
    } else {
        var direct_usb_idx: usize = 0;
        for (b.parts) |part| {
            if (part.kind == .usb_double) {
                const idx = direct_usb_idx;
                direct_usb_idx += 1;
                const is_kbd = (idx == 0);
                const hovered = (look.hovered == if (is_kbd) InteractiveTarget.usb_keyboard else InteractiveTarget.usb_mouse);
                drawRightPlugAndCable(
                    c,
                    map(tr, part.rect),
                    max_x,
                    s,
                    if (hovered) t.primary else ink,
                    t.primary,
                    t.surface,
                    if (is_kbd) .keyboard else .mouse,
                    if (is_kbd) status.usb_keyboard_connected else status.usb_mouse_connected,
                    hovered,
                );
            } else if (part.kind == .ethernet) {
                const hovered = (look.hovered == .ethernet);
                drawRightPlugAndCable(
                    c,
                    map(tr, part.rect),
                    max_x,
                    s,
                    if (hovered) t.primary else ink,
                    t.primary,
                    t.surface,
                    .lan,
                    status.ethernet_connected,
                    hovered,
                );
            }
        }
    }

    // 3. HDMI, Power, and 3.5 mm Audio cables & plugs on the bottom edge
    for (b.parts) |part| {
        const is_hdmi = (part.kind == .mini_hdmi or part.kind == .hdmi);
        const is_power = (part.kind == .power);
        const is_audio = (part.kind == .audio);
        if (is_hdmi or is_power or is_audio) {
            const hovered = if (is_power)
                (look.hovered == .power)
            else if (is_audio)
                (look.hovered == .audio)
            else
                (look.hovered == .hdmi);
            const icon: Icon = if (is_power) .bolt else if (is_audio) .headphones else .monitor;
            const connected = if (is_power)
                status.power_connected
            else if (is_audio)
                status.audio_connected
            else
                status.hdmi_connected;
            drawBottomCable(
                c,
                &part,
                map(tr, part.rect),
                max_y,
                s,
                if (hovered) t.primary else ink,
                t.primary,
                t.surface,
                icon,
                connected,
                hovered,
            );
        }
    }
}

fn partOverhangsBoard(b: *const board.Board, part: *const board.Part) bool {
    if (part.underside) return false;
    const r = part.rect;
    return r.x < 0 or r.y < 0 or (r.x + r.w) > b.width or (r.y + r.h) > b.height;
}

fn partRadius(part: *const board.Part, s: f32) Radii {
    return switch (part.kind) {
        .usb, .usb_double, .ethernet, .hdmi, .mini_hdmi, .power, .usb_otg, .micro_sd => .all(0.4 * s),
        .antenna, .camera, .display => .all(0.3 * s),
        else => .all(0.6 * s),
    };
}

fn fillOverhangingPart(c: *Canvas, part: *const board.Part, r: Rect, s: f32, surface_bg: Color, board_tint: Color) void {
    const rad = partRadius(part, s);
    c.fillRoundedRect(r, rad, surface_bg);
    c.fillRoundedRect(r, rad, board_tint);
}

/// Draws a single board part.
pub fn drawPart(c: *Canvas, part: *const board.Part, r: Rect, s: f32, ink: Color) void {
    const radius: Radii = .all(0.6 * s);
    switch (part.kind) {
        .soc, .soc_with_ram, .ram, .usb_ethernet, .wireless, .pmic => {
            c.strokeRoundedRect(r, radius, heavy_w, ink);
            if (part.lidded) {
                c.strokeRoundedRect(r.outset(-1.2 * s), radius, line_w, ink);
            } else if (r.w > 3 * s) {
                c.fillCircle(.{ r.x + 1.4 * s, r.y + 1.4 * s }, @max(1.0, 0.4 * s), ink);
            }
        },
        .wireless_can => {
            c.strokeRoundedRect(r, radius, line_w, ink);
            c.strokeRoundedRect(r.outset(-1.0 * s), radius, line_w, ink.withAlpha(ink.a * 0.5));
        },
        .antenna => c.strokeRoundedRect(r, .all(0.3 * s), line_w, ink),
        .gpio, .gpio_holes => {
            if (part.kind == .gpio) c.strokeRect(r, line_w, ink);
            const pitch = 2.54 * s;
            for (0..part.pins[1]) |row| for (0..part.pins[0]) |col| {
                const center: Point = .{
                    r.x + (@as(f32, @floatFromInt(col)) + 0.5) * pitch,
                    r.y + (@as(f32, @floatFromInt(row)) + 0.5) * pitch,
                };
                if (part.kind == .gpio)
                    c.fillCircle(center, @max(0.75, 0.35 * s), ink)
                else
                    c.strokeCircle(center, @max(1.0, 0.6 * s), line_w, ink);
            };
        },
        .usb, .usb_double, .ethernet, .hdmi, .mini_hdmi, .power, .usb_otg, .micro_sd => {
            c.strokeRoundedRect(r, .all(0.4 * s), line_w, ink);
            const e = part.faces orelse return;
            const ports: usize = if (part.kind == .usb_double) 2 else 1;
            const depth = switch (part.kind) {
                .ethernet, .usb, .usb_double => 3.0 * s,
                else => 1.2 * s,
            };
            for (0..ports) |i| {
                const f: f32 = @floatFromInt(i);
                const across: f32 = @floatFromInt(ports);
                const slot: Rect = switch (e) {
                    .left, .right => .{
                        .x = if (e == .right) r.x + r.w - depth - 0.8 * s else r.x + 0.8 * s,
                        .y = r.y + r.h * (0.2 + f) / across,
                        .w = depth,
                        .h = r.h * 0.6 / across,
                    },
                    .top, .bottom => .{
                        .x = r.x + r.w * 0.2,
                        .y = if (e == .bottom) r.y + r.h - depth - 0.8 * s else r.y + 0.8 * s,
                        .w = r.w * 0.6,
                        .h = depth,
                    },
                };
                c.strokeRect(slot, line_w, ink);
            }
        },
        .audio => {
            c.strokeRoundedRect(r, .all(0.6 * s), line_w, ink);
            const e = part.faces orelse return;
            const center: Point = switch (e) {
                .bottom => .{ r.x + r.w * 0.5, r.y + r.h - 2.0 * s },
                .top => .{ r.x + r.w * 0.5, r.y + 2.0 * s },
                .left => .{ r.x + 2.0 * s, r.y + r.h * 0.5 },
                .right => .{ r.x + r.w - 2.0 * s, r.y + r.h * 0.5 },
            };
            c.strokeCircle(center, 1.2 * s, line_w, ink);
        },
        .camera, .display => {
            c.strokeRoundedRect(r, .all(0.3 * s), line_w, ink);
            const slot: Rect = if (r.w > r.h)
                .{ .x = r.x + 1.2 * s, .y = r.y + r.h * 0.35, .w = r.w - 2.4 * s, .h = r.h * 0.3 }
            else
                .{ .x = r.x + r.w * 0.35, .y = r.y + 1.2 * s, .w = r.w * 0.3, .h = r.h - 2.4 * s };
            c.fillRect(slot, ink);
        },
        .act_led, .pwr_led => {
            c.strokeRoundedRect(r, .all(0.25 * s), line_w, ink);
            const lens: Rect = .{
                .x = r.x + r.w * 0.25,
                .y = r.y + r.h * 0.2,
                .w = r.w * 0.5,
                .h = r.h * 0.6,
            };
            c.strokeRoundedRect(lens, .all(0.15 * s), line_w, ink.withAlpha(0.75));
        },
    }
}

/// Draws the micro-SD card on a left-facing SD slot:
/// - When `connected` is true: the card is seated inside the slot with its left tab protruding slightly.
/// - When `connected` is false: the card is pulled out to the left of the slot with a gap and exposed contact pins.
/// - When `card_name` is non-empty: draws the active image/card name rotated 90 degrees CCW along the left edge of the card.
pub fn drawSdCard(
    c: *Canvas,
    slot_r: Rect,
    min_y: f32,
    max_y: f32,
    s: f32,
    ink: Color,
    accent: Color,
    surface_bg: Color,
    connected: bool,
    hovered: bool,
    card_name: []const u8,
    /// Whether there is a card image to insert; without one the card is a dashed outline.
    available: bool,
) void {
    const cy = slot_r.y + slot_r.h * 0.5;
    const card_h = slot_r.h * 0.80;
    const card_y = cy - card_h * 0.5;
    const protrude_w = 4.2 * s;
    const gap = 2.8 * s;
    const card_w = 13.0 * s;
    const card_left_x = if (connected) (slot_r.x - protrude_w) else (slot_r.x - gap - card_w);

    if (connected) {
        // Seated inside the slot: draw protruding left tab and subtle outline inside cage
        const tab_rect: Rect = .{
            .x = slot_r.x - protrude_w,
            .y = card_y,
            .w = protrude_w + 0.2 * s,
            .h = card_h,
        };
        const radii: Radii = .{ .tl = 0.8 * s, .bl = 0.8 * s, .tr = 0, .br = 0 };
        c.fillRoundedRect(tab_rect, radii, surface_bg);
        c.fillRoundedRect(tab_rect, radii, if (hovered) accent.withAlpha(0.28) else ink.withAlpha(0.10));
        c.strokeRoundedRect(tab_rect, radii, heavy_w, ink);

        // Raised fingernail lip on left edge of micro-SD card
        const lip_h = card_h * 0.62;
        c.fillRect(.{
            .x = tab_rect.x + 1.2 * s,
            .y = cy - lip_h * 0.5,
            .w = line_w,
            .h = lip_h,
        }, ink.withAlpha(0.75));

        // Faint outline of card body inside the metal slot cage
        const inner_rect: Rect = .{
            .x = slot_r.x + 0.4 * s,
            .y = card_y + 0.6 * s,
            .w = slot_r.w - 2.0 * s,
            .h = card_h - 1.2 * s,
        };
        c.strokeRoundedRect(inner_rect, .{ .tl = 0, .bl = 0, .tr = 0.5 * s, .br = 0.5 * s }, line_w, ink.withAlpha(0.35));
    } else {
        // Pulled out to the left of the slot with exposed contact pads
        const card_rect: Rect = .{
            .x = slot_r.x - gap - card_w,
            .y = card_y,
            .w = card_w,
            .h = card_h,
        };
        const radii: Radii = .{ .tl = 0.8 * s, .bl = 0.8 * s, .tr = 0.4 * s, .br = 0.4 * s };
        c.fillRoundedRect(card_rect, radii, surface_bg);
        c.fillRoundedRect(card_rect, radii, if (hovered) accent.withAlpha(0.28) else ink.withAlpha(0.08));
        if (available) {
            c.strokeRoundedRect(card_rect, radii, heavy_w, ink);
        } else {
            c.strokeDashedRect(card_rect, heavy_w, 1.0 * s, ink);
        }

        // Exposed contact pads along the right edge facing the slot
        const pad_w = 2.2 * s;
        const pad_h = @max(1.0, 0.7 * s);
        const pad_x = card_rect.x + card_rect.w - pad_w - 0.8 * s;
        for (0..6) |i| {
            const frac = (@as(f32, @floatFromInt(i)) + 0.5) / 6.0;
            const py = card_rect.y + card_h * (0.14 + frac * 0.72) - pad_h * 0.5;
            c.fillRect(.{ .x = pad_x, .y = py, .w = pad_w, .h = pad_h }, ink.withAlpha(0.75));
        }

        // Raised fingernail lip near the left edge
        const lip_h = card_h * 0.62;
        c.fillRect(.{
            .x = card_rect.x + 1.3 * s,
            .y = cy - lip_h * 0.5,
            .w = line_w,
            .h = lip_h,
        }, ink.withAlpha(0.70));

        // "SD" label in the middle of the unplugged card
        const lbl = "SD";
        const font_sz = 2.8 * s;
        const tw = c.measureText(font_sz, lbl);
        _ = c.drawText(
            font_sz,
            card_rect.x + (card_w - pad_w - tw) * 0.5 + 0.4 * s,
            cy + font_sz * 0.36,
            lbl,
            ink,
        );
    }

    if (card_name.len > 0) {
        var name_sz = 2.6 * s;
        var name_w = c.measureText(name_sz, card_name);
        const avail_h = @max(8.0 * s, (max_y - min_y) - 2.0 * s);
        if (name_w > avail_h and name_w > 0) {
            name_sz = @max(1.6 * s, name_sz * (avail_h / name_w));
            name_w = c.measureText(name_sz, card_name);
        }
        const baseline_x = card_left_x - 1.3 * s;
        const start_y = std.math.clamp(
            cy + name_w * 0.5,
            min_y + 1.0 * s + name_w,
            max_y - 1.0 * s,
        );
        _ = c.drawTextRotated90(name_sz, baseline_x, start_y, card_name, ink);
    }
}

/// Draws a red exclamation mark over the SD card socket (`slot_r`) when the SD card is
/// disconnected and the user is hovering over the power cable or power is connected.
/// On boards with an underside microSD slot (`underside == true`), shifts right to clear the top-side DSI connector.
pub fn drawSdSocketWarning(c: *Canvas, slot_r: Rect, s: f32, underside: bool) void {
    const icon_sz = 8.0 * s;
    const dx: f32 = if (underside) 3.2 * s else 0.0;
    c.drawIcon(
        .priority_high,
        slot_r.x + (slot_r.w - icon_sz) * 0.5 + dx,
        slot_r.y + (slot_r.h - icon_sz) * 0.5,
        icon_sz,
        red,
    );
}

/// Draws a bottom-facing plug and straight vertical cable (used for Mini HDMI and Power).
pub fn drawBottomCable(
    c: *Canvas,
    part: *const board.Part,
    r: Rect,
    max_y: f32,
    s: f32,
    ink: Color,
    accent: Color,
    surface_bg: Color,
    icon: Icon,
    connected: bool,
    hovered: bool,
) void {
    const e = part.faces orelse return;
    if (e != .bottom) return;

    const cx = r.x + r.w * 0.5;
    const sock_bottom = r.y + r.h;

    const is_audio = (part.kind == .audio);
    const plug_w = r.w * 0.88;
    const plug_h = 5.4 * s;
    const tip_w = if (is_audio) (r.w * 0.30) else (r.w * 0.56);
    const tip_h = if (is_audio) (3.0 * s) else (2.4 * s);
    const boot_w = r.w * 0.42;
    const boot_h = 1.8 * s;
    const cable_w = r.w * 0.24;

    const gap: f32 = if (connected) 0.0 else 2.6 * s;
    const body_y = if (connected) sock_bottom + 0.2 * s else sock_bottom + gap + tip_h;

    if (!connected) {
        const tip_rect: Rect = .{
            .x = cx - tip_w * 0.5,
            .y = sock_bottom + gap,
            .w = tip_w,
            .h = tip_h,
        };
        const tip_r: f32 = if (is_audio) (tip_w * 0.5) else (0.3 * s);
        c.fillRoundedRect(tip_rect, .{ .tl = tip_r, .tr = tip_r, .br = 0, .bl = 0 }, surface_bg);
        if (hovered) {
            c.fillRoundedRect(tip_rect, .{ .tl = tip_r, .tr = tip_r, .br = 0, .bl = 0 }, accent.withAlpha(0.22));
        }
        c.strokeRoundedRect(tip_rect, .{ .tl = tip_r, .tr = tip_r, .br = 0, .bl = 0 }, line_w, ink);

        if (is_audio) {
            // Horizontal TRRS insulating rings on the 3.5 mm audio plug pin
            c.fillRect(.{ .x = tip_rect.x, .y = tip_rect.y + tip_h * 0.36, .w = tip_w, .h = line_w }, ink.withAlpha(0.75));
            c.fillRect(.{ .x = tip_rect.x, .y = tip_rect.y + tip_h * 0.68, .w = tip_w, .h = line_w }, ink.withAlpha(0.75));
        } else {
            const notch_h = @max(1.0, tip_h * 0.45);
            const notch_y = tip_rect.y + (tip_h - notch_h) * 0.5;
            c.fillRect(.{ .x = cx - tip_w * 0.22 - line_w * 0.5, .y = notch_y, .w = line_w, .h = notch_h }, ink.withAlpha(0.75));
            c.fillRect(.{ .x = cx + tip_w * 0.22 - line_w * 0.5, .y = notch_y, .w = line_w, .h = notch_h }, ink.withAlpha(0.75));
        }
    }

    const body_rect: Rect = .{
        .x = cx - plug_w * 0.5,
        .y = body_y,
        .w = plug_w,
        .h = plug_h,
    };
    const body_radii: Radii = .{
        .tl = if (connected) 0.2 * s else 0.6 * s,
        .tr = if (connected) 0.2 * s else 0.6 * s,
        .br = 1.0 * s,
        .bl = 1.0 * s,
    };
    c.fillRoundedRect(body_rect, body_radii, surface_bg);
    c.fillRoundedRect(body_rect, body_radii, if (hovered) accent.withAlpha(0.26) else ink.withAlpha(0.08));
    c.strokeRoundedRect(body_rect, body_radii, heavy_w, ink);

    const icon_sz = 3.5 * s;
    c.drawIcon(
        icon,
        body_rect.x + (body_rect.w - icon_sz) * 0.5,
        body_rect.y + (body_rect.h - icon_sz) * 0.5,
        icon_sz,
        ink,
    );

    const boot_y = body_rect.y + body_rect.h;
    if (boot_y + boot_h <= max_y) {
        const boot_rect: Rect = .{
            .x = cx - boot_w * 0.5,
            .y = boot_y,
            .w = boot_w,
            .h = boot_h,
        };
        c.fillRect(boot_rect, surface_bg);
        if (hovered) {
            c.fillRect(boot_rect, accent.withAlpha(0.20));
        }
        c.strokeRect(boot_rect, line_w, ink);
    }

    const cable_y = boot_y + boot_h;
    if (cable_y < max_y) {
        const cable_rect: Rect = .{
            .x = cx - cable_w * 0.5,
            .y = cable_y,
            .w = cable_w,
            .h = max_y - cable_y,
        };
        c.fillRect(cable_rect, surface_bg);
        c.fillRect(cable_rect, if (hovered) accent.withAlpha(0.22) else ink.withAlpha(0.14));
        c.fillRect(.{ .x = cable_rect.x, .y = cable_rect.y, .w = line_w, .h = cable_rect.h }, ink);
        c.fillRect(.{ .x = cable_rect.x + cable_rect.w - line_w, .y = cable_rect.y, .w = line_w, .h = cable_rect.h }, ink);
    }
}

/// Draws a top-facing plug and vertical cable extending upward (for Keyboard, Mouse, and Ethernet on the USB Hub).
fn drawTopPlugAndCable(
    c: *Canvas,
    port_r: Rect,
    min_y: f32,
    s: f32,
    ink: Color,
    accent: Color,
    surface_bg: Color,
    icon: Icon,
    connected: bool,
    hovered: bool,
) void {
    const cx = port_r.x + port_r.w * 0.5;
    const sock_top = port_r.y;

    const plug_w = port_r.w * 0.88;
    const plug_h = 5.4 * s;
    const tip_w = port_r.w * 0.58;
    const tip_h = 2.0 * s;
    const boot_w = port_r.w * 0.42;
    const boot_h = 1.5 * s;
    const cable_w = port_r.w * 0.24;

    const gap: f32 = if (connected) 0.0 else 2.2 * s;
    const body_y = if (connected) sock_top - 0.2 * s - plug_h else sock_top - gap - tip_h - plug_h;

    // Exposed metal USB-A / RJ45 connector tip below the plug body when disconnected
    if (!connected) {
        const tip_rect: Rect = .{
            .x = cx - tip_w * 0.5,
            .y = body_y + plug_h,
            .w = tip_w,
            .h = tip_h,
        };
        c.fillRoundedRect(tip_rect, .{ .tl = 0, .tr = 0, .br = 0.3 * s, .bl = 0.3 * s }, surface_bg);
        if (hovered) {
            c.fillRoundedRect(tip_rect, .{ .tl = 0, .tr = 0, .br = 0.3 * s, .bl = 0.3 * s }, accent.withAlpha(0.22));
        }
        c.strokeRoundedRect(tip_rect, .{ .tl = 0, .tr = 0, .br = 0.3 * s, .bl = 0.3 * s }, line_w, ink);

        const notch_h = @max(1.0, tip_h * 0.45);
        const notch_y = tip_rect.y + (tip_h - notch_h) * 0.5;
        c.fillRect(.{ .x = cx - tip_w * 0.22 - line_w * 0.5, .y = notch_y, .w = line_w, .h = notch_h }, ink.withAlpha(0.75));
        c.fillRect(.{ .x = cx + tip_w * 0.22 - line_w * 0.5, .y = notch_y, .w = line_w, .h = notch_h }, ink.withAlpha(0.75));
    }

    // Overmolded plug housing
    const body_rect: Rect = .{
        .x = cx - plug_w * 0.5,
        .y = body_y,
        .w = plug_w,
        .h = plug_h,
    };
    const body_radii: Radii = .{
        .tl = 1.0 * s,
        .tr = 1.0 * s,
        .br = if (connected) 0.2 * s else 0.6 * s,
        .bl = if (connected) 0.2 * s else 0.6 * s,
    };
    c.fillRoundedRect(body_rect, body_radii, surface_bg);
    c.fillRoundedRect(body_rect, body_radii, if (hovered) accent.withAlpha(0.26) else ink.withAlpha(0.08));
    c.strokeRoundedRect(body_rect, body_radii, heavy_w, ink);

    // Icon on the plug body (.keyboard, .mouse, .lan)
    const icon_sz = 3.5 * s;
    c.drawIcon(
        icon,
        body_rect.x + (body_rect.w - icon_sz) * 0.5,
        body_rect.y + (body_rect.h - icon_sz) * 0.5,
        icon_sz,
        ink,
    );

    // Strain relief boot above plug housing
    const boot_y = body_rect.y - boot_h;
    if (boot_y >= min_y) {
        const boot_rect: Rect = .{
            .x = cx - boot_w * 0.5,
            .y = boot_y,
            .w = boot_w,
            .h = boot_h,
        };
        c.fillRect(boot_rect, surface_bg);
        if (hovered) {
            c.fillRect(boot_rect, accent.withAlpha(0.20));
        }
        c.strokeRect(boot_rect, line_w, ink);
    }

    // Cable extending upward to min_y
    if (boot_y > min_y) {
        const cable_rect: Rect = .{
            .x = cx - cable_w * 0.5,
            .y = min_y,
            .w = cable_w,
            .h = boot_y - min_y,
        };
        c.fillRect(cable_rect, surface_bg);
        c.fillRect(cable_rect, if (hovered) accent.withAlpha(0.22) else ink.withAlpha(0.14));
        c.fillRect(.{ .x = cable_rect.x, .y = cable_rect.y, .w = line_w, .h = cable_rect.h }, ink);
        c.fillRect(.{ .x = cable_rect.x + cable_rect.w - line_w, .y = cable_rect.y, .w = line_w, .h = cable_rect.h }, ink);
    }
}

/// Draws a 90-degree curved cable bend using quadrant clipping and concentric circles.
fn drawCableBend90(
    c: *Canvas,
    center: Point,
    r_mid: f32,
    cable_w: f32,
    quadrant: enum { bottom_left, bottom_right },
    ink: Color,
    fill_tint: Color,
    surface_bg: Color,
) void {
    const r_out = r_mid + cable_w * 0.5;
    const r_in = @max(0.5, r_mid - cable_w * 0.5);
    const clip_rect: Rect = switch (quadrant) {
        .bottom_left => .{
            .x = center[0] - r_out - heavy_w,
            .y = center[1],
            .w = r_out + heavy_w,
            .h = r_out + heavy_w,
        },
        .bottom_right => .{
            .x = center[0],
            .y = center[1],
            .w = r_out + heavy_w,
            .h = r_out + heavy_w,
        },
    };
    const old_clip = c.clipTo(clip_rect);
    c.fillCircle(center, r_out, surface_bg);
    c.fillCircle(center, r_out, fill_tint);
    c.strokeCircle(center, r_out, line_w, ink);
    c.fillCircle(center, r_in, surface_bg);
    c.strokeCircle(center, r_in + line_w, line_w, ink);
    c.restoreClip(old_clip);
}

/// Draws a right-facing plug and horizontal cable extending rightward (used on B boards for direct
/// USB Keyboard, USB Mouse, and Ethernet connections, and on A+ boards for the USB Hub plug).
pub fn drawRightPlugAndCable(
    c: *Canvas,
    port_r: Rect,
    max_x: f32,
    s: f32,
    ink: Color,
    accent: Color,
    surface_bg: Color,
    icon: Icon,
    connected: bool,
    hovered: bool,
) void {
    const cy = port_r.y + port_r.h * 0.5;
    const sock_right = port_r.x + port_r.w;

    const plug_h = @min(port_r.h * 0.78, 10.2 * s);
    const plug_w = 5.4 * s;
    const tip_h = plug_h * 0.58;
    const tip_w = 2.2 * s;
    const boot_h = @min(plug_h * 0.42, 3.6 * s);
    const boot_w = 1.6 * s;
    const cable_h = @min(plug_h * 0.24, 2.0 * s);

    const gap: f32 = if (connected) 0.0 else 2.2 * s;
    const body_x = if (connected) sock_right + 0.2 * s else sock_right + gap + tip_w;

    // Exposed metal USB-A / RJ45 connector tip to the left of the plug body when disconnected
    if (!connected) {
        const tip_rect: Rect = .{
            .x = sock_right + gap,
            .y = cy - tip_h * 0.5,
            .w = tip_w,
            .h = tip_h,
        };
        c.fillRoundedRect(tip_rect, .{ .tl = 0.3 * s, .bl = 0.3 * s, .tr = 0, .br = 0 }, surface_bg);
        if (hovered) {
            c.fillRoundedRect(tip_rect, .{ .tl = 0.3 * s, .bl = 0.3 * s, .tr = 0, .br = 0 }, accent.withAlpha(0.22));
        }
        c.strokeRoundedRect(tip_rect, .{ .tl = 0.3 * s, .bl = 0.3 * s, .tr = 0, .br = 0 }, line_w, ink);

        const notch_w = @max(1.0, tip_w * 0.45);
        const notch_x = tip_rect.x + (tip_w - notch_w) * 0.5;
        c.fillRect(.{ .x = notch_x, .y = cy - tip_h * 0.22 - line_w * 0.5, .w = notch_w, .h = line_w }, ink.withAlpha(0.75));
        c.fillRect(.{ .x = notch_x, .y = cy + tip_h * 0.22 - line_w * 0.5, .w = notch_w, .h = line_w }, ink.withAlpha(0.75));
    }

    // Overmolded plug housing
    const body_rect: Rect = .{
        .x = body_x,
        .y = cy - plug_h * 0.5,
        .w = plug_w,
        .h = plug_h,
    };
    const body_radii: Radii = .{
        .tl = if (connected) 0.2 * s else 0.6 * s,
        .bl = if (connected) 0.2 * s else 0.6 * s,
        .tr = 1.0 * s,
        .br = 1.0 * s,
    };
    c.fillRoundedRect(body_rect, body_radii, surface_bg);
    c.fillRoundedRect(body_rect, body_radii, if (hovered) accent.withAlpha(0.26) else ink.withAlpha(0.08));
    c.strokeRoundedRect(body_rect, body_radii, heavy_w, ink);

    const icon_sz = 3.5 * s;
    c.drawIcon(
        icon,
        body_rect.x + (body_rect.w - icon_sz) * 0.5,
        body_rect.y + (body_rect.h - icon_sz) * 0.5,
        icon_sz,
        ink,
    );

    const boot_x = body_rect.x + body_rect.w;
    if (boot_x + boot_w <= max_x) {
        const boot_rect: Rect = .{
            .x = boot_x,
            .y = cy - boot_h * 0.5,
            .w = boot_w,
            .h = boot_h,
        };
        c.fillRect(boot_rect, surface_bg);
        if (hovered) {
            c.fillRect(boot_rect, accent.withAlpha(0.20));
        }
        c.strokeRect(boot_rect, line_w, ink);
    }

    const cable_x = boot_x + boot_w;
    if (cable_x < max_x) {
        const cable_rect: Rect = .{
            .x = cable_x,
            .y = cy - cable_h * 0.5,
            .w = max_x - cable_x,
            .h = cable_h,
        };
        c.fillRect(cable_rect, surface_bg);
        c.fillRect(cable_rect, if (hovered) accent.withAlpha(0.22) else ink.withAlpha(0.14));
        c.fillRect(.{ .x = cable_rect.x, .y = cable_rect.y, .w = cable_rect.w, .h = line_w }, ink);
        c.fillRect(.{ .x = cable_rect.x, .y = cable_rect.y + cable_rect.h - line_w, .w = cable_rect.w, .h = line_w }, ink);
    }
}

/// Draws the USB plug, connecting cable, the 3-port USB Hub with Ethernet,
/// and the Keyboard, Mouse, and Ethernet plugs/cables plugged into the top of the hub.
fn drawUsbHubAndPeripherals(
    c: *Canvas,
    tx: f32,
    ty: f32,
    s: f32,
    otg_r: Rect,
    hl: HubLayout.BoardHubLayout,
    ink: Color,
    accent: Color,
    surface_bg: Color,
    status: SystemStatus,
    hovered_target: ?InteractiveTarget,
) void {
    const hub_hovered = (hovered_target == .usb_hub);
    const hub_ink = if (hub_hovered) accent else ink;
    const hub_tint = if (hub_hovered) accent.withAlpha(0.22) else ink.withAlpha(0.14);

    const hub_r: Rect = .{
        .x = tx + hl.hub_rect.x * s,
        .y = ty + hl.hub_rect.y * s,
        .w = hl.hub_rect.w * s,
        .h = hl.hub_rect.h * s,
    };

    if (hl.right_usb_plug) {
        // Right-facing USB-A port on A+ boards: plug into right edge and run cable horizontally into left side of Hub
        const boot_w = 1.6 * s;
        const boot_h = 3.6 * s;
        const cy = otg_r.y + otg_r.h * 0.5;
        drawRightPlugAndCable(
            c,
            otg_r,
            hub_r.x - boot_w,
            s,
            hub_ink,
            accent,
            surface_bg,
            .usb,
            status.usb_hub_connected,
            hub_hovered,
        );
        const hub_left_boot: Rect = .{
            .x = hub_r.x - boot_w,
            .y = cy - boot_h * 0.5,
            .w = boot_w,
            .h = boot_h,
        };
        c.fillRect(hub_left_boot, surface_bg);
        if (hub_hovered) {
            c.fillRect(hub_left_boot, accent.withAlpha(0.20));
        }
        c.strokeRect(hub_left_boot, line_w, hub_ink);
    } else {
        // 1. USB OTG micro-USB plug below the Pi Zero's USB OTG socket
        const otg_cx = otg_r.x + otg_r.w * 0.5;
        const sock_bottom = otg_r.y + otg_r.h;
        const plug_w = otg_r.w * 0.88;
        const plug_h = 5.4 * s;
        const tip_w = otg_r.w * 0.56;
        const tip_h = 2.2 * s;
        const boot_w = otg_r.w * 0.42;
        const boot_h = 1.6 * s;
        const cable_w = otg_r.w * 0.24;

        const gap: f32 = if (status.usb_hub_connected) 0.0 else 2.2 * s;
        const body_y = if (status.usb_hub_connected) sock_bottom + 0.2 * s else sock_bottom + gap + tip_h;

        if (!status.usb_hub_connected) {
            const tip_rect: Rect = .{
                .x = otg_cx - tip_w * 0.5,
                .y = sock_bottom + gap,
                .w = tip_w,
                .h = tip_h,
            };
            c.fillRoundedRect(tip_rect, .{ .tl = 0.3 * s, .tr = 0.3 * s, .br = 0, .bl = 0 }, surface_bg);
            if (hub_hovered) {
                c.fillRoundedRect(tip_rect, .{ .tl = 0.3 * s, .tr = 0.3 * s, .br = 0, .bl = 0 }, accent.withAlpha(0.22));
            }
            c.strokeRoundedRect(tip_rect, .{ .tl = 0.3 * s, .tr = 0.3 * s, .br = 0, .bl = 0 }, line_w, hub_ink);

            const notch_h = @max(1.0, tip_h * 0.45);
            const notch_y = tip_rect.y + (tip_h - notch_h) * 0.5;
            c.fillRect(.{ .x = otg_cx - tip_w * 0.22 - line_w * 0.5, .y = notch_y, .w = line_w, .h = notch_h }, hub_ink.withAlpha(0.75));
            c.fillRect(.{ .x = otg_cx + tip_w * 0.22 - line_w * 0.5, .y = notch_y, .w = line_w, .h = notch_h }, hub_ink.withAlpha(0.75));
        }

        const body_rect: Rect = .{
            .x = otg_cx - plug_w * 0.5,
            .y = body_y,
            .w = plug_w,
            .h = plug_h,
        };
        const body_radii: Radii = .{
            .tl = if (status.usb_hub_connected) 0.2 * s else 0.6 * s,
            .tr = if (status.usb_hub_connected) 0.2 * s else 0.6 * s,
            .br = 1.0 * s,
            .bl = 1.0 * s,
        };
        c.fillRoundedRect(body_rect, body_radii, surface_bg);
        c.fillRoundedRect(body_rect, body_radii, if (hub_hovered) accent.withAlpha(0.26) else ink.withAlpha(0.08));
        c.strokeRoundedRect(body_rect, body_radii, heavy_w, hub_ink);

        const otg_icon_sz = 3.5 * s;
        c.drawIcon(
            .usb,
            body_rect.x + (body_rect.w - otg_icon_sz) * 0.5,
            body_rect.y + (body_rect.h - otg_icon_sz) * 0.5,
            otg_icon_sz,
            hub_ink,
        );

        const boot_y = body_rect.y + body_rect.h;
        const boot_rect: Rect = .{
            .x = otg_cx - boot_w * 0.5,
            .y = boot_y,
            .w = boot_w,
            .h = boot_h,
        };
        c.fillRect(boot_rect, surface_bg);
        if (hub_hovered) {
            c.fillRect(boot_rect, accent.withAlpha(0.20));
        }
        c.strokeRect(boot_rect, line_w, hub_ink);

        // 2. Curved USB cable: down from boot, 90° curve right, horizontal run, 90° curve up into the USB Hub
        const r_turn = HubLayout.usb_cable_turn_r * s;
        const y_horiz = ty + HubLayout.usb_cable_horiz_y * s;
        const y_turn = y_horiz - r_turn;
        const hub_cable_x = tx + HubLayout.hub_cable_x * s;
        const hub_boot_rect: Rect = .{
            .x = hub_cable_x - boot_w * 0.5,
            .y = hub_r.y + hub_r.h,
            .w = boot_w,
            .h = boot_h,
        };

        // Vertical drop below USB OTG boot down to y_turn
        const drop_start_y = boot_y + boot_h;
        if (y_turn > drop_start_y) {
            const seg1: Rect = .{
                .x = otg_cx - cable_w * 0.5,
                .y = drop_start_y,
                .w = cable_w,
                .h = y_turn - drop_start_y,
            };
            c.fillRect(seg1, surface_bg);
            c.fillRect(seg1, hub_tint);
            c.fillRect(.{ .x = seg1.x, .y = seg1.y, .w = line_w, .h = seg1.h }, hub_ink);
            c.fillRect(.{ .x = seg1.x + seg1.w - line_w, .y = seg1.y, .w = line_w, .h = seg1.h }, hub_ink);
        }

        // 90° bend from vertical (going down) to horizontal (going right)
        const turn1_cx = otg_cx + r_turn;
        drawCableBend90(c, .{ turn1_cx, y_turn }, r_turn, cable_w, .bottom_left, hub_ink, hub_tint, surface_bg);

        // Horizontal segment going right
        const turn2_cx = hub_cable_x - r_turn;
        if (turn2_cx > turn1_cx) {
            const seg2: Rect = .{
                .x = turn1_cx,
                .y = y_horiz - cable_w * 0.5,
                .w = turn2_cx - turn1_cx,
                .h = cable_w,
            };
            c.fillRect(seg2, surface_bg);
            c.fillRect(seg2, hub_tint);
            c.fillRect(.{ .x = seg2.x, .y = seg2.y, .w = seg2.w, .h = line_w }, hub_ink);
            c.fillRect(.{ .x = seg2.x, .y = seg2.y + seg2.h - line_w, .w = seg2.w, .h = line_w }, hub_ink);
        }

        // 90° bend from horizontal (going right) to vertical (going up)
        drawCableBend90(c, .{ turn2_cx, y_turn }, r_turn, cable_w, .bottom_right, hub_ink, hub_tint, surface_bg);

        // Vertical segment going up into the bottom of the USB Hub
        const up_top_y = hub_boot_rect.y + hub_boot_rect.h;
        if (y_turn > up_top_y) {
            const seg3: Rect = .{
                .x = hub_cable_x - cable_w * 0.5,
                .y = up_top_y,
                .w = cable_w,
                .h = y_turn - up_top_y,
            };
            c.fillRect(seg3, surface_bg);
            c.fillRect(seg3, hub_tint);
            c.fillRect(.{ .x = seg3.x, .y = seg3.y, .w = line_w, .h = seg3.h }, hub_ink);
            c.fillRect(.{ .x = seg3.x + seg3.w - line_w, .y = seg3.y, .w = line_w, .h = seg3.h }, hub_ink);
        }

        // Hub bottom strain-relief boot
        c.fillRect(hub_boot_rect, surface_bg);
        if (hub_hovered) {
            c.fillRect(hub_boot_rect, accent.withAlpha(0.20));
        }
        c.strokeRect(hub_boot_rect, line_w, hub_ink);
    }

    // 3. Three-Port USB Hub with Ethernet body (not highlighted when hovering USB hub cable/plug)
    c.fillRoundedRect(hub_r, .all(2.2 * s), surface_bg);
    c.fillRoundedRect(hub_r, .all(2.2 * s), ink.withAlpha(0.05));
    c.strokeRoundedRect(hub_r, .all(2.2 * s), heavy_w, ink);

    // Draw the 3 USB-A ports and 1 RJ45 Ethernet port along the top edge of the hub
    const ports = [_]struct { rect: board.Rect, target: ?InteractiveTarget, is_eth: bool }{
        .{ .rect = hl.kbd_port_rect, .target = .usb_keyboard, .is_eth = false },
        .{ .rect = hl.mouse_port_rect, .target = .usb_mouse, .is_eth = false },
        .{ .rect = hl.spare_port_rect, .target = null, .is_eth = false },
        .{ .rect = hl.eth_port_rect, .target = .ethernet, .is_eth = true },
    };
    for (ports) |p| {
        const pr: Rect = .{
            .x = tx + p.rect.x * s,
            .y = ty + p.rect.y * s,
            .w = p.rect.w * s,
            .h = p.rect.h * s,
        };
        const p_hovered = (p.target != null and hovered_target == p.target);
        const p_ink = if (p_hovered) accent else ink;
        if (p_hovered) {
            c.fillRoundedRect(pr, .all(0.4 * s), accent.withAlpha(0.22));
        }
        c.strokeRoundedRect(pr, .all(0.4 * s), line_w, p_ink);
        const depth = (if (p.is_eth) @as(f32, 2.2) else @as(f32, 1.4)) * s;
        const slot: Rect = .{
            .x = pr.x + pr.w * 0.2,
            .y = pr.y + 0.8 * s,
            .w = pr.w * 0.6,
            .h = depth,
        };
        c.strokeRect(slot, line_w, p_ink);
    }

    // 4. Downstream plugs & cables plugged into the top of the USB Hub (Keyboard, Mouse, Ethernet)
    const min_y = ty + HubLayout.top_cable_min_y * s;

    const kbd_r: Rect = .{
        .x = tx + hl.kbd_port_rect.x * s,
        .y = ty + hl.kbd_port_rect.y * s,
        .w = hl.kbd_port_rect.w * s,
        .h = hl.kbd_port_rect.h * s,
    };
    const kbd_hov = (hovered_target == .usb_keyboard);
    drawTopPlugAndCable(
        c,
        kbd_r,
        min_y,
        s,
        if (kbd_hov) accent else ink,
        accent,
        surface_bg,
        .keyboard,
        status.usb_keyboard_connected,
        kbd_hov,
    );

    const mouse_r: Rect = .{
        .x = tx + hl.mouse_port_rect.x * s,
        .y = ty + hl.mouse_port_rect.y * s,
        .w = hl.mouse_port_rect.w * s,
        .h = hl.mouse_port_rect.h * s,
    };
    const mouse_hov = (hovered_target == .usb_mouse);
    drawTopPlugAndCable(
        c,
        mouse_r,
        min_y,
        s,
        if (mouse_hov) accent else ink,
        accent,
        surface_bg,
        .mouse,
        status.usb_mouse_connected,
        mouse_hov,
    );

    const eth_r: Rect = .{
        .x = tx + hl.eth_port_rect.x * s,
        .y = ty + hl.eth_port_rect.y * s,
        .w = hl.eth_port_rect.w * s,
        .h = hl.eth_port_rect.h * s,
    };
    const eth_hov = (hovered_target == .ethernet);
    drawTopPlugAndCable(
        c,
        eth_r,
        min_y,
        s,
        if (eth_hov) accent else ink,
        accent,
        surface_bg,
        .lan,
        status.ethernet_connected,
        eth_hov,
    );
}

/// Draws the 40-pin GPIO IDC ribbon cable and connector above/on the GPIO header.
/// When `connected` is true, the IDC connector sits over the 40-pin GPIO header with the flat
/// ribbon cable extending up to `min_y`. When `connected` is false, the IDC connector is pulled
/// up above the top edge of the board with a visible gap above the GPIO pins.
pub fn drawGpioRibbonCable(
    c: *Canvas,
    gpio_r: Rect,
    min_y: f32,
    s: f32,
    ink: Color,
    accent: Color,
    surface_bg: Color,
    connected: bool,
    hovered: bool,
) void {
    const conn_r: Rect = if (connected)
        gpio_r.outset(0.35 * s)
    else
        .{
            .x = gpio_r.x - 0.35 * s,
            .y = gpio_r.y - 7.8 * s,
            .w = gpio_r.w + 0.7 * s,
            .h = gpio_r.h,
        };

    const ribbon_x = gpio_r.x + 0.8 * s;
    const ribbon_w = gpio_r.w - 1.6 * s;
    const ribbon_bottom = conn_r.y;
    if (ribbon_bottom > min_y and ribbon_w > 2.0) {
        const rib_r: Rect = .{
            .x = ribbon_x,
            .y = min_y,
            .w = ribbon_w,
            .h = ribbon_bottom - min_y,
        };
        c.fillRect(rib_r, surface_bg);
        c.fillRect(rib_r, if (hovered) accent.withAlpha(0.20) else ink.withAlpha(0.12));

        // Vertical conductor grooves across the flat ribbon cable
        const grooves: usize = 19;
        for (1..grooves) |gi| {
            const gx = rib_r.x + (rib_r.w * @as(f32, @floatFromInt(gi))) / @as(f32, @floatFromInt(grooves));
            c.fillRect(.{ .x = gx, .y = rib_r.y, .w = 1.0, .h = rib_r.h }, ink.withAlpha(0.28));
        }

        // Left and right outer edges of the ribbon cable
        c.fillRect(.{ .x = rib_r.x, .y = rib_r.y, .w = line_w, .h = rib_r.h }, ink);
        c.fillRect(.{ .x = rib_r.x + rib_r.w - line_w, .y = rib_r.y, .w = line_w, .h = rib_r.h }, ink);
    }

    // IDC 40-pin connector housing with strain-relief clamp bar and center polarizing key
    const rad: Radii = .all(0.7 * s);
    c.fillRoundedRect(conn_r, rad, surface_bg);
    c.fillRoundedRect(conn_r, rad, if (hovered) accent.withAlpha(0.28) else ink.withAlpha(0.18));
    c.strokeRoundedRect(conn_r, rad, heavy_w, ink);

    // Strain-relief bar running horizontally across the middle of the IDC housing
    const bar_h = @max(1.5, conn_r.h * 0.34);
    const bar_r: Rect = .{
        .x = conn_r.x + 1.0 * s,
        .y = conn_r.y + (conn_r.h - bar_h) * 0.5,
        .w = conn_r.w - 2.0 * s,
        .h = bar_h,
    };
    c.strokeRoundedRect(bar_r, .all(0.3 * s), line_w, ink.withAlpha(0.85));

    // Polarizing center tab on top of the IDC housing
    const key_w = @min(6.0 * s, conn_r.w * 0.14);
    const key_h = @max(1.2, 1.1 * s);
    const key_r: Rect = .{
        .x = conn_r.x + (conn_r.w - key_w) * 0.5,
        .y = conn_r.y,
        .w = key_w,
        .h = key_h,
    };
    c.fillRect(key_r, ink.withAlpha(0.45));
}

test "every board offers its connectors, and what is plugged into them" {
    for (board.BoardModel.all) |model| {
        const b = model.drawing();
        const r = boardBoundsWithPeripherals(b);
        var found: std.EnumSet(InteractiveTarget) = .empty;
        var y = r.y;
        while (y < r.y + r.h) : (y += 0.5) {
            var x = r.x;
            while (x < r.x + r.w) : (x += 0.5) {
                if (targetAt(b, .{ x, y }, false)) |t| found.insert(t);
            }
        }
        for ([_]InteractiveTarget{ .sd_connector, .sd_card, .gpio, .hdmi, .power, .usb_keyboard, .usb_mouse, .ethernet, .cpu }) |t| {
            if (!found.contains(t)) {
                std.debug.print("{s} has no {s}\n", .{ @tagName(model), @tagName(t) });
                return error.TestUnexpectedResult;
            }
        }
        // A hub is plugged into boards without their own USB ports.
        try std.testing.expectEqual(HubLayout.forBoard(b).has_external_hub, found.contains(.usb_hub));
    }
}
