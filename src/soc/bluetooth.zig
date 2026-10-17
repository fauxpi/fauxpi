//! Broadcom / Cypress Bluetooth controller on the HCI UART (H4) transport.
//!
//! Emulates the Bluetooth half of the onboard wireless module, wired to GPIO 30..33
//! (`uart0_pins` ALT3 for the PL011, or `uart1_bt_pins` ALT5 for the mini UART with
//! `dtoverlay=miniuart-bt`):
//! - BCM43430A1 (Pi Zero W, Pi Zero 2 W) or BCM4345C0 (Pi 3 Model A+ / B+) identity
//! - Broadcom vendor setup used by the kernel `hci_bcm` / `btbcm` drivers (verbose config,
//!   baud rate, PatchRAM firmware download, BD_ADDR)
//! - The standard HCI commands issued by the Linux Bluetooth core and BlueZ to bring up
//!   an adapter. Inquiry and LE scanning complete without finding any devices.

const std = @import("std");

pub const Chip = enum {
    bcm43430a1,
    bcm4345c0,
};

/// The board's Bluetooth address: its Wi-Fi MAC address plus one (display order, MSB first).
pub fn addressFromWifiMac(wifi_mac: [6]u8) [6]u8 {
    var addr = wifi_mac;
    addr[5] +%= 1;
    return addr;
}

/// Converts a display-order (MSB first) address to HCI / device-tree (LSB first) order.
pub fn hciOrder(addr: [6]u8) [6]u8 {
    var out = addr;
    std.mem.reverse(u8, &out);
    return out;
}

