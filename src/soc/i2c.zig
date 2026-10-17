const std = @import("std");

/// BCM2835 Broadcom Serial Controller (`brcm,bcm2835-i2c`)
/// Used for BSC0 (`0x20205000`), BSC1 (`0x20804000`), and BSC2 (`0x20805000` HDMI DDC).
pub const BscController = struct {
    pub const BSC0_BASE: u32 = 0x20205000;
    pub const BSC1_BASE: u32 = 0x20804000;
    pub const BSC2_BASE: u32 = 0x20805000;
    pub const SIZE: u32 = 0x20;

    // C register bits
    pub const C_READ: u32 = 1 << 0;
    pub const C_CLEAR: u32 = 3 << 4;
    pub const C_ST: u32 = 1 << 7;
    pub const C_INTD: u32 = 1 << 8;
    pub const C_INTT: u32 = 1 << 9;
    pub const C_INTR: u32 = 1 << 10;
    pub const C_I2CEN: u32 = 1 << 15;

    // S register bits
    pub const S_TA: u32 = 1 << 0;
    pub const S_DONE: u32 = 1 << 1;
    pub const S_TXW: u32 = 1 << 2;
    pub const S_RXR: u32 = 1 << 3;
    pub const S_TXD: u32 = 1 << 4;
    pub const S_RXD: u32 = 1 << 5;
    pub const S_TXE: u32 = 1 << 6;
    pub const S_RXF: u32 = 1 << 7;
    pub const S_ERR: u32 = 1 << 8;
    pub const S_CLKT: u32 = 1 << 9;

    has_hdmi_edid: bool = false,
    edid: [256]u8 = buildHdmiEdid(1280, 720),

    c: u32 = 0,
    s: u32 = S_TXD | S_TXE,
    dlen: u32 = 0,
    slave_addr: u32 = 0,
    div: u32 = 0x5dc,
    del: u32 = 0x00300030,
    clkt: u32 = 0x40,

    edid_offset: u8 = 0,
    edid_segment: u8 = 0,
    tx_remaining: u32 = 0,
    rx_remaining: u32 = 0,

    pub fn init(has_hdmi_edid: bool, width: u16, height: u16) BscController {
        return .{
            .has_hdmi_edid = has_hdmi_edid,
            .edid = buildHdmiEdid(width, height),
        };
    }

    pub fn irqPending(self: *const BscController) bool {
        if ((self.c & C_I2CEN) == 0) return false;
        const status = self.statusWord();
        if ((self.c & C_INTD) != 0 and (status & S_DONE) != 0) return true;
        if ((self.c & C_INTT) != 0 and (status & S_TXW) != 0) return true;
        if ((self.c & C_INTR) != 0 and (status & S_RXR) != 0) return true;
        return false;
    }

    fn statusWord(self: *const BscController) u32 {
        var st = self.s | S_TXD | S_TXE;
        if (self.tx_remaining > 0) {
            st |= S_TA | S_TXW;
        }
        if (self.rx_remaining > 0) {
            st |= S_RXD | S_RXR;
        }
        return st;
    }

    pub fn read32(self: *BscController, offset: u32) u32 {
        return switch (offset) {
            0x00 => self.c,
            0x04 => self.statusWord(),
            0x08 => self.dlen,
            0x0c => self.slave_addr,
            0x10 => blk: { // FIFO read
                if (self.rx_remaining > 0) {
                    const b = self.edid[self.edid_offset];
                    self.edid_offset +%= 1;
                    self.rx_remaining -= 1;
                    break :blk b;
                }
                break :blk 0;
            },
            0x14 => self.div,
            0x18 => self.del,
            0x1c => self.clkt,
            else => 0,
        };
    }

    pub fn write32(self: *BscController, offset: u32, val: u32) void {
        switch (offset) {
            0x00 => { // C
                if ((val & C_CLEAR) != 0) {
                    self.tx_remaining = 0;
                    self.rx_remaining = 0;
                }
                self.c = val & ~(C_ST | C_CLEAR);
                if ((val & C_I2CEN) != 0 and (val & C_ST) != 0) {
                    self.startTransfer();
                }
            },
            0x04 => { // S (W1C for DONE, ERR, CLKT)
                self.s &= ~(val & (S_DONE | S_ERR | S_CLKT));
            },
            0x08 => self.dlen = val & 0xffff,
            0x0c => self.slave_addr = val & 0x7f,
            0x10 => { // FIFO write
                const byte: u8 = @truncate(val);
                if (self.has_hdmi_edid) {
                    if (self.slave_addr == 0x50) {
                        self.edid_offset = byte;
                    } else if (self.slave_addr == 0x30) {
                        self.edid_segment = byte;
                    }
                }
                if (self.tx_remaining > 0) {
                    self.tx_remaining -= 1;
                    if (self.tx_remaining == 0) {
                        self.s |= S_DONE;
                    }
                }
            },
            0x14 => self.div = val,
            0x18 => self.del = val,
            0x1c => self.clkt = val,
            else => {},
        }
    }

    fn startTransfer(self: *BscController) void {
        self.s &= ~(S_DONE | S_ERR | S_CLKT);
        self.tx_remaining = 0;
        self.rx_remaining = 0;

        const valid_slave = self.has_hdmi_edid and (self.slave_addr == 0x50 or self.slave_addr == 0x30);
        if (!valid_slave) {
            self.s |= S_ERR | S_DONE;
            return;
        }

        if (self.dlen == 0) {
            self.s |= S_DONE;
            return;
        }

        if ((self.c & C_READ) != 0) {
            self.rx_remaining = self.dlen;
            self.s |= S_DONE;
        } else {
            self.tx_remaining = self.dlen;
        }
    }

    /// Generates a 256-byte EDID (Block 0: EDID 1.3 + Detailed Timing Descriptor for `width`x`height`@60Hz,
    /// Block 1: CTA-861 Extension Block with HDMI VSDB `00-0C-03`).
    pub fn buildHdmiEdid(width: u16, height: u16) [256]u8 {
        var b: [256]u8 = @splat(0);

        // 0x00..0x07: EDID Header
        const header = [_]u8{ 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 };
        @memcpy(b[0..8], &header);

        // 0x08..0x11: Manufacturer "FXP" (FauxPi), Product 0x0001, Serial 1, Week 1, Year 2024 (34)
        b[8] = 0x1b;
        b[9] = 0x10;
        b[10] = 0x01;
        b[11] = 0x00;
        b[12] = 0x01;
        b[16] = 1;
        b[17] = 34;

        // 0x12..0x13: EDID Version 1.3
        b[18] = 1;
        b[19] = 3;

        // 0x14..0x18: Digital input (0x80), 52cm x 29cm, Gamma 2.2 (120), RGB + Preferred Timing Mode (0x0a)
        b[20] = 0x80;
        b[21] = 52;
        b[22] = 29;
        b[23] = 120;
        b[24] = 0x0a;

        // 0x19..0x22: sRGB chromaticity coordinates
        const chrom = [_]u8{ 0xee, 0x91, 0xa3, 0x54, 0x4c, 0x99, 0x26, 0x0f, 0x50, 0x54 };
        @memcpy(b[25..35], &chrom);

        // 0x23..0x25: Established timings (640x480@60, 800x600@60, 1024x768@60)
        b[35] = 0x21;
        b[36] = 0x08;
        b[37] = 0x00;

        // 0x26..0x35: Standard timings (1280x720@60 = 0x81, 0xc0; unused = 0x01, 0x01)
        b[38] = 0x81;
        b[39] = 0xc0;
        var st_idx: usize = 40;
        while (st_idx < 54) : (st_idx += 2) {
            b[st_idx] = 0x01;
            b[st_idx + 1] = 0x01;
        }

        // 0x36..0x47: Detailed Timing Descriptor 1 (Preferred Mode: width x height @ 60Hz)
        // For 1280x720@60Hz: pixel clock = 74.25 MHz (7425 in 10kHz units = 0x1d01), hblank = 370, vblank = 30
        const hblank: u16 = 370;
        const vblank: u16 = 30;
        const pclk_10khz: u16 = 7425;
        b[54] = @truncate(pclk_10khz);
        b[55] = @truncate(pclk_10khz >> 8);
        b[56] = @truncate(width);
        b[57] = @truncate(hblank);
        b[58] = (@as(u8, @truncate(width >> 8)) << 4) | @as(u8, @truncate(hblank >> 8));
        b[59] = @truncate(height);
        b[60] = @truncate(vblank);
        b[61] = (@as(u8, @truncate(height >> 8)) << 4) | @as(u8, @truncate(vblank >> 8));
        // Hsync offset = 110, Hsync pulse = 40, Vsync offset = 5, Vsync pulse = 5
        b[62] = 110;
        b[63] = 40;
        b[64] = (5 << 4) | 5;
        b[65] = 0x00;
        // Image size 520mm x 290mm
        b[66] = @truncate(@as(u16, 520));
        b[67] = @truncate(@as(u16, 290));
        b[68] = ((520 >> 8) << 4) | (290 >> 8);
        b[69] = 0;
        b[70] = 0;
        b[71] = 0x1e; // Digital separate sync, +hsync, +vsync

        // 0x48..0x59: Descriptor 2 - Monitor Name ("FauxPi HDMI")
        const desc_name = [_]u8{ 0x00, 0x00, 0x00, 0xfc, 0x00, 'F', 'a', 'u', 'x', 'P', 'i', ' ', 'H', 'D', 'M', 'I', 0x0a, ' ' };
        @memcpy(b[72..90], &desc_name);

        // 0x5a..0x6b: Descriptor 3 - Monitor Range Limits (50-75Hz V, 30-85kHz H, 150MHz max pclk)
        const desc_range = [_]u8{ 0x00, 0x00, 0x00, 0xfd, 0x00, 50, 75, 30, 85, 15, 0x00, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20 };
        @memcpy(b[90..108], &desc_range);

        // 0x6c..0x7d: Descriptor 4 - Dummy descriptor
        b[111] = 0x10;

        // 0x7e: 1 Extension block (CTA-861)
        b[126] = 1;

        // Compute Block 0 checksum
        var sum0: u8 = 0;
        for (b[0..127]) |v| sum0 +%= v;
        b[127] = 0 -% sum0;

        // Block 1 (128..255): CTA-861 Rev 3 Extension Block with HDMI VSDB
        b[128] = 0x02; // CTA-861 tag
        b[129] = 0x03; // Revision 3
        b[130] = 16; // DTDs start at offset 16 (byte 144)
        b[131] = 0x40; // Basic audio, underscan=0

        // Video Data Block (tag=2, length=1): VIC 4 (1280x720p@60Hz, native)
        b[132] = (2 << 5) | 1;
        b[133] = 0x80 | 4;

        // Vendor-Specific Data Block (tag=3, length=5): IEEE OUI 00-0C-03 (HDMI Licensing), CEC 1.0.0.0
        b[134] = (3 << 5) | 5;
        b[135] = 0x03;
        b[136] = 0x0c;
        b[137] = 0x00;
        b[138] = 0x10;
        b[139] = 0x00;

        // Compute Block 1 checksum
        var sum1: u8 = 0;
        for (b[128..255]) |v| sum1 +%= v;
        b[255] = 0 -% sum1;

        return b;
    }
};

