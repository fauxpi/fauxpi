//! Broadcom / Cypress SDIO Wi-Fi Controller Emulation.
//!
//! Emulates the onboard wireless controller attached to the BCM2835 Arasan SDHCI
//! interface (`/soc/mmc@7e300000`), one of:
//! - CYW43430 (BCM43438, 802.11b/g/n) on the Raspberry Pi Zero W and Zero 2 W: an ARM
//!   Cortex-M3 with 512 KiB of SOCRAM at `0x00000000`, SDIO ID `0x02d0:0xa9a6`
//! - CYW43455 (802.11a/b/g/n/ac) on the Raspberry Pi 3 Model A+ and B+: an ARM Cortex-R4
//!   with 800 KiB of TCM at `0x00198000`, SDIO ID `0x02d0:0xa9bf`
//!
//! - SDIO bus protocol (`CMD5`, `CMD3`, `CMD7`, `CMD52`, `CMD53`)
//! - Function 0: CCCR, FBR1, FBR2, and CIS tuples
//! - Function 1: Backplane window (`SBSDIO_FUNC1_SBADDR*`), clock/sleep CSRs,
//!   AI/DMP cores (ChipCommon `0x800`, 802.11 `0x812`, SDIO Device `0x829`, and the ARM CM3
//!   `0x82a` and SOCRAM `0x80e` or the ARM CR4 `0x83e`), and the chip RAM
//! - Function 2: SDPCM + BCDC control/event protocol (`brcmfmac` driver interface)

const std = @import("std");
const net_mod = @import("../usb/net.zig");

pub const Chip = enum {
    cyw43430,
    cyw43455,

    /// ChipCommon chip ID: 43430, or 0x4345 for the BCM4345 family
    pub fn id(self: Chip) u16 {
        return switch (self) {
            .cyw43430 => 43430,
            .cyw43455 => 0x4345,
        };
    }

    /// Chip revision: BCM43430A1 (`brcmfmac43430-sdio`), BCM4345C0 (rev 6, `brcmfmac43455-sdio`)
    pub fn rev(self: Chip) u16 {
        return switch (self) {
            .cyw43430 => 1,
            .cyw43455 => 6,
        };
    }

    pub fn sdioDeviceId(self: Chip) u16 {
        return switch (self) {
            .cyw43430 => 0xa9a6,
            .cyw43455 => 0xa9bf,
        };
    }

    /// Backplane address of the chip RAM (SOCRAM, or the Cortex-R4's TCM)
    pub fn ramBase(self: Chip) u32 {
        return switch (self) {
            .cyw43430 => 0,
            .cyw43455 => 0x198000,
        };
    }

    pub fn ramSize(self: Chip) u32 {
        return switch (self) {
            .cyw43430 => 512 * 1024,
            .cyw43455 => 800 * 1024,
        };
    }

    fn hasCortexR4(self: Chip) bool {
        return self == .cyw43455;
    }

    fn dualBand(self: Chip) bool {
        return self == .cyw43455;
    }

    /// Channel widths (WLC_BW_20MHZ_BIT 1, 40MHZ 2, 80MHZ 4) the chip supports in `band`
    /// (WLC_BAND_5G = 1, WLC_BAND_2G = 2): the CYW43430 is 20 MHz only; the CYW43455 adds
    /// 40 MHz in both bands and 80 MHz (802.11ac) at 5 GHz.
    fn bandwidths(self: Chip, band: u32) u32 {
        return switch (self) {
            .cyw43430 => if (band == 2) 1 else 0,
            .cyw43455 => if (band == 2) 1 | 2 else if (band == 1) 1 | 2 | 4 else 0,
        };
    }
};

