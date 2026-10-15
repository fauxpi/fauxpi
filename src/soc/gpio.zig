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

        pub fn alt(f: Function) ?u4 {
            return switch (f) {
                .input, .output => null,
                .alt0 => 0,
                .alt1 => 1,
                .alt2 => 2,
                .alt3 => 3,
                .alt4 => 4,
                .alt5 => 5,
            };
        }
    };

    pub const Mode = enum {
        input,
        input_pull_up,
        input_pull_down,
        output_low,
        output_high,

        pub fn label(m: Mode) []const u8 {
            return switch (m) {
                .input => "Input",
                .input_pull_up => "Input, pulled up",
                .input_pull_down => "Input, pulled down",
                .output_low => "Output, low",
                .output_high => "Output, high",
            };
        }
    };

    /// Default pull-ups at reset: pins 0..8, 34..36, 46..53
    pub const DEFAULT_PULL_UP_MASK: u64 = 0x1ff | (0x7 << 34) | (0xff << 46);
    /// Default no-pull pins at reset: 28..29, 44..45
    pub const DEFAULT_NO_PULL_MASK: u64 = (0x3 << 28) | (0x3 << 44);
    /// Default pull-down pins at reset: all remaining pins 0..53
    pub const DEFAULT_PULL_DOWN_MASK: u64 = ((@as(u64, 1) << 54) - 1) & ~(DEFAULT_PULL_UP_MASK | DEFAULT_NO_PULL_MASK);

    /// Function select registers GPFSEL0..5
    gpfsel: [6]u32 = [_]u32{0} ** 6,
    /// Output levels driven by GPSET / GPCLR
    out_level: u64 = 0,
    /// Pull-up and pull-down masks (initialized to BCM2835 power-on defaults)
    pull_up_mask: u64 = DEFAULT_PULL_UP_MASK,
    pull_down_mask: u64 = DEFAULT_PULL_DOWN_MASK,
    /// External hardware pin levels (GPIO 46 = HDMI_HPD_N = 0 = active/connected)
    ext_level: u64 = (1 << 2) | (1 << 3),
    /// Mask of pins driven by external hardware (GPIO 46 and BCM2837 GPIO 28 HDMI HPD)
    ext_mask: u64 = (1 << 46) | (1 << 28),

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
    act_pulse_latch: bool = false,

    pub fn effectiveLevels(self: *const Gpio) u64 {
        var out_mask: u64 = 0;
        for (0..54) |p| {
            if (self.getPinFunction(@intCast(p)) == .output) {
                out_mask |= (@as(u64, 1) << @intCast(p));
            }
        }
        const input_levels = (self.pull_up_mask & ~self.ext_mask) | (self.ext_level & self.ext_mask);
        return (self.out_level & out_mask) | (input_levels & ~out_mask);
    }

    pub fn getPinFunction(self: *const Gpio, pin: u6) Function {
        if (pin >= 54) return .input;
        const reg_idx = pin / 10;
        const shift: u5 = @intCast((pin % 10) * 3);
        return @enumFromInt(@as(u3, @truncate(self.gpfsel[reg_idx] >> shift)));
    }

    pub fn setPinFunction(self: *Gpio, pin: u6, func: Function) void {
        if (pin >= 54) return;
        const reg_idx = pin / 10;
        const shift: u5 = @intCast((pin % 10) * 3);
        self.gpfsel[reg_idx] = (self.gpfsel[reg_idx] & ~(@as(u32, 7) << shift)) | (@as(u32, @intFromEnum(func)) << shift);
    }

    pub fn getPinLevel(self: *const Gpio, pin: u6) bool {
        if (pin >= 54) return false;
        return ((self.effectiveLevels() >> pin) & 1) != 0;
    }

    /// Returns true if GPIO 48..53 (`SD_CLK_R`, `SD_CMD_R`, `SD_DATA0..3_R`) are muxed to `ALT3` (`emmc_gpio48`),
    /// routing the primary SD card slot to the Arasan SDHCI controller (`0x20300000`) instead of SDHOST (`0x20202000`).
    pub fn isSdCardOnArasanAlt3(self: *const Gpio) bool {
        // Check CLK (48) and CMD (49)
        return self.getPinFunction(48) == .alt3 and self.getPinFunction(49) == .alt3;
    }

    /// Returns true if GPIO 34..39 (`emmc_gpio34`) are muxed to `ALT3` (or have not been reassigned to another alt function),
    /// routing the onboard CYW43430 Wi-Fi SDIO bus to the Arasan SDHCI controller (`0x20300000`).
    pub fn isWifiOnArasanAlt3(self: *const Gpio) bool {
        const f34 = self.getPinFunction(34);
        const f35 = self.getPinFunction(35);
        return (f34 == .alt3 and f35 == .alt3) or (f34 == .input and f35 == .input);
    }

    pub fn getPinMode(self: *const Gpio, pin: u6) ?Mode {
        if (pin >= 54) return null;
        return switch (self.getPinFunction(pin)) {
            .output => if (self.getPinLevel(pin)) .output_high else .output_low,
            .input => blk: {
                const bit = @as(u64, 1) << pin;
                if ((self.pull_up_mask & bit) != 0) break :blk .input_pull_up;
                if ((self.pull_down_mask & bit) != 0) break :blk .input_pull_down;
                break :blk .input;
            },
            else => null,
        };
    }

    pub fn setPinMode(self: *Gpio, pin: u6, mode: Mode) void {
        if (pin >= 54) return;
        const prev = self.effectiveLevels();
        const bit = @as(u64, 1) << pin;
        switch (mode) {
            .input => {
                self.setPinFunction(pin, .input);
                self.pull_up_mask &= ~bit;
                self.pull_down_mask &= ~bit;
                self.ext_mask &= ~bit;
            },
            .input_pull_up => {
                self.setPinFunction(pin, .input);
                self.pull_up_mask |= bit;
                self.pull_down_mask &= ~bit;
                self.ext_mask &= ~bit;
            },
            .input_pull_down => {
                self.setPinFunction(pin, .input);
                self.pull_up_mask &= ~bit;
                self.pull_down_mask |= bit;
                self.ext_mask &= ~bit;
            },
            .output_low => {
                self.setPinFunction(pin, .output);
                self.out_level &= ~bit;
            },
            .output_high => {
                self.setPinFunction(pin, .output);
                self.out_level |= bit;
            },
        }
        self.updateEdgeEvents(prev, self.effectiveLevels());
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

    fn applyPullClock(self: *Gpio, clk_mask: u64) void {
        if (clk_mask == 0) return;
        switch (self.gppud & 3) {
            0 => { // Off
                self.pull_up_mask &= ~clk_mask;
                self.pull_down_mask &= ~clk_mask;
            },
            1 => { // Pull-down
                self.pull_down_mask |= clk_mask;
                self.pull_up_mask &= ~clk_mask;
            },
            2 => { // Pull-up
                self.pull_up_mask |= clk_mask;
                self.pull_down_mask &= ~clk_mask;
            },
            else => {},
        }
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
            0x00, 0x04, 0x08, 0x0c, 0x10, 0x14 => {
                self.gpfsel[offset / 4] = val;
                self.updateEdgeEvents(prev, self.effectiveLevels());
            },
            0x1c => { // GPSET0
                if ((val & (1 << 29)) != 0) self.act_pulse_latch = true;
                self.out_level |= @as(u64, val);
                self.updateEdgeEvents(prev, self.effectiveLevels());
            },
            0x20 => { // GPSET1
                if ((val & (1 << (47 - 32))) != 0) self.act_pulse_latch = true;
                self.out_level |= (@as(u64, val & 0x3fffff) << 32);
                self.updateEdgeEvents(prev, self.effectiveLevels());
            },
            0x28 => { // GPCLR0
                if ((val & (1 << 29)) != 0) self.act_pulse_latch = true;
                self.out_level &= ~@as(u64, val);
                self.updateEdgeEvents(prev, self.effectiveLevels());
            },
            0x2c => { // GPCLR1
                if ((val & (1 << (47 - 32))) != 0) self.act_pulse_latch = true;
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
            0x98 => {
                self.gppudclk[0] = val;
                self.applyPullClock(@as(u64, val));
                self.updateEdgeEvents(prev, self.effectiveLevels());
            },
            0x9c => {
                self.gppudclk[1] = val;
                self.applyPullClock(@as(u64, val & 0x3fffff) << 32);
                self.updateEdgeEvents(prev, self.effectiveLevels());
            },
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
