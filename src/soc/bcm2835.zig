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
const audio_mod = @import("audio.zig");
const local_intc_mod = @import("local_intc.zig");
const spi_mod = @import("spi.zig");

/// Complete BCM2835 / BCM2837 SoC Bus & Peripherals.
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
    is_bcm2837: bool = false,

    intc: intc_mod.IntController = .{},
    local_intc: local_intc_mod.LocalIntc = .{},
    timer: timer_mod.SystemTimer = .{},
    arm_timer: timer_mod.ArmTimer = .{},
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
    audio_fifo: audio_mod.AudioFifo = .{},
    vchiq: audio_mod.Vchiq = .{},
    pwm: audio_mod.PwmAudio = .{},
    i2s: audio_mod.I2sPcm = .{},
    spi0: spi_mod.Spi0 = .{},

    display_width: u16 = 1280,
    display_height: u16 = 720,
    audio_connected: bool = true,
    act_led_hold_frames: u8 = 0,

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

    pub inline fn hasPendingIrqForCore(self: *const Bcm2835, core_id: u2) bool {
        if (self.is_bcm2837) {
            return self.local_intc.irqPendingForCore(core_id, self.intc.hasPendingIrq()) != 0;
        }
        return core_id == 0 and self.intc.hasPendingIrq();
    }

    pub inline fn hasPendingFiqForCore(self: *const Bcm2835, core_id: u2) bool {
        if (self.is_bcm2837) {
            return self.local_intc.fiqPendingForCore(core_id, self.intc.hasPendingFiq()) != 0;
        }
        return core_id == 0 and self.intc.hasPendingFiq();
    }

    pub inline fn hasPendingIrq(self: *const Bcm2835) bool {
        return self.hasPendingIrqForCore(0);
    }

    pub inline fn hasPendingFiq(self: *const Bcm2835) bool {
        return self.hasPendingFiqForCore(0);
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
        return switch (permap) {
            3 => self.i2s.rxDreqReady(), // PCM / I2S RX
            6 => self.spi0.txDreqReady(), // SPI0 TX
            7 => self.spi0.rxDreqReady(), // SPI0 RX
            11 => self.sdhci.dreqReady(), // EMMC / Arasan SDHCI
            13 => self.sdhost.dreqReady(), // SDHOST
            else => true,
        };
    }

    pub fn syncSdRoutingFromGpio(self: *Bcm2835) void {
        const sd_on_arasan = self.gpio.isSdCardOnArasanAlt3();
        self.sdhost.pins_routed = !sd_on_arasan;
        self.sdhci.routed_to_sd_card = sd_on_arasan;
        self.sdhci.routed_to_wifi = !sd_on_arasan and self.gpio.isWifiOnArasanAlt3();
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

        if (self.arm_timer.irqPending()) b0 |= (1 << 0); // Basic bit 0 = ARM Timer (SP804)
        if (self.mailbox.irqPending()) b0 |= (1 << 1); // Basic bit 1 = ARM Mailbox
        if (self.vchiq.irqPending()) b0 |= (1 << 2); // Basic bit 2 = ARM Doorbell 0 (VCHIQ)

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

        // I2C BSC0/1/2 -> Bank 2 bit 21 (IRQ 53)
        if (self.bsc0.irqPending() or self.bsc1.irqPending() or self.bsc2.irqPending()) {
            b2 |= (1 << 21);
        }

        // SPI0 -> Bank 2 bit 22 (IRQ 54)
        if (self.spi0.irqPending()) b2 |= (1 << 22);

        // PCM / I2S -> Bank 2 bit 23 (IRQ 55)
        if (self.i2s.irqPending()) b2 |= (1 << 23);

        // SDHOST -> Bank 2 bit 24 (IRQ 56)
        if (self.sdhost.irqPending()) b2 |= (1 << 24);

        // PL011 UART0 -> Bank 2 bit 25 (IRQ 57)
        if (self.uart0.irqPending()) b2 |= (1 << 25);

        // Arasan SDHCI (mmc@7e300000 / mmcnr@7e300000) -> Bank 2 bit 30 (IRQ 62)
        if (self.sdhci.irqPending()) b2 |= (1 << 30);

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

    /// Connects or disconnects the simulated HDMI monitor cable (updating HPD register, DDC EDID, and GPIO 46/28 HDMI_HPD_N).
    pub fn setHdmiConnected(self: *Bcm2835, connected: bool) void {
        if (self.hdmi.connected == connected) return;
        self.hdmi.connected = connected;
        self.bsc2.has_hdmi_edid = connected;
        // GPIO 46 (BCM2835) and GPIO 28 (BCM2837) are HDMI_HPD_N (active-low: 0 = connected, 1 = disconnected)
        self.gpio.setExternalPin(46, !connected);
        self.gpio.setExternalPin(28, !connected);
        self.updateIrqs();
    }

    /// Connects or disconnects the simulated 3.5 mm audio/video jack.
    /// Note: Physical Raspberry Pi boards do not wire a jack-detect switch to any SoC GPIO;
    /// this state controls whether analog/PWM audio output is played on the host.
    pub fn setAudioConnected(self: *Bcm2835, connected: bool) void {
        self.audio_connected = connected;
    }

    /// Advances paced audio DMA channels (`vc4-hdmi` MAI and `bcm2835-pwm`) and VCHIQ `AUDS` completions.
    pub fn advanceAudio(self: *Bcm2835, elapsed_us: u64) void {
        if (elapsed_us == 0) return;
        self.dma.advanceAudio(elapsed_us, self.hdmi.maiSampleRate(), self.ram, self.dmaMmio());
        self.vchiq.advanceAudio(elapsed_us, self.ram);
    }

    /// Samples the board `ACT` (green) and `PWR` (red) LED states for the 60 Hz UI frame.
    pub fn sampleBoardLeds(self: *Bcm2835, power_connected: bool) struct { act_on: bool, pwr_on: bool } {
        if (!power_connected) {
            self.sdhost.activity_latch = false;
            self.gpio.act_pulse_latch = false;
            self.mailbox.exp_act_latch = false;
            self.act_led_hold_frames = 0;
            return .{ .act_on = false, .pwr_on = false };
        }

        const sd_active = self.sdhost.activity_latch;
        self.sdhost.activity_latch = false;

        const gpio47_pulse = self.gpio.act_pulse_latch;
        self.gpio.act_pulse_latch = false;

        const exp_pulse = self.mailbox.exp_act_latch;
        self.mailbox.exp_act_latch = false;

        if (sd_active or gpio47_pulse or exp_pulse) {
            self.act_led_hold_frames = 2;
        } else if (self.act_led_hold_frames > 0) {
            self.act_led_hold_frames -= 1;
        }

        const gpio47_steady = (self.gpio.getPinFunction(47) == .output) and !self.gpio.getPinLevel(47);
        const gpio29_steady = (self.gpio.getPinFunction(29) == .output) and self.gpio.getPinLevel(29);
        const exp_steady = self.mailbox.exp_gpio_state[0] != 0;
        const act_on = gpio47_steady or gpio29_steady or exp_steady or (self.act_led_hold_frames > 0);

        const gpio35_off = (self.gpio.getPinFunction(35) == .output) and !self.gpio.getPinLevel(35);
        const exp_pwr_off = (self.mailbox.exp_gpio_state[7] == 0) or (self.mailbox.exp_gpio_state[2] != 0);
        const pwr_on = !gpio35_off and !exp_pwr_off;

        return .{ .act_on = act_on, .pwr_on = pwr_on };
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
        // VideoCore bus addresses (0x7e000000..0x7effffff) and BCM2837 physical peripheral
        // addresses (0x3f000000..0x3fffffff) map to 0x20000000..0x20ffffff.
        const top = addr & 0xFF000000;
        if (top == 0x7E000000 or top == 0x3F000000) {
            return 0x20000000 | (addr & 0x00FFFFFF);
        }
        return addr;
    }

    inline fn isMmioAddr(addr: u32) bool {
        return (addr >= PERIPH_BASE and addr < PERIPH_END) or
            (addr >= local_intc_mod.LocalIntc.BASE_ADDR and addr < local_intc_mod.LocalIntc.BASE_ADDR + local_intc_mod.LocalIntc.SIZE);
    }

    pub fn read8(self: *Bcm2835, raw_addr: u32) u8 {
        const addr = normalizeAddr(raw_addr);
        if (!isMmioAddr(addr)) {
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
        if (!isMmioAddr(addr)) {
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
        if (!isMmioAddr(addr)) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off + 4 <= self.ram.len) return std.mem.readInt(u32, self.ram[ram_off..][0..4], .little);
            return 0;
        }
        return self.readMmio32(addr & ~@as(u32, 3));
    }

    pub fn write8(self: *Bcm2835, raw_addr: u32, val: u8) void {
        const addr = normalizeAddr(raw_addr);
        if (!isMmioAddr(addr)) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off < self.ram.len) self.ram[ram_off] = val;
            return;
        }
        self.writeMmio32(addr & ~@as(u32, 3), val);
    }

    pub fn write16(self: *Bcm2835, raw_addr: u32, val: u16) void {
        const addr = normalizeAddr(raw_addr);
        if (!isMmioAddr(addr)) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off + 2 <= self.ram.len) std.mem.writeInt(u16, self.ram[ram_off..][0..2], val, .little);
            return;
        }
        self.writeMmio32(addr & ~@as(u32, 3), val);
    }

    pub fn write32(self: *Bcm2835, raw_addr: u32, val: u32) void {
        const addr = normalizeAddr(raw_addr);
        if (!isMmioAddr(addr)) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off + 4 <= self.ram.len) std.mem.writeInt(u32, self.ram[ram_off..][0..4], val, .little);
            return;
        }
        self.writeMmio32(addr & ~@as(u32, 3), val);
    }

    pub fn readMmio32(self: *Bcm2835, addr: u32) u32 {
        if (addr >= local_intc_mod.LocalIntc.BASE_ADDR and addr < local_intc_mod.LocalIntc.BASE_ADDR + local_intc_mod.LocalIntc.SIZE) {
            self.updateIrqs();
            return self.local_intc.read32(
                addr - local_intc_mod.LocalIntc.BASE_ADDR,
                self.timer.counter,
                self.intc.hasPendingIrq(),
                self.intc.hasPendingFiq(),
            );
        }
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
        if (addr >= timer_mod.ArmTimer.BASE_ADDR and addr < timer_mod.ArmTimer.BASE_ADDR + timer_mod.ArmTimer.SIZE) {
            return self.arm_timer.read32(addr - timer_mod.ArmTimer.BASE_ADDR);
        }
        if (addr >= audio_mod.Vchiq.BASE_ADDR and addr < audio_mod.Vchiq.BASE_ADDR + audio_mod.Vchiq.SIZE) {
            return self.vchiq.read32(addr - audio_mod.Vchiq.BASE_ADDR);
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
        if (addr >= audio_mod.I2sPcm.BASE_ADDR and addr < audio_mod.I2sPcm.BASE_ADDR + audio_mod.I2sPcm.SIZE) {
            return self.i2s.read32(addr - audio_mod.I2sPcm.BASE_ADDR);
        }
        if (addr >= spi_mod.Spi0.BASE_ADDR and addr < spi_mod.Spi0.BASE_ADDR + spi_mod.Spi0.SIZE) {
            return self.spi0.read32(addr - spi_mod.Spi0.BASE_ADDR);
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
        if (addr >= audio_mod.PwmAudio.BASE_ADDR and addr < audio_mod.PwmAudio.BASE_ADDR + audio_mod.PwmAudio.SIZE) {
            return self.pwm.read32(addr - audio_mod.PwmAudio.BASE_ADDR);
        }
        if (addr >= pm_mod.Thermal.BASE_ADDR and addr < pm_mod.Thermal.BASE_ADDR + pm_mod.Thermal.SIZE) {
            return self.thermal.read32(addr - pm_mod.Thermal.BASE_ADDR);
        }
        if (addr >= uart_mod.AuxMiniUart.BASE_ADDR and addr < uart_mod.AuxMiniUart.BASE_ADDR + uart_mod.AuxMiniUart.SIZE) {
            return self.aux_uart.read32(addr - uart_mod.AuxMiniUart.BASE_ADDR);
        }
        if (addr >= sdhost_mod.ArasanSdhci.BASE_ADDR and addr < sdhost_mod.ArasanSdhci.BASE_ADDR + sdhost_mod.ArasanSdhci.SIZE) {
            return self.sdhci.read32WithSd(addr - sdhost_mod.ArasanSdhci.BASE_ADDR, &self.sdhost);
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
        if (addr >= local_intc_mod.LocalIntc.BASE_ADDR and addr < local_intc_mod.LocalIntc.BASE_ADDR + local_intc_mod.LocalIntc.SIZE) {
            self.local_intc.write32(addr - local_intc_mod.LocalIntc.BASE_ADDR, val);
        } else if (addr >= TIMER_BASE and addr < TIMER_BASE + TIMER_SIZE) {
            self.timer.write32(addr - TIMER_BASE, val, &self.intc);
        } else if (addr >= hdmi_mod.Txp.BASE_ADDR and addr < hdmi_mod.Txp.BASE_ADDR + hdmi_mod.Txp.SIZE) {
            self.txp.write32(addr - hdmi_mod.Txp.BASE_ADDR, val);
        } else if (addr >= dma_mod.DmaController.BASE_ADDR and addr < dma_mod.DmaController.BASE_ADDR + dma_mod.DmaController.SIZE) {
            self.dma.write32(addr - dma_mod.DmaController.BASE_ADDR, val, self.ram, self.dmaMmio());
        } else if (addr >= pm_mod.AsbBridge.BASE_ADDR and addr < pm_mod.AsbBridge.BASE_ADDR + pm_mod.AsbBridge.SIZE) {
            self.asb.write32(addr - pm_mod.AsbBridge.BASE_ADDR, val);
        } else if (addr >= INTC_BASE and addr < INTC_BASE + INTC_SIZE) {
            self.intc.write32(addr - INTC_BASE, val);
        } else if (addr >= timer_mod.ArmTimer.BASE_ADDR and addr < timer_mod.ArmTimer.BASE_ADDR + timer_mod.ArmTimer.SIZE) {
            self.arm_timer.write32(addr - timer_mod.ArmTimer.BASE_ADDR, val, &self.intc);
        } else if (addr >= audio_mod.Vchiq.BASE_ADDR and addr < audio_mod.Vchiq.BASE_ADDR + audio_mod.Vchiq.SIZE) {
            self.vchiq.write32(
                addr - audio_mod.Vchiq.BASE_ADDR,
                val,
                self.ram,
                &self.audio_fifo,
                self.audio_connected,
                self.hdmi.connected,
            );
        } else if (addr >= mailbox_mod.Mailbox.BASE_ADDR and addr < mailbox_mod.Mailbox.BASE_ADDR + mailbox_mod.Mailbox.SIZE) {
            self.mailbox.write32WithVchiq(addr - mailbox_mod.Mailbox.BASE_ADDR, val, self.ram, &self.vchiq);
        } else if (addr >= pm_mod.PowerManager.BASE_ADDR and addr < pm_mod.PowerManager.BASE_ADDR + pm_mod.PowerManager.SIZE) {
            self.pm.write32(addr - pm_mod.PowerManager.BASE_ADDR, val);
        } else if (addr >= cprman_mod.Cprman.BASE_ADDR and addr < cprman_mod.Cprman.BASE_ADDR + cprman_mod.Cprman.SIZE) {
            self.cprman.write32(addr - cprman_mod.Cprman.BASE_ADDR, val);
        } else if (addr >= pm_mod.Rng.BASE_ADDR and addr < pm_mod.Rng.BASE_ADDR + pm_mod.Rng.SIZE) {
            self.rng.write32(addr - pm_mod.Rng.BASE_ADDR, val);
        } else if (addr >= gpio_mod.Gpio.BASE_ADDR and addr < gpio_mod.Gpio.BASE_ADDR + gpio_mod.Gpio.SIZE) {
            self.gpio.write32(addr - gpio_mod.Gpio.BASE_ADDR, val);
            self.syncSdRoutingFromGpio();
        } else if (addr >= uart_mod.Pl011Uart.BASE_ADDR and addr < uart_mod.Pl011Uart.BASE_ADDR + uart_mod.Pl011Uart.SIZE) {
            self.uart0.write32(addr - uart_mod.Pl011Uart.BASE_ADDR, val);
        } else if (addr >= sdhost_mod.SdHost.BASE_ADDR and addr < sdhost_mod.SdHost.BASE_ADDR + sdhost_mod.SdHost.SIZE) {
            const offset = addr - sdhost_mod.SdHost.BASE_ADDR;
            self.sdhost.write32(offset, val);
            if (offset == 0x00 and self.sdhost.dreqReady()) {
                self.dma.stepAllActive(self.ram, self.dmaMmio());
            }
        } else if (addr >= audio_mod.I2sPcm.BASE_ADDR and addr < audio_mod.I2sPcm.BASE_ADDR + audio_mod.I2sPcm.SIZE) {
            self.i2s.write32(addr - audio_mod.I2sPcm.BASE_ADDR, val, &self.audio_fifo, self.audio_connected);
            if (self.i2s.rxDreqReady()) {
                self.dma.stepAllActive(self.ram, self.dmaMmio());
            }
        } else if (addr >= spi_mod.Spi0.BASE_ADDR and addr < spi_mod.Spi0.BASE_ADDR + spi_mod.Spi0.SIZE) {
            self.spi0.write32(addr - spi_mod.Spi0.BASE_ADDR, val);
            if (self.spi0.txDreqReady() or self.spi0.rxDreqReady()) {
                self.dma.stepAllActive(self.ram, self.dmaMmio());
            }
        } else if (addr >= i2c_mod.BscController.BSC0_BASE and addr < i2c_mod.BscController.BSC0_BASE + i2c_mod.BscController.SIZE) {
            self.bsc0.write32(addr - i2c_mod.BscController.BSC0_BASE, val);
        } else if (addr >= pv_mod.PixelValve.PV0_BASE and addr < pv_mod.PixelValve.PV0_BASE + pv_mod.PixelValve.SIZE) {
            self.pv0.write32(addr - pv_mod.PixelValve.PV0_BASE, val);
        } else if (addr >= pv_mod.PixelValve.PV1_BASE and addr < pv_mod.PixelValve.PV1_BASE + pv_mod.PixelValve.SIZE) {
            self.pv1.write32(addr - pv_mod.PixelValve.PV1_BASE, val);
        } else if (addr >= audio_mod.PwmAudio.BASE_ADDR and addr < audio_mod.PwmAudio.BASE_ADDR + audio_mod.PwmAudio.SIZE) {
            self.pwm.write32(addr - audio_mod.PwmAudio.BASE_ADDR, val, &self.audio_fifo, self.audio_connected);
        } else if (addr >= pm_mod.Thermal.BASE_ADDR and addr < pm_mod.Thermal.BASE_ADDR + pm_mod.Thermal.SIZE) {
            self.thermal.write32(addr - pm_mod.Thermal.BASE_ADDR, val);
        } else if (addr >= uart_mod.AuxMiniUart.BASE_ADDR and addr < uart_mod.AuxMiniUart.BASE_ADDR + uart_mod.AuxMiniUart.SIZE) {
            self.aux_uart.write32(addr - uart_mod.AuxMiniUart.BASE_ADDR, val);
        } else if (addr >= sdhost_mod.ArasanSdhci.BASE_ADDR and addr < sdhost_mod.ArasanSdhci.BASE_ADDR + sdhost_mod.ArasanSdhci.SIZE) {
            const offset = addr - sdhost_mod.ArasanSdhci.BASE_ADDR;
            self.sdhci.write32WithSd(offset, val, &self.sdhost);
            if (offset == 0x0c and self.sdhci.dreqReady()) {
                self.dma.stepAllActive(self.ram, self.dmaMmio());
            }
        } else if (addr >= hvs_mod.Hvs.BASE_ADDR and addr < hvs_mod.Hvs.BASE_ADDR + hvs_mod.Hvs.SIZE) {
            self.hvs.write32(addr - hvs_mod.Hvs.BASE_ADDR, val);
        } else if (addr >= i2c_mod.BscController.BSC1_BASE and addr < i2c_mod.BscController.BSC1_BASE + i2c_mod.BscController.SIZE) {
            self.bsc1.write32(addr - i2c_mod.BscController.BSC1_BASE, val);
        } else if (addr >= i2c_mod.BscController.BSC2_BASE and addr < i2c_mod.BscController.BSC2_BASE + i2c_mod.BscController.SIZE) {
            self.bsc2.write32(addr - i2c_mod.BscController.BSC2_BASE, val);
        } else if (addr >= pv_mod.PixelValve.PV2_BASE and addr < pv_mod.PixelValve.PV2_BASE + pv_mod.PixelValve.SIZE) {
            self.pv2.write32(addr - pv_mod.PixelValve.PV2_BASE, val);
        } else if (addr >= hdmi_mod.Hdmi.HD_BASE and addr < hdmi_mod.Hdmi.HD_BASE + hdmi_mod.Hdmi.HD_SIZE) {
            self.hdmi.writeHd32(addr - hdmi_mod.Hdmi.HD_BASE, val, &self.audio_fifo);
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

test "Bcm2835 cyclic vc4-hdmi audio DMA (PERMAP 17 -> HD_MAI_DATA) unpacks IEC958 stereo frames" {
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);

    var soc = Bcm2835.init(ram, 1280, 720);

    // Configure HD_MAI_FMT (0x2080801c) for 48000 Hz (sr_enum = 9 in bits [15:8])
    soc.write32(0x2080801c, 9 << 8);
    soc.write32(0x20808014, hdmi_mod.Hdmi.HD_MAI_CTL_ENABLE | (2 << 4));

    // Write 2 stereo IEC958 frames (16 bytes = 4 subframes) at RAM 0x2000:
    // Frame 0: Left = 0x2345 (preamble 0x8), Right = -0x2345 (0xdcbb, preamble 0x4)
    // Frame 1: Left = 0x1111 (preamble 0x2), Right = -0x1111 (0xeeef, preamble 0x4)
    std.mem.writeInt(u32, ram[0x2000..0x2004], (@as(u32, 0x2345) << 12) | 0x8, .little);
    std.mem.writeInt(u32, ram[0x2004..0x2008], (@as(u32, @as(u16, @bitCast(@as(i16, -0x2345)))) << 12) | 0x4, .little);
    std.mem.writeInt(u32, ram[0x2008..0x200c], (@as(u32, 0x1111) << 12) | 0x2, .little);
    std.mem.writeInt(u32, ram[0x200c..0x2010], (@as(u32, @as(u16, @bitCast(@as(i16, -0x1111)))) << 12) | 0x4, .little);

    // Cyclic DMA CB at 0x400 pointing back to 0xc0000400, PERMAP=17 (HDMI MAI), D_DREQ, S_INC, INT_EN
    const cb: u32 = 0x400;
    const ti: u32 = dma_mod.DmaController.TI_S_INC | dma_mod.DmaController.TI_INT_EN | (1 << 6) | (17 << 16);
    std.mem.writeInt(u32, ram[cb + 0 ..][0..4], ti, .little);
    std.mem.writeInt(u32, ram[cb + 4 ..][0..4], 0xc0002000, .little);
    std.mem.writeInt(u32, ram[cb + 8 ..][0..4], 0x7e808020, .little); // HD_MAI_DATA
    std.mem.writeInt(u32, ram[cb + 12 ..][0..4], 16, .little); // 16 bytes = 2 stereo frames
    std.mem.writeInt(u32, ram[cb + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[cb + 20 ..][0..4], 0xc0000400, .little); // cyclic loop

    soc.write32(0x20007004, 0xc0000400); // Ch0 CONBLK_AD
    soc.write32(0x20007000, dma_mod.DmaController.CS_ACTIVE); // Ch0 CS = ACTIVE

    // Immediately after arming, SOURCE_AD should point to start of CB0 (0xc0002000) without draining CBs synchronously
    try std.testing.expectEqual(@as(u32, 0xc0002000), soc.read32(0x2000700c));
    try std.testing.expectEqual(@as(u32, 0), soc.audio_fifo.availableFrames());

    // Advance 42 us (~2 frames at 48 kHz = 41.67 us) -> completes the 16-byte period CB and wraps back to 0xc0002000
    soc.advanceAudio(42);
    try std.testing.expect(soc.dma.channelIrqPending(0));
    try std.testing.expectEqual(@as(u32, 2), soc.audio_fifo.availableFrames());

    var samples: [4]i16 = undefined;
    try std.testing.expectEqual(@as(usize, 2), soc.audio_fifo.popFrames(&samples));
    try std.testing.expectEqual(@as(i16, 0x2345), samples[0]);
    try std.testing.expectEqual(@as(i16, -0x2345), samples[1]);
    try std.testing.expectEqual(@as(i16, 0x1111), samples[2]);
    try std.testing.expectEqual(@as(i16, -0x1111), samples[3]);
}

test "Bcm2835 GPIO 48..53 ALT3 routes SD card to Arasan SDHCI with DMA PERMAP 11 block read/write" {
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);

    var disk: [1024]u8 = [_]u8{0} ** 1024;
    var soc = Bcm2835.init(ram, 1280, 720);
    soc.sdhost.attachMutableSlice(&disk);
    soc.sdhci.wireless_enabled = true;

    // Mux GPIO 48..53 to ALT3 (0b111 = 7) via GPFSEL4 (pins 48..49) and GPFSEL5 (pins 50..53)
    soc.write32(0x20200010, (7 << 24) | (7 << 27)); // GPFSEL4: GPIO 48, 49 = ALT3
    soc.write32(0x20200014, (7 << 0) | (7 << 3) | (7 << 6) | (7 << 9)); // GPFSEL5: GPIO 50..53 = ALT3
    try std.testing.expect(soc.sdhci.routed_to_sd_card);
    try std.testing.expect(!soc.sdhost.pins_routed);

    // When GPIO 48..53 are on ALT3, SDHOST commands time out
    soc.write32(0x20202004, 0x1aa);
    soc.write32(0x20202000, sdhost_mod.SdHost.SDCMD_NEW_FLAG | 8);
    try std.testing.expect((soc.read32(0x20202020) & sdhost_mod.SdHost.SDHSTS_CMD_TIME_OUT) != 0);

    // Prepare 512-byte source buffer in RAM at 0x1000 and DMA CB at 0x200 with PERMAP=11 (Arasan EMMC)
    std.mem.writeInt(u32, ram[0x1000..0x1004], 0x11223344, .little);
    std.mem.writeInt(u32, ram[0x11fc..0x1200], 0x55667788, .little);

    const cb: u32 = 0x200;
    const ti: u32 = dma_mod.DmaController.TI_S_INC | dma_mod.DmaController.TI_INT_EN | (1 << 6) | (11 << 16);
    std.mem.writeInt(u32, ram[cb + 0 ..][0..4], ti, .little);
    std.mem.writeInt(u32, ram[cb + 4 ..][0..4], 0xc0001000, .little); // source_ad in RAM
    std.mem.writeInt(u32, ram[cb + 8 ..][0..4], 0x7e300020, .little); // dest_ad = Arasan SDHCI_BUFFER
    std.mem.writeInt(u32, ram[cb + 12 ..][0..4], 512, .little);
    std.mem.writeInt(u32, ram[cb + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[cb + 20 ..][0..4], 0, .little);

    // Issue CMD24 (WRITE_BLOCK) to sector 1 on Arasan SDHCI (0x20300000), then start DMA channel 0 (matches bcm2835-mmc order)
    soc.write32(0x20300034, 0xffffffff); // INT_ENABLE
    soc.write32(0x20300038, 0xffffffff); // SIGNAL_ENABLE
    soc.write32(0x20300004, (1 << 16) | 512); // BLOCK_SIZE=512, BLOCK_COUNT=1
    soc.write32(0x20300008, 1); // ARGUMENT = sector 1
    soc.write32(0x2030000c, (24 << 24) | (0x3a << 16) | 0x0001); // CMD24 + DATA + DMA

    soc.write32(0x20007004, 0xc0000200); // Ch0 CONBLK_AD
    soc.write32(0x20007000, dma_mod.DmaController.CS_ACTIVE); // Ch0 CS = ACTIVE

    try std.testing.expectEqual(@as(u32, 0x11223344), std.mem.readInt(u32, disk[512..516], .little));
    try std.testing.expectEqual(@as(u32, 0x55667788), std.mem.readInt(u32, disk[1020..1024], .little));
    try std.testing.expect(soc.dma.channelIrqPending(0));
    try std.testing.expect((soc.read32(0x20300030) & sdhost_mod.ArasanSdhci.SDHCI_INT_DATA_END) != 0);
}

test "Bcm2835 SPI0 DMA bidirectional and TX-only clear_rx_desc transfers (PERMAP 6 TX / PERMAP 7 RX)" {
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);

    var soc = Bcm2835.init(ram, 1280, 720);
    soc.spi0.loopback = true;

    // 1. Bidirectional 16-byte DMA transfer (matches Linux spi-bcm2835 order: DLEN -> CS(TA|DMAEN) -> TX DMA -> RX DMA)
    std.mem.writeInt(u32, ram[0x1000..0x1004], 0x11223344, .little);
    std.mem.writeInt(u32, ram[0x1004..0x1008], 0x55667788, .little);
    std.mem.writeInt(u32, ram[0x1008..0x100c], 0x99AABBCC, .little);
    std.mem.writeInt(u32, ram[0x100c..0x1010], 0xDDEEFF00, .little);

    // TX CB at 0x200 (Channel 0, PERMAP 6 = SPI TX, D_DREQ, S_INC)
    const tx_cb: u32 = 0x200;
    const tx_ti: u32 = dma_mod.DmaController.TI_S_INC | (1 << 6) | (6 << 16);
    std.mem.writeInt(u32, ram[tx_cb + 0 ..][0..4], tx_ti, .little);
    std.mem.writeInt(u32, ram[tx_cb + 4 ..][0..4], 0xc0001000, .little);
    std.mem.writeInt(u32, ram[tx_cb + 8 ..][0..4], 0x7e204004, .little); // SPI_FIFO
    std.mem.writeInt(u32, ram[tx_cb + 12 ..][0..4], 16, .little);
    std.mem.writeInt(u32, ram[tx_cb + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[tx_cb + 20 ..][0..4], 0, .little);

    // RX CB at 0x240 (Channel 1, PERMAP 7 = SPI RX, S_DREQ, D_INC, INT_EN)
    const rx_cb: u32 = 0x240;
    const rx_ti: u32 = dma_mod.DmaController.TI_D_INC | dma_mod.DmaController.TI_INT_EN | (1 << 10) | (7 << 16);
    std.mem.writeInt(u32, ram[rx_cb + 0 ..][0..4], rx_ti, .little);
    std.mem.writeInt(u32, ram[rx_cb + 4 ..][0..4], 0x7e204004, .little); // SPI_FIFO
    std.mem.writeInt(u32, ram[rx_cb + 8 ..][0..4], 0xc0002000, .little);
    std.mem.writeInt(u32, ram[rx_cb + 12 ..][0..4], 16, .little);
    std.mem.writeInt(u32, ram[rx_cb + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[rx_cb + 20 ..][0..4], 0, .little);

    soc.write32(0x2020400c, 16); // SPI_DLEN = 16
    soc.write32(0x20204000, spi_mod.Spi0.CS_TA | spi_mod.Spi0.CS_DMAEN); // SPI_CS = TA | DMAEN
    soc.write32(0x20007004, 0xc0000200); // Ch0 CONBLK_AD (TX)
    soc.write32(0x20007000, dma_mod.DmaController.CS_ACTIVE);
    soc.write32(0x20007104, 0xc0000240); // Ch1 CONBLK_AD (RX)
    soc.write32(0x20007100, dma_mod.DmaController.CS_ACTIVE);

    try std.testing.expect(soc.dma.channelIrqPending(1));
    try std.testing.expectEqual(@as(u32, 0x11223344), std.mem.readInt(u32, ram[0x2000..0x2004], .little));
    try std.testing.expectEqual(@as(u32, 0x55667788), std.mem.readInt(u32, ram[0x2004..0x2008], .little));
    try std.testing.expectEqual(@as(u32, 0x99AABBCC), std.mem.readInt(u32, ram[0x2008..0x200c], .little));
    try std.testing.expectEqual(@as(u32, 0xDDEEFF00), std.mem.readInt(u32, ram[0x200c..0x2010], .little));
    try std.testing.expect((soc.read32(0x20204000) & spi_mod.Spi0.CS_DONE) != 0);

    // 2. TX-only DMA transfer with cyclic clear_rx_desc writing CLEAR_RX to SPI_CS (matches bcm2835_spi_setup_dma)
    const clear_rx_cs: u32 = spi_mod.Spi0.CS_TA | spi_mod.Spi0.CS_DMAEN | spi_mod.Spi0.CS_CLEAR_RX;
    std.mem.writeInt(u32, ram[0x3000..0x3004], clear_rx_cs, .little);
    const clr_cb: u32 = 0x280;
    const clr_ti: u32 = (1 << 6) | (7 << 16); // PERMAP 7 (SPI RX), D_DREQ
    std.mem.writeInt(u32, ram[clr_cb + 0 ..][0..4], clr_ti, .little);
    std.mem.writeInt(u32, ram[clr_cb + 4 ..][0..4], 0xc0003000, .little);
    std.mem.writeInt(u32, ram[clr_cb + 8 ..][0..4], 0x7e204000, .little); // SPI_CS
    std.mem.writeInt(u32, ram[clr_cb + 12 ..][0..4], 4, .little);
    std.mem.writeInt(u32, ram[clr_cb + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[clr_cb + 20 ..][0..4], 0xc0000280, .little); // cyclic

    soc.write32(0x2020400c, 16); // SPI_DLEN = 16
    soc.write32(0x20204000, spi_mod.Spi0.CS_TA | spi_mod.Spi0.CS_DMAEN);
    soc.write32(0x20007004, 0xc0000200);
    soc.write32(0x20007000, dma_mod.DmaController.CS_ACTIVE);
    soc.write32(0x20007104, 0xc0000280);
    soc.write32(0x20007100, dma_mod.DmaController.CS_ACTIVE);

    try std.testing.expectEqual(@as(usize, 0), soc.spi0.rx_count);
    try std.testing.expect((soc.read32(0x20204000) & spi_mod.Spi0.CS_DONE) != 0);
}

test "Bcm2835 AUX SPI1/SPI2 and I2S PCM (PERMAP 2) audio streaming" {
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);

    var soc = Bcm2835.init(ram, 1280, 720);
    soc.aux_uart.spi1.loopback = true;

    // 1. Enable AUX SPI1 (bit 1 of AUX_ENABLES at 0x20215004) and verify AUX_IRQ (IRQ 29)
    soc.write32(0x20215004, uart_mod.AuxMiniUart.AUX_ENABLE_MU | uart_mod.AuxMiniUart.AUX_ENABLE_SPI1);
    soc.write32(0x20215080, spi_mod.AuxSpi.CNTL0_ENABLE | spi_mod.AuxSpi.CNTL0_VAR_WIDTH | spi_mod.AuxSpi.CNTL0_MSBF_OUT);
    soc.write32(0x20215084, spi_mod.AuxSpi.CNTL1_IDLE);
    try std.testing.expectEqual(@as(u32, uart_mod.AuxMiniUart.AUX_ENABLE_SPI1), soc.read32(0x20215000));
    try std.testing.expect((soc.intc.raw_level[1] & (1 << 29)) != 0);

    soc.write32(0x202150a0, (16 << 24) | (0xBE << 16) | (0xEF << 8));
    try std.testing.expectEqual(@as(u32, 0x0000BEEF), soc.read32(0x202150a0));

    // 2. Verify I2S CS_A_SYNC round-trip (used by bcm2835_i2s_clear_fifos)
    const sync0 = soc.read32(0x20203000) & audio_mod.I2sPcm.CS_SYNC;
    try std.testing.expectEqual(@as(u32, 0), sync0);
    soc.write32(0x20203000, audio_mod.I2sPcm.CS_EN | audio_mod.I2sPcm.CS_STBY | audio_mod.I2sPcm.CS_SYNC);
    try std.testing.expect((soc.read32(0x20203000) & audio_mod.I2sPcm.CS_SYNC) != 0);

    // 3. Configure I2S for Frame-Packed S16_LE stereo (MODE_FTXP) and stream 2 frames via cyclic DMA PERMAP 2
    soc.write32(0x20203008, audio_mod.I2sPcm.MODE_FTXP | (31 << 10) | 16);
    soc.write32(0x20203000, audio_mod.I2sPcm.CS_EN | audio_mod.I2sPcm.CS_STBY | audio_mod.I2sPcm.CS_DMAEN | audio_mod.I2sPcm.CS_TXON);

    // 2 packed stereo S16_LE frames (8 bytes) at RAM 0x4000:
    // Frame 0: L = 0x1357, R = -0x1357
    // Frame 1: L = 0x2468, R = -0x2468
    std.mem.writeInt(i16, ram[0x4000..0x4002], 0x1357, .little);
    std.mem.writeInt(i16, ram[0x4002..0x4004], -0x1357, .little);
    std.mem.writeInt(i16, ram[0x4004..0x4006], 0x2468, .little);
    std.mem.writeInt(i16, ram[0x4006..0x4008], -0x2468, .little);

    const i2s_cb: u32 = 0x500;
    const i2s_ti: u32 = dma_mod.DmaController.TI_S_INC | dma_mod.DmaController.TI_INT_EN | (1 << 6) | (2 << 16);
    std.mem.writeInt(u32, ram[i2s_cb + 0 ..][0..4], i2s_ti, .little);
    std.mem.writeInt(u32, ram[i2s_cb + 4 ..][0..4], 0xc0004000, .little);
    std.mem.writeInt(u32, ram[i2s_cb + 8 ..][0..4], 0x7e203004, .little); // BCM2835_I2S_FIFO_A_REG
    std.mem.writeInt(u32, ram[i2s_cb + 12 ..][0..4], 8, .little);
    std.mem.writeInt(u32, ram[i2s_cb + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[i2s_cb + 20 ..][0..4], 0xc0000500, .little); // cyclic

    soc.write32(0x20007004, 0xc0000500);
    soc.write32(0x20007000, dma_mod.DmaController.CS_ACTIVE);
    try std.testing.expectEqual(@as(u32, 0), soc.audio_fifo.availableFrames());

    soc.advanceAudio(22); // 8 bytes at 384 KB/s = 20.83 us
    try std.testing.expect(soc.dma.channelIrqPending(0));
    try std.testing.expectEqual(@as(u32, 2), soc.audio_fifo.availableFrames());

    var samples: [4]i16 = undefined;
    try std.testing.expectEqual(@as(usize, 2), soc.audio_fifo.popFrames(&samples));
    try std.testing.expectEqual(@as(i16, 0x1357), samples[0]);
    try std.testing.expectEqual(@as(i16, -0x1357), samples[1]);
    try std.testing.expectEqual(@as(i16, 0x2468), samples[2]);
    try std.testing.expectEqual(@as(i16, -0x2468), samples[3]);
    _ = pm_mod;
}



