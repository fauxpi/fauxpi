const std = @import("std");
const linux = std.os.linux;
const client = @import("../wayland/client.zig");
const protocol = @import("../wayland/protocol.zig");
const UsbHidComposite = @import("../usb/hid.zig").UsbHidComposite;
const Gpio = @import("../soc/gpio.zig").Gpio;
const board_sheet = @import("../ui/board_sheet.zig");

/// Wayland XDG-Shell desktop window with client-side TitleBar (`44px`),
/// drop-down Board & GPIO Status Sheet, HDMI display output, and USB HID
/// keyboard & mouse forwarding.
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

    surface: client.Proxy,
    xdg_surface: client.Proxy,
    toplevel: client.Proxy,

    display_width: u32,
    display_height: u32,
    width: u32,
    height: u32,

    shm_fd: linux.fd_t = -1,
    shm_map: []align(std.heap.page_size_min) u8 = &.{},
    buffers: [2]client.Proxy = undefined,
    cur_buf: u1 = 0,

    configured: bool = false,
    closed: bool = false,

    last_mouse_x: ?f64 = null,
    last_mouse_y: ?f64 = null,
    last_button_serial: u32 = 0,

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
            .xdg_surface = undefined,
            .toplevel = undefined,
            .display_width = display_width,
            .display_height = display_height,
            .width = total_width,
            .height = total_height,
            .hid = hid,
            .gpio = gpio,
            .ui = ui,
            .status = .{
                .hdmi_width = @intCast(display_width),
                .hdmi_height = @intCast(display_height),
            },
        };

        win.seat = try globals.bind(registry, protocol.wl_seat.name, protocol.wl_seat.version, .{ .ptr = win, .handler = seatEvent });

        win.surface = try display.newObject(null);
        {
            var m = try compositor.request(protocol.wl_compositor.request.create_surface);
            m.uint(win.surface.id).end();
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

        try win.initShmBuffers();

        // Wait for initial xdg_surface.configure
        try display.roundtrip();
        if (!win.configured) {
            try display.roundtrip();
        }

        return win;
    }

    pub fn destroy(self: *WaylandWindow) void {
        self.ui.deinit();
        if (self.shm_map.len > 0) {
            _ = linux.munmap(self.shm_map.ptr, self.shm_map.len);
        }
        if (self.shm_fd >= 0) {
            _ = linux.close(self.shm_fd);
        }
        self.display.disconnect();
        self.gpa.destroy(self);
    }

    fn initShmBuffers(self: *WaylandWindow) !void {
        const stride = self.width * 4;
        const single_size = stride * self.height;
        const pool_size = single_size * 2;

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
                .int(@intCast(self.width))
                .int(@intCast(self.height))
                .int(@intCast(stride))
                .uint(protocol.wl_shm.format.xrgb8888)
                .end();
        }

        {
            var m = try pool.request(protocol.wl_shm_pool.request.destroy);
            m.end();
        }
    }

    /// Returns the full window backbuffer (`width * height`).
    pub fn backbufferPixels(self: *WaylandWindow) []u32 {
        const count = self.width * self.height;
        const byte_off = @as(usize, self.cur_buf) * count * 4;
        return @alignCast(std.mem.bytesAsSlice(u32, self.shm_map[byte_off .. byte_off + count * 4]));
    }

    /// Returns the HDMI display slice of the current backbuffer (`display_width * display_height`,
    /// starting below the `44px` TitleBar).
    pub fn displayPixels(self: *WaylandWindow) []u32 {
        const full = self.backbufferPixels();
        const top_offset = @as(usize, board_sheet.BoardUi.title_bar_height) * @as(usize, self.width);
        const disp_count = @as(usize, self.display_width) * @as(usize, self.display_height);
        return full[top_offset .. top_offset + disp_count];
    }

    /// Renders the client-side TitleBar (`y = 0..44`) and, when open, the drop-down
    /// Board & GPIO Status Sheet over the current backbuffer.
    pub fn compositeUi(self: *WaylandWindow) void {
        self.ui.paint(self.backbufferPixels(), self.width, self.height, self.status, self.gpio);
    }

    pub fn present(self: *WaylandWindow) !void {
        const buf = self.buffers[self.cur_buf];
        self.cur_buf ^= 1;

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
    }

    pub fn pollEvents(self: *WaylandWindow) !void {
        try self.display.pollAndDispatch();
    }

    fn startMove(self: *WaylandWindow) void {
        const seat = self.seat orelse return;
        var m = self.toplevel.request(protocol.xdg_toplevel.request.move) catch return;
        m.uint(seat.id).uint(self.last_button_serial).end();
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

    fn pointerEvent(ptr: ?*anyopaque, _: *client.Display, _: u32, opcode: u16, r: *client.Reader) void {
        const self: *WaylandWindow = @ptrCast(@alignCast(ptr.?));
        const hid = self.hid orelse return;

        switch (opcode) {
            protocol.wl_pointer.event.enter => {
                _ = r.uint() catch return; // serial
                _ = r.uint() catch return; // surface
                const sx = r.fixed() catch return;
                const sy = r.fixed() catch return;
                self.last_mouse_x = sx;
                self.last_mouse_y = sy;
                _ = self.ui.pointerMotion(@floatCast(sx), @floatCast(sy), self.status, self.gpio);
            },
            protocol.wl_pointer.event.leave => {
                self.last_mouse_x = null;
                self.last_mouse_y = null;
                self.ui.pointerLeave();
            },
            protocol.wl_pointer.event.motion => {
                _ = r.uint() catch return; // time
                const sx = r.fixed() catch return;
                const sy = r.fixed() catch return;
                const in_ui = self.ui.pointerMotion(@floatCast(sx), @floatCast(sy), self.status, self.gpio);
                if (!in_ui and self.last_mouse_x != null and self.last_mouse_y != null) {
                    const dx_f = std.math.clamp(@round(sx - self.last_mouse_x.?), -127.0, 127.0);
                    const dy_f = std.math.clamp(@round(sy - self.last_mouse_y.?), -127.0, 127.0);
                    const dx: i8 = @intFromFloat(dx_f);
                    const dy: i8 = @intFromFloat(dy_f);
                    hid.handleMouseMotion(dx, dy, 0);
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

                const sx: f32 = @floatCast(self.last_mouse_x orelse 0.0);
                const sy: f32 = @floatCast(self.last_mouse_y orelse 0.0);

                if (button == protocol.input.btn_left) {
                    const action = self.ui.pointerButton(sx, sy, pressed, self.status, self.gpio);
                    switch (action) {
                        .start_drag => {
                            self.startMove();
                            return;
                        },
                        .toggle_maximize => {
                            self.toggleMaximized();
                            return;
                        },
                        .close => {
                            self.closed = true;
                            return;
                        },
                        .consumed => return,
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
                    // Escape (evdev key 1) closes the mode menu or the board sheet
                    if (key == 1 and pressed) {
                        if (self.ui.mode_menu_open) {
                            self.ui.mode_menu_open = false;
                        } else {
                            self.ui.sheet_open = false;
                        }
                    }
                    return;
                }
                hid.handleEvdevKey(key, pressed);
            },
            else => {},
        }
    }
};
