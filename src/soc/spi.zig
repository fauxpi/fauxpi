const std = @import("std");

/// BCM2835 Primary SPI0 Controller (`brcm,bcm2835-spi`) at `0x20204000` (size `0x200`).
/// Supports PIO (8-bit FIFO), interrupt-driven transfers (IRQ 54 / Bank 2 bit 22),
/// and 32-bit DMA transfers via `PERMAP 6` (TX) and `PERMAP 7` (RX).
pub const Spi0 = struct {
    pub const BASE_ADDR: u32 = 0x20204000;
    pub const SIZE: u32 = 0x200;

    // Register offsets
    pub const REG_CS: u32 = 0x00;
    pub const REG_FIFO: u32 = 0x04;
    pub const REG_CLK: u32 = 0x08;
    pub const REG_DLEN: u32 = 0x0c;
    pub const REG_LTOH: u32 = 0x10;
    pub const REG_DC: u32 = 0x14;

    // CS register bits
    pub const CS_LEN_LONG: u32 = 1 << 25;
    pub const CS_DMA_LEN: u32 = 1 << 24;
    pub const CS_CSPOL2: u32 = 1 << 23;
    pub const CS_CSPOL1: u32 = 1 << 22;
    pub const CS_CSPOL0: u32 = 1 << 21;
    pub const CS_RXF: u32 = 1 << 20;
    pub const CS_RXR: u32 = 1 << 19;
    pub const CS_TXD: u32 = 1 << 18;
    pub const CS_RXD: u32 = 1 << 17;
    pub const CS_DONE: u32 = 1 << 16;
    pub const CS_LEN: u32 = 1 << 13;
    pub const CS_REN: u32 = 1 << 12;
    pub const CS_ADCS: u32 = 1 << 11;
    pub const CS_INTR: u32 = 1 << 10;
    pub const CS_INTD: u32 = 1 << 9;
    pub const CS_DMAEN: u32 = 1 << 8;
    pub const CS_TA: u32 = 1 << 7;
    pub const CS_CSPOL: u32 = 1 << 6;
    pub const CS_CLEAR_RX: u32 = 1 << 5;
    pub const CS_CLEAR_TX: u32 = 1 << 4;
    pub const CS_CPOL: u32 = 1 << 3;
    pub const CS_CPHA: u32 = 1 << 2;
    pub const CS_CS_MASK: u32 = 0x3;

    pub const HW_FIFO_SIZE: usize = 64;
    pub const HW_FIFO_3_4: usize = 48;
    pub const RX_BUF_CAPACITY: usize = 65536;

    const WRITABLE_CS_MASK: u32 = CS_LEN_LONG | CS_DMA_LEN | CS_CSPOL2 | CS_CSPOL1 | CS_CSPOL0 |
        CS_LEN | CS_REN | CS_ADCS | CS_INTR | CS_INTD | CS_DMAEN | CS_TA | CS_CSPOL |
        CS_CPOL | CS_CPHA | CS_CS_MASK;

    cs: u32 = 0,
    clk: u32 = 0,
    dlen: u32 = 0,
    ltoh: u32 = 1,
    dc: u32 = 0x30201020,

    /// Internal RX FIFO ring buffer (sized to 64 KiB so full DMA TX bursts complete before RX DMA is armed)
    rx_fifo: [RX_BUF_CAPACITY]u8 = [_]u8{0} ** RX_BUF_CAPACITY,
    rx_head: u16 = 0,
    rx_tail: u16 = 0,
    rx_count: usize = 0,

    /// When true, MOSI bytes are looped back into MISO RX FIFO; otherwise `miso_fill_byte` is shifted in.
    loopback: bool = false,
    miso_fill_byte: u8 = 0x00,

    pub fn clearRxFifo(self: *Spi0) void {
        self.rx_head = 0;
        self.rx_tail = 0;
        self.rx_count = 0;
    }

    fn pushRxByte(self: *Spi0, tx_byte: u8) void {
        if (self.rx_count >= RX_BUF_CAPACITY) return;
        self.rx_fifo[self.rx_tail] = if (self.loopback) tx_byte else self.miso_fill_byte;
        self.rx_tail +%= 1;
        self.rx_count += 1;
    }

    fn popRxByte(self: *Spi0) u8 {
        if (self.rx_count == 0) return 0;
        const b = self.rx_fifo[self.rx_head];
        self.rx_head +%= 1;
        self.rx_count -= 1;
        return b;
    }

    fn isDone(self: *const Spi0) bool {
        if ((self.cs & CS_TA) == 0) return false;
        if ((self.cs & CS_DMAEN) != 0) return self.dlen == 0;
        return true;
    }

    fn isRxr(self: *const Spi0) bool {
        return (self.cs & CS_TA) != 0 and self.rx_count >= HW_FIFO_3_4;
    }

    pub fn irqPending(self: *const Spi0) bool {
        if ((self.cs & CS_TA) == 0) return false;
        const done_irq = (self.cs & CS_INTD) != 0 and self.isDone();
        const rxr_irq = (self.cs & CS_INTR) != 0 and self.isRxr();
        return done_irq or rxr_irq;
    }

    /// DMA DREQ `PERMAP 6` (SPI TX)
    pub fn txDreqReady(self: *const Spi0) bool {
        return (self.cs & CS_TA) != 0 and (self.cs & CS_DMAEN) != 0 and self.dlen > 0 and self.rx_count < RX_BUF_CAPACITY;
    }

    /// DMA DREQ `PERMAP 7` (SPI RX)
    pub fn rxDreqReady(self: *const Spi0) bool {
        return (self.cs & CS_TA) != 0 and (self.cs & CS_DMAEN) != 0 and self.rx_count > 0;
    }

    pub fn read32(self: *Spi0, offset: u32) u32 {
        return switch (offset) {
            REG_CS => blk: {
                var val = self.cs & WRITABLE_CS_MASK;
                if ((self.cs & CS_DMAEN) != 0 or self.rx_count < HW_FIFO_SIZE) {
                    val |= CS_TXD;
                }
                if (self.rx_count > 0) val |= CS_RXD;
                if (self.rx_count >= HW_FIFO_3_4) val |= CS_RXR;
                if (self.rx_count >= HW_FIFO_SIZE) val |= CS_RXF;
                if (self.isDone()) val |= CS_DONE;
                break :blk val;
            },
            REG_FIFO => blk: {
                if ((self.cs & CS_DMAEN) != 0 or (self.cs & CS_LEN_LONG) != 0) {
                    const count = @min(@as(usize, 4), self.rx_count);
                    var word: u32 = 0;
                    for (0..count) |i| {
                        word |= @as(u32, self.popRxByte()) << @intCast(i * 8);
                    }
                    break :blk word;
                }
                break :blk self.popRxByte();
            },
            REG_CLK => self.clk,
            REG_DLEN => self.dlen,
            REG_LTOH => self.ltoh,
            REG_DC => self.dc,
            else => 0,
        };
    }

    pub fn write32(self: *Spi0, offset: u32, val: u32) void {
        switch (offset) {
            REG_CS => {
                if ((val & CS_CLEAR_RX) != 0) {
                    self.clearRxFifo();
                }
                // Note: CLEAR_TX is instantaneous since TX shifts immediately into RX FIFO
                self.cs = val & WRITABLE_CS_MASK;
            },
            REG_FIFO => {
                if ((self.cs & CS_TA) == 0) return;
                if ((self.cs & CS_DMAEN) != 0 or (self.cs & CS_LEN_LONG) != 0) {
                    const count: usize = if (self.dlen > 0) @intCast(@min(@as(u32, 4), self.dlen)) else 4;
                    for (0..count) |i| {
                        const b: u8 = @truncate(val >> @intCast(i * 8));
                        self.pushRxByte(b);
                    }
                    if (self.dlen >= count) {
                        self.dlen -= @intCast(count);
                    } else {
                        self.dlen = 0;
                    }
                } else {
                    self.pushRxByte(@truncate(val));
                    if (self.dlen > 0) self.dlen -= 1;
                }
            },
            REG_CLK => self.clk = val & 0xffff,
            REG_DLEN => self.dlen = val & 0xffff,
            REG_LTOH => self.ltoh = val & 0x0f,
            REG_DC => self.dc = val,
            else => {},
        }
    }
};

