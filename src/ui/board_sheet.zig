//! Client-side Wayland window TitleBar (`44px` tall) and the drop-down
//! Interactive Board Sheet (`BoardSheet`), where each connector and peripheral
//! (Micro-SD card, Mini HDMI, Power, 3-port USB Hub with Ethernet, USB Keyboard,
//! USB Mouse, and Ethernet) is rendered visually and acts as a toggle button.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const board = @import("board.zig");
const soc_gpio = @import("../soc/gpio.zig");

pub const Canvas = canvas_mod.Canvas;
pub const Color = canvas_mod.Color;
pub const Rect = canvas_mod.Rect;
pub const Radii = canvas_mod.Radii;
pub const Point = canvas_mod.Point;
pub const Icon = canvas_mod.Icon;
pub const Theme = canvas_mod.Theme;
pub const Font = canvas_mod.Font;
pub const GlyphCache = canvas_mod.GlyphCache;
pub const Gpio = soc_gpio.Gpio;

/// Status colours.
const red: Color = .rgb(0xe53935);
const orange: Color = .rgb(0xfb8c00);

/// Line widths from `dazzle/src/apps/settings/board_view.zig`.
const line_w: f32 = 1.25;
const heavy_w: f32 = 1.75;

pub const SystemStatus = struct {
    model: []const u8 = "Raspberry Pi Zero Rev 1.3",
    serial: []const u8 = "0000000012345678",
    cpu_busy_percent: f32 = 0.0,
    temperature_c: f32 = 42.0,
    mem_total_mb: u32 = 512,
    hdmi_width: u16 = 1280,
    hdmi_height: u16 = 720,
    hdmi_connected: bool = true,
    hdmi_active: bool = false,
    power_connected: bool = false,
    sd_connected: bool = false,
    usb_hub_connected: bool = true,
    usb_keyboard_connected: bool = true,
    usb_mouse_connected: bool = true,
    ethernet_connected: bool = true,
};

pub const Action = enum {
    none,
    consumed,
    start_drag,
    toggle_maximize,
    toggle_hdmi,
    toggle_power,
    toggle_sd,
    select_sd_image,
    toggle_usb_hub,
    toggle_usb_keyboard,
    toggle_usb_mouse,
    toggle_ethernet,
    close,
};

pub const InteractiveTarget = enum {
    sd_connector,
    sd_card,
    hdmi,
    power,
    usb_hub,
    usb_keyboard,
    usb_mouse,
    ethernet,
};

/// Geometry of the 3-port USB Hub with Ethernet and external cables in board millimetres (`mm`).
pub const HubLayout = struct {
    pub const sd_ext_left_mm: f32 = 17.5;
    pub const bottom_ext_mm: f32 = 18.0; // extends below y=30 to y=48

    pub const hub_rect: board.Rect = .{ .x = 73.0, .y = 14.0, .w = 50.0, .h = 16.0 };
    pub const kbd_port_rect: board.Rect = .{ .x = 75.2, .y = 14.0, .w = 8.6, .h = 5.2 };
    pub const mouse_port_rect: board.Rect = .{ .x = 85.8, .y = 14.0, .w = 8.6, .h = 5.2 };
    pub const spare_port_rect: board.Rect = .{ .x = 96.4, .y = 14.0, .w = 8.6, .h = 5.2 };
    pub const eth_port_rect: board.Rect = .{ .x = 108.6, .y = 14.0, .w = 11.6, .h = 6.8 };

    pub const top_cable_min_y: f32 = 0.0;
    pub const bottom_cable_max_y: f32 = 48.0;
    pub const usb_cable_horiz_y: f32 = 45.2;
    pub const usb_cable_turn_r: f32 = 3.5;
    pub const hub_cable_x: f32 = 98.0;
};

