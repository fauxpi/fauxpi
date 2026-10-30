//! Common desktop window state, compositing, input routing, and platform dispatch
//! shared across `WaylandWindow`, `MacosWindow`, and `WindowsWindow`.

const std = @import("std");
const builtin = @import("builtin");
const host_posix = @import("../host/posix.zig");
const UsbHidComposite = @import("../usb/hid.zig").UsbHidComposite;
const Gpio = @import("../soc/gpio.zig").Gpio;
const board_sheet = @import("../ui/board_sheet.zig");

pub const wayland_window = @import("wayland_window.zig");
pub const macos_window = @import("macos_window.zig");
pub const windows_window = @import("windows_window.zig");

/// Platform-native desktop window backend (`WindowsWindow` on Windows, `MacosWindow` on macOS, `WaylandWindow` on Linux).
pub const Window = switch (builtin.os.tag) {
    .macos => macos_window.MacosWindow,
    .windows => windows_window.WindowsWindow,
    else => wayland_window.WaylandWindow,
};

pub const cursor_logical_dim: u32 = 24;
pub const crosshair_logical_hot: i32 = 12;

pub const CursorMode = enum {
    unknown,
    ui_arrow,
    hdmi_crosshair,
};

pub const KeyRepeat = struct {
    key: u32,
    next_ns: u64,
};

pub const BufferState = struct {
    hdmi_gen: u64 = 0,
    had_sheet: bool = false,
    hdmi_state: u2 = 0,
    sheet_rect: board_sheet.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    display_rect: board_sheet.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    sheet_docked: bool = false,
};

pub const CommonResources = struct {
    ui: board_sheet.BoardUi,
    status: board_sheet.SystemStatus,
    hdmi_fb: []u32,
    width: u32,
    height: u32,

    pub fn deinit(self: *CommonResources, gpa: std.mem.Allocator) void {
        self.ui.deinit();
        gpa.free(self.hdmi_fb);
    }
};

pub fn defaultWindowHeight(display_height: u32, status: board_sheet.SystemStatus) u32 {
    return display_height + board_sheet.BoardUi.title_bar_height +
        (if (status.gpio_connected) board_sheet.BoardUi.gpio_panel_height else 0);
}

pub fn initCommonResources(
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    display_width: u32,
    display_height: u32,
    hid: *UsbHidComposite,
    gpio: *Gpio,
) !CommonResources {
    var ui = try board_sheet.BoardUi.init(gpa);
    errdefer ui.deinit();

    const hdmi_fb = try gpa.alloc(u32, @as(usize, display_width) * @as(usize, display_height));
    errdefer gpa.free(hdmi_fb);
    @memset(hdmi_fb, 0xFF101418);

    var status: board_sheet.SystemStatus = .{
        .serial_u64 = ui.parsedSerial(),
        .mac_address = ui.parsedMac(),
        .wifi_mac_address = ui.parsedWifiMac(),
        .hdmi_width = @intCast(display_width),
        .hdmi_height = @intCast(display_height),
    };
    ui.configureXdgStorage(environ, &status);

    gpio.setExternalPin(46, !status.hdmi_connected);
    hid.setHubKind(status.board_model.hubKind());
    hid.hub_connected = status.usb_hub_connected;
    hid.keyboard_connected = status.usb_keyboard_connected;
    hid.mouse_connected = status.usb_mouse_connected;
    hid.ethernet_connected = status.ethernet_connected;
    hid.net.dhcp_enabled = status.dhcp_enabled;

    return .{
        .ui = ui,
        .status = status,
        .hdmi_fb = hdmi_fb,
        .width = display_width,
        .height = defaultWindowHeight(display_height, status),
    };
}

