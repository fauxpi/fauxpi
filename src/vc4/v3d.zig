const std = @import("std");
const vc_bus = @import("../soc/vc_bus.zig");
const qpu = @import("qpu.zig");
const qpu_sim = @import("qpu_sim.zig");
const format_mod = @import("format.zig");
const texture = @import("texture.zig");
const builtin = @import("builtin");
const metal_renderer = @import("metal_renderer.zig");
const gl_renderer = @import("gl_renderer.zig");
const gpu_draw = @import("gpu_draw.zig");
const profile = @import("../profile.zig");
const qpu_to_shader = @import("qpu_to_shader.zig");

/// VideoCore IV 3D Engine (`brcm,bcm2835-v3d`) at `0x20c00000` (size `0x1000`).
pub const V3d = struct {
    pub const BASE_ADDR: u32 = 0x20c00000;
    pub const SIZE: u32 = 0x1000;

    // V3D Interrupt bits
    pub const INT_FRDONE: u32 = 1 << 0;
    pub const INT_FLDONE: u32 = 1 << 1;
    pub const INT_OUTOMEM: u32 = 1 << 2;
    pub const INT_SPILLUSE: u32 = 1 << 3;

    /// How a draw's vertices are given: shaded by its vertex shader (GL), shaded already in
    /// memory (NV), or as screen coordinates (VG).
    pub const DrawMode = enum { gl, nv, vg };

    pub const DrawCall = struct {
        kind: DrawMode = .gl,
        /// VG mode: its fragment shader, uniforms and varyings (from its shader record, or one
        /// inline); its vertices `first_or_offset` on in `vg_verts`.
        fs_code: u32 = 0,
        fs_unifs: u32 = 0,
        fs_varyings: u8 = 0,
        shader_rec_addr: u32 = 0,
        num_attrs: u4 = 0,
        mode: u8 = 4, // 0 = points, 1 = lines, 2 = line loop, 3 = line strip, 4 = triangles, 5 = strip, 6 = fan
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
        /// The clipper's scaling (CLIPPER_XY_SCALING, CLIPPER_Z_SCALING): from clip coordinates
        /// (divided by W) to screen ones, x and y in 16ths of a pixel from the viewport offset.
        clip_scale_x: f32 = 0,
        clip_scale_y: f32 = 0,
        z_scale: f32 = 1,
        z_offset: f32 = 0,
        /// How wide lines are drawn, in pixels (LINE_WIDTH).
        line_width: f32 = 1,
        /// How wide points are drawn, in pixels (POINT_SIZE), unless the vertex shader says.
        point_size: f32 = 1,
    };

    /// A vertex's clip coordinates, as its coordinate shader writes them (W NaN if it can't be run).
    pub const ClipVertex = struct { x: f32, y: f32, z: f32, w: f32 };

    /// A triangle (in `shaded_tris`) binned into a tile (`y * 32 + x`).
    const BinPair = struct { tri: u32, tile: u16 };

    /// The most triangles a frame's draws are shaded and binned into tiles
    /// with (those drawn: not culled, or off the framebuffer); the draws past
    /// them are shaded again for each tile.
    pub const MAX_PREBINNED_TRIS = 65536;

    pub const PreparedDraw = struct {
        fs_code_phys: u32 = 0,
        fs_code_len: u32 = 0,
        fs_unif_phys: u32 = 0,
        /// The fragment shader, decoded: `fs_code_len` instructions from here in `prep_fs_insts`.
        fs_inst_start: u32 = 0,
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
        /// How wide a point drawn at it is, in pixels.
        point_size: f32 = 1,
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
        draw_idx: u32,
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
            draw_idx: u32,
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
        /// The tile buffer as it was stored (LOAD_FULL_RES_TILE_BUFFER), not pixels.
        full_res: bool = false,
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
    vpacntl: u32 = 0,
    vpmbase: u32 = 0,
    /// QPU user programs: those queued (SRQPC, with SRQUA and SRQUL), those running (on a QPU
    /// each), what they share (semaphores, the mutex, the VPM), the queue's counts and its error
    /// (SRQCS), and the QPUs' interrupts (DBQITE, DBQITC).
    user_queue: [16]UserRequest = undefined,
    user_queued: u8 = 0,
    user_running: [16]?*UserRun = @splat(null),
    user_sync: qpu_sim.Sync = .{},
    vpm: [qpu_sim.vpm_words]u32 = @splat(0),
    srq_requests: u8 = 0,
    srq_completed: u8 = 0,
    srq_error: bool = false,
    dbqite: u32 = 0,
    dbqitc: u32 = 0,

    /// Performance counters: their values, sources (PCTRS), and enables (PCTRE).
    pctr: [16]u32 = @splat(0),
    pctrs: [16]u5 = @splat(0),
    pctre: u32 = 0,

    /// The binning thread stopped out of memory (until given overspill: BPOS), where it goes on
    /// from, and the tile list blocks it still needs.
    bcl_stalled: bool = false,
    bcl_resume: u32 = 0,
    bin_need_blocks: u64 = 0,
    /// The frame's tile list blocks taken so far, and the tile allocation's block sizes and
    /// tiles (TILE_BINNING_MODE_CONFIG).
    bin_blocks_taken: u64 = 0,
    bin_initial_block: u32 = 32,
    bin_block: u32 = 32,
    bin_tiles: u32 = 0,
    /// Where the binner's tile lists are (the tile allocation pool): a rendering list's
    /// sub-lists there are the frame binned, others tile lists written otherwise.
    bin_pool_lo: u32 = 0,
    bin_pool_hi: u32 = 0,
    /// The semaphore between the threads (INCREMENT_SEMAPHORE, WAIT_ON_SEMAPHORE), and a
    /// rendering list waiting on it (its start and end).
    semaphore: u32 = 0,
    rcl_waiting: ?[2]u32 = null,

    // Binning state collected during BCL execution
    /// The frame's draws, as many as the binner is given (it has no limit).
    draws: std.ArrayList(DrawCall) = .empty,
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
    cur_clip_scale_x: f32 = 0,
    cur_clip_scale_y: f32 = 0,
    cur_z_scale: f32 = 1,
    cur_z_offset: f32 = 0,
    cur_line_width: f32 = 1,
    cur_point_size: f32 = 1,
    /// The mode of the shader state last given, and VG's fragment shader.
    cur_kind: DrawMode = .gl,
    cur_fs_code: u32 = 0,
    cur_fs_unifs: u32 = 0,
    cur_fs_varyings: u8 = 0,
    /// VG mode's RHTs' X boundary (RHT_X_BOUNDARY), the frame's VG vertices (each primitive as
    /// triangles), and the last two vertices of the last VG list (for one continuing it).
    rht_x_boundary: f32 = 0,
    vg_verts: std.ArrayList([2]f32) = .empty,
    vg_last: [2][2]f32 = @splat(.{ 0, 0 }),
    multisample_bin: bool = false,

    // Tile buffer (64x64 pixels max per tile)
    tile_color: [64 * 64]u32 = @splat(0),
    tile_depth: [64 * 64]f32 = @splat(1.0),
    tile_stencil: [64 * 64]u8 = @splat(0),
    tile_vg_mask: [64 * 64]u8 = @splat(0),
    tile_color_solid: ?u32 = null,
    tile_depth_valid: bool = false,
    tile_clear_zs: f32 = 1.0,
    tile_clear_stencil: u8 = 0,
    tile_clear_vg_mask: u8 = 0,
    tile_vg_valid: bool = false,
    lazy_load: ?LazyTileLoad = null,
    loaded_from: ?LazyTileLoad = null,
    tile_modified: bool = false,

    // Pre-shaded & pre-binned state for the current RCL frame
    prep_draws: std.ArrayList(PreparedDraw) = .empty,
    /// The frame's fragment shaders, decoded (see `PreparedDraw.fs_inst_start`).
    prep_fs_insts: std.ArrayList(qpu_sim.DecodedInst) = .empty,
    /// A draw's vertex shader, while it is shaded: as read, and decoded.
    vs_code: std.ArrayList(qpu.Inst) = .empty,
    vs_decoded: std.ArrayList(qpu_sim.DecodedInst) = .empty,
    /// A draw's coordinate shader, decoded, and its vertices' clip coordinates (by slot, as
    /// `vs_out`).
    cs_decoded: std.ArrayList(qpu_sim.DecodedInst) = .empty,
    vs_clip: std.ArrayList(ClipVertex) = .empty,
    /// The frame's triangles, shaded, in draw order.
    shaded_tris: std.ArrayList(ShadedTriangle) = .empty,
    /// A draw's vertices, while it is shaded (`shadeVertices`): each corner's slot, each slot's
    /// vertex index, and its shaded vertex (if it was).
    vs_corner_slot: std.ArrayList(u32) = .empty,
    vs_unique: std.ArrayList(u32) = .empty,
    vs_out: std.ArrayList(ShadedVertex) = .empty,
    vs_ok: std.ArrayList(bool) = .empty,
    /// Which slot a vertex index has, if `vs_slot_gen` is the draw's `vs_gen`.
    vs_slot_key: std.ArrayList(u32) = .empty,
    vs_slot_gen: std.ArrayList(u32) = .empty,
    vs_slot_index: std.ArrayList(u32) = .empty,
    vs_gen: u32 = 0,
    overflow_draw_start: usize = 0,
    /// Each 64-pixel tile's triangles (`y * 32 + x`), in draw order: indices
    /// into `shaded_tris`, from `tile_tri_start[t]` to `tile_tri_start[t + 1]`
    /// in `tile_tris`.
    tile_tri_start: [32 * 32 + 1]u32 = @splat(0),
    tile_tris: std.ArrayList(u32) = .empty,
    /// Each triangle's tiles, as binning finds them.
    bin_pairs: std.ArrayList(BinPair) = .empty,

    /// What frames are drawn with on the host's GPU (made with the first frame), if they can be.
    gpu: ?*GpuState = null,
    gpu_tried: bool = false,
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
        self.vpacntl = 0;
        self.vpmbase = 0;
        self.pctr = @splat(0);
        self.pctrs = @splat(0);
        self.pctre = 0;
        self.bcl_stalled = false;
        self.bin_need_blocks = 0;
        self.bin_blocks_taken = 0;
        self.bin_tiles = 0;
        self.semaphore = 0;
        self.rcl_waiting = null;
        for (&self.user_running) |*slot| {
            if (slot.*) |run| {
                tri_allocator.free(run.decoded);
                tri_allocator.destroy(run);
            }
            slot.* = null;
        }
        self.user_queued = 0;
        self.user_sync = .{};
        self.srq_requests = 0;
        self.srq_completed = 0;
        self.srq_error = false;
        self.dbqite = 0;
        self.dbqitc = 0;
        self.draws.clearRetainingCapacity();
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
        self.cur_clip_scale_x = 0;
        self.cur_clip_scale_y = 0;
        self.cur_z_scale = 1;
        self.cur_z_offset = 0;
        self.cur_line_width = 1;
        self.cur_point_size = 1;
        self.multisample_bin = false;
        @memset(&self.tile_color, 0);
        @memset(&self.tile_depth, 1.0);
        self.tile_color_solid = null;
        self.tile_depth_valid = false;
        self.tile_clear_zs = 1.0;
        self.tile_clear_stencil = 0;
        self.tile_clear_vg_mask = 0;
        self.tile_vg_valid = false;
        self.lazy_load = null;
        self.loaded_from = null;
        self.tile_modified = false;
        self.prep_fs_insts.clearRetainingCapacity();
        self.shaded_tris.clearRetainingCapacity();
        self.overflow_draw_start = 0;
        self.tile_tri_start = @splat(0);
        self.frame_dirty = false;
    }

    pub fn takeFrameDirty(self: *V3d) bool {
        const d = self.frame_dirty;
        self.frame_dirty = false;
        return d;
    }

    pub fn irqPending(self: *const V3d) bool {
        return (self.intStatus() & self.int_mask) != 0 or (self.dbqitc & self.dbqite) != 0;
    }

    /// INTCTL: the interrupts raised, and OUTOMEM while the binner has no overspill memory
    /// (BPOS 0), whatever's cleared.
    fn intStatus(self: *const V3d) u32 {
        return self.intctl | (if (self.bpos == 0) INT_OUTOMEM else 0);
    }

    fn ctStatus(self: *const V3d, cs: u32, running: bool) u32 {
        const sema: u32 = @min(self.semaphore, 7);
        return (cs & ~@as(u32, 1 << 5 | 7 << 12)) | @as(u32, @intFromBool(running)) << 5 | sema << 12;
    }

    /// `n` of performance counter source `src` happened: added to the counters counting it.
    fn countEvent(self: *V3d, src: u5, n: u64) void {
        if (self.pctre & (1 << 31) == 0) return;
        for (&self.pctr, self.pctrs, 0..) |*c, sc, i| {
            if (sc == src and self.pctre & (@as(u32, 1) << @intCast(i)) != 0) c.* +%= @truncate(n);
        }
    }

    pub fn read32(self: *const V3d, offset: u32) u32 {
        return switch (offset) {
            0x000 => 0x02443356, // V3D_IDENT0 ("V3D\x02")
            0x004 => 0x41101411, // V3D_IDENT1 (Rev 1, 1 slice, 4 QPUs)
            0x008 => 0x0000010f, // V3D_IDENT2
            0x010 => self.scratch,
            0x020 => self.l2cactl,
            0x024 => self.slcactl,
            0x030 => self.intStatus(),
            0x034 => self.int_mask,
            0x038 => ~self.int_mask,
            // CTRUN while stopped (out of memory, or at the semaphore), else done at once; CTSEMA.
            0x100 => self.ctStatus(self.ct0cs, self.bcl_stalled),
            0x104 => self.ctStatus(self.ct1cs, self.rcl_waiting != null),
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
            0x43c => @as(u32, self.user_queued) | @as(u32, @intFromBool(self.srq_error)) << 7 | @as(u32, self.srq_requests) << 8 | @as(u32, self.srq_completed) << 16,
            0xe2c => self.dbqite,
            0xe30 => self.dbqitc,
            0x500 => self.vpacntl,
            0x504 => self.vpmbase,
            0x670 => 0,
            0x674 => self.pctre,
            0x680...0x6fc => if (offset & 4 == 0) self.pctr[(offset - 0x680) / 8] else self.pctrs[(offset - 0x684) / 8],
            0xf00, 0xf04, 0xf08, 0xf0c, 0xf10, 0xf20 => 0,
            else => 0,
        };
    }

    pub fn write32(self: *V3d, offset: u32, val: u32, ram: []u8) void {
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
            0x108 => { // V3D_CT0EA -> Run Binning Control List (BCL), to here
                self.ct0ea = val;
                if (!self.bcl_stalled and self.ct0ea != self.ct0ca) self.runBcl(ram, self.ct0ca);
            },
            0x10c => { // V3D_CT1EA -> Run Rendering Control List (RCL), to here
                self.ct1ea = val;
                if (self.ct1ea != self.ct1ca and self.rcl_waiting == null) {
                    // One waiting on the semaphore runs once binning increments it.
                    self.rcl_waiting = .{ self.ct1ca, self.ct1ea };
                    self.runWaitingRcl(ram);
                }
            },
            0x110 => self.ct0ca = val,
            0x114 => self.ct1ca = val,
            0x134 => self.bfc &= ~val,
            0x138 => self.rfc &= ~val,
            0x308 => self.bpoa = val,
            0x30c => {
                self.bpos = val;
                // Binning stopped out of memory goes on.
                if (self.bcl_stalled and val != 0) {
                    if (self.binAllocate()) {
                        self.bcl_stalled = false;
                        self.binFlushed();
                        self.runBcl(ram, self.bcl_resume);
                    }
                }
            },
            0x310 => self.bxcf = val,
            0x410 => self.sqrsv0 = val,
            0x414 => self.sqrsv1 = val,
            0x418 => self.sqcntl = val,
            0x430 => { // V3D_SRQPC: a user program queued (16 at most), then run
                self.srqpc = val;
                if (self.user_queued == self.user_queue.len) {
                    self.srq_error = true;
                } else {
                    self.user_queue[self.user_queued] = .{ .pc = val, .unifs = self.srqua, .len = self.srqul };
                    self.user_queued += 1;
                    self.srq_requests +%= 1;
                }
                self.runUserPrograms(ram);
            },
            0x434 => self.srqua = val,
            0x438 => self.srqul = val,
            0x43c => { // SRQCS: the queue emptied (bit 0), the error and counts cleared
                if (val & 1 != 0) self.user_queued = 0;
                if (val & (1 << 7) != 0) self.srq_error = false;
                if (val & (1 << 8) != 0) self.srq_requests = 0;
                if (val & (1 << 16) != 0) self.srq_completed = 0;
                self.runUserPrograms(ram);
            },
            0xe2c => self.dbqite = val,
            0xe30 => self.dbqitc &= ~val,
            0x500 => self.vpacntl = val,
            0x504 => self.vpmbase = val,
            0x670 => { // PCTRC: counters cleared
                for (&self.pctr, 0..) |*c, i| {
                    if (val & (@as(u32, 1) << @intCast(i)) != 0) c.* = 0;
                }
            },
            0x674 => self.pctre = val,
            0x680...0x6fc => if (offset & 4 == 0) {
                self.pctr[(offset - 0x680) / 8] = val;
            } else {
                self.pctrs[(offset - 0x684) / 8] = @truncate(val);
            },
            else => {},
        }
    }

    pub const UserRequest = struct { pc: u32, unifs: u32, len: u32 };

    /// A user program running on a QPU.
    const UserRun = struct {
        req: UserRequest,
        decoded: []qpu_sim.DecodedInst,
        machine: qpu_sim.Machine,
        result: qpu_sim.Result = .{},
    };

    /// Whether QPU `q` may run user programs (SQRSV0/1: its 4 bits; bit 3 reserves it from
    /// them).
    fn userQpuFree(self: *const V3d, q: usize) bool {
        const word = if (q < 8) self.sqrsv0 else self.sqrsv1;
        return (word >> @intCast((q % 8) * 4)) & 8 == 0;
    }

    fn userEnv(self: *V3d, ram: []u8, req: UserRequest, q: usize) qpu_sim.Env {
        const mask = vc_bus.ramMask(ram.len);
        const unif = req.unifs & mask & ~@as(u32, 3);
        // Up to SRQUL of them (over 1023, unlimited).
        const avail: u32 = if (unif < ram.len) @intCast((ram.len - unif) / 4) else 0;
        const n = if (req.len > 1023) avail else @min(req.len, avail);
        return .{
            .uniforms = if (n > 0) std.mem.bytesAsSlice(u32, ram[unif..][0 .. n * 4]) else &.{},
            .texture_memory = ram,
            .uniform_memory = ram,
            .code_addr = req.pc,
            .qpu_number = @intCast(q),
            .max_steps = std.math.maxInt(usize),
            .sync = &self.user_sync,
            .vpm_mem = &self.vpm,
            .dma_ram = ram,
        };
    }

    /// Runs the user programs: those queued started on the QPUs free for them, then each run in
    /// turn (a slice at a time), until all have ended, or wait on each other (they go on later),
    /// or have run long enough (a program looping for ever runs on later too). Each ending
    /// counts as completed; host interrupts are raised (DBQITC).
    fn runUserPrograms(self: *V3d, ram: []u8) void {
        var budget: usize = 1 << 26;
        while (true) {
            // Those queued, onto free QPUs.
            for (&self.user_running, 0..) |*slot, q| {
                if (self.user_queued == 0) break;
                if (slot.* != null or !self.userQpuFree(q)) continue;
                const req = self.user_queue[0];
                std.mem.copyForwards(UserRequest, self.user_queue[0 .. self.user_queued - 1], self.user_queue[1..self.user_queued]);
                self.user_queued -= 1;
                const phys = req.pc & vc_bus.ramMask(ram.len);
                const len = programLen(ram, phys);
                const run = tri_allocator.create(UserRun) catch break;
                const decoded = tri_allocator.alloc(qpu_sim.DecodedInst, len) catch {
                    tri_allocator.destroy(run);
                    break;
                };
                var code: std.ArrayList(qpu.Inst) = .empty;
                defer code.deinit(tri_allocator);
                code.resize(tri_allocator, len) catch {};
                if (code.items.len == len) {
                    _ = qpu_sim.decodeProgram(readProgram(ram, phys, code.items).?, decoded);
                } else @memset(decoded, .{});
                const env = self.userEnv(ram, req, q);
                run.* = .{ .req = req, .decoded = decoded, .machine = .init(&env) };
                slot.* = run;
            }
            var progressed = false;
            for (&self.user_running, 0..) |*slot, q| {
                const run = slot.* orelse continue;
                const env = self.userEnv(ram, run.req, q);
                const before = run.machine.steps;
                const stop = run.machine.run(qpu_sim.Result, run.decoded, &env, &run.result, 1 << 14) catch .ended;
                const ran = run.machine.steps - before;
                budget -|= ran;
                if (ran > 0) progressed = true;
                if (stop == .ended) {
                    tri_allocator.free(run.decoded);
                    tri_allocator.destroy(run);
                    slot.* = null;
                    self.srq_completed +%= 1;
                    progressed = true;
                }
            }
            self.dbqitc |= self.user_sync.host_int;
            self.user_sync.host_int = 0;
            if (!progressed or budget == 0) break;
        }
    }

    /// Runs the binning list from `start` to CT0EA (or until it runs out of memory), then a
    /// rendering list waiting on the semaphore.
    fn runBcl(self: *V3d, ram: []u8, start: u32) void {
        self.executeBcl(ram, start, self.ct0ea);
        if (!self.bcl_stalled) self.ct0ca = self.ct0ea;
        self.runWaitingRcl(ram);
    }

    /// Runs the rendering list waiting, if the semaphore lets it: one with as many
    /// WAIT_ON_SEMAPHOREs as it counts.
    fn runWaitingRcl(self: *V3d, ram: []u8) void {
        const r = self.rcl_waiting orelse return;
        const waits = rclSemaphoreWaits(ram, r[0], r[1]);
        if (waits > self.semaphore) return;
        self.semaphore -= waits;
        self.rcl_waiting = null;
        self.executeRcl(ram, r[0], r[1]);
        self.ct1ca = r[1];
        self.rfc +%= 1;
        self.intctl |= INT_FRDONE;
        self.frame_dirty = true;
    }

    /// The WAIT_ON_SEMAPHOREs in a rendering list from `start` to `end`.
    fn rclSemaphoreWaits(ram: []const u8, start: u32, end_bus: u32) u32 {
        var pc = start & vc_bus.ramMask(ram.len);
        const end = end_bus & vc_bus.ramMask(ram.len);
        var waits: u32 = 0;
        var steps: usize = 0;
        while (pc != end and pc < ram.len and steps < 1 << 22) : (steps += 1) {
            const size: u32 = switch (ram[pc]) {
                0 => break,
                8 => blk: {
                    waits += 1;
                    break :blk 1;
                },
                1, 4, 5, 18, 24, 25 => 1,
                16 => {
                    if (pc + 5 > ram.len) break;
                    pc = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little) & vc_bus.ramMask(ram.len);
                    continue;
                },
                17, 26, 27 => 5,
                28, 29 => 7,
                113 => 11,
                114 => 14,
                115 => 3,
                else => break,
            };
            pc += size;
        }
        return waits;
    }

    /// A flush of the binning list: the memory its tile lists take beyond their initial blocks
    /// taken from the pool (if it may be too small: counted from the frame binned), then the
    /// flush counted. False if it ran out of memory.
    fn binFlush(self: *V3d, ram: []const u8) bool {
        var prims: u64 = 0;
        for (self.draws.items) |d| prims += numPrims(d);
        self.countEvent(1, prims);
        if (self.bin_tiles != 0 and @as(u64, self.bpcs) + self.bpos < prims * 8 + self.draws.items.len * 8) {
            self.prepareDrawsForFrame(ram);
            const total = self.tileListBlocks();
            self.bin_need_blocks = total -| self.bin_blocks_taken;
            self.bin_blocks_taken = @max(total, self.bin_blocks_taken);
        } else self.bin_need_blocks = 0;
        if (!self.binAllocate()) return false;
        self.binFlushed();
        return true;
    }

    fn binFlushed(self: *V3d) void {
        self.bfc +%= 1;
        self.intctl |= INT_FLDONE;
    }

    /// The tile list blocks past their initial ones the frame binned takes: each tile's list
    /// some 7 bytes a draw in it (its state and primitive format) and 2 a primitive, in its
    /// initial block, then more (each ending in a 5-byte branch).
    fn tileListBlocks(self: *const V3d) u64 {
        var bytes: [32 * 32]u32 = @splat(1);
        var last_draw: [32 * 32]u32 = @splat(std.math.maxInt(u32));
        for (self.bin_pairs.items) |pair| {
            const draw = self.shaded_tris.items[pair.tri].draw_idx;
            if (last_draw[pair.tile] != draw) {
                last_draw[pair.tile] = draw;
                bytes[pair.tile] += 7;
            }
            bytes[pair.tile] += 2;
        }
        var blocks: u64 = 0;
        const first = self.bin_initial_block - 5;
        const rest = self.bin_block - 5;
        for (bytes) |b| {
            if (b > first) blocks += (b - first + rest - 1) / rest;
        }
        return blocks;
    }

    /// Takes the blocks needed from the pool (BPCA, BPCS), then from the overspill (BPOA, BPOS:
    /// raising SPILLUSE). False if both run out (OUTOMEM is then raised, until more overspill).
    fn binAllocate(self: *V3d) bool {
        while (self.bin_need_blocks > 0) {
            if (self.bpcs >= self.bin_block) {
                const n = @min(self.bin_need_blocks, self.bpcs / self.bin_block);
                self.bpcs -= @intCast(n * self.bin_block);
                self.bpca +%= @intCast(n * self.bin_block);
                self.bin_need_blocks -= n;
                continue;
            }
            if (self.bpos < self.bin_block) return false;
            self.bpca = self.bpoa;
            self.bpcs = self.bpos;
            self.bpoa = 0;
            self.bpos = 0;
            self.intctl |= INT_SPILLUSE;
        }
        return true;
    }

    fn executeBcl(self: *V3d, ram: []const u8, start_bus: u32, end_bus: u32) void {
        const prof_start = profile.now();
        defer profile.end(.v3d_bin, prof_start);
        var pc = start_bus & vc_bus.ramMask(ram.len);
        // It runs until its address is the end's (sub-lists may be anywhere).
        const end = end_bus & vc_bus.ramMask(ram.len);
        var returns: [4]u32 = undefined;
        var depth: usize = 0;
        var steps: usize = 0;

        while (pc != end and pc < ram.len) : (steps += 1) {
            if (steps > 1 << 26) break;
            const op = ram[pc];
            switch (op) {
                0 => break, // HALT
                1, 8 => pc += 1, // NOP, WAIT_ON_SEMAPHORE
                4, 5 => { // FLUSH, FLUSH_ALL_STATE
                    pc += 1;
                    if (!self.binFlush(ram)) {
                        // Out of memory: stopped, until given more.
                        self.bcl_stalled = true;
                        self.bcl_resume = pc;
                        self.ct0ca = pc;
                        return;
                    }
                },
                7 => { // INCREMENT_SEMAPHORE
                    self.semaphore +|= 1;
                    pc += 1;
                },
                6 => { // START_TILE_BINNING
                    self.draws.clearRetainingCapacity();
                    self.vg_verts.clearRetainingCapacity();
                    self.bin_blocks_taken = 0;
                    pc += 1;
                },
                16 => { // BRANCH
                    if (pc + 5 > ram.len) break;
                    pc = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little) & vc_bus.ramMask(ram.len);
                },
                17 => { // BRANCH_TO_SUB_LIST: returned from by RETURN_FROM_SUB_LIST
                    if (pc + 5 > ram.len) break;
                    if (depth < returns.len) {
                        returns[depth] = pc + 5;
                        depth += 1;
                    }
                    pc = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little) & vc_bus.ramMask(ram.len);
                },
                18 => { // RETURN_FROM_SUB_LIST
                    if (depth == 0) {
                        pc += 1;
                    } else {
                        depth -= 1;
                        pc = returns[depth];
                    }
                },
                32 => { // GL_INDEXED_PRIMITIVE (14 bytes)
                    if (pc + 14 > ram.len) break;
                    const mode_byte = ram[pc + 1];
                    const count = std.mem.readInt(u32, ram[pc + 2 ..][0..4], .little);
                    const index_off = std.mem.readInt(u32, ram[pc + 6 ..][0..4], .little);
                    {
                        // Only running out of memory loses a draw.
                        self.draws.append(tri_allocator, .{
                            .kind = if (self.cur_kind == .vg) .gl else self.cur_kind,
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
                            .clip_scale_x = self.cur_clip_scale_x,
                            .clip_scale_y = self.cur_clip_scale_y,
                            .z_scale = self.cur_z_scale,
                            .z_offset = self.cur_z_offset,
                            .line_width = self.cur_line_width,
                            .point_size = self.cur_point_size,
                        }) catch {};
                    }
                    pc += 14;
                },
                33 => { // GL_ARRAY_PRIMITIVE (10 bytes)
                    if (pc + 10 > ram.len) break;
                    const mode = ram[pc + 1] & 0x0f;
                    const count = std.mem.readInt(u32, ram[pc + 2 ..][0..4], .little);
                    const first = std.mem.readInt(u32, ram[pc + 6 ..][0..4], .little);
                    {
                        self.draws.append(tri_allocator, .{
                            .kind = if (self.cur_kind == .vg) .gl else self.cur_kind,
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
                            .clip_scale_x = self.cur_clip_scale_x,
                            .clip_scale_y = self.cur_clip_scale_y,
                            .z_scale = self.cur_z_scale,
                            .z_offset = self.cur_z_offset,
                            .line_width = self.cur_line_width,
                            .point_size = self.cur_point_size,
                        }) catch {};
                    }
                    pc += 10;
                },
                56 => pc += 2, // PRIMITIVE_LIST_FORMAT
                64 => { // GL_SHADER_STATE (5 bytes)
                    if (pc + 5 > ram.len) break;
                    const word = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little);
                    const n_attr: u4 = @intCast(if ((word & 7) == 0) 8 else (word & 7));
                    self.cur_num_attrs = n_attr;
                    self.cur_shader_rec = word & ~@as(u32, 0xf);
                    self.cur_kind = .gl;
                    pc += 5;
                },
                65 => { // NV_SHADER_STATE (5 bytes): a record of shaded vertices
                    if (pc + 5 > ram.len) break;
                    self.cur_shader_rec = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little) & ~@as(u32, 0xf);
                    self.cur_num_attrs = 0;
                    self.cur_kind = .nv;
                    pc += 5;
                },
                66 => { // VG_SHADER_STATE (5 bytes): its record's fragment shader
                    if (pc + 5 > ram.len) break;
                    const rec = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little) & ~@as(u32, 0xf) & vc_bus.ramMask(ram.len);
                    if (rec + 12 <= ram.len) {
                        self.cur_fs_varyings = ram[rec + 3];
                        self.cur_fs_code = std.mem.readInt(u32, ram[rec + 4 ..][0..4], .little);
                        self.cur_fs_unifs = std.mem.readInt(u32, ram[rec + 8 ..][0..4], .little);
                    }
                    self.cur_kind = .vg;
                    pc += 5;
                },
                67 => { // VG_INLINE_SHADER_RECORD (9 bytes): its fragment shader and uniforms
                    if (pc + 9 > ram.len) break;
                    self.cur_fs_code = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little) & ~@as(u32, 7);
                    self.cur_fs_unifs = std.mem.readInt(u32, ram[pc + 5 ..][0..4], .little);
                    self.cur_fs_varyings = 0;
                    self.cur_kind = .vg;
                    pc += 9;
                },
                41 => { // VG_COORDINATE_ARRAY_PRIMITIVES (10 bytes): primitives' coordinates in memory
                    if (pc + 10 > ram.len) break;
                    const ty: u4 = @truncate(ram[pc + 1]);
                    const count = std.mem.readInt(u32, ram[pc + 2 ..][0..4], .little);
                    const addr = std.mem.readInt(u32, ram[pc + 6 ..][0..4], .little) & vc_bus.ramMask(ram.len);
                    const n_coords: u64 = switch (ty) {
                        1 => @as(u64, count) * 2,
                        3 => @as(u64, count) + 1,
                        4 => @as(u64, count) * 3,
                        5, 6 => @as(u64, count) + 2,
                        else => 0,
                    };
                    const n: usize = @intCast(@min(n_coords, (ram.len -| addr) / 4));
                    self.vgPrimitives(ty, ram[pc + 1] & 0x10 != 0, std.mem.bytesAsSlice(u32, ram[addr..][0 .. n * 4]));
                    pc += 10;
                },
                42 => { // VG_INLINE_PRIMITIVES: coordinates after it, to an escape (padding skipped)
                    if (pc + 2 > ram.len) break;
                    const ty: u4 = @truncate(ram[pc + 1]);
                    const cont = ram[pc + 1] & 0x10 != 0;
                    var q = pc + 2;
                    var coords: std.ArrayList(u32) = .empty;
                    defer coords.deinit(tri_allocator);
                    while (q + 4 <= ram.len) {
                        const w = std.mem.readInt(u32, ram[q..][0..4], .little);
                        q += 4;
                        if (w == vg_escape) break;
                        if (w == vg_pad) continue;
                        coords.append(tri_allocator, w) catch break;
                    }
                    self.vgPrimitives(ty, cont, coords.items);
                    pc = q;
                },
                96 => { // CONFIGURATION_BITS (4 bytes)
                    if (pc + 4 > ram.len) break;
                    self.cur_cfg0 = ram[pc + 1];
                    self.cur_cfg1 = ram[pc + 2];
                    self.cur_cfg2 = ram[pc + 3];
                    pc += 4;
                },
                97, 101 => pc += 5, // FLAT_SHADE, DEPTH_OFFSET
                98 => { // POINT_SIZE (5 bytes): a float, in pixels
                    if (pc + 5 > ram.len) break;
                    self.cur_point_size = @bitCast(std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little));
                    pc += 5;
                },
                99 => { // LINE_WIDTH (5 bytes): a float, in pixels
                    if (pc + 5 > ram.len) break;
                    self.cur_line_width = @bitCast(std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little));
                    pc += 5;
                },
                100 => { // RHT_X_BOUNDARY (3 bytes): in pixels
                    if (pc + 3 > ram.len) break;
                    self.rht_x_boundary = @floatFromInt(@as(i16, @bitCast(std.mem.readInt(u16, ram[pc + 1 ..][0..2], .little))));
                    pc += 3;
                },
                102 => { // CLIP_WINDOW (9 bytes)
                    if (pc + 9 > ram.len) break;
                    self.cur_clip_x = std.mem.readInt(u16, ram[pc + 1 ..][0..2], .little);
                    self.cur_clip_y = std.mem.readInt(u16, ram[pc + 3 ..][0..2], .little);
                    self.cur_clip_w = std.mem.readInt(u16, ram[pc + 5 ..][0..2], .little);
                    self.cur_clip_h = std.mem.readInt(u16, ram[pc + 7 ..][0..2], .little);
                    pc += 9;
                },
                103 => { // VIEWPORT_OFFSET (5 bytes, signed 12.4 fixed point)
                    if (pc + 5 > ram.len) break;
                    const vx: i16 = @bitCast(std.mem.readInt(u16, ram[pc + 1 ..][0..2], .little));
                    const vy: i16 = @bitCast(std.mem.readInt(u16, ram[pc + 3 ..][0..2], .little));
                    self.cur_vp_x = @as(f32, @floatFromInt(vx)) / 16.0;
                    self.cur_vp_y = @as(f32, @floatFromInt(vy)) / 16.0;
                    pc += 5;
                },
                104 => pc += 9, // Z_CLIPPING
                105 => { // CLIPPER_XY_SCALING (9 bytes): x and y, in 16ths of a pixel
                    if (pc + 9 > ram.len) break;
                    self.cur_clip_scale_x = @bitCast(std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little));
                    self.cur_clip_scale_y = @bitCast(std.mem.readInt(u32, ram[pc + 5 ..][0..4], .little));
                    pc += 9;
                },
                106 => { // CLIPPER_Z_SCALING (9 bytes): scale, then offset
                    if (pc + 9 > ram.len) break;
                    self.cur_z_scale = @bitCast(std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little));
                    self.cur_z_offset = @bitCast(std.mem.readInt(u32, ram[pc + 5 ..][0..4], .little));
                    pc += 9;
                },
                112 => { // TILE_BINNING_MODE_CONFIG (16 bytes)
                    if (pc + 16 > ram.len) break;
                    const flags = ram[pc + 15];
                    self.multisample_bin = (flags & 1) != 0;
                    self.draws.clearRetainingCapacity();
                    self.vg_verts.clearRetainingCapacity();
                    // The pool after each tile's initial block.
                    const sizes = [4]u32{ 32, 64, 128, 256 };
                    self.bin_initial_block = sizes[(flags >> 3) & 3];
                    self.bin_block = sizes[(flags >> 5) & 3];
                    self.bin_tiles = @as(u32, ram[pc + 13]) * ram[pc + 14];
                    self.bin_blocks_taken = 0;
                    const pool = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little);
                    const pool_size = std.mem.readInt(u32, ram[pc + 5 ..][0..4], .little);
                    self.bin_pool_lo = pool & vc_bus.ramMask(ram.len);
                    self.bin_pool_hi = self.bin_pool_lo +| pool_size;
                    const initial = self.bin_tiles * self.bin_initial_block;
                    self.bpca = pool +% initial;
                    self.bpcs = pool_size -| initial;
                    pc += 16;
                },
                else => break,
            }
        }
    }

    /// VG mode's coordinates' escape (ending inline primitives) and padding (skipped).
    const vg_escape: u32 = 0xbfff0000;
    const vg_pad: u32 = 0xbfff0001;

    /// VG primitives of type `ty` (RHTs, an RHT strip, triangles, a strip, a fan) of `coords`
    /// (Xs and Ys, 12.4 fixed point from the viewport offset), continuing the last list (its last
    /// two vertices in place of their first two), drawn as a draw of their triangles. An RHT
    /// is the trapezoid between its edge and the RHT X boundary.
    fn vgPrimitives(self: *V3d, ty: u4, cont: bool, coords: []align(1) const u32) void {
        var pts: std.ArrayList([2]f32) = .empty;
        defer pts.deinit(tri_allocator);
        pts.ensureTotalCapacity(tri_allocator, coords.len) catch return;
        for (coords) |w| {
            const xs: i16 = @bitCast(@as(u16, @truncate(w)));
            const ys: i16 = @bitCast(@as(u16, @truncate(w >> 16)));
            pts.appendAssumeCapacity(.{ @as(f32, @floatFromInt(xs)) / 16 + self.cur_vp_x, @as(f32, @floatFromInt(ys)) / 16 + self.cur_vp_y });
        }
        const p = pts.items;
        if (cont) {
            for (0..@min(2, p.len)) |i| p[i] = self.vg_last[i];
        }
        const first = self.vg_verts.items.len;
        const b = self.rht_x_boundary;
        const Out = struct {
            fn tri(v: *V3d, a: [2]f32, bb: [2]f32, c: [2]f32) void {
                v.vg_verts.appendSlice(tri_allocator, &.{ a, bb, c }) catch {};
            }
            fn rht(v: *V3d, a: [2]f32, bb: [2]f32, x: f32) void {
                tri(v, a, bb, .{ x, bb[1] });
                tri(v, a, .{ x, bb[1] }, .{ x, a[1] });
            }
        };
        switch (ty) {
            1 => for (0..p.len / 2) |i| Out.rht(self, p[2 * i], p[2 * i + 1], b),
            3 => for (1..@max(p.len, 1)) |i| Out.rht(self, p[i - 1], p[i], b),
            4 => for (0..p.len / 3) |i| Out.tri(self, p[3 * i], p[3 * i + 1], p[3 * i + 2]),
            5 => for (2..@max(p.len, 2)) |i| {
                if (i & 1 == 0) Out.tri(self, p[i - 2], p[i - 1], p[i]) else Out.tri(self, p[i - 1], p[i - 2], p[i]);
            },
            6 => for (2..@max(p.len, 2)) |i| Out.tri(self, p[0], p[i - 1], p[i]),
            else => {},
        }
        if (p.len >= 2) self.vg_last = if (ty == 6) .{ p[0], p[p.len - 1] } else .{ p[p.len - 2], p[p.len - 1] };
        const n = self.vg_verts.items.len - first;
        if (n == 0) return;
        self.draws.append(tri_allocator, .{
            .kind = .vg,
            .fs_code = self.cur_fs_code,
            .fs_unifs = self.cur_fs_unifs,
            .fs_varyings = self.cur_fs_varyings,
            .mode = 4,
            .count = @intCast(n),
            .first_or_offset = @intCast(first),
            .vp_x = self.cur_vp_x,
            .vp_y = self.cur_vp_y,
            .clip_x = self.cur_clip_x,
            .clip_y = self.cur_clip_y,
            .clip_w = self.cur_clip_w,
            .clip_h = self.cur_clip_h,
            .config_b0 = self.cur_cfg0,
            .config_b1 = self.cur_cfg1,
            .config_b2 = self.cur_cfg2,
            .clip_scale_x = self.cur_clip_scale_x,
            .clip_scale_y = self.cur_clip_scale_y,
            .z_scale = self.cur_z_scale,
            .z_offset = self.cur_z_offset,
            .line_width = self.cur_line_width,
            .point_size = self.cur_point_size,
        }) catch {};
    }

    /// The length of the QPU program at `phys`: to the instruction that signals its end and the two
    /// after it (which the QPU runs too), or to the end of RAM. The QPU has no other limit.
    fn programLen(ram: []const u8, phys: u32) usize {
        if (phys >= ram.len) return 0;
        const max_insts = (ram.len - phys) / 8;
        for (0..max_insts) |i| {
            const sig = qpu.getSig(std.mem.readInt(u64, ram[phys + i * 8 ..][0..8], .little));
            if (sig == .prog_end or sig == .color_load_end) return @min(i + 3, max_insts);
        }
        return max_insts;
    }

    /// The QPU program at `phys` (see `programLen`), read into `out`; null if it is longer.
    fn readProgram(ram: []const u8, phys: u32, out: []qpu.Inst) ?[]const qpu.Inst {
        const len = programLen(ram, phys);
        if (len > out.len) return null;
        for (out[0..len], 0..) |*inst, i| inst.* = std.mem.readInt(u64, ram[phys + i * 8 ..][0..8], .little);
        return out[0..len];
    }

    /// The QPU program at `phys` (see `programLen`), read into `code` and decoded onto the end of
    /// `decoded`; null if there isn't the memory.
    fn decodeProgramAt(ram: []const u8, phys: u32, code: *std.ArrayList(qpu.Inst), decoded: *std.ArrayList(qpu_sim.DecodedInst)) ?[]const qpu_sim.DecodedInst {
        code.resize(tri_allocator, programLen(ram, phys)) catch return null;
        const read = readProgram(ram, phys, code.items).?;
        const out = decoded.addManyAsSlice(tri_allocator, read.len) catch return null;
        return qpu_sim.decodeProgram(read, out);
    }

    /// The uniforms at `phys`: as many as the QPU reads, to the end of RAM (past it, it reads 0).
    fn uniformsAt(ram: []const u8, phys: u32) qpu_sim.Uniforms {
        if (phys >= ram.len) return &.{};
        return std.mem.bytesAsSlice(u32, ram[phys..][0 .. (ram.len - phys) / 4 * 4]);
    }

    /// Pre-shades and bins triangles across all draw calls once per frame before tile loop.
    fn prepareDrawsForFrame(self: *V3d, ram: []const u8) void {
        self.shaded_tris.clearRetainingCapacity();
        self.prep_fs_insts.clearRetainingCapacity();
        self.overflow_draw_start = self.draws.items.len;
        defer self.binTriangles();
        // After the binning (deferred before it, run after it).
        const prof_start = profile.now();
        defer profile.end(.v3d_vertex_shade, prof_start);

        self.prep_draws.resize(tri_allocator, self.draws.items.len) catch {
            self.overflow_draw_start = 0;
            return;
        };
        @memset(self.prep_draws.items, .{});
        draws: for (self.draws.items, 0..) |draw, draw_idx| {
            self.prep_draws.items[draw_idx] = .{};
            if (numPrims(draw) == 0) continue;
            const src = drawSource(ram, draw) orelse continue;
            const fs_num_varyings = src.fs_num_varyings;
            const fs_code_phys = src.fs_code_phys;
            const fs_unif_phys = src.fs_unif_phys;
            const gl = switch (src.vertices) {
                .gl => |g| g,
                else => null,
            };

            // Running out of memory for a draw's shaders draws it, and those after it, as the
            // tiles are (see `overflow_draw_start`).
            self.vs_decoded.clearRetainingCapacity();
            const vs_decoded: []const qpu_sim.DecodedInst = if (gl) |g| decodeProgramAt(ram, g.vs_code_phys, &self.vs_code, &self.vs_decoded) orelse {
                self.overflow_draw_start = draw_idx;
                break;
            } else &.{};
            const fs_inst_start: u32 = @intCast(self.prep_fs_insts.items.len);
            const fs_decoded = decodeProgramAt(ram, fs_code_phys, &self.vs_code, &self.prep_fs_insts) orelse {
                self.overflow_draw_start = draw_idx;
                break;
            };
            if ((gl != null and vs_decoded.len == 0) or fs_decoded.len == 0) continue;
            const vs_unifs = if (gl) |g| uniformsAt(ram, g.vs_unif_phys) else &.{};
            const fast_frag = qpu_sim.analyzeFragmentShader(fs_decoded, uniformsAt(ram, fs_unif_phys));

            self.prep_draws.items[draw_idx] = .{
                .fs_code_phys = fs_code_phys,
                .fs_code_len = @intCast(fs_decoded.len),
                .fs_unif_phys = fs_unif_phys,
                .fs_inst_start = fs_inst_start,
                .fs_num_varyings = fs_num_varyings,
                .fast_frag = fast_frag,
                .valid = true,
            };

            const num_tris = numPrims(draw);

            // Most of a draw's triangles may be culled, or off the
            // framebuffer: only those kept count.
            const draw_start = self.shaded_tris.items.len;
            if (draw_start >= MAX_PREBINNED_TRIS) {
                self.overflow_draw_start = draw_idx;
                break;
            }
            self.shaded_tris.ensureUnusedCapacity(tri_allocator, @min(num_tris, MAX_PREBINNED_TRIS - draw_start)) catch {
                self.overflow_draw_start = draw_idx;
                break;
            };

            var attr_streams: [8]AttrStream = undefined;
            const attr_info: AttrInfo = if (gl) |g| decodeAttrStreams(ram, g.rec_phys, draw.num_attrs, g.vs_attr_mask, &attr_streams) else .{ .count = 0, .vpm_words = 0 };
            const active_attrs = attr_streams[0..attr_info.count];
            const vpm_words = attr_info.vpm_words;
            const n_var = @min(@as(usize, fs_num_varyings), 16);
            const clip_min_x: f32 = @floatFromInt(draw.clip_x);
            const clip_min_y: f32 = @floatFromInt(draw.clip_y);
            const clip_max_x: f32 = @floatFromInt(@as(u32, draw.clip_x) + draw.clip_w);
            const clip_max_y: f32 = @floatFromInt(@as(u32, draw.clip_y) + draw.clip_h);

            // Each triangle's corners, each vertex shaded once (a mesh's triangles share them),
            // then the triangles kept.
            // Their clip coordinates too, from the coordinate shader, for the clipper.
            var cs_attrs: [8]AttrStream = undefined;
            const cs = if (gl) |g| coordStage(ram, g.rec_phys, draw.num_attrs, &self.vs_code, &self.cs_decoded, &cs_attrs) else null;
            const has_clip = cs != null or switch (src.vertices) {
                .nv => |nv| nv.header and nv.clipping,
                else => false,
            };
            const shaded = self.shadeVertices(ram, draw, num_tris, vs_decoded, vs_unifs, active_attrs, vpm_words, n_var, cs, src.vertices, has_clip) orelse {
                self.overflow_draw_start = draw_idx;
                break;
            };
            for (0..num_tris) |t| {
                var tri_verts: [3]ShadedVertex = undefined;
                var tri_clip: [3]ClipVertex = @splat(.{ .x = 0, .y = 0, .z = 0, .w = std.math.nan(f32) });
                var ok = true;
                inline for (0..3) |corner| {
                    const slot = self.vs_corner_slot.items[t * 3 + corner];
                    ok = ok and self.vs_ok.items[slot];
                    tri_verts[corner] = shaded[slot];
                    if (has_clip) tri_clip[corner] = self.vs_clip.items[slot];
                }
                if (!ok) continue;

                var pieces: [max_clipped][3]ShadedVertex = undefined;
                const n_pieces = primitiveTriangles(draw, tri_verts, tri_clip, n_var, &pieces);
                for (pieces[0..n_pieces]) |verts| {
                    const area = (verts[1].x - verts[0].x) * (verts[2].y - verts[0].y) -
                        (verts[1].y - verts[0].y) * (verts[2].x - verts[0].x);
                    if (@abs(area) < 1e-6) continue;
                    if (isTriangles(draw) and culled(draw.config_b0, area)) continue;

                    const min_fx = @max(@floor(@min(verts[0].x, @min(verts[1].x, verts[2].x))), clip_min_x);
                    const min_fy = @max(@floor(@min(verts[0].y, @min(verts[1].y, verts[2].y))), clip_min_y);
                    const max_fx = @min(@ceil(@max(verts[0].x, @max(verts[1].x, verts[2].x))), clip_max_x);
                    const max_fy = @min(@ceil(@max(verts[0].y, @max(verts[1].y, verts[2].y))), clip_max_y);
                    if (min_fx >= max_fx or min_fy >= max_fy) continue;

                    if (self.shaded_tris.items.len == MAX_PREBINNED_TRIS) {
                        // This draw, and those after it, are drawn whole for each tile.
                        self.shaded_tris.shrinkRetainingCapacity(draw_start);
                        self.overflow_draw_start = draw_idx;
                        break :draws;
                    }
                    self.shaded_tris.append(tri_allocator, ShadedTriangle.init(
                        @intCast(draw_idx),
                        @intFromFloat(min_fx),
                        @intFromFloat(min_fy),
                        @intFromFloat(max_fx),
                        @intFromFloat(max_fy),
                        area,
                        verts,
                        n_var,
                    )) catch {
                        self.shaded_tris.shrinkRetainingCapacity(draw_start);
                        self.overflow_draw_start = draw_idx;
                        break :draws;
                    };
                }
            }
        }
    }

    /// A draw's fragment shader, and where its vertices come from.
    const DrawSource = struct {
        fs_code_phys: u32,
        fs_unif_phys: u32,
        /// Its varyings, the rasterizer's included.
        fs_num_varyings: u8,
        vertices: VertexSource,
    };

    const VertexSource = union(enum) {
        /// GL: the shader record's vertex shader (and coordinate shader, for the clipper).
        gl: struct { rec_phys: u32, vs_attr_mask: u8, vs_code_phys: u32, vs_unif_phys: u32 },
        /// NV: vertices shaded already.
        nv: NvSource,
        /// VG: screen coordinates (`vg_verts`).
        vg,
    };

    /// NV mode's vertices: `stride` bytes apart from `base`, each its clip coordinates first (if
    /// `header`; the clipper's if `clipping`), then as a vertex shader writes them (Xs and Ys,
    /// Zs, 1/Wc, the point size if its record says, the varyings).
    const NvSource = struct { base: u32, stride: u32, header: bool, clipping: bool };

    fn drawSource(ram: []const u8, draw: DrawCall) ?DrawSource {
        const mask = vc_bus.ramMask(ram.len);
        switch (draw.kind) {
            .gl => {
                const rec_phys = draw.shader_rec_addr & mask;
                if (rec_phys + 36 + @as(u32, draw.num_attrs) * 8 > ram.len) return null;
                return .{
                    .fs_num_varyings = ram[rec_phys + 3] +| rasterizerVaryings(draw),
                    .fs_code_phys = std.mem.readInt(u32, ram[rec_phys + 4 ..][0..4], .little) & mask,
                    .fs_unif_phys = std.mem.readInt(u32, ram[rec_phys + 8 ..][0..4], .little) & mask,
                    .vertices = .{ .gl = .{
                        .rec_phys = rec_phys,
                        .vs_attr_mask = ram[rec_phys + 14],
                        .vs_code_phys = std.mem.readInt(u32, ram[rec_phys + 16 ..][0..4], .little) & mask,
                        .vs_unif_phys = std.mem.readInt(u32, ram[rec_phys + 20 ..][0..4], .little) & mask,
                    } },
                };
            },
            .nv => {
                const rec = draw.shader_rec_addr & mask;
                if (rec + 16 > ram.len) return null;
                const flags = ram[rec];
                return .{
                    .fs_num_varyings = ram[rec + 3] +| rasterizerVaryings(draw),
                    .fs_code_phys = std.mem.readInt(u32, ram[rec + 4 ..][0..4], .little) & mask,
                    .fs_unif_phys = std.mem.readInt(u32, ram[rec + 8 ..][0..4], .little) & mask,
                    .vertices = .{ .nv = .{
                        .base = std.mem.readInt(u32, ram[rec + 12 ..][0..4], .little) & mask,
                        .stride = ram[rec + 1],
                        .header = flags & 8 != 0,
                        .clipping = flags & 4 != 0,
                    } },
                };
            },
            .vg => return .{
                .fs_num_varyings = draw.fs_varyings,
                .fs_code_phys = draw.fs_code & mask,
                .fs_unif_phys = draw.fs_unifs & mask,
                .vertices = .vg,
            },
        }
    }

    /// The vertex `index` of a draw's triangle `tri`'s `corner`, as V3D reads it (from the index
    /// buffer, for an indexed draw), or null if it is past the end of RAM.
    /// A line's ends are its first two corners, and its last corner its second end again; a
    /// point is all three.
    fn triangleCorner(ram: []const u8, draw: DrawCall, tri: u32, corner: u32) u32 {
        const end = @min(corner, 1);
        const pos: u32 = switch (draw.mode) {
            0 => tri,
            1 => tri * 2 + end,
            2 => (tri + end) % draw.count,
            3 => tri + end,
            4 => tri * 3 + corner,
            // Strips: odd triangles have their first two corners the other way round.
            5 => if (tri & 1 == 0) tri + corner else switch (corner) {
                0 => tri + 1,
                1 => tri,
                else => tri + 2,
            },
            6 => if (corner == 0) 0 else tri + corner,
            else => 0,
        };
        if (!draw.indexed) return pos + draw.first_or_offset;
        const idx_base: usize = draw.index_buffer_addr & vc_bus.ramMask(ram.len);
        if (draw.u16_indices) {
            const off = idx_base + @as(usize, pos) * 2;
            return if (off + 2 <= ram.len) std.mem.readInt(u16, ram[off..][0..2], .little) else 0;
        }
        const off = idx_base + pos;
        return if (off < ram.len) ram[off] else 0;
    }

    /// Shades each vertex of `draw`'s `num_tris` triangles once: their corners' slots go in
    /// `vs_corner_slot`, and each slot's vertex (and whether it was shaded) in the result (and
    /// `vs_ok`). Null if there isn't the memory.
    fn shadeVertices(
        self: *V3d,
        ram: []const u8,
        draw: DrawCall,
        num_tris: u32,
        vs_decoded: []const qpu_sim.DecodedInst,
        vs_unifs: qpu_sim.Uniforms,
        attrs: []const AttrStream,
        vpm_words: usize,
        n_var: usize,
        cs: ?CoordStage,
        source: VertexSource,
        has_clip: bool,
    ) ?[]const ShadedVertex {
        if (!self.collectVertices(ram, draw, num_tris)) return null;
        const unique = self.vs_unique.items;
        self.vs_out.resize(tri_allocator, unique.len) catch return null;
        self.vs_ok.resize(tri_allocator, unique.len) catch return null;
        if (has_clip) self.vs_clip.resize(tri_allocator, unique.len) catch return null;

        const job: VertexJob = .{
            .ram = ram,
            .draw = draw,
            .decoded = vs_decoded,
            .unifs = vs_unifs,
            .attrs = attrs,
            .vpm_words = vpm_words,
            .n_var = n_var,
            .indices = unique,
            .out = self.vs_out.items,
            .ok = self.vs_ok.items,
            .cs = cs,
            .clip = if (has_clip) self.vs_clip.items else &.{},
            .source = source,
            .vg_verts = self.vg_verts.items,
        };
        job.runAll();
        return self.vs_out.items;
    }

    /// Runs `job` for all its vertices, a QPU's 16 at a time, shared among threads when there are
    /// many.
    fn runVertexJob(job: *const VertexJob) void {
        const unique = job.indices;
        const batches = (unique.len + 15) / 16;
        const max_helpers = 3;
        const helpers: usize = if (unique.len < 1024) 0 else @min(max_helpers, batches / 16);
        var threads: [max_helpers]std.Thread = undefined;
        var spawned: usize = 0;
        const per = (batches + helpers) / (helpers + 1);
        for (0..helpers) |h| {
            const lo = @min((h + 1) * per, batches);
            const hi = @min((h + 2) * per, batches);
            threads[spawned] = std.Thread.spawn(.{}, VertexJob.run, .{ job, lo, hi }) catch {
                job.run(lo, hi);
                continue;
            };
            spawned += 1;
        }
        job.run(0, @min(per, batches));
        for (threads[0..spawned]) |th| th.join();
    }

    /// Whether the clipper cuts any of `draw`'s `num_tris` triangles (their vertices listed by
    /// `collectVertices`), from their clip coordinates (its shader record at `rec_phys`).
    fn needsClipping(self: *V3d, ram: []const u8, draw: DrawCall, rec_phys: u32, num_tris: u32) bool {
        var cs_attrs: [8]AttrStream = undefined;
        const cs = coordStage(ram, rec_phys, draw.num_attrs, &self.vs_code, &self.cs_decoded, &cs_attrs) orelse return false;
        const unique = self.vs_unique.items;
        self.vs_clip.resize(tri_allocator, unique.len) catch return true;
        const job: VertexJob = .{
            .ram = ram,
            .draw = draw,
            .decoded = &.{},
            .unifs = &.{},
            .attrs = &.{},
            .vpm_words = 0,
            .n_var = 0,
            .indices = unique,
            .out = &.{},
            .ok = &.{},
            .shade = false,
            .cs = cs,
            .clip = self.vs_clip.items,
        };
        job.runAll();
        for (0..num_tris) |t| {
            var c: [3]ClipVertex = undefined;
            for (&c, 0..) |*v, corner| v.* = self.vs_clip.items[self.vs_corner_slot.items[t * 3 + corner]];
            if (needsClip(draw, c)) return true;
        }
        return false;
    }

    /// Lists `draw`'s `num_tris` triangles' distinct vertices (`vs_unique`) and each corner's
    /// (`vs_corner_slot`). False if there isn't the memory.
    fn collectVertices(self: *V3d, ram: []const u8, draw: DrawCall, num_tris: u32) bool {
        const corners: usize = @as(usize, num_tris) * 3;
        self.vs_corner_slot.resize(tri_allocator, corners) catch return false;
        self.vs_unique.clearRetainingCapacity();
        self.vs_unique.ensureTotalCapacity(tri_allocator, corners) catch return false;
        if (self.vs_slot_key.items.len == 0) {
            self.vs_slot_key.resize(tri_allocator, vs_slot_count) catch return false;
            self.vs_slot_gen.resize(tri_allocator, vs_slot_count) catch return false;
            self.vs_slot_index.resize(tri_allocator, vs_slot_count) catch return false;
            @memset(self.vs_slot_gen.items, 0);
        }
        self.vs_gen +%= 1;
        if (self.vs_gen == 0) {
            @memset(self.vs_slot_gen.items, 0);
            self.vs_gen = 1;
        }
        // The distinct vertices, found by their index (in a table that forgets one when another
        // takes its place: it is then shaded twice, the same).
        for (0..num_tris) |t| {
            for (0..3) |corner| {
                const index = triangleCorner(ram, draw, @intCast(t), @intCast(corner));
                const h = index & (vs_slot_count - 1);
                if (self.vs_slot_gen.items[h] != self.vs_gen or self.vs_slot_key.items[h] != index) {
                    self.vs_slot_gen.items[h] = self.vs_gen;
                    self.vs_slot_key.items[h] = index;
                    self.vs_slot_index.items[h] = @intCast(self.vs_unique.items.len);
                    self.vs_unique.appendAssumeCapacity(index);
                }
                self.vs_corner_slot.items[t * 3 + corner] = self.vs_slot_index.items[h];
            }
        }
        return true;
    }

    /// A draw's coordinate shader: run (as the binner runs it) for its vertices' clip coordinates.
    const CoordStage = struct {
        decoded: []const qpu_sim.DecodedInst,
        unifs: qpu_sim.Uniforms,
        attrs: []const AttrStream,
        vpm_words: usize,
    };

    /// The coordinate shader of the shader record at `rec_phys` (decoded into `decoded`, reading
    /// its program with `code`), its attributes into `attrs`: null if it has none, or there isn't
    /// the memory.
    fn coordStage(ram: []const u8, rec_phys: u32, num_attrs: u8, code: *std.ArrayList(qpu.Inst), decoded: *std.ArrayList(qpu_sim.DecodedInst), attrs: *[8]AttrStream) ?CoordStage {
        const cs_attr_mask = ram[rec_phys + 26];
        const cs_code_phys = std.mem.readInt(u32, ram[rec_phys + 28 ..][0..4], .little) & vc_bus.ramMask(ram.len);
        const cs_unif_phys = std.mem.readInt(u32, ram[rec_phys + 32 ..][0..4], .little) & vc_bus.ramMask(ram.len);
        if (cs_code_phys == 0) return null;
        decoded.clearRetainingCapacity();
        const cs_decoded = decodeProgramAt(ram, cs_code_phys, code, decoded) orelse return null;
        if (cs_decoded.len == 0) return null;
        const info = decodeAttrStreams(ram, rec_phys, num_attrs, cs_attr_mask, attrs);
        return .{ .decoded = cs_decoded, .unifs = uniformsAt(ram, cs_unif_phys), .attrs = attrs[0..info.count], .vpm_words = info.vpm_words };
    }

    /// Where a draw's shaded vertices' varyings are, for `n_var` varyings in the fragment shader.
    const VertexLayout = struct {
        /// Whether the vertex shader writes each point's size, after 1/Wc.
        point_size: bool,
        /// The VPM word its varyings start at.
        first_varying: usize,
        /// The fragment shader's varyings before them (the rasterizer's).
        skip: usize,
        /// How many of them the fragment shader reads.
        varyings: usize,

        fn of(ram: []const u8, draw: DrawCall, n_var: usize) VertexLayout {
            const point_size = pointSizeWritten(ram, draw);
            const skip = @min(rasterizerVaryings(draw), n_var);
            return .{ .point_size = point_size, .first_varying = if (point_size) 4 else 3, .skip = skip, .varyings = n_var - skip };
        }
    };

    /// Vertices shaded together: `indices` into `out` and `ok`, in batches of 16.
    const VertexJob = struct {
        ram: []const u8,
        draw: DrawCall,
        decoded: []const qpu_sim.DecodedInst,
        unifs: qpu_sim.Uniforms,
        attrs: []const AttrStream,
        vpm_words: usize,
        n_var: usize,
        indices: []const u32,
        out: []ShadedVertex,
        ok: []bool,
        /// Whether the vertex shader is run (into `out` and `ok`).
        shade: bool = true,
        /// The coordinate shader, if it is run too: each vertex's clip coordinates into `clip`.
        cs: ?CoordStage = null,
        clip: []ClipVertex = &.{},
        /// Where the vertices come from: shaded here (GL), or as given (NV, VG).
        source: VertexSource = .{ .gl = undefined },
        vg_verts: []const [2]f32 = &.{},

        fn runAll(job: *const VertexJob) void {
            runVertexJob(job);
        }

        fn run(job: *const VertexJob, first_batch: usize, end_batch: usize) void {
            var b = first_batch;
            while (b < end_batch) : (b += 1) {
                const lo = b * 16;
                const hi = @min(lo + 16, job.indices.len);
                if (job.source != .gl) {
                    givenBatch(job, lo, hi);
                    continue;
                }
                if (job.cs) |cs| clipBatch(job, cs, lo, hi);
                if (job.shade) shadeBatch(job, lo, hi);
            }
        }

        /// Vertices `lo` to `hi`, as NV or VG mode gives them.
        fn givenBatch(job: *const VertexJob, lo: usize, hi: usize) void {
            const ram = job.ram;
            const no_clip: ClipVertex = .{ .x = 0, .y = 0, .z = 0, .w = std.math.nan(f32) };
            for (lo..hi) |i| {
                const index = job.indices[i];
                var v: ShadedVertex = .{ .point_size = job.draw.point_size };
                var c = no_clip;
                var ok = true;
                switch (job.source) {
                    .gl => unreachable,
                    .vg => {
                        if (index < job.vg_verts.len) {
                            v.x = job.vg_verts[index][0];
                            v.y = job.vg_verts[index][1];
                        } else ok = false;
                    },
                    .nv => |nv| {
                        const layout: VertexLayout = .of(ram, job.draw, job.n_var);
                        const words = (if (nv.header) @as(usize, 4) else 0) + layout.first_varying + layout.varyings;
                        const off: usize = @as(usize, nv.base) + @as(usize, index) * nv.stride;
                        if (off + words * 4 > ram.len) {
                            ok = false;
                        } else {
                            const w = struct {
                                fn at(r: []const u8, o: usize, k: usize) u32 {
                                    return std.mem.readInt(u32, r[o + k * 4 ..][0..4], .little);
                                }
                            }.at;
                            var k: usize = 0;
                            if (nv.header) {
                                if (nv.clipping) c = .{ .x = @bitCast(w(ram, off, 0)), .y = @bitCast(w(ram, off, 1)), .z = @bitCast(w(ram, off, 2)), .w = @bitCast(w(ram, off, 3)) };
                                k = 4;
                            }
                            const xy = w(ram, off, k);
                            const xs: i16 = @bitCast(@as(u16, @truncate(xy)));
                            const ys: i16 = @bitCast(@as(u16, @truncate(xy >> 16)));
                            v.x = @as(f32, @floatFromInt(xs)) * (1.0 / 16.0) + job.draw.vp_x;
                            v.y = @as(f32, @floatFromInt(ys)) * (1.0 / 16.0) + job.draw.vp_y;
                            v.z = @bitCast(w(ram, off, k + 1));
                            const raw_inv_w: f32 = @bitCast(w(ram, off, k + 2));
                            v.inv_w = if (raw_inv_w == 0.0) 1.0 else raw_inv_w;
                            if (layout.point_size) v.point_size = @bitCast(w(ram, off, k + 3));
                            for (0..layout.varyings) |vi| {
                                const raw_v: f32 = @bitCast(w(ram, off, k + layout.first_varying + vi));
                                v.persp_varyings[layout.skip + vi] = raw_v * v.inv_w;
                            }
                        }
                    },
                }
                if (job.out.len > 0) {
                    job.out[i] = v;
                    job.ok[i] = ok;
                }
                if (job.clip.len > 0) job.clip[i] = c;
            }
        }

        /// The clip coordinates of vertices `lo` to `hi` (a batch), from the coordinate shader.
        fn clipBatch(job: *const VertexJob, cs: CoordStage, lo: usize, hi: usize) void {
            var vpm_in: [32]qpu_sim.Vec = undefined;
            populateBatchVpmIn(job.ram, cs.attrs, job.indices[lo..hi], &vpm_in);
            const res = qpu_sim.runDecoded(cs.decoded, .{ .uniforms = cs.unifs, .vpm_in = vpm_in[0..cs.vpm_words] }) catch {
                @memset(job.clip[lo..hi], .{ .x = 0, .y = 0, .z = 0, .w = std.math.nan(f32) });
                return;
            };
            for (lo..hi) |i| {
                const lane = i - lo;
                job.clip[i] = if (res.vpm_out_len < 4) .{ .x = 0, .y = 0, .z = 0, .w = std.math.nan(f32) } else .{
                    .x = @bitCast(res.vpm_out[0][lane]),
                    .y = @bitCast(res.vpm_out[1][lane]),
                    .z = @bitCast(res.vpm_out[2][lane]),
                    .w = @bitCast(res.vpm_out[3][lane]),
                };
            }
        }

        /// Vertices `lo` to `hi` (a batch), shaded.
        fn shadeBatch(job: *const VertexJob, lo: usize, hi: usize) void {
            {
                var vpm_in: [32]qpu_sim.Vec = undefined;
                populateBatchVpmIn(job.ram, job.attrs, job.indices[lo..hi], &vpm_in);
                const res = qpu_sim.runDecoded(job.decoded, .{
                    .uniforms = job.unifs,
                    .vpm_in = vpm_in[0..job.vpm_words],
                }) catch {
                    @memset(job.ok[lo..hi], false);
                    return;
                };
                const layout: VertexLayout = .of(job.ram, job.draw, job.n_var);
                if (res.vpm_out_len < layout.first_varying) {
                    @memset(job.ok[lo..hi], false);
                    return;
                }
                const valid_vars = @min(layout.varyings, res.vpm_out_len - layout.first_varying);
                for (lo..hi) |i| {
                    const lane = i - lo;
                    var v: ShadedVertex = .{};
                    const xy_packed = res.vpm_out[0][lane];
                    const xs: i16 = @bitCast(@as(u16, @truncate(xy_packed)));
                    const ys: i16 = @bitCast(@as(u16, @truncate(xy_packed >> 16)));
                    v.x = @as(f32, @floatFromInt(xs)) * (1.0 / 16.0) + job.draw.vp_x;
                    v.y = @as(f32, @floatFromInt(ys)) * (1.0 / 16.0) + job.draw.vp_y;
                    v.z = @bitCast(res.vpm_out[1][lane]);
                    const raw_inv_w: f32 = @bitCast(res.vpm_out[2][lane]);
                    const inv_w = if (raw_inv_w == 0.0) 1.0 else raw_inv_w;
                    v.inv_w = inv_w;
                    v.point_size = if (layout.point_size) @bitCast(res.vpm_out[3][lane]) else job.draw.point_size;
                    for (0..valid_vars) |vi| {
                        const raw_v: f32 = @bitCast(res.vpm_out[layout.first_varying + vi][lane]);
                        v.persp_varyings[layout.skip + vi] = raw_v * inv_w;
                    }
                    job.out[i] = v;
                    job.ok[i] = true;
                }
            }
        }
    };

    const vs_slot_count = 65536;

    /// What the frame's triangles and their tiles are kept in.
    const tri_allocator = std.heap.smp_allocator;

    /// The least W the clipper keeps: the near plane (W is 0 at the eye, and negative behind it).
    const clip_min_w: f32 = 1e-5;
    /// How far from the viewport offset the clipper keeps screen coordinates, in 16ths of a pixel:
    /// the guard band (a pixel within the 16 bits of 12.4 fixed point they are written in).
    const guard_band: f32 = 2047 * 16;
    /// The most triangles the clipper cuts one into (with up to 8 corners, cut by 5 planes).
    pub const max_clipped = 6;

    /// Whether the clipper cuts a triangle whose corners have clip coordinates `c`: one is behind
    /// the near plane, or outside the guard band (where its screen coordinates wrap around).
    fn needsClip(draw: DrawCall, c: [3]ClipVertex) bool {
        for (c) |v| {
            // Without a coordinate shader's, drawn as the vertex shader puts it.
            if (std.math.isNan(v.w)) return false;
            if (!(v.w >= clip_min_w)) return true;
            if (@abs(v.x * draw.clip_scale_x) > guard_band * v.w or @abs(v.y * draw.clip_scale_y) > guard_band * v.w) return true;
        }
        return false;
    }

    /// The triangles that the triangle `verts` (its clip coordinates `c`) is drawn as, into `out`:
    /// itself, or what is left of it when the clipper cuts it at the near plane and the guard band,
    /// as a fan (none if nothing is). The clipper places the corners it makes by its scaling, and
    /// interpolates their varyings in clip space; the others are as the vertex shader shaded them.
    pub fn clipTriangle(draw: DrawCall, verts: [3]ShadedVertex, c: [3]ClipVertex, n_var: usize, out: *[max_clipped][3]ShadedVertex) usize {
        if (!needsClip(draw, c)) {
            out[0] = verts;
            return 1;
        }
        // A corner: its clip coordinates (x, y, z, w), varyings (not divided by W), and which of
        // the triangle's it is, if it is one.
        const Corner = struct { c: @Vector(4, f32), raw: [16]f32, orig: ?u2 };
        var poly: [9]Corner = undefined;
        var next: [9]Corner = undefined;
        var n: usize = 3;
        for (0..3) |i| {
            poly[i] = .{ .c = .{ c[i].x, c[i].y, c[i].z, c[i].w }, .raw = @splat(0), .orig = @intCast(i) };
            for (0..n_var) |k| poly[i].raw[k] = verts[i].persp_varyings[k] / verts[i].inv_w;
        }
        for (clipPlanes(draw)) |pl| {
            const normal: @Vector(4, f32) = pl[0..4].*;
            var m: usize = 0;
            for (0..n) |i| {
                const p = poly[i];
                const q = poly[(i + 1) % n];
                const dp = @reduce(.Add, p.c * normal) + pl[4];
                const dq = @reduce(.Add, q.c * normal) + pl[4];
                if (dp >= 0) {
                    next[m] = p;
                    m += 1;
                }
                if ((dp >= 0) != (dq >= 0)) {
                    const t = dp / (dp - dq);
                    var cut: Corner = .{ .c = p.c + (q.c - p.c) * @as(@Vector(4, f32), @splat(t)), .raw = @splat(0), .orig = null };
                    for (0..n_var) |k| cut.raw[k] = p.raw[k] + (q.raw[k] - p.raw[k]) * t;
                    next[m] = cut;
                    m += 1;
                }
            }
            n = m;
            if (n < 3) return 0;
            @memcpy(poly[0..n], next[0..n]);
        }
        var shaded: [9]ShadedVertex = undefined;
        for (poly[0..n], shaded[0..n]) |corner, *v| {
            v.* = if (corner.orig) |i| verts[i] else clippedVertex(draw, corner.c, &corner.raw, n_var);
        }
        for (0..n - 2) |k| out[k] = .{ shaded[0], shaded[k + 1], shaded[k + 2] };
        return n - 2;
    }

    /// The planes the clipper cuts at, each as (x, y, z, w, 1) dotted with it: >= 0 is kept.
    fn clipPlanes(draw: DrawCall) [5][5]f32 {
        const g = guard_band;
        return .{
            .{ 0, 0, 0, 1, -clip_min_w },
            .{ -draw.clip_scale_x, 0, 0, g, 0 },
            .{ draw.clip_scale_x, 0, 0, g, 0 },
            .{ 0, -draw.clip_scale_y, 0, g, 0 },
            .{ 0, draw.clip_scale_y, 0, g, 0 },
        };
    }

    /// A vertex the clipper makes at clip coordinates `c` (x, y, z, w), with varyings `raw` (not
    /// divided by W): placed on screen by its scaling.
    fn clippedVertex(draw: DrawCall, c: @Vector(4, f32), raw: *const [16]f32, n_var: usize) ShadedVertex {
        const inv_w = 1.0 / c[3];
        var v: ShadedVertex = .{
            .x = c[0] * inv_w * draw.clip_scale_x * (1.0 / 16.0) + draw.vp_x,
            .y = c[1] * inv_w * draw.clip_scale_y * (1.0 / 16.0) + draw.vp_y,
            .z = c[2] * inv_w * draw.z_scale + draw.z_offset,
            .inv_w = inv_w,
        };
        for (0..n_var) |k| v.persp_varyings[k] = raw[k] * inv_w;
        return v;
    }

    /// Whether `draw` draws lines (and a loop, or a strip, of them).
    fn isLines(draw: DrawCall) bool {
        return draw.mode >= 1 and draw.mode <= 3;
    }

    /// Whether `draw` draws triangles (and a strip, or a fan, of them), not points or lines.
    fn isTriangles(draw: DrawCall) bool {
        return draw.mode >= 4;
    }

    /// The varyings the rasterizer gives the fragment shader before the vertex shader's (which the
    /// shader record doesn't count): a point's coordinates across it (s, then t), or a line's along
    /// it.
    fn rasterizerVaryings(draw: DrawCall) u8 {
        return if (draw.mode == 0) 2 else if (isLines(draw)) 1 else 0;
    }

    /// Whether the vertex shader writes each point's size (after 1/Wc), as its shader record says.
    fn pointSizeWritten(ram: []const u8, draw: DrawCall) bool {
        if (draw.mode != 0 or draw.kind == .vg) return false;
        const rec = draw.shader_rec_addr & vc_bus.ramMask(ram.len);
        return rec < ram.len and ram[rec] & 2 != 0;
    }

    /// How many points, lines, or triangles `draw` draws.
    fn numPrims(draw: DrawCall) u32 {
        return switch (draw.mode) {
            0 => draw.count,
            1 => draw.count / 2,
            2 => if (draw.count >= 2) draw.count else 0,
            3 => if (draw.count >= 2) draw.count - 1 else 0,
            4 => draw.count / 3,
            5, 6 => if (draw.count >= 3) draw.count - 2 else 0,
            else => 0,
        };
    }

    /// The triangles one of `draw`'s primitives is drawn as, into `out`: a triangle clipped
    /// (`clipTriangle`), a line (its ends the first two of `verts`) clipped and made a quad
    /// (`lineQuad`), or a point made a square (`pointQuad`). `n_var` counts the rasterizer's
    /// varyings, which are set here.
    pub fn primitiveTriangles(draw: DrawCall, verts: [3]ShadedVertex, c: [3]ClipVertex, n_var: usize, out: *[max_clipped][3]ShadedVertex) usize {
        if (isTriangles(draw)) return clipTriangle(draw, verts, c, n_var, out);
        if (!isLines(draw)) {
            // Points whose middles the clipper cuts aren't drawn.
            if (needsClip(draw, c)) return 0;
            return pointQuad(verts[0], out);
        }
        var ends: [2]ShadedVertex = .{ verts[0], verts[1] };
        // Its coordinate along it, from 0 to 1 (clipped with its varyings).
        ends[0].persp_varyings[0] = 0;
        ends[1].persp_varyings[0] = ends[1].inv_w;
        if (needsClip(draw, c)) {
            if (!clipLine(draw, &ends, .{ c[0], c[1] }, n_var)) return 0;
        }
        return lineQuad(draw, ends, out);
    }

    /// Cuts the line `ends` (their clip coordinates `c`) at the near plane and the guard band, as
    /// the clipper does: false if none of it is left.
    fn clipLine(draw: DrawCall, ends: *[2]ShadedVertex, c: [2]ClipVertex, n_var: usize) bool {
        const p: @Vector(4, f32) = .{ c[0].x, c[0].y, c[0].z, c[0].w };
        const q: @Vector(4, f32) = .{ c[1].x, c[1].y, c[1].z, c[1].w };
        // What's kept of the line, from p (0) to q (1).
        var t0: f32 = 0;
        var t1: f32 = 1;
        for (clipPlanes(draw)) |pl| {
            const normal: @Vector(4, f32) = pl[0..4].*;
            const dp = @reduce(.Add, p * normal) + pl[4];
            const dq = @reduce(.Add, q * normal) + pl[4];
            if (dp < 0 and dq < 0) return false;
            if (dp < 0) t0 = @max(t0, dp / (dp - dq));
            if (dq < 0) t1 = @min(t1, dp / (dp - dq));
        }
        if (!(t0 < t1)) return false;
        var raw: [2][16]f32 = @splat(@splat(0));
        for (0..2) |e| {
            for (0..n_var) |k| raw[e][k] = ends[e].persp_varyings[k] / ends[e].inv_w;
        }
        for ([2]f32{ t0, t1 }, [2]bool{ t0 > 0, t1 < 1 }, 0..) |t, cut, e| {
            if (!cut) continue;
            var r: [16]f32 = @splat(0);
            for (0..n_var) |k| r[k] = raw[0][k] + (raw[1][k] - raw[0][k]) * t;
            ends[e] = clippedVertex(draw, p + (q - p) * @as(@Vector(4, f32), @splat(t)), &r, n_var);
        }
        return true;
    }

    /// The two triangles a point at `v` is drawn as: a square `v.point_size` wide, its coordinates
    /// across it (its first two varyings) from 0 at the left and top to 1 at the right and bottom.
    /// None if it has no size.
    fn pointQuad(v: ShadedVertex, out: *[max_clipped][3]ShadedVertex) usize {
        if (!(v.point_size > 0)) return 0;
        const half = v.point_size * 0.5;
        var corners: [4]ShadedVertex = @splat(v);
        for (&corners, [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }) |*c, st| {
            c.x += (st[0] * 2 - 1) * half;
            c.y += (st[1] * 2 - 1) * half;
            c.persp_varyings[0] = st[0] * v.inv_w;
            c.persp_varyings[1] = st[1] * v.inv_w;
        }
        out[0] = .{ corners[0], corners[1], corners[2] };
        out[1] = .{ corners[0], corners[2], corners[3] };
        return 2;
    }

    /// The two triangles a line from `ends[0]` to `ends[1]` is drawn as: `draw.line_width` wide
    /// across the axis it runs along least (as OpenGL draws lines without antialiasing), its
    /// varyings those of its nearer end along it. None if it has no length.
    fn lineQuad(draw: DrawCall, ends: [2]ShadedVertex, out: *[max_clipped][3]ShadedVertex) usize {
        const a = ends[0];
        const b = ends[1];
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        if (dx == 0 and dy == 0) return 0;
        const half = @max(draw.line_width, 1) * 0.5;
        const ox: f32 = if (@abs(dx) >= @abs(dy)) 0 else half;
        const oy: f32 = if (@abs(dx) >= @abs(dy)) half else 0;
        var a0 = a;
        var a1 = a;
        var b0 = b;
        var b1 = b;
        a0.x -= ox;
        a0.y -= oy;
        a1.x += ox;
        a1.y += oy;
        b0.x -= ox;
        b0.y -= oy;
        b1.x += ox;
        b1.y += oy;
        out[0] = .{ a0, b0, b1 };
        out[1] = .{ a0, b1, a1 };
        return 2;
    }

    /// Whether the configuration bits `cfg0` cull a triangle whose screen area
    /// (`y` down) is `area`: those with a positive area face forward, or with
    /// a negative one if bit 2 ("clockwise") is set, as it is for OpenGL's
    /// anticlockwise triangles drawn with `y` flipped (Mesa's vc4); bit 0
    /// draws those facing forward, and bit 1 those facing back.
    fn facesForward(cfg0: u8, area: f32) bool {
        return if (cfg0 & 4 != 0) area < 0 else area > 0;
    }

    fn culled(cfg0: u8, area: f32) bool {
        const forward = facesForward(cfg0, area);
        return (if (forward) cfg0 & 1 else cfg0 & 2) == 0;
    }

    /// Lists each 64-pixel tile's triangles (`tile_tris`), in draw order. If
    /// there is no room for the lists, no triangle is binned: the draws are
    /// all shaded again for each tile.
    fn binTriangles(self: *V3d) void {
        const prof_start = profile.now();
        defer profile.end(.v3d_tile_bin, prof_start);
        const Range = struct {
            fn of(t: *const ShadedTriangle) [4]u32 {
                return .{ @min(t.min_x >> 6, 31), @min(t.min_y >> 6, 31), @min((t.max_x - 1) >> 6, 31), @min((t.max_y - 1) >> 6, 31) };
            }

            /// Whether `t` may cover a pixel of tile (`tx`, `ty`), of those its bounds `r` cross:
            /// none, if all the tile's pixel centres are outside one of its edges (as a thin
            /// triangle across the screen is of most tiles its bounds cross).
            fn touches(t: *const ShadedTriangle, r: [4]u32, tx: usize, ty: usize) bool {
                if ((r[0] == r[2] and r[1] == r[3]) or !t.setup_valid) return true;
                const x0: f32 = @floatFromInt(tx * 64);
                const y0: f32 = @floatFromInt(ty * 64);
                inline for (.{ t.edge0, t.edge1, t.edge2 }) |e| {
                    // A hundredth of a pixel's slack, for rounding.
                    const slack = 0.01 * (@abs(e.dx) + @abs(e.dy));
                    var outside = true;
                    for ([2]f32{ y0 + 0.5, y0 + 63.5 }) |fy| {
                        const row = e.dx * (fy - e.p0y);
                        for ([2]f32{ x0 + 0.5, x0 + 63.5 }) |fx| {
                            if (e.eval(row, fx) >= -slack) outside = false;
                        }
                    }
                    if (outside) return false;
                }
                return true;
            }
        };
        // Each triangle's tiles, in draw order, then each tile's triangles.
        self.bin_pairs.clearRetainingCapacity();
        var counts: [32 * 32]u32 = @splat(0);
        for (self.shaded_tris.items, 0..) |*t, i| {
            const r = Range.of(t);
            self.bin_pairs.ensureUnusedCapacity(tri_allocator, (r[2] - r[0] + 1) * (r[3] - r[1] + 1)) catch return self.binNone();
            for (r[1]..r[3] + 1) |ty| {
                for (r[0]..r[2] + 1) |tx| {
                    if (!Range.touches(t, r, tx, ty)) continue;
                    const tile: u16 = @intCast(ty * 32 + tx);
                    self.bin_pairs.appendAssumeCapacity(.{ .tri = @intCast(i), .tile = tile });
                    counts[tile] += 1;
                }
            }
        }
        var total: u32 = 0;
        for (counts, 0..) |c, i| {
            self.tile_tri_start[i] = total;
            total += c;
        }
        self.tile_tri_start[counts.len] = total;
        self.tile_tris.resize(tri_allocator, total) catch return self.binNone();
        var next = self.tile_tri_start;
        for (self.bin_pairs.items) |pair| {
            self.tile_tris.items[next[pair.tile]] = pair.tri;
            next[pair.tile] += 1;
        }
    }

    /// Bins no triangle: the draws are all shaded again for each tile.
    fn binNone(self: *V3d) void {
        self.shaded_tris.clearRetainingCapacity();
        self.tile_tri_start = @splat(0);
        self.overflow_draw_start = 0;
    }

    const AttrStream = struct {
        base: u32,
        stride: u32,
        words: u32,
    };

    const AttrInfo = struct { count: usize, vpm_words: usize };

    fn decodeAttrStreams(
        ram: []const u8,
        rec_phys: u32,
        num_attrs: u8,
        vs_attr_mask: u8,
        out: *[8]AttrStream,
    ) AttrInfo {
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
        /// Each pixel's (or sample's) stencil, valid with `depth`.
        stencil: *[64 * 64]u8,
        /// Each pixel's VG (alpha) mask, if `vg_valid` (else the clear value).
        vg_mask: *[64 * 64]u8,
        vg_valid: bool = false,
        color_solid: ?u32 = null,
        depth_valid: bool = false,
        clear_zs: f32 = 1.0,
        clear_stencil: u8 = 0,
        clear_vg_mask: u8 = 0,
        lazy_load: ?LazyTileLoad = null,
        loaded_from: ?LazyTileLoad = null,
        modified: bool = false,
        /// 4x multisampled: the tile is 32 pixels square, each pixel's 4 samples together
        /// (`(y * 32 + x) * 4 + sample`), in `color` and `depth`.
        ms: bool = false,
    };

    pub const TileJob = struct {
        tile_x: u32,
        tile_y: u32,
        clear_color0: u32,
        clear_zs: f32,
        clear_stencil: u8 = 0,
        clear_vg_mask: u8 = 0,
        lazy_load: ?LazyTileLoad = null,
        has_render: bool = false,
        /// What's stored (STORE_TILE_BUFFER_GENERAL's buffer): colour (1), depth and stencil (2),
        /// depth (3), the VG mask (4), or all of it as it is (5, less what `dump_flags` leaves
        /// out: bit 0 colour, 1 depth and stencil, 2 the VG mask).
        buffer: u3 = 1,
        dump_flags: u3 = 0,
        /// Colour stores' decimation: 0 the first sample, 1 4x, 2 16x.
        decimate: u2 = 0,
        /// Depth and stencil, and the VG mask, loaded first.
        zs_load: ?GeneralLoad = null,
        vg_load: ?GeneralLoad = null,
        /// Tile lists (not the binner's) rendered, after the frame binned (if `has_render`).
        tile_lists: [4]u32 = undefined,
        n_lists: u8 = 0,
        dst_addr: u32 = 0,
        fb_w: u32 = 0,
        fb_h: u32 = 0,
        tiling: u2 = 0,
        ls_format: u2 = 0,
        /// 4x multisampled (TILE_RENDERING_MODE_CONFIG): tiles are 32 pixels.
        ms: bool = false,
        /// Multisampled, each pixel stored as its samples averaged (decimated 4x), not sample 0.
        resolve: bool = true,
        /// Stored as the tile buffer is (STORE_FULL_RES_TILE_BUFFER), its flags: not the colour
        /// (bit 0), not depth and stencil (bit 1).
        full_res: ?u4 = null,

        pub fn tileSize(j: TileJob) u32 {
            return if (j.ms) 32 else 64;
        }
    };

    const WorkerCtx = struct {
        v3d: *const V3d,
        ram: []u8,
        jobs: []const TileJob,
        next_idx: *std.atomic.Value(usize),

        fn run(ctx: *const WorkerCtx) void {
            var color_buf: [64 * 64]u32 = undefined;
            var depth_buf: [64 * 64]f32 = undefined;
            var stencil_buf: [64 * 64]u8 = undefined;
            var vg_buf: [64 * 64]u8 = undefined;
            var tb = TileBuffer{
                .color = &color_buf,
                .depth = &depth_buf,
                .stencil = &stencil_buf,
                .vg_mask = &vg_buf,
            };
            while (true) {
                const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                if (idx >= ctx.jobs.len) break;
                ctx.v3d.executeTileJob(&tb, ctx.ram, ctx.jobs[idx]);
            }
        }
    };

    /// A load of depth and stencil (`kind` 2, or 3 depth alone; or 5 as the tile buffer holds
    /// them), or of the VG mask (4; or 5 as the tile buffer holds it).
    pub const GeneralLoad = struct { addr: u32, tiling: u2 = 0, kind: u3 };

    const PendingTileLoad = struct {
        addr: u32,
        tiling: u2,
        format: u2,
        full_res: bool = false,
    };

    inline fn tileBuf(self: *V3d) TileBuffer {
        return .{
            .color = &self.tile_color,
            .depth = &self.tile_depth,
            .stencil = &self.tile_stencil,
            .vg_mask = &self.tile_vg_mask,
            .vg_valid = self.tile_vg_valid,
            .color_solid = self.tile_color_solid,
            .depth_valid = self.tile_depth_valid,
            .clear_zs = self.tile_clear_zs,
            .clear_stencil = self.tile_clear_stencil,
            .clear_vg_mask = self.tile_clear_vg_mask,
            .lazy_load = self.lazy_load,
            .loaded_from = self.loaded_from,
            .modified = self.tile_modified,
        };
    }

    inline fn syncFromTileBuf(self: *V3d, tb: *const TileBuffer) void {
        self.tile_color_solid = tb.color_solid;
        self.tile_depth_valid = tb.depth_valid;
        self.tile_clear_zs = tb.clear_zs;
        self.tile_clear_stencil = tb.clear_stencil;
        self.tile_clear_vg_mask = tb.clear_vg_mask;
        self.tile_vg_valid = tb.vg_valid;
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
        const tile_size = job.tileSize();
        tb.ms = job.ms;
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
        tb.clear_stencil = job.clear_stencil;
        tb.clear_vg_mask = job.clear_vg_mask;
        tb.vg_valid = false;
        tb.modified = false;
        if (job.zs_load) |l| loadZs(tb, ram, job, l);
        if (job.vg_load) |l| loadVgMask(tb, ram, job, l);

        if (job.has_render) {
            self.renderDrawsIntoTileBuf(tb, ram, job.tile_x * tile_size, job.tile_y * tile_size, tile_size);
        }
        for (job.tile_lists[0..job.n_lists]) |list| self.renderTileList(tb, ram, list, job.tile_x * tile_size, job.tile_y * tile_size, tile_size);

        switch (job.buffer) {
            2, 3 => {
                ensureTileMaterializedBuf(tb, ram, true);
                storeZs(tb, ram, job, job.buffer == 3);
                return;
            },
            4 => {
                ensureVgMask(tb);
                storeVgMask(tb, ram, job);
                return;
            },
            5 => {
                ensureTileMaterializedBuf(tb, ram, true);
                ensureVgMask(tb);
                storeDump(tb, ram, job.dst_addr, job.dump_flags);
                return;
            },
            else => {},
        }
        if (job.decimate != 0 and (job.decimate == 2 or !tb.ms)) {
            ensureTileMaterializedBuf(tb, ram, false);
            storeDecimated(tb, ram, job);
            return;
        }

        if (job.full_res) |flags| {
            ensureTileMaterializedBuf(tb, ram, flags & 2 == 0);
            storeFullRes(tb, ram, job.dst_addr, flags);
            return;
        }
        if (!canSkipUnmodifiedStoreBuf(tb, job.dst_addr, job.fb_w, job.fb_h, job.tile_x, job.tile_y, tile_size, job.tiling, job.ls_format)) {
            if (tb.lazy_load) |ll| {
                // Not drawn into: stored as loaded, its pixels (each sample of one the same).
                if (!ll.full_res) {
                    tb.lazy_load = null;
                    loadTileIntoBuf(tb, ram, ll.addr, ll.fb_w, ll.fb_h, ll.tile_x, ll.tile_y, ll.tile_size, ll.tiling, ll.format);
                    tb.color_solid = null;
                    storeTileFromBuf(tb, ram, job.dst_addr, job.fb_w, job.fb_h, job.tile_x, job.tile_y, tile_size, job.tiling, job.ls_format);
                    return;
                }
                ensureTileMaterializedBuf(tb, ram, false);
            }
            if (tb.ms and tb.color_solid == null) {
                // Each pixel's samples averaged, or its first.
                var pixels: [64 * 64]u32 = undefined;
                var depth: [64 * 64]f32 = undefined;
                for (pixels[0 .. 32 * 32], 0..) |*px, i| {
                    const samples = tb.color[i * 4 ..][0..4];
                    px.* = if (job.resolve) averageSamples(samples.*) else samples[0];
                }
                const resolved: TileBuffer = .{ .color = &pixels, .depth = &depth, .stencil = tb.stencil, .vg_mask = tb.vg_mask };
                storeTileFromBuf(&resolved, ram, job.dst_addr, job.fb_w, job.fb_h, job.tile_x, job.tile_y, tile_size, job.tiling, job.ls_format);
                return;
            }
            storeTileFromBuf(tb, ram, job.dst_addr, job.fb_w, job.fb_h, job.tile_x, job.tile_y, tile_size, job.tiling, job.ls_format);
        }
    }

    /// A pixel's colour from its 4 samples' (each channel's bytes averaged, rounded).
    fn averageSamples(samples: [4]u32) u32 {
        const v: @Vector(4, u32) = samples;
        var out: u32 = 0;
        inline for (0..4) |c| {
            const shift: u5 = c * 8;
            const sum = @reduce(.Add, (v >> @splat(shift)) & @as(@Vector(4, u32), @splat(0xff)));
            out |= ((sum + 2) / 4) << shift;
        }
        return out;
    }

    /// The bytes a tile buffer is stored as by STORE_FULL_RES_TILE_BUFFER, and loaded from: each
    /// of its 64 * 64 entries (pixels, or a multisampled tile's samples), 4 bytes each.
    const full_res_bytes = 64 * 64 * 4;

    /// Stores the tile buffer as it is at `addr`: its colours (unless `flags` bit 0), or its depths
    /// (unless bit 1) as 24-bit Z above 8-bit stencil.
    fn storeFullRes(tb: *const TileBuffer, ram: []u8, addr: u32, flags: u4) void {
        const base = addr & vc_bus.ramMask(ram.len);
        if (base + full_res_bytes > ram.len) return;
        const out = ram[base..][0..full_res_bytes];
        if (flags & 1 == 0) {
            @memcpy(out, std.mem.sliceAsBytes(tb.color));
        } else if (flags & 2 == 0) {
            for (tb.depth, tb.stencil, 0..) |z, st, i| {
                const z24: u32 = @intFromFloat(@round(std.math.clamp(z, 0, 1) * 16777215.0));
                std.mem.writeInt(u32, out[i * 4 ..][0..4], z24 << 8 | st, .little);
            }
        }
    }

    /// Loads depths into the tile buffer as `storeFullRes` stored them at `addr`.
    fn loadFullResDepth(tb: *TileBuffer, ram: []const u8, addr: u32) void {
        const base = addr & vc_bus.ramMask(ram.len);
        if (base + full_res_bytes > ram.len) return;
        for (tb.depth, tb.stencil, 0..) |*z, *st, i| {
            const word = std.mem.readInt(u32, ram[base + i * 4 ..][0..4], .little);
            z.* = @as(f32, @floatFromInt(word >> 8)) / 16777215.0;
            st.* = @truncate(word);
        }
        tb.depth_valid = true;
    }

    /// Each pixel's depth and stencil (its first sample's) as a word: depth in bits 31:8, the
    /// stencil (unless `z_only`) in bits 7:0.
    fn zsWord(tb: *const TileBuffer, i: usize, z_only: bool) u32 {
        const z24: u32 = @intFromFloat(@round(std.math.clamp(tb.depth[i], 0, 1) * 16777215.0));
        return z24 << 8 | (if (z_only) 0 else tb.stencil[i]);
    }

    /// The tile's depths and stencils stored (STORE_TILE_BUFFER_GENERAL's depth and stencil, or
    /// depth alone): an image of words, as colour images are laid out.
    fn storeZs(tb: *const TileBuffer, ram: []u8, job: TileJob, z_only: bool) void {
        const size = job.tileSize();
        const spp: usize = if (tb.ms) 4 else 1;
        var words: [64 * 64]u32 = undefined;
        for (0..size * size) |i| words[i] = zsWord(tb, i * spp, z_only);
        const image: TileBuffer = .{ .color = &words, .depth = tb.depth, .stencil = tb.stencil, .vg_mask = tb.vg_mask };
        storeTileFromBuf(&image, ram, job.dst_addr, job.fb_w, job.fb_h, job.tile_x, job.tile_y, size, job.tiling, 0);
    }

    /// Depths and stencils loaded from an image as `storeZs` stores it (or, `kind` 5, as
    /// `storeDump` dumps them).
    fn loadZs(tb: *TileBuffer, ram: []const u8, job: TileJob, l: GeneralLoad) void {
        if (l.kind == 5) {
            loadFullResDepth(tb, ram, l.addr);
            return;
        }
        const size = job.tileSize();
        var words: [64 * 64]u32 = undefined;
        var image: TileBuffer = .{ .color = &words, .depth = tb.depth, .stencil = tb.stencil, .vg_mask = tb.vg_mask };
        @memset(&words, 0);
        loadTileIntoBuf(&image, ram, l.addr, job.fb_w, job.fb_h, job.tile_x, job.tile_y, size, l.tiling, 0);
        const spp: usize = if (tb.ms) 4 else 1;
        for (0..size * size) |i| {
            for (0..spp) |si| {
                tb.depth[i * spp + si] = @as(f32, @floatFromInt(words[i] >> 8)) / 16777215.0;
                tb.stencil[i * spp + si] = if (l.kind == 3) tb.clear_stencil else @truncate(words[i]);
            }
        }
        tb.depth_valid = true;
    }

    fn ensureVgMask(tb: *TileBuffer) void {
        if (tb.vg_valid) return;
        @memset(tb.vg_mask, tb.clear_vg_mask);
        tb.vg_valid = true;
    }

    /// Where pixel (`x`, `y`) of a `w` by `h` image of bytes is, laid out as `tiling` says.
    fn byteImageOffset(tiling: u2, w: u32, h: u32, x: u32, y: u32) u32 {
        return if (tiling == 0) y * w + x else texture.texelOffsetOf(.a8, w, h, x, y);
    }

    /// The tile's VG mask stored: an image of bytes.
    fn storeVgMask(tb: *const TileBuffer, ram: []u8, job: TileJob) void {
        const size = job.tileSize();
        const base = job.dst_addr & vc_bus.ramMask(ram.len);
        const x0 = job.tile_x * size;
        const y0 = job.tile_y * size;
        for (0..size) |ty| {
            for (0..size) |tx| {
                const x = x0 + @as(u32, @intCast(tx));
                const y = y0 + @as(u32, @intCast(ty));
                if (x >= job.fb_w or y >= job.fb_h) continue;
                const off = base + byteImageOffset(job.tiling, job.fb_w, job.fb_h, x, y);
                if (off < ram.len) ram[off] = tb.vg_mask[ty * size + tx];
            }
        }
    }

    fn loadVgMask(tb: *TileBuffer, ram: []const u8, job: TileJob, l: GeneralLoad) void {
        const size = job.tileSize();
        if (l.kind == 5) {
            const base = l.addr & vc_bus.ramMask(ram.len);
            if (base + tb.vg_mask.len <= ram.len) @memcpy(tb.vg_mask, ram[base..][0..tb.vg_mask.len]);
            tb.vg_valid = true;
            return;
        }
        ensureVgMask(tb);
        const base = l.addr & vc_bus.ramMask(ram.len);
        const x0 = job.tile_x * size;
        const y0 = job.tile_y * size;
        for (0..size) |ty| {
            for (0..size) |tx| {
                const x = x0 + @as(u32, @intCast(tx));
                const y = y0 + @as(u32, @intCast(ty));
                if (x >= job.fb_w or y >= job.fb_h) continue;
                const off = base + byteImageOffset(l.tiling, job.fb_w, job.fb_h, x, y);
                if (off < ram.len) tb.vg_mask[ty * size + tx] = ram[off];
            }
        }
    }

    /// The whole tile buffer as it is (STORE_TILE_BUFFER_GENERAL's full dump), at `addr`: its
    /// colour (16 KiB, as STORE_FULL_RES_TILE_BUFFER stores it), then its depths and stencils
    /// (16 KiB, likewise), then its VG mask (4 KiB, a byte a pixel); less those `flags` leave out.
    const dump_zs_offset = full_res_bytes;
    const dump_vg_offset = 2 * full_res_bytes;

    fn storeDump(tb: *const TileBuffer, ram: []u8, addr: u32, flags: u3) void {
        if (flags & 1 == 0) storeFullRes(tb, ram, addr, 2);
        if (flags & 2 == 0) storeFullRes(tb, ram, addr +% dump_zs_offset, 1);
        if (flags & 4 == 0) {
            const base = (addr +% dump_vg_offset) & vc_bus.ramMask(ram.len);
            if (base + tb.vg_mask.len <= ram.len) @memcpy(ram[base..][0..tb.vg_mask.len], tb.vg_mask);
        }
    }

    /// The tile's colour decimated (STORE_TILE_BUFFER_GENERAL's decimate modes): each 2x2 pixels
    /// averaged (4x, not multisampled), or each 2x2 pixels' samples (16x, multisampled), into an
    /// image half the framebuffer's size each way.
    fn storeDecimated(tb: *const TileBuffer, ram: []u8, job: TileJob) void {
        const size = job.tileSize();
        const out_size = size / 2;
        var words: [64 * 64]u32 = undefined;
        const spp: usize = if (tb.ms) 4 else 1;
        for (0..out_size) |oy| {
            for (0..out_size) |ox| {
                var sum: @Vector(4, u32) = @splat(0);
                for (0..4) |k| {
                    const i = (oy * 2 + k / 2) * size + ox * 2 + k % 2;
                    for (0..spp) |si| {
                        const c: @Vector(4, u8) = @bitCast(tb.color[i * spp + si]);
                        sum += @as(@Vector(4, u32), c);
                    }
                }
                const n: u32 = @intCast(4 * spp);
                const avg = (sum + @as(@Vector(4, u32), @splat(n / 2))) / @as(@Vector(4, u32), @splat(n));
                words[oy * out_size + ox] = @bitCast(@as(@Vector(4, u8), @truncate(avg)));
            }
        }
        const image: TileBuffer = .{ .color = &words, .depth = tb.depth, .stencil = tb.stencil, .vg_mask = tb.vg_mask };
        storeTileFromBuf(&image, ram, job.dst_addr, job.fb_w / 2, job.fb_h / 2, job.tile_x, job.tile_y, out_size, job.tiling, job.ls_format);
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

    /// Reads an RCL's tile jobs in order: each a tile's store, with how the tile was loaded or
    /// cleared and whether it was drawn into.
    const RclReader = struct {
        pc: u32,
        end: u32,
        fb_addr: u32 = 0,
        fb_width: u32 = 0,
        fb_height: u32 = 0,
        fb_flags: u16 = 0,
        clear_color0: u32 = 0,
        clear_zs: f32 = 1.0,
        clear_stencil: u8 = 0,
        cur_tile_x: u32 = 0,
        cur_tile_y: u32 = 0,
        has_tile_coords: bool = false,
        pending_load: ?PendingTileLoad = null,
        cur_lazy_load: ?LazyTileLoad = null,
        cur_zs_load: ?GeneralLoad = null,
        pending_zs_load: ?GeneralLoad = null,
        cur_vg_load: ?GeneralLoad = null,
        pending_vg_load: ?GeneralLoad = null,
        clear_vg_mask: u8 = 0,
        cur_has_render: bool = false,
        tile_loaded: bool = false,
        steps: usize = 0,
        /// The binner's pool (`bin_pool_lo`, `bin_pool_hi`), and the tile's other tile lists.
        pool_lo: u32 = 0,
        pool_hi: u32 = 0,
        /// Draws were binned.
        binned: bool = false,
        cur_lists: [4]u32 = undefined,
        cur_n_lists: u8 = 0,

        fn ms(it: *const RclReader) bool {
            return it.fb_flags & 1 != 0;
        }

        fn tileSize(it: *const RclReader) u32 {
            return if (it.ms()) 32 else 64;
        }

        fn init(ram: []const u8, start_bus: u32, end_bus: u32) RclReader {
            const end = end_bus & vc_bus.ramMask(ram.len);
            return .{ .pc = start_bus & vc_bus.ramMask(ram.len), .end = if (end > ram.len) 0 else end };
        }

        fn job(it: *const RclReader, dst_addr: u32, tiling: u2, ls_format: u2) TileJob {
            return .{
                .tile_x = it.cur_tile_x,
                .tile_y = it.cur_tile_y,
                .clear_color0 = it.clear_color0,
                .clear_zs = it.clear_zs,
                .clear_stencil = it.clear_stencil,
                .lazy_load = it.cur_lazy_load,
                .has_render = it.cur_has_render,
                .dst_addr = dst_addr,
                .fb_w = it.fb_width,
                .fb_h = it.fb_height,
                .tiling = tiling,
                .ls_format = ls_format,
                .ms = it.ms(),
                .clear_vg_mask = it.clear_vg_mask,
                .zs_load = it.cur_zs_load,
                .vg_load = it.cur_vg_load,
                .tile_lists = it.cur_lists,
                .n_lists = it.cur_n_lists,
            };
        }

        /// The tile is done with: what comes next is for another.
        fn endTile(it: *RclReader) void {
            it.tile_loaded = false;
            it.has_tile_coords = false;
            it.pending_load = null;
            it.cur_lazy_load = null;
            it.cur_zs_load = null;
            it.pending_zs_load = null;
            it.cur_vg_load = null;
            it.pending_vg_load = null;
            it.cur_has_render = false;
            it.cur_n_lists = 0;
        }

        fn startTile(it: *RclReader) void {
            if (!it.tile_loaded) {
                it.cur_lazy_load = null;
                it.cur_zs_load = null;
                it.cur_vg_load = null;
                it.tile_loaded = true;
            }
        }

        /// Depth and stencil loaded, into this tile or the next.
        fn zsLoad(it: *RclReader, l: GeneralLoad) void {
            if (it.has_tile_coords) it.cur_zs_load = l else it.pending_zs_load = l;
        }

        fn vgLoad(it: *RclReader, l: GeneralLoad) void {
            if (it.has_tile_coords) it.cur_vg_load = l else it.pending_vg_load = l;
        }

        /// `load`, for the current tile.
        fn lazyLoad(it: *const RclReader, load: PendingTileLoad) LazyTileLoad {
            return .{
                .addr = load.addr,
                .fb_w = it.fb_width,
                .fb_h = it.fb_height,
                .tile_x = it.cur_tile_x,
                .tile_y = it.cur_tile_y,
                .tile_size = it.tileSize(),
                .tiling = load.tiling,
                .format = load.format,
                .full_res = load.full_res,
            };
        }

        fn next(it: *RclReader, ram: []const u8) ?TileJob {
            // It runs until its address is the end's (branched to anywhere).
            while (it.pc != it.end and it.pc < ram.len) {
                it.steps += 1;
                if (it.steps > 1 << 24) break;
                const pc = it.pc;
                const op = ram[pc];
                switch (op) {
                    0 => break, // HALT
                    1, 4, 5, 8, 18 => it.pc += 1,
                    16 => { // BRANCH
                        if (pc + 5 > ram.len) break;
                        it.pc = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little) & vc_bus.ramMask(ram.len);
                    },
                    17 => { // BRANCH_TO_SUB_LIST: the tile's list, of the frame binned or another
                        if (pc + 5 > ram.len) break;
                        it.startTile();
                        const target = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little) & vc_bus.ramMask(ram.len);
                        // With no pool (binning not set up), it's the frame binned, if one was.
                        const no_pool = it.pool_hi == it.pool_lo;
                        if ((no_pool and it.binned) or (!no_pool and target >= it.pool_lo and target < it.pool_hi)) {
                            it.cur_has_render = true;
                        } else if (it.cur_n_lists < it.cur_lists.len) {
                            it.cur_lists[it.cur_n_lists] = target;
                            it.cur_n_lists += 1;
                        }
                        it.pc += 5;
                    },
                    24, 25 => { // STORE_MS_TILE_BUFFER / STORE_MS_TILE_BUFFER_AND_EOF (1 byte)
                        it.startTile();
                        const r_format: u2 = @truncate((it.fb_flags >> 2) & 3);
                        const r_tiling: u2 = @truncate((it.fb_flags >> 6) & 3);
                        const ls_format: u2 = if (r_format == 1) 0 else 2;
                        var j = it.job(it.fb_addr, r_tiling, ls_format);
                        // The decimate mode: 4x averages each pixel's samples.
                        j.resolve = (it.fb_flags >> 4) & 3 == 1;
                        it.endTile();
                        it.pc += 1;
                        return j;
                    },
                    28 => { // STORE_TILE_BUFFER_GENERAL (7 bytes)
                        if (pc + 7 > ram.len) break;
                        const bits = std.mem.readInt(u16, ram[pc + 1 ..][0..2], .little);
                        const addr_word = std.mem.readInt(u32, ram[pc + 3 ..][0..4], .little);
                        const buf_kind = bits & 7;
                        var j: ?TileJob = null;
                        if (buf_kind >= 1 and buf_kind <= 5) {
                            it.startTile();
                            const ls_tiling: u2 = @truncate((bits >> 4) & 3);
                            const ls_format: u2 = @truncate((bits >> 8) & 3);
                            const dst_addr = if ((addr_word & ~@as(u32, 0xf)) != 0) (addr_word & ~@as(u32, 0xf)) else it.fb_addr;
                            j = it.job(dst_addr, ls_tiling, ls_format);
                            j.?.buffer = @intCast(buf_kind);
                            j.?.dump_flags = @truncate(addr_word);
                            // The decimate mode: 4x averages each pixel's samples, else sample 0.
                            j.?.decimate = @truncate(bits >> 6);
                            j.?.resolve = (bits >> 6) & 3 == 1;
                        }
                        // The tile's last store clears its colour (bit 13 keeps it, for stores after).
                        if (bits & (1 << 13) == 0) it.endTile();
                        it.pc += 7;
                        if (j) |stored| return stored;
                    },
                    26 => { // STORE_FULL_RES_TILE_BUFFER (5 bytes): the tile buffer as it is
                        if (pc + 5 > ram.len) break;
                        const word = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little);
                        it.startTile();
                        var j = it.job(word & ~@as(u32, 0xf), 0, 0);
                        j.full_res = @truncate(word & 3);
                        // Bit 2: the tile buffer isn't cleared (more stores of it follow).
                        if (word & 4 == 0) it.endTile();
                        it.pc += 5;
                        return j;
                    },
                    27 => { // LOAD_FULL_RES_TILE_BUFFER (5 bytes): the tile buffer as it was stored
                        if (pc + 5 > ram.len) break;
                        const word = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little);
                        const addr = word & ~@as(u32, 0xf);
                        if (word & 1 == 0) {
                            const load: PendingTileLoad = .{ .addr = addr, .tiling = 0, .format = 0, .full_res = true };
                            if (it.has_tile_coords) {
                                it.cur_lazy_load = it.lazyLoad(load);
                                it.cur_has_render = false;
                                it.tile_loaded = true;
                            } else it.pending_load = load;
                        }
                        if (word & 2 == 0) it.zsLoad(.{ .addr = addr, .kind = 5 });
                        it.pc += 5;
                    },
                    29 => { // LOAD_TILE_BUFFER_GENERAL (7 bytes)
                        if (pc + 7 > ram.len) break;
                        const bits = std.mem.readInt(u16, ram[pc + 1 ..][0..2], .little);
                        const addr_word = std.mem.readInt(u32, ram[pc + 3 ..][0..4], .little);
                        const buf_kind = bits & 7;
                        const ls_tiling_g: u2 = @truncate((bits >> 4) & 3);
                        const load_addr_g = addr_word & ~@as(u32, 0xf);
                        switch (buf_kind) {
                            2, 3 => it.zsLoad(.{ .addr = load_addr_g, .tiling = ls_tiling_g, .kind = @intCast(buf_kind) }),
                            4 => it.vgLoad(.{ .addr = load_addr_g, .tiling = ls_tiling_g, .kind = 4 }),
                            5 => {
                                // All of it, as a full dump has it, less what bits 0 to 2 leave out.
                                if (addr_word & 2 == 0) it.zsLoad(.{ .addr = load_addr_g +% dump_zs_offset, .kind = 5 });
                                if (addr_word & 4 == 0) it.vgLoad(.{ .addr = load_addr_g +% dump_vg_offset, .kind = 5 });
                            },
                            else => {},
                        }
                        if (buf_kind == 1 or (buf_kind == 5 and addr_word & 1 == 0)) { // Load color buffer from memory into tile buffer
                            const ls_tiling: u2 = @truncate((bits >> 4) & 3);
                            const ls_format: u2 = @truncate((bits >> 8) & 3);
                            const load_addr = addr_word & ~@as(u32, 0xf);
                            const full = buf_kind == 5;
                            const load: PendingTileLoad = .{ .addr = load_addr, .tiling = ls_tiling, .format = ls_format, .full_res = full };
                            if (it.has_tile_coords) {
                                it.cur_lazy_load = it.lazyLoad(load);
                                it.cur_has_render = false;
                                it.tile_loaded = true;
                            } else {
                                it.pending_load = load;
                            }
                        }
                        it.pc += 7;
                    },
                    113 => { // TILE_RENDERING_MODE_CONFIG (11 bytes)
                        if (pc + 11 > ram.len) break;
                        it.fb_addr = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little);
                        it.fb_width = std.mem.readInt(u16, ram[pc + 5 ..][0..2], .little);
                        it.fb_height = std.mem.readInt(u16, ram[pc + 7 ..][0..2], .little);
                        it.fb_flags = std.mem.readInt(u16, ram[pc + 9 ..][0..2], .little);
                        it.pc += 11;
                    },
                    114 => { // CLEAR_COLORS (14 bytes)
                        if (pc + 14 > ram.len) break;
                        const raw_c0 = std.mem.readInt(u32, ram[pc + 1 ..][0..4], .little);
                        const zs_raw = std.mem.readInt(u32, ram[pc + 9 ..][0..4], .little);
                        const zs_word = zs_raw & 0x00FFFFFF;
                        it.clear_zs = @as(f32, @floatFromInt(zs_word)) / 16777215.0;
                        // The VG mask in the top byte; the stencil after.
                        it.clear_vg_mask = @truncate(zs_raw >> 24);
                        it.clear_stencil = ram[pc + 13];
                        // Note: for RGB565 render targets, kernel/userspace packs TWO RGB565 pixels in clear_color0
                        const r_format: u2 = @truncate((it.fb_flags >> 2) & 3);
                        if (r_format == 0 or r_format == 2) {
                            it.clear_color0 = format_mod.fromRgb565(@truncate(raw_c0));
                        } else {
                            it.clear_color0 = raw_c0;
                        }
                        it.pc += 14;
                    },
                    115 => { // TILE_COORDINATES (3 bytes)
                        if (pc + 3 > ram.len) break;
                        // Sent again between a tile's stores (the tile buffer kept): the same tile,
                        // still drawn.
                        if (it.has_tile_coords and ram[pc + 1] == it.cur_tile_x and ram[pc + 2] == it.cur_tile_y) {
                            it.pc += 3;
                            continue;
                        }
                        it.cur_tile_x = ram[pc + 1];
                        it.cur_tile_y = ram[pc + 2];
                        it.has_tile_coords = true;
                        it.cur_has_render = false;
                        it.cur_n_lists = 0;
                        if (it.pending_zs_load) |a| {
                            it.cur_zs_load = a;
                            it.pending_zs_load = null;
                            it.tile_loaded = true;
                        }
                        if (it.pending_vg_load) |a| {
                            it.cur_vg_load = a;
                            it.pending_vg_load = null;
                            it.tile_loaded = true;
                        }
                        if (it.pending_load) |pl| {
                            it.cur_lazy_load = it.lazyLoad(pl);
                            it.tile_loaded = true;
                            it.pending_load = null;
                        } else if (!it.tile_loaded) {
                            it.cur_lazy_load = null;
                            it.tile_loaded = true;
                        }
                        it.pc += 3;
                    },
                    else => break,
                }
            }
            it.pc = it.end;
            return null;
        }
    };

    fn executeRcl(self: *V3d, ram: []u8, start_bus: u32, end_bus: u32) void {
        if ((end_bus & vc_bus.ramMask(ram.len)) > ram.len) return;

        var prof_start = profile.now();
        if (gpu_supported and draw_mode == .gpu and self.renderWithGpuVertices(ram, start_bus, end_bus)) {
            profile.end(.v3d_gpu_vertices_frame, prof_start);
            profile.count(.frames_gpu_vertices, 1);
            return;
        }
        self.prepareDrawsForFrame(ram);
        prof_start = profile.now();
        if (gpu_supported and draw_mode != .cpu and self.renderWithGpu(ram, start_bus, end_bus)) {
            profile.end(.v3d_gpu_frame, prof_start);
            profile.count(.frames_gpu, 1);
            return;
        }
        prof_start = profile.now();
        defer profile.end(.v3d_cpu_frame, prof_start);
        profile.count(.frames_cpu, 1);
        profile.count(.triangles, self.shaded_tris.items.len);

        var tile_jobs: [1024]TileJob = undefined;
        var tile_jobs_len: usize = 0;
        var queued_tile_mask: [64]u64 = @splat(0);

        var reader: RclReader = .init(ram, start_bus, end_bus);
        reader.pool_lo = self.bin_pool_lo;
        reader.pool_hi = self.bin_pool_hi;
        reader.binned = self.draws.items.len > 0;
        while (reader.next(ram)) |job| {
            if (job.tile_x < 64 and job.tile_y < 64) {
                const bit = @as(u64, 1) << @intCast(job.tile_x);
                if ((queued_tile_mask[job.tile_y] & bit) != 0 or tile_jobs_len >= tile_jobs.len) {
                    self.flushTileJobs(ram, tile_jobs[0..tile_jobs_len]);
                    tile_jobs_len = 0;
                    queued_tile_mask = @splat(0);
                }
                queued_tile_mask[job.tile_y] |= bit;
                tile_jobs[tile_jobs_len] = job;
                tile_jobs_len += 1;
            } else {
                self.flushTileJobs(ram, tile_jobs[0..tile_jobs_len]);
                tile_jobs_len = 0;
                queued_tile_mask = @splat(0);
                const single = [1]TileJob{job};
                self.flushTileJobs(ram, &single);
            }
        }

        self.flushTileJobs(ram, tile_jobs[0..tile_jobs_len]);
    }

    /// Where frames are drawn (for comparing, with `--v3d`): on the GPU, their vertices shaded there
    /// too where they can be (`gpu`); on the GPU, their vertices shaded on the CPU
    /// (`gpu_fragments`); or on the CPU. Frames the GPU can't draw are drawn on the CPU.
    pub const Mode = enum { gpu, gpu_fragments, cpu };
    pub var draw_mode: Mode = .gpu;

    /// Whether frames can be drawn on the host's GPU: with Metal on macOS, OpenGL on Linux.
    const gpu_supported = metal_renderer.supported or builtin.os.tag == .linux;
    const GpuRenderer = if (metal_renderer.supported) metal_renderer.Renderer else gl_renderer.Renderer;

    /// What drawing frames on the GPU needs, made with the first frame.
    const GpuState = struct {
        renderer: GpuRenderer,
        vertices: [gpu_draw.max_vertices]gpu_draw.Vertex = undefined,
        draws: std.ArrayList(gpu_draw.Draw) = .empty,
        /// The draws' shaders' uniforms (`Draw.uniforms`): room is made for them all first, so
        /// they don't move.
        uniforms: std.ArrayList([qpu_to_shader.max_uniforms]u32) = .empty,
        /// The draws' shaders, one after another in draw order (each draw's vertex shader, if it
        /// has one, then its fragment shader): `Draw.code` is set from here once they are all read.
        code: std.ArrayList(qpu.Inst) = .empty,
        /// OpenGL: the tile buffer, as big as the framebuffer.
        color: std.ArrayList(u32) = .empty,
        /// OpenGL, shading vertices itself: the frame's vertices' VPM words and triangles' corners.
        inputs: std.ArrayList(u32) = .empty,
        corners: std.ArrayList(u32) = .empty,

        /// Starts a frame of up to `max_draws` draws: false if there isn't the memory.
        fn begin(g: *GpuState, max_draws: usize) bool {
            g.draws.clearRetainingCapacity();
            g.uniforms.clearRetainingCapacity();
            g.code.clearRetainingCapacity();
            g.draws.ensureTotalCapacity(tri_allocator, max_draws) catch return false;
            g.uniforms.ensureTotalCapacity(tri_allocator, 2 * max_draws) catch return false;
            return true;
        }

        /// The QPU program at `phys`, read after the others: null if it is longer than the GPU
        /// takes (drawn on the CPU), or there isn't the memory. `Draw.code` is set by `end`.
        fn addProgram(g: *GpuState, ram: []const u8, phys: u32) ?[]const qpu.Inst {
            const len = programLen(ram, phys);
            if (len > gpu_draw.max_program_len) return null;
            const at = g.code.items.len;
            g.code.resize(tri_allocator, at + len) catch return null;
            return readProgram(ram, phys, g.code.items[at..]).?;
        }

        /// The uniforms at `phys`, as many as the GPU's shaders take (0 past the end of RAM, as
        /// qpu_sim reads them).
        fn addUniforms(g: *GpuState, ram: []const u8, phys: u32) *const [qpu_to_shader.max_uniforms]u32 {
            const out = g.uniforms.addOneAssumeCapacity();
            out.* = @splat(0);
            const unifs = uniformsAt(ram, phys);
            const n = @min(unifs.len, out.len);
            for (out[0..n], unifs[0..n]) |*u, v| u.* = v;
            return out;
        }

        /// The frame's draws, their shaders where `addProgram` put them.
        fn end(g: *GpuState) []const gpu_draw.Draw {
            var at: usize = 0;
            for (g.draws.items) |*d| {
                if (d.vertex_stage) |*vs| {
                    vs.code = g.code.items[at..][0..vs.code.len];
                    at += vs.code.len;
                }
                d.code = g.code.items[at..][0..d.code.len];
                at += d.code.len;
            }
            return g.draws.items;
        }
    };

    /// Draws the frame on the GPU, if it is one the GPU can draw the same as the CPU: each tile
    /// once, all loaded (or cleared) and stored alike, and every shader one the GPU runs.
    /// What drawing on the GPU needs, made the first time (null if it can't).
    fn gpuState(self: *V3d) ?*GpuState {
        if (!self.gpu_tried) {
            self.gpu_tried = true;
            const api = if (metal_renderer.supported) "Metal" else "OpenGL";
            var renderer = GpuRenderer.init() catch |err| {
                if (err != error.Unsupported) std.debug.print("fauxpi: V3D on {s}: {s}\n", .{ api, @errorName(err) });
                return null;
            };
            const state = std.heap.page_allocator.create(GpuState) catch {
                if (metal_renderer.supported) renderer.deinit();
                return null;
            };
            state.* = .{ .renderer = renderer };
            self.gpu = state;
        }
        return self.gpu;
    }

    /// A frame the GPU can draw the same as the CPU: each tile once, all loaded (or cleared) and
    /// stored alike. Its first tile's job, and the tiles.
    /// A frame the GPU can draw: its tiles' jobs all as `first`'s, and which tiles are stored (a
    /// bit for each in each row of them).
    const GpuFrame = struct { first: TileJob, tiles: [64]u64 };

    fn gpuFrame(self: *const V3d, ram: []u8, start_bus: u32, end_bus: u32) ?GpuFrame {
        var reader: RclReader = .init(ram, start_bus, end_bus);
        reader.pool_lo = self.bin_pool_lo;
        reader.pool_hi = self.bin_pool_hi;
        reader.binned = self.draws.items.len > 0;
        const first = reader.next(ram) orelse return null;
        if (first.fb_w == 0 or first.fb_h == 0 or first.fb_w > 2048 or first.fb_h > 2048) return null;
        var tiles: [64]u64 = @splat(0);
        var job: ?TileJob = first;
        while (job) |j| : (job = reader.next(ram)) {
            if (j.tile_x >= 64 or j.tile_y >= 64) return null;
            // The tile buffer stored or loaded as it is, or multisampled tiles stored as their first
            // samples, are drawn on the CPU.
            if (j.full_res != null or j.zs_load != null or j.vg_load != null or j.buffer != 1 or j.n_lists != 0 or (j.ms and !j.resolve)) return null;
            if (j.decimate == 2 or (j.decimate == 1 and !j.ms)) return null;
            if (j.lazy_load) |l| if (l.full_res) return null;
            if (j.ms != first.ms) return null;
            const bit = @as(u64, 1) << @intCast(j.tile_x);
            if ((tiles[j.tile_y] & bit) != 0) return null;
            tiles[j.tile_y] |= bit;
            if (j.fb_w != first.fb_w or j.fb_h != first.fb_h or j.clear_color0 != first.clear_color0 or
                j.clear_zs != first.clear_zs or j.has_render != first.has_render or j.dst_addr != first.dst_addr or
                j.tiling != first.tiling or j.ls_format != first.ls_format)
            {
                return null;
            }
            if ((j.lazy_load == null) != (first.lazy_load == null)) return null;
            if (j.lazy_load) |l| {
                const f = first.lazy_load.?;
                if (l.addr != f.addr or l.tiling != f.tiling or l.format != f.format or
                    l.fb_w != f.fb_w or l.fb_h != f.fb_h or l.tile_size != first.tileSize() or l.tile_x != j.tile_x or l.tile_y != j.tile_y)
                {
                    return null;
                }
            }
        }

        return .{ .first = first, .tiles = tiles };
    }

    /// The most vertices a frame's draws shade on the GPU.
    const max_gpu_vertices = 1 << 20;

    /// Draws the frame on the GPU, its vertices shaded there too (not on the CPU), if the GPU can
    /// run all its shaders the same as qpu_sim.
    fn renderWithGpuVertices(self: *V3d, ram: []u8, start_bus: u32, end_bus: u32) bool {
        const g = self.gpuState() orelse return false;
        const frame = self.gpuFrame(ram, start_bus, end_bus) orelse return false;
        // Without triangles, the CPU loads and stores the tiles as fast.
        if (!frame.first.has_render) return false;
        g.inputs.clearRetainingCapacity();
        g.corners.clearRetainingCapacity();
        var n_draws: usize = 0;
        var vertex_total: u32 = 0;
        if (!g.begin(self.draws.items.len)) return false;
        for (self.draws.items) |draw| {
            // Lines and points are drawn from vertices shaded on the CPU, which makes them quads.
            if (!isTriangles(draw) or draw.kind != .gl) return false;
            // What prepareDrawsForFrame skips, drawing nothing.
            if (numPrims(draw) == 0) continue;
            const rec_phys = draw.shader_rec_addr & vc_bus.ramMask(ram.len);
            if (rec_phys + 36 + @as(u32, draw.num_attrs) * 8 > ram.len) continue;
            const fs_num_varyings = ram[rec_phys + 3] +| rasterizerVaryings(draw);
            const fs_code_phys = std.mem.readInt(u32, ram[rec_phys + 4 ..][0..4], .little) & vc_bus.ramMask(ram.len);
            const fs_unif_phys = std.mem.readInt(u32, ram[rec_phys + 8 ..][0..4], .little) & vc_bus.ramMask(ram.len);
            const vs_attr_mask = ram[rec_phys + 14];
            const vs_code_phys = std.mem.readInt(u32, ram[rec_phys + 16 ..][0..4], .little) & vc_bus.ramMask(ram.len);
            const vs_unif_phys = std.mem.readInt(u32, ram[rec_phys + 20 ..][0..4], .little) & vc_bus.ramMask(ram.len);
            if (n_draws == gpu_draw.max_draws) return false;
            const num_tris = numPrims(draw);
            if (num_tris == 0) continue;
            if (programLen(ram, vs_code_phys) == 0 or programLen(ram, fs_code_phys) == 0) continue;
            // Longer shaders are drawn on the CPU.
            const vs_code = g.addProgram(ram, vs_code_phys) orelse return false;
            const fs_code = g.addProgram(ram, fs_code_phys) orelse return false;
            const fs_unifs = g.addUniforms(ram, fs_unif_phys);
            const vs_unifs = g.addUniforms(ram, vs_unif_phys);

            var attr_streams: [8]AttrStream = undefined;
            const attr_info = decodeAttrStreams(ram, rec_phys, draw.num_attrs, vs_attr_mask, &attr_streams);
            const attrs = attr_streams[0..attr_info.count];
            const vpm_words: u32 = @intCast(attr_info.vpm_words);
            const stride: u32 = @max((vpm_words + 3) / 4 * 4, 4);

            const prof_start = profile.now();
            defer profile.end(.gpu_gather_vertices, prof_start);
            if (!self.collectVertices(ram, draw, num_tris)) return false;
            const unique = self.vs_unique.items;
            if (vertex_total + unique.len > max_gpu_vertices) return false;
            // Triangles the clipper cuts are drawn from vertices shaded on the CPU, which clips.
            if (self.needsClipping(ram, draw, rec_phys, num_tris)) return false;
            // Each vertex's VPM words, as qpu_sim is given them.
            const first_input: u32 = @intCast(g.inputs.items.len);
            g.inputs.resize(tri_allocator, first_input + unique.len * stride) catch return false;
            const in = g.inputs.items[first_input..];
            var b: usize = 0;
            while (b < unique.len) : (b += 16) {
                const lanes = @min(16, unique.len - b);
                var vpm_in: [32]qpu_sim.Vec = undefined;
                populateBatchVpmIn(ram, attrs, unique[b..][0..lanes], &vpm_in);
                for (0..lanes) |lane| {
                    const words = in[(b + lane) * stride ..][0..stride];
                    for (words, 0..) |*word, k| word.* = if (k < vpm_words) vpm_in[k][lane] else 0;
                }
            }
            const first_corner: u32 = @intCast(g.corners.items.len);
            g.corners.appendSlice(tri_allocator, self.vs_corner_slot.items) catch return false;

            g.draws.appendAssumeCapacity(.{
                .first_vertex = vertex_total,
                .vertex_count = @intCast(unique.len),
                .vertex_stage = .{
                    .code = vs_code,
                    .uniforms = vs_unifs,
                    .vpm_words = vpm_words,
                    .first_input = first_input,
                    .input_stride = stride,
                    .first_corner = first_corner,
                    .corner_count = @intCast(self.vs_corner_slot.items.len),
                    .cull = draw.config_b0 & 7,
                    .vp_x = draw.vp_x,
                    .vp_y = draw.vp_y,
                },
                .code = fs_code,
                .uniforms = fs_unifs,
                .num_varyings = fs_num_varyings,
                .depth_func = @truncate((draw.config_b1 >> 4) & 7),
                .depth_write = (draw.config_b1 & 0x80) != 0,
                .clip_x = draw.clip_x,
                .clip_y = draw.clip_y,
                .clip_w = draw.clip_w,
                .clip_h = draw.clip_h,
            });
            n_draws += 1;
            vertex_total += @intCast(unique.len);
        }
        if (n_draws == 0) return false;
        const draws = g.end();
        if (metal_renderer.supported) return renderWithMetal(g, ram, frame, &.{}, draws, g.inputs.items, g.corners.items);
        return renderWithGl(g, ram, frame.first, &frame.tiles, &.{}, draws, g.inputs.items, g.corners.items);
    }

    fn renderWithGpu(self: *V3d, ram: []u8, start_bus: u32, end_bus: u32) bool {
        const g = self.gpuState() orelse return false;
        if (self.overflow_draw_start < self.draws.items.len) return false;
        const gpu_frame = self.gpuFrame(ram, start_bus, end_bus) orelse return false;
        const first = gpu_frame.first;
        const tiles = gpu_frame.tiles;

        // The triangles, in a run for each draw.
        var n_vertices: usize = 0;
        var n_draws: usize = 0;
        if (!g.begin(self.draws.items.len)) return false;
        if (first.has_render) {
            var last_draw: ?u32 = null;
            for (self.shaded_tris.items) |*tri| {
                const prep = self.prep_draws.items[tri.draw_idx];
                if (!prep.valid) continue;
                if (last_draw != tri.draw_idx) {
                    if (n_draws == gpu_draw.max_draws) return false;
                    const draw = self.draws.items[tri.draw_idx];
                    // Longer shaders are drawn on the CPU.
                    const code = g.addProgram(ram, prep.fs_code_phys) orelse return false;
                    g.draws.appendAssumeCapacity(.{
                        .first_vertex = @intCast(n_vertices),
                        .vertex_count = 0,
                        .code = code,
                        .uniforms = g.addUniforms(ram, prep.fs_unif_phys),
                        .num_varyings = prep.fs_num_varyings,
                        .depth_func = @truncate((draw.config_b1 >> 4) & 7),
                        .depth_write = (draw.config_b1 & 0x80) != 0,
                        .clip_x = draw.clip_x,
                        .clip_y = draw.clip_y,
                        .clip_w = draw.clip_w,
                        .clip_h = draw.clip_h,
                    });
                    n_draws += 1;
                    last_draw = tri.draw_idx;
                }
                for (tri.v) |v| {
                    g.vertices[n_vertices] = .{
                        .x = v.x,
                        .y = v.y,
                        .z = v.z,
                        .inv_w = v.inv_w,
                        .unit_w = @intFromBool(tri.all_unit_w),
                        .varyings = v.persp_varyings,
                    };
                    n_vertices += 1;
                }
                g.draws.items[n_draws - 1].vertex_count += 3;
            }
        }

        const draws = g.end();
        if (metal_renderer.supported) return renderWithMetal(g, ram, gpu_frame, g.vertices[0..n_vertices], draws, &.{}, &.{});
        // Only drawing is faster on the GPU: the CPU loads and stores tiles on its own as fast.
        if (n_draws == 0) return false;
        return renderWithGl(g, ram, first, &tiles, g.vertices[0..n_vertices], draws, &.{}, &.{});
    }

    /// Draws the frame with Metal, which loads and stores the tiles too.
    fn renderWithMetal(g: *GpuState, ram: []u8, gpu_frame: GpuFrame, vertices: []const gpu_draw.Vertex, draws: []const gpu_draw.Draw, inputs: []const u32, corners: []const u32) bool {
        const first = gpu_frame.first;
        // Multisampled frames are drawn on the CPU; the others' 64-pixel tiles, 32 a row at most.
        if (first.ms) return false;
        var tiles: [32]u32 = undefined;
        for (&tiles, gpu_frame.tiles[0..32]) |*t, row| t.* = std.math.cast(u32, row) orelse return false;
        for (gpu_frame.tiles[32..]) |row| if (row != 0) return false;
        const frame: metal_renderer.Frame = .{
            .width = first.fb_w,
            .height = first.fb_h,
            .clear_color = first.clear_color0,
            .clear_z = first.clear_zs,
            .load = if (first.lazy_load) |l| .{
                .base = l.addr & vc_bus.ramMask(ram.len),
                .tiling = l.tiling,
                .cpp = if (l.format == 1 or l.format == 2) 2 else 4,
            } else null,
            .store = .{
                .base = first.dst_addr & vc_bus.ramMask(ram.len),
                .tiling = first.tiling,
                .cpp = if (first.ls_format == 1 or first.ls_format == 2) 2 else 4,
            },
            .tiles = tiles,
        };
        g.renderer.render(ram, &frame, vertices, draws, inputs, corners) catch return false;
        return true;
    }

    /// Draws the frame with OpenGL: the tiles listed loaded (or cleared) on the CPU into a buffer
    /// as big as the framebuffer, drawn into, and stored from it.
    fn renderWithGl(g: *GpuState, ram: []u8, first: TileJob, tiles: *const [64]u64, vertices: []const gpu_draw.Vertex, draws: []const gpu_draw.Draw, inputs: []const u32, corners: []const u32) bool {
        const w = first.fb_w;
        const h = first.fb_h;
        g.color.resize(std.heap.page_allocator, @as(usize, w) * h) catch return false;
        const color = g.color.items;
        var tile_color: [64 * 64]u32 = undefined;
        var tile_depth: [64 * 64]f32 = undefined;
        var tile_stencil: [64 * 64]u8 = undefined;
        var tile_vg: [64 * 64]u8 = undefined;
        var tb: TileBuffer = .{ .color = &tile_color, .depth = &tile_depth, .stencil = &tile_stencil, .vg_mask = &tile_vg };
        // 64 pixels square, or 32 multisampled.
        const size = first.tileSize();
        const tiles_w = @min((w + size - 1) / size, 64);
        const tiles_h = @min((h + size - 1) / size, 64);
        const load_start = profile.now();
        for (0..tiles_h) |ty| {
            for (0..tiles_w) |tx| {
                if (tiles[ty] & (@as(u64, 1) << @intCast(tx)) == 0) continue;
                const x0: u32 = @intCast(tx * size);
                const y0: u32 = @intCast(ty * size);
                const vw = @min(size, w - x0);
                const vh = @min(size, h - y0);
                if (first.lazy_load) |ll| {
                    @memset(&tile_color, 0);
                    loadTileIntoBuf(&tb, ram, ll.addr, ll.fb_w, ll.fb_h, @intCast(tx), @intCast(ty), size, ll.tiling, ll.format);
                    for (0..vh) |y| @memcpy(color[(y0 + y) * w + x0 ..][0..vw], tile_color[y * size ..][0..vw]);
                } else {
                    for (0..vh) |y| @memset(color[(y0 + y) * w + x0 ..][0..vw], first.clear_color0);
                }
            }
        }

        profile.end(.gpu_load_tiles, load_start);

        g.renderer.render(ram, w, h, color, first.clear_zs, vertices, draws, inputs, corners, first.ms) catch |err| {
            if (err != error.Unsupported) std.debug.print("fauxpi: V3D on OpenGL: {s}\n", .{@errorName(err)});
            return false;
        };
        const store_start = profile.now();
        defer profile.end(.gpu_store_tiles, store_start);

        for (0..tiles_h) |ty| {
            for (0..tiles_w) |tx| {
                if (tiles[ty] & (@as(u64, 1) << @intCast(tx)) == 0) continue;
                const x0: u32 = @intCast(tx * size);
                const y0: u32 = @intCast(ty * size);
                const vw = @min(size, w - x0);
                const vh = @min(size, h - y0);
                for (0..vh) |y| @memcpy(tile_color[y * size ..][0..vw], color[(y0 + y) * w + x0 ..][0..vw]);
                tb.color_solid = null;
                storeTileFromBuf(&tb, ram, first.dst_addr, w, h, @intCast(tx), @intCast(ty), size, first.tiling, first.ls_format);
            }
        }
        return true;
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
            .stencil = @constCast(&self.tile_stencil),
            .vg_mask = @constCast(&self.tile_vg_mask),
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
            tb.color_solid = null;
            if (ll.full_res) {
                const base = ll.addr & vc_bus.ramMask(ram.len);
                if (base + full_res_bytes <= ram.len) @memcpy(std.mem.sliceAsBytes(tb.color), ram[base..][0..full_res_bytes]);
            } else {
                loadTileIntoBuf(tb, ram, ll.addr, ll.fb_w, ll.fb_h, ll.tile_x, ll.tile_y, ll.tile_size, ll.tiling, ll.format);
                // Multisampled, each pixel loaded into all its samples.
                if (tb.ms) {
                    var i: usize = 32 * 32;
                    while (i > 0) {
                        i -= 1;
                        tb.color[i * 4 ..][0..4].* = @splat(tb.color[i]);
                    }
                }
            }
        } else if (tb.color_solid) |c| {
            @memset(tb.color, c);
            tb.color_solid = null;
        }
        if (need_depth and !tb.depth_valid) {
            @memset(tb.depth, tb.clear_zs);
            @memset(tb.stencil, tb.clear_stencil);
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

        // The tile in one 64-pixel bin (a multisampled tile is in a quarter of one).
        const use_spatial_bin = (tile_px_x >> 6) == ((tile_end_x - 1) >> 6) and (tile_px_y >> 6) == ((tile_end_y - 1) >> 6) and
            (tile_px_x >> 6) < 32 and (tile_px_y >> 6) < 32;
        const binned: []const u32 = if (use_spatial_bin) blk: {
            const t = (tile_px_y >> 6) * 32 + (tile_px_x >> 6);
            break :blk self.tile_tris.items[self.tile_tri_start[t]..self.tile_tri_start[t + 1]];
        } else &.{};
        if (use_spatial_bin and binned.len == 0 and self.overflow_draw_start >= self.draws.items.len) return;

        var cur_draw_idx: ?u32 = null;
        var cur_fs_decoded: []const qpu_sim.DecodedInst = &.{};
        var cur_fs_unifs: qpu_sim.Uniforms = &.{};

        if (use_spatial_bin) {
            for (binned) |tri_idx| {
                const tri = &self.shaded_tris.items[tri_idx];
                const prep = self.prep_draws.items[tri.draw_idx];
                if (!prep.valid) continue;

                if (cur_draw_idx == null or cur_draw_idx.? != tri.draw_idx) {
                    cur_draw_idx = tri.draw_idx;
                    cur_fs_decoded = self.prep_fs_insts.items[prep.fs_inst_start..][0..prep.fs_code_len];
                    cur_fs_unifs = uniformsAt(ram, prep.fs_unif_phys);
                }

                const draw = self.draws.items[tri.draw_idx];
                rasterizeInTileBuf(
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
        } else {
            for (self.shaded_tris.items) |*tri| {
                if (tri.max_x <= tile_px_x or tri.min_x >= tile_end_x or
                    tri.max_y <= tile_px_y or tri.min_y >= tile_end_y)
                {
                    continue;
                }

                const prep = self.prep_draws.items[tri.draw_idx];
                if (!prep.valid) continue;

                if (cur_draw_idx == null or cur_draw_idx.? != tri.draw_idx) {
                    cur_draw_idx = tri.draw_idx;
                    cur_fs_decoded = self.prep_fs_insts.items[prep.fs_inst_start..][0..prep.fs_code_len];
                    cur_fs_unifs = uniformsAt(ram, prep.fs_unif_phys);
                }

                const draw = self.draws.items[tri.draw_idx];
                rasterizeInTileBuf(
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

        if (self.overflow_draw_start < self.draws.items.len) {
            for (self.draws.items[self.overflow_draw_start..]) |draw| {
                renderDrawIntoTileBuf(tb, ram, draw, self.vg_verts.items, tile_px_x, tile_px_y, tile_size);
            }
        }
    }

    /// A draw's shaders, loaded for a tile list's primitives (which name their vertices): its
    /// fragment shader, and its vertex (and coordinate) shader, for GL mode.
    const ListShaders = struct {
        code: std.ArrayList(qpu.Inst) = .empty,
        vs_list: std.ArrayList(qpu_sim.DecodedInst) = .empty,
        fs_list: std.ArrayList(qpu_sim.DecodedInst) = .empty,
        cs_list: std.ArrayList(qpu_sim.DecodedInst) = .empty,
        attrs: [8]AttrStream = undefined,
        cs_attrs: [8]AttrStream = undefined,
        src: DrawSource = undefined,
        fs: []const qpu_sim.DecodedInst = &.{},
        fs_unifs: qpu_sim.Uniforms = &.{},
        fast_frag: qpu_sim.FastFragShader = .{},
        vs: []const qpu_sim.DecodedInst = &.{},
        vs_unifs: qpu_sim.Uniforms = &.{},
        n_attrs: usize = 0,
        vpm_words: usize = 0,
        cs: ?CoordStage = null,
        loaded: bool = false,

        fn deinit(l: *ListShaders) void {
            l.code.deinit(tri_allocator);
            l.vs_list.deinit(tri_allocator);
            l.fs_list.deinit(tri_allocator);
            l.cs_list.deinit(tri_allocator);
        }

        fn load(l: *ListShaders, ram: []const u8, draw: DrawCall) bool {
            l.loaded = false;
            l.src = drawSource(ram, draw) orelse return false;
            l.vs_list.clearRetainingCapacity();
            l.fs_list.clearRetainingCapacity();
            l.cs_list.clearRetainingCapacity();
            l.fs = decodeProgramAt(ram, l.src.fs_code_phys, &l.code, &l.fs_list) orelse return false;
            if (l.fs.len == 0) return false;
            l.fs_unifs = uniformsAt(ram, l.src.fs_unif_phys);
            l.fast_frag = qpu_sim.analyzeFragmentShader(l.fs, l.fs_unifs);
            switch (l.src.vertices) {
                .gl => |g| {
                    l.vs = decodeProgramAt(ram, g.vs_code_phys, &l.code, &l.vs_list) orelse return false;
                    if (l.vs.len == 0) return false;
                    l.vs_unifs = uniformsAt(ram, g.vs_unif_phys);
                    const info = decodeAttrStreams(ram, g.rec_phys, draw.num_attrs, g.vs_attr_mask, &l.attrs);
                    l.n_attrs = info.count;
                    l.vpm_words = info.vpm_words;
                    l.cs = coordStage(ram, g.rec_phys, draw.num_attrs, &l.code, &l.cs_list, &l.cs_attrs);
                },
                else => {},
            }
            l.loaded = true;
            return true;
        }

        /// Vertices `indices` of `draw` (up to 16), shaded or as given, and their clip
        /// coordinates. False if one can't be.
        fn vertices(l: *const ListShaders, ram: []const u8, draw: DrawCall, vg_verts: []const [2]f32, indices: []const u32, out: []ShadedVertex, clip: []ClipVertex) bool {
            var ok: [16]bool = @splat(false);
            @memset(clip, .{ .x = 0, .y = 0, .z = 0, .w = std.math.nan(f32) });
            const n_var = @min(@as(usize, l.src.fs_num_varyings), 16);
            const job: VertexJob = .{
                .ram = ram,
                .draw = draw,
                .decoded = l.vs,
                .unifs = l.vs_unifs,
                .attrs = l.attrs[0..l.n_attrs],
                .vpm_words = l.vpm_words,
                .n_var = n_var,
                .indices = indices,
                .out = out,
                .ok = ok[0..indices.len],
                .cs = l.cs,
                .clip = clip,
                .source = l.src.vertices,
                .vg_verts = vg_verts,
            };
            job.run(0, 1);
            for (ok[0..indices.len]) |o| if (!o) return false;
            return true;
        }
    };

    /// Renders the tile list at `addr` (not the binner's: written otherwise) into the tile: its
    /// state (shader states, the primitive list format, configuration, clip window, viewport,
    /// sizes; from the frame binned's at first), branches and sub-lists, primitives (drawn as
    /// draws are), compressed primitive lists (each coding, and their relative branches), and
    /// clipped primitives (vertices of the next replaced by those given).
    fn renderTileList(self: *const V3d, tb: *TileBuffer, ram: []const u8, addr: u32, tile_px_x: u32, tile_px_y: u32, tile_size: u32) void {
        const mask = vc_bus.ramMask(ram.len);
        var draw: DrawCall = .{
            .kind = self.cur_kind,
            .fs_code = self.cur_fs_code,
            .fs_unifs = self.cur_fs_unifs,
            .fs_varyings = self.cur_fs_varyings,
            .shader_rec_addr = self.cur_shader_rec,
            .num_attrs = self.cur_num_attrs,
            .vp_x = self.cur_vp_x,
            .vp_y = self.cur_vp_y,
            .clip_x = self.cur_clip_x,
            .clip_y = self.cur_clip_y,
            .clip_w = self.cur_clip_w,
            .clip_h = self.cur_clip_h,
            .config_b0 = self.cur_cfg0,
            .config_b1 = self.cur_cfg1,
            .config_b2 = self.cur_cfg2,
            .clip_scale_x = self.cur_clip_scale_x,
            .clip_scale_y = self.cur_clip_scale_y,
            .z_scale = self.cur_z_scale,
            .z_offset = self.cur_z_offset,
            .line_width = self.cur_line_width,
            .point_size = self.cur_point_size,
        };
        var list: TileListCtx = .{ .v3d = self, .tb = tb, .ram = ram, .tile_px_x = tile_px_x, .tile_px_y = tile_px_y, .tile_size = tile_size, .rht_x = self.rht_x_boundary };
        defer list.shaders.deinit();
        var pc = addr & mask;
        var returns: [4]u32 = undefined;
        var depth: usize = 0;
        var steps: usize = 0;
        while (pc < ram.len and steps < 1 << 20) : (steps += 1) {
            const op = ram[pc];
            const word = struct {
                fn at(r: []const u8, o: u32) u32 {
                    return if (o + 4 <= r.len) std.mem.readInt(u32, r[o..][0..4], .little) else 0;
                }
            }.at;
            switch (op) {
                0 => return, // HALT
                1 => pc += 1,
                16 => pc = word(ram, pc + 1) & mask,
                17 => {
                    if (depth < returns.len) {
                        returns[depth] = pc + 5;
                        depth += 1;
                    }
                    pc = word(ram, pc + 1) & mask;
                },
                18 => {
                    if (depth == 0) return;
                    depth -= 1;
                    pc = returns[depth];
                },
                32, 33 => { // Primitives, as a draw's
                    var d = draw;
                    d.mode = ram[pc + 1] & 0x0f;
                    d.count = word(ram, pc + 2);
                    if (op == 32) {
                        d.indexed = true;
                        d.u16_indices = ram[pc + 1] & 0x10 != 0;
                        d.index_buffer_addr = word(ram, pc + 6);
                    } else d.first_or_offset = word(ram, pc + 6);
                    renderDrawIntoTileBuf(tb, ram, d, self.vg_verts.items, tile_px_x, tile_px_y, tile_size);
                    pc += if (op == 32) 14 else 10;
                },
                48 => pc = list.compressed(&draw, pc + 1, null),
                49 => { // CLIPPED_PRIMITIVE: then a compressed list
                    const w = word(ram, pc + 1);
                    pc = list.compressed(&draw, pc + 5, .{ .data = w & ~@as(u32, 7) & mask, .which = @truncate(w) });
                },
                56 => {
                    list.list_type = @truncate(ram[pc + 1]);
                    list.xy = (ram[pc + 1] >> 4) == 3;
                    pc += 2;
                },
                64 => {
                    const w = word(ram, pc + 1);
                    draw.kind = .gl;
                    draw.shader_rec_addr = w & ~@as(u32, 0xf);
                    draw.num_attrs = @intCast(if ((w & 7) == 0) 8 else (w & 7));
                    list.shaders.loaded = false;
                    pc += 5;
                },
                65 => {
                    draw.kind = .nv;
                    draw.shader_rec_addr = word(ram, pc + 1) & ~@as(u32, 0xf);
                    list.shaders.loaded = false;
                    pc += 5;
                },
                66 => {
                    const rec = word(ram, pc + 1) & ~@as(u32, 0xf) & mask;
                    draw.kind = .vg;
                    if (rec + 12 <= ram.len) {
                        draw.fs_varyings = ram[rec + 3];
                        draw.fs_code = word(ram, rec + 4);
                        draw.fs_unifs = word(ram, rec + 8);
                    }
                    list.shaders.loaded = false;
                    pc += 5;
                },
                67 => {
                    draw.kind = .vg;
                    draw.fs_code = word(ram, pc + 1) & ~@as(u32, 7);
                    draw.fs_unifs = word(ram, pc + 5);
                    draw.fs_varyings = 0;
                    list.shaders.loaded = false;
                    pc += 9;
                },
                96 => {
                    draw.config_b0 = ram[pc + 1];
                    draw.config_b1 = ram[pc + 2];
                    draw.config_b2 = ram[pc + 3];
                    pc += 4;
                },
                97, 101, 104 => pc += if (op == 104) 9 else 5,
                98 => {
                    draw.point_size = @bitCast(word(ram, pc + 1));
                    pc += 5;
                },
                99 => {
                    draw.line_width = @bitCast(word(ram, pc + 1));
                    pc += 5;
                },
                100 => {
                    list.rht_x = @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(word(ram, pc + 1))))));
                    pc += 3;
                },
                102 => {
                    draw.clip_x = @truncate(word(ram, pc + 1));
                    draw.clip_y = @truncate(word(ram, pc + 1) >> 16);
                    draw.clip_w = @truncate(word(ram, pc + 5));
                    draw.clip_h = @truncate(word(ram, pc + 5) >> 16);
                    pc += 9;
                },
                103 => {
                    const w = word(ram, pc + 1);
                    draw.vp_x = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(w)))))) / 16.0;
                    draw.vp_y = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(w >> 16)))))) / 16.0;
                    pc += 5;
                },
                105, 106 => {
                    if (op == 105) {
                        draw.clip_scale_x = @bitCast(word(ram, pc + 1));
                        draw.clip_scale_y = @bitCast(word(ram, pc + 5));
                    } else {
                        draw.z_scale = @bitCast(word(ram, pc + 1));
                        draw.z_offset = @bitCast(word(ram, pc + 5));
                    }
                    pc += 9;
                },
                else => return,
            }
        }
    }

    /// Vertices of the next primitive replaced by clipped vertex data (CLIPPED_PRIMITIVE): those
    /// whose bits `which` has, from `data`, each as a vertex shader writes it.
    const ClippedPrimitive = struct { data: u32, which: u3 };

    /// A tile list being rendered: its primitive list format, and its draws' shaders.
    const TileListCtx = struct {
        v3d: *const V3d,
        tb: *TileBuffer,
        ram: []const u8,
        tile_px_x: u32,
        tile_px_y: u32,
        tile_size: u32,
        rht_x: f32,
        /// Points (0), lines (1), triangles (2) or RHTs (3); of indices, or XY coordinates.
        list_type: u4 = 2,
        xy: bool = false,
        shaders: ListShaders = .{},

        /// The corners a triangle shares with the last one (its coding 0's bits 1:0).
        const shared_edges = [3][2]usize{ .{ 2, 1 }, .{ 0, 2 }, .{ 1, 0 } };

        /// Renders the compressed primitive list at `start` (to its escape), the first primitive
        /// clipped as `clipped` says; where the list goes on after it.
        fn compressed(l: *TileListCtx, draw: *const DrawCall, start: u32, clipped_in: ?ClippedPrimitive) u32 {
            const ram = l.ram;
            var clipped = clipped_in;
            var q = start;
            var last: [3]u32 = @splat(0);
            var last_xy: [3][2]f32 = @splat(.{ 0, 0 });
            const corners: usize = switch (l.list_type) {
                0 => 1,
                1, 3 => 2,
                else => 3,
            };
            const half = struct {
                fn at(r: []const u8, o: u32) u32 {
                    return if (o + 2 <= r.len) std.mem.readInt(u16, r[o..][0..2], .little) else 0;
                }
            }.at;
            const sx6 = struct {
                fn f(v: u32) i32 {
                    return @as(i6, @bitCast(@as(u6, @truncate(v))));
                }
            }.f;
            var steps: usize = 0;
            while (q < ram.len and steps < 1 << 20) : (steps += 1) {
                const b0: u32 = ram[q];
                var idx: [3]u32 = last;
                var xy: [3][2]f32 = last_xy;
                // Escapes: the end, absolute vertices, a relative branch.
                if (b0 >= 0x80 and b0 <= 0x83) {
                    switch (b0) {
                        0x80 => return q + 1,
                        0x81 => {
                            if (l.xy) {
                                for (0..corners) |k| xy[k] = xyOf(draw.*, std.mem.readInt(u32, ram[@min(q + 1 + @as(u32, @intCast(k)) * 4, ram.len - 4)..][0..4], .little));
                                q += 1 + @as(u32, @intCast(corners)) * 4;
                            } else {
                                for (0..corners) |k| idx[k] = half(ram, q + 1 + @as(u32, @intCast(k)) * 2);
                                q += 1 + @as(u32, @intCast(corners)) * 2;
                            }
                        },
                        0x82 => {
                            q = (q & ~@as(u32, 31)) +% half(ram, q + 1) * 32;
                            continue;
                        },
                        else => return q + 1,
                    }
                } else if (l.xy) {
                    // Relative: sharing two corners (bits 1:0), the third moved (whole pixels).
                    const h = half(ram, q);
                    const share = h & 3;
                    const dx: f32 = @floatFromInt(@as(i7, @bitCast(@as(u7, @truncate(h >> 2)))));
                    const dy: f32 = @floatFromInt(@as(i7, @bitCast(@as(u7, @truncate(h >> 9)))));
                    const prev = last_xy[corners - 1];
                    if (corners == 3) {
                        const keep = shared_edges[@min(share, 2)];
                        xy = .{ last_xy[keep[0]], last_xy[keep[1]], .{ prev[0] + dx, prev[1] + dy } };
                    } else {
                        xy[0] = last_xy[corners - 1];
                        xy[corners - 1] = .{ prev[0] + dx, prev[1] + dy };
                    }
                    q += 2;
                } else switch (l.list_type) {
                    0 => { // Points: on by 6 or 14 bits.
                        if (b0 & 3 == 3) {
                            const h = half(ram, q);
                            idx[0] = @bitCast(@as(i32, @bitCast(last[0])) +% @as(i14, @bitCast(@as(u14, @truncate(h >> 2)))));
                            q += 2;
                        } else {
                            idx[0] = @bitCast(@as(i32, @bitCast(last[0])) +% sx6(b0 >> 2));
                            q += 1;
                        }
                    },
                    1, 3 => { // Lines: sharing an end, two deltas, or absolute and a delta.
                        if (b0 & 3 == 3) {
                            const h = half(ram, q);
                            idx[0] = @bitCast(@as(i32, @bitCast(last[0])) +% @as(i4, @bitCast(@as(u4, @truncate(h >> 4)))));
                            idx[1] = @bitCast(@as(i32, @bitCast(last[1])) +% @as(i4, @bitCast(@as(u4, @truncate(h >> 8)))));
                            q += 2;
                        } else if (b0 & 3 == 2) {
                            idx[0] = half(ram, q + 1);
                            idx[1] = @bitCast(@as(i32, @bitCast(idx[0])) +% sx6(b0 >> 2));
                            q += 3;
                        } else {
                            idx[0] = if (b0 & 3 == 0) last[1] else last[0];
                            idx[1] = @bitCast(@as(i32, @bitCast(last[1])) +% sx6(b0 >> 2));
                            q += 1;
                        }
                    },
                    else => { // Triangles: sharing an edge, three deltas, or absolute and two.
                        if (b0 & 3 != 3) {
                            const keep = shared_edges[b0 & 3];
                            idx = .{ last[keep[0]], last[keep[1]], @bitCast(@as(i32, @bitCast(last[2])) +% sx6(b0 >> 2)) };
                            q += 1;
                        } else if ((b0 >> 2) & 3 == 3) {
                            const h = half(ram, q);
                            const first = half(ram, q + 2);
                            idx = .{ first, @bitCast(@as(i32, @bitCast(first)) +% sx6(h >> 4)), @bitCast(@as(i32, @bitCast(first)) +% sx6(h >> 10)) };
                            q += 4;
                        } else {
                            const h = half(ram, q);
                            for (0..3) |k| idx[k] = @bitCast(@as(i32, @bitCast(last[k])) +% @as(i4, @bitCast(@as(u4, @truncate(h >> @intCast(4 + k * 4))))));
                            q += 2;
                        }
                    },
                }
                last = idx;
                last_xy = xy;
                l.primitive(draw, idx[0..corners], xy[0..corners], clipped);
                clipped = null;
            }
            return q;
        }

        /// An XY list's coordinate: Xs and Ys (12.4 fixed point) from the viewport offset.
        fn xyOf(draw: DrawCall, w: u32) [2]f32 {
            const xs: i16 = @bitCast(@as(u16, @truncate(w)));
            const ys: i16 = @bitCast(@as(u16, @truncate(w >> 16)));
            return .{ @as(f32, @floatFromInt(xs)) / 16 + draw.vp_x, @as(f32, @floatFromInt(ys)) / 16 + draw.vp_y };
        }

        /// One primitive of a compressed list: its vertices' indices (or XY coordinates).
        fn primitive(l: *TileListCtx, draw_in: *const DrawCall, idx: []const u32, xy: []const [2]f32, clipped: ?ClippedPrimitive) void {
            var draw = draw_in.*;
            draw.mode = switch (l.list_type) {
                0 => 0,
                1 => 1,
                else => 4,
            };
            if (!l.shaders.loaded and !l.shaders.load(l.ram, draw)) return;
            const n_var = @min(@as(usize, l.shaders.src.fs_num_varyings), 16);
            var verts: [3]ShadedVertex = @splat(.{});
            var clip: [3]ClipVertex = @splat(.{ .x = 0, .y = 0, .z = 0, .w = std.math.nan(f32) });
            if (l.xy) {
                for (xy, 0..) |p, k| verts[k] = .{ .x = p[0], .y = p[1], .point_size = draw.point_size };
            } else if (!l.shaders.vertices(l.ram, draw, l.v3d.vg_verts.items, idx, verts[0..idx.len], clip[0..idx.len])) return;
            if (clipped) |c| {
                // Each clipped vertex's data, in turn, as a vertex shader writes it.
                const layout: VertexLayout = .of(l.ram, draw, n_var);
                const words = layout.first_varying + layout.varyings;
                var off = c.data;
                for (0..idx.len) |k| {
                    if (c.which & (@as(u3, 1) << @intCast(k)) == 0) continue;
                    if (off + words * 4 > l.ram.len) return;
                    const w = struct {
                        fn at(r: []const u8, o: usize) u32 {
                            return std.mem.readInt(u32, r[o..][0..4], .little);
                        }
                    }.at;
                    const p = xyOf(draw, w(l.ram, off));
                    var v: ShadedVertex = .{ .x = p[0], .y = p[1], .point_size = draw.point_size };
                    v.z = @bitCast(w(l.ram, off + 4));
                    const iw: f32 = @bitCast(w(l.ram, off + 8));
                    v.inv_w = if (iw == 0) 1 else iw;
                    for (0..layout.varyings) |vi| v.persp_varyings[layout.skip + vi] = @as(f32, @bitCast(w(l.ram, off + (layout.first_varying + vi) * 4))) * v.inv_w;
                    verts[k] = v;
                    clip[k].w = std.math.nan(f32);
                    off += @intCast(words * 4);
                }
            }
            switch (l.list_type) {
                0 => {
                    verts[1] = verts[0];
                    verts[2] = verts[0];
                },
                1 => verts[2] = verts[1],
                3 => {
                    // An RHT: the trapezoid between its edge and the X boundary.
                    const a = verts[0];
                    const b = verts[1];
                    var bb = b;
                    bb.x = l.rht_x;
                    var ba = a;
                    ba.x = l.rht_x;
                    l.triangle(draw, .{ a, b, bb }, @splat(.{ .x = 0, .y = 0, .z = 0, .w = std.math.nan(f32) }), n_var);
                    l.triangle(draw, .{ a, bb, ba }, @splat(.{ .x = 0, .y = 0, .z = 0, .w = std.math.nan(f32) }), n_var);
                    return;
                },
                else => {},
            }
            l.triangle(draw, verts, clip, n_var);
        }

        fn triangle(l: *TileListCtx, draw: DrawCall, verts: [3]ShadedVertex, clip: [3]ClipVertex, n_var: usize) void {
            var pieces: [max_clipped][3]ShadedVertex = undefined;
            const n_pieces = primitiveTriangles(draw, verts, clip, n_var, &pieces);
            for (pieces[0..n_pieces]) |p_verts| {
                const area = (p_verts[1].x - p_verts[0].x) * (p_verts[2].y - p_verts[0].y) -
                    (p_verts[1].y - p_verts[0].y) * (p_verts[2].x - p_verts[0].x);
                if (@abs(area) < 1e-6) continue;
                if (isTriangles(draw) and culled(draw.config_b0, area)) continue;
                const min_fx = @max(@floor(@min(p_verts[0].x, @min(p_verts[1].x, p_verts[2].x))), @as(f32, @floatFromInt(draw.clip_x)));
                const min_fy = @max(@floor(@min(p_verts[0].y, @min(p_verts[1].y, p_verts[2].y))), @as(f32, @floatFromInt(draw.clip_y)));
                const max_fx = @min(@ceil(@max(p_verts[0].x, @max(p_verts[1].x, p_verts[2].x))), @as(f32, @floatFromInt(@as(u32, draw.clip_x) + draw.clip_w)));
                const max_fy = @min(@ceil(@max(p_verts[0].y, @max(p_verts[1].y, p_verts[2].y))), @as(f32, @floatFromInt(@as(u32, draw.clip_y) + draw.clip_h)));
                if (min_fx >= max_fx or min_fy >= max_fy) continue;
                const tri = ShadedTriangle.init(0, @intFromFloat(min_fx), @intFromFloat(min_fy), @intFromFloat(max_fx), @intFromFloat(max_fy), area, p_verts, n_var);
                rasterizeInTileBuf(l.tb, l.ram, draw, &tri, l.shaders.fs, l.shaders.fs_unifs, l.shaders.src.fs_num_varyings, l.shaders.fast_frag, l.tile_px_x, l.tile_px_y, l.tile_size);
            }
        }
    };

    /// `renderDrawIntoTileBuf` for an NV or VG draw: its vertices as given.
    fn renderGivenDrawIntoTileBuf(tb: *TileBuffer, ram: []const u8, draw: DrawCall, src: DrawSource, vg_verts: []const [2]f32, tile_px_x: u32, tile_px_y: u32, tile_size: u32) void {
        var code: std.ArrayList(qpu.Inst) = .empty;
        defer code.deinit(tri_allocator);
        var fs_list: std.ArrayList(qpu_sim.DecodedInst) = .empty;
        defer fs_list.deinit(tri_allocator);
        const fs_decoded = decodeProgramAt(ram, src.fs_code_phys, &code, &fs_list) orelse return;
        if (fs_decoded.len == 0) return;
        const fs_unifs = uniformsAt(ram, src.fs_unif_phys);
        const fast_frag = qpu_sim.analyzeFragmentShader(fs_decoded, fs_unifs);
        const n_var = @min(@as(usize, src.fs_num_varyings), 16);
        const num_tris = numPrims(draw);
        var tri_idx: u32 = 0;
        while (tri_idx < num_tris) : (tri_idx += 1) {
            var indices: [3]u32 = undefined;
            for (&indices, 0..) |*ix, corner| ix.* = triangleCorner(ram, draw, tri_idx, @intCast(corner));
            var verts: [3]ShadedVertex = undefined;
            var ok: [3]bool = undefined;
            var clip: [3]ClipVertex = undefined;
            const job: VertexJob = .{ .ram = ram, .draw = draw, .decoded = &.{}, .unifs = &.{}, .attrs = &.{}, .vpm_words = 0, .n_var = n_var, .indices = &indices, .out = &verts, .ok = &ok, .clip = &clip, .source = src.vertices, .vg_verts = vg_verts };
            job.givenBatch(0, 3);
            if (!ok[0] or !ok[1] or !ok[2]) continue;
            var pieces: [max_clipped][3]ShadedVertex = undefined;
            const n_pieces = primitiveTriangles(draw, verts, clip, n_var, &pieces);
            for (pieces[0..n_pieces]) |p_verts| {
                const area = (p_verts[1].x - p_verts[0].x) * (p_verts[2].y - p_verts[0].y) -
                    (p_verts[1].y - p_verts[0].y) * (p_verts[2].x - p_verts[0].x);
                if (@abs(area) < 1e-6) continue;
                if (isTriangles(draw) and culled(draw.config_b0, area)) continue;
                const min_fx = @max(@floor(@min(p_verts[0].x, @min(p_verts[1].x, p_verts[2].x))), @as(f32, @floatFromInt(draw.clip_x)));
                const min_fy = @max(@floor(@min(p_verts[0].y, @min(p_verts[1].y, p_verts[2].y))), @as(f32, @floatFromInt(draw.clip_y)));
                const max_fx = @min(@ceil(@max(p_verts[0].x, @max(p_verts[1].x, p_verts[2].x))), @as(f32, @floatFromInt(@as(u32, draw.clip_x) + draw.clip_w)));
                const max_fy = @min(@ceil(@max(p_verts[0].y, @max(p_verts[1].y, p_verts[2].y))), @as(f32, @floatFromInt(@as(u32, draw.clip_y) + draw.clip_h)));
                if (min_fx >= max_fx or min_fy >= max_fy) continue;
                const tri = ShadedTriangle.init(0, @intFromFloat(min_fx), @intFromFloat(min_fy), @intFromFloat(max_fx), @intFromFloat(max_fy), area, p_verts, n_var);
                rasterizeInTileBuf(tb, ram, draw, &tri, fs_decoded, fs_unifs, src.fs_num_varyings, fast_frag, tile_px_x, tile_px_y, tile_size);
            }
        }
    }

    fn renderDrawIntoTileBuf(tb: *TileBuffer, ram: []const u8, draw: DrawCall, vg_verts: []const [2]f32, tile_px_x: u32, tile_px_y: u32, tile_size: u32) void {
        if (numPrims(draw) == 0) return;
        const src = drawSource(ram, draw) orelse return;
        if (src.vertices != .gl) return renderGivenDrawIntoTileBuf(tb, ram, draw, src, vg_verts, tile_px_x, tile_px_y, tile_size);
        const rec_phys = src.vertices.gl.rec_phys;
        const fs_num_varyings = src.fs_num_varyings;
        const fs_code_phys = src.fs_code_phys;
        const fs_unif_phys = src.fs_unif_phys;
        const vs_attr_mask = src.vertices.gl.vs_attr_mask;
        const vs_code_phys = src.vertices.gl.vs_code_phys;
        const vs_unif_phys = src.vertices.gl.vs_unif_phys;

        // The shaders, however long (this may run on several threads at once).
        var code: std.ArrayList(qpu.Inst) = .empty;
        defer code.deinit(tri_allocator);
        var vs_list: std.ArrayList(qpu_sim.DecodedInst) = .empty;
        defer vs_list.deinit(tri_allocator);
        var fs_list: std.ArrayList(qpu_sim.DecodedInst) = .empty;
        defer fs_list.deinit(tri_allocator);
        const vs_decoded = decodeProgramAt(ram, vs_code_phys, &code, &vs_list) orelse return;
        const fs_decoded = decodeProgramAt(ram, fs_code_phys, &code, &fs_list) orelse return;
        if (vs_decoded.len == 0 or fs_decoded.len == 0) return;

        const vs_unifs = uniformsAt(ram, vs_unif_phys);
        const fs_unifs = uniformsAt(ram, fs_unif_phys);
        // The coordinate shader, for the clipper.
        var cs_list: std.ArrayList(qpu_sim.DecodedInst) = .empty;
        defer cs_list.deinit(tri_allocator);
        var cs_attrs: [8]AttrStream = undefined;
        const cs = coordStage(ram, rec_phys, draw.num_attrs, &code, &cs_list, &cs_attrs);
        const fast_frag = qpu_sim.analyzeFragmentShader(fs_decoded, fs_unifs);

        const num_tris = numPrims(draw);

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
                for (0..3) |corner| {
                    v_indices[t_i * 3 + corner] = triangleCorner(ram, draw, tri_idx + @as(u32, @intCast(t_i)), @intCast(corner));
                }
            }
            tri_idx += @intCast(batch_tris);

            var vpm_in: [32]qpu_sim.Vec = undefined;
            populateBatchVpmIn(ram, active_attrs, v_indices[0..batch_verts], &vpm_in);

            const vs_res = qpu_sim.runDecoded(vs_decoded, .{
                .uniforms = vs_unifs,
                .vpm_in = vpm_in[0..vpm_words],
            }) catch continue;
            const layout: VertexLayout = .of(ram, draw, n_var);
            if (vs_res.vpm_out_len < layout.first_varying) continue;
            var clip: [16]ClipVertex = @splat(.{ .x = 0, .y = 0, .z = 0, .w = std.math.nan(f32) });
            if (cs) |c| {
                const job: VertexJob = .{ .ram = ram, .draw = draw, .decoded = &.{}, .unifs = &.{}, .attrs = &.{}, .vpm_words = 0, .n_var = 0, .indices = v_indices[0..batch_verts], .out = &.{}, .ok = &.{}, .shade = false, .cs = c, .clip = clip[0..batch_verts] };
                job.run(0, 1);
            }

            for (0..batch_tris) |t_i| {
                const base_l = t_i * 3;
                var tri_verts: [3]ShadedVertex = .{ .{}, .{}, .{} };
                const verts = &tri_verts;
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
                    verts[corner].point_size = if (layout.point_size) @bitCast(vs_res.vpm_out[3][lane]) else draw.point_size;
                    for (0..@min(layout.varyings, vs_res.vpm_out_len - layout.first_varying)) |vi| {
                        const raw_v: f32 = @bitCast(vs_res.vpm_out[layout.first_varying + vi][lane]);
                        verts[corner].persp_varyings[layout.skip + vi] = raw_v * inv_w;
                    }
                }

                var pieces: [max_clipped][3]ShadedVertex = undefined;
                const n_pieces = primitiveTriangles(draw, tri_verts, clip[base_l..][0..3].*, n_var, &pieces);
                for (pieces[0..n_pieces]) |p_verts| {
                    const area = (p_verts[1].x - p_verts[0].x) * (p_verts[2].y - p_verts[0].y) -
                        (p_verts[1].y - p_verts[0].y) * (p_verts[2].x - p_verts[0].x);
                    if (@abs(area) < 1e-6) continue;
                    if (isTriangles(draw) and culled(draw.config_b0, area)) continue;

                    const min_fx = @max(@floor(@min(p_verts[0].x, @min(p_verts[1].x, p_verts[2].x))), clip_min_x);
                    const min_fy = @max(@floor(@min(p_verts[0].y, @min(p_verts[1].y, p_verts[2].y))), clip_min_y);
                    const max_fx = @min(@ceil(@max(p_verts[0].x, @max(p_verts[1].x, p_verts[2].x))), clip_max_x);
                    const max_fy = @min(@ceil(@max(p_verts[0].y, @max(p_verts[1].y, p_verts[2].y))), clip_max_y);
                    if (min_fx >= max_fx or min_fy >= max_fy) continue;

                    const tri = ShadedTriangle.init(
                        0,
                        @intFromFloat(min_fx),
                        @intFromFloat(min_fy),
                        @intFromFloat(max_fx),
                        @intFromFloat(max_fy),
                        area,
                        p_verts,
                        n_var,
                    );
                    rasterizeInTileBuf(tb, ram, draw, &tri, fs_decoded, fs_unifs, fs_num_varyings, fast_frag, tile_px_x, tile_px_y, tile_size);
                }
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
        fs_unifs: qpu_sim.Uniforms,
        num_varyings: u8,
        tile_px_x: u32,
        tile_px_y: u32,
        tile_size: u32,
    ) void {
        const fs_decoded_buf = tri_allocator.alloc(qpu_sim.DecodedInst, fs_code.len) catch return;
        defer tri_allocator.free(fs_decoded_buf);
        const fs_decoded = qpu_sim.decodeProgram(fs_code, fs_decoded_buf);
        const fast_frag = qpu_sim.analyzeFragmentShader(fs_decoded, fs_unifs);
        var tb = self.tileBuf();
        defer self.syncFromTileBuf(&tb);
        rasterizeInTileBuf(&tb, ram, draw, tri, fs_decoded, fs_unifs, num_varyings, fast_frag, tile_px_x, tile_px_y, tile_size);
    }

    /// Rasterizes `tri` into the tile (multisampled or not, as `tb` is).
    inline fn rasterizeInTileBuf(
        tb: *TileBuffer,
        ram: []const u8,
        draw: DrawCall,
        tri: *const ShadedTriangle,
        fs_decoded: []const qpu_sim.DecodedInst,
        fs_unifs: qpu_sim.Uniforms,
        num_varyings: u8,
        fast_frag: qpu_sim.FastFragShader,
        tile_px_x: u32,
        tile_px_y: u32,
        tile_size: u32,
    ) void {
        if (fast_frag.quads) {
            rasterizeQuadsInTileBuf(tb, ram, draw, tri, fs_decoded, fs_unifs, num_varyings, fast_frag, tile_px_x, tile_px_y, tile_size);
        } else if (tb.ms) {
            rasterizeMsTriangleInTileBuf(tb, ram, draw, tri, fs_decoded, fs_unifs, num_varyings, fast_frag, tile_px_x, tile_px_y);
        } else {
            rasterizeShadedTriangleDecodedInTileBuf(tb, ram, draw, tri, fs_decoded, fs_unifs, num_varyings, fast_frag, tile_px_x, tile_px_y, tile_size);
        }
    }

    /// Rasterizes `tri` into the tile (multisampled or not, as `tb` is) as V3D does, a 2x2 quad
    /// of pixels at a time: each quad with a sample covered is shaded whole, 4 quads together (the
    /// pixels not covered too, their results unused), so the TMU's levels of detail come from
    /// the quads' differences. Each fragment is then given to the TLB as V3D's are: those whose
    /// colour (or Z) the shader doesn't write discarded, the samples it covers as MS_FLAGS says,
    /// its Z the shader's or the rasterizer's, through the stencil test (as TLB_STENCIL_SETUP
    /// says) and the depth test. Slower than the other paths; for shaders that need it.
    fn rasterizeQuadsInTileBuf(
        tb: *TileBuffer,
        ram: []const u8,
        draw: DrawCall,
        tri: *const ShadedTriangle,
        fs_decoded: []const qpu_sim.DecodedInst,
        fs_unifs: qpu_sim.Uniforms,
        num_varyings: u8,
        fast_frag: qpu_sim.FastFragShader,
        tile_px_x: u32,
        tile_px_y: u32,
        tile_size_in: u32,
    ) void {
        const tile_size: u32 = if (tb.ms) 32 else tile_size_in;
        const x_start = @max(tri.min_x, tile_px_x);
        const y_start = @max(tri.min_y, tile_px_y);
        const x_end = @min(tri.max_x, tile_px_x + tile_size);
        const y_end = @min(tri.max_y, tile_px_y + tile_size);
        if (x_start >= x_end or y_start >= y_end) return;

        const n_var = @min(@as(usize, num_varyings), 16);
        const t = if (tri.setup_valid) tri.* else ShadedTriangle.init(tri.draw_idx, tri.min_x, tri.min_y, tri.max_x, tri.max_y, tri.area, tri.v, n_var);
        if (t.inv_area <= 0) return;
        const centre = [1][2]f32{.{ 0.5, 0.5 }};
        const offsets: []const [2]f32 = if (tb.ms) &sample_offsets else &centre;
        const spp: u32 = if (tb.ms) 4 else 1;

        var batch: QuadBatch = .{
            .depth_func = @truncate((draw.config_b1 >> 4) & 7),
            .z_updates = (draw.config_b1 & 0x80) != 0,
            // Lines and points face forward.
            .back = isTriangles(draw) and !facesForward(draw.config_b0, t.area),
        };
        var materialized = false;
        var qy = y_start & ~@as(u32, 1);
        while (qy < y_end) : (qy += 2) {
            var qx = x_start & ~@as(u32, 1);
            while (qx < x_end) : (qx += 2) {
                var masks: [4]u4 = @splat(0);
                var zs: [4][4]f32 = undefined;
                for (0..4) |i| {
                    const px = qx + @as(u32, @intCast(i & 1));
                    const py = qy + @as(u32, @intCast(i >> 1));
                    if (px < x_start or px >= x_end or py < y_start or py >= y_end) continue;
                    for (offsets, 0..) |off, si| {
                        const fx = @as(f32, @floatFromInt(px)) + off[0];
                        const fy = @as(f32, @floatFromInt(py)) + off[1];
                        const e0 = t.edge0.eval(t.edge0.dx * (fy - t.edge0.p0y), fx);
                        const e1 = t.edge1.eval(t.edge1.dx * (fy - t.edge1.p0y), fx);
                        const e2 = t.edge2.eval(t.edge2.dx * (fy - t.edge2.p0y), fx);
                        if (!t.edge0.passes(e0) or !t.edge1.passes(e1) or !t.edge2.passes(e2)) continue;
                        masks[i] |= @as(u4, 1) << @intCast(si);
                        zs[i][si] = zq(t.v[2].z + e0 * t.inv_area * t.dz0 + e1 * t.inv_area * t.dz1);
                    }
                }
                if (masks[0] | masks[1] | masks[2] | masks[3] == 0) continue;
                if (!materialized) {
                    ensureTileMaterializedBuf(tb, ram, true);
                    ensureVgMask(tb);
                    materialized = true;
                }
                // The quad's pixels, covered or not, their inputs at their middles.
                for (0..4) |i| {
                    const px = qx + @as(u32, @intCast(i & 1));
                    const py = qy + @as(u32, @intCast(i >> 1));
                    const lane = batch.len;
                    const fx = @as(f32, @floatFromInt(px)) + 0.5;
                    const fy = @as(f32, @floatFromInt(py)) + 0.5;
                    const w0 = t.edge0.eval(t.edge0.dx * (fy - t.edge0.p0y), fx) * t.inv_area;
                    const w1 = t.edge1.eval(t.edge1.dx * (fy - t.edge1.p0y), fx) * t.inv_area;
                    const inv_w = t.v[2].inv_w + w0 * t.dinvw0 + w1 * t.dinvw1;
                    const w: f32 = if (t.all_unit_w or @abs(inv_w) <= 1e-12) 1 else 1 / inv_w;
                    const idx = (py - tile_px_y) * tile_size + (px - tile_px_x);
                    batch.idx[lane] = idx;
                    batch.mask[lane] = masks[i];
                    batch.zs[lane] = zs[i];
                    batch.frag_w[lane] = @bitCast(w);
                    batch.frag_z[lane] = @bitCast(zq(t.v[2].z + w0 * t.dz0 + w1 * t.dz1));
                    batch.frag_x[lane] = px;
                    batch.frag_y[lane] = py;
                    batch.ms_mask[lane] = if (tb.ms) masks[i] else (if (masks[i] != 0) 0xf else 0);
                    batch.alpha_mask[lane] = tb.vg_mask[idx];
                    for (0..n_var) |vi| {
                        const v = t.v[2].persp_varyings[vi] + w0 * t.dvar0[vi] + w1 * t.dvar1[vi];
                        batch.varyings[vi][lane] = @bitCast(v * w);
                    }
                    for (0..4) |si| batch.samples_in[si][lane] = tb.color[idx * spp + (if (tb.ms) si else 0)];
                    batch.len += 1;
                }
                if (batch.len == 16) batch.flush(tb, ram, fs_decoded, fs_unifs, n_var, fast_frag);
            }
        }
        batch.flush(tb, ram, fs_decoded, fs_unifs, n_var, fast_frag);
    }

    /// Up to 4 quads of pixels (multisampled or not), shaded together, then given to the TLB.
    const QuadBatch = struct {
        depth_func: u3,
        z_updates: bool,
        /// The primitive faces back (its stencil test the back's, its REV_FLAG 1).
        back: bool,
        len: usize = 0,
        idx: [16]u32 = undefined,
        /// The samples covered (bit 0 alone, not multisampled), and their depths.
        mask: [16]u4 = undefined,
        zs: [16][4]f32 = undefined,
        frag_w: qpu_sim.Vec = qpu_sim.splatF(1),
        frag_z: qpu_sim.Vec = qpu_sim.splat(0),
        frag_x: qpu_sim.Vec = qpu_sim.splat(0),
        frag_y: qpu_sim.Vec = qpu_sim.splat(0),
        ms_mask: qpu_sim.Vec = qpu_sim.splat(0),
        alpha_mask: qpu_sim.Vec = qpu_sim.splat(0),
        varyings: [16]qpu_sim.Vec = @splat(qpu_sim.splat(0)),
        samples_in: [4]qpu_sim.Vec = @splat(qpu_sim.splat(0)),
        tex_cache: [2]qpu_sim.TexCache = .{ .{}, .{} },

        fn flush(
            b: *QuadBatch,
            tb: *TileBuffer,
            ram: []const u8,
            fs_decoded: []const qpu_sim.DecodedInst,
            fs_unifs: qpu_sim.Uniforms,
            n_var: usize,
            fast_frag: qpu_sim.FastFragShader,
        ) void {
            const count = b.len;
            if (count == 0) return;
            b.len = 0;
            // The quads past them as the last (their results unused).
            for (count..16) |lane| {
                const from = count - 4 + (lane & 3);
                b.mask[lane] = 0;
                b.frag_w[lane] = b.frag_w[from];
                b.frag_z[lane] = b.frag_z[from];
                b.frag_x[lane] = b.frag_x[from];
                b.frag_y[lane] = b.frag_y[from];
                b.ms_mask[lane] = 0;
                b.alpha_mask[lane] = b.alpha_mask[from];
                for (b.varyings[0..n_var]) |*v| v[lane] = v[from];
                for (&b.samples_in) |*v| v[lane] = v[from];
            }
            const env: qpu_sim.Env = .{
                .uniforms = fs_unifs,
                .varyings = b.varyings[0..n_var],
                .frag_w = b.frag_w,
                .frag_z = b.frag_z,
                .frag_x = b.frag_x,
                .frag_y = b.frag_y,
                .ms_mask = b.ms_mask,
                .rev_flag = qpu_sim.splat(@intFromBool(b.back)),
                .alpha_mask_in = b.alpha_mask,
                .texture_memory = ram,
                .tlb_color_in = b.samples_in[0],
                .tlb_samples_in = if (tb.ms) &b.samples_in else null,
                .tex_cache = &b.tex_cache,
            };
            const res = qpu_sim.runFragmentFast(fast_frag, fs_decoded, &env) catch return;
            const stencil = Stencil.of(res.stencil_setups[0..@min(res.stencil_count, 3)], b.back);
            const spp: u32 = if (tb.ms) 4 else 1;
            for (0..count) |lane| {
                const bit = @as(u16, 1) << @intCast(lane);
                // The VG mask written where covered.
                if (res.alpha_mask_mask & bit != 0 and b.mask[lane] != 0) tb.vg_mask[b.idx[lane]] = @truncate(res.alpha_mask[lane]);
                const color_written = res.tlb_color_mask & bit != 0;
                const z_written = res.tlb_z_mask & bit != 0;
                // Neither written: discarded.
                if (!color_written and !z_written) continue;
                var cover = b.mask[lane];
                if (res.ms_flags_mask & bit != 0) {
                    const flags: u4 = @truncate(res.ms_flags[lane]);
                    cover = if (tb.ms) cover & flags else (if (flags != 0) cover else 0);
                }
                const base = b.idx[lane] * spp;
                for (0..spp) |si| {
                    if (cover & (@as(u4, 1) << @intCast(si)) == 0) continue;
                    const i = base + si;
                    const z = if (z_written) @as(f32, @floatFromInt(res.tlb_z.?[lane] & 0xffffff)) / 16777215.0 else b.zs[lane][si];
                    if (stencil) |st| {
                        if (!st.passes(tb.stencil[i])) {
                            tb.stencil[i] = st.apply(st.sfail, tb.stencil[i]);
                            continue;
                        }
                    }
                    const z_passes = depthPasses(b.depth_func, z, tb.depth[i]);
                    if (stencil) |st| tb.stencil[i] = st.apply(if (z_passes) st.zpass else st.zfail, tb.stencil[i]);
                    if (!z_passes) continue;
                    if (b.z_updates) tb.depth[i] = z;
                    if (res.tlb_samples > 0) {
                        // Each sample's colour written in turn.
                        if (si < res.tlb_samples and si < 4 and res.tlb_sample_masks[si] & bit != 0) tb.color[i] = res.tlb_color_samples[si][lane];
                    } else if (color_written) tb.color[i] = res.tlb_color.?[lane];
                }
            }
        }
    };

    /// The stencil test, as the TLB_STENCIL_SETUP words written set it up for a primitive facing
    /// one way: each word (bits 31:30) the front's (1), the back's (2), both (3), or the write
    /// masks (0: the front's bits 7:0, the back's 15:8); configs give the write mask (bits 29:28:
    /// 0x1, 0x3, 0xf or 0xff), the ops on depth failing (27:25), passing (24:22), and the stencil
    /// test failing (21:19), the test (18:16, as depth tests' order), the reference (15:8), and
    /// the mask tested (7:0).
    const Stencil = struct {
        func: u3,
        ref: u8,
        mask: u8,
        write_mask: u8,
        sfail: u3,
        zfail: u3,
        zpass: u3,

        fn of(setups: []const u32, back: bool) ?Stencil {
            var cfgs: [2]?u32 = .{ null, null };
            var write_masks: [2]u8 = .{ 0xff, 0xff };
            const codes = [4]u8{ 0x1, 0x3, 0xf, 0xff };
            for (setups) |w| {
                switch (w >> 30) {
                    0 => write_masks = .{ @truncate(w), @truncate(w >> 8) },
                    1, 2, 3 => {
                        for (0..2) |side| {
                            if ((w >> 30) & (@as(u32, 1) << @intCast(side)) == 0) continue;
                            cfgs[side] = w;
                            write_masks[side] = codes[(w >> 28) & 3];
                        }
                    },
                    else => unreachable,
                }
            }
            const side: usize = @intFromBool(back);
            const w = cfgs[side] orelse return null;
            return .{
                .func = @truncate(w >> 16),
                .ref = @truncate(w >> 8),
                .mask = @truncate(w),
                .write_mask = write_masks[side],
                .sfail = @truncate(w >> 19),
                .zpass = @truncate(w >> 22),
                .zfail = @truncate(w >> 25),
            };
        }

        fn passes(st: Stencil, value: u8) bool {
            const r = st.ref & st.mask;
            const v = value & st.mask;
            return switch (st.func) {
                0 => false,
                1 => r < v,
                2 => r == v,
                3 => r <= v,
                4 => r > v,
                5 => r != v,
                6 => r >= v,
                7 => true,
            };
        }

        /// `value` after `op`: zero, keep, replace (with the reference), increment and
        /// decrement (saturating), invert, increment and decrement (wrapping); only the bits
        /// of the write mask.
        fn apply(st: Stencil, op: u3, value: u8) u8 {
            const new: u8 = switch (op) {
                0 => 0,
                1 => value,
                2 => st.ref,
                3 => value +| 1,
                4 => value -| 1,
                5 => ~value,
                6 => value +% 1,
                7 => value -% 1,
            };
            return (value & ~st.write_mask) | (new & st.write_mask);
        }
    };

    /// A depth as the 24-bit depth buffer holds it.
    pub fn zq(z: f32) f32 {
        return @round(std.math.clamp(z, 0, 1) * 16777215.0) / 16777215.0;
    }

    fn zqVec(comptime n: usize, z: @Vector(n, f32)) @Vector(n, f32) {
        const V = @Vector(n, f32);
        const c = @min(@max(z, @as(V, @splat(0))), @as(V, @splat(1)));
        return @round(c * @as(V, @splat(16777215.0))) / @as(V, @splat(16777215.0));
    }

    /// Where a multisampled pixel's samples are, from its top-left corner (the usual 4x pattern, a
    /// grid turned so no two share a row or column).
    pub const sample_offsets = [4][2]f32{ .{ 0.375, 0.125 }, .{ 0.875, 0.375 }, .{ 0.125, 0.625 }, .{ 0.625, 0.875 } };

    /// Rasterizes `tri` into a multisampled tile (32 pixels square, at `tile_px_x`, `tile_px_y`):
    /// each sample it covers, and that passes the depth test, is drawn. The fragment shader runs
    /// once a pixel (its varyings at the middle), its colour written to all the samples drawn, or
    /// each sample's (its writes to tlb_color_ms in turn) to its own; colour loads read each
    /// sample in turn.
    fn rasterizeMsTriangleInTileBuf(
        tb: *TileBuffer,
        ram: []const u8,
        draw: DrawCall,
        tri: *const ShadedTriangle,
        fs_decoded: []const qpu_sim.DecodedInst,
        fs_unifs: qpu_sim.Uniforms,
        num_varyings: u8,
        fast_frag: qpu_sim.FastFragShader,
        tile_px_x: u32,
        tile_px_y: u32,
    ) void {
        const tile_size = 32;
        const x_start = @max(tri.min_x, tile_px_x);
        const y_start = @max(tri.min_y, tile_px_y);
        const x_end = @min(tri.max_x, tile_px_x + tile_size);
        const y_end = @min(tri.max_y, tile_px_y + tile_size);
        if (x_start >= x_end or y_start >= y_end) return;

        const depth_func: u3 = @truncate((draw.config_b1 >> 4) & 7);
        const z_updates = (draw.config_b1 & 0x80) != 0;
        const need_depth = (depth_func != 7) or z_updates;

        const n_var = @min(@as(usize, num_varyings), 16);
        const t = if (tri.setup_valid) tri.* else ShadedTriangle.init(tri.draw_idx, tri.min_x, tri.min_y, tri.max_x, tri.max_y, tri.area, tri.v, n_var);
        if (t.inv_area <= 0) return;

        var batch: MsBatch = .{};
        var materialized = false;
        var py = y_start;
        while (py < y_end) : (py += 1) {
            var px = x_start;
            while (px < x_end) : (px += 1) {
                // The samples covered, and their depths.
                var mask: u4 = 0;
                var zs: [4]f32 = undefined;
                for (sample_offsets, 0..) |off, si| {
                    const fx = @as(f32, @floatFromInt(px)) + off[0];
                    const fy = @as(f32, @floatFromInt(py)) + off[1];
                    const e0 = t.edge0.eval(t.edge0.dx * (fy - t.edge0.p0y), fx);
                    const e1 = t.edge1.eval(t.edge1.dx * (fy - t.edge1.p0y), fx);
                    const e2 = t.edge2.eval(t.edge2.dx * (fy - t.edge2.p0y), fx);
                    if (!t.edge0.passes(e0) or !t.edge1.passes(e1) or !t.edge2.passes(e2)) continue;
                    mask |= @as(u4, 1) << @intCast(si);
                    zs[si] = zq(t.v[2].z + e0 * t.inv_area * t.dz0 + e1 * t.inv_area * t.dz1);
                }
                if (mask == 0) continue;
                if (!materialized) {
                    ensureTileMaterializedBuf(tb, ram, need_depth);
                    materialized = true;
                }
                const idx = (py - tile_px_y) * tile_size + (px - tile_px_x);
                if (depth_func != 7) {
                    for (0..4) |si| {
                        if (mask & (@as(u4, 1) << @intCast(si)) == 0) continue;
                        if (!depthPasses(depth_func, zs[si], tb.depth[idx * 4 + si])) mask &= ~(@as(u4, 1) << @intCast(si));
                    }
                    if (mask == 0) continue;
                }

                // The fragment shader's inputs, at the pixel's middle.
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                const fy = @as(f32, @floatFromInt(py)) + 0.5;
                const w0 = t.edge0.eval(t.edge0.dx * (fy - t.edge0.p0y), fx) * t.inv_area;
                const w1 = t.edge1.eval(t.edge1.dx * (fy - t.edge1.p0y), fx) * t.inv_area;
                const inv_w = t.v[2].inv_w + w0 * t.dinvw0 + w1 * t.dinvw1;
                const w: f32 = if (t.all_unit_w or @abs(inv_w) <= 1e-12) 1 else 1 / inv_w;
                const lane = batch.len;
                batch.idx[lane] = idx;
                batch.mask[lane] = mask;
                batch.zs[lane] = zs;
                batch.frag_w[lane] = @bitCast(w);
                batch.frag_z[lane] = @bitCast(t.v[2].z + w0 * t.dz0 + w1 * t.dz1);
                batch.frag_x[lane] = px;
                batch.frag_y[lane] = py;
                for (0..n_var) |vi| {
                    const v = t.v[2].persp_varyings[vi] + w0 * t.dvar0[vi] + w1 * t.dvar1[vi];
                    batch.varyings[vi][lane] = @bitCast(v * w);
                }
                for (0..4) |si| batch.samples_in[si][lane] = tb.color[idx * 4 + si];
                batch.len += 1;
                if (batch.len == 16) batch.flush(tb, ram, fs_decoded, fs_unifs, n_var, fast_frag, z_updates);
            }
        }
        batch.flush(tb, ram, fs_decoded, fs_unifs, n_var, fast_frag, z_updates);
    }

    /// Up to 16 multisampled pixels, shaded together.
    const MsBatch = struct {
        len: usize = 0,
        idx: [16]u32 = undefined,
        /// The samples drawn, and their depths.
        mask: [16]u4 = undefined,
        zs: [16][4]f32 = undefined,
        frag_w: qpu_sim.Vec = qpu_sim.splatF(1),
        frag_z: qpu_sim.Vec = qpu_sim.splat(0),
        frag_x: qpu_sim.Vec = qpu_sim.splat(0),
        frag_y: qpu_sim.Vec = qpu_sim.splat(0),
        varyings: [16]qpu_sim.Vec = @splat(qpu_sim.splat(0)),
        samples_in: [4]qpu_sim.Vec = @splat(qpu_sim.splat(0)),
        tex_cache: [2]qpu_sim.TexCache = .{ .{}, .{} },

        fn flush(
            b: *MsBatch,
            tb: *TileBuffer,
            ram: []const u8,
            fs_decoded: []const qpu_sim.DecodedInst,
            fs_unifs: qpu_sim.Uniforms,
            n_var: usize,
            fast_frag: qpu_sim.FastFragShader,
            z_updates: bool,
        ) void {
            const count = b.len;
            if (count == 0) return;
            b.len = 0;
            // The lanes past them as the last (their results unused).
            for (count..16) |lane| {
                b.frag_w[lane] = b.frag_w[count - 1];
                b.frag_z[lane] = b.frag_z[count - 1];
                b.frag_x[lane] = b.frag_x[count - 1];
                b.frag_y[lane] = b.frag_y[count - 1];
                for (b.varyings[0..n_var]) |*v| v[lane] = v[count - 1];
                for (&b.samples_in) |*v| v[lane] = v[count - 1];
            }
            const env: qpu_sim.Env = .{
                .uniforms = fs_unifs,
                .varyings = b.varyings[0..n_var],
                .frag_w = b.frag_w,
                .frag_z = b.frag_z,
                .frag_x = b.frag_x,
                .frag_y = b.frag_y,
                .texture_memory = ram,
                .tlb_color_in = b.samples_in[0],
                .tlb_samples_in = &b.samples_in,
                .tex_cache = &b.tex_cache,
            };
            const res = qpu_sim.runFragmentFast(fast_frag, fs_decoded, &env) catch return;
            if (res.tlb_color == null and res.tlb_samples == 0) return;
            for (0..count) |lane| {
                const base = b.idx[lane] * 4;
                for (0..4) |si| {
                    if (b.mask[lane] & (@as(u4, 1) << @intCast(si)) == 0) continue;
                    // Written to each sample in turn, or all at once.
                    const color = if (res.tlb_samples > 0)
                        (if (si < res.tlb_samples) res.tlb_color_samples[si][lane] else continue)
                    else
                        res.tlb_color.?[lane];
                    tb.color[base + si] = color;
                    if (z_updates) tb.depth[base + si] = b.zs[lane][si];
                }
            }
        }
    };

    /// Whether depth `z` passes `depth_func` (CONFIGURATION_BITS) against the tile buffer's `cur`.
    fn depthPasses(depth_func: u3, z: f32, cur: f32) bool {
        return switch (depth_func) {
            0 => false,
            1 => z < cur,
            2 => z == cur,
            3 => z <= cur,
            4 => z > cur,
            5 => z != cur,
            6 => z >= cur,
            7 => true,
        };
    }

    fn rasterizeShadedTriangleDecodedInTileBuf(
        tb: *TileBuffer,
        ram: []const u8,
        draw: DrawCall,
        tri: *const ShadedTriangle,
        fs_decoded: []const qpu_sim.DecodedInst,
        fs_unifs: qpu_sim.Uniforms,
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
                funifs: qpu_sim.Uniforms,
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
                        const z_vec = zqVec(16, @as(@Vector(16, f32), @splat(z_base)) + step16_z);

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
                    const z_4 = zqVec(4, @as(@Vector(4, f32), @splat(z_base)) + step4_z);
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

                const z = zq(z2 + w0 * dz0 + w1 * dz1);
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

test "V3D counts only the triangles drawn against the most it shades ahead" {
    // The CPU's limit: no GPU.
    var v3d = V3d{ .gpu_tried = true };
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
    // The same at 0x3100, but every vertex the first (stride 0): triangles with no area.
    @memcpy(ram[0x3100..0x3130], ram[0x3000..0x3030]);
    ram[0x3129] = 0;

    // Build BCL at 0x4000
    var bcl: usize = 0x4000;
    ram[bcl] = 6; // START_TILE_BINNING
    bcl += 1;
    ram[bcl] = 103; // VIEWPORT_OFFSET (32.0, 32.0)
    std.mem.writeInt(u16, ram[bcl + 1 ..][0..2], 32 * 16, .little);
    std.mem.writeInt(u16, ram[bcl + 3 ..][0..2], 32 * 16, .little);
    bcl += 5;
    // More triangles than are shaded ahead, none of them drawn.
    ram[bcl] = 64; // GL_SHADER_STATE (0x3100 | 1 attr)
    std.mem.writeInt(u32, ram[bcl + 1 ..][0..4], 0x3101, .little);
    bcl += 5;
    ram[bcl] = 33; // GL_ARRAY_PRIMITIVE (triangles=4)
    ram[bcl + 1] = 4;
    std.mem.writeInt(u32, ram[bcl + 2 ..][0..4], (V3d.MAX_PREBINNED_TRIS + 4000) * 3, .little);
    std.mem.writeInt(u32, ram[bcl + 6 ..][0..4], 0, .little);
    bcl += 10;
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

    // Both draws were shaded ahead, and the triangle drawn.
    try std.testing.expectEqual(@as(usize, 2), v3d.draws.items.len);
    try std.testing.expect(v3d.overflow_draw_start >= v3d.draws.items.len);
    const center_off = 0x10000 + (32 * 64 + 32) * 4;
    try std.testing.expectEqual(@as(u32, 0xffff0000), std.mem.readInt(u32, ram[center_off..][0..4], .little));
}

test "V3D runs shaders however long, with as many uniforms as they read, for every draw" {
    // The QPU runs a program to its end, reading as many uniforms as it asks for, and the binner
    // takes as many draws as it is given: none of the limits FauxPi once had (512 instructions,
    // 128 uniforms, 256 draws). Drawn on the CPU (no GPU).
    var v3d = V3d{ .gpu_tried = true };
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 512 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);

    // A vertex shader of over 700 instructions at 0x20000, its scale uniforms 200 and 201.
    const skipped_uniforms = 200;
    var vs: qpu.Program(1024) = .{};
    vs.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_write_setup, .value = 0x00001a00 }));
    vs.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_read_setup, .value = 0x00501a00 }));
    for (0..skipped_uniforms) |_| vs.emit(try qpu.mov(qpu.wr(3), qpu.unif));
    for (0..500) |_| vs.emit(qpu.nop(.none));
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
    try std.testing.expect(vs.code().len > 700);

    // The fragment shader: the colour varyings.
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

    @memcpy(ram[0x20000..][0 .. vs.code().len * 8], std.mem.sliceAsBytes(vs.code()));
    @memcpy(ram[0x1400..][0 .. fs.code().len * 8], std.mem.sliceAsBytes(fs.code()));

    // The vertex shader's uniforms at 0x8000: those it skips, then x and y scaled to 12.4 pixels.
    for (0..skipped_uniforms) |k| std.mem.writeInt(u32, ram[0x8000 + k * 4 ..][0..4], 0xdeadbeef, .little);
    std.mem.writeInt(u32, ram[0x8000 + skipped_uniforms * 4 ..][0..4], @bitCast(@as(f32, 32.0 * 16.0)), .little);
    std.mem.writeInt(u32, ram[0x8000 + (skipped_uniforms + 1) * 4 ..][0..4], @bitCast(@as(f32, 32.0 * 16.0)), .little);

    // A red triangle over the middle of the tile (x, y, r, g, b).
    const verts = [_]f32{
        -1.0, -1.0, 1.0, 0.0, 0.0,
        1.0,  -1.0, 1.0, 0.0, 0.0,
        0.0,  1.0,  1.0, 0.0, 0.0,
    };
    @memcpy(ram[0x2000..][0..@sizeOf(@TypeOf(verts))], std.mem.sliceAsBytes(&verts));

    // The shader record at 0x3000, and at 0x3100 the same with every vertex the first (stride 0):
    // triangles with no area, drawing nothing.
    ram[0x3003] = 3;
    std.mem.writeInt(u32, ram[0x3004..0x3008], 0x1400, .little);
    std.mem.writeInt(u32, ram[0x3008..0x300c], 0x1900, .little);
    ram[0x300e] = 1;
    std.mem.writeInt(u32, ram[0x3010..0x3014], 0x20000, .little);
    std.mem.writeInt(u32, ram[0x3014..0x3018], 0x8000, .little);
    std.mem.writeInt(u32, ram[0x3024..0x3028], 0x2000, .little);
    ram[0x3028] = 19;
    ram[0x3029] = 20;
    @memcpy(ram[0x3100..0x3130], ram[0x3000..0x3030]);
    ram[0x3129] = 0;

    // The binning control list at 0x40000: 299 draws of nothing, then the triangle.
    const empty_draws = 299;
    var bcl: usize = 0x40000;
    ram[bcl] = 6; // START_TILE_BINNING
    bcl += 1;
    ram[bcl] = 103; // VIEWPORT_OFFSET (32.0, 32.0)
    std.mem.writeInt(u16, ram[bcl + 1 ..][0..2], 32 * 16, .little);
    std.mem.writeInt(u16, ram[bcl + 3 ..][0..2], 32 * 16, .little);
    bcl += 5;
    ram[bcl] = 64; // GL_SHADER_STATE (0x3100, 1 attribute)
    std.mem.writeInt(u32, ram[bcl + 1 ..][0..4], 0x3101, .little);
    bcl += 5;
    for (0..empty_draws) |_| {
        ram[bcl] = 33; // GL_ARRAY_PRIMITIVE (triangles, 3 vertices from 0)
        ram[bcl + 1] = 4;
        std.mem.writeInt(u32, ram[bcl + 2 ..][0..4], 3, .little);
        std.mem.writeInt(u32, ram[bcl + 6 ..][0..4], 0, .little);
        bcl += 10;
    }
    ram[bcl] = 64; // GL_SHADER_STATE (0x3000, 1 attribute)
    std.mem.writeInt(u32, ram[bcl + 1 ..][0..4], 0x3001, .little);
    bcl += 5;
    ram[bcl] = 33;
    ram[bcl + 1] = 4;
    std.mem.writeInt(u32, ram[bcl + 2 ..][0..4], 3, .little);
    std.mem.writeInt(u32, ram[bcl + 6 ..][0..4], 0, .little);
    bcl += 10;
    ram[bcl] = 4; // FLUSH
    bcl += 1;

    v3d.write32(0x034, V3d.INT_FLDONE | V3d.INT_FRDONE, ram);
    v3d.write32(0x110, 0x40000, ram); // CT0CA
    v3d.write32(0x108, @intCast(bcl), ram); // CT0EA
    try std.testing.expect((v3d.read32(0x030) & V3d.INT_FLDONE) != 0);
    try std.testing.expectEqual(@as(usize, empty_draws + 1), v3d.draws.items.len);

    // The rendering control list at 0x5000: one 64x64 tile, linear RGBA8888, at 0x10000.
    var rcl: usize = 0x5000;
    ram[rcl] = 113; // TILE_RENDERING_MODE_CONFIG
    std.mem.writeInt(u32, ram[rcl + 1 ..][0..4], 0x10000, .little);
    std.mem.writeInt(u16, ram[rcl + 5 ..][0..2], 64, .little);
    std.mem.writeInt(u16, ram[rcl + 7 ..][0..2], 64, .little);
    std.mem.writeInt(u16, ram[rcl + 9 ..][0..2], 1 << 2, .little);
    rcl += 11;
    ram[rcl] = 114; // CLEAR_COLORS (black)
    std.mem.writeInt(u32, ram[rcl + 1 ..][0..4], 0xff000000, .little);
    std.mem.writeInt(u32, ram[rcl + 9 ..][0..4], 0x00ffffff, .little);
    rcl += 14;
    ram[rcl] = 115; // TILE_COORDINATES (0, 0)
    rcl += 3;
    ram[rcl] = 17; // BRANCH_TO_SUB_LIST
    rcl += 5;
    ram[rcl] = 25; // STORE_MS_TILE_BUFFER_AND_EOF
    rcl += 1;

    v3d.write32(0x114, 0x5000, ram); // CT1CA
    v3d.write32(0x10c, @intCast(rcl), ram); // CT1EA
    try std.testing.expect((v3d.read32(0x030) & V3d.INT_FRDONE) != 0);

    // The triangle, where its vertex shader put it: red in the middle, black beside its apex.
    const center_off = 0x10000 + (32 * 64 + 32) * 4;
    try std.testing.expectEqual(@as(u32, 0xffff0000), std.mem.readInt(u32, ram[center_off..][0..4], .little));
    const outside_off = 0x10000 + (63 * 64 + 0) * 4;
    try std.testing.expectEqual(@as(u32, 0xff000000), std.mem.readInt(u32, ram[outside_off..][0..4], .little));
}

