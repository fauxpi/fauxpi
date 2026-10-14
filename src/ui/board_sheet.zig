//! Client-side Wayland window TitleBar (`44px` tall) and the drop-down
//! Board & GPIO Status Sheet (`BoardSheet`), ported from dazzle's
//! `src/ui/title_bar.zig` and `src/apps/settings/board_view.zig`.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const board = @import("board.zig");
const gpio_model = @import("gpio_model.zig");
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
pub const Mode = Gpio.Mode;
pub const Pin = gpio_model.Pin;

/// Pin colours from `dazzle/src/apps/settings/board_view.zig`.
const red: Color = .rgb(0xe53935);
const orange: Color = .rgb(0xfb8c00);
const grey: Color = .rgb(0x616161);
const green: Color = .rgb(0x43a047);
const blue: Color = .rgb(0x1e88e5);
const purple: Color = .rgb(0x8e24aa);

/// Line widths from `dazzle/src/apps/settings/board_view.zig`.
const line_w: f32 = 1.25;
const heavy_w: f32 = 1.75;

pub const ModeOption = struct {
    value: Mode,
    label: []const u8,
};

pub const mode_options = [_]ModeOption{
    .{ .value = .input, .label = "Input" },
    .{ .value = .input_pull_up, .label = "Input, pulled up" },
    .{ .value = .input_pull_down, .label = "Input, pulled down" },
    .{ .value = .output_low, .label = "Output, low" },
    .{ .value = .output_high, .label = "Output, high" },
};

pub const SystemStatus = struct {
    model: []const u8 = "Raspberry Pi Zero Rev 1.3",
    serial: []const u8 = "0000000012345678",
    cpu_busy_percent: f32 = 0.0,
    temperature_c: f32 = 42.0,
    mem_total_mb: u32 = 512,
    hdmi_width: u16 = 1280,
    hdmi_height: u16 = 720,
    hdmi_active: bool = true,
};