pub fn paintFaintCrosshairCursor(pixels: []u32, sc: u32) void {
    const dim: usize = @as(usize, cursor_logical_dim) * @as(usize, sc);
    @memset(pixels, 0x00000000);

    const c: i32 = @intCast(crosshair_logical_hot);
    // Premultiplied ARGB8888: faint ~22% white core with subtle ~11% dark halo
    // so the crosshair is subtly visible on both dark and light HDMI frames without
    // doubling up with the guest OS cursor.
    const core_px: u32 = 0x38383838;
    const halo_px: u32 = 0x1C000000;

    var d: i32 = -5;
    while (d <= 5) : (d += 1) {
        if (d >= -1 and d <= 1) continue; // 3x3 gap around center tip
        // Horizontal arm (y = c, x = c + d) + 1px halo above/below
        fillScaledCursorPixel(pixels, dim, sc, c + d, c - 1, halo_px);
        fillScaledCursorPixel(pixels, dim, sc, c + d, c, core_px);
        fillScaledCursorPixel(pixels, dim, sc, c + d, c + 1, halo_px);
        // Vertical arm (x = c, y = c + d) + 1px halo left/right
        fillScaledCursorPixel(pixels, dim, sc, c - 1, c + d, halo_px);
        fillScaledCursorPixel(pixels, dim, sc, c, c + d, core_px);
        fillScaledCursorPixel(pixels, dim, sc, c + 1, c + d, halo_px);
    }
    // Subtle center dot
    fillScaledCursorPixel(pixels, dim, sc, c, c, core_px);
}

pub fn paintArrowCursor(pixels: []u32, sc: u32) void {
    const dim: usize = @as(usize, cursor_logical_dim) * @as(usize, sc);
    @memset(pixels, 0x00000000);
    const arrow_rows = [_][]const u8{
        "X",
        "XX",
        "X.X",
        "X..X",
        "X...X",
        "X....X",
        "X.....X",
        "X......X",
        "X.......X",
        "X........X",
        "X.....XXXXX",
        "X..X..X",
        "X.X X..X",
        "XX  X..X",
        "X    X..X",
        "     X..X",
        "      XX",
    };
    for (arrow_rows, 0..) |row, ly| {
        for (row, 0..) |ch, lx| {
            const color: u32 = switch (ch) {
                'X' => 0xFF000000,
                '.' => 0xFFFFFFFF,
                else => continue,
            };
            fillScaledCursorPixel(pixels, dim, sc, @intCast(lx + 1), @intCast(ly + 1), color);
        }
    }
}

fn fillScaledCursorPixel(pixels: []u32, dim: usize, sc: u32, lx: i32, ly: i32, color: u32) void {
    if (lx < 0 or ly < 0) return;
    const x0: usize = @as(usize, @intCast(lx)) * @as(usize, sc);
    const y0: usize = @as(usize, @intCast(ly)) * @as(usize, sc);
    const s: usize = sc;
    var dy: usize = 0;
    while (dy < s) : (dy += 1) {
        const py = y0 + dy;
        if (py >= dim) break;
        var dx: usize = 0;
        while (dx < s) : (dx += 1) {
            const px = x0 + dx;
            if (px >= dim) break;
            pixels[py * dim + px] = color;
        }
    }
}

pub fn notifyHdmiUpdated(win: anytype) void {
    win.hdmi_gen +%= 1;
    if (win.hdmi_gen == 0) win.hdmi_gen = 1;
}

pub fn chosenSdPath(win: anytype) []const u8 {
    return win.chosen_sd_path_buf[0..win.chosen_sd_path_len];
}

pub fn setChosenSdPath(win: anytype, path: []const u8) void {
    if (path.len == 0 or path.len > win.chosen_sd_path_buf.len) return;
    @memcpy(win.chosen_sd_path_buf[0..path.len], path);
    win.chosen_sd_path_len = path.len;
    const fsize = board_sheet.Qcow2Disk.getFileSizeLinux(path) catch 0;
    win.ui.setPendingSdImageFile(path, fsize);
    win.ui_dirty = true;
}

