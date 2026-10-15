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

pub const BoardModel = enum {
    pi_1_a_plus,
    pi_1_b_plus,
    pi_3_a_plus,
    pi_3_b_plus,
    pi_zero,
    pi_zero_w,
    pi_zero_2_w,

    pub const all = [_]BoardModel{
        .pi_1_a_plus,
        .pi_1_b_plus,
        .pi_3_a_plus,
        .pi_3_b_plus,
        .pi_zero,
        .pi_zero_w,
        .pi_zero_2_w,
    };

    pub fn windowTitle(self: BoardModel) []const u8 {
        return switch (self) {
            .pi_1_a_plus => "Raspberry Pi 1 Model A+",
            .pi_1_b_plus => "Raspberry Pi 1 Model B+",
            .pi_3_a_plus => "Raspberry Pi 3 Model A+",
            .pi_3_b_plus => "Raspberry Pi 3 Model B+",
            .pi_zero => "Raspberry Pi Zero",
            .pi_zero_w => "Raspberry Pi Zero W",
            .pi_zero_2_w => "Raspberry Pi Zero 2 W",
        };
    }

    pub fn dtModel(self: BoardModel) []const u8 {
        return switch (self) {
            .pi_1_a_plus => "Raspberry Pi Model A Plus Rev 1.1",
            .pi_1_b_plus => "Raspberry Pi Model B Plus Rev 1.2",
            .pi_3_a_plus => "Raspberry Pi 3 Model A Plus Rev 1.0",
            .pi_3_b_plus => "Raspberry Pi 3 Model B Plus Rev 1.3",
            .pi_zero => "Raspberry Pi Zero Rev 1.3",
            .pi_zero_w => "Raspberry Pi Zero W Rev 1.1",
            .pi_zero_2_w => "Raspberry Pi Zero 2 W Rev 1.0",
        };
    }

    pub fn boardRevision(self: BoardModel) u32 {
        return switch (self) {
            .pi_1_a_plus => 0x00900021,
            .pi_1_b_plus => 0x00900032,
            .pi_3_a_plus => 0x009020e0,
            .pi_3_b_plus => 0x00a020d3,
            .pi_zero => 0x00900093,
            .pi_zero_w => 0x009000c1,
            .pi_zero_2_w => 0x00902120,
        };
    }

    pub fn hasWireless(self: BoardModel) bool {
        return switch (self) {
            .pi_1_a_plus, .pi_1_b_plus, .pi_zero => false,
            .pi_3_a_plus, .pi_3_b_plus, .pi_zero_w, .pi_zero_2_w => true,
        };
    }

    pub fn usesExternalUsbHub(self: BoardModel) bool {
        return switch (self) {
            .pi_1_b_plus, .pi_3_b_plus => false,
            .pi_1_a_plus, .pi_3_a_plus, .pi_zero, .pi_zero_w, .pi_zero_2_w => true,
        };
    }

    pub fn fromModel(model: []const u8) BoardModel {
        if (std.mem.indexOf(u8, model, "Zero 2 W") != null) return .pi_zero_2_w;
        if (std.mem.indexOf(u8, model, "Zero W") != null) return .pi_zero_w;
        if (std.mem.indexOf(u8, model, "3 Model B Plus") != null or std.mem.indexOf(u8, model, "3 Model B+") != null) return .pi_3_b_plus;
        if (std.mem.indexOf(u8, model, "3 Model A Plus") != null or std.mem.indexOf(u8, model, "3 Model A+") != null) return .pi_3_a_plus;
        if (std.mem.indexOf(u8, model, "Model B Plus") != null or std.mem.indexOf(u8, model, "Model B+") != null) return .pi_1_b_plus;
        if (std.mem.indexOf(u8, model, "Model A Plus") != null or std.mem.indexOf(u8, model, "Model A+") != null) return .pi_1_a_plus;
        return .pi_zero;
    }
};

pub const SystemStatus = struct {
    board_model: BoardModel = .pi_zero,
    model: []const u8 = "Raspberry Pi Zero Rev 1.3",
    serial: []const u8 = "00000000fa000001",
    serial_u64: u64 = 0x00000000fa000001,
    mac_address: [6]u8 = .{ 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56 },
    wifi_mac_address: [6]u8 = .{ 0xb8, 0x27, 0xeb, 0x65, 0x43, 0x21 },
    dhcp_enabled: bool = true,
    cpu_busy_percent: f32 = 0.0,
    temperature_c: f32 = 42.0,
    mem_total_mb: u32 = 512,
    hdmi_width: u16 = 1280,
    hdmi_height: u16 = 720,
    hdmi_connected: bool = true,
    hdmi_active: bool = false,
    audio_connected: bool = true,
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
    toggle_audio,
    toggle_power,
    toggle_sd,
    select_sd_image,
    toggle_usb_hub,
    toggle_usb_keyboard,
    toggle_usb_mouse,
    toggle_ethernet,
    select_board,
    toggle_dhcp,
    close,
};

pub const FocusedSettingField = enum {
    none,
    serial,
    mac,
    wifi_mac,
};

pub const InteractiveTarget = enum {
    sd_connector,
    sd_card,
    hdmi,
    audio,
    power,
    usb_hub,
    usb_keyboard,
    usb_mouse,
    ethernet,
};

