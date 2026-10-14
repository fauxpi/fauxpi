const std = @import("std");

/// Virtual Composite USB HID Device (Interface 0 = Boot Keyboard on EP1 IN, Interface 1 = Boot Mouse on EP2 IN).
pub const UsbHidComposite = struct {
    address: u7 = 0,
    configured: bool = false,
    idle_rate: [2]u8 = [_]u8{ 0, 0 },
    protocol: [2]u8 = [_]u8{ 1, 1 }, // 1 = Report protocol, 0 = Boot protocol

    // Control transfer response buffer
    ctrl_buf: [256]u8 = [_]u8{0} ** 256,
    ctrl_len: usize = 0,
    ctrl_pos: usize = 0,

    // Current Keyboard state: [modifier, reserved, key0, key1, key2, key3, key4, key5]
    kbd_state: [8]u8 = [_]u8{0} ** 8,
    // Queued 8-byte keyboard reports
    kbd_queue: [16][8]u8 = undefined,
    kbd_head: u4 = 0,
    kbd_tail: u4 = 0,
    kbd_count: u5 = 0,

    // Current Mouse button mask (bit 0 = left, bit 1 = right, bit 2 = middle)
    mouse_buttons: u8 = 0,
    // Queued 4-byte mouse reports: [buttons, dx, dy, wheel]
    mouse_queue: [32][4]u8 = undefined,
    mouse_head: u5 = 0,
    mouse_tail: u5 = 0,
    mouse_count: u6 = 0,

    pub fn reset(self: *UsbHidComposite) void {
        self.address = 0;
        self.configured = false;
        self.ctrl_len = 0;
        self.ctrl_pos = 0;
    }

    /// Injects a Linux evdev key press/release (from Wayland wl_keyboard.key) into the USB HID keyboard queue.
    pub fn handleEvdevKey(self: *UsbHidComposite, evdev_key: u32, pressed: bool) void {
        if (evdevToModifierBit(evdev_key)) |mod_bit| {
            if (pressed) {
                self.kbd_state[0] |= mod_bit;
            } else {
                self.kbd_state[0] &= ~mod_bit;
            }
            self.enqueueKbdReport(self.kbd_state);
            return;
        }

        const usage = evdevToHidUsage(evdev_key);
        if (usage == 0) return;

        if (pressed) {
            // Check if already pressed
            for (self.kbd_state[2..8]) |k| {
                if (k == usage) return;
            }
            for (self.kbd_state[2..8]) |*k| {
                if (k.* == 0) {
                    k.* = usage;
                    break;
                }
            }
        } else {
            for (self.kbd_state[2..8]) |*k| {
                if (k.* == usage) {
                    k.* = 0;
                }
            }
        }
        self.enqueueKbdReport(self.kbd_state);
    }

    pub fn enqueueKbdReport(self: *UsbHidComposite, report: [8]u8) void {
        if (self.kbd_count < 16) {
            self.kbd_queue[self.kbd_tail] = report;
            self.kbd_tail +%= 1;
            self.kbd_count += 1;
        }
    }

    pub fn popKbdReport(self: *UsbHidComposite) ?[8]u8 {
        if (self.kbd_count == 0) return null;
        const r = self.kbd_queue[self.kbd_head];
        self.kbd_head +%= 1;
        self.kbd_count -= 1;
        return r;
    }

    pub fn handleMouseMotion(self: *UsbHidComposite, dx: i8, dy: i8, wheel: i8) void {
        if (dx == 0 and dy == 0 and wheel == 0) return;
        self.enqueueMouseReport(.{
            self.mouse_buttons,
            @bitCast(dx),
            @bitCast(dy),
            @bitCast(wheel),
        });
    }

    pub fn handleMouseButton(self: *UsbHidComposite, button_bit: u8, pressed: bool) void {
        if (pressed) {
            self.mouse_buttons |= button_bit;
        } else {
            self.mouse_buttons &= ~button_bit;
        }
        self.enqueueMouseReport(.{ self.mouse_buttons, 0, 0, 0 });
    }

    pub fn enqueueMouseReport(self: *UsbHidComposite, report: [4]u8) void {
        if (self.mouse_count < 32) {
            self.mouse_queue[self.mouse_tail] = report;
            self.mouse_tail +%= 1;
            self.mouse_count += 1;
        }
    }

    pub fn popMouseReport(self: *UsbHidComposite) ?[4]u8 {
        if (self.mouse_count == 0) return null;
        const r = self.mouse_queue[self.mouse_head];
        self.mouse_head +%= 1;
        self.mouse_count -= 1;
        return r;
    }

    /// Processes an 8-byte USB SETUP packet. Returns true if ACKed, false if STALLed.
    pub fn handleSetup(self: *UsbHidComposite, setup: [8]u8) bool {
        const bmRequestType = setup[0];
        const bRequest = setup[1];
        const wValue = std.mem.readInt(u16, setup[2..4], .little);
        const wIndex = std.mem.readInt(u16, setup[4..6], .little);
        const wLength = std.mem.readInt(u16, setup[6..8], .little);

        self.ctrl_len = 0;
        self.ctrl_pos = 0;

        const req_type = (bmRequestType >> 5) & 3;
        const recipient = bmRequestType & 0x1f;

        if (req_type == 0) { // Standard request
            switch (bRequest) {
                0x00 => { // GET_STATUS
                    self.ctrl_buf[0] = 0;
                    self.ctrl_buf[1] = 0;
                    self.ctrl_len = @min(@as(usize, wLength), 2);
                    return true;
                },
                0x01, 0x03 => { // CLEAR_FEATURE / SET_FEATURE
                    return true;
                },
                0x05 => { // SET_ADDRESS
                    self.address = @truncate(wValue & 0x7f);
                    return true;
                },
                0x06 => { // GET_DESCRIPTOR
                    const desc_type: u8 = @truncate(wValue >> 8);
                    const desc_idx: u8 = @truncate(wValue & 0xff);
                    return self.prepareDescriptor(desc_type, desc_idx, wIndex, wLength);
                },
                0x08 => { // GET_CONFIGURATION
                    self.ctrl_buf[0] = if (self.configured) 1 else 0;
                    self.ctrl_len = @min(@as(usize, wLength), 1);
                    return true;
                },
                0x09 => { // SET_CONFIGURATION
                    self.configured = (wValue & 0xff) != 0;
                    return true;
                },
                0x0a => { // GET_INTERFACE
                    if (recipient == 1) {
                        self.ctrl_buf[0] = 0;
                        self.ctrl_len = @min(@as(usize, wLength), 1);
                        return true;
                    }
                },
                0x0b => { // SET_INTERFACE
                    return true;
                },
                else => {},
            }
        } else if (req_type == 1) { // Class (HID) request
            const iface = wIndex & 1;
            switch (bRequest) {
                0x01 => { // GET_REPORT
                    if (iface == 0) {
                        @memcpy(self.ctrl_buf[0..8], &self.kbd_state);
                        self.ctrl_len = @min(@as(usize, wLength), 8);
                    } else {
                        self.ctrl_buf[0] = self.mouse_buttons;
                        self.ctrl_buf[1] = 0;
                        self.ctrl_buf[2] = 0;
                        self.ctrl_buf[3] = 0;
                        self.ctrl_len = @min(@as(usize, wLength), 4);
                    }
                    return true;
                },
                0x02 => { // GET_IDLE
                    self.ctrl_buf[0] = self.idle_rate[iface];
                    self.ctrl_len = @min(@as(usize, wLength), 1);
                    return true;
                },
                0x03 => { // GET_PROTOCOL
                    self.ctrl_buf[0] = self.protocol[iface];
                    self.ctrl_len = @min(@as(usize, wLength), 1);
                    return true;
                },
                0x09 => { // SET_REPORT (e.g. keyboard LEDs)
                    return true;
                },
                0x0a => { // SET_IDLE
                    self.idle_rate[iface] = @truncate(wValue >> 8);
                    return true;
                },
                0x0b => { // SET_PROTOCOL
                    self.protocol[iface] = @truncate(wValue & 1);
                    return true;
                },
                else => {},
            }
        }
        return false;
    }

    pub fn readControlData(self: *UsbHidComposite, dest: []u8) usize {
        if (self.ctrl_pos >= self.ctrl_len) return 0;
        const avail = self.ctrl_len - self.ctrl_pos;
        const n = @min(avail, dest.len);
        @memcpy(dest[0..n], self.ctrl_buf[self.ctrl_pos .. self.ctrl_pos + n]);
        self.ctrl_pos += n;
        return n;
    }

    fn prepareDescriptor(self: *UsbHidComposite, desc_type: u8, desc_idx: u8, wIndex: u16, wLength: u16) bool {
        switch (desc_type) {
            0x01 => { // DEVICE descriptor
                @memcpy(self.ctrl_buf[0..DEVICE_DESC.len], &DEVICE_DESC);
                self.ctrl_len = @min(@as(usize, wLength), DEVICE_DESC.len);
                return true;
            },
            0x02 => { // CONFIGURATION descriptor
                @memcpy(self.ctrl_buf[0..CONFIG_DESC.len], &CONFIG_DESC);
                self.ctrl_len = @min(@as(usize, wLength), CONFIG_DESC.len);
                return true;
            },
            0x03 => { // STRING descriptor
                switch (desc_idx) {
                    0 => {
                        const lang = [_]u8{ 4, 0x03, 0x09, 0x04 };
                        @memcpy(self.ctrl_buf[0..4], &lang);
                        self.ctrl_len = @min(@as(usize, wLength), 4);
                        return true;
                    },
                    1 => return self.writeUtf16String("FauxPi", wLength),
                    2 => return self.writeUtf16String("FauxPi USB Keyboard & Mouse", wLength),
                    3 => return self.writeUtf16String("0001", wLength),
                    else => return false,
                }
            },
            0x06 => { // DEVICE_QUALIFIER (return STALL for Full-Speed-only or return valid qualifier)
                return false;
            },
            0x21 => { // HID descriptor
                const offset: usize = if ((wIndex & 0xff) == 0) 18 else 43;
                @memcpy(self.ctrl_buf[0..9], CONFIG_DESC[offset .. offset + 9]);
                self.ctrl_len = @min(@as(usize, wLength), 9);
                return true;
            },
            0x22 => { // HID REPORT descriptor
                if ((wIndex & 0xff) == 0) {
                    @memcpy(self.ctrl_buf[0..KBD_REPORT_DESC.len], &KBD_REPORT_DESC);
                    self.ctrl_len = @min(@as(usize, wLength), KBD_REPORT_DESC.len);
                    return true;
                } else if ((wIndex & 0xff) == 1) {
                    @memcpy(self.ctrl_buf[0..MOUSE_REPORT_DESC.len], &MOUSE_REPORT_DESC);
                    self.ctrl_len = @min(@as(usize, wLength), MOUSE_REPORT_DESC.len);
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn writeUtf16String(self: *UsbHidComposite, ascii: []const u8, wLength: u16) bool {
        const total_len: u8 = @intCast(2 + ascii.len * 2);
        self.ctrl_buf[0] = total_len;
        self.ctrl_buf[1] = 0x03;
        for (ascii, 0..) |ch, i| {
            self.ctrl_buf[2 + i * 2] = ch;
            self.ctrl_buf[2 + i * 2 + 1] = 0;
        }
        self.ctrl_len = @min(@as(usize, wLength), total_len);
        return true;
    }

    pub const DEVICE_DESC = [18]u8{
        18, // bLength
        0x01, // bDescriptorType (Device)
        0x00, 0x02, // bcdUSB 2.00
        0x00, // bDeviceClass (per-interface)
        0x00, // bDeviceSubClass
        0x00, // bDeviceProtocol
        64, // bMaxPacketSize0
        0x6b, 0x1d, // idVendor (0x1d6b)
        0x01, 0x01, // idProduct (0x0101)
        0x00, 0x01, // bcdDevice 1.00
        1, // iManufacturer
        2, // iProduct
        3, // iSerialNumber
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
        0x25, 0x65, //   Logical Maximum (101)
        0x05, 0x07, //   Usage Page (Key Codes)
        0x19, 0x00, //   Usage Minimum (0)
        0x29, 0x65, //   Usage Maximum (101)
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

    pub const CONFIG_DESC = [59]u8{
        // Configuration Descriptor (9 bytes)
        9, 0x02, 59, 0, 2, 1, 0, 0xa0, 50,
        // Interface 0 Descriptor: HID Boot Keyboard (9 bytes, offset 9)
        9, 0x04, 0, 0, 1, 0x03, 0x01, 0x01, 0,
        // HID Descriptor 0 (9 bytes, offset 18)
        9, 0x21, 0x11, 0x01, 0, 1, 0x22, KBD_REPORT_DESC.len, 0,
        // Endpoint 1 IN Descriptor (7 bytes, offset 27)
        7, 0x05, 0x81, 0x03, 8, 0, 10,
        // Interface 1 Descriptor: HID Boot Mouse (9 bytes, offset 34)
        9, 0x04, 1, 0, 1, 0x03, 0x01, 0x02, 0,
        // HID Descriptor 1 (9 bytes, offset 43)
        9, 0x21, 0x11, 0x01, 0, 1, 0x22, MOUSE_REPORT_DESC.len, 0,
        // Endpoint 2 IN Descriptor (7 bytes, offset 52)
        7, 0x05, 0x82, 0x03, 4, 0, 10,
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
            57 => 0x2c, // Space
            58 => 0x39, // CapsLock
            59...68 => @intCast(0x3a + (evdev_key - 59)), // F1..F10
            87 => 0x44, // F11
            88 => 0x45, // F12
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
            else => 0,
        };
    }
};
