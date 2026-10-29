const std = @import("std");
const intc_mod = @import("intc.zig");
const timer_mod = @import("timer.zig");
const mailbox_mod = @import("mailbox.zig");
const cprman_mod = @import("cprman.zig");
const pm_mod = @import("pm.zig");
const gpio_mod = @import("gpio.zig");
const uart_mod = @import("uart.zig");
const bluetooth_mod = @import("bluetooth.zig");
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
const smi_mod = @import("smi.zig");
const mphi_mod = @import("mphi.zig");
const smp_mod = @import("smp.zig");

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
    bt: bluetooth_mod.Controller = .{},
    /// UART whose TXD/RXD reach the Bluetooth controller through GPIO 32/33.
    bt_uart: enum { none, pl011, mini } = .none,
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
    smi: smi_mod.Smi = .{},
    mphi: mphi_mod.Mphi = .{},
    smp: smp_mod.Smp = .{},

    /// Unemulated peripheral pages the guest touched (each is logged once per boot)
    unmapped_pages: [32]u32 = @splat(0),
    unmapped_page_count: u8 = 0,
    unmapped_mmio_used: bool = false,

    display_width: u16 = 1280,
    display_height: u16 = 720,
    audio_connected: bool = true,
    act_led_hold_frames: u8 = 0,
    last_display_hash: u64 = 0,
    last_display_was_hvs: bool = false,

    pub fn initInPlace(self: *Bcm2835, ram: []u8, display_width: u16, display_height: u16) void {
        self.ram = ram;
        self.is_bcm2837 = false;
        self.intc = .{};
        self.local_intc = .{};
        self.timer = .{};
        self.arm_timer = .{};
        self.mailbox = .{};
        self.cprman = .{};
        self.pm = .{};
        self.asb = .{};
        self.rng = .{};
        self.thermal = .{};
        self.gpio = .{};
        self.uart0 = .{};
        self.aux_uart = .{};
        self.bt = .{};
        self.bt_uart = .none;
        self.dma = .{};
        self.sdhost = .{};
        self.sdhci = .{};
        self.bsc0 = i2c_mod.BscController.init(false, 1280, 720);
        self.bsc1 = i2c_mod.BscController.init(false, 1280, 720);
        self.bsc2 = i2c_mod.BscController.init(true, display_width, display_height);
        self.usb = .{};
        self.v3d.resetInPlace();
        self.hvs = .{};
        self.pv0 = .{};
        self.pv1 = .{};
        self.pv2 = .{};
        self.hdmi = .{};
        self.txp = .{};
        self.audio_fifo = .{};
        self.vchiq = .{};
        self.pwm = .{};
        self.i2s = .{};
        self.spi0 = .{};
        self.smi = .{};
        self.mphi = .{};
        self.smp = .{};
        self.unmapped_pages = @splat(0);
        self.unmapped_page_count = 0;
        self.unmapped_mmio_used = false;
        self.display_width = display_width;
        self.display_height = display_height;
        self.audio_connected = true;
        self.act_led_hold_frames = 0;
        self.last_display_hash = 0;
        self.last_display_was_hvs = false;

        self.mailbox.fb_width = display_width;
        self.mailbox.fb_height = display_height;
        self.mailbox.fb_virt_width = display_width;
        self.mailbox.fb_virt_height = display_height;
        self.usb.hid.guest_x = @divTrunc(@as(i32, display_width), 2);
        self.usb.hid.guest_y = @divTrunc(@as(i32, display_height), 2);
        self.usb.hid.target_x = self.usb.hid.guest_x;
        self.usb.hid.target_y = self.usb.hid.guest_y;
    }

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
        if (self.smp.parallel) return ((self.smp.irq_summary.load(.monotonic) >> core_id) & 1) != 0;
        return self.computeIrqPendingForCore(core_id);
    }

    pub inline fn hasPendingFiqForCore(self: *const Bcm2835, core_id: u2) bool {
        if (self.smp.parallel) return ((self.smp.irq_summary.load(.monotonic) >> (@as(u5, core_id) + 4)) & 1) != 0;
        return self.computeFiqPendingForCore(core_id);
    }

    inline fn computeIrqPendingForCore(self: *const Bcm2835, core_id: u2) bool {
        if (self.is_bcm2837) {
            return self.local_intc.irqPendingForCore(core_id, self.intc.hasPendingIrq()) != 0;
        }
        return core_id == 0 and self.intc.hasPendingIrq();
    }

    inline fn computeFiqPendingForCore(self: *const Bcm2835, core_id: u2) bool {
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

    fn reportUnmappedMmio(self: *Bcm2835, addr: u32) void {
        self.unmapped_mmio_used = true;
        const page = addr & ~@as(u32, 0xfff);
        for (self.unmapped_pages[0..self.unmapped_page_count]) |p| {
            if (p == page) return;
        }
        if (self.unmapped_page_count < self.unmapped_pages.len) {
            self.unmapped_pages[self.unmapped_page_count] = page;
            self.unmapped_page_count += 1;
        }
        std.debug.print("fauxpi: mmio: access to unemulated peripheral at bus address 0x{x:0>8}\n", .{page - PERIPH_BASE + 0x7e000000});
    }

    /// True once the guest has used a firmware property tag or peripheral fauxpi does not emulate.
    pub fn unsupportedHardwareUsed(self: *const Bcm2835) bool {
        return self.mailbox.unsupported_used or self.unmapped_mmio_used;
    }

    /// Recomputes `smp.irq_summary` from the interrupt controllers for every core.
    pub fn publishIrqSummary(self: *Bcm2835) void {
        var summary: u32 = 0;
        for (0..smp_mod.max_cores) |i| {
            const cid: u2 = @intCast(i);
            if (self.computeIrqPendingForCore(cid)) summary |= @as(u32, 1) << cid;
            if (self.computeFiqPendingForCore(cid)) summary |= @as(u32, 1) << (@as(u5, cid) + 4);
        }
        self.smp.irq_summary.store(summary, .release);
        const wfi_m = self.smp.wfi_mask.load(.monotonic);
        if (wfi_m != 0 and (((summary & 0x0f) | (summary >> 4)) & wfi_m) != 0) {
            self.smp.wake_wfi.store(1, .release);
        }
    }

    /// Updates the generic timer interrupt lines of `core_id` after a CPU writes its timer registers.
    pub fn setCoreTimerLines(self: *Bcm2835, core_id: u2, lines: u4) void {
        if (!self.smp.parallel) {
            self.local_intc.core_timer_lines[core_id] = lines;
            if (self.smp.wfi_mask.load(.monotonic) != 0) self.publishIrqSummary();
            return;
        }
        self.smp.device_lock.lock();
        defer self.smp.device_lock.unlock();
        self.local_intc.core_timer_lines[core_id] = lines;
        self.publishIrqSummary();
    }

    inline fn cpuReadMmio32(self: *Bcm2835, addr: u32) u32 {
        if (!self.smp.parallel) return self.readMmio32(addr);
        self.smp.device_lock.lock();
        defer self.smp.device_lock.unlock();
        const val = self.readMmio32(addr);
        self.publishIrqSummary();
        return val;
    }

    inline fn cpuWriteMmio32(self: *Bcm2835, addr: u32, val: u32) void {
        if (!self.smp.parallel) {
            self.writeMmio32(addr, val);
            if (self.smp.wfi_mask.load(.monotonic) != 0) self.publishIrqSummary();
            return;
        }
        self.smp.device_lock.lock();
        defer self.smp.device_lock.unlock();
        self.writeMmio32(addr, val);
        self.publishIrqSummary();
    }

    fn dmaMmio(self: *Bcm2835) dma_mod.DmaController.MmioIo {
        return .{
            .ctx = self,
            .read32Fn = busRead32Opaque,
            .write32Fn = busWrite32Opaque,
            .dreqReadyFn = dmaDreqReady,
            .readFifoBulkFn = busReadFifoBulkOpaque,
            .writeFifoBulkFn = busWriteFifoBulkOpaque,
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

    /// Connects the Bluetooth controller to the UART muxed onto GPIO 32 (TXD): PL011 on ALT3
    /// (`uart0_pins`) or the mini UART on ALT5 (`uart1_bt_pins`, `dtoverlay=miniuart-bt`).
    pub fn syncBtRoutingFromGpio(self: *Bcm2835) void {
        self.bt_uart = if (!self.bt.enabled) .none else switch (self.gpio.getPinFunction(32)) {
            .alt3 => .pl011,
            .alt5 => .mini,
            else => .none,
        };
        self.uart0.tx_capture = self.bt_uart == .pl011;
        self.aux_uart.tx_capture = self.bt_uart == .mini;
    }

    /// Moves bytes between the Bluetooth controller and its UART.
    fn pumpBt(self: *Bcm2835) void {
        switch (self.bt_uart) {
            .none => {},
            .pl011 => {
                for (self.uart0.tx_capture_buf[0..self.uart0.tx_capture_len]) |b| self.bt.hostWrite(b);
                self.uart0.tx_capture_len = 0;
                while (self.uart0.rxSpace() > 0) self.uart0.pushRx(self.bt.popOut() orelse break);
            },
            .mini => {
                for (self.aux_uart.tx_capture_buf[0..self.aux_uart.tx_capture_len]) |b| self.bt.hostWrite(b);
                self.aux_uart.tx_capture_len = 0;
                while (self.aux_uart.rxSpace() > 0) self.aux_uart.pushRx(self.bt.popOut() orelse break);
            },
        }
    }

    fn busRead32Opaque(ctx: *anyopaque, raw_addr: u32) u32 {
        const self: *Bcm2835 = @ptrCast(@alignCast(ctx));
        return self.read32(raw_addr);
    }

    fn busWrite32Opaque(ctx: *anyopaque, raw_addr: u32, val: u32) void {
        const self: *Bcm2835 = @ptrCast(@alignCast(ctx));
        self.write32(raw_addr, val);
    }

    fn busReadFifoBulkOpaque(ctx: *anyopaque, raw_addr: u32, dst: []u8) bool {
        const self: *Bcm2835 = @ptrCast(@alignCast(ctx));
        return switch (normalizeAddr(raw_addr)) {
            sdhost_mod.SdHost.BASE_ADDR + 0x40 => self.sdhost.tryReadDataBulk(dst),
            sdhost_mod.ArasanSdhci.BASE_ADDR + 0x20 => self.sdhci.tryReadDataBulk(&self.sdhost, dst),
            else => false,
        };
    }

    fn busWriteFifoBulkOpaque(ctx: *anyopaque, raw_addr: u32, src: []const u8) bool {
        const self: *Bcm2835 = @ptrCast(@alignCast(ctx));
        return switch (normalizeAddr(raw_addr)) {
            sdhost_mod.SdHost.BASE_ADDR + 0x40 => self.sdhost.tryWriteDataBulk(src),
            sdhost_mod.ArasanSdhci.BASE_ADDR + 0x20 => self.sdhci.tryWriteDataBulk(&self.sdhost, src),
            hdmi_mod.Hdmi.HD_BASE + hdmi_mod.Hdmi.HD_MAI_DATA => self.hdmi.writeMaiDataBulk(src, &self.audio_fifo),
            audio_mod.PwmAudio.BASE_ADDR + audio_mod.PwmAudio.PWM_FIF1 => self.pwm.writeFif1Bulk(src, &self.audio_fifo, self.audio_connected),
            audio_mod.I2sPcm.BASE_ADDR + audio_mod.I2sPcm.REG_FIFO_A => self.i2s.writeFifoBulk(src, &self.audio_fifo, self.audio_connected),
            else => false,
        };
    }

    const MmioPage = enum(u8) {
        none = 0,
        timer,
        txp,
        dma,
        asb,
        page_00b,
        pm,
        cprman,
        rng,
        mphi,
        gpio,
        uart0,
        sdhost,
        i2s,
        spi0,
        smi,
        bsc0,
        pv0,
        pv1,
        pwm,
        thermal,
        aux_uart,
        sdhci,
        hvs,
        bsc1,
        bsc2,
        pv2,
        hdmi_hd,
        hdmi_core,
        usb,
        v3d,
    };

    const MMIO_PAGE_TABLE: [4096]MmioPage = blk: {
        var table: [4096]MmioPage = @splat(.none);
        const Entry = struct { base: u32, size: u32, tag: MmioPage };
        const entries = [_]Entry{
            .{ .base = TIMER_BASE, .size = TIMER_SIZE, .tag = .timer },
            .{ .base = hdmi_mod.Txp.BASE_ADDR, .size = hdmi_mod.Txp.SIZE, .tag = .txp },
            .{ .base = dma_mod.DmaController.BASE_ADDR, .size = dma_mod.DmaController.SIZE, .tag = .dma },
            .{ .base = pm_mod.AsbBridge.BASE_ADDR, .size = pm_mod.AsbBridge.SIZE, .tag = .asb },
            .{ .base = INTC_BASE, .size = INTC_SIZE, .tag = .page_00b },
            .{ .base = timer_mod.ArmTimer.BASE_ADDR, .size = timer_mod.ArmTimer.SIZE, .tag = .page_00b },
            .{ .base = audio_mod.Vchiq.BASE_ADDR, .size = audio_mod.Vchiq.SIZE, .tag = .page_00b },
            .{ .base = mailbox_mod.Mailbox.BASE_ADDR, .size = mailbox_mod.Mailbox.SIZE, .tag = .page_00b },
            .{ .base = pm_mod.PowerManager.BASE_ADDR, .size = pm_mod.PowerManager.SIZE, .tag = .pm },
            .{ .base = cprman_mod.Cprman.BASE_ADDR, .size = cprman_mod.Cprman.SIZE, .tag = .cprman },
            .{ .base = pm_mod.Rng.BASE_ADDR, .size = pm_mod.Rng.SIZE, .tag = .rng },
            .{ .base = mphi_mod.Mphi.BASE_ADDR, .size = mphi_mod.Mphi.SIZE, .tag = .mphi },
            .{ .base = gpio_mod.Gpio.BASE_ADDR, .size = gpio_mod.Gpio.SIZE, .tag = .gpio },
            .{ .base = uart_mod.Pl011Uart.BASE_ADDR, .size = uart_mod.Pl011Uart.SIZE, .tag = .uart0 },
            .{ .base = sdhost_mod.SdHost.BASE_ADDR, .size = sdhost_mod.SdHost.SIZE, .tag = .sdhost },
            .{ .base = audio_mod.I2sPcm.BASE_ADDR, .size = audio_mod.I2sPcm.SIZE, .tag = .i2s },
            .{ .base = spi_mod.Spi0.BASE_ADDR, .size = spi_mod.Spi0.SIZE, .tag = .spi0 },
            .{ .base = smi_mod.Smi.BASE_ADDR, .size = smi_mod.Smi.SIZE, .tag = .smi },
            .{ .base = i2c_mod.BscController.BSC0_BASE, .size = i2c_mod.BscController.SIZE, .tag = .bsc0 },
            .{ .base = pv_mod.PixelValve.PV0_BASE, .size = pv_mod.PixelValve.SIZE, .tag = .pv0 },
            .{ .base = pv_mod.PixelValve.PV1_BASE, .size = pv_mod.PixelValve.SIZE, .tag = .pv1 },
            .{ .base = audio_mod.PwmAudio.BASE_ADDR, .size = audio_mod.PwmAudio.SIZE, .tag = .pwm },
            .{ .base = pm_mod.Thermal.BASE_ADDR, .size = pm_mod.Thermal.SIZE, .tag = .thermal },
            .{ .base = uart_mod.AuxMiniUart.BASE_ADDR, .size = uart_mod.AuxMiniUart.SIZE, .tag = .aux_uart },
            .{ .base = sdhost_mod.ArasanSdhci.BASE_ADDR, .size = sdhost_mod.ArasanSdhci.SIZE, .tag = .sdhci },
            .{ .base = hvs_mod.Hvs.BASE_ADDR, .size = hvs_mod.Hvs.SIZE, .tag = .hvs },
            .{ .base = i2c_mod.BscController.BSC1_BASE, .size = i2c_mod.BscController.SIZE, .tag = .bsc1 },
            .{ .base = i2c_mod.BscController.BSC2_BASE, .size = i2c_mod.BscController.SIZE, .tag = .bsc2 },
            .{ .base = pv_mod.PixelValve.PV2_BASE, .size = pv_mod.PixelValve.SIZE, .tag = .pv2 },
            .{ .base = hdmi_mod.Hdmi.HD_BASE, .size = hdmi_mod.Hdmi.HD_SIZE, .tag = .hdmi_hd },
            .{ .base = hdmi_mod.Hdmi.HDMI_BASE, .size = hdmi_mod.Hdmi.HDMI_SIZE, .tag = .hdmi_core },
            .{ .base = dwc2_mod.Dwc2Controller.BASE_ADDR, .size = dwc2_mod.Dwc2Controller.SIZE, .tag = .usb },
            .{ .base = v3d_mod.V3d.BASE_ADDR, .size = v3d_mod.V3d.SIZE, .tag = .v3d },
        };
        for (entries) |e| {
            const first_page = (e.base - PERIPH_BASE) >> 12;
            const last_page = (e.base + e.size - 1 - PERIPH_BASE) >> 12;
            var p = first_page;
            while (p <= last_page) : (p += 1) {
                std.debug.assert(table[p] == .none or table[p] == e.tag);
                table[p] = e.tag;
            }
        }
        break :blk table;
    };

    pub inline fn updateIrqsBank0(self: *Bcm2835) void {
        self.intc.raw_level[0] = (@as(u32, @intFromBool(self.arm_timer.irqPending())) << 0) |
            (@as(u32, @intFromBool(self.mailbox.irqPending())) << 1) |
            (@as(u32, @intFromBool(self.vchiq.irqPending())) << 2);
    }

    pub inline fn updateIrqsBank1(self: *Bcm2835) void {
        self.intc.raw_level[1] = (self.timer.cs & 0xf) |
            (@as(u32, @intFromBool(self.usb.irqPending())) << 9) |
            (@as(u32, @intFromBool(self.v3d.irqPending())) << 10) |
            (self.dma.irqLines() << 16) |
            (@as(u32, @intFromBool(self.aux_uart.irqPending())) << 29);
    }

    pub inline fn updateIrqsBank2(self: *Bcm2835) void {
        self.intc.raw_level[2] = @as(u32, @intFromBool(self.mphi.irqPending())) |
            (@as(u32, @intFromBool(self.hvs.irqPending())) << 1) |
            (@as(u32, @intFromBool(self.pv2.irqPending())) << 10) |
            (@as(u32, @intFromBool(self.pv0.irqPending())) << 13) |
            (@as(u32, @intFromBool(self.pv1.irqPending())) << 14) |
            (@as(u32, @intFromBool(self.smi.irqPending())) << 16) |
            (@as(u32, @intFromBool(self.gpio.irqPending())) << 20) |
            (@as(u32, @intFromBool(self.bsc0.irqPending() or self.bsc1.irqPending() or self.bsc2.irqPending())) << 21) |
            (@as(u32, @intFromBool(self.spi0.irqPending())) << 22) |
            (@as(u32, @intFromBool(self.i2s.irqPending())) << 23) |
            (@as(u32, @intFromBool(self.sdhost.irqPending())) << 24) |
            (@as(u32, @intFromBool(self.uart0.irqPending())) << 25) |
            (@as(u32, @intFromBool(self.sdhci.irqPending())) << 30);
    }

    /// Updates all interrupt lines on `IntController` from peripheral states.
    pub fn updateIrqs(self: *Bcm2835) void {
        self.updateIrqsBank0();
        self.updateIrqsBank1();
        self.updateIrqsBank2();
    }

    /// Triggers 60 Hz vertical blanking on PixelValves and HVS.
    pub fn triggerVblank(self: *Bcm2835) void {
        self.pv0.triggerVblank();
        self.pv1.triggerVblank();
        self.pv2.triggerVblank();
        self.smi.triggerVblank();
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
        self.updateIrqsBank2();
    }

    /// Connects or disconnects the simulated 3.5 mm audio/video jack.
    /// Note: Physical Raspberry Pi boards do not wire a jack-detect switch to any SoC GPIO;
    /// this state controls whether analog/PWM audio output is played on the host.
    pub fn setAudioConnected(self: *Bcm2835, connected: bool) void {
        self.audio_connected = connected;
    }

    /// Sets the simulated SoC temperature in degrees Celsius (`0..100` °C) for both the
    /// VideoCore property mailbox (`0x00030006`) and the `bcm2835-thermal` MMIO sensor.
    pub fn setCpuTemperatureCelsius(self: *Bcm2835, temp_c: u8) void {
        const temp_mc: u32 = @as(u32, temp_c) * 1000;
        self.mailbox.temperature_mc = temp_mc;
        self.thermal.temperature_mc = @intCast(temp_mc);
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
        return self.renderMailboxFb(out_argb, width, height);
    }

    fn renderMailboxFb(self: *const Bcm2835, out_argb: []u32, width: u32, height: u32) bool {
        if (!self.mailbox.fb_allocated) return false;
        const fb_phys = self.mailbox.fb_bus_addr & 0x1FFFFFFF;
        const fb_w = self.mailbox.fb_width;
        const fb_h = self.mailbox.fb_height;
        const bpp = self.mailbox.fb_depth / 8;
        const pitch = self.mailbox.rowBytes();
        if (bpp < 2 or fb_w == 0 or fb_h == 0 or out_argb.len < width * height) return false;

        const fmt_mod = @import("../vc4/format.zig");

        // Fast path: 1:1 unscaled, packed Mailbox framebuffer (8-wide SIMD)
        if (fb_w == width and fb_h == height and pitch == fb_w * bpp) {
            const total_px: usize = @as(usize, width) * @as(usize, height);
            const total_bytes: usize = total_px * bpp;
            if (@as(usize, fb_phys) + total_bytes <= self.ram.len) {
                const src_bytes = self.ram[fb_phys..][0..total_bytes];
                if (bpp == 2) {
                    var i: usize = 0;
                    while (i + 8 <= total_px) : (i += 8) {
                        const p16_vec: @Vector(8, u16) = @bitCast(src_bytes[i * 2 ..][0..16].*);
                        out_argb[i..][0..8].* = @bitCast(fmt_mod.fromRgb565Vec8(p16_vec));
                    }
                    while (i < total_px) : (i += 1) {
                        const p16 = std.mem.readInt(u16, src_bytes[i * 2 ..][0..2], .little);
                        out_argb[i] = fmt_mod.fromRgb565(p16);
                    }
                    return true;
                } else if (bpp == 4) {
                    const opaque_mask8: @Vector(8, u32) = @splat(0xFF000000);
                    var i: usize = 0;
                    while (i + 8 <= total_px) : (i += 8) {
                        const src_v: @Vector(8, u32) = @bitCast(src_bytes[i * 4 ..][0..32].*);
                        out_argb[i..][0..8].* = @bitCast(src_v | opaque_mask8);
                    }
                    while (i < total_px) : (i += 1) {
                        out_argb[i] = std.mem.readInt(u32, src_bytes[i * 4 ..][0..4], .little) | 0xFF000000;
                    }
                    return true;
                }
            }
        }

        for (0..height) |y| {
            const sy = (@as(u32, @intCast(y)) * fb_h) / height;
            for (0..width) |x| {
                const sx = (@as(u32, @intCast(x)) * fb_w) / width;
                const off = fb_phys + sy * pitch + sx * bpp;
                if (off + bpp <= self.ram.len) {
                    out_argb[y * width + x] = if (bpp == 2)
                        fmt_mod.fromRgb565(std.mem.readInt(u16, self.ram[off..][0..2], .little))
                    else
                        std.mem.readInt(u32, self.ram[off..][0..4], .little) | 0xFF000000;
                }
            }
        }
        return true;
    }

    /// Composites the current HDMI frame only if the display list, V3D output, or scanout RAM changed.
    pub fn renderDisplayFrameIfChanged(
        self: *Bcm2835,
        out_argb: []u32,
        width: u32,
        height: u32,
        force: bool,
        cpu_was_active: bool,
    ) struct { active: bool, changed: bool } {
        if (!self.hdmi.connected) {
            self.last_display_hash = 0;
            self.last_display_was_hvs = false;
            return .{ .active = false, .changed = false };
        }

        const dlist_dirty = self.hvs.dlist_updated;
        self.hvs.dlist_updated = false;
        const v3d_dirty = self.v3d.takeFrameDirty();

        if (self.hvs.isActive()) {
            if (!force and self.last_display_was_hvs and !dlist_dirty and !v3d_dirty) {
                if (!cpu_was_active) {
                    return .{ .active = true, .changed = false };
                }
                const h = self.hvs.computeActivePlanesHash(self.ram, width, height);
                if (h != 0 and h == self.last_display_hash) {
                    return .{ .active = true, .changed = false };
                }
                if (self.hvs.compositeFrame(self.ram, out_argb, width, height)) {
                    self.last_display_hash = h;
                    self.last_display_was_hvs = true;
                    return .{ .active = true, .changed = true };
                }
            } else if (self.hvs.compositeFrame(self.ram, out_argb, width, height)) {
                self.last_display_hash = self.hvs.computeActivePlanesHash(self.ram, width, height);
                self.last_display_was_hvs = true;
                return .{ .active = true, .changed = true };
            }
        }

        if (self.mailbox.fb_allocated) {
            const fb_phys = self.mailbox.fb_bus_addr & 0x1FFFFFFF;
            const fb_w = self.mailbox.fb_width;
            const fb_h = self.mailbox.fb_height;
            const bpp = self.mailbox.fb_depth / 8;
            if (bpp >= 2 and fb_w > 0 and fb_h > 0) {
                const fb_bytes: usize = @as(usize, self.mailbox.rowBytes()) * @as(usize, fb_h);
                var h: u64 = 0;
                if (@as(usize, fb_phys) + fb_bytes <= self.ram.len) {
                    if (!force and !self.last_display_was_hvs and !v3d_dirty) {
                        if (!cpu_was_active and self.last_display_hash != 0) {
                            return .{ .active = true, .changed = false };
                        }
                        h = std.hash.Wyhash.hash(0x517CC1B727220A95, self.ram[fb_phys..][0..fb_bytes]);
                        if (h == self.last_display_hash) {
                            return .{ .active = true, .changed = false };
                        }
                    } else {
                        h = std.hash.Wyhash.hash(0x517CC1B727220A95, self.ram[fb_phys..][0..fb_bytes]);
                    }
                }
                if (self.renderMailboxFb(out_argb, width, height)) {
                    self.last_display_hash = h;
                    self.last_display_was_hvs = false;
                    return .{ .active = true, .changed = true };
                }
            }
        }

        self.last_display_hash = 0;
        self.last_display_was_hvs = false;
        return .{ .active = false, .changed = false };
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
        return (addr -% PERIPH_BASE < (PERIPH_END - PERIPH_BASE)) or
            (addr -% local_intc_mod.LocalIntc.BASE_ADDR < local_intc_mod.LocalIntc.SIZE);
    }

    pub fn read8(self: *Bcm2835, raw_addr: u32) u8 {
        const addr = normalizeAddr(raw_addr);
        if (!isMmioAddr(addr)) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off < self.ram.len) return self.ram[ram_off];
            return 0;
        }
        const word = self.cpuReadMmio32(addr & ~@as(u32, 3));
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
        const word = self.cpuReadMmio32(addr & ~@as(u32, 3));
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
        return self.cpuReadMmio32(addr & ~@as(u32, 3));
    }

    pub fn write8(self: *Bcm2835, raw_addr: u32, val: u8) void {
        const addr = normalizeAddr(raw_addr);
        if (!isMmioAddr(addr)) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off < self.ram.len) self.ram[ram_off] = val;
            return;
        }
        self.cpuWriteMmio32(addr & ~@as(u32, 3), val);
    }

    pub fn write16(self: *Bcm2835, raw_addr: u32, val: u16) void {
        const addr = normalizeAddr(raw_addr);
        if (!isMmioAddr(addr)) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off + 2 <= self.ram.len) std.mem.writeInt(u16, self.ram[ram_off..][0..2], val, .little);
            return;
        }
        self.cpuWriteMmio32(addr & ~@as(u32, 3), val);
    }

    pub fn write32(self: *Bcm2835, raw_addr: u32, val: u32) void {
        const addr = normalizeAddr(raw_addr);
        if (!isMmioAddr(addr)) {
            const ram_off = addr & 0x1FFFFFFF;
            if (ram_off + 4 <= self.ram.len) std.mem.writeInt(u32, self.ram[ram_off..][0..4], val, .little);
            return;
        }
        self.cpuWriteMmio32(addr & ~@as(u32, 3), val);
    }

    pub fn readMmio32(self: *Bcm2835, addr: u32) u32 {
        const periph_off = addr -% PERIPH_BASE;
        if (periph_off < (PERIPH_END - PERIPH_BASE)) {
            return switch (MMIO_PAGE_TABLE[periph_off >> 12]) {
                .none => blk: {
                    self.reportUnmappedMmio(addr);
                    break :blk 0;
                },
                .timer => if (addr -% TIMER_BASE < TIMER_SIZE) self.timer.read32(addr - TIMER_BASE) else 0,
                .txp => if (addr -% hdmi_mod.Txp.BASE_ADDR < hdmi_mod.Txp.SIZE) self.txp.read32(addr - hdmi_mod.Txp.BASE_ADDR) else 0,
                .dma => self.dma.read32(addr - dma_mod.DmaController.BASE_ADDR),
                .asb => if (addr -% pm_mod.AsbBridge.BASE_ADDR < pm_mod.AsbBridge.SIZE) self.asb.read32(addr - pm_mod.AsbBridge.BASE_ADDR) else 0,
                .page_00b => {
                    if (addr -% INTC_BASE < INTC_SIZE) {
                        self.updateIrqs();
                        return self.intc.read32(addr - INTC_BASE);
                    }
                    if (addr -% timer_mod.ArmTimer.BASE_ADDR < timer_mod.ArmTimer.SIZE) {
                        return self.arm_timer.read32(addr - timer_mod.ArmTimer.BASE_ADDR);
                    }
                    if (addr -% audio_mod.Vchiq.BASE_ADDR < audio_mod.Vchiq.SIZE) {
                        return self.vchiq.read32(addr - audio_mod.Vchiq.BASE_ADDR);
                    }
                    if (addr -% mailbox_mod.Mailbox.BASE_ADDR < mailbox_mod.Mailbox.SIZE) {
                        return self.mailbox.read32(addr - mailbox_mod.Mailbox.BASE_ADDR);
                    }
                    return 0;
                },
                .pm => if (addr -% pm_mod.PowerManager.BASE_ADDR < pm_mod.PowerManager.SIZE) self.pm.read32(addr - pm_mod.PowerManager.BASE_ADDR) else 0,
                .cprman => self.cprman.read32(addr - cprman_mod.Cprman.BASE_ADDR),
                .rng => if (addr -% pm_mod.Rng.BASE_ADDR < pm_mod.Rng.SIZE) self.rng.read32(addr - pm_mod.Rng.BASE_ADDR) else 0,
                .mphi => self.mphi.read32(addr - mphi_mod.Mphi.BASE_ADDR),
                .gpio => if (addr -% gpio_mod.Gpio.BASE_ADDR < gpio_mod.Gpio.SIZE) self.gpio.read32(addr - gpio_mod.Gpio.BASE_ADDR) else 0,
                .uart0 => blk: {
                    const v = self.uart0.read32(addr - uart_mod.Pl011Uart.BASE_ADDR);
                    if (self.bt_uart == .pl011 and addr == uart_mod.Pl011Uart.BASE_ADDR) {
                        self.pumpBt();
                        self.updateIrqsBank2();
                    }
                    break :blk v;
                },
                .sdhost => if (addr -% sdhost_mod.SdHost.BASE_ADDR < sdhost_mod.SdHost.SIZE) self.sdhost.read32(addr - sdhost_mod.SdHost.BASE_ADDR) else 0,
                .i2s => if (addr -% audio_mod.I2sPcm.BASE_ADDR < audio_mod.I2sPcm.SIZE) self.i2s.read32(addr - audio_mod.I2sPcm.BASE_ADDR) else 0,
                .spi0 => if (addr -% spi_mod.Spi0.BASE_ADDR < spi_mod.Spi0.SIZE) self.spi0.read32(addr - spi_mod.Spi0.BASE_ADDR) else 0,
                .smi => if (addr -% smi_mod.Smi.BASE_ADDR < smi_mod.Smi.SIZE) self.smi.read32(addr - smi_mod.Smi.BASE_ADDR) else 0,
                .bsc0 => if (addr -% i2c_mod.BscController.BSC0_BASE < i2c_mod.BscController.SIZE) self.bsc0.read32(addr - i2c_mod.BscController.BSC0_BASE) else 0,
                .pv0 => if (addr -% pv_mod.PixelValve.PV0_BASE < pv_mod.PixelValve.SIZE) self.pv0.read32(addr - pv_mod.PixelValve.PV0_BASE) else 0,
                .pv1 => if (addr -% pv_mod.PixelValve.PV1_BASE < pv_mod.PixelValve.SIZE) self.pv1.read32(addr - pv_mod.PixelValve.PV1_BASE) else 0,
                .pwm => if (addr -% audio_mod.PwmAudio.BASE_ADDR < audio_mod.PwmAudio.SIZE) self.pwm.read32(addr - audio_mod.PwmAudio.BASE_ADDR) else 0,
                .thermal => if (addr -% pm_mod.Thermal.BASE_ADDR < pm_mod.Thermal.SIZE) self.thermal.read32(addr - pm_mod.Thermal.BASE_ADDR) else 0,
                .aux_uart => if (addr -% uart_mod.AuxMiniUart.BASE_ADDR < uart_mod.AuxMiniUart.SIZE) blk: {
                    const v = self.aux_uart.read32(addr - uart_mod.AuxMiniUart.BASE_ADDR);
                    if (self.bt_uart == .mini and addr == uart_mod.AuxMiniUart.BASE_ADDR + 0x40) {
                        self.pumpBt();
                        self.updateIrqsBank1();
                    }
                    break :blk v;
                } else 0,
                .sdhci => if (addr -% sdhost_mod.ArasanSdhci.BASE_ADDR < sdhost_mod.ArasanSdhci.SIZE) self.sdhci.read32WithSd(addr - sdhost_mod.ArasanSdhci.BASE_ADDR, &self.sdhost) else 0,
                .hvs => self.hvs.read32(addr - hvs_mod.Hvs.BASE_ADDR),
                .bsc1 => if (addr -% i2c_mod.BscController.BSC1_BASE < i2c_mod.BscController.SIZE) self.bsc1.read32(addr - i2c_mod.BscController.BSC1_BASE) else 0,
                .bsc2 => if (addr -% i2c_mod.BscController.BSC2_BASE < i2c_mod.BscController.SIZE) self.bsc2.read32(addr - i2c_mod.BscController.BSC2_BASE) else 0,
                .pv2 => if (addr -% pv_mod.PixelValve.PV2_BASE < pv_mod.PixelValve.SIZE) self.pv2.read32(addr - pv_mod.PixelValve.PV2_BASE) else 0,
                .hdmi_hd => if (addr -% hdmi_mod.Hdmi.HD_BASE < hdmi_mod.Hdmi.HD_SIZE) self.hdmi.readHd32(addr - hdmi_mod.Hdmi.HD_BASE) else 0,
                .hdmi_core => if (addr -% hdmi_mod.Hdmi.HDMI_BASE < hdmi_mod.Hdmi.HDMI_SIZE) self.hdmi.readHdmi32(addr - hdmi_mod.Hdmi.HDMI_BASE) else 0,
                .usb => blk: {
                    const v = self.usb.read32(addr - dwc2_mod.Dwc2Controller.BASE_ADDR);
                    self.updateIrqsBank1();
                    break :blk v;
                },
                .v3d => self.v3d.read32(addr - v3d_mod.V3d.BASE_ADDR),
            };
        }
        if (addr -% local_intc_mod.LocalIntc.BASE_ADDR < local_intc_mod.LocalIntc.SIZE) {
            self.updateIrqs();
            return self.local_intc.read32(
                addr - local_intc_mod.LocalIntc.BASE_ADDR,
                self.timer.counter,
                self.intc.hasPendingIrq(),
                self.intc.hasPendingFiq(),
            );
        }
        return 0;
    }

    pub fn writeMmio32(self: *Bcm2835, addr: u32, val: u32) void {
        const periph_off = addr -% PERIPH_BASE;
        if (periph_off < (PERIPH_END - PERIPH_BASE)) {
            switch (MMIO_PAGE_TABLE[periph_off >> 12]) {
                .none => self.reportUnmappedMmio(addr),
                .timer => if (addr -% TIMER_BASE < TIMER_SIZE) {
                    self.timer.write32(addr - TIMER_BASE, val, &self.intc);
                    self.updateIrqsBank1();
                },
                .txp => if (addr -% hdmi_mod.Txp.BASE_ADDR < hdmi_mod.Txp.SIZE) {
                    self.txp.write32(addr - hdmi_mod.Txp.BASE_ADDR, val);
                },
                .dma => {
                    self.dma.write32(addr - dma_mod.DmaController.BASE_ADDR, val, self.ram, self.dmaMmio());
                    if (!self.dma.stepping) {
                        self.updateIrqsBank1();
                        self.updateIrqsBank2();
                    }
                },
                .asb => if (addr -% pm_mod.AsbBridge.BASE_ADDR < pm_mod.AsbBridge.SIZE) {
                    self.asb.write32(addr - pm_mod.AsbBridge.BASE_ADDR, val);
                },
                .page_00b => {
                    if (addr -% INTC_BASE < INTC_SIZE) {
                        self.intc.write32(addr - INTC_BASE, val);
                    } else if (addr -% timer_mod.ArmTimer.BASE_ADDR < timer_mod.ArmTimer.SIZE) {
                        self.arm_timer.write32(addr - timer_mod.ArmTimer.BASE_ADDR, val, &self.intc);
                        self.updateIrqsBank0();
                    } else if (addr -% audio_mod.Vchiq.BASE_ADDR < audio_mod.Vchiq.SIZE) {
                        self.vchiq.write32(
                            addr - audio_mod.Vchiq.BASE_ADDR,
                            val,
                            self.ram,
                            &self.audio_fifo,
                            self.audio_connected,
                            self.hdmi.connected,
                        );
                        self.updateIrqsBank0();
                    } else if (addr -% mailbox_mod.Mailbox.BASE_ADDR < mailbox_mod.Mailbox.SIZE) {
                        self.mailbox.write32WithContext(addr - mailbox_mod.Mailbox.BASE_ADDR, val, self.ram, .{
                            .vchiq = &self.vchiq,
                            .hdmi_connected = self.hdmi.connected,
                            .hdmi_edid = &self.bsc2.edid,
                        });
                        self.updateIrqsBank0();
                    }
                },
                .pm => if (addr -% pm_mod.PowerManager.BASE_ADDR < pm_mod.PowerManager.SIZE) {
                    self.pm.write32(addr - pm_mod.PowerManager.BASE_ADDR, val);
                },
                .cprman => self.cprman.write32(addr - cprman_mod.Cprman.BASE_ADDR, val),
                .rng => if (addr -% pm_mod.Rng.BASE_ADDR < pm_mod.Rng.SIZE) {
                    self.rng.write32(addr - pm_mod.Rng.BASE_ADDR, val);
                },
                .mphi => {
                    self.mphi.write32(addr - mphi_mod.Mphi.BASE_ADDR, val);
                    self.updateIrqsBank2();
                },
                .gpio => if (addr -% gpio_mod.Gpio.BASE_ADDR < gpio_mod.Gpio.SIZE) {
                    self.gpio.write32(addr - gpio_mod.Gpio.BASE_ADDR, val);
                    self.syncSdRoutingFromGpio();
                    self.syncBtRoutingFromGpio();
                    self.updateIrqsBank2();
                },
                .uart0 => {
                    self.uart0.write32(addr - uart_mod.Pl011Uart.BASE_ADDR, val);
                    self.pumpBt();
                    self.updateIrqsBank2();
                },
                .sdhost => if (addr -% sdhost_mod.SdHost.BASE_ADDR < sdhost_mod.SdHost.SIZE) {
                    const offset = addr - sdhost_mod.SdHost.BASE_ADDR;
                    self.sdhost.write32(offset, val);
                    if (!self.dma.stepping) {
                        if (offset == 0x00 and self.sdhost.dreqReady()) {
                            self.dma.stepAllActive(self.ram, self.dmaMmio());
                            self.updateIrqsBank1();
                        }
                        self.updateIrqsBank2();
                    }
                },
                .i2s => if (addr -% audio_mod.I2sPcm.BASE_ADDR < audio_mod.I2sPcm.SIZE) {
                    self.i2s.write32(addr - audio_mod.I2sPcm.BASE_ADDR, val, &self.audio_fifo, self.audio_connected);
                    if (!self.dma.stepping) {
                        if (self.i2s.rxDreqReady()) {
                            self.dma.stepAllActive(self.ram, self.dmaMmio());
                            self.updateIrqsBank1();
                        }
                        self.updateIrqsBank2();
                    }
                },
                .spi0 => if (addr -% spi_mod.Spi0.BASE_ADDR < spi_mod.Spi0.SIZE) {
                    self.spi0.write32(addr - spi_mod.Spi0.BASE_ADDR, val);
                    if (!self.dma.stepping) {
                        if (self.spi0.txDreqReady() or self.spi0.rxDreqReady()) {
                            self.dma.stepAllActive(self.ram, self.dmaMmio());
                            self.updateIrqsBank1();
                        }
                        self.updateIrqsBank2();
                    }
                },
                .smi => if (addr -% smi_mod.Smi.BASE_ADDR < smi_mod.Smi.SIZE) {
                    self.smi.write32(addr - smi_mod.Smi.BASE_ADDR, val);
                    self.updateIrqsBank2();
                },
                .bsc0 => if (addr -% i2c_mod.BscController.BSC0_BASE < i2c_mod.BscController.SIZE) {
                    self.bsc0.write32(addr - i2c_mod.BscController.BSC0_BASE, val);
                    self.updateIrqsBank2();
                },
                .pv0 => if (addr -% pv_mod.PixelValve.PV0_BASE < pv_mod.PixelValve.SIZE) {
                    self.pv0.write32(addr - pv_mod.PixelValve.PV0_BASE, val);
                    self.updateIrqsBank2();
                },
                .pv1 => if (addr -% pv_mod.PixelValve.PV1_BASE < pv_mod.PixelValve.SIZE) {
                    self.pv1.write32(addr - pv_mod.PixelValve.PV1_BASE, val);
                    self.updateIrqsBank2();
                },
                .pwm => if (addr -% audio_mod.PwmAudio.BASE_ADDR < audio_mod.PwmAudio.SIZE) {
                    self.pwm.write32(addr - audio_mod.PwmAudio.BASE_ADDR, val, &self.audio_fifo, self.audio_connected);
                },
                .thermal => if (addr -% pm_mod.Thermal.BASE_ADDR < pm_mod.Thermal.SIZE) {
                    self.thermal.write32(addr - pm_mod.Thermal.BASE_ADDR, val);
                },
                .aux_uart => if (addr -% uart_mod.AuxMiniUart.BASE_ADDR < uart_mod.AuxMiniUart.SIZE) {
                    self.aux_uart.write32(addr - uart_mod.AuxMiniUart.BASE_ADDR, val);
                    self.pumpBt();
                    self.updateIrqsBank1();
                },
                .sdhci => if (addr -% sdhost_mod.ArasanSdhci.BASE_ADDR < sdhost_mod.ArasanSdhci.SIZE) {
                    const offset = addr - sdhost_mod.ArasanSdhci.BASE_ADDR;
                    self.sdhci.write32WithSd(offset, val, &self.sdhost);
                    if (!self.dma.stepping) {
                        if (offset == 0x0c and self.sdhci.dreqReady()) {
                            self.dma.stepAllActive(self.ram, self.dmaMmio());
                            self.updateIrqsBank1();
                        }
                        self.updateIrqsBank2();
                    }
                },
                .hvs => {
                    self.hvs.write32(addr - hvs_mod.Hvs.BASE_ADDR, val);
                    self.updateIrqsBank2();
                },
                .bsc1 => if (addr -% i2c_mod.BscController.BSC1_BASE < i2c_mod.BscController.SIZE) {
                    self.bsc1.write32(addr - i2c_mod.BscController.BSC1_BASE, val);
                    self.updateIrqsBank2();
                },
                .bsc2 => if (addr -% i2c_mod.BscController.BSC2_BASE < i2c_mod.BscController.SIZE) {
                    self.bsc2.write32(addr - i2c_mod.BscController.BSC2_BASE, val);
                    self.updateIrqsBank2();
                },
                .pv2 => if (addr -% pv_mod.PixelValve.PV2_BASE < pv_mod.PixelValve.SIZE) {
                    self.pv2.write32(addr - pv_mod.PixelValve.PV2_BASE, val);
                    self.updateIrqsBank2();
                },
                .hdmi_hd => if (addr -% hdmi_mod.Hdmi.HD_BASE < hdmi_mod.Hdmi.HD_SIZE) {
                    self.hdmi.writeHd32(addr - hdmi_mod.Hdmi.HD_BASE, val, &self.audio_fifo);
                },
                .hdmi_core => if (addr -% hdmi_mod.Hdmi.HDMI_BASE < hdmi_mod.Hdmi.HDMI_SIZE) {
                    self.hdmi.writeHdmi32(addr - hdmi_mod.Hdmi.HDMI_BASE, val);
                },
                .usb => {
                    self.usb.write32(addr - dwc2_mod.Dwc2Controller.BASE_ADDR, val, self.ram);
                    self.updateIrqsBank1();
                },
                .v3d => {
                    self.v3d.write32(addr - v3d_mod.V3d.BASE_ADDR, val, self.ram);
                    self.updateIrqsBank1();
                },
            }
            return;
        }
        if (addr -% local_intc_mod.LocalIntc.BASE_ADDR < local_intc_mod.LocalIntc.SIZE) {
            self.local_intc.write32(addr - local_intc_mod.LocalIntc.BASE_ADDR, val);
        }
    }
};

