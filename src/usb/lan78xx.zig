const std = @import("std");
const net_mod = @import("net.zig");

/// Microchip LAN7800 USB 2.0/3.0 to Gigabit Ethernet controller with its integrated LAN88xx PHY,
/// as soldered onto the Raspberry Pi 3 Model B+ (inside the LAN7515 hub package).
///
/// The host drives the chip through vendor control requests that read and write 32-bit registers
/// (`0xA1` / `0xA0`) and fetch the statistics block (`0xA2`). Frames travel over Bulk IN (EP1) and
/// Bulk OUT (EP2), each prefixed by the chip's command words, and the chip reports interrupt status
/// on Interrupt IN (EP3). The PHY sits at MDIO address 1 behind the `MII_ACC` / `MII_DATA` registers.
/// The Pi has no EEPROM or OTP programmed, so the MAC address comes from the device tree.
pub const Lan7800 = struct {
    const BROADCAST: [6]u8 = @splat(0xff);

    pub const VENDOR_REQUEST_WRITE_REGISTER: u8 = 0xa0;
    pub const VENDOR_REQUEST_READ_REGISTER: u8 = 0xa1;
    pub const VENDOR_REQUEST_GET_STATS: u8 = 0xa2;

    /// `struct lan78xx_statstage`: 47 32-bit hardware counters.
    pub const STATS_LEN: usize = 47 * 4;

    // Register map (byte offsets)
    pub const ID_REV: u16 = 0x000;
    pub const INT_STS: u16 = 0x00c;
    pub const HW_CFG: u16 = 0x010;
    pub const PMT_CTL: u16 = 0x014;
    pub const DP_SEL: u16 = 0x024;
    pub const DP_CMD: u16 = 0x028;
    pub const DP_ADDR: u16 = 0x02c;
    pub const DP_DATA: u16 = 0x030;
    pub const E2P_CMD: u16 = 0x040;
    pub const E2P_DATA: u16 = 0x044;
    pub const USB_CFG0: u16 = 0x080;
    pub const BURST_CAP: u16 = 0x090;
    pub const INT_EP_CTL: u16 = 0x098;
    pub const RFE_CTL: u16 = 0x0b0;
    pub const FCT_RX_CTL: u16 = 0x0c0;
    pub const FCT_TX_CTL: u16 = 0x0c4;
    pub const MAC_CR: u16 = 0x100;
    pub const MAC_RX: u16 = 0x104;
    pub const MAC_TX: u16 = 0x108;
    pub const RX_ADDRH: u16 = 0x118;
    pub const RX_ADDRL: u16 = 0x11c;
    pub const MII_ACC: u16 = 0x120;
    pub const MII_DATA: u16 = 0x124;
    pub const MAF_BASE: u16 = 0x400;
    pub const NUM_OF_MAF: usize = 33;
    pub const OTP_BASE: u16 = 0x1000;
    pub const OTP_PWR_DN: u16 = OTP_BASE + 4 * 0x00;
    pub const OTP_ADDR1: u16 = OTP_BASE + 4 * 0x01;
    pub const OTP_ADDR2: u16 = OTP_BASE + 4 * 0x02;
    pub const OTP_RD_DATA: u16 = OTP_BASE + 4 * 0x06;
    pub const OTP_CMD_GO: u16 = OTP_BASE + 4 * 0x0a;
    pub const OTP_STATUS: u16 = OTP_BASE + 4 * 0x0c;

    /// `ID_REV`: chip ID 0x7800 in the upper half, silicon revision in the lower half.
    pub const ID_REV_VALUE: u32 = 0x7800_0002;

    pub const INT_STS_PHY_INT: u32 = 1 << 17;
    pub const HW_CFG_LRST: u32 = 1 << 1;
    pub const HW_CFG_SRST: u32 = 1 << 0;
    pub const PMT_CTL_READY: u32 = 1 << 7;
    pub const PMT_CTL_PHY_RST: u32 = 1 << 4;
    pub const DP_SEL_DPRDY: u32 = 1 << 31;
    pub const DP_SEL_RSEL_MASK: u32 = 0xf;
    pub const DP_SEL_RSEL_VLAN_DA: u32 = 1;
    /// The VLAN/DA hash filter RAM: 128 words of VLAN bitmap, then 16 words of DA multicast hash.
    pub const VHF_VLAN_LEN: usize = 128;
    pub const VHF_HASH_LEN: usize = 16;
    pub const E2P_CMD_BUSY: u32 = 1 << 31;
    pub const E2P_CMD_CMD_MASK: u32 = 0x7 << 28;
    pub const E2P_CMD_CMD_READ: u32 = 0;
    pub const E2P_CMD_TIMEOUT: u32 = 1 << 10;
    pub const E2P_CMD_ADDR_MASK: u32 = 0x1ff;
    pub const USB_CFG_BCE: u32 = 1 << 5;
    pub const RFE_CTL_IGMP_COE: u32 = 1 << 14;
    pub const RFE_CTL_ICMP_COE: u32 = 1 << 13;
    pub const RFE_CTL_TCPUDP_COE: u32 = 1 << 12;
    pub const RFE_CTL_IP_COE: u32 = 1 << 11;
    pub const RFE_CTL_BCAST_EN: u32 = 1 << 10;
    pub const RFE_CTL_MCAST_EN: u32 = 1 << 9;
    pub const RFE_CTL_UCAST_EN: u32 = 1 << 8;
    pub const RFE_CTL_MCAST_HASH: u32 = 1 << 3;
    pub const RFE_CTL_DA_PERFECT: u32 = 1 << 1;
    pub const RFE_CTL_RST: u32 = 1 << 0;
    pub const FCT_CTL_EN: u32 = 1 << 31;
    pub const FCT_CTL_RST: u32 = 1 << 30;
    pub const FCT_CTL_EMPTY: u32 = 1 << 21;
    pub const FCT_CTL_DIS: u32 = 1 << 20;
    pub const MAC_CR_RST: u32 = 1 << 0;
    pub const MAC_RXTX_EN: u32 = 1 << 0;
    pub const MAC_RXTX_DIS: u32 = 1 << 1;
    pub const MAF_HI_VALID: u32 = 1 << 31;
    pub const MAF_HI_TYPE_SRC: u32 = 1 << 30;
    pub const MII_ACC_BUSY: u32 = 1 << 0;
    pub const MII_ACC_WRITE: u32 = 1 << 1;
    pub const OTP_PWR_DN_PWRDN_N: u32 = 1 << 0;

    // Bulk OUT TX command A
    pub const TX_CMD_A_LSO: u32 = 1 << 27;
    pub const TX_CMD_A_IPE: u32 = 1 << 26;
    pub const TX_CMD_A_TPE: u32 = 1 << 25;
    pub const TX_CMD_A_IVTG: u32 = 1 << 24;
    pub const TX_CMD_A_LEN_MASK: u32 = 0x000f_ffff;
    pub const TX_CMD_LEN: usize = 8;

    // Bulk IN RX command A
    pub const RX_CMD_A_IPV: u32 = 1 << 29;
    pub const RX_CMD_A_PID_TCP: u32 = 1 << 27;
    pub const RX_CMD_A_PID_UDP: u32 = 2 << 27;
    pub const RX_CMD_A_PID_IP: u32 = 3 << 27;
    pub const RX_CMD_A_PFF: u32 = 1 << 26;
    pub const RX_CMD_A_BAM: u32 = 1 << 25;
    pub const RX_CMD_A_MAM: u32 = 1 << 24;
    pub const RX_CMD_A_UAM: u32 = 1 << 15;
    pub const RX_CMD_A_ICSM: u32 = 1 << 14;
    pub const RX_CMD_LEN: usize = 10;

    pub const PHY_ADDR: u5 = 1;

    /// Generic register file for 0x000..0x5ff (control, USB, FCT, MAC, MAF); behaviour is layered on top.
    regs: [0x600 / 4]u32 = @splat(0),
    vhf: [VHF_VLAN_LEN + VHF_HASH_LEN]u32 = @splat(0),
    otp_pwr_dn: u32 = OTP_PWR_DN_PWRDN_N,
    otp_addr: u16 = 0,
    otp_rd_data: u32 = 0,
    // Interrupt status bits already reported over EP3 (each is sent once per assertion)
    int_reported: u32 = 0,
    phy: Lan88xxPhy = .{},

    /// Power-on state.
    pub fn reset(self: *Lan7800) void {
        self.* = .{};
        self.liteReset();
        self.phy.reset();
    }

    /// `HW_CFG.LRST`: returns the MAC, FIFO controller and receive filter to their defaults.
    fn liteReset(self: *Lan7800) void {
        const usb_cfg = self.regs[USB_CFG0 / 4 .. (USB_CFG0 / 4) + 8].*;
        self.regs = @splat(0);
        self.regs[USB_CFG0 / 4 .. (USB_CFG0 / 4) + 8].* = usb_cfg;
        self.vhf = @splat(0);
        self.int_reported = 0;
        self.set(PMT_CTL, PMT_CTL_READY);
        // Maximum receive frame size 1518 + 4 bytes
        self.set(MAC_RX, 1522 << 16);
        // No EEPROM: the address registers keep their invalid all-ones default
        self.set(RX_ADDRH, 0x0000_ffff);
        self.set(RX_ADDRL, 0xffff_ffff);
    }

    fn get(self: *const Lan7800, addr: u16) u32 {
        return self.regs[addr / 4];
    }

    fn set(self: *Lan7800, addr: u16, value: u32) void {
        self.regs[addr / 4] = value;
    }

    pub fn readRegister(self: *Lan7800, addr: u16, link_up: bool) u32 {
        self.phy.setLink(link_up);
        if (addr & 3 != 0) return 0;
        return switch (addr) {
            ID_REV => ID_REV_VALUE,
            INT_STS => self.intStatus(),
            DP_SEL => self.get(DP_SEL) | DP_SEL_DPRDY,
            FCT_RX_CTL, FCT_TX_CTL => blk: {
                const v = self.get(addr);
                // The FIFOs drain instantly, and report disabled as soon as they are not enabled
                break :blk v | FCT_CTL_EMPTY | if ((v & FCT_CTL_EN) == 0) FCT_CTL_DIS else 0;
            },
            MAC_RX, MAC_TX => blk: {
                const v = self.get(addr);
                break :blk v | if ((v & MAC_RXTX_EN) == 0) MAC_RXTX_DIS else 0;
            },
            OTP_PWR_DN => self.otp_pwr_dn,
            OTP_ADDR1 => self.otp_addr >> 8,
            OTP_ADDR2 => self.otp_addr & 0xff,
            OTP_RD_DATA => self.otp_rd_data,
            OTP_STATUS => 0,
            else => if (addr < self.regs.len * 4) self.get(addr) else 0,
        };
    }

    pub fn writeRegister(self: *Lan7800, addr: u16, value: u32, link_up: bool) void {
        self.phy.setLink(link_up);
        if (addr & 3 != 0) return;
        switch (addr) {
            ID_REV => {},
            INT_STS => {
                // Write 1 to clear
                self.set(INT_STS, self.get(INT_STS) & ~value);
                self.int_reported &= ~value;
            },
            HW_CFG => {
                if ((value & (HW_CFG_LRST | HW_CFG_SRST)) != 0) {
                    self.liteReset();
                    if ((value & HW_CFG_SRST) != 0) self.phy.reset();
                    // The reset bits self-clear once the reset completes
                    self.set(HW_CFG, value & ~(HW_CFG_LRST | HW_CFG_SRST));
                } else {
                    self.set(HW_CFG, value);
                }
            },
            PMT_CTL => {
                if ((value & PMT_CTL_PHY_RST) != 0) self.phy.reset();
                self.set(PMT_CTL, (value & ~PMT_CTL_PHY_RST) | PMT_CTL_READY);
            },
            DP_SEL => self.set(DP_SEL, value & ~DP_SEL_DPRDY),
            DP_CMD => {
                // DP_CMD_WRITE_: store DP_DATA at DP_ADDR in the selected RAM
                if ((value & 1) != 0 and (self.get(DP_SEL) & DP_SEL_RSEL_MASK) == DP_SEL_RSEL_VLAN_DA) {
                    const idx = self.get(DP_ADDR) & 0x3fff;
                    if (idx < self.vhf.len) self.vhf[idx] = self.get(DP_DATA);
                }
                self.set(DP_CMD, value);
            },
            E2P_CMD => {
                if ((value & E2P_CMD_BUSY) == 0) {
                    self.set(E2P_CMD, value & ~E2P_CMD_TIMEOUT);
                    return;
                }
                // No EEPROM is fitted: reads clock in an idle-high data line, while commands that
                // wait for the EEPROM to signal ready time out.
                var result = value & ~(E2P_CMD_BUSY | E2P_CMD_TIMEOUT);
                if ((value & E2P_CMD_CMD_MASK) == E2P_CMD_CMD_READ) {
                    self.set(E2P_DATA, 0xff);
                } else {
                    result |= E2P_CMD_TIMEOUT;
                }
                self.set(E2P_CMD, result);
            },
            RFE_CTL => self.set(RFE_CTL, value & ~RFE_CTL_RST),
            FCT_RX_CTL, FCT_TX_CTL => self.set(addr, value & (FCT_CTL_EN)),
            MAC_CR => self.set(MAC_CR, value & ~MAC_CR_RST),
            MAC_RX, MAC_TX => self.set(addr, value & ~MAC_RXTX_DIS),
            MII_ACC => {
                if ((value & MII_ACC_BUSY) != 0) {
                    const phy_addr: u5 = @truncate(value >> 11);
                    const reg: u5 = @truncate(value >> 6);
                    if ((value & MII_ACC_WRITE) != 0) {
                        if (phy_addr == PHY_ADDR) self.phy.write(reg, @truncate(self.get(MII_DATA)));
                    } else {
                        // An unpopulated MDIO address reads back with the bus pulled high
                        self.set(MII_DATA, if (phy_addr == PHY_ADDR) self.phy.read(reg) else 0xffff);
                    }
                }
                self.set(MII_ACC, value & ~MII_ACC_BUSY);
            },
            OTP_PWR_DN => self.otp_pwr_dn = value & OTP_PWR_DN_PWRDN_N,
            OTP_ADDR1 => self.otp_addr = (self.otp_addr & 0x00ff) | (@as(u16, @truncate(value & 0x1f)) << 8),
            OTP_ADDR2 => self.otp_addr = (self.otp_addr & 0xff00) | @as(u16, @truncate(value & 0xff)),
            OTP_CMD_GO => {
                // The OTP is blank on the Pi
                if ((value & 1) != 0) self.otp_rd_data = 0;
            },
            else => if (addr < self.regs.len * 4) self.set(addr, value),
        }
    }

    fn intStatus(self: *const Lan7800) u32 {
        var sts = self.get(INT_STS);
        if (self.phy.interruptPending()) sts |= INT_STS_PHY_INT;
        return sts;
    }

    /// Latches PHY interrupts into `INT_STS`, then returns the 4-byte Interrupt IN report if an
    /// enabled status bit has been raised since it was last reported.
    pub fn popInterrupt(self: *Lan7800, link_up: bool, dest: []u8) ?usize {
        self.phy.setLink(link_up);
        if (self.phy.interruptPending()) self.set(INT_STS, self.get(INT_STS) | INT_STS_PHY_INT);
        const enabled = self.get(INT_EP_CTL) & 0x07ff_ffff;
        const sts = self.get(INT_STS);
        if ((sts & enabled & ~self.int_reported) == 0) return null;
        self.int_reported |= sts & enabled;
        var report: [4]u8 = undefined;
        std.mem.writeInt(u32, &report, sts, .little);
        const n = @min(dest.len, report.len);
        @memcpy(dest[0..n], report[0..n]);
        return n;
    }

    pub fn hasInterrupt(self: *Lan7800, link_up: bool) bool {
        self.phy.setLink(link_up);
        var sts = self.get(INT_STS);
        if (self.phy.interruptPending()) sts |= INT_STS_PHY_INT;
        return (sts & self.get(INT_EP_CTL) & 0x07ff_ffff & ~self.int_reported) != 0;
    }

    /// Fills the `GET_STATS` response. Hardware counters are not modelled and read as zero.
    pub fn readStats(_: *const Lan7800, dest: []u8) usize {
        const n = @min(dest.len, STATS_LEN);
        @memset(dest[0..n], 0);
        return n;
    }

    pub fn rxEnabled(self: *const Lan7800) bool {
        return (self.get(MAC_RX) & MAC_RXTX_EN) != 0 and (self.get(FCT_RX_CTL) & FCT_CTL_EN) != 0;
    }

    pub fn txEnabled(self: *const Lan7800) bool {
        return (self.get(MAC_TX) & MAC_RXTX_EN) != 0 and (self.get(FCT_TX_CTL) & FCT_CTL_EN) != 0;
    }

    fn mafMatch(self: *const Lan7800, da: []const u8) bool {
        const lo = std.mem.readInt(u32, da[0..4], .little);
        const hi: u32 = std.mem.readInt(u16, da[4..6], .little);
        for (0..NUM_OF_MAF) |i| {
            const maf_hi = self.get(MAF_BASE + @as(u16, @intCast(i)) * 8);
            const maf_lo = self.get(MAF_BASE + @as(u16, @intCast(i)) * 8 + 4);
            if ((maf_hi & MAF_HI_VALID) == 0 or (maf_hi & MAF_HI_TYPE_SRC) != 0) continue;
            if ((maf_hi & 0xffff) == hi and maf_lo == lo) return true;
        }
        return false;
    }

    /// The 9-bit DA hash the receive filter indexes its multicast table with (`ether_crc() >> 23`).
    pub fn daHash(da: []const u8) u9 {
        const crc_le = ~std.hash.Crc32.hash(da[0..6]);
        return @truncate(@bitReverse(crc_le) >> 23);
    }

    /// Receive filtering engine: decides whether a frame from the wire is passed to the host.
    pub fn acceptsFrame(self: *const Lan7800, frame: []const u8) bool {
        if (frame.len < 14) return false;
        const rfe = self.get(RFE_CTL);
        const da = frame[0..6];
        if (std.mem.eql(u8, da, &BROADCAST)) return (rfe & RFE_CTL_BCAST_EN) != 0;
        if ((da[0] & 1) != 0) {
            if ((rfe & RFE_CTL_MCAST_EN) != 0) return true;
            if ((rfe & RFE_CTL_MCAST_HASH) != 0) {
                const bit = daHash(da);
                if ((self.vhf[VHF_VLAN_LEN + bit / 32] >> @intCast(bit % 32)) & 1 != 0) return true;
            }
            return (rfe & RFE_CTL_DA_PERFECT) != 0 and self.mafMatch(da);
        }
        if ((rfe & RFE_CTL_UCAST_EN) != 0) return true;
        return (rfe & RFE_CTL_DA_PERFECT) != 0 and self.mafMatch(da);
    }

    /// Caps a Bulk IN transfer at `BURST_CAP` (in 512-byte High-Speed packets) when burst cap is enabled.
    pub fn bulkInLimit(self: *const Lan7800, len: usize) usize {
        const burst_cap: usize = self.get(BURST_CAP) & 0xff;
        if ((self.get(USB_CFG0) & USB_CFG_BCE) == 0 or burst_cap == 0) return len;
        return @min(len, burst_cap * 512);
    }

    /// Bytes `encodeRxFrame` needs for `frame_len`, including the alignment that precedes it at `offset`.
    pub fn rxRecordLen(offset: usize, frame_len: usize) usize {
        return rxAlign(offset) + RX_CMD_LEN + @max(frame_len, 60) + 4;
    }

    /// Each RX command starts 4-byte aligned within the transfer.
    fn rxAlign(offset: usize) usize {
        return (4 - (offset % 4)) % 4;
    }

    /// Writes one received frame into a Bulk IN transfer at `offset` as the chip delivers it: RX
    /// command words A/B/C, the frame padded to the 60-byte Ethernet minimum, then its FCS.
    /// Returns the new end of the transfer.
    pub fn encodeRxFrame(self: *const Lan7800, frame: []const u8, dest: []u8, offset: usize) usize {
        const pad = rxAlign(offset);
        @memset(dest[offset .. offset + pad], 0);
        const start = offset + pad;
        const body = dest[start + RX_CMD_LEN ..];
        const data_len = @max(frame.len, 60);
        @memcpy(body[0..frame.len], frame);
        @memset(body[frame.len..data_len], 0);
        const fcs = std.hash.Crc32.hash(body[0..data_len]);
        std.mem.writeInt(u32, body[data_len..][0..4], fcs, .little);
        const size: u32 = @intCast(data_len + 4);

        var cmd_a: u32 = size;
        const da = frame[0..6];
        if (std.mem.eql(u8, da, &BROADCAST)) {
            cmd_a |= RX_CMD_A_BAM;
        } else if ((da[0] & 1) != 0) {
            cmd_a |= RX_CMD_A_MAM;
        } else if ((self.get(RFE_CTL) & RFE_CTL_DA_PERFECT) != 0 and self.mafMatch(da)) {
            cmd_a |= RX_CMD_A_PFF;
        } else {
            cmd_a |= RX_CMD_A_UAM;
        }
        const ethertype = std.mem.readInt(u16, frame[12..14], .big);
        if (ethertype == 0x0800 and frame.len >= 34) {
            cmd_a |= switch (frame[23]) {
                6 => RX_CMD_A_PID_TCP,
                17 => RX_CMD_A_PID_UDP,
                else => RX_CMD_A_PID_IP,
            };
        } else if (ethertype == 0x86dd and frame.len >= 54) {
            cmd_a |= RX_CMD_A_IPV | switch (frame[20]) {
                6 => RX_CMD_A_PID_TCP,
                17 => RX_CMD_A_PID_UDP,
                else => RX_CMD_A_PID_IP,
            };
        }

        // Checksum offload: the 16-bit ones' complement sum of everything after the Ethernet
        // header (including the padding), which the host folds into its own verification.
        var cmd_b: u32 = 0;
        const coe = RFE_CTL_IP_COE | RFE_CTL_TCPUDP_COE | RFE_CTL_ICMP_COE | RFE_CTL_IGMP_COE;
        if ((self.get(RFE_CTL) & coe) != 0) {
            cmd_b = @as(u32, onesComplementSum(body[14..data_len])) << 16;
        } else {
            cmd_a |= RX_CMD_A_ICSM;
        }

        std.mem.writeInt(u32, dest[start..][0..4], cmd_a, .little);
        std.mem.writeInt(u32, dest[start + 4 ..][0..4], cmd_b, .little);
        std.mem.writeInt(u16, dest[start + 8 ..][0..2], 0, .little);
        return start + RX_CMD_LEN + size;
    }

    /// Unpacks a Bulk OUT transfer: each frame carries TX command words A/B and starts 4-byte
    /// aligned. The MAC inserts the checksums and VLAN tags it was asked to, then transmits.
    pub fn handleBulkOut(self: *const Lan7800, data: []const u8, net: *net_mod.VirtualNetwork) void {
        if (!self.txEnabled()) return;
        var off: usize = 0;
        while (off + TX_CMD_LEN <= data.len) {
            const cmd_a = std.mem.readInt(u32, data[off..][0..4], .little);
            const cmd_b = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
            const len: usize = cmd_a & TX_CMD_A_LEN_MASK;
            const start = off + TX_CMD_LEN;
            if (len == 0 or start + len > data.len) break;

            var frame: [net_mod.VirtualNetwork.MAX_FRAME_LEN + 4]u8 = undefined;
            var flen: usize = 0;
            if ((cmd_a & TX_CMD_A_IVTG) != 0 and len >= 12 and len + 4 <= frame.len) {
                @memcpy(frame[0..12], data[start .. start + 12]);
                std.mem.writeInt(u16, frame[12..14], 0x8100, .big);
                std.mem.writeInt(u16, frame[14..16], @truncate(cmd_b), .big);
                @memcpy(frame[16 .. len + 4], data[start + 12 .. start + len]);
                flen = len + 4;
            } else if (len <= frame.len) {
                @memcpy(frame[0..len], data[start .. start + len]);
                flen = len;
            }
            if (flen >= 14) {
                insertChecksums(frame[0..flen], (cmd_a & TX_CMD_A_IPE) != 0, (cmd_a & TX_CMD_A_TPE) != 0);
                net.handleTxFrame(frame[0..flen]);
            }

            off = start + len;
            off = (off + 3) & ~@as(usize, 3);
        }
    }
};

