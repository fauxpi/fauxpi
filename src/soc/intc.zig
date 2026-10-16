//! BCM2835 ARM Interrupt Controller (`brcm,bcm2835-armctrl-ic` at `0x2000b200`).
//!
//! Manages 3 banks of interrupts:
//! - Bank 0 (Basic): 8 local ARM interrupts (`0:0` ARM Timer, `0:1` Mailbox, `0:2` Doorbell 0, ...)
//! - Bank 1 (GPU IRQs 0..31): `1:0..3` System Timer 0..3, `1:9` USB DWC2, `1:10` V3D, `1:16..27` DMA, `1:29` AUX
//! - Bank 2 (GPU IRQs 32..63): `2:1` HVS, `2:8..9` HDMI, `2:10` PV2, `2:13..14` PV0/1, `2:21` I2C2, `2:24` SDHOST, `2:25` UART0, `2:30` EMMC

const std = @import("std");

pub const IntController = struct {
    /// Raw asserted interrupt lines per bank (0 = Basic 8-bit, 1 = GPU1 32-bit, 2 = GPU2 32-bit)
    raw_level: [3]u32 = @splat(0),
    /// Enabled interrupt mask per bank
    enabled: [3]u32 = @splat(0),
    /// FIQ control register (`0x0c`): bit 7 = enable, bits 6:0 = FIQ source (0..31=GPU1, 32..63=GPU2, 64..71=Basic)
    fiq_control: u32 = 0,

    // Bank 1 shortcut bits in IRQ_BASIC_PENDING (bits 10..14): GPU IRQs 7, 9, 10, 18, 19
    const bank1_shortcuts = [_]u5{ 7, 9, 10, 18, 19 };
    const bank1_shortcut_mask: u32 = (1 << 7) | (1 << 9) | (1 << 10) | (1 << 18) | (1 << 19);

    // Bank 2 shortcut bits in IRQ_BASIC_PENDING (bits 15..20): Bank 2 bits 21, 22, 23, 24, 25, 30
    const bank2_shortcuts = [_]u5{ 21, 22, 23, 24, 25, 30 };
    const bank2_shortcut_mask: u32 = (1 << 21) | (1 << 22) | (1 << 23) | (1 << 24) | (1 << 25) | (1 << 30);

    pub inline fn setIrq(self: *IntController, bank: u2, bit: u5, active: bool) void {
        const mask = @as(u32, 1) << bit;
        if (active) {
            self.raw_level[bank] |= mask;
        } else {
            self.raw_level[bank] &= ~mask;
        }
    }

    pub inline fn pendingBank(self: *const IntController, bank: u2) u32 {
        return self.raw_level[bank] & self.enabled[bank];
    }

    pub fn basicPending(self: *const IntController) u32 {
        var out: u32 = self.pendingBank(0) & 0xff;
        const p1 = self.pendingBank(1);
        const p2 = self.pendingBank(2);

        if ((p1 & ~bank1_shortcut_mask) != 0) out |= (1 << 8);
        if ((p2 & ~bank2_shortcut_mask) != 0) out |= (1 << 9);

        inline for (bank1_shortcuts, 0..) |b, i| {
            if ((p1 & (@as(u32, 1) << b)) != 0) {
                out |= (@as(u32, 1) << @intCast(10 + i));
            }
        }
        inline for (bank2_shortcuts, 0..) |b, i| {
            if ((p2 & (@as(u32, 1) << b)) != 0) {
                out |= (@as(u32, 1) << @intCast(15 + i));
            }
        }
        return out;
    }

    pub inline fn hasPendingIrq(self: *const IntController) bool {
        return ((self.raw_level[0] & self.enabled[0]) | (self.raw_level[1] & self.enabled[1]) | (self.raw_level[2] & self.enabled[2])) != 0;
    }

    pub inline fn hasPendingFiq(self: *const IntController) bool {
        if ((self.fiq_control & (1 << 7)) == 0) return false;
        const src: u7 = @truncate(self.fiq_control & 0x7f);
        if (src < 32) {
            return (self.raw_level[1] & (@as(u32, 1) << @intCast(src))) != 0;
        } else if (src < 64) {
            return (self.raw_level[2] & (@as(u32, 1) << @intCast(src - 32))) != 0;
        } else if (src < 72) {
            return (self.raw_level[0] & (@as(u32, 1) << @intCast(src - 64))) != 0;
        }
        return false;
    }

    pub fn read32(self: *const IntController, offset: u32) u32 {
        return switch (offset) {
            0x00 => self.basicPending(), // IRQ_BASIC_PENDING
            0x04 => self.pendingBank(1), // IRQ_PENDING_1
            0x08 => self.pendingBank(2), // IRQ_PENDING_2
            0x0c => self.fiq_control, // FIQ_CONTROL
            0x10 => self.enabled[1], // ENABLE_IRQS_1
            0x14 => self.enabled[2], // ENABLE_IRQS_2
            0x18 => self.enabled[0], // ENABLE_BASIC_IRQS
            0x1c => self.enabled[1], // DISABLE_IRQS_1
            0x20 => self.enabled[2], // DISABLE_IRQS_2
            0x24 => self.enabled[0], // DISABLE_BASIC_IRQS
            else => 0,
        };
    }

    pub fn write32(self: *IntController, offset: u32, val: u32) void {
        switch (offset) {
            0x0c => self.fiq_control = val & 0xff,
            0x10 => self.enabled[1] |= val,
            0x14 => self.enabled[2] |= val,
            0x18 => self.enabled[0] |= (val & 0xff),
            0x1c => self.enabled[1] &= ~val,
            0x20 => self.enabled[2] &= ~val,
            0x24 => self.enabled[0] &= ~(val & 0xff),
            else => {},
        }
    }
};

test "BCM2835 interrupt controller pending and shortcut bits" {
    var ic: IntController = .{};
    // Enable System Timer 3 (bank 1, bit 3 -> non-shortcut) and USB (bank 1, bit 9 -> shortcut 1)
    ic.write32(0x10, (1 << 3) | (1 << 9));
    try std.testing.expect(!ic.hasPendingIrq());

    ic.setIrq(1, 3, true);
    try std.testing.expect(ic.hasPendingIrq());
    // Bit 8 (BANK1_HWIRQ) should be set in IRQ_BASIC_PENDING
    try std.testing.expectEqual(@as(u32, 1 << 8), ic.read32(0x00));
    try std.testing.expectEqual(@as(u32, 1 << 3), ic.read32(0x04));

    ic.setIrq(1, 3, false);
    ic.setIrq(1, 9, true);
    // USB is shortcut index 1 -> bit 11 in IRQ_BASIC_PENDING
    try std.testing.expectEqual(@as(u32, 1 << 11), ic.read32(0x00));
}
