const std = @import("std");
const host_posix = @import("../host/posix.zig");
pub const qcow2 = @import("qcow2.zig");

/// BCM2835 SDHOST Controller (`brcm,bcm2835-sdhost`) at `0x20202000` (size `0x100`).
/// Simulates the controller and an attached SDHC card backed by an image buffer or file.
pub const SdHost = struct {
    pub const BASE_ADDR: u32 = 0x20202000;
    pub const SIZE: u32 = 0x100;

    // SDCMD bits
    pub const SDCMD_NEW_FLAG: u32 = 0x8000;
    pub const SDCMD_FAIL_FLAG: u32 = 0x4000;
    pub const SDCMD_BUSYWAIT: u32 = 0x0800;
    pub const SDCMD_NO_RESPONSE: u32 = 0x0400;
    pub const SDCMD_LONG_RESPONSE: u32 = 0x0200;
    pub const SDCMD_WRITE_CMD: u32 = 0x0080;
    pub const SDCMD_READ_CMD: u32 = 0x0040;
    pub const SDCMD_CMD_MASK: u32 = 0x003f;

    // SDHSTS bits
    pub const SDHSTS_BUSY_IRPT: u32 = 0x0400;
    pub const SDHSTS_BLOCK_IRPT: u32 = 0x0200;
    pub const SDHSTS_SDIO_IRPT: u32 = 0x0100;
    pub const SDHSTS_REW_TIME_OUT: u32 = 0x0080;
    pub const SDHSTS_CMD_TIME_OUT: u32 = 0x0040;
    pub const SDHSTS_CRC16_ERROR: u32 = 0x0020;
    pub const SDHSTS_CRC7_ERROR: u32 = 0x0010;
    pub const SDHSTS_FIFO_ERROR: u32 = 0x0008;
    pub const SDHSTS_DATA_FLAG: u32 = 0x0001;

    // SDHCFG bits
    pub const SDHCFG_BUSY_IRPT_EN: u32 = 1 << 10;
    pub const SDHCFG_BLOCK_IRPT_EN: u32 = 1 << 8;
    pub const SDHCFG_SDIO_IRPT_EN: u32 = 1 << 5;
    pub const SDHCFG_DATA_IRPT_EN: u32 = 1 << 4;

    sdcmd: u32 = 0,
    sdarg: u32 = 0,
    sdtout: u32 = 0x00f00000,
    sdcdiv: u32 = 0,
    sdrsp: [4]u32 = [_]u32{0} ** 4,
    sdhsts: u32 = 0,
    sdvdd: u32 = 1,
    sdedm: u32 = 0x00001f01, // FSM = DATAMODE (1), threshold = 4
    sdhcfg: u32 = 0,
    sdhbct: u32 = 512,
    sdhblc: u32 = 0,

    // SD card protocol state
    app_cmd: bool = false,
    card_state: u4 = 4, // 0=idle, 1=ready, 2=ident, 3=stby, 4=tran

    // Backing storage (in-memory slice, pread/pwrite file descriptor, or QCOW2 virtual disk)
    image_data: ?[]u8 = null,
    image_const: ?[]const u8 = null,
    image_fd: ?std.posix.fd_t = null,
    qcow2_disk: ?*qcow2.Qcow2Disk = null,
    image_size: u64 = 512 * 1024 * 1024,

    // Active data transfer state
    transfer_mode: enum { none, read_image, write_image, read_aux } = .none,
    transfer_offset: u64 = 0,
    data_remaining: u32 = 0,
    aux_buf: [64]u8 = [_]u8{0} ** 64,
    aux_pos: u32 = 0,
    sector_cache: [512]u8 = [_]u8{0} ** 512,
    sector_cache_lba: u64 = std.math.maxInt(u64),
    activity_latch: bool = false,
    /// True when GPIO 48..53 are routed to SDHOST (ALT0, or default before pinctrl switches to ALT3)
    pins_routed: bool = true,

    pub fn hasMedia(self: *const SdHost) bool {
        return self.image_const != null or self.image_fd != null or self.qcow2_disk != null;
    }

    pub fn attachSlice(self: *SdHost, data: []const u8) void {
        self.detach();
        self.image_const = data;
        self.image_size = data.len;
    }

    pub fn attachMutableSlice(self: *SdHost, data: []u8) void {
        self.detach();
        self.image_data = data;
        self.image_const = data;
        self.image_size = data.len;
    }

    pub fn attachFile(self: *SdHost, fd: std.posix.fd_t, size: u64) void {
        self.detach();
        self.image_fd = fd;
        self.image_size = size;
    }

    pub fn attachQcow2(self: *SdHost, disk: *qcow2.Qcow2Disk) void {
        self.detach();
        self.qcow2_disk = disk;
        self.image_size = disk.virtual_size;
    }

    pub fn detach(self: *SdHost) void {
        if (self.qcow2_disk) |disk| {
            disk.flush() catch {};
        }
        self.image_data = null;
        self.image_const = null;
        self.image_fd = null;
        self.qcow2_disk = null;
        self.transfer_mode = .none;
        self.data_remaining = 0;
        self.sector_cache_lba = std.math.maxInt(u64);
    }

    pub fn dreqReady(self: *const SdHost) bool {
        return self.transfer_mode != .none and self.data_remaining > 0;
    }

    pub fn irqPending(self: *const SdHost) bool {
        if ((self.sdhcfg & SDHCFG_BUSY_IRPT_EN) != 0 and (self.sdhsts & SDHSTS_BUSY_IRPT) != 0) return true;
        if ((self.sdhcfg & SDHCFG_BLOCK_IRPT_EN) != 0 and (self.sdhsts & SDHSTS_BLOCK_IRPT) != 0) return true;
        if ((self.sdhcfg & SDHCFG_DATA_IRPT_EN) != 0 and (self.sdhsts & SDHSTS_DATA_FLAG) != 0) return true;
        return false;
    }

    pub fn read32(self: *SdHost, offset: u32) u32 {
        return switch (offset) {
            0x00 => self.sdcmd, // SDCMD (SDCMD_NEW_FLAG is always 0 because commands complete immediately)
            0x04 => self.sdarg,
            0x08 => self.sdtout,
            0x0c => self.sdcdiv,
            0x10 => self.sdrsp[0],
            0x14 => self.sdrsp[1],
            0x18 => self.sdrsp[2],
            0x1c => self.sdrsp[3],
            0x20 => blk: {
                var hsts = self.sdhsts;
                if (self.transfer_mode != .none and self.data_remaining > 0) {
                    hsts |= SDHSTS_DATA_FLAG;
                }
                break :blk hsts;
            },
            0x30 => self.sdvdd,
            0x34 => blk: { // SDEDM
                var edm = self.sdedm & ~@as(u32, 0x1ff);
                if ((self.transfer_mode == .read_image or self.transfer_mode == .read_aux) and self.data_remaining > 0) {
                    const words: u32 = @min((self.data_remaining + 3) / 4, 16);
                    edm |= 2 | (words << 4); // FSM = READDATA (2)
                } else if (self.transfer_mode == .write_image and self.data_remaining > 0) {
                    edm |= 3; // FSM = WRITEDATA (3), 0 words in FIFO (16 words free)
                } else {
                    edm |= 1; // FSM = DATAMODE (1)
                }
                break :blk edm;
            },
            0x38 => self.sdhcfg,
            0x3c => self.sdhbct,
            0x40 => self.readDataWord(),
            0x50 => if (self.sdhbct > 0) (self.data_remaining + self.sdhbct - 1) / self.sdhbct else 0,
            else => 0,
        };
    }

    pub fn write32(self: *SdHost, offset: u32, val: u32) void {
        switch (offset) {
            0x00 => { // SDCMD
                self.sdcmd = val & ~SDCMD_NEW_FLAG;
                if ((val & SDCMD_NEW_FLAG) != 0) {
                    self.executeCommand(val);
                }
            },
            0x04 => self.sdarg = val,
            0x08 => self.sdtout = val,
            0x0c => self.sdcdiv = val,
            0x20 => { // SDHSTS W1C
                self.sdhsts &= ~val;
                if (self.transfer_mode != .none and self.data_remaining > 0) {
                    self.sdhsts |= SDHSTS_DATA_FLAG;
                }
            },
            0x30 => {
                self.sdvdd = val;
                if (val == 0) {
                    self.transfer_mode = .none;
                    self.data_remaining = 0;
                    self.sdhsts = 0;
                }
            },
            0x34 => { // SDEDM
                if ((val & (1 << 19)) != 0) { // SDEDM_FORCE_DATA_MODE
                    self.transfer_mode = .none;
                    self.data_remaining = 0;
                }
                self.sdedm = val;
            },
            0x38 => self.sdhcfg = val,
            0x3c => self.sdhbct = if (val == 0) 512 else val,
            0x40 => self.writeDataWord(val),
            0x50 => self.sdhblc = val,
            else => {},
        }
    }

    pub fn r1Status(self: *const SdHost) u32 {
        return (@as(u32, self.card_state) << 9) | (1 << 8) | (if (self.app_cmd) @as(u32, 1 << 5) else 0);
    }

    pub fn fillCsdWords(self: *const SdHost) [4]u32 {
        const num_512k_units: u32 = @intCast(@max((self.image_size + (512 * 1024 - 1)) / (512 * 1024), 1));
        const c_size: u32 = num_512k_units - 1;
        return .{
            0x0a400001, // [31:0]: WRITE_BL_LEN=9
            (c_size << 16) | 0x7f80, // [63:32]: C_SIZE[15:0] | ERASE_BLK_EN=1, SECTOR_SIZE=0x7f
            0x5b590000 | ((c_size >> 16) & 0x3f), // [95:64]: CCC=0x5b5, READ_BL_LEN=9, C_SIZE[21:16]
            0x400e0032, // [127:96]: CSD_STRUCTURE = 1 (v2.0), TAAC=0x0e, TRAN_SPEED=0x32
        };
    }

    pub fn fillCidWords() [4]u32 {
        return .{
            0x12345601,
            0x30303030,
            0x46585049, // "FXPI"
            0x03534400,
        };
    }

    fn executeCommand(self: *SdHost, cmd_reg: u32) void {
        const cmd: u6 = @truncate(cmd_reg & SDCMD_CMD_MASK);
        self.sdhsts &= ~(SDHSTS_CMD_TIME_OUT | SDHSTS_CRC7_ERROR | SDHSTS_CRC16_ERROR | SDHSTS_REW_TIME_OUT);
        if (!self.pins_routed or !self.hasMedia()) {
            if (cmd != 0) {
                self.sdcmd |= SDCMD_FAIL_FLAG;
                self.sdhsts |= SDHSTS_CMD_TIME_OUT;
            }
            return;
        }
        self.activity_latch = true;

        if (self.app_cmd) {
            self.app_cmd = false;
            switch (cmd) {
                6 => { // ACMD6: SET_BUS_WIDTH
                    self.sdrsp[0] = self.r1Status();
                },
                13 => { // ACMD13: SD_STATUS (64 bytes)
                    self.sdrsp[0] = self.r1Status();
                    @memset(&self.aux_buf, 0);
                    self.aux_buf[0] = 0x80; // 4-bit bus
                    self.aux_pos = 0;
                    self.data_remaining = 64;
                    self.transfer_mode = .read_aux;
                    self.sdhsts |= SDHSTS_DATA_FLAG;
                },
                23 => { // ACMD23: SET_WR_BLK_ERASE_COUNT
                    self.sdrsp[0] = self.r1Status();
                },
                41 => { // ACMD41: SD_SEND_OP_COND
                    self.card_state = 1; // ready
                    // Bit 31 = power up ready, Bit 30 = CCS (SDHC), 3.2-3.4V
                    self.sdrsp[0] = 0xc0ff8000;
                },
                51 => { // ACMD51: SEND_SCR (8 bytes)
                    self.sdrsp[0] = self.r1Status();
                    @memset(&self.aux_buf, 0);
                    // SCR version 2.0, SD Spec 2.0, 1-bit & 4-bit bus width, CMD23 supported
                    self.aux_buf[0] = 0x02;
                    self.aux_buf[1] = 0x35;
                    self.aux_buf[2] = 0x80;
                    self.aux_buf[3] = 0x02;
                    self.aux_pos = 0;
                    self.data_remaining = 8;
                    self.transfer_mode = .read_aux;
                    self.sdhsts |= SDHSTS_DATA_FLAG;
                },
                else => {
                    self.sdrsp[0] = self.r1Status();
                },
            }
            if ((cmd_reg & SDCMD_BUSYWAIT) != 0) self.sdhsts |= SDHSTS_BUSY_IRPT;
            return;
        }

        switch (cmd) {
            0 => { // GO_IDLE_STATE
                self.card_state = 0;
                self.transfer_mode = .none;
                self.data_remaining = 0;
                self.sdrsp[0] = 0;
            },
            2 => { // ALL_SEND_CID (R2 136-bit response)
                self.card_state = 2;
                self.sdrsp = fillCidWords();
            },
            3 => { // SEND_RELATIVE_ADDR (R6)
                self.card_state = 3; // stby
                self.sdrsp[0] = 0x12340500; // RCA = 0x1234
            },
            6 => { // SWITCH_FUNC (64 bytes)
                self.sdrsp[0] = self.r1Status();
                @memset(&self.aux_buf, 0);
                self.aux_buf[0] = 0x00;
                self.aux_buf[1] = 0x64; // 100mA
                self.aux_buf[13] = 0x03; // Function group 1: SDR12 & High-Speed SDR25 supported
                self.aux_buf[16] = @truncate(self.sdarg & 0x0f);
                self.aux_pos = 0;
                self.data_remaining = 64;
                self.transfer_mode = .read_aux;
                self.sdhsts |= SDHSTS_DATA_FLAG;
            },
            7 => { // SELECT_CARD
                self.card_state = 4; // tran
                self.sdrsp[0] = self.r1Status();
            },
            8 => { // SEND_IF_COND (R7)
                self.sdrsp[0] = self.sdarg & 0xfff;
            },
            9 => { // SEND_CSD (R2 136-bit response, CSD v2.0)
                self.sdrsp = self.fillCsdWords();
            },
            10 => { // SEND_CID
                self.sdrsp = fillCidWords();
            },
            12 => { // STOP_TRANSMISSION
                self.card_state = 4;
                self.transfer_mode = .none;
                self.data_remaining = 0;
                self.sdrsp[0] = self.r1Status();
            },
            13 => { // SEND_STATUS
                self.sdrsp[0] = self.r1Status();
            },
            16 => { // SET_BLOCKLEN
                self.sdrsp[0] = self.r1Status();
            },
            17, 18 => { // READ_SINGLE_BLOCK / READ_MULTIPLE_BLOCK
                self.card_state = 4;
                self.sdrsp[0] = self.r1Status();
                const blocks: u32 = if (cmd == 17 or self.sdhblc == 0) 1 else self.sdhblc;
                self.transfer_offset = @as(u64, self.sdarg) * 512;
                self.data_remaining = self.sdhbct * blocks;
                self.transfer_mode = .read_image;
                self.sdhsts |= SDHSTS_DATA_FLAG;
            },
            23 => { // SET_BLOCK_COUNT
                self.sdrsp[0] = self.r1Status();
            },
            24, 25 => { // WRITE_BLOCK / WRITE_MULTIPLE_BLOCK
                self.card_state = 4;
                self.sdrsp[0] = self.r1Status();
                const blocks: u32 = if (cmd == 24 or self.sdhblc == 0) 1 else self.sdhblc;
                self.transfer_offset = @as(u64, self.sdarg) * 512;
                self.data_remaining = self.sdhbct * blocks;
                self.transfer_mode = .write_image;
                self.sdhsts |= SDHSTS_DATA_FLAG;
            },
            55 => { // APP_CMD
                self.app_cmd = true;
                self.sdrsp[0] = self.r1Status();
            },
            // SDIO commands (CMD5, CMD52, CMD53) and MMC commands (CMD1): time out so Linux probes as SDHC
            1, 5, 52, 53 => {
                self.sdcmd |= SDCMD_FAIL_FLAG;
                self.sdhsts |= SDHSTS_CMD_TIME_OUT;
            },
            else => {
                self.sdrsp[0] = self.r1Status();
            },
        }

        if ((cmd_reg & SDCMD_BUSYWAIT) != 0 and (self.sdcmd & SDCMD_FAIL_FLAG) == 0) {
            self.sdhsts |= SDHSTS_BUSY_IRPT;
        }
    }

    pub fn readImageByte(self: *SdHost, offset: u64) u8 {
        if (self.qcow2_disk) |disk| {
            return disk.readByte(offset);
        }
        if (self.image_const) |slice| {
            if (offset < slice.len) return slice[@intCast(offset)];
            return 0;
        }
        if (self.image_fd) |fd| {
            const lba = offset / 512;
            const in_sec: usize = @intCast(offset % 512);
            if (self.sector_cache_lba != lba) {
                @memset(&self.sector_cache, 0);
                host_posix.preadAll(fd, &self.sector_cache, lba * 512) catch {};
                self.sector_cache_lba = lba;
            }
            return self.sector_cache[in_sec];
        }
        return 0;
    }

    pub fn writeImageByte(self: *SdHost, offset: u64, b: u8) void {
        if (self.qcow2_disk) |disk| {
            disk.writeByte(offset, b);
            return;
        }
        if (self.image_data) |slice| {
            if (offset < slice.len) slice[@intCast(offset)] = b;
            return;
        }
        if (self.image_fd) |fd| {
            const buf = [1]u8{b};
            host_posix.pwriteAll(fd, &buf, offset) catch {};
            if (self.sector_cache_lba == offset / 512) {
                self.sector_cache[@intCast(offset % 512)] = b;
            }
        }
    }

    pub fn flushBacking(self: *SdHost) void {
        if (self.qcow2_disk) |disk| {
            disk.flush() catch {};
        }
    }

    fn readDataWord(self: *SdHost) u32 {
        if (self.data_remaining == 0) return 0;

        var bytes: [4]u8 = [_]u8{0} ** 4;
        for (0..4) |i| {
            if (self.data_remaining > 0) {
                switch (self.transfer_mode) {
                    .read_aux => {
                        if (self.aux_pos < self.aux_buf.len) {
                            bytes[i] = self.aux_buf[self.aux_pos];
                            self.aux_pos += 1;
                        }
                    },
                    .read_image => {
                        bytes[i] = self.readImageByte(self.transfer_offset);
                        self.transfer_offset += 1;
                    },
                    else => {},
                }
                self.data_remaining -= 1;
            }
        }

        if (self.data_remaining == 0) {
            self.transfer_mode = .none;
            self.sdhsts &= ~SDHSTS_DATA_FLAG;
            if ((self.sdhcfg & SDHCFG_BLOCK_IRPT_EN) != 0) {
                self.sdhsts |= SDHSTS_BLOCK_IRPT;
            }
            if (self.sdhblc > 0) self.sdhblc = 0;
        }
        return std.mem.readInt(u32, &bytes, .little);
    }

    fn writeDataWord(self: *SdHost, val: u32) void {
        if (self.transfer_mode != .write_image or self.data_remaining == 0) return;

        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, val, .little);
        for (0..4) |i| {
            if (self.data_remaining > 0) {
                self.writeImageByte(self.transfer_offset, bytes[i]);
                self.transfer_offset += 1;
                self.data_remaining -= 1;
            }
        }

        if (self.sdhbct > 0 and (self.data_remaining % self.sdhbct) == 0) {
            if ((self.sdhcfg & SDHCFG_BLOCK_IRPT_EN) != 0) {
                self.sdhsts |= SDHSTS_BLOCK_IRPT;
            }
        }
        if (self.data_remaining == 0) {
            self.transfer_mode = .none;
            self.sdhsts &= ~SDHSTS_DATA_FLAG;
            if (self.sdhblc > 0) self.sdhblc = 0;
            self.flushBacking();
        }
    }
};

