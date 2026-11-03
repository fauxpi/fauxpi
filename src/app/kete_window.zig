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
const window = @import("window.zig");

pub const KeteWindow = struct {
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
    /// Kept for the main loop, which redraws when they differ: kete follows
    /// the output's scale itself.
    scale: u32 = 1,
    pending_scale: u32 = 1,

    /// 1x simulated HDMI framebuffer (`display_width * display_height`)
    hdmi_fb: []u32,
    hdmi_gen: u64 = 1,

    closed: bool = false,
    ui_dirty: bool = true,
    power_reconnected: bool = false,
    sd_disconnected: bool = false,
    sd_reconnected: bool = false,
    sd_image_chosen: bool = false,
    chosen_sd_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    chosen_sd_path_len: usize = 0,

    picker: portal.PortalFilePicker = .{},

    last_mouse_x: ?f64 = null,
    last_mouse_y: ?f64 = null,

    /// Kete repeats held keys itself (as presses), so these stay off.
    repeat_rate: u32 = 0,
    repeat_delay_ms: u32 = 0,
    repeat: ?window.KeyRepeat = null,
    keys_down: std.StaticBitSet(256) = .empty,

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
    ) !*KeteWindow {
        var common = try window.initCommonResources(gpa, environ, display_width, display_height, hid, gpio);
        errdefer common.deinit(gpa);

        const win = try gpa.create(KeteWindow);
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
            .width = common.width,
            .height = common.height,
            .hdmi_fb = common.hdmi_fb,
            .hid = hid,
            .gpio = gpio,
            .ui = common.ui,
            .status = common.status,
        };
        win.kwin = try app.openWindow(.{
            .title = win.ui.title,
            .root = .of(&win.root),
            .size = .{ common.width, common.height },
            .min_size = .{ 320, board_sheet.BoardUi.title_bar_height + 120 },
            .maximized = win.ui.maximized,
            // The sheet's title bar is the window's, with kete's buttons over it.
            .draw_in_title_bar = true,
            .clear_color = 0xFF101418,
            .on_close_request = .{ .call = .of(win, closeRequested) },
        });
        return win;
    }

    pub fn destroy(self: *KeteWindow) void {
        self.picker.close();
        self.ui.saveSettings(self.status) catch {};
        self.app.deinit();
        self.ui.deinit();
        self.gpa.free(self.hdmi_fb);
        self.gpa.destroy(self);
    }

    fn closeRequested(self: *KeteWindow, _: *kete.App.Window) void {
        self.closed = true;
    }

    pub fn chosenSdPath(self: *const KeteWindow) []const u8 {
        return window.chosenSdPath(self);
    }

    pub fn openSdImagePicker(self: *KeteWindow) void {
        self.picker.open(self.environ);
    }

    /// Returns the 1x simulated HDMI framebuffer (`display_width * display_height`).
    pub fn displayPixels(self: *KeteWindow) []u32 {
        return self.hdmi_fb;
    }

    pub fn notifyHdmiUpdated(self: *KeteWindow) void {
        window.notifyHdmiUpdated(self);
    }

    /// Has the window drawn again (by `present`, or the next wait).
    pub fn compositeUi(self: *KeteWindow) void {
        self.ui_dirty = false;
        self.waker.wake();
    }

    pub fn present(self: *KeteWindow) !void {
        try self.pollEvents();
    }

    pub fn pollEvents(self: *KeteWindow) !void {
        try self.step(0);
    }

    pub fn waitEvents(self: *KeteWindow, timeout_ms: i32) !void {
        const timeout_us: ?u64 = if (timeout_ms < 0) null else @as(u64, @intCast(timeout_ms)) * 1000;
        return self.waitEventsUs(timeout_us);
    }

    /// Waits for input (or the window to be drawn) for up to `timeout_us`
    /// (or until there is some, if null), less while host sockets, the file
    /// picker or a card being made want looking at.
    pub fn waitEventsUs(self: *KeteWindow, timeout_us: ?u64) !void {
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

    fn step(self: *KeteWindow, timeout_ns: u64) !void {
        if (!try self.app.step(timeout_ns)) self.closed = true;
        self.picker.poll(self);
        window.pollAsyncSdCreation(self, host_posix.monotonicNs());
    }

    pub fn startWindowDrag(self: *KeteWindow) void {
        if (self.kwin.ui.win) |w| w.startMove();
    }

    /// The GPIO panel was connected (or disconnected): the window grows
    /// (or shrinks) by its height, so that the display keeps its size,
    /// unless it is maximized.
    pub fn fitGpioPanel(self: *KeteWindow) void {
        if (self.kwin.isMaximized()) return;
        const panel = board_sheet.BoardUi.gpio_panel_height;
        const h = if (self.status.gpio_connected) self.height + panel else self.height -| panel;
        self.kwin.setSize(self.width, @max(h, board_sheet.BoardUi.title_bar_height + 120));
    }

    pub fn toggleMaximized(self: *KeteWindow) void {
        self.ui.maximized = !self.kwin.isMaximized();
        self.kwin.setMaximized(self.ui.maximized);
        self.ui_dirty = true;
    }

    pub fn setBoardModel(self: *KeteWindow, bm: board_sheet.BoardModel) void {
        window.applyBoardModel(self, bm);
        self.kwin.setTitle(self.ui.title);
    }

    /// The pointer's shape is the window widget's (`Surface.cursor`).
    pub fn updateCursorShape(_: *KeteWindow, _: bool) void {}

    pub fn dispatchKey(self: *KeteWindow, key: u32, pressed: bool, is_repeat: bool) void {
        window.dispatchKey(self, key, pressed, is_repeat);
    }

    // The main loop's key repeat is kete's.
    pub fn repeatTimeoutMs(_: *const KeteWindow, _: u64) ?i32 {
        return null;
    }

    pub fn serviceRepeat(_: *KeteWindow, _: u64) void {}
};

