const std = @import("std");

/// BCM2835 Power Manager & Watchdog (`brcm,bcm2835-pm`, `brcm,bcm2835-pm-wdt`) at `0x20100000` (size `0x200`).
pub const PowerManager = struct {
    pub const BASE_ADDR: u32 = 0x20100000;
    pub const SIZE: u32 = 0x200;

    pub const PM_RSTC: u32 = 0x1c;
    pub const PM_RSTS: u32 = 0x20;
    pub const PM_WDOG: u32 = 0x24;
    pub const PM_IMAGE: u32 = 0x108;
    pub const PM_GRAFX: u32 = 0x10c;
    pub const PM_PROC: u32 = 0x110;

    pub const PM_RSTC_WRCFG_MASK: u32 = 0x0000_0030;
    pub const PM_RSTC_WRCFG_FULL_RESET: u32 = 0x0000_0020;
    pub const PM_RSTC_RESET: u32 = 0x0000_0102;
    pub const PM_RSTS_HADWRH_SET: u32 = 1 << 5;
    pub const PM_RSTS_RASPBERRYPI_HALT: u32 = 0x0000_0555; // Partition 63 (poweroff)
    pub const PM_WDOG_TIME_SET: u32 = 0x000f_ffff;
    pub const WDOG_HZ: u64 = 65536; // 2^16 ticks per second

    pub const PM_POWUP: u32 = 1 << 0;
    pub const PM_POWOK: u32 = 1 << 1;
    pub const PM_ISPOW: u32 = 1 << 2;
    pub const PM_MEMREP: u32 = 1 << 3;
    pub const PM_MRDONE: u32 = 1 << 4;
    pub const PM_ISFUNC: u32 = 1 << 5;
    pub const PM_V3DRSTN: u32 = 1 << 6;
    pub const PM_PERIRSTN: u32 = 1 << 7;

    regs: [SIZE / 4]u32 = initRegs(),
    wdog_rem_fp: u64 = 0,
    reboot_requested: bool = false,

    fn initRegs() [SIZE / 4]u32 {
        var r: [SIZE / 4]u32 = @splat(0);
        const default_domain = PM_POWUP | PM_POWOK | PM_ISPOW | PM_MRDONE | PM_ISFUNC | PM_V3DRSTN | PM_PERIRSTN;
        r[PM_RSTC / 4] = PM_RSTC_RESET;
        r[PM_IMAGE / 4] = default_domain;
        r[PM_GRAFX / 4] = default_domain;
        r[PM_PROC / 4] = default_domain;
        return r;
    }

    pub inline fn isWatchdogArmed(self: *const PowerManager) bool {
        return (self.regs[PM_RSTC / 4] & PM_RSTC_WRCFG_MASK) == PM_RSTC_WRCFG_FULL_RESET;
    }

    pub inline fn watchdogTicksRemaining(self: *const PowerManager) u32 {
        return self.regs[PM_WDOG / 4] & PM_WDOG_TIME_SET;
    }

    pub inline fn isPowerOffHalt(self: *const PowerManager) bool {
        return (self.regs[PM_RSTS / 4] & PM_RSTS_RASPBERRYPI_HALT) == PM_RSTS_RASPBERRYPI_HALT;
    }

    /// Advances the 65,536 Hz (`PM_WDOG`) countdown timer by `delta_us` microseconds when armed.
    /// Triggers `reboot_requested` and sets `PM_RSTS_HADWRH_SET` when the counter reaches 0.
    pub fn advance(self: *PowerManager, delta_us: u64) void {
        if (delta_us == 0 or !self.isWatchdogArmed() or self.reboot_requested) return;

        self.wdog_rem_fp +%= delta_us * WDOG_HZ;
        const ticks = self.wdog_rem_fp / 1_000_000;
        self.wdog_rem_fp %= 1_000_000;
        if (ticks == 0) return;

        const cur = self.watchdogTicksRemaining();
        if (ticks >= cur) {
            self.regs[PM_WDOG / 4] = 0;
            self.regs[PM_RSTC / 4] &= ~PM_RSTC_WRCFG_MASK;
            self.regs[PM_RSTS / 4] |= PM_RSTS_HADWRH_SET;
            self.reboot_requested = true;
        } else {
            self.regs[PM_WDOG / 4] = cur - @as(u32, @intCast(ticks));
        }
    }

    /// Returns the number of microseconds until the armed watchdog timer expires (capped at `max_us`).
    pub fn usUntilWatchdogExpire(self: *const PowerManager, max_us: u64) u64 {
        if (!self.isWatchdogArmed() or self.reboot_requested) return max_us;
        const cur: u64 = self.watchdogTicksRemaining();
        if (cur == 0) return 1;
        const fp_needed = (cur *| 1_000_000) -| self.wdog_rem_fp;
        const us_needed = @max((fp_needed + (WDOG_HZ - 1)) / WDOG_HZ, 1);
        return @min(us_needed, max_us);
    }

    pub fn read32(self: *const PowerManager, offset: u32) u32 {
        if (offset >= SIZE) return 0;
        return self.regs[offset / 4];
    }

    pub fn write32(self: *PowerManager, offset: u32, val: u32) void {
        if (offset >= SIZE) return;
        var v = val & 0x00FFFFFF; // strip 0x5a000000 password
        switch (offset) {
            PM_RSTC => {
                self.wdog_rem_fp = 0;
                if ((v & PM_RSTC_WRCFG_MASK) == PM_RSTC_WRCFG_FULL_RESET and self.watchdogTicksRemaining() == 0) {
                    self.regs[PM_RSTS / 4] |= PM_RSTS_HADWRH_SET;
                    self.reboot_requested = true;
                }
            },
            PM_WDOG => {
                v &= PM_WDOG_TIME_SET;
                self.wdog_rem_fp = 0;
            },
            PM_IMAGE, PM_GRAFX, PM_PROC => {
                if ((v & PM_POWUP) != 0) {
                    v |= PM_POWOK | PM_ISPOW;
                } else {
                    v &= ~(PM_POWOK | PM_ISPOW);
                }
                if ((v & PM_MEMREP) != 0) {
                    v |= PM_MRDONE;
                }
                v |= PM_MRDONE;
            },
            else => {},
        }
        self.regs[offset / 4] = v;
    }
};