/// 16-bit ones' complement sum (not inverted) of `data` as big-endian words.
pub fn onesComplementSum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += std.mem.readInt(u16, data[i..][0..2], .big);
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(sum);
}

/// TX checksum offload: fills in the IPv4 header checksum and the TCP/UDP checksum of a frame.
fn insertChecksums(frame: []u8, ip: bool, l4: bool) void {
    var l3: usize = 14;
    var ethertype = std.mem.readInt(u16, frame[12..14], .big);
    if (ethertype == 0x8100 and frame.len >= 18) {
        ethertype = std.mem.readInt(u16, frame[16..18], .big);
        l3 = 18;
    }
    var proto: u8 = 0;
    var l4_off: usize = 0;
    var l4_len: usize = 0;
    var pseudo: u32 = 0;
    if (ethertype == 0x0800 and frame.len >= l3 + 20) {
        const ihl: usize = @as(usize, frame[l3] & 0xf) * 4;
        const total: usize = std.mem.readInt(u16, frame[l3 + 2 ..][0..2], .big);
        if (ihl < 20 or l3 + ihl > frame.len or total < ihl or l3 + total > frame.len) return;
        if (ip) {
            std.mem.writeInt(u16, frame[l3 + 10 ..][0..2], 0, .big);
            std.mem.writeInt(u16, frame[l3 + 10 ..][0..2], ~onesComplementSum(frame[l3 .. l3 + ihl]), .big);
        }
        proto = frame[l3 + 9];
        l4_off = l3 + ihl;
        l4_len = total - ihl;
        pseudo = @as(u32, onesComplementSum(frame[l3 + 12 .. l3 + 20])) + proto + @as(u32, @intCast(l4_len));
    } else if (ethertype == 0x86dd and frame.len >= l3 + 40) {
        const payload: usize = std.mem.readInt(u16, frame[l3 + 4 ..][0..2], .big);
        if (l3 + 40 + payload > frame.len) return;
        proto = frame[l3 + 6];
        l4_off = l3 + 40;
        l4_len = payload;
        pseudo = @as(u32, onesComplementSum(frame[l3 + 8 .. l3 + 40])) + proto + @as(u32, @intCast(l4_len));
    } else return;
    if (!l4) return;
    const csum_pos: usize = switch (proto) {
        6 => 16,
        17 => 6,
        else => return,
    };
    if (l4_len < csum_pos + 2) return;
    const seg = frame[l4_off .. l4_off + l4_len];
    std.mem.writeInt(u16, seg[csum_pos..][0..2], 0, .big);
    var sum: u32 = pseudo + onesComplementSum(seg);
    while ((sum >> 16) != 0) sum = (sum & 0xffff) + (sum >> 16);
    var csum: u16 = ~@as(u16, @truncate(sum));
    if (proto == 17 and csum == 0) csum = 0xffff;
    std.mem.writeInt(u16, seg[csum_pos..][0..2], csum, .big);
}

