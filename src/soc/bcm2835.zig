const std = @import("std");
const intc_mod = @import("intc.zig");
const timer_mod = @import("timer.zig");
const mailbox_mod = @import("mailbox.zig");
const cprman_mod = @import("cprman.zig");
const pm_mod = @import("pm.zig");
const gpio_mod = @import("gpio.zig");
const uart_mod = @import("uart.zig");
const dma_mod = @import("dma.zig");
const sdhost_mod = @import("sdhost.zig");
const i2c_mod = @import("i2c.zig");
const dwc2_mod = @import("../usb/dwc2.zig");
const v3d_mod = @import("../vc4/v3d.zig");
const hvs_mod = @import("../vc4/hvs.zig");
const pv_mod = @import("../vc4/pixelvalve.zig");
const hdmi_mod = @import("../vc4/hdmi.zig");

/// Complete BCM2835 SoC Bus & Peripherals for Raspberry Pi Zero 1.
/// Directly satisfies the `Bus` concept required by `Arm1176(Bcm2835)`.
pub const Bcm2835 = struct {
    pub const RAM_SIZE: usize = 512 * 1024 * 1024;
    pub const PERIPH_BASE: u32 = 0x20000000;
    pub const PERIPH_END: u32 = 0x21000000;

    pub const TIMER_BASE: u32 = 0x20003000;
    pub const TIMER_SIZE: u32 = 0x100;
    pub const INTC_BASE: u32 = 0x2000b200;
    pub const INTC_SIZE: u32 = 0x200;

    ram: []u8,

    intc: intc_mod.IntController = .{},
    timer: timer_mod.SystemTimer = .{},
    mailbox: mailbox_mod.Mailbox = .{},
    cprman: cprman_mod.Cprman = .{},
    pm: pm_mod.PowerManager = .{},
    asb: pm_mod.AsbBridge = .{},
    rng: pm_mod.Rng = .{},
    thermal: pm_mod.Thermal = .{},
    gpio: gpio_mod.Gpio = .{},
    uart0: uart_mod.Pl011Uart = .{},
    aux_uart: uart_mod.AuxMiniUart = .{},
    dma: dma_mod.DmaController = .{},
    sdhost: sdhost_mod.SdHost = .{},
    sdhci: sdhost_mod.ArasanSdhci = .{},
    bsc0: i2c_mod.BscController = i2c_mod.BscController.init(false, 1280, 720),
    bsc1: i2c_mod.BscController = i2c_mod.BscController.init(false, 1280, 720),
    bsc2: i2c_mod.BscController = i2c_mod.BscController.init(true, 1280, 720),
    usb: dwc2_mod.Dwc2Controller = .{},
    v3d: v3d_mod.V3d = .{},
    hvs: hvs_mod.Hvs = .{},
    pv0: pv_mod.PixelValve = .{},
    pv1: pv_mod.PixelValve = .{},
    pv2: pv_mod.PixelValve = .{},
    hdmi: hdmi_mod.Hdmi = .{},
    txp: hdmi_mod.Txp = .{},

    display_width: u16 = 1280,
    display_height: u16 = 720,

    pub fn init(ram: []u8, display_width: u16, display_height: u16) Bcm2835 {
        var soc = Bcm2835{
            .ram = ram,
            .display_width = display_width,
            .display_height = display_height,
            .bsc2 = i2c_mod.BscController.init(true, display_width, display_height),
        };
        soc.mailbox.fb_width = display_width;
        soc.mailbox.fb_height = display_height;
        soc.mailbox.fb_virt_width = display_width;
        soc.mailbox.fb_virt_height = display_height;
        soc.usb.hid.guest_x = @divTrunc(@as(i32, display_width), 2);
        soc.usb.hid.guest_y = @divTrunc(@as(i32, display_height), 2);
        soc.usb.hid.target_x = soc.usb.hid.guest_x;
        soc.usb.hid.target_y = soc.usb.hid.guest_y;
        return soc;
    }

    pub inline fn hasPendingIrq(self: *const Bcm2835) bool {
        return self.intc.hasPendingIrq();
    }

    pub inline fn hasPendingFiq(self: *const Bcm2835) bool {
        return self.intc.hasPendingFiq();
    }

    fn dmaMmio(self: *Bcm2835) dma_mod.DmaController.MmioIo {
        return .{
            .ctx = self,
            .read32Fn = busRead32Opaque,
            .write32Fn = busWrite32Opaque,
            .dreqReadyFn = dmaDreqReady,
        };
    }

    fn dmaDreqReady(ctx: *anyopaque, permap: u5) bool {
        const self: *Bcm2835 = @ptrCast(@alignCast(ctx));
        if (permap == 13) { // SDHOST DREQ
            return self.sdhost.dreqReady();
        }
        return true;
    }

    fn busRead32Opaque(ctx: *anyopaque, raw_addr: u32) u32 {
        const self: *Bcm2835 = @ptrCast(@alignCast(ctx));
        return self.read32(raw_addr);
    }

    fn busWrite32Opaque(ctx: *anyopaque, raw_addr: u32, val: u32) void {
        const self: *Bcm2835 = @ptrCast(@alignCast(ctx));
        self.write32(raw_addr, val);
    }

    /// Updates all interrupt lines on `IntController` from peripheral states.
    pub fn updateIrqs(self: *Bcm2835) void {
        var b0: u32 = 0;
        var b1: u32 = 0;
        var b2: u32 = 0;

        if (self.mailbox.irqPending()) b0 |= (1 << 1); // Basic bit 1 = ARM Mailbox

        // System timer channels 0..3 -> Bank 1 bits 0..3
        b1 |= (self.timer.cs & 0xf);

        // USB DWC2 -> Bank 1 bit 9
        if (self.usb.irqPending()) b1 |= (1 << 9);

        // V3D -> Bank 1 bit 10
        if (self.v3d.irqPending()) b1 |= (1 << 10);

        // DMA channels 0..12 -> Bank 1 bits 16..28
        for (0..13) |ch| {
            if (self.dma.channelIrqPending(ch)) {
                b1 |= (@as(u32, 1) << @intCast(16 + ch));
            }
        }

        // AUX Mini-UART1 -> Bank 1 bit 29
        if (self.aux_uart.irqPending()) b1 |= (1 << 29);

        // HVS Scaler -> Bank 2 bit 1 (IRQ 33)
        if (self.hvs.irqPending()) b2 |= (1 << 1);

        // PixelValves: PV2 -> Bank 2 bit 10 (42), PV0 -> Bank 2 bit 13 (45), PV1 -> Bank 2 bit 14 (46)
        if (self.pv2.irqPending()) b2 |= (1 << 10);
        if (self.pv0.irqPending()) b2 |= (1 << 13);
        if (self.pv1.irqPending()) b2 |= (1 << 14);

        // GPIO -> Bank 2 bits 17..20
        if (self.gpio.irqPending()) b2 |= (1 << 20);

        // I2C BSC0/1/2 -> Bank 2 bit 21
        if (self.bsc0.irqPending() or self.bsc1.irqPending() or self.bsc2.irqPending()) {
            b2 |= (1 << 21);
        }

        // SDHOST -> Bank 2 bit 24
        if (self.sdhost.irqPending()) b2 |= (1 << 24);

        // PL011 UART0 -> Bank 2 bit 25
        if (self.uart0.irqPending()) b2 |= (1 << 25);

        self.intc.raw_level[0] = b0;
        self.intc.raw_level[1] = b1;
        self.intc.raw_level[2] = b2;
    }

    /// Triggers 60 Hz vertical blanking on PixelValves and HVS.
    pub fn triggerVblank(self: *Bcm2835) void {
        self.pv0.triggerVblank();
        self.pv1.triggerVblank();
        self.pv2.triggerVblank();
        self.hvs.notifyVblank();
        self.usb.hid.syncCursorFeedback(self.hvs.getCursorHotspot(self.ram));
        self.usb.tickSof(self.ram);
        self.updateIrqs();
    }

    /// Connects or disconnects the simulated HDMI monitor cable (updating HPD register, DDC EDID, and GPIO 46 HDMI_HPD_N).
    pub fn setHdmiConnected(self: *Bcm2835, connected: bool) void {
        if (self.hdmi.connected == connected) return;
        self.hdmi.connected = connected;
        self.bsc2.has_hdmi_edid = connected;
        // GPIO 46 on Raspberry Pi Zero is HDMI_HPD_N (active-low: 0 = connected, 1 = disconnected)
        self.gpio.setExternalPin(46, !connected);
        self.updateIrqs();
    }

    /// Composites the current HDMI frame (`width * height` pixels of `0xFFRRGGBB`) from HVS or Mailbox FB.
    pub fn renderDisplayFrame(self: *const Bcm2835, out_argb: []u32, width: u32, height: u32) bool {
        if (!self.hdmi.connected) return false;
        if (self.hvs.compositeFrame(self.ram, out_argb, width, height)) {
            return true;
        }
        if (self.mailbox.fb_allocated) {
            const fb_phys = self.mailbox.fb_bus_addr & 0x1FFFFFFF;
            const fb_w = self.mailbox.fb_width;
            const fb_h = self.mailbox.fb_height;
            const bpp = self.mailbox.fb_depth / 8;
            if (bpp >= 2 and fb_w > 0 and fb_h > 0) {
                for (0..height) |y| {
                    const sy = (@as(u32, @intCast(y)) * fb_h) / height;
                    for (0..width) |x| {
                        const sx = (@as(u32, @intCast(x)) * fb_w) / width;
                        const off = fb_phys + (sy * fb_w + sx) * bpp;
                        if (off + bpp <= self.ram.len) {
                            out_argb[y * width + x] = if (bpp == 2)
                                @import("../vc4/format.zig").fromRgb565(std.mem.readInt(u16, self.ram[off..][0..2], .little))
                            else
                                std.mem.readInt(u32, self.ram[off..][0..4], .little) | 0xFF000000;
                        }
                    }
                }
                return true;
            }
        }
        return false;
    }

    fn normalizeAddr(addr: u32) u32 {
        // VideoCore bus addresses map 0x7e000000..0x7effffff -> 0x20000000..0x20ffffff
        if ((addr & 0xFF000000) == 0x7E000000) {
            return 0x20000000 | (addr & 0x00FFFFFF);
        }
        return addr;
    }

    pub fn read8(self: *Bcm2835, raw_addr: u32) u8 {
        const addr = normalizeAddr(raw_addr);
        if (addr < PERIPH_BASE or addr >= PERIPH_END) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off < self.ram.len) return self.ram[ram_off];
            return 0;
        }
        const word = self.readMmio32(addr & ~@as(u32, 3));
        const shift: u5 = @intCast((addr & 3) * 8);
        return @truncate(word >> shift);
    }

    pub fn read16(self: *Bcm2835, raw_addr: u32) u16 {
        const addr = normalizeAddr(raw_addr);
        if (addr < PERIPH_BASE or addr >= PERIPH_END) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off + 2 <= self.ram.len) return std.mem.readInt(u16, self.ram[ram_off..][0..2], .little);
            return 0;
        }
        const word = self.readMmio32(addr & ~@as(u32, 3));
        const shift: u5 = @intCast((addr & 2) * 8);
        return @truncate(word >> shift);
    }

    pub fn read32(self: *Bcm2835, raw_addr: u32) u32 {
        const addr = normalizeAddr(raw_addr);
        if (addr < PERIPH_BASE or addr >= PERIPH_END) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off + 4 <= self.ram.len) return std.mem.readInt(u32, self.ram[ram_off..][0..4], .little);
            return 0;
        }
        return self.readMmio32(addr & ~@as(u32, 3));
    }

    pub fn write8(self: *Bcm2835, raw_addr: u32, val: u8) void {
        const addr = normalizeAddr(raw_addr);
        if (addr < PERIPH_BASE or addr >= PERIPH_END) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off < self.ram.len) self.ram[ram_off] = val;
            return;
        }
        self.writeMmio32(addr & ~@as(u32, 3), val);
    }

    pub fn write16(self: *Bcm2835, raw_addr: u32, val: u16) void {
        const addr = normalizeAddr(raw_addr);
        if (addr < PERIPH_BASE or addr >= PERIPH_END) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off + 2 <= self.ram.len) std.mem.writeInt(u16, self.ram[ram_off..][0..2], val, .little);
            return;
        }
        self.writeMmio32(addr & ~@as(u32, 3), val);
    }

    pub fn write32(self: *Bcm2835, raw_addr: u32, val: u32) void {
        const addr = normalizeAddr(raw_addr);
        if (addr < PERIPH_BASE or addr >= PERIPH_END) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off + 4 <= self.ram.len) std.mem.writeInt(u32, self.ram[ram_off..][0..4], val, .little);
            return;
        }
        self.writeMmio32(addr & ~@as(u32, 3), val);
    }

    pub fn readMmio32(self: *Bcm2835, addr: u32) u32 {
        if (addr >= TIMER_BASE and addr < TIMER_BASE + TIMER_SIZE) {
            return self.timer.read32(addr - TIMER_BASE);
        }
        if (addr >= hdmi_mod.Txp.BASE_ADDR and addr < hdmi_mod.Txp.BASE_ADDR + hdmi_mod.Txp.SIZE) {
            return self.txp.read32(addr - hdmi_mod.Txp.BASE_ADDR);
        }
        if (addr >= dma_mod.DmaController.BASE_ADDR and addr < dma_mod.DmaController.BASE_ADDR + dma_mod.DmaController.SIZE) {
            return self.dma.read32(addr - dma_mod.DmaController.BASE_ADDR);
        }
        if (addr >= pm_mod.AsbBridge.BASE_ADDR and addr < pm_mod.AsbBridge.BASE_ADDR + pm_mod.AsbBridge.SIZE) {
            return self.asb.read32(addr - pm_mod.AsbBridge.BASE_ADDR);
        }
        if (addr >= INTC_BASE and addr < INTC_BASE + INTC_SIZE) {
            self.updateIrqs();
            return self.intc.read32(addr - INTC_BASE);
        }
        if (addr >= mailbox_mod.Mailbox.BASE_ADDR and addr < mailbox_mod.Mailbox.BASE_ADDR + mailbox_mod.Mailbox.SIZE) {
            return self.mailbox.read32(addr - mailbox_mod.Mailbox.BASE_ADDR);
        }
        if (addr >= pm_mod.PowerManager.BASE_ADDR and addr < pm_mod.PowerManager.BASE_ADDR + pm_mod.PowerManager.SIZE) {
            return self.pm.read32(addr - pm_mod.PowerManager.BASE_ADDR);
        }
        if (addr >= cprman_mod.Cprman.BASE_ADDR and addr < cprman_mod.Cprman.BASE_ADDR + cprman_mod.Cprman.SIZE) {
            return self.cprman.read32(addr - cprman_mod.Cprman.BASE_ADDR);
        }
        if (addr >= pm_mod.Rng.BASE_ADDR and addr < pm_mod.Rng.BASE_ADDR + pm_mod.Rng.SIZE) {
            return self.rng.read32(addr - pm_mod.Rng.BASE_ADDR);
        }
        if (addr >= gpio_mod.Gpio.BASE_ADDR and addr < gpio_mod.Gpio.BASE_ADDR + gpio_mod.Gpio.SIZE) {
            return self.gpio.read32(addr - gpio_mod.Gpio.BASE_ADDR);
        }
        if (addr >= uart_mod.Pl011Uart.BASE_ADDR and addr < uart_mod.Pl011Uart.BASE_ADDR + uart_mod.Pl011Uart.SIZE) {
            return self.uart0.read32(addr - uart_mod.Pl011Uart.BASE_ADDR);
        }
        if (addr >= sdhost_mod.SdHost.BASE_ADDR and addr < sdhost_mod.SdHost.BASE_ADDR + sdhost_mod.SdHost.SIZE) {
            return self.sdhost.read32(addr - sdhost_mod.SdHost.BASE_ADDR);
        }
        if (addr >= i2c_mod.BscController.BSC0_BASE and addr < i2c_mod.BscController.BSC0_BASE + i2c_mod.BscController.SIZE) {
            return self.bsc0.read32(addr - i2c_mod.BscController.BSC0_BASE);
        }
        if (addr >= pv_mod.PixelValve.PV0_BASE and addr < pv_mod.PixelValve.PV0_BASE + pv_mod.PixelValve.SIZE) {
            return self.pv0.read32(addr - pv_mod.PixelValve.PV0_BASE);
        }
        if (addr >= pv_mod.PixelValve.PV1_BASE and addr < pv_mod.PixelValve.PV1_BASE + pv_mod.PixelValve.SIZE) {
            return self.pv1.read32(addr - pv_mod.PixelValve.PV1_BASE);
        }
        if (addr >= pm_mod.Thermal.BASE_ADDR and addr < pm_mod.Thermal.BASE_ADDR + pm_mod.Thermal.SIZE) {
            return self.thermal.read32(addr - pm_mod.Thermal.BASE_ADDR);
        }
        if (addr >= uart_mod.AuxMiniUart.BASE_ADDR and addr < uart_mod.AuxMiniUart.BASE_ADDR + uart_mod.AuxMiniUart.SIZE) {
            return self.aux_uart.read32(addr - uart_mod.AuxMiniUart.BASE_ADDR);
        }
        if (addr >= sdhost_mod.ArasanSdhci.BASE_ADDR and addr < sdhost_mod.ArasanSdhci.BASE_ADDR + sdhost_mod.ArasanSdhci.SIZE) {
            return self.sdhci.read32(addr - sdhost_mod.ArasanSdhci.BASE_ADDR);
        }
        if (addr >= hvs_mod.Hvs.BASE_ADDR and addr < hvs_mod.Hvs.BASE_ADDR + hvs_mod.Hvs.SIZE) {
            return self.hvs.read32(addr - hvs_mod.Hvs.BASE_ADDR);
        }
        if (addr >= i2c_mod.BscController.BSC1_BASE and addr < i2c_mod.BscController.BSC1_BASE + i2c_mod.BscController.SIZE) {
            return self.bsc1.read32(addr - i2c_mod.BscController.BSC1_BASE);
        }
        if (addr >= i2c_mod.BscController.BSC2_BASE and addr < i2c_mod.BscController.BSC2_BASE + i2c_mod.BscController.SIZE) {
            return self.bsc2.read32(addr - i2c_mod.BscController.BSC2_BASE);
        }
        if (addr >= pv_mod.PixelValve.PV2_BASE and addr < pv_mod.PixelValve.PV2_BASE + pv_mod.PixelValve.SIZE) {
            return self.pv2.read32(addr - pv_mod.PixelValve.PV2_BASE);
        }
        if (addr >= hdmi_mod.Hdmi.HD_BASE and addr < hdmi_mod.Hdmi.HD_BASE + hdmi_mod.Hdmi.HD_SIZE) {
            return self.hdmi.readHd32(addr - hdmi_mod.Hdmi.HD_BASE);
        }
        if (addr >= hdmi_mod.Hdmi.HDMI_BASE and addr < hdmi_mod.Hdmi.HDMI_BASE + hdmi_mod.Hdmi.HDMI_SIZE) {
            return self.hdmi.readHdmi32(addr - hdmi_mod.Hdmi.HDMI_BASE);
        }
        if (addr >= dwc2_mod.Dwc2Controller.BASE_ADDR and addr < dwc2_mod.Dwc2Controller.BASE_ADDR + dwc2_mod.Dwc2Controller.SIZE) {
            return self.usb.read32(addr - dwc2_mod.Dwc2Controller.BASE_ADDR);
        }
        if (addr >= v3d_mod.V3d.BASE_ADDR and addr < v3d_mod.V3d.BASE_ADDR + v3d_mod.V3d.SIZE) {
            return self.v3d.read32(addr - v3d_mod.V3d.BASE_ADDR);
        }
        return 0;
    }

    pub fn writeMmio32(self: *Bcm2835, addr: u32, val: u32) void {
        if (addr >= TIMER_BASE and addr < TIMER_BASE + TIMER_SIZE) {
            self.timer.write32(addr - TIMER_BASE, val, &self.intc);
        } else if (addr >= hdmi_mod.Txp.BASE_ADDR and addr < hdmi_mod.Txp.BASE_ADDR + hdmi_mod.Txp.SIZE) {
            self.txp.write32(addr - hdmi_mod.Txp.BASE_ADDR, val);
        } else if (addr >= dma_mod.DmaController.BASE_ADDR and addr < dma_mod.DmaController.BASE_ADDR + dma_mod.DmaController.SIZE) {
            self.dma.write32(addr - dma_mod.DmaController.BASE_ADDR, val, self.ram, self.dmaMmio());
        } else if (addr >= pm_mod.AsbBridge.BASE_ADDR and addr < pm_mod.AsbBridge.BASE_ADDR + pm_mod.AsbBridge.SIZE) {
            self.asb.write32(addr - pm_mod.AsbBridge.BASE_ADDR, val);
        } else if (addr >= INTC_BASE and addr < INTC_BASE + INTC_SIZE) {
            self.intc.write32(addr - INTC_BASE, val);
        } else if (addr >= mailbox_mod.Mailbox.BASE_ADDR and addr < mailbox_mod.Mailbox.BASE_ADDR + mailbox_mod.Mailbox.SIZE) {
            self.mailbox.write32(addr - mailbox_mod.Mailbox.BASE_ADDR, val, self.ram);
        } else if (addr >= pm_mod.PowerManager.BASE_ADDR and addr < pm_mod.PowerManager.BASE_ADDR + pm_mod.PowerManager.SIZE) {
            self.pm.write32(addr - pm_mod.PowerManager.BASE_ADDR, val);
        } else if (addr >= cprman_mod.Cprman.BASE_ADDR and addr < cprman_mod.Cprman.BASE_ADDR + cprman_mod.Cprman.SIZE) {
            self.cprman.write32(addr - cprman_mod.Cprman.BASE_ADDR, val);
        } else if (addr >= pm_mod.Rng.BASE_ADDR and addr < pm_mod.Rng.BASE_ADDR + pm_mod.Rng.SIZE) {
            self.rng.write32(addr - pm_mod.Rng.BASE_ADDR, val);
        } else if (addr >= gpio_mod.Gpio.BASE_ADDR and addr < gpio_mod.Gpio.BASE_ADDR + gpio_mod.Gpio.SIZE) {
            self.gpio.write32(addr - gpio_mod.Gpio.BASE_ADDR, val);
        } else if (addr >= uart_mod.Pl011Uart.BASE_ADDR and addr < uart_mod.Pl011Uart.BASE_ADDR + uart_mod.Pl011Uart.SIZE) {
            self.uart0.write32(addr - uart_mod.Pl011Uart.BASE_ADDR, val);
        } else if (addr >= sdhost_mod.SdHost.BASE_ADDR and addr < sdhost_mod.SdHost.BASE_ADDR + sdhost_mod.SdHost.SIZE) {
            const offset = addr - sdhost_mod.SdHost.BASE_ADDR;
            self.sdhost.write32(offset, val);
            if (offset == 0x00 and self.sdhost.dreqReady()) {
                self.dma.stepAllActive(self.ram, self.dmaMmio());
            }
        } else if (addr >= i2c_mod.BscController.BSC0_BASE and addr < i2c_mod.BscController.BSC0_BASE + i2c_mod.BscController.SIZE) {
            self.bsc0.write32(addr - i2c_mod.BscController.BSC0_BASE, val);
        } else if (addr >= pv_mod.PixelValve.PV0_BASE and addr < pv_mod.PixelValve.PV0_BASE + pv_mod.PixelValve.SIZE) {
            self.pv0.write32(addr - pv_mod.PixelValve.PV0_BASE, val);
        } else if (addr >= pv_mod.PixelValve.PV1_BASE and addr < pv_mod.PixelValve.PV1_BASE + pv_mod.PixelValve.SIZE) {
            self.pv1.write32(addr - pv_mod.PixelValve.PV1_BASE, val);
        } else if (addr >= pm_mod.Thermal.BASE_ADDR and addr < pm_mod.Thermal.BASE_ADDR + pm_mod.Thermal.SIZE) {
            self.thermal.write32(addr - pm_mod.Thermal.BASE_ADDR, val);
        } else if (addr >= uart_mod.AuxMiniUart.BASE_ADDR and addr < uart_mod.AuxMiniUart.BASE_ADDR + uart_mod.AuxMiniUart.SIZE) {
            self.aux_uart.write32(addr - uart_mod.AuxMiniUart.BASE_ADDR, val);
        } else if (addr >= sdhost_mod.ArasanSdhci.BASE_ADDR and addr < sdhost_mod.ArasanSdhci.BASE_ADDR + sdhost_mod.ArasanSdhci.SIZE) {
            self.sdhci.write32(addr - sdhost_mod.ArasanSdhci.BASE_ADDR, val);
        } else if (addr >= hvs_mod.Hvs.BASE_ADDR and addr < hvs_mod.Hvs.BASE_ADDR + hvs_mod.Hvs.SIZE) {
            self.hvs.write32(addr - hvs_mod.Hvs.BASE_ADDR, val);
        } else if (addr >= i2c_mod.BscController.BSC1_BASE and addr < i2c_mod.BscController.BSC1_BASE + i2c_mod.BscController.SIZE) {
            self.bsc1.write32(addr - i2c_mod.BscController.BSC1_BASE, val);
        } else if (addr >= i2c_mod.BscController.BSC2_BASE and addr < i2c_mod.BscController.BSC2_BASE + i2c_mod.BscController.SIZE) {
            self.bsc2.write32(addr - i2c_mod.BscController.BSC2_BASE, val);
        } else if (addr >= pv_mod.PixelValve.PV2_BASE and addr < pv_mod.PixelValve.PV2_BASE + pv_mod.PixelValve.SIZE) {
            self.pv2.write32(addr - pv_mod.PixelValve.PV2_BASE, val);
        } else if (addr >= hdmi_mod.Hdmi.HD_BASE and addr < hdmi_mod.Hdmi.HD_BASE + hdmi_mod.Hdmi.HD_SIZE) {
            self.hdmi.writeHd32(addr - hdmi_mod.Hdmi.HD_BASE, val);
        } else if (addr >= hdmi_mod.Hdmi.HDMI_BASE and addr < hdmi_mod.Hdmi.HDMI_BASE + hdmi_mod.Hdmi.HDMI_SIZE) {
            self.hdmi.writeHdmi32(addr - hdmi_mod.Hdmi.HDMI_BASE, val);
        } else if (addr >= dwc2_mod.Dwc2Controller.BASE_ADDR and addr < dwc2_mod.Dwc2Controller.BASE_ADDR + dwc2_mod.Dwc2Controller.SIZE) {
            self.usb.write32(addr - dwc2_mod.Dwc2Controller.BASE_ADDR, val, self.ram);
        } else if (addr >= v3d_mod.V3d.BASE_ADDR and addr < v3d_mod.V3d.BASE_ADDR + v3d_mod.V3d.SIZE) {
            self.v3d.write32(addr - v3d_mod.V3d.BASE_ADDR, val, self.ram);
        }
        self.updateIrqs();
    }
};