pub const Action = enum {
    none,
    consumed,
    start_drag,
    toggle_maximize,
    close,
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
    sheet_open: bool = false,

    /// Selected part index on the board; null defaults to the GPIO header (`select_gpio = true`).
    selected_part: ?usize = null,
    select_gpio: bool = true,
    hovered_part: ?usize = null,

    /// Selected header pin (0-indexed into the 40-pin header; 10 = pin 11 = GPIO 17).
    selected_pin: usize = 10,
    hovered_pin: ?usize = null,

    /// Whether the GPIO mode dropdown menu is open.
    mode_menu_open: bool = false,
    hovered_menu_item: ?usize = null,
    mode_btn_hovered: bool = false,
    mode_btn_pressed: bool = false,

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
    pins_origin: Point = .{ 0, 0 },
    mode_btn_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    mode_menu_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

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

    fn boardBtnRect() Rect {
        return .{ .x = 8, .y = (44.0 - bar_btn_size) * 0.5, .w = bar_btn_size, .h = bar_btn_size };
    }

    fn closeBtnRect(win_w: u32) Rect {
        const w: f32 = @floatFromInt(win_w);
        return .{ .x = w - 8.0 - bar_btn_size, .y = (44.0 - bar_btn_size) * 0.5, .w = bar_btn_size, .h = bar_btn_size };
    }

    fn maxBtnRect(win_w: u32) Rect {
        const w: f32 = @floatFromInt(win_w);
        return .{ .x = w - 8.0 - bar_btn_size - 4.0 - bar_btn_size, .y = (44.0 - bar_btn_size) * 0.5, .w = bar_btn_size, .h = bar_btn_size };
    }

    pub fn resolvedPartIndex(self: *const BoardUi, drawing: *const board.Board) usize {
        if (self.selected_part) |idx| {
            return @min(idx, drawing.parts.len - 1);
        }
        if (self.select_gpio) {
            for (drawing.parts, 0..) |part, i| {
                if (part.kind == .gpio or part.kind == .gpio_holes) return i;
            }
        }
        for (drawing.parts, 0..) |part, i| {
            if (part.kind == .soc or part.kind == .soc_with_ram) return i;
        }
        return 0;
    }

    fn boardTransform(drawing: *const board.Board, box: Rect) struct { scale: f32, x: f32, y: f32 } {
        const r = drawing.bounds();
        const scale = @min(box.w / r.w, box.h / r.h);
        const x = box.x + (box.w - r.w * scale) * 0.5 - r.x * scale;
        const y = box.y + (box.h - r.h * scale) * 0.5 - r.y * scale;
        return .{ .scale = scale, .x = x, .y = y };
    }

    fn pinDotRect(pins_origin: Point, index: usize) Rect {
        const col: f32 = @floatFromInt(index / 2);
        const row: f32 = @floatFromInt(index % 2);
        const size: f32 = 20.0;
        const spacing: f32 = 3.0;
        return .{
            .x = pins_origin[0] + col * (size + spacing),
            .y = pins_origin[1] + row * (size + spacing),
            .w = size,
            .h = size,
        };
    }

    /// Updates layout geometry for `(win_w, win_h)` so hit testing and painting match.
    pub fn updateLayout(self: *BoardUi, win_w: u32, win_h: u32, status: SystemStatus, gpio_hw: *const Gpio) void {
        self.last_win_w = win_w;
        self.last_win_h = win_h;

        const w_f: f32 = @floatFromInt(win_w);
        const sheet_w = @min(@max(w_f - 32.0, 320.0), 660.0);
        const sheet_x = @round((w_f - sheet_w) * 0.5);
        const sheet_y: f32 = @floatFromInt(title_bar_height);
        const pad: f32 = 24.0;

        var y: f32 = sheet_y + 20.0;
        // Model + Serial
        y += 24.0;
        if (status.serial.len > 0) y += 22.0;

        const drawing = board.forModel(status.model) orelse &board.pi_zero;
        const bounds = drawing.bounds();
        const max_bw: f32 = 260.0;
        const max_bh: f32 = 170.0;
        const bw = @min(sheet_w - 2 * pad, max_bw);
        const bh = @min(bw * bounds.h / bounds.w, max_bh);
        const actual_bw = bw * @min(1.0, bh / (bw * bounds.h / bounds.w));

        y += 8.0;
        self.board_rect = .{ .x = sheet_x + pad, .y = y, .w = actual_bw, .h = bh };
        y += bh + 12.0;

        // Part title + description
        const picked = self.resolvedPartIndex(drawing);
        const part = &drawing.parts[picked];
        y += 26.0; // title
        y += 22.0; // description

        self.mode_btn_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        self.mode_menu_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

        switch (part.kind) {
            .soc, .soc_with_ram, .ram, .mini_hdmi, .hdmi, .micro_hdmi => {
                y += 22.0;
            },
            .usb, .usb_double, .usb_otg => {
                y += 2 * 48.0;
            },
            .gpio, .gpio_holes => {
                if (gpio_model.headerFor(status.model)) |header| {
                    y += 6.0;
                    self.pins_origin = .{ sheet_x + pad, y };
                    y += 20.0 * 2.0 + 3.0 + 12.0; // 2 rows of 20px pins + 3px spacing

                    // Colour key row
                    y += 24.0;

                    // Pin detail
                    const pin_idx = @min(self.selected_pin, header.len - 1);
                    y += 24.0; // Pin title
                    y += 22.0; // Pin description / doing
                    switch (header[pin_idx]) {
                        .gpio => |g| {
                            if (gpio_hw.getPinFunction(g).alt() != null) {
                                y += 22.0; // "It is high/low now"
                            }
                            const mode_label = if (gpio_hw.getPinMode(g)) |m| m.label() else "Set mode";
                            const text_w = textWidth(&self.font, 14.0, mode_label);
                            const btn_w = @max(48.0, 24.0 + text_w + 8.0 + 18.0 + 24.0);
                            const btn_h: f32 = 40.0;
                            y += 4.0;
                            self.mode_btn_rect = .{
                                .x = sheet_x + pad,
                                .y = y,
                                .w = btn_w,
                                .h = btn_h,
                            };
                            y += btn_h;

                            if (self.mode_menu_open) {
                                const menu_w: f32 = 220.0;
                                const menu_h: f32 = @as(f32, @floatFromInt(mode_options.len)) * 44.0 + 16.0;
                                const win_h_f: f32 = @floatFromInt(win_h);
                                const menu_y = if (self.mode_btn_rect.y + btn_h + menu_h <= win_h_f)
                                    self.mode_btn_rect.y + btn_h
                                else
                                    @max(sheet_y + 4.0, self.mode_btn_rect.y - menu_h);
                                self.mode_menu_rect = .{
                                    .x = self.mode_btn_rect.x,
                                    .y = menu_y,
                                    .w = menu_w,
                                    .h = menu_h,
                                };
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }

        y += 20.0;
        self.sheet_rect = .{
            .x = sheet_x,
            .y = sheet_y,
            .w = sheet_w,
            .h = y - sheet_y,
        };
    }

    fn textWidth(f: *const Font, size: f32, str: []const u8) f32 {
        return @import("../font/text.zig").measure(.{ .font = f, .size = size }, str);
    }

    /// Handles pointer motion at `(x, y)` in window coordinates.
    /// Returns true if the pointer is over the TitleBar or an open BoardSheet.
    pub fn pointerMotion(self: *BoardUi, x: f32, y: f32, status: SystemStatus, gpio_hw: *const Gpio) bool {
        self.updateLayout(self.last_win_w, self.last_win_h, status, gpio_hw);
        const pt: Point = .{ x, y };

        self.board_btn_hovered = boardBtnRect().contains(pt);
        self.max_btn_hovered = maxBtnRect(self.last_win_w).contains(pt);
        self.close_btn_hovered = closeBtnRect(self.last_win_w).contains(pt);

        if (!self.sheet_open) {
            self.hovered_part = null;
            self.hovered_pin = null;
            self.hovered_menu_item = null;
            self.mode_btn_hovered = false;
            return y < @as(f32, @floatFromInt(title_bar_height));
        }

        if (self.mode_menu_open and self.mode_menu_rect.contains(pt)) {
            const rel_y = y - (self.mode_menu_rect.y + 8.0);
            if (rel_y >= 0) {
                const idx: usize = @intFromFloat(@floor(rel_y / 44.0));
                self.hovered_menu_item = if (idx < mode_options.len) idx else null;
            } else {
                self.hovered_menu_item = null;
            }
            self.hovered_part = null;
            self.hovered_pin = null;
            self.mode_btn_hovered = false;
            return true;
        }
        self.hovered_menu_item = null;

        // Board drawing hover
        const drawing = board.forModel(status.model) orelse &board.pi_zero;
        if (self.board_rect.contains(pt)) {
            const tr = boardTransform(drawing, self.board_rect);
            self.hovered_part = drawing.partAt(.{ (x - tr.x) / tr.scale, (y - tr.y) / tr.scale });
        } else {
            self.hovered_part = null;
        }

        // GPIO pins & mode button hover
        self.hovered_pin = null;
        self.mode_btn_hovered = false;
        const picked = self.resolvedPartIndex(drawing);
        const part = &drawing.parts[picked];
        if (part.kind == .gpio or part.kind == .gpio_holes) {
            if (gpio_model.headerFor(status.model)) |header| {
                for (0..header.len) |i| {
                    if (pinDotRect(self.pins_origin, i).contains(pt)) {
                        self.hovered_pin = i;
                        break;
                    }
                }
                if (self.mode_btn_rect.w > 0 and self.mode_btn_rect.contains(pt)) {
                    self.mode_btn_hovered = true;
                }
            }
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
        self.hovered_part = null;
        self.hovered_pin = null;
        self.hovered_menu_item = null;
        self.mode_btn_hovered = false;
        self.mode_btn_pressed = false;
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
                if (boardBtnRect().contains(pt)) {
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
                if (self.board_btn_pressed and boardBtnRect().contains(pt)) {
                    self.sheet_open = !self.sheet_open;
                    if (!self.sheet_open) self.mode_menu_open = false;
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

        // Sheet is open: handle clicks inside the sheet or backdrop scrim
        if (pressed) {
            if (self.mode_menu_open) {
                if (self.mode_menu_rect.contains(pt)) {
                    return .consumed;
                }
                // Clicking outside the open menu closes the menu
                self.mode_menu_open = false;
                return .consumed;
            }
            if (self.mode_btn_rect.w > 0 and self.mode_btn_rect.contains(pt)) {
                self.mode_btn_pressed = true;
                return .consumed;
            }
            return .consumed;
        } else {
            defer self.mode_btn_pressed = false;

            // Release while menu is open
            if (self.mode_menu_open and self.mode_menu_rect.contains(pt)) {
                const rel_y = y - (self.mode_menu_rect.y + 8.0);
                if (rel_y >= 0) {
                    const idx: usize = @intFromFloat(@floor(rel_y / 44.0));
                    if (idx < mode_options.len) {
                        if (gpio_model.headerFor(status.model)) |header| {
                            const pin_idx = @min(self.selected_pin, header.len - 1);
                            switch (header[pin_idx]) {
                                .gpio => |g| gpio_hw.setPinMode(g, mode_options[idx].value),
                                else => {},
                            }
                        }
                    }
                }
                self.mode_menu_open = false;
                return .consumed;
            }

            // Release on mode button
            if (self.mode_btn_pressed and self.mode_btn_rect.w > 0 and self.mode_btn_rect.contains(pt)) {
                self.mode_menu_open = !self.mode_menu_open;
                return .consumed;
            }

            // Release inside board drawing
            const drawing = board.forModel(status.model) orelse &board.pi_zero;
            if (self.board_rect.contains(pt)) {
                const tr = boardTransform(drawing, self.board_rect);
                if (drawing.partAt(.{ (x - tr.x) / tr.scale, (y - tr.y) / tr.scale })) |part_idx| {
                    self.selected_part = part_idx;
                    self.mode_menu_open = false;
                    return .consumed;
                }
            }

            // Release on a GPIO pin dot
            const picked = self.resolvedPartIndex(drawing);
            const part = &drawing.parts[picked];
            if (part.kind == .gpio or part.kind == .gpio_holes) {
                if (gpio_model.headerFor(status.model)) |header| {
                    for (0..header.len) |i| {
                        if (pinDotRect(self.pins_origin, i).contains(pt)) {
                            self.selected_pin = i;
                            self.mode_menu_open = false;
                            return .consumed;
                        }
                    }
                }
            }

            // Release outside the sheet card (on the dimmed HDMI area) dismisses the sheet
            if (!self.sheet_rect.contains(pt)) {
                self.sheet_open = false;
                self.mode_menu_open = false;
            }
            return .consumed;
        }
    }

    /// Renders the client-side TitleBar (`y = 0..44` logical) and, when open, the
    /// drop-down Board & GPIO Status Sheet over `pixels` at `scale` (e.g. 1x or 2x).
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

        self.paintTitleBar(&c, win_w);
        if (self.sheet_open) {
            self.paintSheet(&c, win_w, win_h, status, gpio_hw);
        }
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

        // Left button: Board / GPIO sheet toggle (.developer_board)
        paintBarButton(
            c,
            t,
            boardBtnRect(),
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
        gpio_hw: *const Gpio,
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

        const pad: f32 = 24.0;
        const x0 = sr.x + pad;
        var y = sr.y + 20.0;

        // 1. Board model and serial
        _ = c.drawText(18.0, x0, y + 16.0, status.model, t.on_surface);
        y += 24.0;
        if (status.serial.len > 0) {
            var serial_buf: [64]u8 = undefined;
            const serial_str = std.fmt.bufPrint(&serial_buf, "Serial: {s}", .{status.serial}) catch status.serial;
            _ = c.drawText(15.0, x0, y + 13.0, serial_str, t.on_surface_variant);
            y += 22.0;
        }

        // 2. Interactive BoardView drawing
        const drawing = board.forModel(status.model) orelse &board.pi_zero;
        const picked = self.resolvedPartIndex(drawing);
        self.paintBoardDrawing(c, drawing, self.board_rect, picked);
        y = self.board_rect.y + self.board_rect.h + 12.0;

        // 3. Picked part title & description
        const part = &drawing.parts[picked];
        const about = board.describe(part);
        var title_buf: [128]u8 = undefined;
        const part_title = if (part.chip.len > 0)
            std.fmt.bufPrint(&title_buf, "{s}: {s}", .{ about.title, part.chip }) catch about.title
        else
            about.title;
        _ = c.drawText(20.0, x0, y + 18.0, part_title, t.on_surface);
        y += 26.0;

        var desc_buf: [160]u8 = undefined;
        const part_desc = std.fmt.bufPrint(&desc_buf, "{s}{s}", .{
            about.about,
            if (part.underside) " (underneath the board)" else "",
        }) catch about.about;
        _ = c.drawText(16.0, x0, y + 14.0, part_desc, t.on_surface_variant);
        y += 22.0;

        // 4. Live status for the picked part
        switch (part.kind) {
            .soc, .soc_with_ram => {
                var status_buf: [128]u8 = undefined;
                const status_str = std.fmt.bufPrint(
                    &status_buf,
                    "{d:.0}% busy, at {d:.1} °C  ·  {d} MB of memory",
                    .{ status.cpu_busy_percent, status.temperature_c, status.mem_total_mb },
                ) catch "";
                _ = c.drawText(16.0, x0, y + 14.0, status_str, t.on_surface);
            },
            .mini_hdmi, .hdmi, .micro_hdmi => {
                var hdmi_buf: [64]u8 = undefined;
                const hdmi_str = if (status.hdmi_active)
                    std.fmt.bufPrint(&hdmi_buf, "{d} × {d} at 60 Hz", .{ status.hdmi_width, status.hdmi_height }) catch "Connected"
                else
                    "No signal";
                _ = c.drawText(16.0, x0, y + 14.0, hdmi_str, t.on_surface);
            },
            .usb, .usb_double, .usb_otg => {
                const usb_items = [_]struct { icon: Icon, name: []const u8, detail: []const u8 }{
                    .{ .icon = .keyboard, .name = "USB Keyboard", .detail = "Keyboard  ·  FauxPi  ·  12 Mb/s" },
                    .{ .icon = .mouse, .name = "USB Mouse", .detail = "Mouse  ·  FauxPi  ·  12 Mb/s" },
                };
                for (usb_items) |item| {
                    c.drawIcon(item.icon, x0, y + 8.0, 28.0, t.on_surface_variant);
                    _ = c.drawText(17.0, x0 + 44.0, y + 19.0, item.name, t.on_surface);
                    _ = c.drawText(14.0, x0 + 44.0, y + 38.0, item.detail, t.on_surface_variant);
                    y += 48.0;
                }
            },
            .gpio, .gpio_holes => {
                self.paintGpioSection(c, x0, status.model, gpio_hw);
            },
            else => {},
        }

        // 5. Mode dropdown menu overlay (painted on top of everything in the sheet)
        if (self.mode_menu_open and self.mode_menu_rect.w > 0) {
            self.paintModeMenu(c);
        }
    }

    fn paintBoardDrawing(
        self: *const BoardUi,
        c: *Canvas,
        b: *const board.Board,
        box: Rect,
        selected: ?usize,
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
            if (!part.underside) drawPart(c, &part, map(tr, part.rect), s, ink);
        }

        // Hovered and selected highlights
        if (self.hovered_part) |i| {
            if (i < b.parts.len) {
                c.fillRoundedRect(map(tr, b.parts[i].rect), .all(0.6 * s), t.primary.withAlpha(0.18));
            }
        }
        if (selected) |i| {
            if (i < b.parts.len) {
                const r = map(tr, b.parts[i].rect);
                c.fillRoundedRect(r, .all(0.6 * s), t.primary.withAlpha(0.35));
                c.strokeRoundedRect(r, .all(0.6 * s), heavy_w, t.primary);
            }
        }
    }

    fn paintGpioSection(
        self: *const BoardUi,
        c: *Canvas,
        x0: f32,
        model: []const u8,
        gpio_hw: *const Gpio,
    ) void {
        const t = &self.theme;
        const header = gpio_model.headerFor(model) orelse return;
        const picked_idx = @min(self.selected_pin, header.len - 1);

        // 1. Horizontal 2x20 pin diagram
        for (header, 0..) |pin, i| {
            const r = pinDotRect(self.pins_origin, i);
            const picked = (i == picked_idx);
            const colour: Color, const filled: bool = switch (pin) {
                .power_5v => .{ red, true },
                .power_3v3 => .{ orange, true },
                .ground => .{ grey, true },
                .gpio => |g| switch (gpio_hw.getPinFunction(g)) {
                    .output => .{ green, gpio_hw.getPinLevel(g) },
                    .input => .{ blue, gpio_hw.getPinLevel(g) },
                    else => .{ purple, true },
                },
            };

            const center: Point = .{ r.x + r.w * 0.5, r.y + r.h * 0.5 };
            const radius = r.w * 0.5;
            if (filled) {
                c.fillCircle(center, radius, colour);
            }
            if (picked) {
                c.strokeCircle(center, radius, 3.0, t.on_surface);
            } else {
                c.strokeCircle(center, radius, 2.0, colour);
            }

            var num_buf: [8]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "";
            const num_w = c.measureText(9.0, num_str);
            const num_style: canvas_mod.Style = .{ .font = &self.font, .size = 9.0 };
            const tx = @round(r.x + (r.w - num_w) * 0.5);
            const ty = @round(r.y + (r.h - num_style.lineHeight()) * 0.5 + num_style.ascent());
            _ = c.drawText(9.0, tx, ty, num_str, if (filled) .rgb(0xffffff) else t.on_surface);
        }

        // 2. Colour key row
        var key_y = self.pins_origin[1] + 20.0 * 2.0 + 3.0 + 12.0;
        const entries = [_]struct { Color, []const u8 }{
            .{ red, "5V" },
            .{ orange, "3.3V" },
            .{ grey, "Ground" },
            .{ blue, "Input" },
            .{ green, "Output" },
            .{ purple, "Other" },
        };
        var kx = x0;
        for (entries) |e| {
            c.fillCircle(.{ kx + 6.0, key_y + 8.0 }, 6.0, e[0]);
            kx = c.drawText(14.0, kx + 18.0, key_y + 13.0, e[1], t.on_surface_variant) + 14.0;
        }
        key_y += 24.0;

        // 3. Selected pin detail + mode selector
        const pin_num = picked_idx + 1;
        switch (header[picked_idx]) {
            .power_5v => {
                var b1: [32]u8 = undefined;
                const s1 = std.fmt.bufPrint(&b1, "5V, pin {d}", .{pin_num}) catch "5V";
                _ = c.drawText(18.0, x0, key_y + 16.0, s1, t.on_surface);
                _ = c.drawText(16.0, x0, key_y + 40.0, "5 V power from the board's power supply", t.on_surface_variant);
            },
            .power_3v3 => {
                var b1: [32]u8 = undefined;
                const s1 = std.fmt.bufPrint(&b1, "3.3V, pin {d}", .{pin_num}) catch "3.3V";
                _ = c.drawText(18.0, x0, key_y + 16.0, s1, t.on_surface);
                _ = c.drawText(16.0, x0, key_y + 40.0, "3.3 V power from the board", t.on_surface_variant);
            },
            .ground => {
                var b1: [32]u8 = undefined;
                const s1 = std.fmt.bufPrint(&b1, "Ground, pin {d}", .{pin_num}) catch "Ground";
                _ = c.drawText(18.0, x0, key_y + 16.0, s1, t.on_surface);
                _ = c.drawText(16.0, x0, key_y + 40.0, "Ground (0 V)", t.on_surface_variant);
            },
            .gpio => |g| {
                var title_buf: [64]u8 = undefined;
                const title = if (gpio_model.usualName(g)) |u|
                    std.fmt.bufPrint(&title_buf, "GPIO {d} ({s}), pin {d}", .{ g, u, pin_num }) catch "GPIO"
                else
                    std.fmt.bufPrint(&title_buf, "GPIO {d}, pin {d}", .{ g, pin_num }) catch "GPIO";
                _ = c.drawText(18.0, x0, key_y + 16.0, title, t.on_surface);
                key_y += 24.0;

                var doing_buf: [64]u8 = undefined;
                const doing = gpio_model.gpioDoing(&doing_buf, gpio_hw, g);
                _ = c.drawText(16.0, x0, key_y + 14.0, doing, t.on_surface);
                key_y += 22.0;

                if (gpio_hw.getPinFunction(g).alt() != null) {
                    var now_buf: [32]u8 = undefined;
                    const now_str = std.fmt.bufPrint(&now_buf, "It is {s} now", .{if (gpio_hw.getPinLevel(g)) "high" else "low"}) catch "";
                    _ = c.drawText(16.0, x0, key_y + 14.0, now_str, t.on_surface_variant);
                    key_y += 22.0;
                }

                // Mode OutlinedButton (with trailing .expand_more icon)
                const br = self.mode_btn_rect;
                if (br.w > 0) {
                    const layer: f32 = if (self.mode_btn_pressed) 0.10 else if (self.mode_btn_hovered) 0.08 else 0.0;
                    if (layer > 0.0) {
                        c.fillRoundedRect(br, .all(br.h * 0.5), t.primary.withAlpha(layer));
                    }
                    c.strokeRoundedRect(br, .all(br.h * 0.5), 1.0, t.outline);

                    const mode_label = if (gpio_hw.getPinMode(g)) |m| m.label() else "Set mode";
                    const lbl_style: canvas_mod.Style = .{ .font = &self.font, .size = 14.0 };
                    const lbl_y = @round(br.y + (br.h - lbl_style.lineHeight()) * 0.5 + lbl_style.ascent());
                    const text_end = c.drawText(14.0, br.x + 24.0, lbl_y, mode_label, t.primary);
                    c.drawIcon(
                        if (self.mode_menu_open) .expand_less else .expand_more,
                        @round(text_end + 8.0),
                        @round(br.y + (br.h - 18.0) * 0.5),
                        18.0,
                        t.primary,
                    );
                }
            },
        }
    }

    fn paintModeMenu(self: *const BoardUi, c: *Canvas) void {
        const t = &self.theme;
        const mr = self.mode_menu_rect;
        c.fillRoundedRect(mr, .all(4.0), t.surface_container);
        c.strokeRoundedRect(mr, .all(4.0), 1.0, t.outline_variant);

        const item_style: canvas_mod.Style = .{ .font = &self.font, .size = 14.0 };
        for (mode_options, 0..) |opt, i| {
            const iy = mr.y + 8.0 + @as(f32, @floatFromInt(i)) * 44.0;
            const ir: Rect = .{ .x = mr.x + 1.0, .y = iy, .w = mr.w - 2.0, .h = 44.0 };
            if (self.hovered_menu_item == i) {
                c.fillRect(ir, t.on_surface.withAlpha(0.08));
            }
            const baseline = @round(iy + (44.0 - item_style.lineHeight()) * 0.5 + item_style.ascent());
            _ = c.drawText(14.0, mr.x + 12.0, baseline, opt.label, t.on_surface);
        }
    }
};

/// Draws a single board part, ported directly from `dazzle/src/apps/settings/board_view.zig`.
pub fn drawPart(c: *Canvas, part: *const board.Part, r: Rect, s: f32, ink: Color) void {
    const radius: Radii = .all(0.6 * s);
    switch (part.kind) {
        .soc, .soc_with_ram, .ram, .usb_ethernet, .usb_controller, .southbridge, .ethernet_phy, .wireless, .pmic, .emmc => {
            c.strokeRoundedRect(r, radius, heavy_w, ink);
            if (part.lidded) {
                c.strokeRoundedRect(r.outset(-1.2 * s), radius, line_w, ink);
            } else if (r.w > 3 * s) {
                // Pin 1.
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
            c.strokeRoundedRect(r, .all(0.4 * s), line_w, ink);
            if (r.h > r.w) {
                c.fillRect(.{ .x = r.x + r.w * 0.5 - line_w * 0.5, .y = r.y + 1.5 * s, .w = line_w, .h = r.h - 3.0 * s }, ink);
            } else {
                c.fillRect(.{ .x = r.x + 1.5 * s, .y = r.y + r.h * 0.5 - line_w * 0.5, .w = r.w - 3.0 * s, .h = line_w }, ink);
            }
        },
        .edge => {
            const pitch = 1.2 * s;
            var x = r.x + pitch * 0.5;
            while (x <= r.x + r.w) : (x += pitch) {
                c.fillRect(.{ .x = x, .y = r.y + 0.3 * s, .w = line_w, .h = r.h - 0.6 * s }, ink);
            }
        },
    }
}

const testing = std.testing;

test "TitleBar and BoardSheet toggle, select parts, and configure GPIO pins" {
    var ui = try BoardUi.init(testing.allocator);
    defer ui.deinit();

    var hw: Gpio = .{};
    const status: SystemStatus = .{ .cpu_busy_percent = 34.0, .temperature_c = 45.2 };

    const win_w: u32 = 1280;
    const win_h: u32 = 764;
    const pixels = try testing.allocator.alloc(u32, win_w * win_h);
    defer testing.allocator.free(pixels);
    @memset(pixels, 0xff000000);

    // 1. Paint closed state (only TitleBar at top 44px)
    ui.paint(pixels, win_w, win_h, 1, status, &hw);
    try testing.expect(!ui.sheet_open);

    // Dragging the center of the title bar returns .start_drag
    try testing.expectEqual(Action.start_drag, ui.pointerButton(640, 22, true, status, &hw));

    // Clicking the Board button in the top-left opens the drop-down sheet
    const btn_r = BoardUi.boardBtnRect();
    try testing.expectEqual(Action.consumed, ui.pointerButton(btn_r.x + 10, btn_r.y + 10, true, status, &hw));
    try testing.expectEqual(Action.consumed, ui.pointerButton(btn_r.x + 10, btn_r.y + 10, false, status, &hw));
    try testing.expect(ui.sheet_open);

    // Paint with the drop-down sheet open at 1x and 2x HiDPI scale
    ui.paint(pixels, win_w, win_h, 1, status, &hw);
    try testing.expect(ui.sheet_rect.h > 300);

    const pixels_2x = try testing.allocator.alloc(u32, (win_w * 2) * (win_h * 2));
    defer testing.allocator.free(pixels_2x);
    @memset(pixels_2x, 0xff000000);
    ui.paint(pixels_2x, win_w, win_h, 2, status, &hw);
    // TitleBar spans physical rows 0..88 at 2x scale
    try testing.expectEqual(Theme.dark.surface_container.toArgb(), pixels_2x[80 * (win_w * 2) + 200]);

    // Pin 11 (index 10, GPIO 17) is selected by default; open the mode menu and set "Output, high"
    const mb = ui.mode_btn_rect;
    try testing.expect(mb.w > 0);
    _ = ui.pointerButton(mb.x + 10, mb.y + 10, true, status, &hw);
    _ = ui.pointerButton(mb.x + 10, mb.y + 10, false, status, &hw);
    try testing.expect(ui.mode_menu_open);

    ui.updateLayout(win_w, win_h, status, &hw);
    const mr = ui.mode_menu_rect;
    // Option 4 is "Output, high"
    const opt4_y = mr.y + 8.0 + 4.0 * 44.0 + 22.0;
    _ = ui.pointerButton(mr.x + 40, opt4_y, true, status, &hw);
    _ = ui.pointerButton(mr.x + 40, opt4_y, false, status, &hw);
    try testing.expect(!ui.mode_menu_open);
    try testing.expectEqual(Gpio.Function.output, hw.getPinFunction(17));
    try testing.expect(hw.getPinLevel(17));

    // Clicking outside the sheet (near bottom of window) closes the sheet
    _ = ui.pointerButton(640, 740, true, status, &hw);
    _ = ui.pointerButton(640, 740, false, status, &hw);
    try testing.expect(!ui.sheet_open);
}