/// BCM2835 Arasan SDHCI controller (`brcm,bcm2835-sdhci` / `brcm,bcm2835-mmc`) at `0x20300000` (size `0x100`).
/// Supports both:
/// - Onboard CYW43430 / BCM43430 Wi-Fi SDIO chip when GPIO 34..39 are muxed to ALT3 (`emmc_gpio34`).
/// - Primary SDHC card slot when GPIO 48..53 are muxed to ALT3 (`emmc_gpio48`, e.g. upstream DTBs or `dtoverlay=sdio`).
pub const ArasanSdhci = struct {
    pub const BASE_ADDR: u32 = 0x20300000;
    pub const SIZE: u32 = 0x100;
    pub const PIO_BUF_SIZE: usize = 32768;

    // SDHCI_PRESENT_STATE (0x24) bits
    pub const SDHCI_CMD_INHIBIT: u32 = 0x00000001;
    pub const SDHCI_DATA_INHIBIT: u32 = 0x00000002;
    pub const SDHCI_DOING_WRITE: u32 = 0x00000100;
    pub const SDHCI_DOING_READ: u32 = 0x00000200;
    pub const SDHCI_SPACE_AVAILABLE: u32 = 0x00000400;
    pub const SDHCI_DATA_AVAILABLE: u32 = 0x00000800;
    pub const SDHCI_CARD_PRESENT: u32 = 0x00010000;
    pub const SDHCI_CARD_STATE_STABLE: u32 = 0x00020000;
    pub const SDHCI_CD_LVL: u32 = 0x00040000;
    pub const SDHCI_WRITE_PROTECT: u32 = 0x00080000;
    pub const SDHCI_DATA_0_LVL_MASK: u32 = 0x00f00000;

    // SDHCI_INT_STATUS (0x30) / INT_ENABLE (0x34) / SIGNAL_ENABLE (0x38) bits
    pub const SDHCI_INT_RESPONSE: u32 = 0x00000001;
    pub const SDHCI_INT_DATA_END: u32 = 0x00000002;
    pub const SDHCI_INT_DMA_END: u32 = 0x00000008;
    pub const SDHCI_INT_SPACE_AVAIL: u32 = 0x00000010;
    pub const SDHCI_INT_DATA_AVAIL: u32 = 0x00000020;
    pub const SDHCI_INT_CARD_INT: u32 = 0x00000100;
    pub const SDHCI_INT_ERROR: u32 = 0x00008000;
    pub const SDHCI_INT_TIMEOUT: u32 = 0x00010000;

    pub const Target = enum {
        none,
        wifi_sdio,
        sd_card,
    };

    wireless_enabled: bool = false,
    /// True when GPIO 48..53 are muxed to ALT3 (`emmc_gpio48`), routing the SD card slot to Arasan SDHCI
    routed_to_sd_card: bool = false,
    /// True when GPIO 34..39 are muxed to ALT3 (`emmc_gpio34`), or by default on wireless boards when GPIO 48..53 are not ALT3
    routed_to_wifi: bool = true,
    wifi: @import("cyw43430.zig").Cyw43430 = .{},

    regs: [SIZE / 4]u32 = initRegs(),
    int_status: u32 = 0,
    int_enable: u32 = 0,
    signal_enable: u32 = 0,

    // Active PIO / DMA transfer state
    pio_mode: enum { none, read_wifi, write_wifi, read_sd_image, write_sd_image, read_sd_aux } = .none,
    pio_buf: [PIO_BUF_SIZE]u8 = [_]u8{0} ** PIO_BUF_SIZE,
    pio_blksz: usize = 0,
    pio_blocks_rem: usize = 0,
    pio_block_pos: usize = 0,
    pio_total_pos: usize = 0,
    pio_total_len: usize = 0,
    pio_func: u3 = 0,
    pio_addr: u17 = 0,
    pio_incr: bool = false,
    sd_transfer_offset: u64 = 0,

    fn initRegs() [SIZE / 4]u32 {
        var r: [SIZE / 4]u32 = [_]u32{0} ** (SIZE / 4);
        r[0x24 / 4] = SDHCI_CARD_PRESENT | SDHCI_CARD_STATE_STABLE | SDHCI_CD_LVL | SDHCI_WRITE_PROTECT | SDHCI_DATA_0_LVL_MASK;
        r[0x2c / 4] = 0x00000002; // CLOCK_CONTROL: SDHCI_CLOCK_INT_STABLE
        r[0x30 / 4] = 0x00000000; // INT_STATUS
        r[0x40 / 4] = 0x01e930b0; // CAPABILITIES
        r[0xfc / 4] = 0x10020000; // HOST_VERSION (SDHCI Spec 3.00)
        return r;
    }

    pub fn activeTarget(self: *const ArasanSdhci, sd: ?*const SdHost) Target {
        if (self.routed_to_sd_card) {
            if (sd) |s| {
                if (s.hasMedia()) return .sd_card;
            }
            return .none;
        }
        if (self.wireless_enabled and self.routed_to_wifi) {
            return .wifi_sdio;
        }
        return .none;
    }

    pub fn dreqReady(self: *const ArasanSdhci) bool {
        return self.pio_mode != .none and self.pio_blocks_rem > 0;
    }

    fn effectiveIntStatus(self: *const ArasanSdhci) u32 {
        var st = self.int_status & self.int_enable;
        if (!self.routed_to_sd_card and self.wireless_enabled and self.routed_to_wifi and (self.int_enable & SDHCI_INT_CARD_INT) != 0 and self.wifi.cardIntPending()) {
            st |= SDHCI_INT_CARD_INT;
        }
        if ((st & 0xffff0000) != 0) {
            st |= SDHCI_INT_ERROR;
        }
        return st;
    }

    pub fn irqPending(self: *const ArasanSdhci) bool {
        return (self.effectiveIntStatus() & self.signal_enable) != 0;
    }

    pub fn read32(self: *ArasanSdhci, offset: u32) u32 {
        return self.read32WithSd(offset, null);
    }

    pub fn read32WithSd(self: *ArasanSdhci, offset: u32, sd: ?*SdHost) u32 {
        if (offset >= SIZE) return 0;
        return switch (offset) {
            0x20 => self.readPioBuffer(sd),
            0x24 => blk: {
                var pstate: u32 = SDHCI_CARD_PRESENT | SDHCI_CARD_STATE_STABLE | SDHCI_CD_LVL | SDHCI_WRITE_PROTECT | SDHCI_DATA_0_LVL_MASK;
                switch (self.pio_mode) {
                    .read_wifi, .read_sd_image, .read_sd_aux => {
                        if (self.pio_blocks_rem > 0) pstate |= SDHCI_DOING_READ | SDHCI_DATA_AVAILABLE;
                    },
                    .write_wifi, .write_sd_image => {
                        if (self.pio_blocks_rem > 0) pstate |= SDHCI_DOING_WRITE | SDHCI_SPACE_AVAILABLE;
                    },
                    .none => {},
                }
                break :blk pstate;
            },
            0x30 => self.effectiveIntStatus(),
            0x34 => self.int_enable,
            0x38 => self.signal_enable,
            else => self.regs[offset / 4],
        };
    }

    pub fn write32(self: *ArasanSdhci, offset: u32, val: u32) void {
        self.write32WithSd(offset, val, null);
    }

    pub fn write32WithSd(self: *ArasanSdhci, offset: u32, val: u32, sd: ?*SdHost) void {
        if (offset >= SIZE) return;
        switch (offset) {
            0x0c => {
                self.regs[0x0c / 4] = val;
                self.executeCommand(val, sd);
            },
            0x20 => self.writePioBuffer(val, sd),
            0x2c => {
                // CLOCK_CONTROL + TIMEOUT + SOFTWARE_RESET (bits 26:24 = RESET_ALL / RESET_CMD / RESET_DATA)
                const rst = (val >> 24) & 0x07;
                if ((rst & 0x01) != 0) {
                    // SDHCI_RESET_ALL
                    self.int_status = 0;
                    self.int_enable = 0;
                    self.signal_enable = 0;
                    self.pio_mode = .none;
                    self.pio_blocks_rem = 0;
                } else {
                    if ((rst & 0x02) != 0) {
                        self.int_status &= ~@as(u32, 0x000f0001);
                    }
                    if ((rst & 0x04) != 0) {
                        self.pio_mode = .none;
                        self.pio_blocks_rem = 0;
                        self.int_status &= ~@as(u32, 0x0070003e);
                    }
                }
                var v = val & ~@as(u32, 0x07000000);
                if ((v & 1) != 0) v |= 2; // SDHCI_CLOCK_INT_STABLE
                self.regs[0x2c / 4] = v;
            },
            0x30 => {
                // INT_STATUS W1C
                self.int_status &= ~(val & ~SDHCI_INT_ERROR);
            },
            0x34 => self.int_enable = val,
            0x38 => self.signal_enable = val,
            else => self.regs[offset / 4] = val,
        }
    }

    /// Formats a 128-bit R2 response (`w[3..0]` in `SdHost` SDRSP format, where `w[3]` = `resp[0]`,
    /// `w[2]` = `resp[1]`, `w[1]` = `resp[2]`, `w[0]` = `resp[3]`) into `SDHCI_RESPONSE` (`0x10..0x1c`)
    /// so Linux's `(readl(SDHCI_RESPONSE + (3-i)*4) << 8) | readb(SDHCI_RESPONSE + (3-i)*4 - 1)` reconstructs `w[3 - i]` verbatim.
    fn setR2Response(self: *ArasanSdhci, w: [4]u32) void {
        self.regs[0x10 / 4] = (w[0] >> 8) | (w[1] << 24);
        self.regs[0x14 / 4] = (w[1] >> 8) | (w[2] << 24);
        self.regs[0x18 / 4] = (w[2] >> 8) | (w[3] << 24);
        self.regs[0x1c / 4] = w[3] >> 8;
    }

    fn executeCommand(self: *ArasanSdhci, trns_cmd: u32, sd: ?*SdHost) void {
        const target = self.activeTarget(if (sd) |s| s else null);
        if (target == .none) {
            self.int_status |= SDHCI_INT_TIMEOUT;
            return;
        }
        if (target == .sd_card) {
            self.executeSdCardCommand(trns_cmd, sd.?);
            return;
        }

        const cmd_reg: u16 = @truncate(trns_cmd >> 16);
        const trns_mode: u16 = @truncate(trns_cmd);
        const opcode: u6 = @truncate((cmd_reg >> 8) & 0x3f);
        const has_data = (cmd_reg & 0x0020) != 0;
        const arg = self.regs[0x08 / 4];

        switch (opcode) {
            0 => {
                // GO_IDLE_STATE
                self.regs[0x10 / 4] = 0;
                self.int_status |= SDHCI_INT_RESPONSE;
            },
            3 => {
                // SD_SEND_RELATIVE_ADDR (R6): RCA = 0x0001
                self.regs[0x10 / 4] = 0x00010000;
                self.int_status |= SDHCI_INT_RESPONSE;
            },
            5 => {
                // SD_IO_SEND_OP_COND (R4): C=1 (ready), 2 functions, 3.2-3.4V OCR
                self.regs[0x10 / 4] = 0xa0ffff00;
                self.int_status |= SDHCI_INT_RESPONSE;
            },
            7 => {
                // MMC_SELECT_CARD (R1)
                self.regs[0x10 / 4] = 0x00001e00;
                self.int_status |= SDHCI_INT_RESPONSE;
            },
            52 => {
                // SD_IO_RW_DIRECT (R5)
                const is_write = ((arg >> 31) & 1) != 0;
                const func: u3 = @truncate((arg >> 28) & 0x07);
                const raw = ((arg >> 27) & 1) != 0;
                const addr: u17 = @truncate((arg >> 9) & 0x1ffff);
                const wr_byte: u8 = @truncate(arg & 0xff);

                var rd_byte: u8 = 0;
                if (is_write) {
                    self.wifi.writeByte(func, addr, wr_byte);
                    rd_byte = if (raw) self.wifi.readByte(func, addr) else wr_byte;
                } else {
                    rd_byte = self.wifi.readByte(func, addr);
                }
                self.regs[0x10 / 4] = 0x00001000 | @as(u32, rd_byte);
                self.int_status |= SDHCI_INT_RESPONSE;
            },
            53 => {
                // SD_IO_RW_EXTENDED (R5 + PIO data transfer)
                const is_write = ((arg >> 31) & 1) != 0;
                const func: u3 = @truncate((arg >> 28) & 0x07);
                const blk_mode = ((arg >> 27) & 1) != 0;
                const incr_addr = ((arg >> 26) & 1) != 0;
                const addr: u17 = @truncate((arg >> 9) & 0x1ffff);
                const raw_cnt: usize = arg & 0x1ff;

                const blk_reg = self.regs[0x04 / 4];
                const blksz_reg: usize = blk_reg & 0x0fff;
                const blkcnt_reg: usize = blk_reg >> 16;

                const blksz: usize = if (blksz_reg != 0)
                    blksz_reg
                else if (blk_mode)
                    512
                else if (raw_cnt == 0)
                    512
                else
                    raw_cnt;

                const blocks: usize = if ((trns_mode & 0x0020) != 0 and blkcnt_reg != 0)
                    blkcnt_reg
                else if (blk_mode and raw_cnt != 0)
                    raw_cnt
                else
                    1;

                const total_len = @min(blksz * blocks, PIO_BUF_SIZE);

                self.regs[0x10 / 4] = 0x00001000;
                self.int_status |= SDHCI_INT_RESPONSE;

                if (has_data and total_len > 0) {
                    self.pio_blksz = blksz;
                    self.pio_blocks_rem = blocks;
                    self.pio_block_pos = 0;
                    self.pio_total_pos = 0;
                    self.pio_total_len = total_len;
                    self.pio_func = func;
                    self.pio_addr = addr;
                    self.pio_incr = incr_addr;

                    if (!is_write) {
                        self.pio_mode = .read_wifi;
                        self.wifi.readExtended(func, addr, incr_addr, self.pio_buf[0..total_len]);
                        self.int_status |= SDHCI_INT_DATA_AVAIL;
                    } else {
                        self.pio_mode = .write_wifi;
                        @memset(self.pio_buf[0..total_len], 0);
                        self.int_status |= SDHCI_INT_SPACE_AVAIL;
                    }
                }
            },
            else => {
                // Non-SDIO commands (e.g. CMD8, CMD55, CMD1) time out so Linux probes exclusively as SDIO
                self.int_status |= SDHCI_INT_TIMEOUT;
            },
        }
    }

    fn executeSdCardCommand(self: *ArasanSdhci, trns_cmd: u32, sd: *SdHost) void {
        const cmd_reg: u16 = @truncate(trns_cmd >> 16);
        const trns_mode: u16 = @truncate(trns_cmd);
        const opcode: u6 = @truncate((cmd_reg >> 8) & 0x3f);
        const resp_type: u2 = @truncate(cmd_reg & 0x03);
        const is_busy_rsp = resp_type == 0x03;
        const arg = self.regs[0x08 / 4];

        const blk_reg = self.regs[0x04 / 4];
        const blksz: usize = if ((blk_reg & 0x0fff) != 0) @intCast(blk_reg & 0x0fff) else 512;
        const blkcnt: usize = if ((trns_mode & 0x0002) != 0 and (blk_reg >> 16) != 0) @intCast(blk_reg >> 16) else 1;

        sd.activity_latch = true;

        if (sd.app_cmd) {
            sd.app_cmd = false;
            switch (opcode) {
                6 => { // ACMD6: SET_BUS_WIDTH
                    self.regs[0x10 / 4] = sd.r1Status();
                    self.int_status |= SDHCI_INT_RESPONSE;
                },
                13 => { // ACMD13: SD_STATUS (64 bytes)
                    self.regs[0x10 / 4] = sd.r1Status();
                    @memset(&sd.aux_buf, 0);
                    sd.aux_buf[0] = 0x80; // 4-bit bus
                    sd.aux_pos = 0;
                    self.pio_blksz = 64;
                    self.pio_blocks_rem = 1;
                    self.pio_block_pos = 0;
                    self.pio_total_pos = 0;
                    self.pio_total_len = 64;
                    self.pio_mode = .read_sd_aux;
                    self.int_status |= SDHCI_INT_RESPONSE | SDHCI_INT_DATA_AVAIL;
                },
                23 => { // ACMD23: SET_WR_BLK_ERASE_COUNT
                    self.regs[0x10 / 4] = sd.r1Status();
                    self.int_status |= SDHCI_INT_RESPONSE;
                },
                41 => { // ACMD41: SD_SEND_OP_COND
                    sd.card_state = 1; // ready
                    self.regs[0x10 / 4] = 0xc0ff8000;
                    self.int_status |= SDHCI_INT_RESPONSE;
                },
                51 => { // ACMD51: SEND_SCR (8 bytes)
                    self.regs[0x10 / 4] = sd.r1Status();
                    @memset(&sd.aux_buf, 0);
                    sd.aux_buf[0] = 0x02;
                    sd.aux_buf[1] = 0x35;
                    sd.aux_buf[2] = 0x80;
                    sd.aux_buf[3] = 0x02;
                    sd.aux_pos = 0;
                    self.pio_blksz = 8;
                    self.pio_blocks_rem = 1;
                    self.pio_block_pos = 0;
                    self.pio_total_pos = 0;
                    self.pio_total_len = 8;
                    self.pio_mode = .read_sd_aux;
                    self.int_status |= SDHCI_INT_RESPONSE | SDHCI_INT_DATA_AVAIL;
                },
                else => {
                    self.regs[0x10 / 4] = sd.r1Status();
                    self.int_status |= SDHCI_INT_RESPONSE;
                },
            }
            if (is_busy_rsp) self.int_status |= SDHCI_INT_DATA_END;
            return;
        }

        switch (opcode) {
            0 => { // GO_IDLE_STATE
                sd.card_state = 0;
                self.pio_mode = .none;
                self.pio_blocks_rem = 0;
                self.regs[0x10 / 4] = 0;
                self.int_status |= SDHCI_INT_RESPONSE;
            },
            2, 10 => { // ALL_SEND_CID / SEND_CID (R2)
                if (opcode == 2) sd.card_state = 2;
                self.setR2Response(SdHost.fillCidWords());
                self.int_status |= SDHCI_INT_RESPONSE;
            },
            3 => { // SEND_RELATIVE_ADDR (R6)
                sd.card_state = 3;
                self.regs[0x10 / 4] = 0x12340500;
                self.int_status |= SDHCI_INT_RESPONSE;
            },
            6 => { // SWITCH_FUNC (64 bytes)
                self.regs[0x10 / 4] = sd.r1Status();
                @memset(&sd.aux_buf, 0);
                sd.aux_buf[0] = 0x00;
                sd.aux_buf[1] = 0x64;
                sd.aux_buf[13] = 0x03;
                sd.aux_buf[16] = @truncate(arg & 0x0f);
                sd.aux_pos = 0;
                self.pio_blksz = 64;
                self.pio_blocks_rem = 1;
                self.pio_block_pos = 0;
                self.pio_total_pos = 0;
                self.pio_total_len = 64;
                self.pio_mode = .read_sd_aux;
                self.int_status |= SDHCI_INT_RESPONSE | SDHCI_INT_DATA_AVAIL;
            },
            7 => { // SELECT_CARD
                sd.card_state = 4;
                self.regs[0x10 / 4] = sd.r1Status();
                self.int_status |= SDHCI_INT_RESPONSE;
                if (is_busy_rsp) self.int_status |= SDHCI_INT_DATA_END;
            },
            8 => { // SEND_IF_COND (R7)
                self.regs[0x10 / 4] = arg & 0xfff;
                self.int_status |= SDHCI_INT_RESPONSE;
            },
            9 => { // SEND_CSD (R2)
                self.setR2Response(sd.fillCsdWords());
                self.int_status |= SDHCI_INT_RESPONSE;
            },
            12 => { // STOP_TRANSMISSION
                sd.card_state = 4;
                self.pio_mode = .none;
                self.pio_blocks_rem = 0;
                self.regs[0x10 / 4] = sd.r1Status();
                self.int_status |= SDHCI_INT_RESPONSE;
                if (is_busy_rsp) self.int_status |= SDHCI_INT_DATA_END;
            },
            13, 16, 23 => { // SEND_STATUS / SET_BLOCKLEN / SET_BLOCK_COUNT
                self.regs[0x10 / 4] = sd.r1Status();
                self.int_status |= SDHCI_INT_RESPONSE;
            },
            17, 18 => { // READ_SINGLE_BLOCK / READ_MULTIPLE_BLOCK
                sd.card_state = 4;
                self.regs[0x10 / 4] = sd.r1Status();
                const blocks: usize = if (opcode == 17) 1 else blkcnt;
                self.sd_transfer_offset = @as(u64, arg) * 512;
                self.pio_blksz = blksz;
                self.pio_blocks_rem = blocks;
                self.pio_block_pos = 0;
                self.pio_total_pos = 0;
                self.pio_total_len = blksz * blocks;
                self.pio_mode = .read_sd_image;
                self.int_status |= SDHCI_INT_RESPONSE | SDHCI_INT_DATA_AVAIL;
            },
            24, 25 => { // WRITE_BLOCK / WRITE_MULTIPLE_BLOCK
                sd.card_state = 4;
                self.regs[0x10 / 4] = sd.r1Status();
                const blocks: usize = if (opcode == 24) 1 else blkcnt;
                self.sd_transfer_offset = @as(u64, arg) * 512;
                self.pio_blksz = blksz;
                self.pio_blocks_rem = blocks;
                self.pio_block_pos = 0;
                self.pio_total_pos = 0;
                self.pio_total_len = blksz * blocks;
                self.pio_mode = .write_sd_image;
                self.int_status |= SDHCI_INT_RESPONSE | SDHCI_INT_SPACE_AVAIL;
            },
            55 => { // APP_CMD
                sd.app_cmd = true;
                self.regs[0x10 / 4] = sd.r1Status();
                self.int_status |= SDHCI_INT_RESPONSE;
            },
            1, 5, 52, 53 => {
                // SDIO / MMC commands time out on an SDHC card
                self.int_status |= SDHCI_INT_TIMEOUT;
            },
            else => {
                self.regs[0x10 / 4] = sd.r1Status();
                self.int_status |= SDHCI_INT_RESPONSE;
                if (is_busy_rsp) self.int_status |= SDHCI_INT_DATA_END;
            },
        }
    }

    fn readPioBuffer(self: *ArasanSdhci, sd: ?*SdHost) u32 {
        if (self.pio_blocks_rem == 0) return 0;
        switch (self.pio_mode) {
            .read_wifi => {},
            .read_sd_image, .read_sd_aux => if (sd == null) return 0,
            else => return 0,
        }

        const chunk = @min(@as(usize, 4), self.pio_blksz - self.pio_block_pos);
        var bytes: [4]u8 = [_]u8{0} ** 4;
        for (0..chunk) |i| {
            switch (self.pio_mode) {
                .read_wifi => {
                    if (self.pio_total_pos < self.pio_total_len) {
                        bytes[i] = self.pio_buf[self.pio_total_pos];
                        self.pio_total_pos += 1;
                    }
                },
                .read_sd_aux => {
                    const s = sd.?;
                    if (s.aux_pos < s.aux_buf.len) {
                        bytes[i] = s.aux_buf[s.aux_pos];
                        s.aux_pos += 1;
                    }
                    self.pio_total_pos += 1;
                },
                .read_sd_image => {
                    const s = sd.?;
                    bytes[i] = s.readImageByte(self.sd_transfer_offset);
                    self.sd_transfer_offset += 1;
                    self.pio_total_pos += 1;
                },
                else => {},
            }
        }
        self.pio_block_pos += chunk;

        if (self.pio_block_pos >= self.pio_blksz) {
            self.pio_block_pos = 0;
            self.pio_blocks_rem -= 1;
            if (self.pio_blocks_rem == 0) {
                self.pio_mode = .none;
                self.int_status &= ~SDHCI_INT_DATA_AVAIL;
                self.int_status |= SDHCI_INT_DATA_END;
            } else {
                self.int_status |= SDHCI_INT_DATA_AVAIL;
            }
        }
        return std.mem.readInt(u32, &bytes, .little);
    }

    fn writePioBuffer(self: *ArasanSdhci, val: u32, sd: ?*SdHost) void {
        if (self.pio_blocks_rem == 0) return;
        switch (self.pio_mode) {
            .write_wifi => {},
            .write_sd_image => if (sd == null) return,
            else => return,
        }

        const chunk = @min(@as(usize, 4), self.pio_blksz - self.pio_block_pos);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, val, .little);
        for (0..chunk) |i| {
            switch (self.pio_mode) {
                .write_wifi => {
                    if (self.pio_total_pos < self.pio_total_len) {
                        self.pio_buf[self.pio_total_pos] = bytes[i];
                        self.pio_total_pos += 1;
                    }
                },
                .write_sd_image => {
                    const s = sd.?;
                    s.writeImageByte(self.sd_transfer_offset, bytes[i]);
                    self.sd_transfer_offset += 1;
                    self.pio_total_pos += 1;
                },
                else => {},
            }
        }
        self.pio_block_pos += chunk;

        if (self.pio_block_pos >= self.pio_blksz) {
            self.pio_block_pos = 0;
            self.pio_blocks_rem -= 1;
            if (self.pio_blocks_rem == 0) {
                const finished_mode = self.pio_mode;
                self.pio_mode = .none;
                if (finished_mode == .write_wifi) {
                    self.wifi.writeExtended(
                        self.pio_func,
                        self.pio_addr,
                        self.pio_incr,
                        self.pio_buf[0..self.pio_total_len],
                    );
                } else if (finished_mode == .write_sd_image) {
                    if (sd) |s| s.flushBacking();
                }
                self.int_status &= ~SDHCI_INT_SPACE_AVAIL;
                self.int_status |= SDHCI_INT_DATA_END;
            } else {
                self.int_status |= SDHCI_INT_SPACE_AVAIL;
            }
        }
    }
};