/// Non-blocking child process pipe reader used by the macOS (`osascript`) file chooser dialog.
pub const PosixFilePicker = struct {
    fd: host_posix.fd_t = -1,
    pid: host_posix.pid_t = -1,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    pub fn close(self: *PosixFilePicker) void {
        if (self.fd >= 0) {
            host_posix.close(self.fd);
            self.fd = -1;
        }
        self.pid = -1;
        self.len = 0;
    }

    pub fn spawn(self: *PosixFilePicker, comptime childFn: fn () noreturn) void {
        if (self.fd >= 0) return;

        var fds: [2]host_posix.fd_t = undefined;
        if (!host_posix.pipeNonBlockCloexec(&fds)) return;

        const pid = host_posix.forkProcess() orelse {
            host_posix.close(fds[0]);
            host_posix.close(fds[1]);
            return;
        };

        if (pid == 0) {
            host_posix.dup2Stdout(fds[1]);
            host_posix.close(fds[0]);
            host_posix.close(fds[1]);
            childFn();
        }

        host_posix.close(fds[1]);
        self.fd = fds[0];
        self.pid = pid;
        self.len = 0;
    }

    pub fn poll(self: *PosixFilePicker, win: anytype) void {
        if (self.fd < 0) return;

        while (self.len < self.buf.len) {
            switch (host_posix.readNonBlock(self.fd, self.buf[self.len..])) {
                .again => return,
                .err => break,
                .bytes => |rc| {
                    if (rc == 0) {
                        host_posix.waitpidBlocking(self.pid);
                        host_posix.close(self.fd);
                        self.fd = -1;
                        self.pid = -1;

                        const trimmed = std.mem.trim(u8, self.buf[0..self.len], " \t\r\n");
                        setChosenSdPath(win, trimmed);
                        self.len = 0;
                        win.ui_dirty = true;
                        return;
                    }
                    self.len += rc;
                },
            }
        }
    }
};

/// Composites `win.hdmi_fb` and `win.ui` into `full` backbuffer, tracking incremental backdrop state
/// in `buf_state` and returning whether the HDMI display region was damaged.
pub fn compositeToBuffer(win: anytype, full: []u32, buf_state: *BufferState) bool {
    const sc = @max(win.scale, 1);
    const buf_w: usize = @as(usize, win.width) * @as(usize, sc);
    const dw: usize = win.display_width;
    const dh: usize = win.display_height;

    win.ui.updateLayout(win.width, win.height, win.status, win.gpio);
    const disp_x: u32 = @intFromFloat(@max(0.0, @floor(win.ui.display_rect.x)));
    const disp_y: u32 = @intFromFloat(@max(0.0, @floor(win.ui.display_rect.y)));
    const left_phys_cols: usize = @as(usize, disp_x) * @as(usize, sc);
    const top_phys_rows: usize = @as(usize, disp_y) * @as(usize, sc);

    const has_overlay = win.ui.sheet_open or win.ui.hasSnackbar();
    const has_popup = win.ui.sd_manage_open or win.ui.sd_card_menu_open or win.ui.board_menu_open or win.ui.cpu_temp_popup_open;
    const can_reuse_sheet_backdrop = win.ui.sheet_open and !win.ui.hasSnackbar() and !has_popup;
    const hdmi_state: u2 = (@as(u2, @intFromBool(win.status.hdmi_connected)) |
        (@as(u2, @intFromBool(win.status.hdmi_active)) << 1));
    const same_display_layout = std.meta.eql(buf_state.display_rect, win.ui.display_rect) and
        (buf_state.sheet_docked == win.ui.sheet_docked_above);
    const same_sheet_backdrop = can_reuse_sheet_backdrop and
        buf_state.had_sheet and
        buf_state.hdmi_state == hdmi_state and
        same_display_layout and
        std.meta.eql(buf_state.sheet_rect, win.ui.sheet_rect);

    var reuse_dimmed_backdrop = false;
    var damaged_hdmi = false;
    if (win.status.hdmi_connected and win.status.hdmi_active) {
        if (same_sheet_backdrop and buf_state.hdmi_gen == win.hdmi_gen) {
            reuse_dimmed_backdrop = true;
            damaged_hdmi = false;
        } else {
            const need_hdmi_blit = (buf_state.hdmi_gen != win.hdmi_gen) or
                !same_display_layout or
                has_overlay or
                buf_state.had_sheet or
                (buf_state.hdmi_state != hdmi_state);
            if (need_hdmi_blit) {
                board_sheet.BoardUi.blitHdmiToBackbufferAt(full, buf_w, left_phys_cols, top_phys_rows, win.hdmi_fb, dw, dh, sc);
                buf_state.hdmi_gen = win.hdmi_gen;
                damaged_hdmi = true;
            } else {
                damaged_hdmi = false;
            }
        }
    } else {
        buf_state.hdmi_gen = 0;
        if (same_sheet_backdrop) {
            reuse_dimmed_backdrop = true;
            damaged_hdmi = false;
        } else {
            damaged_hdmi = (buf_state.hdmi_state != hdmi_state) or
                !same_display_layout or
                has_overlay or
                buf_state.had_sheet;
        }
    }
    buf_state.had_sheet = has_overlay;
    buf_state.hdmi_state = hdmi_state;
    buf_state.display_rect = win.ui.display_rect;
    buf_state.sheet_docked = win.ui.sheet_docked_above;
    buf_state.sheet_rect = if (can_reuse_sheet_backdrop)
        win.ui.sheet_rect
    else
        .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    win.ui.paintWithBackdrop(full, win.width, win.height, sc, win.status, win.gpio, reuse_dimmed_backdrop);
    return damaged_hdmi;
}

