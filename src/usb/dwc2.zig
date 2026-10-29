const std = @import("std");
const vc_bus = @import("../soc/vc_bus.zig");
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
    pub const HPRT0_PRTSPD_HIGH: u32 = 0 << 17; // High speed (480 Mbps)
    pub const HPRT0_PRTSPD_FULL: u32 = 1 << 17; // Full speed (12 Mbps)
    pub const HPRT0_PRTSPD_MASK: u32 = 3 << 17;

    // HCCHAR bits
    pub const HCCHAR_CHDIS: u32 = 1 << 30;
    pub const HCCHAR_CHEN: u32 = 1 << 31;

    // HCSPLT bits
    pub const HCSPLT_COMPSPLT: u32 = 1 << 16;
    pub const HCSPLT_SPLTENA: u32 = 1 << 31;

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
    sof_base: u16 = 0,
    pending_csplit_sof: bool = false,
    sof_wakeup_frames: u8 = 16,
    wake_attempts: u8 = 0,
    last_mmio_offset: u32 = 0,
    haintmsk: u32 = 0,
    hprt0: u32 = HPRT0_PRTCONNSTS | HPRT0_PRTSPD_HIGH,
    pcgcctl: u32 = 0,

    channels: [NUM_CHANNELS]HostChannel = @splat(.{}),
    hid: UsbHidComposite = .{},

    pub fn syncRootPortConnection(self: *Dwc2Controller) void {
        if (self.hid.isHubPresent()) {
            if ((self.hprt0 & HPRT0_PRTCONNSTS) == 0) {
                self.hprt0 = (self.hprt0 & ~HPRT0_PRTSPD_MASK) | HPRT0_PRTCONNSTS | HPRT0_PRTSPD_HIGH;
                if ((self.hprt0 & HPRT0_PRTPWR) != 0) {
                    self.hprt0 |= HPRT0_PRTCONNDET;
                }
            }
        } else {
            if ((self.hprt0 & HPRT0_PRTCONNSTS) != 0) {
                self.hprt0 &= ~(HPRT0_PRTCONNSTS | HPRT0_PRTENA);
                self.hprt0 |= HPRT0_PRTCONNDET | HPRT0_PRTENCHNG;
                self.hid.reset();
            }
        }
    }

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

    pub fn wakeIfPending(self: *Dwc2Controller) void {
        self.syncRootPortConnection();
        if (self.hid.hasPendingInterruptIn() or self.hid.hasEthBulkIn() or !self.hid.allConnectedDevicesConfigured() or self.pending_csplit_sof) {
            self.sof_wakeup_frames = 8;
            if ((self.gintmsk & GINTSTS_SOF) != 0 and (self.gintsts & GINTSTS_SOF) == 0 and self.wake_attempts < 8) {
                self.wake_attempts += 1;
                const step: u16 = if (self.pending_csplit_sof) 2 else 64;
                self.pending_csplit_sof = false;
                self.hfnum = (self.hfnum + step) & 0x3fff;
                self.gintsts |= GINTSTS_SOF;
            }
        }
    }

    pub fn tickSof(self: *Dwc2Controller, ram: []u8) void {
        self.syncRootPortConnection();
        // 1 vblank at 60 Hz (~16.67 ms) corresponds to ~128 USB High-Speed microframes (16.0 ms)
        self.sof_base = (self.sof_base + 128) & 0x3fff;
        self.hfnum = self.sof_base;
        self.wake_attempts = 0;
        self.pollNetwork(ram);

        const has_pending = self.hid.hasPendingInterruptIn() or self.hid.hasEthBulkIn() or !self.hid.allConnectedDevicesConfigured();
        if (has_pending) {
            self.sof_wakeup_frames = 8;
        }
        self.pending_csplit_sof = false;
        if (!has_pending and self.sof_wakeup_frames > 0) {
            self.sof_wakeup_frames -= 1;
        }
        if ((self.gintmsk & GINTSTS_SOF) != 0) {
            self.gintsts |= GINTSTS_SOF;
        }
    }

    pub fn pollNetwork(self: *Dwc2Controller, ram: []u8) void {
        self.syncRootPortConnection();
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
                const devaddr: u7 = @truncate((ch.hcchar >> 22) & 0x7f);
                if (eptype == 2 and epdir_in and self.hid.isEthBulkEndpoint(epnum)) {
                    if (self.hid.resolveDevice(devaddr) == .eth) {
                        if (!self.tryCompleteBulkIn(ch_idx, ram)) break;
                    }
                }
            }
        }
    }

    fn tryCompleteBulkIn(self: *Dwc2Controller, ch_idx: usize, ram: []u8) bool {
        const ch = &self.channels[ch_idx];
        const xfersize: u32 = ch.hctsiz & 0x7ffff;
        const pid: u2 = @truncate((ch.hctsiz >> 29) & 3);
        const dma_phys: u32 = ch.hcdma & vc_bus.ramMask(ram.len);
        const mps: usize = @max(@as(usize, ch.hcchar & 0x7ff), 1);

        if (dma_phys + xfersize > ram.len) {
            ch.hcchar &= ~HCCHAR_CHEN;
            ch.hcint |= HCINT_AHBERR | HCINT_CHHLTD;
            return false;
        }

        if (self.hid.popEthBulkIn(ram[dma_phys .. dma_phys + xfersize])) |copy_len| {
            ch.hcchar &= ~HCCHAR_CHEN;
            const rem: u32 = xfersize - @as(u32, @intCast(copy_len));
            const pkt_transferred: usize = if (copy_len == 0) 1 else (copy_len + mps - 1) / mps;
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
        self.syncRootPortConnection();
        const prev_offset = self.last_mmio_offset;
        self.last_mmio_offset = offset;
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

        if (offset >= 0x104 and offset < 0x140) {
            return (256 << 16) | 0x400; // DPTXFSIZN(1..15)
        }

        return switch (offset) {
            0x000 => self.gotgctl,
            0x004 => self.gotgint,
            0x008 => self.gahbcfg,
            0x00c => self.gusbcfg,
            0x010 => 0x80000000, // GRSTCTL: AHBIDLE=1, CSFTRST=0
            0x014 => self.effectiveGintsts(),
            0x018 => {
                // In Linux's dwc2 driver (`dwc2_hcd_urb_enqueue`), non-periodic Control and Bulk URBs
                // (such as Ethernet Bulk OUT TX and Bulk IN RX replenishment) are placed into
                // `non_periodic_sched_inactive` followed only by `dwc2_readl(hsotg, GINTMSK)`. When
                // `GINTSTS_SOF` is enabled in `GINTMSK`, `dwc2_hcd_urb_enqueue` does not start the
                // transfer directly and instead waits for the next `GINTSTS_SOF` interrupt (`dwc2_sof_intr`).
                const is_core_intr_or_perio = (prev_offset == 0x014) or
                    (prev_offset == 0x410) or
                    (prev_offset >= 0x500 and prev_offset < 0x500 + NUM_CHANNELS * 0x20);
                if (!is_core_intr_or_perio and (self.gintmsk & GINTSTS_SOF) != 0) {
                    self.sof_wakeup_frames = 8;
                    if ((self.gintsts & GINTSTS_SOF) == 0 and self.wake_attempts < 32) {
                        self.wake_attempts += 1;
                        self.hfnum = (self.hfnum + 1) & 0x3fff;
                        self.gintsts |= GINTSTS_SOF;
                    }
                }
                return self.gintmsk;
            },
            0x024 => self.grxfsiz,
            0x028 => self.gnptxfsiz,
            0x02c => (8 << 16) | ((self.gnptxfsiz >> 16) & 0xffff), // GNPTXSTS
            0x040 => 0x4f54280a, // GSNPSID (DWC2 2.80a)
            0x044 => 0x00000000, // GHWCFG1
            0x048 => 0x228ddd50, // GHWCFG2 (Internal DMA, 8 host channels, dynamic FIFO)
            0x04c => 0x100000e8, // GHWCFG3 (4096-word DFIFO)
            0x050 => 0x1e000020, // GHWCFG4
            0x054 => 0x00000000, // GLPMCFG
            0x100 => self.hptxfsiz,
            0x400 => self.hcfg,
            0x404 => self.hfir,
            0x408 => ((self.hfir & 0xffff) << 16) | self.hfnum, // HFNUM (FRREM = full frame interval remaining)
            0x410 => (8 << 16) | ((self.hptxfsiz >> 16) & 0xffff), // HPTXSTS (FSPCAVAIL = full periodic FIFO size)
            0x414 => self.effectiveHaint(), // HAINT
            0x418 => self.haintmsk, // HAINTMSK
            0x440 => self.hprt0, // HPRT0
            0xe00 => self.pcgcctl,
            else => 0,
        };
    }

    pub fn write32(self: *Dwc2Controller, offset: u32, val: u32, ram: []u8) void {
        self.syncRootPortConnection();
        self.last_mmio_offset = offset;
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
            0x018 => {
                if ((self.gintmsk & GINTSTS_SOF) == 0 and (val & GINTSTS_SOF) != 0) {
                    self.sof_wakeup_frames = 8;
                    self.wake_attempts = 0;
                }
                self.gintmsk = val;
            },
            0x024 => self.grxfsiz = val,
            0x028 => self.gnptxfsiz = val,
            0x100 => self.hptxfsiz = val,
            0x400 => self.hcfg = val,
            0x404 => self.hfir = val,
            0x418 => {
                self.haintmsk = val;
                // When a periodic Start-Split (SSPLIT) finishes and its channel interrupt is masked,
                // advance 2 microframes and assert SOF so the Complete-Split (CSPLIT) runs immediately.
                if (self.pending_csplit_sof and (self.effectiveHaint() & val) == 0) {
                    self.pending_csplit_sof = false;
                    self.hfnum = (self.hfnum + 2) & 0x3fff;
                    if ((self.gintmsk & GINTSTS_SOF) != 0) {
                        self.gintsts |= GINTSTS_SOF;
                    }
                }
            },
            0x440 => { // HPRT0
                const prev = self.hprt0;
                // Bits 1 (PRTCONNDET), 2 (PRTENA), 3 (PRTENCHNG), 5 (PRTOVRCURRCHNG) are W1C
                const w1c_mask: u32 = HPRT0_PRTCONNDET | HPRT0_PRTENA | HPRT0_PRTENCHNG | HPRT0_PRTOVRCURRCHNG;
                var next = prev & ~(val & w1c_mask);

                // Update writable bits (PRTRES, PRTSUSP, PRTRST, PRTPWR)
                const rw_mask: u32 = HPRT0_PRTRES | HPRT0_PRTSUSP | HPRT0_PRTRST | HPRT0_PRTPWR;
                next = (next & ~rw_mask) | (val & rw_mask);

                if (self.hid.isHubPresent()) {
                    next = (next & ~HPRT0_PRTSPD_MASK) | HPRT0_PRTCONNSTS | HPRT0_PRTSPD_HIGH;

                    // Rising edge of PRTPWR -> trigger PRTCONNDET
                    if ((prev & HPRT0_PRTPWR) == 0 and (val & HPRT0_PRTPWR) != 0) {
                        next |= HPRT0_PRTCONNDET;
                    }

                    // Falling edge of PRTRST (1 -> 0) -> port reset complete, enable port!
                    if ((prev & HPRT0_PRTRST) != 0 and (val & HPRT0_PRTRST) == 0) {
                        self.hid.reset();
                        next |= HPRT0_PRTENA | HPRT0_PRTENCHNG;
                    }
                } else {
                    next &= ~(HPRT0_PRTCONNSTS | HPRT0_PRTENA);
                }

                self.hprt0 = next;
            },
            0xe00 => self.pcgcctl = val,
            else => {},
        }
    }

    fn executeChannel(self: *Dwc2Controller, ch_idx: usize, ram: []u8) void {
        self.wake_attempts = 0;
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
        const mps: usize = @max(@as(usize, ch.hcchar & 0x7ff), 1);

        const xfersize: u32 = ch.hctsiz & 0x7ffff;
        const pid: u2 = @truncate((ch.hctsiz >> 29) & 3);
        const dma_phys: u32 = ch.hcdma & vc_bus.ramMask(ram.len);

        const target = self.hid.resolveDevice(devaddr) orelse {
            ch.hcchar &= ~HCCHAR_CHEN;
            ch.hcint |= HCINT_XACTERR | HCINT_CHHLTD;
            return;
        };

        // Handle High-Speed Hub Split Transactions (SSPLIT / CSPLIT) for Full/Low-Speed downstream devices
        if ((ch.hcsplt & HCSPLT_SPLTENA) != 0) {
            if ((ch.hcsplt & HCSPLT_COMPSPLT) == 0) {
                // Start-Split (SSPLIT): consume SETUP/OUT payload now and halt with HCINT_ACK | HCINT_CHHLTD
                ch.hcchar &= ~HCCHAR_CHEN;
                self.pending_csplit_sof = true;
                if (epnum == 0) {
                    if (pid == 3 and !epdir_in) {
                        if (dma_phys + 8 <= ram.len) {
                            var setup: [8]u8 = undefined;
                            @memcpy(&setup, ram[dma_phys .. dma_phys + 8]);
                            _ = self.hid.handleTargetSetup(target, setup);
                            ch.hctsiz = (@as(u32, pid) << 29);
                            ch.hcdma +%= xfersize;
                            ch.hcdmab = ch.hcdma;
                            ch.hcint |= HCINT_ACK | HCINT_CHHLTD;
                        } else {
                            ch.hcint |= HCINT_AHBERR | HCINT_CHHLTD;
                        }
                        return;
                    } else if (!epdir_in) {
                        ch.hctsiz = (@as(u32, pid) << 29);
                        ch.hcdma +%= xfersize;
                        ch.hcdmab = ch.hcdma;
                    }
                }
                ch.hcint |= HCINT_ACK | HCINT_CHHLTD;
                return;
            } else {
                // Complete-Split (CSPLIT): for SETUP stage, return the status of the SSPLIT setup
                if (epnum == 0 and pid == 3 and !epdir_in) {
                    ch.hcchar &= ~HCCHAR_CHEN;
                    if (self.hid.ctrl[@intFromEnum(target)].last_setup_ok) {
                        ch.hctsiz = (@as(u32, pid) << 29);
                        ch.hcint |= HCINT_XFERCOMP | HCINT_CHHLTD | HCINT_ACK;
                    } else {
                        ch.hcint |= HCINT_STALL | HCINT_CHHLTD;
                    }
                    return;
                }
            }
        }

        // Control endpoint 0
        if (epnum == 0) {
            ch.hcchar &= ~HCCHAR_CHEN;
            if (pid == 3 and !epdir_in) {
                // SETUP stage (8 bytes)
                if (dma_phys + 8 <= ram.len) {
                    var setup: [8]u8 = undefined;
                    @memcpy(&setup, ram[dma_phys .. dma_phys + 8]);
                    const ok = self.hid.handleTargetSetup(target, setup);
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
                    const n = self.hid.readTargetControlData(target, ram[dma_phys .. dma_phys + xfersize]);
                    const rem: u32 = xfersize - @as(u32, @intCast(n));
                    const pkt_transferred: usize = if (n == 0) 1 else (n + mps - 1) / mps;
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
                if (xfersize > 0 and dma_phys + xfersize <= ram.len) {
                    self.hid.writeTargetControlData(target, ram[dma_phys .. dma_phys + xfersize]);
                }
                ch.hctsiz = (@as(u32, pid) << 29);
                ch.hcdma +%= xfersize;
                ch.hcdmab = ch.hcdma;
                ch.hcint |= HCINT_XFERCOMP | HCINT_CHHLTD | HCINT_ACK;
            }
            return;
        }

        // Bulk endpoints on the Ethernet device (EP2 IN / OUT for CDC-ECM, EP1 IN / EP2 OUT for LAN7800 and LAN9514)
        if (eptype == 2 and target == .eth and self.hid.isEthBulkEndpoint(epnum)) {
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
                    const pkt_transferred: usize = if (xfersize == 0) 1 else (@as(usize, xfersize) + mps - 1) / mps;
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

        // Interrupt IN endpoints on each device:
        // - Hub (.hub): EP1 IN (Status Change Bitmap)
        // - Ethernet (.eth): EP1 IN (CDC-ECM Notifications) or EP3 IN (LAN7800 / LAN9514 interrupt status)
        // - Keyboard (.kbd): EP1 IN (8-byte Boot Keyboard Report)
        // - Mouse (.mouse): EP1 IN (4-byte Boot Mouse Report)
        // Note: Raspberry Pi's downstream DWC2 driver (`linux-rpi/drivers/usb/dwc2/hcd.c`)
        // masquerades Split Interrupt IN transfers as `USB_ENDPOINT_XFER_CONTROL` (`eptype == 0`)
        // in `HCCHAR` so the hub uses its non-periodic TT handler.
        if ((eptype == 3 or (eptype == 0 and (ch.hcsplt & HCSPLT_SPLTENA) != 0)) and epdir_in) {
            ch.hcchar &= ~HCCHAR_CHEN;
            switch (target) {
                .hub => {
                    if (epnum == 1) {
                        if (self.hid.popHubInterrupt()) |bitmap| {
                            if (xfersize >= 1 and dma_phys + 1 <= ram.len) {
                                ram[dma_phys] = bitmap;
                            }
                            const copy_len: u32 = @min(xfersize, 1);
                            const rem: u32 = xfersize - copy_len;
                            const next_pid: u32 = if (pid == 0) 2 else 0;
                            ch.hctsiz = (next_pid << 29) | rem;
                            ch.hcdma +%= copy_len;
                            ch.hcdmab = ch.hcdma;
                            ch.hcint |= HCINT_XFERCOMP | HCINT_CHHLTD | HCINT_ACK;
                        } else {
                            ch.hcint |= HCINT_NAK | HCINT_CHHLTD;
                        }
                        return;
                    }
                },
                .eth => {
                    if (self.hid.isEthInterruptEndpoint(epnum)) {
                        if (dma_phys + xfersize <= ram.len) {
                            if (self.hid.popEthInterrupt(ram[dma_phys .. dma_phys + xfersize])) |copy_len| {
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
                },
                .kbd => {
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
                    }
                },
                .mouse => {
                    if (epnum == 1 or epnum == 2) {
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
                    }
                },
            }
        }

        ch.hcchar &= ~HCCHAR_CHEN;
        ch.hcint |= HCINT_STALL | HCINT_CHHLTD;
    }
};

fn testSendSetup(dwc2: *Dwc2Controller, ram: []u8, devaddr: u7, setup: [8]u8, split: bool) !void {
    @memcpy(ram[0x100..0x108], &setup);
    dwc2.write32(0x508, 0x7ff, ram);
    if (split) {
        // SSPLIT SETUP
        dwc2.write32(0x504, Dwc2Controller.HCSPLT_SPLTENA, ram);
        dwc2.write32(0x510, (3 << 29) | (1 << 19) | 8, ram);
        dwc2.write32(0x514, 0xc0000100, ram);
        dwc2.write32(0x500, Dwc2Controller.HCCHAR_CHEN | (@as(u32, devaddr) << 22) | 64, ram);
        try std.testing.expect((dwc2.read32(0x508) & Dwc2Controller.HCINT_ACK) != 0);
        try std.testing.expect((dwc2.read32(0x508) & Dwc2Controller.HCINT_XFERCOMP) == 0);

        // CSPLIT SETUP
        dwc2.write32(0x508, 0x7ff, ram);
        dwc2.write32(0x504, Dwc2Controller.HCSPLT_SPLTENA | Dwc2Controller.HCSPLT_COMPSPLT, ram);
        dwc2.write32(0x510, (3 << 29) | (1 << 19) | 0, ram);
        dwc2.write32(0x500, Dwc2Controller.HCCHAR_CHEN | (@as(u32, devaddr) << 22) | 64, ram);
        try std.testing.expect((dwc2.read32(0x508) & Dwc2Controller.HCINT_XFERCOMP) != 0);
        dwc2.write32(0x504, 0, ram);
    } else {
        dwc2.write32(0x504, 0, ram);
        dwc2.write32(0x510, (3 << 29) | (1 << 19) | 8, ram);
        dwc2.write32(0x514, 0xc0000100, ram);
        dwc2.write32(0x500, Dwc2Controller.HCCHAR_CHEN | (@as(u32, devaddr) << 22) | 64, ram);
        try std.testing.expect((dwc2.read32(0x508) & Dwc2Controller.HCINT_XFERCOMP) != 0);
    }
}

fn testReadControlData(dwc2: *Dwc2Controller, ram: []u8, devaddr: u7, dest_off: u32, len: u32, split: bool) !void {
    dwc2.write32(0x508, 0x7ff, ram);
    if (split) {
        // SSPLIT Control IN
        dwc2.write32(0x504, Dwc2Controller.HCSPLT_SPLTENA, ram);
        dwc2.write32(0x510, (2 << 29) | (1 << 19) | 0, ram);
        dwc2.write32(0x500, Dwc2Controller.HCCHAR_CHEN | (@as(u32, devaddr) << 22) | (1 << 15) | 64, ram);
        try std.testing.expect((dwc2.read32(0x508) & Dwc2Controller.HCINT_ACK) != 0);

        // CSPLIT Control IN
        dwc2.write32(0x508, 0x7ff, ram);
        dwc2.write32(0x504, Dwc2Controller.HCSPLT_SPLTENA | Dwc2Controller.HCSPLT_COMPSPLT, ram);
        dwc2.write32(0x510, (2 << 29) | (1 << 19) | len, ram);
        dwc2.write32(0x514, 0xc0000000 | dest_off, ram);
        dwc2.write32(0x500, Dwc2Controller.HCCHAR_CHEN | (@as(u32, devaddr) << 22) | (1 << 15) | 64, ram);
        try std.testing.expect((dwc2.read32(0x508) & Dwc2Controller.HCINT_XFERCOMP) != 0);
        dwc2.write32(0x504, 0, ram);
    } else {
        dwc2.write32(0x504, 0, ram);
        dwc2.write32(0x510, (2 << 29) | (1 << 19) | len, ram);
        dwc2.write32(0x514, 0xc0000000 | dest_off, ram);
        dwc2.write32(0x500, Dwc2Controller.HCCHAR_CHEN | (@as(u32, devaddr) << 22) | (1 << 15) | 64, ram);
        try std.testing.expect((dwc2.read32(0x508) & Dwc2Controller.HCINT_XFERCOMP) != 0);
    }
}

test "DWC2 multi-device USB Hub, Ethernet, Keyboard, and Mouse enumeration and transfers" {
    var dwc2 = Dwc2Controller{};
    defer dwc2.hid.net.deinit();
    var ram: [4096]u8 = @splat(0);

    // Verify Synopsis ID
    try std.testing.expectEqual(@as(u32, 0x4f54280a), dwc2.read32(0x040));

    // Power on port -> PRTCONNDET asserted at High-Speed (bits 18:17 = 00)
    dwc2.write32(0x440, Dwc2Controller.HPRT0_PRTPWR, &ram);
    try std.testing.expect((dwc2.read32(0x440) & Dwc2Controller.HPRT0_PRTCONNDET) != 0);
    try std.testing.expectEqual(@as(u32, Dwc2Controller.HPRT0_PRTSPD_HIGH), dwc2.read32(0x440) & Dwc2Controller.HPRT0_PRTSPD_MASK);

    // Reset root port (PRTRST = 1 then 0) -> PRTENA asserted
    dwc2.write32(0x440, Dwc2Controller.HPRT0_PRTPWR | Dwc2Controller.HPRT0_PRTRST, &ram);
    dwc2.write32(0x440, Dwc2Controller.HPRT0_PRTPWR, &ram);
    try std.testing.expect((dwc2.read32(0x440) & Dwc2Controller.HPRT0_PRTENA) != 0);

    // 1. Enumerate USB Hub (1-1) at address 0 -> assign address 2
    try testSendSetup(&dwc2, &ram, 0, .{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 18, 0x00 }, false);
    try testReadControlData(&dwc2, &ram, 0, 0x200, 18, false);
    try std.testing.expectEqual(@as(u8, 0x09), ram[0x204]); // bDeviceClass = USB_CLASS_HUB
    try testSendSetup(&dwc2, &ram, 0, .{ 0x00, 0x05, 2, 0x00, 0x00, 0x00, 0x00, 0x00 }, false); // SET_ADDRESS(2)
    try testReadControlData(&dwc2, &ram, 0, 0x200, 0, false); // Status stage at address 0!
    try testSendSetup(&dwc2, &ram, 2, .{ 0x00, 0x09, 1, 0x00, 0x00, 0x00, 0x00, 0x00 }, false); // SET_CONFIGURATION(1)

    // Power on ports 1, 2, 3 on Hub (devaddr = 2)
    for (1..4) |port1| {
        try testSendSetup(&dwc2, &ram, 2, .{ 0x23, 0x03, 8, 0x00, @intCast(port1), 0x00, 0x00, 0x00 }, false); // SetPortFeature(PORT_POWER)
    }

    // Hub EP1 IN Interrupt reports status change bitmap for Ports 1, 2, 3 (0b00001110 = 0x0e)
    dwc2.write32(0x528, 0x7ff, &ram);
    dwc2.write32(0x530, (0 << 29) | (1 << 19) | 1, &ram);
    dwc2.write32(0x534, 0xc0000280, &ram);
    dwc2.write32(0x520, Dwc2Controller.HCCHAR_CHEN | (2 << 22) | (3 << 18) | (1 << 15) | (1 << 11) | 1, &ram);
    try std.testing.expect((dwc2.read32(0x528) & Dwc2Controller.HCINT_XFERCOMP) != 0);
    try std.testing.expectEqual(@as(u8, 0x0e), ram[0x280]);

    // 2. Reset Port 1 (Ethernet, High-Speed) -> enumerate at address 0 -> assign address 3
    try testSendSetup(&dwc2, &ram, 2, .{ 0x23, 0x03, 4, 0x00, 1, 0x00, 0x00, 0x00 }, false); // SetPortFeature(PORT_RESET, port=1)
    try testSendSetup(&dwc2, &ram, 0, .{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 18, 0x00 }, false);
    try testReadControlData(&dwc2, &ram, 0, 0x220, 18, false);
    try std.testing.expectEqual(@as(u16, 0x0105), std.mem.readInt(u16, ram[0x220 + 10 ..][0..2], .little));
    try testSendSetup(&dwc2, &ram, 0, .{ 0x00, 0x05, 3, 0x00, 0x00, 0x00, 0x00, 0x00 }, false); // SET_ADDRESS(3)

    // 3. Reset Port 2 (Keyboard, Full-Speed via Split Transactions) -> enumerate at address 0 -> assign address 4
    try testSendSetup(&dwc2, &ram, 2, .{ 0x23, 0x03, 4, 0x00, 2, 0x00, 0x00, 0x00 }, false); // SetPortFeature(PORT_RESET, port=2)
    try testSendSetup(&dwc2, &ram, 0, .{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 18, 0x00 }, true);
    try testReadControlData(&dwc2, &ram, 0, 0x240, 18, true);
    try std.testing.expectEqualSlices(u8, &UsbHidComposite.KBD_DEVICE_DESC, ram[0x240 .. 0x240 + 18]);
    try testSendSetup(&dwc2, &ram, 0, .{ 0x00, 0x05, 4, 0x00, 0x00, 0x00, 0x00, 0x00 }, true); // SET_ADDRESS(4)

    // 4. Reset Port 3 (Mouse, Full-Speed via Split Transactions) -> enumerate at address 0 -> assign address 5
    try testSendSetup(&dwc2, &ram, 2, .{ 0x23, 0x03, 4, 0x00, 3, 0x00, 0x00, 0x00 }, false); // SetPortFeature(PORT_RESET, port=3)
    try testSendSetup(&dwc2, &ram, 0, .{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 18, 0x00 }, true);
    try testReadControlData(&dwc2, &ram, 0, 0x260, 18, true);
    try std.testing.expectEqualSlices(u8, &UsbHidComposite.MOUSE_DEVICE_DESC, ram[0x260 .. 0x260 + 18]);
    try testSendSetup(&dwc2, &ram, 0, .{ 0x00, 0x05, 5, 0x00, 0x00, 0x00, 0x00, 0x00 }, true); // SET_ADDRESS(5)

    // 5. Inject 'A' key press (evdev keycode 30 -> HID usage 0x04) and poll Keyboard (devaddr=4) EP1 IN on Channel 1
    dwc2.hid.handleEvdevKey(30, true);
    dwc2.write32(0x528, 0x7ff, &ram);
    dwc2.write32(0x530, (0 << 29) | (1 << 19) | 8, &ram); // HCTSIZ1: xfersize=8
    dwc2.write32(0x534, 0xc0000300, &ram); // HCDMA1
    dwc2.write32(0x520, Dwc2Controller.HCCHAR_CHEN | (4 << 22) | (3 << 18) | (1 << 15) | (1 << 11) | 8, &ram); // devaddr=4, EP1 IN Interrupt
    try std.testing.expect((dwc2.read32(0x528) & Dwc2Controller.HCINT_XFERCOMP) != 0);
    try std.testing.expectEqual(@as(u8, 0x04), ram[0x302]);

    // 6. Inject mouse motion and poll Mouse (devaddr=5) EP1 IN on Channel 1 (using SSPLIT + CSPLIT with eptype=0 as masqueraded by linux-rpi)
    dwc2.hid.handleMouseMotion(15, -10, 0);
    dwc2.write32(0x528, 0x7ff, &ram);
    dwc2.write32(0x524, Dwc2Controller.HCSPLT_SPLTENA, &ram);
    dwc2.write32(0x530, (0 << 29) | (1 << 19) | 0, &ram);
    dwc2.write32(0x520, Dwc2Controller.HCCHAR_CHEN | (5 << 22) | (0 << 18) | (1 << 15) | (1 << 11) | 4, &ram);
    try std.testing.expect((dwc2.read32(0x528) & Dwc2Controller.HCINT_ACK) != 0);

    dwc2.write32(0x528, 0x7ff, &ram);
    dwc2.write32(0x524, Dwc2Controller.HCSPLT_SPLTENA | Dwc2Controller.HCSPLT_COMPSPLT, &ram);
    dwc2.write32(0x530, (0 << 29) | (1 << 19) | 4, &ram);
    dwc2.write32(0x534, 0xc0000320, &ram);
    dwc2.write32(0x520, Dwc2Controller.HCCHAR_CHEN | (5 << 22) | (0 << 18) | (1 << 15) | (1 << 11) | 4, &ram);
    try std.testing.expect((dwc2.read32(0x528) & Dwc2Controller.HCINT_XFERCOMP) != 0);
    try std.testing.expectEqual(@as(i8, 15), @as(i8, @bitCast(ram[0x321])));
    try std.testing.expectEqual(@as(i8, -10), @as(i8, @bitCast(ram[0x322])));
    dwc2.write32(0x524, 0, &ram);

    // 7. Poll CDC-ECM Ethernet (devaddr=3) EP1 IN Interrupt on Channel 2 -> expect SPEED_CHANGE then NETWORK_CONNECTION
    dwc2.write32(0x550, (0 << 29) | (1 << 19) | 16, &ram);
    dwc2.write32(0x554, 0xc0000400, &ram);
    dwc2.write32(0x540, Dwc2Controller.HCCHAR_CHEN | (3 << 22) | (3 << 18) | (1 << 15) | (1 << 11) | 16, &ram);
    try std.testing.expect((dwc2.read32(0x548) & Dwc2Controller.HCINT_XFERCOMP) != 0);
    try std.testing.expectEqual(@as(u8, 0x2a), ram[0x401]); // USB_CDC_NOTIFY_SPEED_CHANGE

    dwc2.write32(0x548, 0x7ff, &ram);
    dwc2.write32(0x550, (2 << 29) | (1 << 19) | 16, &ram);
    dwc2.write32(0x554, 0xc0000420, &ram);
    dwc2.write32(0x540, Dwc2Controller.HCCHAR_CHEN | (3 << 22) | (3 << 18) | (1 << 15) | (1 << 11) | 16, &ram);
    try std.testing.expect((dwc2.read32(0x548) & Dwc2Controller.HCINT_XFERCOMP) != 0);
    try std.testing.expectEqual(@as(u8, 0x00), ram[0x421]); // USB_CDC_NOTIFY_NETWORK_CONNECTION
    try std.testing.expectEqual(@as(u8, 0x01), ram[0x422]); // Connected = 1

    // 8. Arm Bulk IN (devaddr=3, EP2 IN) on Channel 3 before any RX frame exists -> stays enabled (HCCHAR_CHEN set)
    dwc2.write32(0x570, (0 << 29) | (3 << 19) | 1536, &ram);
    dwc2.write32(0x574, 0xc0000800, &ram);
    dwc2.write32(0x560, Dwc2Controller.HCCHAR_CHEN | (3 << 22) | (2 << 18) | (1 << 15) | (2 << 11) | 512, &ram);
    try std.testing.expect((dwc2.read32(0x560) & Dwc2Controller.HCCHAR_CHEN) != 0);
    try std.testing.expectEqual(@as(u32, 0), dwc2.read32(0x568));

    // Transmit ARP Request on Bulk OUT (devaddr=3, EP2 OUT) on Channel 4 -> automatically completes waiting Channel 3 Bulk IN!
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
    dwc2.write32(0x580, Dwc2Controller.HCCHAR_CHEN | (3 << 22) | (2 << 18) | (0 << 15) | (2 << 11) | 512, &ram);
    try std.testing.expect((dwc2.read32(0x588) & Dwc2Controller.HCINT_XFERCOMP) != 0);

    // Verify Channel 3 Bulk IN completed with the 42-byte ARP Reply
    try std.testing.expect((dwc2.read32(0x568) & Dwc2Controller.HCINT_XFERCOMP) != 0);
    try std.testing.expectEqual(@as(u32, 1536 - 42), dwc2.read32(0x570) & 0x7ffff);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, ram[0x800 + 20 ..][0..2], .big));
}

test "DWC2 asserts GINTSTS_SOF on dwc2_hcd_urb_enqueue GINTMSK read and tickSof to prevent Ethernet TX timeouts" {
    var dwc2 = Dwc2Controller{};
    defer dwc2.hid.net.deinit();
    var ram: [256]u8 = @splat(0);

    // Enable global interrupts and unmask GINTSTS_SOF + GINTSTS_HCHINT (as Linux dwc2 does when periodic endpoints are active)
    dwc2.write32(0x008, Dwc2Controller.GAHBCFG_GLBL_INTR_EN | Dwc2Controller.GAHBCFG_DMA_EN, &ram);
    dwc2.write32(0x018, Dwc2Controller.GINTSTS_SOF | Dwc2Controller.GINTSTS_HCHINT, &ram);

    // Simulate all USB devices configured and 20 idle vblanks elapsing so sof_wakeup_frames reaches 0
    dwc2.hid.hub_configured = true;
    dwc2.hid.eth_configured = true;
    dwc2.hid.kbd_configured = true;
    dwc2.hid.mouse_configured = true;
    dwc2.hid.eth_notif_polled = true;
    dwc2.hid.reported_link_up = true;

    for (0..20) |_| {
        dwc2.tickSof(&ram);
        // Even after sof_wakeup_frames reaches 0, tickSof must still assert GINTSTS_SOF when unmasked
        try std.testing.expect((dwc2.read32(0x014) & Dwc2Controller.GINTSTS_SOF) != 0);
        // Simulate dwc2_read_core_intr: read GINTSTS (0x014) followed by GINTMSK (0x018)
        _ = dwc2.read32(0x018);
        // Clear GINTSTS_SOF and read HFNUM (0x408) as dwc2_sof_intr does
        dwc2.write32(0x014, Dwc2Controller.GINTSTS_SOF, &ram);
        _ = dwc2.read32(0x408);
        try std.testing.expect(!dwc2.irqPending());
    }
    try std.testing.expectEqual(@as(u8, 0), dwc2.sof_wakeup_frames);

    // Now simulate dwc2_hcd_urb_enqueue enqueuing an Ethernet Bulk OUT TX URB:
    // When GINTSTS_SOF is set in GINTMSK, dwc2_hcd_urb_enqueue only reads GINTMSK (0x018) and returns.
    const intr_mask = dwc2.read32(0x018);
    try std.testing.expect((intr_mask & Dwc2Controller.GINTSTS_SOF) != 0);
    // Dwc2Controller must immediately assert GINTSTS_SOF so dwc2_sof_intr schedules the Bulk OUT QH!
    try std.testing.expect(dwc2.irqPending());
    try std.testing.expect((dwc2.read32(0x014) & Dwc2Controller.GINTSTS_SOF) != 0);
}

