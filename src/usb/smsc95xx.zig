const std = @import("std");
const net_mod = @import("net.zig");
const onesComplementSum = @import("lan78xx.zig").onesComplementSum;

/// SMSC (Microchip) LAN9514 USB 2.0 hub's 10/100 Ethernet controller with its internal PHY, as
/// soldered onto the Raspberry Pi 1 Model B+. It is register compatible with the LAN9512/LAN9500
/// family and identifies itself with chip ID 0xEC00.
///
/// The host drives the chip through vendor control requests that read and write 32-bit registers
/// (`0xA1` / `0xA0`). Frames travel over Bulk IN (EP1) and Bulk OUT (EP2), RX frames behind a status
/// word and TX frames behind command words A/B, and the chip reports interrupt status on Interrupt
/// IN (EP3). The internal PHY sits at MDIO address 1 behind the `MII_ADDR` / `MII_DATA` registers.
/// The Pi has no EEPROM fitted, so the MAC address comes from the device tree.
pub const Lan9514 = struct {
    const BROADCAST: [6]u8 = @splat(0xff);

    pub const VENDOR_REQUEST_WRITE_REGISTER: u8 = 0xa0;
    pub const VENDOR_REQUEST_READ_REGISTER: u8 = 0xa1;
    pub const VENDOR_REQUEST_GET_STATS: u8 = 0xa2;

    /// Statistics block returned by `GET_STATS` (RX and TX counter sets, 32-bit each).
    pub const STATS_LEN: usize = 32 * 4;

    // Register map (byte offsets)
    pub const ID_REV: u16 = 0x00;
    pub const INT_STS: u16 = 0x08;
    pub const RX_CFG: u16 = 0x0c;
    pub const TX_CFG: u16 = 0x10;
    pub const HW_CFG: u16 = 0x14;
    pub const RX_FIFO_INF: u16 = 0x18;
    pub const TX_FIFO_INF: u16 = 0x1c;
    pub const PM_CTRL: u16 = 0x20;
    pub const LED_GPIO_CFG: u16 = 0x24;
    pub const GPIO_CFG: u16 = 0x28;
    pub const AFC_CFG: u16 = 0x2c;
    pub const E2P_CMD: u16 = 0x30;
    pub const E2P_DATA: u16 = 0x34;
    pub const BURST_CAP: u16 = 0x38;
    pub const STRAP_STATUS: u16 = 0x3c;
    pub const INT_EP_CTL: u16 = 0x68;
    pub const BULK_IN_DLY: u16 = 0x6c;
    pub const MAC_CR: u16 = 0x100;
    pub const ADDRH: u16 = 0x104;
    pub const ADDRL: u16 = 0x108;
    pub const HASHH: u16 = 0x10c;
    pub const HASHL: u16 = 0x110;
    pub const MII_ADDR: u16 = 0x114;
    pub const MII_DATA: u16 = 0x118;
    pub const FLOW: u16 = 0x11c;
    pub const VLAN1: u16 = 0x120;
    pub const VLAN2: u16 = 0x124;
    pub const WUFF: u16 = 0x128;
    pub const WUCSR: u16 = 0x12c;
    pub const COE_CR: u16 = 0x130;

    /// `ID_REV`: chip ID 0xEC00 (LAN9512/LAN9514) in the upper half, silicon revision in the lower half.
    pub const ID_REV_VALUE: u32 = 0xec00_0002;

    pub const INT_STS_TX_STOP: u32 = 1 << 17;
    pub const INT_STS_RX_STOP: u32 = 1 << 16;
    pub const INT_STS_PHY_INT: u32 = 1 << 15;
    /// Status bits that can raise an interrupt report (`INT_EP_CTL` enables).
    pub const INT_EP_CTL_INTEP: u32 = 1 << 31;
    pub const INT_EP_CTL_MASK: u32 = 0x000f_ffff;
    pub const RX_FIFO_FLUSH: u32 = 1 << 0;
    pub const TX_CFG_ON: u32 = 1 << 2;
    pub const TX_CFG_STOP: u32 = 1 << 1;
    pub const TX_CFG_FIFO_FLUSH: u32 = 1 << 0;
    pub const HW_CFG_BIR: u32 = 1 << 12;
    pub const HW_CFG_RXDOFF_SHIFT: u5 = 9;
    pub const HW_CFG_RXDOFF_MASK: u32 = 3 << HW_CFG_RXDOFF_SHIFT;
    pub const HW_CFG_MEF: u32 = 1 << 5;
    pub const HW_CFG_LRST: u32 = 1 << 3;
    pub const HW_CFG_PSEL: u32 = 1 << 2;
    pub const HW_CFG_BCE: u32 = 1 << 1;
    pub const HW_CFG_SRST: u32 = 1 << 0;
    pub const PM_CTL_DEV_RDY: u32 = 1 << 7;
    pub const PM_CTL_PHY_RST: u32 = 1 << 4;
    pub const E2P_CMD_BUSY: u32 = 1 << 31;
    pub const E2P_CMD_CMD_MASK: u32 = 0x7 << 28;
    pub const E2P_CMD_READ: u32 = 0;
    pub const E2P_CMD_TIMEOUT: u32 = 1 << 10;
    pub const E2P_CMD_LOADED: u32 = 1 << 9;
    /// Strapped with Auto-MDIX enabled; no EEPROM is fitted.
    pub const STRAP_STATUS_VALUE: u32 = 0x0000_0010;
    pub const MAC_CR_RXALL: u32 = 1 << 31;
    pub const MAC_CR_MCPAS: u32 = 1 << 19;
    pub const MAC_CR_PRMS: u32 = 1 << 18;
    pub const MAC_CR_INVFILT: u32 = 1 << 17;
    pub const MAC_CR_HFILT: u32 = 1 << 15;
    pub const MAC_CR_HPFILT: u32 = 1 << 13;
    pub const MAC_CR_BCAST: u32 = 1 << 11;
    pub const MAC_CR_TXEN: u32 = 1 << 3;
    pub const MAC_CR_RXEN: u32 = 1 << 2;
    pub const MII_WRITE: u32 = 1 << 1;
    pub const MII_BUSY: u32 = 1 << 0;
    pub const TX_COE_EN: u32 = 1 << 16;
    pub const RX_COE_MODE: u32 = 1 << 1;
    pub const RX_COE_EN: u32 = 1 << 0;

    // Bulk OUT TX command words
    pub const TX_CMD_A_DATA_OFFSET_SHIFT: u5 = 16;
    pub const TX_CMD_A_FIRST_SEG: u32 = 1 << 13;
    pub const TX_CMD_A_LAST_SEG: u32 = 1 << 12;
    pub const TX_CMD_A_BUF_SIZE_MASK: u32 = 0x7ff;
    pub const TX_CMD_B_CSUM_ENABLE: u32 = 1 << 14;
    pub const TX_CMD_B_DIS_PADDING: u32 = 1 << 12;
    pub const TX_CMD_B_FRAME_LENGTH_MASK: u32 = 0x7ff;
    pub const TX_CMD_LEN: usize = 8;

    // Bulk IN RX status word
    pub const RX_STS_FF: u32 = 1 << 30;
    pub const RX_STS_FL_SHIFT: u5 = 16;
    pub const RX_STS_ES: u32 = 1 << 15;
    pub const RX_STS_BF: u32 = 1 << 13;
    pub const RX_STS_MF: u32 = 1 << 10;
    pub const RX_STS_TL: u32 = 1 << 7;
    pub const RX_STS_FT: u32 = 1 << 5;
    pub const RX_STS_LEN: usize = 4;

    pub const PHY_ADDR: u5 = 1;

    /// Generic register file for 0x000..0x13f; behaviour is layered on top.
    regs: [0x140 / 4]u32 = @splat(0),
    // Interrupt status bits already reported over EP3 (each is sent once per assertion)
    int_reported: u32 = 0,
    // TX frame being gathered from its buffer segments
    tx_frame: [net_mod.VirtualNetwork.MAX_FRAME_LEN + 4]u8 = undefined,
    tx_len: usize = 0,
    tx_cmd_b: u32 = 0,
    tx_active: bool = false,
    phy: Lan9514Phy = .{},

    /// Power-on state.
    pub fn reset(self: *Lan9514) void {
        self.* = .{};
        self.liteReset();
        self.phy.reset();
    }

    /// `HW_CFG.LRST`: returns the MAC, FIFOs and control registers to their defaults.
    fn liteReset(self: *Lan9514) void {
        self.regs = @splat(0);
        self.int_reported = 0;
        self.tx_active = false;
        self.set(PM_CTRL, PM_CTL_DEV_RDY);
        self.set(AFC_CFG, 0x00f8_30a1);
        self.set(BULK_IN_DLY, 0x800);
        self.set(VLAN1, 0xffff);
        self.set(VLAN2, 0xffff);
        // No EEPROM: the address registers keep their invalid all-ones default
        self.set(ADDRH, 0x0000_ffff);
        self.set(ADDRL, 0xffff_ffff);
    }

    fn get(self: *const Lan9514, addr: u16) u32 {
        return self.regs[addr / 4];
    }

    fn set(self: *Lan9514, addr: u16, value: u32) void {
        self.regs[addr / 4] = value;
    }

    pub fn readRegister(self: *Lan9514, addr: u16, link_up: bool) u32 {
        self.phy.setLink(link_up);
        if (addr & 3 != 0) return 0;
        return switch (addr) {
            ID_REV => ID_REV_VALUE,
            INT_STS => self.intStatus(),
            RX_FIFO_INF => 0, // Frames drain to the host as soon as they arrive
            TX_FIFO_INF => 0x1200, // TX data FIFO free space in bytes (the FIFO drains instantly)
            STRAP_STATUS => STRAP_STATUS_VALUE,
            else => if (addr < self.regs.len * 4) self.get(addr) else 0,
        };
    }

    pub fn writeRegister(self: *Lan9514, addr: u16, value: u32, link_up: bool) void {
        self.phy.setLink(link_up);
        if (addr & 3 != 0) return;
        switch (addr) {
            ID_REV, RX_FIFO_INF, TX_FIFO_INF, STRAP_STATUS => {},
            INT_STS => {
                // Write 1 to clear
                self.set(INT_STS, self.get(INT_STS) & ~value);
                self.int_reported &= ~value;
            },
            RX_CFG => self.set(RX_CFG, value & ~RX_FIFO_FLUSH),
            TX_CFG => {
                var v = value & ~TX_CFG_FIFO_FLUSH;
                if ((value & TX_CFG_FIFO_FLUSH) != 0) self.tx_active = false;
                if ((value & TX_CFG_STOP) != 0) {
                    // The transmitter stops once the current frame completes
                    v &= ~(TX_CFG_STOP | TX_CFG_ON);
                    self.set(INT_STS, self.get(INT_STS) | INT_STS_TX_STOP);
                }
                self.set(TX_CFG, v);
            },
            HW_CFG => {
                if ((value & (HW_CFG_LRST | HW_CFG_SRST)) != 0) {
                    self.liteReset();
                    if ((value & HW_CFG_SRST) != 0) self.phy.reset();
                    // The reset bits self-clear once the reset completes
                    self.set(HW_CFG, value & ~(HW_CFG_LRST | HW_CFG_SRST | HW_CFG_PSEL));
                } else {
                    // The internal PHY is selected: no external PHY is fitted
                    self.set(HW_CFG, value & ~HW_CFG_PSEL);
                }
            },
            PM_CTRL => {
                if ((value & PM_CTL_PHY_RST) != 0) self.phy.reset();
                self.set(PM_CTRL, (value & ~PM_CTL_PHY_RST) | PM_CTL_DEV_RDY);
            },
            E2P_CMD => {
                if ((value & E2P_CMD_BUSY) == 0) {
                    self.set(E2P_CMD, value & ~(E2P_CMD_TIMEOUT | E2P_CMD_LOADED));
                    return;
                }
                // No EEPROM is fitted: reads clock in an idle-high data line, while commands that
                // wait for the EEPROM to signal ready time out.
                var result = value & ~(E2P_CMD_BUSY | E2P_CMD_TIMEOUT | E2P_CMD_LOADED);
                if ((value & E2P_CMD_CMD_MASK) == E2P_CMD_READ) {
                    self.set(E2P_DATA, 0xff);
                } else {
                    result |= E2P_CMD_TIMEOUT;
                }
                self.set(E2P_CMD, result);
            },
            MAC_CR => {
                const old = self.get(MAC_CR);
                if ((old & MAC_CR_RXEN) != 0 and (value & MAC_CR_RXEN) == 0) {
                    self.set(INT_STS, self.get(INT_STS) | INT_STS_RX_STOP);
                }
                self.set(MAC_CR, value);
            },
            MII_ADDR => {
                if ((value & MII_BUSY) != 0) {
                    const phy_addr: u5 = @truncate(value >> 11);
                    const reg: u5 = @truncate(value >> 6);
                    if ((value & MII_WRITE) != 0) {
                        if (phy_addr == PHY_ADDR) self.phy.write(reg, @truncate(self.get(MII_DATA)));
                    } else {
                        // An unpopulated MDIO address reads back with the bus pulled high
                        self.set(MII_DATA, if (phy_addr == PHY_ADDR) self.phy.read(reg) else 0xffff);
                    }
                }
                self.set(MII_ADDR, value & ~MII_BUSY);
            },
            MII_DATA => self.set(MII_DATA, value & 0xffff),
            else => if (addr < self.regs.len * 4) self.set(addr, value),
        }
    }

    fn intStatus(self: *const Lan9514) u32 {
        var sts = self.get(INT_STS);
        if (self.phy.interruptPending()) sts |= INT_STS_PHY_INT;
        return sts;
    }

    /// Latches the PHY interrupt into `INT_STS`, then returns the 4-byte Interrupt IN report if an
    /// enabled status bit has been raised since it was last reported.
    pub fn popInterrupt(self: *Lan9514, link_up: bool, dest: []u8) ?usize {
        self.phy.setLink(link_up);
        if (self.phy.interruptPending()) self.set(INT_STS, self.get(INT_STS) | INT_STS_PHY_INT);
        const enabled = self.get(INT_EP_CTL) & INT_EP_CTL_MASK;
        const sts = self.get(INT_STS);
        if ((sts & enabled & ~self.int_reported) == 0) return null;
        self.int_reported |= sts & enabled;
        var report: [4]u8 = undefined;
        std.mem.writeInt(u32, &report, sts, .little);
        const n = @min(dest.len, report.len);
        @memcpy(dest[0..n], report[0..n]);
        return n;
    }

    pub fn hasInterrupt(self: *Lan9514, link_up: bool) bool {
        self.phy.setLink(link_up);
        return (self.intStatus() & self.get(INT_EP_CTL) & INT_EP_CTL_MASK & ~self.int_reported) != 0;
    }

    /// Fills the `GET_STATS` response. Hardware counters are not modelled and read as zero.
    pub fn readStats(_: *const Lan9514, dest: []u8) usize {
        const n = @min(dest.len, STATS_LEN);
        @memset(dest[0..n], 0);
        return n;
    }

    pub fn rxEnabled(self: *const Lan9514) bool {
        return (self.get(MAC_CR) & MAC_CR_RXEN) != 0;
    }

    pub fn txEnabled(self: *const Lan9514) bool {
        return (self.get(MAC_CR) & MAC_CR_TXEN) != 0 and (self.get(TX_CFG) & TX_CFG_ON) != 0;
    }

    fn perfectMatch(self: *const Lan9514, da: []const u8) bool {
        const lo = std.mem.readInt(u32, da[0..4], .little);
        const hi: u32 = std.mem.readInt(u16, da[4..6], .little);
        return lo == self.get(ADDRL) and hi == (self.get(ADDRH) & 0xffff);
    }

    /// The 6-bit DA hash the MAC indexes `HASHH:HASHL` with (`ether_crc() >> 26`).
    pub fn daHash(da: []const u8) u6 {
        const crc_le = ~std.hash.Crc32.hash(da[0..6]);
        return @truncate(@bitReverse(crc_le) >> 26);
    }

    fn hashMatch(self: *const Lan9514, da: []const u8) bool {
        const bit = daHash(da);
        const word = if (bit >= 32) self.get(HASHH) else self.get(HASHL);
        return (word >> @intCast(bit % 32)) & 1 != 0;
    }

    /// The MAC's address filter: whether a frame from the wire passes the destination checks.
    fn passesFilter(self: *const Lan9514, frame: []const u8) bool {
        const cr = self.get(MAC_CR);
        if ((cr & MAC_CR_PRMS) != 0) return true;
        const da = frame[0..6];
        if (std.mem.eql(u8, da, &BROADCAST)) return (cr & MAC_CR_BCAST) == 0;
        if ((da[0] & 1) != 0) {
            if ((cr & MAC_CR_MCPAS) != 0) return true;
            return (cr & (MAC_CR_HPFILT | MAC_CR_HFILT)) != 0 and self.hashMatch(da);
        }
        if ((cr & MAC_CR_HFILT) != 0) return self.hashMatch(da);
        const matched = self.perfectMatch(da) or ((cr & MAC_CR_HPFILT) != 0 and self.hashMatch(da));
        return if ((cr & MAC_CR_INVFILT) != 0) !matched else matched;
    }

    /// Decides whether a frame from the wire is passed to the host. In receive-all mode frames
    /// that fail the address filter are still passed, flagged with `RX_STS_FF`.
    pub fn acceptsFrame(self: *const Lan9514, frame: []const u8) bool {
        if (frame.len < 14) return false;
        return (self.get(MAC_CR) & MAC_CR_RXALL) != 0 or self.passesFilter(frame);
    }

    /// Whether one Bulk IN transfer may carry more than one frame (`HW_CFG.MEF`).
    pub fn multipleFrames(self: *const Lan9514) bool {
        return (self.get(HW_CFG) & HW_CFG_MEF) != 0;
    }

    /// Caps a Bulk IN transfer at `BURST_CAP` (in 512-byte High-Speed packets) when burst cap is enabled.
    pub fn bulkInLimit(self: *const Lan9514, len: usize) usize {
        const burst_cap: usize = self.get(BURST_CAP) & 0xff;
        if ((self.get(HW_CFG) & HW_CFG_BCE) == 0 or burst_cap == 0) return len;
        return @min(len, burst_cap * 512);
    }

    fn rxDataOffset(self: *const Lan9514) usize {
        return (self.get(HW_CFG) & HW_CFG_RXDOFF_MASK) >> HW_CFG_RXDOFF_SHIFT;
    }

    fn rxCsumEnabled(self: *const Lan9514) bool {
        return (self.get(COE_CR) & RX_COE_EN) != 0;
    }

    /// Bytes `encodeRxFrame` needs for `frame_len`, including the alignment that precedes it at `offset`.
    pub fn rxRecordLen(self: *const Lan9514, offset: usize, frame_len: usize) usize {
        const csum: usize = if (self.rxCsumEnabled()) 2 else 0;
        return rxAlign(offset) + RX_STS_LEN + self.rxDataOffset() + @max(frame_len, 60) + 4 + csum;
    }

    /// Each RX status word starts 4-byte aligned within the transfer.
    fn rxAlign(offset: usize) usize {
        return (4 - (offset % 4)) % 4;
    }

    /// Writes one received frame into a Bulk IN transfer at `offset` as the chip delivers it: the
    /// RX status word, `HW_CFG.RXDOFF` offset bytes, the frame padded to the 60-byte Ethernet
    /// minimum, its FCS, then the receive checksum when RX checksum offload is enabled. Returns the
    /// new end of the transfer.
    pub fn encodeRxFrame(self: *const Lan9514, frame: []const u8, dest: []u8, offset: usize) usize {
        const pad = rxAlign(offset);
        const rxdoff = self.rxDataOffset();
        @memset(dest[offset .. offset + pad + RX_STS_LEN + rxdoff], 0);
        const start = offset + pad;
        const body = dest[start + RX_STS_LEN + rxdoff ..];
        const data_len = @max(frame.len, 60);
        @memcpy(body[0..frame.len], frame);
        @memset(body[frame.len..data_len], 0);
        const fcs = std.hash.Crc32.hash(body[0..data_len]);
        std.mem.writeInt(u32, body[data_len..][0..4], fcs, .little);
        var size = data_len + 4;

        const cr = self.get(MAC_CR);
        var ethertype = std.mem.readInt(u16, frame[12..14], .big);
        const vlan_tagged = ethertype == (self.get(VLAN1) & 0xffff) or ethertype == (self.get(VLAN2) & 0xffff);
        if (vlan_tagged and frame.len >= 18) ethertype = std.mem.readInt(u16, frame[16..18], .big);

        // Checksum offload: the 16-bit ones' complement sum of everything after the Ethernet
        // header (and after a VLAN tag in VLAN mode), up to the FCS, appended in network order.
        if (self.rxCsumEnabled()) {
            const l3: usize = if ((self.get(COE_CR) & RX_COE_MODE) != 0 and vlan_tagged) 18 else 14;
            const sum = if (data_len > l3) onesComplementSum(body[l3..data_len]) else 0;
            std.mem.writeInt(u16, body[size..][0..2], sum, .big);
            size += 2;
        }

        var sts: u32 = @as(u32, @intCast(size)) << RX_STS_FL_SHIFT;
        const da = frame[0..6];
        if (std.mem.eql(u8, da, &BROADCAST)) {
            sts |= RX_STS_BF;
        } else if ((da[0] & 1) != 0) {
            sts |= RX_STS_MF;
        }
        if (ethertype > 1500) sts |= RX_STS_FT;
        if ((cr & MAC_CR_RXALL) != 0 and !self.passesFilter(frame)) sts |= RX_STS_FF;
        if (frame.len > if (vlan_tagged) @as(usize, 1518) else 1514) sts |= RX_STS_TL | RX_STS_ES;
        std.mem.writeInt(u32, dest[start..][0..4], sts, .little);
        return start + RX_STS_LEN + rxdoff + size;
    }

    /// Unpacks a Bulk OUT transfer: each buffer carries TX command words A/B and starts 4-byte
    /// aligned, and a frame is gathered from its first to its last segment. The MAC inserts the
    /// checksum it was asked to and pads short frames, then transmits.
    pub fn handleBulkOut(self: *Lan9514, data: []const u8, net: *net_mod.VirtualNetwork) void {
        if (!self.txEnabled()) return;
        var off: usize = 0;
        while (off + TX_CMD_LEN <= data.len) {
            const cmd_a = std.mem.readInt(u32, data[off..][0..4], .little);
            const cmd_b = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
            const data_offset: usize = (cmd_a >> TX_CMD_A_DATA_OFFSET_SHIFT) & 0x1f;
            const buf_size: usize = cmd_a & TX_CMD_A_BUF_SIZE_MASK;
            const start = off + TX_CMD_LEN + data_offset;
            if (buf_size == 0 or start + buf_size > data.len) break;

            if ((cmd_a & TX_CMD_A_FIRST_SEG) != 0) {
                self.tx_active = true;
                self.tx_len = 0;
                self.tx_cmd_b = cmd_b;
            }
            if (self.tx_active) {
                if (self.tx_len + buf_size <= self.tx_frame.len) {
                    @memcpy(self.tx_frame[self.tx_len .. self.tx_len + buf_size], data[start .. start + buf_size]);
                    self.tx_len += buf_size;
                } else {
                    self.tx_active = false;
                }
            }
            if (self.tx_active and (cmd_a & TX_CMD_A_LAST_SEG) != 0) {
                self.tx_active = false;
                self.transmit(net);
            }

            off = start + buf_size;
            off = (off + 3) & ~@as(usize, 3);
        }
    }

    fn transmit(self: *Lan9514, net: *net_mod.VirtualNetwork) void {
        const cmd_b = self.tx_cmd_b;
        var frame: []u8 = self.tx_frame[0..@min(self.tx_len, cmd_b & TX_CMD_B_FRAME_LENGTH_MASK)];
        if ((cmd_b & TX_CMD_B_CSUM_ENABLE) != 0 and (self.get(COE_CR) & TX_COE_EN) != 0) {
            // The frame starts with the checksum preamble: where summing starts (low half) and
            // where the folded result goes (high half), both relative to the frame after it.
            if (frame.len < 4) return;
            const preamble = std.mem.readInt(u32, frame[0..4], .little);
            frame = frame[4..];
            const csum_start: usize = preamble & 0xffff;
            const csum_pos: usize = preamble >> 16;
            if (csum_start < frame.len and csum_pos + 2 <= frame.len) {
                const csum = ~onesComplementSum(frame[csum_start..]);
                std.mem.writeInt(u16, frame[csum_pos..][0..2], csum, .big);
            }
        }
        if (frame.len < 14) return;
        var padded: [60]u8 = @splat(0);
        if (frame.len < 60 and (cmd_b & TX_CMD_B_DIS_PADDING) == 0) {
            @memcpy(padded[0..frame.len], frame);
            frame = &padded;
        }
        net.handleTxFrame(frame);
    }
};