pub const Cyw43430 = struct {
    /// Largest chip RAM of any `Chip`
    pub const RAM_SIZE: usize = 800 * 1024;
    pub const MAX_RX_FRAMES: usize = 32;
    pub const MAX_FRAME_LEN: usize = 2048;

    // SDIO Function 1 register offsets (0x10000..0x1001f)
    const SBSDIO_FUNC1_SBADDRLOW: u32 = 0x1000a;
    const SBSDIO_FUNC1_SBADDRMID: u32 = 0x1000b;
    const SBSDIO_FUNC1_SBADDRHIGH: u32 = 0x1000c;
    const SBSDIO_FUNC1_FRAMECTRL: u32 = 0x1000d;
    const SBSDIO_FUNC1_CHIPCLKCSR: u32 = 0x1000e;
    const SBSDIO_FUNC1_SDIOPULLUP: u32 = 0x1000f;
    const SBSDIO_FUNC1_WFRAMEBCLO: u32 = 0x10019;
    const SBSDIO_FUNC1_WFRAMEBCHI: u32 = 0x1001a;
    const SBSDIO_FUNC1_RFRAMEBCLO: u32 = 0x1001b;
    const SBSDIO_FUNC1_RFRAMEBCHI: u32 = 0x1001c;
    const SBSDIO_FUNC1_MESBUSYCTRL: u32 = 0x1001d;
    const SBSDIO_FUNC1_WAKEUPCTRL: u32 = 0x1001e;
    const SBSDIO_FUNC1_SLEEPCSR: u32 = 0x1001f;

    const SBSDIO_ALP_AVAIL: u8 = 0x40;
    const SBSDIO_HT_AVAIL: u8 = 0x80;

    // Backplane core base addresses
    const CC_BASE: u32 = 0x18000000;
    const D11_BASE: u32 = 0x18001000;
    const SDIO_BASE: u32 = 0x18002000;
    const ARM_BASE: u32 = 0x18003000; // ARM CM3 or CR4
    const SOCRAM_BASE: u32 = 0x18004000;
    const EROM_BASE: u32 = 0x18000800;

    const CC_WRAP: u32 = 0x18100000;
    const D11_WRAP: u32 = 0x18101000;
    const SDIO_WRAP: u32 = 0x18102000;
    const ARM_WRAP: u32 = 0x18103000;
    const SOCRAM_WRAP: u32 = 0x18104000;

    // SDIO core interrupt bits (struct sdpcmd_regs)
    const I_SMB_SW0: u32 = 1 << 0;
    const I_HMB_FC_STATE: u32 = 1 << 4;
    const I_HMB_FC_CHANGE: u32 = 1 << 5;
    const I_HMB_FRAME_IND: u32 = 1 << 6;
    const I_HMB_HOST_INT: u32 = 1 << 7;

    // SDPCM channels
    const SDPCM_CONTROL_CHANNEL: u8 = 0;
    const SDPCM_EVENT_CHANNEL: u8 = 1;
    const SDPCM_DATA_CHANNEL: u8 = 2;

    // BCDC command codes
    const BRCMF_C_GET_VERSION: u32 = 1;
    const BRCMF_C_UP: u32 = 2;
    const BRCMF_C_DOWN: u32 = 3;
    const BRCMF_C_SET_PROMISC: u32 = 10;
    const BRCMF_C_GET_RATE: u32 = 12;
    const BRCMF_C_SET_INFRA: u32 = 20;
    const BRCMF_C_GET_AUTH: u32 = 21;
    const BRCMF_C_SET_AUTH: u32 = 22;
    const BRCMF_C_GET_BSSID: u32 = 23;
    const BRCMF_C_GET_SSID: u32 = 25;
    const BRCMF_C_SET_SSID: u32 = 26;
    const BRCMF_C_TERMINATED: u32 = 28;
    const BRCMF_C_GET_CHANNEL: u32 = 29;
    const BRCMF_C_SET_CHANNEL: u32 = 30;
    const BRCMF_C_GET_SRL: u32 = 31;
    const BRCMF_C_SET_SRL: u32 = 32;
    const BRCMF_C_GET_LRL: u32 = 33;
    const BRCMF_C_SET_LRL: u32 = 34;
    const BRCMF_C_GET_RADIO: u32 = 37;
    const BRCMF_C_SET_RADIO: u32 = 38;
    const BRCMF_C_GET_PHYTYPE: u32 = 39;
    const BRCMF_C_SET_KEY: u32 = 45;
    const BRCMF_C_SET_PASSIVE_SCAN: u32 = 49;
    const BRCMF_C_DISASSOC: u32 = 52;
    const BRCMF_C_REASSOC: u32 = 53;
    const BRCMF_C_SET_ROAM_TRIGGER: u32 = 55;
    const BRCMF_C_SET_ROAM_DELTA: u32 = 57;
    const BRCMF_C_GET_DTIMPRD: u32 = 77;
    const BRCMF_C_SET_COUNTRY: u32 = 84;
    const BRCMF_C_GET_PM: u32 = 85;
    const BRCMF_C_SET_PM: u32 = 86;
    const BRCMF_C_GET_CURR_RATESET: u32 = 114;
    const BRCMF_C_GET_AP: u32 = 117;
    const BRCMF_C_SET_AP: u32 = 118;
    const BRCMF_C_SET_SCB_AUTHORIZE: u32 = 121;
    const BRCMF_C_SET_SCB_DEAUTHORIZE: u32 = 122;
    const BRCMF_C_GET_RSSI: u32 = 127;
    const BRCMF_C_GET_WSEC: u32 = 133;
    const BRCMF_C_SET_WSEC: u32 = 134;
    const BRCMF_C_GET_PHY_NOISE: u32 = 135;
    const BRCMF_C_GET_BSS_INFO: u32 = 136;
    const BRCMF_C_GET_BANDLIST: u32 = 140;
    const BRCMF_C_SET_SCB_TIMEOUT: u32 = 158;
    const BRCMF_C_GET_ASSOCLIST: u32 = 159;
    const BRCMF_C_GET_PHYLIST: u32 = 180;
    const BRCMF_C_SET_SCAN_CHANNEL_TIME: u32 = 185;
    const BRCMF_C_SET_SCAN_UNASSOC_TIME: u32 = 187;
    const BRCMF_C_SCB_DEAUTHENTICATE_FOR_REASON: u32 = 201;
    const BRCMF_C_SET_ASSOC_PREFER: u32 = 205;
    const BRCMF_C_GET_VALID_CHANNELS: u32 = 217;
    const BRCMF_C_GET_KEY_PRIMARY: u32 = 235;
    const BRCMF_C_SET_KEY_PRIMARY: u32 = 236;
    const BRCMF_C_SET_SCAN_PASSIVE_TIME: u32 = 258;
    const BRCMF_C_GET_VAR: u32 = 262;
    const BRCMF_C_SET_VAR: u32 = 263;
    const BRCMF_C_SET_WSEC_PMK: u32 = 268;
    const BRCMF_C_GET_REVINFO: u32 = 98;

    const BCDC_DCMD_ERROR: u32 = 0x01;
    const BCDC_DCMD_SET: u32 = 0x02;

    chip: Chip = .cyw43430,
    mac_address: [6]u8 = .{ 0xb8, 0x27, 0xeb, 0x47, 0x61, 0x03 },

    // Function 0 CCCR & FBR state
    cccr_ioex: u8 = 0,
    cccr_ienx: u8 = 0,
    cccr_bus_if: u8 = 0,
    cccr_speed: u8 = 0x01, // SDIO_SPEED_SHS
    cccr_brcm_cardcap: u8 = 0x02, // SDIO_CCCR_BRCM_CARDCAP_CMD14_SUPPORT
    cccr_brcm_cardctrl: u8 = 0,
    cccr_brcm_sepint: u8 = 0,
    fbr1_blksize: u16 = 64,
    fbr2_blksize: u16 = 512,

    // Function 1 state
    sbaddr_low: u8 = 0,
    sbaddr_mid: u8 = 0x00,
    sbaddr_high: u8 = 0x18,
    func1_framectrl: u8 = 0,
    func1_chipclkcsr: u8 = SBSDIO_ALP_AVAIL | SBSDIO_HT_AVAIL,
    func1_sdiopullup: u8 = 0,
    func1_mesbusyctrl: u8 = 0,
    func1_wakeupctrl: u8 = 0,
    func1_sleepcsr: u8 = 0x03,

    // Backplane core wrapper states: [0]=CC, [1]=D11, [2]=SDIO, [3]=ARM CM3 / CR4, [4]=SOCRAM
    wrap_ioctl: [5]u32 = .{ 1, 1, 1, 1, 1 },
    wrap_reset: [5]u32 = .{ 0, 0, 0, 1, 0 }, // the ARM starts in reset until firmware loaded
    arm_running: bool = false,
    /// Cortex-R4 reset vector, written to backplane address 0 before the core is started
    cr4_reset_vector: u32 = 0,
    cr4_bankidx: u32 = 0,
    /// The `ver` string, from the version trailer of the firmware the host downloaded
    fw_version: [128]u8 = @splat(0),
    fw_version_len: usize = 0,

    // SOCRAM & SDIO core registers
    socram_bankidx: u32 = 0,
    socram_bankpda: u32 = 0,
    sdio_intstatus: u32 = 0,
    sdio_hostintmask: u32 = 0,
    sdio_tosbmailbox: u32 = 0,
    sdio_tosbmailboxdata: u32 = 0,
    sdio_tohostmailboxdata: u32 = 0x00040008, // HMB_DATA_FWREADY (0x08) | (SDPCM_PROT_VERSION=4 << 16)

    // SDPCM sequence numbers and Function 2 frame queue
    rx_seq: u8 = 0,
    host_tx_seq: u8 = 0,
    event_msgs: [32]u8 = @splat(0),
    country_abrev: [4]u8 = .{ '0', '0', 0, 0 },
    country_rev: i32 = 0,
    country_ccode: [4]u8 = .{ '0', '0', 0, 0 },
    /// `bw_cap` the host set for the 5 GHz and 2.4 GHz bands, if any (`null` = all supported)
    bw_cap: [2]?u32 = .{ null, null },
    /// SSID of the open access point scans find (none while empty)
    ap_ssid: [32]u8 = @splat(0),
    ap_ssid_len: u8 = 0,
    /// The access point radio the host joined
    joined: ?AccessPoint = null,
    /// The network behind the access point: user-mode NAT on 10.0.3.0/24
    net: net_mod.VirtualNetwork = .{ .subnet = 3 },
    /// Last transmit sequence number the host may use, as last advertised in a received frame
    tx_window_end: u8 = 0,

    rx_frames: [MAX_RX_FRAMES][MAX_FRAME_LEN]u8 = undefined,
    rx_frame_lens: [MAX_RX_FRAMES]usize = @splat(0),
    rx_head: usize = 0,
    rx_tail: usize = 0,
    rx_count: usize = 0,
    rx_frame_offset: usize = 0,

    // Chip RAM for firmware & NVRAM upload/verification (`chip.ramSize()` bytes used)
    chip_ram: [RAM_SIZE]u8 = @splat(0),

    pub fn reset(self: *Cyw43430) void {
        const mac = self.mac_address;
        const chip = self.chip;
        const ap_ssid = self.ap_ssid;
        const ap_ssid_len = self.ap_ssid_len;
        const dhcp_enabled = self.net.dhcp_enabled;
        self.net.deinit();
        self.* = .{ .chip = chip, .mac_address = mac, .ap_ssid = ap_ssid, .ap_ssid_len = ap_ssid_len };
        self.net.dhcp_enabled = dhcp_enabled;
    }

    pub fn deinit(self: *Cyw43430) void {
        self.net.deinit();
    }

    /// Services the network behind the access point (host sockets), passing what it has
    /// for the guest to the host as received frames
    pub fn pollNetwork(self: *Cyw43430) void {
        if (self.joined == null) return;
        self.net.poll();
        self.deliverNetworkFrames();
    }

    /// True while the network behind the access point has frames the guest has not taken
    pub fn hasPendingRx(self: *const Cyw43430) bool {
        return self.joined != null and (self.net.hasRxFrame() or self.rx_count != 0);
    }

    /// Names the open access point scans find (up to 32 bytes of `ssid`)
    pub fn setAccessPointName(self: *Cyw43430, ssid: []const u8) void {
        const n = @min(ssid.len, self.ap_ssid.len);
        @memset(&self.ap_ssid, 0);
        @memcpy(self.ap_ssid[0..n], ssid[0..n]);
        self.ap_ssid_len = @intCast(n);
    }

    /// Offset into `chip_ram` of the `len` bytes at backplane address `addr`, if they are RAM
    inline fn ramOffset(self: *const Cyw43430, addr: u32, len: u32) ?u32 {
        const off = addr -% self.chip.ramBase();
        return if (off < self.chip.ramSize() and self.chip.ramSize() - off >= len) off else null;
    }

    pub fn cardIntPending(self: *const Cyw43430) bool {
        if ((self.cccr_ienx & 0x01) == 0) return false; // Master interrupt enable
        if ((self.cccr_ienx & 0x06) == 0) return false; // Function 1 or 2 interrupt enable
        return (self.sdio_intstatus & self.sdio_hostintmask) != 0;
    }

    pub fn backplaneWindowBase(self: *const Cyw43430) u32 {
        return (@as(u32, self.sbaddr_high) << 24) |
            (@as(u32, self.sbaddr_mid) << 16) |
            (@as(u32, self.sbaddr_low & 0x80) << 8);
    }

    /// Reads 1 byte from Function `func` at 17-bit `addr` (`CMD52` or byte-wise `CMD53`).
    pub fn readByte(self: *Cyw43430, func: u3, addr: u17) u8 {
        return switch (func) {
            0 => self.readFunc0Byte(addr),
            1 => self.readFunc1Byte(addr),
            2 => 0,
            else => 0,
        };
    }

    /// Writes 1 byte to Function `func` at 17-bit `addr` (`CMD52` or byte-wise `CMD53`).
    pub fn writeByte(self: *Cyw43430, func: u3, addr: u17, val: u8) void {
        switch (func) {
            0 => self.writeFunc0Byte(addr, val),
            1 => self.writeFunc1Byte(addr, val),
            2 => {},
            else => {},
        }
    }

    /// Executes a `CMD53` read transfer into `out`.
    pub fn readExtended(self: *Cyw43430, func: u3, addr: u17, incr_addr: bool, out: []u8) void {
        switch (func) {
            0 => {
                for (out, 0..) |*b, i| {
                    const a: u17 = if (incr_addr) addr +| @as(u17, @intCast(i)) else addr;
                    b.* = self.readFunc0Byte(a);
                }
            },
            1 => {
                if (addr < 0x10000 and incr_addr and (out.len % 4) == 0) {
                    const win = self.backplaneWindowBase();
                    const base_off: u32 = addr & 0x07fff;
                    var i: usize = 0;
                    while (i < out.len) : (i += 4) {
                        const bp_addr = win + ((base_off + @as(u32, @intCast(i))) & 0x07fff);
                        const word = self.readBackplane32(bp_addr);
                        std.mem.writeInt(u32, out[i..][0..4], word, .little);
                    }
                } else {
                    for (out, 0..) |*b, i| {
                        const a: u17 = if (incr_addr) addr +| @as(u17, @intCast(i)) else addr;
                        b.* = self.readFunc1Byte(a);
                    }
                }
            },
            2 => {
                self.readFunc2Frame(out);
            },
            else => @memset(out, 0),
        }
    }

    /// Executes a `CMD53` write transfer from `data`.
    pub fn writeExtended(self: *Cyw43430, func: u3, addr: u17, incr_addr: bool, data: []const u8) void {
        switch (func) {
            0 => {
                for (data, 0..) |b, i| {
                    const a: u17 = if (incr_addr) addr +| @as(u17, @intCast(i)) else addr;
                    self.writeFunc0Byte(a, b);
                }
            },
            1 => {
                if (addr < 0x10000 and incr_addr and (data.len % 4) == 0) {
                    const win = self.backplaneWindowBase();
                    const base_off: u32 = addr & 0x07fff;
                    var i: usize = 0;
                    while (i < data.len) : (i += 4) {
                        const bp_addr = win + ((base_off + @as(u32, @intCast(i))) & 0x07fff);
                        const word = std.mem.readInt(u32, data[i..][0..4], .little);
                        self.writeBackplane32(bp_addr, word);
                    }
                } else {
                    for (data, 0..) |b, i| {
                        const a: u17 = if (incr_addr) addr +| @as(u17, @intCast(i)) else addr;
                        self.writeFunc1Byte(a, b);
                    }
                }
            },
            2 => {
                self.writeFunc2Frame(data);
            },
            else => {},
        }
    }

    // -------------------------------------------------------------------------
    // Function 0: CCCR, FBR1, FBR2, CIS Tuples
    // -------------------------------------------------------------------------

    fn readFunc0Byte(self: *const Cyw43430, addr: u17) u8 {
        return switch (addr) {
            0x00 => 0x32, // SDIO rev 3.0, CCCR rev 2.0
            0x01 => 0x02, // SD spec 2.0
            0x02 => self.cccr_ioex,
            0x03 => self.cccr_ioex, // IORx: enabled functions are immediately ready
            0x04 => self.cccr_ienx,
            0x05 => if ((self.sdio_intstatus & self.sdio_hostintmask) != 0) @as(u8, 0x02) else 0x00,
            0x06 => 0x00, // ABORT
            0x07 => self.cccr_bus_if,
            0x08 => 0x17, // CAPS: SMB | LSC | 4BLS | S4MI
            0x09 => 0x00, // Common CIS pointer = 0x001000
            0x0a => 0x10,
            0x0b => 0x00,
            0x12 => 0x01, // POWER: SMPC
            0x13 => self.cccr_speed | 0x01, // SPEED: SHS Always 1
            0xf0 => self.cccr_brcm_cardcap,
            0xf1 => self.cccr_brcm_cardctrl,
            0xf2 => self.cccr_brcm_sepint,

            // FBR1 (0x100..0x1ff)
            0x100 => 0x07, // Standard SDIO Function interface code
            0x109 => 0x00, // F1 CIS pointer = 0x001100
            0x10a => 0x11,
            0x10b => 0x00,
            0x110 => @truncate(self.fbr1_blksize),
            0x111 => @truncate(self.fbr1_blksize >> 8),

            // FBR2 (0x200..0x2ff)
            0x200 => 0x07, // Standard SDIO WLAN interface
            0x209 => 0x00, // F2 CIS pointer = 0x001200
            0x20a => 0x12,
            0x20b => 0x00,
            0x210 => @truncate(self.fbr2_blksize),
            0x211 => @truncate(self.fbr2_blksize >> 8),

            // Common CIS at 0x1000..0x10ff
            0x1000...0x10ff => readCisCommon(addr - 0x1000, self.chip.sdioDeviceId()),
            // Function 1 CIS at 0x1100..0x11ff
            0x1100...0x11ff => readCisFunc(addr - 0x1100, 64),
            // Function 2 CIS at 0x1200..0x12ff
            0x1200...0x12ff => readCisFunc(addr - 0x1200, 512),

            else => 0,
        };
    }

    fn writeFunc0Byte(self: *Cyw43430, addr: u17, val: u8) void {
        switch (addr) {
            0x02 => self.cccr_ioex = val,
            0x04 => self.cccr_ienx = val,
            0x06 => {
                if ((val & 0x08) != 0) self.reset(); // RES bit
            },
            0x07 => self.cccr_bus_if = val,
            0x13 => self.cccr_speed = (val & 0x0e) | 0x01,
            0xf0 => self.cccr_brcm_cardcap = val,
            0xf1 => self.cccr_brcm_cardctrl = val,
            0xf2 => self.cccr_brcm_sepint = val,
            0x110 => self.fbr1_blksize = (self.fbr1_blksize & 0xff00) | val,
            0x111 => self.fbr1_blksize = (self.fbr1_blksize & 0x00ff) | (@as(u16, val) << 8),
            0x210 => self.fbr2_blksize = (self.fbr2_blksize & 0xff00) | val,
            0x211 => self.fbr2_blksize = (self.fbr2_blksize & 0x00ff) | (@as(u16, val) << 8),
            else => {},
        }
    }

    fn readCisCommon(off: u17, device_id: u16) u8 {
        // CISTPL_MANFID (0x20, len 4): vendor 0x02d0 (Broadcom), device
        // CISTPL_FUNCE (0x22, len 4): type 0x00, fn0_blk_size=64 (0x0040), max_tran_speed=0x32 (25 MHz)
        // CISTPL_END (0xff)
        const cis_common = [_]u8{
            0x20, 0x04, 0xd0, 0x02, @truncate(device_id), @truncate(device_id >> 8),
            0x22, 0x04, 0x00, 0x40, 0x00,                 0x32,
            0xff,
        };
        if (off < cis_common.len) return cis_common[off];
        return 0xff;
    }

    fn readCisFunc(off: u17, max_blksize: u16) u8 {
        // CISTPL_FUNCE (0x22, len 0x2a = 42):
        //   byte 0: type = 0x01
        //   byte 1: function_info = 0x01
        //   byte 2: std_rev = 0x20 (SDIO 2.0)
        //   bytes 12..13: max_blksize (LE)
        //   bytes 28..29: enable_timeout_val = 10 (100 ms)
        if (off == 0) return 0x22;
        if (off == 1) return 0x2a;
        if (off >= 2 and off < 44) {
            const payload_idx = off - 2;
            return switch (payload_idx) {
                0 => 0x01,
                1 => 0x01,
                2 => 0x20,
                12 => @truncate(max_blksize),
                13 => @truncate(max_blksize >> 8),
                28 => 0x0a,
                29 => 0x00,
                else => 0x00,
            };
        }
        return 0xff; // CISTPL_END
    }

    // -------------------------------------------------------------------------
    // Function 1: Backplane Window & Control Registers
    // -------------------------------------------------------------------------

    fn readFunc1Byte(self: *Cyw43430, addr: u17) u8 {
        if (addr >= 0x10000) {
            return switch (addr) {
                SBSDIO_FUNC1_SBADDRLOW => self.sbaddr_low,
                SBSDIO_FUNC1_SBADDRMID => self.sbaddr_mid,
                SBSDIO_FUNC1_SBADDRHIGH => self.sbaddr_high,
                SBSDIO_FUNC1_FRAMECTRL => self.func1_framectrl,
                SBSDIO_FUNC1_CHIPCLKCSR => self.func1_chipclkcsr,
                SBSDIO_FUNC1_SDIOPULLUP => self.func1_sdiopullup,
                SBSDIO_FUNC1_WFRAMEBCLO,
                SBSDIO_FUNC1_WFRAMEBCHI,
                SBSDIO_FUNC1_RFRAMEBCLO,
                SBSDIO_FUNC1_RFRAMEBCHI,
                => 0,
                SBSDIO_FUNC1_MESBUSYCTRL => self.func1_mesbusyctrl,
                SBSDIO_FUNC1_WAKEUPCTRL => self.func1_wakeupctrl,
                SBSDIO_FUNC1_SLEEPCSR => self.func1_sleepcsr,
                else => 0,
            };
        }
        const bp_addr = self.backplaneWindowBase() + (@as(u32, addr) & 0x07fff);
        const word = self.readBackplane32(bp_addr & ~@as(u32, 3));
        const shift: u5 = @intCast((bp_addr & 3) * 8);
        return @truncate(word >> shift);
    }

    fn writeFunc1Byte(self: *Cyw43430, addr: u17, val: u8) void {
        if (addr >= 0x10000) {
            switch (addr) {
                SBSDIO_FUNC1_SBADDRLOW => self.sbaddr_low = val & 0x80,
                SBSDIO_FUNC1_SBADDRMID => self.sbaddr_mid = val,
                SBSDIO_FUNC1_SBADDRHIGH => self.sbaddr_high = val,
                SBSDIO_FUNC1_FRAMECTRL => self.func1_framectrl = val,
                SBSDIO_FUNC1_CHIPCLKCSR => {
                    if (val == 0) {
                        self.func1_chipclkcsr = 0;
                    } else {
                        self.func1_chipclkcsr = val | SBSDIO_ALP_AVAIL | SBSDIO_HT_AVAIL;
                    }
                },
                SBSDIO_FUNC1_SDIOPULLUP => self.func1_sdiopullup = val,
                SBSDIO_FUNC1_MESBUSYCTRL => self.func1_mesbusyctrl = val,
                SBSDIO_FUNC1_WAKEUPCTRL => self.func1_wakeupctrl = val,
                SBSDIO_FUNC1_SLEEPCSR => {
                    if ((val & 0x01) != 0) {
                        self.func1_sleepcsr = val | 0x03; // KSO + DEVON
                    } else {
                        self.func1_sleepcsr = val & ~@as(u8, 0x02);
                    }
                },
                else => {},
            }
            return;
        }
        const bp_addr = self.backplaneWindowBase() + (@as(u32, addr) & 0x07fff);
        if (self.ramOffset(bp_addr, 1)) |off| {
            self.chip_ram[off] = val;
            return;
        }
        const aligned = bp_addr & ~@as(u32, 3);
        const shift: u5 = @intCast((bp_addr & 3) * 8);
        const mask = ~(@as(u32, 0xff) << shift);
        const old = self.readBackplane32(aligned);
        self.writeBackplane32(aligned, (old & mask) | (@as(u32, val) << shift));
    }

    pub fn readBackplane32(self: *const Cyw43430, addr: u32) u32 {
        if (self.ramOffset(addr, 4)) |off| {
            return std.mem.readInt(u32, self.chip_ram[off..][0..4], .little);
        }
        if (self.chip.hasCortexR4() and addr == 0) return self.cr4_reset_vector;

        // DMP EROM table at 0x18000800..0x18000900
        if (addr >= EROM_BASE and addr < EROM_BASE + 0x100) {
            return self.readEromWord((addr - EROM_BASE) / 4);
        }

        // ChipCommon (0x18000000..0x18000fff)
        if (addr >= CC_BASE and addr < CC_BASE + 0x1000) {
            return switch (addr - CC_BASE) {
                0x000 => (1 << 28) | (@as(u32, self.chip.rev()) << 16) | self.chip.id(), // SOCI_AI (1<<28) | rev | chip
                0x004 => 0x10000000, // CC_CAP_PMU
                0x0fc => EROM_BASE, // eromptr
                0x190 => 0x00000000, // clk_ctl_st
                0x604 => 17, // pmucapabilities (pmurev = 17)
                0x648 => 0, // sr_control1 = 0 (disable Save-Restore)
                else => 0,
            };
        }

        // SDIO Device core (0x18002000..0x18002fff)
        if (addr >= SDIO_BASE and addr < SDIO_BASE + 0x1000) {
            return switch (addr - SDIO_BASE) {
                0x000 => 0, // corecontrol
                0x004 => 0, // corestatus
                0x020 => self.sdio_intstatus,
                0x024 => self.sdio_hostintmask,
                0x028 => 0, // intmask
                0x02c => 0, // sbintstatus
                0x030 => 0, // sbintmask
                0x040 => self.sdio_tosbmailbox,
                0x044 => 0, // tohostmailbox
                0x048 => self.sdio_tosbmailboxdata,
                0x04c => self.sdio_tohostmailboxdata,
                else => 0,
            };
        }

        // ARM CR4 core: one bank of TCM, (99 + 1) * 8 KiB = 800 KiB
        if (self.chip.hasCortexR4() and addr >= ARM_BASE and addr < ARM_BASE + 0x1000) {
            return switch (addr - ARM_BASE) {
                0x004 => 1, // corecapabilities: 1 bank A, 0 bank B
                0x040 => self.cr4_bankidx,
                0x044 => 99, // bankinfo
                else => 0,
            };
        }

        // SOCRAM core (0x18004000..0x18004fff)
        if (!self.chip.hasCortexR4() and addr >= SOCRAM_BASE and addr < SOCRAM_BASE + 0x1000) {
            return switch (addr - SOCRAM_BASE) {
                0x000 => (1 << 4), // coreinfo: 1 bank (MEM_BMSHIFT = 4)
                0x010 => self.socram_bankidx,
                0x040 => 63, // bankinfo: (63 + 1) * 8192 = 512 KiB
                0x044 => self.socram_bankpda,
                else => 0,
            };
        }

        // AI Core Wrappers (0x18100000..0x18104fff)
        if (addr >= CC_WRAP and addr < SOCRAM_WRAP + 0x1000) {
            const idx = (addr - CC_WRAP) / 0x1000;
            const off = addr & 0xfff;
            if (idx < 5) {
                return switch (off) {
                    0x408 => self.wrap_ioctl[idx], // BCMA_IOCTL
                    0x800 => self.wrap_reset[idx], // BCMA_RESET_CTL
                    else => 0,
                };
            }
        }

        return 0;
    }

    pub fn writeBackplane32(self: *Cyw43430, addr: u32, val: u32) void {
        if (self.ramOffset(addr, 4)) |off| {
            std.mem.writeInt(u32, self.chip_ram[off..][0..4], val, .little);
            return;
        }
        if (self.chip.hasCortexR4() and addr == 0) {
            self.cr4_reset_vector = val;
            return;
        }
        if (self.chip.hasCortexR4() and addr >= ARM_BASE and addr < ARM_BASE + 0x1000) {
            if (addr - ARM_BASE == 0x040) self.cr4_bankidx = val;
            return;
        }

        // SDIO Device core (0x18002000..0x18002fff)
        if (addr >= SDIO_BASE and addr < SDIO_BASE + 0x1000) {
            switch (addr - SDIO_BASE) {
                0x020 => {
                    // intstatus is write-1-to-clear
                    self.sdio_intstatus &= ~val;
                },
                0x024 => self.sdio_hostintmask = val,
                0x040 => {
                    self.sdio_tosbmailbox = val;
                    // SMB_DEV_INT (1<<3): host informs firmware via mailbox
                    if ((val & (1 << 3)) != 0) {
                        self.sdio_intstatus |= I_HMB_SW_MASK_ACK;
                    }
                },
                0x048 => self.sdio_tosbmailboxdata = val,
                else => {},
            }
            return;
        }

        // SOCRAM core (0x18004000..0x18004fff)
        if (!self.chip.hasCortexR4() and addr >= SOCRAM_BASE and addr < SOCRAM_BASE + 0x1000) {
            switch (addr - SOCRAM_BASE) {
                0x010 => self.socram_bankidx = val,
                0x044 => self.socram_bankpda = val,
                else => {},
            }
            return;
        }

        // AI Core Wrappers (0x18100000..0x18104fff)
        if (addr >= CC_WRAP and addr < SOCRAM_WRAP + 0x1000) {
            const idx = (addr - CC_WRAP) / 0x1000;
            const off = addr & 0xfff;
            if (idx < 5) {
                switch (off) {
                    0x408 => self.wrap_ioctl[idx] = val,
                    0x800 => self.wrap_reset[idx] = val,
                    else => {},
                }
                if (idx == 3) self.updateArm();
            }
            return;
        }
    }

    const I_HMB_SW_MASK_ACK: u32 = I_HMB_HOST_INT;

    const ARMCR4_IOCTL_CPUHALT: u32 = 0x20;

    /// The ARM runs once out of reset (BCMA_RESET_CTL clear) and, for the Cortex-R4, with
    /// CPUHALT clear in its wrapper's BCMA_IOCTL. Starting it starts the downloaded firmware,
    /// which signals HMB_DATA_FWREADY.
    fn updateArm(self: *Cyw43430) void {
        const running = (self.wrap_reset[3] & 1) == 0 and
            (!self.chip.hasCortexR4() or (self.wrap_ioctl[3] & ARMCR4_IOCTL_CPUHALT) == 0);
        if (running and !self.arm_running) {
            self.readFirmwareVersion();
            self.publishShared();
            self.sdio_tohostmailboxdata = 0x00040008;
            self.sdio_intstatus |= I_HMB_HOST_INT;
        }
        self.arm_running = running;
    }

    /// Builds the `ver` reply ("wl0: Aug 29 2023 01:51:02 version 7.45.265 (28bca26 CY)
    /// FWID 01-b677b91b") from the trailer firmware images end with ("... Version: 7.45.265
    /// (28bca26 CY) CRC: 68bafb8c Date: Tue 2023-08-29 01:51:02 PDT Ucode Ver: 1043.2170
    /// FWID 01-b677b91b"; some write "FWID: 01-...").
    fn readFirmwareVersion(self: *Cyw43430) void {
        self.fw_version_len = 0;
        const ram = self.chip_ram[0..self.chip.ramSize()];
        const v = std.mem.lastIndexOf(u8, ram, " Version: ") orelse return;
        const trailer = std.mem.sliceTo(ram[v + 10 .. @min(ram.len, v + 400)], 0);
        const ver_end = std.mem.indexOf(u8, trailer, " CRC: ") orelse return;
        const date_at = std.mem.indexOf(u8, trailer, " Date: ") orelse return;
        const fwid_at = std.mem.indexOf(u8, trailer, " FWID") orelse return;
        // "Tue 2023-08-29 01:51:02 PDT": weekday, date, time
        var date_it = std.mem.tokenizeScalar(u8, trailer[date_at + 7 ..], ' ');
        _ = date_it.next() orelse return;
        const ymd = date_it.next() orelse return;
        const time = date_it.next() orelse return;
        if (ymd.len != 10) return;
        const month = std.fmt.parseInt(u8, ymd[5..7], 10) catch return;
        if (month < 1 or month > 12) return;
        const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        var fwid_it = std.mem.tokenizeAny(u8, trailer[fwid_at + 5 ..], ": \n");
        const fwid = fwid_it.next() orelse return;
        const out = std.fmt.bufPrint(&self.fw_version, "wl0: {s} {s} {s} {s} version {s} FWID {s}\n", .{
            months[month - 1], ymd[8..10], ymd[0..4], time, trailer[0..ver_end], fwid,
        }) catch return;
        self.fw_version_len = out.len;
    }

    const SDPCM_SHARED_VERSION: u32 = 3;
    const SDPCM_SHARED_SIZE: u32 = 76; // struct sdpcm_shared
    const RTE_CONSOLE_SIZE: u32 = 156; // struct rte_console
    const CONSOLE_BUF_SIZE: u32 = 1024;

    /// What the firmware does as it starts: it lays out its `sdpcm_shared` structure, with an
    /// (empty) console log, and overwrites the last word of RAM, which held the NVRAM length
    /// token, with its address. `brcmfmac` reads it to find the console and trap information.
    fn publishShared(self: *Cyw43430) void {
        const ram_size = self.chip.ramSize();
        const base = self.chip.ramBase();
        // The NVRAM, ending in its length token (~words << 16 | words), sits at the top of RAM
        const token = std.mem.readInt(u32, self.chip_ram[ram_size - 4 ..][0..4], .little);
        const words = token & 0xffff;
        const nvram_len: u32 = if ((token >> 16) == (~words & 0xffff)) words * 4 + 4 else 4;
        if (nvram_len + SDPCM_SHARED_SIZE + RTE_CONSOLE_SIZE + CONSOLE_BUF_SIZE + 48 > ram_size) return;
        const console_buf = (ram_size - nvram_len - CONSOLE_BUF_SIZE) & ~@as(u32, 15);
        const console = (console_buf - RTE_CONSOLE_SIZE) & ~@as(u32, 15);
        const shared = (console - SDPCM_SHARED_SIZE) & ~@as(u32, 15);

        @memset(self.chip_ram[shared .. ram_size - nvram_len], 0);
        // struct rte_console: vcons_in, vcons_out, then rte_log_le { buf, buf_size, idx, buf }
        self.writeRam32(console + 8, base + console_buf);
        self.writeRam32(console + 12, CONSOLE_BUF_SIZE);
        self.writeRam32(console + 20, base + console_buf);
        // struct sdpcm_shared: flags, trap_addr, assert_exp_addr, assert_file_addr, assert_line,
        // console_addr, msgtrace_addr, tag[32], brpt_addr
        self.writeRam32(shared, SDPCM_SHARED_VERSION);
        self.writeRam32(shared + 20, base + console);
        self.writeRam32(ram_size - 4, base + shared);
    }

    /// Writes the RAM word at offset `off` (not a backplane address)
    fn writeRam32(self: *Cyw43430, off: u32, val: u32) void {
        std.mem.writeInt(u32, self.chip_ram[off..][0..4], val, .little);
    }

    fn eromCoreEntry(comptime core_id: u16, comptime rev: u8, comptime base: u32, comptime wrap: u32) [4]u32 {
        return .{
            // CI_A: mfg=0x4bf (Broadcom), id=core_id, DMP_DESC_COMPONENT (1)
            (0x4bf << 20) | (@as(u32, core_id) << 8) | 0x01,
            // CI_B: rev, nsw=1 (bit 19), nmw=0, nsp=1 (bit 9), DMP_DESC_COMPONENT (1)
            (@as(u32, rev) << 24) | (1 << 19) | (1 << 9) | 0x01,
            // Slave port address descriptor: base | SLAVE (0<<6) | 4K (0<<4) | DMP_DESC_ADDRESS (5)
            (base & 0xfffff000) | 0x05,
            // Slave wrapper address descriptor: wrap | SWRAP (2<<6 = 0x80) | 4K (0<<4) | DMP_DESC_ADDRESS (5)
            (wrap & 0xfffff000) | 0x80 | 0x05,
        };
    }

    fn readEromWord(self: *const Cyw43430, word_idx: u32) u32 {
        const common = eromCoreEntry(0x800, 49, CC_BASE, CC_WRAP) ++
            eromCoreEntry(0x812, 42, D11_BASE, D11_WRAP) ++
            eromCoreEntry(0x829, 12, SDIO_BASE, SDIO_WRAP);
        // ARM CM3 and SOCRAM, or an ARM CR4 with its own TCM
        const cm3_table = common ++
            eromCoreEntry(0x82a, 5, ARM_BASE, ARM_WRAP) ++
            eromCoreEntry(0x80e, 8, SOCRAM_BASE, SOCRAM_WRAP) ++
            [_]u32{0x0000000f}; // DMP_DESC_EOT
        const cr4_table = common ++
            eromCoreEntry(0x83e, 7, ARM_BASE, ARM_WRAP) ++
            [_]u32{0x0000000f};
        const erom_table: []const u32 = if (self.chip.hasCortexR4()) &cr4_table else &cm3_table;
        if (word_idx < erom_table.len) return erom_table[word_idx];
        return 0x0000000f;
    }

    // -------------------------------------------------------------------------
    // Function 2: SDPCM + BCDC Protocol
    // -------------------------------------------------------------------------

    fn queueRxFrame(self: *Cyw43430, channel: u8, payload: []const u8) void {
        if (self.rx_count >= MAX_RX_FRAMES) return;
        const hdr_len: usize = 12;
        const total_len: usize = @min(hdr_len + payload.len, MAX_FRAME_LEN);
        const body_len = total_len - hdr_len;

        var frame = &self.rx_frames[self.rx_tail];
        @memset(frame, 0);

        const len16: u16 = @intCast(total_len);
        std.mem.writeInt(u16, frame[0..2], len16, .little);
        std.mem.writeInt(u16, frame[2..4], ~len16, .little);

        // Software header (8 bytes)
        frame[4] = self.rx_seq;
        self.rx_seq +%= 1;
        frame[5] = channel & 0x0f;
        frame[6] = 0; // len_nxtfrm = 0 (each frame header read individually)
        frame[7] = hdr_len; // data_offset = 12
        frame[8] = 0; // flow control = 0
        // tx_seq_max: the host may send up to 32 frames past the last one it sent
        self.tx_window_end = self.host_tx_seq +% 32;
        frame[9] = self.tx_window_end;
        frame[10] = 0;
        frame[11] = 0;

        @memcpy(frame[hdr_len .. hdr_len + body_len], payload[0..body_len]);

        self.rx_frame_lens[self.rx_tail] = total_len;
        self.rx_tail = (self.rx_tail + 1) % MAX_RX_FRAMES;
        self.rx_count += 1;

        self.sdio_intstatus |= I_HMB_FRAME_IND;
    }

    fn readFunc2Frame(self: *Cyw43430, out: []u8) void {
        @memset(out, 0);
        if (self.rx_count == 0) {
            self.rx_frame_offset = 0;
            self.sdio_intstatus &= ~I_HMB_FRAME_IND;
            return;
        }

        const frame = &self.rx_frames[self.rx_head];
        const frame_len = self.rx_frame_lens[self.rx_head];
        const off = self.rx_frame_offset;

        if (off < frame_len) {
            const avail = frame_len - off;
            const copy_len = @min(avail, out.len);
            @memcpy(out[0..copy_len], frame[off .. off + copy_len]);
        }

        if (off == 0 and frame_len > out.len) {
            // brcmf_sdio_readframes read the initial BRCMF_FIRSTREAD (64 bytes);
            // the remainder of this frame will be read by the immediately following F2 read.
            self.rx_frame_offset = out.len;
        } else {
            // Frame completely consumed
            self.rx_frame_offset = 0;
            self.rx_head = (self.rx_head + 1) % MAX_RX_FRAMES;
            self.rx_count -= 1;
            if (self.joined != null) self.deliverNetworkFrames();
            if (self.rx_count == 0) {
                self.sdio_intstatus &= ~I_HMB_FRAME_IND;
            } else {
                self.sdio_intstatus |= I_HMB_FRAME_IND;
            }
        }
    }

    fn writeFunc2Frame(self: *Cyw43430, data: []const u8) void {
        if (data.len < 12) return;
        const frm_len = std.mem.readInt(u16, data[0..2], .little);
        const chk = std.mem.readInt(u16, data[2..4], .little);
        if ((frm_len ^ chk) != 0xffff or frm_len < 12 or frm_len > data.len) return;

        self.host_tx_seq = data[4];
        const channel = data[5] & 0x0f;
        const doff = data[7];
        if (doff < 12 or doff > frm_len) return;

        const payload = data[doff..frm_len];
        if (channel == SDPCM_CONTROL_CHANNEL) {
            self.handleBcdcControl(payload);
        } else if (channel == SDPCM_DATA_CHANNEL) {
            self.handleDataFrame(payload);
        }
    }

    /// A frame the host sends to the network: a BCDC data header (flags, priority, flags2,
    /// data_offset in words of signalling TLVs), then an 802.3 frame
    fn handleDataFrame(self: *Cyw43430, payload: []const u8) void {
        if (payload.len < 4) return;
        const start = 4 + @as(usize, payload[3]) * 4;
        if (self.joined != null and start + 14 <= payload.len) {
            self.net.handleTxFrame(payload[start..]);
            self.deliverNetworkFrames();
        }
        // No reply to carry a new transmit window: send it in an empty frame
        if (self.rx_count == 0 and (self.tx_window_end -% self.host_tx_seq) < 8) {
            self.queueRxFrame(SDPCM_DATA_CHANNEL, &.{});
        }
    }

    /// Moves the network's frames for the guest to the host, each after a BCDC data header
    fn deliverNetworkFrames(self: *Cyw43430) void {
        while (self.rx_count < MAX_RX_FRAMES) {
            const frame = self.net.peekRxFrame() orelse break;
            var buf: [4 + net_mod.VirtualNetwork.MAX_FRAME_LEN]u8 = undefined;
            buf[0..4].* = .{ 0x20, 0, 0, 0 }; // BCDC_PROTO_VER << 4, priority, ifidx 0, data_offset
            @memcpy(buf[4..][0..frame.len], frame);
            self.queueRxFrame(SDPCM_DATA_CHANNEL, buf[0 .. 4 + frame.len]);
            self.net.dropRxFrame();
        }
    }

    fn handleBcdcControl(self: *Cyw43430, dcmd: []const u8) void {
        if (dcmd.len < 16) return;
        const cmd = std.mem.readInt(u32, dcmd[0..4], .little);
        const len = std.mem.readInt(u32, dcmd[4..8], .little);
        var flags = std.mem.readInt(u32, dcmd[8..12], .little);
        const is_set = (flags & BCDC_DCMD_SET) != 0;
        const body = dcmd[16..];

        var resp_buf: [1536]u8 = @splat(0);
        const max_body = @min(@as(usize, len & 0xffff), resp_buf.len - 16);
        const copy_in = @min(body.len, max_body);
        @memcpy(resp_buf[16 .. 16 + copy_in], body[0..copy_in]);

        var status: i32 = 0;
        var out_body_len: usize = max_body;
        var escan_params: ?[]const u8 = null;
        var join: ?JoinRequest = null;
        var leave = false;

        switch (cmd) {
            BRCMF_C_GET_VAR, BRCMF_C_SET_VAR => {
                const var_name = std.mem.sliceTo(body, 0);
                const arg_off = @min(var_name.len + 1, body.len);
                const arg = body[arg_off..];
                const dst = resp_buf[16 .. 16 + max_body];

                if (!is_set and cmd == BRCMF_C_GET_VAR) {
                    @memset(dst, 0);
                    if (std.mem.eql(u8, var_name, "cur_etheraddr")) {
                        if (dst.len >= 6) @memcpy(dst[0..6], &self.mac_address);
                        out_body_len = @max(max_body, 6);
                    } else if (std.mem.eql(u8, var_name, "ver")) {
                        const fallback = "wl0: Oct 23 2017 03:55:53 version 7.45.98.94 (r666254 CY) FWID 01-e58d219f\n";
                        const ver_str = if (self.fw_version_len != 0) self.fw_version[0..self.fw_version_len] else fallback;
                        const n = @min(dst.len, ver_str.len);
                        @memcpy(dst[0..n], ver_str[0..n]);
                    } else if (std.mem.eql(u8, var_name, "clmver")) {
                        const clm_str = "API: 12.2\n\x00";
                        const n = @min(dst.len, clm_str.len);
                        @memcpy(dst[0..n], clm_str[0..n]);
                    } else if (std.mem.eql(u8, var_name, "cap")) {
                        const cap_str = "sta ap mbss \x00";
                        const n = @min(dst.len, cap_str.len);
                        @memcpy(dst[0..n], cap_str[0..n]);
                    } else if (std.mem.eql(u8, var_name, "wlc_ver")) {
                        // struct brcmf_wlc_version_le { u16 desc_ver=1, ver_major=12, ver_minor=0, ... }
                        if (dst.len >= 8) {
                            std.mem.writeInt(u16, dst[0..2], 1, .little);
                            std.mem.writeInt(u16, dst[2..4], 12, .little);
                            std.mem.writeInt(u16, dst[4..6], 0, .little);
                            std.mem.writeInt(u16, dst[6..8], 0, .little);
                        }
                    } else if (std.mem.eql(u8, var_name, "nmode") or
                        std.mem.eql(u8, var_name, "rxchain"))
                    {
                        if (dst.len >= 4) std.mem.writeInt(u32, dst[0..4], 1, .little);
                    } else if (std.mem.eql(u8, var_name, "bw_cap")) {
                        // Queried with the band (WLC_BAND_5G = 1, WLC_BAND_2G = 2) as the argument
                        const band: u32 = if (arg.len >= 4) std.mem.readInt(u32, arg[0..4], .little) else 2;
                        if (dst.len >= 4) std.mem.writeInt(u32, dst[0..4], self.bandBwCap(band), .little);
                    } else if (std.mem.eql(u8, var_name, "vhtmode")) {
                        if (dst.len >= 4) std.mem.writeInt(u32, dst[0..4], @intFromBool(self.chip.bandwidths(1) & 4 != 0), .little);
                    } else if (std.mem.eql(u8, var_name, "per_chan_info") or
                        std.mem.eql(u8, var_name, "ampdu_ba_wsize") or
                        std.mem.eql(u8, var_name, "mpc"))
                    {
                        if (dst.len >= 4) std.mem.writeInt(u32, dst[0..4], 0, .little);
                    } else if (std.mem.eql(u8, var_name, "chanspec")) {
                        if (dst.len >= 4) std.mem.writeInt(u32, dst[0..4], 0x1001, .little);
                    } else if (std.mem.eql(u8, var_name, "qtxpower")) {
                        if (dst.len >= 4) std.mem.writeInt(u32, dst[0..4], 80, .little); // 20 dBm (80 qdBm)
                    } else if (std.mem.eql(u8, var_name, "chanspecs")) {
                        // struct brcmf_chanspec_list { __le32 count; __le32 element[]; }. A chanspec
                        // argument with a bandwidth (brcmf_enable_bw40_2g passes 2.4 GHz 40 MHz,
                        // 0x1800) asks for just that band and width.
                        const q_chspec: u16 = if (arg.len >= 2) std.mem.readInt(u16, arg[0..2], .little) else 0;
                        const filter: ?u16 = if ((q_chspec & 0x3800) != 0) q_chspec & 0xf800 else null;
                        var list: [64]u16 = undefined;
                        const all = self.chanspecs(&list);
                        var count: usize = 0;
                        for (all) |chanspec| {
                            if (filter) |f| if ((chanspec & 0xf800) != f) continue;
                            if (4 + (count + 1) * 4 > dst.len) break;
                            std.mem.writeInt(u32, dst[4 + count * 4 ..][0..4], chanspec, .little);
                            count += 1;
                        }
                        if (dst.len >= 4) std.mem.writeInt(u32, dst[0..4], @intCast(count), .little);
                    } else if (std.mem.eql(u8, var_name, "country")) {
                        if (dst.len >= 12) {
                            @memcpy(dst[0..4], &self.country_abrev);
                            std.mem.writeInt(i32, dst[4..8], self.country_rev, .little);
                            @memcpy(dst[8..12], &self.country_ccode);
                        }
                    } else if (std.mem.eql(u8, var_name, "event_msgs")) {
                        const n = @min(dst.len, self.event_msgs.len);
                        @memcpy(dst[0..n], self.event_msgs[0..n]);
                    } else if (std.mem.eql(u8, var_name, "assoc_info")) {
                        // struct brcmf_cfg80211_assoc_ielen_le { req_len, resp_len }: no IEs kept
                    } else if (std.mem.eql(u8, var_name, "sta_info") and self.joined != null) {
                        self.writeStaInfo(dst);
                        out_body_len = @min(max_body, STA_INFO_SIZE);
                    } else {
                        // Unsupported optional feature queries return -BRCMF_FW_UNSUPPORTED (-23)
                        status = -23;
                        flags |= BCDC_DCMD_ERROR;
                    }
                } else {
                    // SET_VAR
                    if (std.mem.eql(u8, var_name, "cur_etheraddr")) {
                        if (arg.len >= 6) @memcpy(&self.mac_address, arg[0..6]);
                    } else if (std.mem.eql(u8, var_name, "event_msgs")) {
                        const n = @min(arg.len, self.event_msgs.len);
                        @memcpy(self.event_msgs[0..n], arg[0..n]);
                    } else if (std.mem.eql(u8, var_name, "country")) {
                        if (arg.len >= 12) {
                            @memcpy(&self.country_abrev, arg[0..4]);
                            self.country_rev = std.mem.readInt(i32, arg[4..8], .little);
                            @memcpy(&self.country_ccode, arg[8..12]);
                        }
                    } else if (std.mem.eql(u8, var_name, "bw_cap")) {
                        // struct brcmf_fil_bwcap_le { __le32 band; __le32 bw_cap; }
                        if (arg.len >= 8) {
                            const band = std.mem.readInt(u32, arg[0..4], .little);
                            const bw = std.mem.readInt(u32, arg[4..8], .little);
                            // A width the chip lacks is BCME_BADARG: brcmfmac asks for 40 MHz at
                            // 2.4 GHz on every chip and only keeps HT40 there if this succeeds
                            const supported = self.chip.bandwidths(band);
                            if ((band == 1 or band == 2) and bw != 0 and (bw & ~supported) == 0) {
                                self.bw_cap[band - 1] = bw;
                            } else {
                                status = -2;
                                flags |= BCDC_DCMD_ERROR;
                            }
                        }
                    } else if (std.mem.eql(u8, var_name, "escan")) {
                        escan_params = arg;
                    } else if (std.mem.eql(u8, var_name, "join")) {
                        // struct brcmf_ext_join_params_le: ssid_le, scan_le, then assoc_le
                        // (bssid at 56, chanspec_num at 64, chanspec_list at 68)
                        join = JoinRequest.parse(arg, 56);
                    } else if (std.mem.eql(u8, var_name, "bus:rxglom") or
                        std.mem.eql(u8, var_name, "ulp_sdioctrl") or
                        std.mem.eql(u8, var_name, "pfn") or
                        std.mem.eql(u8, var_name, "pfn_macaddr") or
                        std.mem.eql(u8, var_name, "mfp") or
                        std.mem.eql(u8, var_name, "tdls_enable"))
                    {
                        // Disable SDPCM glomming and optional offloads cleanly
                        status = -23;
                        flags |= BCDC_DCMD_ERROR;
                    }
                    out_body_len = 0;
                }
            },
            BRCMF_C_GET_REVINFO => {
                const dst = resp_buf[16 .. 16 + max_body];
                @memset(dst, 0);
                if (dst.len >= 48) {
                    std.mem.writeInt(u32, dst[0..4], 0x14e4, .little); // vendorid
                    std.mem.writeInt(u32, dst[4..8], self.chip.sdioDeviceId(), .little); // deviceid
                    std.mem.writeInt(u32, dst[8..12], 1, .little); // radiorev
                    std.mem.writeInt(u32, dst[12..16], self.chip.rev(), .little); // chiprev
                    std.mem.writeInt(u32, dst[20..24], 42, .little); // corerev
                    std.mem.writeInt(u32, dst[44..48], self.chip.id(), .little); // chipnum
                }
            },
            BRCMF_C_SET_SSID => {
                // struct brcmf_join_params: ssid_le, then params_le (bssid at 36, chanspec_num at
                // 44, chanspec_list at 48)
                join = JoinRequest.parse(body, 36);
                out_body_len = 0;
            },
            BRCMF_C_DISASSOC => {
                leave = true;
                out_body_len = 0;
            },
            BRCMF_C_GET_BSS_INFO, BRCMF_C_GET_BSSID, BRCMF_C_GET_RSSI, BRCMF_C_GET_RATE => {
                const dst = resp_buf[16 .. 16 + max_body];
                @memset(dst, 0);
                if (self.joined) |ap| {
                    switch (cmd) {
                        // A length word, then struct brcmf_bss_info_le
                        BRCMF_C_GET_BSS_INFO => if (dst.len >= 4 + BSS_INFO_SIZE + 64) {
                            const n = self.writeBssInfo(ap, dst[4..]);
                            std.mem.writeInt(u32, dst[0..4], n, .little);
                        },
                        BRCMF_C_GET_BSSID => if (dst.len >= 6) @memcpy(dst[0..6], &ap.bssid),
                        // struct brcmf_scb_val_le { val, ea }
                        BRCMF_C_GET_RSSI => if (dst.len >= 4) std.mem.writeInt(i32, dst[0..4], ap.rssi, .little),
                        // In 500 kb/s units: 54 Mb/s
                        BRCMF_C_GET_RATE => if (dst.len >= 4) std.mem.writeInt(u32, dst[0..4], 108, .little),
                        else => unreachable,
                    }
                } else {
                    status = -17; // BCME_NOTASSOCIATED
                    flags |= BCDC_DCMD_ERROR;
                }
            },
            BRCMF_C_GET_VERSION => {
                const dst = resp_buf[16 .. 16 + max_body];
                if (dst.len >= 4) {
                    std.mem.writeInt(u32, dst[0..4], 2, .little); // BRCMU_D11AC_IOTYPE = 2
                }
            },
            BRCMF_C_GET_BANDLIST => {
                const dst = resp_buf[16 .. 16 + max_body];
                @memset(dst, 0);
                if (self.chip.dualBand() and dst.len >= 12) {
                    std.mem.writeInt(u32, dst[0..4], 2, .little); // 2 bands
                    std.mem.writeInt(u32, dst[4..8], 1, .little); // WLC_BAND_5G = 1
                    std.mem.writeInt(u32, dst[8..12], 2, .little); // WLC_BAND_2G = 2
                } else if (dst.len >= 8) {
                    std.mem.writeInt(u32, dst[0..4], 1, .little); // 1 band
                    std.mem.writeInt(u32, dst[4..8], 2, .little); // WLC_BAND_2G = 2
                }
            },
            BRCMF_C_GET_VALID_CHANNELS => {
                const dst = resp_buf[16 .. 16 + max_body];
                @memset(dst, 0);
                if (dst.len >= 48) {
                    std.mem.writeInt(u32, dst[0..4], 11, .little);
                    for (0..11) |ch_idx| {
                        std.mem.writeInt(u32, dst[4 + ch_idx * 4 ..][0..4], @intCast(ch_idx + 1), .little);
                    }
                }
            },
            else => {
                if (!is_set) {
                    @memset(resp_buf[16 .. 16 + max_body], 0);
                } else {
                    out_body_len = 0;
                }
            },
        }

        std.mem.writeInt(u32, resp_buf[0..4], cmd, .little);
        std.mem.writeInt(u32, resp_buf[4..8], @intCast(out_body_len), .little);
        std.mem.writeInt(u32, resp_buf[8..12], flags, .little);
        std.mem.writeInt(i32, resp_buf[12..16], status, .little);

        self.queueRxFrame(SDPCM_CONTROL_CHANNEL, resp_buf[0 .. 16 + out_body_len]);

        if (escan_params) |params| self.runEscan(params);
        if (join) |req| self.runJoin(req);
        if (leave) self.leaveNetwork();
    }

    /// The channel widths enabled in `band`: what the host set with `bw_cap`, or all supported
    fn bandBwCap(self: *const Cyw43430, band: u32) u32 {
        const supported = self.chip.bandwidths(band);
        if (band == 1 or band == 2) {
            if (self.bw_cap[band - 1]) |bw| return bw & supported;
        }
        return supported;
    }

    /// The D11AC chanspecs the chip offers (center channel | sideband | width | band): the
    /// 2.4 GHz channels 1..11 and, on dual-band chips, the 5 GHz channels outside DFS. All the
    /// 20 MHz channels come first, then the 40 MHz and 80 MHz ones, in the order brcmfmac expects.
    fn chanspecs(self: *const Cyw43430, out: *[64]u16) []const u16 {
        const band_2g: u16 = 0x0000;
        const band_5g: u16 = 0xc000;
        const bw_20: u16 = 0x1000;
        const bw_40: u16 = 0x1800;
        const bw_80: u16 = 0x2000;
        const ch_5g = [_]u16{ 36, 40, 44, 48, 149, 153, 157, 161, 165 };
        const bw_2g = self.bandBwCap(2);
        const bw_5g = if (self.chip.dualBand()) self.bandBwCap(1) else 0;
        var n: usize = 0;
        if (bw_2g & 1 != 0) {
            for (1..12) |ch| {
                out[n] = band_2g | bw_20 | @as(u16, @intCast(ch));
                n += 1;
            }
        }
        if (bw_5g & 1 != 0) {
            for (ch_5g) |ch| {
                out[n] = band_5g | bw_20 | ch;
                n += 1;
            }
        }
        // 40 MHz: the control channel is the lower (sideband L, 0x000) or upper (U, 0x100)
        // 20 MHz half, 2 channels below or above the center
        if (bw_2g & 2 != 0) {
            for (3..10) |center| {
                for ([_]u16{ 0x000, 0x100 }) |sb| {
                    out[n] = band_2g | bw_40 | sb | @as(u16, @intCast(center));
                    n += 1;
                }
            }
        }
        if (bw_5g & 2 != 0) {
            for ([_]u16{ 38, 46, 151, 159 }) |center| {
                for ([_]u16{ 0x000, 0x100 }) |sb| {
                    out[n] = band_5g | bw_40 | sb | center;
                    n += 1;
                }
            }
        }
        // 80 MHz: control channel 6, 2 below or 2, 6 above the center (sidebands LL..UU)
        if (bw_5g & 4 != 0) {
            for ([_]u16{ 42, 155 }) |center| {
                for ([_]u16{ 0x000, 0x100, 0x200, 0x300 }) |sb| {
                    out[n] = band_5g | bw_80 | sb | center;
                    n += 1;
                }
            }
        }
        return out[0..n];
    }

    const BRCMF_E_ESCAN_RESULT: u32 = 69;
    const BRCMF_E_STATUS_SUCCESS: u32 = 0;
    const BRCMF_E_STATUS_PARTIAL: u32 = 8;
    const BSS_INFO_SIZE: usize = 128; // struct brcmf_bss_info_le, before its IEs
    const ESCAN_RESULT_FIXED: usize = 12; // struct brcmf_escan_result_le, before bss_info_le

    /// One radio of the emulated access point: an open, legacy (802.11a/g) BSS
    const AccessPoint = struct {
        bssid: [6]u8,
        channel: u8,
        band_5g: bool,
        rssi: i16,
    };

    /// The access point's radios this chip can hear: 2.4 GHz channel 6 and, on dual-band chips,
    /// 5 GHz channel 36, each with a locally administered BSSID derived from the SSID
    fn accessPoints(self: *const Cyw43430, out: *[2]AccessPoint) []const AccessPoint {
        if (self.ap_ssid_len == 0) return out[0..0];
        var h: u64 = 0xcbf2_9ce4_8422_2325;
        for (self.ap_ssid[0..self.ap_ssid_len]) |c| h = (h ^ c) *% 0x0000_0100_0000_01b3;
        var bssid: [6]u8 = undefined;
        for (&bssid, 0..) |*b, i| b.* = @truncate(h >> @intCast(i * 8));
        bssid[0] = (bssid[0] & 0xfc) | 0x02; // locally administered, unicast
        bssid[5] &= 0xfe;
        out[0] = .{ .bssid = bssid, .channel = 6, .band_5g = false, .rssi = -45 };
        if (!self.chip.dualBand()) return out[0..1];
        bssid[5] |= 1;
        out[1] = .{ .bssid = bssid, .channel = 36, .band_5g = true, .rssi = -52 };
        return out[0..2];
    }

    /// Handles `escan` (struct brcmf_escan_params_le: version, action, sync_id, then
    /// struct brcmf_scan_params_le): reports each access point radio on a requested channel
    /// whose SSID was asked for, as a BRCMF_E_ESCAN_RESULT partial result, then completes.
    fn runEscan(self: *Cyw43430, params: []const u8) void {
        const sync_id: u16 = if (params.len >= 8) std.mem.readInt(u16, params[6..8], .little) else 0;
        // scan_params_le: ssid_le at 8, ..., channel_num at 68 (channels low 16 bits, SSIDs high),
        // then the channel chanspecs and, 32-bit aligned, the SSIDs (struct brcmf_ssid_le)
        const channel_num: u32 = if (params.len >= 72) std.mem.readInt(u32, params[68..72], .little) else 0;
        const n_channels: usize = channel_num & 0xffff;
        const n_ssids: usize = channel_num >> 16;
        const ssids_at = std.mem.alignForward(usize, 72 + n_channels * 2, 4);

        var aps: [2]AccessPoint = undefined;
        for (self.accessPoints(&aps)) |ap| {
            if (n_channels != 0) {
                var listed = false;
                for (0..n_channels) |i| {
                    if (72 + i * 2 + 2 > params.len) break;
                    const chanspec = std.mem.readInt(u16, params[72 + i * 2 ..][0..2], .little);
                    if ((chanspec & 0xff) == ap.channel) listed = true;
                }
                if (!listed) continue;
            }
            if (n_ssids != 0) {
                var wanted = false;
                for (0..n_ssids) |i| {
                    const at = ssids_at + i * 36;
                    if (at + 36 > params.len) break;
                    if (self.ssidMatches(params[at..][0..36])) wanted = true;
                }
                if (!wanted) continue;
            } else if (params.len >= 44 and !self.ssidMatches(params[8..44])) {
                continue;
            }
            self.queueEscanResult(sync_id, ap);
        }
        self.queueEvent(BRCMF_E_ESCAN_RESULT, BRCMF_E_STATUS_SUCCESS, &.{});
    }

    const BRCMF_E_SET_SSID: u32 = 0;
    const BRCMF_E_AUTH: u32 = 3;
    const BRCMF_E_ASSOC: u32 = 7;
    const BRCMF_E_LINK: u32 = 16;
    const BRCMF_E_STATUS_NO_NETWORKS: u32 = 3;
    const BRCMF_EVENT_MSG_LINK: u16 = 0x01;
    const STA_INFO_SIZE: usize = 84; // struct brcmf_sta_info_le, version 3

    /// A join (SET_SSID, or the `join` iovar): an SSID, then a BSSID (broadcast or zero for any)
    /// and the chanspecs to look on (none for all)
    const JoinRequest = struct {
        ssid_le: [36]u8,
        bssid: [6]u8,
        chanspecs: [4]u16,
        n_chanspecs: usize,

        fn parse(params: []const u8, bssid_at: usize) ?JoinRequest {
            if (params.len < 36) return null;
            var req: JoinRequest = .{ .ssid_le = params[0..36].*, .bssid = @splat(0xff), .chanspecs = undefined, .n_chanspecs = 0 };
            if (params.len >= bssid_at + 6) req.bssid = params[bssid_at..][0..6].*;
            const num_at = bssid_at + 8;
            if (params.len >= num_at + 4) {
                const n = std.mem.readInt(u32, params[num_at..][0..4], .little);
                for (0..@min(n, req.chanspecs.len)) |i| {
                    const at = num_at + 4 + i * 2;
                    if (at + 2 > params.len) break;
                    req.chanspecs[req.n_chanspecs] = std.mem.readInt(u16, params[at..][0..2], .little);
                    req.n_chanspecs += 1;
                }
            }
            return req;
        }
    };

    /// Joins the access point radio the request picks (the strongest, given a choice). The
    /// network is open, so the firmware authenticates and associates by itself: it reports
    /// BRCMF_E_AUTH, BRCMF_E_ASSOC, link up and BRCMF_E_SET_SSID, or BRCMF_E_SET_SSID failing
    /// with no networks.
    fn runJoin(self: *Cyw43430, req: JoinRequest) void {
        const any_bssid = std.mem.allEqual(u8, &req.bssid, 0xff) or std.mem.allEqual(u8, &req.bssid, 0);
        var aps: [2]AccessPoint = undefined;
        var best: ?AccessPoint = null;
        if (std.mem.readInt(u32, req.ssid_le[0..4], .little) != 0 and self.ssidMatches(&req.ssid_le)) {
            for (self.accessPoints(&aps)) |ap| {
                if (!any_bssid and !std.mem.eql(u8, &req.bssid, &ap.bssid)) continue;
                if (req.n_chanspecs != 0) {
                    var listed = false;
                    for (req.chanspecs[0..req.n_chanspecs]) |cs| {
                        if ((cs & 0xff) == ap.channel) listed = true;
                    }
                    if (!listed) continue;
                }
                if (best == null or ap.rssi > best.?.rssi) best = ap;
            }
        }
        if (self.joined) |old| self.queueLinkEvent(BRCMF_E_LINK, 0, 0, old.bssid);
        self.joined = best;
        const ap = best orelse {
            self.queueLinkEvent(BRCMF_E_SET_SSID, BRCMF_E_STATUS_NO_NETWORKS, 0, @splat(0));
            return;
        };
        self.queueLinkEvent(BRCMF_E_AUTH, BRCMF_E_STATUS_SUCCESS, 0, ap.bssid);
        self.queueLinkEvent(BRCMF_E_ASSOC, BRCMF_E_STATUS_SUCCESS, 0, ap.bssid);
        self.queueLinkEvent(BRCMF_E_LINK, BRCMF_E_STATUS_SUCCESS, BRCMF_EVENT_MSG_LINK, ap.bssid);
        self.queueLinkEvent(BRCMF_E_SET_SSID, BRCMF_E_STATUS_SUCCESS, 0, ap.bssid);
    }

    /// Disassociates (BRCMF_C_DISASSOC): the link goes down
    fn leaveNetwork(self: *Cyw43430) void {
        const ap = self.joined orelse return;
        self.joined = null;
        self.queueLinkEvent(BRCMF_E_LINK, BRCMF_E_STATUS_SUCCESS, 0, ap.bssid);
    }

    fn queueLinkEvent(self: *Cyw43430, event_type: u32, status: u32, flags: u16, addr: [6]u8) void {
        self.queueEventFrom(event_type, status, flags, addr, &.{});
    }

    /// The access point as a station seen from this one (struct brcmf_sta_info_le version 3):
    /// authenticated, associated and authorized
    fn writeStaInfo(self: *const Cyw43430, dst: []u8) void {
        const ap = self.joined orelse return;
        if (dst.len < STA_INFO_SIZE) return;
        @memset(dst[0..STA_INFO_SIZE], 0);
        std.mem.writeInt(u16, dst[0..2], 3, .little); // ver
        std.mem.writeInt(u16, dst[2..4], STA_INFO_SIZE, .little); // len
        std.mem.writeInt(u16, dst[4..6], if (ap.band_5g) 0x0001 else 0x0401, .little); // cap
        // flags: BRCMF_STA_AUTHE | BRCMF_STA_ASSOC | BRCMF_STA_AUTHO
        std.mem.writeInt(u32, dst[8..12], 0x08 | 0x10 | 0x20, .little);
        @memcpy(dst[16..22], &ap.bssid); // ea
    }

    /// Whether the access point answers to `ssid_le` (struct brcmf_ssid_le: length, SSID);
    /// an empty SSID is a wildcard
    fn ssidMatches(self: *const Cyw43430, ssid_le: *const [36]u8) bool {
        const len = std.mem.readInt(u32, ssid_le[0..4], .little);
        if (len == 0) return true;
        return len == self.ap_ssid_len and std.mem.eql(u8, ssid_le[4..][0..len], self.ap_ssid[0..len]);
    }

    fn queueEscanResult(self: *Cyw43430, sync_id: u16, ap: AccessPoint) void {
        var buf: [ESCAN_RESULT_FIXED + BSS_INFO_SIZE + 64]u8 = @splat(0);
        const bi_len = self.writeBssInfo(ap, buf[ESCAN_RESULT_FIXED..]);

        // struct brcmf_escan_result_le: buflen, version, sync_id, bss_count, bss_info_le
        const buflen: u32 = @intCast(ESCAN_RESULT_FIXED + bi_len);
        std.mem.writeInt(u32, buf[0..4], buflen, .little);
        std.mem.writeInt(u32, buf[4..8], 109, .little);
        std.mem.writeInt(u16, buf[8..10], sync_id, .little);
        std.mem.writeInt(u16, buf[10..12], 1, .little);
        self.queueEvent(BRCMF_E_ESCAN_RESULT, BRCMF_E_STATUS_PARTIAL, buf[0..buflen]);
    }

    /// Writes `ap`'s struct brcmf_bss_info_le, with its IEs, to the zeroed `bi`; returns its length
    fn writeBssInfo(self: *const Cyw43430, ap: AccessPoint, bi: []u8) u32 {
        const ssid = self.ap_ssid[0..self.ap_ssid_len];
        // Rates in 500 kb/s units, 0x80 marking the basic rates: 1, 2, 5.5, 11 Mb/s (basic) and
        // 6..54 Mb/s at 2.4 GHz; 6, 12, 24 Mb/s (basic) and 9..54 Mb/s at 5 GHz
        const rates: []const u8 = if (ap.band_5g)
            &.{ 0x8c, 0x12, 0x98, 0x24, 0xb0, 0x48, 0x60, 0x6c }
        else
            &.{ 0x82, 0x84, 0x8b, 0x96, 0x0c, 0x12, 0x18, 0x24, 0x30, 0x48, 0x60, 0x6c };

        // Information elements: SSID, Supported Rates (8 at most), DS Parameter Set (the
        // channel), Extended Supported Rates
        var ies = bi[BSS_INFO_SIZE..];
        var n: usize = 0;
        ies[n] = 0;
        ies[n + 1] = @intCast(ssid.len);
        @memcpy(ies[n + 2 ..][0..ssid.len], ssid);
        n += 2 + ssid.len;
        const basic = @min(rates.len, 8);
        ies[n] = 1;
        ies[n + 1] = @intCast(basic);
        @memcpy(ies[n + 2 ..][0..basic], rates[0..basic]);
        n += 2 + basic;
        ies[n] = 3;
        ies[n + 1] = 1;
        ies[n + 2] = ap.channel;
        n += 3;
        if (rates.len > basic) {
            ies[n] = 50;
            ies[n + 1] = @intCast(rates.len - basic);
            @memcpy(ies[n + 2 ..][0 .. rates.len - basic], rates[basic..]);
            n += 2 + rates.len - basic;
        }
        n = std.mem.alignForward(usize, n, 4);

        // struct brcmf_bss_info_le
        const bi_len: u32 = @intCast(BSS_INFO_SIZE + n);
        std.mem.writeInt(u32, bi[0..4], 109, .little); // BRCMF_BSS_INFO_VERSION
        std.mem.writeInt(u32, bi[4..8], bi_len, .little);
        @memcpy(bi[8..14], &ap.bssid);
        std.mem.writeInt(u16, bi[14..16], 100, .little); // beacon_period (TU)
        // capability: ESS, plus short slot time at 2.4 GHz; no privacy (an open network)
        std.mem.writeInt(u16, bi[16..18], if (ap.band_5g) 0x0001 else 0x0401, .little);
        bi[18] = @intCast(ssid.len);
        @memcpy(bi[19..][0..ssid.len], ssid);
        std.mem.writeInt(u32, bi[52..56], @intCast(rates.len), .little); // rateset.count
        @memcpy(bi[56..][0..rates.len], rates);
        const band: u16 = if (ap.band_5g) 0xc000 else 0x0000;
        std.mem.writeInt(u16, bi[72..74], band | 0x1000 | ap.channel, .little); // 20 MHz chanspec
        bi[76] = 1; // dtim_period
        std.mem.writeInt(i16, bi[78..80], ap.rssi, .little);
        bi[80] = @bitCast(@as(i8, -92)); // phy_noise
        bi[88] = ap.channel; // ctl_ch
        std.mem.writeInt(u16, bi[116..118], BSS_INFO_SIZE, .little); // ie_offset
        std.mem.writeInt(u32, bi[120..124], @intCast(n), .little); // ie_length
        std.mem.writeInt(u16, bi[124..126], @intCast(ap.rssi + 92), .little); // SNR
        return bi_len;
    }

    /// Queues a firmware event (BCDC header, ethernet header, struct brcm_ethhdr, then
    /// struct brcmf_event_msg_be followed by `data`) on the SDPCM event channel
    fn queueEvent(self: *Cyw43430, event_type: u32, status: u32, data: []const u8) void {
        self.queueEventFrom(event_type, status, 0, self.mac_address, data);
    }

    /// Queues a firmware event about `addr` (the peer, or this station)
    fn queueEventFrom(self: *Cyw43430, event_type: u32, status: u32, flags: u16, addr: [6]u8, data: []const u8) void {
        var evt: [76 + 512]u8 = @splat(0);
        if (data.len > evt.len - 76) return;

        // 1. struct brcmf_proto_bcdc_header (4 bytes)
        evt[0] = 0x20; // BCDC_PROTO_VER (2) << BCDC_FLAG_VER_SHIFT (4)
        evt[1] = 0x00; // priority
        evt[2] = 0x00; // flags2 (ifidx = 0)
        evt[3] = 0x00; // data_offset

        // 2. struct ethhdr (14 bytes at evt[4..18])
        @memcpy(evt[4..10], &self.mac_address); // h_dest
        @memcpy(evt[10..16], &self.mac_address); // h_source
        std.mem.writeInt(u16, evt[16..18], 0x886c, .big); // ETH_P_LINK_CTL

        // 3. struct brcm_ethhdr (10 bytes at evt[18..28])
        std.mem.writeInt(u16, evt[18..20], 32769, .big); // BCMILCP_SUBTYPE_VENDOR_LONG
        std.mem.writeInt(u16, evt[20..22], @intCast(54 + data.len), .big); // length
        evt[22] = 0; // version
        evt[23] = 0x00; // BRCM_OUI
        evt[24] = 0x10;
        evt[25] = 0x18;
        std.mem.writeInt(u16, evt[26..28], 1, .big); // BCMILCP_BCM_SUBTYPE_EVENT

        // 4. struct brcmf_event_msg_be (48 bytes at evt[28..76])
        std.mem.writeInt(u16, evt[28..30], 2, .big); // version = 2
        std.mem.writeInt(u16, evt[30..32], flags, .big);
        std.mem.writeInt(u32, evt[32..36], event_type, .big);
        std.mem.writeInt(u32, evt[36..40], status, .big);
        std.mem.writeInt(u32, evt[40..44], 0, .big); // reason = 0
        std.mem.writeInt(u32, evt[44..48], 0, .big); // auth_type = 0
        std.mem.writeInt(u32, evt[48..52], @intCast(data.len), .big); // datalen
        @memcpy(evt[52..58], &addr);
        @memcpy(evt[58..63], "wlan0"); // ifname
        evt[74] = 0; // ifidx
        evt[75] = 0; // bsscfgidx
        @memcpy(evt[76..][0..data.len], data);

        self.queueRxFrame(SDPCM_EVENT_CHANNEL, evt[0 .. 76 + data.len]);
    }
};