/// Whether screen point (`x`, `y`) is in one of the triangles `pieces`.
fn inAnyPiece(pieces: []const [3]V3d.ShadedVertex, x: f32, y: f32) bool {
    for (pieces) |t| {
        const d0 = (t[1].x - t[0].x) * (y - t[0].y) - (t[1].y - t[0].y) * (x - t[0].x);
        const d1 = (t[2].x - t[1].x) * (y - t[1].y) - (t[2].y - t[1].y) * (x - t[1].x);
        const d2 = (t[0].x - t[2].x) * (y - t[2].y) - (t[0].y - t[2].y) * (x - t[2].x);
        if ((d0 >= 0 and d1 >= 0 and d2 >= 0) or (d0 <= 0 and d1 <= 0 and d2 <= 0)) return true;
    }
    return false;
}

/// A vertex at clip coordinates `c`, shaded as the clipper's scaling for `draw` places it, with one
/// varying `v` (not divided by W).
fn shadedAt(draw: V3d.DrawCall, c: V3d.ClipVertex, v: f32) V3d.ShadedVertex {
    const inv_w = 1.0 / c.w;
    var out: V3d.ShadedVertex = .{
        .x = c.x * inv_w * draw.clip_scale_x / 16.0 + draw.vp_x,
        .y = c.y * inv_w * draw.clip_scale_y / 16.0 + draw.vp_y,
        .z = c.z * inv_w * draw.z_scale + draw.z_offset,
        .inv_w = inv_w,
    };
    out.persp_varyings[0] = v * inv_w;
    return out;
}

