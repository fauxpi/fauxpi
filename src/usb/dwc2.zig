const std = @import("std");
const UsbHidComposite = @import("hid.zig").UsbHidComposite;

/// Synopsys DesignWare Hi-Speed USB 2.0 OTG Controller (`brcm,bcm2835-usb`) at `0x20980000`.
pub const Dwc2Controller = struct {
    pub const BASE_ADDR: u32 = 0x20980000;
    pub const SIZE: u32 = 0x10000;
    pub const NUM_CHANNELS: usize = 8;

    // GAHBCFG bits
    pub const GAHBCFG_GLBL_INTR_EN: u32 = 1 << 0;
    pub const GAHBCFG_DMA_EN: u32 = 1 << 5;

    // GINTSTS bits
    pub const GINTSTS_CURMODE_HOST: u32 = 1 << 0;
    pub const GINTSTS_MODEMIS: u32 = 1 << 1;
    pub const GINTSTS_OTGINT: u32 = 1 << 2;
    pub const GINTSTS_SOF: u32 = 1 << 3;
    pub const GINTSTS_RXFLVL: u32 = 1 << 4;
    pub const GINTSTS_NPTXFEMP: u32 = 1 << 5;
    pub const GINTSTS_PRTINT: u32 = 1 << 24;
    pub const GINTSTS_HCHINT: u32 = 1 << 25;
    pub const GINTSTS_PTXFEMP: u32 = 1 << 26;
    pub const GINTSTS_CONIDSTSCHNG: u32 = 1 << 28;
    pub const GINTSTS_DISCONNINT: u32 = 1 << 29;
    pub const GINTSTS_SESSREQINT: u32 = 1 << 30;
    pub const GINTSTS_WKUPINT: u32 = 1 << 31;

    // HPRT0 bits
    pub const HPRT0_PRTCONNSTS: u32 = 1 << 0;
    pub const HPRT0_PRTCONNDET: u32 = 1 << 1;
    pub const HPRT0_PRTENA: u32 = 1 << 2;
    pub const HPRT0_PRTENCHNG: u32 = 1 << 3;
    pub const HPRT0_PRTOVRCURRACT: u32 = 1 << 4;
    pub const HPRT0_PRTOVRCURRCHNG: u32 = 1 << 5;
    pub const HPRT0_PRTRES: u32 = 1 << 6;
    pub const HPRT0_PRTSUSP: u32 = 1 << 7;
    pub const HPRT0_PRTRST: u32 = 1 << 8;
    pub const HPRT0_PRTPWR: u32 = 1 << 12;
    pub const HPRT0_PRTSPD_FULL: u32 = 1 << 17; // Full speed (12 Mbps)

    // HCCHAR bits
    pub const HCCHAR_CHDIS: u32 = 1 << 30;
    pub const HCCHAR_CHEN: u32 = 1 << 31;

    // HCINT bits
    pub const HCINT_XFERCOMP: u32 = 1 << 0;
    pub const HCINT_CHHLTD: u32 = 1 << 1;
    pub const HCINT_AHBERR: u32 = 1 << 2;
    pub const HCINT_STALL: u32 = 1 << 3;
    pub const HCINT_NAK: u32 = 1 << 4;
    pub const HCINT_ACK: u32 = 1 << 5;
    pub const HCINT_NYET: u32 = 1 << 6;
    pub const HCINT_XACTERR: u32 = 1 << 7;
    pub const HCINT_BBLERR: u32 = 1 << 8;
    pub const HCINT_FRMOVRUN: u32 = 1 << 9;
    pub const HCINT_DATATGLERR: u32 = 1 << 10;

    pub const HostChannel = struct {
        hcchar: u32 = 0,
        hcsplt: u32 = 0,
        hcint: u32 = 0,
        hcintmsk: u32 = 0,
        hctsiz: u32 = 0,
        hcdma: u32 = 0,
        hcdmab: u32 = 0,
    };

    gotgctl: u32 = 0x00010000,
    gotgint: u32 = 0,
    gahbcfg: u32 = 0,
    gusbcfg: u32 = 0x20001400,
    grstctl: u32 = 0x80000000, // AHBIDLE = 1
    gintsts: u32 = GINTSTS_CURMODE_HOST | GINTSTS_NPTXFEMP | GINTSTS_PTXFEMP,
    gintmsk: u32 = 0,
    grxfsiz: u32 = 0x00001000,
    gnptxfsiz: u32 = 0x01001000,
    hptxfsiz: u32 = 0x02002000,

    hcfg: u32 = 0,
    hfir: u32 = 60000,
    hfnum: u16 = 0,
    haintmsk: u32 = 0,
    hprt0: u32 = HPRT0_PRTCONNSTS | HPRT0_PRTSPD_FULL,
    pcgcctl: u32 = 0,

    channels: [NUM_CHANNELS]HostChannel = [_]HostChannel{.{}} ** NUM_CHANNELS,
    hid: UsbHidComposite = .{},

    pub fn effectiveGintsts(self: *const Dwc2Controller) u32 {
        var sts = self.gintsts | GINTSTS_CURMODE_HOST | GINTSTS_NPTXFEMP | GINTSTS_PTXFEMP;
        if ((self.hprt0 & (HPRT0_PRTCONNDET | HPRT0_PRTENCHNG | HPRT0_PRTOVRCURRCHNG)) != 0) {
            sts |= GINTSTS_PRTINT;
        } else {
            sts &= ~GINTSTS_PRTINT;
        }
        if ((self.effectiveHaint() & self.haintmsk) != 0) {
            sts |= GINTSTS_HCHINT;
        } else {
            sts &= ~GINTSTS_HCHINT;
        }
        return sts;
    }

    pub fn effectiveHaint(self: *const Dwc2Controller) u32 {
        var mask: u32 = 0;
        for (self.channels, 0..) |ch, i| {
            if ((ch.hcint & ch.hcintmsk) != 0) {
                mask |= (@as(u32, 1) << @intCast(i));
            }
        }
        return mask;
    }

    pub fn irqPending(self: *const Dwc2Controller) bool {
        if ((self.gahbcfg & GAHBCFG_GLBL_INTR_EN) == 0) return false;
        return (self.effectiveGintsts() & self.gintmsk) != 0;
    }

    pub fn tickSof(self: *Dwc2Controller, ram: []u8) void {
        self.hfnum +%= 1;
        if ((self.gintmsk & GINTSTS_SOF) != 0) {
            self.gintsts |= GINTSTS_SOF;
        }
        self.pollNetwork(ram);
    }

    pub fn pollNetwork(self: *Dwc2Controller, ram: []u8) void {
        if (self.hid.isEthernetLinkUp()) {
            self.hid.net.poll();
            if (self.hid.hasEthBulkIn()) {
                self.servicePendingBulkIn(ram);
            }
        }
    }

    pub fn servicePendingBulkIn(self: *Dwc2Controller, ram: []u8) void {
        for (0..NUM_CHANNELS) |ch_idx| {
            const ch = &self.channels[ch_idx];
            if ((ch.hcchar & HCCHAR_CHEN) != 0) {
                const epnum: u4 = @truncate((ch.hcchar >> 11) & 0xf);
                const epdir_in = ((ch.hcchar >> 15) & 1) != 0;
                const eptype: u2 = @truncate((ch.hcchar >> 18) & 3);
                if (eptype == 2 and epdir_in and epnum == 4) {
                    if (!self.tryCompleteBulkIn(ch_idx, ram)) break;
                }
            }
        }
    }

    fn tryCompleteBulkIn(self: *Dwc2Controller, ch_idx: usize, ram: []u8) bool {
        const ch = &self.channels[ch_idx];
        const xfersize: u32 = ch.hctsiz & 0x7ffff;
        const pid: u2 = @truncate((ch.hctsiz >> 29) & 3);
        const dma_phys: u32 = ch.hcdma & 0x1FFFFFFF;

        if (dma_phys + xfersize > ram.len) {
            ch.hcchar &= ~HCCHAR_CHEN;
            ch.hcint |= HCINT_AHBERR | HCINT_CHHLTD;
            return false;
        }

        if (self.hid.popEthBulkIn(ram[dma_phys .. dma_phys + xfersize])) |copy_len| {
            ch.hcchar &= ~HCCHAR_CHEN;
            const rem: u32 = xfersize - @as(u32, @intCast(copy_len));
            const pkt_transferred: usize = if (copy_len == 0) 1 else (copy_len + 63) / 64;
            const next_pid: u32 = if ((pkt_transferred & 1) != 0)
                (if (pid == 0) @as(u32, 2) else 0)
            else
                pid;
            ch.hctsiz = (next_pid << 29) | rem;
            ch.hcdma +%= @intCast(copy_len);
            ch.hcdmab = ch.hcdma;
            ch.hcint |= HCINT_XFERCOMP | HCINT_CHHLTD | HCINT_ACK;
            return true;
        }
        return false;
    }

    pub fn read32(self: *Dwc2Controller, offset: u32) u32 {
        if (offset >= 0x500 and offset < 0x500 + NUM_CHANNELS * 0x20) {
            const ch_idx = (offset - 0x500) / 0x20;
            const reg = (offset - 0x500) % 0x20;
            const ch = &self.channels[ch_idx];
            return switch (reg) {
                0x00 => ch.hcchar,
                0x04 => ch.hcsplt,
                0x08 => ch.hcint,
                0x0c => ch.hcintmsk,
                0x10 => ch.hctsiz,
                0x14 => ch.hcdma,
                0x1c => ch.hcdmab,
                else => 0,
            };
        }

        return switch (offset) {
            0x000 => self.gotgctl,
            0x004 => self.gotgint,
            0x008 => self.gahbcfg,
            0x00c => self.gusbcfg,
            0x010 => 0x80000000, // GRSTCTL: AHBIDLE=1, CSFTRST=0
            0x014 => self.effectiveGintsts(),
            0x018 => self.gintmsk,
            0x024 => self.grxfsiz,
            0x028 => self.gnptxfsiz,
            0x02c => (8 << 16) | 0x0400, // GNPTXSTS
            0x040 => 0x4f54280a, // GSNPSID (DWC2 2.80a)
            0x044 => 0x00000000, // GHWCFG1
            0x048 => 0x228ddd50, // GHWCFG2 (Internal DMA, 8 host channels, dynamic FIFO)
            0x04c => 0x100000e8, // GHWCFG3 (4096-word DFIFO)
            0x050 => 0x1e000020, // GHWCFG4
            0x054 => 0x00000000, // GLPMCFG
            0x100 => self.hptxfsiz,
            0x400 => self.hcfg,
            0x404 => self.hfir,
            0x408 => blk: { // HFNUM
                self.hfnum +%= 1;
                break :blk (@as(u32, 0x3fff) << 16) | self.hfnum;
            },
            0x410 => (8 << 16) | 0x0400, // HPTXSTS
            0x414 => self.effectiveHaint(), // HAINT
            0x418 => self.haintmsk, // HAINTMSK
            0x440 => self.hprt0, // HPRT0
            0xe00 => self.pcgcctl,
            else => 0,
        };
    }

    pub fn write32(self: *Dwc2Controller, offset: u32, val: u32, ram: []u8) void {
        if (offset >= 0x500 and offset < 0x500 + NUM_CHANNELS * 0x20) {
            const ch_idx = (offset - 0x500) / 0x20;
            const reg = (offset - 0x500) % 0x20;
            var ch = &self.channels[ch_idx];
            switch (reg) {
                0x00 => { // HCCHAR
                    ch.hcchar = val;
                    if ((val & HCCHAR_CHEN) != 0) {
                        self.executeChannel(ch_idx, ram);
                    } else if ((val & HCCHAR_CHDIS) != 0) {
                        ch.hcchar &= ~(HCCHAR_CHEN | HCCHAR_CHDIS);
                        ch.hcint |= HCINT_CHHLTD;
                    }
                },
                0x04 => ch.hcsplt = val,
                0x08 => ch.hcint &= ~val, // W1C
                0x0c => ch.hcintmsk = val,
                0x10 => ch.hctsiz = val,
                0x14 => {
                    ch.hcdma = val;
                    ch.hcdmab = val;
                },
                else => {},
            }
            return;
        }

        switch (offset) {
            0x000 => self.gotgctl = val,
            0x004 => self.gotgint &= ~val,
            0x008 => self.gahbcfg = val,
            0x00c => self.gusbcfg = val,
            0x010 => { // GRSTCTL
                if ((val & 1) != 0) { // CSFTRST
                    for (&self.channels) |*c| c.* = .{};
                }
            },
            0x014 => { // GINTSTS W1C
                self.gintsts &= ~val;
            },
            0x018 => self.gintmsk = val,
            0x024 => self.grxfsiz = val,
            0x028 => self.gnptxfsiz = val,
            0x100 => self.hptxfsiz = val,
            0x400 => self.hcfg = val,
            0x404 => self.hfir = val,
            0x418 => self.haintmsk = val,
            0x440 => { // HPRT0
                const prev = self.hprt0;
                // Bits 1 (PRTCONNDET), 2 (PRTENA), 3 (PRTENCHNG), 5 (PRTOVRCURRCHNG) are W1C
                const w1c_mask: u32 = HPRT0_PRTCONNDET | HPRT0_PRTENA | HPRT0_PRTENCHNG | HPRT0_PRTOVRCURRCHNG;
                var next = prev & ~(val & w1c_mask);

                // Update writable bits (PRTRES, PRTSUSP, PRTRST, PRTPWR)
                const rw_mask: u32 = HPRT0_PRTRES | HPRT0_PRTSUSP | HPRT0_PRTRST | HPRT0_PRTPWR;
                next = (next & ~rw_mask) | (val & rw_mask);

                // Always keep device connected at Full Speed
                next |= HPRT0_PRTCONNSTS | HPRT0_PRTSPD_FULL;

                // Rising edge of PRTPWR -> trigger PRTCONNDET
                if ((prev & HPRT0_PRTPWR) == 0 and (val & HPRT0_PRTPWR) != 0) {
                    next |= HPRT0_PRTCONNDET;
                }

                // Falling edge of PRTRST (1 -> 0) -> port reset complete, enable port!
                if ((prev & HPRT0_PRTRST) != 0 and (val & HPRT0_PRTRST) == 0) {
                    self.hid.reset();
                    next |= HPRT0_PRTENA | HPRT0_PRTENCHNG;
                }

                self.hprt0 = next;
            },
            0xe00 => self.pcgcctl = val,
            else => {},
        }
    }

    fn executeChannel(self: *Dwc2Controller, ch_idx: usize, ram: []u8) void {
        var ch = &self.channels[ch_idx];

        if ((ch.hcchar & HCCHAR_CHDIS) != 0) {
            ch.hcchar &= ~(HCCHAR_CHEN | HCCHAR_CHDIS);
            ch.hcint |= HCINT_CHHLTD;
            return;
        }

        const epnum: u4 = @truncate((ch.hcchar >> 11) & 0xf);
        const epdir_in = ((ch.hcchar >> 15) & 1) != 0;
        const eptype: u2 = @truncate((ch.hcchar >> 18) & 3);
        const devaddr: u7 = @truncate((ch.hcchar >> 22) & 0x7f);

        const xfersize: u32 = ch.hctsiz & 0x7ffff;
        const pid: u2 = @truncate((ch.hctsiz >> 29) & 3);
        const dma_phys: u32 = ch.hcdma & 0x1FFFFFFF;

        // Check device address (respond to address 0 before SET_ADDRESS or matching address)
        if (devaddr != self.hid.address and devaddr != 0) {
            ch.hcchar &= ~HCCHAR_CHEN;
            ch.hcint |= HCINT_XACTERR | HCINT_CHHLTD;
            return;
        }

        // Control endpoint 0
        if (epnum == 0 or eptype == 0) {
            ch.hcchar &= ~HCCHAR_CHEN;
            if (pid == 3 and !epdir_in) {
                // SETUP stage (8 bytes)
                if (dma_phys + 8 <= ram.len) {
                    var setup: [8]u8 = undefined;
                    @memcpy(&setup, ram[dma_phys .. dma_phys + 8]);
                    const ok = self.hid.handleSetup(setup);
                    if (ok) {
                        ch.hctsiz = (@as(u32, pid) << 29); // xfersize=0, pktcnt=0
                        ch.hcdma +%= xfersize;
                        ch.hcdmab = ch.hcdma;
                        ch.hcint |= HCINT_XFERCOMP | HCINT_CHHLTD | HCINT_ACK;
                    } else {
                        ch.hcint |= HCINT_STALL | HCINT_CHHLTD;
                    }
                } else {
                    ch.hcint |= HCINT_AHBERR | HCINT_CHHLTD;
                }
            } else if (epdir_in) {
                // Control IN (data stage or 0-length status stage)
                if (xfersize == 0) {
                    ch.hctsiz = (@as(u32, pid) << 29);
                    ch.hcint |= HCINT_XFERCOMP | HCINT_CHHLTD | HCINT_ACK;
                } else if (dma_phys + xfersize <= ram.len) {
                    const n = self.hid.readControlData(ram[dma_phys .. dma_phys + xfersize]);
                    const rem: u32 = xfersize - @as(u32, @intCast(n));
                    const pkt_transferred: usize = if (n == 0) 1 else (n + 63) / 64;
                    const next_pid: u32 = if ((pkt_transferred & 1) != 0)
                        (if (pid == 0) @as(u32, 2) else 0)
                    else
                        pid;
                    ch.hctsiz = (next_pid << 29) | rem;
                    ch.hcdma +%= @intCast(n);
                    ch.hcdmab = ch.hcdma;
                    ch.hcint |= HCINT_XFERCOMP | HCINT_CHHLTD | HCINT_ACK;
                } else {
                    ch.hcint |= HCINT_AHBERR | HCINT_CHHLTD;
                }
            } else {
                // Control OUT (data stage or 0-length status stage)
                ch.hctsiz = (@as(u32, pid) << 29);
                ch.hcdma +%= xfersize;
                ch.hcdmab = ch.hcdma;
                ch.hcint |= HCINT_XFERCOMP | HCINT_CHHLTD | HCINT_ACK;
            }
            return;
        }

        // Bulk endpoints (EP4 IN / OUT for CDC-ECM Ethernet)
        if (eptype == 2 and epnum == 4) {
            if (epdir_in) {
                // In DWC2 DMA mode, Bulk IN channels stay enabled (HCCHAR_CHEN) until an RX frame arrives
                // or the host driver aborts the channel with HCCHAR_CHDIS.
                if (!self.tryCompleteBulkIn(ch_idx, ram)) {
                    self.pollNetwork(ram);
                }
                return;
            } else {
                // Bulk OUT: transmit Ethernet frame from guest to VirtualNetwork
                ch.hcchar &= ~HCCHAR_CHEN;
                if (dma_phys + xfersize <= ram.len) {
                    if (xfersize >= 14) {
                        self.hid.handleEthBulkOut(ram[dma_phys .. dma_phys + xfersize]);
                    }
                    const pkt_transferred: u32 = if (xfersize == 0) 1 else (xfersize + 63) / 64;
                    const next_pid: u32 = if ((pkt_transferred & 1) != 0)
                        (if (pid == 0) @as(u32, 2) else 0)
                    else
                        pid;
                    ch.hctsiz = (next_pid << 29);
                    ch.hcdma +%= xfersize;
                    ch.hcdmab = ch.hcdma;
                    ch.hcint |= HCINT_XFERCOMP | HCINT_CHHLTD | HCINT_ACK;
                    // Service any waiting Bulk IN channel immediately if an RX reply was generated
                    if (self.hid.hasEthBulkIn()) {
                        self.servicePendingBulkIn(ram);
                    }
                } else {
                    ch.hcint |= HCINT_AHBERR | HCINT_CHHLTD;
                }
                return;
            }
        }

        // Interrupt IN endpoints: EP1 (Keyboard), EP2 (Mouse), EP3 (CDC-ECM Status)
        if (eptype == 3 and epdir_in) {
            ch.hcchar &= ~HCCHAR_CHEN;
            if (epnum == 1) {
                if (self.hid.popKbdReport()) |report| {
                    const copy_len = @min(@as(usize, xfersize), 8);
                    if (dma_phys + copy_len <= ram.len) {
                        @memcpy(ram[dma_phys .. dma_phys + copy_len], report[0..copy_len]);
                    }
                    const rem: u32 = xfersize - @as(u32, @intCast(copy_len));
                    const next_pid: u32 = if (pid == 0) 2 else 0;
                    ch.hctsiz = (next_pid << 29) | rem;
                    ch.hcdma +%= @intCast(copy_len);
                    ch.hcdmab = ch.hcdma;
                    ch.hcint |= HCINT_XFERCOMP | HCINT_CHHLTD | HCINT_ACK;
                } else {
                    ch.hcint |= HCINT_NAK | HCINT_CHHLTD;
                }
                return;
            } else if (epnum == 2) {
                if (self.hid.popMouseReport()) |report| {
                    const copy_len = @min(@as(usize, xfersize), 4);
                    if (dma_phys + copy_len <= ram.len) {
                        @memcpy(ram[dma_phys .. dma_phys + copy_len], report[0..copy_len]);
                    }
                    const rem: u32 = xfersize - @as(u32, @intCast(copy_len));
                    const next_pid: u32 = if (pid == 0) 2 else 0;
                    ch.hctsiz = (next_pid << 29) | rem;
                    ch.hcdma +%= @intCast(copy_len);
                    ch.hcdmab = ch.hcdma;
                    ch.hcint |= HCINT_XFERCOMP | HCINT_CHHLTD | HCINT_ACK;
                } else {
                    ch.hcint |= HCINT_NAK | HCINT_CHHLTD;
                }
                return;
            } else if (epnum == 3) {
                if (dma_phys + xfersize <= ram.len) {
                    if (self.hid.popCdcNotification(ram[dma_phys .. dma_phys + xfersize])) |copy_len| {
                        const rem: u32 = xfersize - @as(u32, @intCast(copy_len));
                        const next_pid: u32 = if (pid == 0) 2 else 0;
                        ch.hctsiz = (next_pid << 29) | rem;
                        ch.hcdma +%= @intCast(copy_len);
                        ch.hcdmab = ch.hcdma;
                        ch.hcint |= HCINT_XFERCOMP | HCINT_CHHLTD | HCINT_ACK;
                        return;
                    }
                }
                ch.hcint |= HCINT_NAK | HCINT_CHHLTD;
                return;
            }
        }

        ch.hcchar &= ~HCCHAR_CHEN;
        ch.hcint |= HCINT_STALL | HCINT_CHHLTD;
    }
};

