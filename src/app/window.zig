//! The desktop window's state and input routing: what the window (`KeteWindow`)
//! does with the pointer and keyboard, for the Board & GPIO sheet and the guest.

const std = @import("std");
const UsbHidComposite = @import("../usb/hid.zig").UsbHidComposite;
const Gpio = @import("../soc/gpio.zig").Gpio;
const board_sheet = @import("../ui/board_sheet.zig");

pub const kete_window = @import("kete_window.zig");

/// The desktop window, made with kete.
pub const Window = kete_window.KeteWindow;

pub const KeyRepeat = struct {
    key: u32,
    next_ns: u64,
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
                win.fitGpioPanel();
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
    _ = kete_window;
}
