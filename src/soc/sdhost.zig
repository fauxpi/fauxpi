const std = @import("std");

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

    // Backing storage (either in-memory slice or pread/pwrite file descriptor)
    image_data: ?[]u8 = null,
    image_const: ?[]const u8 = null,
    image_fd: ?std.posix.fd_t = null,
    image_size: u64 = 512 * 1024 * 1024,

    // Active data transfer state
    transfer_mode: enum { none, read_image, write_image, read_aux } = .none,
    transfer_offset: u64 = 0,
    data_remaining: u32 = 0,
    aux_buf: [64]u8 = [_]u8{0} ** 64,
    aux_pos: u32 = 0,
    sector_cache: [512]u8 = [_]u8{0} ** 512,
    sector_cache_lba: u64 = std.math.maxInt(u64),

    pub fn attachSlice(self: *SdHost, data: []const u8) void {
        self.image_const = data;
        self.image_size = data.len;
    }

    pub fn attachMutableSlice(self: *SdHost, data: []u8) void {
        self.image_data = data;
        self.image_const = data;
        self.image_size = data.len;
    }

    pub fn attachFile(self: *SdHost, fd: std.posix.fd_t, size: u64) void {
        self.image_fd = fd;
        self.image_size = size;
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

    fn r1Status(self: *const SdHost) u32 {
        return (@as(u32, self.card_state) << 9) | (1 << 8) | (if (self.app_cmd) @as(u32, 1 << 5) else 0);
    }

    fn executeCommand(self: *SdHost, cmd_reg: u32) void {
        const cmd: u6 = @truncate(cmd_reg & SDCMD_CMD_MASK);
        self.sdhsts &= ~(SDHSTS_CMD_TIME_OUT | SDHSTS_CRC7_ERROR | SDHSTS_CRC16_ERROR | SDHSTS_REW_TIME_OUT);

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
                self.sdrsp[0] = 0x12345601;
                self.sdrsp[1] = 0x30303030;
                self.sdrsp[2] = 0x46585049; // "FXPI"
                self.sdrsp[3] = 0x03534400;
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
                // CSD v2.0: C_SIZE is in bits [69:48] of the 128-bit CSD (where SDRSP3 is [127:96], SDRSP2 is [95:64], SDRSP1 is [63:32], SDRSP0 is [31:0])
                // Note: bcm2835-sdhost shifts R2 response by 8 bits or Linux reads resp[0..3] with SDRSP3=resp[0], SDRSP2=resp[1], SDRSP1=resp[2], SDRSP0=resp[3].
                // In drivers/mmc/host/bcm2835.c:
                // cmd->resp[3 - i] = readl(host->ioaddr + SDRSP0 + i * 4);
                // And Linux UNSTUFF_BITS(resp, 48, 22) extracts C_SIZE from:
                // resp[1] bits [5:0] (top 6 bits of C_SIZE) and resp[2] bits [31:16] (low 16 bits of C_SIZE),
                // where resp[0] = SDRSP3, resp[1] = SDRSP2, resp[2] = SDRSP1, resp[3] = SDRSP0!
                const num_512k_units: u32 = @intCast(@max((self.image_size + (512 * 1024 - 1)) / (512 * 1024), 1));
                const c_size: u32 = num_512k_units - 1;
                self.sdrsp[3] = 0x400e0032; // CSD_STRUCTURE = 1 (v2.0), TAAC=0x0e, TRAN_SPEED=0x32
                self.sdrsp[2] = 0x5b590000 | ((c_size >> 16) & 0x3f); // CCC=0x5b5, READ_BL_LEN=9
                self.sdrsp[1] = (c_size << 16) | 0x7f80; // C_SIZE[15:0] | ERASE_BLK_EN=1, SECTOR_SIZE=0x7f
                self.sdrsp[0] = 0x0a400001; // WRITE_BL_LEN=9
            },
            10 => { // SEND_CID
                self.sdrsp[0] = 0x12345601;
                self.sdrsp[1] = 0x30303030;
                self.sdrsp[2] = 0x46585049;
                self.sdrsp[3] = 0x03534400;
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

    fn readImageByte(self: *SdHost, offset: u64) u8 {
        if (self.image_const) |slice| {
            if (offset < slice.len) return slice[@intCast(offset)];
            return 0;
        }
        if (self.image_fd) |fd| {
            const lba = offset / 512;
            const in_sec: usize = @intCast(offset % 512);
            if (self.sector_cache_lba != lba) {
                @memset(&self.sector_cache, 0);
                _ = std.os.linux.pread(fd, &self.sector_cache, 512, @intCast(lba * 512));
                self.sector_cache_lba = lba;
            }
            return self.sector_cache[in_sec];
        }
        return 0;
    }

    fn writeImageByte(self: *SdHost, offset: u64, b: u8) void {
        if (self.image_data) |slice| {
            if (offset < slice.len) slice[@intCast(offset)] = b;
            return;
        }
        if (self.image_fd) |fd| {
            const buf = [1]u8{b};
            _ = std.os.linux.pwrite(fd, &buf, 1, @intCast(offset));
            if (self.sector_cache_lba == offset / 512) {
                self.sector_cache[@intCast(offset % 512)] = b;
            }
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
        }
    }
};

/// BCM2835 Arasan SDHCI stub (`brcm,bcm2835-sdhci`) at `0x20300000` (size `0x100`).
/// On Pi Zero 1, SD0 uses `bcm2835-sdhost` (`0x20202000`) and Arasan SDHCI has no card attached.
pub const ArasanSdhci = struct {
    pub const BASE_ADDR: u32 = 0x20300000;
    pub const SIZE: u32 = 0x100;

    regs: [SIZE / 4]u32 = initRegs(),

    fn initRegs() [SIZE / 4]u32 {
        var r: [SIZE / 4]u32 = [_]u32{0} ** (SIZE / 4);
        r[0x2c / 4] = 0x00000002; // CLOCK_CONTROL: SDHCI_CLOCK_INT_STABLE
        r[0x30 / 4] = 0x00000000; // INT_STATUS
        r[0x40 / 4] = 0x01e930b0; // CAPABILITIES
        r[0xfc / 4] = 0x10020000; // HOST_VERSION (SDHCI Spec 3.00)
        return r;
    }

    pub fn read32(self: *const ArasanSdhci, offset: u32) u32 {
        if (offset >= SIZE) return 0;
        return self.regs[offset / 4];
    }

    pub fn write32(self: *ArasanSdhci, offset: u32, val: u32) void {
        if (offset >= SIZE) return;
        if (offset == 0x2c) {
            // CLOCK_CONTROL + TIMEOUT + SOFTWARE_RESET: clear reset bits [26:24], set INT_STABLE (bit 1)
            var v = val & ~@as(u32, 0x07000000);
            if ((v & 1) != 0) v |= 2;
            self.regs[offset / 4] = v;
            return;
        }
        if (offset == 0x0c) {
            // TRANSFER_MODE + COMMAND: immediately set command timeout in INT_STATUS (no card attached)
            self.regs[0x30 / 4] |= 0x00018000; // ERR_INT | TIMEOUT_ERR
            return;
        }
        if (offset == 0x30) {
            // INT_STATUS W1C
            self.regs[0x30 / 4] &= ~val;
            return;
        }
        self.regs[offset / 4] = val;
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
