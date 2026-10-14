const std = @import("std");

/// BCM2835 DMA Controller (`brcm,bcm2835-dma`) at `0x20007000` (size `0x1000`).
/// Supports channels 0..14 with chained Control Blocks (CBs), 1D/2D transfers, and peripheral FIFO ports.
pub const DmaController = struct {
    pub const BASE_ADDR: u32 = 0x20007000;
    pub const SIZE: u32 = 0x1000;
    pub const NUM_CHANNELS: usize = 15;

    // CS register bits
    pub const CS_ACTIVE: u32 = 1 << 0;
    pub const CS_END: u32 = 1 << 1;
    pub const CS_INT: u32 = 1 << 2;
    pub const CS_DREQ: u32 = 1 << 3;
    pub const CS_PAUSED: u32 = 1 << 4;
    pub const CS_ABORT: u32 = 1 << 30;
    pub const CS_RESET: u32 = 1 << 31;

    // TI register bits
    pub const TI_INT_EN: u32 = 1 << 0;
    pub const TI_TDMODE: u32 = 1 << 1;
    pub const TI_D_INC: u32 = 1 << 4;
    pub const TI_D_IGNORE: u32 = 1 << 7;
    pub const TI_S_INC: u32 = 1 << 8;
    pub const TI_S_IGNORE: u32 = 1 << 11;

    pub const Channel = struct {
        cs: u32 = 0,
        conblk_ad: u32 = 0,
        ti: u32 = 0,
        source_ad: u32 = 0,
        dest_ad: u32 = 0,
        txfr_len: u32 = 0,
        stride: u32 = 0,
        nextconbk: u32 = 0,
        debug: u32 = 0,
    };

    channels: [NUM_CHANNELS]Channel = [_]Channel{.{}} ** NUM_CHANNELS,
    int_status: u32 = 0,
    enable: u32 = 0x7fff,

    /// Callback interface for reading/writing peripheral MMIO addresses (such as SDDATA 0x7e202040)
    pub const MmioIo = struct {
        ctx: *anyopaque,
        read32Fn: *const fn (ctx: *anyopaque, phys_addr: u32) u32,
        write32Fn: *const fn (ctx: *anyopaque, phys_addr: u32, val: u32) void,
        dreqReadyFn: *const fn (ctx: *anyopaque, permap: u5) bool,
    };

    pub fn channelIrqPending(self: *const DmaController, ch: usize) bool {
        if (ch >= NUM_CHANNELS) return false;
        return (self.channels[ch].cs & CS_INT) != 0;
    }

    pub fn read32(self: *const DmaController, offset: u32) u32 {
        if (offset == 0xfe0) return self.int_status;
        if (offset == 0xff0) return self.enable;

        const ch = offset / 0x100;
        const reg = offset % 0x100;
        if (ch >= NUM_CHANNELS) return 0;

        const c = &self.channels[ch];
        return switch (reg) {
            0x00 => c.cs | CS_DREQ,
            0x04 => c.conblk_ad,
            0x08 => c.ti,
            0x0c => c.source_ad,
            0x10 => c.dest_ad,
            0x14 => c.txfr_len,
            0x18 => c.stride,
            0x1c => c.nextconbk,
            0x20 => c.debug,
            else => 0,
        };
    }

    pub fn write32(self: *DmaController, offset: u32, val: u32, ram: []u8, mmio: ?MmioIo) void {
        if (offset == 0xfe0) {
            self.int_status &= ~val;
            return;
        }
        if (offset == 0xff0) {
            self.enable = val;
            return;
        }

        const ch = offset / 0x100;
        const reg = offset % 0x100;
        if (ch >= NUM_CHANNELS) return;

        var c = &self.channels[ch];
        switch (reg) {
            0x00 => { // CS
                if ((val & CS_RESET) != 0) {
                    c.* = .{};
                    self.int_status &= ~(@as(u32, 1) << @intCast(ch));
                    return;
                }
                if ((val & CS_ABORT) != 0) {
                    c.conblk_ad = c.nextconbk;
                    c.cs &= ~CS_ACTIVE;
                }
                // W1C bits: CS_END (bit 1) and CS_INT (bit 2)
                if ((val & CS_END) != 0) c.cs &= ~CS_END;
                if ((val & CS_INT) != 0) {
                    c.cs &= ~CS_INT;
                    self.int_status &= ~(@as(u32, 1) << @intCast(ch));
                }
                // Update writable control bits (ACTIVE, priority, panic priority, wait)
                const writable_mask: u32 = CS_ACTIVE | 0x30ff0000;
                c.cs = (c.cs & ~writable_mask) | (val & writable_mask);

                if ((c.cs & CS_ACTIVE) != 0) {
                    self.stepChannel(ch, ram, mmio);
                }
            },
            0x04 => c.conblk_ad = val,
            0x20 => c.debug = val & ~@as(u32, 7),
            else => {},
        }
    }

    pub fn stepAllActive(self: *DmaController, ram: []u8, mmio: ?MmioIo) void {
        for (0..NUM_CHANNELS) |ch| {
            if ((self.channels[ch].cs & CS_ACTIVE) != 0) {
                self.stepChannel(ch, ram, mmio);
            }
        }
    }

    fn stepChannel(self: *DmaController, ch: usize, ram: []u8, mmio: ?MmioIo) void {
        var c = &self.channels[ch];
        var max_cbs: usize = 1024;

        while ((c.cs & CS_ACTIVE) != 0 and c.conblk_ad != 0 and max_cbs > 0) : (max_cbs -= 1) {
            const cb_phys = c.conblk_ad & 0x1FFFFFFF;
            if (cb_phys + 32 > ram.len) {
                c.cs &= ~CS_ACTIVE;
                break;
            }

            c.ti = std.mem.readInt(u32, ram[cb_phys + 0 ..][0..4], .little);
            c.source_ad = std.mem.readInt(u32, ram[cb_phys + 4 ..][0..4], .little);
            c.dest_ad = std.mem.readInt(u32, ram[cb_phys + 8 ..][0..4], .little);
            c.txfr_len = std.mem.readInt(u32, ram[cb_phys + 12 ..][0..4], .little);
            c.stride = std.mem.readInt(u32, ram[cb_phys + 16 ..][0..4], .little);
            c.nextconbk = std.mem.readInt(u32, ram[cb_phys + 20 ..][0..4], .little);

            // Check if gated by peripheral DREQ (e.g. PERMAP 13 = SDHOST)
            const permap: u5 = @truncate((c.ti >> 16) & 0x1f);
            const uses_dreq = (c.ti & ((1 << 6) | (1 << 10))) != 0;
            if (uses_dreq and permap != 0) {
                if (mmio) |m| {
                    if (!m.dreqReadyFn(m.ctx, permap)) {
                        // Keep channel CS_ACTIVE; it will run once the peripheral DREQ is ready
                        return;
                    }
                }
            }

            self.executeTransfer(c, ram, mmio);

            c.txfr_len = 0;
            c.cs |= CS_END;
            if ((c.ti & TI_INT_EN) != 0) {
                c.cs |= CS_INT;
                self.int_status |= (@as(u32, 1) << @intCast(ch));
            }

            c.conblk_ad = c.nextconbk;
            if (c.conblk_ad == 0) {
                c.cs &= ~CS_ACTIVE;
                break;
            }
        }
    }

    fn isPeripAddr(bus_addr: u32) bool {
        if ((bus_addr & 0xFF000000) == 0x7E000000) return true;
        return bus_addr >= 0x20000000 and bus_addr < 0x21000000;
    }

    fn executeTransfer(self: *DmaController, c: *Channel, ram: []u8, mmio: ?MmioIo) void {
        _ = self;
        const s_inc = (c.ti & TI_S_INC) != 0;
        const d_inc = (c.ti & TI_D_INC) != 0;
        const s_ign = (c.ti & TI_S_IGNORE) != 0;
        const d_ign = (c.ti & TI_D_IGNORE) != 0;

        const tdmode = (c.ti & TI_TDMODE) != 0;
        const x_len: u32 = if (tdmode) (c.txfr_len & 0xFFFF) else c.txfr_len;
        const y_cnt: u32 = if (tdmode) ((c.txfr_len >> 16) & 0x3FFF) + 1 else 1;
        const s_stride: i32 = if (tdmode) @as(i16, @bitCast(@as(u16, @truncate(c.stride)))) else 0;
        const d_stride: i32 = if (tdmode) @as(i16, @bitCast(@as(u16, @truncate(c.stride >> 16)))) else 0;

        var src = c.source_ad;
        var dst = c.dest_ad;

        var y: u32 = 0;
        while (y < y_cnt) : (y += 1) {
            var rem = x_len;
            while (rem > 0) {
                if (rem >= 4 and (src & 3) == 0 and (dst & 3) == 0) {
                    var word: u32 = 0;
                    if (!s_ign) {
                        if (isPeripAddr(src)) {
                            if (mmio) |m| word = m.read32Fn(m.ctx, src);
                        } else {
                            const sp = src & 0x1FFFFFFF;
                            if (sp + 4 <= ram.len) word = std.mem.readInt(u32, ram[sp..][0..4], .little);
                        }
                    }
                    if (!d_ign) {
                        if (isPeripAddr(dst)) {
                            if (mmio) |m| m.write32Fn(m.ctx, dst, word);
                        } else {
                            const dp = dst & 0x1FFFFFFF;
                            if (dp + 4 <= ram.len) std.mem.writeInt(u32, ram[dp..][0..4], word, .little);
                        }
                    }
                    if (s_inc) src +%= 4;
                    if (d_inc) dst +%= 4;
                    rem -= 4;
                } else {
                    var byte: u8 = 0;
                    if (!s_ign and !isPeripAddr(src)) {
                        const sp = src & 0x1FFFFFFF;
                        if (sp < ram.len) byte = ram[sp];
                    }
                    if (!d_ign and !isPeripAddr(dst)) {
                        const dp = dst & 0x1FFFFFFF;
                        if (dp < ram.len) ram[dp] = byte;
                    }
                    if (s_inc) src +%= 1;
                    if (d_inc) dst +%= 1;
                    rem -= 1;
                }
            }
            src = @bitCast(@as(i32, @bitCast(src)) +% s_stride);
            dst = @bitCast(@as(i32, @bitCast(dst)) +% d_stride);
        }

        c.source_ad = src;
        c.dest_ad = dst;
    }
};