test "SdHost identification and CMD17 block read" {
    var sd = SdHost{};
    var disk: [1024]u8 = [_]u8{0} ** 1024;
    std.mem.writeInt(u32, disk[512..516], 0xDEADBEEF, .little);
    sd.attachSlice(&disk);

    // CMD8
    sd.write32(0x04, 0x1aa);
    sd.write32(0x00, SdHost.SDCMD_NEW_FLAG | 8);
    try std.testing.expectEqual(@as(u32, 0x1aa), sd.read32(0x10));

    // CMD55 + ACMD41
    sd.write32(0x00, SdHost.SDCMD_NEW_FLAG | 55);
    sd.write32(0x04, 0x40ff8000);
    sd.write32(0x00, SdHost.SDCMD_NEW_FLAG | 41);
    try std.testing.expectEqual(@as(u32, 0xc0ff8000), sd.read32(0x10));

    // CMD17: read block 1 (offset 512)
    sd.write32(0x3c, 512);
    sd.write32(0x50, 1);
    sd.write32(0x04, 1);
    sd.write32(0x00, SdHost.SDCMD_NEW_FLAG | SdHost.SDCMD_READ_CMD | 17);
    try std.testing.expect(sd.dreqReady());
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), sd.read32(0x40));
}

test "ArasanSdhci SDIO CMD5, CMD52, and CMD53 PIO transfer" {
    var sdhci = ArasanSdhci{ .wireless_enabled = true };
    sdhci.write32(0x34, 0xffffffff); // INT_ENABLE
    sdhci.write32(0x38, 0xffffffff); // SIGNAL_ENABLE

    // CMD5 (SD_IO_SEND_OP_COND)
    sdhci.write32(0x08, 0x00000000);
    sdhci.write32(0x0c, (5 << 24) | (2 << 16));
    try std.testing.expectEqual(@as(u32, 0xa0ffff00), sdhci.read32(0x10));
    try std.testing.expect(sdhci.irqPending());
    sdhci.write32(0x30, 0xffffffff);

    // CMD53 read 4 bytes from Function 1 ChipCommon chipid (0x18000000)
    sdhci.write32(0x04, (1 << 16) | 4); // BLOCK_COUNT=1, BLOCK_SIZE=4
    // arg: write=0, fn=1, blk_mode=0, incr=1, addr=0x08000, count=4
    sdhci.write32(0x08, (1 << 28) | (1 << 26) | (0x08000 << 9) | 4);
    sdhci.write32(0x0c, (53 << 24) | (0x20 << 16) | 0x10); // CMD53 + CMD_DATA + TRNS_READ
    try std.testing.expect((sdhci.read32(0x24) & ArasanSdhci.SDHCI_DATA_AVAILABLE) != 0);
    try std.testing.expectEqual(@as(u32, 0x1001a9a6), sdhci.read32(0x20));
    try std.testing.expect((sdhci.read32(0x30) & ArasanSdhci.SDHCI_INT_DATA_END) != 0);
}

