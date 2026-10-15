const std = @import("std");
const qpu = @import("qpu.zig");
const qpu_sim = @import("qpu_sim.zig");
const format_mod = @import("format.zig");
const texture = @import("texture.zig");
const GlRenderer = @import("gl_renderer.zig").GlRenderer;

/// VideoCore IV 3D Engine (`brcm,bcm2835-v3d`) at `0x20c00000` (size `0x1000`).
pub const V3d = struct {
    pub const BASE_ADDR: u32 = 0x20c00000;
    pub const SIZE: u32 = 0x1000;

    // V3D Interrupt bits
    pub const INT_FRDONE: u32 = 1 << 0;
    pub const INT_FLDONE: u32 = 1 << 1;
    pub const INT_OUTOMEM: u32 = 1 << 2;
    pub const INT_SPILLUSE: u32 = 1 << 3;

    pub const DrawCall = struct {
        shader_rec_addr: u32 = 0,
        num_attrs: u4 = 0,
        mode: u8 = 4, // 4 = triangles, 5 = strip, 6 = fan
        indexed: bool = false,
        u16_indices: bool = true,
        count: u32 = 0,
        first_or_offset: u32 = 0,
        index_buffer_addr: u32 = 0,
        vp_x: f32 = 0,
        vp_y: f32 = 0,
        clip_x: u16 = 0,
        clip_y: u16 = 0,
        clip_w: u16 = 4096,
        clip_h: u16 = 4096,
        config_b0: u8 = 0x03, // enable forward + reverse
        config_b1: u8 = 0x70, // depth_func = always
        config_b2: u8 = 0x00,
    };

    pub const MAX_PREBINNED_TRIS = 2048;

    pub const PreparedDraw = struct {
        fs_code_phys: u32 = 0,
        fs_code_len: u16 = 0,
        fs_unif_phys: u32 = 0,
        fs_unif_len: u16 = 0,
        fs_num_varyings: u8 = 0,
        valid: bool = false,
    };

    pub const ShadedVertex = struct {
        x: f32 = 0,
        y: f32 = 0,
        z: f32 = 0.5,
        inv_w: f32 = 1.0,
        persp_varyings: [16]f32 = [_]f32{0} ** 16,
    };

    pub const ShadedTriangle = struct {
        draw_idx: u16,
        min_x: u32,
        min_y: u32,
        max_x: u32,
        max_y: u32,
        area: f32,
        v: [3]ShadedVertex,
    };

    scratch: u32 = 0,
    l2cactl: u32 = 0,
    slcactl: u32 = 0,
    intctl: u32 = 0,
    int_mask: u32 = 0,

    ct0cs: u32 = 0,
    ct1cs: u32 = 0,
    ct0ea: u32 = 0,
    ct1ea: u32 = 0,
    ct0ca: u32 = 0,
    ct1ca: u32 = 0,

    bfc: u32 = 0,
    rfc: u32 = 0,
    bpca: u32 = 0,
    bpcs: u32 = 0x00100000,
    bpoa: u32 = 0,
    bpos: u32 = 0,
    bxcf: u32 = 0,
    sqrsv0: u32 = 0,
    sqrsv1: u32 = 0,
    sqcntl: u32 = 0,
    srqpc: u32 = 0,
    srqua: u32 = 0,
    srqul: u32 = 0,
    srqcs: u32 = 0,
    vpmbase: u32 = 0,

    // Binning state collected during BCL execution
    draws: [256]DrawCall = undefined,
    draws_len: usize = 0,
    cur_shader_rec: u32 = 0,
    cur_num_attrs: u4 = 0,
    cur_vp_x: f32 = 0,
    cur_vp_y: f32 = 0,
    cur_clip_x: u16 = 0,
    cur_clip_y: u16 = 0,
    cur_clip_w: u16 = 4096,
    cur_clip_h: u16 = 4096,
    cur_cfg0: u8 = 0x03,
    cur_cfg1: u8 = 0x70,
    cur_cfg2: u8 = 0x00,
    multisample_bin: bool = false,

    // Tile buffer (64x64 pixels max per tile)
    tile_color: [64 * 64]u32 = [_]u32{0} ** (64 * 64),
    tile_depth: [64 * 64]f32 = [_]f32{1.0} ** (64 * 64),
    tile_color_solid: ?u32 = null,
    tile_depth_valid: bool = false,
    tile_clear_zs: f32 = 1.0,

    // Pre-shaded & pre-binned state for the current RCL frame
    prep_draws: [256]PreparedDraw = undefined,
    shaded_tris: [MAX_PREBINNED_TRIS]ShadedTriangle = undefined,
    shaded_tris_len: usize = 0,
    overflow_draw_start: usize = 0,

    gl: GlRenderer = .{},
    gl_initialized: bool = false,

    pub fn irqPending(self: *const V3d) bool {
        return (self.intctl & self.int_mask) != 0;
    }

    pub fn read32(self: *const V3d, offset: u32) u32 {
        return switch (offset) {
            0x000 => 0x02443356, // V3D_IDENT0 ("V3D\x02")
            0x004 => 0x41101411, // V3D_IDENT1 (Rev 1, 1 slice, 4 QPUs)
            0x008 => 0x0000010f, // V3D_IDENT2
            0x010 => self.scratch,
            0x020 => self.l2cactl,
            0x024 => self.slcactl,
            0x030 => self.intctl,
            0x034 => self.int_mask,
            0x038 => ~self.int_mask,
            0x100 => self.ct0cs & ~@as(u32, 1 << 5), // CTRUN=0 (completes synchronously)
            0x104 => self.ct1cs & ~@as(u32, 1 << 5),
            0x108 => self.ct0ea,
            0x10c => self.ct1ea,
            0x110 => self.ct0ca,
            0x114 => self.ct1ca,
            0x130 => 0, // V3D_PCS (pipeline idle)
            0x134 => self.bfc,
            0x138 => self.rfc,
            0x300 => self.bpca,
            0x304 => self.bpcs,
            0x308 => self.bpoa,
            0x30c => self.bpos,
            0x310 => self.bxcf,
            0x410 => self.sqrsv0,
            0x414 => self.sqrsv1,
            0x418 => self.sqcntl,
            0x430 => self.srqpc,
            0x434 => self.srqua,
            0x438 => self.srqul,
            0x43c => self.srqcs,
            0x500 => self.vpmbase,
            0xf00, 0xf04, 0xf08, 0xf0c, 0xf10, 0xf20 => 0,
            else => 0,
        };
    }

    pub fn write32(self: *V3d, offset: u32, val: u32, ram: []u8) void {
        if (!self.gl_initialized) {
            self.gl = GlRenderer.init();
            self.gl_initialized = true;
        }

        switch (offset) {
            0x010 => self.scratch = val,
            0x020 => self.l2cactl = val,
            0x024 => self.slcactl = val,
            0x030 => self.intctl &= ~val, // W1C
            0x034 => self.int_mask |= val, // INTENA
            0x038 => self.int_mask &= ~val, // INTDIS
            0x100 => {
                if ((val & (1 << 15)) != 0) { // CTRSTA reset
                    self.ct0cs = 0;
                } else {
                    self.ct0cs = val;
                }
            },
            0x104 => {
                if ((val & (1 << 15)) != 0) {
                    self.ct1cs = 0;
                } else {
                    self.ct1cs = val;
                }
            },
            0x108 => { // V3D_CT0EA -> Run Binning Control List (BCL)
                self.ct0ea = val;
                if (self.ct0ea > self.ct0ca) {
                    self.executeBcl(ram, self.ct0ca, self.ct0ea);
                    self.ct0ca = self.ct0ea;
                    self.bfc +%= 1;
                    self.intctl |= INT_FLDONE;
                }
            },
            0x10c => { // V3D_CT1EA -> Run Rendering Control List (RCL)
                self.ct1ea = val;
                if (self.ct1ea > self.ct1ca) {
                    self.executeRcl(ram, self.ct1ca, self.ct1ea);
                    self.ct1ca = self.ct1ea;
                    self.rfc +%= 1;
                    self.intctl |= INT_FRDONE;
                }
            },
            0x110 => self.ct0ca = val,
            0x114 => self.ct1ca = val,
            0x134 => self.bfc &= ~val,
            0x138 => self.rfc &= ~val,
            0x308 => self.bpoa = val,
            0x30c => self.bpos = val,
            0x310 => self.bxcf = val,
            0x410 => self.sqrsv0 = val,
            0x414 => self.sqrsv1 = val,
            0x418 => self.sqcntl = val,
            0x430 => { // V3D_SRQPC: User QPU program request
                self.srqpc = val;
                const completed = ((self.srqcs >> 16) & 0xff) +% 1;
                self.srqcs = (self.srqcs & 0xff000000) | (completed << 16) | (completed << 8);
            },
            0x434 => self.srqua = val,
            0x438 => self.srqul = val,
            0x43c => self.srqcs = val,
            0x500 => self.vpmbase = val,
            else => {},
        }
    }

    fn executeBcl(self: *V3d, ram: []const u8, start_bus: u32, end_bus: u32) void {
        var pc = start_bus & 0x1FFFFFFF;
        const end = end_bus & 0x1FFFFFFF;
        if (end > ram.len) return;

        while (pc < end) {
            const op = ram[pc];
            switch (op) {
                0 => break, // HALT
                1, 5, 8, 18 => pc += 1, // NOP, FLUSH_ALL, WAIT_SEMAPHORE, RETURN
                4, 7 => pc += 1, // FLUSH, INCREMENT_SEMAPHORE
                6 => { // START_TILE_BINNING
                    self.draws_len = 0;
                    pc += 1;
                },
                16, 17 => { // BRANCH / BRANCH_TO_SUB_LIST
                    if (pc + 5 > end) break;
                    pc += 5;
                },
                32 => { // GL_INDEXED_PRIMITIVE (14 bytes)
                    if (pc + 14 > end) break;
                    const mode_byte = ram[pc + 1];
                    const count = std.mem.readInt(u32, ram[pc + 2 ..][0..4], .little);
                    const index_off = std.mem.readInt(u32, ram[pc + 6 ..][0..4], .little);
                    if (self.draws_len < self.draws.len) {
                        self.draws[self.draws_len] = .{
                            .shader_rec_addr = self.cur_shader_rec,
                            .num_attrs = self.cur_num_attrs,
                            .mode = mode_byte & 0x0f,
                            .indexed = true,
                            .u16_indices = (mode_byte & 0x10) != 0,
                            .count = count,
                            .first_or_offset = 0,
                            .index_buffer_addr = index_off,
                            .vp_x = self.cur_vp_x,
                            .vp_y = self.cur_vp_y,
                            .clip_x = self.cur_clip_x,
                            .clip_y = self.cur_clip_y,
                            .clip_w = self.cur_clip_w,
                            .clip_h = self.cur_clip_h,
                            .config_b0 = self.cur_cfg0,
                            .config_b1 = self.cur_cfg1,
                            .config_b2 = self.cur_cfg2,
                        };
                        self.draws_len += 1;
                    }
                    pc += 14;
                },
                33 => { // GL_ARRAY_PRIMITIVE (10 bytes)
                    if (pc + 10 > end) break;
                    const mode = ram[pc + 1] & 0x0f;
                    const count = std.mem.readInt(u32, ram[pc + 2 ..][0..4], .little);
                    const first = std.mem.readInt(u32, ram[pc + 6 ..][0..4], .little);
                    if (self.draws_len < self.draws.len) {
                        self.draws[self.draws_len] = .{
                            .shader_rec_addr = self.cur_shader_rec,
                            .num_attrs = self.cur_num_attrs,
                            .mode = mode,
                            .indexed = false,
                            .count = count,
                            .first_or_offset = first,
                            .vp_x = self.cur_vp_x,
                            .vp_y = self.cur_vp_y,
                            .clip_x = self.cur_clip_x,
                            .clip_y = self.cur_clip_y,
                            .clip_w = self.cur_clip_w,
                            .clip_h = self.cur_clip_h,
                            .config_b0 = self.cur_cfg0,
                            .config_b1 = self.cur_cfg1,
                            .config_b2 = self.cur_cfg2,
                        };
                        self.draws_len += 1;
                    }
                    pc += 10;
                },
                56 => pc += 2, // PRIMITIVE_LIST_FORMAT
                64 => { // GL_SHADER_STATE (5 bytes)
                    if (pc + 5 > end) break;
                    const word = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little);
                    const n_attr: u4 = @intCast(if ((word & 7) == 0) 8 else (word & 7));
                    self.cur_num_attrs = n_attr;
                    self.cur_shader_rec = word & ~@as(u32, 0xf);
                    self.warmShaderCache(ram, self.cur_shader_rec);
                    pc += 5;
                },
                96 => { // CONFIGURATION_BITS (4 bytes)
                    if (pc + 4 > end) break;
                    self.cur_cfg0 = ram[pc + 1];
                    self.cur_cfg1 = ram[pc + 2];
                    self.cur_cfg2 = ram[pc + 3];
                    pc += 4;
                },
                97, 98, 99, 101 => pc += 5, // FLAT_SHADE, POINT_SIZE, LINE_WIDTH, DEPTH_OFFSET
                100 => pc += 3, // RHT_X_BOUNDARY
                102 => { // CLIP_WINDOW (9 bytes)
                    if (pc + 9 > end) break;
                    self.cur_clip_x = std.mem.readInt(u16, ram[pc + 1 ..][0..2], .little);
                    self.cur_clip_y = std.mem.readInt(u16, ram[pc + 3 ..][0..2], .little);
                    self.cur_clip_w = std.mem.readInt(u16, ram[pc + 5 ..][0..2], .little);
                    self.cur_clip_h = std.mem.readInt(u16, ram[pc + 7 ..][0..2], .little);
                    pc += 9;
                },
                103 => { // VIEWPORT_OFFSET (5 bytes, signed 12.4 fixed point)
                    if (pc + 5 > end) break;
                    const vx: i16 = @bitCast(std.mem.readInt(u16, ram[pc + 1 ..][0..2], .little));
                    const vy: i16 = @bitCast(std.mem.readInt(u16, ram[pc + 3 ..][0..2], .little));
                    self.cur_vp_x = @as(f32, @floatFromInt(vx)) / 16.0;
                    self.cur_vp_y = @as(f32, @floatFromInt(vy)) / 16.0;
                    pc += 5;
                },
                104, 105, 106 => pc += 9, // Z_CLIPPING, CLIPPER_XY_SCALING, CLIPPER_Z_SCALING
                112 => { // TILE_BINNING_MODE_CONFIG (16 bytes)
                    if (pc + 16 > end) break;
                    self.multisample_bin = (ram[pc + 15] & 1) != 0;
                    self.draws_len = 0;
                    pc += 16;
                },
                else => break,
            }
        }
    }

    fn warmShaderCache(self: *V3d, ram: []const u8, shader_rec_bus: u32) void {
        const rec_phys = shader_rec_bus & 0x1FFFFFFF;
        if (rec_phys + 36 > ram.len) return;
        const fs_code_phys = std.mem.readInt(u32, ram[rec_phys + 4 ..][0..4], .little) & 0x1FFFFFFF;
        const vs_code_phys = std.mem.readInt(u32, ram[rec_phys + 16 ..][0..4], .little) & 0x1FFFFFFF;
        var vs_buf: [512]qpu.Inst = undefined;
        var fs_buf: [512]qpu.Inst = undefined;
        const vs_code = extractQpuProgram(ram, vs_code_phys, &vs_buf);
        const fs_code = extractQpuProgram(ram, fs_code_phys, &fs_buf);
        if (vs_code.len > 0 and fs_code.len > 0) {
            _ = self.gl.getOrTranslateProgram(vs_code, fs_code);
        }
    }

    fn extractQpuProgram(ram: []const u8, phys: u32, out_buf: *[512]qpu.Inst) []const qpu.Inst {
        if (phys >= ram.len) return &.{};
        const max_bytes = ram.len - phys;
        const max_insts = @min(max_bytes / 8, out_buf.len);
        for (0..max_insts) |i| {
            const inst = std.mem.readInt(u64, ram[phys + i * 8 ..][0..8], .little);
            out_buf[i] = inst;
            const sig = qpu.getSig(inst);
            if (sig == .prog_end or sig == .color_load_end) {
                const len = @min(i + 3, max_insts);
                for (i + 1..len) |j| {
                    out_buf[j] = std.mem.readInt(u64, ram[phys + j * 8 ..][0..8], .little);
                }
                return out_buf[0..len];
            }
        }
        return out_buf[0..max_insts];
    }

    fn extractUniforms(ram: []const u8, phys: u32, out_buf: *[128]u32) []const u32 {
        if (phys >= ram.len) return &.{};
        const max_bytes = ram.len - phys;
        const max_words = @min(max_bytes / 4, out_buf.len);
        for (0..max_words) |i| {
            out_buf[i] = std.mem.readInt(u32, ram[phys + i * 4 ..][0..4], .little);
        }
        return out_buf[0..max_words];
    }

    /// Pre-shades and bins triangles across all draw calls once per frame before tile loop.
    fn prepareDrawsForFrame(self: *V3d, ram: []const u8) void {
        self.shaded_tris_len = 0;
        self.overflow_draw_start = self.draws_len;

        var vs_buf: [512]qpu.Inst = undefined;
        var fs_buf: [512]qpu.Inst = undefined;
        var vs_unif_buf: [128]u32 = undefined;

        for (self.draws[0..self.draws_len], 0..) |draw, draw_idx| {
            self.prep_draws[draw_idx] = .{};
            if (draw.count < 3) continue;
            const rec_phys = draw.shader_rec_addr & 0x1FFFFFFF;
            if (rec_phys + 36 + @as(u32, draw.num_attrs) * 8 > ram.len) continue;

            const fs_num_varyings = ram[rec_phys + 3];
            const fs_code_phys = std.mem.readInt(u32, ram[rec_phys + 4 ..][0..4], .little) & 0x1FFFFFFF;
            const fs_unif_phys = std.mem.readInt(u32, ram[rec_phys + 8 ..][0..4], .little) & 0x1FFFFFFF;
            const vs_attr_mask = ram[rec_phys + 14];
            const vs_code_phys = std.mem.readInt(u32, ram[rec_phys + 16 ..][0..4], .little) & 0x1FFFFFFF;
            const vs_unif_phys = std.mem.readInt(u32, ram[rec_phys + 20 ..][0..4], .little) & 0x1FFFFFFF;

            const vs_code = extractQpuProgram(ram, vs_code_phys, &vs_buf);
            const fs_code = extractQpuProgram(ram, fs_code_phys, &fs_buf);
            if (vs_code.len == 0 or fs_code.len == 0) continue;

            const vs_unifs = extractUniforms(ram, vs_unif_phys, &vs_unif_buf);
            const max_unif_words: u16 = if (fs_unif_phys < ram.len) @intCast(@min((ram.len - fs_unif_phys) / 4, 128)) else 0;

            self.prep_draws[draw_idx] = .{
                .fs_code_phys = fs_code_phys,
                .fs_code_len = @intCast(fs_code.len),
                .fs_unif_phys = fs_unif_phys,
                .fs_unif_len = max_unif_words,
                .fs_num_varyings = fs_num_varyings,
                .valid = true,
            };

            const num_tris: u32 = switch (draw.mode) {
                4 => draw.count / 3,
                5, 6 => if (draw.count >= 3) draw.count - 2 else 0,
                else => 0,
            };

            if (self.shaded_tris_len + num_tris > MAX_PREBINNED_TRIS) {
                self.overflow_draw_start = draw_idx;
                break;
            }

            var tri_idx: u32 = 0;
            while (tri_idx < num_tris) : (tri_idx += 1) {
                var v_indices: [3]u32 = undefined;
                switch (draw.mode) {
                    4 => {
                        v_indices[0] = tri_idx * 3 + 0;
                        v_indices[1] = tri_idx * 3 + 1;
                        v_indices[2] = tri_idx * 3 + 2;
                    },
                    5 => {
                        if ((tri_idx & 1) == 0) {
                            v_indices[0] = tri_idx + 0;
                            v_indices[1] = tri_idx + 1;
                            v_indices[2] = tri_idx + 2;
                        } else {
                            v_indices[0] = tri_idx + 1;
                            v_indices[1] = tri_idx + 0;
                            v_indices[2] = tri_idx + 2;
                        }
                    },
                    6 => {
                        v_indices[0] = 0;
                        v_indices[1] = tri_idx + 1;
                        v_indices[2] = tri_idx + 2;
                    },
                    else => continue,
                }

                for (&v_indices) |*vi| {
                    if (draw.indexed) {
                        const idx_base = draw.index_buffer_addr & 0x1FFFFFFF;
                        if (draw.u16_indices) {
                            const off = idx_base + vi.* * 2;
                            vi.* = if (off + 2 <= ram.len) std.mem.readInt(u16, ram[off..][0..2], .little) else 0;
                        } else {
                            const off = idx_base + vi.*;
                            vi.* = if (off < ram.len) ram[off] else 0;
                        }
                    } else {
                        vi.* += draw.first_or_offset;
                    }
                }

                var vpm_in: [32]qpu_sim.Vec = [_]qpu_sim.Vec{qpu_sim.splat(0)} ** 32;
                var vpm_words: usize = 0;
                for (0..draw.num_attrs) |ai| {
                    if (vs_attr_mask != 0 and (vs_attr_mask & (@as(u8, 1) << @intCast(ai))) == 0) continue;
                    const a_off = rec_phys + 36 + ai * 8;
                    const attr_base = std.mem.readInt(u32, ram[a_off..][0..4], .little) & 0x1FFFFFFF;
                    const attr_bytes: u32 = @as(u32, ram[a_off + 4]) + 1;
                    const attr_stride: u32 = ram[a_off + 5];
                    const words = (attr_bytes + 3) / 4;
                    for (0..words) |w_i| {
                        if (vpm_words >= vpm_in.len) break;
                        for (0..3) |lane| {
                            const v_addr = attr_base + v_indices[lane] * attr_stride + @as(u32, @intCast(w_i * 4));
                            if (v_addr + 4 <= ram.len) {
                                vpm_in[vpm_words][lane] = std.mem.readInt(u32, ram[v_addr..][0..4], .little);
                            }
                        }
                        vpm_words += 1;
                    }
                }

                const vs_res = qpu_sim.run(vs_code, .{
                    .uniforms = vs_unifs,
                    .vpm_in = vpm_in[0..vpm_words],
                }) catch continue;
                if (vs_res.vpm_out_len < 3) continue;

                var verts: [3]ShadedVertex = .{ .{}, .{}, .{} };
                const n_var = @min(@as(usize, fs_num_varyings), 16);
                for (0..3) |lane| {
                    const xy_packed = vs_res.vpm_out[0][lane];
                    const xs: i16 = @bitCast(@as(u16, @truncate(xy_packed)));
                    const ys: i16 = @bitCast(@as(u16, @truncate(xy_packed >> 16)));
                    verts[lane].x = @as(f32, @floatFromInt(xs)) / 16.0 + draw.vp_x;
                    verts[lane].y = @as(f32, @floatFromInt(ys)) / 16.0 + draw.vp_y;
                    verts[lane].z = @bitCast(vs_res.vpm_out[1][lane]);
                    const raw_inv_w: f32 = @bitCast(vs_res.vpm_out[2][lane]);
                    const inv_w = if (raw_inv_w == 0.0) 1.0 else raw_inv_w;
                    verts[lane].inv_w = inv_w;
                    for (0..n_var) |vi| {
                        if (3 + vi < vs_res.vpm_out_len) {
                            const raw_v: f32 = @bitCast(vs_res.vpm_out[3 + vi][lane]);
                            verts[lane].persp_varyings[vi] = raw_v * inv_w;
                        }
                    }
                }

                const area = (verts[1].x - verts[0].x) * (verts[2].y - verts[0].y) -
                    (verts[1].y - verts[0].y) * (verts[2].x - verts[0].x);
                if (@abs(area) < 1e-6) continue;

                const clip_min_x: f32 = @floatFromInt(draw.clip_x);
                const clip_min_y: f32 = @floatFromInt(draw.clip_y);
                const clip_max_x: f32 = @floatFromInt(@as(u32, draw.clip_x) + draw.clip_w);
                const clip_max_y: f32 = @floatFromInt(@as(u32, draw.clip_y) + draw.clip_h);

                const min_fx = @max(@floor(@min(verts[0].x, @min(verts[1].x, verts[2].x))), clip_min_x);
                const min_fy = @max(@floor(@min(verts[0].y, @min(verts[1].y, verts[2].y))), clip_min_y);
                const max_fx = @min(@ceil(@max(verts[0].x, @max(verts[1].x, verts[2].x))), clip_max_x);
                const max_fy = @min(@ceil(@max(verts[0].y, @max(verts[1].y, verts[2].y))), clip_max_y);
                if (min_fx >= max_fx or min_fy >= max_fy) continue;

                self.shaded_tris[self.shaded_tris_len] = .{
                    .draw_idx = @intCast(draw_idx),
                    .min_x = @intFromFloat(min_fx),
                    .min_y = @intFromFloat(min_fy),
                    .max_x = @intFromFloat(max_fx),
                    .max_y = @intFromFloat(max_fy),
                    .area = area,
                    .v = verts,
                };
                self.shaded_tris_len += 1;
            }
        }
    }

    const PendingTileLoad = struct {
        addr: u32,
        tiling: u2,
        format: u2,
    };

    fn executeRcl(self: *V3d, ram: []u8, start_bus: u32, end_bus: u32) void {
        var pc = start_bus & 0x1FFFFFFF;
        const end = end_bus & 0x1FFFFFFF;
        if (end > ram.len) return;

        self.prepareDrawsForFrame(ram);

        var fb_addr: u32 = 0;
        var fb_width: u32 = 0;
        var fb_height: u32 = 0;
        var fb_flags: u16 = 0;
        var clear_color0: u32 = 0;
        var clear_zs: f32 = 1.0;

        var cur_tile_x: u32 = 0;
        var cur_tile_y: u32 = 0;
        var has_tile_coords: bool = false;
        var pending_load: ?PendingTileLoad = null;
        var tile_loaded: bool = false;
        var tile_rendered: bool = false;

        while (pc < end) {
            const op = ram[pc];
            switch (op) {
                0 => break, // HALT
                1, 4, 5, 8, 18 => pc += 1,
                16 => { // BRANCH
                    if (pc + 5 > end) break;
                    pc = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little) & 0x1FFFFFFF;
                },
                17 => { // BRANCH_TO_SUB_LIST (executes binned primitives for the current tile)
                    if (pc + 5 > end) break;
                    const tile_size: u32 = 64;
                    if (!tile_loaded) {
                        self.tile_color_solid = clear_color0;
                        self.tile_depth_valid = false;
                        self.tile_clear_zs = clear_zs;
                        tile_loaded = true;
                    }
                    self.renderDrawsIntoTile(ram, cur_tile_x * tile_size, cur_tile_y * tile_size, tile_size);
                    tile_rendered = true;
                    pc += 5;
                },
                24, 25 => { // STORE_MS_TILE_BUFFER / STORE_MS_TILE_BUFFER_AND_EOF (1 byte)
                    const tile_size: u32 = 64;
                    if (!tile_loaded) {
                        self.tile_color_solid = clear_color0;
                        self.tile_depth_valid = false;
                        self.tile_clear_zs = clear_zs;
                        tile_loaded = true;
                    }
                    const r_format: u2 = @truncate((fb_flags >> 2) & 3);
                    const r_tiling: u2 = @truncate((fb_flags >> 6) & 3);
                    const ls_format: u2 = if (r_format == 1) 0 else 2;
                    self.storeTileToRam(ram, fb_addr, fb_width, fb_height, cur_tile_x, cur_tile_y, tile_size, r_tiling, ls_format);
                    tile_loaded = false;
                    tile_rendered = false;
                    has_tile_coords = false;
                    pending_load = null;
                    pc += 1;
                },
                28 => { // STORE_TILE_BUFFER_GENERAL (7 bytes)
                    if (pc + 7 > end) break;
                    const bits = std.mem.readInt(u16, ram[pc + 1 ..][0..2], .little);
                    const addr_word = std.mem.readInt(u32, ram[pc + 3 ..][0..4], .little);
                    const buf_kind = bits & 7;
                    if (buf_kind == 1) { // Color buffer store
                        const tile_size: u32 = 64;
                        if (!tile_loaded) {
                            self.tile_color_solid = clear_color0;
                            tile_loaded = true;
                        }
                        const ls_tiling: u2 = @truncate((bits >> 4) & 3);
                        const ls_format: u2 = @truncate((bits >> 8) & 3);
                        const dst_addr = if ((addr_word & ~@as(u32, 0xf)) != 0) (addr_word & ~@as(u32, 0xf)) else fb_addr;
                        self.storeTileToRam(ram, dst_addr, fb_width, fb_height, cur_tile_x, cur_tile_y, tile_size, ls_tiling, ls_format);
                    }
                    if ((bits & (1 << 15)) == 0) {
                        // Last store for tile
                        tile_loaded = false;
                        tile_rendered = false;
                        has_tile_coords = false;
                        pending_load = null;
                    }
                    pc += 7;
                },
                29 => { // LOAD_TILE_BUFFER_GENERAL (7 bytes)
                    if (pc + 7 > end) break;
                    const bits = std.mem.readInt(u16, ram[pc + 1 ..][0..2], .little);
                    const addr_word = std.mem.readInt(u32, ram[pc + 3 ..][0..4], .little);
                    const buf_kind = bits & 7;
                    if (buf_kind == 1) { // Load color buffer from memory into tile buffer
                        const ls_tiling: u2 = @truncate((bits >> 4) & 3);
                        const ls_format: u2 = @truncate((bits >> 8) & 3);
                        const load_addr = addr_word & ~@as(u32, 0xf);
                        if (has_tile_coords) {
                            self.loadTileFromRam(ram, load_addr, fb_width, fb_height, cur_tile_x, cur_tile_y, 64, ls_tiling, ls_format);
                            self.tile_color_solid = null;
                            self.tile_depth_valid = false;
                            self.tile_clear_zs = clear_zs;
                            tile_loaded = true;
                        } else {
                            pending_load = .{
                                .addr = load_addr,
                                .tiling = ls_tiling,
                                .format = ls_format,
                            };
                        }
                    }
                    pc += 7;
                },
                113 => { // TILE_RENDERING_MODE_CONFIG (11 bytes)
                    if (pc + 11 > end) break;
                    fb_addr = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little);
                    fb_width = std.mem.readInt(u16, ram[pc + 5 ..][0..2], .little);
                    fb_height = std.mem.readInt(u16, ram[pc + 7 ..][0..2], .little);
                    fb_flags = std.mem.readInt(u16, ram[pc + 9 ..][0..2], .little);
                    pc += 11;
                },
                114 => { // CLEAR_COLORS (14 bytes)
                    if (pc + 14 > end) break;
                    const raw_c0 = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little);
                    const zs_word = std.mem.readInt(u32, ram[pc + 9 ..][0..4], .little) & 0x00FFFFFF;
                    clear_zs = @as(f32, @floatFromInt(zs_word)) / 16777215.0;
                    // Note: for RGB565 render targets, kernel/userspace packs TWO RGB565 pixels in clear_color0
                    const r_format: u2 = @truncate((fb_flags >> 2) & 3);
                    if (r_format == 0 or r_format == 2) {
                        clear_color0 = format_mod.fromRgb565(@truncate(raw_c0));
                    } else {
                        clear_color0 = raw_c0;
                    }
                    pc += 14;
                },
                115 => { // TILE_COORDINATES (3 bytes)
                    if (pc + 3 > end) break;
                    cur_tile_x = ram[pc + 1];
                    cur_tile_y = ram[pc + 2];
                    has_tile_coords = true;
                    if (pending_load) |pl| {
                        self.loadTileFromRam(ram, pl.addr, fb_width, fb_height, cur_tile_x, cur_tile_y, 64, pl.tiling, pl.format);
                        self.tile_color_solid = null;
                        self.tile_depth_valid = false;
                        self.tile_clear_zs = clear_zs;
                        tile_loaded = true;
                        pending_load = null;
                    } else if (!tile_loaded) {
                        self.tile_color_solid = clear_color0;
                        self.tile_depth_valid = false;
                        self.tile_clear_zs = clear_zs;
                        tile_loaded = true;
                    }
                    pc += 3;
                },
                else => break,
            }
        }
    }

    fn loadTileFromRam(
        self: *V3d,
        ram: []const u8,
        base_bus: u32,
        fb_w: u32,
        fb_h: u32,
        tile_x: u32,
        tile_y: u32,
        tile_size: u32,
        tiling: u2,
        ls_format: u2,
    ) void {
        const base = base_bus & 0x1FFFFFFF;
        const is_565 = (ls_format == 1 or ls_format == 2);
        const fmt: format_mod.Format = if (is_565) .rgb565 else .argb8888;
        const cpp: u32 = if (is_565) 2 else 4;
        const x0 = tile_x * tile_size;
        const y0 = tile_y * tile_size;

        if (!is_565 and tile_size == 64 and x0 + 64 <= fb_w and y0 + 64 <= fb_h) {
            if (tiling == 0) {
                for (0..64) |ty| {
                    const py = y0 + @as(u32, @intCast(ty));
                    const off = base + (py * fb_w + x0) * 4;
                    if (off + 256 <= ram.len) {
                        @memcpy(std.mem.sliceAsBytes(self.tile_color[ty * 64 ..][0..64]), ram[off..][0..256]);
                    }
                }
                return;
            } else {
                for (0..16) |uy| {
                    for (0..16) |ux| {
                        const px = x0 + @as(u32, @intCast(ux * 4));
                        const py = y0 + @as(u32, @intCast(uy * 4));
                        const utile_off = base + texture.texelOffsetOf(.argb8888, fb_w, fb_h, px, py);
                        if (utile_off + 64 <= ram.len) {
                            inline for (0..4) |ry| {
                                const dst_idx = (uy * 4 + ry) * 64 + ux * 4;
                                @memcpy(
                                    std.mem.sliceAsBytes(self.tile_color[dst_idx..][0..4]),
                                    ram[utile_off + ry * 16 ..][0..16],
                                );
                            }
                        }
                    }
                }
                return;
            }
        }

        for (0..tile_size) |ty| {
            const py = y0 + @as(u32, @intCast(ty));
            if (py >= fb_h) continue;
            for (0..tile_size) |tx| {
                const px = x0 + @as(u32, @intCast(tx));
                if (px >= fb_w) continue;
                const off = base + if (tiling == 0)
                    (py * fb_w + px) * cpp
                else
                    texture.texelOffsetOf(fmt, fb_w, fb_h, px, py);
                if (off + cpp <= ram.len) {
                    self.tile_color[ty * tile_size + tx] = if (is_565)
                        format_mod.fromRgb565(std.mem.readInt(u16, ram[off..][0..2], .little))
                    else
                        std.mem.readInt(u32, ram[off..][0..4], .little);
                }
            }
        }
    }

    fn storeTileToRam(
        self: *const V3d,
        ram: []u8,
        base_bus: u32,
        fb_w: u32,
        fb_h: u32,
        tile_x: u32,
        tile_y: u32,
        tile_size: u32,
        tiling: u2,
        ls_format: u2,
    ) void {
        const base = base_bus & 0x1FFFFFFF;
        const is_565 = (ls_format == 1 or ls_format == 2);
        const fmt: format_mod.Format = if (is_565) .rgb565 else .argb8888;
        const cpp: u32 = if (is_565) 2 else 4;
        const x0 = tile_x * tile_size;
        const y0 = tile_y * tile_size;

        if (!is_565 and tile_size == 64 and x0 + 64 <= fb_w and y0 + 64 <= fb_h) {
            if (tiling == 0) {
                if (self.tile_color_solid) |solid_c| {
                    var solid_row: [64]u32 = @splat(solid_c);
                    const row_bytes = std.mem.asBytes(&solid_row);
                    for (0..64) |ty| {
                        const py = y0 + @as(u32, @intCast(ty));
                        const off = base + (py * fb_w + x0) * 4;
                        if (off + 256 <= ram.len) {
                            @memcpy(ram[off..][0..256], row_bytes);
                        }
                    }
                } else {
                    for (0..64) |ty| {
                        const py = y0 + @as(u32, @intCast(ty));
                        const off = base + (py * fb_w + x0) * 4;
                        if (off + 256 <= ram.len) {
                            @memcpy(ram[off..][0..256], std.mem.sliceAsBytes(self.tile_color[ty * 64 ..][0..64]));
                        }
                    }
                }
                return;
            } else {
                if (self.tile_color_solid) |solid_c| {
                    var solid_utile: [16]u32 = @splat(solid_c);
                    const utile_bytes = std.mem.asBytes(&solid_utile);
                    for (0..16) |uy| {
                        for (0..16) |ux| {
                            const px = x0 + @as(u32, @intCast(ux * 4));
                            const py = y0 + @as(u32, @intCast(uy * 4));
                            const utile_off = base + texture.texelOffsetOf(.argb8888, fb_w, fb_h, px, py);
                            if (utile_off + 64 <= ram.len) {
                                @memcpy(ram[utile_off..][0..64], utile_bytes);
                            }
                        }
                    }
                } else {
                    for (0..16) |uy| {
                        for (0..16) |ux| {
                            const px = x0 + @as(u32, @intCast(ux * 4));
                            const py = y0 + @as(u32, @intCast(uy * 4));
                            const utile_off = base + texture.texelOffsetOf(.argb8888, fb_w, fb_h, px, py);
                            if (utile_off + 64 <= ram.len) {
                                inline for (0..4) |ry| {
                                    const src_idx = (uy * 4 + ry) * 64 + ux * 4;
                                    @memcpy(
                                        ram[utile_off + ry * 16 ..][0..16],
                                        std.mem.sliceAsBytes(self.tile_color[src_idx..][0..4]),
                                    );
                                }
                            }
                        }
                    }
                }
                return;
            }
        }

        const solid_565 = if (self.tile_color_solid) |sc| format_mod.toRgb565(sc) else 0;
        for (0..tile_size) |ty| {
            const py = y0 + @as(u32, @intCast(ty));
            if (py >= fb_h) continue;
            for (0..tile_size) |tx| {
                const px = x0 + @as(u32, @intCast(tx));
                if (px >= fb_w) continue;
                const off = base + if (tiling == 0)
                    (py * fb_w + px) * cpp
                else
                    texture.texelOffsetOf(fmt, fb_w, fb_h, px, py);
                const c = self.tile_color_solid orelse self.tile_color[ty * tile_size + tx];
                if (off + cpp <= ram.len) {
                    if (is_565) {
                        const c565 = if (self.tile_color_solid != null) solid_565 else format_mod.toRgb565(c);
                        std.mem.writeInt(u16, ram[off..][0..2], c565, .little);
                    } else {
                        std.mem.writeInt(u32, ram[off..][0..4], c, .little);
                    }
                }
            }
        }
    }

    fn ensureTileMaterialized(self: *V3d, need_depth: bool) void {
        if (self.tile_color_solid) |c| {
            @memset(&self.tile_color, c);
            self.tile_color_solid = null;
        }
        if (need_depth and !self.tile_depth_valid) {
            @memset(&self.tile_depth, self.tile_clear_zs);
            self.tile_depth_valid = true;
        }
    }

    fn renderDrawsIntoTile(self: *V3d, ram: []const u8, tile_px_x: u32, tile_px_y: u32, tile_size: u32) void {
        const tile_end_x = tile_px_x + tile_size;
        const tile_end_y = tile_px_y + tile_size;

        var fs_buf: [512]qpu.Inst = undefined;
        var fs_unif_buf: [128]u32 = undefined;
        var cur_draw_idx: ?u16 = null;
        var cur_fs_code: []const qpu.Inst = &.{};
        var cur_fs_unifs: []const u32 = &.{};

        for (self.shaded_tris[0..self.shaded_tris_len]) |*tri| {
            if (tri.max_x <= tile_px_x or tri.min_x >= tile_end_x or
                tri.max_y <= tile_px_y or tri.min_y >= tile_end_y)
            {
                continue;
            }

            const prep = self.prep_draws[tri.draw_idx];
            if (!prep.valid) continue;

            if (cur_draw_idx == null or cur_draw_idx.? != tri.draw_idx) {
                cur_draw_idx = tri.draw_idx;
                for (0..prep.fs_code_len) |i| {
                    fs_buf[i] = std.mem.readInt(u64, ram[prep.fs_code_phys + i * 8 ..][0..8], .little);
                }
                cur_fs_code = fs_buf[0..prep.fs_code_len];
                for (0..prep.fs_unif_len) |i| {
                    fs_unif_buf[i] = std.mem.readInt(u32, ram[prep.fs_unif_phys + i * 4 ..][0..4], .little);
                }
                cur_fs_unifs = fs_unif_buf[0..prep.fs_unif_len];
            }

            const draw = self.draws[tri.draw_idx];
            self.rasterizeShadedTriangleInTile(
                ram,
                draw,
                tri,
                cur_fs_code,
                cur_fs_unifs,
                prep.fs_num_varyings,
                tile_px_x,
                tile_px_y,
                tile_size,
            );
        }

        if (self.overflow_draw_start < self.draws_len) {
            for (self.draws[self.overflow_draw_start..self.draws_len]) |draw| {
                self.renderDrawIntoTile(ram, draw, tile_px_x, tile_px_y, tile_size);
            }
        }
    }

    fn renderDrawIntoTile(self: *V3d, ram: []const u8, draw: DrawCall, tile_px_x: u32, tile_px_y: u32, tile_size: u32) void {
        if (draw.count < 3) return;
        const rec_phys = draw.shader_rec_addr & 0x1FFFFFFF;
        if (rec_phys + 36 + @as(u32, draw.num_attrs) * 8 > ram.len) return;

        const fs_num_varyings = ram[rec_phys + 3];
        const fs_code_phys = std.mem.readInt(u32, ram[rec_phys + 4 ..][0..4], .little) & 0x1FFFFFFF;
        const fs_unif_phys = std.mem.readInt(u32, ram[rec_phys + 8 ..][0..4], .little) & 0x1FFFFFFF;
        const vs_attr_mask = ram[rec_phys + 14];
        const vs_code_phys = std.mem.readInt(u32, ram[rec_phys + 16 ..][0..4], .little) & 0x1FFFFFFF;
        const vs_unif_phys = std.mem.readInt(u32, ram[rec_phys + 20 ..][0..4], .little) & 0x1FFFFFFF;

        var vs_buf: [512]qpu.Inst = undefined;
        var fs_buf: [512]qpu.Inst = undefined;
        const vs_code = extractQpuProgram(ram, vs_code_phys, &vs_buf);
        const fs_code = extractQpuProgram(ram, fs_code_phys, &fs_buf);
        if (vs_code.len == 0 or fs_code.len == 0) return;

        var vs_unif_buf: [128]u32 = undefined;
        var fs_unif_buf: [128]u32 = undefined;
        const vs_unifs = extractUniforms(ram, vs_unif_phys, &vs_unif_buf);
        const fs_unifs = extractUniforms(ram, fs_unif_phys, &fs_unif_buf);

        const num_tris: u32 = switch (draw.mode) {
            4 => draw.count / 3,
            5, 6 => if (draw.count >= 3) draw.count - 2 else 0,
            else => 0,
        };

        var tri_idx: u32 = 0;
        while (tri_idx < num_tris) : (tri_idx += 1) {
            var v_indices: [3]u32 = undefined;
            switch (draw.mode) {
                4 => {
                    v_indices[0] = tri_idx * 3 + 0;
                    v_indices[1] = tri_idx * 3 + 1;
                    v_indices[2] = tri_idx * 3 + 2;
                },
                5 => {
                    if ((tri_idx & 1) == 0) {
                        v_indices[0] = tri_idx + 0;
                        v_indices[1] = tri_idx + 1;
                        v_indices[2] = tri_idx + 2;
                    } else {
                        v_indices[0] = tri_idx + 1;
                        v_indices[1] = tri_idx + 0;
                        v_indices[2] = tri_idx + 2;
                    }
                },
                6 => {
                    v_indices[0] = 0;
                    v_indices[1] = tri_idx + 1;
                    v_indices[2] = tri_idx + 2;
                },
                else => continue,
            }

            for (&v_indices) |*vi| {
                if (draw.indexed) {
                    const idx_base = draw.index_buffer_addr & 0x1FFFFFFF;
                    if (draw.u16_indices) {
                        const off = idx_base + vi.* * 2;
                        vi.* = if (off + 2 <= ram.len) std.mem.readInt(u16, ram[off..][0..2], .little) else 0;
                    } else {
                        const off = idx_base + vi.*;
                        vi.* = if (off < ram.len) ram[off] else 0;
                    }
                } else {
                    vi.* += draw.first_or_offset;
                }
            }

            var vpm_in: [32]qpu_sim.Vec = [_]qpu_sim.Vec{qpu_sim.splat(0)} ** 32;
            var vpm_words: usize = 0;
            for (0..draw.num_attrs) |ai| {
                if (vs_attr_mask != 0 and (vs_attr_mask & (@as(u8, 1) << @intCast(ai))) == 0) continue;
                const a_off = rec_phys + 36 + ai * 8;
                const attr_base = std.mem.readInt(u32, ram[a_off..][0..4], .little) & 0x1FFFFFFF;
                const attr_bytes: u32 = @as(u32, ram[a_off + 4]) + 1;
                const attr_stride: u32 = ram[a_off + 5];
                const words = (attr_bytes + 3) / 4;
                for (0..words) |w_i| {
                    if (vpm_words >= vpm_in.len) break;
                    for (0..3) |lane| {
                        const v_addr = attr_base + v_indices[lane] * attr_stride + @as(u32, @intCast(w_i * 4));
                        if (v_addr + 4 <= ram.len) {
                            vpm_in[vpm_words][lane] = std.mem.readInt(u32, ram[v_addr..][0..4], .little);
                        }
                    }
                    vpm_words += 1;
                }
            }

            const vs_res = qpu_sim.run(vs_code, .{
                .uniforms = vs_unifs,
                .vpm_in = vpm_in[0..vpm_words],
            }) catch continue;
            if (vs_res.vpm_out_len < 3) continue;

            var verts: [3]ShadedVertex = .{ .{}, .{}, .{} };
            const n_var = @min(@as(usize, fs_num_varyings), 16);
            for (0..3) |lane| {
                const xy_packed = vs_res.vpm_out[0][lane];
                const xs: i16 = @bitCast(@as(u16, @truncate(xy_packed)));
                const ys: i16 = @bitCast(@as(u16, @truncate(xy_packed >> 16)));
                verts[lane].x = @as(f32, @floatFromInt(xs)) / 16.0 + draw.vp_x;
                verts[lane].y = @as(f32, @floatFromInt(ys)) / 16.0 + draw.vp_y;
                verts[lane].z = @bitCast(vs_res.vpm_out[1][lane]);
                const raw_inv_w: f32 = @bitCast(vs_res.vpm_out[2][lane]);
                const inv_w = if (raw_inv_w == 0.0) 1.0 else raw_inv_w;
                verts[lane].inv_w = inv_w;
                for (0..n_var) |vi| {
                    if (3 + vi < vs_res.vpm_out_len) {
                        const raw_v: f32 = @bitCast(vs_res.vpm_out[3 + vi][lane]);
                        verts[lane].persp_varyings[vi] = raw_v * inv_w;
                    }
                }
            }

            const area = (verts[1].x - verts[0].x) * (verts[2].y - verts[0].y) -
                (verts[1].y - verts[0].y) * (verts[2].x - verts[0].x);
            if (@abs(area) < 1e-6) continue;

            const min_fx = @max(@floor(@min(verts[0].x, @min(verts[1].x, verts[2].x))), @as(f32, @floatFromInt(draw.clip_x)));
            const min_fy = @max(@floor(@min(verts[0].y, @min(verts[1].y, verts[2].y))), @as(f32, @floatFromInt(draw.clip_y)));
            const max_fx = @min(@ceil(@max(verts[0].x, @max(verts[1].x, verts[2].x))), @as(f32, @floatFromInt(@as(u32, draw.clip_x) + draw.clip_w)));
            const max_fy = @min(@ceil(@max(verts[0].y, @max(verts[1].y, verts[2].y))), @as(f32, @floatFromInt(@as(u32, draw.clip_y) + draw.clip_h)));
            if (min_fx >= max_fx or min_fy >= max_fy) continue;

            const tri = ShadedTriangle{
                .draw_idx = 0,
                .min_x = @intFromFloat(min_fx),
                .min_y = @intFromFloat(min_fy),
                .max_x = @intFromFloat(max_fx),
                .max_y = @intFromFloat(max_fy),
                .area = area,
                .v = verts,
            };
            self.rasterizeShadedTriangleInTile(ram, draw, &tri, fs_code, fs_unifs, fs_num_varyings, tile_px_x, tile_px_y, tile_size);
        }
    }

    fn edge(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32) f32 {
        return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
    }

    fn canonicalEdge(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32) f32 {
        if (ax > bx or (ax == bx and ay > by)) {
            return -edge(bx, by, ax, ay, cx, cy);
        }
        return edge(ax, ay, bx, by, cx, cy);
    }

    fn topLeft(ax: f32, ay: f32, bx: f32, by: f32, area_sign: f32) bool {
        const dx = (bx - ax) * area_sign;
        const dy = (by - ay) * area_sign;
        return (dy == 0 and dx < 0) or dy > 0;
    }

    fn rasterizeShadedTriangleInTile(
        self: *V3d,
        ram: []const u8,
        draw: DrawCall,
        tri: *const ShadedTriangle,
        fs_code: []const qpu.Inst,
        fs_unifs: []const u32,
        num_varyings: u8,
        tile_px_x: u32,
        tile_px_y: u32,
        tile_size: u32,
    ) void {
        const x_start = @max(tri.min_x, tile_px_x);
        const y_start = @max(tri.min_y, tile_px_y);
        const x_end = @min(tri.max_x, tile_px_x + tile_size);
        const y_end = @min(tri.max_y, tile_px_y + tile_size);
        if (x_start >= x_end or y_start >= y_end) return;

        const depth_func: u3 = @truncate((draw.config_b1 >> 4) & 7);
        const z_updates = (draw.config_b1 & 0x80) != 0;
        const need_depth = (depth_func != 7) or z_updates;
        self.ensureTileMaterialized(need_depth);

        const v = &tri.v;
        const area_sign = std.math.sign(tri.area);
        const n_var = @min(@as(usize, num_varyings), 16);

        // Batch up to 16 covered pixels per SIMD QPU invocation
        var batch_idx: [16]u32 = undefined;
        var batch_z: [16]f32 = undefined;
        var frag_w: qpu_sim.Vec = qpu_sim.splatF(1.0);
        var frag_z: qpu_sim.Vec = qpu_sim.splat(0);
        var frag_x_vec: qpu_sim.Vec = qpu_sim.splat(0);
        var frag_y_vec: qpu_sim.Vec = qpu_sim.splat(0);
        var tlb_in: qpu_sim.Vec = qpu_sim.splat(0);
        var vary_vecs: [16]qpu_sim.Vec = [_]qpu_sim.Vec{qpu_sim.splat(0)} ** 16;
        var batch_len: usize = 0;

        const flushBatch = struct {
            fn f(
                v3d_self: *V3d,
                count: usize,
                b_idx: *const [16]u32,
                bz: *const [16]f32,
                fw: *qpu_sim.Vec,
                fz: *qpu_sim.Vec,
                fx: *qpu_sim.Vec,
                fy: *qpu_sim.Vec,
                tin: *qpu_sim.Vec,
                vvecs: []qpu_sim.Vec,
                fcode: []const qpu.Inst,
                funifs: []const u32,
                mem: []const u8,
                z_upd: bool,
            ) void {
                if (count < 16 and count > 0) {
                    const last = count - 1;
                    for (count..16) |lane| {
                        fw[lane] = fw[last];
                        fz[lane] = fz[last];
                        fx[lane] = fx[last];
                        fy[lane] = fy[last];
                        tin[lane] = tin[last];
                        for (vvecs) |*vv| {
                            vv[lane] = vv[last];
                        }
                    }
                }
                const res = qpu_sim.run(fcode, .{
                    .uniforms = funifs,
                    .varyings = vvecs,
                    .frag_w = fw.*,
                    .frag_z = fz.*,
                    .frag_x = fx.*,
                    .frag_y = fy.*,
                    .texture_memory = mem,
                    .tlb_color_in = tin.*,
                }) catch return;
                if (res.tlb_color) |colors| {
                    for (0..count) |i| {
                        const idx = b_idx[i];
                        v3d_self.tile_color[idx] = colors[i];
                        if (z_upd) {
                            v3d_self.tile_depth[idx] = bz[i];
                        }
                    }
                }
            }
        }.f;

        var py = y_start;
        while (py < y_end) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            const row_base = (py - tile_px_y) * tile_size;

            var px = x_start;
            while (px < x_end) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                const e0 = canonicalEdge(v[1].x, v[1].y, v[2].x, v[2].y, fx, fy) * area_sign;
                const e1 = canonicalEdge(v[2].x, v[2].y, v[0].x, v[0].y, fx, fy) * area_sign;
                const e2 = canonicalEdge(v[0].x, v[0].y, v[1].x, v[1].y, fx, fy) * area_sign;

                if (e0 < 0 or (e0 == 0 and !topLeft(v[1].x, v[1].y, v[2].x, v[2].y, area_sign))) continue;
                if (e1 < 0 or (e1 == 0 and !topLeft(v[2].x, v[2].y, v[0].x, v[0].y, area_sign))) continue;
                if (e2 < 0 or (e2 == 0 and !topLeft(v[0].x, v[0].y, v[1].x, v[1].y, area_sign))) continue;

                const sum = e0 + e1 + e2;
                if (sum <= 0) continue;
                const inv_sum = 1.0 / sum;
                const w0 = e0 * inv_sum;
                const w1 = e1 * inv_sum;
                const w2 = e2 * inv_sum;

                const z = w0 * v[0].z + w1 * v[1].z + w2 * v[2].z;
                const tile_idx = row_base + (px - tile_px_x);

                if (depth_func != 7) {
                    const cur_z = self.tile_depth[tile_idx];
                    const depth_pass = switch (depth_func) {
                        0 => false, // never
                        1 => z < cur_z, // less
                        2 => z == cur_z, // equal
                        3 => z <= cur_z, // lequal
                        4 => z > cur_z, // greater
                        5 => z != cur_z, // notequal
                        6 => z >= cur_z, // gequal
                        7 => true, // always
                    };
                    if (!depth_pass) continue;
                }

                const interp_inv_w = w0 * v[0].inv_w + w1 * v[1].inv_w + w2 * v[2].inv_w;
                const w_val = if (@abs(interp_inv_w) > 1e-12) (1.0 / interp_inv_w) else 1.0;

                const lane = batch_len;
                batch_idx[lane] = tile_idx;
                batch_z[lane] = z;
                frag_w[lane] = @bitCast(w_val);
                frag_z[lane] = @bitCast(z);
                frag_x_vec[lane] = px;
                frag_y_vec[lane] = py;
                tlb_in[lane] = self.tile_color[tile_idx];

                for (0..n_var) |vi| {
                    const p_val = (w0 * v[0].persp_varyings[vi] +
                        w1 * v[1].persp_varyings[vi] +
                        w2 * v[2].persp_varyings[vi]) * w_val;
                    vary_vecs[vi][lane] = @bitCast(p_val);
                }

                batch_len += 1;
                if (batch_len == 16) {
                    flushBatch(
                        self,
                        batch_len,
                        &batch_idx,
                        &batch_z,
                        &frag_w,
                        &frag_z,
                        &frag_x_vec,
                        &frag_y_vec,
                        &tlb_in,
                        vary_vecs[0..n_var],
                        fs_code,
                        fs_unifs,
                        ram,
                        z_updates,
                    );
                    batch_len = 0;
                }
            }
        }

        if (batch_len > 0) {
            flushBatch(
                self,
                batch_len,
                &batch_idx,
                &batch_z,
                &frag_w,
                &frag_z,
                &frag_x_vec,
                &frag_y_vec,
                &tlb_in,
                vary_vecs[0..n_var],
                fs_code,
                fs_unifs,
                ram,
                z_updates,
            );
        }
    }
};

