const std = @import("std");
const net_mod = @import("net.zig");
const Lan7800 = @import("lan78xx.zig").Lan7800;

/// USB Hub hardware topology variant:
/// - `.external`: External 3-port USB 2.0 Hub with Ethernet (Pi Zero / Zero W / Zero 2 W / Model A+)
/// - `.lan9514`: Built-in SMSC LAN9514 5-port USB 2.0 Hub + 10/100 Ethernet (Pi 1 Model B+)
/// - `.lan7515`: Built-in Microchip LAN7515 (USB2514B 5-port Hub + LAN7800 Ethernet, Pi 3 Model B+)
pub const HubKind = enum {
    external,
    lan9514,
    lan7515,

    pub fn isBuiltIn(self: HubKind) bool {
        return self != .external;
    }

    pub fn numPorts(self: HubKind) u8 {
        return switch (self) {
            .external => 4, // Port 1: Ethernet, Ports 2..4: 3 USB-A ports
            .lan9514, .lan7515 => 5, // Port 1: Ethernet, Ports 2..5: 4 USB-A ports
        };
    }

    pub fn hubVendorId(self: HubKind) u16 {
        return switch (self) {
            .external => 0x1d6b,
            .lan9514, .lan7515 => 0x0424,
        };
    }

    pub fn hubProductId(self: HubKind) u16 {
        return switch (self) {
            .external => 0x0101,
            .lan9514 => 0x9514,
            .lan7515 => 0x2514,
        };
    }

    pub fn hubBcdDevice(self: HubKind) u16 {
        return switch (self) {
            .external => 0x0100,
            .lan9514 => 0x0200,
            .lan7515 => 0x0bb3,
        };
    }

    pub fn ethVendorId(self: HubKind) u16 {
        return switch (self) {
            .external => 0x1d6b,
            .lan9514, .lan7515 => 0x0424,
        };
    }

    pub fn ethProductId(self: HubKind) u16 {
        return switch (self) {
            .external => 0x0105,
            .lan9514 => 0xec00,
            .lan7515 => 0x7800,
        };
    }

    pub fn ethBcdDevice(self: HubKind) u16 {
        return switch (self) {
            .external => 0x0100,
            .lan9514 => 0x0200,
            .lan7515 => 0x0300,
        };
    }

    pub fn dtHubCompatible(self: HubKind) ?[]const u8 {
        return switch (self) {
            .external => null,
            .lan9514 => "usb424,9514",
            .lan7515 => "usb424,2514",
        };
    }
};

