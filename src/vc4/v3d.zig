const std = @import("std");
const vc_bus = @import("../soc/vc_bus.zig");
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
    pub const MAX_PREP_FS_INSTS = 8192;
    pub const MAX_PREP_FS_UNIFS = 8192;

    pub const PreparedDraw = struct {
        fs_code_phys: u32 = 0,
        fs_code_len: u16 = 0,
        fs_unif_phys: u32 = 0,
        fs_unif_len: u16 = 0,
        fs_inst_start: u16 = 0,
        fs_unif_start: u16 = 0,
        fs_cached: bool = false,
        fs_num_varyings: u8 = 0,
        fast_frag: qpu_sim.FastFragShader = .{},
        valid: bool = false,
    };

    pub const ShadedVertex = struct {
        x: f32 = 0,
        y: f32 = 0,
        z: f32 = 0.5,
        inv_w: f32 = 1.0,
        persp_varyings: [16]f32 = @splat(0),
    };

    pub const EdgeSetup = struct {
        p0x: f32 = 0,
        p0y: f32 = 0,
        dx: f32 = 0,
        dy: f32 = 0,
        sign: f32 = 1.0,
        step_x: f32 = 0,
        is_top_left: bool = false,

        pub inline fn init(ax: f32, ay: f32, bx: f32, by: f32, area_sign: f32) EdgeSetup {
            const is_tl = topLeft(ax, ay, bx, by, area_sign);
            if (ax > bx or (ax == bx and ay > by)) {
                const dy = ay - by;
                const s = -area_sign;
                return .{
                    .p0x = bx,
                    .p0y = by,
                    .dx = ax - bx,
                    .dy = dy,
                    .sign = s,
                    .step_x = -dy * s,
                    .is_top_left = is_tl,
                };
            }
            const dy = by - ay;
            return .{
                .p0x = ax,
                .p0y = ay,
                .dx = bx - ax,
                .dy = dy,
                .sign = area_sign,
                .step_x = -dy * area_sign,
                .is_top_left = is_tl,
            };
        }

        pub inline fn eval(self: EdgeSetup, row_term: f32, fx: f32) f32 {
            return (row_term - self.dy * (fx - self.p0x)) * self.sign;
        }

        pub inline fn passes(self: EdgeSetup, val: f32) bool {
            return if (self.is_top_left) (val >= 0.0) else (val > 0.0);
        }

        pub inline fn passesMask4(self: EdgeSetup, val4: @Vector(4, f32)) u4 {
            const zero4: @Vector(4, f32) = @splat(0.0);
            return @bitCast(if (self.is_top_left) (val4 >= zero4) else (val4 > zero4));
        }
    };

    pub const ShadedTriangle = struct {
        draw_idx: u16,
        min_x: u32,
        min_y: u32,
        max_x: u32,
        max_y: u32,
        area: f32,
        v: [3]ShadedVertex,
        inv_area: f32 = 0,
        edge0: EdgeSetup = .{},
        edge1: EdgeSetup = .{},
        edge2: EdgeSetup = .{},
        dz0: f32 = 0,
        dz1: f32 = 0,
        dz_dx: f32 = 0,
        dinvw0: f32 = 0,
        dinvw1: f32 = 0,
        dinvw_dx: f32 = 0,
        dvar0: [16]f32 = @splat(0),
        dvar1: [16]f32 = @splat(0),
        dvar_dx: [16]f32 = @splat(0),
        all_unit_w: bool = true,
        setup_valid: bool = false,

        pub fn init(
            draw_idx: u16,
            min_x: u32,
            min_y: u32,
            max_x: u32,
            max_y: u32,
            area: f32,
            verts: [3]ShadedVertex,
            n_var: usize,
        ) ShadedTriangle {
            const abs_area = @abs(area);
            const area_sign = std.math.sign(area);
            const inv_area = if (abs_area > 0) (1.0 / abs_area) else 0.0;
            const edge0 = EdgeSetup.init(verts[1].x, verts[1].y, verts[2].x, verts[2].y, area_sign);
            const edge1 = EdgeSetup.init(verts[2].x, verts[2].y, verts[0].x, verts[0].y, area_sign);
            const edge2 = EdgeSetup.init(verts[0].x, verts[0].y, verts[1].x, verts[1].y, area_sign);
            const dw0_dx = edge0.step_x * inv_area;
            const dw1_dx = edge1.step_x * inv_area;
            const z2 = verts[2].z;
            const invw2 = verts[2].inv_w;
            const dz0 = verts[0].z - z2;
            const dz1 = verts[1].z - z2;
            const dinvw0 = verts[0].inv_w - invw2;
            const dinvw1 = verts[1].inv_w - invw2;
            var dvar0: [16]f32 = @splat(0);
            var dvar1: [16]f32 = @splat(0);
            var dvar_dx: [16]f32 = @splat(0);
            for (0..n_var) |vi| {
                const v2 = verts[2].persp_varyings[vi];
                const dv0 = verts[0].persp_varyings[vi] - v2;
                const dv1 = verts[1].persp_varyings[vi] - v2;
                dvar0[vi] = dv0;
                dvar1[vi] = dv1;
                dvar_dx[vi] = dw0_dx * dv0 + dw1_dx * dv1;
            }
            return .{
                .draw_idx = draw_idx,
                .min_x = min_x,
                .min_y = min_y,
                .max_x = max_x,
                .max_y = max_y,
                .area = area,
                .v = verts,
                .inv_area = inv_area,
                .edge0 = edge0,
                .edge1 = edge1,
                .edge2 = edge2,
                .dz0 = dz0,
                .dz1 = dz1,
                .dz_dx = dw0_dx * dz0 + dw1_dx * dz1,
                .dinvw0 = dinvw0,
                .dinvw1 = dinvw1,
                .dinvw_dx = dw0_dx * dinvw0 + dw1_dx * dinvw1,
                .dvar0 = dvar0,
                .dvar1 = dvar1,
                .dvar_dx = dvar_dx,
                .all_unit_w = (verts[0].inv_w == 1.0 and verts[1].inv_w == 1.0 and verts[2].inv_w == 1.0),
                .setup_valid = true,
            };
        }
    };

    pub const LazyTileLoad = struct {
        addr: u32,
        fb_w: u32,
        fb_h: u32,
        tile_x: u32,
        tile_y: u32,
        tile_size: u32,
        tiling: u2,
        format: u2,
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
    tile_color: [64 * 64]u32 = @splat(0),
    tile_depth: [64 * 64]f32 = @splat(1.0),
    tile_color_solid: ?u32 = null,
    tile_depth_valid: bool = false,
    tile_clear_zs: f32 = 1.0,
    lazy_load: ?LazyTileLoad = null,
    loaded_from: ?LazyTileLoad = null,
    tile_modified: bool = false,

    // Pre-shaded & pre-binned state for the current RCL frame
    prep_draws: [256]PreparedDraw = undefined,
    prep_fs_insts: [MAX_PREP_FS_INSTS]qpu_sim.DecodedInst = undefined,
    prep_fs_insts_len: usize = 0,
    prep_fs_unifs: [MAX_PREP_FS_UNIFS]u32 = undefined,
    prep_fs_unifs_len: usize = 0,
    shaded_tris: [MAX_PREBINNED_TRIS]ShadedTriangle = undefined,
    shaded_tris_len: usize = 0,
    overflow_draw_start: usize = 0,
    tile_nonempty: [32]u32 = @splat(0),
    tile_tri_mask: [32 * 32][MAX_PREBINNED_TRIS / 64]u64 = undefined,

    gl: GlRenderer = .{},
    gl_initialized: bool = false,
    frame_dirty: bool = false,

    pub fn resetInPlace(self: *V3d) void {
        self.scratch = 0;
        self.l2cactl = 0;
        self.slcactl = 0;
        self.intctl = 0;
        self.int_mask = 0;
        self.ct0cs = 0;
        self.ct1cs = 0;
        self.ct0ea = 0;
        self.ct1ea = 0;
        self.ct0ca = 0;
        self.ct1ca = 0;
        self.bfc = 0;
        self.rfc = 0;
        self.bpca = 0;
        self.bpcs = 0x00100000;
        self.bpoa = 0;
        self.bpos = 0;
        self.bxcf = 0;
        self.sqrsv0 = 0;
        self.sqrsv1 = 0;
        self.sqcntl = 0;
        self.srqpc = 0;
        self.srqua = 0;
        self.srqul = 0;
        self.srqcs = 0;
        self.vpmbase = 0;
        self.draws_len = 0;
        self.cur_shader_rec = 0;
        self.cur_num_attrs = 0;
        self.cur_vp_x = 0;
        self.cur_vp_y = 0;
        self.cur_clip_x = 0;
        self.cur_clip_y = 0;
        self.cur_clip_w = 4096;
        self.cur_clip_h = 4096;
        self.cur_cfg0 = 0x03;
        self.cur_cfg1 = 0x70;
        self.cur_cfg2 = 0x00;
        self.multisample_bin = false;
        @memset(&self.tile_color, 0);
        @memset(&self.tile_depth, 1.0);
        self.tile_color_solid = null;
        self.tile_depth_valid = false;
        self.tile_clear_zs = 1.0;
        self.lazy_load = null;
        self.loaded_from = null;
        self.tile_modified = false;
        self.prep_fs_insts_len = 0;
        self.prep_fs_unifs_len = 0;
        self.shaded_tris_len = 0;
        self.overflow_draw_start = 0;
        self.tile_nonempty = @splat(0);
        self.gl = .{};
        self.gl_initialized = false;
        self.frame_dirty = false;
    }

    pub fn takeFrameDirty(self: *V3d) bool {
        const d = self.frame_dirty;
        self.frame_dirty = false;
        return d;
    }

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
                    self.frame_dirty = true;
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
        var pc = start_bus & vc_bus.ramMask(ram.len);
        const end = end_bus & vc_bus.ramMask(ram.len);
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
        const rec_phys = shader_rec_bus & vc_bus.ramMask(ram.len);
        if (rec_phys + 36 > ram.len) return;
        const fs_code_phys = std.mem.readInt(u32, ram[rec_phys + 4 ..][0..4], .little) & vc_bus.ramMask(ram.len);
        const vs_code_phys = std.mem.readInt(u32, ram[rec_phys + 16 ..][0..4], .little) & vc_bus.ramMask(ram.len);
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
        const max_words: usize = @min(max_bytes / 4, out_buf.len);
        @memcpy(std.mem.sliceAsBytes(out_buf[0..max_words]), ram[phys..][0 .. max_words * 4]);
        return out_buf[0..max_words];
    }

    /// Pre-shades and bins triangles across all draw calls once per frame before tile loop.
    fn prepareDrawsForFrame(self: *V3d, ram: []const u8) void {
        self.shaded_tris_len = 0;
        self.prep_fs_insts_len = 0;
        self.prep_fs_unifs_len = 0;
        self.overflow_draw_start = self.draws_len;
        self.tile_nonempty = @splat(0);

        var vs_buf: [512]qpu.Inst = undefined;
        var fs_buf: [512]qpu.Inst = undefined;
        var vs_decoded_buf: [512]qpu_sim.DecodedInst = undefined;
        var vs_unif_buf: [128]u32 = undefined;

        for (self.draws[0..self.draws_len], 0..) |draw, draw_idx| {
            self.prep_draws[draw_idx] = .{};
            if (draw.count < 3) continue;
            const rec_phys = draw.shader_rec_addr & vc_bus.ramMask(ram.len);
            if (rec_phys + 36 + @as(u32, draw.num_attrs) * 8 > ram.len) continue;

            const fs_num_varyings = ram[rec_phys + 3];
            const fs_code_phys = std.mem.readInt(u32, ram[rec_phys + 4 ..][0..4], .little) & vc_bus.ramMask(ram.len);
            const fs_unif_phys = std.mem.readInt(u32, ram[rec_phys + 8 ..][0..4], .little) & vc_bus.ramMask(ram.len);
            const vs_attr_mask = ram[rec_phys + 14];
            const vs_code_phys = std.mem.readInt(u32, ram[rec_phys + 16 ..][0..4], .little) & vc_bus.ramMask(ram.len);
            const vs_unif_phys = std.mem.readInt(u32, ram[rec_phys + 20 ..][0..4], .little) & vc_bus.ramMask(ram.len);

            const vs_code = extractQpuProgram(ram, vs_code_phys, &vs_buf);
            const fs_code = extractQpuProgram(ram, fs_code_phys, &fs_buf);
            if (vs_code.len == 0 or fs_code.len == 0) continue;

            const vs_decoded = qpu_sim.decodeProgram(vs_code, &vs_decoded_buf);
            const vs_unifs = extractUniforms(ram, vs_unif_phys, &vs_unif_buf);
            const max_unif_words: u16 = if (fs_unif_phys < ram.len) @intCast(@min((ram.len - fs_unif_phys) / 4, 128)) else 0;

            var fs_inst_start: u16 = 0;
            var fs_unif_start: u16 = 0;
            var fs_cached = false;
            var fast_frag: qpu_sim.FastFragShader = .{};
            if (self.prep_fs_insts_len + fs_code.len <= MAX_PREP_FS_INSTS and
                self.prep_fs_unifs_len + max_unif_words <= MAX_PREP_FS_UNIFS)
            {
                fs_inst_start = @intCast(self.prep_fs_insts_len);
                const fs_dec = qpu_sim.decodeProgram(fs_code, self.prep_fs_insts[self.prep_fs_insts_len..][0..fs_code.len]);
                self.prep_fs_insts_len += fs_code.len;

                fs_unif_start = @intCast(self.prep_fs_unifs_len);
                const unif_words: usize = max_unif_words;
                const fs_u = self.prep_fs_unifs[self.prep_fs_unifs_len..][0..unif_words];
                @memcpy(
                    std.mem.sliceAsBytes(fs_u),
                    ram[fs_unif_phys..][0 .. unif_words * 4],
                );
                self.prep_fs_unifs_len += unif_words;
                fs_cached = true;
                fast_frag = qpu_sim.analyzeFragmentShader(fs_dec, fs_u);
            }

            self.prep_draws[draw_idx] = .{
                .fs_code_phys = fs_code_phys,
                .fs_code_len = @intCast(fs_code.len),
                .fs_unif_phys = fs_unif_phys,
                .fs_unif_len = max_unif_words,
                .fs_inst_start = fs_inst_start,
                .fs_unif_start = fs_unif_start,
                .fs_cached = fs_cached,
                .fs_num_varyings = fs_num_varyings,
                .fast_frag = fast_frag,
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

            var attr_streams: [8]AttrStream = undefined;
            const attr_info = decodeAttrStreams(ram, rec_phys, draw.num_attrs, vs_attr_mask, &attr_streams);
            const active_attrs = attr_streams[0..attr_info.count];
            const vpm_words = attr_info.vpm_words;
            const n_var = @min(@as(usize, fs_num_varyings), 16);
            const clip_min_x: f32 = @floatFromInt(draw.clip_x);
            const clip_min_y: f32 = @floatFromInt(draw.clip_y);
            const clip_max_x: f32 = @floatFromInt(@as(u32, draw.clip_x) + draw.clip_w);
            const clip_max_y: f32 = @floatFromInt(@as(u32, draw.clip_y) + draw.clip_h);

            var tri_idx: u32 = 0;
            while (tri_idx < num_tris) {
                const batch_tris: usize = @min(@as(usize, num_tris - tri_idx), 5);
                const batch_verts: usize = batch_tris * 3;
                var v_indices: [15]u32 = undefined;

                if (draw.mode == 4) {
                    const base_v = tri_idx * 3;
                    if (draw.indexed) {
                        const idx_base: usize = draw.index_buffer_addr & vc_bus.ramMask(ram.len);
                        if (draw.u16_indices) {
                            const start_off = idx_base + @as(usize, base_v) * 2;
                            if (start_off + batch_verts * 2 <= ram.len) {
                                for (0..batch_verts) |k| {
                                    v_indices[k] = std.mem.readInt(u16, ram[start_off + k * 2 ..][0..2], .little);
                                }
                            } else {
                                for (0..batch_verts) |k| {
                                    const off = start_off + k * 2;
                                    v_indices[k] = if (off + 2 <= ram.len) std.mem.readInt(u16, ram[off..][0..2], .little) else 0;
                                }
                            }
                        } else {
                            const start_off = idx_base + @as(usize, base_v);
                            if (start_off + batch_verts <= ram.len) {
                                for (0..batch_verts) |k| {
                                    v_indices[k] = ram[start_off + k];
                                }
                            } else {
                                for (0..batch_verts) |k| {
                                    const off = start_off + k;
                                    v_indices[k] = if (off < ram.len) ram[off] else 0;
                                }
                            }
                        }
                    } else {
                        const start_v = base_v + draw.first_or_offset;
                        for (0..batch_verts) |k| {
                            v_indices[k] = start_v + @as(u32, @intCast(k));
                        }
                    }
                    tri_idx += @intCast(batch_tris);
                } else {
                    for (0..batch_tris) |t_i| {
                        const cur_tri = tri_idx + @as(u32, @intCast(t_i));
                        const base_l = t_i * 3;
                        switch (draw.mode) {
                            5 => {
                                if ((cur_tri & 1) == 0) {
                                    v_indices[base_l + 0] = cur_tri + 0;
                                    v_indices[base_l + 1] = cur_tri + 1;
                                    v_indices[base_l + 2] = cur_tri + 2;
                                } else {
                                    v_indices[base_l + 0] = cur_tri + 1;
                                    v_indices[base_l + 1] = cur_tri + 0;
                                    v_indices[base_l + 2] = cur_tri + 2;
                                }
                            },
                            6 => {
                                v_indices[base_l + 0] = 0;
                                v_indices[base_l + 1] = cur_tri + 1;
                                v_indices[base_l + 2] = cur_tri + 2;
                            },
                            else => {
                                v_indices[base_l + 0] = 0;
                                v_indices[base_l + 1] = 0;
                                v_indices[base_l + 2] = 0;
                            },
                        }
                    }
                    tri_idx += @intCast(batch_tris);

                    if (draw.indexed) {
                        const idx_base = draw.index_buffer_addr & vc_bus.ramMask(ram.len);
                        if (draw.u16_indices) {
                            for (v_indices[0..batch_verts]) |*vi| {
                                const off = idx_base + vi.* * 2;
                                vi.* = if (off + 2 <= ram.len) std.mem.readInt(u16, ram[off..][0..2], .little) else 0;
                            }
                        } else {
                            for (v_indices[0..batch_verts]) |*vi| {
                                const off = idx_base + vi.*;
                                vi.* = if (off < ram.len) ram[off] else 0;
                            }
                        }
                    } else if (draw.first_or_offset != 0) {
                        for (v_indices[0..batch_verts]) |*vi| {
                            vi.* += draw.first_or_offset;
                        }
                    }
                }

                var vpm_in: [32]qpu_sim.Vec = undefined;
                populateBatchVpmIn(ram, active_attrs, v_indices[0..batch_verts], &vpm_in);

                const vs_res = qpu_sim.runDecoded(vs_decoded, .{
                    .uniforms = vs_unifs,
                    .vpm_in = vpm_in[0..vpm_words],
                }) catch continue;
                if (vs_res.vpm_out_len < 3) continue;
                const valid_vars = @min(n_var, vs_res.vpm_out_len - 3);

                for (0..batch_tris) |t_i| {
                    const base_l = t_i * 3;
                    var verts: [3]ShadedVertex = .{ .{}, .{}, .{} };
                    inline for (0..3) |corner| {
                        const lane = base_l + corner;
                        const xy_packed = vs_res.vpm_out[0][lane];
                        const xs: i16 = @bitCast(@as(u16, @truncate(xy_packed)));
                        const ys: i16 = @bitCast(@as(u16, @truncate(xy_packed >> 16)));
                        verts[corner].x = @as(f32, @floatFromInt(xs)) * (1.0 / 16.0) + draw.vp_x;
                        verts[corner].y = @as(f32, @floatFromInt(ys)) * (1.0 / 16.0) + draw.vp_y;
                        verts[corner].z = @bitCast(vs_res.vpm_out[1][lane]);
                        const raw_inv_w: f32 = @bitCast(vs_res.vpm_out[2][lane]);
                        const inv_w = if (raw_inv_w == 0.0) 1.0 else raw_inv_w;
                        verts[corner].inv_w = inv_w;
                        for (0..valid_vars) |vi| {
                            const raw_v: f32 = @bitCast(vs_res.vpm_out[3 + vi][lane]);
                            verts[corner].persp_varyings[vi] = raw_v * inv_w;
                        }
                    }

                    const area = (verts[1].x - verts[0].x) * (verts[2].y - verts[0].y) -
                        (verts[1].y - verts[0].y) * (verts[2].x - verts[0].x);
                    if (@abs(area) < 1e-6) continue;

                    const min_fx = @max(@floor(@min(verts[0].x, @min(verts[1].x, verts[2].x))), clip_min_x);
                    const min_fy = @max(@floor(@min(verts[0].y, @min(verts[1].y, verts[2].y))), clip_min_y);
                    const max_fx = @min(@ceil(@max(verts[0].x, @max(verts[1].x, verts[2].x))), clip_max_x);
                    const max_fy = @min(@ceil(@max(verts[0].y, @max(verts[1].y, verts[2].y))), clip_max_y);
                    if (min_fx >= max_fx or min_fy >= max_fy) continue;

                    const tri_slot = self.shaded_tris_len;
                    const min_ux: u32 = @intFromFloat(min_fx);
                    const min_uy: u32 = @intFromFloat(min_fy);
                    const max_ux: u32 = @intFromFloat(max_fx);
                    const max_uy: u32 = @intFromFloat(max_fy);
                    self.shaded_tris[tri_slot] = ShadedTriangle.init(
                        @intCast(draw_idx),
                        min_ux,
                        min_uy,
                        max_ux,
                        max_uy,
                        area,
                        verts,
                        n_var,
                    );
                    self.shaded_tris_len = tri_slot + 1;

                    // Spatially bin this triangle into overlapping 64x64 tiles
                    const tx0: u32 = @min(min_ux >> 6, 31);
                    const ty0: u32 = @min(min_uy >> 6, 31);
                    const tx1: u32 = @min((max_ux - 1) >> 6, 31);
                    const ty1: u32 = @min((max_uy - 1) >> 6, 31);
                    const word_idx = tri_slot >> 6;
                    const bit_mask = @as(u64, 1) << @intCast(tri_slot & 63);
                    if (tx0 == tx1 and ty0 == ty1) {
                        const tx_bit = @as(u32, 1) << @intCast(tx0);
                        const t_idx = (ty0 << 5) + tx0;
                        if ((self.tile_nonempty[ty0] & tx_bit) == 0) {
                            @memset(&self.tile_tri_mask[t_idx], 0);
                            self.tile_nonempty[ty0] |= tx_bit;
                        }
                        self.tile_tri_mask[t_idx][word_idx] |= bit_mask;
                    } else {
                        var ty: u32 = ty0;
                        while (ty <= ty1) : (ty += 1) {
                            const row_base = ty << 5;
                            var row_nonempty = self.tile_nonempty[ty];
                            var tx: u32 = tx0;
                            while (tx <= tx1) : (tx += 1) {
                                const tx_bit = @as(u32, 1) << @intCast(tx);
                                const t_idx = row_base + tx;
                                if ((row_nonempty & tx_bit) == 0) {
                                    @memset(&self.tile_tri_mask[t_idx], 0);
                                    row_nonempty |= tx_bit;
                                }
                                self.tile_tri_mask[t_idx][word_idx] |= bit_mask;
                            }
                            self.tile_nonempty[ty] = row_nonempty;
                        }
                    }
                }
            }
        }
    }

    const AttrStream = struct {
        base: u32,
        stride: u32,
        words: u32,
    };

    fn decodeAttrStreams(
        ram: []const u8,
        rec_phys: u32,
        num_attrs: u8,
        vs_attr_mask: u8,
        out: *[8]AttrStream,
    ) struct { count: usize, vpm_words: usize } {
        var count: usize = 0;
        var vpm_words: usize = 0;
        for (0..num_attrs) |ai| {
            if (vs_attr_mask != 0 and (vs_attr_mask & (@as(u8, 1) << @intCast(ai))) == 0) continue;
            const a_off = rec_phys + 36 + ai * 8;
            const attr_base = std.mem.readInt(u32, ram[a_off..][0..4], .little) & vc_bus.ramMask(ram.len);
            const attr_bytes: u32 = @as(u32, ram[a_off + 4]) + 1;
            const attr_stride: u32 = ram[a_off + 5];
            const words = (attr_bytes + 3) / 4;
            if (count < out.len) {
                out[count] = .{
                    .base = attr_base,
                    .stride = attr_stride,
                    .words = words,
                };
                count += 1;
                vpm_words = @min(vpm_words + words, 32);
            }
        }
        return .{ .count = count, .vpm_words = vpm_words };
    }

    pub inline fn populateBatchVpmIn(
        ram: []const u8,
        attrs: []const AttrStream,
        v_indices: []const u32,
        vpm_in: *[32]qpu_sim.Vec,
    ) void {
        var vpm_word: usize = 0;
        const batch_verts = v_indices.len;
        for (attrs) |attr| {
            const words: usize = attr.words;
            if (words == 0 or vpm_word >= 32) break;
            if (vpm_word + words <= 32 and words <= 4) {
                switch (words) {
                    1 => {
                        var v0: qpu_sim.Vec = undefined;
                        for (v_indices, 0..) |vi, lane| {
                            const v_addr: usize = @as(usize, attr.base) + @as(usize, vi) * @as(usize, attr.stride);
                            v0[lane] = if (v_addr + 4 <= ram.len) std.mem.readInt(u32, ram[v_addr..][0..4], .little) else 0;
                        }
                        const pad0 = if (batch_verts > 0) v0[batch_verts - 1] else 0;
                        for (batch_verts..16) |lane| v0[lane] = pad0;
                        vpm_in[vpm_word] = v0;
                    },
                    2 => {
                        var v0: qpu_sim.Vec = undefined;
                        var v1: qpu_sim.Vec = undefined;
                        for (v_indices, 0..) |vi, lane| {
                            const v_addr: usize = @as(usize, attr.base) + @as(usize, vi) * @as(usize, attr.stride);
                            if (v_addr + 8 <= ram.len) {
                                const w2: [2]u32 = @bitCast(ram[v_addr..][0..8].*);
                                v0[lane] = w2[0];
                                v1[lane] = w2[1];
                            } else {
                                v0[lane] = if (v_addr + 4 <= ram.len) std.mem.readInt(u32, ram[v_addr..][0..4], .little) else 0;
                                v1[lane] = 0;
                            }
                        }
                        const pad0 = if (batch_verts > 0) v0[batch_verts - 1] else 0;
                        const pad1 = if (batch_verts > 0) v1[batch_verts - 1] else 0;
                        for (batch_verts..16) |lane| {
                            v0[lane] = pad0;
                            v1[lane] = pad1;
                        }
                        vpm_in[vpm_word + 0] = v0;
                        vpm_in[vpm_word + 1] = v1;
                    },
                    3 => {
                        var v0: qpu_sim.Vec = undefined;
                        var v1: qpu_sim.Vec = undefined;
                        var v2: qpu_sim.Vec = undefined;
                        for (v_indices, 0..) |vi, lane| {
                            const v_addr: usize = @as(usize, attr.base) + @as(usize, vi) * @as(usize, attr.stride);
                            if (v_addr + 12 <= ram.len) {
                                const w3: [3]u32 = @bitCast(ram[v_addr..][0..12].*);
                                v0[lane] = w3[0];
                                v1[lane] = w3[1];
                                v2[lane] = w3[2];
                            } else {
                                v0[lane] = if (v_addr + 4 <= ram.len) std.mem.readInt(u32, ram[v_addr..][0..4], .little) else 0;
                                v1[lane] = if (v_addr + 8 <= ram.len) std.mem.readInt(u32, ram[v_addr + 4 ..][0..4], .little) else 0;
                                v2[lane] = 0;
                            }
                        }
                        const pad0 = if (batch_verts > 0) v0[batch_verts - 1] else 0;
                        const pad1 = if (batch_verts > 0) v1[batch_verts - 1] else 0;
                        const pad2 = if (batch_verts > 0) v2[batch_verts - 1] else 0;
                        for (batch_verts..16) |lane| {
                            v0[lane] = pad0;
                            v1[lane] = pad1;
                            v2[lane] = pad2;
                        }
                        vpm_in[vpm_word + 0] = v0;
                        vpm_in[vpm_word + 1] = v1;
                        vpm_in[vpm_word + 2] = v2;
                    },
                    4 => {
                        var v0: qpu_sim.Vec = undefined;
                        var v1: qpu_sim.Vec = undefined;
                        var v2: qpu_sim.Vec = undefined;
                        var v3: qpu_sim.Vec = undefined;
                        for (v_indices, 0..) |vi, lane| {
                            const v_addr: usize = @as(usize, attr.base) + @as(usize, vi) * @as(usize, attr.stride);
                            if (v_addr + 16 <= ram.len) {
                                const w4: [4]u32 = @bitCast(ram[v_addr..][0..16].*);
                                v0[lane] = w4[0];
                                v1[lane] = w4[1];
                                v2[lane] = w4[2];
                                v3[lane] = w4[3];
                            } else {
                                v0[lane] = if (v_addr + 4 <= ram.len) std.mem.readInt(u32, ram[v_addr..][0..4], .little) else 0;
                                v1[lane] = if (v_addr + 8 <= ram.len) std.mem.readInt(u32, ram[v_addr + 4 ..][0..4], .little) else 0;
                                v2[lane] = if (v_addr + 12 <= ram.len) std.mem.readInt(u32, ram[v_addr + 8 ..][0..4], .little) else 0;
                                v3[lane] = 0;
                            }
                        }
                        const pad0 = if (batch_verts > 0) v0[batch_verts - 1] else 0;
                        const pad1 = if (batch_verts > 0) v1[batch_verts - 1] else 0;
                        const pad2 = if (batch_verts > 0) v2[batch_verts - 1] else 0;
                        const pad3 = if (batch_verts > 0) v3[batch_verts - 1] else 0;
                        for (batch_verts..16) |lane| {
                            v0[lane] = pad0;
                            v1[lane] = pad1;
                            v2[lane] = pad2;
                            v3[lane] = pad3;
                        }
                        vpm_in[vpm_word + 0] = v0;
                        vpm_in[vpm_word + 1] = v1;
                        vpm_in[vpm_word + 2] = v2;
                        vpm_in[vpm_word + 3] = v3;
                    },
                    else => unreachable,
                }
                vpm_word += words;
                continue;
            }
            for (0..words) |w_i| {
                if (vpm_word >= 32) return;
                const word_off: u32 = @intCast(w_i * 4);
                var vec: qpu_sim.Vec = undefined;
                for (v_indices, 0..) |vi, lane| {
                    const v_addr = attr.base + vi * attr.stride + word_off;
                    vec[lane] = if (v_addr + 4 <= ram.len) std.mem.readInt(u32, ram[v_addr..][0..4], .little) else 0;
                }
                const pad_val = if (batch_verts > 0) vec[batch_verts - 1] else 0;
                for (batch_verts..16) |lane| {
                    vec[lane] = pad_val;
                }
                vpm_in[vpm_word] = vec;
                vpm_word += 1;
            }
        }
    }

    pub const TileBuffer = struct {
        color: *[64 * 64]u32,
        depth: *[64 * 64]f32,
        color_solid: ?u32 = null,
        depth_valid: bool = false,
        clear_zs: f32 = 1.0,
        lazy_load: ?LazyTileLoad = null,
        loaded_from: ?LazyTileLoad = null,
        modified: bool = false,
    };

    pub const TileJob = struct {
        tile_x: u32,
        tile_y: u32,
        clear_color0: u32,
        clear_zs: f32,
        lazy_load: ?LazyTileLoad = null,
        has_render: bool = false,
        dst_addr: u32 = 0,
        fb_w: u32 = 0,
        fb_h: u32 = 0,
        tiling: u2 = 0,
        ls_format: u2 = 0,
    };

    const WorkerCtx = struct {
        v3d: *const V3d,
        ram: []u8,
        jobs: []const TileJob,
        next_idx: *std.atomic.Value(usize),

        fn run(ctx: *const WorkerCtx) void {
            var color_buf: [64 * 64]u32 = undefined;
            var depth_buf: [64 * 64]f32 = undefined;
            var tb = TileBuffer{
                .color = &color_buf,
                .depth = &depth_buf,
            };
            while (true) {
                const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                if (idx >= ctx.jobs.len) break;
                ctx.v3d.executeTileJob(&tb, ctx.ram, ctx.jobs[idx]);
            }
        }
    };

    const PendingTileLoad = struct {
        addr: u32,
        tiling: u2,
        format: u2,
    };

    inline fn tileBuf(self: *V3d) TileBuffer {
        return .{
            .color = &self.tile_color,
            .depth = &self.tile_depth,
            .color_solid = self.tile_color_solid,
            .depth_valid = self.tile_depth_valid,
            .clear_zs = self.tile_clear_zs,
            .lazy_load = self.lazy_load,
            .loaded_from = self.loaded_from,
            .modified = self.tile_modified,
        };
    }

    inline fn syncFromTileBuf(self: *V3d, tb: *const TileBuffer) void {
        self.tile_color_solid = tb.color_solid;
        self.tile_depth_valid = tb.depth_valid;
        self.tile_clear_zs = tb.clear_zs;
        self.lazy_load = tb.lazy_load;
        self.loaded_from = tb.loaded_from;
        self.tile_modified = tb.modified;
    }

    inline fn canSkipUnmodifiedStoreBuf(
        tb: *const TileBuffer,
        dst_addr: u32,
        fb_w: u32,
        fb_h: u32,
        tile_x: u32,
        tile_y: u32,
        tile_size: u32,
        tiling: u2,
        format: u2,
    ) bool {
        if (tb.modified) return false;
        const lf = tb.loaded_from orelse return false;
        const dst_is_565 = (format == 1 or format == 2);
        const src_is_565 = (lf.format == 1 or lf.format == 2);
        return (lf.addr & 0x3FFFFFFF) == (dst_addr & 0x3FFFFFFF) and
            lf.fb_w == fb_w and
            lf.fb_h == fb_h and
            lf.tile_x == tile_x and
            lf.tile_y == tile_y and
            lf.tile_size == tile_size and
            lf.tiling == tiling and
            dst_is_565 == src_is_565;
    }

    fn executeTileJob(self: *const V3d, tb: *TileBuffer, ram: []u8, job: TileJob) void {
        const tile_size: u32 = 64;
        if (job.lazy_load) |ll| {
            tb.lazy_load = ll;
            tb.loaded_from = ll;
            tb.color_solid = null;
        } else {
            tb.lazy_load = null;
            tb.loaded_from = null;
            tb.color_solid = job.clear_color0;
        }
        tb.depth_valid = false;
        tb.clear_zs = job.clear_zs;
        tb.modified = false;

        if (job.has_render) {
            self.renderDrawsIntoTileBuf(tb, ram, job.tile_x * tile_size, job.tile_y * tile_size, tile_size);
        }

        if (!canSkipUnmodifiedStoreBuf(tb, job.dst_addr, job.fb_w, job.fb_h, job.tile_x, job.tile_y, tile_size, job.tiling, job.ls_format)) {
            if (tb.lazy_load) |ll| {
                tb.lazy_load = null;
                loadTileIntoBuf(tb, ram, ll.addr, ll.fb_w, ll.fb_h, ll.tile_x, ll.tile_y, ll.tile_size, ll.tiling, ll.format);
                tb.color_solid = null;
            }
            storeTileFromBuf(tb, ram, job.dst_addr, job.fb_w, job.fb_h, job.tile_x, job.tile_y, tile_size, job.tiling, job.ls_format);
        }
    }

    fn flushTileJobs(self: *V3d, ram: []u8, jobs: []const TileJob) void {
        if (jobs.len == 0) return;
        if (jobs.len < 4) {
            var tb = self.tileBuf();
            defer self.syncFromTileBuf(&tb);
            for (jobs) |job| {
                self.executeTileJob(&tb, ram, job);
            }
            return;
        }

        var next_idx = std.atomic.Value(usize).init(0);
        const ctx = WorkerCtx{
            .v3d = self,
            .ram = ram,
            .jobs = jobs,
            .next_idx = &next_idx,
        };

        const max_helper_threads = 3;
        const desired_helpers = @min(max_helper_threads, (jobs.len / 2) - 1);
        var threads: [max_helper_threads]std.Thread = undefined;
        var spawned: usize = 0;
        for (0..desired_helpers) |_| {
            threads[spawned] = std.Thread.spawn(.{}, WorkerCtx.run, .{&ctx}) catch break;
            spawned += 1;
        }

        {
            var tb = self.tileBuf();
            defer self.syncFromTileBuf(&tb);
            while (true) {
                const idx = next_idx.fetchAdd(1, .monotonic);
                if (idx >= jobs.len) break;
                self.executeTileJob(&tb, ram, jobs[idx]);
            }
        }

        for (threads[0..spawned]) |t| {
            t.join();
        }
    }

    fn executeRcl(self: *V3d, ram: []u8, start_bus: u32, end_bus: u32) void {
        var pc = start_bus & vc_bus.ramMask(ram.len);
        const end = end_bus & vc_bus.ramMask(ram.len);
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
        var cur_lazy_load: ?LazyTileLoad = null;
        var cur_has_render: bool = false;
        var tile_loaded: bool = false;

        var tile_jobs: [1024]TileJob = undefined;
        var tile_jobs_len: usize = 0;
        var queued_tile_mask: [32]u32 = @splat(0);

        const queueOrRunJob = struct {
            fn f(
                v3d_self: *V3d,
                mem: []u8,
                jobs: *[1024]TileJob,
                jobs_len: *usize,
                q_mask: *[32]u32,
                job: TileJob,
            ) void {
                if (job.tile_x < 32 and job.tile_y < 32) {
                    const bit = @as(u32, 1) << @intCast(job.tile_x);
                    if ((q_mask[job.tile_y] & bit) != 0 or jobs_len.* >= jobs.len) {
                        v3d_self.flushTileJobs(mem, jobs[0..jobs_len.*]);
                        jobs_len.* = 0;
                        q_mask.* = @splat(0);
                    }
                    q_mask[job.tile_y] |= bit;
                    jobs[jobs_len.*] = job;
                    jobs_len.* += 1;
                } else {
                    v3d_self.flushTileJobs(mem, jobs[0..jobs_len.*]);
                    jobs_len.* = 0;
                    q_mask.* = @splat(0);
                    const single = [1]TileJob{job};
                    v3d_self.flushTileJobs(mem, &single);
                }
            }
        }.f;

        while (pc < end) {
            const op = ram[pc];
            switch (op) {
                0 => break, // HALT
                1, 4, 5, 8, 18 => pc += 1,
                16 => { // BRANCH
                    if (pc + 5 > end) break;
                    pc = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little) & vc_bus.ramMask(ram.len);
                },
                17 => { // BRANCH_TO_SUB_LIST (executes binned primitives for the current tile)
                    if (pc + 5 > end) break;
                    if (!tile_loaded) {
                        cur_lazy_load = null;
                        tile_loaded = true;
                    }
                    cur_has_render = true;
                    pc += 5;
                },
                24, 25 => { // STORE_MS_TILE_BUFFER / STORE_MS_TILE_BUFFER_AND_EOF (1 byte)
                    if (!tile_loaded) {
                        cur_lazy_load = null;
                        tile_loaded = true;
                    }
                    const r_format: u2 = @truncate((fb_flags >> 2) & 3);
                    const r_tiling: u2 = @truncate((fb_flags >> 6) & 3);
                    const ls_format: u2 = if (r_format == 1) 0 else 2;
                    queueOrRunJob(self, ram, &tile_jobs, &tile_jobs_len, &queued_tile_mask, .{
                        .tile_x = cur_tile_x,
                        .tile_y = cur_tile_y,
                        .clear_color0 = clear_color0,
                        .clear_zs = clear_zs,
                        .lazy_load = cur_lazy_load,
                        .has_render = cur_has_render,
                        .dst_addr = fb_addr,
                        .fb_w = fb_width,
                        .fb_h = fb_height,
                        .tiling = r_tiling,
                        .ls_format = ls_format,
                    });
                    tile_loaded = false;
                    has_tile_coords = false;
                    pending_load = null;
                    cur_lazy_load = null;
                    cur_has_render = false;
                    pc += 1;
                },
                28 => { // STORE_TILE_BUFFER_GENERAL (7 bytes)
                    if (pc + 7 > end) break;
                    const bits = std.mem.readInt(u16, ram[pc + 1 ..][0..2], .little);
                    const addr_word = std.mem.readInt(u32, ram[pc + 3 ..][0..4], .little);
                    const buf_kind = bits & 7;
                    if (buf_kind == 1) { // Color buffer store
                        if (!tile_loaded) {
                            cur_lazy_load = null;
                            tile_loaded = true;
                        }
                        const ls_tiling: u2 = @truncate((bits >> 4) & 3);
                        const ls_format: u2 = @truncate((bits >> 8) & 3);
                        const dst_addr = if ((addr_word & ~@as(u32, 0xf)) != 0) (addr_word & ~@as(u32, 0xf)) else fb_addr;
                        queueOrRunJob(self, ram, &tile_jobs, &tile_jobs_len, &queued_tile_mask, .{
                            .tile_x = cur_tile_x,
                            .tile_y = cur_tile_y,
                            .clear_color0 = clear_color0,
                            .clear_zs = clear_zs,
                            .lazy_load = cur_lazy_load,
                            .has_render = cur_has_render,
                            .dst_addr = dst_addr,
                            .fb_w = fb_width,
                            .fb_h = fb_height,
                            .tiling = ls_tiling,
                            .ls_format = ls_format,
                        });
                    }
                    if ((bits & (1 << 15)) == 0) {
                        // Last store for tile
                        tile_loaded = false;
                        has_tile_coords = false;
                        pending_load = null;
                        cur_lazy_load = null;
                        cur_has_render = false;
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
                            cur_lazy_load = .{
                                .addr = load_addr,
                                .fb_w = fb_width,
                                .fb_h = fb_height,
                                .tile_x = cur_tile_x,
                                .tile_y = cur_tile_y,
                                .tile_size = 64,
                                .tiling = ls_tiling,
                                .format = ls_format,
                            };
                            cur_has_render = false;
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
                    cur_has_render = false;
                    if (pending_load) |pl| {
                        cur_lazy_load = .{
                            .addr = pl.addr,
                            .fb_w = fb_width,
                            .fb_h = fb_height,
                            .tile_x = cur_tile_x,
                            .tile_y = cur_tile_y,
                            .tile_size = 64,
                            .tiling = pl.tiling,
                            .format = pl.format,
                        };
                        tile_loaded = true;
                        pending_load = null;
                    } else if (!tile_loaded) {
                        cur_lazy_load = null;
                        tile_loaded = true;
                    }
                    pc += 3;
                },
                else => break,
            }
        }

        self.flushTileJobs(ram, tile_jobs[0..tile_jobs_len]);
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
        var tb = self.tileBuf();
        defer self.syncFromTileBuf(&tb);
        loadTileIntoBuf(&tb, ram, base_bus, fb_w, fb_h, tile_x, tile_y, tile_size, tiling, ls_format);
    }

    fn loadTileIntoBuf(
        tb: *TileBuffer,
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
        const base = base_bus & vc_bus.ramMask(ram.len);
        const is_565 = (ls_format == 1 or ls_format == 2);
        const fmt: format_mod.Format = if (is_565) .rgb565 else .argb8888;
        const cpp: u32 = if (is_565) 2 else 4;
        const x0 = tile_x * tile_size;
        const y0 = tile_y * tile_size;
        if (x0 >= fb_w or y0 >= fb_h) return;
        const valid_w = @min(tile_size, fb_w - x0);
        const valid_h = @min(tile_size, fb_h - y0);

        if (!is_565 and tile_size == 64) {
            if (tiling == 0 and valid_w == 64) {
                for (0..valid_h) |ty| {
                    const py = y0 + @as(u32, @intCast(ty));
                    const off = base + (py * fb_w + x0) * 4;
                    if (off + 256 <= ram.len) {
                        @memcpy(std.mem.sliceAsBytes(tb.color[ty * 64 ..][0..64]), ram[off..][0..256]);
                    }
                }
                return;
            } else if (tiling != 0 and (valid_w & 3) == 0) {
                const is_lt = (fb_w <= 16 or fb_h <= 16);
                const lt_row_stride = ((fb_w + 3) & ~@as(u32, 3)) << 2;
                const utile_stride = ((fb_w + 31) & ~@as(u32, 31)) >> 2;
                const base_ux = x0 >> 2;
                const base_uy = y0 >> 2;
                const utiles_x = valid_w >> 2;
                const utiles_y = valid_h >> 2;
                for (0..utiles_y) |uy| {
                    const abs_uy = base_uy + @as(u32, @intCast(uy));
                    var group_base: u32 = 0;
                    for (0..utiles_x) |ux| {
                        const abs_ux = base_ux + @as(u32, @intCast(ux));
                        if ((ux & 3) == 0) {
                            group_base = base + texture.utileGroupOffset(is_lt, lt_row_stride, utile_stride, abs_ux & ~@as(u32, 3), abs_uy);
                        }
                        const utile_off = group_base + ((abs_ux & 3) << 6);
                        if (utile_off + 64 <= ram.len) {
                            inline for (0..4) |ry| {
                                const dst_idx = (uy * 4 + ry) * 64 + ux * 4;
                                @memcpy(
                                    std.mem.sliceAsBytes(tb.color[dst_idx..][0..4]),
                                    ram[utile_off + ry * 16 ..][0..16],
                                );
                            }
                        }
                    }
                }
                if ((valid_h & 3) == 0) return;
            }
        } else if (is_565 and tile_size == 64 and tiling != 0 and (valid_w & 7) == 0) {
            const is_lt = (fb_w <= 32 or fb_h <= 16);
            const lt_row_stride = ((fb_w + 7) & ~@as(u32, 7)) << 1;
            const utile_stride = ((fb_w + 63) & ~@as(u32, 63)) >> 3;
            const base_ux = x0 >> 3;
            const base_uy = y0 >> 2;
            const utiles_x = valid_w >> 3;
            const utiles_y = valid_h >> 2;
            for (0..utiles_y) |uy| {
                const abs_uy = base_uy + @as(u32, @intCast(uy));
                var group_base: u32 = 0;
                for (0..utiles_x) |ux| {
                    const abs_ux = base_ux + @as(u32, @intCast(ux));
                    if ((ux & 3) == 0) {
                        group_base = base + texture.utileGroupOffset(is_lt, lt_row_stride, utile_stride, abs_ux & ~@as(u32, 3), abs_uy);
                    }
                    const utile_off = group_base + ((abs_ux & 3) << 6);
                    if (utile_off + 64 <= ram.len) {
                        inline for (0..4) |ry| {
                            const dst_row = tb.color[(uy * 4 + ry) * 64 + ux * 8 ..][0..8];
                            const p16_vec: @Vector(8, u16) = @bitCast(ram[utile_off + ry * 16 ..][0..16].*);
                            dst_row.* = @bitCast(format_mod.fromRgb565Vec8(p16_vec));
                        }
                    }
                }
            }
            if ((valid_h & 3) == 0) return;
        }

        const start_ty: usize = if (tile_size == 64 and tiling != 0 and ((!is_565 and (valid_w & 3) == 0) or (is_565 and (valid_w & 7) == 0)))
            (valid_h & ~@as(u32, 3))
        else
            0;

        for (start_ty..valid_h) |ty| {
            const py = y0 + @as(u32, @intCast(ty));
            for (0..valid_w) |tx| {
                const px = x0 + @as(u32, @intCast(tx));
                const off = base + if (tiling == 0)
                    (py * fb_w + px) * cpp
                else
                    texture.texelOffsetOf(fmt, fb_w, fb_h, px, py);
                if (off + cpp <= ram.len) {
                    tb.color[ty * tile_size + tx] = if (is_565)
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
        const tb = TileBuffer{
            .color = @constCast(&self.tile_color),
            .depth = @constCast(&self.tile_depth),
            .color_solid = self.tile_color_solid,
            .depth_valid = self.tile_depth_valid,
            .clear_zs = self.tile_clear_zs,
            .lazy_load = self.lazy_load,
            .loaded_from = self.loaded_from,
            .modified = self.tile_modified,
        };
        storeTileFromBuf(&tb, ram, base_bus, fb_w, fb_h, tile_x, tile_y, tile_size, tiling, ls_format);
    }

    fn storeTileFromBuf(
        tb: *const TileBuffer,
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
        const base = base_bus & vc_bus.ramMask(ram.len);
        const is_565 = (ls_format == 1 or ls_format == 2);
        const fmt: format_mod.Format = if (is_565) .rgb565 else .argb8888;
        const cpp: u32 = if (is_565) 2 else 4;
        const x0 = tile_x * tile_size;
        const y0 = tile_y * tile_size;
        if (x0 >= fb_w or y0 >= fb_h) return;
        const valid_w = @min(tile_size, fb_w - x0);
        const valid_h = @min(tile_size, fb_h - y0);

        if (!is_565 and tile_size == 64) {
            if (tiling == 0 and valid_w == 64) {
                if (tb.color_solid) |solid_c| {
                    var solid_row: [64]u32 = @splat(solid_c);
                    const row_bytes = std.mem.asBytes(&solid_row);
                    for (0..valid_h) |ty| {
                        const py = y0 + @as(u32, @intCast(ty));
                        const off = base + (py * fb_w + x0) * 4;
                        if (off + 256 <= ram.len) {
                            @memcpy(ram[off..][0..256], row_bytes);
                        }
                    }
                } else {
                    for (0..valid_h) |ty| {
                        const py = y0 + @as(u32, @intCast(ty));
                        const off = base + (py * fb_w + x0) * 4;
                        if (off + 256 <= ram.len) {
                            @memcpy(ram[off..][0..256], std.mem.sliceAsBytes(tb.color[ty * 64 ..][0..64]));
                        }
                    }
                }
                return;
            } else if (tiling != 0 and (valid_w & 3) == 0) {
                const is_lt = (fb_w <= 16 or fb_h <= 16);
                const lt_row_stride = ((fb_w + 3) & ~@as(u32, 3)) << 2;
                const utile_stride = ((fb_w + 31) & ~@as(u32, 31)) >> 2;
                const base_ux = x0 >> 2;
                const base_uy = y0 >> 2;
                const utiles_x = valid_w >> 2;
                const utiles_y = valid_h >> 2;
                if (tb.color_solid) |solid_c| {
                    var solid_utile: [16]u32 = @splat(solid_c);
                    const utile_bytes = std.mem.asBytes(&solid_utile);
                    for (0..utiles_y) |uy| {
                        const abs_uy = base_uy + @as(u32, @intCast(uy));
                        var group_base: u32 = 0;
                        for (0..utiles_x) |ux| {
                            const abs_ux = base_ux + @as(u32, @intCast(ux));
                            if ((ux & 3) == 0) {
                                group_base = base + texture.utileGroupOffset(is_lt, lt_row_stride, utile_stride, abs_ux & ~@as(u32, 3), abs_uy);
                            }
                            const utile_off = group_base + ((abs_ux & 3) << 6);
                            if (utile_off + 64 <= ram.len) {
                                @memcpy(ram[utile_off..][0..64], utile_bytes);
                            }
                        }
                    }
                } else {
                    for (0..utiles_y) |uy| {
                        const abs_uy = base_uy + @as(u32, @intCast(uy));
                        var group_base: u32 = 0;
                        for (0..utiles_x) |ux| {
                            const abs_ux = base_ux + @as(u32, @intCast(ux));
                            if ((ux & 3) == 0) {
                                group_base = base + texture.utileGroupOffset(is_lt, lt_row_stride, utile_stride, abs_ux & ~@as(u32, 3), abs_uy);
                            }
                            const utile_off = group_base + ((abs_ux & 3) << 6);
                            if (utile_off + 64 <= ram.len) {
                                inline for (0..4) |ry| {
                                    const src_idx = (uy * 4 + ry) * 64 + ux * 4;
                                    @memcpy(
                                        ram[utile_off + ry * 16 ..][0..16],
                                        std.mem.sliceAsBytes(tb.color[src_idx..][0..4]),
                                    );
                                }
                            }
                        }
                    }
                }
                if ((valid_h & 3) == 0) return;
            }
        }

        const solid_565 = if (tb.color_solid) |sc| format_mod.toRgb565(sc) else 0;
        if (is_565 and tile_size == 64 and tiling != 0 and (valid_w & 7) == 0) {
            const is_lt = (fb_w <= 32 or fb_h <= 16);
            const lt_row_stride = ((fb_w + 7) & ~@as(u32, 7)) << 1;
            const utile_stride = ((fb_w + 63) & ~@as(u32, 63)) >> 3;
            const base_ux = x0 >> 3;
            const base_uy = y0 >> 2;
            const utiles_x = valid_w >> 3;
            const utiles_y = valid_h >> 2;
            if (tb.color_solid != null) {
                var solid_utile: [32]u16 = @splat(solid_565);
                const utile_bytes = std.mem.asBytes(&solid_utile);
                for (0..utiles_y) |uy| {
                    const abs_uy = base_uy + @as(u32, @intCast(uy));
                    var group_base: u32 = 0;
                    for (0..utiles_x) |ux| {
                        const abs_ux = base_ux + @as(u32, @intCast(ux));
                        if ((ux & 3) == 0) {
                            group_base = base + texture.utileGroupOffset(is_lt, lt_row_stride, utile_stride, abs_ux & ~@as(u32, 3), abs_uy);
                        }
                        const utile_off = group_base + ((abs_ux & 3) << 6);
                        if (utile_off + 64 <= ram.len) {
                            @memcpy(ram[utile_off..][0..64], utile_bytes);
                        }
                    }
                }
            } else {
                for (0..utiles_y) |uy| {
                    const abs_uy = base_uy + @as(u32, @intCast(uy));
                    var group_base: u32 = 0;
                    for (0..utiles_x) |ux| {
                        const abs_ux = base_ux + @as(u32, @intCast(ux));
                        if ((ux & 3) == 0) {
                            group_base = base + texture.utileGroupOffset(is_lt, lt_row_stride, utile_stride, abs_ux & ~@as(u32, 3), abs_uy);
                        }
                        const utile_off = group_base + ((abs_ux & 3) << 6);
                        if (utile_off + 64 <= ram.len) {
                            inline for (0..4) |ry| {
                                const src_row: @Vector(8, u32) = tb.color[(uy * 4 + ry) * 64 + ux * 8 ..][0..8].*;
                                const dst_bytes = ram[utile_off + ry * 16 ..][0..16];
                                dst_bytes.* = @bitCast(format_mod.toRgb565Vec8(src_row));
                            }
                        }
                    }
                }
            }
            if ((valid_h & 3) == 0) return;
        }

        const start_ty: usize = if (tile_size == 64 and tiling != 0 and ((!is_565 and (valid_w & 3) == 0) or (is_565 and (valid_w & 7) == 0)))
            (valid_h & ~@as(u32, 3))
        else
            0;

        for (start_ty..valid_h) |ty| {
            const py = y0 + @as(u32, @intCast(ty));
            for (0..valid_w) |tx| {
                const px = x0 + @as(u32, @intCast(tx));
                const off = base + if (tiling == 0)
                    (py * fb_w + px) * cpp
                else
                    texture.texelOffsetOf(fmt, fb_w, fb_h, px, py);
                const c = tb.color_solid orelse tb.color[ty * tile_size + tx];
                if (off + cpp <= ram.len) {
                    if (is_565) {
                        const c565 = if (tb.color_solid != null) solid_565 else format_mod.toRgb565(c);
                        std.mem.writeInt(u16, ram[off..][0..2], c565, .little);
                    } else {
                        std.mem.writeInt(u32, ram[off..][0..4], c, .little);
                    }
                }
            }
        }
    }

    fn ensureTileMaterializedBuf(tb: *TileBuffer, ram: []const u8, need_depth: bool) void {
        tb.modified = true;
        if (tb.lazy_load) |ll| {
            tb.lazy_load = null;
            loadTileIntoBuf(tb, ram, ll.addr, ll.fb_w, ll.fb_h, ll.tile_x, ll.tile_y, ll.tile_size, ll.tiling, ll.format);
            tb.color_solid = null;
        } else if (tb.color_solid) |c| {
            @memset(tb.color, c);
            tb.color_solid = null;
        }
        if (need_depth and !tb.depth_valid) {
            @memset(tb.depth, tb.clear_zs);
            tb.depth_valid = true;
        }
    }

    fn renderDrawsIntoTileBuf(
        self: *const V3d,
        tb: *TileBuffer,
        ram: []const u8,
        tile_px_x: u32,
        tile_px_y: u32,
        tile_size: u32,
    ) void {
        const tile_end_x = tile_px_x + tile_size;
        const tile_end_y = tile_px_y + tile_size;

        const use_spatial_bin = (tile_size == 64 and (tile_px_x & 63) == 0 and (tile_px_y & 63) == 0 and (tile_px_x >> 6) < 32 and (tile_px_y >> 6) < 32);
        if (use_spatial_bin) {
            const tx = tile_px_x >> 6;
            const ty = tile_px_y >> 6;
            if ((self.tile_nonempty[ty] & (@as(u32, 1) << @intCast(tx))) == 0 and self.overflow_draw_start >= self.draws_len) {
                return;
            }
        }

        var fs_decoded_buf: [512]qpu_sim.DecodedInst = undefined;
        var fs_unif_buf: [128]u32 = undefined;
        var cur_draw_idx: ?u16 = null;
        var cur_fs_decoded: []const qpu_sim.DecodedInst = &.{};
        var cur_fs_unifs: []const u32 = &.{};

        if (use_spatial_bin) {
            const tx = tile_px_x >> 6;
            const ty = tile_px_y >> 6;
            if ((self.tile_nonempty[ty] & (@as(u32, 1) << @intCast(tx))) != 0) {
                const t_idx = ty * 32 + tx;
                const active_words = (self.shaded_tris_len + 63) >> 6;
                for (0..active_words) |w_i| {
                    var bits = self.tile_tri_mask[t_idx][w_i];
                    while (bits != 0) {
                        const bit_pos: usize = @ctz(bits);
                        bits &= bits - 1;
                        const tri_idx = (w_i << 6) + bit_pos;
                        if (tri_idx >= self.shaded_tris_len) break;
                        const tri = &self.shaded_tris[tri_idx];
                        const prep = self.prep_draws[tri.draw_idx];
                        if (!prep.valid) continue;

                        if (cur_draw_idx == null or cur_draw_idx.? != tri.draw_idx) {
                            cur_draw_idx = tri.draw_idx;
                            if (prep.fs_cached) {
                                cur_fs_decoded = self.prep_fs_insts[prep.fs_inst_start..][0..prep.fs_code_len];
                                cur_fs_unifs = self.prep_fs_unifs[prep.fs_unif_start..][0..prep.fs_unif_len];
                            } else {
                                for (0..prep.fs_code_len) |i| {
                                    const raw_inst = std.mem.readInt(u64, ram[prep.fs_code_phys + i * 8 ..][0..8], .little);
                                    fs_decoded_buf[i] = qpu_sim.decodeInst(raw_inst);
                                }
                                cur_fs_decoded = fs_decoded_buf[0..prep.fs_code_len];
                                for (0..prep.fs_unif_len) |i| {
                                    fs_unif_buf[i] = std.mem.readInt(u32, ram[prep.fs_unif_phys + i * 4 ..][0..4], .little);
                                }
                                cur_fs_unifs = fs_unif_buf[0..prep.fs_unif_len];
                            }
                        }

                        const draw = self.draws[tri.draw_idx];
                        rasterizeShadedTriangleDecodedInTileBuf(
                            tb,
                            ram,
                            draw,
                            tri,
                            cur_fs_decoded,
                            cur_fs_unifs,
                            prep.fs_num_varyings,
                            prep.fast_frag,
                            tile_px_x,
                            tile_px_y,
                            tile_size,
                        );
                    }
                }
            }
        } else {
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
                    if (prep.fs_cached) {
                        cur_fs_decoded = self.prep_fs_insts[prep.fs_inst_start..][0..prep.fs_code_len];
                        cur_fs_unifs = self.prep_fs_unifs[prep.fs_unif_start..][0..prep.fs_unif_len];
                    } else {
                        for (0..prep.fs_code_len) |i| {
                            const raw_inst = std.mem.readInt(u64, ram[prep.fs_code_phys + i * 8 ..][0..8], .little);
                            fs_decoded_buf[i] = qpu_sim.decodeInst(raw_inst);
                        }
                        cur_fs_decoded = fs_decoded_buf[0..prep.fs_code_len];
                        for (0..prep.fs_unif_len) |i| {
                            fs_unif_buf[i] = std.mem.readInt(u32, ram[prep.fs_unif_phys + i * 4 ..][0..4], .little);
                        }
                        cur_fs_unifs = fs_unif_buf[0..prep.fs_unif_len];
                    }
                }

                const draw = self.draws[tri.draw_idx];
                rasterizeShadedTriangleDecodedInTileBuf(
                    tb,
                    ram,
                    draw,
                    tri,
                    cur_fs_decoded,
                    cur_fs_unifs,
                    prep.fs_num_varyings,
                    prep.fast_frag,
                    tile_px_x,
                    tile_px_y,
                    tile_size,
                );
            }
        }

        if (self.overflow_draw_start < self.draws_len) {
            for (self.draws[self.overflow_draw_start..self.draws_len]) |draw| {
                renderDrawIntoTileBuf(tb, ram, draw, tile_px_x, tile_px_y, tile_size);
            }
        }
    }

    fn renderDrawIntoTileBuf(tb: *TileBuffer, ram: []const u8, draw: DrawCall, tile_px_x: u32, tile_px_y: u32, tile_size: u32) void {
        if (draw.count < 3) return;
        const rec_phys = draw.shader_rec_addr & vc_bus.ramMask(ram.len);
        if (rec_phys + 36 + @as(u32, draw.num_attrs) * 8 > ram.len) return;

        const fs_num_varyings = ram[rec_phys + 3];
        const fs_code_phys = std.mem.readInt(u32, ram[rec_phys + 4 ..][0..4], .little) & vc_bus.ramMask(ram.len);
        const fs_unif_phys = std.mem.readInt(u32, ram[rec_phys + 8 ..][0..4], .little) & vc_bus.ramMask(ram.len);
        const vs_attr_mask = ram[rec_phys + 14];
        const vs_code_phys = std.mem.readInt(u32, ram[rec_phys + 16 ..][0..4], .little) & vc_bus.ramMask(ram.len);
        const vs_unif_phys = std.mem.readInt(u32, ram[rec_phys + 20 ..][0..4], .little) & vc_bus.ramMask(ram.len);

        var vs_buf: [512]qpu.Inst = undefined;
        var fs_buf: [512]qpu.Inst = undefined;
        const vs_code = extractQpuProgram(ram, vs_code_phys, &vs_buf);
        const fs_code = extractQpuProgram(ram, fs_code_phys, &fs_buf);
        if (vs_code.len == 0 or fs_code.len == 0) return;

        var vs_decoded_buf: [512]qpu_sim.DecodedInst = undefined;
        var fs_decoded_buf: [512]qpu_sim.DecodedInst = undefined;
        const vs_decoded = qpu_sim.decodeProgram(vs_code, &vs_decoded_buf);
        const fs_decoded = qpu_sim.decodeProgram(fs_code, &fs_decoded_buf);

        var vs_unif_buf: [128]u32 = undefined;
        var fs_unif_buf: [128]u32 = undefined;
        const vs_unifs = extractUniforms(ram, vs_unif_phys, &vs_unif_buf);
        const fs_unifs = extractUniforms(ram, fs_unif_phys, &fs_unif_buf);
        const fast_frag = qpu_sim.analyzeFragmentShader(fs_decoded, fs_unifs);

        const num_tris: u32 = switch (draw.mode) {
            4 => draw.count / 3,
            5, 6 => if (draw.count >= 3) draw.count - 2 else 0,
            else => 0,
        };

        var attr_streams: [8]AttrStream = undefined;
        const attr_info = decodeAttrStreams(ram, rec_phys, draw.num_attrs, vs_attr_mask, &attr_streams);
        const active_attrs = attr_streams[0..attr_info.count];
        const vpm_words = attr_info.vpm_words;
        const n_var = @min(@as(usize, fs_num_varyings), 16);
        const clip_min_x: f32 = @floatFromInt(draw.clip_x);
        const clip_min_y: f32 = @floatFromInt(draw.clip_y);
        const clip_max_x: f32 = @floatFromInt(@as(u32, draw.clip_x) + draw.clip_w);
        const clip_max_y: f32 = @floatFromInt(@as(u32, draw.clip_y) + draw.clip_h);

        var tri_idx: u32 = 0;
        while (tri_idx < num_tris) {
            const batch_tris: usize = @min(@as(usize, num_tris - tri_idx), 5);
            const batch_verts: usize = batch_tris * 3;
            var v_indices: [15]u32 = undefined;

            for (0..batch_tris) |t_i| {
                const cur_tri = tri_idx + @as(u32, @intCast(t_i));
                const base_l = t_i * 3;
                switch (draw.mode) {
                    4 => {
                        v_indices[base_l + 0] = cur_tri * 3 + 0;
                        v_indices[base_l + 1] = cur_tri * 3 + 1;
                        v_indices[base_l + 2] = cur_tri * 3 + 2;
                    },
                    5 => {
                        if ((cur_tri & 1) == 0) {
                            v_indices[base_l + 0] = cur_tri + 0;
                            v_indices[base_l + 1] = cur_tri + 1;
                            v_indices[base_l + 2] = cur_tri + 2;
                        } else {
                            v_indices[base_l + 0] = cur_tri + 1;
                            v_indices[base_l + 1] = cur_tri + 0;
                            v_indices[base_l + 2] = cur_tri + 2;
                        }
                    },
                    6 => {
                        v_indices[base_l + 0] = 0;
                        v_indices[base_l + 1] = cur_tri + 1;
                        v_indices[base_l + 2] = cur_tri + 2;
                    },
                    else => {
                        v_indices[base_l + 0] = 0;
                        v_indices[base_l + 1] = 0;
                        v_indices[base_l + 2] = 0;
                    },
                }
            }
            tri_idx += @intCast(batch_tris);

            if (draw.indexed) {
                const idx_base = draw.index_buffer_addr & vc_bus.ramMask(ram.len);
                if (draw.u16_indices) {
                    for (v_indices[0..batch_verts]) |*vi| {
                        const off = idx_base + vi.* * 2;
                        vi.* = if (off + 2 <= ram.len) std.mem.readInt(u16, ram[off..][0..2], .little) else 0;
                    }
                } else {
                    for (v_indices[0..batch_verts]) |*vi| {
                        const off = idx_base + vi.*;
                        vi.* = if (off < ram.len) ram[off] else 0;
                    }
                }
            } else if (draw.first_or_offset != 0) {
                for (v_indices[0..batch_verts]) |*vi| {
                    vi.* += draw.first_or_offset;
                }
            }

            var vpm_in: [32]qpu_sim.Vec = undefined;
            populateBatchVpmIn(ram, active_attrs, v_indices[0..batch_verts], &vpm_in);

            const vs_res = qpu_sim.runDecoded(vs_decoded, .{
                .uniforms = vs_unifs,
                .vpm_in = vpm_in[0..vpm_words],
            }) catch continue;
            if (vs_res.vpm_out_len < 3) continue;

            for (0..batch_tris) |t_i| {
                const base_l = t_i * 3;
                var verts: [3]ShadedVertex = .{ .{}, .{}, .{} };
                for (0..3) |corner| {
                    const lane = base_l + corner;
                    const xy_packed = vs_res.vpm_out[0][lane];
                    const xs: i16 = @bitCast(@as(u16, @truncate(xy_packed)));
                    const ys: i16 = @bitCast(@as(u16, @truncate(xy_packed >> 16)));
                    verts[corner].x = @as(f32, @floatFromInt(xs)) * (1.0 / 16.0) + draw.vp_x;
                    verts[corner].y = @as(f32, @floatFromInt(ys)) * (1.0 / 16.0) + draw.vp_y;
                    verts[corner].z = @bitCast(vs_res.vpm_out[1][lane]);
                    const raw_inv_w: f32 = @bitCast(vs_res.vpm_out[2][lane]);
                    const inv_w = if (raw_inv_w == 0.0) 1.0 else raw_inv_w;
                    verts[corner].inv_w = inv_w;
                    for (0..n_var) |vi| {
                        if (3 + vi < vs_res.vpm_out_len) {
                            const raw_v: f32 = @bitCast(vs_res.vpm_out[3 + vi][lane]);
                            verts[corner].persp_varyings[vi] = raw_v * inv_w;
                        }
                    }
                }

                const area = (verts[1].x - verts[0].x) * (verts[2].y - verts[0].y) -
                    (verts[1].y - verts[0].y) * (verts[2].x - verts[0].x);
                if (@abs(area) < 1e-6) continue;

                const min_fx = @max(@floor(@min(verts[0].x, @min(verts[1].x, verts[2].x))), clip_min_x);
                const min_fy = @max(@floor(@min(verts[0].y, @min(verts[1].y, verts[2].y))), clip_min_y);
                const max_fx = @min(@ceil(@max(verts[0].x, @max(verts[1].x, verts[2].x))), clip_max_x);
                const max_fy = @min(@ceil(@max(verts[0].y, @max(verts[1].y, verts[2].y))), clip_max_y);
                if (min_fx >= max_fx or min_fy >= max_fy) continue;

                const tri = ShadedTriangle.init(
                    0,
                    @intFromFloat(min_fx),
                    @intFromFloat(min_fy),
                    @intFromFloat(max_fx),
                    @intFromFloat(max_fy),
                    area,
                    verts,
                    n_var,
                );
                rasterizeShadedTriangleDecodedInTileBuf(tb, ram, draw, &tri, fs_decoded, fs_unifs, fs_num_varyings, fast_frag, tile_px_x, tile_px_y, tile_size);
            }
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
        var fs_decoded_buf: [512]qpu_sim.DecodedInst = undefined;
        const fs_decoded = qpu_sim.decodeProgram(fs_code, &fs_decoded_buf);
        const fast_frag = qpu_sim.analyzeFragmentShader(fs_decoded, fs_unifs);
        var tb = self.tileBuf();
        defer self.syncFromTileBuf(&tb);
        rasterizeShadedTriangleDecodedInTileBuf(&tb, ram, draw, tri, fs_decoded, fs_unifs, num_varyings, fast_frag, tile_px_x, tile_px_y, tile_size);
    }

    fn rasterizeShadedTriangleDecodedInTileBuf(
        tb: *TileBuffer,
        ram: []const u8,
        draw: DrawCall,
        tri: *const ShadedTriangle,
        fs_decoded: []const qpu_sim.DecodedInst,
        fs_unifs: []const u32,
        num_varyings: u8,
        fast_frag: qpu_sim.FastFragShader,
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
        var tile_materialized = false;

        const n_var = @min(@as(usize, num_varyings), 16);
        const setup_tri = if (tri.setup_valid)
            tri.*
        else
            ShadedTriangle.init(tri.draw_idx, tri.min_x, tri.min_y, tri.max_x, tri.max_y, tri.area, tri.v, n_var);

        const inv_area = setup_tri.inv_area;
        if (inv_area <= 0) return;

        const edge0 = setup_tri.edge0;
        const edge1 = setup_tri.edge1;
        const edge2 = setup_tri.edge2;

        const z2 = setup_tri.v[2].z;
        const dz0 = setup_tri.dz0;
        const dz1 = setup_tri.dz1;
        const dz_dx = setup_tri.dz_dx;

        const all_unit_w = setup_tri.all_unit_w;
        const invw2 = setup_tri.v[2].inv_w;
        const dinvw0 = setup_tri.dinvw0;
        const dinvw1 = setup_tri.dinvw1;
        const dinvw_dx = setup_tri.dinvw_dx;

        const var2 = &setup_tri.v[2].persp_varyings;
        const dvar0 = &setup_tri.dvar0;
        const dvar1 = &setup_tri.dvar1;
        const dvar_dx = &setup_tri.dvar_dx;

        // Batch up to 16 covered pixels per SIMD QPU invocation
        var batch_idx: [16]u32 = undefined;
        var batch_z: [16]f32 = undefined;
        var frag_w: qpu_sim.Vec = qpu_sim.splatF(1.0);
        var frag_z: qpu_sim.Vec = qpu_sim.splat(0);
        var frag_x_vec: qpu_sim.Vec = qpu_sim.splat(0);
        var frag_y_vec: qpu_sim.Vec = qpu_sim.splat(0);
        var tlb_in: qpu_sim.Vec = qpu_sim.splat(0);
        var vary_vecs: [16]qpu_sim.Vec = @splat(qpu_sim.splat(0));
        var span_vary_vecs: [16]qpu_sim.Vec = undefined;
        var tex_cache: [2]qpu_sim.TexCache = .{ .{}, .{} };
        var batch_len: usize = 0;

        const flushBatch = struct {
            fn f(
                tbuf: *TileBuffer,
                count: usize,
                b_idx: *const [16]u32,
                bz: *const [16]f32,
                fw: *qpu_sim.Vec,
                fz: *qpu_sim.Vec,
                fx: *qpu_sim.Vec,
                fy: *qpu_sim.Vec,
                tin: *qpu_sim.Vec,
                vvecs: []qpu_sim.Vec,
                ffrag: qpu_sim.FastFragShader,
                fcode: []const qpu_sim.DecodedInst,
                funifs: []const u32,
                mem: []const u8,
                z_upd: bool,
                tcache: *[2]qpu_sim.TexCache,
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
                const env: qpu_sim.Env = .{
                    .uniforms = funifs,
                    .varyings = vvecs,
                    .frag_w = fw.*,
                    .frag_z = fz.*,
                    .frag_x = fx.*,
                    .frag_y = fy.*,
                    .texture_memory = mem,
                    .tlb_color_in = tin.*,
                    .tex_cache = tcache,
                };
                const res = qpu_sim.runFragmentFast(ffrag, fcode, &env) catch return;
                if (res.tlb_color) |colors| {
                    var i: usize = 0;
                    while (i + 4 <= count) {
                        const idx0 = b_idx[i];
                        if (b_idx[i + 3] == idx0 + 3) {
                            tbuf.color[idx0..][0..4].* = colors[i..][0..4].*;
                            if (z_upd) {
                                tbuf.depth[idx0..][0..4].* = bz[i..][0..4].*;
                            }
                            i += 4;
                            continue;
                        }
                        inline for (0..4) |k| {
                            const idx = b_idx[i + k];
                            tbuf.color[idx] = colors[i + k];
                            if (z_upd) {
                                tbuf.depth[idx] = bz[i + k];
                            }
                        }
                        i += 4;
                    }
                    while (i < count) : (i += 1) {
                        const idx = b_idx[i];
                        tbuf.color[idx] = colors[i];
                        if (z_upd) {
                            tbuf.depth[idx] = bz[i];
                        }
                    }
                }
            }
        }.f;

        const lane4_f_offsets = @Vector(4, f32){ 0.0, 1.0, 2.0, 3.0 };
        const lane4_u_offsets = @Vector(4, u32){ 0, 1, 2, 3 };
        const lane_f_offsets = @Vector(16, f32){ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        const lane_u_offsets = @Vector(16, u32){ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        const fx_min_tile = @as(f32, @floatFromInt(x_start)) + 0.5;
        const fx_max_tile = @as(f32, @floatFromInt(x_end - 1)) + 0.5;
        const step_x0 = edge0.step_x;
        const step_x1 = edge1.step_x;
        const step_x2 = edge2.step_x;
        const step16_z = @as(@Vector(16, f32), @splat(dz_dx)) * lane_f_offsets;
        const step4_z = @as(@Vector(4, f32), @splat(dz_dx)) * lane4_f_offsets;
        const step16_invw = @as(@Vector(16, f32), @splat(dinvw_dx)) * lane_f_offsets;
        const step4_invw = @as(@Vector(4, f32), @splat(dinvw_dx)) * lane4_f_offsets;
        var step16_var: [16]@Vector(16, f32) = undefined;
        var step4_var: [16]@Vector(4, f32) = undefined;
        for (0..n_var) |vi| {
            step16_var[vi] = @as(@Vector(16, f32), @splat(dvar_dx[vi])) * lane_f_offsets;
            step4_var[vi] = @as(@Vector(4, f32), @splat(dvar_dx[vi])) * lane4_f_offsets;
        }
        const step4_e0 = @as(@Vector(4, f32), @splat(step_x0)) * lane4_f_offsets;
        const step4_e1 = @as(@Vector(4, f32), @splat(step_x1)) * lane4_f_offsets;
        const step4_e2 = @as(@Vector(4, f32), @splat(step_x2)) * lane4_f_offsets;

        var py = y_start;
        while (py < y_end) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            const row_term0 = edge0.dx * (fy - edge0.p0y);
            const row_term1 = edge1.dx * (fy - edge1.p0y);
            const row_term2 = edge2.dx * (fy - edge2.p0y);

            // Evaluate edges at tile scanline endpoints to reject empty scanlines and tighten [px_start, px_end)
            const e0_min = edge0.eval(row_term0, fx_min_tile);
            const e0_max = edge0.eval(row_term0, fx_max_tile);
            const p0_min = edge0.passes(e0_min);
            const p0_max = edge0.passes(e0_max);
            if (!p0_min and !p0_max) continue;

            const e1_min = edge1.eval(row_term1, fx_min_tile);
            const e1_max = edge1.eval(row_term1, fx_max_tile);
            const p1_min = edge1.passes(e1_min);
            const p1_max = edge1.passes(e1_max);
            if (!p1_min and !p1_max) continue;

            const e2_min = edge2.eval(row_term2, fx_min_tile);
            const e2_max = edge2.eval(row_term2, fx_max_tile);
            const p2_min = edge2.passes(e2_min);
            const p2_max = edge2.passes(e2_max);
            if (!p2_min and !p2_max) continue;

            var px_start = x_start;
            var px_end = x_end;
            inline for (
                .{ p0_min, p1_min, p2_min },
                .{ p0_max, p1_max, p2_max },
                .{ e0_min, e1_min, e2_min },
                .{ step_x0, step_x1, step_x2 },
            ) |p_min, p_max, e_min, sx| {
                if (!p_min and p_max and sx > 1e-12) {
                    const skip = @floor((-e_min) / sx - 0.5);
                    if (skip > 0.0) {
                        const cand = x_start + @as(u32, @intFromFloat(@min(skip, @as(f32, @floatFromInt(x_end - x_start)))));
                        if (cand > px_start) px_start = cand;
                    }
                } else if (p_min and !p_max and sx < -1e-12) {
                    const keep = @ceil(e_min / (-sx) + 1.5);
                    if (keep > 0.0) {
                        const cand = x_start + @as(u32, @intFromFloat(@min(keep, @as(f32, @floatFromInt(x_end - x_start)))));
                        if (cand < px_end) px_end = cand;
                    }
                }
            }
            if (px_start >= px_end) continue;

            const row_base = (py - tile_px_y) * tile_size;
            const fx_start = @as(f32, @floatFromInt(px_start)) + 0.5;
            var cur_e0 = edge0.eval(row_term0, fx_start);
            var cur_e1 = edge1.eval(row_term1, fx_start);
            var cur_e2 = edge2.eval(row_term2, fx_start);

            var px = px_start;
            while (px < px_end) {
                // 16-lane SIMD interior span fast-path (runs even when batch_len > 0 holds earlier edge pixels)
                if (px + 16 <= px_end) {
                    if (edge0.passes(cur_e0) and
                        edge0.passes(cur_e0 + step_x0 * 15.0) and
                        edge1.passes(cur_e1) and
                        edge1.passes(cur_e1 + step_x1 * 15.0) and
                        edge2.passes(cur_e2) and
                        edge2.passes(cur_e2 + step_x2 * 15.0))
                    {
                        if (!tile_materialized) {
                            ensureTileMaterializedBuf(tb, ram, need_depth);
                            tile_materialized = true;
                        }
                        const tile_idx = row_base + (px - tile_px_x);
                        const w0_base = cur_e0 * inv_area;
                        const w1_base = cur_e1 * inv_area;
                        const z_base = z2 + w0_base * dz0 + w1_base * dz1;
                        const z_vec = @as(@Vector(16, f32), @splat(z_base)) + step16_z;

                        const depth_all_pass: bool = if (depth_func == 7) true else blk: {
                            const cur_z_vec: @Vector(16, f32) = tb.depth[tile_idx..][0..16].*;
                            break :blk switch (depth_func) {
                                0 => false,
                                1 => @reduce(.And, z_vec < cur_z_vec),
                                2 => @reduce(.And, z_vec == cur_z_vec),
                                3 => @reduce(.And, z_vec <= cur_z_vec),
                                4 => @reduce(.And, z_vec > cur_z_vec),
                                5 => @reduce(.And, z_vec != cur_z_vec),
                                6 => @reduce(.And, z_vec >= cur_z_vec),
                                7 => true,
                            };
                        };

                        if (depth_all_pass) {
                            if (fast_frag.kind == .constant_color) {
                                tb.color[tile_idx..][0..16].* = @splat(fast_frag.color);
                                if (z_updates) {
                                    tb.depth[tile_idx..][0..16].* = z_vec;
                                }
                                px += 16;
                                cur_e0 += step_x0 * 16.0;
                                cur_e1 += step_x1 * 16.0;
                                cur_e2 += step_x2 * 16.0;
                                continue;
                            }

                            const w_vec: @Vector(16, f32) = if (all_unit_w)
                                @splat(1.0)
                            else blk: {
                                const invw_base = invw2 + w0_base * dinvw0 + w1_base * dinvw1;
                                const interp_inv_w = @as(@Vector(16, f32), @splat(invw_base)) + step16_invw;
                                const valid_mask = @abs(interp_inv_w) > @as(@Vector(16, f32), @splat(1e-12));
                                break :blk @select(f32, valid_mask, @as(@Vector(16, f32), @splat(1.0)) / interp_inv_w, @as(@Vector(16, f32), @splat(1.0)));
                            };

                            for (0..n_var) |vi| {
                                const var_base = var2[vi] + w0_base * dvar0[vi] + w1_base * dvar1[vi];
                                const p_vec = (@as(@Vector(16, f32), @splat(var_base)) + step16_var[vi]) * w_vec;
                                span_vary_vecs[vi] = @bitCast(p_vec);
                            }

                            const span_env: qpu_sim.Env = .{
                                .uniforms = fs_unifs,
                                .varyings = span_vary_vecs[0..n_var],
                                .frag_w = @bitCast(w_vec),
                                .frag_z = @bitCast(z_vec),
                                .frag_x = @as(qpu_sim.Vec, @splat(px)) + lane_u_offsets,
                                .frag_y = @splat(py),
                                .texture_memory = ram,
                                .tlb_color_in = tb.color[tile_idx..][0..16].*,
                                .tex_cache = &tex_cache,
                            };
                            const span_res = qpu_sim.runFragmentFast(fast_frag, fs_decoded, &span_env) catch null;

                            if (span_res) |res| {
                                if (res.tlb_color) |colors| {
                                    tb.color[tile_idx..][0..16].* = colors;
                                    if (z_updates) {
                                        tb.depth[tile_idx..][0..16].* = z_vec;
                                    }
                                }
                            }
                            px += 16;
                            cur_e0 += step_x0 * 16.0;
                            cur_e1 += step_x1 * 16.0;
                            cur_e2 += step_x2 * 16.0;
                            continue;
                        }
                    }
                }

                // 4-wide SIMD edge stepping & coverage evaluation
                if (px + 4 <= px_end) {
                    const e0_4 = @as(@Vector(4, f32), @splat(cur_e0)) + step4_e0;
                    var mask4: u4 = edge0.passesMask4(e0_4);
                    if (mask4 == 0) {
                        px += 4;
                        cur_e0 += step_x0 * 4.0;
                        cur_e1 += step_x1 * 4.0;
                        cur_e2 += step_x2 * 4.0;
                        continue;
                    }
                    const e1_4 = @as(@Vector(4, f32), @splat(cur_e1)) + step4_e1;
                    mask4 &= edge1.passesMask4(e1_4);
                    if (mask4 == 0) {
                        px += 4;
                        cur_e0 += step_x0 * 4.0;
                        cur_e1 += step_x1 * 4.0;
                        cur_e2 += step_x2 * 4.0;
                        continue;
                    }
                    const e2_4 = @as(@Vector(4, f32), @splat(cur_e2)) + step4_e2;
                    mask4 &= edge2.passesMask4(e2_4);
                    if (mask4 == 0) {
                        px += 4;
                        cur_e0 += step_x0 * 4.0;
                        cur_e1 += step_x1 * 4.0;
                        cur_e2 += step_x2 * 4.0;
                        continue;
                    }

                    if (!tile_materialized) {
                        ensureTileMaterializedBuf(tb, ram, need_depth);
                        tile_materialized = true;
                    }

                    const w0_base = cur_e0 * inv_area;
                    const w1_base = cur_e1 * inv_area;
                    const z_base = z2 + w0_base * dz0 + w1_base * dz1;
                    const z_4 = @as(@Vector(4, f32), @splat(z_base)) + step4_z;
                    const base_tile_idx = row_base + (px - tile_px_x);

                    if (depth_func != 7) {
                        const cur_z_4: @Vector(4, f32) = tb.depth[base_tile_idx..][0..4].*;
                        const dmask: u4 = switch (depth_func) {
                            0 => 0,
                            1 => @bitCast(z_4 < cur_z_4),
                            2 => @bitCast(z_4 == cur_z_4),
                            3 => @bitCast(z_4 <= cur_z_4),
                            4 => @bitCast(z_4 > cur_z_4),
                            5 => @bitCast(z_4 != cur_z_4),
                            6 => @bitCast(z_4 >= cur_z_4),
                            7 => 0xf,
                        };
                        mask4 &= dmask;
                        if (mask4 == 0) {
                            px += 4;
                            cur_e0 += step_x0 * 4.0;
                            cur_e1 += step_x1 * 4.0;
                            cur_e2 += step_x2 * 4.0;
                            continue;
                        }
                    }

                    if (fast_frag.kind == .constant_color) {
                        if (mask4 == 0xf) {
                            tb.color[base_tile_idx..][0..4].* = @splat(fast_frag.color);
                            if (z_updates) {
                                tb.depth[base_tile_idx..][0..4].* = z_4;
                            }
                        } else {
                            const z_arr_c: [4]f32 = z_4;
                            while (mask4 != 0) {
                                const k: usize = @ctz(mask4);
                                mask4 &= mask4 - 1;
                                const t_idx = base_tile_idx + @as(u32, @intCast(k));
                                tb.color[t_idx] = fast_frag.color;
                                if (z_updates) {
                                    tb.depth[t_idx] = z_arr_c[k];
                                }
                            }
                        }
                        px += 4;
                        cur_e0 += step_x0 * 4.0;
                        cur_e1 += step_x1 * 4.0;
                        cur_e2 += step_x2 * 4.0;
                        continue;
                    }

                    const w_vec_4: @Vector(4, f32) = if (all_unit_w)
                        @splat(1.0)
                    else blk: {
                        const invw_base = invw2 + w0_base * dinvw0 + w1_base * dinvw1;
                        const interp_inv_w = @as(@Vector(4, f32), @splat(invw_base)) + step4_invw;
                        const valid_mask = @abs(interp_inv_w) > @as(@Vector(4, f32), @splat(1e-12));
                        break :blk @select(f32, valid_mask, @as(@Vector(4, f32), @splat(1.0)) / interp_inv_w, @as(@Vector(4, f32), @splat(1.0)));
                    };

                    if (mask4 == 0xf and batch_len <= 12) {
                        batch_idx[batch_len..][0..4].* = @as(@Vector(4, u32), @splat(base_tile_idx)) + lane4_u_offsets;
                        batch_z[batch_len..][0..4].* = z_4;
                        frag_w[batch_len..][0..4].* = @bitCast(w_vec_4);
                        frag_z[batch_len..][0..4].* = @bitCast(z_4);
                        frag_x_vec[batch_len..][0..4].* = @as(@Vector(4, u32), @splat(px)) + lane4_u_offsets;
                        frag_y_vec[batch_len..][0..4].* = @splat(py);
                        tlb_in[batch_len..][0..4].* = tb.color[base_tile_idx..][0..4].*;

                        for (0..n_var) |vi| {
                            const var_base = var2[vi] + w0_base * dvar0[vi] + w1_base * dvar1[vi];
                            const p_4 = (@as(@Vector(4, f32), @splat(var_base)) + step4_var[vi]) * w_vec_4;
                            vary_vecs[vi][batch_len..][0..4].* = @bitCast(p_4);
                        }

                        batch_len += 4;
                        if (batch_len == 16) {
                            flushBatch(
                                tb,
                                batch_len,
                                &batch_idx,
                                &batch_z,
                                &frag_w,
                                &frag_z,
                                &frag_x_vec,
                                &frag_y_vec,
                                &tlb_in,
                                vary_vecs[0..n_var],
                                fast_frag,
                                fs_decoded,
                                fs_unifs,
                                ram,
                                z_updates,
                                &tex_cache,
                            );
                            batch_len = 0;
                        }
                        px += 4;
                        cur_e0 += step_x0 * 4.0;
                        cur_e1 += step_x1 * 4.0;
                        cur_e2 += step_x2 * 4.0;
                        continue;
                    }

                    const w_val_4: [4]f32 = w_vec_4;
                    const z_arr: [4]f32 = z_4;

                    while (mask4 != 0) {
                        const k: usize = @ctz(mask4);
                        mask4 &= mask4 - 1;
                        const tile_idx = base_tile_idx + @as(u32, @intCast(k));
                        const z = z_arr[k];
                        const w_val = w_val_4[k];
                        const kf: f32 = @floatFromInt(k);
                        const w0 = w0_base + kf * (step_x0 * inv_area);
                        const w1 = w1_base + kf * (step_x1 * inv_area);

                        const lane = batch_len;
                        batch_idx[lane] = tile_idx;
                        batch_z[lane] = z;
                        frag_w[lane] = @bitCast(w_val);
                        frag_z[lane] = @bitCast(z);
                        frag_x_vec[lane] = px + @as(u32, @intCast(k));
                        frag_y_vec[lane] = py;
                        tlb_in[lane] = tb.color[tile_idx];

                        for (0..n_var) |vi| {
                            const p_val = (var2[vi] + w0 * dvar0[vi] + w1 * dvar1[vi]) * w_val;
                            vary_vecs[vi][lane] = @bitCast(p_val);
                        }

                        batch_len += 1;
                        if (batch_len == 16) {
                            flushBatch(
                                tb,
                                batch_len,
                                &batch_idx,
                                &batch_z,
                                &frag_w,
                                &frag_z,
                                &frag_x_vec,
                                &frag_y_vec,
                                &tlb_in,
                                vary_vecs[0..n_var],
                                fast_frag,
                                fs_decoded,
                                fs_unifs,
                                ram,
                                z_updates,
                                &tex_cache,
                            );
                            batch_len = 0;
                        }
                    }
                    px += 4;
                    cur_e0 += step_x0 * 4.0;
                    cur_e1 += step_x1 * 4.0;
                    cur_e2 += step_x2 * 4.0;
                    continue;
                }

                const e0 = cur_e0;
                const e1 = cur_e1;
                const e2 = cur_e2;
                px += 1;
                cur_e0 += step_x0;
                cur_e1 += step_x1;
                cur_e2 += step_x2;
                if (!edge0.passes(e0)) continue;
                if (!edge1.passes(e1)) continue;
                if (!edge2.passes(e2)) continue;

                if (!tile_materialized) {
                    ensureTileMaterializedBuf(tb, ram, need_depth);
                    tile_materialized = true;
                }

                const w0 = e0 * inv_area;
                const w1 = e1 * inv_area;

                const z = z2 + w0 * dz0 + w1 * dz1;
                const tile_idx = row_base + (px - 1 - tile_px_x);

                if (depth_func != 7) {
                    const cur_z = tb.depth[tile_idx];
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

                if (fast_frag.kind == .constant_color) {
                    tb.color[tile_idx] = fast_frag.color;
                    if (z_updates) {
                        tb.depth[tile_idx] = z;
                    }
                    continue;
                }

                const w_val: f32 = if (all_unit_w) 1.0 else blk: {
                    const interp_inv_w = invw2 + w0 * dinvw0 + w1 * dinvw1;
                    break :blk if (@abs(interp_inv_w) > 1e-12) (1.0 / interp_inv_w) else 1.0;
                };

                const lane = batch_len;
                batch_idx[lane] = tile_idx;
                batch_z[lane] = z;
                frag_w[lane] = @bitCast(w_val);
                frag_z[lane] = @bitCast(z);
                frag_x_vec[lane] = px - 1;
                frag_y_vec[lane] = py;
                tlb_in[lane] = tb.color[tile_idx];

                for (0..n_var) |vi| {
                    const p_val = (var2[vi] + w0 * dvar0[vi] + w1 * dvar1[vi]) * w_val;
                    vary_vecs[vi][lane] = @bitCast(p_val);
                }

                batch_len += 1;
                if (batch_len == 16) {
                    flushBatch(
                        tb,
                        batch_len,
                        &batch_idx,
                        &batch_z,
                        &frag_w,
                        &frag_z,
                        &frag_x_vec,
                        &frag_y_vec,
                        &tlb_in,
                        vary_vecs[0..n_var],
                        fast_frag,
                        fs_decoded,
                        fs_unifs,
                        ram,
                        z_updates,
                        &tex_cache,
                    );
                    batch_len = 0;
                }
            }
        }

        if (batch_len > 0) {
            flushBatch(
                tb,
                batch_len,
                &batch_idx,
                &batch_z,
                &frag_w,
                &frag_z,
                &frag_x_vec,
                &frag_y_vec,
                &tlb_in,
                vary_vecs[0..n_var],
                fast_frag,
                fs_decoded,
                fs_unifs,
                ram,
                z_updates,
                &tex_cache,
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

test "V3D RGB565 8x4 utile storeTileToRam and loadTileFromRam round-trip" {
    var v3d = V3d{};
    const fb_w: u32 = 128;
    const fb_h: u32 = 93; // tile_y=0 has full 64 rows, tile_y=1 has 29 rows (7 full utile rows + 1 remainder row)
    var ram: [128 * 96 * 2]u8 = @splat(0);

    // 1. Solid clear store on tile (0, 0) and partial-height tile (1, 1)
    v3d.tile_color_solid = 0xff00ff00;
    v3d.storeTileToRam(&ram, 0x80000000, fb_w, fb_h, 0, 0, 64, 1, 2);
    v3d.storeTileToRam(&ram, 0x80000000, fb_w, fb_h, 1, 1, 64, 1, 2);

    // 2. Non-solid store on tile (0, 1) (29 rows high)
    v3d.tile_color_solid = null;
    for (0..29) |ty| {
        for (0..64) |tx| {
            v3d.tile_color[ty * 64 + tx] = if (((tx + ty) & 1) == 0) 0xffff0000 else 0xff0000ff;
        }
    }
    v3d.storeTileToRam(&ram, 0x80000000, fb_w, fb_h, 0, 1, 64, 1, 2);

    // 3. Clear tile_color and load back tile (0, 1) via loadTileFromRam
    @memset(&v3d.tile_color, 0);
    v3d.loadTileFromRam(&ram, 0x80000000, fb_w, fb_h, 0, 1, 64, 1, 2);
    for (0..29) |ty| {
        for (0..64) |tx| {
            const expected: u32 = if (((tx + ty) & 1) == 0) 0xffff0000 else 0xff0000ff;
            try std.testing.expectEqual(expected, v3d.tile_color[ty * 64 + tx]);
        }
    }
}

test "V3D populateBatchVpmIn multi-word attribute gather and padding" {
    var ram: [256]u8 = @splat(0);
    // 3 vertices, each 24 bytes (vec4 + vec2 interleaved, stride = 24)
    for (0..3) |vi| {
        for (0..6) |wi| {
            const val: u32 = @intCast((vi + 1) * 100 + wi);
            std.mem.writeInt(u32, ram[vi * 24 + wi * 4 ..][0..4], val, .little);
        }
    }

    const attrs = [_]V3d.AttrStream{
        .{ .base = 0, .stride = 24, .words = 4 },
        .{ .base = 16, .stride = 24, .words = 2 },
    };
    const v_indices = [_]u32{ 2, 0, 1 };
    var vpm_in: [32]qpu_sim.Vec = undefined;
    V3d.populateBatchVpmIn(&ram, &attrs, &v_indices, &vpm_in);

    for (0..6) |wi| {
        try std.testing.expectEqual(@as(u32, @intCast(300 + wi)), vpm_in[wi][0]); // vi = 2
        try std.testing.expectEqual(@as(u32, @intCast(100 + wi)), vpm_in[wi][1]); // vi = 0
        try std.testing.expectEqual(@as(u32, @intCast(200 + wi)), vpm_in[wi][2]); // vi = 1
        // Lanes 3..15 should pad with lane 2 (vi = 1)
        for (3..16) |lane| {
            try std.testing.expectEqual(@as(u32, @intCast(200 + wi)), vpm_in[wi][lane]);
        }
    }
}

test "V3D multi-tile RCL parallel rasterization across 16 tiles" {
    var v3d = V3d{};
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 512 * 1024);
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

    var fs: qpu.Program(16) = .{};
    fs.emit(try qpu.loadImm(.{ .add_dst = qpu.tlb_color_all, .value = 0xff00ff00 }));
    fs.end(.fragment);

    @memcpy(ram[0x1000 .. 0x1000 + vs.code().len * 8], std.mem.sliceAsBytes(vs.code()));
    @memcpy(ram[0x1400 .. 0x1400 + fs.code().len * 8], std.mem.sliceAsBytes(fs.code()));

    // VS uniforms at 0x1800: x_scale = 128.0 * 16.0, y_scale = 128.0 * 16.0 (for 256x256 viewport)
    std.mem.writeInt(u32, ram[0x1800..0x1804], @bitCast(@as(f32, 128.0 * 16.0)), .little);
    std.mem.writeInt(u32, ram[0x1804..0x1808], @bitCast(@as(f32, 128.0 * 16.0)), .little);

    // 2 triangles forming a full-screen quad [-1, 1] x [-1, 1] covering all 16 tiles
    const verts = [_]f32{
        -1.0, -1.0, 0.0, 1.0, 0.0,
        1.0,  -1.0, 0.0, 1.0, 0.0,
        1.0,  1.0,  0.0, 1.0, 0.0,
        -1.0, -1.0, 0.0, 1.0, 0.0,
        1.0,  1.0,  0.0, 1.0, 0.0,
        -1.0, 1.0,  0.0, 1.0, 0.0,
    };
    @memcpy(ram[0x2000 .. 0x2000 + @sizeOf(@TypeOf(verts))], std.mem.sliceAsBytes(&verts));

    ram[0x3003] = 3; // fs_num_varyings = 3
    std.mem.writeInt(u32, ram[0x3004..0x3008], 0x1400, .little); // FS code
    std.mem.writeInt(u32, ram[0x3008..0x300c], 0x1900, .little); // FS unifs
    ram[0x300e] = 1; // vs_attr_mask = 1
    std.mem.writeInt(u32, ram[0x3010..0x3014], 0x1000, .little); // VS code
    std.mem.writeInt(u32, ram[0x3014..0x3018], 0x1800, .little); // VS unifs
    std.mem.writeInt(u32, ram[0x3024..0x3028], 0x2000, .little);
    ram[0x3028] = 19;
    ram[0x3029] = 20;

    var bcl: usize = 0x4000;
    ram[bcl] = 6; // START_TILE_BINNING
    bcl += 1;
    ram[bcl] = 103; // VIEWPORT_OFFSET (128.0, 128.0)
    std.mem.writeInt(u16, ram[bcl + 1 ..][0..2], 128 * 16, .little);
    std.mem.writeInt(u16, ram[bcl + 3 ..][0..2], 128 * 16, .little);
    bcl += 5;
    ram[bcl] = 64; // GL_SHADER_STATE (0x3000 | 1 attr)
    std.mem.writeInt(u32, ram[bcl + 1 ..][0..4], 0x3001, .little);
    bcl += 5;
    ram[bcl] = 33; // GL_ARRAY_PRIMITIVE (triangles=4, count=6, first=0)
    ram[bcl + 1] = 4;
    std.mem.writeInt(u32, ram[bcl + 2 ..][0..4], 6, .little);
    std.mem.writeInt(u32, ram[bcl + 6 ..][0..4], 0, .little);
    bcl += 10;
    ram[bcl] = 4; // FLUSH
    bcl += 1;

    v3d.write32(0x034, V3d.INT_FLDONE | V3d.INT_FRDONE, ram);
    v3d.write32(0x110, 0x4000, ram);
    v3d.write32(0x108, @intCast(bcl), ram);
    try std.testing.expect((v3d.read32(0x030) & V3d.INT_FLDONE) != 0);

    // Build RCL at 0x5000 rendering 16 tiles (4x4 = 256x256) to Linear RGBA8888 framebuffer at 0x20000
    var rcl: usize = 0x5000;
    ram[rcl] = 113; // TILE_RENDERING_MODE_CONFIG
    std.mem.writeInt(u32, ram[rcl + 1 ..][0..4], 0x20000, .little);
    std.mem.writeInt(u16, ram[rcl + 5 ..][0..2], 256, .little);
    std.mem.writeInt(u16, ram[rcl + 7 ..][0..2], 256, .little);
    std.mem.writeInt(u16, ram[rcl + 9 ..][0..2], 1 << 2, .little); // format=1 (RGBA8888), tiling=0 (Linear)
    rcl += 11;
    ram[rcl] = 114; // CLEAR_COLORS (black 0xff000000)
    std.mem.writeInt(u32, ram[rcl + 1 ..][0..4], 0xff000000, .little);
    std.mem.writeInt(u32, ram[rcl + 9 ..][0..4], 0x00ffffff, .little);
    rcl += 14;

    for (0..4) |ty| {
        for (0..4) |tx| {
            ram[rcl] = 115; // TILE_COORDINATES
            ram[rcl + 1] = @intCast(tx);
            ram[rcl + 2] = @intCast(ty);
            rcl += 3;
            ram[rcl] = 17; // BRANCH_TO_SUB_LIST
            std.mem.writeInt(u32, ram[rcl + 1 ..][0..4], 0, .little);
            rcl += 5;
            ram[rcl] = if (tx == 3 and ty == 3) 25 else 24; // STORE_MS_TILE_BUFFER(_AND_EOF)
            rcl += 1;
        }
    }

    v3d.write32(0x114, 0x5000, ram);
    v3d.write32(0x10c, @intCast(rcl), ram);
    try std.testing.expect((v3d.read32(0x030) & V3d.INT_FRDONE) != 0);

    // Check center of each of the 16 64x64 tiles is green (0xff00ff00)
    for (0..4) |ty| {
        for (0..4) |tx| {
            const px = tx * 64 + 32;
            const py = ty * 64 + 32;
            const off = 0x20000 + (py * 256 + px) * 4;
            try std.testing.expectEqual(@as(u32, 0xff00ff00), std.mem.readInt(u32, ram[off..][0..4], .little));
        }
    }
}
