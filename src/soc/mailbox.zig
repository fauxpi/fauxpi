const std = @import("std");
const vc_bus = @import("vc_bus.zig");
const audio_mod = @import("audio.zig");

/// BCM2835 VideoCore Mailbox (`0x2000b880`) and Property Tags (`channel 8`)
/// Also tracks legacy/simple framebuffer configuration if requested by firmware fb drivers.
/// A clock the firmware scales between its `config.txt` `*_freq_min` and `*_freq` settings.
pub const ScaledClock = struct {
    rate_hz: u32,
    min_hz: u32,
    max_hz: u32,

    /// Starts at the maximum.
    pub fn mhz(min: u32, max: u32) ScaledClock {
        return .{ .rate_hz = max * 1_000_000, .min_hz = min * 1_000_000, .max_hz = max * 1_000_000 };
    }

    fn set(self: *ScaledClock, rate_hz: u32) void {
        self.rate_hz = std.math.clamp(rate_hz, self.min_hz, self.max_hz);
    }
};

/// The firmware's default clocks for a board.
pub const BoardClocks = struct {
    arm: ScaledClock,
    core: ScaledClock,
    v3d: ScaledClock,
    h264: ScaledClock,
    isp: ScaledClock,
    sdram: ScaledClock,
};

pub const Mailbox = struct {
    pub const BASE_ADDR: u32 = 0x2000b880;
    pub const SIZE: u32 = 0x40;

    pub const MBOX_FULL: u32 = 0x80000000;
    pub const MBOX_EMPTY: u32 = 0x40000000;
    pub const MBOX_IHAVEDATAIRQEN: u32 = 0x00000001;

    /// Other peripheral state some property tags report on
    pub const Context = struct {
        vchiq: ?*audio_mod.Vchiq = null,
        hdmi_connected: bool = false,
        /// EDID of the attached HDMI display (one or more 128-byte blocks)
        hdmi_edid: []const u8 = &.{},
    };

    /// Response FIFO (up to 16 entries)
    fifo: [16]u32 = @splat(0),
    fifo_head: u4 = 0,
    fifo_tail: u4 = 0,
    fifo_count: u5 = 0,

    config: u32 = 0,

    /// Unhandled property tags already reported (each is logged once per boot)
    unknown_tags: [32]u32 = @splat(0),
    unknown_tag_count: u8 = 0,
    /// Set whenever the guest uses a property tag fauxpi does not implement (`--strict` stops on it)
    unsupported_used: bool = false,

    /// Framebuffer state (when allocated via Mailbox channel 1 or Property Tag 0x00040001)
    fb_width: u32 = 1280,
    fb_height: u32 = 720,
    fb_virt_width: u32 = 1280,
    fb_virt_height: u32 = 720,
    fb_depth: u32 = 32,
    // 0 = BGR (bytes B, G, R in memory: x8r8g8b8), the firmware default; 1 = RGB (bytes R, G, B)
    fb_pixel_order: u32 = 0,
    fb_alpha_mode: u32 = 0,
    fb_virt_x: u32 = 0,
    fb_virt_y: u32 = 0,
    fb_bus_addr: u32 = 0x5c100000, // Bus address in VC RAM region (`vc_mem_base + 0x100000`)
    /// Bytes per row when it is not `fb_width * bytes per pixel` (a firmware KMS plane); 0 = packed
    fb_pitch: u32 = 0,
    fb_allocated: bool = false,

    /// The VideoCore's share of SDRAM at the top (`gpu_mem`); the ARM has everything below it.
    vc_mem_base: u32 = 0x1c000000,
    vc_mem_size: u32 = 0x04000000,
    /// Bump allocator for VC GPU memory allocations (Property Tag 0x0003000c)
    vc_alloc_next: u32 = 0x1d000000,

    /// Tracked clock rates (modifiable by Set Clock Rate tag)
    /// Clocks the firmware scales (Pi Zero defaults until `setBoardClocks`)
    clocks: BoardClocks = .{
        .arm = .mhz(700, 1000),
        .core = .mhz(250, 400),
        .v3d = .mhz(250, 300),
        .h264 = .mhz(250, 300),
        .isp = .mhz(250, 300),
        .sdram = .mhz(400, 450),
    },
    uart_rate_hz: u32 = 48_000_000,
    emmc_rate_hz: u32 = 250_000_000,
    pixel_rate_hz: u32 = 74_250_000,

    board_revision: u32 = 0x00900093,
    board_serial: u64 = 0x00000000fa000001,
    mac_address: [6]u8 = .{ 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56 },
    temperature_mc: u32 = 42_000,

    /// Firmware GPIO expander state (pins 128..135; 128 = ACT LED, 130 = active-low PWR LED on Pi 3 B+, 135 = PWR LED)
    exp_gpio_state: [8]u1 = .{ 0, 1, 0, 1, 1, 1, 1, 1 },
    exp_act_latch: bool = false,

    /// Sets the board's clocks. They start at their maximum: the firmware runs in turbo from boot
    /// (`initial_turbo`) until cpufreq sets a frequency.
    pub fn setBoardClocks(self: *Mailbox, clocks: BoardClocks) void {
        self.clocks = clocks;
    }

    /// Fixes the VPU core clock at `hz`, as the firmware does with `enable_uart=1` when the mini
    /// UART, whose baud rate follows the core clock, is the primary UART.
    pub fn fixCoreClock(self: *Mailbox, hz: u32) void {
        self.clocks.core = .{ .rate_hz = hz, .min_hz = hz, .max_hz = hz };
    }

    /// Splits SDRAM between the ARM (`arm_bytes` from address 0) and the VideoCore (`vc_bytes` above
    /// it), placing the firmware's framebuffer and GPU allocations in the VideoCore's share.
    pub fn setMemorySplit(self: *Mailbox, arm_bytes: u32, vc_bytes: u32) void {
        self.vc_mem_base = arm_bytes;
        self.vc_mem_size = vc_bytes;
        self.fb_bus_addr = 0x40000000 | (arm_bytes + 0x100000);
        self.vc_alloc_next = arm_bytes + 0x1000000;
    }

    pub fn irqPending(self: *const Mailbox) bool {
        return (self.config & MBOX_IHAVEDATAIRQEN) != 0 and self.fifo_count > 0;
    }

    /// Shows the primary plane of display 0 (fauxpi's HDMI output) through the framebuffer. A plane with
    /// no size or buffer is a blank. Other planes (overlays, cursor) are not composited.
    fn setFirmwareKmsPlane(self: *Mailbox, plane: *const [60]u8) void {
        const plane_id = plane[1];
        if (plane_id != 0) return;
        const width = std.mem.readInt(u16, plane[4..6], .little);
        const height = std.mem.readInt(u16, plane[6..8], .little);
        const row_bytes = std.mem.readInt(u16, plane[8..10], .little);
        const num_planes = plane[37];
        const buffer = std.mem.readInt(u32, plane[40..44], .little);
        if (width == 0 or height == 0 or num_planes == 0 or row_bytes < width * 2) {
            self.fb_allocated = false;
            return;
        }
        // Bytes per pixel from the pitch (RGB565 or 32-bit XRGB/ARGB, as fbdev and DRM clients use)
        self.fb_depth = if (row_bytes >= @as(u32, width) * 4) 32 else 16;
        self.fb_width = width;
        self.fb_height = height;
        self.fb_pitch = row_bytes;
        self.fb_bus_addr = buffer;
        self.fb_allocated = true;
    }

    /// Bytes per framebuffer row.
    pub fn rowBytes(self: *const Mailbox) u32 {
        return if (self.fb_pitch != 0) self.fb_pitch else self.fb_width * (self.fb_depth / 8);
    }

    fn reportUnknownTag(self: *Mailbox, tag_id: u32) void {
        self.unsupported_used = true;
        for (self.unknown_tags[0..self.unknown_tag_count]) |t| {
            if (t == tag_id) return;
        }
        if (self.unknown_tag_count < self.unknown_tags.len) {
            self.unknown_tags[self.unknown_tag_count] = tag_id;
            self.unknown_tag_count += 1;
        }
        std.debug.print("fauxpi: mailbox: unsupported firmware property tag 0x{x:0>8}\n", .{tag_id});
    }

    fn pushResponse(self: *Mailbox, val: u32) void {
        if (self.fifo_count < 16) {
            self.fifo[self.fifo_tail] = val;
            self.fifo_tail +%= 1;
            self.fifo_count += 1;
        }
    }

    fn popResponse(self: *Mailbox) u32 {
        if (self.fifo_count == 0) return 0;
        const val = self.fifo[self.fifo_head];
        self.fifo_head +%= 1;
        self.fifo_count -= 1;
        return val;
    }

    pub fn read32(self: *Mailbox, offset: u32) u32 {
        return switch (offset) {
            0x00 => self.popResponse(), // MBOX0_READ
            0x10 => if (self.fifo_count > 0) self.fifo[self.fifo_head] else 0, // MBOX0_PEEK
            0x14 => 0, // MBOX0_SENDER
            0x18 => if (self.fifo_count == 0) MBOX_EMPTY else 0, // MBOX0_STATUS
            0x1c => self.config, // MBOX0_CONFIG
            0x38 => 0, // MBOX1_STATUS (never full)
            else => 0,
        };
    }

    pub fn write32(self: *Mailbox, offset: u32, val: u32, ram: []u8) void {
        self.write32WithContext(offset, val, ram, .{});
    }

    pub fn write32WithContext(self: *Mailbox, offset: u32, val: u32, ram: []u8, ctx: Context) void {
        switch (offset) {
            0x00, 0x20 => {
                const channel: u4 = @truncate(val & 0xF);
                const data_bus = val & ~@as(u32, 0xF);
                const phys = data_bus & vc_bus.ramMask(ram.len);
                if (channel == 8) {
                    self.processPropertyTags(phys, ram, ctx);
                } else if (channel == 1) {
                    self.processLegacyFramebuffer(phys, ram);
                }
                self.pushResponse(val);
            },
            0x1c => {
                self.config = val;
            },
            else => {},
        }
    }

    fn processLegacyFramebuffer(self: *Mailbox, phys: u32, ram: []u8) void {
        if (phys + 40 > ram.len) return;
        const width = std.mem.readInt(u32, ram[phys..][0..4], .little);
        const height = std.mem.readInt(u32, ram[phys + 4 ..][0..4], .little);
        const vwidth = std.mem.readInt(u32, ram[phys + 8 ..][0..4], .little);
        const vheight = std.mem.readInt(u32, ram[phys + 12 ..][0..4], .little);
        const depth = std.mem.readInt(u32, ram[phys + 20 ..][0..4], .little);
        if (width > 0 and height > 0) {
            self.fb_width = width;
            self.fb_height = height;
            self.fb_virt_width = if (vwidth > 0) vwidth else width;
            self.fb_virt_height = if (vheight > 0) vheight else height;
            self.fb_depth = if (depth > 0) depth else 32;
            self.fb_allocated = true;
            self.fb_pitch = 0;
            const pitch = self.fb_width * (self.fb_depth / 8);
            const size = pitch * self.fb_virt_height;
            std.mem.writeInt(u32, ram[phys + 16 ..][0..4], pitch, .little);
            std.mem.writeInt(u32, ram[phys + 32 ..][0..4], self.fb_bus_addr, .little);
            std.mem.writeInt(u32, ram[phys + 36 ..][0..4], size, .little);
        }
    }

    fn getClockRate(self: *Mailbox, clock_id: u32) u32 {
        return switch (clock_id) {
            1 => self.emmc_rate_hz, // EMMC
            2 => self.uart_rate_hz, // UART
            9 => self.pixel_rate_hz, // PIXEL
            10 => 100_000_000, // PWM
            12 => 250_000_000, // EMMC2
            else => if (self.scaledClock(clock_id)) |c| c.rate_hz else 250_000_000,
        };
    }

    /// The clocks the firmware scales: ARM, CORE, V3D, H264, ISP and SDRAM.
    fn scaledClock(self: *Mailbox, clock_id: u32) ?*ScaledClock {
        return switch (clock_id) {
            3 => &self.clocks.arm,
            4 => &self.clocks.core,
            5 => &self.clocks.v3d,
            6 => &self.clocks.h264,
            7 => &self.clocks.isp,
            8 => &self.clocks.sdram,
            else => null,
        };
    }

    fn processPropertyTags(self: *Mailbox, phys: u32, ram: []u8, ctx: Context) void {
        if (phys + 12 > ram.len) return;
        const total_size = std.mem.readInt(u32, ram[phys..][0..4], .little);
        if (total_size < 12 or phys + total_size > ram.len) return;

        // Mark buffer as successful response
        std.mem.writeInt(u32, ram[phys + 4 ..][0..4], 0x80000000, .little);

        var pos: u32 = phys + 8;
        const end: u32 = phys + total_size;

        while (pos + 12 <= end) {
            const tag_id = std.mem.readInt(u32, ram[pos..][0..4], .little);
            if (tag_id == 0) break;

            const buf_size = std.mem.readInt(u32, ram[pos + 4 ..][0..4], .little);
            const payload = pos + 12;
            if (payload + buf_size > end) break;

            var resp_len: u32 = buf_size;
            var handled = true;

            const readU32 = struct {
                fn f(mem: []const u8, p: u32, off: u32, sz: u32) u32 {
                    if (off + 4 > sz) return 0;
                    return std.mem.readInt(u32, mem[p + off ..][0..4], .little);
                }
            }.f;
            const writeU32 = struct {
                fn f(mem: []u8, p: u32, off: u32, sz: u32, v: u32) void {
                    if (off + 4 <= sz) {
                        std.mem.writeInt(u32, mem[p + off ..][0..4], v, .little);
                    }
                }
            }.f;

            switch (tag_id) {
                0x00000001 => { // Get firmware revision
                    writeU32(ram, payload, 0, buf_size, 0x6187b965);
                    resp_len = 4;
                },
                0x00000002 => { // Get firmware variant (1 = start.elf)
                    writeU32(ram, payload, 0, buf_size, 1);
                    resp_len = 4;
                },
                0x00000003 => { // Get firmware hash (5 words; fauxpi has no firmware build to report)
                    for (0..5) |i| writeU32(ram, payload, @intCast(i * 4), buf_size, 0);
                    resp_len = 20;
                },
                0x00010001 => { // Get board model
                    writeU32(ram, payload, 0, buf_size, 0);
                    resp_len = 4;
                },
                0x00010002 => { // Get board revision (0x00900093 = Pi Zero v1.3, 0x00902120 = Pi Zero 2 W v1.0)
                    writeU32(ram, payload, 0, buf_size, self.board_revision);
                    resp_len = 4;
                },
                0x00010003 => { // Get board MAC address
                    if (buf_size >= 6) {
                        @memcpy(ram[payload .. payload + 6], &self.mac_address);
                    }
                    resp_len = 6;
                },
                0x00010004 => { // Get board serial
                    writeU32(ram, payload, 0, buf_size, @truncate(self.board_serial));
                    writeU32(ram, payload, 4, buf_size, @truncate(self.board_serial >> 32));
                    resp_len = 8;
                },
                0x00010005 => { // Get ARM memory
                    writeU32(ram, payload, 0, buf_size, 0x00000000);
                    writeU32(ram, payload, 4, buf_size, self.vc_mem_base);
                    resp_len = 8;
                },
                0x00010006 => { // Get VC memory
                    writeU32(ram, payload, 0, buf_size, self.vc_mem_base);
                    writeU32(ram, payload, 4, buf_size, self.vc_mem_size);
                    resp_len = 8;
                },
                0x00010007 => { // Get clocks (parent, id pairs for clock IDs 1..16)
                    var off: u32 = 0;
                    var clk_id: u32 = 1;
                    while (clk_id <= 16 and off + 8 <= buf_size) : ({
                        clk_id += 1;
                        off += 8;
                    }) {
                        writeU32(ram, payload, off, buf_size, 0); // parent = 0
                        writeU32(ram, payload, off + 4, buf_size, clk_id);
                    }
                    resp_len = off;
                },
                0x00020001, 0x00028001 => { // Get/Set power state
                    const dev_id = readU32(ram, payload, 0, buf_size);
                    const req_state = readU32(ram, payload, 4, buf_size);
                    const state = if (tag_id == 0x00028001) (req_state & 1) else 1;
                    writeU32(ram, payload, 0, buf_size, dev_id);
                    writeU32(ram, payload, 4, buf_size, state);
                    resp_len = 8;
                },
                0x00030001, 0x00038001 => { // Get/Set clock state
                    const clk_id = readU32(ram, payload, 0, buf_size);
                    writeU32(ram, payload, 0, buf_size, clk_id);
                    writeU32(ram, payload, 4, buf_size, 1); // On & exists
                    resp_len = 8;
                },
                0x00030002, 0x00030047 => { // Get clock rate / Get clock measured
                    const clk_id = readU32(ram, payload, 0, buf_size);
                    writeU32(ram, payload, 0, buf_size, clk_id);
                    writeU32(ram, payload, 4, buf_size, self.getClockRate(clk_id));
                    resp_len = 8;
                },
                0x00038002 => { // Set clock rate
                    const clk_id = readU32(ram, payload, 0, buf_size);
                    const rate = readU32(ram, payload, 4, buf_size);
                    if (rate > 0) {
                        switch (clk_id) {
                            1 => self.emmc_rate_hz = rate,
                            2 => self.uart_rate_hz = rate,
                            9 => self.pixel_rate_hz = rate,
                            else => if (self.scaledClock(clk_id)) |c| c.set(rate),
                        }
                    }
                    writeU32(ram, payload, 0, buf_size, clk_id);
                    writeU32(ram, payload, 4, buf_size, self.getClockRate(clk_id));
                    resp_len = 8;
                },
                0x00030004 => { // Get max clock rate
                    const clk_id = readU32(ram, payload, 0, buf_size);
                    const max_rate: u32 = if (self.scaledClock(clk_id)) |c| c.max_hz else switch (clk_id) {
                        9 => 162_000_000,
                        else => self.getClockRate(clk_id),
                    };
                    writeU32(ram, payload, 0, buf_size, clk_id);
                    writeU32(ram, payload, 4, buf_size, max_rate);
                    resp_len = 8;
                },
                0x00030007 => { // Get min clock rate
                    const clk_id = readU32(ram, payload, 0, buf_size);
                    const min_rate: u32 = if (self.scaledClock(clk_id)) |c| c.min_hz else switch (clk_id) {
                        9 => 25_000_000,
                        else => self.getClockRate(clk_id),
                    };
                    writeU32(ram, payload, 0, buf_size, clk_id);
                    writeU32(ram, payload, 4, buf_size, min_rate);
                    resp_len = 8;
                },
                0x00030003, 0x00030005, 0x00030008, 0x00038003 => { // Voltage
                    const id = readU32(ram, payload, 0, buf_size);
                    writeU32(ram, payload, 0, buf_size, id);
                    writeU32(ram, payload, 4, buf_size, 1_200_000);
                    resp_len = 8;
                },
                0x00030006 => { // Get temperature
                    const id = readU32(ram, payload, 0, buf_size);
                    writeU32(ram, payload, 0, buf_size, id);
                    writeU32(ram, payload, 4, buf_size, self.temperature_mc);
                    resp_len = 8;
                },
                0x0003000a => { // Get max temperature
                    const id = readU32(ram, payload, 0, buf_size);
                    writeU32(ram, payload, 0, buf_size, id);
                    writeU32(ram, payload, 4, buf_size, 85000);
                    resp_len = 8;
                },
                0x0003000c => { // Allocate VC memory -> returns handle
                    const size = readU32(ram, payload, 0, buf_size);
                    const align_val = @max(readU32(ram, payload, 4, buf_size), 4096);
                    const aligned = (self.vc_alloc_next + align_val - 1) & ~(align_val - 1);
                    self.vc_alloc_next = aligned + size;
                    writeU32(ram, payload, 0, buf_size, aligned);
                    resp_len = 4;
                },
                0x0003000d => { // Lock VC memory -> returns bus address
                    const handle = readU32(ram, payload, 0, buf_size);
                    writeU32(ram, payload, 0, buf_size, handle | 0x40000000);
                    resp_len = 4;
                },
                0x0003000e, 0x0003000f => { // Unlock / Release VC memory -> status 0
                    writeU32(ram, payload, 0, buf_size, 0);
                    resp_len = 4;
                },
                0x00030014 => { // Execute QPU -> status 0 (enabled)
                    writeU32(ram, payload, 0, buf_size, 0);
                    resp_len = 4;
                },
                0x00030030, 0x00038030 => { // Get/Set domain state (raspberrypi-power)
                    const dom = readU32(ram, payload, 0, buf_size);
                    writeU32(ram, payload, 0, buf_size, dom);
                    writeU32(ram, payload, 4, buf_size, 1);
                    resp_len = 8;
                },
                0x00030041, 0x00038041 => { // Get/Set GPIO state (expander/firmware GPIO)
                    const gpio = readU32(ram, payload, 0, buf_size);
                    const val = readU32(ram, payload, 4, buf_size);
                    var cur: u32 = 0;
                    if (gpio >= 128 and gpio < 136) {
                        const idx: usize = gpio - 128;
                        if (tag_id == 0x00038041) {
                            self.exp_gpio_state[idx] = if (val != 0) 1 else 0;
                            if (idx == 0 and val != 0) self.exp_act_latch = true;
                        }
                        cur = self.exp_gpio_state[idx];
                    } else if (tag_id == 0x00038041) {
                        cur = val;
                    }
                    writeU32(ram, payload, 0, buf_size, 0); // status = 0 (success)
                    writeU32(ram, payload, 4, buf_size, cur);
                    resp_len = 8;
                },
                0x00030043, 0x00038043 => { // Get/Set GPIO config (expander/firmware GPIO)
                    const gpio = readU32(ram, payload, 0, buf_size);
                    if (tag_id == 0x00038043 and gpio >= 128 and gpio < 136) {
                        const idx: usize = gpio - 128;
                        const dir = readU32(ram, payload, 4, buf_size);
                        const state = readU32(ram, payload, 20, buf_size);
                        if (dir != 0) {
                            self.exp_gpio_state[idx] = if (state != 0) 1 else 0;
                            if (idx == 0 and state != 0) self.exp_act_latch = true;
                        }
                    }
                    writeU32(ram, payload, 0, buf_size, 0); // status = 0 (success)
                    if (tag_id == 0x00030043) {
                        writeU32(ram, payload, 4, buf_size, 1); // direction = OUT
                        writeU32(ram, payload, 8, buf_size, 0); // polarity = active-high
                        writeU32(ram, payload, 12, buf_size, 0);
                        writeU32(ram, payload, 16, buf_size, 0);
                        resp_len = 20;
                    } else {
                        resp_len = 24;
                    }
                },
                0x00038042 => { // Set SDHOST clock
                    const req_clk = readU32(ram, payload, 0, buf_size);
                    const actual_clk: u32 = if (req_clk > 0) req_clk else 400_000;
                    writeU32(ram, payload, 0, buf_size, req_clk);
                    writeU32(ram, payload, 4, buf_size, actual_clk);
                    writeU32(ram, payload, 8, buf_size, actual_clk);
                    resp_len = 12;
                },
                0x00030046 => { // Get throttled
                    writeU32(ram, payload, 0, buf_size, 0);
                    resp_len = 4;
                },
                0x00040001 => { // Allocate framebuffer
                    self.fb_allocated = true;
                    self.fb_pitch = 0;
                    const pitch = self.fb_width * (self.fb_depth / 8);
                    const fb_size = pitch * self.fb_virt_height;
                    writeU32(ram, payload, 0, buf_size, self.fb_bus_addr);
                    writeU32(ram, payload, 4, buf_size, fb_size);
                    resp_len = 8;
                },
                0x00048001 => { // Release framebuffer
                    self.fb_allocated = false;
                    resp_len = 0;
                },
                0x00040002 => { // Blank screen
                    writeU32(ram, payload, 0, buf_size, 0);
                    resp_len = 4;
                },
                0x00040003, 0x00044003, 0x00048003 => { // Physical display width/height
                    if (tag_id == 0x00048003) {
                        const w = readU32(ram, payload, 0, buf_size);
                        const h = readU32(ram, payload, 4, buf_size);
                        if (w > 0 and h > 0) {
                            self.fb_width = w;
                            self.fb_height = h;
                        }
                    }
                    writeU32(ram, payload, 0, buf_size, self.fb_width);
                    writeU32(ram, payload, 4, buf_size, self.fb_height);
                    resp_len = 8;
                },
                0x00040004, 0x00044004, 0x00048004 => { // Virtual buffer width/height
                    if (tag_id == 0x00048004) {
                        const w = readU32(ram, payload, 0, buf_size);
                        const h = readU32(ram, payload, 4, buf_size);
                        if (w > 0 and h > 0) {
                            self.fb_virt_width = w;
                            self.fb_virt_height = h;
                        }
                    }
                    writeU32(ram, payload, 0, buf_size, self.fb_virt_width);
                    writeU32(ram, payload, 4, buf_size, self.fb_virt_height);
                    resp_len = 8;
                },
                0x00040005, 0x00044005, 0x00048005 => { // Depth
                    if (tag_id == 0x00048005) {
                        const d = readU32(ram, payload, 0, buf_size);
                        if (d > 0) self.fb_depth = d;
                    }
                    writeU32(ram, payload, 0, buf_size, self.fb_depth);
                    resp_len = 4;
                },
                0x00040006, 0x00044006, 0x00048006 => { // Pixel order
                    if (tag_id == 0x00048006) {
                        self.fb_pixel_order = readU32(ram, payload, 0, buf_size);
                    }
                    writeU32(ram, payload, 0, buf_size, self.fb_pixel_order);
                    resp_len = 4;
                },
                0x00040007, 0x00044007, 0x00048007 => { // Alpha mode
                    if (tag_id == 0x00048007) {
                        self.fb_alpha_mode = readU32(ram, payload, 0, buf_size);
                    }
                    writeU32(ram, payload, 0, buf_size, self.fb_alpha_mode);
                    resp_len = 4;
                },
                0x00040008 => { // Pitch
                    const pitch = self.fb_width * (self.fb_depth / 8);
                    writeU32(ram, payload, 0, buf_size, pitch);
                    resp_len = 4;
                },
                0x00040009, 0x00044009, 0x00048009 => { // Virtual offset
                    if (tag_id == 0x00048009) {
                        self.fb_virt_x = readU32(ram, payload, 0, buf_size);
                        self.fb_virt_y = readU32(ram, payload, 4, buf_size);
                    }
                    writeU32(ram, payload, 0, buf_size, self.fb_virt_x);
                    writeU32(ram, payload, 4, buf_size, self.fb_virt_y);
                    resp_len = 8;
                },
                // Display enumeration and HDMI display information (vc4 firmware KMS, snd_bcm2835).
                // Drivers size arrays and loops from these and pass uninitialised request values,
                // so leaving them unanswered hands back guest garbage.
                0x00040013 => { // Get number of displays
                    writeU32(ram, payload, 0, buf_size, if (ctx.hdmi_connected) 1 else 0);
                    resp_len = 4;
                },
                0x00040016 => { // Get display ID for a display index (DISPMANX_ID_HDMI0 = 2)
                    const index = readU32(ram, payload, 0, buf_size);
                    writeU32(ram, payload, 0, buf_size, if (index == 0) 2 else 0);
                    resp_len = 4;
                },
                0x00048013 => { // Set display number for the following framebuffer tags
                    resp_len = 4;
                },
                0x00040017 => { // Get display timing: clock 0 means no fixed mode, so the driver reads the EDID
                    var off: u32 = 4;
                    while (off < 36) : (off += 4) writeU32(ram, payload, off, buf_size, 0);
                    resp_len = 36;
                },
                0x00040018 => { // Get display config: maximum pixel clock (Hz) for HDMI0 and HDMI1
                    writeU32(ram, payload, 0, buf_size, 162_000_000);
                    writeU32(ram, payload, 4, buf_size, 0);
                    resp_len = 8;
                },
                0x00030020, 0x00030023 => { // Get EDID block (0x00030023: for a display number)
                    // Response: u32 block, u32 status (non-zero = no such block), 128 bytes of EDID.
                    const block = readU32(ram, payload, 0, buf_size);
                    const start = @as(usize, block) * 128;
                    const present = ctx.hdmi_connected and start + 128 <= ctx.hdmi_edid.len;
                    writeU32(ram, payload, 4, buf_size, if (present) 0 else 1);
                    if (buf_size >= 8) {
                        const n = @min(128, buf_size - 8);
                        const dst = ram[payload + 8 ..][0..n];
                        if (present) @memcpy(dst, ctx.hdmi_edid[start..][0..n]) else @memset(dst, 0);
                    }
                    resp_len = 136;
                },
                0x00030066 => { // Notify display done (KMS has taken over the display)
                    resp_len = 0;
                },
                0x00030048 => { // Notify reboot (the kernel is about to restart the SoC)
                    resp_len = 0;
                },
                // Firmware KMS (vc4-fkms-v3d) display control. The HDMI output keeps fauxpi's size, so a
                // mode set and display power are acknowledged; planes are shown through the framebuffer.
                0x00048017 => { // Set display timing
                    resp_len = 36;
                },
                0x00048019 => { // Set display power: u32 display, u32 state
                    resp_len = 8;
                },
                0x00048015 => { // Set plane (struct set_plane, 60 bytes)
                    if (buf_size >= 60) self.setFirmwareKmsPlane(ram[payload..][0..60]);
                    resp_len = 60;
                },
                0x00048010 => { // RPI_FIRMWARE_VCHIQ_INIT
                    const channel_base = readU32(ram, payload, 0, buf_size);
                    const status: u32 = if (ctx.vchiq) |v| v.initSlotZero(channel_base, ram) else 0;
                    writeU32(ram, payload, 0, buf_size, status);
                    resp_len = 4;
                },
                0x00060001 => { // Get DMA channels
                    writeU32(ram, payload, 0, buf_size, 0x00007f35);
                    resp_len = 4;
                },
                else => {
                    // Like the firmware, ignore the tag: the value is left as sent and the response bit clear.
                    self.reportUnknownTag(tag_id);
                    handled = false;
                },
            }

            if (handled) std.mem.writeInt(u32, ram[pos + 8 ..][0..4], 0x80000000 | @min(resp_len, buf_size), .little);
            pos = payload + ((buf_size + 3) & ~@as(u32, 3));
        }
    }
};