test "DMA 1D memory-to-memory copy" {
    var dma = DmaController{};
    var ram: [1024]u8 = [_]u8{0} ** 1024;

    // Source data at 0x100
    std.mem.writeInt(u32, ram[0x100..0x104], 0xCAFEBABE, .little);
    std.mem.writeInt(u32, ram[0x104..0x108], 0x12345678, .little);

    // Control block at 0x20 (32-byte aligned)
    const cb: u32 = 0x20;
    std.mem.writeInt(u32, ram[cb + 0 ..][0..4], DmaController.TI_S_INC | DmaController.TI_D_INC | DmaController.TI_INT_EN, .little);
    std.mem.writeInt(u32, ram[cb + 4 ..][0..4], 0xc0000100, .little); // src bus addr
    std.mem.writeInt(u32, ram[cb + 8 ..][0..4], 0xc0000200, .little); // dst bus addr
    std.mem.writeInt(u32, ram[cb + 12 ..][0..4], 8, .little); // len
    std.mem.writeInt(u32, ram[cb + 16 ..][0..4], 0, .little); // stride
    std.mem.writeInt(u32, ram[cb + 20 ..][0..4], 0, .little); // next

    dma.write32(0x04, 0xc0000020, &ram, null); // Ch0 CONBLK_AD
    dma.write32(0x00, DmaController.CS_ACTIVE, &ram, null); // Ch0 CS = ACTIVE

    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), std.mem.readInt(u32, ram[0x200..0x204], .little));
    try std.testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, ram[0x204..0x208], .little));
    try std.testing.expect(dma.channelIrqPending(0));
}
