const std = @import("std");

/// BCM2835 Clock Manager (`brcm,bcm2835-cprman`) at `0x20101000` (size `0x2000`).
pub const Cprman = struct {
    pub const BASE_ADDR: u32 = 0x20101000;
    pub const SIZE: u32 = 0x2000;

    pub const CM_LOCK: u32 = 0x0114;
    pub const CM_BUSY: u32 = 1 << 7;

    regs: [SIZE / 4]u32 = initDefaultRegs(),

    fn initDefaultRegs() [SIZE / 4]u32 {
        var r: [SIZE / 4]u32 = [_]u32{0} ** (SIZE / 4);

        // CM_LOCK: all PLLs locked
        r[CM_LOCK / 4] = 0x0000FFFF;

        // Initialize A2W PLL control words (PDIV=1 [14:12], NDIV [9:0])
        r[0x1100 / 4] = (1 << 12) | 100; // A2W_PLLA_CTRL (~1920 MHz)
        r[0x1120 / 4] = (1 << 12) | 104; // A2W_PLLC_CTRL (~1996.8 MHz)
        r[0x1140 / 4] = (1 << 12) | 104; // A2W_PLLD_CTRL (~1996.8 MHz)
        r[0x1160 / 4] = (1 << 12) | 45; // A2W_PLLH_CTRL (~864 MHz)
        r[0x11e0 / 4] = (1 << 12) | 52; // A2W_PLLB_CTRL (~998.4 MHz)

        // Initialize A2W ANA1 registers (bit 14 = KI, etc.)
        r[0x1014 / 4] = 0x00140000;
        r[0x1034 / 4] = 0x00140000;
        r[0x1054 / 4] = 0x00140000;
        r[0x1074 / 4] = 0x00140000;
        r[0x10f4 / 4] = 0x00140000;

        // Initialize PLL channel dividers to 4 (enabled, non-zero divisor)
        const pll_div_offsets = [_]u32{
            0x1104, 0x1108, 0x110c, 0x1110, // PLLA_DSI0, CORE, PER, CCP2
            0x1124, 0x1128, 0x112c, 0x1130, // PLLC_CORE2, CORE1, PER, CORE0
            0x1144, 0x1148, 0x114c, 0x1150, // PLLD_DSI0, CORE, PER, DSI1
            0x1164, 0x1168, 0x116c, // PLLH_RCAL, AUX, PIX
            0x11e4, // PLLB_ARM
        };
        for (pll_div_offsets) |off| {
            r[off / 4] = 4;
        }

        // Initialize standard clock generator dividers (DIVI in bits [23:12])
        var off: u32 = 0x0000;
        while (off < 0x0100) : (off += 8) {
            r[off / 4] = (1 << 4) | 1; // CM_ENABLE | SRC=OSC
            r[(off + 4) / 4] = 4 << 12; // DIVI = 4
        }
        // VPU clock (0x0008): SRC=PLLC_CORE0 (5), DIVI=2
        r[0x0008 / 4] = (1 << 4) | 5;
        r[0x000c / 4] = 2 << 12;

        // EMMC clock (0x01c0): SRC=PLLC_PER (6), DIVI=2
        r[0x01c0 / 4] = (1 << 4) | 6;
        r[0x01c4 / 4] = 2 << 12;

        return r;
    }

    pub fn read32(self: *const Cprman, offset: u32) u32 {
        if (offset >= SIZE) return 0;
        if (offset == CM_LOCK) return 0x0000FFFF;
        // Clear CM_BUSY on clock control reads so clk-bcm2835 never spins waiting for busy clear
        return self.regs[offset / 4] & ~CM_BUSY;
    }

    pub fn write32(self: *Cprman, offset: u32, val: u32) void {
        if (offset >= SIZE) return;
        // Strip password byte [31:24] (`0x5a000000`) and CM_BUSY bit
        self.regs[offset / 4] = (val & 0x00FFFFFF) & ~CM_BUSY;
        self.regs[CM_LOCK / 4] = 0x0000FFFF;
    }
};