/// The LAN7800's integrated 10/100/1000BASE-T PHY (Microchip LAN88xx core), accessed over MDIO.
/// Its link partner is the emulated network, which advertises 1000BASE-T full duplex, so
/// auto-negotiation completes as soon as the cable is connected.
pub const Lan88xxPhy = struct {
    pub const PHY_ID1: u16 = 0x0007;
    pub const PHY_ID2: u16 = 0xc132;

    pub const BMCR_RESET: u16 = 0x8000;
    pub const BMCR_ANRESTART: u16 = 0x0200;
    pub const BMCR_PDOWN: u16 = 0x0800;
    pub const BMSR_BASE: u16 = 0x7949; // 100/10 FD/HD, extended status, preamble suppression, AN able, ext caps
    pub const BMSR_ANEGCOMPLETE: u16 = 0x0020;
    pub const BMSR_LSTATUS: u16 = 0x0004;
    /// Link partner: 1000/100/10 FD/HD with symmetric pause, acknowledging our base page.
    pub const LP_ADVERTISE: u16 = 0x45e1;
    pub const LP_STAT1000: u16 = 0x3c00;
    pub const ESTATUS: u16 = 0x3000;

    pub const INT_MASK: u5 = 0x19;
    pub const INT_STS: u5 = 0x1a;
    pub const EXT_PAGE_ACCESS: u5 = 0x1f;
    pub const INT_LINK_CHANGE: u16 = 0x2000;
    pub const INT_AUTONEG_DONE: u16 = 0x0400;
    pub const INT_ACTIVE: u16 = 0x8000;

    const MMD_SLOTS = 16;

    /// Standard and vendor registers in page 0.
    regs: [32]u16 = @splat(0),
    /// Registers 16..30 of the extended pages (1, 2 and the 0x52B5 token ring page).
    ext: [3][16]u16 = @splat(@splat(0)),
    page: u16 = 0,
    int_sts: u16 = 0,
    link: bool = false,
    mmd_ctrl: u16 = 0,
    mmd_addr: [32]u16 = @splat(0),
    mmd_keys: [MMD_SLOTS]u32 = @splat(0),
    mmd_vals: [MMD_SLOTS]u16 = @splat(0),
    mmd_count: usize = 0,

    pub fn reset(self: *Lan88xxPhy) void {
        const link = self.link;
        self.* = .{};
        self.link = link;
        self.regs[0] = 0x1140; // Auto-negotiation enabled, 1000 Mb/s full duplex
        self.regs[2] = PHY_ID1;
        self.regs[3] = PHY_ID2;
        self.regs[4] = 0x01e1; // Advertise 100/10 FD/HD, IEEE 802.3
        self.regs[9] = 0x0300; // Advertise 1000BASE-T FD/HD
        self.regs[15] = ESTATUS;
        // EEE: 100BASE-TX and 1000BASE-T capable and advertised
        self.mmdSet(3, 20, 0x0006);
        self.mmdSet(7, 60, 0x0006);
    }

    fn linkUp(self: *const Lan88xxPhy) bool {
        return self.link and (self.regs[0] & BMCR_PDOWN) == 0;
    }

    pub fn setLink(self: *Lan88xxPhy, up: bool) void {
        if (self.regs[2] == 0) self.reset();
        if (self.link == up) return;
        const was_up = self.linkUp();
        self.link = up;
        if (self.linkUp() != was_up) {
            self.int_sts |= INT_LINK_CHANGE;
            if (self.linkUp()) self.int_sts |= INT_AUTONEG_DONE;
        }
    }

    pub fn interruptPending(self: *const Lan88xxPhy) bool {
        const mask = self.regs[INT_MASK];
        return (mask & INT_ACTIVE) != 0 and (self.int_sts & mask & 0x7fff) != 0;
    }

    fn extSlot(self: *const Lan88xxPhy) ?usize {
        return switch (self.page) {
            1 => 0,
            2 => 1,
            0x52b5 => 2,
            else => null,
        };
    }

    fn mmdKey(devad: u16, addr: u16) u32 {
        return (@as(u32, devad & 0x1f) << 16) | addr;
    }

    fn mmdGet(self: *const Lan88xxPhy, devad: u16, addr: u16) u16 {
        const key = mmdKey(devad, addr);
        for (self.mmd_keys[0..self.mmd_count], 0..) |k, i| {
            if (k == key) return self.mmd_vals[i];
        }
        return 0;
    }

    fn mmdSet(self: *Lan88xxPhy, devad: u16, addr: u16, value: u16) void {
        const key = mmdKey(devad, addr);
        for (self.mmd_keys[0..self.mmd_count], 0..) |k, i| {
            if (k == key) {
                self.mmd_vals[i] = value;
                return;
            }
        }
        if (self.mmd_count == MMD_SLOTS) return;
        self.mmd_keys[self.mmd_count] = key;
        self.mmd_vals[self.mmd_count] = value;
        self.mmd_count += 1;
    }

    pub fn read(self: *Lan88xxPhy, reg: u5) u16 {
        if (self.regs[2] == 0) self.reset();
        if (reg >= 16 and reg != EXT_PAGE_ACCESS) {
            if (self.extSlot()) |slot| return self.ext[slot][reg - 16];
        }
        const up = self.linkUp();
        return switch (reg) {
            1 => BMSR_BASE | if (up) BMSR_ANEGCOMPLETE | BMSR_LSTATUS else 0,
            5 => if (up) LP_ADVERTISE else 0,
            6 => if (up) 0x0001 else 0, // Link partner is auto-negotiation able
            10 => if (up) LP_STAT1000 else 0,
            14 => blk: {
                const devad = self.mmd_ctrl & 0x1f;
                const v = if ((self.mmd_ctrl & 0xc000) == 0) self.mmd_addr[devad] else self.mmdGet(devad, self.mmd_addr[devad]);
                // Post-increment modes advance the address after each data access
                if ((self.mmd_ctrl & 0xc000) == 0x8000) self.mmd_addr[devad] +%= 1;
                break :blk v;
            },
            INT_STS => blk: {
                // Read to clear
                const v = self.int_sts | if (self.interruptPending()) INT_ACTIVE else 0;
                self.int_sts = 0;
                break :blk v;
            },
            EXT_PAGE_ACCESS => self.page,
            else => self.regs[reg],
        };
    }

    pub fn write(self: *Lan88xxPhy, reg: u5, value: u16) void {
        if (self.regs[2] == 0) self.reset();
        if (reg >= 16 and reg != EXT_PAGE_ACCESS) {
            if (self.extSlot()) |slot| {
                self.ext[slot][reg - 16] = value;
                return;
            }
        }
        switch (reg) {
            0 => {
                if ((value & BMCR_RESET) != 0) {
                    // Soft reset restores the defaults and self-clears
                    const mmd_keys = self.mmd_keys;
                    const mmd_vals = self.mmd_vals;
                    const mmd_count = self.mmd_count;
                    self.reset();
                    self.mmd_keys = mmd_keys;
                    self.mmd_vals = mmd_vals;
                    self.mmd_count = mmd_count;
                    return;
                }
                const was_up = self.linkUp();
                self.regs[0] = value & ~BMCR_ANRESTART;
                if (self.linkUp() != was_up) self.int_sts |= INT_LINK_CHANGE;
            },
            1, 2, 3, 5, 6, 10, 15, INT_STS => {}, // Read-only
            13 => self.mmd_ctrl = value,
            14 => {
                const devad = self.mmd_ctrl & 0x1f;
                if ((self.mmd_ctrl & 0xc000) == 0) {
                    self.mmd_addr[devad] = value;
                } else {
                    self.mmdSet(devad, self.mmd_addr[devad], value);
                    if ((self.mmd_ctrl & 0xc000) != 0x4000) self.mmd_addr[devad] +%= 1;
                }
            },
            EXT_PAGE_ACCESS => self.page = value,
            else => self.regs[reg] = value,
        }
    }
};

