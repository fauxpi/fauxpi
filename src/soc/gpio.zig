const std = @import("std");

/// BCM2835 54-pin GPIO controller (`brcm,bcm2835-gpio`) at `0x20200000` (size `0xb4`).
pub const Gpio = struct {
    pub const BASE_ADDR: u32 = 0x20200000;
    pub const SIZE: u32 = 0xb4;

    pub const Function = enum(u3) {
        input = 0b000,
        output = 0b001,
        alt5 = 0b010,
        alt4 = 0b011,
        alt0 = 0b100,
        alt1 = 0b101,
        alt2 = 0b110,
        alt3 = 0b111,
    };

    /// Function select registers GPFSEL0..5
    gpfsel: [6]u32 = [_]u32{0} ** 6,
    /// Output levels driven by GPSET / GPCLR
    out_level: u64 = 0,
    /// External input pin levels (default: pull-ups on I2C pins 2,3; GPIO 46 = HDMI_HPD_N = 0 = active/connected)
    ext_level: u64 = (1 << 2) | (1 << 3),
    /// Mask of pins driven externally (vs driven by output register)
    ext_mask: u64 = (1 << 46),

    /// Event detect status and edge/level enables
    gpeds: u64 = 0,
    gpren: u64 = 0,
    gpfen: u64 = 0,
    gphen: u64 = 0,
    gplen: u64 = 0,
    gparen: u64 = 0,
    gpafen: u64 = 0,
    gppud: u32 = 0,
    gppudclk: [2]u32 = [_]u32{ 0, 0 },

    pub fn effectiveLevels(self: *const Gpio) u64 {
        return (self.out_level & ~self.ext_mask) | (self.ext_level & self.ext_mask);
    }

    pub fn getPinFunction(self: *const Gpio, pin: u6) Function {
        if (pin >= 54) return .input;
        const reg_idx = pin / 10;
        const shift: u5 = @intCast((pin % 10) * 3);
        return @enumFromInt(@as(u3, @truncate(self.gpfsel[reg_idx] >> shift)));
    }

    pub fn getPinLevel(self: *const Gpio, pin: u6) bool {
        if (pin >= 54) return false;
        return ((self.effectiveLevels() >> pin) & 1) != 0;
    }

    pub fn setExternalPin(self: *Gpio, pin: u6, high: bool) void {
        if (pin >= 54) return;
        const prev = self.effectiveLevels();
        const bit = @as(u64, 1) << pin;
        self.ext_mask |= bit;
        if (high) {
            self.ext_level |= bit;
        } else {
            self.ext_level &= ~bit;
        }
        self.updateEdgeEvents(prev, self.effectiveLevels());
    }

    fn updateEdgeEvents(self: *Gpio, prev: u64, curr: u64) void {
        const risen = ~prev & curr;
        const fallen = prev & ~curr;
        self.gpeds |= (risen & (self.gpren | self.gparen)) |
            (fallen & (self.gpfen | self.gpafen)) |
            (curr & self.gphen) |
            (~curr & self.gplen);
    }

    pub fn irqPending(self: *const Gpio) bool {
        return self.gpeds != 0;
    }

    pub fn read32(self: *const Gpio, offset: u32) u32 {
        const levels = self.effectiveLevels();
        return switch (offset) {
            0x00, 0x04, 0x08, 0x0c, 0x10, 0x14 => self.gpfsel[offset / 4],
            0x34 => @truncate(levels), // GPLEV0
            0x38 => @truncate(levels >> 32), // GPLEV1
            0x40 => @truncate(self.gpeds), // GPEDS0
            0x44 => @truncate(self.gpeds >> 32), // GPEDS1
            0x4c => @truncate(self.gpren), // GPREN0
            0x50 => @truncate(self.gpren >> 32), // GPREN1
            0x58 => @truncate(self.gpfen), // GPFEN0
            0x5c => @truncate(self.gpfen >> 32), // GPFEN1
            0x64 => @truncate(self.gphen), // GPHEN0
            0x68 => @truncate(self.gphen >> 32), // GPHEN1
            0x70 => @truncate(self.gplen), // GPLEN0
            0x74 => @truncate(self.gplen >> 32), // GPLEN1
            0x7c => @truncate(self.gparen), // GPAREN0
            0x80 => @truncate(self.gparen >> 32), // GPAREN1
            0x88 => @truncate(self.gpafen), // GPAFEN0
            0x8c => @truncate(self.gpafen >> 32), // GPAFEN1
            0x94 => self.gppud,
            0x98 => self.gppudclk[0],
            0x9c => self.gppudclk[1],
            else => 0,
        };
    }

    pub fn write32(self: *Gpio, offset: u32, val: u32) void {
        const prev = self.effectiveLevels();
        switch (offset) {
            0x00, 0x04, 0x08, 0x0c, 0x10, 0x14 => self.gpfsel[offset / 4] = val,
            0x1c => { // GPSET0
                self.out_level |= @as(u64, val);
                self.updateEdgeEvents(prev, self.effectiveLevels());
            },
            0x20 => { // GPSET1
                self.out_level |= (@as(u64, val & 0x3fffff) << 32);
                self.updateEdgeEvents(prev, self.effectiveLevels());
            },
            0x28 => { // GPCLR0
                self.out_level &= ~@as(u64, val);
                self.updateEdgeEvents(prev, self.effectiveLevels());
            },
            0x2c => { // GPCLR1
                self.out_level &= ~(@as(u64, val & 0x3fffff) << 32);
                self.updateEdgeEvents(prev, self.effectiveLevels());
            },
            0x40 => self.gpeds &= ~@as(u64, val), // GPEDS0 W1C
            0x44 => self.gpeds &= ~(@as(u64, val) << 32), // GPEDS1 W1C
            0x4c => self.gpren = (self.gpren & 0xFFFFFFFF00000000) | val,
            0x50 => self.gpren = (self.gpren & 0x00000000FFFFFFFF) | (@as(u64, val) << 32),
            0x58 => self.gpfen = (self.gpfen & 0xFFFFFFFF00000000) | val,
            0x5c => self.gpfen = (self.gpfen & 0x00000000FFFFFFFF) | (@as(u64, val) << 32),
            0x64 => self.gphen = (self.gphen & 0xFFFFFFFF00000000) | val,
            0x68 => self.gphen = (self.gphen & 0x00000000FFFFFFFF) | (@as(u64, val) << 32),
            0x70 => self.gplen = (self.gplen & 0xFFFFFFFF00000000) | val,
            0x74 => self.gplen = (self.gplen & 0x00000000FFFFFFFF) | (@as(u64, val) << 32),
            0x7c => self.gparen = (self.gparen & 0xFFFFFFFF00000000) | val,
            0x80 => self.gparen = (self.gparen & 0x00000000FFFFFFFF) | (@as(u64, val) << 32),
            0x88 => self.gpafen = (self.gpafen & 0xFFFFFFFF00000000) | val,
            0x8c => self.gpafen = (self.gpafen & 0x00000000FFFFFFFF) | (@as(u64, val) << 32),
            0x94 => self.gppud = val,
            0x98 => self.gppudclk[0] = val,
            0x9c => self.gppudclk[1] = val,
            else => {},
        }
    }
};

test "GPIO pin set/clear and HDMI_HPD_N pin 46" {
    var gpio = Gpio{};
    // Pin 46 (HDMI_HPD_N) is active-low (0 = connected)
    try std.testing.expect(!gpio.getPinLevel(46));

    // Set GPIO 47 (ACT LED on Pi Zero) as output and drive high
    gpio.write32(0x10, 1 << 21); // GPFSEL4 pin 47 = output (001)
    try std.testing.expectEqual(Gpio.Function.output, gpio.getPinFunction(47));
    gpio.write32(0x20, 1 << (47 - 32)); // GPSET1
    try std.testing.expect(gpio.getPinLevel(47));
    gpio.write32(0x2c, 1 << (47 - 32)); // GPCLR1
    try std.testing.expect(!gpio.getPinLevel(47));
}
