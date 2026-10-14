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

    pub const PM_POWUP: u32 = 1 << 0;
    pub const PM_POWOK: u32 = 1 << 1;
    pub const PM_ISPOW: u32 = 1 << 2;
    pub const PM_MEMREP: u32 = 1 << 3;
    pub const PM_MRDONE: u32 = 1 << 4;
    pub const PM_ISFUNC: u32 = 1 << 5;
    pub const PM_V3DRSTN: u32 = 1 << 6;
    pub const PM_PERIRSTN: u32 = 1 << 7;

    regs: [SIZE / 4]u32 = initRegs(),
    reboot_requested: bool = false,

    fn initRegs() [SIZE / 4]u32 {
        var r: [SIZE / 4]u32 = [_]u32{0} ** (SIZE / 4);
        const default_domain = PM_POWUP | PM_POWOK | PM_ISPOW | PM_MRDONE | PM_ISFUNC | PM_V3DRSTN | PM_PERIRSTN;
        r[PM_IMAGE / 4] = default_domain;
        r[PM_GRAFX / 4] = default_domain;
        r[PM_PROC / 4] = default_domain;
        return r;
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
                if ((v & 0x30) == 0x20) {
                    self.reboot_requested = true;
                }
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
        var r: [SIZE / 4]u32 = [_]u32{0} ** (SIZE / 4);
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
