const std = @import("std");

/// VideoCore IV PixelValve Scanout Timing Generator (`brcm,bcm2835-pixelvalve0/1/2`)
/// PV0: `0x20206000` (IRQ Bank 2 bit 13 = 45)
/// PV1: `0x20207000` (IRQ Bank 2 bit 14 = 46)
/// PV2: `0x20807000` (IRQ Bank 2 bit 10 = 42, drives HDMI)
pub const PixelValve = struct {
    pub const PV0_BASE: u32 = 0x20206000;
    pub const PV1_BASE: u32 = 0x20207000;
    pub const PV2_BASE: u32 = 0x20807000;
    pub const SIZE: u32 = 0x100;

    pub const PV_CONTROL_EN: u32 = 1 << 0;
    pub const PV_VCONTROL_VIDEN: u32 = 1 << 0;
    pub const PV_INT_VFP_START: u32 = 1 << 7;
    pub const PV_STAT_VID_IDLE: u32 = 1 << 10;

    control: u32 = 0,
    v_control: u32 = 0,
    vsyncd_even: u32 = 0,
    horza: u32 = 0,
    horzb: u32 = 1280,
    verta: u32 = 0,
    vertb: u32 = 720,
    verta_even: u32 = 0,
    vertb_even: u32 = 0,
    inten: u32 = 0,
    intstat: u32 = PV_INT_VFP_START,
    stat: u32 = PV_STAT_VID_IDLE,
    hact_act: u32 = 1280,

    pub fn irqPending(self: *const PixelValve) bool {
        return (self.intstat & self.inten) != 0;
    }

    pub fn triggerVblank(self: *PixelValve) void {
        if ((self.control & PV_CONTROL_EN) != 0 and (self.v_control & PV_VCONTROL_VIDEN) != 0) {
            self.intstat |= PV_INT_VFP_START;
        }
    }

    pub fn read32(self: *const PixelValve, offset: u32) u32 {
        return switch (offset) {
            0x00 => self.control,
            0x04 => self.v_control,
            0x08 => self.vsyncd_even,
            0x0c => self.horza,
            0x10 => self.horzb,
            0x14 => self.verta,
            0x18 => self.vertb,
            0x1c => self.verta_even,
            0x20 => self.vertb_even,
            0x24 => self.inten,
            0x28 => self.intstat,
            0x2c => if ((self.v_control & PV_VCONTROL_VIDEN) == 0) (self.stat | PV_STAT_VID_IDLE) else (self.stat & ~PV_STAT_VID_IDLE),
            0x30 => self.hact_act,
            else => 0,
        };
    }

    pub fn write32(self: *PixelValve, offset: u32, val: u32) void {
        switch (offset) {
            0x00 => self.control = val & ~@as(u32, 2), // clear FIFO_CLR bit
            0x04 => {
                self.v_control = val;
                if ((val & PV_VCONTROL_VIDEN) == 0) {
                    // Immediately signal VFP_START so vc4_crtc_disable never times out waiting for frame end
                    self.intstat |= PV_INT_VFP_START;
                }
            },
            0x08 => self.vsyncd_even = val,
            0x0c => self.horza = val,
            0x10 => self.horzb = val,
            0x14 => self.verta = val,
            0x18 => self.vertb = val,
            0x1c => self.verta_even = val,
            0x20 => self.vertb_even = val,
            0x24 => self.inten = val,
            0x28 => self.intstat &= ~val, // W1C
            0x30 => self.hact_act = val,
            else => {},
        }
    }
};
