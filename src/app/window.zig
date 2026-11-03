//! FauxPi's desktop window, made and drawn with kete: the HDMI output, and
//! over it the title bar, the display's surround and the Board & GPIO sheet
//! (`BoardUi`), with kete's own window buttons over the title bar's right end.
//! Pointer and keyboard input go to the sheet, or to the guest's USB mouse and
//! keyboard.

const std = @import("std");
const kete = @import("kete");
const host_posix = @import("../host/posix.zig");
const portal = @import("portal.zig");
const UsbHidComposite = @import("../usb/hid.zig").UsbHidComposite;
const VirtualNetwork = @import("../usb/net.zig").VirtualNetwork;
const Gpio = @import("../soc/gpio.zig").Gpio;
const board_sheet = @import("../ui/board_sheet.zig");

pub const Window = struct {
    gpa: std.mem.Allocator,
    environ: std.process.Environ = .empty,
    app: *kete.App,
    kwin: *kete.App.Window,
    root: Root,
    /// Wakes the window to be drawn again (`compositeUi`).
    waker: kete.Waker,

    /// Logical HDMI display size (e.g. 1280 x 720)
    display_width: u32,
    display_height: u32,
    /// Logical window size, as last laid out.
    width: u32,
    height: u32,

    /// 1x simulated HDMI framebuffer (`display_width * display_height`)
    hdmi_fb: []u32,
    hdmi_gen: u64 = 1,
    /// `hdmi_fb` as kete draws it (scaled on the GPU), if it is no bigger
    /// than kete's images can be; or else it is scaled on the CPU.
    hdmi_image: ?kete.gfx.Image = null,

    closed: bool = false,
    ui_dirty: bool = true,
    power_reconnected: bool = false,
    sd_disconnected: bool = false,
    sd_reconnected: bool = false,
    sd_image_chosen: bool = false,

    picker: portal.PortalFilePicker = .{},

    last_mouse_x: ?f64 = null,
    last_mouse_y: ?f64 = null,

    hid: ?*UsbHidComposite = null,
    /// The Wi-Fi network, whose sockets wake event waits as Ethernet's do
    wifi_net: ?*VirtualNetwork = null,
    gpio: *Gpio,
    ui: board_sheet.BoardUi,
    status: board_sheet.SystemStatus = .{},

    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        display_width: u32,
        display_height: u32,
        hid: *UsbHidComposite,
        gpio: *Gpio,
    ) !*Window {
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

        const width = display_width;
        const height = display_height + board_sheet.BoardUi.title_bar_height +
            (if (status.gpio_connected) board_sheet.BoardUi.gpio_panel_height else 0);

        const win = try gpa.create(Window);
        errdefer gpa.destroy(win);

        // The desktop file's ID, so the shell shows the window with FauxPi's name and icon
        const app = try kete.App.init(gpa, io, environ, .{ .app_id = "io.github.fauxpi.Fauxpi" });
        errdefer app.deinit();

        win.* = .{
            .gpa = gpa,
            .environ = environ,
            .app = app,
            .kwin = undefined,
            .root = .{ .win = win },
            .waker = app.waker(),
            .display_width = display_width,
            .display_height = display_height,
            .width = width,
            .height = height,
            .hdmi_fb = hdmi_fb,
            .hid = hid,
            .gpio = gpio,
            .ui = ui,
            .status = status,
        };
        if (display_width <= kete.gfx.Image.max_size and display_height <= kete.gfx.Image.max_size) {
            win.hdmi_image = .init(win.hdmi_fb, display_width, display_height);
            // Each of the guest's pixels a sharp square, as a monitor shows it.
            win.hdmi_image.?.nearest = true;
        }
        win.kwin = try app.openWindow(.{
            .title = win.ui.title,
            .root = .of(&win.root),
            .size = .{ width, height },
            .min_size = .{ 320, board_sheet.BoardUi.title_bar_height + 120 },
            .maximized = win.ui.maximized,
            // The sheet's title bar is the window's, with kete's buttons over it.
            .draw_in_title_bar = true,
            .clear_color = 0xFF101418,
            .on_close_request = .{ .call = .of(win, closeRequested) },
        });
        return win;
    }

    pub fn destroy(self: *Window) void {
        self.picker.close();
        self.ui.saveSettings(self.status) catch {};
        self.app.deinit();
        self.ui.deinit();
        self.gpa.free(self.hdmi_fb);
        self.gpa.destroy(self);
    }

    fn closeRequested(self: *Window, _: *kete.App.Window) void {
        self.closed = true;
    }

    /// Returns the 1x simulated HDMI framebuffer (`display_width * display_height`).
    pub fn displayPixels(self: *Window) []u32 {
        return self.hdmi_fb;
    }

    pub fn notifyHdmiUpdated(self: *Window) void {
        self.hdmi_gen +%= 1;
        if (self.hdmi_gen == 0) self.hdmi_gen = 1;
        if (self.hdmi_image) |*img| img.changed();
    }

    /// Has the window drawn again (by `present`, or the next wait).
    pub fn compositeUi(self: *Window) void {
        self.ui_dirty = false;
        self.waker.wake();
    }

    pub fn present(self: *Window) !void {
        try self.pollEvents();
    }

    pub fn pollEvents(self: *Window) !void {
        try self.step(0);
    }

    pub fn waitEvents(self: *Window, timeout_ms: i32) !void {
        const timeout_us: ?u64 = if (timeout_ms < 0) null else @as(u64, @intCast(timeout_ms)) * 1000;
        return self.waitEventsUs(timeout_us);
    }

    /// Waits for input (or the window to be drawn) for up to `timeout_us`
    /// (or until there is some, if null), less while host sockets, the file
    /// picker or a card being made want looking at.
    pub fn waitEventsUs(self: *Window, timeout_us: ?u64) !void {
        var timeout = timeout_us orelse std.math.maxInt(u64) / 1000;
        if (self.ui_dirty or self.closed) timeout = 0;
        if (self.hid) |h| {
            if (h.hasPendingInterruptIn()) timeout = 0;
            if (h.isEthernetLinkUp() and h.net.hasHostSockets()) timeout = @min(timeout, 2_000);
        }
        if (self.wifi_net) |n| {
            if (n.hasHostSockets()) timeout = @min(timeout, 2_000);
        }
        if (self.picker.fd >= 0) timeout = @min(timeout, 10_000);
        if (self.ui.isCreatingSdCard()) timeout = @min(timeout, 16_000);
        try self.step(timeout * std.time.ns_per_us);
    }

    fn step(self: *Window, timeout_ns: u64) !void {
        if (!try self.app.step(timeout_ns)) self.closed = true;
        self.picker.poll(self);
        self.pollAsyncSdCreation(host_posix.monotonicNs());
    }

    /// The image file picked (in the file chooser) to make an SD card from.
    pub fn setChosenSdPath(self: *Window, path: []const u8) void {
        if (path.len == 0 or path.len > std.fs.max_path_bytes) return;
        const fsize = board_sheet.Qcow2Disk.getFileSizeLinux(path) catch 0;
        self.ui.setPendingSdImageFile(path, fsize);
        self.ui_dirty = true;
    }

    fn pollAsyncSdCreation(self: *Window, now_ns: u64) void {
        switch (self.ui.pollAsyncSdCreation(now_ns)) {
            .idle => {},
            .in_progress, .completed_err => self.ui_dirty = true,
            .completed_ok => {
                self.sd_image_chosen = true;
                self.ui_dirty = true;
                self.ui.saveSettings(self.status) catch {};
            },
        }
    }

    /// The GPIO panel was connected (or disconnected): the window grows
    /// (or shrinks) by its height, so that the display keeps its size,
    /// unless it is maximized.
    fn fitGpioPanel(self: *Window) void {
        if (self.kwin.isMaximized()) return;
        const panel = board_sheet.BoardUi.gpio_panel_height;
        const h = if (self.status.gpio_connected) self.height + panel else self.height -| panel;
        self.kwin.setSize(self.width, @max(h, board_sheet.BoardUi.title_bar_height + 120));
    }

    fn toggleMaximized(self: *Window) void {
        self.ui.maximized = !self.kwin.isMaximized();
        self.kwin.setMaximized(self.ui.maximized);
        self.ui_dirty = true;
    }

    pub fn setBoardModel(self: *Window, bm: board_sheet.BoardModel) void {
        self.status.board_model = bm;
        self.status.serial_u64 = self.ui.parsedSerial();
        self.status.mac_address = self.ui.parsedMac();
        self.status.wifi_mac_address = self.ui.parsedWifiMac();
        self.ui.title = bm.windowTitle();
        if (!bm.usesExternalUsbHub()) {
            self.status.usb_hub_connected = true;
        }
        if (self.hid) |h| {
            h.setHubKind(bm.hubKind());
            h.hub_connected = self.status.usb_hub_connected;
        }
        self.ui_dirty = true;
        self.ui.saveSettings(self.status) catch {};
        self.kwin.setTitle(self.ui.title);
    }

    // --- Input ------------------------------------------------------------------

    fn updateGuestMouseTarget(self: *Window, sx: f64, sy: f64) void {
        const hid = self.hid orelse return;
        const coords = self.ui.windowToHdmiCoords(sx, sy, self.display_width, self.display_height);
        hid.setMouseTarget(coords.x, coords.y);
    }

    fn handlePointerMotion(self: *Window, sx: f64, sy: f64) void {
        const prev_temp = self.ui.cpu_temperature_c;
        const in_ui = self.ui.pointerMotion(@floatCast(sx), @floatCast(sy), self.status, self.gpio);
        if (self.ui.cpu_temperature_c != prev_temp) {
            self.status.cpu_temperature_c = self.ui.cpu_temperature_c;
            self.ui_dirty = true;
        }
        if (!in_ui) {
            self.updateGuestMouseTarget(sx, sy);
        }
        self.last_mouse_x = sx;
        self.last_mouse_y = sy;
        if (self.ui.takeHoverDirty()) {
            self.ui_dirty = true;
        }
    }

    fn handlePointerLeave(self: *Window) void {
        self.last_mouse_x = null;
        self.last_mouse_y = null;
        self.ui.pointerLeave();
        if (self.ui.takeHoverDirty()) {
            self.ui_dirty = true;
        }
    }

    fn handleMouseWheel(self: *Window, wheel: i8) void {
        if (wheel == 0) return;
        const sx: f32 = @floatCast(self.last_mouse_x orelse 0.0);
        const sy: f32 = @floatCast(self.last_mouse_y orelse 0.0);
        if (!self.ui.isPointInUi(sx, sy, self.status)) {
            if (self.hid) |h| {
                h.handleMouseMotion(0, 0, wheel);
            }
        }
    }

    fn handlePointerButton(self: *Window, button_bit: u8, pressed: bool, sx_f64: f64, sy_f64: f64) void {
        const hid = self.hid orelse return;
        self.ui_dirty = true;
        const sx: f32 = @floatCast(sx_f64);
        const sy: f32 = @floatCast(sy_f64);

        if (button_bit == (1 << 0)) {
            const prev_sheet = self.ui.sheet_open;
            const action = self.ui.pointerButton(sx, sy, pressed, self.status, self.gpio);
            if (!prev_sheet and self.ui.sheet_open and !self.ui.sheet_docked_above) {
                hid.releaseAllKeys();
            }
            switch (action) {
                .start_drag => {
                    if (self.kwin.ui.win) |w| w.startMove();
                    return;
                },
                .toggle_maximize => {
                    self.toggleMaximized();
                    return;
                },
                .toggle_hdmi => {
                    self.status.hdmi_connected = !self.status.hdmi_connected;
                    if (!self.status.hdmi_connected) {
                        self.status.hdmi_active = false;
                    }
                    self.gpio.setExternalPin(46, !self.status.hdmi_connected);
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_audio => {
                    self.status.audio_connected = !self.status.audio_connected;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_power => {
                    self.status.power_connected = !self.status.power_connected;
                    if (self.status.power_connected) {
                        self.power_reconnected = true;
                    } else {
                        self.status.hdmi_active = false;
                        self.gpio.resetSocState();
                    }
                    return;
                },
                .toggle_sd => {
                    // A card can't go in without an image
                    if (!self.status.sd_connected and !self.ui.hasActiveSdCard()) return;
                    self.status.sd_connected = !self.status.sd_connected;
                    if (self.status.sd_connected) {
                        self.sd_reconnected = true;
                    } else {
                        self.sd_disconnected = true;
                    }
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .select_sd_image => {
                    self.picker.open(self.environ);
                    return;
                },
                .select_sd_card => {
                    if (self.ui.activeSdCard() == null) {
                        self.status.sd_connected = false;
                        self.sd_disconnected = true;
                    } else {
                        self.sd_image_chosen = true;
                    }
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_usb_hub => {
                    self.status.usb_hub_connected = !self.status.usb_hub_connected;
                    hid.hub_connected = self.status.usb_hub_connected;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_usb_keyboard => {
                    self.status.usb_keyboard_connected = !self.status.usb_keyboard_connected;
                    hid.keyboard_connected = self.status.usb_keyboard_connected;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_usb_mouse => {
                    self.status.usb_mouse_connected = !self.status.usb_mouse_connected;
                    hid.mouse_connected = self.status.usb_mouse_connected;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_ethernet => {
                    self.status.ethernet_connected = !self.status.ethernet_connected;
                    hid.ethernet_connected = self.status.ethernet_connected;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_gpio => {
                    self.status.gpio_connected = !self.status.gpio_connected;
                    if (!self.status.gpio_connected) {
                        self.gpio.clearHeaderExternalPins();
                    }
                    self.fitGpioPanel();
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .select_board => {
                    self.setBoardModel(self.ui.selected_board_model);
                    return;
                },
                .toggle_dhcp => {
                    self.status.dhcp_enabled = !self.status.dhcp_enabled;
                    hid.net.dhcp_enabled = self.status.dhcp_enabled;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .close => {
                    self.closed = true;
                    return;
                },
                .consumed => {
                    self.status.serial_u64 = self.ui.parsedSerial();
                    self.status.mac_address = self.ui.parsedMac();
                    self.status.wifi_mac_address = self.ui.parsedWifiMac();
                    self.status.cpu_temperature_c = self.ui.cpu_temperature_c;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .none => {},
            }
        } else if (self.ui.isPointInUi(sx, sy, self.status)) {
            return;
        }

        self.updateGuestMouseTarget(sx_f64, sy_f64);
        hid.handleMouseButton(button_bit, pressed);
    }

    fn releaseAllHeldKeys(self: *Window) void {
        self.ui.clearModifiers();
        if (self.hid) |h| {
            h.releaseAllKeys();
        }
    }

    fn dispatchKey(self: *Window, key: u32, pressed: bool) void {
        self.ui.updateModifierKey(key, pressed);
        if (self.ui.sheet_open) {
            self.ui_dirty = true;
            if (pressed and self.ui.handleKey(key)) {
                self.status.serial_u64 = self.ui.parsedSerial();
                self.status.mac_address = self.ui.parsedMac();
                self.status.wifi_mac_address = self.ui.parsedWifiMac();
                self.ui.saveSettings(self.status) catch {};
                return;
            }
            // Escape (evdev key 1) closes any open SD popup/menu first, then the board sheet (when overlaying)
            if (key == 1 and pressed) {
                if (self.ui.sd_manage_open) {
                    self.ui.sd_manage_open = false;
                    self.ui.sd_create_open = false;
                    return;
                }
                if (self.ui.sd_card_menu_open) {
                    self.ui.sd_card_menu_open = false;
                    return;
                }
                if (self.ui.cpu_temp_popup_open) {
                    self.ui.cpu_temp_popup_open = false;
                    self.ui.cpu_temp_slider_dragging = false;
                    return;
                }
                if (!self.ui.sheet_docked_above) {
                    self.ui.sheet_open = false;
                    return;
                }
            }
            if (!self.ui.sheet_docked_above or self.ui.focused_field != .none or self.ui.sd_manage_open or self.ui.sd_card_menu_open or self.ui.cpu_temp_popup_open) {
                return;
            }
        }
        if (self.hid) |hid| {
            hid.handleEvdevKey(key, pressed);
        }
    }
};

/// What the window draws: the whole of it, as one widget.
const Root = struct {
    win: *Window,

    pub fn build(self: *const Root, cx: *kete.BuildContext) kete.Widget {
        return cx.make(Surface{ .win = self.win });
    }
};

/// The window's contents: the HDMI output (on the GPU's frame where the
/// renderer draws one, or else on the CPU), and the sheet over it. It takes
/// the keyboard, and the pointer.
const Surface = struct {
    win: *Window,

    pub const State = struct {
        focused: bool = false,
    };

    pub fn layout(self: *const Surface, n: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        const size = c.constrain(.{
            .w = if (c.boundedWidth()) c.max_w else @floatFromInt(self.win.width),
            .h = if (c.boundedHeight()) c.max_h else @floatFromInt(self.win.height),
        });
        self.win.width = @intFromFloat(@max(size.w, 1));
        self.win.height = @intFromFloat(@max(size.h, 1));
        // The keyboard is the window's, for the sheet's fields and the guest.
        const st = n.state(State);
        if (!st.focused) {
            st.focused = true;
            n.ui.focus(n);
        }
        return size;
    }

    pub fn focusable(_: *const Surface, _: *kete.WidgetNode) bool {
        return true;
    }

    pub fn paint(self: *const Surface, _: *kete.WidgetNode, p: *kete.Painter) void {
        const win = self.win;
        win.ui.updateLayout(win.width, win.height, win.status, win.gpio);
        if (win.status.hdmi_connected and win.status.hdmi_active) {
            const dr = win.ui.display_rect;
            const r: kete.Rect = .{ .x = dr.x, .y = dr.y, .w = dr.w, .h = dr.h };
            if (win.hdmi_image) |*img| {
                // HDMI has no transparency: whatever alpha the pixels have,
                // they are over black.
                const c = p.canvas();
                c.fillRect(r, .{ .r = 0, .g = 0, .b = 0 });
                c.drawImage(img, r, 1);
            } else {
                p.gpuWith(.{ .bounds = r, .key = win.hdmi_gen, .fills = true }, win, drawHdmi);
            }
        }
        win.ui.paint(p, win.width, win.height, win.status, win.gpio);
    }

    /// Scales the HDMI framebuffer into the display's rectangle in `area`
    /// (the whole widget's: the bounds only say where it draws), nearest
    /// pixel, so it stays sharp.
    fn drawHdmi(win: *const Window, target: *kete.gfx.software.Image, area: kete.gfx.GpuArea) anyerror!void {
        const box = area.viewport;
        if (box.width == 0 or box.height == 0 or win.width == 0) return;
        const s = @as(f32, @floatFromInt(box.width)) / @as(f32, @floatFromInt(win.width));
        const dr = win.ui.display_rect;
        const vp: kete.gfx.Viewport = .{
            .x = box.x + @as(i32, @intFromFloat(@round(dr.x * s))),
            .y = box.y + @as(i32, @intFromFloat(@round(dr.y * s))),
            .width = @intFromFloat(@max(@round(dr.w * s), 0)),
            .height = @intFromFloat(@max(@round(dr.h * s), 0)),
        };
        if (vp.width == 0 or vp.height == 0) return;
        const full: kete.gfx.Viewport = .{ .width = target.width, .height = target.height };
        const sc = full.intersect(if (area.scissor) |cut| vp.intersect(cut) orelse return else vp) orelse return;
        const dw: usize = win.display_width;
        const dh: usize = win.display_height;
        const stride = target.rowStride();
        for (0..sc.height) |row| {
            const y: usize = @intCast(sc.y + @as(i32, @intCast(row)));
            const local_y = y - @as(usize, @intCast(vp.y));
            const src_row = win.hdmi_fb[(local_y * dh / vp.height) * dw ..][0..dw];
            const dst = target.pixels[y * stride ..];
            for (0..sc.width) |col| {
                const x: usize = @intCast(sc.x + @as(i32, @intCast(col)));
                const local_x = x - @as(usize, @intCast(vp.x));
                dst[x] = src_row[local_x * dw / vp.width] | 0xFF000000;
            }
        }
    }

    pub fn cursor(self: *const Surface, _: *kete.WidgetNode, pos: kete.Point) ?kete.PointerCursor {
        // A cross over the display: the guest draws its own pointer.
        if (!self.win.ui.isPointInUi(pos[0], pos[1], self.win.status)) return .crosshair;
        return switch (self.win.ui.hoverCursor()) {
            .default => .default,
            .pointer => .pointer,
            .text => .text,
        };
    }

    pub fn event(self: *const Surface, n: *kete.WidgetNode, e: kete.Event) bool {
        const win = self.win;
        switch (e) {
            .motion => |pos| win.handlePointerMotion(pos[0], pos[1]),
            .leave => win.handlePointerLeave(),
            .press => |pr| {
                n.ui.focus(n);
                win.last_mouse_x = pr.pos[0];
                win.last_mouse_y = pr.pos[1];
                const bit = buttonBit(pr.button);
                if (bit == 0) return false;
                win.handlePointerButton(bit, true, pr.pos[0], pr.pos[1]);
            },
            .release => |rl| {
                const bit = buttonBit(rl.button);
                if (bit == 0) return false;
                win.handlePointerButton(bit, false, rl.pos[0], rl.pos[1]);
            },
            .scroll => |sc| {
                if (sc.dy == 0) return false;
                win.handleMouseWheel(if (sc.dy < 0) 1 else -1);
            },
            .key => |k| {
                const code = kete.window.evdev.codeOf(k.key) orelse return false;
                // What the key types is the system's keymap's (kete's).
                win.ui.typed_char = k.char;
                win.ui.typed_char_known = true;
                defer win.ui.typed_char_known = false;
                win.dispatchKey(code, k.pressed);
            },
            .blur => win.releaseAllHeldKeys(),
            else => return false,
        }
        if (win.ui_dirty) win.waker.wake();
        return true;
    }

    fn buttonBit(b: kete.PointerButton) u8 {
        return switch (b) {
            .left => 1 << 0,
            .right => 1 << 1,
            .middle => 1 << 2,
            else => 0,
        };
    }
};