test "BSC2 HDMI EDID read via I2C 0x50" {
    var bsc2 = BscController.init(true, 1280, 720);

    // Step 1: Write 1 byte (offset 0) to slave 0x50
    bsc2.write32(0x0c, 0x50); // A = 0x50
    bsc2.write32(0x08, 1); // DLEN = 1
    bsc2.write32(0x00, BscController.C_I2CEN | BscController.C_ST | BscController.C_INTD | BscController.C_INTT);
    try std.testing.expect(bsc2.irqPending()); // INTT (TXW) pending
    bsc2.write32(0x10, 0x00); // write offset 0 to FIFO
    try std.testing.expect((bsc2.read32(0x04) & BscController.S_DONE) != 0);

    // Clear S_DONE and read 128 bytes from slave 0x50
    bsc2.write32(0x04, BscController.S_DONE);
    bsc2.write32(0x08, 128);
    bsc2.write32(0x00, BscController.C_I2CEN | BscController.C_ST | BscController.C_READ | BscController.C_INTD | BscController.C_INTR);

    var buf: [128]u8 = undefined;
    var sum: u8 = 0;
    for (&buf) |*b| {
        b.* = @truncate(bsc2.read32(0x10));
        sum +%= b.*;
    }
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 }, buf[0..8]);
    try std.testing.expectEqual(@as(u8, 0), sum);
}