test "Cyw43430 CIS tuples, backplane ChipCommon/EROM, and BCDC cur_etheraddr" {
    var chip = Cyw43430{
        .mac_address = .{ 0xb8, 0x27, 0xeb, 0xaa, 0xbb, 0xcc },
    };

    // Verify Common CIS vendor/device ID (0x02d0:0xa9a6)
    try std.testing.expectEqual(@as(u8, 0x20), chip.readByte(0, 0x1000));
    try std.testing.expectEqual(@as(u8, 0x04), chip.readByte(0, 0x1001));
    try std.testing.expectEqual(@as(u8, 0xd0), chip.readByte(0, 0x1002));
    try std.testing.expectEqual(@as(u8, 0x02), chip.readByte(0, 0x1003));
    try std.testing.expectEqual(@as(u8, 0xa6), chip.readByte(0, 0x1004));
    try std.testing.expectEqual(@as(u8, 0xa9), chip.readByte(0, 0x1005));

    // Verify ChipCommon chipid via Function 1 backplane window
    chip.writeByte(1, 0x1000a, 0x00);
    chip.writeByte(1, 0x1000b, 0x00);
    chip.writeByte(1, 0x1000c, 0x18);
    var cc_id_bytes: [4]u8 = undefined;
    chip.readExtended(1, 0x08000, true, &cc_id_bytes);
    const chipid = std.mem.readInt(u32, &cc_id_bytes, .little);
    try std.testing.expectEqual(@as(u32, 0x1001a9a6), chipid);

    // Enable interrupts and send BCDC GET_VAR("cur_etheraddr") on Function 2
    chip.writeByte(0, 0x04, 0x07); // CCCR IENx
    chip.writeBackplane32(0x18002024, 0x000000ff); // hostintmask

    var tx_pkt: [64]u8 = @splat(0);
    const total_len: u16 = 12 + 16 + 14;
    std.mem.writeInt(u16, tx_pkt[0..2], total_len, .little);
    std.mem.writeInt(u16, tx_pkt[2..4], ~total_len, .little);
    tx_pkt[4] = 1; // seq
    tx_pkt[5] = 0; // SDPCM_CONTROL_CHANNEL
    tx_pkt[7] = 12; // doff
    std.mem.writeInt(u32, tx_pkt[12..16], 262, .little); // BRCMF_C_GET_VAR
    std.mem.writeInt(u32, tx_pkt[16..20], 14, .little); // len
    std.mem.writeInt(u32, tx_pkt[20..24], 0x00010000, .little); // reqid = 1
    @memcpy(tx_pkt[28..42], "cur_etheraddr\x00");

    chip.writeExtended(2, 0, true, tx_pkt[0..total_len]);
    try std.testing.expect(chip.cardIntPending());

    var rx_pkt: [64]u8 = undefined;
    chip.readExtended(2, 0, true, &rx_pkt);
    try std.testing.expectEqualSlices(u8, &.{ 0xb8, 0x27, 0xeb, 0xaa, 0xbb, 0xcc }, rx_pkt[28..34]);
}