/// The LAN9514's internal 10/100 PHY (SMSC LAN8700 core), accessed over MDIO. Its link partner is
/// the emulated network, which advertises 100BASE-TX full duplex, so auto-negotiation completes
/// as soon as the cable is connected.
pub const Lan9514Phy = struct {
    pub const PHY_ID1: u16 = 0x0007;
    pub const PHY_ID2: u16 = 0xc0c3;

    pub const BMCR_RESET: u16 = 0x8000;
    pub const BMCR_ANRESTART: u16 = 0x0200;
    pub const BMCR_PDOWN: u16 = 0x0800;
    pub const BMSR_BASE: u16 = 0x7809; // 100/10 FD/HD, AN able, extended capabilities
    pub const BMSR_ANEGCOMPLETE: u16 = 0x0020;
    pub const BMSR_LSTATUS: u16 = 0x0004;
    /// Link partner: 100/10 FD/HD with symmetric pause, acknowledging our base page.
    pub const LP_ADVERTISE: u16 = 0x45e1;

    pub const CTRL_STATUS: u5 = 17;
    pub const SPECIAL_MODES: u5 = 18;
    pub const SPECIAL_CTRL_STS: u5 = 27;
    pub const INT_SRC: u5 = 29;
    pub const INT_MASK: u5 = 30;
    pub const SPECIAL: u5 = 31;
    pub const CTRL_STATUS_ENERGYON: u16 = 0x0002;
    pub const INT_ENERGYON: u16 = 0x0080;
    pub const INT_ANEG_COMP: u16 = 0x0040;
    pub const INT_LINK_DOWN: u16 = 0x0010;
    /// `PHY_SPECIAL`: auto-negotiation done, 100BASE-TX full duplex.
    pub const SPECIAL_AUTODONE_100FULL: u16 = 0x1018;

    regs: [32]u16 = @splat(0),
    int_src: u16 = 0,
    link: bool = false,

    pub fn reset(self: *Lan9514Phy) void {
        const link = self.link;
        self.* = .{};
        self.link = link;
        self.regs[0] = 0x3100; // Auto-negotiation enabled, 100 Mb/s full duplex
        self.regs[2] = PHY_ID1;
        self.regs[3] = PHY_ID2;
        self.regs[4] = 0x01e1; // Advertise 100/10 FD/HD, IEEE 802.3
        self.regs[SPECIAL_MODES] = 0x00e0 | PHY_ADDR_STRAP; // All capable, PHY address 1
    }

    const PHY_ADDR_STRAP: u16 = 1;

    fn linkUp(self: *const Lan9514Phy) bool {
        return self.link and (self.regs[0] & BMCR_PDOWN) == 0;
    }

    fn noteLinkChange(self: *Lan9514Phy, was_up: bool) void {
        if (self.linkUp() == was_up) return;
        self.int_src |= if (self.linkUp()) INT_ENERGYON | INT_ANEG_COMP else INT_LINK_DOWN;
    }

    pub fn setLink(self: *Lan9514Phy, up: bool) void {
        if (self.regs[2] == 0) self.reset();
        if (self.link == up) return;
        const was_up = self.linkUp();
        self.link = up;
        self.noteLinkChange(was_up);
    }

    pub fn interruptPending(self: *const Lan9514Phy) bool {
        return (self.int_src & self.regs[INT_MASK]) != 0;
    }

    pub fn read(self: *Lan9514Phy, reg: u5) u16 {
        if (self.regs[2] == 0) self.reset();
        const up = self.linkUp();
        return switch (reg) {
            1 => BMSR_BASE | if (up) BMSR_ANEGCOMPLETE | BMSR_LSTATUS else 0,
            5 => if (up) LP_ADVERTISE else 0,
            6 => if (up) 0x0001 else 0, // Link partner is auto-negotiation able
            CTRL_STATUS => (self.regs[CTRL_STATUS] & ~CTRL_STATUS_ENERGYON) | if (self.link) CTRL_STATUS_ENERGYON else 0,
            INT_SRC => blk: {
                // Read to clear
                const v = self.int_src;
                self.int_src = 0;
                break :blk v;
            },
            SPECIAL => if (up) SPECIAL_AUTODONE_100FULL else 0,
            else => self.regs[reg],
        };
    }

    pub fn write(self: *Lan9514Phy, reg: u5, value: u16) void {
        if (self.regs[2] == 0) self.reset();
        switch (reg) {
            0 => {
                const was_up = self.linkUp();
                if ((value & BMCR_RESET) != 0) {
                    // Soft reset restores the defaults (except the strapped mode) and self-clears
                    const modes = self.regs[SPECIAL_MODES];
                    self.reset();
                    self.regs[SPECIAL_MODES] = modes;
                } else {
                    self.regs[0] = value & ~BMCR_ANRESTART;
                }
                self.noteLinkChange(was_up);
            },
            1, 2, 3, 5, 6, INT_SRC, SPECIAL => {}, // Read-only
            else => self.regs[reg] = value,
        }
    }
};