pub const Controller = struct {
    enabled: bool = false,
    chip: Chip = .bcm43430a1,
    /// BD_ADDR in HCI (least-significant byte first) order.
    bd_addr: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },

    // H4 packet reassembly (host -> controller)
    rx_buf: [260]u8 = undefined,
    rx_len: usize = 0,
    rx_skip: usize = 0,

    // Event bytes (controller -> host)
    out: [4096]u8 = undefined,
    out_head: usize = 0,
    out_len: usize = 0,

    local_name: [248]u8 = @splat(0),
    class_of_device: [3]u8 = .{ 0, 0, 0 },
    scan_enable: u8 = 0,
    page_scan_type: u8 = 0,
    ssp_mode: u8 = 0,
    le_host: u8 = 0,
    simultaneous_le_host: u8 = 0,
    default_link_policy: u16 = 0,
    random_seed: u64 = 0x2545_f491_4f6c_dd1d,

    const EVT_INQUIRY_COMPLETE: u8 = 0x01;
    const EVT_CONN_COMPLETE: u8 = 0x03;
    const EVT_CMD_COMPLETE: u8 = 0x0e;
    const EVT_CMD_STATUS: u8 = 0x0f;

    const STATUS_SUCCESS: u8 = 0x00;
    const STATUS_UNKNOWN_COMMAND: u8 = 0x01;
    const STATUS_PAGE_TIMEOUT: u8 = 0x04;

    const MANUFACTURER_BROADCOM: u16 = 15;

    /// Restores the controller to its power-on state (`HCI_Reset` / power cycle).
    pub fn reset(self: *Controller) void {
        self.local_name = @splat(0);
        self.class_of_device = .{ 0, 0, 0 };
        self.scan_enable = 0;
        self.page_scan_type = 0;
        self.ssp_mode = 0;
        self.le_host = 0;
        self.simultaneous_le_host = 0;
        self.default_link_policy = 0;
    }

    /// Accepts one byte sent by the host on the UART.
    pub fn hostWrite(self: *Controller, byte: u8) void {
        if (!self.enabled) return;
        if (self.rx_skip > 0) {
            self.rx_skip -= 1;
            return;
        }
        self.rx_buf[self.rx_len] = byte;
        self.rx_len += 1;
        switch (self.rx_buf[0]) {
            0x01 => { // HCI command: opcode(2) plen(1) params
                if (self.rx_len >= 4 and self.rx_len == 4 + @as(usize, self.rx_buf[3])) {
                    const opcode = std.mem.readInt(u16, self.rx_buf[1..3], .little);
                    self.rx_len = 0;
                    self.handleCommand(opcode, self.rx_buf[4 .. 4 + @as(usize, self.rx_buf[3])]);
                }
            },
            0x02 => { // ACL data: handle(2) len(2) data - no connections, so it is dropped
                if (self.rx_len == 5) {
                    self.rx_skip = std.mem.readInt(u16, self.rx_buf[3..5], .little);
                    self.rx_len = 0;
                }
            },
            0x03 => { // SCO data: handle(2) len(1) data
                if (self.rx_len == 4) {
                    self.rx_skip = self.rx_buf[3];
                    self.rx_len = 0;
                }
            },
            else => self.rx_len = 0, // Not a packet start; resynchronise
        }
    }

    /// Returns the next byte the controller sends to the host, if any.
    pub fn popOut(self: *Controller) ?u8 {
        if (self.out_len == 0) return null;
        const b = self.out[self.out_head];
        self.out_head = (self.out_head + 1) % self.out.len;
        self.out_len -= 1;
        return b;
    }

    pub fn hasOutput(self: *const Controller) bool {
        return self.out_len > 0;
    }

    fn pushOut(self: *Controller, bytes: []const u8) void {
        if (self.out_len + bytes.len > self.out.len) return;
        for (bytes) |b| {
            self.out[(self.out_head + self.out_len) % self.out.len] = b;
            self.out_len += 1;
        }
    }

    fn sendEvent(self: *Controller, code: u8, params: []const u8) void {
        self.pushOut(&.{ 0x04, code, @intCast(params.len) });
        self.pushOut(params);
    }

    fn sendCommandComplete(self: *Controller, opcode: u16, status: u8, ret: []const u8) void {
        var buf: [255]u8 = undefined;
        buf[0] = 1; // Num_HCI_Command_Packets
        std.mem.writeInt(u16, buf[1..3], opcode, .little);
        buf[3] = status;
        @memcpy(buf[4 .. 4 + ret.len], ret);
        self.sendEvent(EVT_CMD_COMPLETE, buf[0 .. 4 + ret.len]);
    }

    fn sendCommandStatus(self: *Controller, opcode: u16, status: u8) void {
        var buf: [4]u8 = .{ status, 1, 0, 0 };
        std.mem.writeInt(u16, buf[2..4], opcode, .little);
        self.sendEvent(EVT_CMD_STATUS, &buf);
    }

    fn lmpFeatures(self: *const Controller) [8]u8 {
        _ = self;
        // 3-slot/5-slot, encryption, sniff, RSSI with inquiry, EDR, LE + BR/EDR,
        // extended inquiry response, secure simple pairing, extended features.
        return .{ 0xbf, 0xfe, 0xcf, 0xfe, 0xdb, 0xff, 0x7b, 0x87 };
    }

    fn localVersion(self: *const Controller) [8]u8 {
        // HCI_Version, HCI_Revision, LMP_Version, Manufacturer, LMP_Subversion.
        // `btbcm` derives the PatchRAM firmware name from LMP_Subversion.
        const hci_ver: u8, const hci_rev: u16, const subver: u16 = switch (self.chip) {
            .bcm43430a1 => .{ 0x07, 0x00a8, 0x2209 }, // Bluetooth 4.1, BCM43430A1
            .bcm4345c0 => .{ 0x08, 0x0157, 0x6119 }, // Bluetooth 4.2, BCM4345C0
        };
        var v: [8]u8 = undefined;
        v[0] = hci_ver;
        std.mem.writeInt(u16, v[1..3], hci_rev, .little);
        v[3] = hci_ver;
        std.mem.writeInt(u16, v[4..6], MANUFACTURER_BROADCOM, .little);
        std.mem.writeInt(u16, v[6..8], subver, .little);
        return v;
    }

    fn nextRandom(self: *Controller) u64 {
        self.random_seed ^= self.random_seed << 13;
        self.random_seed ^= self.random_seed >> 7;
        self.random_seed ^= self.random_seed << 17;
        return self.random_seed;
    }

    fn handleCommand(self: *Controller, opcode: u16, params: []const u8) void {
        var ret: [252]u8 = @splat(0);
        const len: usize = switch (opcode) {
            // Link Control
            0x0401 => { // Inquiry: no devices in range
                self.sendCommandStatus(opcode, STATUS_SUCCESS);
                self.sendEvent(EVT_INQUIRY_COMPLETE, &.{STATUS_SUCCESS});
                return;
            },
            0x0402 => 0, // Inquiry Cancel
            0x0405 => { // Create Connection: nothing answers the page
                self.sendCommandStatus(opcode, STATUS_SUCCESS);
                var evt: [11]u8 = @splat(0);
                evt[0] = STATUS_PAGE_TIMEOUT;
                if (params.len >= 6) @memcpy(evt[3..9], params[0..6]);
                evt[9] = 0x01; // ACL
                self.sendEvent(EVT_CONN_COMPLETE, &evt);
                return;
            },
            0x0408 => blk: { // Create Connection Cancel
                if (params.len >= 6) @memcpy(ret[0..6], params[0..6]);
                break :blk 6;
            },

            // Link Policy
            0x080e => blk: { // Read Default Link Policy Settings
                std.mem.writeInt(u16, ret[0..2], self.default_link_policy, .little);
                break :blk 2;
            },
            0x080f => blk: { // Write Default Link Policy Settings
                if (params.len >= 2) self.default_link_policy = std.mem.readInt(u16, params[0..2], .little);
                break :blk 0;
            },

            // Controller & Baseband
            0x0c01, 0x0c05, 0x0c16, 0x0c18, 0x0c1c, 0x0c1e, 0x0c20, 0x0c33, 0x0c3a, 0x0c43, 0x0c45, 0x0c52, 0x0c63, 0x0c7a => 0,
            0x0c03 => blk: { // Reset
                self.reset();
                break :blk 0;
            },
            0x0c0d => 4, // Read Stored Link Key: Max_Num_Keys = 0, Num_Keys_Read = 0
            0x0c12 => 2, // Delete Stored Link Key: Num_Keys_Deleted = 0
            0x0c13 => blk: { // Write Local Name
                const n = @min(params.len, self.local_name.len);
                self.local_name = @splat(0);
                @memcpy(self.local_name[0..n], params[0..n]);
                break :blk 0;
            },
            0x0c14 => blk: { // Read Local Name
                @memcpy(ret[0..248], &self.local_name);
                break :blk 248;
            },
            0x0c19 => blk: { // Read Scan Enable
                ret[0] = self.scan_enable;
                break :blk 1;
            },
            0x0c1a => blk: { // Write Scan Enable
                if (params.len >= 1) self.scan_enable = params[0];
                break :blk 0;
            },
            0x0c1b => blk: { // Read Page Scan Activity
                std.mem.writeInt(u16, ret[0..2], 0x0800, .little);
                std.mem.writeInt(u16, ret[2..4], 0x0012, .little);
                break :blk 4;
            },
            0x0c23 => blk: { // Read Class of Device
                @memcpy(ret[0..3], &self.class_of_device);
                break :blk 3;
            },
            0x0c24 => blk: { // Write Class of Device
                if (params.len >= 3) @memcpy(&self.class_of_device, params[0..3]);
                break :blk 0;
            },
            0x0c25 => blk: { // Read Voice Setting
                std.mem.writeInt(u16, ret[0..2], 0x0060, .little);
                break :blk 2;
            },
            0x0c38 => blk: { // Read Number of Supported IAC
                ret[0] = 1;
                break :blk 1;
            },
            0x0c39 => blk: { // Read Current IAC LAP: GIAC 0x9e8b33
                ret[0] = 1;
                ret[1] = 0x33;
                ret[2] = 0x8b;
                ret[3] = 0x9e;
                break :blk 4;
            },
            0x0c46 => blk: { // Read Page Scan Type
                ret[0] = self.page_scan_type;
                break :blk 1;
            },
            0x0c47 => blk: { // Write Page Scan Type
                if (params.len >= 1) self.page_scan_type = params[0];
                break :blk 0;
            },
            0x0c55 => blk: { // Read Simple Pairing Mode
                ret[0] = self.ssp_mode;
                break :blk 1;
            },
            0x0c56 => blk: { // Write Simple Pairing Mode
                if (params.len >= 1) self.ssp_mode = params[0];
                break :blk 0;
            },
            0x0c57 => blk: { // Read Local OOB Data: C and R
                for (0..4) |i| std.mem.writeInt(u64, ret[i * 8 ..][0..8], self.nextRandom(), .little);
                break :blk 32;
            },
            0x0c58 => blk: { // Read Inquiry Response Transmit Power Level
                ret[0] = 4;
                break :blk 1;
            },
            0x0c6c => blk: { // Read LE Host Support
                ret[0] = self.le_host;
                ret[1] = self.simultaneous_le_host;
                break :blk 2;
            },
            0x0c6d => blk: { // Write LE Host Support
                if (params.len >= 2) {
                    self.le_host = params[0];
                    self.simultaneous_le_host = params[1];
                }
                break :blk 0;
            },

            // Informational
            0x1001 => blk: { // Read Local Version Information
                ret[0..8].* = self.localVersion();
                break :blk 8;
            },
            0x1002 => 64, // Read Local Supported Commands: optional commands are not advertised
            0x1003 => blk: { // Read Local Supported Features
                ret[0..8].* = self.lmpFeatures();
                break :blk 8;
            },
            0x1004 => blk: { // Read Local Extended Features
                const page: u8 = if (params.len >= 1) params[0] else 0;
                ret[0] = page;
                ret[1] = 1; // Max_Page_Number
                if (page == 0) {
                    ret[2..10].* = self.lmpFeatures();
                } else if (page == 1) {
                    // Host-supported features: SSP, LE, simultaneous LE and BR/EDR
                    ret[2] = (if (self.ssp_mode != 0) @as(u8, 0x01) else 0) |
                        (if (self.le_host != 0) @as(u8, 0x02) else 0) |
                        (if (self.simultaneous_le_host != 0) @as(u8, 0x04) else 0);
                }
                break :blk 10;
            },
            0x1005 => blk: { // Read Buffer Size: ACL 1021 x 8, SCO 64 x 1
                std.mem.writeInt(u16, ret[0..2], 1021, .little);
                ret[2] = 64;
                std.mem.writeInt(u16, ret[3..5], 8, .little);
                std.mem.writeInt(u16, ret[5..7], 1, .little);
                break :blk 7;
            },
            0x1009 => blk: { // Read BD_ADDR
                @memcpy(ret[0..6], &self.bd_addr);
                break :blk 6;
            },

            // LE Controller
            0x2001, 0x2005, 0x2006, 0x2008, 0x2009, 0x200a, 0x200b, 0x200c, 0x2010, 0x2011, 0x2012 => 0,
            0x2002 => 3, // LE Read Buffer Size: 0 -> shares the ACL buffers
            0x2003 => blk: { // LE Read Local Supported Features: LE Encryption
                ret[0] = 0x01;
                break :blk 8;
            },
            0x2007 => blk: { // LE Read Advertising Channel TX Power
                ret[0] = 8;
                break :blk 1;
            },
            0x200f => blk: { // LE Read Filter Accept List Size
                ret[0] = 8;
                break :blk 1;
            },
            0x2018 => blk: { // LE Rand
                std.mem.writeInt(u64, ret[0..8], self.nextRandom(), .little);
                break :blk 8;
            },
            0x201c => blk: { // LE Read Supported States
                ret[0..8].* = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0x03, 0x00, 0x00 };
                break :blk 8;
            },

            // Broadcom vendor commands (`btbcm` / `hci_bcm`)
            0xfc01 => blk: { // Write BD_ADDR
                if (params.len >= 6) @memcpy(&self.bd_addr, params[0..6]);
                break :blk 0;
            },
            0xfc18, 0xfc1c, 0xfc1e, 0xfc27, 0xfc45 => 0, // UART baud rate, SCO/PCM routing, sleep mode, UART clock
            0xfc2e, 0xfc4c, 0xfc4e => 0, // PatchRAM: Download Minidriver, Write RAM, Launch RAM
            0xfc6e => 8, // Read Controller Features
            0xfc79 => blk: { // Read Verbose Config Version Info: chip_id, target_id, build_base, build_num
                ret[0] = switch (self.chip) {
                    .bcm43430a1 => 0x50,
                    .bcm4345c0 => 0x60,
                };
                ret[1] = 0xff;
                std.mem.writeInt(u16, ret[2..4], 0x0000, .little);
                std.mem.writeInt(u16, ret[4..6], 0x0186, .little);
                break :blk 6;
            },

            else => {
                std.debug.print("fauxpi: bluetooth: unsupported HCI command 0x{x:0>4}\n", .{opcode});
                self.sendCommandComplete(opcode, STATUS_UNKNOWN_COMMAND, &.{});
                return;
            },
        };
        self.sendCommandComplete(opcode, STATUS_SUCCESS, ret[0..len]);
    }
};