test "Cyw43430 firmware start replaces the NVRAM token with its sdpcm_shared address" {
    var chip = Cyw43430{};
    const top = chip.chip.ramSize();
    // brcmfmac downloads 0x2a0 bytes of NVRAM to the top of RAM, ending in its length token
    const words: u32 = 0x2a0 / 4;
    chip.writeBackplane32(top - 4, (~words << 16) | words);
    chip.writeBackplane32(top - 0x2a4, 0x3d6e6f6d); // NVRAM text

    chip.writeBackplane32(0x18103800, 0); // release the ARM CM3 from reset

    const shared = chip.readBackplane32(top - 4);
    try std.testing.expect(shared != 0 and ((~shared >> 16) & 0xffff) != (shared & 0xffff));
    try std.testing.expect(shared < top - 0x2a4);
    try std.testing.expectEqual(@as(u32, 0x3d6e6f6d), chip.readBackplane32(top - 0x2a4));
    try std.testing.expectEqual(@as(u32, 3), chip.readBackplane32(shared) & 0xff); // version
    const console = chip.readBackplane32(shared + 20);
    const buf = chip.readBackplane32(console + 8);
    try std.testing.expectEqual(@as(u32, 1024), chip.readBackplane32(console + 12)); // buf_size
    try std.testing.expectEqual(@as(u32, 0), chip.readBackplane32(console + 16)); // idx
    try std.testing.expect(buf > console and buf + 1024 <= top - 0x2a4);
}