test "Bcm2835 DMA block write to SDHOST (CMD24) completes without recursion" {
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);

    var disk: [1024]u8 = [_]u8{0} ** 1024;
    var soc = Bcm2835.init(ram, 1280, 720);
    soc.sdhost.attachMutableSlice(&disk);

    // Prepare 512-byte source buffer in RAM at 0x1000
    std.mem.writeInt(u32, ram[0x1000..0x1004], 0xCAFEBABE, .little);
    std.mem.writeInt(u32, ram[0x11fc..0x1200], 0xDEADBEEF, .little);

    // Prepare DMA Control Block at 0x200: PERMAP=13 (SDHOST), D_DREQ (bit 6), S_INC, INT_EN
    const cb: u32 = 0x200;
    const ti: u32 = dma_mod.DmaController.TI_S_INC | dma_mod.DmaController.TI_INT_EN | (1 << 6) | (13 << 16);
    std.mem.writeInt(u32, ram[cb + 0 ..][0..4], ti, .little);
    std.mem.writeInt(u32, ram[cb + 4 ..][0..4], 0xc0001000, .little); // source_ad in RAM
    std.mem.writeInt(u32, ram[cb + 8 ..][0..4], 0x7e202040, .little); // dest_ad = SDDATA
    std.mem.writeInt(u32, ram[cb + 12 ..][0..4], 512, .little); // txfr_len = 512 bytes
    std.mem.writeInt(u32, ram[cb + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[cb + 20 ..][0..4], 0, .little);

    // Arm DMA channel 0 before issuing SDCMD (matches Linux bcm2835-sdhost driver order)
    soc.write32(0x20007004, 0xc0000200); // CONBLK_AD
    soc.write32(0x20007000, dma_mod.DmaController.CS_ACTIVE); // CS = ACTIVE (waits for SDHOST DREQ)

    // Issue CMD24 (WRITE_BLOCK) to sector 1 (offset 512)
    soc.write32(0x2020203c, 512); // SDHBCT
    soc.write32(0x20202050, 1); // SDHBLC
    soc.write32(0x20202004, 1); // SDARG = sector 1
    soc.write32(0x20202000, sdhost_mod.SdHost.SDCMD_NEW_FLAG | sdhost_mod.SdHost.SDCMD_WRITE_CMD | 24);

    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), std.mem.readInt(u32, disk[512..516], .little));
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), std.mem.readInt(u32, disk[1020..1024], .little));
    try std.testing.expect(soc.dma.channelIrqPending(0));
}

