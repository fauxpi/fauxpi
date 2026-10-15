const std = @import("std");

/// BCM2835 VideoCore Mailbox (`0x2000b880`) and Property Tags (`channel 8`)
/// Also tracks legacy/simple framebuffer configuration if requested by firmware fb drivers.
pub const Mailbox = struct {
    pub const BASE_ADDR: u32 = 0x2000b880;
    pub const SIZE: u32 = 0x40;

    pub const MBOX_FULL: u32 = 0x80000000;
    pub const MBOX_EMPTY: u32 = 0x40000000;
    pub const MBOX_IHAVEDATAIRQEN: u32 = 0x00000001;

    /// Response FIFO (up to 16 entries)
    fifo: [16]u32 = [_]u32{0} ** 16,
    fifo_head: u4 = 0,
    fifo_tail: u4 = 0,
    fifo_count: u5 = 0,

    config: u32 = 0,

    /// Framebuffer state (when allocated via Mailbox channel 1 or Property Tag 0x00040001)
    fb_width: u32 = 1280,
    fb_height: u32 = 720,
    fb_virt_width: u32 = 1280,
    fb_virt_height: u32 = 720,
    fb_depth: u32 = 32,
    fb_pixel_order: u32 = 1, // RGB
    fb_alpha_mode: u32 = 0,
    fb_virt_x: u32 = 0,
    fb_virt_y: u32 = 0,
    fb_bus_addr: u32 = 0x5c100000, // Bus address in VC RAM region (phys 0x1c100000)
    fb_allocated: bool = false,

    /// Bump allocator for VC GPU memory allocations (Property Tag 0x0003000c)
    vc_alloc_next: u32 = 0x1d000000,

    /// Tracked clock rates (modifiable by Set Clock Rate tag)
    arm_rate_hz: u32 = 1_000_000_000,
    core_rate_hz: u32 = 250_000_000,
    v3d_rate_hz: u32 = 250_000_000,
    uart_rate_hz: u32 = 48_000_000,
    emmc_rate_hz: u32 = 250_000_000,
    pixel_rate_hz: u32 = 74_250_000,

    board_serial: u64 = 0x00000000fa000001,
    mac_address: [6]u8 = .{ 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56 },

    pub fn irqPending(self: *const Mailbox) bool {
        return (self.config & MBOX_IHAVEDATAIRQEN) != 0 and self.fifo_count > 0;
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
        switch (offset) {
            0x00, 0x20 => {
                const channel: u4 = @truncate(val & 0xF);
                const data_bus = val & ~@as(u32, 0xF);
                const phys = data_bus & 0x1FFFFFFF;
                if (channel == 8) {
                    self.processPropertyTags(phys, ram);
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
            const pitch = self.fb_width * (self.fb_depth / 8);
            const size = pitch * self.fb_virt_height;
            std.mem.writeInt(u32, ram[phys + 16 ..][0..4], pitch, .little);
            std.mem.writeInt(u32, ram[phys + 32 ..][0..4], self.fb_bus_addr, .little);
            std.mem.writeInt(u32, ram[phys + 36 ..][0..4], size, .little);
        }
    }

    fn getClockRate(self: *const Mailbox, clock_id: u32) u32 {
        return switch (clock_id) {
            1 => self.emmc_rate_hz, // EMMC
            2 => self.uart_rate_hz, // UART
            3 => self.arm_rate_hz, // ARM
            4 => self.core_rate_hz, // CORE
            5 => self.v3d_rate_hz, // V3D
            6 => 250_000_000, // H264
            7 => 250_000_000, // ISP
            8 => 400_000_000, // SDRAM
            9 => self.pixel_rate_hz, // PIXEL
            10 => 100_000_000, // PWM
            12 => 250_000_000, // EMMC2
            else => 250_000_000,
        };
    }

    fn processPropertyTags(self: *Mailbox, phys: u32, ram: []u8) void {
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
                0x00010001 => { // Get board model
                    writeU32(ram, payload, 0, buf_size, 0);
                    resp_len = 4;
                },
                0x00010002 => { // Get board revision (Pi Zero v1.3 512MB)
                    writeU32(ram, payload, 0, buf_size, 0x00900093);
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
                    writeU32(ram, payload, 4, buf_size, 0x1c000000);
                    resp_len = 8;
                },
                0x00010006 => { // Get VC memory
                    writeU32(ram, payload, 0, buf_size, 0x1c000000);
                    writeU32(ram, payload, 4, buf_size, 0x04000000);
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
                            3 => self.arm_rate_hz = rate,
                            4 => self.core_rate_hz = rate,
                            5 => self.v3d_rate_hz = rate,
                            9 => self.pixel_rate_hz = rate,
                            else => {},
                        }
                    }
                    writeU32(ram, payload, 0, buf_size, clk_id);
                    writeU32(ram, payload, 4, buf_size, self.getClockRate(clk_id));
                    resp_len = 8;
                },
                0x00030004 => { // Get max clock rate
                    const clk_id = readU32(ram, payload, 0, buf_size);
                    const max_rate: u32 = switch (clk_id) {
                        3 => 1_000_000_000,
                        9 => 162_000_000,
                        else => self.getClockRate(clk_id),
                    };
                    writeU32(ram, payload, 0, buf_size, clk_id);
                    writeU32(ram, payload, 4, buf_size, max_rate);
                    resp_len = 8;
                },
                0x00030007 => { // Get min clock rate
                    const clk_id = readU32(ram, payload, 0, buf_size);
                    const min_rate: u32 = switch (clk_id) {
                        3 => 700_000_000,
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
                    writeU32(ram, payload, 4, buf_size, 42000);
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
                    writeU32(ram, payload, 0, buf_size, gpio);
                    writeU32(ram, payload, 4, buf_size, if (tag_id == 0x00038041) val else 0);
                    resp_len = 8;
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
                0x00060001 => { // Get DMA channels
                    writeU32(ram, payload, 0, buf_size, 0x00007f35);
                    resp_len = 4;
                },
                else => {
                    // Default: leave request payload or zero-fill and mark succeeded
                },
            }

            std.mem.writeInt(u32, ram[pos + 8 ..][0..4], 0x80000000 | @min(resp_len, buf_size), .little);
            pos = payload + ((buf_size + 3) & ~@as(u32, 3));
        }
    }
};

test "Mailbox property tags: board revision and clock rate" {
    var mbox = Mailbox{};
    var ram: [1024]u8 = [_]u8{0} ** 1024;

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
