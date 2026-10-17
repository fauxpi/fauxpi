const std = @import("std");
const host_posix = @import("../host/posix.zig");
const spi_mod = @import("spi.zig");

/// ARM PrimeCell PL011 UART0 (`0x20201000`, size `0x1000` for AMBA PeriphID at `0xfe0..0xffc`).
pub const Pl011Uart = struct {
    pub const BASE_ADDR: u32 = 0x20201000;
    pub const SIZE: u32 = 0x1000;

    pub const INT_RX: u32 = 1 << 4;
    pub const INT_TX: u32 = 1 << 5;
    pub const INT_RT: u32 = 1 << 6;

    rx_fifo: [64]u8 = @splat(0),
    rx_head: u6 = 0,
    rx_tail: u6 = 0,
    rx_count: u7 = 0,

    ibrd: u32 = 0,
    fbrd: u32 = 0,
    lcrh: u32 = 0,
    cr: u32 = 0x0300,
    ifls: u32 = 0x12,
    imsc: u32 = 0,
    ris: u32 = INT_TX, // TX is always ready

    stdout_enabled: bool = true,
    tx_log: [256]u8 = @splat(0),
    tx_log_len: usize = 0,

    /// When set, transmitted bytes are held in `tx_capture_buf` for an attached device
    /// (the Bluetooth controller) instead of going to the console.
    tx_capture: bool = false,
    tx_capture_buf: [64]u8 = undefined,
    tx_capture_len: usize = 0,

    pub fn rxSpace(self: *const Pl011Uart) usize {
        return 64 - @as(usize, self.rx_count);
    }

    pub fn pushRx(self: *Pl011Uart, byte: u8) void {
        if (self.rx_count < 64) {
            self.rx_fifo[self.rx_tail] = byte;
            self.rx_tail +%= 1;
            self.rx_count += 1;
            self.ris |= INT_RX | INT_RT;
        }
    }

    fn popRx(self: *Pl011Uart) u8 {
        if (self.rx_count == 0) return 0;
        const b = self.rx_fifo[self.rx_head];
        self.rx_head +%= 1;
        self.rx_count -= 1;
        if (self.rx_count == 0) {
            self.ris &= ~(INT_RX | INT_RT);
        }
        return b;
    }

    pub fn irqPending(self: *const Pl011Uart) bool {
        return (self.ris & self.imsc) != 0;
    }

    pub fn read32(self: *Pl011Uart, offset: u32) u32 {
        return switch (offset) {
            0x00 => self.popRx(), // DR
            0x04 => 0, // RSRECR
            0x18 => blk: { // FR
                var fr: u32 = 1 << 7; // TXFE (TX FIFO empty)
                if (self.rx_count == 0) fr |= (1 << 4); // RXFE
                if (self.rx_count >= 64) fr |= (1 << 6); // RXFF
                break :blk fr;
            },
            0x24 => self.ibrd,
            0x28 => self.fbrd,
            0x2c => self.lcrh,
            0x30 => self.cr,
            0x34 => self.ifls,
            0x38 => self.imsc,
            0x3c => self.ris,
            0x40 => self.ris & self.imsc, // MIS
            // AMBA PrimeCell PeriphID (PL011 r1p5 = 0x00241011)
            0xfe0 => 0x11,
            0xfe4 => 0x10,
            0xfe8 => 0x24,
            0xfec => 0x00,
            // AMBA PrimeCell CellID (0xb105f00d)
            0xff0 => 0x0d,
            0xff4 => 0xf0,
            0xff8 => 0x05,
            0xffc => 0xb1,
            else => 0,
        };
    }

    pub fn write32(self: *Pl011Uart, offset: u32, val: u32) void {
        switch (offset) {
            0x00 => { // DR
                const ch: u8 = @truncate(val);
                self.ris |= INT_TX;
                if (self.tx_capture) {
                    if (self.tx_capture_len < self.tx_capture_buf.len) {
                        self.tx_capture_buf[self.tx_capture_len] = ch;
                        self.tx_capture_len += 1;
                    }
                    return;
                }
                if (self.tx_log_len < self.tx_log.len) {
                    self.tx_log[self.tx_log_len] = ch;
                    self.tx_log_len += 1;
                }
                if (self.stdout_enabled) {
                    const buf = [1]u8{ch};
                    host_posix.writeStdout(&buf);
                }
                self.ris |= INT_TX;
            },
            0x24 => self.ibrd = val,
            0x28 => self.fbrd = val,
            0x2c => self.lcrh = val,
            0x30 => self.cr = val,
            0x34 => self.ifls = val,
            0x38 => self.imsc = val,
            0x44 => { // ICR
                self.ris &= ~val;
                if (self.rx_count > 0) self.ris |= INT_RX;
            },
            else => {},
        }
    }
};