test "V3D clips triangles behind the eye at the near plane, as the Pi's clipper does" {
    const draw: V3d.DrawCall = .{ .vp_x = 32, .vp_y = 32, .clip_scale_x = 32 * 16, .clip_scale_y = 32 * 16, .z_scale = 0.5, .z_offset = 0.5 };
    const c = [3]V3d.ClipVertex{
        .{ .x = -0.5, .y = -0.5, .z = 0, .w = 1 },
        .{ .x = 0.5, .y = -0.5, .z = 0, .w = 1 },
        // Behind the eye: its screen position (as the vertex shader writes it) means nothing.
        .{ .x = 0, .y = 1, .z = 0, .w = -1 },
    };
    var verts = [3]V3d.ShadedVertex{ shadedAt(draw, c[0], 0), shadedAt(draw, c[1], 1), .{ .x = 999, .y = -999, .inv_w = -1 } };
    verts[2].persp_varyings[0] = -10;
    var pieces: [V3d.max_clipped][3]V3d.ShadedVertex = undefined;
    const n = V3d.clipTriangle(draw, verts, c, 1, &pieces);
    try std.testing.expect(n >= 1);
    var kept: usize = 0;
    for (pieces[0..n]) |t| for (t) |v| {
        // In front of the eye, and inside the guard band.
        try std.testing.expect(v.inv_w > 0);
        try std.testing.expect(@abs(v.x - 32) <= 2047.01 and @abs(v.y - 32) <= 2047.01);
        if (std.meta.eql(v, verts[0]) or std.meta.eql(v, verts[1])) kept += 1;
    };
    // The corners in front are kept as shaded; what is drawn runs from them away from the eye
    // (through (32, 40), the screen point of clip coordinates (0, 0.0625, 0, 0.25)), not to the
    // corner behind it.
    try std.testing.expect(kept >= 2);
    try std.testing.expect(inAnyPiece(pieces[0..n], 32, 40));
    try std.testing.expect(!inAnyPiece(pieces[0..n], 32, 10));
}