fn testRead(chip: *Lan7800, addr: u16) u32 {
    return chip.readRegister(addr, true);
}

fn testWrite(chip: *Lan7800, addr: u16, value: u32) void {
    chip.writeRegister(addr, value, true);
}

fn testMdioRead(chip: *Lan7800, reg: u5) !u16 {
    testWrite(chip, Lan7800.MII_ACC, (@as(u32, Lan7800.PHY_ADDR) << 11) | (@as(u32, reg) << 6) | Lan7800.MII_ACC_BUSY);
    try std.testing.expectEqual(@as(u32, 0), testRead(chip, Lan7800.MII_ACC) & Lan7800.MII_ACC_BUSY);
    return @truncate(testRead(chip, Lan7800.MII_DATA));
}

test "LAN7800 identifies itself, resets, and has no EEPROM or OTP" {
    var chip = Lan7800{};
    chip.reset();
    try std.testing.expectEqual(@as(u32, 0x7800), testRead(&chip, Lan7800.ID_REV) >> 16);

    // Lite reset self-clears; PHY reset completes with PMT_CTL.READY
    testWrite(&chip, Lan7800.HW_CFG, Lan7800.HW_CFG_LRST);
    try std.testing.expectEqual(@as(u32, 0), testRead(&chip, Lan7800.HW_CFG) & Lan7800.HW_CFG_LRST);
    testWrite(&chip, Lan7800.PMT_CTL, testRead(&chip, Lan7800.PMT_CTL) | Lan7800.PMT_CTL_PHY_RST);
    const pmt = testRead(&chip, Lan7800.PMT_CTL);
    try std.testing.expect((pmt & Lan7800.PMT_CTL_PHY_RST) == 0 and (pmt & Lan7800.PMT_CTL_READY) != 0);

    // No MAC address until the host programs one
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), testRead(&chip, Lan7800.RX_ADDRL));

    // EEPROM read completes without the 0xA5 signature; OTP is blank
    testWrite(&chip, Lan7800.E2P_CMD, Lan7800.E2P_CMD_BUSY | Lan7800.E2P_CMD_CMD_READ);
    try std.testing.expectEqual(@as(u32, 0), testRead(&chip, Lan7800.E2P_CMD) & (Lan7800.E2P_CMD_BUSY | Lan7800.E2P_CMD_TIMEOUT));
    try std.testing.expect((testRead(&chip, Lan7800.E2P_DATA) & 0xff) != 0xa5);
    testWrite(&chip, Lan7800.OTP_PWR_DN, 0);
    testWrite(&chip, Lan7800.OTP_CMD_GO, 1);
    try std.testing.expectEqual(@as(u32, 0), testRead(&chip, Lan7800.OTP_RD_DATA));

    // RX path disable is reported once RXEN clears
    testWrite(&chip, Lan7800.MAC_RX, testRead(&chip, Lan7800.MAC_RX) | Lan7800.MAC_RXTX_EN);
    try std.testing.expectEqual(@as(u32, 0), testRead(&chip, Lan7800.MAC_RX) & Lan7800.MAC_RXTX_DIS);
    testWrite(&chip, Lan7800.MAC_RX, testRead(&chip, Lan7800.MAC_RX) & ~Lan7800.MAC_RXTX_EN);
    try std.testing.expect((testRead(&chip, Lan7800.MAC_RX) & Lan7800.MAC_RXTX_DIS) != 0);
}