fn testRead(chip: *Lan9514, addr: u16) u32 {
    return chip.readRegister(addr, true);
}

fn testWrite(chip: *Lan9514, addr: u16, value: u32) void {
    chip.writeRegister(addr, value, true);
}

fn testMdioRead(chip: *Lan9514, reg: u5) !u16 {
    testWrite(chip, Lan9514.MII_ADDR, (@as(u32, Lan9514.PHY_ADDR) << 11) | (@as(u32, reg) << 6) | Lan9514.MII_BUSY);
    try std.testing.expectEqual(@as(u32, 0), testRead(chip, Lan9514.MII_ADDR) & Lan9514.MII_BUSY);
    return @truncate(testRead(chip, Lan9514.MII_DATA));
}

fn testMdioWrite(chip: *Lan9514, reg: u5, value: u16) void {
    testWrite(chip, Lan9514.MII_DATA, value);
    testWrite(chip, Lan9514.MII_ADDR, (@as(u32, Lan9514.PHY_ADDR) << 11) | (@as(u32, reg) << 6) | Lan9514.MII_WRITE | Lan9514.MII_BUSY);
}

test "LAN9514 identifies itself, resets, and has no EEPROM" {
    var chip = Lan9514{};
    chip.reset();
    try std.testing.expectEqual(@as(u32, 0xec00), testRead(&chip, Lan9514.ID_REV) >> 16);

    // Lite reset self-clears and the internal PHY is selected
    testWrite(&chip, Lan9514.HW_CFG, Lan9514.HW_CFG_LRST);
    try std.testing.expectEqual(@as(u32, 0), testRead(&chip, Lan9514.HW_CFG) & (Lan9514.HW_CFG_LRST | Lan9514.HW_CFG_PSEL));
    testWrite(&chip, Lan9514.HW_CFG, Lan9514.HW_CFG_BIR | Lan9514.HW_CFG_MEF | Lan9514.HW_CFG_BCE | (2 << 9));
    try std.testing.expectEqual(Lan9514.HW_CFG_BIR | Lan9514.HW_CFG_MEF | Lan9514.HW_CFG_BCE | (2 << 9), testRead(&chip, Lan9514.HW_CFG));

    // PHY reset completes with PM_CTRL.DEV_RDY
    testWrite(&chip, Lan9514.PM_CTRL, testRead(&chip, Lan9514.PM_CTRL) | Lan9514.PM_CTL_PHY_RST);
    const pm = testRead(&chip, Lan9514.PM_CTRL);
    try std.testing.expect((pm & Lan9514.PM_CTL_PHY_RST) == 0 and (pm & Lan9514.PM_CTL_DEV_RDY) != 0);

    // No MAC address until the host programs one
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), testRead(&chip, Lan9514.ADDRL));
    try std.testing.expectEqual(@as(u32, 0x0000_ffff), testRead(&chip, Lan9514.ADDRH));
    testWrite(&chip, Lan9514.ADDRL, 0x12eb27b8);
    testWrite(&chip, Lan9514.ADDRH, 0x5634);
    try std.testing.expectEqual(@as(u32, 0x12eb27b8), testRead(&chip, Lan9514.ADDRL));

    // EEPROM read completes without a valid signature; other commands time out
    testWrite(&chip, Lan9514.E2P_CMD, Lan9514.E2P_CMD_BUSY | Lan9514.E2P_CMD_READ);
    try std.testing.expectEqual(@as(u32, 0), testRead(&chip, Lan9514.E2P_CMD) & (Lan9514.E2P_CMD_BUSY | Lan9514.E2P_CMD_TIMEOUT));
    try std.testing.expect((testRead(&chip, Lan9514.E2P_DATA) & 0xff) != 0xa5);
    testWrite(&chip, Lan9514.E2P_CMD, Lan9514.E2P_CMD_BUSY | (3 << 28));
    try std.testing.expect((testRead(&chip, Lan9514.E2P_CMD) & Lan9514.E2P_CMD_TIMEOUT) != 0);

    // Stopping the transmitter is reported in INT_STS, which is write-1-to-clear
    testWrite(&chip, Lan9514.TX_CFG, Lan9514.TX_CFG_ON);
    testWrite(&chip, Lan9514.TX_CFG, Lan9514.TX_CFG_STOP);
    try std.testing.expectEqual(@as(u32, 0), testRead(&chip, Lan9514.TX_CFG) & Lan9514.TX_CFG_ON);
    try std.testing.expect((testRead(&chip, Lan9514.INT_STS) & Lan9514.INT_STS_TX_STOP) != 0);
    testWrite(&chip, Lan9514.INT_STS, 0xffff_ffff);
    try std.testing.expectEqual(@as(u32, 0), testRead(&chip, Lan9514.INT_STS) & Lan9514.INT_STS_TX_STOP);
}