test "V3D clips triangles past the guard band to it, their varyings interpolated in clip space" {
    const draw: V3d.DrawCall = .{ .vp_x = 32, .vp_y = 32, .clip_scale_x = 32 * 16, .clip_scale_y = 32 * 16 };
    // About 6400 pixels across, so their 12.4 screen coordinates would wrap; W differs so the
    // interpolation is perspective-correct. The varying is 1 + x + 2y (in clip coordinates / W).
    const c = [3]V3d.ClipVertex{
        .{ .x = -100, .y = -100, .z = 0, .w = 1 },
        .{ .x = 200, .y = -200, .z = 0, .w = 2 },
        .{ .x = 0, .y = 50, .z = 0, .w = 0.5 },
    };
    var verts: [3]V3d.ShadedVertex = undefined;
    for (&verts, c) |*v, cv| v.* = shadedAt(draw, cv, cv.w + cv.x + 2 * cv.y);
    var pieces: [V3d.max_clipped][3]V3d.ShadedVertex = undefined;
    const n = V3d.clipTriangle(draw, verts, c, 1, &pieces);
    try std.testing.expect(n >= 2);
    for (pieces[0..n]) |t| for (t) |v| {
        try std.testing.expect(@abs(v.x - 32) <= 2047.01 and @abs(v.y - 32) <= 2047.01);
        // Each corner's varying, divided by W (1 + x/W + 2y/W), as at its place on the screen.
        const ndc_x = (v.x - 32) / 32;
        const ndc_y = (v.y - 32) / 32;
        try std.testing.expectApproxEqRel(1 + ndc_x + 2 * ndc_y, v.persp_varyings[0], 1e-3);
    };
    // The middle of the screen is still drawn.
    try std.testing.expect(inAnyPiece(pieces[0..n], 32, 32));
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

test "V3D culls triangles by the way they face, as the configuration bits ask" {
    // A positive screen area (y down) faces forward, unless bit 2 is set.
    const pos: f32 = 10;
    const neg: f32 = -10;
    // Both drawn.
    try std.testing.expect(!V3d.culled(0x03, pos) and !V3d.culled(0x03, neg));
    // Only forward facing: the back culled.
    try std.testing.expect(!V3d.culled(0x01, pos) and V3d.culled(0x01, neg));
    // Only reverse facing.
    try std.testing.expect(V3d.culled(0x02, pos) and !V3d.culled(0x02, neg));
    // With bit 2, a negative area faces forward.
    try std.testing.expect(V3d.culled(0x05, pos) and !V3d.culled(0x05, neg));
}

test "V3D bins more triangles than tiles once did, into each tile in draw order" {
    const v = try std.testing.allocator.create(V3d);
    defer std.testing.allocator.destroy(v);
    v.* = .{};
    defer v.shaded_tris.deinit(V3d.tri_allocator);
    defer v.tile_tris.deinit(V3d.tri_allocator);
    defer v.bin_pairs.deinit(V3d.tri_allocator);

    // 5000 triangles, each in the tile its number picks (some across two).
    for (0..5000) |i| {
        const tx: u32 = @intCast(i % 20);
        const ty: u32 = @intCast((i / 20) % 12);
        const wide: u32 = if (i % 7 == 0) 64 else 0;
        const x0: f32 = @floatFromInt(tx * 64 + 8);
        const y0: f32 = @floatFromInt(ty * 64 + 8);
        const x1: f32 = @floatFromInt(tx * 64 + 16 + wide);
        const verts = [3]V3d.ShadedVertex{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x0, .y = y0 + 8 } };
        try v.shaded_tris.append(V3d.tri_allocator, V3d.ShadedTriangle.init(0, tx * 64 + 8, ty * 64 + 8, tx * 64 + 16 + wide, ty * 64 + 16, (x1 - x0) * 8, verts, 0));
    }
    v.binTriangles();

    var total: usize = 0;
    for (0..32 * 32) |t| {
        const list = v.tile_tris.items[v.tile_tri_start[t]..v.tile_tri_start[t + 1]];
        total += list.len;
        for (list, 0..) |tri, k| {
            const s = &v.shaded_tris.items[tri];
            try std.testing.expect(s.min_x >> 6 <= t % 32 and (s.max_x - 1) >> 6 >= t % 32);
            if (k > 0) try std.testing.expect(list[k - 1] < tri);
        }
    }
    // Each in one tile, and those that are wider in two.
    try std.testing.expectEqual(@as(usize, 5000 + (5000 + 6) / 7), total);
}