test "LAN7800 MDIO reaches the LAN88xx PHY at address 1 with the link negotiated" {
    var chip = Lan7800{};
    chip.reset();
    try std.testing.expectEqual(Lan88xxPhy.PHY_ID1, try testMdioRead(&chip, 2));
    try std.testing.expectEqual(Lan88xxPhy.PHY_ID2, try testMdioRead(&chip, 3));
    const bmsr = try testMdioRead(&chip, 1);
    try std.testing.expect((bmsr & Lan88xxPhy.BMSR_LSTATUS) != 0 and (bmsr & Lan88xxPhy.BMSR_ANEGCOMPLETE) != 0);
    try std.testing.expectEqual(Lan88xxPhy.LP_STAT1000, try testMdioRead(&chip, 10));

    // Other MDIO addresses are empty
    testWrite(&chip, Lan7800.MII_ACC, (@as(u32, 3) << 11) | (2 << 6) | Lan7800.MII_ACC_BUSY);
    try std.testing.expectEqual(@as(u32, 0xffff), testRead(&chip, Lan7800.MII_DATA));

    // Unplugging the cable drops the link
    chip.phy.setLink(false);
    try std.testing.expectEqual(@as(u16, 0), chip.phy.read(1) & Lan88xxPhy.BMSR_LSTATUS);
    try std.testing.expect((chip.phy.read(Lan88xxPhy.INT_STS) & Lan88xxPhy.INT_LINK_CHANGE) != 0);

    // Clause 45 registers through the Clause 22 MMD window
    chip.phy.write(13, 3);
    chip.phy.write(14, 20);
    chip.phy.write(13, 0x4003);
    try std.testing.expectEqual(@as(u16, 0x0006), chip.phy.read(14));
}