pub fn reallocSingleBackbuffer(win: anytype) !void {
    freeSingleBackbuffer(win);
    const sc = @max(win.scale, 1);
    const count = @as(usize, win.width * sc) * @as(usize, win.height * sc);
    win.backbuffer = try win.gpa.alloc(u32, count);
    @memset(win.backbuffer, 0xFF101418);
    win.buf_state = .{};
    win.cursor_mode = .unknown;
    win.ui_dirty = true;
}

pub fn freeSingleBackbuffer(win: anytype) void {
    if (win.backbuffer.len > 0) {
        win.gpa.free(win.backbuffer);
        win.backbuffer = &.{};
    }
}

pub fn pollAsyncSdCreation(win: anytype, now_ns: u64) void {
    switch (win.ui.pollAsyncSdCreation(now_ns)) {
        .idle => {},
        .in_progress => {
            win.ui_dirty = true;
        },
        .completed_ok => {
            win.sd_image_chosen = true;
            win.ui_dirty = true;
            win.ui.saveSettings(win.status) catch {};
        },
        .completed_err => {
            win.ui_dirty = true;
        },
    }
}

pub fn updateGuestMouseTarget(win: anytype, sx: f64, sy: f64) void {
    const hid = win.hid orelse return;
    const coords = win.ui.windowToHdmiCoords(sx, sy, win.display_width, win.display_height);
    hid.setMouseTarget(coords.x, coords.y);
}

pub fn handlePointerMotion(win: anytype, sx: f64, sy: f64) void {
    const prev_temp = win.ui.cpu_temperature_c;
    const in_ui = win.ui.pointerMotion(@floatCast(sx), @floatCast(sy), win.status, win.gpio);
    if (win.ui.cpu_temperature_c != prev_temp) {
        win.status.cpu_temperature_c = win.ui.cpu_temperature_c;
        win.ui_dirty = true;
    }
    win.updateCursorShape(in_ui);
    if (!in_ui) {
        updateGuestMouseTarget(win, sx, sy);
    }
    win.last_mouse_x = sx;
    win.last_mouse_y = sy;
    if (win.ui.takeHoverDirty()) {
        win.ui_dirty = true;
    }
}

pub fn handlePointerLeave(win: anytype) void {
    win.last_mouse_x = null;
    win.last_mouse_y = null;
    win.cursor_mode = .unknown;
    win.ui.pointerLeave();
    if (win.ui.takeHoverDirty()) {
        win.ui_dirty = true;
    }
}

pub fn handleMouseWheel(win: anytype, wheel: i8) void {
    if (wheel == 0) return;
    const sx: f32 = @floatCast(win.last_mouse_x orelse 0.0);
    const sy: f32 = @floatCast(win.last_mouse_y orelse 0.0);
    if (!win.ui.isPointInUi(sx, sy, win.status)) {
        if (win.hid) |h| {
            h.handleMouseMotion(0, 0, wheel);
        }
    }
}