test "Mailbox property tags: board revision and clock rate" {
    var mbox = Mailbox{};
    var ram: [1024]u8 = @splat(0);

    // Build a property buffer at phys 0x100 with:
    // Tag 1: 0x00010002 (Board revision, 4 bytes)
    // Tag 2: 0x00030002 (Get clock rate for clock 3 = ARM, 8 bytes)
    const base: u32 = 0x100;
    std.mem.writeInt(u32, ram[base + 0 ..][0..4], 44, .little); // size
    std.mem.writeInt(u32, ram[base + 4 ..][0..4], 0, .little); // request

    // Tag 1
    std.mem.writeInt(u32, ram[base + 8 ..][0..4], 0x00010002, .little);
    std.mem.writeInt(u32, ram[base + 12 ..][0..4], 4, .little);
    std.mem.writeInt(u32, ram[base + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[base + 20 ..][0..4], 0, .little);

    // Tag 2
    std.mem.writeInt(u32, ram[base + 24 ..][0..4], 0x00030002, .little);
    std.mem.writeInt(u32, ram[base + 28 ..][0..4], 8, .little);
    std.mem.writeInt(u32, ram[base + 32 ..][0..4], 4, .little);
    std.mem.writeInt(u32, ram[base + 36 ..][0..4], 3, .little); // clock_id = 3 (ARM)
    std.mem.writeInt(u32, ram[base + 40 ..][0..4], 0, .little);

    // End tag
    std.mem.writeInt(u32, ram[base + 44 ..][0..4], 0, .little);

    mbox.write32(0x20, base | 8, &ram);
    try std.testing.expectEqual(@as(u32, 0), mbox.read32(0x18)); // not empty
    try std.testing.expectEqual(base | 8, mbox.read32(0x00));
    try std.testing.expectEqual(@as(u32, 0x80000000), std.mem.readInt(u32, ram[base + 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x00900093), std.mem.readInt(u32, ram[base + 20 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 1_000_000_000), std.mem.readInt(u32, ram[base + 40 ..][0..4], .little));
}

test "Mailbox property tags: clocks scale within the board's limits" {
    var mbox = Mailbox{};
    var ram: [256]u8 = @splat(0);
    mbox.setBoardClocks(.{
        .arm = .mhz(600, 1400),
        .core = .mhz(250, 400),
        .v3d = .mhz(250, 400),
        .h264 = .mhz(250, 400),
        .isp = .mhz(250, 400),
        .sdram = .mhz(400, 500),
    });

    const Tag = struct {
        fn call(m: *Mailbox, r: *[256]u8, tag: u32, clock_id: u32, rate: u32) u32 {
            const base: u32 = 0x40;
            std.mem.writeInt(u32, r[base + 0 ..][0..4], 32, .little);
            std.mem.writeInt(u32, r[base + 4 ..][0..4], 0, .little);
            std.mem.writeInt(u32, r[base + 8 ..][0..4], tag, .little);
            std.mem.writeInt(u32, r[base + 12 ..][0..4], 8, .little);
            std.mem.writeInt(u32, r[base + 16 ..][0..4], 8, .little);
            std.mem.writeInt(u32, r[base + 20 ..][0..4], clock_id, .little);
            std.mem.writeInt(u32, r[base + 24 ..][0..4], rate, .little);
            std.mem.writeInt(u32, r[base + 28 ..][0..4], 0, .little);
            m.write32(0x20, base | 8, r);
            _ = m.read32(0x00);
            return std.mem.readInt(u32, r[base + 24 ..][0..4], .little);
        }
    };

    try std.testing.expectEqual(@as(u32, 1_400_000_000), Tag.call(&mbox, &ram, 0x00030002, 3, 0)); // turbo from boot
    try std.testing.expectEqual(@as(u32, 1_400_000_000), Tag.call(&mbox, &ram, 0x00030004, 3, 0));
    try std.testing.expectEqual(@as(u32, 600_000_000), Tag.call(&mbox, &ram, 0x00030007, 3, 0));
    try std.testing.expectEqual(@as(u32, 600_000_000), Tag.call(&mbox, &ram, 0x00038002, 3, 100_000_000));
    try std.testing.expectEqual(@as(u32, 1_400_000_000), Tag.call(&mbox, &ram, 0x00038002, 3, 2_000_000_000));
    try std.testing.expectEqual(@as(u32, 500_000_000), Tag.call(&mbox, &ram, 0x00030002, 8, 0));

    // enable_uart=1 with the mini UART primary fixes the core clock
    mbox.fixCoreClock(250_000_000);
    try std.testing.expectEqual(@as(u32, 250_000_000), Tag.call(&mbox, &ram, 0x00030004, 4, 0));
    try std.testing.expectEqual(@as(u32, 250_000_000), Tag.call(&mbox, &ram, 0x00038002, 4, 400_000_000));
}

test "Mailbox property tags: display enumeration" {
    var mbox = Mailbox{};
    var ram: [1024]u8 = @splat(0);

    // Drivers pass uninitialised values in these tags (snd_bcm2835 set_hdmi_enables,
    // vc4 firmware KMS), so the request words are deliberately garbage.
    // Tag 1: 0x00040013 (Get number of displays, 4 bytes)
    // Tag 2: 0x00040016 (Get display ID for index 0, 4 bytes)
    const base: u32 = 0x100;
    std.mem.writeInt(u32, ram[base + 0 ..][0..4], 40, .little); // size
    std.mem.writeInt(u32, ram[base + 4 ..][0..4], 0, .little); // request

    std.mem.writeInt(u32, ram[base + 8 ..][0..4], 0x00040013, .little);
    std.mem.writeInt(u32, ram[base + 12 ..][0..4], 4, .little);
    std.mem.writeInt(u32, ram[base + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[base + 20 ..][0..4], 0xdead_beef, .little);

    std.mem.writeInt(u32, ram[base + 24 ..][0..4], 0x00040016, .little);
    std.mem.writeInt(u32, ram[base + 28 ..][0..4], 4, .little);
    std.mem.writeInt(u32, ram[base + 32 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[base + 36 ..][0..4], 0, .little); // display index 0

    std.mem.writeInt(u32, ram[base + 40 ..][0..4], 0, .little); // end tag

    mbox.write32WithContext(0x20, base | 8, &ram, .{ .hdmi_connected = true });
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ram[base + 20 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, ram[base + 36 ..][0..4], .little));
}

test "Mailbox property tags: unknown tags are ignored like the firmware" {
    var mbox = Mailbox{};
    var ram: [1024]u8 = @splat(0);

    const base: u32 = 0x100;
    std.mem.writeInt(u32, ram[base + 0 ..][0..4], 28, .little); // size
    std.mem.writeInt(u32, ram[base + 4 ..][0..4], 0, .little); // request
    std.mem.writeInt(u32, ram[base + 8 ..][0..4], 0x0004ffff, .little); // unknown tag
    std.mem.writeInt(u32, ram[base + 12 ..][0..4], 4, .little);
    std.mem.writeInt(u32, ram[base + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[base + 20 ..][0..4], 0x1234_5678, .little);
    std.mem.writeInt(u32, ram[base + 24 ..][0..4], 0, .little); // end tag

    mbox.write32(0x20, base | 8, &ram);
    // Buffer succeeds, but the tag keeps its request value and its response bit stays clear.
    try std.testing.expectEqual(@as(u32, 0x80000000), std.mem.readInt(u32, ram[base + 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, ram[base + 16 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), std.mem.readInt(u32, ram[base + 20 ..][0..4], .little));
    try std.testing.expect(mbox.unsupported_used);
}

test "Mailbox property tags: HDMI EDID block for display" {
    var mbox = Mailbox{};
    var ram: [1024]u8 = @splat(0);
    var edid: [256]u8 = undefined;
    for (&edid, 0..) |*b, i| b.* = @truncate(i);

    const base: u32 = 0x100;
    std.mem.writeInt(u32, ram[base + 0 ..][0..4], 12 + 12 + 136 + 4, .little); // size
    std.mem.writeInt(u32, ram[base + 4 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[base + 8 ..][0..4], 0x00030023, .little);
    std.mem.writeInt(u32, ram[base + 12 ..][0..4], 136, .little);
    std.mem.writeInt(u32, ram[base + 16 ..][0..4], 0, .little);
    std.mem.writeInt(u32, ram[base + 20 ..][0..4], 1, .little); // block 1
    std.mem.writeInt(u32, ram[base + 24 ..][0..4], 0, .little); // display 0
    std.mem.writeInt(u32, ram[base + 12 + 12 + 136 ..][0..4], 0, .little); // end tag

    mbox.write32WithContext(0x20, base | 8, &ram, .{ .hdmi_connected = true, .hdmi_edid = &edid });
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, ram[base + 24 ..][0..4], .little)); // status ok
    try std.testing.expectEqualSlices(u8, edid[128..256], ram[base + 28 ..][0..128]);
}

test "Mailbox property tags: firmware KMS plane is shown through the framebuffer" {
    var mbox = Mailbox{};
    var ram: [1024]u8 = @splat(0);

    const base: u32 = 0x100;
    const setPlane = struct {
        fn f(m: *Mailbox, mem: *[1024]u8, plane_id: u8, width: u16, height: u16, row_bytes: u16, buffer: u32) void {
            @memset(mem[base..][0 .. 12 + 12 + 60 + 4], 0);
            std.mem.writeInt(u32, mem[base + 0 ..][0..4], 12 + 12 + 60 + 4, .little);
            std.mem.writeInt(u32, mem[base + 8 ..][0..4], 0x00048015, .little);
            std.mem.writeInt(u32, mem[base + 12 ..][0..4], 60, .little);
            const plane = mem[base + 20 ..][0..60];
            plane[0] = 2; // display (HDMI0)
            plane[1] = plane_id;
            std.mem.writeInt(u16, plane[4..6], width, .little);
            std.mem.writeInt(u16, plane[6..8], height, .little);
            std.mem.writeInt(u16, plane[8..10], row_bytes, .little);
            plane[37] = if (width != 0) 1 else 0; // num_planes
            std.mem.writeInt(u32, plane[40..44], buffer, .little);
            m.write32(0x20, base | 8, mem);
        }
    }.f;

    setPlane(&mbox, &ram, 0, 1024, 768, 4096 + 64, 0xc800_0000);
    try std.testing.expect(mbox.fb_allocated);
    try std.testing.expectEqual(@as(u32, 1024), mbox.fb_width);
    try std.testing.expectEqual(@as(u32, 768), mbox.fb_height);
    try std.testing.expectEqual(@as(u32, 32), mbox.fb_depth);
    try std.testing.expectEqual(@as(u32, 4096 + 64), mbox.rowBytes());
    try std.testing.expectEqual(@as(u32, 0xc800_0000), mbox.fb_bus_addr);

    // Overlay and cursor planes are not composited
    setPlane(&mbox, &ram, 7, 64, 64, 256, 0xc900_0000);
    try std.testing.expectEqual(@as(u32, 0xc800_0000), mbox.fb_bus_addr);

    // Blanking the primary plane (all-zero plane apart from display and plane_id)
    setPlane(&mbox, &ram, 0, 0, 0, 0, 0);
    try std.testing.expect(!mbox.fb_allocated);
    try std.testing.expect(!mbox.unsupported_used);
}