/// BCM2835 AXI Async Bridge (`asb`) at `0x2000a000` (size `0x24`).
/// Used by `drivers/pmdomain/bcm/bcm2835-power.c` when powering up/down V3D, ISP, H264.
pub const AsbBridge = struct {
    pub const BASE_ADDR: u32 = 0x2000a000;
    pub const SIZE: u32 = 0x24;

    pub const ASB_AXI_BRDG_ID: u32 = 0x20;
    pub const BRDG_ID_VAL: u32 = 0x62726467; // "brdg"
    pub const ASB_REQ_STOP: u32 = 1 << 0;
    pub const ASB_ACK: u32 = 1 << 1;

    regs: [SIZE / 4]u32 = initRegs(),

    fn initRegs() [SIZE / 4]u32 {
        var r: [SIZE / 4]u32 = @splat(0);
        r[ASB_AXI_BRDG_ID / 4] = BRDG_ID_VAL;
        return r;
    }

    pub fn read32(self: *const AsbBridge, offset: u32) u32 {
        if (offset >= SIZE) return 0;
        if (offset == ASB_AXI_BRDG_ID) return BRDG_ID_VAL;
        return self.regs[offset / 4];
    }

    pub fn write32(self: *AsbBridge, offset: u32, val: u32) void {
        if (offset >= SIZE or offset == ASB_AXI_BRDG_ID) return;
        var v = val & 0x00FFFFFF;
        if ((v & ASB_REQ_STOP) != 0) {
            v |= ASB_ACK;
        } else {
            v &= ~ASB_ACK;
        }
        self.regs[offset / 4] = v;
    }
};