pub fn handlePointerButton(win: anytype, button_bit: u8, pressed: bool, sx_f64: f64, sy_f64: f64) void {
    const hid = win.hid orelse return;
    win.ui_dirty = true;
    const sx: f32 = @floatCast(sx_f64);
    const sy: f32 = @floatCast(sy_f64);

    if (button_bit == (1 << 0)) {
        const prev_sheet = win.ui.sheet_open;
        const action = win.ui.pointerButton(sx, sy, pressed, win.status, win.gpio);
        if (!prev_sheet and win.ui.sheet_open and !win.ui.sheet_docked_above) {
            hid.releaseAllKeys();
        }
        const over_ui = win.ui.isPointInUi(sx, sy, win.status);
        win.updateCursorShape(over_ui);
        switch (action) {
            .start_drag => {
                win.startWindowDrag();
                return;
            },
            .toggle_maximize => {
                win.toggleMaximized();
                return;
            },
            .toggle_hdmi => {
                win.status.hdmi_connected = !win.status.hdmi_connected;
                if (!win.status.hdmi_connected) {
                    win.status.hdmi_active = false;
                }
                win.gpio.setExternalPin(46, !win.status.hdmi_connected);
                win.ui.saveSettings(win.status) catch {};
                return;
            },
            .toggle_audio => {
                win.status.audio_connected = !win.status.audio_connected;
                win.ui.saveSettings(win.status) catch {};
                return;
            },
            .toggle_power => {
                win.status.power_connected = !win.status.power_connected;
                if (win.status.power_connected) {
                    win.power_reconnected = true;
                } else {
                    win.status.hdmi_active = false;
                    win.gpio.resetSocState();
                }
                return;
            },
            .toggle_sd => {
                // A card can't go in without an image
                if (!win.status.sd_connected and !win.ui.hasActiveSdCard()) return;
                win.status.sd_connected = !win.status.sd_connected;
                if (win.status.sd_connected) {
                    win.sd_reconnected = true;
                } else {
                    win.sd_disconnected = true;
                }
                win.ui.saveSettings(win.status) catch {};
                return;
            },
            .select_sd_image => {
                win.openSdImagePicker();
                return;
            },
            .select_sd_card => {
                if (win.ui.activeSdCard() == null) {
                    win.status.sd_connected = false;
                    win.sd_disconnected = true;
                } else {
                    win.sd_image_chosen = true;
                }
                win.ui.saveSettings(win.status) catch {};
                return;
            },
            .toggle_usb_hub => {
                win.status.usb_hub_connected = !win.status.usb_hub_connected;
                hid.hub_connected = win.status.usb_hub_connected;
                win.ui.saveSettings(win.status) catch {};
                return;
            },
            .toggle_usb_keyboard => {
                win.status.usb_keyboard_connected = !win.status.usb_keyboard_connected;
                hid.keyboard_connected = win.status.usb_keyboard_connected;
                win.ui.saveSettings(win.status) catch {};
                return;
            },
            .toggle_usb_mouse => {
                win.status.usb_mouse_connected = !win.status.usb_mouse_connected;
                hid.mouse_connected = win.status.usb_mouse_connected;
                win.ui.saveSettings(win.status) catch {};
                return;
            },
            .toggle_ethernet => {
                win.status.ethernet_connected = !win.status.ethernet_connected;
                hid.ethernet_connected = win.status.ethernet_connected;
                win.ui.saveSettings(win.status) catch {};
                return;
            },
            .toggle_gpio => {
                win.status.gpio_connected = !win.status.gpio_connected;
                if (!win.status.gpio_connected) {
                    win.gpio.clearHeaderExternalPins();
                }
                win.ui.saveSettings(win.status) catch {};
                return;
            },
            .select_board => {
                win.setBoardModel(win.ui.selected_board_model);
                return;
            },
            .toggle_dhcp => {
                win.status.dhcp_enabled = !win.status.dhcp_enabled;
                hid.net.dhcp_enabled = win.status.dhcp_enabled;
                win.ui.saveSettings(win.status) catch {};
                return;
            },
            .close => {
                win.closed = true;
                return;
            },
            .consumed => {
                win.status.serial_u64 = win.ui.parsedSerial();
                win.status.mac_address = win.ui.parsedMac();
                win.status.wifi_mac_address = win.ui.parsedWifiMac();
                win.status.cpu_temperature_c = win.ui.cpu_temperature_c;
                win.ui.saveSettings(win.status) catch {};
                return;
            },
            .none => {},
        }
    } else if (win.ui.isPointInUi(sx, sy, win.status)) {
        return;
    }

    updateGuestMouseTarget(win, sx_f64, sy_f64);
    hid.handleMouseButton(button_bit, pressed);
}

pub fn applyBoardModel(win: anytype, bm: board_sheet.BoardModel) void {
    win.status.board_model = bm;
    win.status.serial_u64 = win.ui.parsedSerial();
    win.status.mac_address = win.ui.parsedMac();
    win.status.wifi_mac_address = win.ui.parsedWifiMac();
    win.ui.title = bm.windowTitle();
    if (!bm.usesExternalUsbHub()) {
        win.status.usb_hub_connected = true;
    }
    if (win.hid) |h| {
        h.setHubKind(bm.hubKind());
        h.hub_connected = win.status.usb_hub_connected;
    }
    win.ui_dirty = true;
    win.ui.saveSettings(win.status) catch {};
}

