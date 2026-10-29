//! BCM2835 MPHI, the "host port" at `0x7e006000` (GPU IRQ 32), as the Raspberry Pi `dwc_otg` USB
//! driver uses it: its FIQ handler (on 64-bit kernels, a handler on the USB interrupt) services the
//! controller, then starts a dummy output DMA (`OUTDDA`, then `OUTDDB` with bit 29) whose completion
//! interrupt runs the driver's main handler. That handler clears the interrupt (`INTSTAT` bit 16)
//! and every so often resets the block (`CTRL` bit 16, waiting for bit 17).
const std = @import("std");

pub const Mphi = struct {
    pub const BASE_ADDR: u32 = 0x20006000;
    pub const SIZE: u32 = 0x1000;

    const OUTDDA: u32 = 0x28;
    const OUTDDB: u32 = 0x2c;
    const CTRL: u32 = 0x4c;
    const INTSTAT: u32 = 0x50;

    const CTRL_ENABLE: u32 = 1 << 31;
    const CTRL_RESET: u32 = 1 << 16;
    const CTRL_RESET_DONE: u32 = 1 << 17;
    /// `OUTDDB`: interrupt when this output transfer completes.
    const OUTDDB_INTERRUPT: u32 = 1 << 29;
    /// `INTSTAT`: an output transfer completed (the interrupt the driver clears).
    const INT_OUTPUT_DONE: u32 = 1 << 16;
    /// `INTSTAT`: the completed transfer asked for an interrupt.
    const INT_OUTPUT_IRQ: u32 = 1 << 29;

    ctrl: u32 = 0,
    outdda: u32 = 0,
    intstat: u32 = 0,

    pub fn irqPending(self: *const Mphi) bool {
        return (self.ctrl & CTRL_ENABLE) != 0 and (self.intstat & INT_OUTPUT_DONE) != 0;
    }

    pub fn read32(self: *const Mphi, offset: u32) u32 {
        return switch (offset) {
            OUTDDA => self.outdda,
            CTRL => self.ctrl | (if ((self.ctrl & CTRL_RESET) != 0) CTRL_RESET_DONE else 0),
            INTSTAT => self.intstat,
            else => 0,
        };
    }

    pub fn write32(self: *Mphi, offset: u32, val: u32) void {
        switch (offset) {
            OUTDDA => self.outdda = val,
            // The transfer completes at once: nothing reads what it sends.
            OUTDDB => if ((val & OUTDDB_INTERRUPT) != 0) {
                self.intstat |= INT_OUTPUT_DONE | INT_OUTPUT_IRQ;
            },
            CTRL => {
                self.ctrl = val & ~CTRL_RESET_DONE;
                if ((val & CTRL_RESET) != 0) self.intstat = 0;
            },
            INTSTAT => self.intstat &= ~val,
            else => {},
        }
    }
};

test "MPHI raises its interrupt for an output transfer and clears it" {
    var m: Mphi = .{};
    m.write32(Mphi.CTRL, Mphi.CTRL_ENABLE);
    try std.testing.expect(!m.irqPending());

    m.write32(Mphi.OUTDDA, 0xc000_1000);
    m.write32(Mphi.OUTDDB, 1 << 29);
    try std.testing.expect(m.irqPending());

    m.write32(Mphi.INTSTAT, 1 << 16);
    try std.testing.expect(!m.irqPending());

    // Reset handshake: bit 17 reads back while bit 16 is set
    m.write32(Mphi.OUTDDB, 1 << 29);
    m.write32(Mphi.CTRL, Mphi.CTRL_ENABLE | Mphi.CTRL_RESET);
    try std.testing.expect((m.read32(Mphi.CTRL) & Mphi.CTRL_RESET_DONE) != 0);
    try std.testing.expect(!m.irqPending());
    m.write32(Mphi.CTRL, Mphi.CTRL_ENABLE);
    try std.testing.expectEqual(Mphi.CTRL_ENABLE, m.read32(Mphi.CTRL));
}
