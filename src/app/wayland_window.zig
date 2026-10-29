//! Wayland XDG-Shell desktop window backend for `fauxpi`.
//!
//! Renders client-side TitleBar (`44px` logical), drop-down Board & GPIO Status Sheet,
//! HiDPI buffer scale support (`1x`, `2x`, ...), pixel-multiplied HDMI display output,
//! and USB HID keyboard & mouse forwarding.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const host_posix = @import("../host/posix.zig");
const client = @import("../wayland/client.zig");
const protocol = @import("../wayland/protocol.zig");
const portal = @import("../wayland/portal.zig");
const UsbHidComposite = @import("../usb/hid.zig").UsbHidComposite;
const Gpio = @import("../soc/gpio.zig").Gpio;
const board_sheet = @import("../ui/board_sheet.zig");
const window = @import("window.zig");

pub const WaylandWindow = struct {
    gpa: std.mem.Allocator,
    environ: std.process.Environ = .empty,
    display: *client.Display,
    registry: client.Proxy,
    compositor: client.Proxy,
    shm: client.Proxy,
    wm_base: client.Proxy,
    seat: ?client.Proxy = null,
    pointer: ?client.Proxy = null,
    keyboard: ?client.Proxy = null,
    cursor_shape_mgr: ?client.Proxy = null,
    cursor_shape_dev: ?client.Proxy = null,

    surface: client.Proxy,
    cursor_surface: client.Proxy,
    xdg_surface: client.Proxy,
    toplevel: client.Proxy,

    /// Logical HDMI display size (e.g. 1280 x 720)
    display_width: u32,
    display_height: u32,
    /// Logical window size (`display_width` x `display_height + 44` when unmaximized, or compositor-configured size when maximized)
    width: u32,
    height: u32,
    configured_width: u32 = 0,
    configured_height: u32 = 0,
    pending_toplevel_width: u32 = 0,
    pending_toplevel_height: u32 = 0,
    pending_maximized: bool = false,
    has_pending_toplevel_configure: bool = false,
    /// HiDPI buffer scale factor (`1` on standard displays, `2` on 2x2 scaled outputs)
    scale: u32 = 1,
    pending_scale: u32 = 1,

    /// 1x simulated HDMI framebuffer (`display_width * display_height`)
    hdmi_fb: []u32,

    shm_fd: linux.fd_t = -1,
    shm_map: []align(std.heap.page_size_min) u8 = &.{},
    buffers: [2]client.Proxy = undefined,
    cursor_buffers: [2]client.Proxy = undefined,
    has_buffers: bool = false,
    cur_buf: u1 = 0,
    hdmi_gen: u64 = 1,
    buf_states: [2]window.BufferState = .{ .{}, .{} },
    last_composite_damaged_hdmi: bool = true,

    configured: bool = false,
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
    last_button_serial: u32 = 0,
    pointer_enter_serial: u32 = 0,
    cursor_mode: window.CursorMode = .unknown,

    /// Keyboard repeat configuration (`wl_keyboard.repeat_info`, 0 disables repeat) and repeat state.
    repeat_rate: u32 = 25,
    repeat_delay_ms: u32 = 600,
    repeat: ?window.KeyRepeat = null,
    keys_down: std.StaticBitSet(256) = .empty,

    hid: ?*UsbHidComposite = null,
    gpio: *Gpio,
    ui: board_sheet.BoardUi,
    status: board_sheet.SystemStatus = .{},

    pub fn create(
        gpa: std.mem.Allocator,
        environ: std.process.Environ,
        display_width: u32,
        display_height: u32,
        hid: *UsbHidComposite,
        gpio: *Gpio,
    ) !*WaylandWindow {
        var common = try window.initCommonResources(gpa, environ, display_width, display_height, hid, gpio);
        errdefer common.deinit(gpa);

        const display = try client.Display.connectEnviron(gpa, environ);
        errdefer display.disconnect();

        const win = try gpa.create(WaylandWindow);
        errdefer gpa.destroy(win);

        var globals: client.Globals = .{};
        const registry = try globals.fetch(display);

        const compositor = (try globals.bind(registry, protocol.wl_compositor.name, protocol.wl_compositor.version, null)) orelse return error.MissingCompositor;
        const shm = (try globals.bind(registry, protocol.wl_shm.name, protocol.wl_shm.version, null)) orelse return error.MissingShm;
        const wm_base = (try globals.bind(registry, protocol.xdg_wm_base.name, protocol.xdg_wm_base.version, .{ .ptr = win, .handler = wmBaseEvent })) orelse return error.MissingXdgWmBase;

        win.* = .{
            .gpa = gpa,
            .environ = environ,
            .display = display,
            .registry = registry,
            .compositor = compositor,
            .shm = shm,
            .wm_base = wm_base,
            .surface = undefined,
            .cursor_surface = undefined,
            .xdg_surface = undefined,
            .toplevel = undefined,
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

        // Bind all wl_output globals to receive output scale factor events
        for (globals.list[0..globals.len]) |gl| {
            if (std.mem.eql(u8, gl.interface[0..gl.interface_len], protocol.wl_output.name)) {
                const out_proxy = try display.newObject(.{ .ptr = win, .handler = outputEvent });
                var m = try registry.request(protocol.wl_registry.request.bind);
                m.uint(gl.name)
                    .string(protocol.wl_output.name)
                    .uint(@min(protocol.wl_output.version, gl.version))
                    .uint(out_proxy.id)
                    .end();
            }
        }

        win.cursor_shape_mgr = try globals.bind(
            registry,
            protocol.wp_cursor_shape_manager_v1.name,
            protocol.wp_cursor_shape_manager_v1.version,
            null,
        );
        win.seat = try globals.bind(registry, protocol.wl_seat.name, protocol.wl_seat.version, .{ .ptr = win, .handler = seatEvent });

        win.surface = try display.newObject(.{ .ptr = win, .handler = surfaceEvent });
        {
            var m = try compositor.request(protocol.wl_compositor.request.create_surface);
            m.uint(win.surface.id).end();
        }
        win.cursor_surface = try display.newObject(null);
        {
            var m = try compositor.request(protocol.wl_compositor.request.create_surface);
            m.uint(win.cursor_surface.id).end();
        }

        win.xdg_surface = try display.newObject(.{ .ptr = win, .handler = xdgSurfaceEvent });
        {
            var m = try wm_base.request(protocol.xdg_wm_base.request.get_xdg_surface);
            m.uint(win.xdg_surface.id).uint(win.surface.id).end();
        }

        win.toplevel = try display.newObject(.{ .ptr = win, .handler = toplevelEvent });
        {
            var m = try win.xdg_surface.request(protocol.xdg_surface.request.get_toplevel);
            m.uint(win.toplevel.id).end();
        }
        {
            var m = try win.toplevel.request(protocol.xdg_toplevel.request.set_title);
            m.string(win.ui.title).end();
        }
        {
            var m = try win.toplevel.request(protocol.xdg_toplevel.request.set_app_id);
            m.string("fauxpi").end();
        }
        {
            var m = try win.surface.request(protocol.wl_surface.request.commit);
            m.end();
        }

        // Wait for initial xdg_surface.configure and wl_output.scale / preferred_buffer_scale
        try display.roundtrip();
        if (!win.configured) {
            try display.roundtrip();
        }

        win.scale = @max(win.pending_scale, 1);
        if (win.ui.maximized and win.configured_width > 0 and win.configured_height > 0) {
            win.width = win.configured_width;
            win.height = win.configured_height;
        }
        try win.initShmBuffers();

        return win;
    }

    pub fn destroy(self: *WaylandWindow) void {
        self.picker.close();
        self.ui.saveSettings(self.status) catch {};
        self.ui.deinit();
        self.gpa.free(self.hdmi_fb);
        self.freeShmBuffers();
        self.display.disconnect();
        self.gpa.destroy(self);
    }

    pub fn chosenSdPath(self: *const WaylandWindow) []const u8 {
        return window.chosenSdPath(self);
    }

    pub fn openSdImagePicker(self: *WaylandWindow) void {
        self.picker.open(self.environ);
    }

    fn freeShmBuffers(self: *WaylandWindow) void {
        if (self.has_buffers) {
            for (0..2) |i| {
                if (self.buffers[i].request(protocol.wl_buffer.request.destroy)) |req| {
                    var m = req;
                    m.end();
                } else |_| {}
                self.display.forget(self.buffers[i].id);
                if (self.cursor_buffers[i].request(protocol.wl_buffer.request.destroy)) |req| {
                    var m = req;
                    m.end();
                } else |_| {}
                self.display.forget(self.cursor_buffers[i].id);
            }
            self.has_buffers = false;
        }
        if (self.shm_map.len > 0) {
            _ = linux.munmap(self.shm_map.ptr, self.shm_map.len);
            self.shm_map = &.{};
        }
        if (self.shm_fd >= 0) {
            _ = linux.close(self.shm_fd);
            self.shm_fd = -1;
        }
    }

    fn initShmBuffers(self: *WaylandWindow) !void {
        self.freeShmBuffers();

        const sc = @max(self.scale, 1);
        const buf_w = self.width * sc;
        const buf_h = self.height * sc;
        const stride = buf_w * 4;
        const single_size = @as(usize, stride) * @as(usize, buf_h);

        const cur_dim = window.cursor_logical_dim * sc;
        const cur_stride = cur_dim * 4;
        const cur_size = @as(usize, cur_stride) * @as(usize, cur_dim);
        const pool_size = single_size * 2 + cur_size * 2;

        const fd_rc = linux.memfd_create("fauxpi-hdmi-shm", linux.MFD.CLOEXEC);
        if (linux.errno(fd_rc) != .SUCCESS) return error.SystemError;
        self.shm_fd = @intCast(fd_rc);

        if (linux.errno(linux.ftruncate(self.shm_fd, @intCast(pool_size))) != .SUCCESS) return error.SystemError;

        const map_rc = linux.mmap(null, pool_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, self.shm_fd, 0);
        if (linux.errno(map_rc) != .SUCCESS) return error.SystemError;
        self.shm_map = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(map_rc))[0..pool_size];

        const dup_rc = linux.dup(self.shm_fd);
        if (linux.errno(dup_rc) != .SUCCESS) return error.SystemError;
        const send_fd: linux.fd_t = @intCast(dup_rc);

        const pool = try self.display.newObject(null);
        {
            var m = try self.shm.request(protocol.wl_shm.request.create_pool);
            m.uint(pool.id).fd(send_fd).int(@intCast(pool_size)).end();
        }

        for (0..2) |i| {
            self.buffers[i] = try self.display.newObject(null);
            var m = try pool.request(protocol.wl_shm_pool.request.create_buffer);
            m.uint(self.buffers[i].id)
                .int(@intCast(i * single_size))
                .int(@intCast(buf_w))
                .int(@intCast(buf_h))
                .int(@intCast(stride))
                .uint(protocol.wl_shm.format.xrgb8888)
                .end();
        }

        for (0..2) |i| {
            const byte_off = single_size * 2 + i * cur_size;
            const cur_px: []u32 = @alignCast(std.mem.bytesAsSlice(u32, self.shm_map[byte_off .. byte_off + cur_size]));
            if (i == 0) {
                window.paintFaintCrosshairCursor(cur_px, sc);
            } else {
                window.paintArrowCursor(cur_px, sc);
            }
            self.cursor_buffers[i] = try self.display.newObject(null);
            var m = try pool.request(protocol.wl_shm_pool.request.create_buffer);
            m.uint(self.cursor_buffers[i].id)
                .int(@intCast(byte_off))
                .int(@intCast(cur_dim))
                .int(@intCast(cur_dim))
                .int(@intCast(cur_stride))
                .uint(protocol.wl_shm.format.argb8888)
                .end();
        }

        self.has_buffers = true;
        self.cur_buf = 0;
        self.buf_states = .{ .{}, .{} };
        self.last_composite_damaged_hdmi = true;
        self.cursor_mode = .unknown;
        self.ui_dirty = true;

        {
            var m = try pool.request(protocol.wl_shm_pool.request.destroy);
            m.end();
        }
        self.display.forget(pool.id);
    }

    /// Returns the full physical window backbuffer (`(width * scale) * (height * scale)`).
    pub fn backbufferPixels(self: *WaylandWindow) []u32 {
        const sc = @max(self.scale, 1);
        const count = @as(usize, self.width * sc) * @as(usize, self.height * sc);
        const byte_off = @as(usize, self.cur_buf) * count * 4;
        return @alignCast(std.mem.bytesAsSlice(u32, self.shm_map[byte_off .. byte_off + count * 4]));
    }

    /// Returns the 1x simulated HDMI framebuffer (`display_width * display_height`).
    pub fn displayPixels(self: *WaylandWindow) []u32 {
        return self.hdmi_fb;
    }

    pub fn notifyHdmiUpdated(self: *WaylandWindow) void {
        window.notifyHdmiUpdated(self);
    }

    /// Blits the 1x `hdmi_fb` (`display_width * display_height`) into the physical
    /// backbuffer (pixel-doubling `scale x scale` when `scale > 1`) and renders
    /// `BoardUi` at native HiDPI resolution (`scale`).
    pub fn compositeUi(self: *WaylandWindow) void {
        self.ui_dirty = false;
        const default_w = self.display_width;
        const default_h = window.defaultWindowHeight(self.display_height, self.status);
        const desired_w = if (self.ui.maximized and self.configured_width > 0) self.configured_width else default_w;
        const desired_h = if (self.ui.maximized and self.configured_height > 0) self.configured_height else default_h;
        if ((self.pending_scale != self.scale and self.pending_scale >= 1) or self.width != desired_w or self.height != desired_h) {
            if (self.pending_scale >= 1) self.scale = self.pending_scale;
            self.width = desired_w;
            self.height = desired_h;
            self.initShmBuffers() catch {};
            self.ui_dirty = false;
        }

        const full = self.backbufferPixels();
        const b_idx: usize = self.cur_buf;
        self.last_composite_damaged_hdmi = window.compositeToBuffer(self, full, &self.buf_states[b_idx]);
    }

    pub fn present(self: *WaylandWindow) !void {
        const sc = @max(self.scale, 1);
        const buf = self.buffers[self.cur_buf];
        self.cur_buf ^= 1;

        {
            var m = try self.surface.request(protocol.wl_surface.request.set_buffer_scale);
            m.int(@intCast(sc)).end();
        }
        {
            var m = try self.surface.request(protocol.wl_surface.request.attach);
            m.uint(buf.id).int(0).int(0).end();
        }
        if (self.last_composite_damaged_hdmi) {
            var m = try self.surface.request(protocol.wl_surface.request.damage);
            m.int(0).int(0).int(@intCast(self.width)).int(@intCast(self.height)).end();
        } else {
            {
                var m = try self.surface.request(protocol.wl_surface.request.damage);
                m.int(0).int(0).int(@intCast(self.width)).int(@intCast(board_sheet.BoardUi.title_bar_height)).end();
            }
            if (self.ui.sheet_open) {
                const sr = self.ui.sheet_rect;
                const sx: i32 = @intFromFloat(@max(0.0, @floor(sr.x)));
                const sy: i32 = @intFromFloat(@max(0.0, @floor(sr.y)));
                const sw: i32 = @intFromFloat(@ceil(sr.w + 2.0));
                const sh: i32 = @intFromFloat(@ceil(sr.h + 2.0));
                var m = try self.surface.request(protocol.wl_surface.request.damage);
                m.int(sx).int(sy).int(sw).int(sh).end();
            }
            if (self.status.gpio_connected and self.height > board_sheet.BoardUi.gpio_panel_height) {
                const gpio_y = self.height - board_sheet.BoardUi.gpio_panel_height;
                var m = try self.surface.request(protocol.wl_surface.request.damage);
                m.int(0).int(@intCast(gpio_y)).int(@intCast(self.width)).int(@intCast(board_sheet.BoardUi.gpio_panel_height)).end();
            }
        }
        {
            var m = try self.surface.request(protocol.wl_surface.request.commit);
            m.end();
        }
        try self.pollEvents();
    }

    pub fn pollEvents(self: *WaylandWindow) !void {
        try self.display.pollAndDispatch();
        self.picker.poll(self);
        const now_ns = host_posix.monotonicNs();
        window.pollAsyncSdCreation(self, now_ns);
        self.serviceRepeat(now_ns);
    }

    pub fn waitEvents(self: *WaylandWindow, timeout_ms: i32) !void {
        const timeout_us: ?u64 = if (timeout_ms < 0) null else @as(u64, @intCast(timeout_ms)) * 1000;
        return self.waitEventsUs(timeout_us);
    }

    pub fn waitEventsUs(self: *WaylandWindow, timeout_us: ?u64) !void {
        const was_dirty = self.ui_dirty;
        const had_pending_in = if (self.hid) |h| h.hasPendingInterruptIn() else false;
        try self.display.pollAndDispatch();
        self.picker.poll(self);
        const now_ns = host_posix.monotonicNs();
        window.pollAsyncSdCreation(self, now_ns);
        self.serviceRepeat(now_ns);
        if (self.closed or (!was_dirty and self.ui_dirty)) return;
        if (timeout_us != null) {
            if (self.hid) |h| {
                if (!had_pending_in and h.hasPendingInterruptIn()) return;
            }
        }

        var fds: [2 + 32]linux.pollfd = undefined;
        var nfds: usize = 1;
        fds[0] = .{ .fd = self.display.conn.fd, .events = linux.POLL.IN, .revents = 0 };
        if (self.picker.fd >= 0) {
            fds[nfds] = .{ .fd = self.picker.fd, .events = linux.POLL.IN, .revents = 0 };
            nfds += 1;
        }
        if (self.hid) |h| {
            if (h.isEthernetLinkUp()) {
                nfds += h.net.fillPollFds(fds[nfds..]);
            }
        }

        var eff_timeout_ms: i32 = if (timeout_us) |us|
            @intCast(@min((us + 999) / 1000, @as(u64, std.math.maxInt(i32))))
        else
            -1;
        if (self.ui.isCreatingSdCard()) {
            if (eff_timeout_ms < 0 or eff_timeout_ms > 16) {
                eff_timeout_ms = 16;
            }
        }
        if (self.repeatTimeoutMs(now_ns)) |rep_ms| {
            if (eff_timeout_ms < 0 or rep_ms < eff_timeout_ms) {
                eff_timeout_ms = rep_ms;
            }
        }
        const rc = linux.poll(&fds, @intCast(nfds), eff_timeout_ms);
        if (linux.errno(rc) == .SUCCESS and rc > 0) {
            try self.display.pollAndDispatch();
            self.picker.poll(self);
        }
        const after_ns = host_posix.monotonicNs();
        window.pollAsyncSdCreation(self, after_ns);
        self.serviceRepeat(after_ns);
    }

    pub fn repeatTimeoutMs(self: *const WaylandWindow, now_ns: u64) ?i32 {
        return window.repeatTimeoutMs(self, now_ns);
    }

    pub fn serviceRepeat(self: *WaylandWindow, now_ns: u64) void {
        window.serviceRepeat(self, now_ns);
    }

    pub fn startWindowDrag(self: *WaylandWindow) void {
        const seat = self.seat orelse return;
        var m = self.toplevel.request(protocol.xdg_toplevel.request.move) catch return;
        m.uint(seat.id).uint(self.last_button_serial).end();
    }

    pub fn setBoardModel(self: *WaylandWindow, bm: board_sheet.BoardModel) void {
        window.applyBoardModel(self, bm);
        var m = self.toplevel.request(protocol.xdg_toplevel.request.set_title) catch return;
        m.string(self.ui.title).end();
    }

    pub fn toggleMaximized(self: *WaylandWindow) void {
        self.ui.maximized = !self.ui.maximized;
        if (!self.ui.maximized) {
            self.configured_width = 0;
            self.configured_height = 0;
        }
        self.ui_dirty = true;
        const op: u16 = if (self.ui.maximized)
            protocol.xdg_toplevel.request.set_maximized
        else
            protocol.xdg_toplevel.request.unset_maximized;
        var m = self.toplevel.request(op) catch return;
        m.end();
    }

    fn surfaceEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == protocol.wl_surface.event.preferred_buffer_scale) {
            const factor = r.int() catch return;
            if (factor >= 1 and factor <= 4) {
                const new_scale: u32 = @intCast(factor);
                if (self.pending_scale != new_scale) {
                    self.pending_scale = new_scale;
                    self.ui_dirty = true;
                }
            }
        }
    }

    fn outputEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == protocol.wl_output.event.scale) {
            const factor = r.int() catch return;
            if (factor >= 1 and factor <= 4) {
                const new_scale: u32 = @intCast(factor);
                if (self.pending_scale != new_scale) {
                    self.pending_scale = new_scale;
                    self.ui_dirty = true;
                }
            }
        }
    }

    fn wmBaseEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == protocol.xdg_wm_base.event.ping) {
            const serial = r.uint() catch return;
            var m = self.wm_base.request(protocol.xdg_wm_base.request.pong) catch return;
            m.uint(serial).end();
        }
    }

    fn xdgSurfaceEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == protocol.xdg_surface.event.configure) {
            const serial = r.uint() catch return;
            var m = self.xdg_surface.request(protocol.xdg_surface.request.ack_configure) catch return;
            m.uint(serial).end();
            if (self.has_pending_toplevel_configure) {
                self.has_pending_toplevel_configure = false;
                self.ui.maximized = self.pending_maximized;
                if (self.pending_maximized and self.pending_toplevel_width > 0 and self.pending_toplevel_height > 0) {
                    self.configured_width = self.pending_toplevel_width;
                    self.configured_height = self.pending_toplevel_height;
                } else if (!self.pending_maximized) {
                    self.configured_width = 0;
                    self.configured_height = 0;
                }
            }
            self.configured = true;
            self.ui_dirty = true;
        }
    }

    fn toplevelEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == protocol.xdg_toplevel.event.configure) {
            const w = r.int() catch return;
            const h = r.int() catch return;
            const states = r.array() catch return;
            var is_max = false;
            var i: usize = 0;
            while (i + 4 <= states.len) : (i += 4) {
                const st = std.mem.readInt(u32, states[i..][0..4], .little);
                if (st == protocol.xdg_toplevel.state.maximized or st == protocol.xdg_toplevel.state.fullscreen) {
                    is_max = true;
                }
            }
            self.pending_toplevel_width = if (w > 0) @intCast(w) else 0;
            self.pending_toplevel_height = if (h > 0) @intCast(h) else 0;
            self.pending_maximized = is_max;
            self.has_pending_toplevel_configure = true;
        } else if (opcode == protocol.xdg_toplevel.event.close) {
            self.closed = true;
            self.ui_dirty = true;
        }
    }

    fn seatEvent(ptr: ?*anyopaque, d: *client.Display, _: u32, opcode: u16, r: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == protocol.wl_seat.event.capabilities) {
            const caps = r.uint() catch return;
            const seat = self.seat orelse return;
            if ((caps & protocol.wl_seat.capability.pointer) != 0 and self.pointer == null) {
                if (d.newObject(.{ .ptr = self, .handler = pointerEvent })) |p| {
                    self.pointer = p;
                    if (seat.request(protocol.wl_seat.request.get_pointer)) |req| {
                        var m = req;
                        m.uint(p.id).end();
                    } else |_| {}
                    if (self.cursor_shape_mgr) |mgr| {
                        if (d.newObject(null)) |dev| {
                            self.cursor_shape_dev = dev;
                            if (mgr.request(protocol.wp_cursor_shape_manager_v1.request.get_pointer)) |sreq| {
                                var sm = sreq;
                                sm.uint(dev.id).uint(p.id).end();
                            } else |_| {}
                        } else |_| {}
                    }
                } else |_| {}
            }
            if ((caps & protocol.wl_seat.capability.keyboard) != 0 and self.keyboard == null) {
                if (d.newObject(.{ .ptr = self, .handler = keyboardEvent })) |k| {
                    self.keyboard = k;
                    if (seat.request(protocol.wl_seat.request.get_keyboard)) |req| {
                        var m = req;
                        m.uint(k.id).end();
                    } else |_| {}
                } else |_| {}
            }
        }
    }

    pub fn updateCursorShape(self: *WaylandWindow, over_ui: bool) void {
        const ptr = self.pointer orelse return;
        if (!self.has_buffers) return;
        const target: window.CursorMode = if (over_ui) .ui_arrow else .hdmi_crosshair;
        if (self.cursor_mode == target) return;
        self.cursor_mode = target;

        if (over_ui) {
            if (self.cursor_shape_dev) |dev| {
                if (dev.request(protocol.wp_cursor_shape_device_v1.request.set_shape)) |req| {
                    var m = req;
                    m.uint(self.pointer_enter_serial).uint(protocol.wp_cursor_shape_device_v1.shape.default).end();
                    return;
                } else |_| {}
            }
        }

        const sc = @max(self.scale, 1);
        const buf_idx: usize = if (over_ui) 1 else 0;
        const hot_x: i32 = if (over_ui) 1 else window.crosshair_logical_hot;
        const hot_y: i32 = if (over_ui) 1 else window.crosshair_logical_hot;

        if (self.cursor_surface.request(protocol.wl_surface.request.set_buffer_scale)) |req| {
            var m = req;
            m.int(@intCast(sc)).end();
        } else |_| {}
        if (self.cursor_surface.request(protocol.wl_surface.request.attach)) |req| {
            var m = req;
            m.uint(self.cursor_buffers[buf_idx].id).int(0).int(0).end();
        } else |_| {}
        if (self.cursor_surface.request(protocol.wl_surface.request.damage)) |req| {
            var m = req;
            m.int(0).int(0).int(@intCast(window.cursor_logical_dim)).int(@intCast(window.cursor_logical_dim)).end();
        } else |_| {}
        if (self.cursor_surface.request(protocol.wl_surface.request.commit)) |req| {
            var m = req;
            m.end();
        } else |_| {}
        if (ptr.request(protocol.wl_pointer.request.set_cursor)) |req| {
            var m = req;
            m.uint(self.pointer_enter_serial).uint(self.cursor_surface.id).int(hot_x).int(hot_y).end();
        } else |_| {}
    }

    fn pointerEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));

        switch (opcode) {
            protocol.wl_pointer.event.enter => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return; // surface
                const sx = r.fixed() catch return;
                const sy = r.fixed() catch return;
                self.pointer_enter_serial = serial;
                self.cursor_mode = .unknown;
                window.handlePointerMotion(self, sx, sy);
            },
            protocol.wl_pointer.event.leave => {
                window.handlePointerLeave(self);
            },
            protocol.wl_pointer.event.motion => {
                _ = r.uint() catch return; // time
                const sx = r.fixed() catch return;
                const sy = r.fixed() catch return;
                window.handlePointerMotion(self, sx, sy);
            },
            protocol.wl_pointer.event.button => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return; // time
                const button = r.uint() catch return;
                const state = r.uint() catch return;
                const pressed = (state == protocol.wl_pointer.button_state.pressed);
                self.last_button_serial = serial;

                const sx_f64 = self.last_mouse_x orelse 0.0;
                const sy_f64 = self.last_mouse_y orelse 0.0;
                const bit: u8 = switch (button) {
                    protocol.input.btn_left => 1 << 0,
                    protocol.input.btn_right => 1 << 1,
                    protocol.input.btn_middle => 1 << 2,
                    else => 0,
                };
                if (bit != 0) {
                    window.handlePointerButton(self, bit, pressed, sx_f64, sy_f64);
                } else {
                    self.ui_dirty = true;
                }
            },
            protocol.wl_pointer.event.axis => {
                _ = r.uint() catch return; // time
                const axis = r.uint() catch return;
                const value = r.fixed() catch return;
                if (axis == protocol.wl_pointer.axis.vertical_scroll and value != 0) {
                    const wheel: i8 = if (value < 0) 1 else -1;
                    window.handleMouseWheel(self, wheel);
                }
            },
            else => {},
        }
    }

    pub fn dispatchKey(self: *WaylandWindow, key: u32, pressed: bool, is_repeat: bool) void {
        window.dispatchKey(self, key, pressed, is_repeat);
    }

    fn keyboardEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));

        switch (opcode) {
            protocol.wl_keyboard.event.keymap => {
                const format = r.uint() catch return;
                const fd = r.fd() catch return;
                defer _ = linux.close(fd);
                const size = r.uint() catch return;
                if (format == protocol.wl_keyboard.keymap_format.xkb_v1 and size > 0 and size <= 4 * 1024 * 1024) {
                    const map = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
                    if (linux.errno(map) == .SUCCESS) {
                        defer _ = linux.munmap(@ptrFromInt(map), size);
                        const bytes: [*]const u8 = @ptrFromInt(map);
                        const len = if (bytes[size - 1] == 0) size - 1 else size;
                        self.ui.loadXkbKeymap(bytes[0..len]);
                    }
                }
            },
            protocol.wl_keyboard.event.enter => {
                _ = r.uint() catch return; // serial
                _ = r.uint() catch return; // surface
                const keys = r.array() catch return;
                self.repeat = null;
                self.keys_down = .empty;
                self.ui.clearModifiers();
                var i: usize = 0;
                while (i + 4 <= keys.len) : (i += 4) {
                    const key = std.mem.readInt(u32, keys[i..][0..4], .little);
                    if (key < 256) self.keys_down.set(key);
                    self.ui.updateModifierKey(key, true);
                    if (!self.ui.sheet_open or (self.ui.sheet_docked_above and self.ui.focused_field == .none and !self.ui.sd_manage_open)) {
                        if (self.hid) |hid| {
                            hid.handleEvdevKey(key, true);
                        }
                    }
                }
            },
            protocol.wl_keyboard.event.leave => {
                _ = r.uint() catch return; // serial
                _ = r.uint() catch return; // surface
                window.releaseAllHeldKeys(self);
            },
            protocol.wl_keyboard.event.key => {
                _ = r.uint() catch return; // serial
                _ = r.uint() catch return; // time
                const key = r.uint() catch return;
                const state = r.uint() catch return;
                const pressed = switch (state) {
                    protocol.wl_keyboard.key_state.released => false,
                    protocol.wl_keyboard.key_state.pressed, protocol.wl_keyboard.key_state.repeated => true,
                    else => return,
                };
                const is_repeat = (state == protocol.wl_keyboard.key_state.repeated);
                window.recordKeyEvent(self, key, pressed, is_repeat, host_posix.monotonicNs());
                self.dispatchKey(key, pressed, is_repeat);
            },
            protocol.wl_keyboard.event.modifiers => {
                _ = r.uint() catch return; // serial
                const mods_depressed = r.uint() catch return;
                const mods_latched = r.uint() catch return;
                const mods_locked = r.uint() catch return;
                _ = r.uint() catch return; // group
                self.ui.updateModifiersFromXkb(mods_depressed, mods_latched, mods_locked);
            },
            protocol.wl_keyboard.event.repeat_info => {
                const rate = r.int() catch return;
                const delay = r.int() catch return;
                self.repeat_rate = if (rate > 0) @intCast(rate) else 0;
                self.repeat_delay_ms = if (delay > 0) @intCast(delay) else 0;
                if (self.repeat_rate == 0) self.repeat = null;
            },
            else => {},
        }
    }
};