/// BCM2835 Auxiliary SPI Controller (`brcm,bcm2835-aux-spi`) for `SPI1` (`0x20215080`) and `SPI2` (`0x202150c0`).
pub const AuxSpi = struct {
    pub const SIZE: u32 = 0x40;

    // Register offsets within the 0x40-byte block
    pub const REG_CNTL0: u32 = 0x00;
    pub const REG_CNTL1: u32 = 0x04;
    pub const REG_STAT: u32 = 0x08;
    pub const REG_PEEK: u32 = 0x0c;
    pub const REG_IO_BASE: u32 = 0x20;
    pub const REG_TXHOLD_BASE: u32 = 0x30;

    // CNTL0 bits
    pub const CNTL0_SPEED_MASK: u32 = 0xfff00000;
    pub const CNTL0_VAR_WIDTH: u32 = 1 << 14;
    pub const CNTL0_ENABLE: u32 = 1 << 11;
    pub const CNTL0_CLEARFIFO: u32 = 1 << 9;
    pub const CNTL0_MSBF_OUT: u32 = 1 << 6;
    pub const CNTL0_SHIFTLEN_MASK: u32 = 0x3f;

    // CNTL1 bits
    pub const CNTL1_TXEMPTY: u32 = 1 << 7;
    pub const CNTL1_IDLE: u32 = 1 << 6;
    pub const CNTL1_MSBF_IN: u32 = 1 << 1;

    // STAT bits
    pub const STAT_TX_FULL: u32 = 1 << 10;
    pub const STAT_TX_EMPTY: u32 = 1 << 9;
    pub const STAT_RX_FULL: u32 = 1 << 8;
    pub const STAT_RX_EMPTY: u32 = 1 << 7;
    pub const STAT_BUSY: u32 = 1 << 6;

    pub const FIFO_DEPTH: usize = 4;

    cntl0: u32 = 0,
    cntl1: u32 = 0,
    rx_fifo: [16]u32 = [_]u32{0} ** 16,
    rx_head: u4 = 0,
    rx_tail: u4 = 0,
    rx_count: u5 = 0,

    loopback: bool = false,
    miso_fill_word: u32 = 0,

    pub fn clearFifo(self: *AuxSpi) void {
        self.rx_head = 0;
        self.rx_tail = 0;
        self.rx_count = 0;
    }

    pub fn irqPending(self: *const AuxSpi) bool {
        if ((self.cntl0 & CNTL0_ENABLE) == 0 or (self.cntl0 & CNTL0_CLEARFIFO) != 0) return false;
        return (self.cntl1 & (CNTL1_TXEMPTY | CNTL1_IDLE)) != 0;
    }

    fn pushTransferWord(self: *AuxSpi, val: u32) void {
        if ((self.cntl0 & CNTL0_ENABLE) == 0 or (self.cntl0 & CNTL0_CLEARFIFO) != 0) return;
        if (self.rx_count >= 16) return;

        const width: u6 = if ((self.cntl0 & CNTL0_VAR_WIDTH) != 0)
            @truncate((val >> 24) & 0x3f)
        else
            @truncate(self.cntl0 & CNTL0_SHIFTLEN_MASK);

        const rx_word: u32 = if (self.loopback) blk: {
            if ((self.cntl0 & CNTL0_MSBF_OUT) != 0 and width > 0 and width < 24) {
                const shift: u5 = @intCast(24 - width);
                break :blk (val & 0x00ffffff) >> shift;
            }
            const mask: u32 = if (width == 0 or width >= 32) 0xffffffff else (@as(u32, 1) << @intCast(width)) - 1;
            break :blk val & mask;
        } else self.miso_fill_word;

        self.rx_fifo[self.rx_tail] = rx_word;
        self.rx_tail +%= 1;
        self.rx_count += 1;
    }

    fn popRxWord(self: *AuxSpi) u32 {
        if (self.rx_count == 0) return 0;
        const w = self.rx_fifo[self.rx_head];
        self.rx_head +%= 1;
        self.rx_count -= 1;
        return w;
    }

    pub fn read32(self: *AuxSpi, offset: u32) u32 {
        return switch (offset) {
            REG_CNTL0 => self.cntl0,
            REG_CNTL1 => self.cntl1,
            REG_STAT => blk: {
                var st: u32 = STAT_TX_EMPTY | (@as(u32, self.rx_count) << 16);
                if (self.rx_count == 0) st |= STAT_RX_EMPTY;
                if (self.rx_count >= FIFO_DEPTH) st |= STAT_RX_FULL | STAT_TX_FULL;
                break :blk st;
            },
            REG_PEEK => if (self.rx_count > 0) self.rx_fifo[self.rx_head] else 0,
            0x20, 0x24, 0x28, 0x2c, 0x30, 0x34, 0x38, 0x3c => self.popRxWord(),
            else => 0,
        };
    }

    pub fn write32(self: *AuxSpi, offset: u32, val: u32) void {
        switch (offset) {
            REG_CNTL0 => {
                self.cntl0 = val;
                if ((val & CNTL0_CLEARFIFO) != 0) {
                    self.clearFifo();
                }
            },
            REG_CNTL1 => self.cntl1 = val,
            0x20, 0x24, 0x28, 0x2c, 0x30, 0x34, 0x38, 0x3c => self.pushTransferWord(val),
            else => {},
        }
    }
};