/// The vertices of a grid, `grid_size` by `grid_size` at 0x10000 (x and y from -1 to 1, a little
/// uneven, then three colours), with a shader record at 0x3000 that scales them by 300 pixels and
/// passes the colours on: its vertex shader is returned.
fn writeGridScene(ram: []u8) !qpu.Program(32) {
    // The vertex shader: x and y scaled (by uniforms) into pixels, and three varyings.
    var vs: qpu.Program(32) = .{};
    vs.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_write_setup, .value = 0x00001a00 }));
    vs.emit(try qpu.loadImm(.{ .add_dst = qpu.vpm_read_setup, .value = 0x00501a00 }));
    vs.emit(try qpu.mov(qpu.wr(0), qpu.vpm_read));
    vs.emit(try qpu.mov(qpu.wr(1), qpu.vpm_read));
    vs.emit(try qpu.mov(qpu.wa(0), qpu.vpm_read));
    vs.emit(try qpu.mov(qpu.wr(3), qpu.vpm_read));
    vs.emit(try qpu.mov(qpu.wa(2), qpu.vpm_read));
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
    var fs: qpu.Program(4) = .{};
    fs.emit(try qpu.mov(qpu.tlb_color_all, qpu.r(0)));
    fs.end(.fragment);
    @memcpy(ram[0x1000..][0 .. vs.code().len * 8], std.mem.sliceAsBytes(vs.code()));
    @memcpy(ram[0x1400..][0 .. fs.code().len * 8], std.mem.sliceAsBytes(fs.code()));
    std.mem.writeInt(u32, ram[0x1800..0x1804], @bitCast(@as(f32, 300.0 * 16.0)), .little);
    std.mem.writeInt(u32, ram[0x1804..0x1808], @bitCast(@as(f32, 300.0 * 16.0)), .little);

    // The grid's vertices (x, y, r, g, b).
    const n = grid_size;
    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();
    for (0..n) |gy| {
        for (0..n) |gx| {
            const off = 0x10000 + (gy * n + gx) * 20;
            const vals = [5]f32{
                -1 + 2 * @as(f32, @floatFromInt(gx)) / (n - 1) + (rand.float(f32) - 0.5) * 0.01,
                -1 + 2 * @as(f32, @floatFromInt(gy)) / (n - 1) + (rand.float(f32) - 0.5) * 0.01,
                rand.float(f32),
                rand.float(f32),
                rand.float(f32),
            };
            @memcpy(ram[off..][0..20], std.mem.sliceAsBytes(&vals));
        }
    }
    // The shader record: 3 varyings, one attribute of 20 bytes.
    ram[0x3003] = 3;
    std.mem.writeInt(u32, ram[0x3004..0x3008], 0x1400, .little);
    std.mem.writeInt(u32, ram[0x3008..0x300c], 0x1900, .little);
    ram[0x300e] = 1;
    std.mem.writeInt(u32, ram[0x3010..0x3014], 0x1000, .little);
    std.mem.writeInt(u32, ram[0x3014..0x3018], 0x1800, .little);
    std.mem.writeInt(u32, ram[0x3024..0x3028], 0x10000, .little);
    ram[0x3028] = 19;
    ram[0x3029] = 20;

    return vs;
}

