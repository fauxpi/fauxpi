const std = @import("std");
const format_mod = @import("format.zig");
const texture = @import("texture.zig");

/// VideoCore IV Hardware Video Scaler (`brcm,bcm2835-hvs`) at `0x20400000` (size `0x6000`).
/// Parses HVS Display Lists (DLIST) and composites linear & T-tiled DRM planes into the HDMI output buffer.
pub const Hvs = struct {
    pub const BASE_ADDR: u32 = 0x20400000;
    pub const SIZE: u32 = 0x6000;
    pub const DLIST_OFFSET: u32 = 0x2000;
    pub const DLIST_WORDS: usize = 1024;

    pub const SCALER_DISPSTATX_EMPTY: u32 = 1 << 28;
    pub const SCALER_CTL0_END: u32 = 1 << 31;
    pub const SCALER_CTL0_VALID: u32 = 1 << 30;
    pub const SCALER_CTL0_UNITY: u32 = 1 << 4;

    dispctrl: u32 = 1 << 31,
    dispstat: u32 = 0,
    dispectrl: u32 = 0,
    dispprof: u32 = 0,
    dispdither: u32 = 0,
    dispeoln: u32 = 0,
    displist: [3]u32 = .{ 0, 0, 0 },
    displact: [3]u32 = .{ 0, 0, 0 },

    chan_ctrl: [3]u32 = .{ 0, 0, 0 },
    chan_bkgnd: [3]u32 = .{ 0, 0, 0 },
    chan_stat: [3]u32 = .{ SCALER_DISPSTATX_EMPTY, SCALER_DISPSTATX_EMPTY, SCALER_DISPSTATX_EMPTY },
    chan_base: [3]u32 = .{ 0x000003ff, 0x040007ff, 0x08000bff },

    dlist: [DLIST_WORDS]u32 = initDlist(),
    dlist_updated: bool = false,
    frame_count: u6 = 0,

    fn initDlist() [DLIST_WORDS]u32 {
        var d: [DLIST_WORDS]u32 = [_]u32{0} ** DLIST_WORDS;
        d[0] = SCALER_CTL0_END;
        return d;
    }

    pub fn irqPending(self: *const Hvs) bool {
        return self.dispstat != 0;
    }

    pub fn notifyVblank(self: *Hvs) void {
        self.frame_count +%= 1;
        for (0..3) |ch| {
            self.chan_stat[ch] = SCALER_DISPSTATX_EMPTY | (@as(u32, self.frame_count) << 18);
        }
    }

    pub fn read32(self: *const Hvs, offset: u32) u32 {
        if (offset >= DLIST_OFFSET and offset < DLIST_OFFSET + DLIST_WORDS * 4) {
            return self.dlist[(offset - DLIST_OFFSET) / 4];
        }
        return switch (offset) {
            0x0000 => self.dispctrl,
            0x0004 => self.dispstat,
            0x0008 => 0x00001000, // SCALER_DISPID
            0x000c => self.dispectrl,
            0x0010 => self.dispprof,
            0x0014 => self.dispdither,
            0x0018 => self.dispeoln,
            0x0020 => self.displist[0],
            0x0024 => self.displist[1],
            0x0028 => self.displist[2],
            0x002c => 0,
            0x0030 => self.displact[0],
            0x0034 => self.displact[1],
            0x0038 => self.displact[2],
            0x0040 => self.chan_ctrl[0],
            0x0044 => self.chan_bkgnd[0],
            0x0048 => self.chan_stat[0] | SCALER_DISPSTATX_EMPTY,
            0x004c => self.chan_base[0],
            0x0050 => self.chan_ctrl[1],
            0x0054 => self.chan_bkgnd[1],
            0x0058 => self.chan_stat[1] | SCALER_DISPSTATX_EMPTY,
            0x005c => self.chan_base[1],
            0x0060 => self.chan_ctrl[2],
            0x0064 => self.chan_bkgnd[2],
            0x0068 => self.chan_stat[2] | SCALER_DISPSTATX_EMPTY,
            0x006c => self.chan_base[2],
            else => 0,
        };
    }

    pub fn write32(self: *Hvs, offset: u32, val: u32) void {
        if (offset >= DLIST_OFFSET and offset < DLIST_OFFSET + DLIST_WORDS * 4) {
            self.dlist[(offset - DLIST_OFFSET) / 4] = val;
            return;
        }
        switch (offset) {
            0x0000 => self.dispctrl = val,
            0x0004 => self.dispstat &= ~val,
            0x000c => self.dispectrl = val,
            0x0010 => self.dispprof = val,
            0x0014 => self.dispdither = val,
            0x0018 => self.dispeoln = val,
            0x0020 => {
                self.displist[0] = val;
                self.displact[0] = val;
                self.dlist_updated = true;
            },
            0x0024 => {
                self.displist[1] = val;
                self.displact[1] = val;
                self.dlist_updated = true;
            },
            0x0028 => {
                self.displist[2] = val;
                self.displact[2] = val;
                self.dlist_updated = true;
            },
            0x0040 => self.chan_ctrl[0] = val,
            0x0044 => self.chan_bkgnd[0] = val,
            0x0048 => self.chan_stat[0] = (self.chan_stat[0] & ~val) | SCALER_DISPSTATX_EMPTY,
            0x004c => self.chan_base[0] = val,
            0x0050 => self.chan_ctrl[1] = val,
            0x0054 => self.chan_bkgnd[1] = val,
            0x0058 => self.chan_stat[1] = (self.chan_stat[1] & ~val) | SCALER_DISPSTATX_EMPTY,
            0x005c => self.chan_base[1] = val,
            0x0060 => self.chan_ctrl[2] = val,
            0x0064 => self.chan_bkgnd[2] = val,
            0x0068 => self.chan_stat[2] = (self.chan_stat[2] & ~val) | SCALER_DISPSTATX_EMPTY,
            0x006c => self.chan_base[2] = val,
            else => {},
        }
    }

    /// Returns true if any HVS channel has an active display list configured.
    pub fn isActive(self: *const Hvs) bool {
        if ((self.dispctrl & (1 << 31)) == 0) return false;
        for (0..3) |ch| {
            const head = self.displact[ch] & 0x3ff;
            if ((self.dlist[head] & SCALER_CTL0_END) == 0 and (self.dlist[head] & SCALER_CTL0_VALID) != 0) {
                return true;
            }
        }
        return false;
    }

    /// Composites the active HVS display list into `out_argb` (`width * height` pixels of `0xFFRRGGBB`).
    pub fn compositeFrame(self: *const Hvs, ram: []const u8, out_argb: []u32, width: u32, height: u32) bool {
        if (out_argb.len < width * height) return false;

        // Find active channel (HDMI on BCM2835 uses channel 1, fallback to 0 or 2)
        var active_ch: ?usize = null;
        for ([_]usize{ 1, 0, 2 }) |ch| {
            const head = self.displact[ch] & 0x3ff;
            const ctl0 = self.dlist[head];
            if ((ctl0 & SCALER_CTL0_END) == 0 and (ctl0 & SCALER_CTL0_VALID) != 0) {
                active_ch = ch;
                break;
            }
        }
        const ch = active_ch orelse return false;

        const bkgnd = (self.chan_bkgnd[ch] & 0x00FFFFFF) | 0xFF000000;
        @memset(out_argb[0 .. width * height], bkgnd);

        var idx: usize = self.displact[ch] & 0x3ff;
        var planes_drawn: usize = 0;

        while (idx + 7 <= DLIST_WORDS and planes_drawn < 32) {
            const ctl0 = self.dlist[idx];
            if ((ctl0 & SCALER_CTL0_END) != 0) break;
            const entry_words: usize = (ctl0 >> 24) & 0x3f;
            if (entry_words < 7 or idx + entry_words > DLIST_WORDS) break;

            if ((ctl0 & SCALER_CTL0_VALID) != 0) {
                self.compositePlane(ram, out_argb, width, height, idx);
                planes_drawn += 1;
            }
            idx += entry_words;
        }
        return planes_drawn > 0;
    }

    fn compositePlane(
        self: *const Hvs,
        ram: []const u8,
        out_argb: []u32,
        out_w: u32,
        out_h: u32,
        idx: usize,
    ) void {
        const ctl0 = self.dlist[idx];
        const pix_fmt: u4 = @truncate(ctl0 & 0x0f);
        const unity = (ctl0 & SCALER_CTL0_UNITY) != 0;
        const tiling: u2 = @truncate((ctl0 >> 20) & 3);

        const pos0 = self.dlist[idx + 1];
        const dst_x: u32 = pos0 & 0xfff;
        const dst_y: u32 = (pos0 >> 12) & 0xfff;

        const pos2_idx = if (unity) idx + 2 else idx + 3;
        const pos2 = self.dlist[pos2_idx];
        const src_w: u32 = pos2 & 0xfff;
        const src_h: u32 = (pos2 >> 12) & 0xfff;
        const alpha_mode: u2 = @truncate((pos2 >> 30) & 3);

        const dst_w: u32 = if (unity) src_w else (self.dlist[idx + 2] & 0xfff);
        const dst_h: u32 = if (unity) src_h else ((self.dlist[idx + 2] >> 16) & 0xfff);
        if (src_w == 0 or src_h == 0 or dst_w == 0 or dst_h == 0) return;

        const ptr0_idx = if (unity) idx + 4 else idx + 5;
        if (ptr0_idx + 2 >= DLIST_WORDS) return;
        const ptr0 = self.dlist[ptr0_idx] & 0x1FFFFFFF;
        const pitch0 = self.dlist[ptr0_idx + 2];

        const is_565 = (pix_fmt == 0);
        const fmt: format_mod.Format = if (is_565) .rgb565 else .argb8888;
        const cpp: u32 = if (is_565) 2 else 4;
        const linear_pitch: u32 = if ((pitch0 & 0xffff) != 0) (pitch0 & 0xffff) else (src_w * cpp);
        const tiled_w: u32 = if (tiling == 3 and (pitch0 >> 16) != 0)
            ((pitch0 >> 16) & 0xffff) * 32
        else
            src_w;

        const max_dy = @min(dst_y + dst_h, out_h);
        const max_dx = @min(dst_x + dst_w, out_w);
        if (dst_x >= max_dx or dst_y >= max_dy) return;

        var py: u32 = dst_y;
        while (py < max_dy) : (py += 1) {
            const sy: u32 = if (unity) (py - dst_y) else ((py - dst_y) * src_h) / dst_h;
            var px: u32 = dst_x;
            while (px < max_dx) : (px += 1) {
                const sx: u32 = if (unity) (px - dst_x) else ((px - dst_x) * src_w) / dst_w;
                const off = ptr0 + if (tiling == 0)
                    (sy * linear_pitch + sx * cpp)
                else
                    texture.texelOffsetOf(fmt, tiled_w, src_h, sx, sy);

                if (off + cpp > ram.len) continue;

                const src_color: u32 = if (is_565)
                    format_mod.fromRgb565(std.mem.readInt(u16, ram[off..][0..2], .little))
                else
                    std.mem.readInt(u32, ram[off..][0..4], .little);

                const out_idx = py * out_w + px;
                if (alpha_mode == 0 or is_565) {
                    out_argb[out_idx] = src_color | 0xFF000000;
                } else {
                    const a: u32 = (src_color >> 24) & 0xff;
                    if (a == 255) {
                        out_argb[out_idx] = src_color;
                    } else if (a > 0) {
                        const dst_c = out_argb[out_idx];
                        const inv_a = 255 - a;
                        const r = (((src_color >> 16) & 0xff) * a + ((dst_c >> 16) & 0xff) * inv_a) / 255;
                        const g = (((src_color >> 8) & 0xff) * a + ((dst_c >> 8) & 0xff) * inv_a) / 255;
                        const b = ((src_color & 0xff) * a + (dst_c & 0xff) * inv_a) / 255;
                        out_argb[out_idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
                    }
                }
            }
        }
    }
};

test "HVS DLIST plane compositing" {
    var hvs = Hvs{};
    var ram: [1024]u8 = [_]u8{0} ** 1024;

    // 2x2 Linear XRGB8888 plane at 0x100 with green pixels
    for (0..4) |i| {
        std.mem.writeInt(u32, ram[0x100 + i * 4 ..][0..4], 0xff00ff00, .little);
    }

    // Write DLIST entry at slot 16
    // ctl0: VALID | UNITY | format=4 (RGBA8888) | size=7 words
    hvs.write32(Hvs.DLIST_OFFSET + 16 * 4, Hvs.SCALER_CTL0_VALID | Hvs.SCALER_CTL0_UNITY | (7 << 24) | 4);
    // pos0: x=0, y=0
    hvs.write32(Hvs.DLIST_OFFSET + 17 * 4, 0);
    // pos2: w=2, h=2, alpha_mode=0
    hvs.write32(Hvs.DLIST_OFFSET + 18 * 4, (2 << 12) | 2);
    // pos3: 0
    hvs.write32(Hvs.DLIST_OFFSET + 19 * 4, 0);
    // ptr0: 0xc0000100
    hvs.write32(Hvs.DLIST_OFFSET + 20 * 4, 0xc0000100);
    // ptr_ctx0: 0
    hvs.write32(Hvs.DLIST_OFFSET + 21 * 4, 0);
    // pitch0: 8 bytes
    hvs.write32(Hvs.DLIST_OFFSET + 22 * 4, 8);
    // End marker at slot 23
    hvs.write32(Hvs.DLIST_OFFSET + 23 * 4, Hvs.SCALER_CTL0_END);

    // Point DISPLIST1 to slot 16
    hvs.write32(0x0024, 16);

    var out: [4]u32 = [_]u32{0} ** 4;
    try std.testing.expect(hvs.compositeFrame(&ram, &out, 2, 2));
    try std.testing.expectEqual(@as(u32, 0xff00ff00), out[0]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), out[3]);
}