pub fn isModifierKey(evdev_key: u32) bool {
    return switch (evdev_key) {
        29, 97, 42, 54, 56, 100, 125, 126, 58, 69, 70 => true,
        else => false,
    };
}

pub fn repeatTimeoutMs(win: anytype, now_ns: u64) ?i32 {
    const rep = win.repeat orelse return null;
    if (win.repeat_rate == 0 or !win.ui.sheet_open) return null;
    if (now_ns >= rep.next_ns) return 0;
    const rem_ms = std.math.divCeil(u64, rep.next_ns - now_ns, std.time.ns_per_ms) catch 0;
    return @intCast(@min(rem_ms, @as(u64, std.math.maxInt(i32))));
}

pub fn serviceRepeat(win: anytype, now_ns: u64) void {
    const rep = &(win.repeat orelse return);
    if (win.repeat_rate == 0) {
        win.repeat = null;
        return;
    }
    if (now_ns < rep.next_ns) return;
    const step = std.time.ns_per_s / @as(u64, win.repeat_rate);
    rep.next_ns = if (now_ns - rep.next_ns < step) rep.next_ns + step else now_ns + step;
    if (win.ui.sheet_open) {
        win.dispatchKey(rep.key, true, true);
    }
}

pub fn recordKeyEvent(win: anytype, key: u32, pressed: bool, is_repeat: bool, now_ns: u64) void {
    if (key < 256) {
        if (pressed) win.keys_down.set(key) else win.keys_down.unset(key);
    }
    if (pressed) {
        if (!isModifierKey(key) and win.repeat_rate > 0 and !is_repeat) {
            const delay_ns = @as(u64, win.repeat_delay_ms) * std.time.ns_per_ms;
            win.repeat = .{ .key = key, .next_ns = now_ns + delay_ns };
        }
    } else {
        if (win.repeat) |rep| {
            if (rep.key == key) win.repeat = null;
        }
    }
}

pub fn releaseAllHeldKeys(win: anytype) void {
    win.repeat = null;
    win.keys_down = .empty;
    win.ui.clearModifiers();
    if (win.hid) |h| {
        h.releaseAllKeys();
    }
}

pub fn dispatchKey(win: anytype, key: u32, pressed: bool, is_repeat: bool) void {
    win.ui.updateModifierKey(key, pressed);
    if (win.ui.sheet_open) {
        win.ui_dirty = true;
        if (pressed and win.ui.handleKey(key)) {
            win.status.serial_u64 = win.ui.parsedSerial();
            win.status.mac_address = win.ui.parsedMac();
            win.status.wifi_mac_address = win.ui.parsedWifiMac();
            win.ui.saveSettings(win.status) catch {};
            return;
        }
        // Escape (evdev key 1) closes any open SD popup/menu first, then the board sheet (when overlaying)
        if (key == 1 and pressed and !is_repeat) {
            if (win.ui.sd_manage_open) {
                win.ui.sd_manage_open = false;
                win.ui.sd_create_open = false;
                return;
            }
            if (win.ui.sd_card_menu_open) {
                win.ui.sd_card_menu_open = false;
                return;
            }
            if (win.ui.cpu_temp_popup_open) {
                win.ui.cpu_temp_popup_open = false;
                win.ui.cpu_temp_slider_dragging = false;
                return;
            }
            if (!win.ui.sheet_docked_above) {
                win.ui.sheet_open = false;
                const sx: f32 = @floatCast(win.last_mouse_x orelse 0.0);
                const sy: f32 = @floatCast(win.last_mouse_y orelse 0.0);
                win.updateCursorShape(win.ui.isPointInUi(sx, sy, win.status));
                return;
            }
        }
        if (!win.ui.sheet_docked_above or win.ui.focused_field != .none or win.ui.sd_manage_open or win.ui.sd_card_menu_open or win.ui.cpu_temp_popup_open) {
            return;
        }
    }
    if (win.hid) |hid| {
        hid.handleEvdevKey(key, pressed);
    }
}

test {
    _ = wayland_window;
    _ = macos_window;
    _ = windows_window;
}