const grid_size = 40;

test "V3D shades each vertex once, as shading each triangle's corners would" {
    var v3d = V3d{};
    defer {
        inline for (.{ "shaded_tris", "tile_tris", "vs_corner_slot", "vs_unique", "vs_out", "vs_ok", "vs_slot_key", "vs_slot_gen", "vs_slot_index" }) |f| @field(v3d, f).deinit(V3d.tri_allocator);
    }
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 512 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);

    const vs = try writeGridScene(ram);
    const n = grid_size;
    var n_idx: u32 = 0;
    for (0..n - 1) |gy| {
        for (0..n - 1) |gx| {
            const a: u16 = @intCast(gy * n + gx);
            // Alternately facing each way, so culling has some to cull.
            const quad = if ((gx + gy) % 3 == 0) [6]u16{ a, a + 1, a + n, a + 1, a + n + 1, a + n } else [6]u16{ a, a + n, a + 1, a + 1, a + n, a + n + 1 };
            for (quad) |ix| {
                std.mem.writeInt(u16, ram[0x30000 + n_idx * 2 ..][0..2], ix, .little);
                n_idx += 1;
            }
        }
    }
    // The mesh, culling one way; a strip and a fan through the grid's vertices.
    const draws = [_]V3d.DrawCall{
        .{ .shader_rec_addr = 0x3000, .num_attrs = 1, .mode = 4, .indexed = true, .count = n_idx, .index_buffer_addr = 0x30000, .vp_x = 320, .vp_y = 320, .config_b0 = 0x01 },
        .{ .shader_rec_addr = 0x3000, .num_attrs = 1, .mode = 5, .count = 200, .first_or_offset = 7, .vp_x = 320, .vp_y = 320 },
        .{ .shader_rec_addr = 0x3000, .num_attrs = 1, .mode = 6, .count = 60, .first_or_offset = 400, .vp_x = 320, .vp_y = 320 },
    };
    v3d.draws.clearRetainingCapacity();
    try v3d.draws.appendSlice(V3d.tri_allocator, &draws);
    v3d.prepareDrawsForFrame(ram);
    try std.testing.expect(v3d.overflow_draw_start >= v3d.draws.items.len);

    // Each triangle's corners shaded together, as a batch of their own.
    const vs_decoded_buf = try std.testing.allocator.alloc(qpu_sim.DecodedInst, vs.code().len);
    defer std.testing.allocator.free(vs_decoded_buf);
    const vs_decoded = qpu_sim.decodeProgram(vs.code(), vs_decoded_buf);
    const unifs = [2]u32{ std.mem.readInt(u32, ram[0x1800..0x1804], .little), std.mem.readInt(u32, ram[0x1804..0x1808], .little) };
    var attr_streams: [8]V3d.AttrStream = undefined;
    const attr_info = V3d.decodeAttrStreams(ram, 0x3000, 1, 1, &attr_streams);
    var expected: usize = 0;
    var culled_some = false;
    for (draws, 0..) |draw, draw_idx| {
        const num_tris: u32 = if (draw.mode == 4) draw.count / 3 else draw.count - 2;
        for (0..num_tris) |t| {
            var indices: [3]u32 = undefined;
            for (&indices, 0..) |*ix, c| ix.* = V3d.triangleCorner(ram, draw, @intCast(t), @intCast(c));
            var vpm_in: [32]qpu_sim.Vec = undefined;
            V3d.populateBatchVpmIn(ram, attr_streams[0..attr_info.count], &indices, &vpm_in);
            const res = try qpu_sim.runDecoded(vs_decoded, .{ .uniforms = &unifs, .vpm_in = vpm_in[0..attr_info.vpm_words] });
            var verts: [3]V3d.ShadedVertex = undefined;
            for (&verts, 0..) |*v, lane| {
                const xy = res.vpm_out[0][lane];
                v.* = .{
                    .x = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(xy)))))) / 16.0 + draw.vp_x,
                    .y = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(xy >> 16)))))) / 16.0 + draw.vp_y,
                    .z = @bitCast(res.vpm_out[1][lane]),
                    .inv_w = @bitCast(res.vpm_out[2][lane]),
                };
                for (0..3) |k| v.persp_varyings[k] = @as(f32, @bitCast(res.vpm_out[3 + k][lane])) * v.inv_w;
            }
            const area = (verts[1].x - verts[0].x) * (verts[2].y - verts[0].y) - (verts[1].y - verts[0].y) * (verts[2].x - verts[0].x);
            if (@abs(area) < 1e-6) continue;
            if (V3d.culled(draw.config_b0, area)) {
                culled_some = true;
                continue;
            }
            try std.testing.expect(expected < v3d.shaded_tris.items.len);
            const got = v3d.shaded_tris.items[expected];
            try std.testing.expectEqual(@as(u16, @intCast(draw_idx)), got.draw_idx);
            for (got.v, verts) |g, e| {
                try std.testing.expectEqual(e.x, g.x);
                try std.testing.expectEqual(e.y, g.y);
                try std.testing.expectEqual(e.z, g.z);
                try std.testing.expectEqual(e.inv_w, g.inv_w);
                try std.testing.expectEqualSlices(f32, e.persp_varyings[0..3], g.persp_varyings[0..3]);
            }
            expected += 1;
        }
    }
    try std.testing.expect(culled_some);
    try std.testing.expect(expected > 1000);
    try std.testing.expectEqual(expected, v3d.shaded_tris.items.len);
    // More vertices than one thread shades.
    try std.testing.expect(n * n >= 1024);
}