test "Cyw43455 identifies as BCM4345/6 with an ARM CR4 and starts its firmware from TCM" {
    var chip = Cyw43430{ .chip = .cyw43455 };

    // SDIO device 0x02d0:0xa9bf and ChipCommon chip ID 0x4345 rev 6
    try std.testing.expectEqual(@as(u8, 0xbf), chip.readByte(0, 0x1004));
    try std.testing.expectEqual(@as(u8, 0xa9), chip.readByte(0, 0x1005));
    try std.testing.expectEqual(@as(u32, 0x10064345), chip.readBackplane32(0x18000000));

    // The EROM lists ChipCommon, 802.11, SDIO and an ARM CR4 (0x83e), and no SOCRAM
    var i: u32 = 0;
    var cores: [8]u32 = undefined;
    var n: usize = 0;
    while (i < 64) : (i += 4) {
        const ci_a = chip.readBackplane32(0x18000800 + i * 4);
        if (ci_a == 0x0000000f) break;
        cores[n] = (ci_a >> 8) & 0xfff;
        n += 1;
    }
    try std.testing.expectEqualSlices(u32, &.{ 0x800, 0x812, 0x829, 0x83e }, cores[0..n]);

    // TCM size from the CR4 core: bank count in corecap, then bank 0's size
    try std.testing.expectEqual(@as(u32, 1), chip.readBackplane32(0x18003004) & 0xf);
    chip.writeBackplane32(0x18003040, 0);
    try std.testing.expectEqual(chip.chip.ramSize(), ((chip.readBackplane32(0x18003044) & 0x7f) + 1) * 8192);

    // Firmware goes to the TCM at 0x198000, NVRAM to its top, the reset vector to address 0
    const base = chip.chip.ramBase();
    const top = base + chip.chip.ramSize();
    chip.writeBackplane32(base, 0xb8f0f00b);
    try std.testing.expectEqual(@as(u32, 0xb8f0f00b), chip.readBackplane32(base));
    const trailer = "43455c0-roml/43455_sdio Version: 7.45.265 (28bca26 CY) CRC: 68bafb8c Date: Tue 2023-08-29 01:51:02 PDT Ucode Ver: 1043.2170 FWID 01-b677b91b\x00";
    for (0..trailer.len / 4) |w| chip.writeBackplane32(base + 0x1000 + @as(u32, @intCast(w)) * 4, std.mem.readInt(u32, trailer[w * 4 ..][0..4], .little));
    const words: u32 = 0x2a0 / 4;
    chip.writeBackplane32(top - 4, (~words << 16) | words);
    chip.writeBackplane32(0, 0xb8f0f00b);

    // brcmf_chip_cr4_set_passive leaves the core out of reset but halted: not started
    chip.writeBackplane32(0x18103408, 0x20 | 0x3); // IOCTL: CPUHALT | FGC | CLK
    chip.writeBackplane32(0x18103800, 0);
    try std.testing.expectEqual(@as(u32, 0), chip.sdio_intstatus);
    try std.testing.expectEqual(@as(u32, (~words << 16) | words), chip.readBackplane32(top - 4));

    // brcmf_chip_cr4_set_active: reset with CPUHALT clear, which starts the firmware
    chip.writeBackplane32(0x18103800, 1);
    chip.writeBackplane32(0x18103408, 0x3);
    chip.writeBackplane32(0x18103800, 0);
    try std.testing.expect((chip.sdio_intstatus & 0x80) != 0); // I_HMB_HOST_INT: FWREADY
    const shared = chip.readBackplane32(top - 4);
    try std.testing.expect(shared >= base and shared < top - 0x2a4);
    try std.testing.expectEqual(@as(u32, 3), chip.readBackplane32(shared) & 0xff);
    try std.testing.expectEqualStrings(
        "wl0: Aug 29 2023 01:51:02 version 7.45.265 (28bca26 CY) FWID 01-b677b91b\n",
        chip.fw_version[0..chip.fw_version_len],
    );
}