test "DWC2 enumeration, USB HID keyboard report, and CDC-ECM Ethernet" {
    var dwc2 = Dwc2Controller{};
    defer dwc2.hid.net.deinit();
    var ram: [4096]u8 = [_]u8{0} ** 4096;

    // Verify Synopsis ID
    try std.testing.expectEqual(@as(u32, 0x4f54280a), dwc2.read32(0x040));

    // Power on port -> PRTCONNDET asserted
    dwc2.write32(0x440, Dwc2Controller.HPRT0_PRTPWR, &ram);
    try std.testing.expect((dwc2.read32(0x440) & Dwc2Controller.HPRT0_PRTCONNDET) != 0);

    // Reset port (PRTRST = 1 then 0) -> PRTENA asserted
    dwc2.write32(0x440, Dwc2Controller.HPRT0_PRTPWR | Dwc2Controller.HPRT0_PRTRST, &ram);
    dwc2.write32(0x440, Dwc2Controller.HPRT0_PRTPWR, &ram);
    try std.testing.expect((dwc2.read32(0x440) & Dwc2Controller.HPRT0_PRTENA) != 0);

    // Issue GET_DESCRIPTOR(Device) SETUP on Channel 0
    const setup = [8]u8{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 18, 0x00 };
    @memcpy(ram[0x100..0x108], &setup);

    dwc2.write32(0x510, (3 << 29) | (1 << 19) | 8, &ram); // HCTSIZ0: PID=SETUP, pktcnt=1, xfersize=8
    dwc2.write32(0x514, 0xc0000100, &ram); // HCDMA0
    dwc2.write32(0x500, Dwc2Controller.HCCHAR_CHEN | 64, &ram); // HCCHAR0: CHEN, EP0 OUT
    try std.testing.expect((dwc2.read32(0x508) & Dwc2Controller.HCINT_XFERCOMP) != 0);

    // Control IN data stage (18 bytes) into 0x200
    dwc2.write32(0x508, 0x7ff, &ram); // clear HCINT0
    dwc2.write32(0x510, (2 << 29) | (1 << 19) | 18, &ram); // PID=DATA1, xfersize=18
    dwc2.write32(0x514, 0xc0000200, &ram);
    dwc2.write32(0x500, Dwc2Controller.HCCHAR_CHEN | (1 << 15) | 64, &ram); // EP0 IN
    try std.testing.expectEqualSlices(u8, &UsbHidComposite.DEVICE_DESC, ram[0x200 .. 0x200 + 18]);

    // Inject 'A' key press (evdev keycode 30 -> HID usage 0x04) and poll EP1 IN on Channel 1
    dwc2.hid.handleEvdevKey(30, true);
    dwc2.write32(0x530, (0 << 29) | (1 << 19) | 8, &ram); // HCTSIZ1: xfersize=8
    dwc2.write32(0x534, 0xc0000300, &ram); // HCDMA1
    dwc2.write32(0x520, Dwc2Controller.HCCHAR_CHEN | (3 << 18) | (1 << 15) | (1 << 11) | 8, &ram); // EP1 IN Interrupt
    try std.testing.expect((dwc2.read32(0x528) & Dwc2Controller.HCINT_XFERCOMP) != 0);
    try std.testing.expectEqual(@as(u8, 0x04), ram[0x302]);

    // Poll CDC-ECM EP3 IN Interrupt on Channel 2 -> expect SPEED_CHANGE (16 bytes) then NETWORK_CONNECTION (8 bytes)
    dwc2.write32(0x550, (0 << 29) | (1 << 19) | 16, &ram);
    dwc2.write32(0x554, 0xc0000400, &ram);
    dwc2.write32(0x540, Dwc2Controller.HCCHAR_CHEN | (3 << 18) | (1 << 15) | (3 << 11) | 16, &ram);
    try std.testing.expect((dwc2.read32(0x548) & Dwc2Controller.HCINT_XFERCOMP) != 0);
    try std.testing.expectEqual(@as(u8, 0x2a), ram[0x401]); // USB_CDC_NOTIFY_SPEED_CHANGE

    dwc2.write32(0x548, 0x7ff, &ram);
    dwc2.write32(0x550, (2 << 29) | (1 << 19) | 16, &ram);
    dwc2.write32(0x554, 0xc0000420, &ram);
    dwc2.write32(0x540, Dwc2Controller.HCCHAR_CHEN | (3 << 18) | (1 << 15) | (3 << 11) | 16, &ram);
    try std.testing.expect((dwc2.read32(0x548) & Dwc2Controller.HCINT_XFERCOMP) != 0);
    try std.testing.expectEqual(@as(u8, 0x00), ram[0x421]); // USB_CDC_NOTIFY_NETWORK_CONNECTION
    try std.testing.expectEqual(@as(u8, 0x01), ram[0x422]); // Connected = 1

    // Arm Bulk IN (EP4 IN) on Channel 3 before any RX frame exists -> stays enabled (HCCHAR_CHEN set)
    dwc2.write32(0x570, (0 << 29) | (24 << 19) | 1536, &ram);
    dwc2.write32(0x574, 0xc0000800, &ram);
    dwc2.write32(0x560, Dwc2Controller.HCCHAR_CHEN | (2 << 18) | (1 << 15) | (4 << 11) | 64, &ram);
    try std.testing.expect((dwc2.read32(0x560) & Dwc2Controller.HCCHAR_CHEN) != 0);
    try std.testing.expectEqual(@as(u32, 0), dwc2.read32(0x568));

    // Transmit ARP Request on Bulk OUT (EP4 OUT) on Channel 4 -> automatically completes waiting Channel 3 Bulk IN!
    var arp_req = ram[0x500 .. 0x500 + 42];
    @memset(arp_req[0..6], 0xff);
    @memcpy(arp_req[6..12], &[_]u8{ 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56 });
    std.mem.writeInt(u16, arp_req[12..14], 0x0806, .big);
    std.mem.writeInt(u16, arp_req[14..16], 1, .big);
    std.mem.writeInt(u16, arp_req[16..18], 0x0800, .big);
    arp_req[18] = 6;
    arp_req[19] = 4;
    std.mem.writeInt(u16, arp_req[20..22], 1, .big);
    @memcpy(arp_req[22..28], &[_]u8{ 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56 });
    @memcpy(arp_req[28..32], &[_]u8{ 10, 0, 2, 15 });
    @memcpy(arp_req[38..42], &[_]u8{ 10, 0, 2, 2 });

    dwc2.write32(0x590, (0 << 29) | (1 << 19) | 42, &ram);
    dwc2.write32(0x594, 0xc0000500, &ram);
    dwc2.write32(0x580, Dwc2Controller.HCCHAR_CHEN | (2 << 18) | (0 << 15) | (4 << 11) | 64, &ram);
    try std.testing.expect((dwc2.read32(0x588) & Dwc2Controller.HCINT_XFERCOMP) != 0);

    // Verify Channel 3 Bulk IN completed with the 42-byte ARP Reply
    try std.testing.expect((dwc2.read32(0x568) & Dwc2Controller.HCINT_XFERCOMP) != 0);
    try std.testing.expectEqual(@as(u32, 1536 - 42), dwc2.read32(0x570) & 0x7ffff);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, ram[0x800 + 20 ..][0..2], .big));
}