test "V3D draws lines a pixel wide, across the axis they run along least" {
    const draw: V3d.DrawCall = .{ .mode = 1 };
    for ([_][4]f32{ .{ 10.25, 20.1, 40.25, 31.3 }, .{ 30.3, 5.2, 21.17, 50.4 } }) |l| {
        const verts: [3]V3d.ShadedVertex = .{ .{ .x = l[0], .y = l[1] }, .{ .x = l[2], .y = l[3] }, .{ .x = l[2], .y = l[3] } };
        const no_clip: V3d.ClipVertex = .{ .x = 0, .y = 0, .z = 0, .w = std.math.nan(f32) };
        var pieces: [V3d.max_clipped][3]V3d.ShadedVertex = undefined;
        const n = V3d.primitiveTriangles(draw, verts, @splat(no_clip), 1, &pieces);
        try std.testing.expectEqual(@as(usize, 2), n);
        // Each pixel along the line's longer axis has one pixel of it across the other.
        const x_major = @abs(l[2] - l[0]) >= @abs(l[3] - l[1]);
        const lo: usize = @intFromFloat(@ceil(@min(if (x_major) l[0] else l[1], if (x_major) l[2] else l[3]) - 0.5));
        const hi: usize = @intFromFloat(@floor(@max(if (x_major) l[0] else l[1], if (x_major) l[2] else l[3]) - 0.5));
        for (lo..hi + 1) |along| {
            var hits: usize = 0;
            for (0..64) |across| {
                const a: f32 = @as(f32, @floatFromInt(along)) + 0.5;
                const b: f32 = @as(f32, @floatFromInt(across)) + 0.5;
                if (if (x_major) inAnyPiece(pieces[0..n], a, b) else inAnyPiece(pieces[0..n], b, a)) hits += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), hits);
        }
        // Its coordinate along it (the rasterizer's varying, the fragment shader's first) runs from 0 to 1.
        for (pieces[0..n]) |t| for (t) |v| {
            const at_start = @abs(v.x - l[0]) <= 0.5 and @abs(v.y - l[1]) <= 0.5;
            try std.testing.expectEqual(@as(f32, if (at_start) 0 else 1), v.persp_varyings[0]);
        };
    }
}

test "V3D clips lines behind the eye at the near plane" {
    const draw: V3d.DrawCall = .{ .mode = 1, .vp_x = 32, .vp_y = 32, .clip_scale_x = 32 * 16, .clip_scale_y = 32 * 16 };
    const c = [3]V3d.ClipVertex{
        .{ .x = 0, .y = -0.5, .z = 0, .w = 1 },
        .{ .x = 0, .y = 1, .z = 0, .w = -1 },
        .{ .x = 0, .y = 1, .z = 0, .w = -1 },
    };
    const verts = [3]V3d.ShadedVertex{ shadedAt(draw, c[0], 0), .{ .x = 999, .y = -999, .inv_w = -1 }, .{ .x = 999, .y = -999, .inv_w = -1 } };
    var pieces: [V3d.max_clipped][3]V3d.ShadedVertex = undefined;
    const n = V3d.primitiveTriangles(draw, verts, c, 1, &pieces);
    try std.testing.expectEqual(@as(usize, 2), n);
    for (pieces[0..n]) |t| for (t) |v| {
        try std.testing.expect(v.inv_w > 0);
        try std.testing.expect(@abs(v.x - 32) <= 2047.01 and @abs(v.y - 32) <= 2047.01);
    };
    // It runs from its end in front (at (32, 16)) away from the eye, down the screen.
    try std.testing.expect(inAnyPiece(pieces[0..n], 32, 40));
    try std.testing.expect(!inAnyPiece(pieces[0..n], 32, 10));
    // Wholly behind the eye, none of it is drawn.
    const behind = [3]V3d.ClipVertex{ c[1], c[1], c[1] };
    try std.testing.expectEqual(@as(usize, 0), V3d.primitiveTriangles(draw, verts, behind, 1, &pieces));
}

test "V3D draws lines, line strips and line loops, whichever way they face" {
    var v3d = V3d{};
    defer {
        inline for (.{ "shaded_tris", "tile_tris", "vs_corner_slot", "vs_unique", "vs_out", "vs_ok", "vs_slot_key", "vs_slot_gen", "vs_slot_index" }) |f| @field(v3d, f).deinit(V3d.tri_allocator);
    }
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 512 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);
    _ = try writeGridScene(ram);
    const n = grid_size;
    // A loop round the grid's corners.
    const corners = [4]u16{ 0, n - 1, n * n - 1, n * (n - 1) };
    for (corners, 0..) |ix, i| std.mem.writeInt(u16, ram[0x30000 + i * 2 ..][0..2], ix, .little);

    const draws = [_]V3d.DrawCall{
        // Pairs along the top row; a strip along the sixth; the loop. Culling faces doesn't cull lines.
        .{ .shader_rec_addr = 0x3000, .num_attrs = 1, .mode = 1, .count = n, .vp_x = 320, .vp_y = 320, .config_b0 = 0x01 },
        .{ .shader_rec_addr = 0x3000, .num_attrs = 1, .mode = 3, .count = n, .first_or_offset = 5 * n, .vp_x = 320, .vp_y = 320, .config_b0 = 0x02 },
        .{ .shader_rec_addr = 0x3000, .num_attrs = 1, .mode = 2, .indexed = true, .count = 4, .index_buffer_addr = 0x30000, .vp_x = 320, .vp_y = 320 },
    };
    v3d.draws.clearRetainingCapacity();
    try v3d.draws.appendSlice(V3d.tri_allocator, &draws);
    v3d.prepareDrawsForFrame(ram);
    try std.testing.expect(v3d.overflow_draw_start >= v3d.draws.items.len);

    // Each line drawn as two triangles.
    var per_draw: [3]usize = @splat(0);
    for (v3d.shaded_tris.items) |t| per_draw[t.draw_idx] += 1;
    try std.testing.expectEqual([3]usize{ 2 * (n / 2), 2 * (n - 1), 2 * 4 }, per_draw);

    // The loop's sides, the last back to its start, each drawn through its middle.
    var loop: [8][3]V3d.ShadedVertex = undefined;
    var k: usize = 0;
    for (v3d.shaded_tris.items) |t| if (t.draw_idx == 2) {
        loop[k] = t.v;
        k += 1;
    };
    const Corner = struct {
        // Where the vertex shader puts the grid's vertex `ix` on screen.
        fn at(r: []const u8, ix: u16, axis: usize) f32 {
            const v: f32 = @bitCast(std.mem.readInt(u32, r[0x10000 + @as(usize, ix) * 20 + axis * 4 ..][0..4], .little));
            return @trunc(v * 300 * 16) / 16 + 320;
        }
    };
    for (0..4) |i| {
        const a = corners[i];
        const b = corners[(i + 1) % 4];
        const mx = (Corner.at(ram, a, 0) + Corner.at(ram, b, 0)) / 2;
        const my = (Corner.at(ram, a, 1) + Corner.at(ram, b, 1)) / 2;
        try std.testing.expect(inAnyPiece(&loop, mx, my));
    }
    try std.testing.expect(!inAnyPiece(&loop, 320, 320));
}