/// BCM2835 AUX Peripherals (`brcm,bcm2835-aux` at `0x20215000`, size `0x100`):
/// - `0x00..0x07`: `AUX_IRQ` and `AUX_ENABLES` (bit 0 = Mini-UART, bit 1 = SPI1, bit 2 = SPI2)
/// - `0x40..0x6b`: Mini-UART1 (`brcm,bcm2835-aux-uart`)
/// - `0x80..0xbf`: Auxiliary SPI1 (`brcm,bcm2835-aux-spi`)
/// - `0xc0..0xff`: Auxiliary SPI2 (`brcm,bcm2835-aux-spi`)
pub const AuxMiniUart = struct {
    pub const BASE_ADDR: u32 = 0x20215000;
    pub const SIZE: u32 = 0x100;

    pub const AUX_ENABLE_MU: u32 = 1 << 0;
    pub const AUX_ENABLE_SPI1: u32 = 1 << 1;
    pub const AUX_ENABLE_SPI2: u32 = 1 << 2;

    enables: u32 = AUX_ENABLE_MU, // Mini-UART enabled by default
    ier: u32 = 0,
    lcr: u32 = 3,
    mcr: u32 = 0,
    scratch: u32 = 0,
    cntl: u32 = 3,
    baud: u32 = 270,
    dll: u32 = 0,
    dlm: u32 = 0,
    tx_irq_pending: bool = false,

    rx_fifo: [64]u8 = @splat(0),
    rx_head: u6 = 0,
    rx_tail: u6 = 0,
    rx_count: u7 = 0,

    spi1: spi_mod.AuxSpi = .{},
    spi2: spi_mod.AuxSpi = .{},

    stdout_enabled: bool = true,

    /// When set, transmitted bytes are held in `tx_capture_buf` for an attached device
    /// (the Bluetooth controller with `dtoverlay=miniuart-bt`) instead of going to the console.
    tx_capture: bool = false,
    tx_capture_buf: [64]u8 = undefined,
    tx_capture_len: usize = 0,

    pub fn rxSpace(self: *const AuxMiniUart) usize {
        return 64 - @as(usize, self.rx_count);
    }

    pub fn pushRx(self: *AuxMiniUart, byte: u8) void {
        if (self.rx_count < 64) {
            self.rx_fifo[self.rx_tail] = byte;
            self.rx_tail +%= 1;
            self.rx_count += 1;
        }
    }

    fn muIrqPending(self: *const AuxMiniUart) bool {
        if ((self.enables & AUX_ENABLE_MU) == 0) return false;
        const rx_irq = (self.ier & 1) != 0 and self.rx_count > 0;
        const tx_irq = (self.ier & 2) != 0 and self.tx_irq_pending;
        return rx_irq or tx_irq;
    }

    pub fn auxIrqStatus(self: *const AuxMiniUart) u32 {
        var irq: u32 = 0;
        if (self.muIrqPending()) irq |= AUX_ENABLE_MU;
        if ((self.enables & AUX_ENABLE_SPI1) != 0 and self.spi1.irqPending()) irq |= AUX_ENABLE_SPI1;
        if ((self.enables & AUX_ENABLE_SPI2) != 0 and self.spi2.irqPending()) irq |= AUX_ENABLE_SPI2;
        return irq;
    }

    pub fn irqPending(self: *const AuxMiniUart) bool {
        return self.auxIrqStatus() != 0;
    }

    pub fn read32(self: *AuxMiniUart, offset: u32) u32 {
        if (offset >= 0x80 and offset < 0xc0) {
            return self.spi1.read32(offset - 0x80);
        }
        if (offset >= 0xc0 and offset < 0x100) {
            return self.spi2.read32(offset - 0xc0);
        }
        return switch (offset) {
            0x00 => self.auxIrqStatus(), // AUX_IRQ
            0x04 => self.enables, // AUX_ENABLES
            0x40 => blk: { // AUX_MU_IO_REG
                if ((self.lcr & 0x80) != 0) break :blk self.dll;
                if (self.rx_count == 0) break :blk 0;
                const b = self.rx_fifo[self.rx_head];
                self.rx_head +%= 1;
                self.rx_count -= 1;
                break :blk b;
            },
            0x44 => if ((self.lcr & 0x80) != 0) self.dlm else self.ier,
            0x48 => blk: { // AUX_MU_IIR_REG
                if ((self.ier & 1) != 0 and self.rx_count > 0) break :blk 0xc4; // RX data available
                if ((self.ier & 2) != 0 and self.tx_irq_pending) {
                    self.tx_irq_pending = false;
                    break :blk 0xc2; // TX holding register empty
                }
                break :blk 0xc1; // No interrupt pending
            },
            0x4c => self.lcr,
            0x50 => self.mcr,
            0x54 => 0x60 | @as(u32, if (self.rx_count > 0) 1 else 0), // LSR: TX empty+idle | DR
            0x58 => 0,
            0x5c => self.scratch,
            0x60 => self.cntl,
            0x64 => 0x30e | @as(u32, if (self.rx_count > 0) 1 else 0), // STAT
            0x68 => self.baud,
            else => 0,
        };
    }

    pub fn write32(self: *AuxMiniUart, offset: u32, val: u32) void {
        if (offset >= 0x80 and offset < 0xc0) {
            self.spi1.write32(offset - 0x80, val);
            return;
        }
        if (offset >= 0xc0 and offset < 0x100) {
            self.spi2.write32(offset - 0xc0, val);
            return;
        }
        switch (offset) {
            0x04 => self.enables = val & 0x07,
            0x40 => {
                if ((self.lcr & 0x80) != 0) {
                    self.dll = val & 0xff;
                } else {
                    const ch: u8 = @truncate(val);
                    if (self.tx_capture) {
                        if (self.tx_capture_len < self.tx_capture_buf.len) {
                            self.tx_capture_buf[self.tx_capture_len] = ch;
                            self.tx_capture_len += 1;
                        }
                    } else if (self.stdout_enabled) {
                        const buf = [1]u8{ch};
                        host_posix.writeStdout(&buf);
                    }
                    if ((self.ier & 2) != 0) self.tx_irq_pending = true;
                }
            },
            0x44 => {
                if ((self.lcr & 0x80) != 0) {
                    self.dlm = val & 0xff;
                } else {
                    self.ier = val & 0x0f;
                    if ((self.ier & 2) != 0) self.tx_irq_pending = true;
                }
            },
            0x48 => {
                if ((val & 2) != 0) {
                    self.rx_head = 0;
                    self.rx_tail = 0;
                    self.rx_count = 0;
                }
            },
            0x4c => self.lcr = val,
            0x50 => self.mcr = val,
            0x5c => self.scratch = val,
            0x60 => self.cntl = val,
            0x68 => self.baud = val,
            else => {},
        }
    }
};