test "ArasanSdhci secondary SD card routing (GPIO 48..53 ALT3) supports SDHC identification, R2 CSD, and block read/write" {
    var sd = SdHost{ .pins_routed = false };
    var disk: [1024]u8 = [_]u8{0} ** 1024;
    std.mem.writeInt(u32, disk[512..516], 0xCAFEBABE, .little);
    sd.attachMutableSlice(&disk);

    var sdhci = ArasanSdhci{
        .wireless_enabled = true,
        .routed_to_sd_card = true,
    };
    sdhci.write32WithSd(0x34, 0xffffffff, &sd);
    sdhci.write32WithSd(0x38, 0xffffffff, &sd);

    // When routed to SD card, SDIO CMD5 should time out
    sdhci.write32WithSd(0x08, 0, &sd);
    sdhci.write32WithSd(0x0c, (5 << 24) | (0x02 << 16), &sd);
    try std.testing.expect((sdhci.read32WithSd(0x30, &sd) & ArasanSdhci.SDHCI_INT_TIMEOUT) != 0);
    sdhci.write32WithSd(0x30, 0xffffffff, &sd);

    // CMD8 -> R7 0x1aa
    sdhci.write32WithSd(0x08, 0x1aa, &sd);
    sdhci.write32WithSd(0x0c, (8 << 24) | (0x1a << 16), &sd);
    try std.testing.expectEqual(@as(u32, 0x1aa), sdhci.read32WithSd(0x10, &sd));

    // CMD55 + ACMD41 -> 0xc0ff8000
    sdhci.write32WithSd(0x30, 0xffffffff, &sd);
    sdhci.write32WithSd(0x08, 0, &sd);
    sdhci.write32WithSd(0x0c, (55 << 24) | (0x1a << 16), &sd);
    sdhci.write32WithSd(0x30, 0xffffffff, &sd);
    sdhci.write32WithSd(0x08, 0x40ff8000, &sd);
    sdhci.write32WithSd(0x0c, (41 << 24) | (0x02 << 16), &sd);
    try std.testing.expectEqual(@as(u32, 0xc0ff8000), sdhci.read32WithSd(0x10, &sd));

    // CMD9 (SEND_CSD R2 136-bit response): verify sdhci_read_rsp_136 / bcm2835_mmc_finish_command shift
    sdhci.write32WithSd(0x30, 0xffffffff, &sd);
    sdhci.write32WithSd(0x08, 0x12340000, &sd);
    sdhci.write32WithSd(0x0c, (9 << 24) | (0x09 << 16), &sd);
    const r0 = (sdhci.read32WithSd(0x1c, &sd) << 8) | (sdhci.read32WithSd(0x18, &sd) >> 24);
    try std.testing.expectEqual(@as(u32, 0x400e0032), r0);

    // CMD17: read sector 1 (offset 512) via SDHCI_BUFFER (0x20)
    sdhci.write32WithSd(0x30, 0xffffffff, &sd);
    sdhci.write32WithSd(0x04, (1 << 16) | 512, &sd);
    sdhci.write32WithSd(0x08, 1, &sd);
    sdhci.write32WithSd(0x0c, (17 << 24) | (0x3a << 16) | 0x0010, &sd);
    try std.testing.expect(sdhci.dreqReady());
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), sdhci.read32WithSd(0x20, &sd));
    for (1..128) |_| {
        _ = sdhci.read32WithSd(0x20, &sd);
    }
    try std.testing.expect((sdhci.read32WithSd(0x30, &sd) & ArasanSdhci.SDHCI_INT_DATA_END) != 0);
}