test "Spi0 PIO and interrupt-driven transfer with loopback" {
    var spi = Spi0{ .loopback = true };

    // Start transfer active (TA = 1)
    spi.write32(Spi0.REG_CLK, 4);
    spi.write32(Spi0.REG_CS, Spi0.CS_TA | Spi0.CS_CLEAR_RX | Spi0.CS_CLEAR_TX);

    // TXD should be set, RXD should be clear, DONE should be set
    try std.testing.expect((spi.read32(Spi0.REG_CS) & Spi0.CS_TXD) != 0);
    try std.testing.expect((spi.read32(Spi0.REG_CS) & Spi0.CS_RXD) == 0);
    try std.testing.expect((spi.read32(Spi0.REG_CS) & Spi0.CS_DONE) != 0);

    // Write 3 bytes in PIO mode
    spi.write32(Spi0.REG_FIFO, 0xA5);
    spi.write32(Spi0.REG_FIFO, 0x5A);
    spi.write32(Spi0.REG_FIFO, 0x3C);

    try std.testing.expect((spi.read32(Spi0.REG_CS) & Spi0.CS_RXD) != 0);
    try std.testing.expectEqual(@as(u32, 0xA5), spi.read32(Spi0.REG_FIFO));
    try std.testing.expectEqual(@as(u32, 0x5A), spi.read32(Spi0.REG_FIFO));
    try std.testing.expectEqual(@as(u32, 0x3C), spi.read32(Spi0.REG_FIFO));
    try std.testing.expect((spi.read32(Spi0.REG_CS) & Spi0.CS_RXD) == 0);

    // Enable INTD -> IRQ should assert since DONE is 1
    spi.write32(Spi0.REG_CS, Spi0.CS_TA | Spi0.CS_INTD);
    try std.testing.expect(spi.irqPending());
}

