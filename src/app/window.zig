//! FauxPi's desktop window, made and drawn with kete (`window_ui.zig`): the
//! title bar, the HDMI output with the board sheet over or above it, and the
//! GPIO panel, with kete's own window buttons over the title bar's right end.
//! This keeps what they show (the board's settings and SD cards, and its
//! status), and acts on what they change.

const std = @import("std");
const kete = @import("kete");
const portal = @import("portal.zig");
const UsbHidComposite = @import("../usb/hid.zig").UsbHidComposite;
const VirtualNetwork = @import("../usb/net.zig").VirtualNetwork;
const Gpio = @import("../soc/gpio.zig").Gpio;
const board_state = @import("../ui/board_state.zig");
const window_ui = @import("../ui/window_ui.zig");

pub const Window = struct {
    gpa: std.mem.Allocator,
    environ: std.process.Environ = .empty,
    app: *kete.App,
    kwin: *kete.App.Window,
    root: window_ui.Root,
    /// Wakes the window to be drawn again (`compositeUi`).
    waker: kete.Waker,

    /// Logical HDMI display size (e.g. 1280 x 720)
    display_width: u32,
    display_height: u32,

    /// 1x simulated HDMI framebuffer (`display_width * display_height`)
    hdmi_fb: []u32,

    closed: bool = false,
    ui_dirty: bool = true,
    power_reconnected: bool = false,
    sd_disconnected: bool = false,
    sd_reconnected: bool = false,
    sd_image_chosen: bool = false,

    picker: portal.PortalFilePicker = .{},

    hid: ?*UsbHidComposite = null,
    /// The Wi-Fi network, whose sockets wake event waits as Ethernet's do
    wifi_net: ?*VirtualNetwork = null,
    gpio: *Gpio,
    board: board_state.BoardState,
    status: board_state.SystemStatus = .{},
    shell: window_ui.Shell,

    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        display_width: u32,
        display_height: u32,
        hid: *UsbHidComposite,
        gpio: *Gpio,
    ) !*Window {
        var board = try board_state.BoardState.init(gpa);
        errdefer board.deinit();

        const hdmi_fb = try gpa.alloc(u32, @as(usize, display_width) * @as(usize, display_height));
        errdefer gpa.free(hdmi_fb);
        @memset(hdmi_fb, 0xFF101418);

        var status: board_state.SystemStatus = .{
            .serial_u64 = board.parsedSerial(),
            .mac_address = board.parsedMac(),
            .wifi_mac_address = board.parsedWifiMac(),
            .hdmi_width = @intCast(display_width),
            .hdmi_height = @intCast(display_height),
        };
        board.configureXdgStorage(environ, &status);

        gpio.setExternalPin(46, !status.hdmi_connected);
        hid.setHubKind(status.board_model.hubKind());
        hid.hub_connected = status.usb_hub_connected;
        hid.keyboard_connected = status.usb_keyboard_connected;
        hid.mouse_connected = status.usb_mouse_connected;
        hid.ethernet_connected = status.ethernet_connected;
        hid.net.dhcp_enabled = status.dhcp_enabled;

        const width = display_width;
        const height = display_height + window_ui.title_bar_height +
            (if (status.gpio_connected) window_ui.gpio_panel_height else 0);

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
            .root = .{ .shell = &win.shell },
            .waker = app.waker(),
            .display_width = display_width,
            .display_height = display_height,
            .hdmi_fb = hdmi_fb,
            .hid = hid,
            .gpio = gpio,
            .board = board,
            .status = status,
            .shell = undefined,
        };
        win.shell = try .init(&win.board, &win.status, gpio, .{ .width = display_width, .height = display_height, .fb = hdmi_fb });
        win.shell.hid = hid;
        if (display_width <= kete.gfx.Image.max_size and display_height <= kete.gfx.Image.max_size) {
            win.shell.hdmi.image = .init(win.hdmi_fb, display_width, display_height);
            // Each of the guest's pixels a sharp square, as a monitor shows it.
            win.shell.hdmi.image.?.nearest = true;
        }
        win.kwin = try app.openWindow(.{
            .title = status.board_model.windowTitle(),
            .root = .of(&win.root),
            .size = .{ width, height },
            .min_size = .{ 320, window_ui.title_bar_height + 120 },
            // The title bar is the window's, with kete's buttons over it.
            .draw_in_title_bar = true,
            .clear_color = 0xFF101418,
            .on_close_request = .{ .call = .of(win, closeRequested) },
        });
        return win;
    }

    pub fn destroy(self: *Window) void {
        self.picker.close();
        self.board.saveSettings(self.status) catch {};
        self.app.deinit();
        self.board.deinit();
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
        const hdmi = &self.shell.hdmi;
        hdmi.gen +%= 1;
        if (hdmi.gen == 0) hdmi.gen = 1;
        if (hdmi.image) |*img| img.changed();
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
        if (self.board.isCreatingSdCard()) timeout = @min(timeout, 16_000);
        try self.step(timeout * std.time.ns_per_us);
    }

    fn step(self: *Window, timeout_ns: u64) !void {
        if (!try self.app.step(timeout_ns)) self.closed = true;
        self.picker.poll(self);
        self.pollAsyncSdCreation();
        self.takeEvents();
    }

    /// Acts on what the window's widgets changed.
    fn takeEvents(self: *Window) void {
        const ev = self.shell.events;
        self.shell.events = .{};
        if (ev.power_on) self.power_reconnected = true;
        if (ev.sd_in) self.sd_reconnected = true;
        if (ev.sd_out) self.sd_disconnected = true;
        if (ev.sd_chosen) self.sd_image_chosen = true;
        if (ev.pick_image) self.picker.open(self.environ);
        if (ev.gpio_toggled) self.fitGpioPanel();
        if (ev.board_changed) self.kwin.setTitle(self.status.board_model.windowTitle());
        if (ev.save) self.board.saveSettings(self.status) catch {};
    }

    /// The image file picked (in the file chooser) to make an SD card from.
    pub fn setChosenSdPath(self: *Window, path: []const u8) void {
        if (path.len == 0 or path.len > std.fs.max_path_bytes) return;
        const fsize = board_state.Qcow2Disk.getFileSizeLinux(path) catch 0;
        self.board.setPendingSdImageFile(path, fsize);
        self.compositeUi();
    }

    fn pollAsyncSdCreation(self: *Window) void {
        switch (self.board.pollAsyncSdCreation()) {
            .idle => {},
            // The progress shown moves on.
            .in_progress, .completed_err => self.compositeUi(),
            .completed_ok => {
                self.sd_image_chosen = true;
                self.compositeUi();
                self.board.saveSettings(self.status) catch {};
            },
        }
    }

    /// The GPIO panel was connected (or disconnected): the window grows
    /// (or shrinks) by its height, so that the display keeps its size,
    /// unless it is maximized.
    fn fitGpioPanel(self: *Window) void {
        if (self.kwin.isMaximized()) return;
        const panel = window_ui.gpio_panel_height;
        const h = if (self.status.gpio_connected) self.shell.height + panel else self.shell.height -| panel;
        self.kwin.setSize(self.shell.width, @max(h, window_ui.title_bar_height + 120));
    }

    /// Makes the board a `bm` (from the command line), keeping its identity.
    pub fn setBoardModel(self: *Window, bm: board_state.BoardModel) void {
        self.shell.setBoardModel(bm);
        self.takeEvents();
        self.compositeUi();
    }

    /// Whether the board is drawn now (so its LEDs show).
    pub fn boardShown(self: *const Window) bool {
        return self.shell.sheet_open or self.shell.sheet_docked;
    }
};