test "V3D draws points as squares, their coordinates across them the first varyings" {
    const draw: V3d.DrawCall = .{ .mode = 0 };
    var v: V3d.ShadedVertex = .{ .x = 20.5, .y = 30.5, .point_size = 3 };
    v.persp_varyings[2] = 0.25;
    const no_clip: V3d.ClipVertex = .{ .x = 0, .y = 0, .z = 0, .w = std.math.nan(f32) };
    var pieces: [V3d.max_clipped][3]V3d.ShadedVertex = undefined;
    const n = V3d.primitiveTriangles(draw, @splat(v), @splat(no_clip), 3, &pieces);
    try std.testing.expectEqual(@as(usize, 2), n);
    // 3 pixels by 3, round its middle.
    for (15..26) |y| for (15..26) |x| {
        const inside = x >= 19 and x <= 21 and y >= 29 and y <= 31;
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        try std.testing.expectEqual(inside, inAnyPiece(pieces[0..n], fx + 0.5, fy + 0.5));
    };
    for (pieces[0..n]) |t| for (t) |c| {
        // s and t from 0 at the left and top to 1 at the right and bottom; the vertex shader's
        // varyings after them, as shaded.
        try std.testing.expectEqual((c.x - 19) / 3, c.persp_varyings[0]);
        try std.testing.expectEqual((c.y - 29) / 3, c.persp_varyings[1]);
        try std.testing.expectEqual(@as(f32, 0.25), c.persp_varyings[2]);
    };
    // Without size, or behind the eye, none is drawn.
    v.point_size = 0;
    try std.testing.expectEqual(@as(usize, 0), V3d.primitiveTriangles(draw, @splat(v), @splat(no_clip), 3, &pieces));
    v.point_size = 3;
    const clipped: V3d.DrawCall = .{ .mode = 0, .clip_scale_x = 32 * 16, .clip_scale_y = 32 * 16 };
    try std.testing.expectEqual(@as(usize, 0), V3d.primitiveTriangles(clipped, @splat(v), @splat(.{ .x = 0, .y = 0, .z = 0, .w = -1 }), 3, &pieces));
}

test "V3D sizes points by POINT_SIZE, or by the vertex shader if the shader record says" {
    var v3d = V3d{};
    defer {
        inline for (.{ "shaded_tris", "tile_tris", "vs_corner_slot", "vs_unique", "vs_out", "vs_ok", "vs_slot_key", "vs_slot_gen", "vs_slot_index" }) |f| @field(v3d, f).deinit(V3d.tri_allocator);
    }
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 512 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);
    _ = try writeGridScene(ram);
    const Grid = struct {
        // The grid's vertex `ix`'s attribute word `k` (x, y, r, g, b).
        fn word(r: []const u8, ix: usize, k: usize) f32 {
            return @bitCast(std.mem.readInt(u32, r[0x10000 + ix * 20 + k * 4 ..][0..4], .little));
        }
    };

    for ([_]bool{ false, true }) |per_vertex| {
        // The vertex shader writes x|y, z, 1/W, then r, g, b: read with the point size flag, r is
        // each point's size.
        ram[0x3000] = if (per_vertex) 2 else 0;
        const draw: V3d.DrawCall = .{ .shader_rec_addr = 0x3000, .num_attrs = 1, .mode = 0, .count = 30, .first_or_offset = 100, .vp_x = 320, .vp_y = 320, .point_size = 4, .config_b0 = 0 };
        v3d.draws.clearRetainingCapacity();
        try v3d.draws.append(V3d.tri_allocator, draw);
        v3d.prepareDrawsForFrame(ram);
        // Never culled: each point two triangles.
        try std.testing.expectEqual(@as(usize, 2 * 30), v3d.shaded_tris.items.len);
        for (0..30) |i| {
            const ix = 100 + i;
            const size = if (per_vertex) Grid.word(ram, ix, 2) else 4;
            for (v3d.shaded_tris.items[i * 2 ..][0..2]) |t| for (t.v) |c| {
                try std.testing.expectEqual(size, c.point_size);
                // Its coordinates first, then the vertex shader's varyings (after the size).
                try std.testing.expect(c.persp_varyings[0] == 0 or c.persp_varyings[0] == 1);
                const first: usize = if (per_vertex) 3 else 2;
                try std.testing.expectEqual(Grid.word(ram, ix, first), c.persp_varyings[2]);
                try std.testing.expectEqual(Grid.word(ram, ix, first + 1), c.persp_varyings[3]);
            };
        }
    }
}

test "V3D bins a thin triangle into the tiles it covers, not all its bounds cross" {
    const v = try std.testing.allocator.create(V3d);
    defer std.testing.allocator.destroy(v);
    v.* = .{};
    defer v.shaded_tris.deinit(V3d.tri_allocator);
    defer v.tile_tris.deinit(V3d.tri_allocator);
    defer v.bin_pairs.deinit(V3d.tri_allocator);

    // A line 2 pixels wide from (10, 20) to (1000, 700), as its quad's two triangles.
    const draw: V3d.DrawCall = .{ .mode = 1, .line_width = 2 };
    const ends: [3]V3d.ShadedVertex = .{ .{ .x = 10, .y = 20 }, .{ .x = 1000, .y = 700 }, .{ .x = 1000, .y = 700 } };
    const no_clip: V3d.ClipVertex = .{ .x = 0, .y = 0, .z = 0, .w = std.math.nan(f32) };
    var pieces: [V3d.max_clipped][3]V3d.ShadedVertex = undefined;
    const n = V3d.primitiveTriangles(draw, ends, @splat(no_clip), 0, &pieces);
    for (pieces[0..n]) |p| {
        const area = (p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[1].y - p[0].y) * (p[2].x - p[0].x);
        const min_x: u32 = @intFromFloat(@floor(@min(p[0].x, @min(p[1].x, p[2].x))));
        const min_y: u32 = @intFromFloat(@floor(@min(p[0].y, @min(p[1].y, p[2].y))));
        const max_x: u32 = @intFromFloat(@ceil(@max(p[0].x, @max(p[1].x, p[2].x))));
        const max_y: u32 = @intFromFloat(@ceil(@max(p[0].y, @max(p[1].y, p[2].y))));
        try v.shaded_tris.append(V3d.tri_allocator, V3d.ShadedTriangle.init(0, min_x, min_y, max_x, max_y, area, p, 0));
    }
    v.binTriangles();

    for (v.shaded_tris.items, 0..) |*t, i| {
        var bounds: usize = 0;
        var binned: usize = 0;
        for (0..32) |ty| for (0..32) |tx| {
            const in_bounds = t.min_x >> 6 <= tx and (t.max_x - 1) >> 6 >= tx and t.min_y >> 6 <= ty and (t.max_y - 1) >> 6 >= ty;
            if (in_bounds) bounds += 1;
            const tile = ty * 32 + tx;
            const list = v.tile_tris.items[v.tile_tri_start[tile]..v.tile_tri_start[tile + 1]];
            const in_list = std.mem.indexOfScalar(u32, list, @intCast(i)) != null;
            if (in_list) binned += 1;
            // Binned into each tile one of its pixels is in.
            var covers = false;
            for (0..64) |py| for (0..64) |px| {
                const fx: f32 = @floatFromInt(tx * 64 + px);
                const fy: f32 = @floatFromInt(ty * 64 + py);
                if (inAnyPiece(&.{t.v}, fx + 0.5, fy + 0.5)) covers = true;
            };
            if (covers) try std.testing.expect(in_list);
        };
        // A small part of the tiles its bounds cross.
        try std.testing.expect(binned * 4 < bounds);
    }
}

test "V3D draws fragment shaders that read varyings and drop them on its fast path" {
    // Varyings each into an accumulator, or read on their own and dropped into r3, where the
    // colour is then packed: red from r0, green r1, blue r2.
    const cases = .{
        .{ &[_]?u3{ 0, 1, 2 }, [4]u8{ 2, 1, 0, 0xff } },
        .{ &[_]?u3{ null, 0, 1, 2 }, [4]u8{ 3, 2, 1, 0xff } },
        .{ &[_]?u3{ 0, 1, null, null, 2 }, [4]u8{ 4, 1, 0, 0xff } },
    };
    inline for (cases) |case| {
        var p: qpu.Program(32) = .{};
        for (case[0]) |dst| {
            const acc = dst orelse 3;
            p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(acc), .a = qpu.vary, .b = qpu.frag_w } }));
            if (dst != null) p.emit(try qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(acc), .a = qpu.r(acc), .b = qpu.r(5) } }));
        }
        const one = qpu.smallImmFloat(1.0);
        p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(2), .b = one }, .pack = .{ .mul = .@"8a" } }));
        p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(1), .b = one }, .pack = .{ .mul = .@"8b" } }));
        p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(0), .b = one }, .pack = .{ .mul = .@"8c" } }));
        p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = one, .b = one }, .pack = .{ .mul = .@"8d" } }));
        p.emit(qpu.nop(.wait_scoreboard));
        p.emit(try qpu.mov(qpu.tlb_color_all, qpu.r(3)));
        p.end(.fragment);
        var buf: [64]qpu_sim.DecodedInst = undefined;
        const f = qpu_sim.analyzeFragmentShader(qpu_sim.decodeProgram(p.code(), &buf), &.{});
        try std.testing.expectEqual(qpu_sim.FastFragKind.varying_pack_rgba, f.kind);
        try std.testing.expectEqual(case[1], f.var_idx);
        try std.testing.expectEqual(@as(u32, 0xff000000), f.color & 0xff000000);
    }
    // Packing only some bytes of what isn't known leaves the colour unknown: no fast path.
    var p: qpu.Program(16) = .{};
    p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.vary, .b = qpu.frag_w } }));
    p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.smallImmFloat(1.0), .b = qpu.smallImmFloat(1.0) }, .pack = .{ .mul = .@"8d" } }));
    p.emit(qpu.nop(.wait_scoreboard));
    p.emit(try qpu.mov(qpu.tlb_color_all, qpu.r(3)));
    p.end(.fragment);
    var buf: [32]qpu_sim.DecodedInst = undefined;
    try std.testing.expectEqual(qpu_sim.FastFragKind.none, qpu_sim.analyzeFragmentShader(qpu_sim.decodeProgram(p.code(), &buf), &.{}).kind);
}

test "V3D draws multisampled frames: each pixel its samples averaged, blended a sample at a time" {
    var v3d = V3d{};
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);
    // The grid scene's shaders and record at 0x3000 (colours from varyings), and vertices at
    // 0x2000 of our own: x, y (clip space, 32 pixels to 1 from the middle of a 64-pixel frame), and
    // white.
    _ = try writeGridScene(ram);
    std.mem.writeInt(u32, ram[0x1800..0x1804], @bitCast(@as(f32, 32.0 * 16.0)), .little);
    std.mem.writeInt(u32, ram[0x1804..0x1808], @bitCast(@as(f32, 32.0 * 16.0)), .little);
    std.mem.writeInt(u32, ram[0x3024..0x3028], 0x2000, .little);
    // A triangle left of x = 20.5 (so in pixel 20 its samples 0 and 2, as x 0.375 and 0.125 in it),
    // then one over the whole frame.
    const edge = (20.5 - 32.0) / 32.0;
    const verts = [_]f32{
        edge, -4, 1, 1, 1, edge, 4,  1, 1, 1, -4, 0, 1, 1, 1,
        -4,   -4, 1, 1, 1, 4,    -4, 1, 1, 1, 0,  4, 1, 1, 1,
    };
    @memcpy(ram[0x2000..][0..@sizeOf(@TypeOf(verts))], std.mem.sliceAsBytes(&verts));
    // Its fragment shader: the varyings red, green and blue, opaque.
    var flat: qpu.Program(32) = .{};
    for (0..3) |i| {
        const acc: u3 = @intCast(i);
        flat.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(acc), .a = qpu.vary, .b = qpu.frag_w } }));
        flat.emit(try qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(acc), .a = qpu.r(acc), .b = qpu.r(5) } }));
    }
    const one = qpu.smallImmFloat(1.0);
    flat.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(2), .b = one }, .pack = .{ .mul = .@"8a" } }));
    flat.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(1), .b = one }, .pack = .{ .mul = .@"8b" } }));
    flat.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(0), .b = one }, .pack = .{ .mul = .@"8c" } }));
    flat.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = one, .b = one }, .pack = .{ .mul = .@"8d" } }));
    flat.emit(try qpu.mov(qpu.tlb_color_all, qpu.r(3)));
    flat.end(.fragment);
    @memcpy(ram[0x1400..][0 .. flat.code().len * 8], std.mem.sliceAsBytes(flat.code()));
    // The second's record at 0x3100: no varyings, and a fragment shader that reads each sample in
    // turn and writes its red (and alpha) back to it.
    @memcpy(ram[0x3100..][0..0x30], ram[0x3000..][0..0x30]);
    ram[0x3103] = 0;
    std.mem.writeInt(u32, ram[0x3104..0x3108], 0x1600, .little);
    var fs: qpu.Program(32) = .{};
    fs.emit(try qpu.loadImm(.{ .add_dst = qpu.wr(1), .value = 0xffff0000 }));
    for (0..4) |_| {
        fs.emit(qpu.nop(.color_load));
        fs.emit(try qpu.alu(.{ .add = .{ .op = .@"and", .dst = .{ .periph = qpu.W.tlb_color_ms }, .a = qpu.r(4), .b = qpu.r(1) } }));
    }
    fs.end(.fragment);
    @memcpy(ram[0x1600..][0 .. fs.code().len * 8], std.mem.sliceAsBytes(fs.code()));

    const Frame = struct {
        fn bin(v: *V3d, r: []u8, draws: usize) !void {
            var c: usize = 0x4000;
            r[c] = 6; // START_TILE_BINNING
            c += 1;
            r[c] = 103; // VIEWPORT_OFFSET (32, 32)
            std.mem.writeInt(u16, r[c + 1 ..][0..2], 32 * 16, .little);
            std.mem.writeInt(u16, r[c + 3 ..][0..2], 32 * 16, .little);
            c += 5;
            for (0..draws) |d| {
                r[c] = 64; // GL_SHADER_STATE
                std.mem.writeInt(u32, r[c + 1 ..][0..4], if (d == 0) 0x3001 else 0x3101, .little);
                c += 5;
                r[c] = 33; // GL_ARRAY_PRIMITIVE: a triangle
                r[c + 1] = 4;
                std.mem.writeInt(u32, r[c + 2 ..][0..4], 3, .little);
                std.mem.writeInt(u32, r[c + 6 ..][0..4], @intCast(d * 3), .little);
                c += 10;
            }
            r[c] = 4; // FLUSH
            c += 1;
            v.write32(0x110, 0x4000, r);
            v.write32(0x108, @intCast(c), r);
        }

        /// Renders the frame, 4x multisampled, its samples averaged (`resolve`) or not.
        fn render(v: *V3d, r: []u8, resolve: bool) void {
            var c: usize = 0x5000;
            r[c] = 113; // TILE_RENDERING_MODE_CONFIG: RGBA8888, linear, 4x multisampled
            std.mem.writeInt(u32, r[c + 1 ..][0..4], 0x10000, .little);
            std.mem.writeInt(u16, r[c + 5 ..][0..2], 64, .little);
            std.mem.writeInt(u16, r[c + 7 ..][0..2], 64, .little);
            std.mem.writeInt(u16, r[c + 9 ..][0..2], 1 << 2 | 1 | @as(u16, if (resolve) 1 << 4 else 0), .little);
            c += 11;
            r[c] = 114; // CLEAR_COLORS: black, far
            @memset(r[c + 1 ..][0..13], 0);
            std.mem.writeInt(u32, r[c + 1 ..][0..4], 0xff000000, .little);
            std.mem.writeInt(u32, r[c + 9 ..][0..4], 0x00ffffff, .little);
            c += 14;
            // 32-pixel tiles, 2 by 2.
            for (0..2) |ty| for (0..2) |tx| {
                r[c] = 115;
                r[c + 1] = @intCast(tx);
                r[c + 2] = @intCast(ty);
                r[c + 3] = 17; // BRANCH_TO_SUB_LIST
                std.mem.writeInt(u32, r[c + 4 ..][0..4], 0, .little);
                r[c + 8] = if (tx == 1 and ty == 1) 25 else 24; // STORE_MS_TILE_BUFFER(_AND_EOF)
                c += 9;
            };
            v.write32(0x114, 0x5000, r);
            v.write32(0x10c, @intCast(c), r);
        }

        fn pixel(r: []const u8, x: usize, y: usize) u32 {
            return std.mem.readInt(u32, r[0x10000 + (y * 64 + x) * 4 ..][0..4], .little);
        }
    };

    try Frame.bin(&v3d, ram, 1);
    Frame.render(&v3d, ram, true);
    for ([_]usize{ 5, 31, 32, 60 }) |y| {
        try std.testing.expectEqual(@as(u32, 0xffffffff), Frame.pixel(ram, 19, y));
        // Half its samples white, half black.
        try std.testing.expectEqual(@as(u32, 0xff808080), Frame.pixel(ram, 20, y));
        try std.testing.expectEqual(@as(u32, 0xff000000), Frame.pixel(ram, 21, y));
    }
    // Not averaged, each pixel is its first sample.
    Frame.render(&v3d, ram, false);
    try std.testing.expectEqual(@as(u32, 0xffffffff), Frame.pixel(ram, 20, 31));

    // Each sample read and written in turn: red where it was white.
    try Frame.bin(&v3d, ram, 2);
    Frame.render(&v3d, ram, true);
    try std.testing.expectEqual(@as(u32, 0xffff0000), Frame.pixel(ram, 19, 40));
    try std.testing.expectEqual(@as(u32, 0xff800000), Frame.pixel(ram, 20, 40));
    try std.testing.expectEqual(@as(u32, 0xff000000), Frame.pixel(ram, 21, 40));
}

test "V3D draws a tile stored more than once, its coordinates sent again between the stores" {
    var v3d = V3d{};
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);
    // A white triangle over the whole 64-pixel tile, coloured from its varyings.
    _ = try writeGridScene(ram);
    std.mem.writeInt(u32, ram[0x1800..0x1804], @bitCast(@as(f32, 32.0 * 16.0)), .little);
    std.mem.writeInt(u32, ram[0x1804..0x1808], @bitCast(@as(f32, 32.0 * 16.0)), .little);
    std.mem.writeInt(u32, ram[0x3024..0x3028], 0x2000, .little);
    const verts = [_]f32{ -4, -4, 1, 1, 1, 4, -4, 1, 1, 1, 0, 4, 1, 1, 1 };
    @memcpy(ram[0x2000..][0..@sizeOf(@TypeOf(verts))], std.mem.sliceAsBytes(&verts));
    var flat: qpu.Program(32) = .{};
    for (0..3) |i| {
        const acc: u3 = @intCast(i);
        flat.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(acc), .a = qpu.vary, .b = qpu.frag_w } }));
        flat.emit(try qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(acc), .a = qpu.r(acc), .b = qpu.r(5) } }));
    }
    const one = qpu.smallImmFloat(1.0);
    flat.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(2), .b = one }, .pack = .{ .mul = .@"8a" } }));
    flat.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(1), .b = one }, .pack = .{ .mul = .@"8b" } }));
    flat.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(0), .b = one }, .pack = .{ .mul = .@"8c" } }));
    flat.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = one, .b = one }, .pack = .{ .mul = .@"8d" } }));
    flat.emit(try qpu.mov(qpu.tlb_color_all, qpu.r(3)));
    flat.end(.fragment);
    @memcpy(ram[0x1400..][0 .. flat.code().len * 8], std.mem.sliceAsBytes(flat.code()));

    var c: usize = 0x4000;
    ram[c] = 6; // START_TILE_BINNING
    ram[c + 1] = 103; // VIEWPORT_OFFSET (32, 32)
    std.mem.writeInt(u16, ram[c + 2 ..][0..2], 32 * 16, .little);
    std.mem.writeInt(u16, ram[c + 4 ..][0..2], 32 * 16, .little);
    ram[c + 6] = 64; // GL_SHADER_STATE
    std.mem.writeInt(u32, ram[c + 7 ..][0..4], 0x3001, .little);
    ram[c + 11] = 33; // GL_ARRAY_PRIMITIVE: a triangle
    ram[c + 12] = 4;
    std.mem.writeInt(u32, ram[c + 13 ..][0..4], 3, .little);
    std.mem.writeInt(u32, ram[c + 17 ..][0..4], 0, .little);
    ram[c + 21] = 4; // FLUSH
    c += 22;
    v3d.write32(0x110, 0x4000, ram);
    v3d.write32(0x108, @intCast(c), ram);

    c = 0x5000;
    ram[c] = 113; // TILE_RENDERING_MODE_CONFIG: 64 square, RGBA8888, linear, at 0x10000
    std.mem.writeInt(u32, ram[c + 1 ..][0..4], 0x10000, .little);
    std.mem.writeInt(u16, ram[c + 5 ..][0..2], 64, .little);
    std.mem.writeInt(u16, ram[c + 7 ..][0..2], 64, .little);
    std.mem.writeInt(u16, ram[c + 9 ..][0..2], 1 << 2, .little);
    c += 11;
    ram[c] = 114; // CLEAR_COLORS: black
    @memset(ram[c + 1 ..][0..13], 0);
    std.mem.writeInt(u32, ram[c + 1 ..][0..4], 0xff000000, .little);
    c += 14;
    ram[c] = 115; // TILE_COORDINATES (0, 0)
    ram[c + 1] = 0;
    ram[c + 2] = 0;
    ram[c + 3] = 17; // BRANCH_TO_SUB_LIST
    std.mem.writeInt(u32, ram[c + 4 ..][0..4], 0, .little);
    // STORE_TILE_BUFFER_GENERAL: colour, raster, keeping the tile buffer (no colour clear), to
    // 0x20000; then the coordinates again, and the frame's store.
    ram[c + 8] = 28;
    std.mem.writeInt(u16, ram[c + 9 ..][0..2], 1 | 1 << 13, .little);
    std.mem.writeInt(u32, ram[c + 11 ..][0..4], 0x20000, .little);
    ram[c + 15] = 115;
    ram[c + 16] = 0;
    ram[c + 17] = 0;
    ram[c + 18] = 25; // STORE_MS_TILE_BUFFER_AND_EOF
    c += 19;
    v3d.write32(0x114, 0x5000, ram);
    v3d.write32(0x10c, @intCast(c), ram);

    for ([_]usize{ 0x10000, 0x20000 }) |fb| {
        try std.testing.expectEqual(@as(u32, 0xffffffff), std.mem.readInt(u32, ram[fb + (32 * 64 + 32) * 4 ..][0..4], .little));
    }
}

test "V3D stencil setups test and update stencils" {
    const S = V3d.Stencil;
    // Both faces: write mask 0xff, z-fail incsat, z-pass replace, s-fail keep, always, ref 0x5a.
    const both: u32 = 3 << 30 | 3 << 28 | 3 << 25 | 2 << 22 | 1 << 19 | 7 << 16 | 0x5a << 8 | 0xff;
    const st = S.of(&.{both}, false).?;
    try std.testing.expect(st.passes(0));
    try std.testing.expectEqual(@as(u8, 0x5a), st.apply(st.zpass, 0));
    try std.testing.expectEqual(@as(u8, 0xff), st.apply(st.zfail, 0xff));
    // Front alone, equal to 0x5a with mask 0x0f, write mask 0x3 (code 1), inverting on pass.
    const front: u32 = 1 << 30 | 1 << 28 | 1 << 25 | 5 << 22 | 1 << 19 | 2 << 16 | 0x5a << 8 | 0x0f;
    try std.testing.expect(S.of(&.{front}, true) == null);
    const f = S.of(&.{front}, false).?;
    try std.testing.expect(f.passes(0xfa));
    try std.testing.expect(!f.passes(0x5b));
    try std.testing.expectEqual(@as(u8, 0xf0 | 0x2), f.apply(f.zpass, 0xf1));
    // A write mask word after: the front's 0xf0.
    const masked = S.of(&.{ front, 0x00f0 }, false).?;
    try std.testing.expectEqual(@as(u8, 0x0e), masked.apply(masked.zpass, 0xfe));
}

test "V3D control lists branch, call sub-lists, and wait on the semaphore" {
    var v3d = V3d{};
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);

    // Rendering list first: tile coordinates, then a wait (it runs once binning increments).
    @memcpy(ram[0x3000..][0..4], &[_]u8{ 115, 0, 0, 8 });
    v3d.write32(0x114, 0x3000, ram); // CT1CA
    v3d.write32(0x10c, 0x3004, ram); // CT1EA
    try std.testing.expect(v3d.rcl_waiting != null);
    try std.testing.expectEqual(@as(u32, 1 << 5), v3d.read32(0x104) & (1 << 5));
    try std.testing.expectEqual(@as(u32, 0), v3d.rfc);

    // Binning list: a sub-list (incrementing the semaphore, nested once), then a branch to a
    // flush, where it ends.
    @memcpy(ram[0x1000..][0..10], &[_]u8{ 17, 0x00, 0x20, 0, 0, 16, 0x00, 0x28, 0, 0 });
    @memcpy(ram[0x2000..][0..6], &[_]u8{ 17, 0x00, 0x24, 0, 0, 18 });
    @memcpy(ram[0x2400..][0..2], &[_]u8{ 7, 18 });
    ram[0x2800] = 4;
    v3d.write32(0x110, 0x1000, ram); // CT0CA
    v3d.write32(0x108, 0x2801, ram); // CT0EA
    try std.testing.expectEqual(@as(u32, 1), v3d.bfc);
    try std.testing.expectEqual(@as(u32, 0x2801), v3d.ct0ca);
    // The rendering list ran, the semaphore taken.
    try std.testing.expect(v3d.rcl_waiting == null);
    try std.testing.expectEqual(@as(u32, 1), v3d.rfc);
    try std.testing.expectEqual(@as(u32, 0), v3d.semaphore);
}

test "V3D VG primitives become triangles: RHTs to the X boundary, fans continued" {
    var v3d = V3d{};
    defer v3d.vg_verts.deinit(V3d.tri_allocator);
    defer v3d.draws.deinit(V3d.tri_allocator);
    v3d.cur_vp_x = 100;
    v3d.cur_vp_y = 50;
    v3d.rht_x_boundary = 300;
    const xy = struct {
        fn f(x: i16, y: i16) u32 {
            return @as(u32, @as(u16, @bitCast(x * 16))) | @as(u32, @as(u16, @bitCast(y * 16))) << 16;
        }
    }.f;
    // An RHT: the trapezoid from its edge (100,50)-(110,70) to x = 300, as two triangles.
    v3d.vgPrimitives(1, false, &.{ xy(0, 0), xy(10, 20) });
    try std.testing.expectEqual(@as(usize, 6), v3d.vg_verts.items.len);
    try std.testing.expectEqual([2]f32{ 300, 70 }, v3d.vg_verts.items[2]);
    try std.testing.expectEqual([2]f32{ 300, 50 }, v3d.vg_verts.items[5]);
    // A fan of two triangles, continued by one more (its first two coordinates the last's centre
    // and last vertex).
    v3d.vgPrimitives(6, false, &.{ xy(0, 0), xy(10, 0), xy(10, 10), xy(0, 10) });
    v3d.vgPrimitives(6, true, &.{ 0, 0, xy(-10, 10) });
    try std.testing.expectEqual(@as(usize, 6 + 6 + 3), v3d.vg_verts.items.len);
    const last = v3d.vg_verts.items[12..15];
    try std.testing.expectEqual([2]f32{ 100, 50 }, last[0]);
    try std.testing.expectEqual([2]f32{ 100, 60 }, last[1]);
    try std.testing.expectEqual([2]f32{ 90, 60 }, last[2]);
    try std.testing.expectEqual(@as(usize, 3), v3d.draws.items.len);
    try std.testing.expectEqual(V3d.DrawMode.vg, v3d.draws.items[2].kind);
}

test "V3D renders tile lists written by hand: XY lists, relative codes and branches" {
    const v3d = V3d{};
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);
    // A fragment shader writing its uniform's colour.
    var fs: qpu.Program(8) = .{};
    fs.emit(try qpu.mov(qpu.tlb_color_all, qpu.unif));
    fs.end(.fragment);
    @memcpy(ram[0x1000..][0 .. fs.code().len * 8], std.mem.sliceAsBytes(fs.code()));
    std.mem.writeInt(u32, ram[0x1800..][0..4], 0xff00ff00, .little);
    const xy = struct {
        fn f(x: i16, y: i16) u32 {
            return @as(u32, @as(u16, @bitCast(x * 16))) | @as(u32, @as(u16, @bitCast(y * 16))) << 16;
        }
    }.f;
    // Format XY triangles, an inline VG shader record, then a compressed list: an absolute
    // triangle, a branch to the next 32-byte block, a relative one (sharing two corners), the end.
    var list: [64]u8 = @splat(0);
    var n: usize = 0;
    for ([_]u8{ 56, 2 | 3 << 4, 67 }) |b| {
        list[n] = b;
        n += 1;
    }
    std.mem.writeInt(u32, list[n..][0..4], 0x1000, .little);
    std.mem.writeInt(u32, list[n + 4 ..][0..4], 0x1800, .little);
    n += 8;
    list[n] = 48;
    list[n + 1] = 0x81;
    std.mem.writeInt(u32, list[n + 2 ..][0..4], xy(2, 2), .little);
    std.mem.writeInt(u32, list[n + 6 ..][0..4], xy(20, 2), .little);
    std.mem.writeInt(u32, list[n + 10 ..][0..4], xy(2, 20), .little);
    n += 14;
    // At 0x2000 + n: the branch, one block (32 bytes) on from its block.
    list[n] = 0x82;
    std.mem.writeInt(u16, list[n + 1 ..][0..2], 1, .little);
    @memcpy(ram[0x2000..][0..list.len], &list);
    // The rest, at 0x2020: a triangle sharing (2, 1) of the last, its third 20 pixels right and
    // 10 down from the last's third; the end; HALT.
    const h: u16 = 0 | (20 & 0x7f) << 2 | (10 & 0x7f) << 9;
    std.mem.writeInt(u16, ram[0x2020..][0..2], h, .little);
    ram[0x2022] = 0x80;
    ram[0x2023] = 0;

    var color: [64 * 64]u32 = @splat(0xff000000);
    var depth: [64 * 64]f32 = @splat(1);
    var stencil: [64 * 64]u8 = @splat(0);
    var vg: [64 * 64]u8 = @splat(0);
    var tb: V3d.TileBuffer = .{ .color = &color, .depth = &depth, .stencil = &stencil, .vg_mask = &vg, .depth_valid = true };
    v3d.renderTileList(&tb, ram, 0x2000, 0, 0, 64);
    // Inside the first triangle, and the second (corners (2,20), (20,2), (22,30)).
    try std.testing.expectEqual(@as(u32, 0xff00ff00), color[5 * 64 + 5]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), color[20 * 64 + 16]);
    try std.testing.expectEqual(@as(u32, 0xff000000), color[40 * 64 + 40]);
}

test "V3D runs user programs on QPUs, waiting on each other's semaphores" {
    var v3d = V3d{};
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(ram);
    @memset(ram, 0);
    // The first program waits on semaphore 3; the second raises it, then a host interrupt.
    var waiter: qpu.Program(8) = .{};
    waiter.emit(qpu.semaphore(3, true));
    waiter.end(.vertex);
    var raiser: qpu.Program(8) = .{};
    raiser.emit(qpu.semaphore(3, false));
    raiser.emit(try qpu.alu(.{ .add = .{ .op = .@"or", .dst = .{ .periph = qpu.W.host_int }, .a = qpu.smallImmInt(1), .b = qpu.smallImmInt(1) } }));
    raiser.end(.vertex);
    @memcpy(ram[0x1000..][0 .. waiter.code().len * 8], std.mem.sliceAsBytes(waiter.code()));
    @memcpy(ram[0x2000..][0 .. raiser.code().len * 8], std.mem.sliceAsBytes(raiser.code()));
    v3d.write32(0xe2c, 0xffff, ram); // DBQITE
    v3d.write32(0x430, 0x1000, ram); // SRQPC
    // Waiting: requested, not completed.
    try std.testing.expectEqual(@as(u32, 1 << 8), v3d.read32(0x43c) & 0xffff00);
    v3d.write32(0x430, 0x2000, ram);
    try std.testing.expectEqual(@as(u32, 2 << 16 | 2 << 8), v3d.read32(0x43c) & 0xffff00);
    try std.testing.expect(v3d.read32(0xe30) != 0);
    try std.testing.expect(v3d.irqPending());
}