test "LAN9514 MDIO reaches the internal PHY at address 1 with 100 Mb/s full duplex negotiated" {
    var chip = Lan9514{};
    chip.reset();
    try std.testing.expectEqual(Lan9514Phy.PHY_ID1, try testMdioRead(&chip, 2));
    try std.testing.expectEqual(Lan9514Phy.PHY_ID2, try testMdioRead(&chip, 3));
    const bmsr = try testMdioRead(&chip, 1);
    try std.testing.expect((bmsr & Lan9514Phy.BMSR_LSTATUS) != 0 and (bmsr & Lan9514Phy.BMSR_ANEGCOMPLETE) != 0);
    try std.testing.expectEqual(Lan9514Phy.LP_ADVERTISE, try testMdioRead(&chip, 5));
    try std.testing.expectEqual(@as(u16, 0x0018), try testMdioRead(&chip, Lan9514Phy.SPECIAL) & 0x001c);

    // Other MDIO addresses are empty
    testWrite(&chip, Lan9514.MII_ADDR, (@as(u32, 3) << 11) | (2 << 6) | Lan9514.MII_BUSY);
    try std.testing.expectEqual(@as(u32, 0xffff), testRead(&chip, Lan9514.MII_DATA));

    // Soft reset self-clears and restores the defaults
    testMdioWrite(&chip, 4, 0x0061);
    testMdioWrite(&chip, 0, Lan9514Phy.BMCR_RESET);
    try std.testing.expectEqual(@as(u16, 0), try testMdioRead(&chip, 0) & Lan9514Phy.BMCR_RESET);
    try std.testing.expectEqual(@as(u16, 0x01e1), try testMdioRead(&chip, 4));

    // An enabled link-down interrupt raises PHY_INT and an interrupt report on EP3
    testMdioWrite(&chip, Lan9514Phy.INT_MASK, Lan9514Phy.INT_ANEG_COMP | Lan9514Phy.INT_LINK_DOWN | Lan9514Phy.INT_ENERGYON);
    _ = try testMdioRead(&chip, Lan9514Phy.INT_SRC);
    testWrite(&chip, Lan9514.INT_EP_CTL, Lan9514.INT_STS_PHY_INT);
    var report: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), chip.popInterrupt(true, &report));
    try std.testing.expectEqual(@as(?usize, 4), chip.popInterrupt(false, &report));
    try std.testing.expect((std.mem.readInt(u32, &report, .little) & Lan9514.INT_STS_PHY_INT) != 0);
    try std.testing.expectEqual(@as(?usize, null), chip.popInterrupt(false, &report));
    try std.testing.expect((chip.phy.read(Lan9514Phy.INT_SRC) & Lan9514Phy.INT_LINK_DOWN) != 0);
    try std.testing.expectEqual(@as(u16, 0), chip.phy.read(1) & Lan9514Phy.BMSR_LSTATUS);
    chip.writeRegister(Lan9514.INT_STS, Lan9514.INT_STS_PHY_INT, false);
    try std.testing.expectEqual(@as(u32, 0), chip.readRegister(Lan9514.INT_STS, false) & Lan9514.INT_STS_PHY_INT);
}