test "V3D BCL + RCL execution renders triangle into T-tiled framebuffer" {
    var v3d = V3d{};
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);

    // Build VS and FS programs in guest RAM at 0x1000 and 0x1400
    var vs: qpu.Program(32) = .{};
    vs.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_write_setup, .value = 0x00001a00 }));
    vs.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_read_setup, .value = 0x00501a00 }));
    vs.emit(try qpu.mov(qpu.wr(0), qpu.vpm_read)); // x
    vs.emit(try qpu.mov(qpu.wr(1), qpu.vpm_read)); // y
    vs.emit(try qpu.mov(qpu.wa(0), qpu.vpm_read)); // r
    vs.emit(try qpu.mov(qpu.wr(3), qpu.vpm_read)); // g
    vs.emit(try qpu.mov(qpu.wa(2), qpu.vpm_read)); // b
    vs.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(0), .a = qpu.r(0), .b = qpu.unif } }));
    vs.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(1), .a = qpu.r(1), .b = qpu.unif } }));
    vs.emit(try qpu.alu(.{ .add = .{ .op = .ftoi, .dst = qpu.wa(1), .a = qpu.r(0), .b = qpu.r(0) }, .pack = .{ .regfile_a = .@"16a" } }));
    vs.emit(try qpu.alu(.{ .add = .{ .op = .ftoi, .dst = qpu.wa(1), .a = qpu.r(1), .b = qpu.r(1) }, .pack = .{ .regfile_a = .@"16b" } }));
    vs.emit(try qpu.loadImm(.{ .add_dst = qpu.wr(2), .value = @bitCast(@as(f32, 0.5)) }));
    vs.emit(try qpu.mov(qpu.vpm_write, qpu.ra(1)));
    vs.emit(try qpu.mov(qpu.vpm_write, qpu.r(2)));
    vs.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_write, .value = @bitCast(@as(f32, 1.0)) }));
    vs.emit(try qpu.mov(qpu.vpm_write, qpu.ra(0)));
    vs.emit(try qpu.mov(qpu.vpm_write, qpu.r(3)));
    vs.emit(try qpu.mov(qpu.vpm_write, qpu.ra(2)));
    vs.end(.vertex);

    var fs: qpu.Program(32) = .{};
    for (0..3) |i| {
        const acc: u3 = @intCast(i);
        fs.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(acc), .a = qpu.vary, .b = qpu.frag_w } }));
        fs.emit(try qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(acc), .a = qpu.r(acc), .b = qpu.r(5) } }));
    }
    const one = qpu.smallImmFloat(1.0);
    fs.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(2), .b = one }, .pack = .{ .mul = .@"8a" } }));
    fs.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(1), .b = one }, .pack = .{ .mul = .@"8b" } }));
    fs.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(0), .b = one }, .pack = .{ .mul = .@"8c" } }));
    fs.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = one, .b = one }, .pack = .{ .mul = .@"8d" } }));
    fs.emit(try qpu.mov(qpu.tlb_color_all, qpu.r(3)));
    fs.end(.fragment);

    @memcpy(ram[0x1000 .. 0x1000 + vs.code().len * 8], std.mem.sliceAsBytes(vs.code()));
    @memcpy(ram[0x1400 .. 0x1400 + fs.code().len * 8], std.mem.sliceAsBytes(fs.code()));

    // VS uniforms at 0x1800: x_scale = 32.0 * 16.0, y_scale = 32.0 * 16.0
    std.mem.writeInt(u32, ram[0x1800..0x1804], @bitCast(@as(f32, 32.0 * 16.0)), .little);
    std.mem.writeInt(u32, ram[0x1804..0x1808], @bitCast(@as(f32, 32.0 * 16.0)), .little);

    // 3 vertices at 0x2000 (stride 20: x, y, r, g, b) covering the 64x64 tile in Pure Red (1, 0, 0)
    const verts = [_]f32{
        -1.0, -1.0, 1.0, 0.0, 0.0,
        1.0,  -1.0, 1.0, 0.0, 0.0,
        0.0,  1.0,  1.0, 0.0, 0.0,
    };
    @memcpy(ram[0x2000 .. 0x2000 + @sizeOf(@TypeOf(verts))], std.mem.sliceAsBytes(&verts));

    // Shader record at 0x3000 (16-byte aligned)
    ram[0x3003] = 3; // fs_num_varyings = 3
    std.mem.writeInt(u32, ram[0x3004..0x3008], 0x1400, .little); // FS code
    std.mem.writeInt(u32, ram[0x3008..0x300c], 0x1900, .little); // FS unifs
    ram[0x300e] = 1; // vs_attr_mask = 1
    std.mem.writeInt(u32, ram[0x3010..0x3014], 0x1000, .little); // VS code
    std.mem.writeInt(u32, ram[0x3014..0x3018], 0x1800, .little); // VS unifs
    // Attribute 0 at 0x3024: base=0x2000, size-1=19, stride=20
    std.mem.writeInt(u32, ram[0x3024..0x3028], 0x2000, .little);
    ram[0x3028] = 19;
    ram[0x3029] = 20;

    // Build BCL at 0x4000
    var bcl: usize = 0x4000;
    ram[bcl] = 6; // START_TILE_BINNING
    bcl += 1;
    ram[bcl] = 103; // VIEWPORT_OFFSET (32.0, 32.0)
    std.mem.writeInt(u16, ram[bcl + 1 ..][0..2], 32 * 16, .little);
    std.mem.writeInt(u16, ram[bcl + 3 ..][0..2], 32 * 16, .little);
    bcl += 5;
    ram[bcl] = 64; // GL_SHADER_STATE (0x3000 | 1 attr)
    std.mem.writeInt(u32, ram[bcl + 1 ..][0..4], 0x3001, .little);
    bcl += 5;
    ram[bcl] = 33; // GL_ARRAY_PRIMITIVE (triangles=4, count=3, first=0)
    ram[bcl + 1] = 4;
    std.mem.writeInt(u32, ram[bcl + 2 ..][0..4], 3, .little);
    std.mem.writeInt(u32, ram[bcl + 6 ..][0..4], 0, .little);
    bcl += 10;
    ram[bcl] = 4; // FLUSH
    bcl += 1;

    v3d.write32(0x034, V3d.INT_FLDONE | V3d.INT_FRDONE, ram); // Enable interrupts
    v3d.write32(0x110, 0x4000, ram); // CT0CA
    v3d.write32(0x108, @intCast(bcl), ram); // CT0EA -> run BCL
    try std.testing.expect((v3d.read32(0x030) & V3d.INT_FLDONE) != 0);

    // Build RCL at 0x5000 rendering to Linear RGBA8888 framebuffer at 0x10000 (64x64)
    var rcl: usize = 0x5000;
    ram[rcl] = 113; // TILE_RENDERING_MODE_CONFIG
    std.mem.writeInt(u32, ram[rcl + 1 ..][0..4], 0x10000, .little);
    std.mem.writeInt(u16, ram[rcl + 5 ..][0..2], 64, .little);
    std.mem.writeInt(u16, ram[rcl + 7 ..][0..2], 64, .little);
    std.mem.writeInt(u16, ram[rcl + 9 ..][0..2], 1 << 2, .little); // format=1 (RGBA8888), tiling=0 (Linear)
    rcl += 11;
    ram[rcl] = 114; // CLEAR_COLORS (black 0xff000000)
    std.mem.writeInt(u32, ram[rcl + 1 ..][0..4], 0xff000000, .little);
    std.mem.writeInt(u32, ram[rcl + 9 ..][0..4], 0x00ffffff, .little);
    rcl += 14;
    ram[rcl] = 115; // TILE_COORDINATES (0, 0)
    ram[rcl + 1] = 0;
    ram[rcl + 2] = 0;
    rcl += 3;
    ram[rcl] = 17; // BRANCH_TO_SUB_LIST
    std.mem.writeInt(u32, ram[rcl + 1 ..][0..4], 0, .little);
    rcl += 5;
    ram[rcl] = 25; // STORE_MS_TILE_BUFFER_AND_EOF
    rcl += 1;

    v3d.write32(0x114, 0x5000, ram); // CT1CA
    v3d.write32(0x10c, @intCast(rcl), ram); // CT1EA -> run RCL
    try std.testing.expect((v3d.read32(0x030) & V3d.INT_FRDONE) != 0);

    // Center pixel (32, 32) should be opaque red (0xffff0000)
    const center_off = 0x10000 + (32 * 64 + 32) * 4;
    try std.testing.expectEqual(@as(u32, 0xffff0000), std.mem.readInt(u32, ram[center_off..][0..4], .little));
}