test "LAN7800 Bulk IN framing, receive filter, and TX checksum offload" {
    var chip = Lan7800{};
    chip.reset();
    const mac = [6]u8{ 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56 };
    testWrite(&chip, Lan7800.MAF_BASE + 4, std.mem.readInt(u32, mac[0..4], .little));
    testWrite(&chip, Lan7800.MAF_BASE, std.mem.readInt(u16, mac[4..6], .little) | Lan7800.MAF_HI_VALID);
    testWrite(&chip, Lan7800.RFE_CTL, Lan7800.RFE_CTL_BCAST_EN | Lan7800.RFE_CTL_DA_PERFECT | Lan7800.RFE_CTL_IP_COE | Lan7800.RFE_CTL_TCPUDP_COE);

    var frame: [42]u8 = @splat(0);
    @memcpy(frame[0..6], &mac);
    frame[12] = 0x08;
    frame[13] = 0x06;
    try std.testing.expect(chip.acceptsFrame(&frame));
    var other = frame;
    other[5] = 0x57;
    try std.testing.expect(!chip.acceptsFrame(&other));

    // Short frames are padded to 60 bytes and carry a 4-byte FCS
    var buf: [256]u8 = undefined;
    const end = chip.encodeRxFrame(&frame, &buf, 0);
    try std.testing.expectEqual(Lan7800.rxRecordLen(0, frame.len), end);
    const cmd_a = std.mem.readInt(u32, buf[0..4], .little);
    try std.testing.expectEqual(@as(u32, 64), cmd_a & 0x3fff);
    try std.testing.expect((cmd_a & Lan7800.RX_CMD_A_PFF) != 0);
    try std.testing.expectEqual(std.hash.Crc32.hash(buf[10..70]), std.mem.readInt(u32, buf[70..74], .little));
    // The next frame's command words start 4-byte aligned
    try std.testing.expectEqual(@as(usize, 2), Lan7800.rxRecordLen(end, frame.len) - Lan7800.rxRecordLen(0, frame.len));

    // UDP checksum inserted on transmit: 10.0.2.15:68 -> 10.0.2.2:67, payload "hi"
    var udp = [_]u8{
        0x52, 0x55, 0x0a, 0x00, 0x02, 0x02, 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56, 0x08, 0x00,
        0x45, 0x00, 0x00, 0x1e, 0x00, 0x01, 0x00, 0x00, 0x40, 0x11, 0x00, 0x00, 10,   0,
        2,    15,   10,   0,    2,    2,    0x00, 0x44, 0x00, 0x43, 0x00, 0x0a, 0x00, 0x00,
        'h',  'i',
    };
    insertChecksums(&udp, true, true);
    try std.testing.expectEqual(@as(u16, 0xffff), onesComplementSum(udp[14..34]));
    var pseudo: [12]u8 = undefined;
    @memcpy(pseudo[0..8], udp[26..34]);
    pseudo[8] = 0;
    pseudo[9] = 17;
    std.mem.writeInt(u16, pseudo[10..12], 10, .big);
    var total: u32 = @as(u32, onesComplementSum(&pseudo)) + onesComplementSum(udp[34..44]);
    while ((total >> 16) != 0) total = (total & 0xffff) + (total >> 16);
    try std.testing.expectEqual(@as(u32, 0xffff), total);
}
