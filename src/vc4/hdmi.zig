const std = @import("std");

/// VideoCore IV HDMI Controller (`brcm,bcm2835-hdmi`) at `0x20902000` (HDMI) and `0x20808000` (HD).
pub const Hdmi = struct {
    pub const HDMI_BASE: u32 = 0x20902000;
    pub const HDMI_SIZE: u32 = 0x600;
    pub const HD_BASE: u32 = 0x20808000;
    pub const HD_SIZE: u32 = 0x100;

    pub const HDMI_CORE_REV: u32 = 0x000;
    pub const HDMI_HOTPLUG: u32 = 0x00c;
    pub const HDMI_FIFO_CTL: u32 = 0x05c;
    pub const HDMI_RAM_PACKET_CONFIG: u32 = 0x0a0;
    pub const HDMI_RAM_PACKET_STATUS: u32 = 0x0a4;
    pub const HDMI_SCHEDULER_CONTROL: u32 = 0x0c0;

    connected: bool = true,
    hdmi_regs: [HDMI_SIZE / 4]u32 = initHdmiRegs(),
    hd_regs: [HD_SIZE / 4]u32 = [_]u32{0} ** (HD_SIZE / 4),

    fn initHdmiRegs() [HDMI_SIZE / 4]u32 {
        var r: [HDMI_SIZE / 4]u32 = [_]u32{0} ** (HDMI_SIZE / 4);
        r[HDMI_CORE_REV / 4] = 0x00000105;
        r[HDMI_HOTPLUG / 4] = 0x00000001; // Connected
        r[HDMI_FIFO_CTL / 4] = (1 << 14) | 1; // VC4_HDMI_FIFO_CTL_RECENTER_DONE | MASTER_SLAVE_N
        return r;
    }

    pub fn readHdmi32(self: *const Hdmi, offset: u32) u32 {
        if (offset >= HDMI_SIZE) return 0;
        if (offset == HDMI_HOTPLUG) return if (self.connected) 1 else 0; // VC4_HDMI_HOTPLUG_CONNECTED
        if (offset == HDMI_RAM_PACKET_STATUS) return self.hdmi_regs[HDMI_RAM_PACKET_CONFIG / 4];
        return self.hdmi_regs[offset / 4];
    }

    pub fn writeHdmi32(self: *Hdmi, offset: u32, val: u32) void {
        if (offset >= HDMI_SIZE) return;
        var v = val;
        if (offset == HDMI_FIFO_CTL) {
            v |= (1 << 14); // VC4_HDMI_FIFO_CTL_RECENTER_DONE
        } else if (offset == HDMI_SCHEDULER_CONTROL) {
            if ((v & 1) != 0) { // MODE_HDMI -> set HDMI_ACTIVE (bit 1)
                v |= 2;
            } else {
                v &= ~@as(u32, 2);
            }
        }
        self.hdmi_regs[offset / 4] = v;
        if (offset == HDMI_RAM_PACKET_CONFIG) {
            self.hdmi_regs[HDMI_RAM_PACKET_STATUS / 4] = v;
        }
    }

    pub fn readHd32(self: *const Hdmi, offset: u32) u32 {
        if (offset >= HD_SIZE) return 0;
        return self.hd_regs[offset / 4];
    }

    pub fn writeHd32(self: *Hdmi, offset: u32, val: u32) void {
        if (offset >= HD_SIZE) return;
        self.hd_regs[offset / 4] = val;
    }
};

/// VideoCore IV Transposer (`brcm,bcm2835-txp`) at `0x20004000` (size `0x20`).
pub const Txp = struct {
    pub const BASE_ADDR: u32 = 0x20004000;
    pub const SIZE: u32 = 0x20;

    regs: [8]u32 = [_]u32{0} ** 8,
    irq_pending: bool = false,

    pub fn read32(self: *const Txp, offset: u32) u32 {
        if (offset >= SIZE) return 0;
        return self.regs[offset / 4];
    }

    pub fn write32(self: *Txp, offset: u32, val: u32) void {
        if (offset >= SIZE) return;
        if (offset == 0x0c) { // TXP_CTRL
            if ((val & 1) != 0) { // TXP_GO
                self.irq_pending = true;
            }
            if ((val & (1 << 5)) != 0) { // TXP_EI clear interrupt
                self.irq_pending = false;
            }
            self.regs[3] = val & ~@as(u32, 3); // Clear GO and BUSY
            return;
        }
        self.regs[offset / 4] = val;
    }
};