test "Cyw43430 reports the version of the firmware the host downloaded" {
    var chip = Cyw43430{};
    const trailer = "43430a1-roml/sdio-g-pool-p2p Version: 7.45.96.s1 (gf031a129) CRC: 6670a1e Date: Wed 2023-06-14 07:28:04 CST Ucode Ver: 1043.20744 FWID: 01-70bd2af7\x00\x00\x00\x00";
    for (0..trailer.len / 4) |w| {
        chip.writeBackplane32(0x2000 + @as(u32, @intCast(w)) * 4, std.mem.readInt(u32, trailer[w * 4 ..][0..4], .little));
    }
    chip.writeBackplane32(0x18103800, 0); // release the ARM CM3 from reset
    try std.testing.expectEqualStrings(
        "wl0: Jun 14 2023 07:28:04 version 7.45.96.s1 (gf031a129) FWID 01-70bd2af7\n",
        chip.fw_version[0..chip.fw_version_len],
    );
}

/// Sends BCDC GET_VAR(`name`, `arg`) on Function 2 and returns the reply body in `reply`
fn testGetVar(chip: *Cyw43430, name: []const u8, arg: []const u8, reply: *[1600]u8) []const u8 {
    var tx: [256]u8 = @splat(0);
    const body_len = name.len + 1 + arg.len;
    const total: u16 = @intCast(12 + 16 + body_len);
    std.mem.writeInt(u16, tx[0..2], total, .little);
    std.mem.writeInt(u16, tx[2..4], ~total, .little);
    tx[7] = 12; // doff, SDPCM_CONTROL_CHANNEL
    std.mem.writeInt(u32, tx[12..16], 262, .little); // BRCMF_C_GET_VAR
    std.mem.writeInt(u32, tx[16..20], 1024, .little); // len: the host's buffer
    @memcpy(tx[28..][0..name.len], name);
    @memcpy(tx[28 + name.len + 1 ..][0..arg.len], arg);
    chip.writeExtended(2, 0, true, tx[0..total]);
    chip.readExtended(2, 0, true, reply);
    const len = std.mem.readInt(u16, reply[0..2], .little);
    return reply[12 + 16 .. len];
}

