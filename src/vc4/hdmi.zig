const std = @import("std");
const audio_mod = @import("../soc/audio.zig");

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

    // HD registers (offset from 0x20808000) for Multi-channel Audio Interconnect (MAI)
    pub const HD_MAI_CTL: u32 = 0x014;
    pub const HD_MAI_THR: u32 = 0x018;
    pub const HD_MAI_FMT: u32 = 0x01c;
    pub const HD_MAI_DATA: u32 = 0x020;
    pub const HD_MAI_SMP: u32 = 0x02c;

    pub const HD_MAI_CTL_RESET: u32 = 1 << 1;
    pub const HD_MAI_CTL_FLUSH: u32 = 1 << 2;
    pub const HD_MAI_CTL_ENABLE: u32 = 1 << 3;
    pub const HD_MAI_CTL_EMPTY: u32 = 1 << 11;

    connected: bool = true,
    hdmi_regs: [HDMI_SIZE / 4]u32 = initHdmiRegs(),
    hd_regs: [HD_SIZE / 4]u32 = @splat(0),

    mai_pending_left: i16 = 0,
    mai_has_left: bool = false,

    fn initHdmiRegs() [HDMI_SIZE / 4]u32 {
        var r: [HDMI_SIZE / 4]u32 = @splat(0);
        r[HDMI_CORE_REV / 4] = 0x00000105;
        r[HDMI_HOTPLUG / 4] = 0x00000001; // Connected
        r[HDMI_FIFO_CTL / 4] = (1 << 14) | 1; // VC4_HDMI_FIFO_CTL_RECENTER_DONE | MASTER_SLAVE_N
        return r;
    }

    pub fn maiSampleRate(self: *const Hdmi) u32 {
        const fmt = self.hd_regs[HD_MAI_FMT / 4];
        const sr_enum: u8 = @truncate((fmt >> 8) & 0xff);
        return switch (sr_enum) {
            2 => 8_000,
            3 => 11_025,
            4 => 12_000,
            5 => 16_000,
            6 => 22_050,
            7 => 32_000,
            8 => 44_100,
            9 => 48_000,
            10 => 64_000,
            11 => 88_200,
            12 => 96_000,
            13 => 128_000,
            14 => 176_400,
            15 => 192_000,
            else => 48_000,
        };
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
        if (offset == HD_MAI_CTL) {
            return self.hd_regs[HD_MAI_CTL / 4] | HD_MAI_CTL_EMPTY;
        }
        return self.hd_regs[offset / 4];
    }

    pub fn writeHd32(self: *Hdmi, offset: u32, val: u32, audio_fifo: ?*audio_mod.AudioFifo) void {
        if (offset >= HD_SIZE) return;
        self.hd_regs[offset / 4] = val;

        if (offset == HD_MAI_CTL) {
            if ((val & (HD_MAI_CTL_RESET | HD_MAI_CTL_FLUSH)) != 0) {
                self.mai_has_left = false;
            }
        } else if (offset == HD_MAI_DATA) {
            // Unpack 32-bit IEC958_SUBFRAME_LE word:
            // bits [3:0] = preamble (0x8 = B/left frame 0, 0x2 = M/left, 0x4 = W/right)
            // bits [27:12] = signed 16-bit PCM sample
            const preamble: u4 = @truncate(val & 0xf);
            const sample: i16 = @bitCast(@as(u16, @truncate((val >> 12) & 0xffff)));

            if (preamble == 0x8 or preamble == 0x2) {
                self.mai_pending_left = sample;
                self.mai_has_left = true;
            } else if (preamble == 0x4) {
                self.mai_has_left = false;
                if (self.connected) {
                    if (audio_fifo) |fifo| {
                        fifo.pushStereoSample(self.mai_pending_left, sample, self.maiSampleRate());
                    }
                }
            } else {
                if (!self.mai_has_left) {
                    self.mai_pending_left = sample;
                    self.mai_has_left = true;
                } else {
                    self.mai_has_left = false;
                    if (self.connected) {
                        if (audio_fifo) |fifo| {
                            fifo.pushStereoSample(self.mai_pending_left, sample, self.maiSampleRate());
                        }
                    }
                }
            }
        }
    }
};

/// VideoCore IV Transposer (`brcm,bcm2835-txp`) at `0x20004000` (size `0x20`).
pub const Txp = struct {
    pub const BASE_ADDR: u32 = 0x20004000;
    pub const SIZE: u32 = 0x20;

    regs: [8]u32 = @splat(0),
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
