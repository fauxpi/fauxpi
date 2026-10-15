//! Client-side Wayland window TitleBar (`44px` tall) and the drop-down
//! Interactive Board Sheet (`BoardSheet`), where each connector and peripheral
//! (Micro-SD card, Mini HDMI, Power, 3-port USB Hub with Ethernet, USB Keyboard,
//! USB Mouse, and Ethernet) is rendered visually and acts as a toggle button.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const board = @import("board.zig");
const gpio_model = @import("gpio_model.zig");
const soc_gpio = @import("../soc/gpio.zig");
const qcow2_mod = @import("../soc/qcow2.zig");

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
pub const SdCardSize = qcow2_mod.SdCardSize;
pub const Qcow2Disk = qcow2_mod.Qcow2Disk;

pub const SdCardEntry = struct {
    name_buf: [64]u8 = @splat(0),
    name_len: usize = 0,
    image_path_buf: [512]u8 = @splat(0),
    image_path_len: usize = 0,
    image_size_bytes: u64 = 0,
    size: SdCardSize = .gb_4,
    disk: Qcow2Disk,

    pub fn name(self: *const SdCardEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn imagePath(self: *const SdCardEntry) []const u8 {
        return self.image_path_buf[0..self.image_path_len];
    }

    pub fn deinit(self: *SdCardEntry) void {
        self.disk.deinit();
    }
};

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

    pub fn isBcm2837(self: BoardModel) bool {
        return switch (self) {
            .pi_3_a_plus, .pi_3_b_plus, .pi_zero_2_w => true,
            .pi_1_a_plus, .pi_1_b_plus, .pi_zero, .pi_zero_w => false,
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

    pub fn id(self: BoardModel) []const u8 {
        return switch (self) {
            .pi_1_a_plus => "pi_1_a_plus",
            .pi_1_b_plus => "pi_1_b_plus",
            .pi_3_a_plus => "pi_3_a_plus",
            .pi_3_b_plus => "pi_3_b_plus",
            .pi_zero => "pi_zero",
            .pi_zero_w => "pi_zero_w",
            .pi_zero_2_w => "pi_zero_2_w",
        };
    }

    pub fn fromId(s: []const u8) ?BoardModel {
        for (all) |bm| {
            if (std.mem.eql(u8, s, bm.id()) or std.mem.eql(u8, s, bm.windowTitle())) return bm;
        }
        return null;
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
    gpio_connected: bool = false,
    usb_hub_connected: bool = true,
    usb_keyboard_connected: bool = true,
    usb_mouse_connected: bool = true,
    ethernet_connected: bool = true,
    act_led_on: bool = false,
    pwr_led_on: bool = false,
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
    toggle_gpio,
    select_sd_image,
    select_sd_card,
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
    sd_card_name,
};

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

pub const BoardUi = struct {
    pub const title_bar_height: u32 = 44;
    pub const gpio_panel_height: u32 = 136;
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
        sd_card_name_hash: u64 = 0,
        sd_connected: bool = false,
        gpio_connected: bool = false,
        hdmi_connected: bool = false,
        audio_connected: bool = false,
        power_connected: bool = false,
        usb_hub_connected: bool = false,
        usb_keyboard_connected: bool = false,
        usb_mouse_connected: bool = false,
        ethernet_connected: bool = false,
        act_led_on: bool = false,
        pwr_led_on: bool = false,
    };

    pub const GpioCacheKey = struct {
        win_w: u32 = 0,
        scale: u32 = 0,
        board_model: BoardModel = .pi_zero,
        output_mask: u32 = 0,
        input_mask: u32 = 0,
        level_mask: u32 = 0,
        hovered_input_idx: ?usize = null,
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

    /// Persistent storage paths under `$XDG_DATA_HOME/fauxpi`.
    data_dir_buf: [512]u8 = @splat(0),
    data_dir_len: usize = 0,
    images_dir_buf: [512]u8 = @splat(0),
    images_dir_len: usize = 0,
    settings_path_buf: [512]u8 = @splat(0),
    settings_path_len: usize = 0,

    /// Virtual SD cards list, SD card selector menu, and Manage SD Cards popup states.
    sd_cards: std.ArrayListUnmanaged(SdCardEntry) = .empty,
    selected_sd_card_idx: ?usize = null,
    sd_card_menu_open: bool = false,
    hovered_sd_menu_idx: ?usize = null,
    sd_manage_open: bool = false,
    new_card_name_buf: [64]u8 = @splat(0),
    new_card_name_len: usize = 0,
    sd_name_field_hovered: bool = false,
    shift_held: bool = false,
    new_card_size: SdCardSize = .gb_4,
    hovered_sd_size_idx: ?usize = null,
    hovered_sd_card_row_idx: ?usize = null,
    sd_browse_btn_hovered: bool = false,
    sd_add_btn_hovered: bool = false,
    sd_manage_close_hovered: bool = false,
    pending_sd_image_path_buf: [512]u8 = @splat(0),
    pending_sd_image_path_len: usize = 0,
    pending_sd_image_size: u64 = 0,
    pending_sd_image_slice: ?[]const u8 = null,
    sd_error_buf: [160]u8 = @splat(0),
    sd_error_len: usize = 0,

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
    sd_card_menu_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    sd_manage_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    sd_manage_close_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    sd_name_field_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    sd_size_btn_rects: [SdCardSize.all.len]Rect = @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0 }),
    sd_browse_btn_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    sd_add_btn_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    /// Bottom GPIO Outputs (LEDs) & Inputs (Switches) box state (shown when `status.gpio_connected` is true).
    gpio_box_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    gpio_output_pins: [28]u6 = @splat(0),
    gpio_output_count: usize = 0,
    gpio_input_pins: [28]u6 = @splat(0),
    gpio_input_count: usize = 0,
    hovered_gpio_input_idx: ?usize = null,

    /// Cached rasterized pixel buffers for TitleBar, Board diagram, and GPIO panel.
    title_cache: []u32 = &.{},
    title_cache_key: TitleCacheKey = .{},
    board_cache: []u32 = &.{},
    board_cache_key: BoardCacheKey = .{},
    gpio_cache: []u32 = &.{},
    gpio_cache_key: GpioCacheKey = .{},

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
        ui.resetDefaultNewCardName();
        return ui;
    }

    pub fn deinit(self: *BoardUi) void {
        for (self.sd_cards.items) |*card| {
            card.deinit();
        }
        self.sd_cards.deinit(self.gpa);
        if (self.title_cache.len > 0) self.gpa.free(self.title_cache);
        if (self.board_cache.len > 0) self.gpa.free(self.board_cache);
        if (self.gpio_cache.len > 0) self.gpa.free(self.gpio_cache);
        self.cache.deinit();
    }

    pub fn dataDir(self: *const BoardUi) []const u8 {
        return self.data_dir_buf[0..self.data_dir_len];
    }

    pub fn imagesDir(self: *const BoardUi) []const u8 {
        return self.images_dir_buf[0..self.images_dir_len];
    }

    pub fn settingsPath(self: *const BoardUi) []const u8 {
        return self.settings_path_buf[0..self.settings_path_len];
    }

    pub fn newCardName(self: *const BoardUi) []const u8 {
        return self.new_card_name_buf[0..self.new_card_name_len];
    }

    pub fn setNewCardName(self: *BoardUi, name: []const u8) void {
        const n = @min(name.len, self.new_card_name_buf.len);
        @memcpy(self.new_card_name_buf[0..n], name[0..n]);
        self.new_card_name_len = n;
    }

    /// Sets `new_card_name_buf` to the first unused `"Card N"` (`"Card 1"`, `"Card 2"`, ...).
    pub fn resetDefaultNewCardName(self: *BoardUi) void {
        var n: usize = 1;
        while (n < 10_000) : (n += 1) {
            var cand_buf: [64]u8 = undefined;
            const cand = std.fmt.bufPrint(&cand_buf, "Card {d}", .{n}) catch break;
            if (!self.hasCardNamed(cand)) {
                self.setNewCardName(cand);
                return;
            }
        }
        self.setNewCardName("Card 1");
    }

    pub fn hasCardNamed(self: *const BoardUi, candidate: []const u8) bool {
        for (self.sd_cards.items) |*card| {
            if (std.ascii.eqlIgnoreCase(card.name(), candidate)) return true;
        }
        return false;
    }

    /// Resolves `$XDG_DATA_HOME/fauxpi` (or `$HOME/.local/share/fauxpi` when `XDG_DATA_HOME` is unset/empty).
    pub fn resolveXdgDataDir(buf: []u8, environ: std.process.Environ) ?[]const u8 {
        const Environ = std.process.Environ;
        if (Environ.getPosix(environ, "XDG_DATA_HOME")) |xdg| {
            const trimmed = std.mem.trimEnd(u8, xdg, "/");
            if (trimmed.len > 0) {
                return std.fmt.bufPrint(buf, "{s}/fauxpi", .{trimmed}) catch null;
            }
        }
        if (Environ.getPosix(environ, "HOME")) |home| {
            const trimmed = std.mem.trimEnd(u8, home, "/");
            if (trimmed.len > 0) {
                return std.fmt.bufPrint(buf, "{s}/.local/share/fauxpi", .{trimmed}) catch null;
            }
        }
        return null;
    }

    /// Configures persistent storage under `$XDG_DATA_HOME/fauxpi`, loading existing QCOW2 images
    /// from `$XDG_DATA_HOME/fauxpi/images` and board settings from `$XDG_DATA_HOME/fauxpi/settings.json`.
    pub fn configureXdgStorage(self: *BoardUi, environ: std.process.Environ, status: *SystemStatus) void {
        var dir_buf: [512]u8 = undefined;
        if (resolveXdgDataDir(&dir_buf, environ)) |dir| {
            self.configureDataDir(dir, status);
        }
    }

    /// Configures persistent storage under `data_dir` (`{data_dir}/images` and `{data_dir}/settings.json`),
    /// loads existing `.qcow2` images, and loads or initializes `settings.json`.
    pub fn configureDataDir(self: *BoardUi, data_dir: []const u8, status: *SystemStatus) void {
        const dlen = @min(data_dir.len, self.data_dir_buf.len);
        @memcpy(self.data_dir_buf[0..dlen], data_dir[0..dlen]);
        self.data_dir_len = dlen;

        const imgs = std.fmt.bufPrint(&self.images_dir_buf, "{s}/images", .{self.dataDir()}) catch "";
        self.images_dir_len = imgs.len;

        const spath = std.fmt.bufPrint(&self.settings_path_buf, "{s}/settings.json", .{self.dataDir()}) catch "";
        self.settings_path_len = spath.len;

        ensureDirPathLinux(self.dataDir());
        if (self.images_dir_len > 0) {
            ensureDirPathLinux(self.imagesDir());
            self.loadImagesFromDir();
        }
        if (self.settings_path_len > 0) {
            const loaded = self.loadSettings(status) catch false;
            if (!loaded) {
                self.saveSettings(status.*) catch {};
            }
        }
    }

    /// Scans `self.imagesDir()` (`$XDG_DATA_HOME/fauxpi/images`) for `.qcow2` files and opens them.
    pub fn loadImagesFromDir(self: *BoardUi) void {
        if (self.images_dir_len == 0) return;
        const dir_path = self.imagesDir();

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (dir_path.len >= path_buf.len) return;
        @memcpy(path_buf[0..dir_path.len], dir_path);
        path_buf[dir_path.len] = 0;

        const fd_rc = std.os.linux.openat(
            std.os.linux.AT.FDCWD,
            path_buf[0..dir_path.len :0],
            .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true },
            0,
        );
        if (std.os.linux.errno(fd_rc) != .SUCCESS) return;
        const dir_fd: std.os.linux.fd_t = @intCast(fd_rc);
        defer _ = std.os.linux.close(dir_fd);

        var dents_buf: [4096]u8 align(8) = undefined;
        while (true) {
            const n = std.os.linux.getdents64(dir_fd, &dents_buf, dents_buf.len);
            if (std.os.linux.errno(n) != .SUCCESS or n == 0) break;
            var at: usize = 0;
            while (at < n) {
                const reclen = std.mem.readInt(u16, dents_buf[at + 16 ..][0..2], .little);
                const d_name = std.mem.sliceTo(dents_buf[at + 19 .. at + reclen], 0);
                at += reclen;
                if (d_name.len <= ".qcow2".len or d_name[0] == '.') continue;
                if (!std.mem.endsWith(u8, d_name, ".qcow2")) continue;

                const card_name = d_name[0 .. d_name.len - ".qcow2".len];
                if (self.hasCardNamed(card_name)) continue;

                var full_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, d_name }) catch continue;

                var disk = Qcow2Disk.openExistingFile(self.gpa, full_path) catch continue;
                const sz = SdCardSize.smallestFitting(disk.virtual_size) orelse .gb_32;
                const entry = makeNamedSdCardEntry(card_name, full_path, disk.diskAllocatedBytes(), sz, disk);
                self.sd_cards.append(self.gpa, entry) catch {
                    disk.deinit();
                    continue;
                };
            }
        }

        var i: usize = 1;
        while (i < self.sd_cards.items.len) : (i += 1) {
            var j = i;
            while (j > 0 and std.mem.order(u8, self.sd_cards.items[j].name(), self.sd_cards.items[j - 1].name()) == .lt) : (j -= 1) {
                std.mem.swap(SdCardEntry, &self.sd_cards.items[j], &self.sd_cards.items[j - 1]);
            }
        }

        if (self.sd_cards.items.len > 0 and self.selected_sd_card_idx == null) {
            self.selected_sd_card_idx = 0;
        }
        self.resetDefaultNewCardName();
    }

    const PersistedSettings = struct {
        board_model: ?[]const u8 = null,
        serial: ?[]const u8 = null,
        mac_address: ?[]const u8 = null,
        wifi_mac_address: ?[]const u8 = null,
        dhcp_enabled: ?bool = null,
        selected_sd_card: ?[]const u8 = null,
        sd_connected: ?bool = null,
        gpio_connected: ?bool = null,
        hdmi_connected: ?bool = null,
        audio_connected: ?bool = null,
        usb_hub_connected: ?bool = null,
        usb_keyboard_connected: ?bool = null,
        usb_mouse_connected: ?bool = null,
        ethernet_connected: ?bool = null,
    };

    /// Writes the current board settings to `$XDG_DATA_HOME/fauxpi/settings.json`.
    pub fn saveSettings(self: *const BoardUi, status: SystemStatus) !void {
        if (self.settings_path_len == 0) return;
        if (self.data_dir_len > 0) ensureDirPathLinux(self.dataDir());

        const sel_name = if (self.selected_sd_card_idx) |idx|
            (if (idx < self.sd_cards.items.len) self.sd_cards.items[idx].name() else "")
        else
            "";

        var esc_name_buf: [140]u8 = undefined;
        var esc_len: usize = 0;
        for (sel_name) |ch| {
            if (ch == '"' or ch == '\\') {
                if (esc_len + 2 > esc_name_buf.len) break;
                esc_name_buf[esc_len] = '\\';
                esc_name_buf[esc_len + 1] = ch;
                esc_len += 2;
            } else if (ch >= 0x20) {
                if (esc_len + 1 > esc_name_buf.len) break;
                esc_name_buf[esc_len] = ch;
                esc_len += 1;
            }
        }

        var json_buf: [2048]u8 = undefined;
        const json_str = try std.fmt.bufPrint(
            &json_buf,
            \\{{
            \\  "board_model": "{s}",
            \\  "serial": "{s}",
            \\  "mac_address": "{s}",
            \\  "wifi_mac_address": "{s}",
            \\  "dhcp_enabled": {},
            \\  "selected_sd_card": "{s}",
            \\  "sd_connected": {},
            \\  "gpio_connected": {},
            \\  "hdmi_connected": {},
            \\  "audio_connected": {},
            \\  "usb_hub_connected": {},
            \\  "usb_keyboard_connected": {},
            \\  "usb_mouse_connected": {},
            \\  "ethernet_connected": {}
            \\}}
            \\
        ,
            .{
                status.board_model.id(),
                self.serial_hex[0..self.serial_len],
                self.mac_hex[0..self.mac_len],
                self.wifi_mac_hex[0..self.wifi_mac_len],
                status.dhcp_enabled,
                esc_name_buf[0..esc_len],
                status.sd_connected,
                status.gpio_connected,
                status.hdmi_connected,
                status.audio_connected,
                status.usb_hub_connected,
                status.usb_keyboard_connected,
                status.usb_mouse_connected,
                status.ethernet_connected,
            },
        );

        const path = self.settingsPath();
        var path_z: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= path_z.len) return error.NameTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const fd_rc = std.os.linux.openat(
            std.os.linux.AT.FDCWD,
            path_z[0..path.len :0],
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
            0o644,
        );
        if (std.os.linux.errno(fd_rc) != .SUCCESS) return error.FileOpenFailed;
        const fd: std.os.linux.fd_t = @intCast(fd_rc);
        defer _ = std.os.linux.close(fd);

        var written: usize = 0;
        while (written < json_str.len) {
            const rc = std.os.linux.write(fd, json_str[written..].ptr, json_str.len - written);
            if (std.os.linux.errno(rc) != .SUCCESS) return error.FileWriteFailed;
            written += rc;
        }
    }

    /// Reads board settings from `$XDG_DATA_HOME/fauxpi/settings.json` into `self` and `status`.
    /// Returns `true` if `settings.json` existed and was parsed.
    pub fn loadSettings(self: *BoardUi, status: *SystemStatus) !bool {
        if (self.settings_path_len == 0) return false;
        const path = self.settingsPath();

        var path_z: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= path_z.len) return error.NameTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const fd_rc = std.os.linux.openat(
            std.os.linux.AT.FDCWD,
            path_z[0..path.len :0],
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
            0,
        );
        if (std.os.linux.errno(fd_rc) != .SUCCESS) return false;
        const fd: std.os.linux.fd_t = @intCast(fd_rc);
        defer _ = std.os.linux.close(fd);

        var file_buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < file_buf.len) {
            const rc = std.os.linux.read(fd, file_buf[total..].ptr, file_buf.len - total);
            if (std.os.linux.errno(rc) != .SUCCESS) return error.FileReadFailed;
            if (rc == 0) break;
            total += rc;
        }

        const parsed = try std.json.parseFromSlice(
            PersistedSettings,
            self.gpa,
            file_buf[0..total],
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const cfg = parsed.value;

        if (cfg.board_model) |bm_str| {
            if (BoardModel.fromId(bm_str)) |bm| {
                self.selected_board_model = bm;
                status.board_model = bm;
                status.model = bm.dtModel();
                self.title = bm.windowTitle();
            }
        }
        if (cfg.serial) |ser| {
            self.setHexField(&self.serial_hex, &self.serial_len, ser, false);
        }
        if (cfg.mac_address) |mac| {
            self.setHexField(&self.mac_hex, &self.mac_len, mac, true);
        }
        if (cfg.wifi_mac_address) |wmac| {
            self.setHexField(&self.wifi_mac_hex, &self.wifi_mac_len, wmac, true);
        }
        status.serial_u64 = self.parsedSerial();
        status.mac_address = self.parsedMac();
        status.wifi_mac_address = self.parsedWifiMac();

        if (cfg.dhcp_enabled) |v| status.dhcp_enabled = v;
        if (cfg.gpio_connected) |v| status.gpio_connected = v;
        if (cfg.hdmi_connected) |v| status.hdmi_connected = v;
        if (cfg.audio_connected) |v| status.audio_connected = v;
        if (cfg.usb_hub_connected) |v| status.usb_hub_connected = v;
        if (cfg.usb_keyboard_connected) |v| status.usb_keyboard_connected = v;
        if (cfg.usb_mouse_connected) |v| status.usb_mouse_connected = v;
        if (cfg.ethernet_connected) |v| status.ethernet_connected = v;
        if (!status.board_model.usesExternalUsbHub()) {
            status.usb_hub_connected = true;
        }

        if (cfg.selected_sd_card) |sel_name| {
            if (sel_name.len > 0) {
                for (self.sd_cards.items, 0..) |*card, idx| {
                    if (std.mem.eql(u8, card.name(), sel_name)) {
                        self.selected_sd_card_idx = idx;
                        break;
                    }
                }
            }
        }
        if (cfg.sd_connected) |v| {
            status.sd_connected = v and (self.selected_sd_card_idx != null);
        }
        status.power_connected = false;
        return true;
    }

    fn setHexField(self: *BoardUi, dst: []u8, dst_len: *usize, src: []const u8, uppercase: bool) void {
        _ = self;
        var out_i: usize = 0;
        for (src) |ch| {
            if (std.ascii.isHex(ch) and out_i < dst.len) {
                dst[out_i] = if (uppercase) std.ascii.toUpper(ch) else std.ascii.toLower(ch);
                out_i += 1;
            }
        }
        if (out_i > 0) {
            dst_len.* = out_i;
        }
    }

    pub fn activeSdCard(self: *BoardUi) ?*SdCardEntry {
        const idx = self.selected_sd_card_idx orelse return null;
        if (idx >= self.sd_cards.items.len) return null;
        return &self.sd_cards.items[idx];
    }

    pub fn activeSdCardName(self: *const BoardUi) []const u8 {
        const idx = self.selected_sd_card_idx orelse return "";
        if (idx >= self.sd_cards.items.len) return "";
        return self.sd_cards.items[idx].name();
    }

    pub fn sdErrorMessage(self: *const BoardUi) []const u8 {
        return self.sd_error_buf[0..self.sd_error_len];
    }

    pub fn hasImageTooLargeError(self: *const BoardUi) bool {
        return self.pending_sd_image_path_len > 0 and self.pending_sd_image_size > self.new_card_size.bytes();
    }

    fn setSdError(self: *BoardUi, msg: []const u8) void {
        const n = @min(msg.len, self.sd_error_buf.len);
        @memcpy(self.sd_error_buf[0..n], msg[0..n]);
        self.sd_error_len = n;
    }

    pub fn revalidatePendingSdImage(self: *BoardUi) void {
        if (self.pending_sd_image_path_len == 0) {
            self.sd_error_len = 0;
            return;
        }
        if (self.pending_sd_image_size > self.new_card_size.bytes()) {
            const img_mb = (self.pending_sd_image_size + (1024 * 1024 - 1)) / (1024 * 1024);
            const msg = std.fmt.bufPrint(
                &self.sd_error_buf,
                "Error: Image ({d} MB) is too large for a {s} SD card",
                .{ img_mb, self.new_card_size.label() },
            ) catch "Error: Image is too large for selected SD card size";
            self.sd_error_len = msg.len;
        } else {
            self.sd_error_len = 0;
        }
    }

    /// Sets the pending image path and byte size in the Manage SD Cards dialog and validates it against `new_card_size`.
    pub fn setPendingSdImageFile(self: *BoardUi, path: []const u8, size_bytes: u64) void {
        const n = @min(path.len, self.pending_sd_image_path_buf.len);
        @memcpy(self.pending_sd_image_path_buf[0..n], path[0..n]);
        self.pending_sd_image_path_len = n;
        self.pending_sd_image_size = size_bytes;
        self.pending_sd_image_slice = null;
        self.revalidatePendingSdImage();
    }

    /// Sets an in-memory image slice as the pending image in the Manage SD Cards dialog and validates it against `new_card_size`.
    pub fn setPendingSdImageSlice(self: *BoardUi, name_or_path: []const u8, data: []const u8) void {
        const n = @min(name_or_path.len, self.pending_sd_image_path_buf.len);
        @memcpy(self.pending_sd_image_path_buf[0..n], name_or_path[0..n]);
        self.pending_sd_image_path_len = n;
        self.pending_sd_image_size = data.len;
        self.pending_sd_image_slice = data;
        self.revalidatePendingSdImage();
    }

    fn resolveNewCardName(self: *BoardUi, custom_name: ?[]const u8, buf: *[64]u8) []const u8 {
        if (custom_name) |cn| {
            const trimmed = std.mem.trim(u8, cn, " \t\r\n");
            if (trimmed.len > 0) {
                const n = @min(trimmed.len, buf.len);
                @memcpy(buf[0..n], trimmed[0..n]);
                return buf[0..n];
            }
        }
        const cur_trimmed = std.mem.trim(u8, self.newCardName(), " \t\r\n");
        if (cur_trimmed.len == 0) {
            self.resetDefaultNewCardName();
        }
        const active = std.mem.trim(u8, self.newCardName(), " \t\r\n");
        const n = @min(active.len, buf.len);
        @memcpy(buf[0..n], active[0..n]);
        return buf[0..n];
    }

    fn buildPersistentQcow2Path(self: *const BoardUi, card_name: []const u8, out_buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
        if (self.images_dir_len == 0) return null;
        ensureDirPathLinux(self.imagesDir());

        var safe_buf: [64]u8 = undefined;
        var safe_len: usize = 0;
        for (card_name) |ch| {
            if (safe_len >= safe_buf.len) break;
            if (ch == '/' or ch == '\\' or ch < 0x20) {
                safe_buf[safe_len] = '_';
            } else {
                safe_buf[safe_len] = ch;
            }
            safe_len += 1;
        }
        const stem = if (safe_len > 0) safe_buf[0..safe_len] else "Card";

        var suffix: usize = 1;
        while (suffix < 10_000) : (suffix += 1) {
            const path = if (suffix == 1)
                std.fmt.bufPrint(out_buf, "{s}/{s}.qcow2", .{ self.imagesDir(), stem }) catch return null
            else
                std.fmt.bufPrint(out_buf, "{s}/{s}-{d}.qcow2", .{ self.imagesDir(), stem, suffix }) catch return null;
            if (!fileExistsLinux(path)) return path;
        }
        return null;
    }

    /// Creates a new QCOW2-backed SD card from an in-memory image slice using the current `newCardName()`
    /// (defaulting to `"Card 1"`, `"Card 2"`, etc.).
    pub fn addSdCardFromSlice(self: *BoardUi, label_or_path: []const u8, size: SdCardSize, image_bytes: []const u8) !usize {
        return self.addNamedSdCardFromSlice(null, label_or_path, size, image_bytes);
    }

    /// Creates a new QCOW2-backed SD card with an optional explicit `card_name` from an in-memory image slice.
    pub fn addNamedSdCardFromSlice(
        self: *BoardUi,
        card_name_opt: ?[]const u8,
        label_or_path: []const u8,
        size: SdCardSize,
        image_bytes: []const u8,
    ) !usize {
        if (image_bytes.len > size.bytes()) {
            self.new_card_size = size;
            self.setPendingSdImageSlice(label_or_path, image_bytes);
            return error.ImageTooLarge;
        }
        var name_buf: [64]u8 = undefined;
        const card_name = self.resolveNewCardName(card_name_opt, &name_buf);

        var qcow2_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const qcow2_path = self.buildPersistentQcow2Path(card_name, &qcow2_path_buf);

        var disk = try Qcow2Disk.createFromSliceAtPath(self.gpa, size.bytes(), image_bytes, qcow2_path);
        errdefer disk.deinit();

        const entry_path = qcow2_path orelse label_or_path;
        const entry = makeNamedSdCardEntry(card_name, entry_path, image_bytes.len, size, disk);
        try self.sd_cards.append(self.gpa, entry);
        const idx = self.sd_cards.items.len - 1;
        self.selected_sd_card_idx = idx;
        self.sd_error_len = 0;
        self.resetDefaultNewCardName();
        return idx;
    }

    /// Creates a new QCOW2-backed SD card by streaming an image file from disk using the current `newCardName()`
    /// (defaulting to `"Card 1"`, `"Card 2"`, etc.).
    pub fn addSdCardFromFile(self: *BoardUi, path: []const u8, size: SdCardSize) !usize {
        return self.addNamedSdCardFromFile(null, path, size);
    }

    /// Creates a new QCOW2-backed SD card with an optional explicit `card_name` by streaming an image file from disk.
    pub fn addNamedSdCardFromFile(self: *BoardUi, card_name_opt: ?[]const u8, path: []const u8, size: SdCardSize) !usize {
        const file_size = try Qcow2Disk.getFileSizeLinux(path);
        if (file_size > size.bytes()) {
            self.new_card_size = size;
            self.setPendingSdImageFile(path, file_size);
            return error.ImageTooLarge;
        }
        var name_buf: [64]u8 = undefined;
        const card_name = self.resolveNewCardName(card_name_opt, &name_buf);

        var qcow2_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const qcow2_path = self.buildPersistentQcow2Path(card_name, &qcow2_path_buf);

        var disk = try Qcow2Disk.createFromImageFileAtPath(self.gpa, size.bytes(), path, qcow2_path);
        errdefer disk.deinit();

        const entry_path = qcow2_path orelse path;
        const entry = makeNamedSdCardEntry(card_name, entry_path, file_size, size, disk);
        try self.sd_cards.append(self.gpa, entry);
        const idx = self.sd_cards.items.len - 1;
        self.selected_sd_card_idx = idx;
        self.sd_error_len = 0;
        self.resetDefaultNewCardName();
        return idx;
    }

    pub fn addPendingSdCard(self: *BoardUi) bool {
        if (self.pending_sd_image_path_len == 0) {
            self.setSdError("Error: Choose an image file to put on the SD card");
            return false;
        }
        self.revalidatePendingSdImage();
        if (self.sd_error_len > 0) return false;

        var path_copy: [512]u8 = undefined;
        const path_len = self.pending_sd_image_path_len;
        @memcpy(path_copy[0..path_len], self.pending_sd_image_path_buf[0..path_len]);
        const path = path_copy[0..path_len];

        if (self.pending_sd_image_slice) |slice| {
            _ = self.addSdCardFromSlice(path, self.new_card_size, slice) catch |err| {
                self.setSdError(@errorName(err));
                return false;
            };
        } else {
            _ = self.addSdCardFromFile(path, self.new_card_size) catch |err| {
                self.setSdError(@errorName(err));
                return false;
            };
        }
        self.pending_sd_image_path_len = 0;
        self.pending_sd_image_size = 0;
        self.pending_sd_image_slice = null;
        return true;
    }

    fn makeNamedSdCardEntry(card_name: []const u8, path: []const u8, img_size: u64, size: SdCardSize, disk: Qcow2Disk) SdCardEntry {
        var entry: SdCardEntry = .{
            .image_size_bytes = img_size,
            .size = size,
            .disk = disk,
        };
        const plen = @min(path.len, entry.image_path_buf.len);
        @memcpy(entry.image_path_buf[0..plen], path[0..plen]);
        entry.image_path_len = plen;

        const nlen = @min(card_name.len, entry.name_buf.len);
        @memcpy(entry.name_buf[0..nlen], card_name[0..nlen]);
        entry.name_len = nlen;
        return entry;
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
                .micro_sd, .sd => {
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

    pub fn updateModifierKey(self: *BoardUi, evdev_key: u32, pressed: bool) void {
        if (evdev_key == 42 or evdev_key == 54) {
            self.shift_held = pressed;
        }
    }

    /// Handles an evdev key press when a text field (`serial`, `mac`, `wifi_mac`, or `sd_card_name`) is focused.
    /// Returns true if the key was consumed by the editor.
    pub fn handleKey(self: *BoardUi, evdev_key: u32) bool {
        if (!self.sheet_open or self.focused_field == .none) return false;
        if (self.focused_field == .sd_card_name) {
            if (!self.sd_manage_open) return false;
        } else {
            if (!self.settings_open) return false;
        }

        // Left Shift (42) or Right Shift (54)
        if (evdev_key == 42 or evdev_key == 54) {
            self.shift_held = true;
            return true;
        }

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
                .sd_card_name => if (self.new_card_name_len > 0) {
                    self.new_card_name_len -= 1;
                },
                .none => {},
            }
            return true;
        }

        if (self.focused_field == .sd_card_name) {
            if (evdevKeyToCardNameChar(evdev_key, self.shift_held)) |ch| {
                if (self.new_card_name_len < self.new_card_name_buf.len) {
                    self.new_card_name_buf[self.new_card_name_len] = ch;
                    self.new_card_name_len += 1;
                }
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
                .sd_card_name, .none => {},
            }
            return true;
        }
        return true;
    }

    /// Updates layout geometry for `(win_w, win_h)` so hit testing and painting match.
    pub fn updateLayout(self: *BoardUi, win_w: u32, win_h: u32, status: SystemStatus, gpio_hw: *const Gpio) void {
        self.last_win_w = win_w;
        self.last_win_h = win_h;
        const cur_board = BoardModel.fromModel(status.model);
        self.title = cur_board.windowTitle();
        if (status.power_connected and self.focused_field != .sd_card_name) {
            self.focused_field = .none;
            self.board_menu_open = false;
        }
        if (!cur_board.hasWireless() and self.focused_field == .wifi_mac) {
            self.focused_field = .none;
        }

        const w_f: f32 = @floatFromInt(win_w);
        const h_f: f32 = @floatFromInt(win_h);
        const gpio_h: f32 = @floatFromInt(gpio_panel_height);
        if (status.gpio_connected and h_f > gpio_h) {
            self.gpio_box_rect = .{
                .x = 0.0,
                .y = h_f - gpio_h,
                .w = w_f,
                .h = gpio_h,
            };
        } else {
            self.gpio_box_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        }

        // Populate ordered header GPIO outputs and inputs (from low to high pin number 0..27)
        const hdr_mask = headerGpioMask(status.model);
        var out_n: usize = 0;
        var in_n: usize = 0;
        for (0..28) |pin_usize| {
            const pin: u6 = @intCast(pin_usize);
            if (((hdr_mask >> @intCast(pin)) & 1) == 0) continue;
            switch (gpio_hw.getPinFunction(pin)) {
                .output => {
                    self.gpio_output_pins[out_n] = pin;
                    out_n += 1;
                },
                .input => {
                    self.gpio_input_pins[in_n] = pin;
                    in_n += 1;
                },
                else => {},
            }
        }
        self.gpio_output_count = out_n;
        self.gpio_input_count = in_n;
        if (self.hovered_gpio_input_idx) |hidx| {
            if (!status.gpio_connected or hidx >= in_n) self.hovered_gpio_input_idx = null;
        }

        const sheet_w = @min(@max(w_f - 32.0, 360.0), 740.0);
        const sheet_x = @round((w_f - sheet_w) * 0.5);
        const sheet_y: f32 = @floatFromInt(title_bar_height);
        const pad: f32 = 24.0;

        const drawing = board.forModel(status.model) orelse &board.pi_zero;
        const bounds = boardBoundsWithPeripherals(drawing);
        const max_bw: f32 = sheet_w - 2.0 * pad;
        const max_bh: f32 = 300.0;
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

        // SD Card selector popup menu (anchored near the SD card on the left of the board)
        const sd_menu_w: f32 = 250.0;
        const sd_menu_h: f32 = @as(f32, @floatFromInt(self.sd_cards.items.len + 1)) * 32.0 + 12.0;
        self.sd_card_menu_rect = .{
            .x = @round(@max(sheet_x + 12.0, self.board_rect.x + 8.0)),
            .y = @round(self.board_rect.y + 48.0),
            .w = sd_menu_w,
            .h = sd_menu_h,
        };

        // Manage SD Cards modal popup (centered in the sheet)
        const mg_w: f32 = @min(520.0, sheet_w - 32.0);
        const mg_x: f32 = @round(sheet_x + (sheet_w - mg_w) * 0.5);
        const mg_y: f32 = @round(sheet_y + 18.0);
        self.sd_manage_close_rect = .{ .x = mg_x + mg_w - 40.0, .y = mg_y + 12.0, .w = 28.0, .h = 28.0 };

        const list_y0: f32 = mg_y + 72.0;
        const list_h: f32 = if (self.sd_cards.items.len == 0)
            36.0
        else
            @as(f32, @floatFromInt(self.sd_cards.items.len)) * 32.0;

        const add_y0: f32 = list_y0 + list_h + 16.0;
        const name_row_y: f32 = add_y0 + 24.0;
        self.sd_name_field_rect = .{
            .x = mg_x + 16.0,
            .y = name_row_y,
            .w = mg_w - 32.0,
            .h = 32.0,
        };

        const size_row_y: f32 = name_row_y + 54.0;
        const size_gap: f32 = 6.0;
        const size_count: f32 = @floatFromInt(SdCardSize.all.len);
        const size_btn_w: f32 = @floor((mg_w - 32.0 - (size_count - 1.0) * size_gap) / size_count);
        for (0..SdCardSize.all.len) |i| {
            const fi: f32 = @floatFromInt(i);
            self.sd_size_btn_rects[i] = .{
                .x = mg_x + 16.0 + fi * (size_btn_w + size_gap),
                .y = size_row_y,
                .w = size_btn_w,
                .h = 28.0,
            };
        }

        const img_row_y: f32 = size_row_y + 52.0;
        self.sd_browse_btn_rect = .{
            .x = mg_x + mg_w - 16.0 - 116.0,
            .y = img_row_y,
            .w = 116.0,
            .h = 32.0,
        };

        const btn_row_y: f32 = img_row_y + (if (self.sd_error_len > 0) @as(f32, 70.0) else @as(f32, 44.0));
        self.sd_add_btn_rect = .{
            .x = mg_x + mg_w - 16.0 - 116.0,
            .y = btn_row_y,
            .w = 116.0,
            .h = 32.0,
        };

        const mg_h: f32 = (btn_row_y + 32.0 + 16.0) - mg_y;
        self.sd_manage_rect = .{
            .x = mg_x,
            .y = mg_y,
            .w = mg_w,
            .h = mg_h,
        };

        const menu_bottom: f32 = if (self.board_menu_open) (self.board_menu_rect.y + self.board_menu_rect.h + 16.0) else 0.0;
        const sd_menu_bottom: f32 = if (self.sd_card_menu_open) (self.sd_card_menu_rect.y + self.sd_card_menu_rect.h + 16.0) else 0.0;
        const sd_manage_bottom: f32 = if (self.sd_manage_open) (self.sd_manage_rect.y + self.sd_manage_rect.h + 18.0) else 0.0;
        const base_bottom: f32 = if (self.settings_open)
            @max(panel_y + panel_h + 16.0, menu_bottom)
        else
            (btn_y + btn_h + 14.0);
        const total_h: f32 = @max(base_bottom, @max(sd_menu_bottom, sd_manage_bottom)) - sheet_y;

        self.sheet_rect = .{
            .x = sheet_x,
            .y = sheet_y,
            .w = sheet_w,
            .h = total_h,
        };
    }

    /// Returns a 28-bit mask of BCM GPIO numbers (`0..27`) exposed on the board's 40-pin GPIO header.
    pub fn headerGpioMask(model: []const u8) u32 {
        const hdr = gpio_model.headerFor(model) orelse return 0x0fff_ffff;
        var mask: u32 = 0;
        for (hdr) |p| {
            switch (p) {
                .gpio => |bcm| {
                    if (bcm < 28) mask |= (@as(u32, 1) << @intCast(bcm));
                },
                else => {},
            }
        }
        return mask;
    }

    /// Returns the bounding box of output LED cell `idx` inside `gpio_box_rect`.
    pub fn gpioOutputLedRect(self: *const BoardUi, idx: usize) Rect {
        const gb = self.gpio_box_rect;
        const start_x = gb.x + 112.0;
        const avail_w = @max(280.0, gb.w - 112.0 - 20.0);
        const count: f32 = @floatFromInt(@max(self.gpio_output_count, 28));
        const pitch: f32 = @min(40.0, @floor(avail_w / count));
        return .{
            .x = start_x + @as(f32, @floatFromInt(idx)) * pitch,
            .y = gb.y + 10.0,
            .w = pitch - 2.0,
            .h = 46.0,
        };
    }

    /// Returns the clickable bounding box of input switch `idx` inside `gpio_box_rect`.
    pub fn gpioInputSwitchRect(self: *const BoardUi, idx: usize) Rect {
        const gb = self.gpio_box_rect;
        const start_x = gb.x + 112.0;
        const avail_w = @max(280.0, gb.w - 112.0 - 20.0);
        const count: f32 = @floatFromInt(@max(self.gpio_input_count, 28));
        const pitch: f32 = @min(40.0, @floor(avail_w / count));
        return .{
            .x = start_x + @as(f32, @floatFromInt(idx)) * pitch,
            .y = gb.y + 68.0,
            .w = pitch - 2.0,
            .h = 58.0,
        };
    }

    /// Returns true if `(x, y)` is over the TitleBar, an open BoardSheet, or the connected GPIO box.
    pub fn isPointInUi(self: *const BoardUi, x: f32, y: f32, status: SystemStatus) bool {
        if (y < @as(f32, @floatFromInt(title_bar_height))) return true;
        if (self.sheet_open) return true;
        if (status.gpio_connected and self.gpio_box_rect.contains(.{ x, y })) return true;
        return false;
    }

    pub fn sdMenuRowRect(self: *const BoardUi, idx: usize) Rect {
        const mr = self.sd_card_menu_rect;
        return .{
            .x = mr.x + 4.0,
            .y = mr.y + 4.0 + @as(f32, @floatFromInt(idx)) * 32.0,
            .w = mr.w - 8.0,
            .h = 32.0,
        };
    }

    pub fn sdMenuManageRowRect(self: *const BoardUi) Rect {
        const mr = self.sd_card_menu_rect;
        const off: f32 = if (self.sd_cards.items.len > 0) 8.0 else 4.0;
        return .{
            .x = mr.x + 4.0,
            .y = mr.y + off + @as(f32, @floatFromInt(self.sd_cards.items.len)) * 32.0,
            .w = mr.w - 8.0,
            .h = 32.0,
        };
    }

    pub fn sdManageCardRowRect(self: *const BoardUi, idx: usize) Rect {
        const mr = self.sd_manage_rect;
        return .{
            .x = mr.x + 16.0,
            .y = mr.y + 72.0 + @as(f32, @floatFromInt(idx)) * 32.0,
            .w = mr.w - 32.0,
            .h = 30.0,
        };
    }

    /// Handles pointer motion at `(x, y)` in window coordinates.
    /// Returns true if the pointer is over the TitleBar, an open BoardSheet, or the connected GPIO box.
    pub fn pointerMotion(self: *BoardUi, x: f32, y: f32, status: SystemStatus, gpio_hw: *const Gpio) bool {
        self.updateLayout(self.last_win_w, self.last_win_h, status, gpio_hw);
        const pt: Point = .{ x, y };

        self.board_btn_hovered = self.boardBtnRect(self.last_win_w).contains(pt);
        self.max_btn_hovered = maxBtnRect(self.last_win_w).contains(pt);
        self.close_btn_hovered = closeBtnRect(self.last_win_w).contains(pt);

        // Track hover over GPIO input switches in the GPIO box below the display
        self.hovered_gpio_input_idx = null;
        if (status.gpio_connected and self.gpio_box_rect.contains(pt) and (!self.sheet_open or !self.sheet_rect.contains(pt))) {
            for (0..self.gpio_input_count) |idx| {
                if (self.gpioInputSwitchRect(idx).contains(pt)) {
                    self.hovered_gpio_input_idx = idx;
                    break;
                }
            }
        }

        if (!self.sheet_open) {
            self.hovered_target = null;
            self.settings_btn_hovered = false;
            self.board_menu_btn_hovered = false;
            self.hovered_board_menu_idx = null;
            self.serial_field_hovered = false;
            self.mac_field_hovered = false;
            self.wifi_mac_field_hovered = false;
            self.dhcp_toggle_hovered = false;
            self.hovered_sd_menu_idx = null;
            self.hovered_sd_size_idx = null;
            self.hovered_sd_card_row_idx = null;
            self.sd_name_field_hovered = false;
            self.sd_browse_btn_hovered = false;
            self.sd_add_btn_hovered = false;
            self.sd_manage_close_hovered = false;
            return y < @as(f32, @floatFromInt(title_bar_height)) or (status.gpio_connected and self.gpio_box_rect.contains(pt));
        }

        if (self.sd_manage_open) {
            self.hovered_target = null;
            self.sd_manage_close_hovered = self.sd_manage_close_rect.contains(pt);
            self.sd_name_field_hovered = self.sd_name_field_rect.contains(pt);
            self.sd_browse_btn_hovered = self.sd_browse_btn_rect.contains(pt);
            self.sd_add_btn_hovered = self.sd_add_btn_rect.contains(pt);
            self.hovered_sd_size_idx = null;
            for (self.sd_size_btn_rects, 0..) |sr, idx| {
                if (sr.contains(pt)) {
                    self.hovered_sd_size_idx = idx;
                    break;
                }
            }
            self.hovered_sd_card_row_idx = null;
            for (0..self.sd_cards.items.len) |idx| {
                if (self.sdManageCardRowRect(idx).contains(pt)) {
                    self.hovered_sd_card_row_idx = idx;
                    break;
                }
            }
            return true;
        } else {
            self.hovered_sd_size_idx = null;
            self.hovered_sd_card_row_idx = null;
            self.sd_name_field_hovered = false;
            self.sd_browse_btn_hovered = false;
            self.sd_add_btn_hovered = false;
            self.sd_manage_close_hovered = false;
        }

        if (self.sd_card_menu_open) {
            self.hovered_sd_menu_idx = null;
            for (0..self.sd_cards.items.len) |idx| {
                if (self.sdMenuRowRect(idx).contains(pt)) {
                    self.hovered_sd_menu_idx = idx;
                    break;
                }
            }
            if (self.sdMenuManageRowRect().contains(pt)) {
                self.hovered_sd_menu_idx = self.sd_cards.items.len;
            }
            if (self.sd_card_menu_rect.contains(pt)) {
                self.hovered_target = null;
                return true;
            }
        } else {
            self.hovered_sd_menu_idx = null;
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
        self.hovered_sd_menu_idx = null;
        self.hovered_sd_size_idx = null;
        self.hovered_sd_card_row_idx = null;
        self.sd_name_field_hovered = false;
        self.sd_browse_btn_hovered = false;
        self.sd_add_btn_hovered = false;
        self.sd_manage_close_hovered = false;
        self.hovered_gpio_input_idx = null;
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
                        self.sd_card_menu_open = false;
                        self.sd_manage_open = false;
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

        // GPIO box below the display (interactive when not covered by the drop-down sheet)
        if (status.gpio_connected and self.gpio_box_rect.contains(pt) and (!self.sheet_open or !self.sheet_rect.contains(pt))) {
            if (!pressed) {
                for (0..self.gpio_input_count) |idx| {
                    if (self.gpioInputSwitchRect(idx).contains(pt)) {
                        const pin = self.gpio_input_pins[idx];
                        gpio_hw.setExternalPin(pin, !gpio_hw.getPinLevel(pin));
                        return .consumed;
                    }
                }
            }
            return .consumed;
        }

        if (!self.sheet_open) return .none;

        if (pressed) {
            if (!self.sd_manage_open and !self.sd_card_menu_open and self.settings_btn_rect.contains(pt)) {
                self.settings_btn_pressed = true;
            }
            return .consumed;
        } else {
            defer self.settings_btn_pressed = false;

            // 1. Modal Manage SD Cards popup handling
            if (self.sd_manage_open) {
                if (self.sd_name_field_rect.contains(pt)) {
                    self.focused_field = .sd_card_name;
                    return .consumed;
                }
                self.focused_field = .none;
                if (self.sd_manage_close_rect.contains(pt)) {
                    self.sd_manage_open = false;
                    return .consumed;
                }
                for (self.sd_size_btn_rects, 0..) |sr, idx| {
                    if (sr.contains(pt)) {
                        self.new_card_size = SdCardSize.all[idx];
                        self.revalidatePendingSdImage();
                        return .consumed;
                    }
                }
                if (self.sd_browse_btn_rect.contains(pt)) {
                    return .select_sd_image;
                }
                if (self.sd_add_btn_rect.contains(pt)) {
                    if (self.addPendingSdCard()) {
                        self.sd_manage_open = false;
                        return .select_sd_card;
                    }
                    return .consumed;
                }
                for (0..self.sd_cards.items.len) |idx| {
                    if (self.sdManageCardRowRect(idx).contains(pt)) {
                        self.selected_sd_card_idx = idx;
                        return .select_sd_card;
                    }
                }
                if (!self.sd_manage_rect.contains(pt)) {
                    self.sd_manage_open = false;
                }
                return .consumed;
            }

            // 2. SD Card selector menu handling
            if (self.sd_card_menu_open) {
                if (self.sd_card_menu_rect.contains(pt)) {
                    for (0..self.sd_cards.items.len) |idx| {
                        if (self.sdMenuRowRect(idx).contains(pt)) {
                            self.selected_sd_card_idx = idx;
                            self.sd_card_menu_open = false;
                            self.hovered_sd_menu_idx = null;
                            return .select_sd_card;
                        }
                    }
                    if (self.sdMenuManageRowRect().contains(pt)) {
                        self.sd_card_menu_open = false;
                        self.hovered_sd_menu_idx = null;
                        self.sd_manage_open = true;
                        if (self.new_card_name_len == 0) self.resetDefaultNewCardName();
                        return .consumed;
                    }
                    return .consumed;
                }
                self.sd_card_menu_open = false;
                self.hovered_sd_menu_idx = null;
                return .consumed;
            }

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
                        .sd_card => blk: {
                            if (status.sd_connected) break :blk .toggle_sd;
                            if (self.sd_cards.items.len == 0) {
                                // Initial list is empty: skip the menu and show Manage Cards popup directly
                                self.sd_card_menu_open = false;
                                self.sd_manage_open = true;
                                if (self.new_card_name_len == 0) self.resetDefaultNewCardName();
                            } else {
                                self.sd_card_menu_open = !self.sd_card_menu_open;
                            }
                            break :blk .consumed;
                        },
                        .hdmi => .toggle_hdmi,
                        .audio => .toggle_audio,
                        .power => .toggle_power,
                        .usb_hub => .toggle_usb_hub,
                        .usb_keyboard => .toggle_usb_keyboard,
                        .usb_mouse => .toggle_usb_mouse,
                        .ethernet => .toggle_ethernet,
                        .gpio => .toggle_gpio,
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

    /// Renders the client-side TitleBar (`y = 0..44` logical), the GPIO box below the display when
    /// connected, and, when open, the drop-down Board Sheet over `pixels` at `scale` (e.g. 1x or 2x).
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

        const disp_bottom_h: u32 = if (status.gpio_connected and win_h > gpio_panel_height)
            win_h - gpio_panel_height
        else
            win_h;

        if (!status.hdmi_connected or !status.hdmi_active) {
            self.paintNoSignal(&c, win_w, disp_bottom_h, status.hdmi_connected);
        }
        if (status.gpio_connected and win_h > gpio_panel_height) {
            self.paintGpioBox(&c, win_w, status, gpio_hw);
        }
        self.paintTitleBar(&c, win_w);
        if (self.sheet_open) {
            self.paintSheet(&c, win_w, disp_bottom_h, status);
        }
    }

    fn paintNoSignal(self: *BoardUi, c: *Canvas, win_w: u32, disp_bottom_h: u32, hdmi_connected: bool) void {
        const w_f: f32 = @floatFromInt(win_w);
        const h_f: f32 = @floatFromInt(disp_bottom_h);
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
        disp_bottom_h: u32,
        status: SystemStatus,
    ) void {
        const t = &self.theme;
        const sc_f = @max(c.scale, 1.0);
        const sc: u32 = @intFromFloat(sc_f);
        const h_f: f32 = @floatFromInt(disp_bottom_h);
        const top_y: f32 = @floatFromInt(title_bar_height);

        const sr = self.sheet_rect;
        // Dim the HDMI display behind the drop-down sheet using SWAR (skipping the opaque upper body of sheet_rect)
        if (h_f > top_y) {
            const py_start: u32 = title_bar_height * sc;
            const py_end: u32 = @min(c.height, disp_bottom_h * sc);
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
                .sd_card_name_hash = std.hash.Wyhash.hash(0, self.activeSdCardName()),
                .sd_connected = status.sd_connected,
                .hdmi_connected = status.hdmi_connected,
                .audio_connected = status.audio_connected,
                .power_connected = status.power_connected,
                .usb_hub_connected = status.usb_hub_connected,
                .usb_keyboard_connected = status.usb_keyboard_connected,
                .usb_mouse_connected = status.usb_mouse_connected,
                .ethernet_connected = status.ethernet_connected,
                .gpio_connected = status.gpio_connected,
                .act_led_on = status.act_led_on,
                .pwr_led_on = status.pwr_led_on,
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
                self.paintSdPopups(c);
                return;
            }
        }

        const drawing = board.forModel(status.model) orelse &board.pi_zero;
        self.paintBoardDrawing(c, drawing, self.board_rect, status);
        self.paintSettingsSection(c, status);
        self.paintSdPopups(c);
    }

    /// Renders the GPIO box below the display when the GPIO ribbon cable is connected.
    /// First section: LEDs for outputs ordered from low to high pin numbers.
    /// Second section: interactive switches for inputs ordered from low to high pin numbers.
    fn paintGpioBox(
        self: *BoardUi,
        c: *Canvas,
        win_w: u32,
        status: SystemStatus,
        gpio_hw: *const Gpio,
    ) void {
        const gb = self.gpio_box_rect;
        if (gb.w <= 0 or gb.h <= 0) return;

        const sc_f = @max(c.scale, 1.0);
        const sc: u32 = @intFromFloat(sc_f);
        const box_y_px: u32 = @intFromFloat(@round(gb.y * sc_f));
        const box_w_px: u32 = win_w * sc;
        const box_h_px: u32 = gpio_panel_height * sc;
        if (box_y_px + box_h_px > c.height or box_w_px > c.width) return;

        const hdr_mask = headerGpioMask(status.model);
        var out_mask: u32 = 0;
        var in_mask: u32 = 0;
        var level_mask: u32 = 0;
        for (0..28) |pin_usize| {
            const pin: u6 = @intCast(pin_usize);
            const bit: u32 = @as(u32, 1) << @intCast(pin);
            if ((hdr_mask & bit) == 0) continue;
            switch (gpio_hw.getPinFunction(pin)) {
                .output => out_mask |= bit,
                .input => in_mask |= bit,
                else => {},
            }
            if (gpio_hw.getPinLevel(pin)) level_mask |= bit;
        }

        const total_px = @as(usize, box_w_px) * @as(usize, box_h_px);
        const gkey: GpioCacheKey = .{
            .win_w = win_w,
            .scale = sc,
            .board_model = BoardModel.fromModel(status.model),
            .output_mask = out_mask,
            .input_mask = in_mask,
            .level_mask = level_mask,
            .hovered_input_idx = self.hovered_gpio_input_idx,
        };

        if (self.gpio_cache.len == total_px and std.meta.eql(self.gpio_cache_key, gkey)) {
            for (0..box_h_px) |ry| {
                const dst_row = c.pixels[(box_y_px + ry) * c.stride ..][0..box_w_px];
                const src_row = self.gpio_cache[ry * box_w_px ..][0..box_w_px];
                @memcpy(dst_row, src_row);
            }
            return;
        }

        const t = &self.theme;
        c.fillRect(gb, t.surface_container);
        c.fillRect(.{ .x = gb.x, .y = gb.y, .w = gb.w, .h = 1.0 }, t.outline_variant);

        const card_r: Rect = .{
            .x = gb.x + 12.0,
            .y = gb.y + 8.0,
            .w = gb.w - 24.0,
            .h = gb.h - 16.0,
        };
        c.fillRoundedRect(card_r, .all(10.0), t.surface);
        c.strokeRoundedRect(card_r, .all(10.0), 1.0, t.outline_variant);

        // Divider between Section 1 (Outputs) and Section 2 (Inputs)
        const div_y = gb.y + 60.0;
        c.fillRect(.{ .x = card_r.x + 12.0, .y = div_y, .w = card_r.w - 24.0, .h = 1.0 }, t.outline_variant.withAlpha(0.6));

        // Section 1: Outputs (LEDs ordered from low to high pin numbers)
        _ = c.drawText(13.0, gb.x + 24.0, gb.y + 32.0, "Outputs", t.on_surface);
        _ = c.drawText(11.0, gb.x + 24.0, gb.y + 47.0, "GPIO LEDs", t.on_surface_variant);

        if (self.gpio_output_count == 0) {
            _ = c.drawText(12.5, gb.x + 116.0, gb.y + 39.0, "No pins configured as outputs", t.on_surface_variant);
        } else {
            const num_st: canvas_mod.Style = .{ .font = &self.font, .size = 11.0 };
            for (0..self.gpio_output_count) |idx| {
                const pin = self.gpio_output_pins[idx];
                const cell = self.gpioOutputLedRect(idx);
                const cx = @round(cell.x + cell.w * 0.5);
                const led_cy = @round(cell.y + 15.0);
                const high = gpio_hw.getPinLevel(pin);

                if (high) {
                    const led_col = Color.rgb(0x22E55E);
                    c.fillCircle(.{ cx, led_cy }, 9.5, led_col.withAlpha(0.28));
                    c.fillCircle(.{ cx, led_cy }, 6.5, led_col);
                    c.fillCircle(.{ cx - 1.8, led_cy - 1.8 }, 2.0, Color.rgb(0xC8FFDA));
                    c.strokeCircle(.{ cx, led_cy }, 6.5, 1.0, Color.rgb(0x16A34A));
                } else {
                    c.fillCircle(.{ cx, led_cy }, 6.5, t.surface_container_highest);
                    c.strokeCircle(.{ cx, led_cy }, 6.5, 1.2, t.outline);
                }

                var pin_buf: [8]u8 = undefined;
                const pin_lbl = std.fmt.bufPrint(&pin_buf, "{d}", .{pin}) catch "";
                const tw = c.measureText(11.0, pin_lbl);
                _ = c.drawText(
                    11.0,
                    @round(cx - tw * 0.5),
                    @round(cell.y + 32.0 + num_st.ascent()),
                    pin_lbl,
                    if (high) t.on_surface else t.on_surface_variant,
                );
            }
        }

        // Section 2: Inputs (interactive switches ordered from low to high pin numbers)
        _ = c.drawText(13.0, gb.x + 24.0, gb.y + 93.0, "Inputs", t.on_surface);
        _ = c.drawText(11.0, gb.x + 24.0, gb.y + 108.0, "GPIO Switches", t.on_surface_variant);

        if (self.gpio_input_count == 0) {
            _ = c.drawText(12.5, gb.x + 116.0, gb.y + 100.0, "No pins configured as inputs", t.on_surface_variant);
        } else {
            const num_st: canvas_mod.Style = .{ .font = &self.font, .size = 11.0 };
            for (0..self.gpio_input_count) |idx| {
                const pin = self.gpio_input_pins[idx];
                const cell = self.gpioInputSwitchRect(idx);
                const cx = @round(cell.x + cell.w * 0.5);
                const high = gpio_hw.getPinLevel(pin);
                const hovered = (self.hovered_gpio_input_idx == idx);

                const sw_w: f32 = 16.0;
                const sw_h: f32 = 30.0;
                const sw_r: Rect = .{
                    .x = @round(cx - sw_w * 0.5),
                    .y = @round(cell.y + 3.0),
                    .w = sw_w,
                    .h = sw_h,
                };
                const track_bg = if (high) t.primary else t.surface_container_highest;
                const track_border = if (hovered)
                    t.on_surface
                else if (high)
                    t.primary
                else
                    t.outline;
                c.fillRoundedRect(sw_r, .all(sw_w * 0.5), track_bg);
                c.strokeRoundedRect(sw_r, .all(sw_w * 0.5), if (hovered) 1.5 else 1.1, track_border);

                const knob_cy = if (high) (sw_r.y + 8.0) else (sw_r.y + sw_r.h - 8.0);
                const knob_col = if (high) t.on_primary else t.on_surface_variant;
                c.fillCircle(.{ cx, knob_cy }, 5.5, knob_col);

                var pin_buf: [8]u8 = undefined;
                const pin_lbl = std.fmt.bufPrint(&pin_buf, "{d}", .{pin}) catch "";
                const tw = c.measureText(11.0, pin_lbl);
                _ = c.drawText(
                    11.0,
                    @round(cx - tw * 0.5),
                    @round(cell.y + 38.0 + num_st.ascent()),
                    pin_lbl,
                    if (high or hovered) t.on_surface else t.on_surface_variant,
                );
            }
        }

        if (self.gpio_cache.len != total_px) {
            if (self.gpio_cache.len > 0) self.gpa.free(self.gpio_cache);
            self.gpio_cache = self.gpa.alloc(u32, total_px) catch &.{};
        }
        if (self.gpio_cache.len == total_px) {
            for (0..box_h_px) |ry| {
                const src_row = c.pixels[(box_y_px + ry) * c.stride ..][0..box_w_px];
                const dst_row = self.gpio_cache[ry * box_w_px ..][0..box_w_px];
                @memcpy(dst_row, src_row);
            }
            self.gpio_cache_key = gkey;
        }
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

    fn paintSdPopups(self: *const BoardUi, c: *Canvas) void {
        const t = &self.theme;
        const item_st: canvas_mod.Style = .{ .font = &self.font, .size = 13.0 };

        // 1. SD Card selector menu (shown when clicking the SD card and at least 1 card exists)
        if (self.sd_card_menu_open) {
            const mr = self.sd_card_menu_rect;
            c.fillRoundedRect(mr, .all(8.0), t.surface_container_highest);
            c.strokeRoundedRect(mr, .all(8.0), 1.2, t.primary);

            for (self.sd_cards.items, 0..) |*card, idx| {
                const item_r = self.sdMenuRowRect(idx);
                const is_sel = (self.selected_sd_card_idx == idx);
                const is_hov = (self.hovered_sd_menu_idx == idx);
                if (is_sel or is_hov) {
                    c.fillRoundedRect(item_r, .all(6.0), if (is_sel) t.secondary_container else t.surface);
                }
                var label_buf: [112]u8 = undefined;
                const lbl = std.fmt.bufPrint(&label_buf, "{s} ({s})", .{ card.name(), card.size.label() }) catch card.name();
                _ = c.drawText(
                    13.0,
                    item_r.x + 10.0,
                    @round(item_r.y + (item_r.h - item_st.lineHeight()) * 0.5 + item_st.ascent()),
                    lbl,
                    if (is_sel) t.primary else t.on_surface,
                );
            }

            if (self.sd_cards.items.len > 0) {
                const div_y = mr.y + 5.5 + @as(f32, @floatFromInt(self.sd_cards.items.len)) * 32.0;
                c.fillRect(.{ .x = mr.x + 8.0, .y = div_y, .w = mr.w - 16.0, .h = 1.0 }, t.outline_variant);
            }

            const mg_r = self.sdMenuManageRowRect();
            const mg_hov = (self.hovered_sd_menu_idx == self.sd_cards.items.len);
            if (mg_hov) {
                c.fillRoundedRect(mg_r, .all(6.0), t.surface);
            }
            _ = c.drawText(
                13.0,
                mg_r.x + 10.0,
                @round(mg_r.y + (mg_r.h - item_st.lineHeight()) * 0.5 + item_st.ascent()),
                "Manage Cards...",
                t.primary,
            );
        }

        // 2. Manage SD Cards modal popup
        if (self.sd_manage_open) {
            const mr = self.sd_manage_rect;
            c.fillRoundedRect(mr, .all(12.0), t.surface_container_highest);
            c.strokeRoundedRect(mr, .all(12.0), 1.4, t.outline);

            // Title & Close button
            _ = c.drawText(16.0, mr.x + 16.0, mr.y + 31.0, "Manage SD Cards", t.on_surface);
            paintBarButton(c, t, self.sd_manage_close_rect, .close, self.sd_manage_close_hovered, false, false);
            c.fillRect(.{ .x = mr.x + 16.0, .y = mr.y + 44.0, .w = mr.w - 32.0, .h = 1.0 }, t.outline_variant.withAlpha(0.7));

            // Existing cards section
            _ = c.drawText(12.5, mr.x + 16.0, mr.y + 64.0, "SD Cards", t.on_surface_variant);
            if (self.sd_cards.items.len == 0) {
                const empty_r: Rect = .{ .x = mr.x + 16.0, .y = mr.y + 72.0, .w = mr.w - 32.0, .h = 34.0 };
                c.fillRoundedRect(empty_r, .all(6.0), t.surface);
                c.strokeRoundedRect(empty_r, .all(6.0), 1.0, t.outline_variant);
                _ = c.drawText(12.5, empty_r.x + 12.0, empty_r.y + 22.0, "No SD cards added yet", t.on_surface_variant);
            } else {
                for (self.sd_cards.items, 0..) |*card, idx| {
                    const row_r = self.sdManageCardRowRect(idx);
                    const is_sel = (self.selected_sd_card_idx == idx);
                    const is_hov = (self.hovered_sd_card_row_idx == idx);
                    c.fillRoundedRect(row_r, .all(6.0), if (is_sel) t.secondary_container else if (is_hov) t.surface_container else t.surface);
                    c.strokeRoundedRect(row_r, .all(6.0), 1.0, if (is_sel) t.primary else t.outline_variant);

                    var row_buf: [128]u8 = undefined;
                    const disk_kb = (card.disk.diskAllocatedBytes() + 1023) / 1024;
                    const row_txt = std.fmt.bufPrint(
                        &row_buf,
                        "{s}  ·  {s}  ({d} KB on disk)",
                        .{ card.name(), card.size.label(), disk_kb },
                    ) catch card.name();
                    _ = c.drawText(
                        13.0,
                        row_r.x + 12.0,
                        @round(row_r.y + (row_r.h - item_st.lineHeight()) * 0.5 + item_st.ascent()),
                        row_txt,
                        if (is_sel) t.primary else t.on_surface,
                    );
                }
            }

            // Add Card section: Card Name + standard SD card sizes + image file selector
            const list_h: f32 = if (self.sd_cards.items.len == 0) 36.0 else @as(f32, @floatFromInt(self.sd_cards.items.len)) * 32.0;
            const add_y0: f32 = mr.y + 72.0 + list_h + 16.0;
            _ = c.drawText(12.5, mr.x + 16.0, add_y0 + 18.0, "Add Card — Name", t.on_surface_variant);

            var name_disp_buf: [68]u8 = undefined;
            const name_slice = self.newCardName();
            const name_disp = if (self.focused_field == .sd_card_name)
                std.fmt.bufPrint(&name_disp_buf, "{s}|", .{name_slice}) catch name_slice
            else
                name_slice;
            self.paintTextField(
                c,
                self.sd_name_field_rect,
                name_disp,
                self.focused_field == .sd_card_name,
                self.sd_name_field_hovered,
                false,
            );

            const size_row_y = self.sd_size_btn_rects[0].y;
            _ = c.drawText(12.5, mr.x + 16.0, size_row_y - 6.0, "Card Size", t.on_surface_variant);

            const pill_st: canvas_mod.Style = .{ .font = &self.font, .size = 11.5 };
            for (SdCardSize.all, 0..) |sz, idx| {
                const sr = self.sd_size_btn_rects[idx];
                const is_sel = (self.new_card_size == sz);
                const is_hov = (self.hovered_sd_size_idx == idx);
                c.fillRoundedRect(sr, .all(6.0), if (is_sel) t.primary else if (is_hov) t.surface_container else t.surface);
                c.strokeRoundedRect(sr, .all(6.0), 1.0, if (is_sel or is_hov) t.primary else t.outline_variant);
                const tw = c.measureText(11.5, sz.label());
                _ = c.drawText(
                    11.5,
                    @round(sr.x + (sr.w - tw) * 0.5),
                    @round(sr.y + (sr.h - pill_st.lineHeight()) * 0.5 + pill_st.ascent()),
                    sz.label(),
                    if (is_sel) t.on_primary else t.on_surface,
                );
            }

            const img_row_y = self.sd_browse_btn_rect.y;
            _ = c.drawText(12.5, mr.x + 16.0, img_row_y - 6.0, "OS Image File", t.on_surface_variant);
            const path_box: Rect = .{
                .x = mr.x + 16.0,
                .y = img_row_y,
                .w = self.sd_browse_btn_rect.x - (mr.x + 16.0) - 8.0,
                .h = 32.0,
            };
            var img_lbl_buf: [128]u8 = undefined;
            const img_lbl = if (self.pending_sd_image_path_len > 0) blk: {
                const base = std.fs.path.basename(self.pending_sd_image_path_buf[0..self.pending_sd_image_path_len]);
                const mb = (self.pending_sd_image_size + (1024 * 1024 - 1)) / (1024 * 1024);
                break :blk std.fmt.bufPrint(&img_lbl_buf, "{s} ({d} MB)", .{ base, mb }) catch base;
            } else "No image file selected";
            self.paintTextField(c, path_box, img_lbl, false, false, self.pending_sd_image_path_len == 0);

            // Browse button
            const br = self.sd_browse_btn_rect;
            c.fillRoundedRect(br, .all(6.0), if (self.sd_browse_btn_hovered) t.secondary_container else t.surface);
            c.strokeRoundedRect(br, .all(6.0), 1.0, if (self.sd_browse_btn_hovered) t.primary else t.outline_variant);
            const br_lbl = "Choose Image...";
            const br_tw = c.measureText(12.5, br_lbl);
            _ = c.drawText(
                12.5,
                @round(br.x + (br.w - br_tw) * 0.5),
                @round(br.y + (br.h - item_st.lineHeight()) * 0.5 + item_st.ascent()),
                br_lbl,
                t.on_surface,
            );

            // Error banner when image exceeds card size
            if (self.sd_error_len > 0) {
                const err_r: Rect = .{ .x = mr.x + 16.0, .y = img_row_y + 38.0, .w = mr.w - 32.0, .h = 24.0 };
                c.fillRoundedRect(err_r, .all(5.0), t.@"error".withAlpha(0.16));
                _ = c.drawText(12.0, err_r.x + 10.0, err_r.y + 16.5, self.sdErrorMessage(), t.@"error");
            }

            // Add Card button
            const ar = self.sd_add_btn_rect;
            const can_add = self.pending_sd_image_path_len > 0 and !self.hasImageTooLargeError();
            c.fillRoundedRect(ar, .all(6.0), if (can_add) t.primary else t.surface.withAlpha(0.5));
            c.strokeRoundedRect(ar, .all(6.0), 1.0, if (can_add) t.primary else t.outline_variant);
            const add_lbl = "Add Card";
            const add_tw = c.measureText(13.0, add_lbl);
            _ = c.drawText(
                13.0,
                @round(ar.x + (ar.w - add_tw) * 0.5),
                @round(ar.y + (ar.h - item_st.lineHeight()) * 0.5 + item_st.ascent()),
                add_lbl,
                if (can_add) t.on_primary else t.on_surface_variant.withAlpha(0.5),
            );
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
                .gpio, .gpio_holes => self.hovered_target == .gpio,
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
                drawPart(c, &part, pr, s, if (part_hovered) t.primary else ink);
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
                const hovered = (self.hovered_target == .gpio);
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
        const sd_card_name = self.activeSdCardName();
        for (b.parts) |part| {
            if (part.kind == .micro_sd or part.kind == .sd) {
                const hovered = (self.hovered_target == .sd_card) or (status.sd_connected and self.hovered_target == .sd_connector);
                drawSdCard(
                    c,
                    map(tr, part.rect),
                    tr.y + HubLayout.top_cable_min_y * s,
                    max_y,
                    s,
                    if (hovered) t.primary else ink,
                    t.primary,
                    t.surface,
                    status.sd_connected,
                    hovered,
                    sd_card_name,
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
        .edge => {},
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
    else .{
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

        // Pin-1 red edge stripe on the left conductor of the ribbon cable
        const stripe_w = @max(1.5, ribbon_w / 24.0);
        c.fillRect(
            .{ .x = rib_r.x + line_w, .y = rib_r.y, .w = stripe_w, .h = rib_r.h },
            red.withAlpha(if (hovered) 0.85 else 0.72),
        );

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

    // Pin-1 triangle marker on the left side of the IDC housing
    c.fillCircle(.{ conn_r.x + 2.0 * s, conn_r.y + conn_r.h - 1.4 * s }, @max(1.2, 0.55 * s), red.withAlpha(0.85));
}

fn evdevKeyToCardNameChar(evdev_key: u32, shift: bool) ?u8 {
    const lower: ?u8 = switch (evdev_key) {
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
        12 => if (shift) '_' else '-',
        16 => 'q',
        17 => 'w',
        18 => 'e',
        19 => 'r',
        20 => 't',
        21 => 'y',
        22 => 'u',
        23 => 'i',
        24 => 'o',
        25 => 'p',
        30 => 'a',
        31 => 's',
        32 => 'd',
        33 => 'f',
        34 => 'g',
        35 => 'h',
        36 => 'j',
        37 => 'k',
        38 => 'l',
        44 => 'z',
        45 => 'x',
        46 => 'c',
        47 => 'v',
        48 => 'b',
        49 => 'n',
        50 => 'm',
        52 => '.',
        57 => ' ',
        else => null,
    };
    if (lower) |ch| {
        if (shift and std.ascii.isLower(ch)) return std.ascii.toUpper(ch);
        return ch;
    }
    return null;
}

pub fn ensureDirPathLinux(path: []const u8) void {
    if (path.len == 0 or path.len >= std.fs.max_path_bytes) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(buf[0..path.len], path);

    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or buf[i] == '/') {
            const saved = if (i < path.len) buf[i] else 0;
            buf[i] = 0;
            _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, buf[0..i :0], 0o755);
            if (i < path.len) buf[i] = saved;
        }
    }
}

pub fn fileExistsLinux(path: []const u8) bool {
    if (path.len == 0 or path.len >= std.fs.max_path_bytes) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.os.linux.errno(std.os.linux.faccessat(std.os.linux.AT.FDCWD, buf[0..path.len :0], std.os.linux.F_OK, 0)) == .SUCCESS;
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

    // 2. When removed and the SD card list is initially empty, clicking the SD card skips the menu
    //    and opens the Manage SD Cards popup directly.
    const sd_card_removed_x = tr.x + (-8.0) * tr.scale;
    const sd_y = tr.y + 13.3 * tr.scale;
    try testing.expectEqual(@as(usize, 0), ui.sd_cards.items.len);
    _ = ui.pointerButton(sd_card_removed_x, sd_y, true, status, &hw);
    try testing.expectEqual(Action.consumed, ui.pointerButton(sd_card_removed_x, sd_y, false, status, &hw));
    try testing.expect(!ui.sd_card_menu_open);
    try testing.expect(ui.sd_manage_open);

    // Paint the Manage SD Cards popup and verify Browse button triggers .select_sd_image
    ui.paint(pixels, win_w, win_h, 1, status, &hw);
    _ = ui.pointerButton(ui.sd_browse_btn_rect.x + 10, ui.sd_browse_btn_rect.y + 10, true, status, &hw);
    try testing.expectEqual(Action.select_sd_image, ui.pointerButton(ui.sd_browse_btn_rect.x + 10, ui.sd_browse_btn_rect.y + 10, false, status, &hw));

    // Selecting 256 MB (button index 0) and choosing a 300 MB image is detected as an error
    _ = ui.pointerButton(ui.sd_size_btn_rects[0].x + 10, ui.sd_size_btn_rects[0].y + 10, true, status, &hw);
    _ = ui.pointerButton(ui.sd_size_btn_rects[0].x + 10, ui.sd_size_btn_rects[0].y + 10, false, status, &hw);
    try testing.expectEqual(SdCardSize.mb_256, ui.new_card_size);
    ui.setPendingSdImageFile("/tmp/oversized.img", 300 * 1024 * 1024);
    try testing.expect(ui.hasImageTooLargeError());
    ui.paint(pixels, win_w, win_h, 1, status, &hw);

    // Selecting a valid small image and clicking "+ Create & Add Card" adds a sparse QCOW2 card and selects it
    var valid_img: [512]u8 = @splat(0);
    valid_img[510] = 0x55;
    valid_img[511] = 0xAA;
    ui.setPendingSdImageSlice("raspios-lite.img", &valid_img);
    try testing.expect(!ui.hasImageTooLargeError());
    ui.paint(pixels, win_w, win_h, 1, status, &hw);
    _ = ui.pointerButton(ui.sd_add_btn_rect.x + 10, ui.sd_add_btn_rect.y + 10, true, status, &hw);
    try testing.expectEqual(Action.select_sd_card, ui.pointerButton(ui.sd_add_btn_rect.x + 10, ui.sd_add_btn_rect.y + 10, false, status, &hw));
    try testing.expect(!ui.sd_manage_open);
    try testing.expectEqual(@as(usize, 1), ui.sd_cards.items.len);
    try testing.expectEqual(@as(?usize, 0), ui.selected_sd_card_idx);

    // Now that the card list is non-empty, clicking the removed SD card opens the card menu
    // offering the list of cards and "Manage Cards..."
    _ = ui.pointerButton(sd_card_removed_x, sd_y, true, status, &hw);
    try testing.expectEqual(Action.consumed, ui.pointerButton(sd_card_removed_x, sd_y, false, status, &hw));
    try testing.expect(ui.sd_card_menu_open);
    try testing.expect(!ui.sd_manage_open);
    ui.paint(pixels, win_w, win_h, 1, status, &hw);

    // Click item 0 in the SD card menu to select the card
    const sd_menu_item0_y = ui.sd_card_menu_rect.y + 4.0 + 16.0;
    _ = ui.pointerButton(ui.sd_card_menu_rect.x + 20, sd_menu_item0_y, true, status, &hw);
    try testing.expectEqual(Action.select_sd_card, ui.pointerButton(ui.sd_card_menu_rect.x + 20, sd_menu_item0_y, false, status, &hw));
    try testing.expect(!ui.sd_card_menu_open);

    // Verify the active SD card name ("Card 1") is rendered rotated 90° beside the left edge of the unplugged SD card
    ui.paint(pixels, win_w, win_h, 1, status, &hw);
    try testing.expectEqual(std.hash.Wyhash.hash(0, "Card 1"), ui.board_cache_key.sd_card_name_hash);
    const surface_argb = Theme.dark.surface.toArgb();
    var unplugged_label_lit: usize = 0;
    const unp_x0: usize = @intFromFloat(@round(tr.x + (-19.8) * tr.scale));
    const unp_x1: usize = @intFromFloat(@round(tr.x + (-16.8) * tr.scale));
    const lbl_y0: usize = @intFromFloat(@round(tr.y + 8.0 * tr.scale));
    const lbl_y1: usize = @intFromFloat(@round(tr.y + 18.5 * tr.scale));
    for (lbl_y0..lbl_y1) |py| {
        for (unp_x0..unp_x1) |px| {
            if (pixels[py * win_w + px] != surface_argb) unplugged_label_lit += 1;
        }
    }
    try testing.expect(unplugged_label_lit > 20);

    // Clicking the SD card connector (on the board) returns .toggle_sd to insert it.
    // When inserted, clicking the SD card disconnects it (.toggle_sd).
    const sd_conn_x = tr.x + 6.75 * tr.scale;
    _ = ui.pointerButton(sd_conn_x, sd_y, true, status, &hw);
    try testing.expectEqual(Action.toggle_sd, ui.pointerButton(sd_conn_x, sd_y, false, status, &hw));
    status.sd_connected = true;
    ui.paint(pixels, win_w, win_h, 1, status, &hw);

    // Verify the active SD card name ("Card 1") moves with the card and is rendered beside the protruding left edge when inserted
    var inserted_label_lit: usize = 0;
    const ins_x0: usize = @intFromFloat(@round(tr.x + (-8.2) * tr.scale));
    const ins_x1: usize = @intFromFloat(@round(tr.x + (-5.2) * tr.scale));
    for (lbl_y0..lbl_y1) |py| {
        for (ins_x0..ins_x1) |px| {
            if (pixels[py * win_w + px] != surface_argb) inserted_label_lit += 1;
        }
    }
    try testing.expect(inserted_label_lit > 20);

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

    // 5. Clicking the USB Hub body does not toggle the hub (.consumed), while clicking the USB OTG socket/plug/cable returns .toggle_usb_hub
    const hub_body_x = tr.x + 98.0 * tr.scale;
    const hub_body_y = tr.y + 25.0 * tr.scale;
    _ = ui.pointerButton(hub_body_x, hub_body_y, true, status, &hw);
    try testing.expectEqual(Action.consumed, ui.pointerButton(hub_body_x, hub_body_y, false, status, &hw));

    const otg_x = tr.x + 41.4 * tr.scale;
    const otg_y = tr.y + 28.1 * tr.scale;
    _ = ui.pointerButton(otg_x, otg_y, true, status, &hw);
    try testing.expectEqual(Action.toggle_usb_hub, ui.pointerButton(otg_x, otg_y, false, status, &hw));
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

test "BoardUi persistent images and settings.json with custom and default card names" {
    const os = std.os.linux;

    const tmp_dir: [:0]const u8 = "/tmp/fauxpi-test-xdg-data";
    const tmp_images_dir: [:0]const u8 = "/tmp/fauxpi-test-xdg-data/images";
    const tmp_settings_path: [:0]const u8 = "/tmp/fauxpi-test-xdg-data/settings.json";
    defer {
        _ = os.unlinkat(os.AT.FDCWD, "/tmp/fauxpi-test-xdg-data/images/Card 1.qcow2", 0);
        _ = os.unlinkat(os.AT.FDCWD, "/tmp/fauxpi-test-xdg-data/images/Card 2.qcow2", 0);
        _ = os.unlinkat(os.AT.FDCWD, "/tmp/fauxpi-test-xdg-data/images/Custom OS.qcow2", 0);
        _ = os.unlinkat(os.AT.FDCWD, tmp_settings_path, 0);
        _ = os.unlinkat(os.AT.FDCWD, tmp_images_dir, os.AT.REMOVEDIR);
        _ = os.unlinkat(os.AT.FDCWD, tmp_dir, os.AT.REMOVEDIR);
    }
    _ = os.unlinkat(os.AT.FDCWD, "/tmp/fauxpi-test-xdg-data/images/Card 1.qcow2", 0);
    _ = os.unlinkat(os.AT.FDCWD, "/tmp/fauxpi-test-xdg-data/images/Card 2.qcow2", 0);
    _ = os.unlinkat(os.AT.FDCWD, "/tmp/fauxpi-test-xdg-data/images/Custom OS.qcow2", 0);
    _ = os.unlinkat(os.AT.FDCWD, tmp_settings_path, 0);
    _ = os.unlinkat(os.AT.FDCWD, tmp_images_dir, os.AT.REMOVEDIR);
    _ = os.unlinkat(os.AT.FDCWD, tmp_dir, os.AT.REMOVEDIR);

    // 1. Initialize first BoardUi with tmp_dir and create cards + modify settings
    {
        var ui = try BoardUi.init(testing.allocator);
        defer ui.deinit();

        var status = SystemStatus{
            .board_model = .pi_zero,
            .model = BoardModel.pi_zero.dtModel(),
        };
        ui.configureDataDir(tmp_dir, &status);

        // Default new card name starts as "Card 1"
        try testing.expectEqualStrings("Card 1", ui.newCardName());

        // Create first card ("Card 1") via Manage SD Cards dialog
        var hw: Gpio = .{};
        ui.sheet_open = true;
        ui.sd_manage_open = true;
        var valid_img: [512]u8 = @splat(0);
        valid_img[510] = 0x55;
        valid_img[511] = 0xAA;
        ui.setPendingSdImageSlice("raspios-lite.img", &valid_img);
        ui.updateLayout(1280, 764, status, &hw);

        // Create button creates "Card 1", closes manage dialog, and advances default name to "Card 2"
        _ = ui.pointerButton(ui.sd_add_btn_rect.x + 10, ui.sd_add_btn_rect.y + 10, true, status, &hw);
        try testing.expectEqual(Action.select_sd_card, ui.pointerButton(ui.sd_add_btn_rect.x + 10, ui.sd_add_btn_rect.y + 10, false, status, &hw));
        try testing.expectEqual(@as(usize, 1), ui.sd_cards.items.len);
        try testing.expectEqualStrings("Card 1", ui.sd_cards.items[0].name());
        try testing.expectEqualStrings("Card 2", ui.newCardName());

        // Write bytes to Card 1 so we can verify its contents persist
        ui.sd_cards.items[0].disk.writeByte(0, 0x42);
        ui.sd_cards.items[0].disk.writeByte(511, 0x99);

        // Reopen Manage SD Cards dialog and edit the card name field via pointer + keyboard to "Custom OS"
        ui.sd_manage_open = true;
        ui.setPendingSdImageSlice("custom-os.img", &valid_img);
        ui.updateLayout(1280, 764, status, &hw);
        _ = ui.pointerButton(ui.sd_name_field_rect.x + 10, ui.sd_name_field_rect.y + 10, true, status, &hw);
        _ = ui.pointerButton(ui.sd_name_field_rect.x + 10, ui.sd_name_field_rect.y + 10, false, status, &hw);
        try testing.expectEqual(FocusedSettingField.sd_card_name, ui.focused_field);

        // Clear "Card 2" with backspaces and type "Custom OS" via evdev key codes
        for (0..10) |_| {
            _ = ui.handleKey(14);
        }
        try testing.expectEqualStrings("", ui.newCardName());
        _ = ui.handleKey(42); // Left Shift down
        _ = ui.handleKey(46); // 'C'
        ui.updateModifierKey(42, false); // Left Shift up
        _ = ui.handleKey(22); // 'u'
        _ = ui.handleKey(31); // 's'
        _ = ui.handleKey(20); // 't'
        _ = ui.handleKey(24); // 'o'
        _ = ui.handleKey(50); // 'm'
        _ = ui.handleKey(57); // ' '
        _ = ui.handleKey(42); // Left Shift down
        _ = ui.handleKey(24); // 'O'
        _ = ui.handleKey(31); // 'S'
        ui.updateModifierKey(42, false); // Left Shift up
        try testing.expectEqualStrings("Custom OS", ui.newCardName());

        // Click Create button to create "Custom OS"
        _ = ui.pointerButton(ui.sd_add_btn_rect.x + 10, ui.sd_add_btn_rect.y + 10, true, status, &hw);
        try testing.expectEqual(Action.select_sd_card, ui.pointerButton(ui.sd_add_btn_rect.x + 10, ui.sd_add_btn_rect.y + 10, false, status, &hw));
        try testing.expectEqual(@as(usize, 2), ui.sd_cards.items.len);
        try testing.expectEqualStrings("Custom OS", ui.sd_cards.items[1].name());
        // Next default card name should be "Card 2" since "Card 2" has not been taken yet
        try testing.expectEqualStrings("Card 2", ui.newCardName());

        // Customize board settings and save
        status.board_model = .pi_zero_2_w;
        status.model = status.board_model.dtModel();
        ui.setHexField(&ui.serial_hex, &ui.serial_len, "00000000cafebabe", false);
        ui.setHexField(&ui.mac_hex, &ui.mac_len, "B827EB112233", true);
        ui.setHexField(&ui.wifi_mac_hex, &ui.wifi_mac_len, "B827EB445566", true);
        status.dhcp_enabled = false;
        status.sd_connected = true;
        status.hdmi_connected = false;
        ui.selected_sd_card_idx = 0; // select "Card 1"
        try ui.saveSettings(status);
    }

    // 2. Initialize second BoardUi from the same tmp_dir and verify everything is restored
    {
        var ui2 = try BoardUi.init(testing.allocator);
        defer ui2.deinit();

        var status2 = SystemStatus{};
        ui2.configureDataDir(tmp_dir, &status2);

        try testing.expectEqual(BoardModel.pi_zero_2_w, status2.board_model);
        try testing.expectEqual(BoardModel.pi_zero_2_w, ui2.selected_board_model);
        try testing.expectEqual(@as(u64, 0x00000000CAFEBABE), status2.serial_u64);
        try testing.expectEqualSlices(u8, &.{ 0xB8, 0x27, 0xEB, 0x11, 0x22, 0x33 }, &status2.mac_address);
        try testing.expectEqualSlices(u8, &.{ 0xB8, 0x27, 0xEB, 0x44, 0x55, 0x66 }, &status2.wifi_mac_address);
        try testing.expect(!status2.dhcp_enabled);
        try testing.expect(status2.sd_connected);
        try testing.expect(!status2.hdmi_connected);

        try testing.expectEqual(@as(usize, 2), ui2.sd_cards.items.len);
        try testing.expect(ui2.selected_sd_card_idx != null);
        const sel = ui2.selected_sd_card_idx.?;
        try testing.expectEqualStrings("Card 1", ui2.sd_cards.items[sel].name());

        try testing.expectEqual(@as(u8, 0x42), ui2.sd_cards.items[sel].disk.readByte(0));
        try testing.expectEqual(@as(u8, 0x99), ui2.sd_cards.items[sel].disk.readByte(511));

        // Default name for next card should be "Card 2" since "Card 1" exists
        try testing.expectEqualStrings("Card 2", ui2.newCardName());
    }
}

test "GPIO ribbon cable connector and GPIO box outputs LEDs and input switches" {
    var ui = try BoardUi.init(testing.allocator);
    defer ui.deinit();

    var hw: Gpio = .{};
    var status: SystemStatus = .{};

    // 1. Disconnected by default
    try testing.expect(!status.gpio_connected);

    const win_w: u32 = 1280;
    const win_h_disconnected: u32 = 764;
    const win_h_connected: u32 = 764 + BoardUi.gpio_panel_height;
    const pixels = try testing.allocator.alloc(u32, win_w * win_h_connected);
    defer testing.allocator.free(pixels);
    @memset(pixels, 0xff000000);

    ui.paint(pixels[0 .. win_w * win_h_disconnected], win_w, win_h_disconnected, 1, status, &hw);
    try testing.expectEqual(@as(f32, 0.0), ui.gpio_box_rect.h);

    // 2. Clicking the GPIO ribbon cable / header on the board diagram toggles .toggle_gpio
    const tr = BoardUi.boardTransform(&board.pi_zero, ui.board_rect);
    const gpio_click_x = tr.x + 32.5 * tr.scale;
    const gpio_click_y = tr.y + (-4.0) * tr.scale; // over the unplugged IDC ribbon cable above the GPIO header
    try testing.expect(ui.pointerMotion(gpio_click_x, gpio_click_y, status, &hw));
    try testing.expectEqual(@as(?InteractiveTarget, .gpio), ui.hovered_target);
    _ = ui.pointerButton(gpio_click_x, gpio_click_y, true, status, &hw);
    try testing.expectEqual(Action.toggle_gpio, ui.pointerButton(gpio_click_x, gpio_click_y, false, status, &hw));

    // Connect the GPIO ribbon cable
    status.gpio_connected = true;
    ui.paint(pixels, win_w, win_h_connected, 1, status, &hw);
    try testing.expectEqual(@as(f32, @floatFromInt(BoardUi.gpio_panel_height)), ui.gpio_box_rect.h);
    try testing.expectEqual(@as(f32, 764.0), ui.gpio_box_rect.y);

    // 3. Hardware reset defaults: all 28 header pins (0..27) are inputs ordered low-to-high;
    //    pins 0..8 default high (pulled up) and pins 9..27 default low (pulled down).
    try testing.expectEqual(@as(usize, 0), ui.gpio_output_count);
    try testing.expectEqual(@as(usize, 28), ui.gpio_input_count);
    for (0..28) |idx| {
        const pin = ui.gpio_input_pins[idx];
        try testing.expectEqual(@as(u6, @intCast(idx)), pin);
        if (pin <= 8) {
            try testing.expect(hw.getPinLevel(pin));
        } else {
            try testing.expect(!hw.getPinLevel(pin));
        }
    }

    // 4. Close the board sheet and toggle input switches in the GPIO box below the display
    ui.sheet_open = false;
    ui.updateLayout(win_w, win_h_connected, status, &hw);

    // Toggle GPIO 4 (default high -> low) and GPIO 17 (default low -> high)
    const sw4 = ui.gpioInputSwitchRect(4);
    hw.write32(0x4C, 1 << 17); // GPREN0: rising edge detect on GPIO 17
    hw.write32(0x58, 1 << 4); // GPFEN0: falling edge detect on GPIO 4
    _ = ui.pointerButton(sw4.x + sw4.w * 0.5, sw4.y + sw4.h * 0.5, true, status, &hw);
    try testing.expectEqual(Action.consumed, ui.pointerButton(sw4.x + sw4.w * 0.5, sw4.y + sw4.h * 0.5, false, status, &hw));
    try testing.expect(!hw.getPinLevel(4));

    const sw17 = ui.gpioInputSwitchRect(17);
    _ = ui.pointerButton(sw17.x + sw17.w * 0.5, sw17.y + sw17.h * 0.5, true, status, &hw);
    try testing.expectEqual(Action.consumed, ui.pointerButton(sw17.x + sw17.w * 0.5, sw17.y + sw17.h * 0.5, false, status, &hw));
    try testing.expect(hw.getPinLevel(17));
    try testing.expect(hw.irqPending());
    try testing.expect(hw.takeUiDirty());

    // 5. Guest OS reconfigures GPIO pins via MMIO (GPFSEL, GPSET, GPCLR, GPPUD, GPPUDCLK):
    //    Configure GPIO 21, GPIO 5, and GPIO 18 as outputs (0b001).
    //    Notice GPFSEL0 also contains GPIO 4 (currently overridden low by switch): read-modify-write
    //    of GPFSEL0 to set GPIO 5 as output must NOT clobber GPIO 4's input switch override!
    const gpfsel0_prev = hw.read32(0x00);
    hw.write32(0x00, gpfsel0_prev | (0b001 << 15)); // GPIO 5 -> output
    hw.write32(0x04, 0b001 << 24); // GPIO 18 -> output
    hw.write32(0x08, 0b001 << 3); // GPIO 21 -> output
    hw.write32(0x1C, (1 << 5) | (1 << 21)); // GPSET0: set GPIO 5 and GPIO 21 high
    try testing.expect(hw.takeUiDirty());

    ui.paint(pixels, win_w, win_h_connected, 1, status, &hw);

    // Outputs section has 3 pins ordered low-to-high: [5, 18, 21]
    try testing.expectEqual(@as(usize, 3), ui.gpio_output_count);
    try testing.expectEqual(@as(u6, 5), ui.gpio_output_pins[0]);
    try testing.expectEqual(@as(u6, 18), ui.gpio_output_pins[1]);
    try testing.expectEqual(@as(u6, 21), ui.gpio_output_pins[2]);
    try testing.expect(hw.getPinLevel(5));
    try testing.expect(!hw.getPinLevel(18));
    try testing.expect(hw.getPinLevel(21));

    // Inputs section now has 25 pins ordered low-to-high (excluding 5, 18, 21), and GPIO 4 kept its switch override
    try testing.expectEqual(@as(usize, 25), ui.gpio_input_count);
    for (1..ui.gpio_input_count) |i| {
        try testing.expect(ui.gpio_input_pins[i - 1] < ui.gpio_input_pins[i]);
    }
    try testing.expect(!hw.getPinLevel(4));

    // Guest OS reconfigures pull-up on input pin 12 via GPPUD (0x94) + GPPUDCLK0 (0x98)
    try testing.expect(!hw.getPinLevel(12));
    hw.write32(0x94, 2); // Pull-up
    hw.write32(0x98, 1 << 12); // Clock pull into GPIO 12
    hw.write32(0x94, 0);
    hw.write32(0x98, 0);
    try testing.expect(hw.takeUiDirty());
    try testing.expect(hw.getPinLevel(12));

    // Guest OS clears GPIO 21 via GPCLR0 (0x28)
    hw.write32(0x28, 1 << 21);
    try testing.expect(!hw.getPinLevel(21));
    ui.paint(pixels, win_w, win_h_connected, 1, status, &hw);
}