test "LAN9514 receive filter and Bulk IN status word framing" {
    var chip = Lan9514{};
    chip.reset();
    const mac = [6]u8{ 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56 };
    testWrite(&chip, Lan9514.ADDRL, std.mem.readInt(u32, mac[0..4], .little));
    testWrite(&chip, Lan9514.ADDRH, std.mem.readInt(u16, mac[4..6], .little));
    testWrite(&chip, Lan9514.HW_CFG, Lan9514.HW_CFG_MEF | Lan9514.HW_CFG_BCE | (2 << 9));
    testWrite(&chip, Lan9514.COE_CR, Lan9514.RX_COE_EN);
    testWrite(&chip, Lan9514.MAC_CR, Lan9514.MAC_CR_RXEN | Lan9514.MAC_CR_TXEN);

    var frame: [42]u8 = @splat(0);
    @memcpy(frame[0..6], &mac);
    frame[12] = 0x08;
    frame[13] = 0x06;
    frame[14] = 0x12;
    try std.testing.expect(chip.acceptsFrame(&frame));
    var other = frame;
    other[5] = 0x57;
    try std.testing.expect(!chip.acceptsFrame(&other));
    var bcast = frame;
    @memset(bcast[0..6], 0xff);
    try std.testing.expect(chip.acceptsFrame(&bcast));
    testWrite(&chip, Lan9514.MAC_CR, testRead(&chip, Lan9514.MAC_CR) | Lan9514.MAC_CR_BCAST);
    try std.testing.expect(!chip.acceptsFrame(&bcast));

    // Multicast passes only through the hash filter
    var mcast = frame;
    @memcpy(mcast[0..6], &[_]u8{ 0x33, 0x33, 0x00, 0x00, 0x00, 0x01 });
    try std.testing.expect(!chip.acceptsFrame(&mcast));
    const bit = Lan9514.daHash(mcast[0..6]);
    testWrite(&chip, if (bit >= 32) Lan9514.HASHH else Lan9514.HASHL, @as(u32, 1) << @intCast(bit % 32));
    testWrite(&chip, Lan9514.MAC_CR, testRead(&chip, Lan9514.MAC_CR) | Lan9514.MAC_CR_HPFILT);
    try std.testing.expect(chip.acceptsFrame(&mcast));

    // Status word, 2 offset bytes, the frame padded to 60 bytes, FCS, then the checksum
    var buf: [256]u8 = undefined;
    const end = chip.encodeRxFrame(&frame, &buf, 0);
    try std.testing.expectEqual(chip.rxRecordLen(0, frame.len), end);
    const sts = std.mem.readInt(u32, buf[0..4], .little);
    try std.testing.expectEqual(@as(u32, 66), (sts >> 16) & 0x3fff);
    try std.testing.expect((sts & Lan9514.RX_STS_FT) != 0 and (sts & Lan9514.RX_STS_ES) == 0);
    try std.testing.expectEqualSlices(u8, &frame, buf[6..48]);
    try std.testing.expectEqual(std.hash.Crc32.hash(buf[6..66]), std.mem.readInt(u32, buf[66..70], .little));
    try std.testing.expectEqual(@as(u16, 0x1200), std.mem.readInt(u16, buf[70..72], .big));

    // The next status word starts 4-byte aligned
    try std.testing.expectEqual(@as(usize, 72), end);
    try std.testing.expectEqual(@as(usize, 2), chip.rxRecordLen(end + 2, frame.len) - chip.rxRecordLen(0, frame.len));

    // Burst cap in 512-byte packets
    testWrite(&chip, Lan9514.BURST_CAP, 5);
    try std.testing.expectEqual(@as(usize, 2560), chip.bulkInLimit(18944));
}