test "Bcm2835 DMA block write to SDHOST (CMD24) completes without recursion" {
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);

    var disk: [1024]u8 = @splat(0);
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

    var disk: [1024]u8 = @splat(0);
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

test "Bcm2835 renderDisplayFrameIfChanged dirty-frame detection and SIMD Mailbox FB scanout" {
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 16 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);

    const w: u16 = 16;
    const h: u16 = 8;
    var soc = Bcm2835.init(ram, w, h);
    var out: [16 * 8]u32 = @splat(0);

    // 1. Before FB allocation or HVS setup: inactive and unchanged
    const r0 = soc.renderDisplayFrameIfChanged(&out, w, h, true, true);
    try std.testing.expect(!r0.active);
    try std.testing.expect(!r0.changed);

    // 2. Allocate 16x8 32bpp Mailbox FB at 0x1000 and write a pixel
    soc.mailbox.fb_allocated = true;
    soc.mailbox.fb_bus_addr = 0x40001000;
    soc.mailbox.fb_width = w;
    soc.mailbox.fb_height = h;
    soc.mailbox.fb_depth = 32;
    std.mem.writeInt(u32, ram[0x1000..0x1004], 0x00112233, .little);

    const r1 = soc.renderDisplayFrameIfChanged(&out, w, h, true, true);
    try std.testing.expect(r1.active);
    try std.testing.expect(r1.changed);
    try std.testing.expectEqual(@as(u32, 0xFF112233), out[0]);

    // 3. Subsequent frame with no RAM changes: skipped (changed == false) even if CPU was active
    const r2 = soc.renderDisplayFrameIfChanged(&out, w, h, false, true);
    try std.testing.expect(r2.active);
    try std.testing.expect(!r2.changed);

    // 4. Modify pixel in-place in RAM: detected and re-rendered
    std.mem.writeInt(u32, ram[0x1000 + 15 * 4 ..][0..4], 0x00AABBCC, .little);
    const r3 = soc.renderDisplayFrameIfChanged(&out, w, h, false, true);
    try std.testing.expect(r3.active);
    try std.testing.expect(r3.changed);
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), out[15]);
}