test "V3D quad top-left to bottom-right diagonal shades each pixel exactly once" {
    var v3d = V3d{};
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);

    // FS reads existing tile color via tlb_read into r4, adds 0x00101010, and writes back to tlb_color_all.
    // Any double-shaded pixel on the shared diagonal will become 0xff202020, and any missed pixel will remain 0xff000000.
    var fs: qpu.Program(16) = .{};
    fs.emit(qpu.nop(.color_load));
    fs.emit(try qpu.loadImm(.{ .add_dst = qpu.wr(0), .value = 0x00101010 }));
    fs.emit(try qpu.alu(.{ .add = .{ .op = .add, .dst = qpu.tlb_color_all, .a = qpu.r(4), .b = qpu.r(0) } }));
    fs.end(.fragment);

    v3d.tile_color_solid = 0xff000000;
    const draw = V3d.DrawCall{};

    // Square quad [10, 30] x [10, 30] split along top-left (10,10) to bottom-right (30,30) diagonal:
    // Triangle 1: (10, 10) -> (30, 10) -> (30, 30)
    const tri1 = V3d.ShadedTriangle{
        .draw_idx = 0,
        .min_x = 10,
        .min_y = 10,
        .max_x = 30,
        .max_y = 30,
        .area = (30.0 - 10.0) * (30.0 - 10.0),
        .v = .{
            .{ .x = 10.0, .y = 10.0 },
            .{ .x = 30.0, .y = 10.0 },
            .{ .x = 30.0, .y = 30.0 },
        },
    };
    // Triangle 2: (10, 10) -> (30, 30) -> (10, 30)
    const tri2 = V3d.ShadedTriangle{
        .draw_idx = 0,
        .min_x = 10,
        .min_y = 10,
        .max_x = 30,
        .max_y = 30,
        .area = (30.0 - 10.0) * (30.0 - 10.0),
        .v = .{
            .{ .x = 10.0, .y = 10.0 },
            .{ .x = 30.0, .y = 30.0 },
            .{ .x = 10.0, .y = 30.0 },
        },
    };

    v3d.rasterizeShadedTriangleInTile(ram, draw, &tri1, fs.code(), &.{}, 0, 0, 0, 64);
    v3d.rasterizeShadedTriangleInTile(ram, draw, &tri2, fs.code(), &.{}, 0, 0, 0, 64);

    for (10..30) |y| {
        for (10..30) |x| {
            try std.testing.expectEqual(@as(u32, 0xff101010), v3d.tile_color[y * 64 + x]);
        }
    }
}

