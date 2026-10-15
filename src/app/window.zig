const std = @import("std");
const linux = std.os.linux;
const client = @import("../wayland/client.zig");
const protocol = @import("../wayland/protocol.zig");
const UsbHidComposite = @import("../usb/hid.zig").UsbHidComposite;
const Gpio = @import("../soc/gpio.zig").Gpio;
const board_sheet = @import("../ui/board_sheet.zig");

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(status: c_int) noreturn;

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

        const total_width = display_width;
        const total_height = display_height + board_sheet.BoardUi.title_bar_height;

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
            .status = .{
                .serial_u64 = ui.parsedSerial(),
                .mac_address = ui.parsedMac(),
                .wifi_mac_address = ui.parsedWifiMac(),
                .hdmi_width = @intCast(display_width),
                .hdmi_height = @intCast(display_height),
            },
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
            m.string("Raspberry Pi Zero").end();
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
                "--file-filter=Disk Images (*.img, *.iso, *.bin, *.raw) | *.img *.iso *.bin *.raw",
                "--file-filter=All files | *",
            };
            _ = execvp("zenity", &zenity_argv);

            const kdialog_argv = [_:null]?[*:0]const u8{
                "kdialog",
                "--title",
                "Select SD Card Image",
                "--getopenfilename",
                ".",
                "*.img *.iso *.bin *.raw|Disk Images (*.img, *.iso, *.bin, *.raw)\n*|All Files",
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

    const cursor_logical_dim: u32 = 24;
    const crosshair_logical_hot: i32 = 12;

    fn paintFaintCrosshairCursor(pixels: []u32, sc: u32) void {
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
        if (self.pending_scale != self.scale and self.pending_scale >= 1) {
            self.scale = self.pending_scale;
            self.initShmBuffers() catch {};
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
    }

    pub fn pollEvents(self: *WaylandWindow) !void {
        try self.display.pollAndDispatch();
        self.pollSdImagePicker();
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
        var m = self.toplevel.request(protocol.xdg_toplevel.request.set_title) catch return;
        m.string(self.ui.title).end();
    }

    fn toggleMaximized(self: *WaylandWindow) void {
        self.ui.maximized = !self.ui.maximized;
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
                self.pending_scale = @intCast(factor);
            }
        }
    }

    fn outputEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == protocol.wl_output.event.scale) {
            const factor = r.int() catch return;
            if (factor >= 1 and factor <= 4) {
                self.pending_scale = @intCast(factor);
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
        }
    }

    fn toplevelEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, _: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        if (opcode == protocol.xdg_toplevel.event.close) {
            self.closed = true;
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
            },
            protocol.wl_pointer.event.leave => {
                self.last_mouse_x = null;
                self.last_mouse_y = null;
                self.cursor_mode = .unknown;
                self.ui.pointerLeave();
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
                const sx: f32 = @floatCast(sx_f64);
                const sy: f32 = @floatCast(sy_f64);

                if (button == protocol.input.btn_left) {
                    const action = self.ui.pointerButton(sx, sy, pressed, self.status, self.gpio);
                    const over_ui = self.ui.sheet_open or sy < @as(f32, @floatFromInt(board_sheet.BoardUi.title_bar_height));
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
                            return;
                        },
                        .toggle_audio => {
                            self.status.audio_connected = !self.status.audio_connected;
                            return;
                        },
                        .toggle_power => {
                            self.status.power_connected = !self.status.power_connected;
                            if (self.status.power_connected) {
                                self.power_reconnected = true;
                            } else {
                                self.status.hdmi_active = false;
                                self.status.cpu_busy_percent = 0.0;
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
                            return;
                        },
                        .select_sd_image => {
                            self.openSdImagePicker();
                            return;
                        },
                        .select_sd_card => {
                            self.sd_image_chosen = true;
                            return;
                        },
                        .toggle_usb_hub => {
                            self.status.usb_hub_connected = !self.status.usb_hub_connected;
                            hid.hub_connected = self.status.usb_hub_connected;
                            return;
                        },
                        .toggle_usb_keyboard => {
                            self.status.usb_keyboard_connected = !self.status.usb_keyboard_connected;
                            hid.keyboard_connected = self.status.usb_keyboard_connected;
                            return;
                        },
                        .toggle_usb_mouse => {
                            self.status.usb_mouse_connected = !self.status.usb_mouse_connected;
                            hid.mouse_connected = self.status.usb_mouse_connected;
                            return;
                        },
                        .toggle_ethernet => {
                            self.status.ethernet_connected = !self.status.ethernet_connected;
                            hid.ethernet_connected = self.status.ethernet_connected;
                            return;
                        },
                        .select_board => {
                            self.setBoardModel(self.ui.selected_board_model);
                            return;
                        },
                        .toggle_dhcp => {
                            self.status.dhcp_enabled = !self.status.dhcp_enabled;
                            hid.net.dhcp_enabled = self.status.dhcp_enabled;
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
                            return;
                        },
                        .none => {},
                    }
                } else if (self.ui.sheet_open or sy < @as(f32, @floatFromInt(board_sheet.BoardUi.title_bar_height))) {
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
                const sy: f32 = @floatCast(self.last_mouse_y orelse 0.0);
                if (self.ui.sheet_open or sy < @as(f32, @floatFromInt(board_sheet.BoardUi.title_bar_height))) {
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

    fn keyboardEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        const hid = self.hid orelse return;

        switch (opcode) {
            protocol.wl_keyboard.event.keymap => {
                _ = r.uint() catch return; // format
                const fd = r.fd() catch return;
                _ = linux.close(fd);
            },
            protocol.wl_keyboard.event.key => {
                _ = r.uint() catch return; // serial
                _ = r.uint() catch return; // time
                const key = r.uint() catch return;
                const state = r.uint() catch return;
                const pressed = (state == protocol.wl_keyboard.key_state.pressed);
                if (self.ui.sheet_open) {
                    if (pressed and self.ui.handleKey(key)) {
                        self.status.serial_u64 = self.ui.parsedSerial();
                        self.status.mac_address = self.ui.parsedMac();
                        self.status.wifi_mac_address = self.ui.parsedWifiMac();
                        return;
                    }
                    // Escape (evdev key 1) closes any open SD popup/menu first, then the board sheet
                    if (key == 1 and pressed) {
                        if (self.ui.sd_manage_open) {
                            self.ui.sd_manage_open = false;
                            return;
                        }
                        if (self.ui.sd_card_menu_open) {
                            self.ui.sd_card_menu_open = false;
                            return;
                        }
                        self.ui.sheet_open = false;
                        const sy: f64 = self.last_mouse_y orelse 0.0;
                        self.updateCursorShape(sy < @as(f64, @floatFromInt(board_sheet.BoardUi.title_bar_height)));
                    }
                    return;
                }
                hid.handleEvdevKey(key, pressed);
            },
            else => {},
        }
    }
};