/// Geometry of the 3-port USB Hub with Ethernet and external cables in board millimetres (`mm`).
pub const HubLayout = struct {
    pub const sd_ext_left_mm: f32 = 17.5;
    pub const bottom_ext_mm: f32 = 18.0; // extends 18mm below board.height
    pub const right_ext_mm: f32 = 19.0; // extends 19mm past board.width on B boards

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

pub const BoardUi = struct {
    pub const title_bar_height: u32 = 44;
    pub const bar_btn_size: f32 = 34;

    pub const TitleCacheKey = struct {
        win_w: u32 = 0,
        scale: u32 = 0,
        board_model: BoardModel = .pi_zero,
        maximized: bool = false,
        sheet_open: bool = false,
        board_btn_hovered: bool = false,
        board_btn_pressed: bool = false,
        max_btn_hovered: bool = false,
        max_btn_pressed: bool = false,
        close_btn_hovered: bool = false,
        close_btn_pressed: bool = false,
    };

    pub const BoardCacheKey = struct {
        w_px: u32 = 0,
        h_px: u32 = 0,
        scale: u32 = 0,
        board_model: BoardModel = .pi_zero,
        hovered_target: ?InteractiveTarget = null,
        sd_connected: bool = false,
        hdmi_connected: bool = false,
        audio_connected: bool = false,
        power_connected: bool = false,
        usb_hub_connected: bool = false,
        usb_keyboard_connected: bool = false,
        usb_mouse_connected: bool = false,
        ethernet_connected: bool = false,
    };

    gpa: std.mem.Allocator,
    font: Font,
    icon_font: Font,
    cache: GlyphCache,
    theme: Theme = Theme.dark,

    title: []const u8 = "Raspberry Pi Zero",
    maximized: bool = false,
    sheet_open: bool = true,
    settings_open: bool = false,

    /// Currently hovered connector/peripheral button in the board diagram.
    hovered_target: ?InteractiveTarget = null,

    /// Title bar button hover/press states.
    board_btn_hovered: bool = false,
    board_btn_pressed: bool = false,
    max_btn_hovered: bool = false,
    max_btn_pressed: bool = false,
    close_btn_hovered: bool = false,
    close_btn_pressed: bool = false,

    /// Expandable Settings panel states & editable buffers.
    settings_btn_hovered: bool = false,
    settings_btn_pressed: bool = false,
    board_menu_btn_hovered: bool = false,
    board_menu_open: bool = false,
    hovered_board_menu_idx: ?usize = null,
    selected_board_model: BoardModel = .pi_zero,
    serial_field_hovered: bool = false,
    mac_field_hovered: bool = false,
    wifi_mac_field_hovered: bool = false,
    dhcp_toggle_hovered: bool = false,
    focused_field: FocusedSettingField = .none,

    serial_hex: [16]u8 = "00000000fa000001".*,
    serial_len: usize = 16,
    mac_hex: [12]u8 = "B827EB123456".*,
    mac_len: usize = 12,
    wifi_mac_hex: [12]u8 = "B827EB654321".*,
    wifi_mac_len: usize = 12,

    /// Last computed geometry for hit-testing.
    last_win_w: u32 = 1280,
    last_win_h: u32 = 764,
    sheet_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    board_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    settings_btn_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    settings_panel_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    board_menu_btn_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    board_menu_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    serial_field_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    mac_field_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    wifi_mac_field_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    dhcp_toggle_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    /// Cached rasterized pixel buffers for TitleBar and Board diagram.
    title_cache: []u32 = &.{},
    title_cache_key: TitleCacheKey = .{},
    board_cache: []u32 = &.{},
    board_cache_key: BoardCacheKey = .{},

    pub fn init(gpa: std.mem.Allocator) !BoardUi {
        const font = try Font.init(canvas_mod.fira_ttf);
        const icon_font = try Font.init(canvas_mod.icons_ttf);
        var ui: BoardUi = .{
            .gpa = gpa,
            .font = font,
            .icon_font = icon_font,
            .cache = GlyphCache.init(gpa),
        };
        ui.randomizeIdentity();
        return ui;
    }

    pub fn deinit(self: *BoardUi) void {
        if (self.title_cache.len > 0) self.gpa.free(self.title_cache);
        if (self.board_cache.len > 0) self.gpa.free(self.board_cache);
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
        const hl = HubLayout.forBoard(drawing);
        const x0 = @min(r.x, -HubLayout.sd_ext_left_mm);
        const y0 = @min(r.y, HubLayout.top_cable_min_y);
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

            // 2. USB Hub body & its connecting cable
            if (rectContainsMm(hl.hub_rect, pt)) return .usb_hub;
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
                        .h = hl.bottom_cable_max_y - p.rect.y,
                    };
                    if (rectContainsMm(hdmi_hit, pt)) return .hdmi;
                },
                .power, .usb_c_power => {
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
                else => {},
            }
        }
        return null;
    }

    pub fn parsedSerial(self: *const BoardUi) u64 {
        if (self.serial_len == 0) return 0;
        return std.fmt.parseInt(u64, self.serial_hex[0..self.serial_len], 16) catch 0x00000000fa000001;
    }

    pub fn parsedMac(self: *const BoardUi) [6]u8 {
        var out: [6]u8 = .{ 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56 };
        if (self.mac_len < 12) return out;
        for (0..6) |i| {
            out[i] = std.fmt.parseInt(u8, self.mac_hex[i * 2 .. i * 2 + 2], 16) catch out[i];
        }
        return out;
    }

    pub fn parsedWifiMac(self: *const BoardUi) [6]u8 {
        var out: [6]u8 = .{ 0xb8, 0x27, 0xeb, 0x65, 0x43, 0x21 };
        if (self.wifi_mac_len < 12) return out;
        for (0..6) |i| {
            out[i] = std.fmt.parseInt(u8, self.wifi_mac_hex[i * 2 .. i * 2 + 2], 16) catch out[i];
        }
        return out;
    }

    pub fn randomizeSerial(self: *BoardUi) void {
        var rnd: [4]u8 = undefined;
        _ = std.os.linux.getrandom(&rnd, rnd.len, 0);
        const low = std.mem.readInt(u32, &rnd, .big);
        _ = std.fmt.bufPrint(&self.serial_hex, "00000000{x:0>8}", .{low}) catch {};
        self.serial_len = 16;
    }

    pub fn randomizeMac(self: *BoardUi) void {
        var rnd: [3]u8 = undefined;
        _ = std.os.linux.getrandom(&rnd, rnd.len, 0);
        _ = std.fmt.bufPrint(&self.mac_hex, "B827EB{X:0>2}{X:0>2}{X:0>2}", .{ rnd[0], rnd[1], rnd[2] }) catch {};
        self.mac_len = 12;
    }

    pub fn randomizeWifiMac(self: *BoardUi) void {
        var rnd: [3]u8 = undefined;
        _ = std.os.linux.getrandom(&rnd, rnd.len, 0);
        _ = std.fmt.bufPrint(&self.wifi_mac_hex, "B827EB{X:0>2}{X:0>2}{X:0>2}", .{ rnd[0], rnd[1], rnd[2] }) catch {};
        self.wifi_mac_len = 12;
    }

    pub fn randomizeIdentity(self: *BoardUi) void {
        self.randomizeSerial();
        self.randomizeMac();
        self.randomizeWifiMac();
    }

    /// Handles an evdev key press when a Settings text field (`serial`, `mac`, or `wifi_mac`) is focused.
    /// Returns true if the key was consumed by the Settings editor.
    pub fn handleKey(self: *BoardUi, evdev_key: u32) bool {
        if (!self.sheet_open or !self.settings_open or self.focused_field == .none) return false;

        // Enter (28) or Escape (1) unfocuses the text field
        if (evdev_key == 28 or evdev_key == 1) {
            self.focused_field = .none;
            return true;
        }

        // Backspace (14)
        if (evdev_key == 14) {
            switch (self.focused_field) {
                .serial => if (self.serial_len > 0) {
                    self.serial_len -= 1;
                },
                .mac => if (self.mac_len > 0) {
                    self.mac_len -= 1;
                },
                .wifi_mac => if (self.wifi_mac_len > 0) {
                    self.wifi_mac_len -= 1;
                },
                .none => {},
            }
            return true;
        }

        const hex_ch: ?u8 = switch (evdev_key) {
            2 => '1',
            3 => '2',
            4 => '3',
            5 => '4',
            6 => '5',
            7 => '6',
            8 => '7',
            9 => '8',
            10 => '9',
            11 => '0',
            30 => 'a',
            48 => 'b',
            46 => 'c',
            32 => 'd',
            18 => 'e',
            33 => 'f',
            else => null,
        };
        if (hex_ch) |ch| {
            switch (self.focused_field) {
                .serial => if (self.serial_len < 16) {
                    self.serial_hex[self.serial_len] = ch;
                    self.serial_len += 1;
                },
                .mac => if (self.mac_len < 12) {
                    self.mac_hex[self.mac_len] = std.ascii.toUpper(ch);
                    self.mac_len += 1;
                },
                .wifi_mac => if (self.wifi_mac_len < 12) {
                    self.wifi_mac_hex[self.wifi_mac_len] = std.ascii.toUpper(ch);
                    self.wifi_mac_len += 1;
                },
                .none => {},
            }
            return true;
        }
        return true;
    }

    /// Updates layout geometry for `(win_w, win_h)` so hit testing and painting match.
    pub fn updateLayout(self: *BoardUi, win_w: u32, win_h: u32, status: SystemStatus, _: *const Gpio) void {
        self.last_win_w = win_w;
        self.last_win_h = win_h;
        const cur_board = BoardModel.fromModel(status.model);
        self.title = cur_board.windowTitle();
        if (status.power_connected) {
            self.focused_field = .none;
            self.board_menu_open = false;
        }
        if (!cur_board.hasWireless() and self.focused_field == .wifi_mac) {
            self.focused_field = .none;
        }

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

        const btn_w: f32 = 128.0;
        const btn_h: f32 = 30.0;
        const btn_y: f32 = @round(y + bh + 12.0);
        self.settings_btn_rect = .{
            .x = @round(sheet_x + (sheet_w - btn_w) * 0.5),
            .y = btn_y,
            .w = btn_w,
            .h = btn_h,
        };

        const has_wifi = cur_board.hasWireless();
        const panel_x: f32 = @round(sheet_x + pad);
        const panel_w: f32 = @round(sheet_w - 2.0 * pad);
        const panel_y: f32 = @round(btn_y + btn_h + 12.0);
        const panel_h: f32 = if (has_wifi) 292.0 else 242.0;
        self.settings_panel_rect = .{
            .x = panel_x,
            .y = panel_y,
            .w = panel_w,
            .h = panel_h,
        };

        const right_x = panel_x + panel_w - 16.0;
        const ctrl_w: f32 = 228.0;
        const ctrl_h: f32 = 32.0;

        const row0_y = panel_y + 44.0;
        self.board_menu_btn_rect = .{ .x = right_x - ctrl_w, .y = row0_y, .w = ctrl_w, .h = ctrl_h };
        const menu_item_h: f32 = 32.0;
        const menu_h: f32 = @as(f32, @floatFromInt(BoardModel.all.len)) * menu_item_h + 8.0;
        self.board_menu_rect = .{
            .x = self.board_menu_btn_rect.x,
            .y = row0_y + ctrl_h + 4.0,
            .w = ctrl_w,
            .h = menu_h,
        };

        const row1_y = panel_y + 94.0;
        self.serial_field_rect = .{ .x = right_x - ctrl_w, .y = row1_y, .w = ctrl_w, .h = ctrl_h };

        const row2_y = panel_y + 144.0;
        self.mac_field_rect = .{ .x = right_x - ctrl_w, .y = row2_y, .w = ctrl_w, .h = ctrl_h };

        if (has_wifi) {
            const row_wifi_y = panel_y + 194.0;
            self.wifi_mac_field_rect = .{ .x = right_x - ctrl_w, .y = row_wifi_y, .w = ctrl_w, .h = ctrl_h };
        } else {
            self.wifi_mac_field_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        }

        const row_dhcp_y: f32 = if (has_wifi) (panel_y + 246.0) else (panel_y + 196.0);
        self.dhcp_toggle_rect = .{ .x = right_x - 52.0, .y = row_dhcp_y, .w = 52.0, .h = 28.0 };

        const menu_Bottom: f32 = if (self.board_menu_open) (self.board_menu_rect.y + self.board_menu_rect.h + 16.0) else 0.0;
        const total_h: f32 = if (self.settings_open)
            @max(panel_y + panel_h + 16.0, menu_Bottom) - sheet_y
        else
            (btn_y + btn_h + 14.0) - sheet_y;

        self.sheet_rect = .{
            .x = sheet_x,
            .y = sheet_y,
            .w = sheet_w,
            .h = total_h,
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
            self.settings_btn_hovered = false;
            self.board_menu_btn_hovered = false;
            self.hovered_board_menu_idx = null;
            self.serial_field_hovered = false;
            self.mac_field_hovered = false;
            self.wifi_mac_field_hovered = false;
            self.dhcp_toggle_hovered = false;
            return y < @as(f32, @floatFromInt(title_bar_height));
        }

        self.settings_btn_hovered = self.settings_btn_rect.contains(pt);
        if (self.settings_open) {
            const boot_editable = !status.power_connected;
            if (self.board_menu_open and boot_editable and self.board_menu_rect.contains(pt)) {
                const rel_y = y - (self.board_menu_rect.y + 4.0);
                if (rel_y >= 0.0) {
                    const idx: usize = @intFromFloat(@floor(rel_y / 32.0));
                    self.hovered_board_menu_idx = if (idx < BoardModel.all.len) idx else null;
                } else {
                    self.hovered_board_menu_idx = null;
                }
            } else {
                self.hovered_board_menu_idx = null;
            }
            const over_open_menu = self.board_menu_open and self.board_menu_rect.contains(pt);
            self.board_menu_btn_hovered = boot_editable and self.board_menu_btn_rect.contains(pt);
            self.serial_field_hovered = boot_editable and !over_open_menu and self.serial_field_rect.contains(pt);
            self.mac_field_hovered = boot_editable and !over_open_menu and self.mac_field_rect.contains(pt);
            self.wifi_mac_field_hovered = boot_editable and !over_open_menu and self.wifi_mac_field_rect.contains(pt);
            self.dhcp_toggle_hovered = !over_open_menu and self.dhcp_toggle_rect.contains(pt);
        } else {
            self.board_menu_btn_hovered = false;
            self.hovered_board_menu_idx = null;
            self.serial_field_hovered = false;
            self.mac_field_hovered = false;
            self.wifi_mac_field_hovered = false;
            self.dhcp_toggle_hovered = false;
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
        self.settings_btn_hovered = false;
        self.settings_btn_pressed = false;
        self.board_menu_btn_hovered = false;
        self.hovered_board_menu_idx = null;
        self.serial_field_hovered = false;
        self.mac_field_hovered = false;
        self.wifi_mac_field_hovered = false;
        self.dhcp_toggle_hovered = false;
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
                    if (!self.sheet_open) {
                        self.focused_field = .none;
                        self.board_menu_open = false;
                    }
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
            if (self.settings_btn_rect.contains(pt)) {
                self.settings_btn_pressed = true;
            }
            return .consumed;
        } else {
            defer self.settings_btn_pressed = false;

            if (self.settings_btn_rect.contains(pt)) {
                self.settings_open = !self.settings_open;
                if (!self.settings_open) {
                    self.focused_field = .none;
                    self.board_menu_open = false;
                }
                return .consumed;
            }

            if (self.settings_open) {
                // If the Board popup menu is open, handle menu item selection or dismiss it first
                if (self.board_menu_open and !status.power_connected) {
                    if (self.board_menu_rect.contains(pt)) {
                        const rel_y = y - (self.board_menu_rect.y + 4.0);
                        self.board_menu_open = false;
                        self.hovered_board_menu_idx = null;
                        if (rel_y >= 0.0) {
                            const idx: usize = @intFromFloat(@floor(rel_y / 32.0));
                            if (idx < BoardModel.all.len) {
                                const chosen = BoardModel.all[idx];
                                self.selected_board_model = chosen;
                                if (chosen != BoardModel.fromModel(status.model)) {
                                    self.randomizeIdentity();
                                }
                                return .select_board;
                            }
                        }
                        return .consumed;
                    }
                    if (self.board_menu_btn_rect.contains(pt)) {
                        self.board_menu_open = false;
                        self.hovered_board_menu_idx = null;
                        return .consumed;
                    }
                    self.board_menu_open = false;
                    self.hovered_board_menu_idx = null;
                }

                if (self.settings_panel_rect.contains(pt)) {
                    if (!status.power_connected) {
                        if (self.board_menu_btn_rect.contains(pt)) {
                            self.focused_field = .none;
                            self.board_menu_open = !self.board_menu_open;
                            return .consumed;
                        }
                        if (self.serial_field_rect.contains(pt)) {
                            self.focused_field = .serial;
                            return .consumed;
                        }
                        if (self.mac_field_rect.contains(pt)) {
                            self.focused_field = .mac;
                            return .consumed;
                        }
                        if (self.wifi_mac_field_rect.contains(pt)) {
                            self.focused_field = .wifi_mac;
                            return .consumed;
                        }
                        self.focused_field = .none;
                    } else {
                        self.focused_field = .none;
                    }
                    if (self.dhcp_toggle_rect.contains(pt)) {
                        return .toggle_dhcp;
                    }
                    return .consumed;
                }
            }

            self.focused_field = .none;

            const drawing = board.forModel(status.model) orelse &board.pi_zero;
            if (self.board_rect.contains(pt)) {
                const tr = boardTransform(drawing, self.board_rect);
                if (targetAt(drawing, .{ (x - tr.x) / tr.scale, (y - tr.y) / tr.scale }, status.sd_connected)) |target| {
                    return switch (target) {
                        .sd_connector => .toggle_sd,
                        .sd_card => if (status.sd_connected) .toggle_sd else .select_sd_image,
                        .hdmi => .toggle_hdmi,
                        .audio => .toggle_audio,
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
                self.focused_field = .none;
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
        const sc: u32 = @intFromFloat(@max(c.scale, 1.0));
        const bar_px_w = win_w * sc;
        const bar_px_h = title_bar_height * sc;
        const total_px = @as(usize, bar_px_w) * @as(usize, bar_px_h);
        if (total_px == 0 or c.pixels.len < total_px) return;

        const key: TitleCacheKey = .{
            .win_w = win_w,
            .scale = sc,
            .board_model = BoardModel.fromModel(self.title),
            .maximized = self.maximized,
            .sheet_open = self.sheet_open,
            .board_btn_hovered = self.board_btn_hovered,
            .board_btn_pressed = self.board_btn_pressed,
            .max_btn_hovered = self.max_btn_hovered,
            .max_btn_pressed = self.max_btn_pressed,
            .close_btn_hovered = self.close_btn_hovered,
            .close_btn_pressed = self.close_btn_pressed,
        };

        if (self.title_cache.len == total_px and std.meta.eql(self.title_cache_key, key)) {
            @memcpy(c.pixels[0..total_px], self.title_cache);
            return;
        }

        const t = &self.theme;
        const w_f: f32 = @floatFromInt(win_w);
        const h_f: f32 = @floatFromInt(title_bar_height);

        @memset(c.pixels[0..total_px], t.surface_container.toArgb());

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

        if (self.title_cache.len != total_px) {
            if (self.title_cache.len > 0) self.gpa.free(self.title_cache);
            self.title_cache = self.gpa.alloc(u32, total_px) catch &.{};
        }
        if (self.title_cache.len == total_px) {
            @memcpy(self.title_cache, c.pixels[0..total_px]);
            self.title_cache_key = key;
        }
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

    inline fn dimSpanSwar(span: []u32) void {
        for (span) |*dst| {
            const px = dst.*;
            const rb = (((px & 0x00FF00FF) * 115) >> 8) & 0x00FF00FF;
            const g = (((px & 0x0000FF00) * 115) >> 8) & 0x0000FF00;
            dst.* = 0xFF000000 | rb | g;
        }
    }

    fn paintSheet(
        self: *BoardUi,
        c: *Canvas,
        _: u32,
        win_h: u32,
        status: SystemStatus,
    ) void {
        const t = &self.theme;
        const sc_f = @max(c.scale, 1.0);
        const sc: u32 = @intFromFloat(sc_f);
        const h_f: f32 = @floatFromInt(win_h);
        const top_y: f32 = @floatFromInt(title_bar_height);

        const sr = self.sheet_rect;
        // Dim the HDMI display behind the drop-down sheet using SWAR (skipping the opaque upper body of sheet_rect)
        if (h_f > top_y) {
            const py_start: u32 = title_bar_height * sc;
            const py_end: u32 = @min(c.height, win_h * sc);
            const sr_x0: u32 = @intFromFloat(@max(0.0, @ceil((sr.x + 2.0) * sc_f)));
            const sr_x1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(c.width)), @floor((sr.x + sr.w - 2.0) * sc_f)));
            const sr_opaque_y1: u32 = @intFromFloat(@max(@as(f32, @floatFromInt(py_start)), @floor((sr.y + sr.h - 17.0) * sc_f)));

            for (py_start..py_end) |py| {
                const row = c.pixels[py * c.stride ..][0..c.width];
                if (py < sr_opaque_y1 and sr_x0 < sr_x1) {
                    dimSpanSwar(row[0..sr_x0]);
                    dimSpanSwar(row[sr_x1..c.width]);
                } else {
                    dimSpanSwar(row);
                }
            }
        }

        // Drop-down sheet container (anchored to the bottom of the TitleBar)
        const sheet_radii: Radii = .{ .tl = 0, .tr = 0, .br = 16, .bl = 16 };
        c.fillRoundedRect(sr, sheet_radii, t.surface);
        c.strokeRoundedRect(sr, sheet_radii, 1.0, t.outline_variant);

        // Cache the interior board diagram region (padded by 16px inside sheet_rect)
        const pad_in: f32 = 16.0;
        const cache_box_x = @max(@round(sr.x + 8.0), @round(self.board_rect.x - pad_in));
        const cache_box_y = @max(@round(sr.y + 4.0), @round(self.board_rect.y - pad_in));
        const cache_box_x1 = @min(@round(sr.x + sr.w - 8.0), @round(self.board_rect.x + self.board_rect.w + pad_in));
        const cache_box_y1 = @min(@round(sr.y + sr.h - 16.0), @round(self.board_rect.y + self.board_rect.h + pad_in));

        if (cache_box_x1 > cache_box_x and cache_box_y1 > cache_box_y) {
            const box_x_px: u32 = @intFromFloat(cache_box_x * sc_f);
            const box_y_px: u32 = @intFromFloat(cache_box_y * sc_f);
            const box_w_px: u32 = @intFromFloat((cache_box_x1 - cache_box_x) * sc_f);
            const box_h_px: u32 = @intFromFloat((cache_box_y1 - cache_box_y) * sc_f);
            const total_board_px = @as(usize, box_w_px) * @as(usize, box_h_px);

            const bkey: BoardCacheKey = .{
                .w_px = box_w_px,
                .h_px = box_h_px,
                .scale = sc,
                .board_model = BoardModel.fromModel(status.model),
                .hovered_target = self.hovered_target,
                .sd_connected = status.sd_connected,
                .hdmi_connected = status.hdmi_connected,
                .audio_connected = status.audio_connected,
                .power_connected = status.power_connected,
                .usb_hub_connected = status.usb_hub_connected,
                .usb_keyboard_connected = status.usb_keyboard_connected,
                .usb_mouse_connected = status.usb_mouse_connected,
                .ethernet_connected = status.ethernet_connected,
            };

            if (self.board_cache.len != total_board_px or !std.meta.eql(self.board_cache_key, bkey)) {
                if (self.board_cache.len != total_board_px) {
                    if (self.board_cache.len > 0) self.gpa.free(self.board_cache);
                    self.board_cache = self.gpa.alloc(u32, total_board_px) catch &.{};
                }
                if (self.board_cache.len == total_board_px) {
                    @memset(self.board_cache, t.surface.toArgb());
                    var sub_c: Canvas = .{
                        .pixels = self.board_cache,
                        .width = box_w_px,
                        .height = box_h_px,
                        .stride = box_w_px,
                        .scale = sc_f,
                        .origin = .{ -cache_box_x, -cache_box_y },
                        .font = &self.font,
                        .icon_font = &self.icon_font,
                        .cache = &self.cache,
                    };
                    const drawing = board.forModel(status.model) orelse &board.pi_zero;
                    self.paintBoardDrawing(&sub_c, drawing, self.board_rect, status);
                    self.board_cache_key = bkey;
                }
            }

            if (self.board_cache.len == total_board_px and box_x_px + box_w_px <= c.width and box_y_px + box_h_px <= c.height) {
                for (0..box_h_px) |ry| {
                    const dst_row = c.pixels[(box_y_px + ry) * c.stride + box_x_px ..][0..box_w_px];
                    const src_row = self.board_cache[ry * box_w_px ..][0..box_w_px];
                    @memcpy(dst_row, src_row);
                }
                self.paintSettingsSection(c, status);
                return;
            }
        }

        const drawing = board.forModel(status.model) orelse &board.pi_zero;
        self.paintBoardDrawing(c, drawing, self.board_rect, status);
        self.paintSettingsSection(c, status);
    }

    fn paintSettingsSection(self: *const BoardUi, c: *Canvas, status: SystemStatus) void {
        const t = &self.theme;
        const btn = self.settings_btn_rect;
        const btn_bg = if (self.settings_open)
            t.secondary_container
        else if (self.settings_btn_hovered)
            t.surface_container_highest
        else
            t.surface_container;

        c.fillRoundedRect(btn, .all(btn.h * 0.5), btn_bg);
        c.strokeRoundedRect(btn, .all(btn.h * 0.5), 1.0, if (self.settings_btn_hovered or self.settings_open) t.primary else t.outline_variant);

        const icon: Icon = if (self.settings_open) .expand_less else .expand_more;
        const icon_s: f32 = 18.0;
        const label = "Settings";
        const label_style: canvas_mod.Style = .{ .font = &self.font, .size = 13.5 };
        const label_w = c.measureText(13.5, label);
        const total_w = icon_s + 6.0 + label_w;
        const start_x = @round(btn.x + (btn.w - total_w) * 0.5);
        const fg = if (self.settings_open) t.primary else t.on_surface;

        c.drawIcon(icon, start_x, @round(btn.y + (btn.h - icon_s) * 0.5), icon_s, fg);
        _ = c.drawText(
            13.5,
            start_x + icon_s + 6.0,
            @round(btn.y + (btn.h - label_style.lineHeight()) * 0.5 + label_style.ascent()),
            label,
            fg,
        );

        if (!self.settings_open) return;

        const pr = self.settings_panel_rect;
        c.fillRoundedRect(pr, .all(12.0), t.surface_container);
        c.strokeRoundedRect(pr, .all(12.0), 1.0, t.outline_variant);

        // Top boot-time notice banner
        const boot_disabled = status.power_connected;
        const note = "Power down board to set board, serial number, and MAC addresses";
        _ = c.drawText(12.5, pr.x + 16.0, pr.y + 23.0, note, t.on_surface_variant);
        c.fillRect(.{ .x = pr.x + 16.0, .y = pr.y + 33.0, .w = pr.w - 32.0, .h = 1.0 }, t.outline_variant.withAlpha(0.6));

        const row_title_col = if (boot_disabled) t.on_surface.withAlpha(0.42) else t.on_surface;
        const row_sub_col = if (boot_disabled) t.on_surface_variant.withAlpha(0.42) else t.on_surface_variant;

        // Row 0: Board Model Menu Button
        const cur_board = BoardModel.fromModel(status.model);
        const row0_y = self.board_menu_btn_rect.y;
        _ = c.drawText(14.0, pr.x + 16.0, row0_y + 15.0, "Board", row_title_col);
        _ = c.drawText(11.5, pr.x + 16.0, row0_y + 30.0, "Hardware model", row_sub_col);
        self.paintMenuButton(c, self.board_menu_btn_rect, cur_board.windowTitle(), self.board_menu_open, self.board_menu_btn_hovered, boot_disabled);

        // Row 1: Serial Number
        const row1_y = self.serial_field_rect.y;
        _ = c.drawText(14.0, pr.x + 16.0, row1_y + 15.0, "Serial Number", row_title_col);
        _ = c.drawText(11.5, pr.x + 16.0, row1_y + 30.0, "64-bit hex board ID", row_sub_col);

        var serial_disp_buf: [18]u8 = undefined;
        const serial_slice = self.serial_hex[0..self.serial_len];
        const serial_disp = if (!boot_disabled and self.focused_field == .serial)
            std.fmt.bufPrint(&serial_disp_buf, "{s}|", .{serial_slice}) catch serial_slice
        else
            serial_slice;
        self.paintTextField(c, self.serial_field_rect, serial_disp, !boot_disabled and self.focused_field == .serial, self.serial_field_hovered, boot_disabled);

        // Row 2: Ethernet MAC Address ("USB Ethernet MAC" on Zero/A+ models, "Ethernet MAC" on B models)
        const row2_y = self.mac_field_rect.y;
        const eth_title = if (cur_board.usesExternalUsbHub()) "USB Ethernet MAC" else "Ethernet MAC";
        const eth_sub = if (cur_board.usesExternalUsbHub()) "External Ethernet hardware address" else "On-board Ethernet hardware address";
        _ = c.drawText(14.0, pr.x + 16.0, row2_y + 15.0, eth_title, row_title_col);
        _ = c.drawText(11.5, pr.x + 16.0, row2_y + 30.0, eth_sub, row_sub_col);

        var mac_disp_buf: [20]u8 = undefined;
        const mac_disp = formatMacDisplay(&mac_disp_buf, self.mac_hex[0..self.mac_len], !boot_disabled and self.focused_field == .mac);
        self.paintTextField(c, self.mac_field_rect, mac_disp, !boot_disabled and self.focused_field == .mac, self.mac_field_hovered, boot_disabled);

        // Row 2b (optional): Wireless MAC Address (only shown when a board with wireless is selected)
        if (cur_board.hasWireless()) {
            const row_wifi_y = self.wifi_mac_field_rect.y;
            _ = c.drawText(14.0, pr.x + 16.0, row_wifi_y + 15.0, "Wireless MAC", row_title_col);
            _ = c.drawText(11.5, pr.x + 16.0, row_wifi_y + 30.0, "On-board Wi-Fi hardware address", row_sub_col);

            var wifi_disp_buf: [20]u8 = undefined;
            const wifi_disp = formatMacDisplay(&wifi_disp_buf, self.wifi_mac_hex[0..self.wifi_mac_len], !boot_disabled and self.focused_field == .wifi_mac);
            self.paintTextField(c, self.wifi_mac_field_rect, wifi_disp, !boot_disabled and self.focused_field == .wifi_mac, self.wifi_mac_field_hovered, boot_disabled);
        }

        // Row 3: DHCP Server Toggle
        const row3_y = self.dhcp_toggle_rect.y;
        _ = c.drawText(14.0, pr.x + 16.0, row3_y + 13.0, "DHCP Server", t.on_surface);
        _ = c.drawText(11.5, pr.x + 16.0, row3_y + 28.0, "Lease 10.0.2.15/24 · Gateway & DNS 10.0.2.2", t.on_surface_variant);

        const sw = self.dhcp_toggle_rect;
        const sw_bg = if (status.dhcp_enabled) t.primary else t.surface_container_highest;
        c.fillRoundedRect(sw, .all(sw.h * 0.5), sw_bg);
        c.strokeRoundedRect(
            sw,
            .all(sw.h * 0.5),
            1.2,
            if (self.dhcp_toggle_hovered) t.on_surface else if (status.dhcp_enabled) t.primary else t.outline,
        );
        const knob_r: f32 = if (status.dhcp_enabled) 10.0 else 8.0;
        const knob_x: f32 = if (status.dhcp_enabled) (sw.x + sw.w - 14.0) else (sw.x + 14.0);
        const knob_col = if (status.dhcp_enabled) t.on_primary else t.outline;
        c.fillCircle(.{ knob_x, sw.y + sw.h * 0.5 }, knob_r, knob_col);

        const state_txt = if (status.dhcp_enabled) "Enabled" else "Disabled";
        const st_w = c.measureText(13.0, state_txt);
        _ = c.drawText(13.0, sw.x - 10.0 - st_w, row3_y + 19.0, state_txt, if (status.dhcp_enabled) t.primary else t.on_surface_variant);

        // Draw floating Board popup menu last so it overlays lower rows cleanly
        if (self.board_menu_open and !boot_disabled) {
            const mr = self.board_menu_rect;
            c.fillRoundedRect(mr, .all(8.0), t.surface_container_highest);
            c.strokeRoundedRect(mr, .all(8.0), 1.2, t.primary);
            const item_st: canvas_mod.Style = .{ .font = &self.font, .size = 13.0 };
            for (BoardModel.all, 0..) |bm, idx| {
                const item_y = mr.y + 4.0 + @as(f32, @floatFromInt(idx)) * 32.0;
                const item_r: Rect = .{ .x = mr.x + 4.0, .y = item_y, .w = mr.w - 8.0, .h = 32.0 };
                const is_sel = (bm == cur_board);
                const is_hov = (self.hovered_board_menu_idx == idx);
                if (is_sel or is_hov) {
                    c.fillRoundedRect(item_r, .all(6.0), if (is_sel) t.secondary_container else t.surface);
                }
                _ = c.drawText(
                    13.0,
                    item_r.x + 10.0,
                    @round(item_r.y + (item_r.h - item_st.lineHeight()) * 0.5 + item_st.ascent()),
                    bm.windowTitle(),
                    if (is_sel) t.primary else t.on_surface,
                );
            }
        }
    }

    fn formatMacDisplay(buf: *[20]u8, hex: []const u8, focused: bool) []const u8 {
        var len: usize = 0;
        for (hex, 0..) |ch, idx| {
            if (idx > 0 and (idx % 2) == 0 and len < buf.len) {
                buf[len] = ':';
                len += 1;
            }
            if (len < buf.len) {
                buf[len] = ch;
                len += 1;
            }
        }
        if (focused and len < buf.len) {
            buf[len] = '|';
            len += 1;
        }
        return buf[0..len];
    }

    fn paintMenuButton(self: *const BoardUi, c: *Canvas, r: Rect, label: []const u8, open: bool, hovered: bool, disabled: bool) void {
        const t = &self.theme;
        const bg = if (disabled)
            t.surface.withAlpha(0.45)
        else if (open)
            t.secondary_container
        else if (hovered)
            t.surface_container_highest
        else
            t.surface;
        const border = if (disabled)
            t.outline_variant.withAlpha(0.4)
        else if (open or hovered)
            t.primary
        else
            t.outline_variant;
        c.fillRoundedRect(r, .all(6.0), bg);
        c.strokeRoundedRect(r, .all(6.0), if (open) 1.5 else 1.0, border);
        const st: canvas_mod.Style = .{ .font = &self.font, .size = 13.0 };
        const fg = if (disabled) t.on_surface.withAlpha(0.42) else if (open) t.primary else t.on_surface;
        _ = c.drawText(
            13.0,
            r.x + 12.0,
            @round(r.y + (r.h - st.lineHeight()) * 0.5 + st.ascent()),
            label,
            fg,
        );
        const icon: Icon = if (open) .expand_less else .expand_more;
        const icon_s: f32 = 18.0;
        c.drawIcon(icon, @round(r.x + r.w - icon_s - 8.0), @round(r.y + (r.h - icon_s) * 0.5), icon_s, fg);
    }

    fn paintTextField(self: *const BoardUi, c: *Canvas, r: Rect, text: []const u8, focused: bool, hovered: bool, disabled: bool) void {
        const t = &self.theme;
        c.fillRoundedRect(r, .all(6.0), if (disabled) t.surface.withAlpha(0.45) else t.surface);
        const border_col = if (disabled)
            t.outline_variant.withAlpha(0.4)
        else if (focused)
            t.primary
        else if (hovered)
            t.on_surface_variant
        else
            t.outline_variant;
        c.strokeRoundedRect(r, .all(6.0), if (focused and !disabled) 1.8 else 1.0, border_col);
        const st: canvas_mod.Style = .{ .font = &self.font, .size = 13.5 };
        _ = c.drawText(
            13.5,
            r.x + 10.0,
            @round(r.y + (r.h - st.lineHeight()) * 0.5 + st.ascent()),
            text,
            if (disabled) t.on_surface.withAlpha(0.42) else t.on_surface,
        );
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
        const hl = HubLayout.forBoard(b);
        var usb_double_idx: usize = 0;
        for (b.parts) |part| {
            const part_hovered = switch (part.kind) {
                .micro_sd, .sd => self.hovered_target == .sd_connector or (status.sd_connected and self.hovered_target == .sd_card),
                .mini_hdmi, .hdmi, .micro_hdmi => self.hovered_target == .hdmi,
                .audio => self.hovered_target == .audio,
                .power, .usb_c_power => self.hovered_target == .power,
                .usb_otg => self.hovered_target == .usb_hub,
                .usb => hl.has_external_hub and self.hovered_target == .usb_hub,
                .usb_double => blk: {
                    const idx = usb_double_idx;
                    usb_double_idx += 1;
                    break :blk !hl.has_external_hub and (self.hovered_target == if (idx == 0) InteractiveTarget.usb_keyboard else InteractiveTarget.usb_mouse);
                },
                .ethernet => !hl.has_external_hub and self.hovered_target == .ethernet,
                else => false,
            };
            const pr = map(tr, part.rect);
            if (!part.underside) {
                if (partOverhangsBoard(b, &part)) {
                    fillOverhangingPart(c, &part, pr, s, t.surface, t.on_surface.withAlpha(0.04));
                }
                drawPart(c, &part, pr, s, if (part_hovered) t.primary else ink);
            }
            if (part_hovered) {
                c.fillRoundedRect(pr, partRadius(&part, s), t.primary.withAlpha(0.22));
            }
        }

        const max_y = tr.y + hl.bottom_cable_max_y * s;
        const max_x = tr.x + hl.right_cable_max_x * s;

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
                        self.hovered_target,
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
                    const hovered = (self.hovered_target == if (is_kbd) InteractiveTarget.usb_keyboard else InteractiveTarget.usb_mouse);
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
                    const hovered = (self.hovered_target == .ethernet);
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
            const is_hdmi = (part.kind == .mini_hdmi or part.kind == .hdmi or part.kind == .micro_hdmi);
            const is_power = (part.kind == .power or part.kind == .usb_c_power);
            const is_audio = (part.kind == .audio);
            if (is_hdmi or is_power or is_audio) {
                const hovered = if (is_power)
                    (self.hovered_target == .power)
                else if (is_audio)
                    (self.hovered_target == .audio)
                else
                    (self.hovered_target == .hdmi);
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
};

fn partOverhangsBoard(b: *const board.Board, part: *const board.Part) bool {
    if (part.underside) return false;
    const r = part.rect;
    return r.x < 0 or r.y < 0 or (r.x + r.w) > b.width or (r.y + r.h) > b.height;
}

fn partRadius(part: *const board.Part, s: f32) Radii {
    return switch (part.kind) {
        .usb, .usb_double, .ethernet, .hdmi, .mini_hdmi, .micro_hdmi, .power, .usb_c_power, .power_button, .usb_otg, .micro_sd, .sd => .all(0.4 * s),
        .antenna, .camera, .display, .camera_display, .pcie => .all(0.3 * s),
        else => .all(0.6 * s),
    };
}

fn fillOverhangingPart(c: *Canvas, part: *const board.Part, r: Rect, s: f32, surface_bg: Color, board_tint: Color) void {
    if (part.kind == .composite) {
        const body: Rect = .{ .x = r.x, .y = r.y + r.h * 0.45, .w = r.w, .h = r.h * 0.55 };
        const barrel: Rect = .{ .x = r.x + r.w * 0.2, .y = r.y, .w = r.w * 0.6, .h = r.h * 0.45 };
        c.fillRoundedRect(body, .all(0.6 * s), surface_bg);
        c.fillRoundedRect(body, .all(0.6 * s), board_tint);
        c.fillRoundedRect(barrel, .all(0.4 * s), surface_bg);
        c.fillRoundedRect(barrel, .all(0.4 * s), board_tint);
        return;
    }
    const rad = partRadius(part, s);
    c.fillRoundedRect(r, rad, surface_bg);
    c.fillRoundedRect(r, rad, board_tint);
}

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

    // 3. Three-Port USB Hub with Ethernet body
    c.fillRoundedRect(hub_r, .all(2.2 * s), surface_bg);
    c.fillRoundedRect(hub_r, .all(2.2 * s), if (hub_hovered) accent.withAlpha(0.16) else ink.withAlpha(0.05));
    c.strokeRoundedRect(hub_r, .all(2.2 * s), heavy_w, hub_ink);

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

    // 7. Clicking the bottom Settings button expands the sheet downward and exposes
    //    Serial Number, USB Ethernet MAC, and DHCP Server controls.
    const collapsed_h = ui.sheet_rect.h;
    const sbtn = ui.settings_btn_rect;
    _ = ui.pointerButton(sbtn.x + 10, sbtn.y + 10, true, status, &hw);
    try testing.expectEqual(Action.consumed, ui.pointerButton(sbtn.x + 10, sbtn.y + 10, false, status, &hw));
    try testing.expect(ui.settings_open);
    ui.updateLayout(win_w, win_h, status, &hw);
    try testing.expect(ui.sheet_rect.h > collapsed_h);

    // While status.power_connected == true, Board menu button, Serial Number, and MAC fields are disabled
    const bm_btn = ui.board_menu_btn_rect;
    _ = ui.pointerButton(bm_btn.x + 10, bm_btn.y + 10, true, status, &hw);
    try testing.expectEqual(Action.consumed, ui.pointerButton(bm_btn.x + 10, bm_btn.y + 10, false, status, &hw));
    try testing.expect(!ui.board_menu_open);
    try testing.expectEqual(@as(f32, 0.0), ui.wifi_mac_field_rect.w);

    const ser_r = ui.serial_field_rect;
    _ = ui.pointerButton(ser_r.x + 10, ser_r.y + 10, true, status, &hw);
    _ = ui.pointerButton(ser_r.x + 10, ser_r.y + 10, false, status, &hw);
    try testing.expectEqual(@as(@TypeOf(ui.focused_field), .none), ui.focused_field);

    // Powering down the board enables opening the Board menu and choosing A+, B+, Zero W, or Zero 2 W
    status.power_connected = false;
    _ = ui.pointerButton(bm_btn.x + 10, bm_btn.y + 10, true, status, &hw);
    try testing.expectEqual(Action.consumed, ui.pointerButton(bm_btn.x + 10, bm_btn.y + 10, false, status, &hw));
    try testing.expect(ui.board_menu_open);

    // Select item 0 (Raspberry Pi 1 Model A+) from the open popup menu
    const item0_y = ui.board_menu_rect.y + 4.0 + 0.0 * 32.0 + 16.0;
    _ = ui.pointerButton(ui.board_menu_rect.x + 20, item0_y, true, status, &hw);
    try testing.expectEqual(Action.select_board, ui.pointerButton(ui.board_menu_rect.x + 20, item0_y, false, status, &hw));
    try testing.expectEqual(BoardModel.pi_1_a_plus, ui.selected_board_model);
    status.board_model = ui.selected_board_model;
    status.model = status.board_model.dtModel();
    ui.updateLayout(win_w, win_h, status, &hw);
    try testing.expectEqualStrings("Raspberry Pi 1 Model A+", ui.title);
    try testing.expect(board.forModel(status.model).? == &board.pi1_a_plus);
    try testing.expectEqual(@as(f32, 0.0), ui.wifi_mac_field_rect.w);
    ui.paint(pixels, win_w, win_h, 1, status, &hw);

    // Select item 1 (Raspberry Pi 1 Model B+): B board has no external USB hub; USB & Ethernet ports are interactive directly
    _ = ui.pointerButton(ui.board_menu_btn_rect.x + 10, ui.board_menu_btn_rect.y + 10, true, status, &hw);
    _ = ui.pointerButton(ui.board_menu_btn_rect.x + 10, ui.board_menu_btn_rect.y + 10, false, status, &hw);
    const item1_y = ui.board_menu_rect.y + 4.0 + 1.0 * 32.0 + 16.0;
    _ = ui.pointerButton(ui.board_menu_rect.x + 20, item1_y, true, status, &hw);
    try testing.expectEqual(Action.select_board, ui.pointerButton(ui.board_menu_rect.x + 20, item1_y, false, status, &hw));
    try testing.expectEqual(BoardModel.pi_1_b_plus, ui.selected_board_model);
    status.board_model = ui.selected_board_model;
    status.model = status.board_model.dtModel();
    ui.updateLayout(win_w, win_h, status, &hw);
    try testing.expectEqualStrings("Raspberry Pi 1 Model B+", ui.title);
    try testing.expect(board.forModel(status.model).? == &board.pi1_b_plus);
    try testing.expect(!status.board_model.usesExternalUsbHub());
    try testing.expectEqual(InteractiveTarget.usb_keyboard, BoardUi.targetAt(&board.pi1_b_plus, .{ 92.0, 9.0 }, true).?);
    try testing.expectEqual(InteractiveTarget.usb_mouse, BoardUi.targetAt(&board.pi1_b_plus, .{ 92.0, 27.0 }, true).?);
    try testing.expectEqual(InteractiveTarget.ethernet, BoardUi.targetAt(&board.pi1_b_plus, .{ 92.0, 45.75 }, true).?);
    try testing.expectEqual(InteractiveTarget.audio, BoardUi.targetAt(&board.pi1_b_plus, .{ 53.5, 55.0 }, true).?);
    try testing.expect(status.audio_connected);
    status.audio_connected = false;
    ui.paint(pixels, win_w, win_h, 1, status, &hw);
    status.audio_connected = true;
    ui.paint(pixels, win_w, win_h, 1, status, &hw);

    // Select item 2 (Raspberry Pi 3 Model A+): A+ board with wireless and external USB hub
    _ = ui.pointerButton(ui.board_menu_btn_rect.x + 10, ui.board_menu_btn_rect.y + 10, true, status, &hw);
    _ = ui.pointerButton(ui.board_menu_btn_rect.x + 10, ui.board_menu_btn_rect.y + 10, false, status, &hw);
    const item2_y = ui.board_menu_rect.y + 4.0 + 2.0 * 32.0 + 16.0;
    _ = ui.pointerButton(ui.board_menu_rect.x + 20, item2_y, true, status, &hw);
    try testing.expectEqual(Action.select_board, ui.pointerButton(ui.board_menu_rect.x + 20, item2_y, false, status, &hw));
    try testing.expectEqual(BoardModel.pi_3_a_plus, ui.selected_board_model);
    status.board_model = ui.selected_board_model;
    status.model = status.board_model.dtModel();
    ui.updateLayout(win_w, win_h, status, &hw);
    try testing.expectEqualStrings("Raspberry Pi 3 Model A+", ui.title);
    try testing.expect(board.forModel(status.model).? == &board.pi3_a_plus);
    try testing.expect(status.board_model.usesExternalUsbHub());
    try testing.expect(ui.wifi_mac_field_rect.w > 0.0);
    ui.paint(pixels, win_w, win_h, 1, status, &hw);

    // Select item 3 (Raspberry Pi 3 Model B+): B+ board with wireless and direct USB/Ethernet ports
    _ = ui.pointerButton(ui.board_menu_btn_rect.x + 10, ui.board_menu_btn_rect.y + 10, true, status, &hw);
    _ = ui.pointerButton(ui.board_menu_btn_rect.x + 10, ui.board_menu_btn_rect.y + 10, false, status, &hw);
    const item3_y = ui.board_menu_rect.y + 4.0 + 3.0 * 32.0 + 16.0;
    _ = ui.pointerButton(ui.board_menu_rect.x + 20, item3_y, true, status, &hw);
    try testing.expectEqual(Action.select_board, ui.pointerButton(ui.board_menu_rect.x + 20, item3_y, false, status, &hw));
    try testing.expectEqual(BoardModel.pi_3_b_plus, ui.selected_board_model);
    status.board_model = ui.selected_board_model;
    status.model = status.board_model.dtModel();
    ui.updateLayout(win_w, win_h, status, &hw);
    try testing.expectEqualStrings("Raspberry Pi 3 Model B+", ui.title);
    try testing.expect(board.forModel(status.model).? == &board.pi3_b_plus);
    try testing.expect(!status.board_model.usesExternalUsbHub());
    try testing.expect(ui.wifi_mac_field_rect.w > 0.0);
    ui.paint(pixels, win_w, win_h, 1, status, &hw);

    // Select item 5 (Raspberry Pi Zero W) from the popup menu
    _ = ui.pointerButton(ui.board_menu_btn_rect.x + 10, ui.board_menu_btn_rect.y + 10, true, status, &hw);
    _ = ui.pointerButton(ui.board_menu_btn_rect.x + 10, ui.board_menu_btn_rect.y + 10, false, status, &hw);
    const item5_y = ui.board_menu_rect.y + 4.0 + 5.0 * 32.0 + 16.0;
    _ = ui.pointerButton(ui.board_menu_rect.x + 20, item5_y, true, status, &hw);
    try testing.expectEqual(Action.select_board, ui.pointerButton(ui.board_menu_rect.x + 20, item5_y, false, status, &hw));
    try testing.expectEqual(BoardModel.pi_zero_w, ui.selected_board_model);
    status.board_model = ui.selected_board_model;
    status.model = status.board_model.dtModel();
    ui.updateLayout(win_w, win_h, status, &hw);
    try testing.expectEqualStrings("Raspberry Pi Zero W", ui.title);
    try testing.expect(board.forModel(status.model).? == &board.pi_zero_w);
    // Wireless MAC row is now visible
    try testing.expect(ui.wifi_mac_field_rect.w > 0.0);

    // Open menu again and select item 6 (Raspberry Pi Zero 2 W)
    _ = ui.pointerButton(ui.board_menu_btn_rect.x + 10, ui.board_menu_btn_rect.y + 10, true, status, &hw);
    _ = ui.pointerButton(ui.board_menu_btn_rect.x + 10, ui.board_menu_btn_rect.y + 10, false, status, &hw);
    const item6_y = ui.board_menu_rect.y + 4.0 + 6.0 * 32.0 + 16.0;
    _ = ui.pointerButton(ui.board_menu_rect.x + 20, item6_y, true, status, &hw);
    try testing.expectEqual(Action.select_board, ui.pointerButton(ui.board_menu_rect.x + 20, item6_y, false, status, &hw));
    try testing.expectEqual(BoardModel.pi_zero_2_w, ui.selected_board_model);
    status.board_model = ui.selected_board_model;
    status.model = status.board_model.dtModel();
    ui.updateLayout(win_w, win_h, status, &hw);
    try testing.expectEqualStrings("Raspberry Pi Zero 2 W", ui.title);
    try testing.expect(board.forModel(status.model).? == &board.pi_zero_2_w);
    try testing.expect(ui.wifi_mac_field_rect.w > 0.0);

    _ = ui.pointerButton(ui.serial_field_rect.x + 10, ui.serial_field_rect.y + 10, true, status, &hw);
    _ = ui.pointerButton(ui.serial_field_rect.x + 10, ui.serial_field_rect.y + 10, false, status, &hw);
    try testing.expectEqual(@as(@TypeOf(ui.focused_field), .serial), ui.focused_field);

    const dhcp_r = ui.dhcp_toggle_rect;
    _ = ui.pointerButton(dhcp_r.x + 10, dhcp_r.y + 10, true, status, &hw);
    try testing.expectEqual(Action.toggle_dhcp, ui.pointerButton(dhcp_r.x + 10, dhcp_r.y + 10, false, status, &hw));
    status.dhcp_enabled = false;
    ui.paint(pixels, win_w, win_h, 1, status, &hw);

    // 8. Clicking outside the sheet (near bottom of window) closes the sheet
    _ = ui.pointerButton(640, 740, true, status, &hw);
    _ = ui.pointerButton(640, 740, false, status, &hw);
    try testing.expect(!ui.sheet_open);

    // 9. Verify board outline stops at the edge of overhanging connectors (e.g. HDMI on B+)
    ui.sheet_open = true;
    status.board_model = .pi_1_b_plus;
    status.model = status.board_model.dtModel();
    ui.updateLayout(win_w, win_h, status, &hw);
    ui.paint(pixels, win_w, win_h, 1, status, &hw);

    const b_plus = &board.pi1_b_plus;
    const b_tr = BoardUi.boardTransform(b_plus, ui.board_rect);
    // Point on the board's bottom outline (y = b_plus.height = 56.0) just inside the HDMI connector's left wall
    // (HDMI spans x = 24.4..39.6, inner slot spans x = 27.44..36.56; x = 25.9 is inside the HDMI body between wall and slot)
    const inside_hdmi_x: u32 = @intFromFloat(@round(b_tr.x + 25.9 * b_tr.scale));
    const board_bottom_y: u32 = @intFromFloat(@round(b_tr.y + (b_plus.height - 0.15) * b_tr.scale));
    // Point on the board's bottom outline outside any connector (x = 20.0, between power and HDMI)
    const outside_conn_x: u32 = @intFromFloat(@round(b_tr.x + 20.0 * b_tr.scale));
    const px_inside_hdmi = pixels[board_bottom_y * win_w + inside_hdmi_x];
    const px_board_outline = pixels[board_bottom_y * win_w + outside_conn_x];
    // Sample interior board background at (x = 20.0, y = 48.0)
    const interior_y: u32 = @intFromFloat(@round(b_tr.y + 48.0 * b_tr.scale));
    const px_board_bg = pixels[interior_y * win_w + outside_conn_x];
    try testing.expect(px_board_outline != px_board_bg);
    try testing.expectEqual(px_board_bg, px_inside_hdmi);
}


