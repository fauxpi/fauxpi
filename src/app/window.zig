const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const client = @import("../wayland/client.zig");
const protocol = @import("../wayland/protocol.zig");
const UsbHidComposite = @import("../usb/hid.zig").UsbHidComposite;
const Gpio = @import("../soc/gpio.zig").Gpio;
const board_sheet = @import("../ui/board_sheet.zig");
pub const macos_window = @import("macos_window.zig");
pub const windows_window = @import("windows_window.zig");

/// Platform-native desktop window backend (`WindowsWindow` on Windows, `MacosWindow` on macOS, `WaylandWindow` on Linux).
pub const Window = switch (builtin.os.tag) {
    .macos => macos_window.MacosWindow,
    .windows => windows_window.WindowsWindow,
    else => WaylandWindow,
};

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(status: c_int) noreturn;

pub const cursor_logical_dim: u32 = 24;
pub const crosshair_logical_hot: i32 = 12;

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

/// Wayland XDG-Shell desktop window with client-side TitleBar (`44px` logical),
/// drop-down Board & GPIO Status Sheet, HiDPI buffer scale support (`1x`, `2x`, ...),
/// pixel-multiplied HDMI display output, and USB HID keyboard & mouse forwarding.
pub const WaylandWindow = struct {
    gpa: std.mem.Allocator,
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
    /// Logical window size (`display_width` x `display_height + 44`)
    width: u32,
    height: u32,
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

    configured: bool = false,
    closed: bool = false,
    ui_dirty: bool = true,
    power_reconnected: bool = false,
    sd_disconnected: bool = false,
    sd_reconnected: bool = false,
    sd_image_chosen: bool = false,
    chosen_sd_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    chosen_sd_path_len: usize = 0,

    picker_fd: linux.fd_t = -1,
    picker_pid: linux.pid_t = -1,
    picker_buf: [std.fs.max_path_bytes]u8 = undefined,
    picker_len: usize = 0,

    last_mouse_x: ?f64 = null,
    last_mouse_y: ?f64 = null,
    last_button_serial: u32 = 0,
    pointer_enter_serial: u32 = 0,
    cursor_mode: enum { unknown, ui_arrow, hdmi_crosshair } = .unknown,

    /// Keyboard repeat configuration (`wl_keyboard.repeat_info`, 0 disables repeat) and repeat state.
    repeat_rate: u32 = 25,
    repeat_delay_ms: u32 = 600,
    repeat: ?struct { key: u32, next_ns: u64 } = null,
    keys_down: std.StaticBitSet(256) = .initEmpty(),

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
        var ui = try board_sheet.BoardUi.init(gpa);
        errdefer ui.deinit();

        const hdmi_fb = try gpa.alloc(u32, @as(usize, display_width) * @as(usize, display_height));
        errdefer gpa.free(hdmi_fb);
        @memset(hdmi_fb, 0xFF101418);

        const display = try client.Display.connectEnviron(gpa, environ);
        errdefer display.disconnect();

        const win = try gpa.create(WaylandWindow);
        errdefer gpa.destroy(win);

        var globals: client.Globals = .{};
        const registry = try globals.fetch(display);

        const compositor = (try globals.bind(registry, protocol.wl_compositor.name, protocol.wl_compositor.version, null)) orelse return error.MissingCompositor;
        const shm = (try globals.bind(registry, protocol.wl_shm.name, protocol.wl_shm.version, null)) orelse return error.MissingShm;
        const wm_base = (try globals.bind(registry, protocol.xdg_wm_base.name, protocol.xdg_wm_base.version, .{ .ptr = win, .handler = wmBaseEvent })) orelse return error.MissingXdgWmBase;

        var status: board_sheet.SystemStatus = .{
            .serial_u64 = ui.parsedSerial(),
            .mac_address = ui.parsedMac(),
            .wifi_mac_address = ui.parsedWifiMac(),
            .hdmi_width = @intCast(display_width),
            .hdmi_height = @intCast(display_height),
        };
        ui.configureXdgStorage(environ, &status);

        const total_width = display_width;
        const total_height = display_height + board_sheet.BoardUi.title_bar_height +
            (if (status.gpio_connected) board_sheet.BoardUi.gpio_panel_height else 0);

        win.* = .{
            .gpa = gpa,
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
            .width = total_width,
            .height = total_height,
            .hdmi_fb = hdmi_fb,
            .hid = hid,
            .gpio = gpio,
            .ui = ui,
            .status = status,
        };
        gpio.setExternalPin(46, !win.status.hdmi_connected);
        hid.setHubKind(@import("../usb/hid.zig").HubKind.fromModel(win.status.model));
        hid.hub_connected = win.status.usb_hub_connected;
        hid.keyboard_connected = win.status.usb_keyboard_connected;
        hid.mouse_connected = win.status.usb_mouse_connected;
        hid.ethernet_connected = win.status.ethernet_connected;
        hid.net.dhcp_enabled = win.status.dhcp_enabled;

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
        try win.initShmBuffers();

        return win;
    }

    pub fn destroy(self: *WaylandWindow) void {
        if (self.picker_fd >= 0) {
            _ = linux.close(self.picker_fd);
            self.picker_fd = -1;
        }
        self.ui.saveSettings(self.status) catch {};
        self.ui.deinit();
        self.gpa.free(self.hdmi_fb);
        self.freeShmBuffers();
        self.display.disconnect();
        self.gpa.destroy(self);
    }

    pub fn chosenSdPath(self: *const WaylandWindow) []const u8 {
        return self.chosen_sd_path_buf[0..self.chosen_sd_path_len];
    }

    fn openSdImagePicker(self: *WaylandWindow) void {
        if (self.picker_fd >= 0) return;

        var fds: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) {
            return;
        }

        const fork_rc = linux.fork();
        if (linux.errno(fork_rc) != .SUCCESS) {
            _ = linux.close(fds[0]);
            _ = linux.close(fds[1]);
            return;
        }

        if (fork_rc == 0) {
            // Child process: redirect stdout to pipe and exec native file chooser
            _ = linux.dup2(fds[1], linux.STDOUT_FILENO);
            _ = linux.close(fds[0]);
            _ = linux.close(fds[1]);

            const zenity_argv = [_:null]?[*:0]const u8{
                "zenity",
                "--file-selection",
                "--title=Select SD Card Image",
                "--file-filter=Disk Images (*.img, *.img.xz, *.iso, *.bin, *.raw) | *.img *.img.xz *.xz *.iso *.bin *.raw",
                "--file-filter=All files | *",
            };
            _ = execvp("zenity", &zenity_argv);

            const kdialog_argv = [_:null]?[*:0]const u8{
                "kdialog",
                "--title",
                "Select SD Card Image",
                "--getopenfilename",
                ".",
                "*.img *.img.xz *.xz *.iso *.bin *.raw|Disk Images (*.img, *.img.xz, *.iso, *.bin, *.raw)\n*|All Files",
            };
            _ = execvp("kdialog", &kdialog_argv);

            _exit(127);
        }

        _ = linux.close(fds[1]);
        self.picker_fd = fds[0];
        self.picker_pid = @intCast(fork_rc);
        self.picker_len = 0;
    }

    fn pollSdImagePicker(self: *WaylandWindow) void {
        if (self.picker_fd < 0) return;

        while (self.picker_len < self.picker_buf.len) {
            const rc = linux.read(
                self.picker_fd,
                self.picker_buf[self.picker_len..].ptr,
                self.picker_buf.len - self.picker_len,
            );
            const err = linux.errno(rc);
            if (err == .AGAIN) return;
            if (err != .SUCCESS) break;
            if (rc == 0) {
                // EOF: dialog closed
                var wstatus: u32 = 0;
                if (self.picker_pid > 0) {
                    _ = linux.waitpid(self.picker_pid, &wstatus, 0);
                }
                _ = linux.close(self.picker_fd);
                self.picker_fd = -1;
                self.picker_pid = -1;

                const trimmed = std.mem.trim(u8, self.picker_buf[0..self.picker_len], " \t\r\n");
                if (trimmed.len > 0 and trimmed.len <= self.chosen_sd_path_buf.len) {
                    @memcpy(self.chosen_sd_path_buf[0..trimmed.len], trimmed);
                    self.chosen_sd_path_len = trimmed.len;
                    const fsize = board_sheet.Qcow2Disk.getFileSizeLinux(trimmed) catch 0;
                    self.ui.setPendingSdImageFile(trimmed, fsize);
                }
                self.picker_len = 0;
                self.ui_dirty = true;
                return;
            }
            self.picker_len += rc;
        }
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

    fn paintArrowCursor(pixels: []u32, sc: u32) void {
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

    fn initShmBuffers(self: *WaylandWindow) !void {
        self.freeShmBuffers();

        const sc = @max(self.scale, 1);
        const buf_w = self.width * sc;
        const buf_h = self.height * sc;
        const stride = buf_w * 4;
        const single_size = @as(usize, stride) * @as(usize, buf_h);

        const cur_dim = cursor_logical_dim * sc;
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
                paintFaintCrosshairCursor(cur_px, sc);
            } else {
                paintArrowCursor(cur_px, sc);
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

    /// Blits the 1x `hdmi_fb` (`display_width * display_height`) into the physical
    /// backbuffer (pixel-doubling `scale x scale` when `scale > 1`) and renders
    /// `BoardUi` at native HiDPI resolution (`scale`).
    pub fn compositeUi(self: *WaylandWindow) void {
        self.ui_dirty = false;
        const desired_h = self.display_height + board_sheet.BoardUi.title_bar_height +
            (if (self.status.gpio_connected) board_sheet.BoardUi.gpio_panel_height else 0);
        if ((self.pending_scale != self.scale and self.pending_scale >= 1) or self.height != desired_h) {
            if (self.pending_scale >= 1) self.scale = self.pending_scale;
            self.height = desired_h;
            self.initShmBuffers() catch {};
            self.ui_dirty = false;
        }

        const sc = @max(self.scale, 1);
        const full = self.backbufferPixels();
        const buf_w: usize = @as(usize, self.width) * @as(usize, sc);
        const top_phys_rows: usize = @as(usize, board_sheet.BoardUi.title_bar_height) * @as(usize, sc);
        const dw: usize = self.display_width;
        const dh: usize = self.display_height;

        if (self.status.hdmi_connected and self.status.hdmi_active) {
            if (sc == 1) {
                const dst = full[top_phys_rows * buf_w ..][0 .. dw * dh];
                @memcpy(dst, self.hdmi_fb[0 .. dw * dh]);
            } else if (sc == 2) {
                for (0..dh) |sy| {
                    const src_row = self.hdmi_fb[sy * dw ..][0..dw];
                    const dst_y0 = top_phys_rows + sy * 2;
                    const first_dst_row = full[dst_y0 * buf_w ..][0 .. dw * 2];
                    const dst_u64: [*]align(4) u64 = @ptrCast(first_dst_row.ptr);
                    for (src_row, 0..) |px, sx| {
                        dst_u64[sx] = (@as(u64, px) << 32) | px;
                    }
                    const dup_dst_row = full[(dst_y0 + 1) * buf_w ..][0 .. dw * 2];
                    @memcpy(dup_dst_row, first_dst_row);
                }
            } else {
                for (0..dh) |sy| {
                    const src_row = self.hdmi_fb[sy * dw ..][0..dw];
                    const dst_y0 = top_phys_rows + sy * sc;
                    const first_dst_row = full[dst_y0 * buf_w ..][0 .. dw * sc];
                    for (src_row, 0..) |px, sx| {
                        @memset(first_dst_row[sx * sc ..][0..sc], px);
                    }
                    for (1..sc) |ry| {
                        const dup_dst_row = full[(dst_y0 + ry) * buf_w ..][0 .. dw * sc];
                        @memcpy(dup_dst_row, first_dst_row);
                    }
                }
            }
        }

        self.ui.paint(full, self.width, self.height, sc, self.status, self.gpio);
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
        {
            var m = try self.surface.request(protocol.wl_surface.request.damage);
            m.int(0).int(0).int(@intCast(self.width)).int(@intCast(self.height)).end();
        }
        {
            var m = try self.surface.request(protocol.wl_surface.request.commit);
            m.end();
        }
        try self.display.pollAndDispatch();
        self.pollSdImagePicker();
        self.pollAsyncSdCreation();
        self.serviceRepeat(monotonicNs());
    }

    pub fn pollEvents(self: *WaylandWindow) !void {
        try self.display.pollAndDispatch();
        self.pollSdImagePicker();
        self.pollAsyncSdCreation();
        self.serviceRepeat(monotonicNs());
    }

    fn pollAsyncSdCreation(self: *WaylandWindow) void {
        switch (self.ui.pollAsyncSdCreation(monotonicNs())) {
            .idle => {},
            .in_progress => {
                self.ui_dirty = true;
            },
            .completed_ok => {
                self.sd_image_chosen = true;
                self.ui_dirty = true;
                self.ui.saveSettings(self.status) catch {};
            },
            .completed_err => {
                self.ui_dirty = true;
            },
        }
    }

    pub fn waitEvents(self: *WaylandWindow, timeout_ms: i32) !void {
        const timeout_us: ?u64 = if (timeout_ms < 0) null else @as(u64, @intCast(timeout_ms)) * 1000;
        return self.waitEventsUs(timeout_us);
    }

    pub fn waitEventsUs(self: *WaylandWindow, timeout_us: ?u64) !void {
        const was_dirty = self.ui_dirty;
        const had_pending_in = if (self.hid) |h| h.hasPendingInterruptIn() else false;
        try self.display.pollAndDispatch();
        self.pollSdImagePicker();
        self.pollAsyncSdCreation();
        const now_ns = monotonicNs();
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
        if (self.picker_fd >= 0) {
            fds[nfds] = .{ .fd = self.picker_fd, .events = linux.POLL.IN, .revents = 0 };
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
            self.pollSdImagePicker();
        }
        self.pollAsyncSdCreation();
        self.serviceRepeat(monotonicNs());
    }

    pub fn repeatTimeoutMs(self: *const WaylandWindow, now_ns: u64) ?i32 {
        const rep = self.repeat orelse return null;
        if (self.repeat_rate == 0 or !self.ui.sheet_open) return null;
        if (now_ns >= rep.next_ns) return 0;
        const rem_ms = std.math.divCeil(u64, rep.next_ns - now_ns, std.time.ns_per_ms) catch 0;
        return @intCast(@min(rem_ms, @as(u64, std.math.maxInt(i32))));
    }

    pub fn serviceRepeat(self: *WaylandWindow, now_ns: u64) void {
        const rep = &(self.repeat orelse return);
        if (self.repeat_rate == 0) {
            self.repeat = null;
            return;
        }
        if (now_ns < rep.next_ns) return;
        const step = std.time.ns_per_s / @as(u64, self.repeat_rate);
        rep.next_ns = if (now_ns - rep.next_ns < step) rep.next_ns + step else now_ns + step;
        if (self.ui.sheet_open) {
            self.dispatchKey(rep.key, true, true);
        }
    }

    fn startMove(self: *WaylandWindow) void {
        const seat = self.seat orelse return;
        var m = self.toplevel.request(protocol.xdg_toplevel.request.move) catch return;
        m.uint(seat.id).uint(self.last_button_serial).end();
    }

    pub fn setBoardModel(self: *WaylandWindow, bm: board_sheet.BoardModel) void {
        self.status.board_model = bm;
        self.status.model = bm.dtModel();
        self.status.serial_u64 = self.ui.parsedSerial();
        self.status.mac_address = self.ui.parsedMac();
        self.status.wifi_mac_address = self.ui.parsedWifiMac();
        self.ui.title = bm.windowTitle();
        if (!bm.usesExternalUsbHub()) {
            self.status.usb_hub_connected = true;
        }
        if (self.hid) |h| {
            h.setHubKind(@import("../usb/hid.zig").HubKind.fromModel(self.status.model));
            h.hub_connected = self.status.usb_hub_connected;
        }
        self.ui_dirty = true;
        self.ui.saveSettings(self.status) catch {};
        var m = self.toplevel.request(protocol.xdg_toplevel.request.set_title) catch return;
        m.string(self.ui.title).end();
    }

    fn toggleMaximized(self: *WaylandWindow) void {
        self.ui.maximized = !self.ui.maximized;
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
            self.configured = true;
            self.ui_dirty = true;
        }
    }

    fn toplevelEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, _: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == protocol.xdg_toplevel.event.close) {
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

    fn updateCursorShape(self: *WaylandWindow, over_ui: bool) void {
        const ptr = self.pointer orelse return;
        if (!self.has_buffers) return;
        const target: @TypeOf(self.cursor_mode) = if (over_ui) .ui_arrow else .hdmi_crosshair;
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
        const hot_x: i32 = if (over_ui) 1 else crosshair_logical_hot;
        const hot_y: i32 = if (over_ui) 1 else crosshair_logical_hot;

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
            m.int(0).int(0).int(@intCast(cursor_logical_dim)).int(@intCast(cursor_logical_dim)).end();
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

    fn updateGuestMouseTarget(self: *WaylandWindow, sx: f64, sy: f64) void {
        const hid = self.hid orelse return;
        const max_x = @max(@as(i32, @intCast(self.display_width)) - 1, 0);
        const max_y = @max(@as(i32, @intCast(self.display_height)) - 1, 0);
        const hdmi_x = std.math.clamp(@as(i32, @intFromFloat(@floor(sx))), 0, max_x);
        const hdmi_y = std.math.clamp(
            @as(i32, @intFromFloat(@floor(sy))) - @as(i32, board_sheet.BoardUi.title_bar_height),
            0,
            max_y,
        );
        hid.setMouseTarget(hdmi_x, hdmi_y);
    }

    fn pointerEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        const hid = self.hid orelse return;

        switch (opcode) {
            protocol.wl_pointer.event.enter => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return; // surface
                const sx = r.fixed() catch return;
                const sy = r.fixed() catch return;
                self.pointer_enter_serial = serial;
                self.cursor_mode = .unknown;
                self.last_mouse_x = sx;
                self.last_mouse_y = sy;
                const in_ui = self.ui.pointerMotion(@floatCast(sx), @floatCast(sy), self.status, self.gpio);
                self.updateCursorShape(in_ui);
                if (!in_ui) {
                    self.updateGuestMouseTarget(sx, sy);
                }
                self.ui_dirty = true;
            },
            protocol.wl_pointer.event.leave => {
                self.last_mouse_x = null;
                self.last_mouse_y = null;
                self.cursor_mode = .unknown;
                self.ui.pointerLeave();
                self.ui_dirty = true;
            },
            protocol.wl_pointer.event.motion => {
                _ = r.uint() catch return; // time
                const sx = r.fixed() catch return;
                const sy = r.fixed() catch return;
                const in_ui = self.ui.pointerMotion(@floatCast(sx), @floatCast(sy), self.status, self.gpio);
                self.updateCursorShape(in_ui);
                if (!in_ui) {
                    self.updateGuestMouseTarget(sx, sy);
                }
                self.last_mouse_x = sx;
                self.last_mouse_y = sy;
                self.ui_dirty = true;
            },
            protocol.wl_pointer.event.button => {
                const serial = r.uint() catch return;
                _ = r.uint() catch return; // time
                const button = r.uint() catch return;
                const state = r.uint() catch return;
                const pressed = (state == protocol.wl_pointer.button_state.pressed);
                self.last_button_serial = serial;
                self.ui_dirty = true;

                const sx_f64 = self.last_mouse_x orelse 0.0;
                const sy_f64 = self.last_mouse_y orelse 0.0;
                const sx: f32 = @floatCast(sx_f64);
                const sy: f32 = @floatCast(sy_f64);

                if (button == protocol.input.btn_left) {
                    const prev_sheet = self.ui.sheet_open;
                    const action = self.ui.pointerButton(sx, sy, pressed, self.status, self.gpio);
                    if (!prev_sheet and self.ui.sheet_open) {
                        hid.releaseAllKeys();
                    }
                    const over_ui = self.ui.isPointInUi(sx, sy, self.status);
                    self.updateCursorShape(over_ui);
                    switch (action) {
                        .start_drag => {
                            self.startMove();
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
                                self.status.cpu_busy_percent = 0.0;
                                self.gpio.resetSocState();
                            }
                            return;
                        },
                        .toggle_sd => {
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
                            self.openSdImagePicker();
                            return;
                        },
                        .select_sd_card => {
                            self.sd_image_chosen = true;
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
                            self.ui.saveSettings(self.status) catch {};
                            return;
                        },
                        .none => {},
                    }
                } else if (self.ui.isPointInUi(sx, sy, self.status)) {
                    return;
                }

                const bit: u8 = switch (button) {
                    protocol.input.btn_left => 1 << 0,
                    protocol.input.btn_right => 1 << 1,
                    protocol.input.btn_middle => 1 << 2,
                    else => 0,
                };
                if (bit != 0) {
                    self.updateGuestMouseTarget(sx_f64, sy_f64);
                    hid.handleMouseButton(bit, pressed);
                }
            },
            protocol.wl_pointer.event.axis => {
                _ = r.uint() catch return; // time
                const axis = r.uint() catch return;
                const value = r.fixed() catch return;
                const sx: f32 = @floatCast(self.last_mouse_x orelse 0.0);
                const sy: f32 = @floatCast(self.last_mouse_y orelse 0.0);
                if (self.ui.isPointInUi(sx, sy, self.status)) {
                    return;
                }
                if (axis == protocol.wl_pointer.axis.vertical_scroll and value != 0) {
                    const wheel: i8 = if (value < 0) 1 else -1;
                    hid.handleMouseMotion(0, 0, wheel);
                }
            },
            else => {},
        }
    }

    fn isModifierKey(evdev_key: u32) bool {
        return switch (evdev_key) {
            29, 97, 42, 54, 56, 100, 125, 126, 58, 69, 70 => true,
            else => false,
        };
    }

    pub fn dispatchKey(self: *WaylandWindow, key: u32, pressed: bool, is_repeat: bool) void {
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
            // Escape (evdev key 1) closes any open SD popup/menu first, then the board sheet
            if (key == 1 and pressed and !is_repeat) {
                if (self.ui.sd_manage_open) {
                    self.ui.sd_manage_open = false;
                    return;
                }
                if (self.ui.sd_card_menu_open) {
                    self.ui.sd_card_menu_open = false;
                    return;
                }
                self.ui.sheet_open = false;
                const sx: f32 = @floatCast(self.last_mouse_x orelse 0.0);
                const sy: f32 = @floatCast(self.last_mouse_y orelse 0.0);
                self.updateCursorShape(self.ui.isPointInUi(sx, sy, self.status));
            }
            return;
        }
        if (self.hid) |hid| {
            hid.handleEvdevKey(key, pressed);
        }
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
                self.keys_down = .initEmpty();
                self.ui.clearModifiers();
                var i: usize = 0;
                while (i + 4 <= keys.len) : (i += 4) {
                    const key = std.mem.readInt(u32, keys[i..][0..4], .little);
                    if (key < 256) self.keys_down.set(key);
                    self.ui.updateModifierKey(key, true);
                    if (!self.ui.sheet_open) {
                        if (self.hid) |hid| {
                            hid.handleEvdevKey(key, true);
                        }
                    }
                }
            },
            protocol.wl_keyboard.event.leave => {
                _ = r.uint() catch return; // serial
                _ = r.uint() catch return; // surface
                self.repeat = null;
                self.keys_down = .initEmpty();
                self.ui.clearModifiers();
                if (self.hid) |hid| {
                    hid.releaseAllKeys();
                }
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
                if (key < 256) {
                    if (pressed) self.keys_down.set(key) else self.keys_down.unset(key);
                }
                if (pressed) {
                    if (!isModifierKey(key) and self.repeat_rate > 0 and !is_repeat) {
                        const delay_ns = @as(u64, self.repeat_delay_ms) * std.time.ns_per_ms;
                        self.repeat = .{ .key = key, .next_ns = monotonicNs() + delay_ns };
                    }
                } else {
                    if (self.repeat) |rep| {
                        if (rep.key == key) self.repeat = null;
                    }
                }
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

fn monotonicNs() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    const sec: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
    const nsec: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
    return sec * std.time.ns_per_s + nsec;
}

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
}

