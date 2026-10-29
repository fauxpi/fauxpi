const std = @import("std");
const vc_bus = @import("vc_bus.zig");

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
        cb_loaded: bool = false,
        audio_byte_rem_fp: u64 = 0,
    };

    channels: [NUM_CHANNELS]Channel = @splat(.{}),
    int_status: u32 = 0,
    cs_int_mask: u16 = 0,
    active_mask: u16 = 0,
    enable: u32 = 0x7fff,
    stepping: bool = false,

    /// Callback interface for reading/writing peripheral MMIO addresses (such as SDDATA 0x7e202040)
    pub const MmioIo = struct {
        ctx: *anyopaque,
        read32Fn: *const fn (ctx: *anyopaque, phys_addr: u32) u32,
        write32Fn: *const fn (ctx: *anyopaque, phys_addr: u32, val: u32) void,
        dreqReadyFn: *const fn (ctx: *anyopaque, permap: u5) bool,
        readFifoBulkFn: ?*const fn (ctx: *anyopaque, phys_addr: u32, dst: []u8) bool = null,
        writeFifoBulkFn: ?*const fn (ctx: *anyopaque, phys_addr: u32, src: []const u8) bool = null,
    };

    pub inline fn channelIrqPending(self: *const DmaController, ch: usize) bool {
        if (ch >= NUM_CHANNELS) return false;
        return (self.cs_int_mask & (@as(u16, 1) << @intCast(ch))) != 0;
    }

    /// The DMA interrupt lines, from GPU IRQ 16 (bit 0) up, as the board wires them: one line each
    /// for channels 0..10 (IRQs 16..26), one shared by channels 11..14 (IRQ 27), and one raised by
    /// any channel (IRQ 28, `dma-shared-all`).
    pub inline fn irqLines(self: *const DmaController) u32 {
        const m: u32 = self.cs_int_mask;
        return (m & 0x7ff) |
            (@as(u32, @intFromBool((m & 0x7800) != 0)) << 11) |
            (@as(u32, @intFromBool((m & 0x7fff) != 0)) << 12);
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

        const ch_bit = @as(u16, 1) << @intCast(ch);
        var c = &self.channels[ch];
        switch (reg) {
            0x00 => { // CS
                if ((val & CS_RESET) != 0) {
                    c.* = .{};
                    self.int_status &= ~(@as(u32, 1) << @intCast(ch));
                    self.cs_int_mask &= ~ch_bit;
                    self.active_mask &= ~ch_bit;
                    return;
                }
                if ((val & CS_ABORT) != 0) {
                    c.conblk_ad = c.nextconbk;
                    c.cb_loaded = false;
                    c.cs &= ~CS_ACTIVE;
                    self.active_mask &= ~ch_bit;
                }
                // W1C bits: CS_END (bit 1) and CS_INT (bit 2)
                if ((val & CS_END) != 0) c.cs &= ~CS_END;
                if ((val & CS_INT) != 0) {
                    c.cs &= ~CS_INT;
                    self.int_status &= ~(@as(u32, 1) << @intCast(ch));
                    self.cs_int_mask &= ~ch_bit;
                }
                // Update writable control bits (ACTIVE, priority, panic priority, wait)
                const writable_mask: u32 = CS_ACTIVE | 0x30ff0000;
                c.cs = (c.cs & ~writable_mask) | (val & writable_mask);

                if ((c.cs & CS_ACTIVE) != 0) {
                    self.active_mask |= ch_bit;
                    self.stepChannel(ch, ram, mmio);
                } else {
                    self.active_mask &= ~ch_bit;
                }
            },
            0x04 => {
                c.conblk_ad = val;
                c.cb_loaded = false;
            },
            0x20 => c.debug = val & ~@as(u32, 7),
            else => {},
        }
    }

    pub fn stepAllActive(self: *DmaController, ram: []u8, mmio: ?MmioIo) void {
        var mask = self.active_mask;
        while (mask != 0) : (mask &= mask - 1) {
            const ch: usize = @ctz(mask);
            if ((self.channels[ch].cs & CS_ACTIVE) != 0) {
                self.stepChannel(ch, ram, mmio);
            } else {
                self.active_mask &= ~(@as(u16, 1) << @intCast(ch));
            }
        }
    }

    fn isPacedAudioPermap(permap: u5) bool {
        // PERMAP 2 = I2S PCM TX, PERMAP 5 = PWM audio, PERMAP 17 = VC4 HDMI MAI audio-rx
        return permap == 2 or permap == 5 or permap == 17;
    }

    fn loadCbHeader(c: *Channel, ram: []const u8) bool {
        const cb_phys = c.conblk_ad & vc_bus.ramMask(ram.len);
        if (cb_phys + 32 > ram.len) {
            c.cs &= ~CS_ACTIVE;
            c.cb_loaded = false;
            return false;
        }
        c.ti = std.mem.readInt(u32, ram[cb_phys + 0 ..][0..4], .little);
        c.source_ad = std.mem.readInt(u32, ram[cb_phys + 4 ..][0..4], .little);
        c.dest_ad = std.mem.readInt(u32, ram[cb_phys + 8 ..][0..4], .little);
        c.txfr_len = std.mem.readInt(u32, ram[cb_phys + 12 ..][0..4], .little);
        c.stride = std.mem.readInt(u32, ram[cb_phys + 16 ..][0..4], .little);
        c.nextconbk = std.mem.readInt(u32, ram[cb_phys + 20 ..][0..4], .little);
        c.cb_loaded = true;
        return true;
    }

    fn stepChannel(self: *DmaController, ch: usize, ram: []u8, mmio: ?MmioIo) void {
        if (self.stepping) return;
        self.stepping = true;
        defer self.stepping = false;

        const ch_bit = @as(u16, 1) << @intCast(ch);
        var c = &self.channels[ch];
        var max_cbs: usize = 16384;

        while ((c.cs & CS_ACTIVE) != 0 and c.conblk_ad != 0 and max_cbs > 0) : (max_cbs -= 1) {
            if (!c.cb_loaded) {
                if (!loadCbHeader(c, ram)) {
                    self.active_mask &= ~ch_bit;
                    break;
                }
            }

            // Check if gated by peripheral DREQ (e.g. PERMAP 13 = SDHOST, PERMAP 17 = HDMI MAI, PERMAP 5 = PWM)
            const permap: u5 = @truncate((c.ti >> 16) & 0x1f);
            const uses_dreq = (c.ti & ((1 << 6) | (1 << 10))) != 0;
            if (uses_dreq and permap != 0) {
                if (isPacedAudioPermap(permap)) {
                    // Audio DMA channels are stepped incrementally at the audio sample rate via advanceAudio()
                    // so cyclic ALSA ring buffers report accurate DMA_SOURCE_AD pointers and period IRQs.
                    return;
                }
                if (mmio) |m| {
                    if (!m.dreqReadyFn(m.ctx, permap)) {
                        c.cb_loaded = false;
                        return;
                    }
                }
            }

            self.executeTransfer(c, ram, mmio);

            c.txfr_len = 0;
            c.cb_loaded = false;
            c.cs |= CS_END;
            if ((c.ti & TI_INT_EN) != 0) {
                c.cs |= CS_INT;
                self.int_status |= (@as(u32, 1) << @intCast(ch));
                self.cs_int_mask |= ch_bit;
            }

            c.conblk_ad = c.nextconbk;
            if (c.conblk_ad == 0) {
                c.cs &= ~CS_ACTIVE;
                self.active_mask &= ~ch_bit;
                break;
            }
        }
        if ((c.cs & CS_ACTIVE) == 0) {
            self.active_mask &= ~ch_bit;
        }
    }

    /// Steps active cyclic audio DMA channels (`PERMAP = 17` HDMI MAI or `PERMAP = 5` PWM)
    /// proportionally to `elapsed_us` at `hdmi_sample_rate` (2 subframes * 4 bytes = 8 bytes per stereo frame).
    pub fn advanceAudio(self: *DmaController, elapsed_us: u64, hdmi_sample_rate: u32, ram: []u8, mmio: MmioIo) void {
        if (elapsed_us == 0 or self.active_mask == 0) return;
        const rate: u64 = @max(hdmi_sample_rate, 8_000);
        const bytes_per_sec: u64 = rate * 8; // 2 channels * 4 bytes per 32-bit subframe

        var mask = self.active_mask;
        while (mask != 0) : (mask &= mask - 1) {
            const ch: usize = @ctz(mask);
            const ch_bit = @as(u16, 1) << @intCast(ch);
            var c = &self.channels[ch];
            if ((c.cs & CS_ACTIVE) == 0 or c.conblk_ad == 0) {
                if ((c.cs & CS_ACTIVE) == 0) self.active_mask &= ~ch_bit;
                continue;
            }

            if (!c.cb_loaded) {
                if (!loadCbHeader(c, ram)) {
                    self.active_mask &= ~ch_bit;
                    continue;
                }
            }

            const permap: u5 = @truncate((c.ti >> 16) & 0x1f);
            const uses_dreq = (c.ti & ((1 << 6) | (1 << 10))) != 0;
            if (!uses_dreq or !isPacedAudioPermap(permap)) continue;

            c.audio_byte_rem_fp += elapsed_us * bytes_per_sec;
            var bytes_to_transfer: u32 = @intCast((c.audio_byte_rem_fp / 1_000_000) & ~@as(u64, 3));
            c.audio_byte_rem_fp -= @as(u64, bytes_to_transfer) * 1_000_000;

            const s_inc = (c.ti & TI_S_INC) != 0;
            const d_inc = (c.ti & TI_D_INC) != 0;
            const s_ign = (c.ti & TI_S_IGNORE) != 0;
            const d_ign = (c.ti & TI_D_IGNORE) != 0;

            var safety: usize = 64;
            while (bytes_to_transfer >= 4 and (c.cs & CS_ACTIVE) != 0 and c.conblk_ad != 0 and safety > 0) : (safety -= 1) {
                if (!c.cb_loaded) {
                    if (!loadCbHeader(c, ram)) {
                        self.active_mask &= ~ch_bit;
                        break;
                    }
                }

                if (!s_ign and s_inc and !d_ign and !d_inc and isPeripAddr(c.dest_ad)) {
                    const chunk: u32 = @min(bytes_to_transfer, c.txfr_len) & ~@as(u32, 3);
                    if (chunk >= 4 and !isPeripAddr(c.source_ad) and !isPeripAddr(c.source_ad +% (chunk - 1))) {
                        const sp: usize = c.source_ad & vc_bus.ramMask(ram.len);
                        if (sp + chunk <= ram.len) {
                            if (mmio.writeFifoBulkFn) |bulkWrite| {
                                if (bulkWrite(mmio.ctx, c.dest_ad, ram[sp .. sp + chunk])) {
                                    c.source_ad +%= chunk;
                                    c.txfr_len -= chunk;
                                    bytes_to_transfer -= chunk;
                                }
                            }
                        }
                    }
                }

                while (bytes_to_transfer >= 4 and c.txfr_len >= 4) {
                    var word: u32 = 0;
                    if (!s_ign) {
                        if (isPeripAddr(c.source_ad)) {
                            word = mmio.read32Fn(mmio.ctx, c.source_ad);
                        } else {
                            const sp = c.source_ad & vc_bus.ramMask(ram.len);
                            if (sp + 4 <= ram.len) word = std.mem.readInt(u32, ram[sp..][0..4], .little);
                        }
                    }
                    if (!d_ign) {
                        if (isPeripAddr(c.dest_ad)) {
                            mmio.write32Fn(mmio.ctx, c.dest_ad, word);
                        } else {
                            const dp = c.dest_ad & vc_bus.ramMask(ram.len);
                            if (dp + 4 <= ram.len) std.mem.writeInt(u32, ram[dp..][0..4], word, .little);
                        }
                    }
                    if (s_inc) c.source_ad +%= 4;
                    if (d_inc) c.dest_ad +%= 4;
                    c.txfr_len -= 4;
                    bytes_to_transfer -= 4;
                }

                if (c.txfr_len < 4) {
                    c.txfr_len = 0;
                    c.cb_loaded = false;
                    c.cs |= CS_END;
                    if ((c.ti & TI_INT_EN) != 0) {
                        c.cs |= CS_INT;
                        self.int_status |= (@as(u32, 1) << @intCast(ch));
                        self.cs_int_mask |= ch_bit;
                    }
                    c.conblk_ad = c.nextconbk;
                    if (c.conblk_ad == 0) {
                        c.cs &= ~CS_ACTIVE;
                        self.active_mask &= ~ch_bit;
                        break;
                    }
                    // Immediately load the next CB header so BCM2835_DMA_SOURCE_AD stays inside a valid CB
                    if (!loadCbHeader(c, ram)) {
                        self.active_mask &= ~ch_bit;
                    }
                }
            }
        }
    }

    /// Peripherals are at `0x7e000000` on the VideoCore bus; every other bus address is RAM
    /// (`0x20000000` is the ARM's physical address for them on the BCM2835, not the DMA's).
    fn isPeripAddr(bus_addr: u32) bool {
        return (bus_addr & 0xFF000000) == 0x7E000000;
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
            if (x_len > 0 and !d_ign and d_inc and !isPeripAddr(dst) and !isPeripAddr(dst +% (x_len - 1))) {
                const dp: usize = dst & vc_bus.ramMask(ram.len);
                if (dp + x_len <= ram.len) {
                    if (s_ign) {
                        @memset(ram[dp .. dp + x_len], 0);
                        if (s_inc) src +%= x_len;
                        dst +%= x_len;
                        src = @bitCast(@as(i32, @bitCast(src)) +% s_stride);
                        dst = @bitCast(@as(i32, @bitCast(dst)) +% d_stride);
                        continue;
                    } else if (s_inc and !isPeripAddr(src) and !isPeripAddr(src +% (x_len - 1))) {
                        const sp: usize = src & vc_bus.ramMask(ram.len);
                        if (sp + x_len <= ram.len and (sp + x_len <= dp or dp + x_len <= sp)) {
                            @memcpy(ram[dp .. dp + x_len], ram[sp .. sp + x_len]);
                            src +%= x_len;
                            dst +%= x_len;
                            src = @bitCast(@as(i32, @bitCast(src)) +% s_stride);
                            dst = @bitCast(@as(i32, @bitCast(dst)) +% d_stride);
                            continue;
                        }
                    } else if (!s_inc and !isPeripAddr(src) and (src & 3) == 0 and (dst & 3) == 0 and (x_len & 3) == 0) {
                        const sp: usize = src & vc_bus.ramMask(ram.len);
                        const word: u32 = if (sp + 4 <= ram.len) std.mem.readInt(u32, ram[sp..][0..4], .little) else 0;
                        const b0: u8 = @truncate(word);
                        if (word == @as(u32, b0) * 0x01010101) {
                            @memset(ram[dp .. dp + x_len], b0);
                        } else {
                            const vec8: @Vector(8, u32) = @splat(word);
                            var off: usize = 0;
                            while (off + 32 <= x_len) : (off += 32) {
                                ram[dp + off ..][0..32].* = @bitCast(vec8);
                            }
                            while (off < x_len) : (off += 4) {
                                std.mem.writeInt(u32, ram[dp + off ..][0..4], word, .little);
                            }
                        }
                        dst +%= x_len;
                        src = @bitCast(@as(i32, @bitCast(src)) +% s_stride);
                        dst = @bitCast(@as(i32, @bitCast(dst)) +% d_stride);
                        continue;
                    } else if (!s_inc and !s_ign and isPeripAddr(src) and (x_len & 3) == 0) {
                        if (mmio) |m| {
                            if (m.readFifoBulkFn) |bulkRead| {
                                if (bulkRead(m.ctx, src, ram[dp .. dp + x_len])) {
                                    dst +%= x_len;
                                    src = @bitCast(@as(i32, @bitCast(src)) +% s_stride);
                                    dst = @bitCast(@as(i32, @bitCast(dst)) +% d_stride);
                                    continue;
                                }
                            }
                        }
                    }
                }
            } else if (x_len > 0 and !s_ign and s_inc and !isPeripAddr(src) and !isPeripAddr(src +% (x_len - 1)) and !d_ign and !d_inc and isPeripAddr(dst) and (x_len & 3) == 0) {
                const sp: usize = src & vc_bus.ramMask(ram.len);
                if (sp + x_len <= ram.len) {
                    if (mmio) |m| {
                        if (m.writeFifoBulkFn) |bulkWrite| {
                            if (bulkWrite(m.ctx, dst, ram[sp .. sp + x_len])) {
                                src +%= x_len;
                                src = @bitCast(@as(i32, @bitCast(src)) +% s_stride);
                                dst = @bitCast(@as(i32, @bitCast(dst)) +% d_stride);
                                continue;
                            }
                        }
                    }
                }
            }

            var rem = x_len;
            while (rem > 0) {
                if (rem >= 4 and (src & 3) == 0 and (dst & 3) == 0) {
                    var word: u32 = 0;
                    if (!s_ign) {
                        if (isPeripAddr(src)) {
                            if (mmio) |m| word = m.read32Fn(m.ctx, src);
                        } else {
                            const sp = src & vc_bus.ramMask(ram.len);
                            if (sp + 4 <= ram.len) word = std.mem.readInt(u32, ram[sp..][0..4], .little);
                        }
                    }
                    if (!d_ign) {
                        if (isPeripAddr(dst)) {
                            if (mmio) |m| m.write32Fn(m.ctx, dst, word);
                        } else {
                            const dp = dst & vc_bus.ramMask(ram.len);
                            if (dp + 4 <= ram.len) std.mem.writeInt(u32, ram[dp..][0..4], word, .little);
                        }
                    }
                    if (s_inc) src +%= 4;
                    if (d_inc) dst +%= 4;
                    rem -= 4;
                } else {
                    var byte: u8 = 0;
                    if (!s_ign and !isPeripAddr(src)) {
                        const sp = src & vc_bus.ramMask(ram.len);
                        if (sp < ram.len) byte = ram[sp];
                    }
                    if (!d_ign and !isPeripAddr(dst)) {
                        const dp = dst & vc_bus.ramMask(ram.len);
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
    var ram: [1024]u8 = @splat(0);

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

test "DMA reaches RAM at bus address 0x20000000" {
    var dma = DmaController{};
    const ram = try std.heap.page_allocator.alloc(u8, 0x2000_1000);
    defer std.heap.page_allocator.free(ram);

    std.mem.writeInt(u32, ram[0x2000_0100..][0..4], 0xCAFEBABE, .little);

    const cb: u32 = 0x20;
    std.mem.writeInt(u32, ram[cb + 0 ..][0..4], DmaController.TI_S_INC | DmaController.TI_D_INC, .little);
    std.mem.writeInt(u32, ram[cb + 4 ..][0..4], 0x2000_0100, .little); // src: RAM through the 0x00000000 alias
    std.mem.writeInt(u32, ram[cb + 8 ..][0..4], 0xc000_0200, .little);
    std.mem.writeInt(u32, ram[cb + 12 ..][0..4], 4, .little);
    std.mem.writeInt(u32, ram[cb + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[cb + 20 ..][0..4], 0, .little);

    dma.write32(0x04, 0xc0000020, ram, null);
    dma.write32(0x00, DmaController.CS_ACTIVE, ram, null);

    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), std.mem.readInt(u32, ram[0x200..0x204], .little));
}

test "DMA zero-fill and constant-word fill fast paths" {
    var dma = DmaController{};
    var ram: [1024]u8 = @splat(0xAA);

    // 1. TI_S_IGNORE zero-fill 64 bytes at 0x200
    const cb1: u32 = 0x20;
    std.mem.writeInt(u32, ram[cb1 + 0 ..][0..4], DmaController.TI_S_IGNORE | DmaController.TI_D_INC, .little);
    std.mem.writeInt(u32, ram[cb1 + 4 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[cb1 + 8 ..][0..4], 0xc0000200, .little);
    std.mem.writeInt(u32, ram[cb1 + 12 ..][0..4], 64, .little);
    std.mem.writeInt(u32, ram[cb1 + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[cb1 + 20 ..][0..4], 0, .little);

    dma.write32(0x04, 0xc0000020, &ram, null);
    dma.write32(0x00, DmaController.CS_ACTIVE, &ram, null);

    for (ram[0x200..0x240]) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
    try std.testing.expectEqual(@as(u8, 0xAA), ram[0x240]);

    // 2. Constant-word fill (!TI_S_INC) with 0xDEADBEEF across 76 bytes (19 words: 2x32B SIMD + 3x4B tail) at 0x280
    std.mem.writeInt(u32, ram[0x100..0x104], 0xDEADBEEF, .little);
    std.mem.writeInt(u32, ram[cb1 + 0 ..][0..4], DmaController.TI_D_INC, .little);
    std.mem.writeInt(u32, ram[cb1 + 4 ..][0..4], 0xc0000100, .little);
    std.mem.writeInt(u32, ram[cb1 + 8 ..][0..4], 0xc0000280, .little);
    std.mem.writeInt(u32, ram[cb1 + 12 ..][0..4], 76, .little);
    std.mem.writeInt(u32, ram[cb1 + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[cb1 + 20 ..][0..4], 0, .little);

    dma.write32(0x04, 0xc0000020, &ram, null);
    dma.write32(0x00, DmaController.CS_ACTIVE, &ram, null);

    for (0..19) |i| {
        try std.testing.expectEqual(@as(u32, 0xDEADBEEF), std.mem.readInt(u32, ram[0x280 + i * 4 ..][0..4], .little));
    }
    try std.testing.expectEqual(@as(u8, 0xAA), ram[0x280 + 76]);
}