/// BCM2835 Hardware RNG (`brcm,bcm2835-rng`) at `0x20104000` (size `0x10`).
pub const Rng = struct {
    pub const BASE_ADDR: u32 = 0x20104000;
    pub const SIZE: u32 = 0x10;

    ctrl: u32 = 0,
    state: u32 = 0x9e3779b9,

    pub fn read32(self: *Rng, offset: u32) u32 {
        return switch (offset) {
            0x00 => self.ctrl,
            0x04 => (4 << 24) | 0x40000, // 4 words available, warmup count reached
            0x08 => {
                var x = self.state;
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                self.state = x;
                return x;
            },
            else => 0,
        };
    }

    pub fn write32(self: *Rng, offset: u32, val: u32) void {
        if (offset == 0x00) self.ctrl = val;
    }
};

/// BCM2835 Thermal Sensor (`brcm,bcm2835-thermal`) at `0x20212000` (size `0x08`).
pub const Thermal = struct {
    pub const BASE_ADDR: u32 = 0x20212000;
    pub const SIZE: u32 = 0x08;

    ctl: u32 = 0,

    pub fn read32(self: *const Thermal, offset: u32) u32 {
        return switch (offset) {
            0x00 => self.ctl,
            0x04 => (1 << 10) | 682, // TS_TSENSSTAT_VALID | raw ADC (407000 - 538*682 = 40.08 C)
            else => 0,
        };
    }

    pub fn write32(self: *Thermal, offset: u32, val: u32) void {
        if (offset == 0x00) self.ctl = val;
    }
};

test "BCM2835 PowerManager PM_WDOG 65536 Hz countdown, petting, disarming, and expiry" {
    var pm: PowerManager = .{};
    try std.testing.expect(!pm.isWatchdogArmed());
    try std.testing.expect(!pm.reboot_requested);

    // 1. Arm watchdog for 1 second (65536 ticks) with PM_PASSWORD (0x5a000000)
    pm.write32(PowerManager.PM_WDOG, 0x5a00_0000 | 65536);
    pm.write32(PowerManager.PM_RSTC, 0x5a00_0000 | PowerManager.PM_RSTC_WRCFG_FULL_RESET);
    try std.testing.expect(pm.isWatchdogArmed());
    try std.testing.expect(!pm.reboot_requested);
    try std.testing.expectEqual(@as(u32, 65536), pm.read32(PowerManager.PM_WDOG));
    try std.testing.expectEqual(@as(u64, 1_000_000), pm.usUntilWatchdogExpire(5_000_000));

    // 2. Advance 500 ms (500,000 us) -> 32768 ticks remaining, not expired yet
    pm.advance(500_000);
    try std.testing.expectEqual(@as(u32, 32768), pm.read32(PowerManager.PM_WDOG));
    try std.testing.expect(!pm.reboot_requested);

    // 3. Pet watchdog back to 65536 ticks and advance 500 ms -> 32768 ticks left
    pm.write32(PowerManager.PM_WDOG, 0x5a00_0000 | 65536);
    pm.advance(500_000);
    try std.testing.expectEqual(@as(u32, 32768), pm.read32(PowerManager.PM_WDOG));
    try std.testing.expect(!pm.reboot_requested);

    // 4. Disarm watchdog (PM_RSTC_RESET) and advance 1 second -> does not decrement or expire
    pm.write32(PowerManager.PM_RSTC, 0x5a00_0000 | PowerManager.PM_RSTC_RESET);
    try std.testing.expect(!pm.isWatchdogArmed());
    pm.advance(1_000_000);
    try std.testing.expectEqual(@as(u32, 32768), pm.read32(PowerManager.PM_WDOG));
    try std.testing.expect(!pm.reboot_requested);

    // 5. Re-arm and advance 500 ms -> countdown reaches 0, sets reboot_requested and PM_RSTS_HADWRH_SET
    pm.write32(PowerManager.PM_RSTC, 0x5a00_0000 | PowerManager.PM_RSTC_WRCFG_FULL_RESET);
    pm.advance(500_000);
    try std.testing.expectEqual(@as(u32, 0), pm.read32(PowerManager.PM_WDOG));
    try std.testing.expect(pm.reboot_requested);
    try std.testing.expect((pm.read32(PowerManager.PM_RSTS) & PowerManager.PM_RSTS_HADWRH_SET) != 0);
}