/// What the window draws: the whole of it, as one widget.
const Root = struct {
    win: *KeteWindow,

    pub fn build(self: *const Root, cx: *kete.BuildContext) kete.Widget {
        return cx.make(Surface{ .win = self.win });
    }
};

/// The window's contents: the HDMI output (on the GPU's frame where the
/// renderer draws one, or else on the CPU), and the sheet over it. It takes
/// the keyboard, and the pointer.
const Surface = struct {
    win: *KeteWindow,

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
            p.gpuWith(.{ .bounds = .{ .x = dr.x, .y = dr.y, .w = dr.w, .h = dr.h }, .key = win.hdmi_gen, .fills = true }, win, drawHdmi);
        }
        win.ui.paint(p, win.width, win.height, win.status, win.gpio);
    }

    /// Scales the HDMI framebuffer into the display's rectangle in `area`
    /// (the whole widget's: the bounds only say where it draws), nearest
    /// pixel, so it stays sharp.
    fn drawHdmi(win: *const KeteWindow, target: *kete.gfx.software.Image, area: kete.gfx.GpuArea) anyerror!void {
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
            .motion => |pos| window.handlePointerMotion(win, pos[0], pos[1]),
            .leave => window.handlePointerLeave(win),
            .press => |pr| {
                n.ui.focus(n);
                win.last_mouse_x = pr.pos[0];
                win.last_mouse_y = pr.pos[1];
                const bit = buttonBit(pr.button);
                if (bit == 0) return false;
                window.handlePointerButton(win, bit, true, pr.pos[0], pr.pos[1]);
            },
            .release => |rl| {
                const bit = buttonBit(rl.button);
                if (bit == 0) return false;
                window.handlePointerButton(win, bit, false, rl.pos[0], rl.pos[1]);
            },
            .scroll => |sc| {
                if (sc.dy == 0) return false;
                window.handleMouseWheel(win, if (sc.dy < 0) 1 else -1);
            },
            .key => |k| {
                const code = kete.window.evdev.codeOf(k.key) orelse return false;
                // What the key types is the system's keymap's (kete's).
                win.ui.typed_char = k.char;
                win.ui.typed_char_known = true;
                defer win.ui.typed_char_known = false;
                if (code < 256) {
                    if (k.pressed) win.keys_down.set(code) else win.keys_down.unset(code);
                }
                win.dispatchKey(code, k.pressed, false);
            },
            .blur => window.releaseAllHeldKeys(win),
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
