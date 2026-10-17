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
        var d: [DLIST_WORDS]u32 = @splat(0);
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
                if ((self.dispctrl ^ val) & (1 << 31) != 0) self.dlist_updated = true;
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
                if (self.displist[0] != val or self.displact[0] != val) self.dlist_updated = true;
                self.displist[0] = val;
                self.displact[0] = val;
            },
            0x0024 => {
                if (self.displist[1] != val or self.displact[1] != val) self.dlist_updated = true;
                self.displist[1] = val;
                self.displact[1] = val;
            },
            0x0028 => {
                if (self.displist[2] != val or self.displact[2] != val) self.dlist_updated = true;
                self.displist[2] = val;
                self.displact[2] = val;
            },
            0x0040 => {
                const next = val & ~SCALER_DISPCTRLX_RESET;
                if (self.chan_ctrl[0] != next) self.dlist_updated = true;
                self.chan_ctrl[0] = next;
                self.chan_stat[0] = self.computeChanStat(0);
            },
            0x0044 => {
                if (self.chan_bkgnd[0] != val) self.dlist_updated = true;
                self.chan_bkgnd[0] = val;
            },
            0x0048 => self.chan_stat[0] = self.computeChanStat(0),
            0x004c => self.chan_base[0] = val,
            0x0050 => {
                const next = val & ~SCALER_DISPCTRLX_RESET;
                if (self.chan_ctrl[1] != next) self.dlist_updated = true;
                self.chan_ctrl[1] = next;
                self.chan_stat[1] = self.computeChanStat(1);
            },
            0x0054 => {
                if (self.chan_bkgnd[1] != val) self.dlist_updated = true;
                self.chan_bkgnd[1] = val;
            },
            0x0058 => self.chan_stat[1] = self.computeChanStat(1),
            0x005c => self.chan_base[1] = val,
            0x0060 => {
                const next = val & ~SCALER_DISPCTRLX_RESET;
                if (self.chan_ctrl[2] != next) self.dlist_updated = true;
                self.chan_ctrl[2] = next;
                self.chan_stat[2] = self.computeChanStat(2);
            },
            0x0064 => {
                if (self.chan_bkgnd[2] != val) self.dlist_updated = true;
                self.chan_bkgnd[2] = val;
            },
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

    /// Computes a fast 64-bit Wyhash signature over the active HVS display list and plane backing memory.
    /// Used to skip re-compositing 1280x720 frames when neither DLIST nor scanout pixel data changed.
    pub fn computeActivePlanesHash(self: *const Hvs, ram: []const u8, width: u32, height: u32) u64 {
        var active_ch: ?usize = null;
        for ([_]usize{ 1, 0, 2 }) |ch| {
            const head = self.displact[ch] & DLIST_MASK;
            const ctl0 = self.dlist[head];
            if ((ctl0 & SCALER_CTL0_END) == 0 and (ctl0 & SCALER_CTL0_VALID) != 0) {
                active_ch = ch;
                break;
            }
        }
        const ch = active_ch orelse return 0;

        var hasher = std.hash.Wyhash.init(0x9E3779B97F4A7C15);
        const hdr = [3]u32{ self.dispctrl & (1 << 31), self.chan_bkgnd[ch], self.displact[ch] };
        hasher.update(std.mem.asBytes(&hdr));

        var idx: usize = self.displact[ch] & DLIST_MASK;
        var planes_seen: usize = 0;

        while (idx + 7 <= DLIST_WORDS and planes_seen < 32) {
            const ctl0 = self.dlist[idx];
            if ((ctl0 & SCALER_CTL0_END) != 0) break;
            const entry_words: usize = (ctl0 >> 24) & 0x3f;
            if (entry_words < 7 or idx + entry_words > DLIST_WORDS) break;

            if ((ctl0 & SCALER_CTL0_VALID) != 0) {
                hasher.update(std.mem.sliceAsBytes(self.dlist[idx .. idx + entry_words]));
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
                const dst_w: u32 = if (unity) src_w else (self.dlist[idx + 2] & 0xfff);
                const dst_h: u32 = if (unity) src_h else ((self.dlist[idx + 2] >> 16) & 0xfff);

                const ptr0_idx = if (unity) idx + 4 else idx + 5;
                if (src_w > 0 and src_h > 0 and dst_w > 0 and dst_h > 0 and ptr0_idx + 2 < DLIST_WORDS) {
                    const ptr0 = self.dlist[ptr0_idx] & 0x1FFFFFFF;
                    const pitch0 = self.dlist[ptr0_idx + 2];
                    const is_565 = (pix_fmt == 0) or (pix_fmt == 4);
                    const cpp: u32 = if (is_565) 2 else 4;
                    const max_dy = @min(dst_y + dst_h, height);
                    const max_dx = @min(dst_x + dst_w, width);

                    if (dst_x < max_dx and dst_y < max_dy) {
                        const span_w = max_dx - dst_x;
                        const span_h = max_dy - dst_y;
                        if (tiling == 0) {
                            const raw_pitch: u32 = pitch0 & 0xffff;
                            const linear_pitch: u32 = if (raw_pitch != 0) raw_pitch else (src_w * cpp);
                            const row_bytes: usize = @as(usize, span_w) * cpp;
                            if (linear_pitch == span_w * cpp) {
                                const total_bytes = row_bytes * @as(usize, span_h);
                                if (@as(usize, ptr0) + total_bytes <= ram.len) {
                                    if (total_bytes <= 16384) {
                                        hasher.update(ram[ptr0 .. ptr0 + total_bytes]);
                                    } else {
                                        // Sparse strided 64-byte cacheline sampling across large linear planes
                                        // (~20 samples per 1280px row, cutting 3.68 MB/frame bandwidth by 4x).
                                        var off: usize = 0;
                                        while (off + 64 <= total_bytes) : (off += 256) {
                                            hasher.update(ram[@as(usize, ptr0) + off ..][0..64]);
                                        }
                                        hasher.update(ram[@as(usize, ptr0) + total_bytes - 64 ..][0..64]);
                                    }
                                }
                            } else {
                                const row_step: u32 = if (span_h > 64) 2 else 1;
                                var sy: u32 = 0;
                                while (sy < span_h) : (sy += row_step) {
                                    const row_off: usize = @as(usize, ptr0) + @as(usize, sy) * linear_pitch;
                                    if (row_off + row_bytes <= ram.len) {
                                        if (row_bytes <= 1024) {
                                            hasher.update(ram[row_off .. row_off + row_bytes]);
                                        } else {
                                            var off: usize = 0;
                                            while (off + 64 <= row_bytes) : (off += 256) {
                                                hasher.update(ram[row_off + off ..][0..64]);
                                            }
                                            hasher.update(ram[row_off + row_bytes - 64 ..][0..64]);
                                        }
                                    }
                                }
                            }
                        } else {
                            // T-tiled / LT-tiled plane: sample 64-byte utiles across the plane
                            const tile_w_px: u32 = if (is_565) 64 else 32;
                            const tiled_w: u32 = if (tiling == 3 and (pitch0 & 0x7f) != 0)
                                (pitch0 & 0x7f) * tile_w_px
                            else
                                src_w;
                            const aligned_h = (src_h + 31) & ~@as(u32, 31);
                            const total_bytes: usize = @as(usize, tiled_w) * @as(usize, aligned_h) * cpp;
                            const step: usize = @max((total_bytes / 64) & ~@as(usize, 63), 64);
                            var off: usize = 0;
                            while (off + 64 <= total_bytes and @as(usize, ptr0) + off + 64 <= ram.len) : (off += step) {
                                hasher.update(ram[@as(usize, ptr0) + off ..][0..64]);
                            }
                        }
                    }
                }
                planes_seen += 1;
            }
            idx += entry_words;
        }
        return hasher.final();
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

    inline fn div255(x: u32) u32 {
        return (x + 1 + (x >> 8)) >> 8;
    }

    inline fn div255Vec4(x: @Vector(4, u32)) @Vector(4, u32) {
        const one: @Vector(4, u32) = @splat(1);
        const shift8: @Vector(4, u5) = @splat(8);
        return (x + one + (x >> shift8)) >> shift8;
    }

    inline fn blendPixel(dst_c: u32, src_color: u32, a: u32, premult: bool) u32 {
        const inv_a = 255 - a;
        if (premult) {
            const r: u32 = @min(((src_color >> 16) & 0xff) + div255(((dst_c >> 16) & 0xff) * inv_a), @as(u32, 255));
            const g: u32 = @min(((src_color >> 8) & 0xff) + div255(((dst_c >> 8) & 0xff) * inv_a), @as(u32, 255));
            const b: u32 = @min((src_color & 0xff) + div255((dst_c & 0xff) * inv_a), @as(u32, 255));
            return 0xFF000000 | (r << 16) | (g << 8) | b;
        } else {
            const r = div255(((src_color >> 16) & 0xff) * a + ((dst_c >> 16) & 0xff) * inv_a);
            const g = div255(((src_color >> 8) & 0xff) * a + ((dst_c >> 8) & 0xff) * inv_a);
            const b = div255((src_color & 0xff) * a + (dst_c & 0xff) * inv_a);
            return 0xFF000000 | (r << 16) | (g << 8) | b;
        }
    }

    pub inline fn blendPixels4(dst_v: @Vector(4, u32), src_v: @Vector(4, u32), premult: bool) @Vector(4, u32) {
        const zero: @Vector(4, u32) = @splat(0);
        const full: @Vector(4, u32) = @splat(255);
        const mask_ff: @Vector(4, u32) = @splat(0xff);
        const opaque_a: @Vector(4, u32) = @splat(0xFF000000);
        const shift24: @Vector(4, u5) = @splat(24);
        const shift16: @Vector(4, u5) = @splat(16);
        const shift8: @Vector(4, u5) = @splat(8);

        const a = src_v >> shift24;
        const inv_a = full - a;

        const sr = (src_v >> shift16) & mask_ff;
        const sg = (src_v >> shift8) & mask_ff;
        const sb = src_v & mask_ff;

        const dr = (dst_v >> shift16) & mask_ff;
        const dg = (dst_v >> shift8) & mask_ff;
        const db = dst_v & mask_ff;

        const blended = if (premult) blk: {
            const r: @Vector(4, u32) = @min(sr + div255Vec4(dr * inv_a), full);
            const g: @Vector(4, u32) = @min(sg + div255Vec4(dg * inv_a), full);
            const b: @Vector(4, u32) = @min(sb + div255Vec4(db * inv_a), full);
            break :blk opaque_a | (r << shift16) | (g << shift8) | b;
        } else blk: {
            const r: @Vector(4, u32) = div255Vec4(sr * a + dr * inv_a);
            const g: @Vector(4, u32) = div255Vec4(sg * a + dg * inv_a);
            const b: @Vector(4, u32) = div255Vec4(sb * a + db * inv_a);
            break :blk opaque_a | (r << shift16) | (g << shift8) | b;
        };

        return @select(u32, a == zero, dst_v, @select(u32, a == full, src_v, blended));
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

        const span_w = max_dx - dst_x;
        const span_h = max_dy - dst_y;

        // Fast path 1a: Unity 32-bit Linear plane (8-wide SIMD)
        if (unity and tiling == 0 and !is_565) {
            const opaque_mask8: @Vector(8, u32) = @splat(0xFF000000);
            var py: u32 = dst_y;
            while (py < max_dy) : (py += 1) {
                const sy = py - dst_y;
                const row_off = ptr0 + sy * linear_pitch;
                if (row_off + span_w * 4 > ram.len) continue;
                const dst_row = out_argb[py * out_w + dst_x ..][0..span_w];
                const src_bytes = ram[row_off..][0 .. span_w * 4];
                if (alpha_mode == 1) {
                    var x: u32 = 0;
                    while (x + 8 <= span_w) : (x += 8) {
                        const src_v: @Vector(8, u32) = @bitCast(src_bytes[x * 4 ..][0..32].*);
                        dst_row[x..][0..8].* = @bitCast(src_v | opaque_mask8);
                    }
                    while (x < span_w) : (x += 1) {
                        dst_row[x] = std.mem.readInt(u32, src_bytes[x * 4 ..][0..4], .little) | 0xFF000000;
                    }
                } else {
                    var x: u32 = 0;
                    while (x + 8 <= span_w) : (x += 8) {
                        const src_v: @Vector(8, u32) = @bitCast(src_bytes[x * 4 ..][0..32].*);
                        const alphas = src_v >> @splat(24);
                        if (@reduce(.And, alphas) == 0xff) {
                            dst_row[x..][0..8].* = @bitCast(src_v);
                        } else if (@reduce(.Or, alphas) != 0) {
                            const src_lo: @Vector(4, u32) = @bitCast(src_bytes[x * 4 ..][0..16].*);
                            const src_hi: @Vector(4, u32) = @bitCast(src_bytes[x * 4 + 16 ..][0..16].*);
                            const dst_lo: @Vector(4, u32) = dst_row[x..][0..4].*;
                            const dst_hi: @Vector(4, u32) = dst_row[x + 4 ..][0..4].*;
                            dst_row[x..][0..4].* = blendPixels4(dst_lo, src_lo, premult);
                            dst_row[x + 4 ..][0..4].* = blendPixels4(dst_hi, src_hi, premult);
                        }
                    }
                    while (x < span_w) : (x += 1) {
                        const src_color = std.mem.readInt(u32, src_bytes[x * 4 ..][0..4], .little);
                        const a = src_color >> 24;
                        if (a == 255) {
                            dst_row[x] = src_color;
                        } else if (a > 0) {
                            dst_row[x] = blendPixel(dst_row[x], src_color, a, premult);
                        }
                    }
                }
            }
            return;
        }

        // Fast path 1b: Unity 16-bit RGB565 Linear plane
        if (unity and tiling == 0 and is_565) {
            var py: u32 = dst_y;
            while (py < max_dy) : (py += 1) {
                const sy = py - dst_y;
                const row_off = ptr0 + sy * linear_pitch;
                if (row_off + span_w * 2 > ram.len) continue;
                const dst_row = out_argb[py * out_w + dst_x ..][0..span_w];
                const src_bytes = ram[row_off..][0 .. span_w * 2];
                var x: u32 = 0;
                while (x + 8 <= span_w) : (x += 8) {
                    const p16_vec: @Vector(8, u16) = @bitCast(src_bytes[x * 2 ..][0..16].*);
                    dst_row[x..][0..8].* = @bitCast(format_mod.fromRgb565Vec8(p16_vec));
                }
                while (x < span_w) : (x += 1) {
                    const p16 = std.mem.readInt(u16, src_bytes[x * 2 ..][0..2], .little);
                    dst_row[x] = format_mod.fromRgb565(p16);
                }
            }
            return;
        }

        // Fast path 2: Unity 32-bit T-tiled / LT-tiled plane (4x4 utiles, hoisted group address)
        if (unity and tiling != 0 and !is_565) {
            const is_lt = (tiled_w <= 16 or src_h <= 16);
            const lt_row_stride = ((tiled_w + 3) & ~@as(u32, 3)) << 2;
            const utile_stride = ((tiled_w + 31) & ~@as(u32, 31)) >> 2;
            const utiles_x = span_w >> 2;
            const utiles_y = span_h >> 2;
            const rem_x = span_w & 3;
            const rem_y = span_h & 3;
            const total_uy = utiles_y + @intFromBool(rem_y != 0);
            const opaque_mask: @Vector(4, u32) = @splat(0xFF000000);

            var uy: u32 = 0;
            while (uy < total_uy) : (uy += 1) {
                const dy0 = dst_y + (uy << 2);
                const rows: u32 = if (uy < utiles_y) 4 else rem_y;
                var ux: u32 = 0;
                var group_base: u32 = 0;
                while (ux < utiles_x) : (ux += 1) {
                    if ((ux & 3) == 0) {
                        group_base = ptr0 + texture.utileGroupOffset(is_lt, lt_row_stride, utile_stride, ux, uy);
                    }
                    const utile_off = group_base + ((ux & 3) << 6);
                    if (utile_off + 64 > ram.len) continue;
                    const dx0 = dst_x + (ux << 2);
                    if (rows == 4) {
                        inline for (0..4) |ry| {
                            const dst_row = out_argb[(dy0 + @as(u32, @intCast(ry))) * out_w + dx0 ..][0..4];
                            const src_v: @Vector(4, u32) = @bitCast(ram[utile_off + ry * 16 ..][0..16].*);
                            if (alpha_mode == 1) {
                                dst_row.* = @bitCast(src_v | opaque_mask);
                            } else {
                                const alphas = src_v >> @splat(24);
                                if (@reduce(.And, alphas) == 0xff) {
                                    dst_row.* = @bitCast(src_v);
                                } else if (@reduce(.Or, alphas) != 0) {
                                    const dst_v: @Vector(4, u32) = dst_row.*;
                                    dst_row.* = blendPixels4(dst_v, src_v, premult);
                                }
                            }
                        }
                    } else {
                        for (0..rows) |ry| {
                            const dst_row = out_argb[(dy0 + @as(u32, @intCast(ry))) * out_w + dx0 ..][0..4];
                            const src_v: @Vector(4, u32) = @bitCast(ram[utile_off + @as(u32, @intCast(ry)) * 16 ..][0..16].*);
                            if (alpha_mode == 1) {
                                dst_row.* = @bitCast(src_v | opaque_mask);
                            } else {
                                const alphas = src_v >> @splat(24);
                                if (@reduce(.And, alphas) == 0xff) {
                                    dst_row.* = @bitCast(src_v);
                                } else if (@reduce(.Or, alphas) != 0) {
                                    const dst_v: @Vector(4, u32) = dst_row.*;
                                    dst_row.* = blendPixels4(dst_v, src_v, premult);
                                }
                            }
                        }
                    }
                }
                if (rem_x != 0) {
                    if ((utiles_x & 3) == 0) {
                        group_base = ptr0 + texture.utileGroupOffset(is_lt, lt_row_stride, utile_stride, utiles_x, uy);
                    }
                    const utile_off = group_base + ((utiles_x & 3) << 6);
                    if (utile_off + 64 <= ram.len) {
                        const dx0 = dst_x + (utiles_x << 2);
                        for (0..rows) |ry| {
                            const dst_row = out_argb[(dy0 + @as(u32, @intCast(ry))) * out_w + dx0 ..][0..rem_x];
                            const src_row_bytes = ram[utile_off + @as(u32, @intCast(ry)) * 16 ..][0..16];
                            for (0..rem_x) |rx| {
                                const src_color = std.mem.readInt(u32, src_row_bytes[rx * 4 ..][0..4], .little);
                                if (alpha_mode == 1) {
                                    dst_row[rx] = src_color | 0xFF000000;
                                } else {
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
            }
            return;
        }

        // Fast path 3: Unity 16-bit RGB565 T-tiled / LT-tiled plane (8x4 utiles, hoisted group address + SIMD)
        if (unity and tiling != 0 and is_565) {
            const is_lt = (tiled_w <= 32 or src_h <= 16);
            const lt_row_stride = ((tiled_w + 7) & ~@as(u32, 7)) << 1;
            const utile_stride = ((tiled_w + 63) & ~@as(u32, 63)) >> 3;
            const utiles_x = span_w >> 3;
            const utiles_y = span_h >> 2;
            const rem_x = span_w & 7;
            const rem_y = span_h & 3;
            const total_uy = utiles_y + @intFromBool(rem_y != 0);

            var uy: u32 = 0;
            while (uy < total_uy) : (uy += 1) {
                const dy0 = dst_y + (uy << 2);
                const rows: u32 = if (uy < utiles_y) 4 else rem_y;
                var ux: u32 = 0;
                var group_base: u32 = 0;
                while (ux < utiles_x) : (ux += 1) {
                    if ((ux & 3) == 0) {
                        group_base = ptr0 + texture.utileGroupOffset(is_lt, lt_row_stride, utile_stride, ux, uy);
                    }
                    const utile_off = group_base + ((ux & 3) << 6);
                    if (utile_off + 64 > ram.len) continue;
                    const dx0 = dst_x + (ux << 3);
                    if (rows == 4) {
                        inline for (0..4) |ry| {
                            const dst_row = out_argb[(dy0 + @as(u32, @intCast(ry))) * out_w + dx0 ..][0..8];
                            const p16_vec: @Vector(8, u16) = @bitCast(ram[utile_off + ry * 16 ..][0..16].*);
                            dst_row.* = @bitCast(format_mod.fromRgb565Vec8(p16_vec));
                        }
                    } else {
                        for (0..rows) |ry| {
                            const dst_row = out_argb[(dy0 + @as(u32, @intCast(ry))) * out_w + dx0 ..][0..8];
                            const p16_vec: @Vector(8, u16) = @bitCast(ram[utile_off + @as(u32, @intCast(ry)) * 16 ..][0..16].*);
                            dst_row.* = @bitCast(format_mod.fromRgb565Vec8(p16_vec));
                        }
                    }
                }
                if (rem_x != 0) {
                    if ((utiles_x & 3) == 0) {
                        group_base = ptr0 + texture.utileGroupOffset(is_lt, lt_row_stride, utile_stride, utiles_x, uy);
                    }
                    const utile_off = group_base + ((utiles_x & 3) << 6);
                    if (utile_off + 64 <= ram.len) {
                        const dx0 = dst_x + (utiles_x << 3);
                        for (0..rows) |ry| {
                            const dst_row = out_argb[(dy0 + @as(u32, @intCast(ry))) * out_w + dx0 ..][0..rem_x];
                            const src_row_bytes = ram[utile_off + @as(u32, @intCast(ry)) * 16 ..][0..16];
                            for (0..rem_x) |rx| {
                                const p16 = std.mem.readInt(u16, src_row_bytes[rx * 2 ..][0..2], .little);
                                dst_row[rx] = format_mod.fromRgb565(p16);
                            }
                        }
                    }
                }
            }
            return;
        }

        // Scaled plane path (!unity): 32.32 fixed-point reciprocal stepping
        const step_x_fp: u64 = ((@as(u64, src_w) << 32) + dst_w - 1) / dst_w;
        const step_y_fp: u64 = ((@as(u64, src_h) << 32) + dst_h - 1) / dst_h;
        var acc_y: u64 = 0;

        if (tiling == 0) {
            var py: u32 = dst_y;
            while (py < max_dy) : ({
                py += 1;
                acc_y += step_y_fp;
            }) {
                const sy: u32 = @intCast(acc_y >> 32);
                const linear_row_off = ptr0 + sy * linear_pitch;
                const dst_row = out_argb[py * out_w + dst_x ..][0..span_w];
                var acc_x: u64 = 0;
                for (0..span_w) |x| {
                    const sx: u32 = @intCast(acc_x >> 32);
                    acc_x += step_x_fp;
                    const off = linear_row_off + sx * cpp;
                    if (off + cpp > ram.len) continue;
                    const src_color: u32 = if (is_565)
                        format_mod.fromRgb565(std.mem.readInt(u16, ram[off..][0..2], .little))
                    else
                        std.mem.readInt(u32, ram[off..][0..4], .little);
                    if (alpha_mode == 1 or is_565) {
                        dst_row[x] = src_color | 0xFF000000;
                    } else {
                        const a: u32 = (src_color >> 24) & 0xff;
                        if (a == 255) {
                            dst_row[x] = src_color;
                        } else if (a > 0) {
                            dst_row[x] = blendPixel(dst_row[x], src_color, a, premult);
                        }
                    }
                }
            }
            return;
        }

        // Scaled T-tiled / LT-tiled plane with per-scanline cached utile row base
        const uw_shift: u5 = if (is_565) 3 else 2;
        const uw_mask: u32 = (@as(u32, 1) << uw_shift) - 1;
        const cpp_shift: u5 = if (is_565) 1 else 2;
        const is_lt = (tiled_w <= (@as(u32, 4) << uw_shift) or src_h <= 16);
        const lt_row_stride = ((tiled_w + uw_mask) & ~uw_mask) << cpp_shift;
        const tile_w = @as(u32, 8) << uw_shift;
        const utile_stride = ((tiled_w + tile_w - 1) & ~(tile_w - 1)) >> uw_shift;

        var py: u32 = dst_y;
        while (py < max_dy) : ({
            py += 1;
            acc_y += step_y_fp;
        }) {
            const sy: u32 = @intCast(acc_y >> 32);
            const uy = sy >> 2;
            const in_utile_y = (sy & 3) << 4;
            const dst_row = out_argb[py * out_w + dst_x ..][0..span_w];
            var cached_ux: u32 = 0xffff_ffff;
            var cached_utile_row_off: u32 = 0;
            var acc_x: u64 = 0;

            for (0..span_w) |x| {
                const sx: u32 = @intCast(acc_x >> 32);
                acc_x += step_x_fp;
                const ux = sx >> uw_shift;
                if (ux != cached_ux) {
                    cached_ux = ux;
                    const group_off = texture.utileGroupOffset(is_lt, lt_row_stride, utile_stride, ux & ~@as(u32, 3), uy);
                    cached_utile_row_off = ptr0 + group_off + ((ux & 3) << 6) + in_utile_y;
                }
                const off = cached_utile_row_off + ((sx & uw_mask) << cpp_shift);
                if (off + cpp > ram.len) continue;

                const src_color: u32 = if (is_565)
                    format_mod.fromRgb565(std.mem.readInt(u16, ram[off..][0..2], .little))
                else
                    std.mem.readInt(u32, ram[off..][0..4], .little);

                if (alpha_mode == 1 or is_565) {
                    dst_row[x] = src_color | 0xFF000000;
                } else {
                    const a: u32 = (src_color >> 24) & 0xff;
                    if (a == 255) {
                        dst_row[x] = src_color;
                    } else if (a > 0) {
                        dst_row[x] = blendPixel(dst_row[x], src_color, a, premult);
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
    var ram: [1024]u8 = @splat(0);

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

    var out: [4]u32 = @splat(0);
    try std.testing.expect(hvs.compositeFrame(&ram, &out, 2, 2));
    try std.testing.expectEqual(@as(u32, 0xff00ff00), out[0]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), out[3]);
}

test "HVS T-tiled RGB565 plane compositing (direct scanout of maximized window)" {
    var hvs = Hvs{};
    const w: u32 = 128;
    const h: u32 = 69; // Non-multiple-of-4 height (e.g. 1280x669)
    var ram: [128 * 96 * 2]u8 = @splat(0);

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

    var out: [128 * 69]u32 = @splat(0);
    try std.testing.expect(hvs.compositeFrame(&ram, &out, w, h));
    for (out) |px| {
        try std.testing.expectEqual(@as(u32, 0xff0000ff), px);
    }
}

test "HVS cursor hotspot detection" {
    var hvs = Hvs{};
    var ram: [8192]u8 = @splat(0);

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

test "HVS Linear RGB565 SIMD scanline and offset T-tiled ARGB8888 overlay compositing" {
    var hvs = Hvs{};
    const out_w: u32 = 40;
    const out_h: u32 = 24;
    var ram: [65536]u8 = @splat(0);

    // Plane 0: 40x24 Linear RGB565 background at 0x0000 with pure red (0xffff0000)
    const red565 = format_mod.toRgb565(0xffff0000);
    for (0..out_w * out_h) |i| {
        std.mem.writeInt(u16, ram[i * 2 ..][0..2], red565, .little);
    }

    // Plane 1: 35x21 T-tiled ARGB8888 overlay at 0x4000 placed at (dst_x=3, dst_y=2) with opaque green (0xff00ff00)
    const ov_w: u32 = 35;
    const ov_h: u32 = 21;
    for (0..ov_h) |y| {
        for (0..ov_w) |x| {
            const off = 0x4000 + texture.texelOffsetOf(.argb8888, 64, ov_h, @intCast(x), @intCast(y));
            std.mem.writeInt(u32, ram[off..][0..4], 0xff00ff00, .little);
        }
    }

    // Slot 16: Plane 0 (Linear RGB565, 40x24 at (0, 0))
    hvs.write32(Hvs.DLIST_OFFSET + 16 * 4, Hvs.SCALER_CTL0_VALID | Hvs.SCALER_CTL0_UNITY | (7 << 24) | 4);
    hvs.write32(Hvs.DLIST_OFFSET + 17 * 4, 0);
    hvs.write32(Hvs.DLIST_OFFSET + 18 * 4, (1 << 30) | (out_h << 16) | out_w);
    hvs.write32(Hvs.DLIST_OFFSET + 19 * 4, 0);
    hvs.write32(Hvs.DLIST_OFFSET + 20 * 4, 0x80000000);
    hvs.write32(Hvs.DLIST_OFFSET + 21 * 4, 0);
    hvs.write32(Hvs.DLIST_OFFSET + 22 * 4, out_w * 2);

    // Slot 23: Plane 1 (T-tiled ARGB8888, 35x21 at (3, 2), tile_width_t = 2 (64px))
    hvs.write32(Hvs.DLIST_OFFSET + 23 * 4, Hvs.SCALER_CTL0_VALID | Hvs.SCALER_CTL0_UNITY | (7 << 24) | (3 << 20) | 7);
    hvs.write32(Hvs.DLIST_OFFSET + 24 * 4, (2 << 12) | 3);
    hvs.write32(Hvs.DLIST_OFFSET + 25 * 4, (ov_h << 16) | ov_w);
    hvs.write32(Hvs.DLIST_OFFSET + 26 * 4, 0);
    hvs.write32(Hvs.DLIST_OFFSET + 27 * 4, 0x80004000);
    hvs.write32(Hvs.DLIST_OFFSET + 28 * 4, 0);
    hvs.write32(Hvs.DLIST_OFFSET + 29 * 4, 2); // 2 T-tiles wide (64px)

    // Slot 30: End marker
    hvs.write32(Hvs.DLIST_OFFSET + 30 * 4, Hvs.SCALER_CTL0_END);
    hvs.write32(0x0024, 16);

    var out: [40 * 24]u32 = @splat(0);
    try std.testing.expect(hvs.compositeFrame(&ram, &out, out_w, out_h));
    for (0..out_h) |y| {
        for (0..out_w) |x| {
            const in_ov = (x >= 3 and x < 3 + ov_w and y >= 2 and y < 2 + ov_h);
            const expected: u32 = if (in_ov) 0xff00ff00 else 0xffff0000;
            try std.testing.expectEqual(expected, out[y * out_w + x]);
        }
    }
}

test "HVS 4-wide SIMD blendPixels4 matches scalar division by 255" {
    const dst_v: @Vector(4, u32) = .{ 0xFF102030, 0xFF8040C0, 0xFFFFFFFF, 0xFF000000 };
    const src_v: @Vector(4, u32) = .{ 0x00AABBCC, 0xFFAABBCC, 0x804080C0, 0x33112233 };

    inline for ([_]bool{ false, true }) |premult| {
        const res = Hvs.blendPixels4(dst_v, src_v, premult);
        const res_arr: [4]u32 = res;
        const dst_arr: [4]u32 = dst_v;
        const src_arr: [4]u32 = src_v;
        for (0..4) |i| {
            const a = src_arr[i] >> 24;
            const expected = if (a == 0)
                dst_arr[i]
            else if (a == 255)
                src_arr[i]
            else
                Hvs.blendPixel(dst_arr[i], src_arr[i], a, premult);
            try std.testing.expectEqual(expected, res_arr[i]);
        }
    }
}

test "HVS scaled T-tiled plane compositing matches exact integer division" {
    var hvs = Hvs{};
    const src_w: u32 = 37;
    const src_h: u32 = 23;
    const dst_w: u32 = 59;
    const dst_h: u32 = 41;
    var ram: [65536]u8 = @splat(0);

    for (0..src_h) |y| {
        for (0..src_w) |x| {
            const off = texture.texelOffsetOf(.argb8888, 64, src_h, @intCast(x), @intCast(y));
            const color: u32 = 0xff000000 | (@as(u32, @intCast(y)) << 16) | (@as(u32, @intCast(x)) << 8) | 0x55;
            std.mem.writeInt(u32, ram[off..][0..4], color, .little);
        }
    }

    // Non-unity DLIST entry at slot 16 (8 words: ctl0, pos0, pos1 (dst_w/dst_h), pos2 (src_w/src_h), pos3, ptr0, ptr_ctx0, pitch0)
    hvs.write32(Hvs.DLIST_OFFSET + 16 * 4, Hvs.SCALER_CTL0_VALID | (8 << 24) | (3 << 20) | 7);
    hvs.write32(Hvs.DLIST_OFFSET + 17 * 4, 0);
    hvs.write32(Hvs.DLIST_OFFSET + 18 * 4, (dst_h << 16) | dst_w);
    hvs.write32(Hvs.DLIST_OFFSET + 19 * 4, (1 << 30) | (src_h << 16) | src_w);
    hvs.write32(Hvs.DLIST_OFFSET + 20 * 4, 0);
    hvs.write32(Hvs.DLIST_OFFSET + 21 * 4, 0x80000000);
    hvs.write32(Hvs.DLIST_OFFSET + 22 * 4, 0);
    hvs.write32(Hvs.DLIST_OFFSET + 23 * 4, 2); // 2 T-tiles wide (64px)
    hvs.write32(Hvs.DLIST_OFFSET + 24 * 4, Hvs.SCALER_CTL0_END);
    hvs.write32(0x0024, 16);

    var out: [59 * 41]u32 = @splat(0);
    try std.testing.expect(hvs.compositeFrame(&ram, &out, dst_w, dst_h));

    for (0..dst_h) |py| {
        const sy = (@as(u32, @intCast(py)) * src_h) / dst_h;
        for (0..dst_w) |px| {
            const sx = (@as(u32, @intCast(px)) * src_w) / dst_w;
            const expected: u32 = 0xff000000 | (sy << 16) | (sx << 8) | 0x55;
            try std.testing.expectEqual(expected, out[py * dst_w + px]);
        }
    }
}