test "WaylandWindow keyboard repeat_info, serviceRepeat, keymap fd mmap, and leave release" {
    if (builtin.os.tag != .linux) return;
    const testing = std.testing;
    var gpio: Gpio = .{};
    var hid: UsbHidComposite = .{};
    var ui = try board_sheet.BoardUi.init(testing.allocator);
    defer ui.deinit();

    var win: WaylandWindow = .{
        .gpa = testing.allocator,
        .display = undefined,
        .registry = undefined,
        .compositor = undefined,
        .surface = undefined,
        .cursor_surface = undefined,
        .xdg_surface = undefined,
        .toplevel = undefined,
        .wm_base = undefined,
        .shm = undefined,
        .width = 1280,
        .height = 764,
        .display_width = 1280,
        .display_height = 720,
        .hdmi_fb = &.{},
        .gpio = &gpio,
        .hid = &hid,
        .ui = ui,
    };

    var conn: client.Connection = .{ .fd = -1 };

    // 1. Test repeat_info event (rate = 25 Hz -> 40ms step, delay = 200ms)
    var repeat_payload: [8]u8 = undefined;
    std.mem.writeInt(i32, repeat_payload[0..4], 25, .little);
    std.mem.writeInt(i32, repeat_payload[4..8], 200, .little);
    var r_info: client.Reader = .{ .data = &repeat_payload, .c = &conn };
    WaylandWindow.keyboardEvent(&win, undefined, 1, protocol.wl_keyboard.event.repeat_info, &r_info);
    try testing.expectEqual(@as(u32, 25), win.repeat_rate);
    try testing.expectEqual(@as(u32, 200), win.repeat_delay_ms);

    // 2. Test keymap event via memfd
    const keymap_str =
        \\xkb_keymap {
        \\xkb_keycodes "evdev" { <AD01> = 24; };
        \\xkb_symbols "pc" { key <AD01> { [ z, Z ] }; };
        \\};
    ;
    const mfd_rc = linux.memfd_create("test-keymap", 0);
    if (linux.errno(mfd_rc) == .SUCCESS) {
        const mfd: linux.fd_t = @intCast(mfd_rc);
        _ = linux.write(mfd, keymap_str.ptr, keymap_str.len);
        var km_payload: [8]u8 = undefined;
        std.mem.writeInt(u32, km_payload[0..4], protocol.wl_keyboard.keymap_format.xkb_v1, .little);
        std.mem.writeInt(u32, km_payload[4..8], @intCast(keymap_str.len), .little);
        conn.in_fds[0] = mfd;
        conn.in_fds_start = 0;
        conn.in_fds_end = 1;
        var r_km: client.Reader = .{ .data = &km_payload, .c = &conn };
        WaylandWindow.keyboardEvent(&win, undefined, 1, protocol.wl_keyboard.event.keymap, &r_km);
        try testing.expectEqual(@as(?u8, 'z'), win.ui.lookupKeyChar(16));
    }

    // 3. Open Manage SD Cards text field, press key 16 ('z' in our custom keymap), and verify key repeat
    win.ui.sheet_open = true;
    win.ui.sd_manage_open = true;
    win.ui.focused_field = .sd_card_name;
    win.ui.new_card_name_len = 0;

    var key_down_payload: [16]u8 = undefined;
    std.mem.writeInt(u32, key_down_payload[0..4], 1, .little); // serial
    std.mem.writeInt(u32, key_down_payload[4..8], 100, .little); // time
    std.mem.writeInt(u32, key_down_payload[8..12], 16, .little); // key AD01
    std.mem.writeInt(u32, key_down_payload[12..16], protocol.wl_keyboard.key_state.pressed, .little);
    var r_down: client.Reader = .{ .data = &key_down_payload, .c = &conn };
    WaylandWindow.keyboardEvent(&win, undefined, 1, protocol.wl_keyboard.event.key, &r_down);
    try testing.expectEqualStrings("z", win.ui.newCardName());
    try testing.expect(win.repeat != null);

    const first_due = win.repeat.?.next_ns;
    // Before delay expires: no repeat
    win.serviceRepeat(first_due - 1);
    try testing.expectEqualStrings("z", win.ui.newCardName());

    // At delay expiry: 2nd 'z'
    win.serviceRepeat(first_due);
    try testing.expectEqualStrings("zz", win.ui.newCardName());

    // 40ms later (25 Hz): 3rd 'z'
    win.serviceRepeat(first_due + 40 * std.time.ns_per_ms);
    try testing.expectEqualStrings("zzz", win.ui.newCardName());

    // Release key 16 -> repeat stops
    var key_up_payload = key_down_payload;
    std.mem.writeInt(u32, key_up_payload[12..16], protocol.wl_keyboard.key_state.released, .little);
    var r_up: client.Reader = .{ .data = &key_up_payload, .c = &conn };
    WaylandWindow.keyboardEvent(&win, undefined, 1, protocol.wl_keyboard.event.key, &r_up);
    try testing.expect(win.repeat == null);

    // 4. Test guest USB HID key press + wl_keyboard.leave releases held keys
    win.ui.sheet_open = false;
    r_down = .{ .data = &key_down_payload, .c = &conn };
    WaylandWindow.keyboardEvent(&win, undefined, 1, protocol.wl_keyboard.event.key, &r_down);
    try testing.expectEqual(@as(u8, 0x14), hid.kbd_state[2]);

    var leave_payload: [8]u8 = @splat(0);
    var r_leave: client.Reader = .{ .data = &leave_payload, .c = &conn };
    WaylandWindow.keyboardEvent(&win, undefined, 1, protocol.wl_keyboard.event.leave, &r_leave);
    try testing.expectEqual(@as(u8, 0), hid.kbd_state[2]);

    // 5. Test xdg_toplevel.configure + xdg_surface.configure for maximize and unmaximize
    var disp: client.Display = .{
        .gpa = testing.allocator,
        .conn = .{ .fd = -1 },
    };
    win.display = &disp;
    win.xdg_surface = .{ .display = &disp, .id = 10 };

    // Build xdg_toplevel.configure payload: width=1920, height=1080, states=[maximized(1), activated(4)]
    var tl_cfg_max: [20]u8 = undefined;
    std.mem.writeInt(i32, tl_cfg_max[0..4], 1920, .little);
    std.mem.writeInt(i32, tl_cfg_max[4..8], 1080, .little);
    std.mem.writeInt(u32, tl_cfg_max[8..12], 8, .little); // array byte len = 8
    std.mem.writeInt(u32, tl_cfg_max[12..16], protocol.xdg_toplevel.state.maximized, .little);
    std.mem.writeInt(u32, tl_cfg_max[16..20], protocol.xdg_toplevel.state.activated, .little);
    var r_tl_max: client.Reader = .{ .data = &tl_cfg_max, .c = &conn };
    WaylandWindow.toplevelEvent(&win, &disp, 11, protocol.xdg_toplevel.event.configure, &r_tl_max);
    try testing.expect(win.has_pending_toplevel_configure);
    try testing.expect(win.pending_maximized);
    try testing.expectEqual(@as(u32, 1920), win.pending_toplevel_width);
    try testing.expectEqual(@as(u32, 1080), win.pending_toplevel_height);

    var surf_cfg: [4]u8 = undefined;
    std.mem.writeInt(u32, surf_cfg[0..4], 42, .little);
    var r_surf: client.Reader = .{ .data = &surf_cfg, .c = &conn };
    WaylandWindow.xdgSurfaceEvent(&win, &disp, 10, protocol.xdg_surface.event.configure, &r_surf);
    try testing.expect(win.configured);
    try testing.expect(win.ui.maximized);
    try testing.expectEqual(@as(u32, 1920), win.configured_width);
    try testing.expectEqual(@as(u32, 1080), win.configured_height);

    // When sheet_docked_above is true (both sheet and display visible) and no text field is focused,
    // typing forwards keys to guest USB HID
    win.ui.sheet_open = true;
    win.ui.sheet_docked_above = true;
    win.ui.sd_manage_open = false;
    win.ui.focused_field = .none;
    win.dispatchKey(30, true, false); // KEY_A -> USB HID 0x04
    try testing.expectEqual(@as(u8, 0x04), hid.kbd_state[2]);
    win.dispatchKey(30, false, false);
    try testing.expectEqual(@as(u8, 0), hid.kbd_state[2]);

    // Unmaximize via xdg_toplevel.configure(0, 0, [activated])
    var tl_cfg_unmax: [16]u8 = undefined;
    std.mem.writeInt(i32, tl_cfg_unmax[0..4], 0, .little);
    std.mem.writeInt(i32, tl_cfg_unmax[4..8], 0, .little);
    std.mem.writeInt(u32, tl_cfg_unmax[8..12], 4, .little);
    std.mem.writeInt(u32, tl_cfg_unmax[12..16], protocol.xdg_toplevel.state.activated, .little);
    var r_tl_unmax: client.Reader = .{ .data = &tl_cfg_unmax, .c = &conn };
    WaylandWindow.toplevelEvent(&win, &disp, 11, protocol.xdg_toplevel.event.configure, &r_tl_unmax);
    r_surf = .{ .data = &surf_cfg, .c = &conn };
    WaylandWindow.xdgSurfaceEvent(&win, &disp, 10, protocol.xdg_surface.event.configure, &r_surf);
    try testing.expect(!win.ui.maximized);
    try testing.expectEqual(@as(u32, 0), win.configured_width);
    try testing.expectEqual(@as(u32, 0), win.configured_height);
}

test {
    _ = portal;
}