pub const BoardUi = struct {
    pub const title_bar_height: u32 = 44;
    pub const bar_btn_size: f32 = 34;

    gpa: std.mem.Allocator,
    font: Font,
    icon_font: Font,
    cache: GlyphCache,
    theme: Theme = Theme.dark,

    title: []const u8 = "Raspberry Pi Zero",
    maximized: bool = false,
    sheet_open: bool = true,

    /// Currently hovered connector/peripheral button in the board diagram.
    hovered_target: ?InteractiveTarget = null,

    /// Title bar button hover/press states.
    board_btn_hovered: bool = false,
    board_btn_pressed: bool = false,
    max_btn_hovered: bool = false,
    max_btn_pressed: bool = false,
    close_btn_hovered: bool = false,
    close_btn_pressed: bool = false,

    /// Last computed geometry for hit-testing.
    last_win_w: u32 = 1280,
    last_win_h: u32 = 764,
    sheet_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    board_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn init(gpa: std.mem.Allocator) !BoardUi {
        const font = try Font.init(canvas_mod.fira_ttf);
        const icon_font = try Font.init(canvas_mod.icons_ttf);
        return .{
            .gpa = gpa,
            .font = font,
            .icon_font = icon_font,
            .cache = GlyphCache.init(gpa),
        };
    }

    pub fn deinit(self: *BoardUi) void {
        self.cache.deinit();
    }

    fn boardBtnRect(self: *const BoardUi, win_w: u32) Rect {
        const w_f: f32 = @floatFromInt(win_w);
        const title_w = @import("../font/text.zig").measure(.{ .font = &self.font, .size = 22.0 }, self.title);
        const title_x = @round((w_f - title_w) * 0.5);
        return .{
            .x = @round(title_x + title_w + 8.0),
            .y = (44.0 - bar_btn_size) * 0.5,
            .w = bar_btn_size,
            .h = bar_btn_size,
        };
    }

    fn closeBtnRect(win_w: u32) Rect {
        const w: f32 = @floatFromInt(win_w);
        return .{ .x = w - 8.0 - bar_btn_size, .y = (44.0 - bar_btn_size) * 0.5, .w = bar_btn_size, .h = bar_btn_size };
    }

    fn maxBtnRect(win_w: u32) Rect {
        const w: f32 = @floatFromInt(win_w);
        return .{ .x = w - 8.0 - bar_btn_size - 4.0 - bar_btn_size, .y = (44.0 - bar_btn_size) * 0.5, .w = bar_btn_size, .h = bar_btn_size };
    }

    pub fn boardBoundsWithPeripherals(drawing: *const board.Board) board.Rect {
        var r = drawing.bounds();
        const x0 = @min(r.x, -HubLayout.sd_ext_left_mm);
        const y0 = @min(r.y, HubLayout.top_cable_min_y);
        const x1 = @max(r.x + r.w, HubLayout.hub_rect.x + HubLayout.hub_rect.w + 1.0);
        const y1 = @max(r.y + r.h, HubLayout.bottom_cable_max_y);
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
        // 1. Downstream ports & plugs on the 3-port USB Hub with Ethernet
        const kbd_hit: board.Rect = .{
            .x = HubLayout.kbd_port_rect.x,
            .y = HubLayout.top_cable_min_y,
            .w = HubLayout.kbd_port_rect.w,
            .h = (HubLayout.kbd_port_rect.y + HubLayout.kbd_port_rect.h) - HubLayout.top_cable_min_y,
        };
        if (rectContainsMm(kbd_hit, pt)) return .usb_keyboard;

        const mouse_hit: board.Rect = .{
            .x = HubLayout.mouse_port_rect.x,
            .y = HubLayout.top_cable_min_y,
            .w = HubLayout.mouse_port_rect.w,
            .h = (HubLayout.mouse_port_rect.y + HubLayout.mouse_port_rect.h) - HubLayout.top_cable_min_y,
        };
        if (rectContainsMm(mouse_hit, pt)) return .usb_mouse;

        const eth_hit: board.Rect = .{
            .x = HubLayout.eth_port_rect.x,
            .y = HubLayout.top_cable_min_y,
            .w = HubLayout.eth_port_rect.w,
            .h = (HubLayout.eth_port_rect.y + HubLayout.eth_port_rect.h) - HubLayout.top_cable_min_y,
        };
        if (rectContainsMm(eth_hit, pt)) return .ethernet;

        // 2. USB Hub body & its curved cable
        if (rectContainsMm(HubLayout.hub_rect, pt)) return .usb_hub;
        if (pt[0] >= 40.0 and pt[0] <= HubLayout.hub_cable_x + 3.0 and
            pt[1] >= 42.0 and pt[1] <= HubLayout.bottom_cable_max_y)
        {
            return .usb_hub;
        }
        if (pt[0] >= HubLayout.hub_cable_x - 3.0 and pt[0] <= HubLayout.hub_cable_x + 3.0 and
            pt[1] >= HubLayout.hub_rect.y + HubLayout.hub_rect.h and pt[1] <= HubLayout.usb_cable_horiz_y + 2.0)
        {
            return .usb_hub;
        }

        // 3. Connectors on the Raspberry Pi board itself (plus their plugs/cards)
        for (drawing.parts) |p| {
            switch (p.kind) {
                .micro_sd, .sd => {
                    const ext_w: f32 = if (sd_connected) 4.5 else HubLayout.sd_ext_left_mm;
                    const sd_card_hit: board.Rect = .{
                        .x = p.rect.x - ext_w,
                        .y = p.rect.y,
                        .w = ext_w,
                        .h = p.rect.h,
                    };
                    if (rectContainsMm(sd_card_hit, pt)) return .sd_card;
                    if (rectContainsMm(p.rect, pt)) return .sd_connector;
                },
                .mini_hdmi, .hdmi, .micro_hdmi => {
                    const hdmi_hit: board.Rect = .{
                        .x = p.rect.x,
                        .y = p.rect.y,
                        .w = p.rect.w,
                        .h = HubLayout.bottom_cable_max_y - p.rect.y,
                    };
                    if (rectContainsMm(hdmi_hit, pt)) return .hdmi;
                },
                .power, .usb_c_power => {
                    const pwr_hit: board.Rect = .{
                        .x = p.rect.x,
                        .y = p.rect.y,
                        .w = p.rect.w,
                        .h = HubLayout.bottom_cable_max_y - p.rect.y,
                    };
                    if (rectContainsMm(pwr_hit, pt)) return .power;
                },
                .usb_otg, .usb, .usb_double => {
                    const usb_hit: board.Rect = .{
                        .x = p.rect.x,
                        .y = p.rect.y,
                        .w = p.rect.w,
                        .h = HubLayout.bottom_cable_max_y - p.rect.y,
                    };
                    if (rectContainsMm(usb_hit, pt)) return .usb_hub;
                },
                else => {},
            }
        }
        return null;
    }

    /// Updates layout geometry for `(win_w, win_h)` so hit testing and painting match.
    pub fn updateLayout(self: *BoardUi, win_w: u32, win_h: u32, status: SystemStatus, _: *const Gpio) void {
        self.last_win_w = win_w;
        self.last_win_h = win_h;

        const w_f: f32 = @floatFromInt(win_w);
        const sheet_w = @min(@max(w_f - 32.0, 360.0), 740.0);
        const sheet_x = @round((w_f - sheet_w) * 0.5);
        const sheet_y: f32 = @floatFromInt(title_bar_height);
        const pad: f32 = 24.0;

        const drawing = board.forModel(status.model) orelse &board.pi_zero;
        const bounds = boardBoundsWithPeripherals(drawing);
        const max_bw: f32 = sheet_w - 2.0 * pad;
        const max_bh: f32 = 280.0;
        const bw = max_bw;
        const bh = @min(bw * bounds.h / bounds.w, max_bh);
        const actual_bw = bw * @min(1.0, bh / (bw * bounds.h / bounds.w));
        const board_x = @round(sheet_x + (sheet_w - actual_bw) * 0.5);

        const y: f32 = sheet_y + pad;
        self.board_rect = .{ .x = board_x, .y = y, .w = actual_bw, .h = bh };

        self.sheet_rect = .{
            .x = sheet_x,
            .y = sheet_y,
            .w = sheet_w,
            .h = bh + 2.0 * pad,
        };
    }

    /// Handles pointer motion at `(x, y)` in window coordinates.
    /// Returns true if the pointer is over the TitleBar or an open BoardSheet.
    pub fn pointerMotion(self: *BoardUi, x: f32, y: f32, status: SystemStatus, gpio_hw: *const Gpio) bool {
        self.updateLayout(self.last_win_w, self.last_win_h, status, gpio_hw);
        const pt: Point = .{ x, y };

        self.board_btn_hovered = self.boardBtnRect(self.last_win_w).contains(pt);
        self.max_btn_hovered = maxBtnRect(self.last_win_w).contains(pt);
        self.close_btn_hovered = closeBtnRect(self.last_win_w).contains(pt);

        if (!self.sheet_open) {
            self.hovered_target = null;
            return y < @as(f32, @floatFromInt(title_bar_height));
        }

        const drawing = board.forModel(status.model) orelse &board.pi_zero;
        if (self.board_rect.contains(pt)) {
            const tr = boardTransform(drawing, self.board_rect);
            self.hovered_target = targetAt(drawing, .{ (x - tr.x) / tr.scale, (y - tr.y) / tr.scale }, status.sd_connected);
        } else {
            self.hovered_target = null;
        }

        return true;
    }

    pub fn pointerLeave(self: *BoardUi) void {
        self.board_btn_hovered = false;
        self.board_btn_pressed = false;
        self.max_btn_hovered = false;
        self.max_btn_pressed = false;
        self.close_btn_hovered = false;
        self.close_btn_pressed = false;
        self.hovered_target = null;
    }

    /// Handles pointer button press/release at `(x, y)` in window coordinates.
    pub fn pointerButton(
        self: *BoardUi,
        x: f32,
        y: f32,
        pressed: bool,
        status: SystemStatus,
        gpio_hw: *Gpio,
    ) Action {
        self.updateLayout(self.last_win_w, self.last_win_h, status, gpio_hw);
        const pt: Point = .{ x, y };

        // Top bar (y < 44)
        if (y < @as(f32, @floatFromInt(title_bar_height))) {
            if (pressed) {
                if (self.boardBtnRect(self.last_win_w).contains(pt)) {
                    self.board_btn_pressed = true;
                    return .consumed;
                }
                if (maxBtnRect(self.last_win_w).contains(pt)) {
                    self.max_btn_pressed = true;
                    return .consumed;
                }
                if (closeBtnRect(self.last_win_w).contains(pt)) {
                    self.close_btn_pressed = true;
                    return .consumed;
                }
                return .start_drag;
            } else {
                defer {
                    self.board_btn_pressed = false;
                    self.max_btn_pressed = false;
                    self.close_btn_pressed = false;
                }
                if (self.board_btn_pressed and self.boardBtnRect(self.last_win_w).contains(pt)) {
                    self.sheet_open = !self.sheet_open;
                    return .consumed;
                }
                if (self.max_btn_pressed and maxBtnRect(self.last_win_w).contains(pt)) {
                    return .toggle_maximize;
                }
                if (self.close_btn_pressed and closeBtnRect(self.last_win_w).contains(pt)) {
                    return .close;
                }
                return .consumed;
            }
        }

        self.board_btn_pressed = false;
        self.max_btn_pressed = false;
        self.close_btn_pressed = false;

        if (!self.sheet_open) return .none;

        if (pressed) {
            return .consumed;
        } else {
            const drawing = board.forModel(status.model) orelse &board.pi_zero;
            if (self.board_rect.contains(pt)) {
                const tr = boardTransform(drawing, self.board_rect);
                if (targetAt(drawing, .{ (x - tr.x) / tr.scale, (y - tr.y) / tr.scale }, status.sd_connected)) |target| {
                    return switch (target) {
                        .sd_connector => .toggle_sd,
                        .sd_card => if (status.sd_connected) .toggle_sd else .select_sd_image,
                        .hdmi => .toggle_hdmi,
                        .power => .toggle_power,
                        .usb_hub => .toggle_usb_hub,
                        .usb_keyboard => .toggle_usb_keyboard,
                        .usb_mouse => .toggle_usb_mouse,
                        .ethernet => .toggle_ethernet,
                    };
                }
            }

            // Release outside the sheet card (on the dimmed HDMI area) dismisses the sheet
            if (!self.sheet_rect.contains(pt)) {
                self.sheet_open = false;
            }
            return .consumed;
        }
    }

    /// Renders the client-side TitleBar (`y = 0..44` logical) and, when open, the
    /// drop-down Board Sheet over `pixels` at `scale` (e.g. 1x or 2x).
    pub fn paint(
        self: *BoardUi,
        pixels: []u32,
        win_w: u32,
        win_h: u32,
        scale: u32,
        status: SystemStatus,
        gpio_hw: *const Gpio,
    ) void {
        const sc = @max(scale, 1);
        self.updateLayout(win_w, win_h, status, gpio_hw);

        const buf_w = win_w * sc;
        const buf_h = win_h * sc;
        var c: Canvas = .{
            .pixels = pixels,
            .width = buf_w,
            .height = buf_h,
            .stride = buf_w,
            .scale = @floatFromInt(sc),
            .font = &self.font,
            .icon_font = &self.icon_font,
            .cache = &self.cache,
        };

        if (!status.hdmi_connected or !status.hdmi_active) {
            self.paintNoSignal(&c, win_w, win_h, status.hdmi_connected);
        }
        self.paintTitleBar(&c, win_w);
        if (self.sheet_open) {
            self.paintSheet(&c, win_w, win_h, status);
        }
    }

    fn paintNoSignal(self: *BoardUi, c: *Canvas, win_w: u32, win_h: u32, hdmi_connected: bool) void {
        const w_f: f32 = @floatFromInt(win_w);
        const h_f: f32 = @floatFromInt(win_h);
        const top_y: f32 = @floatFromInt(title_bar_height);
        if (h_f <= top_y) return;

        // Monitor matte dark panel background
        const disp_h = h_f - top_y;
        c.fillRect(.{ .x = 0, .y = top_y, .w = w_f, .h = disp_h }, Color.rgb(0x0b0d11));

        // Centered monitor On-Screen Display (OSD) dialog
        const osd_w: f32 = 288.0;
        const osd_h: f32 = 122.0;
        const osd_x = @round((w_f - osd_w) * 0.5);
        const osd_y = @round(top_y + (disp_h - osd_h) * 0.5);
        const osd_rect: Rect = .{ .x = osd_x, .y = osd_y, .w = osd_w, .h = osd_h };

        c.fillRoundedRect(osd_rect, .all(12.0), Color.rgb(0x161920).withAlpha(0.96));
        c.strokeRoundedRect(osd_rect, .all(12.0), 1.5, Color.rgb(0x323846));

        // Top HDMI input pill badge inside OSD
        const badge_w: f32 = 64.0;
        const badge_h: f32 = 22.0;
        const badge_rect: Rect = .{
            .x = @round(osd_x + (osd_w - badge_w) * 0.5),
            .y = osd_y + 16.0,
            .w = badge_w,
            .h = badge_h,
        };
        c.fillRoundedRect(badge_rect, .all(6.0), Color.rgb(0x252a36));
        c.strokeRoundedRect(badge_rect, .all(6.0), 1.0, Color.rgb(0x414858));
        const badge_label = "HDMI";
        const badge_tw = c.measureText(12.0, badge_label);
        const badge_style: canvas_mod.Style = .{ .font = &self.font, .size = 12.0 };
        _ = c.drawText(
            12.0,
            @round(badge_rect.x + (badge_w - badge_tw) * 0.5),
            @round(badge_rect.y + (badge_h - badge_style.lineHeight()) * 0.5 + badge_style.ascent()),
            badge_label,
            Color.rgb(0xb8c0d0),
        );

        // Main "No signal detected" message
        const msg = "No signal detected";
        const msg_w = c.measureText(20.0, msg);
        _ = c.drawText(
            20.0,
            @round(osd_x + (osd_w - msg_w) * 0.5),
            osd_y + 68.0,
            msg,
            Color.rgb(0xe8ecf4),
        );

        // Subtitle with amber standby LED dot
        const sub = if (hdmi_connected) "Standby  ·  Waiting for signal" else "HDMI cable disconnected";
        const sub_w = c.measureText(13.0, sub);
        const total_sub_w = 12.0 + sub_w;
        const sub_x0 = @round(osd_x + (osd_w - total_sub_w) * 0.5);
        const dot_color = if (hdmi_connected) orange else red;
        c.fillCircle(.{ sub_x0 + 3.0, osd_y + 92.0 }, 3.5, dot_color);
        _ = c.drawText(
            13.0,
            sub_x0 + 12.0,
            osd_y + 96.0,
            sub,
            Color.rgb(0x8c94a6),
        );
    }

    fn paintTitleBar(self: *BoardUi, c: *Canvas, win_w: u32) void {
        const t = &self.theme;
        const w_f: f32 = @floatFromInt(win_w);
        const h_f: f32 = @floatFromInt(title_bar_height);

        c.fillRect(.{ .x = 0, .y = 0, .w = w_f, .h = h_f }, t.surface_container);

        // Centered window title (22px, as in dazzle/src/ui/title_bar.zig)
        const title_w = c.measureText(22.0, self.title);
        const style: canvas_mod.Style = .{ .font = &self.font, .size = 22.0 };
        const title_x = @round((w_f - title_w) * 0.5);
        const title_base = @round((h_f - style.lineHeight()) * 0.5 + style.ascent());
        _ = c.drawText(22.0, title_x, title_base, self.title, t.on_surface);

        // Button to the right of the window title: Board sheet toggle (.developer_board)
        paintBarButton(
            c,
            t,
            self.boardBtnRect(win_w),
            .developer_board,
            self.board_btn_hovered,
            self.board_btn_pressed,
            self.sheet_open,
        );

        // Right buttons: Maximize/Restore and Close
        paintBarButton(
            c,
            t,
            maxBtnRect(win_w),
            if (self.maximized) .filter_none else .crop_square,
            self.max_btn_hovered,
            self.max_btn_pressed,
            false,
        );
        paintBarButton(
            c,
            t,
            closeBtnRect(win_w),
            .close,
            self.close_btn_hovered,
            self.close_btn_pressed,
            false,
        );
    }

    fn paintBarButton(
        c: *Canvas,
        t: *const Theme,
        r: Rect,
        icon: Icon,
        hovered: bool,
        pressed: bool,
        active: bool,
    ) void {
        const mid: Point = .{ r.x + r.w * 0.5, r.y + r.h * 0.5 };
        if (active) {
            c.fillCircle(mid, r.w * 0.5, t.secondary_container);
        }
        if (hovered or pressed) {
            c.fillCircle(mid, r.w * 0.5, t.on_surface.withAlpha(if (pressed) 0.16 else 0.08));
        }
        const s = @round(r.w * 0.6);
        const icon_color = if (active) t.primary else t.on_surface_variant;
        c.drawIcon(icon, @round(r.x + (r.w - s) * 0.5), @round(r.y + (r.h - s) * 0.5), s, icon_color);
    }

    fn paintSheet(
        self: *BoardUi,
        c: *Canvas,
        win_w: u32,
        win_h: u32,
        status: SystemStatus,
    ) void {
        const t = &self.theme;
        const w_f: f32 = @floatFromInt(win_w);
        const h_f: f32 = @floatFromInt(win_h);
        const top_y: f32 = @floatFromInt(title_bar_height);

        // Dim the HDMI display behind the drop-down sheet
        if (h_f > top_y) {
            c.fillRect(.{ .x = 0, .y = top_y, .w = w_f, .h = h_f - top_y }, Color.rgb(0x000000).withAlpha(0.55));
        }

        // Drop-down sheet container (anchored to the bottom of the TitleBar)
        const sr = self.sheet_rect;
        const sheet_radii: Radii = .{ .tl = 0, .tr = 0, .br = 16, .bl = 16 };
        c.fillRoundedRect(sr, sheet_radii, t.surface);
        c.strokeRoundedRect(sr, sheet_radii, 1.0, t.outline_variant);

        const drawing = board.forModel(status.model) orelse &board.pi_zero;
        self.paintBoardDrawing(c, drawing, self.board_rect, status);
    }

    fn paintBoardDrawing(
        self: *const BoardUi,
        c: *Canvas,
        b: *const board.Board,
        box: Rect,
        status: SystemStatus,
    ) void {
        const t = &self.theme;
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

        if (b.notches.len > 0) {
            const old = c.clipTo(outline.outset(heavy_w));
            for (b.notches) |notch| {
                const center: Point = .{ tr.x + notch.x * s, tr.y + notch.y * s };
                c.fillCircle(center, notch.r * s + heavy_w * 0.5, t.surface);
                c.strokeCircle(center, notch.r * s, heavy_w, ink);
            }
            c.restoreClip(old);
        }

        for (b.holes) |h| {
            c.strokeCircle(.{ tr.x + h[0] * s, tr.y + h[1] * s }, b.hole_diameter * 0.5 * s, line_w, ink);
        }

        // Underside parts (faint), then top parts
        for (b.parts) |part| {
            if (part.underside) drawPart(c, &part, map(tr, part.rect), s, ink.withAlpha(0.35));
        }
        for (b.parts) |part| {
            const part_hovered = switch (part.kind) {
                .micro_sd, .sd => self.hovered_target == .sd_connector or (status.sd_connected and self.hovered_target == .sd_card),
                .mini_hdmi, .hdmi, .micro_hdmi => self.hovered_target == .hdmi,
                .power, .usb_c_power => self.hovered_target == .power,
                .usb_otg, .usb, .usb_double => self.hovered_target == .usb_hub,
                else => false,
            };
            const pr = map(tr, part.rect);
            if (!part.underside) {
                drawPart(c, &part, pr, s, if (part_hovered) t.primary else ink);
            }
            if (part_hovered) {
                c.fillRoundedRect(pr, .all(0.6 * s), t.primary.withAlpha(0.22));
            }
        }

        const max_y = tr.y + HubLayout.bottom_cable_max_y * s;

        // 1. Micro-SD card (connected into slot or pulled out to the left)
        for (b.parts) |part| {
            if (part.kind == .micro_sd or part.kind == .sd) {
                const hovered = (self.hovered_target == .sd_card) or (status.sd_connected and self.hovered_target == .sd_connector);
                drawSdCard(
                    c,
                    map(tr, part.rect),
                    s,
                    if (hovered) t.primary else ink,
                    t.primary,
                    t.surface,
                    status.sd_connected,
                    hovered,
                );
            }
        }

        // 2. USB OTG plug, curved cable, and 3-port USB Hub with Ethernet
        //    (drawn before the Power cable so the straight Power cable cleanly crosses over the horizontal USB cable)
        for (b.parts) |part| {
            if (part.kind == .usb_otg) {
                drawUsbHubAndPeripherals(
                    c,
                    tr.x,
                    tr.y,
                    s,
                    map(tr, part.rect),
                    ink,
                    t.primary,
                    t.surface,
                    status,
                    self.hovered_target,
                );
            }
        }

        // 3. Mini HDMI and Power cables & plugs
        for (b.parts) |part| {
            const is_hdmi = (part.kind == .mini_hdmi or part.kind == .hdmi or part.kind == .micro_hdmi);
            const is_power = (part.kind == .power or part.kind == .usb_c_power);
            if (is_hdmi or is_power) {
                const hovered = if (is_power) (self.hovered_target == .power) else (self.hovered_target == .hdmi);
                drawBottomCable(
                    c,
                    &part,
                    map(tr, part.rect),
                    max_y,
                    s,
                    if (hovered) t.primary else ink,
                    t.primary,
                    t.surface,
                    if (is_power) .bolt else .monitor,
                    if (is_power) status.power_connected else status.hdmi_connected,
                    hovered,
                );
            }
        }
    }
};