/// Multi-Device USB Bus Topology:
/// - Root Hub Port 1 (`1-1`): USB 2.0 Hub (`bDeviceClass = 0x09`, High-Speed 480 Mb/s)
///   - Hub Port 1 (`1-1.1`): USB Ethernet Adapter (`bInterfaceClass = 0x02`, High-Speed 480 Mb/s; fixed on built-in hubs)
///   - Hub Port 2 (`1-1.2`): Standalone USB HID Boot Keyboard (`1d6b:0102`, Full-Speed 12 Mb/s, removable)
///   - Hub Port 3 (`1-1.3`): Standalone USB HID Boot Mouse (`1d6b:0103`, Full-Speed 12 Mb/s, removable)
pub const UsbHidComposite = struct {
    pub const MAX_PORTS: usize = 5;

    // USB 2.0 Hub Port Status bits (wPortStatus)
    pub const PORT_STAT_CONNECTION: u16 = 1 << 0;
    pub const PORT_STAT_ENABLE: u16 = 1 << 1;
    pub const PORT_STAT_SUSPEND: u16 = 1 << 2;
    pub const PORT_STAT_OVER_CURRENT: u16 = 1 << 3;
    pub const PORT_STAT_RESET: u16 = 1 << 4;
    pub const PORT_STAT_POWER: u16 = 1 << 8;
    pub const PORT_STAT_LOW_SPEED: u16 = 1 << 9;
    pub const PORT_STAT_HIGH_SPEED: u16 = 1 << 10;

    // USB 2.0 Hub Port Change bits (wPortChange)
    pub const PORT_CHANGE_CONNECTION: u16 = 1 << 0;
    pub const PORT_CHANGE_ENABLE: u16 = 1 << 1;
    pub const PORT_CHANGE_SUSPEND: u16 = 1 << 2;
    pub const PORT_CHANGE_OVER_CURRENT: u16 = 1 << 3;
    pub const PORT_CHANGE_RESET: u16 = 1 << 4;

    pub const TargetDevice = enum(u2) {
        hub = 0,
        eth = 1,
        kbd = 2,
        mouse = 3,
    };

    pub const ControlState = struct {
        buf: [256]u8 = @splat(0),
        len: usize = 0,
        pos: usize = 0,
        last_setup_ok: bool = true,
        // Host-to-device request waiting for its DATA OUT stage (collected into `buf`)
        out_setup: ?[8]u8 = null,
    };

    hub_kind: HubKind = .external,

    // Per-device USB addresses and configuration states
    hub_addr: u7 = 0,
    hub_configured: bool = false,
    port_status: [MAX_PORTS]u16 = @splat(0),
    port_change: [MAX_PORTS]u16 = @splat(0),
    latched_port_conn: [MAX_PORTS]bool = @splat(false),

    eth_addr: u7 = 0,
    eth_configured: bool = false,
    cdc_alt_setting: u8 = 0,
    cdc_packet_filter: u16 = 0,
    // Microchip LAN7800 controller state (built-in Ethernet on `.lan7515`)
    lan7800: Lan7800 = .{},

    kbd_addr: u7 = 0,
    kbd_configured: bool = false,
    kbd_idle_rate: u8 = 0,
    kbd_protocol: u8 = 1, // 1 = Report protocol, 0 = Boot protocol

    mouse_addr: u7 = 0,
    mouse_configured: bool = false,
    mouse_idle_rate: u8 = 0,
    mouse_protocol: u8 = 1, // 1 = Report protocol, 0 = Boot protocol

    // Which device currently responds to USB default address 0 (set by root port reset or hub port reset)
    active_zero_target: TargetDevice = .hub,

    // Per-device control transfer buffers (prevents hub GetPortStatus polling from clobbering child enumeration)
    ctrl: [4]ControlState = @splat(.{}),

    // Current Keyboard state: [modifier, reserved, key0, key1, key2, key3, key4, key5]
    kbd_state: [8]u8 = @splat(0),
    // Queued 8-byte keyboard reports
    kbd_queue: [16][8]u8 = undefined,
    kbd_head: u4 = 0,
    kbd_tail: u4 = 0,
    kbd_count: u5 = 0,

    // Current Mouse button mask (bit 0 = left, bit 1 = right, bit 2 = middle)
    mouse_buttons: u8 = 0,
    reported_buttons: u8 = 0,
    // Queued 4-byte mouse reports: [buttons, dx, dy, wheel]
    mouse_queue: [32][4]u8 = undefined,
    mouse_head: u5 = 0,
    mouse_tail: u5 = 0,
    mouse_count: u6 = 0,

    // Target-tracking guest cursor position (in HDMI display pixel coordinates)
    guest_x: i32 = 640,
    guest_y: i32 = 360,
    target_x: i32 = 640,
    target_y: i32 = 360,
    has_target: bool = false,
    cursor_seen: bool = false,
    idle_vblanks: u8 = 0,

    // Peripheral connection states on the USB Hub
    hub_connected: bool = true,
    keyboard_connected: bool = true,
    mouse_connected: bool = true,
    ethernet_connected: bool = true,

    // CDC-ECM Interrupt IN notification queue (EP1 IN on Ethernet device)
    eth_notif_polled: bool = false,
    reported_link_up: ?bool = null,
    cdc_notif_queue: [8][16]u8 = undefined,
    cdc_notif_lens: [8]u8 = @splat(0),
    cdc_notif_head: u3 = 0,
    cdc_notif_tail: u3 = 0,
    cdc_notif_count: u4 = 0,

    // User-mode NAT / SLIRP network stack
    net: net_mod.VirtualNetwork = .{},

    pub fn setHubKind(self: *UsbHidComposite, kind: HubKind) void {
        self.hub_kind = kind;
    }

    pub fn isHubPresent(self: *const UsbHidComposite) bool {
        return self.hub_kind.isBuiltIn() or self.hub_connected;
    }

    pub fn isPortDeviceConnected(self: *const UsbHidComposite, port_idx: usize) bool {
        if (!self.isHubPresent()) return false;
        if (port_idx >= self.hub_kind.numPorts()) return false;
        return switch (port_idx) {
            0 => true, // Port 1: USB Ethernet controller on the hub (link carrier is ethernet_connected)
            1 => self.keyboard_connected, // Port 2: USB Keyboard
            2 => self.mouse_connected, // Port 3: USB Mouse
            else => false, // Spare USB-A ports
        };
    }

    pub fn resetHubDevice(self: *UsbHidComposite) void {
        self.hub_addr = 0;
        self.hub_configured = false;
        self.port_status = @splat(0);
        self.port_change = @splat(0);
        self.latched_port_conn = @splat(false);
        self.ctrl[@intFromEnum(TargetDevice.hub)] = .{};
    }

    pub fn resetEthDevice(self: *UsbHidComposite) void {
        self.eth_addr = 0;
        self.eth_configured = false;
        self.cdc_alt_setting = 0;
        self.cdc_packet_filter = 0;
        self.eth_notif_polled = false;
        self.reported_link_up = null;
        self.cdc_notif_head = 0;
        self.cdc_notif_tail = 0;
        self.cdc_notif_count = 0;
        self.lan7800.reset();
        self.ctrl[@intFromEnum(TargetDevice.eth)] = .{};
    }

    pub fn resetKbdDevice(self: *UsbHidComposite) void {
        self.kbd_addr = 0;
        self.kbd_configured = false;
        self.kbd_idle_rate = 0;
        self.kbd_protocol = 1;
        self.ctrl[@intFromEnum(TargetDevice.kbd)] = .{};
    }

    pub fn resetMouseDevice(self: *UsbHidComposite) void {
        self.mouse_addr = 0;
        self.mouse_configured = false;
        self.has_target = false;
        self.mouse_idle_rate = 0;
        self.mouse_protocol = 1;
        self.ctrl[@intFromEnum(TargetDevice.mouse)] = .{};
    }

    /// Resets the entire USB bus (triggered on DWC2 root port `HPRT0` reset).
    pub fn reset(self: *UsbHidComposite) void {
        self.resetHubDevice();
        self.resetEthDevice();
        self.resetKbdDevice();
        self.resetMouseDevice();
        self.active_zero_target = .hub;
    }

    /// Synchronizes downstream hub port connection states with `keyboard_connected` and `mouse_connected`.
    pub fn syncHubPortConnections(self: *UsbHidComposite) void {
        const num_ports = self.hub_kind.numPorts();
        for (0..num_ports) |p| {
            const powered = (self.port_status[p] & PORT_STAT_POWER) != 0;
            if (!powered) continue;
            const want_conn = self.isPortDeviceConnected(p);
            const cur_conn = (self.port_status[p] & PORT_STAT_CONNECTION) != 0;
            if (want_conn != cur_conn) {
                if (want_conn) {
                    self.port_status[p] |= PORT_STAT_CONNECTION | if (p == 0) PORT_STAT_HIGH_SPEED else 0;
                } else {
                    self.port_status[p] &= ~(PORT_STAT_CONNECTION | PORT_STAT_ENABLE | PORT_STAT_SUSPEND | PORT_STAT_RESET);
                    switch (p) {
                        0 => self.resetEthDevice(),
                        1 => self.resetKbdDevice(),
                        2 => self.resetMouseDevice(),
                        else => {},
                    }
                }
                self.port_change[p] |= PORT_CHANGE_CONNECTION;
                self.latched_port_conn[p] = want_conn;
            }
        }
    }

    /// Resolves which USB device on the bus responds to `devaddr`.
    pub fn resolveDevice(self: *const UsbHidComposite, devaddr: u7) ?TargetDevice {
        if (!self.isHubPresent()) return null;
        if (devaddr == 0) {
            return switch (self.active_zero_target) {
                .hub => .hub,
                .eth => .eth,
                .kbd => if (self.keyboard_connected) .kbd else null,
                .mouse => if (self.mouse_connected) .mouse else null,
            };
        }
        if (self.hub_addr != 0 and devaddr == self.hub_addr) return .hub;
        if (self.eth_addr != 0 and devaddr == self.eth_addr) return .eth;
        if (self.kbd_addr != 0 and devaddr == self.kbd_addr and self.keyboard_connected) return .kbd;
        if (self.mouse_addr != 0 and devaddr == self.mouse_addr and self.mouse_connected) return .mouse;
        return null;
    }

    pub fn isEthernetLinkUp(self: *const UsbHidComposite) bool {
        return self.isHubPresent() and self.ethernet_connected;
    }

    fn enqueueCdcNotif(self: *UsbHidComposite, data: []const u8) void {
        if (self.cdc_notif_count >= 8 or data.len > 16) return;
        @memset(&self.cdc_notif_queue[self.cdc_notif_tail], 0);
        @memcpy(self.cdc_notif_queue[self.cdc_notif_tail][0..data.len], data);
        self.cdc_notif_lens[self.cdc_notif_tail] = @intCast(data.len);
        self.cdc_notif_tail +%= 1;
        self.cdc_notif_count += 1;
    }

    fn queueLinkNotifications(self: *UsbHidComposite, link_up: bool) void {
        if (link_up) {
            // USB_CDC_NOTIFY_SPEED_CHANGE (0x2a) on Interface 0: 100 Mbps (0x05f5e100) DL & UL
            const speed_notif = [16]u8{
                0xa1, 0x2a, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00,
                0x00, 0xe1, 0xf5, 0x05, 0x00, 0xe1, 0xf5, 0x05,
            };
            self.enqueueCdcNotif(&speed_notif);
        }
        // USB_CDC_NOTIFY_NETWORK_CONNECTION (0x00) on Interface 0: wValue = 1 (connected) or 0 (disconnected)
        const conn_notif = [8]u8{
            0xa1,
            0x00,
            if (link_up) 1 else 0,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
        };
        self.enqueueCdcNotif(&conn_notif);
    }

    pub fn allConnectedDevicesConfigured(self: *const UsbHidComposite) bool {
        if (!self.isHubPresent()) return true;
        if (!self.hub_configured) return false;
        if (!self.eth_configured) return false;
        if (self.keyboard_connected and !self.kbd_configured) return false;
        if (self.mouse_connected and !self.mouse_configured) return false;
        return true;
    }

    pub fn hasPendingInterruptIn(self: *UsbHidComposite) bool {
        if (!self.isHubPresent() or !self.hub_configured) return false;
        self.syncHubPortConnections();
        const num_ports = self.hub_kind.numPorts();
        for (0..num_ports) |p| {
            if (self.port_change[p] != 0) return true;
        }
        if (self.eth_configured and self.hub_kind == .lan7515) {
            if (self.lan7800.hasInterrupt(self.isEthernetLinkUp())) return true;
        } else if (self.eth_configured and self.eth_notif_polled) {
            const link_up = self.isEthernetLinkUp();
            if (self.reported_link_up == null or self.reported_link_up.? != link_up or self.cdc_notif_count > 0) {
                return true;
            }
        }
        if (self.keyboard_connected and self.kbd_configured and self.kbd_count > 0) return true;
        if (self.mouse_connected and self.mouse_configured) {
            if (self.mouse_count > 0) return true;
            if (self.has_target and (self.target_x != self.guest_x or self.target_y != self.guest_y)) return true;
        }
        return false;
    }

    /// Returns the 1-byte Hub status change bitmap for EP1 IN on the Hub device if any port has a pending change.
    pub fn popHubInterrupt(self: *UsbHidComposite) ?u8 {
        if (!self.isHubPresent()) return null;
        self.syncHubPortConnections();
        var bitmap: u8 = 0;
        const num_ports = self.hub_kind.numPorts();
        for (0..num_ports) |p| {
            if (self.port_change[p] != 0) {
                bitmap |= (@as(u8, 1) << @intCast(p + 1));
            }
        }
        if (bitmap == 0) return null;
        return bitmap;
    }

    /// Returns the Ethernet controller's next Interrupt IN report: CDC notifications, or the
    /// LAN7800's interrupt status word.
    pub fn popEthInterrupt(self: *UsbHidComposite, dest: []u8) ?usize {
        if (!self.isHubPresent()) return null;
        if (self.hub_kind == .lan7515) return self.lan7800.popInterrupt(self.isEthernetLinkUp(), dest);
        self.eth_notif_polled = true;
        const link_up = self.isEthernetLinkUp();
        if (self.reported_link_up == null or self.reported_link_up.? != link_up) {
            self.reported_link_up = link_up;
            self.queueLinkNotifications(link_up);
        }
        if (self.cdc_notif_count == 0) return null;
        const len: usize = self.cdc_notif_lens[self.cdc_notif_head];
        const copy_len = @min(dest.len, len);
        @memcpy(dest[0..copy_len], self.cdc_notif_queue[self.cdc_notif_head][0..copy_len]);
        self.cdc_notif_head +%= 1;
        self.cdc_notif_count -= 1;
        return copy_len;
    }

    /// Whether `ep` (endpoint number) is a Bulk endpoint of the Ethernet controller.
    pub fn isEthBulkEndpoint(self: *const UsbHidComposite, ep: u4) bool {
        return switch (self.hub_kind) {
            .lan7515 => ep == 1 or ep == 2,
            else => ep == 2,
        };
    }

    /// Whether `ep` (endpoint number) is the Interrupt IN endpoint of the Ethernet controller.
    pub fn isEthInterruptEndpoint(self: *const UsbHidComposite, ep: u4) bool {
        return switch (self.hub_kind) {
            .lan7515 => ep == 3,
            else => ep == 1,
        };
    }

    pub fn handleEthBulkOut(self: *UsbHidComposite, data: []const u8) void {
        if (!self.isEthernetLinkUp()) return;
        switch (self.hub_kind) {
            .lan7515 => self.lan7800.handleBulkOut(data, &self.net),
            else => self.net.handleTxFrame(data),
        }
    }

    /// Discards frames the controller would not pass to the host (receiver off or filtered out).
    fn dropRejectedRxFrames(self: *UsbHidComposite) void {
        if (self.hub_kind != .lan7515) return;
        while (self.net.peekRxFrame()) |frame| {
            if (self.lan7800.rxEnabled() and self.lan7800.acceptsFrame(frame)) break;
            self.net.dropRxFrame();
        }
    }

    pub fn hasEthBulkIn(self: *UsbHidComposite) bool {
        if (!self.isEthernetLinkUp()) return false;
        self.dropRejectedRxFrames();
        return self.net.hasRxFrame();
    }

    pub fn popEthBulkIn(self: *UsbHidComposite, dest: []u8) ?usize {
        if (!self.isEthernetLinkUp()) return null;
        if (self.hub_kind != .lan7515) return self.net.popRxFrame(dest);

        // The LAN7800 packs as many received frames as fit into one transfer, up to its burst cap
        const limit = self.lan7800.bulkInLimit(dest.len);
        var len: usize = 0;
        while (true) {
            self.dropRejectedRxFrames();
            const frame = self.net.peekRxFrame() orelse break;
            if (len + Lan7800.rxRecordLen(len, frame.len) > limit) break;
            len = self.lan7800.encodeRxFrame(frame, dest, len);
            self.net.dropRxFrame();
        }
        return if (len == 0) null else len;
    }

    /// Injects a Linux evdev key press/release (from Wayland wl_keyboard.key) into the USB HID keyboard queue.
    pub fn handleEvdevKey(self: *UsbHidComposite, evdev_key: u32, pressed: bool) void {
        if (!self.isHubPresent() or !self.keyboard_connected) return;
        if (evdevToModifierBit(evdev_key)) |mod_bit| {
            const prev = self.kbd_state[0];
            if (pressed) {
                self.kbd_state[0] |= mod_bit;
            } else {
                self.kbd_state[0] &= ~mod_bit;
            }
            if (self.kbd_state[0] != prev) {
                self.enqueueKbdReport(self.kbd_state);
            }
            return;
        }

        const usage = evdevToHidUsage(evdev_key);
        if (usage == 0) return;

        var changed = false;
        if (pressed) {
            for (self.kbd_state[2..8]) |k| {
                if (k == usage) return;
            }
            for (self.kbd_state[2..8]) |*k| {
                if (k.* == 0) {
                    k.* = usage;
                    changed = true;
                    break;
                }
            }
        } else {
            for (self.kbd_state[2..8]) |*k| {
                if (k.* == usage) {
                    k.* = 0;
                    changed = true;
                }
            }
        }
        if (changed) {
            self.enqueueKbdReport(self.kbd_state);
        }
    }

    /// Releases any currently held keys or modifiers in the USB HID keyboard state.
    pub fn releaseAllKeys(self: *UsbHidComposite) void {
        var any_held = false;
        for (self.kbd_state) |b| {
            if (b != 0) {
                any_held = true;
                break;
            }
        }
        if (!any_held) return;
        self.kbd_state = @splat(0);
        if (self.isHubPresent() and self.keyboard_connected) {
            self.enqueueKbdReport(self.kbd_state);
        }
    }

    pub fn enqueueKbdReport(self: *UsbHidComposite, report: [8]u8) void {
        if (self.kbd_count < 16) {
            self.kbd_queue[self.kbd_tail] = report;
            self.kbd_tail +%= 1;
            self.kbd_count += 1;
        }
    }

    pub fn popKbdReport(self: *UsbHidComposite) ?[8]u8 {
        if (!self.isHubPresent() or !self.keyboard_connected) return null;
        if (self.kbd_count == 0) return null;
        const r = self.kbd_queue[self.kbd_head];
        self.kbd_head +%= 1;
        self.kbd_count -= 1;
        return r;
    }

    /// Sets the desired HDMI display pixel coordinate `(x, y)` for the simulated cursor.
    pub fn setMouseTarget(self: *UsbHidComposite, x: i32, y: i32) void {
        if (!self.isHubPresent() or !self.mouse_connected) return;
        self.target_x = x;
        self.target_y = y;
        self.has_target = true;
    }

    /// Anchors `guest_x` and `guest_y` to the actual HVS cursor plane hotspot on vblank.
    pub fn syncCursorFeedback(self: *UsbHidComposite, actual: ?[2]i32) void {
        if (self.idle_vblanks < 255) {
            self.idle_vblanks += 1;
        }
        if (actual) |pos| {
            if (!self.cursor_seen) {
                self.cursor_seen = true;
                self.guest_x = pos[0];
                self.guest_y = pos[1];
            } else if (self.idle_vblanks >= 4) {
                self.guest_x = pos[0];
                self.guest_y = pos[1];
                self.has_target = false;
            }
        }
    }

    pub fn handleMouseMotion(self: *UsbHidComposite, dx: i8, dy: i8, wheel: i8) void {
        if (!self.isHubPresent() or !self.mouse_connected) return;
        if (dx == 0 and dy == 0 and wheel == 0) return;
        self.enqueueMouseReport(.{
            self.mouse_buttons,
            @bitCast(dx),
            @bitCast(dy),
            @bitCast(wheel),
        });
    }

    pub fn handleMouseButton(self: *UsbHidComposite, button_bit: u8, pressed: bool) void {
        if (!self.isHubPresent() or !self.mouse_connected) return;
        if (pressed) {
            self.mouse_buttons |= button_bit;
        } else {
            self.mouse_buttons &= ~button_bit;
        }
        self.enqueueMouseReport(.{
            self.mouse_buttons,
            0,
            0,
            0,
        });
    }

    pub fn enqueueMouseReport(self: *UsbHidComposite, report: [4]u8) void {
        if (self.mouse_count < 32) {
            self.mouse_queue[self.mouse_tail] = report;
            self.mouse_tail +%= 1;
            self.mouse_count += 1;
        }
    }

    pub fn popMouseReport(self: *UsbHidComposite) ?[4]u8 {
        if (!self.isHubPresent() or !self.mouse_connected) return null;
        if (self.has_target) {
            const dx_i32 = std.math.clamp(self.target_x - self.guest_x, -127, 127);
            const dy_i32 = std.math.clamp(self.target_y - self.guest_y, -127, 127);
            if (dx_i32 != 0 or dy_i32 != 0) {
                const dx: i8 = @intCast(dx_i32);
                const dy: i8 = @intCast(dy_i32);
                self.guest_x += dx_i32;
                self.guest_y += dy_i32;
                self.idle_vblanks = 0;
                return .{
                    self.reported_buttons,
                    @bitCast(dx),
                    @bitCast(dy),
                    0,
                };
            }
        }
        if (self.mouse_count == 0) return null;
        const r = self.mouse_queue[self.mouse_head];
        self.mouse_head +%= 1;
        self.mouse_count -= 1;
        self.reported_buttons = r[0];
        self.guest_x += @as(i8, @bitCast(r[1]));
        self.guest_y += @as(i8, @bitCast(r[2]));
        return r;
    }

    /// Processes an 8-byte USB SETUP packet on `active_zero_target`.
    pub fn handleSetup(self: *UsbHidComposite, setup: [8]u8) bool {
        return self.handleTargetSetup(self.active_zero_target, setup);
    }

    /// Reads control data from `active_zero_target`.
    pub fn readControlData(self: *UsbHidComposite, dest: []u8) usize {
        return self.readTargetControlData(self.active_zero_target, dest);
    }

    pub fn readTargetControlData(self: *UsbHidComposite, target: TargetDevice, dest: []u8) usize {
        var cs = &self.ctrl[@intFromEnum(target)];
        if (cs.pos >= cs.len) return 0;
        const avail = cs.len - cs.pos;
        const n = @min(avail, dest.len);
        @memcpy(dest[0..n], cs.buf[cs.pos .. cs.pos + n]);
        cs.pos += n;
        return n;
    }

    /// Delivers the DATA OUT stage of a host-to-device control request to `target`.
    pub fn writeTargetControlData(self: *UsbHidComposite, target: TargetDevice, data: []const u8) void {
        var cs = &self.ctrl[@intFromEnum(target)];
        const setup = cs.out_setup orelse return;
        const wLength: usize = std.mem.readInt(u16, setup[6..8], .little);
        const n = @min(data.len, @min(wLength, cs.buf.len) - cs.len);
        @memcpy(cs.buf[cs.len .. cs.len + n], data[0..n]);
        cs.len += n;
        if (cs.len < @min(wLength, cs.buf.len)) return;
        cs.out_setup = null;
        switch (target) {
            .eth => self.completeEthOutRequest(setup, cs.buf[0..cs.len]),
            else => {},
        }
        cs.len = 0;
    }

    /// Processes an 8-byte USB SETUP packet for a specific `target` device. Returns true if ACKed, false if STALLed.
    pub fn handleTargetSetup(self: *UsbHidComposite, target: TargetDevice, setup: [8]u8) bool {
        var cs = &self.ctrl[@intFromEnum(target)];
        cs.len = 0;
        cs.pos = 0;
        cs.out_setup = null;

        const ok = switch (target) {
            .hub => self.handleHubSetup(cs, setup),
            .eth => self.handleEthSetup(cs, setup),
            .kbd => self.handleHidSetup(cs, setup, false),
            .mouse => self.handleHidSetup(cs, setup, true),
        };
        cs.last_setup_ok = ok;
        return ok;
    }

    fn handleHubSetup(self: *UsbHidComposite, cs: *ControlState, setup: [8]u8) bool {
        const bmRequestType = setup[0];
        const bRequest = setup[1];
        const wValue = std.mem.readInt(u16, setup[2..4], .little);
        const wIndex = std.mem.readInt(u16, setup[4..6], .little);
        const wLength = std.mem.readInt(u16, setup[6..8], .little);

        const req_type = (bmRequestType >> 5) & 3;
        const recipient = bmRequestType & 0x1f;

        if (req_type == 0) { // Standard request
            switch (bRequest) {
                0x00 => { // GET_STATUS
                    cs.buf[0] = if (recipient == 0) 1 else 0; // Self-powered
                    cs.buf[1] = 0;
                    cs.len = @min(@as(usize, wLength), 2);
                    return true;
                },
                0x01, 0x03 => return true, // CLEAR_FEATURE / SET_FEATURE
                0x05 => { // SET_ADDRESS
                    self.hub_addr = @truncate(wValue & 0x7f);
                    return true;
                },
                0x06 => { // GET_DESCRIPTOR
                    const desc_type: u8 = @truncate(wValue >> 8);
                    const desc_idx: u8 = @truncate(wValue & 0xff);
                    return self.prepareHubDescriptor(cs, desc_type, desc_idx, wLength);
                },
                0x08 => { // GET_CONFIGURATION
                    cs.buf[0] = if (self.hub_configured) 1 else 0;
                    cs.len = @min(@as(usize, wLength), 1);
                    return true;
                },
                0x09 => { // SET_CONFIGURATION
                    self.hub_configured = (wValue & 0xff) != 0;
                    return true;
                },
                0x0a => { // GET_INTERFACE
                    cs.buf[0] = 0;
                    cs.len = @min(@as(usize, wLength), 1);
                    return true;
                },
                0x0b => return true, // SET_INTERFACE
                else => return false,
            }
        } else if (req_type == 1) { // Hub Class request
            const num_ports = self.hub_kind.numPorts();
            switch (bRequest) {
                0x00 => { // GET_STATUS (Hub status or Port status)
                    if (recipient == 0) {
                        // GetHubStatus: 4 bytes (wHubStatus = 0, wHubChange = 0)
                        @memset(cs.buf[0..4], 0);
                        cs.len = @min(@as(usize, wLength), 4);
                        return true;
                    } else if (recipient == 3) {
                        // GetPortStatus: wIndex = 1-based port number
                        self.syncHubPortConnections();
                        const port1: u8 = @truncate(wIndex & 0xff);
                        if (port1 < 1 or port1 > num_ports) return false;
                        const p: usize = port1 - 1;
                        std.mem.writeInt(u16, cs.buf[0..2], self.port_status[p], .little);
                        std.mem.writeInt(u16, cs.buf[2..4], self.port_change[p], .little);
                        cs.len = @min(@as(usize, wLength), 4);
                        return true;
                    }
                },
                0x01 => { // CLEAR_FEATURE (ClearHubFeature or ClearPortFeature)
                    if (recipient == 0) return true;
                    if (recipient == 3) {
                        const port1: u8 = @truncate(wIndex & 0xff);
                        if (port1 < 1 or port1 > num_ports) return false;
                        const p: usize = port1 - 1;
                        switch (wValue) {
                            1 => self.port_status[p] &= ~PORT_STAT_ENABLE, // PORT_ENABLE
                            2 => { // PORT_SUSPEND
                                self.port_status[p] &= ~PORT_STAT_SUSPEND;
                                self.port_change[p] |= PORT_CHANGE_SUSPEND;
                            },
                            8 => { // PORT_POWER
                                self.port_status[p] = 0;
                                self.port_change[p] = 0;
                                self.latched_port_conn[p] = false;
                            },
                            16 => self.port_change[p] &= ~PORT_CHANGE_CONNECTION, // C_PORT_CONNECTION
                            17 => self.port_change[p] &= ~PORT_CHANGE_ENABLE, // C_PORT_ENABLE
                            18 => self.port_change[p] &= ~PORT_CHANGE_SUSPEND, // C_PORT_SUSPEND
                            19 => self.port_change[p] &= ~PORT_CHANGE_OVER_CURRENT, // C_PORT_OVER_CURRENT
                            20 => self.port_change[p] &= ~PORT_CHANGE_RESET, // C_PORT_RESET
                            else => {},
                        }
                        return true;
                    }
                },
                0x03 => { // SET_FEATURE (SetHubFeature or SetPortFeature)
                    if (recipient == 0) return true;
                    if (recipient == 3) {
                        const port1: u8 = @truncate(wIndex & 0xff);
                        if (port1 < 1 or port1 > num_ports) return false;
                        const p: usize = port1 - 1;
                        switch (wValue) {
                            2 => self.port_status[p] |= PORT_STAT_SUSPEND, // PORT_SUSPEND
                            4 => { // PORT_RESET
                                switch (p) {
                                    0 => {
                                        self.resetEthDevice();
                                        self.active_zero_target = .eth;
                                    },
                                    1 => {
                                        self.resetKbdDevice();
                                        self.active_zero_target = .kbd;
                                    },
                                    2 => {
                                        self.resetMouseDevice();
                                        self.active_zero_target = .mouse;
                                    },
                                    else => {},
                                }
                                if (self.isPortDeviceConnected(p)) {
                                    self.port_status[p] |= PORT_STAT_CONNECTION | PORT_STAT_ENABLE | PORT_STAT_POWER | if (p == 0) PORT_STAT_HIGH_SPEED else 0;
                                    self.port_status[p] &= ~PORT_STAT_RESET;
                                    self.port_change[p] |= PORT_CHANGE_RESET;
                                    self.latched_port_conn[p] = true;
                                } else {
                                    self.port_status[p] &= ~(PORT_STAT_CONNECTION | PORT_STAT_ENABLE | PORT_STAT_RESET);
                                }
                            },
                            8 => { // PORT_POWER
                                self.port_status[p] |= PORT_STAT_POWER;
                                const conn = self.isPortDeviceConnected(p);
                                if (conn) {
                                    if ((self.port_status[p] & PORT_STAT_CONNECTION) == 0) {
                                        self.port_status[p] |= PORT_STAT_CONNECTION | if (p == 0) PORT_STAT_HIGH_SPEED else 0;
                                        self.port_change[p] |= PORT_CHANGE_CONNECTION;
                                    }
                                }
                                self.latched_port_conn[p] = conn;
                            },
                            else => {},
                        }
                        return true;
                    }
                },
                0x06 => { // GetHubDescriptor (0x29 = USB_DT_HUB, or 0x00)
                    const desc_type: u8 = @truncate(wValue >> 8);
                    if (desc_type == 0x29 or desc_type == 0x00) {
                        return self.writeHubClassDescriptor(cs, wLength);
                    }
                    return false;
                },
                0x08, 0x09, 0x0a, 0x0b => return true, // ClearTTBuffer / ResetTT / GetTTState / StopTT
                else => return false,
            }
        }
        return false;
    }

    fn writeHubClassDescriptor(self: *const UsbHidComposite, cs: *ControlState, wLength: u16) bool {
        // 9-byte USB 2.0 Hub Descriptor (USB_DT_HUB = 0x29)
        // wHubCharacteristics:
        //   bits 1:0 = 01 (individual port power switching)
        //   bit  2   = 1 if compound device (built-in RPi hub with soldered Ethernet), 0 if standalone
        //   bits 4:3 = 01 (individual port over-current protection)
        const hub_chars: u16 = if (self.hub_kind.isBuiltIn()) 0x000d else 0x0009;
        // DeviceRemovable bitmask (bit N = Port N is non-removable):
        // On built-in hubs (LAN9512/LAN9514/LAN7515), Port 1 (bit 1 = 0x02) is the built-in Ethernet
        // controller ("fixed" / "Part of the board"), while Ports 2..5 (bits 2..5 = 0) are removable USB-A ports!
        const dev_removable: u8 = if (self.hub_kind.isBuiltIn()) 0x02 else 0x00;
        const desc = [9]u8{
            9, // bDescLength
            0x29, // bDescriptorType (USB_DT_HUB)
            self.hub_kind.numPorts(), // bNbrPorts
            @truncate(hub_chars),
            @truncate(hub_chars >> 8),
            50, // bPwrOn2PwrGood (100ms)
            100, // bHubContrCurrent (100mA)
            dev_removable, // DeviceRemovable (Port 1..7 bitmask)
            0xff, // PortPwrCtrlMask
        };
        @memcpy(cs.buf[0..desc.len], &desc);
        cs.len = @min(@as(usize, wLength), desc.len);
        return true;
    }

    fn prepareHubDescriptor(self: *const UsbHidComposite, cs: *ControlState, desc_type: u8, desc_idx: u8, wLength: u16) bool {
        switch (desc_type) {
            0x01 => { // DEVICE descriptor
                const vid = self.hub_kind.hubVendorId();
                const pid = self.hub_kind.hubProductId();
                const bcd = self.hub_kind.hubBcdDevice();
                const has_strings = !self.hub_kind.isBuiltIn();
                const desc = [18]u8{
                    18, // bLength
                    0x01, // bDescriptorType (Device)
                    0x00, 0x02, // bcdUSB 2.00
                    0x09, // bDeviceClass (USB_CLASS_HUB)
                    0x00, // bDeviceSubClass
                    0x01, // bDeviceProtocol (Single TT High-Speed Hub)
                    64, // bMaxPacketSize0
                    @truncate(vid),
                    @truncate(vid >> 8),
                    @truncate(pid),
                    @truncate(pid >> 8),
                    @truncate(bcd),
                    @truncate(bcd >> 8),
                    if (has_strings) 1 else 0, // iManufacturer
                    if (has_strings) 2 else 0, // iProduct
                    0, // iSerialNumber
                    1, // bNumConfigurations
                };
                @memcpy(cs.buf[0..desc.len], &desc);
                cs.len = @min(@as(usize, wLength), desc.len);
                return true;
            },
            0x02 => { // CONFIGURATION descriptor
                @memcpy(cs.buf[0..HUB_CONFIG_DESC.len], &HUB_CONFIG_DESC);
                cs.len = @min(@as(usize, wLength), HUB_CONFIG_DESC.len);
                return true;
            },
            0x03 => { // STRING descriptor
                switch (desc_idx) {
                    0 => return writeLangId(cs, wLength),
                    1 => return writeUtf16ToBuf(cs, "FauxPi", wLength),
                    2 => return writeUtf16ToBuf(cs, "USB 2.0 Hub", wLength),
                    else => return false,
                }
            },
            0x29 => return self.writeHubClassDescriptor(cs, wLength),
            else => return false,
        }
    }

    fn handleEthSetup(self: *UsbHidComposite, cs: *ControlState, setup: [8]u8) bool {
        const bmRequestType = setup[0];
        const bRequest = setup[1];
        const wValue = std.mem.readInt(u16, setup[2..4], .little);
        const wIndex = std.mem.readInt(u16, setup[4..6], .little);
        const wLength = std.mem.readInt(u16, setup[6..8], .little);

        const req_type = (bmRequestType >> 5) & 3;
        const recipient = bmRequestType & 0x1f;

        if (req_type == 0) { // Standard request
            switch (bRequest) {
                0x00 => { // GET_STATUS
                    cs.buf[0] = 0;
                    cs.buf[1] = 0;
                    cs.len = @min(@as(usize, wLength), 2);
                    return true;
                },
                0x01, 0x03 => return true, // CLEAR_FEATURE / SET_FEATURE
                0x05 => { // SET_ADDRESS
                    self.eth_addr = @truncate(wValue & 0x7f);
                    return true;
                },
                0x06 => { // GET_DESCRIPTOR
                    const desc_type: u8 = @truncate(wValue >> 8);
                    const desc_idx: u8 = @truncate(wValue & 0xff);
                    return self.prepareEthDescriptor(cs, desc_type, desc_idx, wLength);
                },
                0x08 => { // GET_CONFIGURATION
                    cs.buf[0] = if (self.eth_configured) 1 else 0;
                    cs.len = @min(@as(usize, wLength), 1);
                    return true;
                },
                0x09 => { // SET_CONFIGURATION
                    self.eth_configured = (wValue & 0xff) != 0;
                    self.reported_link_up = null;
                    return true;
                },
                0x0a => { // GET_INTERFACE
                    if (recipient == 1) {
                        cs.buf[0] = if ((wIndex & 0xff) == 1) self.cdc_alt_setting else 0;
                        cs.len = @min(@as(usize, wLength), 1);
                        return true;
                    }
                },
                0x0b => { // SET_INTERFACE
                    if ((wIndex & 0xff) == 1) {
                        self.cdc_alt_setting = @truncate(wValue & 0xff);
                        self.reported_link_up = null;
                    }
                    return true;
                },
                else => {},
            }
        } else if (req_type == 1 and self.hub_kind != .lan7515) { // CDC Class request
            if (bRequest == 0x43) { // USB_CDC_SET_ETHERNET_PACKET_FILTER
                self.cdc_packet_filter = wValue;
                self.reported_link_up = null;
            }
            return true;
        } else if (req_type == 2 and self.hub_kind == .lan7515 and recipient == 0) { // LAN7800 vendor request
            const out = (bmRequestType & 0x80) == 0;
            switch (bRequest) {
                Lan7800.VENDOR_REQUEST_WRITE_REGISTER => {
                    if (!out or wLength != 4) return false;
                    cs.out_setup = setup;
                    return true;
                },
                Lan7800.VENDOR_REQUEST_READ_REGISTER => {
                    if (out) return false;
                    const value = self.lan7800.readRegister(wIndex, self.isEthernetLinkUp());
                    std.mem.writeInt(u32, cs.buf[0..4], value, .little);
                    cs.len = @min(@as(usize, wLength), 4);
                    return true;
                },
                Lan7800.VENDOR_REQUEST_GET_STATS => {
                    if (out) return false;
                    cs.len = self.lan7800.readStats(cs.buf[0..@min(@as(usize, wLength), cs.buf.len)]);
                    return true;
                },
                else => {},
            }
        }
        return false;
    }

    fn completeEthOutRequest(self: *UsbHidComposite, setup: [8]u8, data: []const u8) void {
        const wIndex = std.mem.readInt(u16, setup[4..6], .little);
        if (self.hub_kind == .lan7515 and setup[1] == Lan7800.VENDOR_REQUEST_WRITE_REGISTER and data.len == 4) {
            self.lan7800.writeRegister(wIndex, std.mem.readInt(u32, data[0..4], .little), self.isEthernetLinkUp());
        }
    }

    fn prepareEthDescriptor(self: *const UsbHidComposite, cs: *ControlState, desc_type: u8, desc_idx: u8, wLength: u16) bool {
        switch (desc_type) {
            0x01 => { // DEVICE descriptor
                const vid = self.hub_kind.ethVendorId();
                const pid = self.hub_kind.ethProductId();
                const bcd = self.hub_kind.ethBcdDevice();
                const has_strings = !self.hub_kind.isBuiltIn();
                const vendor = self.hub_kind == .lan7515;
                const desc = [18]u8{
                    18, // bLength
                    0x01, // bDescriptorType (Device)
                    if (vendor) 0x10 else 0x00, 0x02, // bcdUSB 2.10 (USB 3.0 device at High-Speed) or 2.00
                    if (vendor) 0xff else 0x00, // bDeviceClass (vendor-specific, or per-interface: Interface 0 is 0x02 CDC Control)
                    0x00, // bDeviceSubClass
                    if (vendor) 0xff else 0x00, // bDeviceProtocol
                    64, // bMaxPacketSize0
                    @truncate(vid),
                    @truncate(vid >> 8),
                    @truncate(pid),
                    @truncate(pid >> 8),
                    @truncate(bcd),
                    @truncate(bcd >> 8),
                    if (has_strings) 1 else 0, // iManufacturer
                    if (has_strings) 2 else 0, // iProduct
                    if (has_strings) 3 else 0, // iSerialNumber
                    1, // bNumConfigurations
                };
                @memcpy(cs.buf[0..desc.len], &desc);
                cs.len = @min(@as(usize, wLength), desc.len);
                return true;
            },
            0x02 => { // CONFIGURATION descriptor
                const desc: []const u8 = if (self.hub_kind == .lan7515) &LAN7800_CONFIG_DESC else &ETH_CONFIG_DESC;
                @memcpy(cs.buf[0..desc.len], desc);
                cs.len = @min(@as(usize, wLength), desc.len);
                return true;
            },
            0x0f => { // BOS descriptor (USB 2.1 and later)
                if (self.hub_kind != .lan7515) return false;
                @memcpy(cs.buf[0..LAN7800_BOS_DESC.len], &LAN7800_BOS_DESC);
                cs.len = @min(@as(usize, wLength), LAN7800_BOS_DESC.len);
                return true;
            },
            0x03 => { // STRING descriptor
                switch (desc_idx) {
                    0 => return writeLangId(cs, wLength),
                    1 => return writeUtf16ToBuf(cs, "FauxPi", wLength),
                    2 => return writeUtf16ToBuf(cs, "USB Ethernet", wLength),
                    3 => return writeUtf16ToBuf(cs, "0003", wLength),
                    4 => {
                        var mac_str_buf: [12]u8 = undefined;
                        const m = self.net.guest_mac;
                        const mac_str = std.fmt.bufPrint(
                            &mac_str_buf,
                            "{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}",
                            .{ m[0], m[1], m[2], m[3], m[4], m[5] },
                        ) catch "B827EB123456";
                        return writeUtf16ToBuf(cs, mac_str, wLength);
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    fn handleHidSetup(self: *UsbHidComposite, cs: *ControlState, setup: [8]u8, is_mouse: bool) bool {
        const bmRequestType = setup[0];
        const bRequest = setup[1];
        const wValue = std.mem.readInt(u16, setup[2..4], .little);
        const wLength = std.mem.readInt(u16, setup[6..8], .little);

        const req_type = (bmRequestType >> 5) & 3;
        const recipient = bmRequestType & 0x1f;

        if (req_type == 0) { // Standard request
            switch (bRequest) {
                0x00 => { // GET_STATUS
                    cs.buf[0] = 0;
                    cs.buf[1] = 0;
                    cs.len = @min(@as(usize, wLength), 2);
                    return true;
                },
                0x01, 0x03 => return true, // CLEAR_FEATURE / SET_FEATURE
                0x05 => { // SET_ADDRESS
                    const addr: u7 = @truncate(wValue & 0x7f);
                    if (is_mouse) {
                        self.mouse_addr = addr;
                    } else {
                        self.kbd_addr = addr;
                    }
                    return true;
                },
                0x06 => { // GET_DESCRIPTOR
                    const desc_type: u8 = @truncate(wValue >> 8);
                    const desc_idx: u8 = @truncate(wValue & 0xff);
                    return prepareHidDescriptor(cs, desc_type, desc_idx, wLength, is_mouse);
                },
                0x08 => { // GET_CONFIGURATION
                    const cfg = if (is_mouse) self.mouse_configured else self.kbd_configured;
                    cs.buf[0] = if (cfg) 1 else 0;
                    cs.len = @min(@as(usize, wLength), 1);
                    return true;
                },
                0x09 => { // SET_CONFIGURATION
                    const cfg = (wValue & 0xff) != 0;
                    if (is_mouse) {
                        self.mouse_configured = cfg;
                    } else {
                        self.kbd_configured = cfg;
                    }
                    return true;
                },
                0x0a => { // GET_INTERFACE
                    if (recipient == 1) {
                        cs.buf[0] = 0;
                        cs.len = @min(@as(usize, wLength), 1);
                        return true;
                    }
                },
                0x0b => return true, // SET_INTERFACE
                else => {},
            }
        } else if (req_type == 1) { // HID Class request
            switch (bRequest) {
                0x01 => { // GET_REPORT
                    if (!is_mouse) {
                        @memcpy(cs.buf[0..8], &self.kbd_state);
                        cs.len = @min(@as(usize, wLength), 8);
                    } else {
                        cs.buf[0] = self.mouse_buttons;
                        cs.buf[1] = 0;
                        cs.buf[2] = 0;
                        cs.buf[3] = 0;
                        cs.len = @min(@as(usize, wLength), 4);
                    }
                    return true;
                },
                0x02 => { // GET_IDLE
                    cs.buf[0] = if (is_mouse) self.mouse_idle_rate else self.kbd_idle_rate;
                    cs.len = @min(@as(usize, wLength), 1);
                    return true;
                },
                0x03 => { // GET_PROTOCOL
                    cs.buf[0] = if (is_mouse) self.mouse_protocol else self.kbd_protocol;
                    cs.len = @min(@as(usize, wLength), 1);
                    return true;
                },
                0x09 => return true, // SET_REPORT (e.g. keyboard LEDs)
                0x0a => { // SET_IDLE
                    const rate: u8 = @truncate(wValue >> 8);
                    if (is_mouse) {
                        self.mouse_idle_rate = rate;
                    } else {
                        self.kbd_idle_rate = rate;
                    }
                    return true;
                },
                0x0b => { // SET_PROTOCOL
                    const proto: u8 = @truncate(wValue & 1);
                    if (is_mouse) {
                        self.mouse_protocol = proto;
                    } else {
                        self.kbd_protocol = proto;
                    }
                    return true;
                },
                else => {},
            }
        }
        return false;
    }

    fn prepareHidDescriptor(cs: *ControlState, desc_type: u8, desc_idx: u8, wLength: u16, is_mouse: bool) bool {
        switch (desc_type) {
            0x01 => { // DEVICE descriptor
                const desc = if (is_mouse) &MOUSE_DEVICE_DESC else &KBD_DEVICE_DESC;
                @memcpy(cs.buf[0..desc.len], desc);
                cs.len = @min(@as(usize, wLength), desc.len);
                return true;
            },
            0x02 => { // CONFIGURATION descriptor
                const desc = if (is_mouse) &MOUSE_CONFIG_DESC else &KBD_CONFIG_DESC;
                @memcpy(cs.buf[0..desc.len], desc);
                cs.len = @min(@as(usize, wLength), desc.len);
                return true;
            },
            0x03 => { // STRING descriptor
                switch (desc_idx) {
                    0 => return writeLangId(cs, wLength),
                    1 => return writeUtf16ToBuf(cs, "FauxPi", wLength),
                    2 => return writeUtf16ToBuf(cs, if (is_mouse) "USB Mouse" else "USB Keyboard", wLength),
                    3 => return writeUtf16ToBuf(cs, if (is_mouse) "0002" else "0001", wLength),
                    else => return false,
                }
            },
            0x21 => { // HID descriptor (at offset 18 inside the 34-byte config descriptor)
                const cfg = if (is_mouse) &MOUSE_CONFIG_DESC else &KBD_CONFIG_DESC;
                @memcpy(cs.buf[0..9], cfg[18..27]);
                cs.len = @min(@as(usize, wLength), 9);
                return true;
            },
            0x22 => { // HID REPORT descriptor
                if (is_mouse) {
                    @memcpy(cs.buf[0..MOUSE_REPORT_DESC.len], &MOUSE_REPORT_DESC);
                    cs.len = @min(@as(usize, wLength), MOUSE_REPORT_DESC.len);
                } else {
                    @memcpy(cs.buf[0..KBD_REPORT_DESC.len], &KBD_REPORT_DESC);
                    cs.len = @min(@as(usize, wLength), KBD_REPORT_DESC.len);
                }
                return true;
            },
            else => return false,
        }
    }

    fn writeLangId(cs: *ControlState, wLength: u16) bool {
        const lang = [_]u8{ 4, 0x03, 0x09, 0x04 };
        @memcpy(cs.buf[0..4], &lang);
        cs.len = @min(@as(usize, wLength), 4);
        return true;
    }

    fn writeUtf16ToBuf(cs: *ControlState, ascii: []const u8, wLength: u16) bool {
        const total_len: u8 = @intCast(2 + ascii.len * 2);
        cs.buf[0] = total_len;
        cs.buf[1] = 0x03;
        for (ascii, 0..) |ch, i| {
            cs.buf[2 + i * 2] = ch;
            cs.buf[2 + i * 2 + 1] = 0;
        }
        cs.len = @min(@as(usize, wLength), total_len);
        return true;
    }

    pub const HUB_CONFIG_DESC = [25]u8{
        // Configuration Descriptor (9 bytes, wTotalLength = 25, bNumInterfaces = 1, self-powered + remote wakeup)
        9, 0x02, 25, 0, 1, 1, 0, 0xe0, 1,
        // Interface 0 Descriptor: USB Hub (9 bytes)
        9, 0x04, 0, 0, 1, 0x09, 0x00, 0x00, 0,
        // Endpoint 1 IN Interrupt Descriptor: Status Change Bitmap (7 bytes, bInterval = 12 -> 256ms)
        7, 0x05, 0x81, 0x03, 1, 0, 12,
    };

    pub const ETH_CONFIG_DESC = [80]u8{
        // Configuration Descriptor (9 bytes, wTotalLength = 80, bNumInterfaces = 2)
        9, 0x02, 80, 0, 2, 1, 0, 0xa0, 50,
        // Interface 0 Descriptor: CDC Communications Control (9 bytes)
        9, 0x04, 0, 0, 1, 0x02, 0x06, 0x00, 0,
        // CDC Header Functional Descriptor (5 bytes)
        5, 0x24, 0x00, 0x10, 0x01,
        // CDC Union Functional Descriptor: Master=0, Slave=1 (5 bytes)
        5, 0x24, 0x06, 0, 1,
        // CDC Ethernet Networking Functional Descriptor: iMACAddress=4, wMaxSegmentSize=1514 (13 bytes)
        13, 0x24, 0x0f, 4, 0, 0, 0, 0, 0xea, 0x05, 0, 0, 0,
        // Endpoint 1 IN Interrupt Descriptor (7 bytes, bInterval = 11 -> 128ms)
        7, 0x05, 0x81, 0x03, 16, 0, 11,
        // Interface 1 Alternate 0: CDC Data Idle (9 bytes)
        9, 0x04, 1, 0, 0, 0x0a, 0x00, 0x00, 0,
        // Interface 1 Alternate 1: CDC Data Active (9 bytes)
        9, 0x04, 1, 1, 2, 0x0a, 0x00, 0x00, 0,
        // Endpoint 2 IN Bulk Descriptor (7 bytes, wMaxPacketSize = 512)
        7, 0x05, 0x82, 0x02, 0x00, 0x02, 0,
        // Endpoint 2 OUT Bulk Descriptor (7 bytes, wMaxPacketSize = 512)
        7, 0x05, 0x02, 0x02, 0x00, 0x02, 0,
    };

    /// Microchip LAN7800: one vendor-specific interface with Bulk IN (EP1), Bulk OUT (EP2) and
    /// Interrupt IN (EP3) endpoints.
    pub const LAN7800_CONFIG_DESC = [39]u8{
        // Configuration Descriptor (9 bytes, wTotalLength = 39, bNumInterfaces = 1, remote wakeup)
        9, 0x02, 39, 0, 1, 1, 0, 0xa0, 50,
        // Interface 0 Descriptor: vendor-specific class and protocol (9 bytes)
        9, 0x04, 0, 0, 3, 0xff, 0x00, 0xff, 0,
        // Endpoint 1 IN Bulk Descriptor (7 bytes, wMaxPacketSize = 512)
        7, 0x05, 0x81, 0x02, 0x00, 0x02, 0,
        // Endpoint 2 OUT Bulk Descriptor (7 bytes, wMaxPacketSize = 512)
        7, 0x05, 0x02, 0x02, 0x00, 0x02, 0,
        // Endpoint 3 IN Interrupt Descriptor (7 bytes, wMaxPacketSize = 16, bInterval = 4 -> 1ms)
        7, 0x05, 0x83, 0x03, 16, 0, 4,
    };

    /// LAN7800 Binary Object Store: USB 2.0 Extension (LPM) and SuperSpeed USB device capabilities.
    pub const LAN7800_BOS_DESC = [22]u8{
        // BOS Descriptor (5 bytes, wTotalLength = 22, bNumDeviceCaps = 2)
        5, 0x0f, 22, 0, 2,
        // USB 2.0 Extension: Link Power Management supported (7 bytes)
        7, 0x10, 0x02, 0x02, 0x00, 0x00, 0x00,
        // SuperSpeed USB: Full/High/SuperSpeed, functional from Full-Speed, U1 10us, U2 2047us (10 bytes)
        10, 0x10, 0x03, 0x00, 0x0e, 0x00, 0x01, 0x0a, 0xff, 0x07,
    };

    pub const KBD_DEVICE_DESC = [18]u8{
        18, // bLength
        0x01, // bDescriptorType (Device)
        0x00, 0x02, // bcdUSB 2.00
        0x00, // bDeviceClass (per-interface)
        0x00, // bDeviceSubClass
        0x00, // bDeviceProtocol
        64, // bMaxPacketSize0
        0x6b, 0x1d, // idVendor (0x1d6b)
        0x02, 0x01, // idProduct (0x0102)
        0x00, 0x01, // bcdDevice 1.00
        1, // iManufacturer ("FauxPi")
        2, // iProduct ("USB Keyboard")
        3, // iSerialNumber ("0001")
        1, // bNumConfigurations
    };

    pub const MOUSE_DEVICE_DESC = [18]u8{
        18, // bLength
        0x01, // bDescriptorType (Device)
        0x00, 0x02, // bcdUSB 2.00
        0x00, // bDeviceClass (per-interface)
        0x00, // bDeviceSubClass
        0x00, // bDeviceProtocol
        64, // bMaxPacketSize0
        0x6b, 0x1d, // idVendor (0x1d6b)
        0x03, 0x01, // idProduct (0x0103)
        0x00, 0x01, // bcdDevice 1.00
        1, // iManufacturer ("FauxPi")
        2, // iProduct ("USB Mouse")
        3, // iSerialNumber ("0002")
        1, // bNumConfigurations
    };

    pub const KBD_REPORT_DESC = [63]u8{
        0x05, 0x01, // Usage Page (Generic Desktop)
        0x09, 0x06, // Usage (Keyboard)
        0xa1, 0x01, // Collection (Application)
        0x05, 0x07, //   Usage Page (Key Codes)
        0x19, 0xe0, //   Usage Minimum (224)
        0x29, 0xe7, //   Usage Maximum (231)
        0x15, 0x00, //   Logical Minimum (0)
        0x25, 0x01, //   Logical Maximum (1)
        0x75, 0x01, //   Report Size (1)
        0x95, 0x08, //   Report Count (8)
        0x81, 0x02, //   Input (Data, Variable, Absolute) - Modifier byte
        0x95, 0x01, //   Report Count (1)
        0x75, 0x08, //   Report Size (8)
        0x81, 0x01, //   Input (Constant) - Reserved byte
        0x95, 0x05, //   Report Count (5)
        0x75, 0x01, //   Report Size (1)
        0x05, 0x08, //   Usage Page (LEDs)
        0x19, 0x01, //   Usage Minimum (1)
        0x29, 0x05, //   Usage Maximum (5)
        0x91, 0x02, //   Output (Data, Variable, Absolute) - LED report
        0x95, 0x01, //   Report Count (1)
        0x75, 0x03, //   Report Size (3)
        0x91, 0x01, //   Output (Constant) - LED padding
        0x95, 0x06, //   Report Count (6)
        0x75, 0x08, //   Report Size (8)
        0x15, 0x00, //   Logical Minimum (0)
        0x25, 0x67, //   Logical Maximum (103)
        0x05, 0x07, //   Usage Page (Key Codes)
        0x19, 0x00, //   Usage Minimum (0)
        0x29, 0x67, //   Usage Maximum (103)
        0x81, 0x00, //   Input (Data, Array) - Key arrays (6 bytes)
        0xc0, // End Collection
    };

    pub const MOUSE_REPORT_DESC = [52]u8{
        0x05, 0x01, // Usage Page (Generic Desktop)
        0x09, 0x02, // Usage (Mouse)
        0xa1, 0x01, // Collection (Application)
        0x09, 0x01, //   Usage (Pointer)
        0xa1, 0x00, //   Collection (Physical)
        0x05, 0x09, //     Usage Page (Buttons)
        0x19, 0x01, //     Usage Minimum (1)
        0x29, 0x03, //     Usage Maximum (3)
        0x15, 0x00, //     Logical Minimum (0)
        0x25, 0x01, //     Logical Maximum (1)
        0x95, 0x03, //     Report Count (3)
        0x75, 0x01, //     Report Size (1)
        0x81, 0x02, //     Input (Data, Variable, Absolute) - 3 buttons
        0x95, 0x01, //     Report Count (1)
        0x75, 0x05, //     Report Size (5)
        0x81, 0x01, //     Input (Constant) - padding
        0x05, 0x01, //     Usage Page (Generic Desktop)
        0x09, 0x30, //     Usage (X)
        0x09, 0x31, //     Usage (Y)
        0x09, 0x38, //     Usage (Wheel)
        0x15, 0x81, //     Logical Minimum (-127)
        0x25, 0x7f, //     Logical Maximum (127)
        0x75, 0x08, //     Report Size (8)
        0x95, 0x03, //     Report Count (3)
        0x81, 0x06, //     Input (Data, Variable, Relative) - X, Y, Wheel
        0xc0, //   End Collection
        0xc0, // End Collection
    };

    pub const KBD_CONFIG_DESC = [34]u8{
        // Configuration Descriptor (9 bytes, wTotalLength = 34, bNumInterfaces = 1)
        9, 0x02, 34, 0, 1, 1, 0, 0xa0, 50,
        // Interface 0 Descriptor: HID Boot Keyboard (9 bytes, offset 9)
        9, 0x04, 0, 0, 1, 0x03, 0x01, 0x01, 0,
        // HID Descriptor (9 bytes, offset 18)
        9, 0x21, 0x11, 0x01, 0, 1, 0x22, KBD_REPORT_DESC.len, 0,
        // Endpoint 1 IN Descriptor (7 bytes, offset 27, bInterval = 10 -> 10ms)
        7, 0x05, 0x81, 0x03, 8, 0, 10,
    };

    pub const MOUSE_CONFIG_DESC = [34]u8{
        // Configuration Descriptor (9 bytes, wTotalLength = 34, bNumInterfaces = 1)
        9, 0x02, 34, 0, 1, 1, 0, 0xa0, 50,
        // Interface 0 Descriptor: HID Boot Mouse (9 bytes, offset 9)
        9, 0x04, 0, 0, 1, 0x03, 0x01, 0x02, 0,
        // HID Descriptor (9 bytes, offset 18)
        9, 0x21, 0x11, 0x01, 0, 1, 0x22, MOUSE_REPORT_DESC.len, 0,
        // Endpoint 1 IN Descriptor (7 bytes, offset 27, bInterval = 10 -> 10ms)
        7, 0x05, 0x81, 0x03, 4, 0, 10,
    };

    fn evdevToModifierBit(evdev_key: u32) ?u8 {
        return switch (evdev_key) {
            29 => 1 << 0, // KEY_LEFTCTRL
            42 => 1 << 1, // KEY_LEFTSHIFT
            56 => 1 << 2, // KEY_LEFTALT
            125 => 1 << 3, // KEY_LEFTMETA
            97 => 1 << 4, // KEY_RIGHTCTRL
            54 => 1 << 5, // KEY_RIGHTSHIFT
            100 => 1 << 6, // KEY_RIGHTALT
            126 => 1 << 7, // KEY_RIGHTMETA
            else => null,
        };
    }

    fn evdevToHidUsage(evdev_key: u32) u8 {
        return switch (evdev_key) {
            1 => 0x29, // ESC
            2 => 0x1e, // 1
            3 => 0x1f, // 2
            4 => 0x20, // 3
            5 => 0x21, // 4
            6 => 0x22, // 5
            7 => 0x23, // 6
            8 => 0x24, // 7
            9 => 0x25, // 8
            10 => 0x26, // 9
            11 => 0x27, // 0
            12 => 0x2d, // -
            13 => 0x2e, // =
            14 => 0x2a, // Backspace
            15 => 0x2b, // Tab
            16 => 0x14, // Q
            17 => 0x1a, // W
            18 => 0x08, // E
            19 => 0x15, // R
            20 => 0x17, // T
            21 => 0x1c, // Y
            22 => 0x18, // U
            23 => 0x0c, // I
            24 => 0x12, // O
            25 => 0x13, // P
            26 => 0x2f, // [
            27 => 0x30, // ]
            28 => 0x28, // Enter
            30 => 0x04, // A
            31 => 0x16, // S
            32 => 0x07, // D
            33 => 0x09, // F
            34 => 0x0a, // G
            35 => 0x0b, // H
            36 => 0x0d, // J
            37 => 0x0e, // K
            38 => 0x0f, // L
            39 => 0x33, // ;
            40 => 0x34, // '
            41 => 0x35, // `
            43 => 0x31, // \
            44 => 0x1d, // Z
            45 => 0x1b, // X
            46 => 0x06, // C
            47 => 0x19, // V
            48 => 0x05, // B
            49 => 0x11, // N
            50 => 0x10, // M
            51 => 0x36, // ,
            52 => 0x37, // .
            53 => 0x38, // /
            55 => 0x55, // Keypad *
            57 => 0x2c, // Space
            58 => 0x39, // CapsLock
            59...68 => @intCast(0x3a + (evdev_key - 59)), // F1..F10
            69 => 0x53, // NumLock
            70 => 0x47, // ScrollLock
            71 => 0x5f, // Keypad 7
            72 => 0x60, // Keypad 8
            73 => 0x61, // Keypad 9
            74 => 0x56, // Keypad -
            75 => 0x5c, // Keypad 4
            76 => 0x5d, // Keypad 5
            77 => 0x5e, // Keypad 6
            78 => 0x57, // Keypad +
            79 => 0x59, // Keypad 1
            80 => 0x5a, // Keypad 2
            81 => 0x5b, // Keypad 3
            82 => 0x62, // Keypad 0
            83 => 0x63, // Keypad .
            86 => 0x64, // KEY_102ND (Non-US \ and |)
            87 => 0x44, // F11
            88 => 0x45, // F12
            96 => 0x58, // Keypad Enter
            98 => 0x54, // Keypad /
            99 => 0x46, // SysRq / PrintScreen
            102 => 0x4a, // Home
            103 => 0x52, // Up
            104 => 0x4b, // PageUp
            105 => 0x50, // Left
            106 => 0x4f, // Right
            107 => 0x4d, // End
            108 => 0x51, // Down
            109 => 0x4e, // PageDown
            110 => 0x49, // Insert
            111 => 0x4c, // Delete
            117 => 0x67, // Keypad =
            119 => 0x48, // Pause
            127 => 0x65, // Compose / Application
            else => 0,
        };
    }
};

test {
    _ = @import("lan78xx.zig");
}

test "USB HID mouse target tracking and HVS hotspot sync" {
    var hid = UsbHidComposite{};
    // Move target from default (640, 360) to (400, 300) without needing cursor_seen
    hid.setMouseTarget(400, 300);

    // Step 1: clamped to (-127, -60) -> guest at (513, 300)
    const r1 = hid.popMouseReport().?;
    try std.testing.expectEqual(@as(i8, -127), @as(i8, @bitCast(r1[1])));
    try std.testing.expectEqual(@as(i8, -60), @as(i8, @bitCast(r1[2])));

    // Step 2: remaining (-113, 0) -> guest at (400, 300)
    const r2 = hid.popMouseReport().?;
    try std.testing.expectEqual(@as(i8, -113), @as(i8, @bitCast(r2[1])));
    try std.testing.expectEqual(@as(i8, 0), @as(i8, @bitCast(r2[2])));
    try std.testing.expectEqual(@as(?[4]u8, null), hid.popMouseReport());

    // Simulate HVS cursor plane appearing at (640, 360) after guest boot:
    // syncCursorFeedback anchors guest_x/guest_y to (640, 360) so popMouseReport re-sends deltas to reach (400, 300).
    hid.syncCursorFeedback(.{ 640, 360 });
    try std.testing.expectEqual(@as(i32, 640), hid.guest_x);
    try std.testing.expectEqual(@as(i32, 360), hid.guest_y);
    const r3 = hid.popMouseReport().?;
    try std.testing.expectEqual(@as(i8, -127), @as(i8, @bitCast(r3[1])));
    try std.testing.expectEqual(@as(i8, -60), @as(i8, @bitCast(r3[2])));
}

test "USB HubKind mapping for RPi boards and separate Hub/Ethernet/Keyboard/Mouse descriptors" {
    const BoardModel = @import("../ui/board.zig").BoardModel;
    try std.testing.expectEqual(HubKind.external, BoardModel.pi_zero.hubKind());
    try std.testing.expectEqual(HubKind.external, BoardModel.pi_zero_w.hubKind());
    try std.testing.expectEqual(HubKind.external, BoardModel.pi_3_a_plus.hubKind());
    try std.testing.expectEqual(HubKind.lan9514, BoardModel.pi_1_b_plus.hubKind());
    try std.testing.expectEqual(HubKind.lan7515, BoardModel.pi_3_b_plus.hubKind());

    var hid = UsbHidComposite{};
    hid.setHubKind(.lan9514);
    hid.reset();

    // 1. Enumerate built-in LAN9514 Hub at address 0 -> assign address 2
    try std.testing.expect(hid.handleTargetSetup(.hub, .{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 18, 0x00 }));
    var dev_desc: [18]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 18), hid.readTargetControlData(.hub, &dev_desc));
    try std.testing.expectEqual(@as(u8, 0x09), dev_desc[4]); // USB_CLASS_HUB
    try std.testing.expectEqual(@as(u16, 0x0424), std.mem.readInt(u16, dev_desc[8..10], .little));
    try std.testing.expectEqual(@as(u16, 0x9514), std.mem.readInt(u16, dev_desc[10..12], .little));
    try std.testing.expectEqual(@as(u8, 0), dev_desc[14]); // no manufacturer string on real SMSC hub
    try std.testing.expectEqual(@as(u8, 0), dev_desc[15]); // no product string on real SMSC hub

    // Check Hub Class Descriptor (0x29): 5 ports, compound bit set, port 1 non-removable (0x02)
    try std.testing.expect(hid.handleTargetSetup(.hub, .{ 0xa0, 0x06, 0x00, 0x29, 0x00, 0x00, 9, 0x00 }));
    var hub_desc: [9]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 9), hid.readTargetControlData(.hub, &hub_desc));
    try std.testing.expectEqual(@as(u8, 5), hub_desc[2]); // bNbrPorts = 5
    try std.testing.expect((hub_desc[3] & 0x04) != 0); // HUB_CHAR_COMPOUND
    try std.testing.expectEqual(@as(u8, 0x02), hub_desc[7]); // DeviceRemovable: Port 1 fixed, Ports 2..5 removable
}



test "USB LAN7515 Ethernet presents a LAN7800 with vendor register access" {
    var hid = UsbHidComposite{};
    hid.setHubKind(.lan7515);
    hid.reset();

    // Device descriptor: 0424:7800, vendor-specific class, USB 2.10 with a BOS
    try std.testing.expect(hid.handleTargetSetup(.eth, .{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 18, 0x00 }));
    var dev_desc: [18]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 18), hid.readTargetControlData(.eth, &dev_desc));
    try std.testing.expectEqual(@as(u16, 0x0210), std.mem.readInt(u16, dev_desc[2..4], .little));
    try std.testing.expectEqual(@as(u8, 0xff), dev_desc[4]);
    try std.testing.expectEqual(@as(u16, 0x7800), std.mem.readInt(u16, dev_desc[10..12], .little));
    try std.testing.expect(hid.handleTargetSetup(.eth, .{ 0x80, 0x06, 0x00, 0x0f, 0x00, 0x00, 5, 0x00 }));

    // Configuration: one vendor interface with Bulk IN EP1, Bulk OUT EP2, Interrupt IN EP3
    try std.testing.expect(hid.handleTargetSetup(.eth, .{ 0x80, 0x06, 0x00, 0x02, 0x00, 0x00, 0xff, 0x00 }));
    var cfg: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 39), hid.readTargetControlData(.eth, &cfg));
    try std.testing.expectEqual(@as(u8, 0xff), cfg[9 + 5]);
    try std.testing.expectEqual(@as(u8, 0x81), cfg[18 + 2]);
    try std.testing.expectEqual(@as(u8, 0x02), cfg[25 + 2]);
    try std.testing.expectEqual(@as(u8, 0x83), cfg[32 + 2]);

    // Read ID_REV (vendor request 0xA1)
    try std.testing.expect(hid.handleTargetSetup(.eth, .{ 0xc0, 0xa1, 0x00, 0x00, 0x00, 0x00, 4, 0x00 }));
    var reg: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), hid.readTargetControlData(.eth, &reg));
    try std.testing.expectEqual(@as(u32, 0x7800), std.mem.readInt(u32, &reg, .little) >> 16);

    // Write RX_ADDRL (vendor request 0xA0 with a 4-byte DATA OUT stage), then read it back
    try std.testing.expect(hid.handleTargetSetup(.eth, .{ 0x40, 0xa0, 0x00, 0x00, 0x1c, 0x01, 4, 0x00 }));
    hid.writeTargetControlData(.eth, &.{ 0xb8, 0x27, 0xeb, 0x12 });
    try std.testing.expect(hid.handleTargetSetup(.eth, .{ 0xc0, 0xa1, 0x00, 0x00, 0x1c, 0x01, 4, 0x00 }));
    try std.testing.expectEqual(@as(usize, 4), hid.readTargetControlData(.eth, &reg));
    try std.testing.expectEqual(@as(u32, 0x12eb27b8), std.mem.readInt(u32, &reg, .little));

    // Statistics block (vendor request 0xA2)
    try std.testing.expect(hid.handleTargetSetup(.eth, .{ 0xc0, 0xa2, 0x00, 0x00, 0x00, 0x00, Lan7800.STATS_LEN, 0x00 }));
    var stats: [Lan7800.STATS_LEN]u8 = undefined;
    try std.testing.expectEqual(Lan7800.STATS_LEN, hid.readTargetControlData(.eth, &stats));

    // CDC class requests are not part of the LAN7800
    try std.testing.expect(!hid.handleTargetSetup(.eth, .{ 0x21, 0x43, 0x0e, 0x00, 0x00, 0x00, 0, 0x00 }));
}
