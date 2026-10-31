//! Broadcom BCM43430 / Cypress CYW43430 SDIO 802.11b/g/n Wi-Fi Controller Emulation.
//!
//! Emulates the onboard wireless controller attached to the BCM2835 Arasan SDHCI
//! interface (`/soc/mmc@7e300000`) on Raspberry Pi Zero W and Raspberry Pi Zero 2 W:
//! - SDIO bus protocol (`CMD5`, `CMD3`, `CMD7`, `CMD52`, `CMD53`)
//! - Function 0: CCCR, FBR1, FBR2, and CIS tuples (`0x02d0:0xa9a6`)
//! - Function 1: Backplane window (`SBSDIO_FUNC1_SBADDR*`), clock/sleep CSRs,
//!   AI/DMP cores (ChipCommon `0x800`, SDIO Device `0x829`, SOCRAM `0x80e`,
//!   ARM CM3 `0x82a`, 802.11 `0x812`), and 512 KiB chip RAM (`0x00000000..0x0007ffff`)
//! - Function 2: SDPCM + BCDC control/event protocol (`brcmfmac` driver interface)

const std = @import("std");

pub const Cyw43430 = struct {
    pub const CHIP_ID: u16 = 43430; // 0xa9a6
    pub const CHIP_REV: u16 = 1; // BCM43430A1 -> brcmfmac43430-sdio.bin
    pub const RAM_SIZE: usize = 512 * 1024;
    pub const MAX_RX_FRAMES: usize = 8;
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
    const ARMCM3_BASE: u32 = 0x18003000;
    const SOCRAM_BASE: u32 = 0x18004000;
    const EROM_BASE: u32 = 0x18000800;

    const CC_WRAP: u32 = 0x18100000;
    const D11_WRAP: u32 = 0x18101000;
    const SDIO_WRAP: u32 = 0x18102000;
    const ARMCM3_WRAP: u32 = 0x18103000;
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

    // Backplane core wrapper states: [0]=CC, [1]=D11, [2]=SDIO, [3]=ARMCM3, [4]=SOCRAM
    wrap_ioctl: [5]u32 = .{ 1, 1, 1, 1, 1 },
    wrap_reset: [5]u32 = .{ 0, 0, 0, 1, 0 }, // ARM CM3 starts in reset until firmware loaded

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

    rx_frames: [MAX_RX_FRAMES][MAX_FRAME_LEN]u8 = undefined,
    rx_frame_lens: [MAX_RX_FRAMES]usize = @splat(0),
    rx_head: usize = 0,
    rx_tail: usize = 0,
    rx_count: usize = 0,
    rx_frame_offset: usize = 0,

    // 512 KiB chip RAM for firmware & NVRAM upload/verification
    chip_ram: [RAM_SIZE]u8 = @splat(0),

    pub fn reset(self: *Cyw43430) void {
        const mac = self.mac_address;
        self.* = .{ .mac_address = mac };
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
            0x1000...0x10ff => readCisCommon(addr - 0x1000),
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

    fn readCisCommon(off: u17) u8 {
        // CISTPL_MANFID (0x20, len 4): vendor 0x02d0 (Broadcom), device 0xa9a6 (BCM43430)
        // CISTPL_FUNCE (0x22, len 4): type 0x00, fn0_blk_size=64 (0x0040), max_tran_speed=0x32 (25 MHz)
        // CISTPL_END (0xff)
        const cis_common = [_]u8{
            0x20, 0x04, 0xd0, 0x02, 0xa6, 0xa9,
            0x22, 0x04, 0x00, 0x40, 0x00, 0x32,
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
        if (bp_addr < RAM_SIZE) {
            self.chip_ram[bp_addr] = val;
            return;
        }
        const aligned = bp_addr & ~@as(u32, 3);
        const shift: u5 = @intCast((bp_addr & 3) * 8);
        const mask = ~(@as(u32, 0xff) << shift);
        const old = self.readBackplane32(aligned);
        self.writeBackplane32(aligned, (old & mask) | (@as(u32, val) << shift));
    }

    pub fn readBackplane32(self: *const Cyw43430, addr: u32) u32 {
        if (addr + 4 <= RAM_SIZE) {
            return std.mem.readInt(u32, self.chip_ram[addr..][0..4], .little);
        }

        // DMP EROM table at 0x18000800..0x18000900
        if (addr >= EROM_BASE and addr < EROM_BASE + 0x100) {
            return readEromWord((addr - EROM_BASE) / 4);
        }

        // ChipCommon (0x18000000..0x18000fff)
        if (addr >= CC_BASE and addr < CC_BASE + 0x1000) {
            return switch (addr - CC_BASE) {
                0x000 => (1 << 28) | (@as(u32, CHIP_REV) << 16) | CHIP_ID, // SOCI_AI (1<<28) | rev 1 | 43430
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

        // SOCRAM core (0x18004000..0x18004fff)
        if (addr >= SOCRAM_BASE and addr < SOCRAM_BASE + 0x1000) {
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
        if (addr + 4 <= RAM_SIZE) {
            std.mem.writeInt(u32, self.chip_ram[addr..][0..4], val, .little);
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
        if (addr >= SOCRAM_BASE and addr < SOCRAM_BASE + 0x1000) {
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
                    0x800 => {
                        self.wrap_reset[idx] = val;
                        // When ARM CM3 core (idx 3) is released from reset (val == 0),
                        // firmware is ready and signals HMB_DATA_FWREADY
                        if (idx == 3 and val == 0) {
                            self.publishShared();
                            self.sdio_tohostmailboxdata = 0x00040008;
                            self.sdio_intstatus |= I_HMB_HOST_INT;
                        }
                    },
                    else => {},
                }
            }
            return;
        }
    }

    const I_HMB_SW_MASK_ACK: u32 = I_HMB_HOST_INT;

    const SDPCM_SHARED_VERSION: u32 = 3;
    const SDPCM_SHARED_SIZE: u32 = 76; // struct sdpcm_shared
    const RTE_CONSOLE_SIZE: u32 = 156; // struct rte_console
    const CONSOLE_BUF_SIZE: u32 = 1024;

    /// What the firmware does as it starts: it lays out its `sdpcm_shared` structure, with an
    /// (empty) console log, and overwrites the last word of RAM, which held the NVRAM length
    /// token, with its address. `brcmfmac` reads it to find the console and trap information.
    fn publishShared(self: *Cyw43430) void {
        const ram_size: u32 = RAM_SIZE;
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
        self.writeRam32(console + 8, console_buf);
        self.writeRam32(console + 12, CONSOLE_BUF_SIZE);
        self.writeRam32(console + 20, console_buf);
        // struct sdpcm_shared: flags, trap_addr, assert_exp_addr, assert_file_addr, assert_line,
        // console_addr, msgtrace_addr, tag[32], brpt_addr
        self.writeRam32(shared, SDPCM_SHARED_VERSION);
        self.writeRam32(shared + 20, console);
        self.writeRam32(ram_size - 4, shared);
    }

    fn writeRam32(self: *Cyw43430, addr: u32, val: u32) void {
        std.mem.writeInt(u32, self.chip_ram[addr..][0..4], val, .little);
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

    fn readEromWord(word_idx: u32) u32 {
        const erom_table = eromCoreEntry(0x800, 49, CC_BASE, CC_WRAP) ++
            eromCoreEntry(0x812, 42, D11_BASE, D11_WRAP) ++
            eromCoreEntry(0x829, 12, SDIO_BASE, SDIO_WRAP) ++
            eromCoreEntry(0x82a, 5, ARMCM3_BASE, ARMCM3_WRAP) ++
            eromCoreEntry(0x80e, 8, SOCRAM_BASE, SOCRAM_WRAP) ++
            [_]u32{0x0000000f}; // DMP_DESC_EOT
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
        frame[9] = self.host_tx_seq +% 32; // tx_seq_max window
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
        var trigger_escan = false;

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
                        const ver_str = "wl0: Oct 23 2017 03:55:53 version 7.45.98.94 (r666254 CY) FWID 01-e58d219f\n\x00";
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
                        std.mem.eql(u8, var_name, "rxchain") or
                        std.mem.eql(u8, var_name, "bw_cap"))
                    {
                        if (dst.len >= 4) std.mem.writeInt(u32, dst[0..4], 1, .little);
                    } else if (std.mem.eql(u8, var_name, "vhtmode") or
                        std.mem.eql(u8, var_name, "per_chan_info") or
                        std.mem.eql(u8, var_name, "ampdu_ba_wsize") or
                        std.mem.eql(u8, var_name, "mpc"))
                    {
                        if (dst.len >= 4) std.mem.writeInt(u32, dst[0..4], 0, .little);
                    } else if (std.mem.eql(u8, var_name, "chanspec")) {
                        if (dst.len >= 4) std.mem.writeInt(u32, dst[0..4], 0x1001, .little);
                    } else if (std.mem.eql(u8, var_name, "qtxpower")) {
                        if (dst.len >= 4) std.mem.writeInt(u32, dst[0..4], 80, .little); // 20 dBm (80 qdBm)
                    } else if (std.mem.eql(u8, var_name, "chanspecs")) {
                        // struct brcmf_chanspec_list { __le32 count; __le32 element[]; }
                        // Note: brcmf_enable_bw40_2g passes a 40 MHz chanspec filter (0x1800) in arg[0..2].
                        // BCM43430 is 20 MHz only in 2.4 GHz, so return count=0 for 40 MHz queries.
                        const q_chspec: u16 = if (arg.len >= 2) std.mem.readInt(u16, arg[0..2], .little) else 0;
                        if ((q_chspec & 0x3800) == 0x1800) {
                            if (dst.len >= 4) std.mem.writeInt(u32, dst[0..4], 0, .little);
                        } else if (dst.len >= 4) {
                            // D11AC 2.4 GHz 20 MHz chanspec: band=2G (0x0000), bw=20MHz (0x1000), ch=1..11
                            const max_ch: u32 = @min(@as(u32, @intCast((dst.len - 4) / 4)), 11);
                            std.mem.writeInt(u32, dst[0..4], max_ch, .little);
                            for (0..max_ch) |ch_idx| {
                                const ch: u32 = @intCast(ch_idx + 1);
                                const chanspec: u32 = 0x1000 | ch;
                                std.mem.writeInt(u32, dst[4 + ch_idx * 4 ..][0..4], chanspec, .little);
                            }
                        }
                    } else if (std.mem.eql(u8, var_name, "country")) {
                        if (dst.len >= 12) {
                            @memcpy(dst[0..4], &self.country_abrev);
                            std.mem.writeInt(i32, dst[4..8], self.country_rev, .little);
                            @memcpy(dst[8..12], &self.country_ccode);
                        }
                    } else if (std.mem.eql(u8, var_name, "event_msgs")) {
                        const n = @min(dst.len, self.event_msgs.len);
                        @memcpy(dst[0..n], self.event_msgs[0..n]);
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
                    } else if (std.mem.eql(u8, var_name, "escan")) {
                        trigger_escan = true;
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
                    std.mem.writeInt(u32, dst[4..8], 0xa9a6, .little); // deviceid
                    std.mem.writeInt(u32, dst[8..12], 1, .little); // radiorev
                    std.mem.writeInt(u32, dst[12..16], CHIP_REV, .little); // chiprev
                    std.mem.writeInt(u32, dst[20..24], 42, .little); // corerev
                    std.mem.writeInt(u32, dst[44..48], CHIP_ID, .little); // chipnum
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
                if (dst.len >= 8) {
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

        if (trigger_escan) {
            self.queueEscanCompleteEvent();
        }
    }

    fn queueEscanCompleteEvent(self: *Cyw43430) void {
        // BCDC header (4 bytes) + struct brcmf_event (14 + 10 + 48 = 72 bytes) = 76 bytes
        // Total SDPCM frame = 12 + 76 = 88 bytes (> BRCMF_FIRSTREAD = 64 bytes)
        var evt: [76]u8 = @splat(0);

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
        std.mem.writeInt(u16, evt[20..22], 54, .big); // length
        evt[22] = 0; // version
        evt[23] = 0x00; // BRCM_OUI
        evt[24] = 0x10;
        evt[25] = 0x18;
        std.mem.writeInt(u16, evt[26..28], 1, .big); // BCMILCP_BCM_SUBTYPE_EVENT

        // 4. struct brcmf_event_msg_be (48 bytes at evt[28..76])
        std.mem.writeInt(u16, evt[28..30], 2, .big); // version = 2
        std.mem.writeInt(u16, evt[30..32], 0, .big); // flags = 0
        std.mem.writeInt(u32, evt[32..36], 69, .big); // event_type = BRCMF_E_ESCAN_RESULT (69)
        std.mem.writeInt(u32, evt[36..40], 0, .big); // status = BRCMF_E_STATUS_SUCCESS (0)
        std.mem.writeInt(u32, evt[40..44], 0, .big); // reason = 0
        std.mem.writeInt(u32, evt[44..48], 0, .big); // auth_type = 0
        std.mem.writeInt(u32, evt[48..52], 0, .big); // datalen = 0
        @memcpy(evt[52..58], &self.mac_address); // addr
        @memcpy(evt[58..63], "wlan0"); // ifname
        evt[74] = 0; // ifidx
        evt[75] = 0; // bsscfgidx

        self.queueRxFrame(SDPCM_EVENT_CHANNEL, &evt);
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
    // brcmfmac downloads 0x2a0 bytes of NVRAM to the top of RAM, ending in its length token
    const words: u32 = 0x2a0 / 4;
    chip.writeBackplane32(Cyw43430.RAM_SIZE - 4, (~words << 16) | words);
    chip.writeBackplane32(Cyw43430.RAM_SIZE - 0x2a4, 0x3d6e6f6d); // NVRAM text

    chip.writeBackplane32(0x18103800, 0); // release the ARM CM3 from reset

    const shared = chip.readBackplane32(Cyw43430.RAM_SIZE - 4);
    try std.testing.expect(shared != 0 and ((~shared >> 16) & 0xffff) != (shared & 0xffff));
    try std.testing.expect(shared < Cyw43430.RAM_SIZE - 0x2a4);
    try std.testing.expectEqual(@as(u32, 0x3d6e6f6d), chip.readBackplane32(Cyw43430.RAM_SIZE - 0x2a4));
    try std.testing.expectEqual(@as(u32, 3), chip.readBackplane32(shared) & 0xff); // version
    const console = chip.readBackplane32(shared + 20);
    const buf = chip.readBackplane32(console + 8);
    try std.testing.expectEqual(@as(u32, 1024), chip.readBackplane32(console + 12)); // buf_size
    try std.testing.expectEqual(@as(u32, 0), chip.readBackplane32(console + 16)); // idx
    try std.testing.expect(buf > console and buf + 1024 <= Cyw43430.RAM_SIZE - 0x2a4);
}