test "Bluetooth controller answers HCI commands over H4" {
    var bt: Controller = .{ .enabled = true, .bd_addr = .{ 0x57, 0x34, 0x12, 0xeb, 0x27, 0xb8 } };

    // HCI_Reset
    for ([_]u8{ 0x01, 0x03, 0x0c, 0x00 }) |b| bt.hostWrite(b);
    var evt: [300]u8 = undefined;
    var n: usize = 0;
    while (bt.popOut()) |b| : (n += 1) evt[n] = b;
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x0e, 0x04, 0x01, 0x03, 0x0c, 0x00 }, evt[0..n]);

    // Read BD_ADDR
    for ([_]u8{ 0x01, 0x09, 0x10, 0x00 }) |b| bt.hostWrite(b);
    n = 0;
    while (bt.popOut()) |b| : (n += 1) evt[n] = b;
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x0e, 0x0a, 0x01, 0x09, 0x10, 0x00, 0x57, 0x34, 0x12, 0xeb, 0x27, 0xb8 }, evt[0..n]);

    // Read Local Version: BCM43430A1 LMP subversion
    for ([_]u8{ 0x01, 0x01, 0x10, 0x00 }) |b| bt.hostWrite(b);
    n = 0;
    while (bt.popOut()) |b| : (n += 1) evt[n] = b;
    try std.testing.expectEqual(@as(usize, 15), n);
    try std.testing.expectEqual(@as(u16, 0x2209), std.mem.readInt(u16, evt[13..15], .little));

    // ACL data is ignored, and the following command is still parsed
    for ([_]u8{ 0x02, 0x01, 0x00, 0x02, 0x00, 0xaa, 0xbb, 0x01, 0x14, 0x0c, 0x00 }) |b| bt.hostWrite(b);
    n = 0;
    while (bt.popOut()) |b| : (n += 1) evt[n] = b;
    try std.testing.expectEqual(@as(usize, 3 + 4 + 248), n);

    // Inquiry: Command Status followed by Inquiry Complete
    for ([_]u8{ 0x01, 0x01, 0x04, 0x05, 0x33, 0x8b, 0x9e, 0x08, 0x00 }) |b| bt.hostWrite(b);
    n = 0;
    while (bt.popOut()) |b| : (n += 1) evt[n] = b;
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x0f, 0x04, 0x00, 0x01, 0x01, 0x04, 0x04, 0x01, 0x01, 0x00 }, evt[0..n]);
}