test "Cyw43455 reports 40 MHz at 2.4 GHz and 40/80 MHz with VHT at 5 GHz" {
    var chip = Cyw43430{ .chip = .cyw43455 };
    chip.writeByte(0, 0x04, 0x07);
    var reply: [1600]u8 = undefined;

    const le = std.mem.toBytes;
    var r = testGetVar(&chip, "bw_cap", &le(@as(u32, 2)), &reply);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, r[0..4], .little));
    r = testGetVar(&chip, "bw_cap", &le(@as(u32, 1)), &reply);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, r[0..4], .little));
    r = testGetVar(&chip, "vhtmode", "", &reply);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, r[0..4], .little));

    // All chanspecs: every 20 MHz channel before any wider one
    r = testGetVar(&chip, "chanspecs", &le(@as(u32, 0)), &reply);
    const count = std.mem.readInt(u32, r[0..4], .little);
    try std.testing.expectEqual(@as(u32, 11 + 9 + 14 + 8 + 8), count);
    var seen_wide = false;
    var has_80_ll_36 = false;
    for (0..count) |i| {
        const cs = std.mem.readInt(u32, r[4 + i * 4 ..][0..4], .little);
        const bw = cs & 0x3800;
        if (bw != 0x1000) seen_wide = true else try std.testing.expect(!seen_wide);
        if (cs == 0xe02a) has_80_ll_36 = true; // 5 GHz 80 MHz center 42, control channel 36
    }
    try std.testing.expect(has_80_ll_36);

    // brcmf_enable_bw40_2g's query: only the 2.4 GHz 40 MHz chanspecs
    r = testGetVar(&chip, "chanspecs", &le(@as(u32, 0x1800)), &reply);
    try std.testing.expectEqual(@as(u32, 14), std.mem.readInt(u32, r[0..4], .little));
    for (0..14) |i| try std.testing.expectEqual(@as(u32, 0x1800), std.mem.readInt(u32, r[4 + i * 4 ..][0..4], .little) & 0xf800);
}

test "Cyw43430 reports 20 MHz channels at 2.4 GHz only" {
    var chip = Cyw43430{};
    chip.writeByte(0, 0x04, 0x07);
    var reply: [1600]u8 = undefined;

    const le = std.mem.toBytes;
    var r = testGetVar(&chip, "bw_cap", &le(@as(u32, 2)), &reply);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, r[0..4], .little));
    r = testGetVar(&chip, "vhtmode", "", &reply);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, r[0..4], .little));
    r = testGetVar(&chip, "chanspecs", &le(@as(u32, 0)), &reply);
    try std.testing.expectEqual(@as(u32, 11), std.mem.readInt(u32, r[0..4], .little));
    r = testGetVar(&chip, "chanspecs", &le(@as(u32, 0x1800)), &reply);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, r[0..4], .little));

    // brcmf_enable_bw40_2g's SET_VAR("bw_cap", { WLC_BAND_2G, 20/40 MHz }) fails
    var tx: [64]u8 = @splat(0);
    const total: u16 = 12 + 16 + 15;
    std.mem.writeInt(u16, tx[0..2], total, .little);
    std.mem.writeInt(u16, tx[2..4], ~total, .little);
    tx[7] = 12;
    std.mem.writeInt(u32, tx[12..16], 263, .little); // BRCMF_C_SET_VAR
    std.mem.writeInt(u32, tx[16..20], 15, .little);
    std.mem.writeInt(u32, tx[20..24], 0x0001_0002, .little); // reqid 1, BCDC_DCMD_SET
    @memcpy(tx[28..35], "bw_cap\x00");
    std.mem.writeInt(u32, tx[35..39], 2, .little);
    std.mem.writeInt(u32, tx[39..43], 3, .little);
    chip.writeExtended(2, 0, true, tx[0..total]);
    chip.readExtended(2, 0, true, &reply);
    try std.testing.expect(std.mem.readInt(u32, reply[12 + 8 ..][0..4], .little) & 1 != 0); // BCDC_DCMD_ERROR
    r = testGetVar(&chip, "bw_cap", &le(@as(u32, 2)), &reply);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, r[0..4], .little));
}