/// Draws a single board part, ported from `dazzle/src/apps/settings/board_view.zig`.
pub fn drawPart(c: *Canvas, part: *const board.Part, r: Rect, s: f32, ink: Color) void {
    const radius: Radii = .all(0.6 * s);
    switch (part.kind) {
        .soc, .soc_with_ram, .ram, .usb_ethernet, .usb_controller, .southbridge, .ethernet_phy, .wireless, .pmic, .emmc => {
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
        .usb, .usb_double, .ethernet, .hdmi, .mini_hdmi, .micro_hdmi, .power, .usb_c_power, .power_button, .usb_otg, .micro_sd, .sd => {
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
        .composite => {
            c.strokeRoundedRect(.{ .x = r.x, .y = r.y + r.h * 0.45, .w = r.w, .h = r.h * 0.55 }, .all(0.6 * s), line_w, ink);
            c.strokeRoundedRect(.{ .x = r.x + r.w * 0.2, .y = r.y, .w = r.w * 0.6, .h = r.h * 0.45 }, .all(0.4 * s), line_w, ink);
        },
        .camera, .display, .camera_display, .pcie => {
            c.strokeRoundedRect(r, .all(0.3 * s), line_w, ink);
            const slot: Rect = if (r.w > r.h)
                .{ .x = r.x + 1.2 * s, .y = r.y + r.h * 0.35, .w = r.w - 2.4 * s, .h = r.h * 0.3 }
            else
                .{ .x = r.x + r.w * 0.35, .y = r.y + 1.2 * s, .w = r.w * 0.3, .h = r.h - 2.4 * s };
            c.fillRect(slot, ink);
        },
        .edge => {},
    }
}

/// Draws the micro-SD card on a left-facing SD slot:
/// - When `connected` is true: the card is seated inside the slot with its left tab protruding slightly.
/// - When `connected` is false: the card is pulled out to the left of the slot with a gap and exposed contact pins.
pub fn drawSdCard(
    c: *Canvas,
    slot_r: Rect,
    s: f32,
    ink: Color,
    accent: Color,
    surface_bg: Color,
    connected: bool,
    hovered: bool,
) void {
    const cy = slot_r.y + slot_r.h * 0.5;
    const card_h = slot_r.h * 0.80;
    const card_y = cy - card_h * 0.5;

    if (connected) {
        // Seated inside the slot: draw protruding left tab and subtle outline inside cage
        const protrude_w = 4.2 * s;
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
        const gap = 2.8 * s;
        const card_w = 13.0 * s;
        const card_rect: Rect = .{
            .x = slot_r.x - gap - card_w,
            .y = card_y,
            .w = card_w,
            .h = card_h,
        };
        const radii: Radii = .{ .tl = 0.8 * s, .bl = 0.8 * s, .tr = 0.4 * s, .br = 0.4 * s };
        c.fillRoundedRect(card_rect, radii, surface_bg);
        c.fillRoundedRect(card_rect, radii, if (hovered) accent.withAlpha(0.28) else ink.withAlpha(0.08));
        c.strokeRoundedRect(card_rect, radii, heavy_w, ink);

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

    const plug_w = r.w * 0.88;
    const plug_h = 5.4 * s;
    const tip_w = r.w * 0.56;
    const tip_h = 2.4 * s;
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
        c.fillRoundedRect(tip_rect, .{ .tl = 0.3 * s, .tr = 0.3 * s, .br = 0, .bl = 0 }, surface_bg);
        if (hovered) {
            c.fillRoundedRect(tip_rect, .{ .tl = 0.3 * s, .tr = 0.3 * s, .br = 0, .bl = 0 }, accent.withAlpha(0.22));
        }
        c.strokeRoundedRect(tip_rect, .{ .tl = 0.3 * s, .tr = 0.3 * s, .br = 0, .bl = 0 }, line_w, ink);

        const notch_h = @max(1.0, tip_h * 0.45);
        const notch_y = tip_rect.y + (tip_h - notch_h) * 0.5;
        c.fillRect(.{ .x = cx - tip_w * 0.22 - line_w * 0.5, .y = notch_y, .w = line_w, .h = notch_h }, ink.withAlpha(0.75));
        c.fillRect(.{ .x = cx + tip_w * 0.22 - line_w * 0.5, .y = notch_y, .w = line_w, .h = notch_h }, ink.withAlpha(0.75));
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

/// Draws the USB OTG plug, the curved USB cable (down -> right -> up), the 3-port USB Hub with Ethernet,
/// and the Keyboard, Mouse, and Ethernet plugs/cables plugged into the top of the hub.
fn drawUsbHubAndPeripherals(
    c: *Canvas,
    tx: f32,
    ty: f32,
    s: f32,
    otg_r: Rect,
    ink: Color,
    accent: Color,
    surface_bg: Color,
    status: SystemStatus,
    hovered_target: ?InteractiveTarget,
) void {
    const hub_hovered = (hovered_target == .usb_hub);
    const hub_ink = if (hub_hovered) accent else ink;
    const hub_tint = if (hub_hovered) accent.withAlpha(0.22) else ink.withAlpha(0.14);

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
    const hub_r: Rect = .{
        .x = tx + HubLayout.hub_rect.x * s,
        .y = ty + HubLayout.hub_rect.y * s,
        .w = HubLayout.hub_rect.w * s,
        .h = HubLayout.hub_rect.h * s,
    };
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

    // 3. Three-Port USB Hub with Ethernet body
    c.fillRoundedRect(hub_r, .all(2.2 * s), surface_bg);
    c.fillRoundedRect(hub_r, .all(2.2 * s), if (hub_hovered) accent.withAlpha(0.16) else ink.withAlpha(0.05));
    c.strokeRoundedRect(hub_r, .all(2.2 * s), heavy_w, hub_ink);

    // Draw the 3 USB-A ports and 1 RJ45 Ethernet port along the top edge of the hub
    const ports = [_]struct { rect: board.Rect, target: ?InteractiveTarget, is_eth: bool }{
        .{ .rect = HubLayout.kbd_port_rect, .target = .usb_keyboard, .is_eth = false },
        .{ .rect = HubLayout.mouse_port_rect, .target = .usb_mouse, .is_eth = false },
        .{ .rect = HubLayout.spare_port_rect, .target = null, .is_eth = false },
        .{ .rect = HubLayout.eth_port_rect, .target = .ethernet, .is_eth = true },
    };
    for (ports) |p| {
        const pr: Rect = .{
            .x = tx + p.rect.x * s,
            .y = ty + p.rect.y * s,
            .w = p.rect.w * s,
            .h = p.rect.h * s,
        };
        const p_hovered = (p.target != null and hovered_target == p.target);
        const p_ink = if (p_hovered) accent else hub_ink;
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
        .x = tx + HubLayout.kbd_port_rect.x * s,
        .y = ty + HubLayout.kbd_port_rect.y * s,
        .w = HubLayout.kbd_port_rect.w * s,
        .h = HubLayout.kbd_port_rect.h * s,
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
        .x = tx + HubLayout.mouse_port_rect.x * s,
        .y = ty + HubLayout.mouse_port_rect.y * s,
        .w = HubLayout.mouse_port_rect.w * s,
        .h = HubLayout.mouse_port_rect.h * s,
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
        .x = tx + HubLayout.eth_port_rect.x * s,
        .y = ty + HubLayout.eth_port_rect.y * s,
        .w = HubLayout.eth_port_rect.w * s,
        .h = HubLayout.eth_port_rect.h * s,
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

const testing = std.testing;

test "TitleBar and BoardSheet toggle connectors and peripherals on the board diagram" {
    var ui = try BoardUi.init(testing.allocator);
    defer ui.deinit();

    var hw: Gpio = .{};
    var status: SystemStatus = .{};

    // By default at startup, SD card and Power are disconnected, while HDMI, USB Hub, Keyboard, Mouse, and Ethernet are connected
    try testing.expect(!status.sd_connected);
    try testing.expect(!status.power_connected);
    try testing.expect(status.hdmi_connected);
    try testing.expect(status.usb_hub_connected);
    try testing.expect(status.usb_keyboard_connected);
    try testing.expect(status.usb_mouse_connected);
    try testing.expect(status.ethernet_connected);

    const win_w: u32 = 1280;
    const win_h: u32 = 764;
    const pixels = try testing.allocator.alloc(u32, win_w * win_h);
    defer testing.allocator.free(pixels);
    @memset(pixels, 0xff000000);

    // 1. Starts with the hardware overlay open by default
    try testing.expect(ui.sheet_open);
    ui.paint(pixels, win_w, win_h, 1, status, &hw);
    try testing.expect(ui.sheet_rect.h > 150);

    // Dragging the left side of the title bar returns .start_drag
    try testing.expectEqual(Action.start_drag, ui.pointerButton(200, 22, true, status, &hw));

    // Clicking the Board button (to the right of the window title) toggles the drop-down sheet
    const btn_r = ui.boardBtnRect(win_w);
    try testing.expect(btn_r.x > 640);
    try testing.expectEqual(Action.consumed, ui.pointerButton(btn_r.x + 10, btn_r.y + 10, true, status, &hw));
    try testing.expectEqual(Action.consumed, ui.pointerButton(btn_r.x + 10, btn_r.y + 10, false, status, &hw));
    try testing.expect(!ui.sheet_open);

    // Click again to reopen the drop-down sheet
    try testing.expectEqual(Action.consumed, ui.pointerButton(btn_r.x + 10, btn_r.y + 10, true, status, &hw));
    try testing.expectEqual(Action.consumed, ui.pointerButton(btn_r.x + 10, btn_r.y + 10, false, status, &hw));
    try testing.expect(ui.sheet_open);

    // Paint with the drop-down sheet open at 1x and 2x HiDPI scale
    ui.paint(pixels, win_w, win_h, 1, status, &hw);

    const pixels_2x = try testing.allocator.alloc(u32, (win_w * 2) * (win_h * 2));
    defer testing.allocator.free(pixels_2x);
    @memset(pixels_2x, 0xff000000);
    ui.paint(pixels_2x, win_w, win_h, 2, status, &hw);
    try testing.expectEqual(Theme.dark.surface_container.toArgb(), pixels_2x[80 * (win_w * 2) + 200]);

    const tr = BoardUi.boardTransform(&board.pi_zero, ui.board_rect);

    // 2. When removed, clicking the SD card (to the left of the board) returns .select_sd_image,
    //    and clicking the SD card connector (on the board) returns .toggle_sd to insert it.
    //    When inserted, clicking the SD card disconnects it (.toggle_sd).
    const sd_card_removed_x = tr.x + (-8.0) * tr.scale;
    const sd_y = tr.y + 13.3 * tr.scale;
    _ = ui.pointerButton(sd_card_removed_x, sd_y, true, status, &hw);
    try testing.expectEqual(Action.select_sd_image, ui.pointerButton(sd_card_removed_x, sd_y, false, status, &hw));

    const sd_conn_x = tr.x + 6.75 * tr.scale;
    _ = ui.pointerButton(sd_conn_x, sd_y, true, status, &hw);
    try testing.expectEqual(Action.toggle_sd, ui.pointerButton(sd_conn_x, sd_y, false, status, &hw));
    status.sd_connected = true;

    const sd_card_inserted_x = tr.x + (-2.0) * tr.scale;
    _ = ui.pointerButton(sd_card_inserted_x, sd_y, true, status, &hw);
    try testing.expectEqual(Action.toggle_sd, ui.pointerButton(sd_card_inserted_x, sd_y, false, status, &hw));

    // 3. Clicking the Mini HDMI socket returns .toggle_hdmi
    const hdmi_x = tr.x + 12.4 * tr.scale;
    const hdmi_y = tr.y + 26.9 * tr.scale;
    _ = ui.pointerButton(hdmi_x, hdmi_y, true, status, &hw);
    try testing.expectEqual(Action.toggle_hdmi, ui.pointerButton(hdmi_x, hdmi_y, false, status, &hw));
    status.hdmi_connected = false;

    // 4. Clicking the Power socket returns .toggle_power
    const pwr_x = tr.x + 54.0 * tr.scale;
    const pwr_y = tr.y + 28.1 * tr.scale;
    _ = ui.pointerButton(pwr_x, pwr_y, true, status, &hw);
    try testing.expectEqual(Action.toggle_power, ui.pointerButton(pwr_x, pwr_y, false, status, &hw));
    status.power_connected = true;

    // 5. Clicking the USB Hub body (or USB OTG socket) returns .toggle_usb_hub
    const hub_x = tr.x + 98.0 * tr.scale;
    const hub_y = tr.y + 25.0 * tr.scale;
    _ = ui.pointerButton(hub_x, hub_y, true, status, &hw);
    try testing.expectEqual(Action.toggle_usb_hub, ui.pointerButton(hub_x, hub_y, false, status, &hw));
    status.usb_hub_connected = false;

    // 6. Clicking the Keyboard, Mouse, and Ethernet plugs on the USB Hub toggles each one
    const kbd_x = tr.x + 79.5 * tr.scale;
    const kbd_y = tr.y + 10.0 * tr.scale;
    _ = ui.pointerButton(kbd_x, kbd_y, true, status, &hw);
    try testing.expectEqual(Action.toggle_usb_keyboard, ui.pointerButton(kbd_x, kbd_y, false, status, &hw));
    status.usb_keyboard_connected = false;

    const mouse_x = tr.x + 90.1 * tr.scale;
    const mouse_y = tr.y + 10.0 * tr.scale;
    _ = ui.pointerButton(mouse_x, mouse_y, true, status, &hw);
    try testing.expectEqual(Action.toggle_usb_mouse, ui.pointerButton(mouse_x, mouse_y, false, status, &hw));
    status.usb_mouse_connected = false;

    const eth_x = tr.x + 114.4 * tr.scale;
    const eth_y = tr.y + 10.0 * tr.scale;
    _ = ui.pointerButton(eth_x, eth_y, true, status, &hw);
    try testing.expectEqual(Action.toggle_ethernet, ui.pointerButton(eth_x, eth_y, false, status, &hw));
    status.ethernet_connected = false;

    ui.paint(pixels, win_w, win_h, 1, status, &hw);

    // 7. Clicking outside the sheet (near bottom of window) closes the sheet
    _ = ui.pointerButton(640, 740, true, status, &hw);
    _ = ui.pointerButton(640, 740, false, status, &hw);
    try testing.expect(!ui.sheet_open);
}
