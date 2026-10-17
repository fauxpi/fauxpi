const std = @import("std");

/// BCM2835 Secondary Memory Interface (`brcm,bcm2835-smi`) at `0x20600000` (size `0x100`, IRQ Bank 2 bit 16 = 48).
/// Only the part the firmware uses for vc4 firmware KMS (`raspberrypi,rpi-firmware-kms`, same registers and
/// interrupt) is emulated: the firmware raises an SMICS interrupt bit at each vblank and tags SMIDSW0/SMIDSW1
/// with `SMI_NEW | 1` to say which display it was for. The driver acknowledges by writing 0 to SMICS and
/// `SMI_NEW` to the display's SMIDSW register. Other registers are plain storage.
pub const Smi = struct {
    pub const BASE_ADDR: u32 = 0x20600000;
    pub const SIZE: u32 = 0x100;

    pub const SMICS: u32 = 0x00;
    pub const SMIDSW0: u32 = 0x14;
    pub const SMIDSW1: u32 = 0x1c;

    pub const SMICS_INTD: u32 = 1 << 9;
    pub const SMICS_INTT: u32 = 1 << 10;
    pub const SMICS_INTR: u32 = 1 << 11;
    pub const SMICS_INTERRUPTS: u32 = SMICS_INTD | SMICS_INTT | SMICS_INTR;

    /// Tag in SMIDSWn telling the driver the firmware reports vblanks per display (bit 0 = vblank pending).
    pub const SMI_NEW: u32 = 0xabcd0000;

    regs: [SIZE / 4]u32 = initRegs(),
    /// Set once the guest initialises SMICS: the firmware only reports vblanks here for firmware KMS.
    vblank_enabled: bool = false,

    fn initRegs() [SIZE / 4]u32 {
        var r: [SIZE / 4]u32 = @splat(0);
        r[SMIDSW0 / 4] = SMI_NEW;
        r[SMIDSW1 / 4] = SMI_NEW;
        return r;
    }

    pub fn irqPending(self: *const Smi) bool {
        return (self.regs[SMICS / 4] & SMICS_INTERRUPTS) != 0;
    }

    /// Reports a vblank on display 0 (fauxpi's only display, HDMI0).
    pub fn triggerVblank(self: *Smi) void {
        if (!self.vblank_enabled) return;
        self.regs[SMIDSW0 / 4] = SMI_NEW | 1;
        self.regs[SMICS / 4] |= SMICS_INTD;
    }

    pub fn read32(self: *const Smi, offset: u32) u32 {
        return self.regs[(offset & (SIZE - 1)) / 4];
    }

    pub fn write32(self: *Smi, offset: u32, val: u32) void {
        const off = offset & (SIZE - 1);
        if (off == SMICS) self.vblank_enabled = true;
        self.regs[off / 4] = val;
    }
};

test "SMI firmware KMS vblank interrupt and acknowledge" {
    var smi: Smi = .{};

    // No vblanks until the driver initialises SMICS
    smi.triggerVblank();
    try std.testing.expect(!smi.irqPending());

    smi.write32(Smi.SMICS, 0);
    try std.testing.expect(!smi.irqPending());
    try std.testing.expectEqual(Smi.SMI_NEW, smi.read32(Smi.SMIDSW0));

    smi.triggerVblank();
    try std.testing.expect(smi.irqPending());
    try std.testing.expect(smi.read32(Smi.SMICS) & Smi.SMICS_INTERRUPTS != 0);
    try std.testing.expectEqual(Smi.SMI_NEW | 1, smi.read32(Smi.SMIDSW0));
    try std.testing.expectEqual(Smi.SMI_NEW, smi.read32(Smi.SMIDSW1));

    // vc4_crtc_irq_handler: clear SMICS, then acknowledge display 0
    smi.write32(Smi.SMICS, 0);
    try std.testing.expect(!smi.irqPending());
    smi.write32(Smi.SMIDSW0, Smi.SMI_NEW);
    try std.testing.expectEqual(Smi.SMI_NEW, smi.read32(Smi.SMIDSW0));

    smi.triggerVblank();
    try std.testing.expect(smi.irqPending());
}