/// Starts an escan (SET_VAR "escan") for `ssid` ("" = any) on `chanspecs` (none = all channels),
/// skips the control reply and returns the BSS infos of the partial results in `out`
fn testEscan(chip: *Cyw43430, ssid: []const u8, chanspecs: []const u16, out: *[4][256]u8) !usize {
    var params: [256]u8 = @splat(0);
    std.mem.writeInt(u32, params[0..4], 1, .little); // version
    std.mem.writeInt(u16, params[4..6], 1, .little); // action: start
    std.mem.writeInt(u16, params[6..8], 0x1234, .little); // sync_id
    std.mem.writeInt(u32, params[8..12], @intCast(ssid.len), .little);
    @memcpy(params[12..][0..ssid.len], ssid);
    std.mem.writeInt(u32, params[68..72], @intCast(chanspecs.len), .little);
    for (chanspecs, 0..) |cs, i| std.mem.writeInt(u16, params[72 + i * 2 ..][0..2], cs, .little);
    const params_len = 72 + chanspecs.len * 2;

    var tx: [512]u8 = @splat(0);
    const total: u16 = @intCast(12 + 16 + 6 + params_len);
    std.mem.writeInt(u16, tx[0..2], total, .little);
    std.mem.writeInt(u16, tx[2..4], ~total, .little);
    tx[7] = 12;
    std.mem.writeInt(u32, tx[12..16], 263, .little); // BRCMF_C_SET_VAR
    std.mem.writeInt(u32, tx[16..20], @intCast(6 + params_len), .little);
    std.mem.writeInt(u32, tx[20..24], 0x0001_0002, .little);
    @memcpy(tx[28..34], "escan\x00");
    @memcpy(tx[34..][0..params_len], params[0..params_len]);
    chip.writeExtended(2, 0, true, tx[0..total]);

    var frame: [2048]u8 = undefined;
    chip.readExtended(2, 0, true, &frame); // control reply
    try std.testing.expectEqual(@as(u8, 0), frame[5] & 0x0f);
    var n: usize = 0;
    while (true) {
        chip.readExtended(2, 0, true, &frame);
        try std.testing.expectEqual(@as(u8, 1), frame[5] & 0x0f); // SDPCM_EVENT_CHANNEL
        const evt = frame[12 + 4 ..]; // after the SDPCM and BCDC headers
        try std.testing.expectEqual(@as(u32, 69), std.mem.readInt(u32, evt[28..32], .big)); // ESCAN_RESULT
        const status = std.mem.readInt(u32, evt[32..36], .big);
        if (status == 0) return n; // BRCMF_E_STATUS_SUCCESS: scan complete
        try std.testing.expectEqual(@as(u32, 8), status); // BRCMF_E_STATUS_PARTIAL
        const datalen = std.mem.readInt(u32, evt[44..48], .big);
        const result = evt[72..][0..datalen];
        // The checks brcmf_cfg80211_escan_handler makes
        const buflen = std.mem.readInt(u32, result[0..4], .little);
        try std.testing.expectEqual(datalen, buflen);
        try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, result[8..10], .little));
        try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, result[10..12], .little));
        const bi = result[12..];
        try std.testing.expectEqual(@as(u32, 109), std.mem.readInt(u32, bi[0..4], .little));
        try std.testing.expectEqual(buflen - 12, std.mem.readInt(u32, bi[4..8], .little));
        @memcpy(out[n][0..bi.len], bi);
        n += 1;
    }
}

test "Cyw43455 scans find the access point at 2.4 and 5 GHz, open" {
    var chip = Cyw43430{ .chip = .cyw43455 };
    chip.writeByte(0, 0x04, 0x07);
    chip.setAccessPointName("tokamak");
    var bss: [4][256]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 2), try testEscan(&chip, "", &.{}, &bss));
    for (bss[0..2], [_]u8{ 6, 36 }, [_]u16{ 0x1006, 0xd024 }) |bi, ch, chanspec| {
        try std.testing.expectEqualStrings("tokamak", bi[19..][0..bi[18]]);
        try std.testing.expectEqual(chanspec, std.mem.readInt(u16, bi[72..74], .little));
        try std.testing.expectEqual(ch, bi[88]);
        try std.testing.expect(std.mem.readInt(u16, bi[16..18], .little) & 0x0010 == 0); // no privacy
        try std.testing.expect(bi[8] & 0x03 == 0x02); // locally administered BSSID
        // The IEs start with the SSID
        const ies = bi[std.mem.readInt(u16, bi[116..118], .little)..];
        try std.testing.expectEqual(@as(u8, 0), ies[0]);
        try std.testing.expectEqualStrings("tokamak", ies[2..][0..ies[1]]);
    }
    try std.testing.expect(!std.mem.eql(u8, bss[0][8..14], bss[1][8..14])); // one BSSID per radio

    // A scan of 5 GHz channel 36 only, or for another SSID
    try std.testing.expectEqual(@as(usize, 1), try testEscan(&chip, "", &.{0xd024}, &bss));
    try std.testing.expectEqual(@as(u8, 36), bss[0][88]);
    try std.testing.expectEqual(@as(usize, 2), try testEscan(&chip, "tokamak", &.{}, &bss));
    try std.testing.expectEqual(@as(usize, 0), try testEscan(&chip, "other", &.{}, &bss));
}

test "Cyw43430 scans find only the access point's 2.4 GHz radio" {
    var chip = Cyw43430{};
    chip.writeByte(0, 0x04, 0x07);
    chip.setAccessPointName("tokamak");
    var bss: [4][256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try testEscan(&chip, "", &.{}, &bss));
    try std.testing.expectEqual(@as(u8, 6), bss[0][88]);
}

/// Sends BCDC command `cmd` (SET when `set`) with `body`, and returns the reply body
fn testDcmd(chip: *Cyw43430, cmd: u32, set: bool, body: []const u8, reply: *[2048]u8) []const u8 {
    var tx: [512]u8 = @splat(0);
    const total: u16 = @intCast(12 + 16 + body.len);
    std.mem.writeInt(u16, tx[0..2], total, .little);
    std.mem.writeInt(u16, tx[2..4], ~total, .little);
    tx[7] = 12; // SDPCM_CONTROL_CHANNEL
    std.mem.writeInt(u32, tx[12..16], cmd, .little);
    std.mem.writeInt(u32, tx[16..20], if (set) @intCast(body.len) else 1536, .little);
    std.mem.writeInt(u32, tx[20..24], if (set) 0x0001_0002 else 0x0001_0000, .little);
    @memcpy(tx[28..][0..body.len], body);
    chip.writeExtended(2, 0, true, tx[0..total]);
    chip.readExtended(2, 0, true, reply);
    std.debug.assert(reply[5] & 0x0f == 0);
    const len = std.mem.readInt(u16, reply[0..2], .little);
    return reply[12 + 16 .. len];
}

const TestEvent = struct { event_type: u32, status: u32, flags: u16, addr: [6]u8 };

fn testReadEvent(chip: *Cyw43430) !TestEvent {
    var frame: [2048]u8 = undefined;
    chip.readExtended(2, 0, true, &frame);
    try std.testing.expectEqual(@as(u8, 1), frame[5] & 0x0f); // SDPCM_EVENT_CHANNEL
    const evt = frame[12 + 4 ..];
    return .{
        .event_type = std.mem.readInt(u32, evt[28..32], .big),
        .status = std.mem.readInt(u32, evt[32..36], .big),
        .flags = std.mem.readInt(u16, evt[26..28], .big),
        .addr = evt[48..54].*,
    };
}

/// struct brcmf_ext_join_params_le for `ssid` (any BSSID) on `chanspec` (0 = any channel)
fn testJoinParams(ssid: []const u8, chanspec: u16) [70]u8 {
    var p: [70]u8 = @splat(0);
    std.mem.writeInt(u32, p[0..4], @intCast(ssid.len), .little);
    @memcpy(p[4..][0..ssid.len], ssid);
    @memset(p[56..62], 0xff);
    if (chanspec != 0) {
        std.mem.writeInt(u32, p[64..68], 1, .little);
        std.mem.writeInt(u16, p[68..70], chanspec, .little);
    }
    return p;
}

test "Cyw43430 joins the open access point and reaches its network" {
    var chip = Cyw43430{ .mac_address = .{ 0xb8, 0x27, 0xeb, 0x01, 0x02, 0x03 } };
    defer chip.deinit();
    chip.writeByte(0, 0x04, 0x07);
    chip.setAccessPointName("tokamak");
    var reply: [2048]u8 = undefined;
    var aps: [2]Cyw43430.AccessPoint = undefined;
    const ap = chip.accessPoints(&aps)[0];

    // Joining an SSID that is not there fails
    var body: [80]u8 = @splat(0);
    @memcpy(body[0..5], "join\x00");
    body[5..75].* = testJoinParams("other", 0);
    _ = testDcmd(&chip, 263, true, body[0..75], &reply);
    var e = try testReadEvent(&chip);
    try std.testing.expectEqual(@as(u32, 0), e.event_type); // BRCMF_E_SET_SSID
    try std.testing.expectEqual(@as(u32, 3), e.status); // BRCMF_E_STATUS_NO_NETWORKS

    // Joining it: authenticated, associated, link up, SET_SSID done
    body[5..75].* = testJoinParams("tokamak", 0);
    _ = testDcmd(&chip, 263, true, body[0..75], &reply);
    for ([_]u32{ 3, 7, 16, 0 }) |want| {
        e = try testReadEvent(&chip);
        try std.testing.expectEqual(want, e.event_type);
        try std.testing.expectEqual(@as(u32, 0), e.status);
        try std.testing.expectEqualSlices(u8, &ap.bssid, &e.addr);
        if (want == 16) try std.testing.expectEqual(@as(u16, 1), e.flags); // BRCMF_EVENT_MSG_LINK
    }
    var r = testDcmd(&chip, 136, false, &.{}, &reply); // BRCMF_C_GET_BSS_INFO
    try std.testing.expectEqualStrings("tokamak", r[4 + 19 ..][0..r[4 + 18]]);
    r = testDcmd(&chip, 23, false, &.{}, &reply); // BRCMF_C_GET_BSSID
    try std.testing.expectEqualSlices(u8, &ap.bssid, r[0..6]);

    // ARP for the gateway over the data channel: answered by 10.0.3.2
    var tx: [128]u8 = @splat(0);
    const arp = tx[12 + 4 ..];
    @memset(arp[0..6], 0xff);
    @memcpy(arp[6..12], &chip.mac_address);
    arp[12..22].* = .{ 0x08, 0x06, 0x00, 0x01, 0x08, 0x00, 6, 4, 0x00, 0x01 };
    @memcpy(arp[22..28], &chip.mac_address);
    arp[28..32].* = .{ 10, 0, 3, 15 };
    arp[38..42].* = .{ 10, 0, 3, 2 };
    const total: u16 = 12 + 4 + 42;
    std.mem.writeInt(u16, tx[0..2], total, .little);
    std.mem.writeInt(u16, tx[2..4], ~total, .little);
    tx[4] = 1;
    tx[5] = 2; // SDPCM_DATA_CHANNEL
    tx[7] = 12;
    tx[12] = 0x20; // BCDC data header
    chip.writeExtended(2, 0, true, tx[0..total]);
    var frame: [2048]u8 = undefined;
    chip.readExtended(2, 0, true, &frame);
    try std.testing.expectEqual(@as(u8, 2), frame[5] & 0x0f);
    const eth = frame[12 + 4 ..];
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x06 }, eth[12..14]);
    try std.testing.expectEqualSlices(u8, &.{ 0x52, 0x55, 0x0a, 0x00, 0x03, 0x02 }, eth[22..28]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 3, 2 }, eth[28..32]);

    // Disassociating takes the link down
    _ = testDcmd(&chip, 52, true, &.{}, &reply); // BRCMF_C_DISASSOC
    e = try testReadEvent(&chip);
    try std.testing.expectEqual(@as(u32, 16), e.event_type);
    try std.testing.expectEqual(@as(u16, 0), e.flags);
}

test "Cyw43455 joins the access point's 5 GHz radio when asked for its channel" {
    var chip = Cyw43430{ .chip = .cyw43455 };
    defer chip.deinit();
    chip.writeByte(0, 0x04, 0x07);
    chip.setAccessPointName("tokamak");
    var reply: [2048]u8 = undefined;
    var aps: [2]Cyw43430.AccessPoint = undefined;
    const ap_5g = chip.accessPoints(&aps)[1];

    // BRCMF_C_SET_SSID with struct brcmf_join_params on 5 GHz channel 36
    var body: [50]u8 = @splat(0);
    std.mem.writeInt(u32, body[0..4], 7, .little);
    @memcpy(body[4..11], "tokamak");
    @memset(body[36..42], 0xff);
    std.mem.writeInt(u32, body[44..48], 1, .little);
    std.mem.writeInt(u16, body[48..50], 0xd024, .little);
    _ = testDcmd(&chip, 26, true, &body, &reply);
    for ([_]u32{ 3, 7, 16, 0 }) |want| {
        const e = try testReadEvent(&chip);
        try std.testing.expectEqual(want, e.event_type);
        try std.testing.expectEqualSlices(u8, &ap_5g.bssid, &e.addr);
    }
    const r = testDcmd(&chip, 127, false, &.{}, &reply); // BRCMF_C_GET_RSSI
    try std.testing.expectEqual(@as(i32, ap_5g.rssi), std.mem.readInt(i32, r[0..4], .little));
}