test "AuxSpi variable-width 3-byte transfer matches spi-bcm2835aux packing" {
    var aux_spi = AuxSpi{ .loopback = true };

    aux_spi.write32(AuxSpi.REG_CNTL1, AuxSpi.CNTL1_MSBF_IN);
    aux_spi.write32(
        AuxSpi.REG_CNTL0,
        AuxSpi.CNTL0_ENABLE | AuxSpi.CNTL0_VAR_WIDTH | AuxSpi.CNTL0_MSBF_OUT,
    );

    // Pack 3 bytes [0x12, 0x34, 0x56] with width = 24 bits in [29:24], just like bcm2835aux_wr_fifo()
    const tx3: u32 = (24 << 24) | (0x12 << 16) | (0x34 << 8) | 0x56;
    aux_spi.write32(AuxSpi.REG_TXHOLD_BASE, tx3);

    // Pack 1 byte [0xAB] with width = 8 bits in [29:24] and byte in [23:16]
    const tx1: u32 = (8 << 24) | (0xAB << 16);
    aux_spi.write32(AuxSpi.REG_IO_BASE, tx1);

    try std.testing.expectEqual(@as(u32, 0x00123456), aux_spi.read32(AuxSpi.REG_IO_BASE));
    try std.testing.expectEqual(@as(u32, 0x000000AB), aux_spi.read32(AuxSpi.REG_IO_BASE));
    try std.testing.expect((aux_spi.read32(AuxSpi.REG_STAT) & AuxSpi.STAT_RX_EMPTY) != 0);
}
