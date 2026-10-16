const std = @import("std");
const format_mod = @import("format.zig");
const texture = @import("texture.zig");

/// VideoCore IV Hardware Video Scaler (`brcm,bcm2835-hvs`) at `0x20400000` (size `0x6000`).
/// Parses HVS Display Lists (DLIST) and composites linear & T-tiled DRM planes into the HDMI output buffer.
pub const Hvs = struct {
    pub const BASE_ADDR: u32 = 0x20400000;
    pub const SIZE: u32 = 0x6000;
    pub const DLIST_OFFSET: u32 = 0x2000;
    pub const DLIST_WORDS: usize = 4096;
    pub const DLIST_MASK: u32 = DLIST_WORDS - 1;

    pub const SCALER_DISPSTATX_EMPTY: u32 = 1 << 28;
    pub const SCALER_DISPSTATX_MODE_RUN: u32 = 2 << 30;
    pub const SCALER_DISPCTRLX_ENABLE: u32 = 1 << 31;
    pub const SCALER_DISPCTRLX_RESET: u32 = 1 << 30;
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

    fn computeChanStat(self: *const Hvs, ch: usize) u32 {
        const enabled = (self.chan_ctrl[ch] & SCALER_DISPCTRLX_ENABLE) != 0;
        const mode: u32 = if (enabled) SCALER_DISPSTATX_MODE_RUN else 0;
        const fc: u32 = self.frame_count;
        const frcnt_bits: u32 = switch (ch) {
            0 => 0,
            // VC4_GEN_4 stores FRCNT0 in DISPSTAT1[23:18] and FRCNT1 in DISPSTAT1[17:12]
            1 => (fc << 18) | (fc << 12),
            // VC4_GEN_4 stores FRCNT2 in DISPSTAT2[17:12]
            2 => (fc << 12),
            else => 0,
        };
        return mode | SCALER_DISPSTATX_EMPTY | frcnt_bits;
    }

    fn updateDispstatSummaryBits(self: *Hvs) void {
        // SCALER_DISPSTAT_IRQDISP(ch) is BIT(1 + ch), active when any flag in
        // SCALER_DISPSTAT_IRQMASK(ch) (bits [13 + ch*8 : 8 + ch*8]) is set and
        // SCALER_DISPCTRL_DISPEIRQ(ch) (BIT(1 + ch)) is enabled.
        self.dispstat &= ~@as(u32, 0x0e);
        inline for (0..3) |ch| {
            const chan_mask: u32 = @as(u32, 0x3f) << (8 + ch * 8);
            const disp_ie: u32 = @as(u32, 1) << (1 + ch);
            if ((self.dispstat & chan_mask) != 0 and (self.dispctrl & disp_ie) != 0) {
                self.dispstat |= disp_ie;
            }
        }
    }

    pub fn notifyVblank(self: *Hvs) void {
        self.frame_count +%= 1;
        for (0..3) |ch| {
            self.chan_stat[ch] = self.computeChanStat(ch);
        }
        if ((self.dispctrl & (1 << 31)) != 0) {
            inline for (0..3) |ch| {
                // SCALER_DISPCTRL_DSPEIEOF(ch) is BIT(7 + ch * 2)
                const eof_ie: u32 = @as(u32, 1) << (7 + ch * 2);
                // SCALER_DISPCTRL_DSPEIEOLN(ch) is BIT(8 + ch * 2)
                const eoln_ie: u32 = @as(u32, 1) << (8 + ch * 2);
                if ((self.dispctrl & eof_ie) != 0) {
                    // SCALER_DISPSTAT_EOF(ch) is BIT(8 + ch * 8)
                    self.dispstat |= (@as(u32, 1) << (8 + ch * 8));
                }
                if ((self.dispctrl & eoln_ie) != 0) {
                    // SCALER_DISPSTAT_EOLN(ch) is BIT(12 + ch * 8)
                    self.dispstat |= (@as(u32, 1) << (12 + ch * 8));
                }
            }
            self.updateDispstatSummaryBits();
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
            0x0048 => self.computeChanStat(0),
            0x004c => self.chan_base[0],
            0x0050 => self.chan_ctrl[1],
            0x0054 => self.chan_bkgnd[1],
            0x0058 => self.computeChanStat(1),
            0x005c => self.chan_base[1],
            0x0060 => self.chan_ctrl[2],
            0x0064 => self.chan_bkgnd[2],
            0x0068 => self.computeChanStat(2),
            0x006c => self.chan_base[2],
            else => 0,
        };
    }

    pub fn write32(self: *Hvs, offset: u32, val: u32) void {
        if (offset >= DLIST_OFFSET and offset < DLIST_OFFSET + DLIST_WORDS * 4) {
            const slot = (offset - DLIST_OFFSET) / 4;
            if (self.dlist[slot] != val) {
                self.dlist[slot] = val;
                self.dlist_updated = true;
            }
            return;
        }
        switch (offset) {
            0x0000 => {
                self.dispctrl = val;
                self.updateDispstatSummaryBits();
            },
            0x0004 => {
                self.dispstat &= ~val;
                self.updateDispstatSummaryBits();
            },
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
            0x0040 => {
                self.chan_ctrl[0] = val & ~SCALER_DISPCTRLX_RESET;
                self.chan_stat[0] = self.computeChanStat(0);
            },
            0x0044 => self.chan_bkgnd[0] = val,
            0x0048 => self.chan_stat[0] = self.computeChanStat(0),
            0x004c => self.chan_base[0] = val,
            0x0050 => {
                self.chan_ctrl[1] = val & ~SCALER_DISPCTRLX_RESET;
                self.chan_stat[1] = self.computeChanStat(1);
            },
            0x0054 => self.chan_bkgnd[1] = val,
            0x0058 => self.chan_stat[1] = self.computeChanStat(1),
            0x005c => self.chan_base[1] = val,
            0x0060 => {
                self.chan_ctrl[2] = val & ~SCALER_DISPCTRLX_RESET;
                self.chan_stat[2] = self.computeChanStat(2);
            },
            0x0064 => self.chan_bkgnd[2] = val,
            0x0068 => self.chan_stat[2] = self.computeChanStat(2),
            0x006c => self.chan_base[2] = val,
            else => {},
        }
    }

    /// Returns true if any HVS channel has an active display list configured.
    pub fn isActive(self: *const Hvs) bool {
        if ((self.dispctrl & (1 << 31)) == 0) return false;
        for (0..3) |ch| {
            const head = self.displact[ch] & DLIST_MASK;
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
            const head = self.displact[ch] & DLIST_MASK;
            const ctl0 = self.dlist[head];
            if ((ctl0 & SCALER_CTL0_END) == 0 and (ctl0 & SCALER_CTL0_VALID) != 0) {
                active_ch = ch;
                break;
            }
        }
        const ch = active_ch orelse return false;

        var idx: usize = self.displact[ch] & DLIST_MASK;
        var planes_drawn: usize = 0;
        var bkgnd_cleared = false;

        while (idx + 7 <= DLIST_WORDS and planes_drawn < 32) {
            const ctl0 = self.dlist[idx];
            if ((ctl0 & SCALER_CTL0_END) != 0) break;
            const entry_words: usize = (ctl0 >> 24) & 0x3f;
            if (entry_words < 7 or idx + entry_words > DLIST_WORDS) break;

            if ((ctl0 & SCALER_CTL0_VALID) != 0) {
                if (!bkgnd_cleared) {
                    if (!self.planeCoversScreenOpaquely(idx, width, height)) {
                        const bkgnd = (self.chan_bkgnd[ch] & 0x00FFFFFF) | 0xFF000000;
                        @memset(out_argb[0 .. width * height], bkgnd);
                    }
                    bkgnd_cleared = true;
                }
                self.compositePlane(ram, out_argb, width, height, idx);
                planes_drawn += 1;
            }
            idx += entry_words;
        }
        return planes_drawn > 0;
    }

    fn planeCoversScreenOpaquely(self: *const Hvs, idx: usize, out_w: u32, out_h: u32) bool {
        const ctl0 = self.dlist[idx];
        const pix_fmt: u4 = @truncate(ctl0 & 0x0f);
        const unity = (ctl0 & SCALER_CTL0_UNITY) != 0;
        const pos0 = self.dlist[idx + 1];
        const dst_x: u32 = pos0 & 0xfff;
        const dst_y: u32 = (pos0 >> 12) & 0xfff;
        if (dst_x != 0 or dst_y != 0) return false;

        const pos2_idx = if (unity) idx + 2 else idx + 3;
        if (pos2_idx >= DLIST_WORDS) return false;
        const pos2 = self.dlist[pos2_idx];
        const src_w: u32 = pos2 & 0xfff;
        const raw_h16: u32 = (pos2 >> 16) & 0xfff;
        const src_h: u32 = if (raw_h16 != 0) raw_h16 else ((pos2 >> 12) & 0xfff);
        const alpha_mode: u2 = @truncate((pos2 >> 30) & 3);
        const dst_w: u32 = if (unity) src_w else (self.dlist[idx + 2] & 0xfff);
        const dst_h: u32 = if (unity) src_h else ((self.dlist[idx + 2] >> 16) & 0xfff);
        return dst_w >= out_w and dst_h >= out_h and (alpha_mode == 1 or pix_fmt == 0 or pix_fmt == 4);
    }

    inline fn blendPixel(dst_c: u32, src_color: u32, a: u32, premult: bool) u32 {
        const inv_a = 255 - a;
        if (premult) {
            const r: u32 = @min(((src_color >> 16) & 0xff) + (((dst_c >> 16) & 0xff) * inv_a) / 255, @as(u32, 255));
            const g: u32 = @min(((src_color >> 8) & 0xff) + (((dst_c >> 8) & 0xff) * inv_a) / 255, @as(u32, 255));
            const b: u32 = @min((src_color & 0xff) + ((dst_c & 0xff) * inv_a) / 255, @as(u32, 255));
            return 0xFF000000 | (r << 16) | (g << 8) | b;
        } else {
            const r = (((src_color >> 16) & 0xff) * a + ((dst_c >> 16) & 0xff) * inv_a) / 255;
            const g = (((src_color >> 8) & 0xff) * a + ((dst_c >> 8) & 0xff) * inv_a) / 255;
            const b = ((src_color & 0xff) * a + (dst_c & 0xff) * inv_a) / 255;
            return 0xFF000000 | (r << 16) | (g << 8) | b;
        }
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
        const raw_h16: u32 = (pos2 >> 16) & 0xfff;
        const src_h: u32 = if (raw_h16 != 0) raw_h16 else ((pos2 >> 12) & 0xfff);
        const premult = (pos2 & ((1 << 29) | (1 << 28))) != 0;
        const alpha_mode: u2 = @truncate((pos2 >> 30) & 3);

        const dst_w: u32 = if (unity) src_w else (self.dlist[idx + 2] & 0xfff);
        const dst_h: u32 = if (unity) src_h else ((self.dlist[idx + 2] >> 16) & 0xfff);
        if (src_w == 0 or src_h == 0 or dst_w == 0 or dst_h == 0) return;

        const ptr0_idx = if (unity) idx + 4 else idx + 5;
        if (ptr0_idx + 2 >= DLIST_WORDS) return;
        const ptr0 = self.dlist[ptr0_idx] & 0x1FFFFFFF;
        const pitch0 = self.dlist[ptr0_idx + 2];

        const raw_pitch: u32 = pitch0 & 0xffff;
        // HVS_PIXEL_FORMAT_RGB565 is 4 (some legacy bare-metal tests also used 0 for 565)
        const is_565 = (pix_fmt == 0) or (pix_fmt == 4);
        const fmt: format_mod.Format = if (is_565) .rgb565 else .argb8888;
        const cpp: u32 = if (is_565) 2 else 4;
        const linear_pitch: u32 = if (raw_pitch != 0) raw_pitch else (src_w * cpp);
        // For T-tiled planes (SCALER_CTL0_TILING_256B_OR_T = 3), pitch0[6:0] is SCALER_TILE_WIDTH_T
        // in 4KB T-tiles (64 pixels wide for 16bpp RGB565, 32 pixels wide for 32bpp).
        const tile_w_px: u32 = if (is_565) 64 else 32;
        const tiled_w: u32 = if (tiling == 3 and (pitch0 & 0x7f) != 0)
            (pitch0 & 0x7f) * tile_w_px
        else
            src_w;

        const max_dy = @min(dst_y + dst_h, out_h);
        const max_dx = @min(dst_x + dst_w, out_w);
        if (dst_x >= max_dx or dst_y >= max_dy) return;

        // Fast path 1: Unity 32-bit Linear plane
        if (unity and tiling == 0 and !is_565) {
            const span_w = max_dx - dst_x;
            var py: u32 = dst_y;
            while (py < max_dy) : (py += 1) {
                const sy = py - dst_y;
                const row_off = ptr0 + sy * linear_pitch;
                if (row_off + span_w * 4 > ram.len) continue;
                const dst_row = out_argb[py * out_w + dst_x ..][0..span_w];
                const src_bytes = ram[row_off..][0 .. span_w * 4];
                if (alpha_mode == 1) {
                    @memcpy(std.mem.sliceAsBytes(dst_row), src_bytes);
                    for (dst_row) |*p| p.* |= 0xFF000000;
                } else {
                    for (dst_row, 0..) |*dst_p, i| {
                        const src_color = std.mem.readInt(u32, src_bytes[i * 4 ..][0..4], .little);
                        const a = src_color >> 24;
                        if (a == 255) {
                            dst_p.* = src_color;
                        } else if (a > 0) {
                            dst_p.* = blendPixel(dst_p.*, src_color, a, premult);
                        }
                    }
                }
            }
            return;
        }

        var start_py: u32 = dst_y;

        // Fast path 2: Unity 32-bit T-tiled / LT-tiled plane aligned to (0, 0)
        if (unity and tiling != 0 and !is_565 and dst_x == 0 and dst_y == 0 and (max_dx & 3) == 0) {
            const utiles_x = max_dx >> 2;
            const utiles_y = max_dy >> 2;
            var uy: u32 = 0;
            while (uy < utiles_y) : (uy += 1) {
                const py0 = uy << 2;
                var ux: u32 = 0;
                while (ux < utiles_x) : (ux += 1) {
                    const px0 = ux << 2;
                    const utile_off = ptr0 + texture.texelOffsetOf(.argb8888, tiled_w, src_h, px0, py0);
                    if (utile_off + 64 > ram.len) continue;
                    inline for (0..4) |ry| {
                        const dst_row = out_argb[(py0 + @as(u32, @intCast(ry))) * out_w + px0 ..][0..4];
                        const src_row_bytes = ram[utile_off + ry * 16 ..][0..16];
                        if (alpha_mode == 1) {
                            @memcpy(std.mem.sliceAsBytes(dst_row), src_row_bytes);
                            inline for (0..4) |rx| dst_row[rx] |= 0xFF000000;
                        } else {
                            inline for (0..4) |rx| {
                                const src_color = std.mem.readInt(u32, src_row_bytes[rx * 4 ..][0..4], .little);
                                const a = src_color >> 24;
                                if (a == 255) {
                                    dst_row[rx] = src_color;
                                } else if (a > 0) {
                                    dst_row[rx] = blendPixel(dst_row[rx], src_color, a, premult);
                                }
                            }
                        }
                    }
                }
            }
            if ((max_dy & 3) == 0) return;
            start_py = utiles_y << 2;
        }

        // Fast path 3: Unity 16-bit RGB565 T-tiled / LT-tiled plane aligned to (0, 0) (8x4 utiles)
        if (unity and tiling != 0 and is_565 and dst_x == 0 and dst_y == 0 and (max_dx & 7) == 0) {
            const utiles_x = max_dx >> 3;
            const utiles_y = max_dy >> 2;
            var uy: u32 = 0;
            while (uy < utiles_y) : (uy += 1) {
                const py0 = uy << 2;
                var ux: u32 = 0;
                while (ux < utiles_x) : (ux += 1) {
                    const px0 = ux << 3;
                    const utile_off = ptr0 + texture.texelOffsetOf(.rgb565, tiled_w, src_h, px0, py0);
                    if (utile_off + 64 > ram.len) continue;
                    inline for (0..4) |ry| {
                        const dst_row = out_argb[(py0 + @as(u32, @intCast(ry))) * out_w + px0 ..][0..8];
                        const src_row_bytes = ram[utile_off + ry * 16 ..][0..16];
                        inline for (0..8) |rx| {
                            const p16 = std.mem.readInt(u16, src_row_bytes[rx * 2 ..][0..2], .little);
                            dst_row[rx] = format_mod.fromRgb565(p16);
                        }
                    }
                }
            }
            if ((max_dy & 3) == 0) return;
            start_py = utiles_y << 2;
        }

        var py: u32 = start_py;
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
                if (alpha_mode == 1 or is_565) {
                    out_argb[out_idx] = src_color | 0xFF000000;
                } else {
                    const a: u32 = (src_color >> 24) & 0xff;
                    if (a == 255) {
                        out_argb[out_idx] = src_color;
                    } else if (a > 0) {
                        out_argb[out_idx] = blendPixel(out_argb[out_idx], src_color, a, premult);
                    }
                }
            }
        }
    }

    /// Inspects the active HVS display list for the 32x32 linear ARGB8888 cursor plane
    /// and returns its current hotspot `(x, y)` in HDMI display coordinates if visible.
    pub fn getCursorHotspot(self: *const Hvs, ram: []const u8) ?[2]i32 {
        if ((self.dispctrl & (1 << 31)) == 0) return null;

        var active_ch: ?usize = null;
        for ([_]usize{ 1, 0, 2 }) |ch| {
            const head = self.displact[ch] & DLIST_MASK;
            const ctl0 = self.dlist[head];
            if ((ctl0 & SCALER_CTL0_END) == 0 and (ctl0 & SCALER_CTL0_VALID) != 0) {
                active_ch = ch;
                break;
            }
        }
        const ch = active_ch orelse return null;

        var idx: usize = self.displact[ch] & DLIST_MASK;
        var planes_seen: usize = 0;
        var found: ?[2]i32 = null;

        while (idx + 7 <= DLIST_WORDS and planes_seen < 32) {
            const ctl0 = self.dlist[idx];
            if ((ctl0 & SCALER_CTL0_END) != 0) break;
            const entry_words: usize = (ctl0 >> 24) & 0x3f;
            if (entry_words < 7 or idx + entry_words > DLIST_WORDS) break;

            if ((ctl0 & SCALER_CTL0_VALID) != 0) {
                const unity = (ctl0 & SCALER_CTL0_UNITY) != 0;
                const tiling: u2 = @truncate((ctl0 >> 20) & 3);
                const pos0 = self.dlist[idx + 1];
                const dst_x: u32 = pos0 & 0xfff;
                const dst_y: u32 = (pos0 >> 12) & 0xfff;

                const pos2_idx = if (unity) idx + 2 else idx + 3;
                const pos2 = self.dlist[pos2_idx];
                const src_w: u32 = pos2 & 0xfff;
                const raw_h16: u32 = (pos2 >> 16) & 0xfff;
                const src_h: u32 = if (raw_h16 != 0) raw_h16 else ((pos2 >> 12) & 0xfff);

                const ptr0_idx = if (unity) idx + 4 else idx + 5;
                if (unity and tiling == 0 and src_w > 0 and src_w <= 32 and src_h > 0 and src_h <= 32 and ptr0_idx + 2 < DLIST_WORDS) {
                    const ptr0 = self.dlist[ptr0_idx] & 0x1FFFFFFF;
                    const pitch0 = self.dlist[ptr0_idx + 2] & 0xffff;
                    if (pitch0 == 128) {
                        const bo_base = ptr0 & ~@as(u32, 0xfff);
                        const off_in_bo = ptr0 & 0xfff;
                        const src_x: i32 = @intCast((off_in_bo % 128) / 4);
                        const src_y: i32 = @intCast(off_in_bo / 128);
                        const plane_x: i32 = @as(i32, @intCast(dst_x)) - src_x;
                        const plane_y: i32 = @as(i32, @intCast(dst_y)) - src_y;

                        if (bo_base + 4096 <= ram.len) {
                            const px_arrow = std.mem.readInt(u32, ram[bo_base + (2 * 32 + 1) * 4 ..][0..4], .little);
                            const px_hand = std.mem.readInt(u32, ram[bo_base + (3 * 32 + 9) * 4 ..][0..4], .little);
                            if ((px_arrow >> 24) != 0 and (px_hand >> 24) == 0) {
                                found = .{ plane_x + 1, plane_y + 1 };
                            } else if ((px_hand >> 24) != 0 and (px_arrow >> 24) == 0) {
                                found = .{ plane_x + 9, plane_y + 2 };
                            } else {
                                var any_alpha = false;
                                for (0..32 * 32) |px_i| {
                                    const px_val = std.mem.readInt(u32, ram[bo_base + px_i * 4 ..][0..4], .little);
                                    if ((px_val >> 24) != 0) {
                                        any_alpha = true;
                                        break;
                                    }
                                }
                                if (any_alpha) {
                                    found = .{ plane_x + 16, plane_y + 16 };
                                }
                            }
                        } else {
                            found = .{ plane_x + 1, plane_y + 1 };
                        }
                    }
                }
                planes_seen += 1;
            }
            idx += entry_words;
        }
        return found;
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
    // ctl0: VALID | UNITY | format=7 (HVS_PIXEL_FORMAT_RGBA8888) | size=7 words
    hvs.write32(Hvs.DLIST_OFFSET + 16 * 4, Hvs.SCALER_CTL0_VALID | Hvs.SCALER_CTL0_UNITY | (7 << 24) | 7);
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

test "HVS T-tiled RGB565 plane compositing (direct scanout of maximized window)" {
    var hvs = Hvs{};
    const w: u32 = 128;
    const h: u32 = 69; // Non-multiple-of-4 height (like 1280x669 in Dazzle)
    var ram: [128 * 96 * 2]u8 = [_]u8{0} ** (128 * 96 * 2);

    // Populate T-tiled RGB565 buffer with pure blue (0xff0000ff)
    const blue565 = format_mod.toRgb565(0xff0000ff);
    for (0..h) |y| {
        for (0..w) |x| {
            const off = texture.texelOffsetOf(.rgb565, w, h, @intCast(x), @intCast(y));
            std.mem.writeInt(u16, ram[off..][0..2], blue565, .little);
        }
    }

    // ctl0: VALID | UNITY | tiling=3 (T-tiled) | format=4 (HVS_PIXEL_FORMAT_RGB565) | size=7 words
    hvs.write32(Hvs.DLIST_OFFSET + 16 * 4, Hvs.SCALER_CTL0_VALID | Hvs.SCALER_CTL0_UNITY | (7 << 24) | (3 << 20) | 4);
    hvs.write32(Hvs.DLIST_OFFSET + 17 * 4, 0xff000000);
    hvs.write32(Hvs.DLIST_OFFSET + 18 * 4, (1 << 30) | (h << 16) | w);
    hvs.write32(Hvs.DLIST_OFFSET + 19 * 4, 0xc0c0c0c0);
    hvs.write32(Hvs.DLIST_OFFSET + 20 * 4, 0x80000000);
    hvs.write32(Hvs.DLIST_OFFSET + 21 * 4, 0xc0c0c0c0);
    // pitch0: SCALER_TILE_WIDTH_T = w / 64 = 2 T-tiles (NOT w * 2 bytes!)
    hvs.write32(Hvs.DLIST_OFFSET + 22 * 4, w / 64);
    hvs.write32(Hvs.DLIST_OFFSET + 23 * 4, Hvs.SCALER_CTL0_END);
    hvs.write32(0x0024, 16);

    var out: [128 * 69]u32 = [_]u32{0} ** (128 * 69);
    try std.testing.expect(hvs.compositeFrame(&ram, &out, w, h));
    for (out) |px| {
        try std.testing.expectEqual(@as(u32, 0xff0000ff), px);
    }
}

test "HVS cursor hotspot detection" {
    var hvs = Hvs{};
    var ram: [8192]u8 = [_]u8{0} ** 8192;

    // Simulate arrow cursor buffer at page-aligned 0x1000 (pixel (1,2) opaque)
    std.mem.writeInt(u32, ram[0x1000 + (2 * 32 + 1) * 4 ..][0..4], 0xffffffff, .little);

    // Write cursor DLIST entry at slot 32 (dst_x=639, dst_y=359 -> hotspot (640, 360))
    // Uses VC4_GEN_4 SCALER_POS2 layout: ALPHA_MODE_PIPELINE (0 << 30) | ALPHA_PREMULT (1 << 29) | (32 << 16) | 32
    hvs.write32(Hvs.DLIST_OFFSET + 32 * 4, Hvs.SCALER_CTL0_VALID | Hvs.SCALER_CTL0_UNITY | (7 << 24) | 7);
    hvs.write32(Hvs.DLIST_OFFSET + 33 * 4, (359 << 12) | 639);
    hvs.write32(Hvs.DLIST_OFFSET + 34 * 4, (1 << 29) | (32 << 16) | 32);
    hvs.write32(Hvs.DLIST_OFFSET + 35 * 4, 0);
    hvs.write32(Hvs.DLIST_OFFSET + 36 * 4, 0xc0001000);
    hvs.write32(Hvs.DLIST_OFFSET + 37 * 4, 0);
    hvs.write32(Hvs.DLIST_OFFSET + 38 * 4, 128);
    hvs.write32(Hvs.DLIST_OFFSET + 39 * 4, Hvs.SCALER_CTL0_END);
    hvs.write32(0x0024, 32);

    const hot = hvs.getCursorHotspot(&ram);
    try std.testing.expectEqual(@as(?[2]i32, .{ 640, 360 }), hot);
}

test "HVS EOF interrupt and per-channel frame counters for DLIST reclamation" {
    var hvs = Hvs{};

    // Enable channel 1 and configure SCALER_DISPCTRL = 0xaa0c020e
    // (ENABLE | DSPEIEOF(1) [0x200] | DISPEIRQ(0..2) [0x0e])
    hvs.write32(0x0050, Hvs.SCALER_DISPCTRLX_ENABLE);
    hvs.write32(0x0000, 0xaa0c020e);
    try std.testing.expect(!hvs.irqPending());

    // Vblank increments frame_count and asserts EOF(1) (bit 16) + IRQDISP(1) (bit 2)
    hvs.notifyVblank();
    try std.testing.expect(hvs.irqPending());
    const stat = hvs.read32(0x0004);
    try std.testing.expect((stat & (1 << 16)) != 0); // SCALER_DISPSTAT_EOF(1)
    try std.testing.expect((stat & (1 << 2)) != 0); // SCALER_DISPSTAT_IRQDISP(1)

    // Verify VC4_GEN_4 FRCNT0 (bits 23:18) and FRCNT1 (bits 17:12) in SCALER_DISPSTAT1
    const dispstat1 = hvs.read32(0x0058);
    try std.testing.expectEqual(@as(u32, 1), (dispstat1 >> 18) & 0x3f);
    try std.testing.expectEqual(@as(u32, 1), (dispstat1 >> 12) & 0x3f);

    // Clearing SCALER_DISPSTAT_IRQMASK(0..2) (0x3f3f3f00) clears both EOF(1) and summary IRQDISP(1)
    hvs.write32(0x0004, 0x3f3f3f00);
    try std.testing.expect(!hvs.irqPending());
}