test "LAN9514 Bulk OUT command words and TX checksum offload" {
    var chip = Lan9514{};
    chip.reset();
    var net = net_mod.VirtualNetwork{};
    testWrite(&chip, Lan9514.COE_CR, Lan9514.TX_COE_EN);
    testWrite(&chip, Lan9514.MAC_CR, Lan9514.MAC_CR_TXEN);
    testWrite(&chip, Lan9514.TX_CFG, Lan9514.TX_CFG_ON);

    // UDP 10.0.2.15:68 -> 10.0.2.2:67, payload "hi", with the pseudo-header sum seeded in the
    // checksum field as the host stack leaves it for offload
    var udp = [_]u8{
        0x52, 0x55, 0x0a, 0x00, 0x02, 0x02, 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56, 0x08, 0x00,
        0x45, 0x00, 0x00, 0x1e, 0x00, 0x01, 0x00, 0x00, 0x40, 0x11, 0x00, 0x00, 10,   0,
        2,    15,   10,   0,    2,    2,    0x00, 0x44, 0x00, 0x43, 0x00, 0x0a, 0x00, 0x00,
        'h',  'i',
    };
    var pseudo: [12]u8 = undefined;
    @memcpy(pseudo[0..8], udp[26..34]);
    pseudo[8] = 0;
    pseudo[9] = 17;
    std.mem.writeInt(u16, pseudo[10..12], 10, .big);
    std.mem.writeInt(u16, udp[40..42], onesComplementSum(&pseudo), .big);

    var xfer: [128]u8 = @splat(0);
    const len: u32 = udp.len + 4;
    std.mem.writeInt(u32, xfer[0..4], len | Lan9514.TX_CMD_A_FIRST_SEG | Lan9514.TX_CMD_A_LAST_SEG, .little);
    std.mem.writeInt(u32, xfer[4..8], len | Lan9514.TX_CMD_B_CSUM_ENABLE, .little);
    std.mem.writeInt(u32, xfer[8..12], (40 << 16) | 34, .little);
    @memcpy(xfer[12 .. 12 + udp.len], &udp);
    chip.handleBulkOut(xfer[0 .. 12 + udp.len], &net);

    // The MAC filled in the UDP checksum, which now validates against the pseudo-header
    try std.testing.expectEqual(udp.len + 4, chip.tx_len);
    const sent = chip.tx_frame[4 .. 4 + udp.len];
    try std.testing.expectEqualSlices(u8, udp[0..40], sent[0..40]);
    var verify: [22]u8 = undefined;
    @memcpy(verify[0..12], &pseudo);
    @memcpy(verify[12..22], sent[34..44]);
    try std.testing.expectEqual(@as(u16, 0xffff), onesComplementSum(&verify));

    // Disabled transmitter drops the transfer
    testWrite(&chip, Lan9514.TX_CFG, Lan9514.TX_CFG_STOP);
    try std.testing.expect(!chip.txEnabled());
}
