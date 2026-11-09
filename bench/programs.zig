//! QPU programs for the feature tests (bare-metal and through Linux), built with FauxPi's encoder
//! (src/vc4/qpu.zig). Each returns its program by value, to be copied where the QPUs read it.

const std = @import("std");
const qpu = @import("qpu");

pub const Prog = qpu.Program(1024);
/// For the long programs of the stress tests.
pub const LongProg = qpu.Program(8192);

/// Appends an instruction, which can't fail to encode for the programs here (a program that
/// doesn't encode is a bug in it).
fn e(p: anytype, inst: qpu.EncodeError!qpu.Inst) void {
    p.emit(inst catch |err| @panic(@errorName(err)));
}

/// `dst` = the 32-bit `value`.
fn li(p: anytype, dst: qpu.Dst, value: u32) void {
    e(p, qpu.loadImm(.{ .add_dst = dst, .value = value }));
}

fn lif(p: anytype, dst: qpu.Dst, value: f32) void {
    li(p, dst, @bitCast(value));
}

const one = qpu.smallImmFloat(1.0);

/// Interpolates the next varying into accumulator `acc` (`vary * W + r5`).
fn varying(p: anytype, acc: u3) void {
    e(p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(acc), .a = qpu.vary, .b = qpu.frag_w } }));
    e(p, qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(acc), .a = qpu.r(acc), .b = qpu.r(5) } }));
}

/// r3 = r0, r1, r2 (red, green, blue, floats) packed as an opaque colour (BGRA in memory).
fn packColour(p: anytype) void {
    e(p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(2), .b = one }, .pack = .{ .mul = .@"8a" } }));
    e(p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(1), .b = one }, .pack = .{ .mul = .@"8b" } }));
    e(p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(0), .b = one }, .pack = .{ .mul = .@"8c" } }));
    e(p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = one, .b = one }, .pack = .{ .mul = .@"8d" } }));
}

/// What a vertex has, in its attributes' words (in order): x, y, z, w (clip space), the point
/// size if `point_size`, then `varyings` words passed on.
pub const VertexLayout = struct {
    varyings: u8,
    point_size: bool = false,
};

/// The vertex shader (or `coordinate`, the coordinate shader) for clip-space vertices: Xs and Ys
/// are x/w and y/w times the first two uniforms (16ths of a pixel from the viewport centre) as
/// 12.4 fixed point, Zs is z/w times the third plus the fourth, then 1/w (from the SFU), the point
/// size, and (vertex shader) the varyings; the coordinate shader writes x, y, z and w first.
pub fn clipVertexShader(layout: VertexLayout, coordinate: bool) Prog {
    var p: Prog = .{};
    // The coordinate shader is given just the position (and point size).
    const varyings: u32 = if (coordinate) 0 else layout.varyings;
    const inputs: u32 = 4 + @as(u32, @intFromBool(layout.point_size)) + varyings;
    li(&p, qpu.vpm_write_setup, 0x00001a00);
    // The inputs read in blocks of up to 16 words (a block read's most).
    li(&p, qpu.vpm_read_setup, (@as(u32, @min(inputs, 16)) & 15) << 20 | 0x1a00);
    // x, y into r0, r1; z, w into ra3, ra4; the point size into ra5; the varyings into ra6...
    e(&p, qpu.mov(qpu.wr(0), qpu.vpm_read));
    e(&p, qpu.mov(qpu.wr(1), qpu.vpm_read));
    e(&p, qpu.mov(qpu.wa(3), qpu.vpm_read));
    e(&p, qpu.mov(qpu.wa(4), qpu.vpm_read));
    if (layout.point_size) e(&p, qpu.mov(qpu.wa(5), qpu.vpm_read));
    for (0..varyings) |k| {
        const word = 4 + @as(u32, @intFromBool(layout.point_size)) + @as(u32, @intCast(k));
        if (word == 16) li(&p, qpu.vpm_read_setup, ((inputs - 16) & 15) << 20 | 0x1a00 | 16);
        e(&p, qpu.mov(qpu.wa(@intCast(6 + k)), qpu.vpm_read));
    }
    // 1/w, ready two instructions later.
    e(&p, qpu.mov(.{ .periph = qpu.W.sfu_recip }, qpu.ra(4)));
    if (coordinate) {
        e(&p, qpu.mov(qpu.vpm_write, qpu.r(0)));
        e(&p, qpu.mov(qpu.vpm_write, qpu.r(1)));
        e(&p, qpu.mov(qpu.vpm_write, qpu.ra(3)));
        e(&p, qpu.mov(qpu.vpm_write, qpu.ra(4)));
    } else {
        p.emit(qpu.nop(.none));
        p.emit(qpu.nop(.none));
    }
    // 1/w in rb2.
    e(&p, qpu.mov(qpu.wb(2), qpu.r(4)));
    p.emit(qpu.nop(.none));
    e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(0), .a = qpu.r(0), .b = qpu.rb(2) } }));
    e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(1), .a = qpu.r(1), .b = qpu.rb(2) } }));
    e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(0), .a = qpu.r(0), .b = qpu.unif } }));
    e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(1), .a = qpu.r(1), .b = qpu.unif } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .ftoi, .dst = qpu.wa(1), .a = qpu.r(0), .b = qpu.r(0) }, .pack = .{ .regfile_a = .@"16a" } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .ftoi, .dst = qpu.wa(1), .a = qpu.r(1), .b = qpu.r(1) }, .pack = .{ .regfile_a = .@"16b" } }));
    e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(2), .a = qpu.ra(3), .b = qpu.rb(2) } }));
    e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(2), .a = qpu.r(2), .b = qpu.unif } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(2), .a = qpu.r(2), .b = qpu.unif } }));
    e(&p, qpu.mov(qpu.vpm_write, qpu.ra(1)));
    e(&p, qpu.mov(qpu.vpm_write, qpu.r(2)));
    e(&p, qpu.mov(qpu.vpm_write, qpu.rb(2)));
    if (layout.point_size) e(&p, qpu.mov(qpu.vpm_write, qpu.ra(5)));
    for (0..varyings) |k| e(&p, qpu.mov(qpu.vpm_write, qpu.ra(@intCast(6 + k))));
    p.end(.vertex);
    return p;
}

/// The varyings red, green and blue, opaque.
pub fn flatFragmentShader() Prog {
    var p: Prog = .{};
    for (0..3) |i| varying(&p, @intCast(i));
    packColour(&p);
    e(&p, qpu.mov(qpu.tlb_color_all, qpu.r(3)));
    p.end(.fragment);
    return p;
}

/// The varyings red, green and blue, opaque, with the fragment's depth written to the tile
/// buffer first (`TLB_Z`): from the rasterizer's (rb15), or, `from_varying`, the fourth varying
/// (0 to 1) as 24-bit fixed point.
pub fn depthFragmentShader(from_varying: bool) Prog {
    var p: Prog = .{};
    for (0..3) |i| varying(&p, @intCast(i));
    if (from_varying) {
        varying(&p, 3);
        lif(&p, qpu.wa(0), 16777215.0);
        p.emit(qpu.nop(.none));
        e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(3), .b = qpu.ra(0) } }));
        e(&p, qpu.alu(.{ .add = .{ .op = .ftoi, .dst = qpu.tlb_z, .a = qpu.r(3), .b = qpu.r(3) } }));
    } else {
        e(&p, qpu.mov(qpu.tlb_z, qpu.frag_z));
    }
    packColour(&p);
    e(&p, qpu.mov(qpu.tlb_color_all, qpu.r(3)));
    p.end(.fragment);
    return p;
}

/// The stencil test set up from `setups` uniforms (`TLB_STENCIL_SETUP` words), then the depth and
/// stencil tests run (`TLB_Z`, the rasterizer's depth), then the varyings' colour.
pub fn stencilFragmentShader(setups: u8) Prog {
    var p: Prog = .{};
    for (0..setups) |_| e(&p, qpu.mov(.{ .periph = qpu.W.tlb_stencil_setup }, qpu.unif));
    for (0..3) |i| varying(&p, @intCast(i));
    e(&p, qpu.mov(qpu.tlb_z, qpu.frag_z));
    packColour(&p);
    e(&p, qpu.mov(qpu.tlb_color_all, qpu.r(3)));
    p.end(.fragment);
    return p;
}

/// The varyings' colour, with the samples of fragments whose fourth varying is below 0.5 not
/// drawn (their MS_FLAGS cleared): a discard.
pub fn discardFragmentShader() Prog {
    var p: Prog = .{};
    for (0..4) |i| varying(&p, @intCast(i));
    lif(&p, qpu.wa(0), 0.5);
    p.emit(qpu.nop(.none));
    e(&p, qpu.alu(.{ .add = .{ .op = .fsub, .dst = qpu.wr(3), .a = qpu.r(3), .b = qpu.ra(0) }, .sf = true }));
    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = .{ .periph = qpu.W.ms_flags }, .a = qpu.smallImmInt(0), .b = qpu.smallImmInt(0), .cond = .ns } }));
    packColour(&p);
    e(&p, qpu.mov(qpu.tlb_color_all, qpu.r(3)));
    p.end(.fragment);
    return p;
}

/// A colour from what the rasterizer gives each fragment: its pixel coordinates (red, green: the
/// low 8 bits of X_PIXEL_COORD and Y_PIXEL_COORD), whether it faces back (blue: REV_FLAG), and
/// its multisample mask (alpha: MS_FLAGS).
pub fn payloadFragmentShader() Prog {
    var p: Prog = .{};
    e(&p, qpu.mov(qpu.wr(0), .{ .a = qpu.R.xy_pixel_coord }));
    e(&p, qpu.mov(qpu.wr(1), .{ .b = qpu.R.xy_pixel_coord }));
    e(&p, qpu.mov(qpu.wr(2), .{ .b = qpu.R.ms_rev_flags }));
    e(&p, qpu.mov(qpu.wr(3), .{ .a = qpu.R.ms_rev_flags }));
    // Each into its byte.
    li(&p, qpu.wa(0), 0xff);
    p.emit(qpu.nop(.none));
    e(&p, qpu.alu(.{ .add = .{ .op = .@"and", .dst = qpu.wr(0), .a = qpu.r(0), .b = qpu.ra(0) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .@"and", .dst = qpu.wr(1), .a = qpu.r(1), .b = qpu.ra(0) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .shl, .dst = qpu.wr(0), .a = qpu.r(0), .b = qpu.smallImmInt(8) } }));
    li(&p, qpu.wa(1), 16);
    e(&p, qpu.alu(.{ .add = .{ .op = .shl, .dst = qpu.wr(1), .a = qpu.r(1), .b = qpu.smallImmInt(0) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .shl, .dst = qpu.wr(0), .a = qpu.r(0), .b = qpu.ra(1) } }));
    // Blue: 0xff if back facing.
    e(&p, qpu.alu(.{ .add = .{ .op = .sub, .dst = qpu.wr(2), .a = qpu.smallImmInt(0), .b = qpu.r(2) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .@"and", .dst = qpu.wr(2), .a = qpu.r(2), .b = qpu.ra(0) } }));
    // Alpha: the mask times 17, in the top byte.
    li(&p, qpu.wb(2), 17 << 24);
    p.emit(qpu.nop(.none));
    e(&p, qpu.alu(.{ .mul = .{ .op = .mul24, .dst = qpu.wr(3), .a = qpu.r(3), .b = qpu.rb(2) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.wr(0), .a = qpu.r(0), .b = qpu.r(1) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.wr(0), .a = qpu.r(0), .b = qpu.r(2) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.wr(0), .a = qpu.r(0), .b = qpu.r(3) } }));
    e(&p, qpu.mov(qpu.tlb_color_all, qpu.r(0)));
    p.end(.fragment);
    return p;
}

/// The coverage the coverage accumulation pipe left in the tile (a Coverage Load), as grey.
pub fn coverageFragmentShader() Prog {
    var p: Prog = .{};
    p.emit(qpu.nop(.none));
    p.emit(qpu.nop(.none));
    p.emit(qpu.nop(.coverage_load));
    e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(0), .a = qpu.r(4), .b = one }, .unpack = .{ .r4 = .@"8a" }, .pack = .{ .mul = .@"8888" } }));
    e(&p, qpu.mov(qpu.tlb_color_all, qpu.r(0)));
    p.end(.fragment);
    return p;
}

/// The varyings' colour, and their red written to the tile's alpha mask (`TLB_ALPHA_MASK`), then
/// the alpha mask read back (an Alpha-Mask Load) into the colour's alpha.
pub fn alphaMaskFragmentShader() Prog {
    var p: Prog = .{};
    for (0..3) |i| varying(&p, @intCast(i));
    e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = .{ .periph = qpu.W.tlb_alpha_mask }, .a = qpu.r(0), .b = one }, .pack = .{ .mul = .@"8888" } }));
    packColour(&p);
    p.emit(qpu.nop(.alpha_mask_load));
    li(&p, qpu.wa(0), 0x00ffffff);
    e(&p, qpu.alu(.{ .add = .{ .op = .@"and", .dst = qpu.wr(3), .a = qpu.r(3), .b = qpu.ra(0) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .shl, .dst = qpu.wr(1), .a = qpu.r(4), .b = qpu.smallImmInt(0) } }));
    li(&p, qpu.wb(1), 24);
    p.emit(qpu.nop(.none));
    e(&p, qpu.alu(.{ .add = .{ .op = .shl, .dst = qpu.wr(1), .a = qpu.r(1), .b = qpu.rb(1) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.tlb_color_all, .a = qpu.r(3), .b = qpu.r(1) } }));
    p.end(.fragment);
    return p;
}

/// The colour in its uniform (VG mode's shaders have no varyings).
pub fn uniformColourFragmentShader() Prog {
    var p: Prog = .{};
    e(&p, qpu.mov(qpu.tlb_color_all, qpu.unif));
    p.end(.fragment);
    return p;
}

/// The varyings red, green and blue, opaque, written to each sample in turn (TLB_COLOUR_MS), the
/// first sample darkened by the second varying: what a multisampled shader writing samples does.
pub fn sampleWritesFragmentShader() Prog {
    var p: Prog = .{};
    for (0..3) |i| varying(&p, @intCast(i));
    packColour(&p);
    li(&p, qpu.wa(0), 0x00202020);
    for (0..4) |s| {
        if (s == 0) {
            e(&p, qpu.alu(.{ .add = .{ .op = .v8subs, .dst = .{ .periph = qpu.W.tlb_color_ms }, .a = qpu.r(3), .b = qpu.ra(0) } }));
        } else {
            e(&p, qpu.mov(.{ .periph = qpu.W.tlb_color_ms }, qpu.r(3)));
        }
    }
    p.end(.fragment);
    return p;
}

/// For a 64-bit (HDR) tile buffer: the varyings red, green and blue (and an alpha of 1), each as
/// a 16-bit float, written as two words (red and green, then blue and alpha).
pub fn hdrFragmentShader() Prog {
    var p: Prog = .{};
    for (0..3) |i| varying(&p, @intCast(i));
    e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wa(0), .a = qpu.r(0), .b = one }, .pack = .{ .regfile_a = .@"16a" } }));
    e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wa(0), .a = qpu.r(1), .b = one }, .pack = .{ .regfile_a = .@"16b" } }));
    e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wa(1), .a = qpu.r(2), .b = one }, .pack = .{ .regfile_a = .@"16a" } }));
    e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wa(1), .a = one, .b = one }, .pack = .{ .regfile_a = .@"16b" } }));
    p.emit(qpu.nop(.none));
    e(&p, qpu.mov(qpu.tlb_color_all, qpu.ra(0)));
    e(&p, qpu.mov(qpu.tlb_color_all, qpu.ra(1)));
    p.end(.fragment);
    return p;
}

/// How a texture is sampled (`textureFragmentShader`).
pub const TextureSample = struct {
    /// TMU 0 or 1.
    unit: u1 = 0,
    /// Coordinates written: s alone (a 1D lookup), s and t, or s, t and r (a cube map's
    /// direction; or the border colour, from its own uniform, in 2D).
    coords: u2 = 2,
    /// The LOD bias written (from the fourth varying).
    bias: bool = false,
    /// All four parameters written (a child image's two extra config words).
    child: bool = false,
    /// Two words read back (RGBA64: red and green, then blue and alpha), combined.
    two_reads: bool = false,
    /// Then a second texture (on the other unit) sampled at the same place, the two multiplied.
    modulate: bool = false,
    /// `TMU_NOSWAP` written first (three instructions before the first TMU write).
    noswap: bool = false,
    /// Four lookups queued before the first is read (the FIFO's depth), their results xored.
    queued: bool = false,
};

/// The texture sampled at the first two varyings (s, t; then r from the third, the bias from the
/// fourth), with the config parameters from uniforms (each TMU write reads the next), written to
/// the tile buffer.
pub fn textureFragmentShader(s: TextureSample) Prog {
    var p: Prog = .{};
    if (s.noswap) {
        e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = .{ .periph = qpu.W.tmu_noswap }, .a = qpu.smallImmInt(1), .b = qpu.smallImmInt(1) } }));
        p.emit(qpu.nop(.none));
        p.emit(qpu.nop(.none));
    }
    const varyings: u3 = if (s.bias) 4 else @max(s.coords, 2);
    for (0..varyings) |i| varying(&p, @intCast(i));
    const lookups: usize = if (s.queued) 4 else 1;
    const units: usize = if (s.modulate) 2 else 1;
    for (0..lookups) |_| {
        for (0..units) |k| {
            const unit: u1 = if (k == 0) s.unit else ~s.unit;
            const base: u6 = if (unit == 0) qpu.W.tmu0_s else qpu.W.tmu1_s;
            if (s.coords >= 2 or s.child) e(&p, qpu.mov(.{ .periph = base + 1 }, qpu.r(1)));
            if (s.coords >= 3 or s.child) e(&p, qpu.mov(.{ .periph = base + 2 }, if (s.coords >= 3) qpu.r(2) else qpu.smallImmInt(0)));
            if (s.bias or s.child) e(&p, qpu.mov(.{ .periph = base + 3 }, if (s.bias) qpu.r(3) else qpu.smallImmInt(0)));
            e(&p, qpu.mov(.{ .periph = base }, qpu.r(0)));
        }
    }
    // Results into rb0 (xored), each read on its unit.
    e(&p, qpu.loadImm(.{ .mul_dst = qpu.wb(0), .value = 0 }));
    for (0..lookups) |_| {
        for (0..units) |k| {
            const unit: u1 = if (k == 0) s.unit else ~s.unit;
            const sig: qpu.Sig = if (unit == 0) .load_tmu0 else .load_tmu1;
            p.emit(qpu.nop(sig));
            if (k == 0) {
                e(&p, qpu.alu(.{ .add = .{ .op = .xor, .dst = qpu.wb(0), .a = qpu.r(4), .b = qpu.rb(0) } }));
            } else {
                e(&p, qpu.alu(.{ .mul = .{ .op = .v8muld, .dst = qpu.wb(0), .a = qpu.r(4), .b = qpu.rb(0) } }));
            }
            if (s.two_reads) {
                p.emit(qpu.nop(sig));
                e(&p, qpu.alu(.{ .add = .{ .op = .xor, .dst = qpu.wb(0), .a = qpu.r(4), .b = qpu.rb(0) } }));
            }
        }
    }
    p.emit(qpu.nop(.none));
    e(&p, qpu.mov(qpu.tlb_color_all, qpu.rb(0)));
    p.end(.fragment);
    return p;
}

/// General memory lookups (the TMU given an address, no config): each fragment reads the word at
/// the first uniform plus 4 times (its pixel X & 1023), and the one 4 KiB on, xored.
pub fn directLookupFragmentShader() Prog {
    var p: Prog = .{};
    e(&p, qpu.mov(qpu.wr(0), .{ .a = qpu.R.xy_pixel_coord }));
    li(&p, qpu.wb(1), 1023);
    e(&p, qpu.mov(qpu.wr(1), qpu.unif));
    e(&p, qpu.alu(.{ .add = .{ .op = .@"and", .dst = qpu.wr(0), .a = qpu.r(0), .b = qpu.rb(1) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .shl, .dst = qpu.wr(0), .a = qpu.r(0), .b = qpu.smallImmInt(2) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = qpu.wr(0), .a = qpu.r(0), .b = qpu.r(1) } }));
    e(&p, qpu.mov(.{ .periph = qpu.W.tmu0_s }, qpu.r(0)));
    li(&p, qpu.wa(2), 4096);
    p.emit(qpu.nop(.none));
    e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = .{ .periph = qpu.W.tmu0_s }, .a = qpu.r(0), .b = qpu.ra(2) } }));
    p.emit(qpu.nop(.load_tmu0));
    e(&p, qpu.mov(qpu.wr(2), qpu.r(4)));
    p.emit(qpu.nop(.load_tmu0));
    e(&p, qpu.alu(.{ .add = .{ .op = .xor, .dst = qpu.tlb_color_all, .a = qpu.r(4), .b = qpu.r(2) } }));
    p.end(.fragment);
    return p;
}

/// A group of QPU instructions `aluFragmentShader` tests.
pub const AluGroup = enum {
    add_float,
    add_int,
    mul,
    vector8,
    unpack_regfile,
    unpack_r4,
    pack_regfile,
    pack_mul,
    conditions,
    branches,
    small_immediates,
    rotation,
    sfu,
    load_immediates,
    special_registers,
    threads,
    sync,
};

/// Operands each fragment gets: ra10, rb10 its X and Y; ra11, rb11 floats from them (one
/// negative); ra12, rb12 integers with high bits set; ra13 a packed word (bytes and halves
/// differing). Results are xored into r3, written to the tile buffer at the end.
fn aluInputs(p: anytype) void {
    e(p, qpu.mov(qpu.wa(10), .{ .a = qpu.R.xy_pixel_coord }));
    e(p, qpu.mov(qpu.wb(10), .{ .b = qpu.R.xy_pixel_coord }));
    p.emit(qpu.nop(.none));
    e(p, qpu.alu(.{ .add = .{ .op = .itof, .dst = qpu.wr(0), .a = qpu.ra(10), .b = qpu.ra(10) } }));
    e(p, qpu.alu(.{ .add = .{ .op = .itof, .dst = qpu.wr(1), .a = qpu.rb(10), .b = qpu.rb(10) } }));
    lif(p, qpu.wr(2), -640.5);
    e(p, qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wa(11), .a = qpu.r(0), .b = qpu.r(2) } }));
    lif(p, qpu.wr(2), 1.375);
    e(p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wb(11), .a = qpu.r(1), .b = qpu.r(2) } }));
    li(p, qpu.wr(2), 0x9e3779b1);
    e(p, qpu.alu(.{ .mul = .{ .op = .mul24, .dst = qpu.wr(0), .a = qpu.ra(10), .b = qpu.r(2) } }));
    e(p, qpu.alu(.{ .add = .{ .op = .xor, .dst = qpu.wa(12), .a = qpu.r(0), .b = qpu.r(2) } }));
    li(p, qpu.wr(2), 0x80001234);
    e(p, qpu.alu(.{ .mul = .{ .op = .mul24, .dst = qpu.wr(1), .a = qpu.rb(10), .b = qpu.r(2) } }));
    e(p, qpu.alu(.{ .add = .{ .op = .sub, .dst = qpu.wb(12), .a = qpu.r(1), .b = qpu.r(2) } }));
    li(p, qpu.wr(2), 0x01010101);
    e(p, qpu.alu(.{ .mul = .{ .op = .mul24, .dst = qpu.wr(0), .a = qpu.ra(10), .b = qpu.r(2) } }));
    e(p, qpu.alu(.{ .add = .{ .op = .xor, .dst = qpu.wa(13), .a = qpu.r(0), .b = qpu.rb(12) } }));
    li(p, qpu.wr(3), 0);
}

/// r3 ^= r0.
fn fold(p: anytype) void {
    e(p, qpu.alu(.{ .add = .{ .op = .xor, .dst = qpu.wr(3), .a = qpu.r(3), .b = qpu.r(0) } }));
}

fn addOp(p: anytype, op: qpu.AddOp, a: qpu.Src, b: qpu.Src) void {
    e(p, qpu.alu(.{ .add = .{ .op = op, .dst = qpu.wr(0), .a = a, .b = b } }));
    fold(p);
}

fn mulOp(p: anytype, op: qpu.MulOp, a: qpu.Src, b: qpu.Src) void {
    e(p, qpu.alu(.{ .mul = .{ .op = op, .dst = qpu.wr(0), .a = a, .b = b } }));
    fold(p);
}

/// Exercises `group`'s instructions on the fragment's operands, the results folded into its
/// colour.
pub fn aluFragmentShader(group: AluGroup) Prog {
    var p: Prog = .{};
    if (group == .unpack_r4) {
        // The tile's colour, read before anything else touches r4.
        p.emit(qpu.nop(.none));
        p.emit(qpu.nop(.none));
        p.emit(qpu.nop(.color_load));
        e(&p, qpu.mov(qpu.wb(20), qpu.r(4)));
    }
    aluInputs(&p);
    const xa = qpu.ra(10);
    const yb = qpu.rb(10);
    const fa = qpu.ra(11);
    const fb = qpu.rb(11);
    const ia = qpu.ra(12);
    const ib = qpu.rb(12);
    switch (group) {
        .add_float => {
            for ([_]qpu.AddOp{ .fadd, .fsub, .fmin, .fmax, .fminabs, .fmaxabs }) |op| {
                addOp(&p, op, fa, fb);
                addOp(&p, op, fb, fa);
            }
            addOp(&p, .ftoi, fa, fa);
            addOp(&p, .ftoi, fb, fb);
            addOp(&p, .itof, ia, ia);
            addOp(&p, .itof, ib, ib);
        },
        .add_int => {
            for ([_]qpu.AddOp{ .add, .sub, .shr, .asr, .ror, .shl, .min, .max, .@"and", .@"or", .xor }) |op| {
                addOp(&p, op, ia, ib);
                addOp(&p, op, ia, yb);
                addOp(&p, op, xa, ib);
            }
            addOp(&p, .not, ia, ia);
            addOp(&p, .clz, ia, ia);
            addOp(&p, .clz, yb, yb);
        },
        .mul => {
            mulOp(&p, .fmul, fa, fb);
            mulOp(&p, .fmul, fa, fa);
            mulOp(&p, .mul24, ia, ib);
            mulOp(&p, .mul24, xa, yb);
        },
        .vector8 => {
            for ([_]qpu.AddOp{ .v8adds, .v8subs }) |op| addOp(&p, op, qpu.ra(13), ib);
            for ([_]qpu.MulOp{ .v8muld, .v8min, .v8max, .v8adds, .v8subs }) |op| {
                mulOp(&p, op, qpu.ra(13), ib);
                mulOp(&p, op, ia, ib);
            }
        },
        .unpack_regfile => {
            // Each unpack of ra13, as integer (or) and as float (fadd) operands.
            for (0..8) |m| {
                const mode: qpu.UnpackMode = @fromBackingInt(@intCast(m));
                e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.wr(0), .a = qpu.ra(13), .b = qpu.ra(13) }, .unpack = .{ .regfile_a = mode } }));
                fold(&p);
                e(&p, qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(0), .a = qpu.ra(13), .b = qpu.r(1) }, .unpack = .{ .regfile_a = mode } }));
                fold(&p);
            }
        },
        .unpack_r4 => {
            // The tile's colour, back in r4, each r4 unpack.
            for (0..8) |m| {
                const mode: qpu.UnpackMode = @fromBackingInt(@intCast(m));
                e(&p, qpu.mov(.{ .periph = qpu.W.sfu_recip }, qpu.smallImmFloat(1.0)));
                p.emit(qpu.nop(.none));
                p.emit(qpu.nop(.none));
                e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(0), .a = qpu.r(4), .b = one }, .unpack = .{ .r4 = mode } }));
                fold(&p);
            }
            e(&p, qpu.mov(qpu.wr(0), qpu.rb(20)));
            fold(&p);
        },
        .pack_regfile => {
            // Each regfile A pack of an integer result (with signed overflow, for the saturating
            // ones) and a float one.
            for (1..16) |m| {
                const mode: qpu.PackA = @fromBackingInt(@intCast(m));
                e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = qpu.wa(14), .a = ia, .b = ib }, .pack = .{ .regfile_a = mode } }));
                p.emit(qpu.nop(.none));
                e(&p, qpu.mov(qpu.wr(0), qpu.ra(14)));
                fold(&p);
                e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wa(14), .a = fa, .b = fb }, .pack = .{ .regfile_a = mode } }));
                p.emit(qpu.nop(.none));
                e(&p, qpu.mov(qpu.wr(0), qpu.ra(14)));
                fold(&p);
            }
        },
        .pack_mul => {
            lif(&p, qpu.wb(14), 1.0 / 1024.0);
            p.emit(qpu.nop(.none));
            for ([_]qpu.PackMul{ .@"8888", .@"8a", .@"8b", .@"8c", .@"8d" }) |m| {
                e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(0), .a = fa, .b = qpu.rb(14) }, .pack = .{ .mul = m } }));
                fold(&p);
            }
        },
        .conditions => {
            // Flags from an integer add (Z, N, C), a float add, and the mul unit (the add a nop);
            // each condition on each unit.
            const setters = [_]qpu.Alu{
                .{ .add = .{ .op = .sub, .dst = qpu.wr(1), .a = ia, .b = ib }, .sf = true },
                .{ .add = .{ .op = .fsub, .dst = qpu.wr(1), .a = fa, .b = fb }, .sf = true },
                .{ .add = .{ .op = .add, .dst = qpu.wr(1), .a = ia, .b = ia }, .sf = true },
                .{ .mul = .{ .op = .fmul, .dst = qpu.wr(1), .a = fa, .b = fb }, .sf = true },
            };
            for (setters) |set| {
                e(&p, qpu.alu(set));
                for (0..8) |c| {
                    const cond: qpu.Cond = @fromBackingInt(@intCast(c));
                    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.wr(0), .a = xa, .b = xa, .cond = cond }, .mul = .{ .op = .v8max, .dst = qpu.wr(2), .a = qpu.r(1), .b = qpu.r(1), .cond = cond } }));
                    fold(&p);
                    e(&p, qpu.alu(.{ .add = .{ .op = .xor, .dst = qpu.wr(3), .a = qpu.r(3), .b = qpu.r(2) } }));
                }
            }
        },
        .branches => {
            // Flags from the element number (the same in every vector): each branch condition,
            // taken or not, skipping an instruction that changes r3 (after the three delay slots).
            e(&p, qpu.mov(qpu.wr(1), .{ .a = qpu.R.elem_qpu }));
            for ([_]i5{ 0, 5, -1 }) |k| {
                e(&p, qpu.alu(.{ .add = .{ .op = .sub, .dst = qpu.wr(2), .a = qpu.r(1), .b = qpu.smallImmInt(k) }, .sf = true }));
                for ([_]qpu.BranchCond{ .all_z, .all_nz, .any_z, .any_nz, .all_n, .all_nn, .any_n, .any_nn, .all_c, .all_nc, .any_c, .any_nc, .always }) |bc| {
                    e(&p, qpu.branch(.{ .cond = bc, .offset = 8 }));
                    p.emit(qpu.nop(.none));
                    p.emit(qpu.nop(.none));
                    p.emit(qpu.nop(.none));
                    // Skipped if taken.
                    e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = qpu.wr(3), .a = qpu.r(3), .b = qpu.smallImmInt(@intCast(@backingInt(bc) & 15)) } }));
                    e(&p, qpu.alu(.{ .add = .{ .op = .ror, .dst = qpu.wr(3), .a = qpu.r(3), .b = qpu.smallImmInt(3) } }));
                }
            }
            // A call and return: the link register written by a branch, branched back to (a
            // register-relative, absolute branch).
            e(&p, qpu.branch(.{ .cond = .always, .offset = 4 * 8, .link = qpu.wa(20) }));
            p.emit(qpu.nop(.none));
            p.emit(qpu.nop(.none));
            p.emit(qpu.nop(.none));
            // Returned to: skip the subroutine.
            e(&p, qpu.branch(.{ .cond = .always, .offset = 5 * 8 }));
            p.emit(qpu.nop(.none));
            p.emit(qpu.nop(.none));
            e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = qpu.wr(3), .a = qpu.r(3), .b = qpu.smallImmInt(7) } }));
            // The subroutine.
            e(&p, qpu.alu(.{ .add = .{ .op = .xor, .dst = qpu.wr(3), .a = qpu.r(3), .b = xa } }));
            e(&p, qpu.branch(.{ .cond = .always, .rel = false, .reg = 20, .offset = 0 }));
            p.emit(qpu.nop(.none));
            p.emit(qpu.nop(.none));
            p.emit(qpu.nop(.none));
        },
        .small_immediates => {
            for (0..48) |v| {
                e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = qpu.wr(0), .a = ia, .b = .{ .imm = @intCast(v) } } }));
                fold(&p);
                e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(0), .a = fa, .b = .{ .imm = @intCast(v) } } }));
                fold(&p);
            }
        },
        .rotation => {
            e(&p, qpu.mov(qpu.wr(1), ia));
            e(&p, qpu.mov(qpu.wr(2), ib));
            p.emit(qpu.nop(.none));
            for (1..16) |n| {
                e(&p, qpu.alu(.{ .mul = .{ .op = .v8max, .dst = qpu.wr(0), .a = qpu.r(1), .b = qpu.r(2) }, .rotate = @intCast(n) }));
                fold(&p);
            }
            // By r5 (element 0 of a value written to r5 replicating element 0).
            e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = .{ .b = qpu.W.acc5 }, .a = xa, .b = xa } }));
            p.emit(qpu.nop(.none));
            e(&p, qpu.alu(.{ .mul = .{ .op = .v8max, .dst = qpu.wr(0), .a = qpu.r(1), .b = qpu.r(2) }, .rotate = qpu.rotate_by_r5 }));
            fold(&p);
        },
        .sfu => {
            for ([_]u6{ qpu.W.sfu_recip, qpu.W.sfu_recipsqrt, qpu.W.sfu_exp, qpu.W.sfu_log }) |sfu| {
                for ([_]qpu.Src{ fa, fb }) |src| {
                    e(&p, qpu.mov(.{ .periph = sfu }, src));
                    p.emit(qpu.nop(.none));
                    p.emit(qpu.nop(.none));
                    e(&p, qpu.mov(qpu.wr(0), qpu.r(4)));
                    fold(&p);
                }
            }
        },
        .load_immediates => {
            li(&p, qpu.wr(0), 0xdeadbeef);
            fold(&p);
            e(&p, qpu.loadImmPerElement(.{ .add_dst = qpu.wr(0), .signed = true, .ls = 0x5a5a, .ms = 0x0ff0 }));
            fold(&p);
            e(&p, qpu.loadImmPerElement(.{ .add_dst = qpu.wr(0), .signed = false, .ls = 0x3c3c, .ms = 0xf00f }));
            fold(&p);
        },
        .special_registers => {
            // The element number; r5 written replicating each quad's first pixel, and element 0;
            // the uniforms read, then the uniforms address moved (to a list of two) and read again.
            e(&p, qpu.mov(qpu.wr(0), .{ .a = qpu.R.elem_qpu }));
            fold(&p);
            e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = .{ .a = qpu.W.acc5 }, .a = ia, .b = ia } }));
            e(&p, qpu.mov(qpu.wr(0), qpu.r(5)));
            fold(&p);
            e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = .{ .b = qpu.W.acc5 }, .a = ia, .b = ia } }));
            e(&p, qpu.mov(qpu.wr(0), qpu.r(5)));
            fold(&p);
            e(&p, qpu.mov(qpu.wr(0), qpu.unif));
            fold(&p);
            e(&p, qpu.mov(qpu.wr(1), qpu.unif));
            e(&p, qpu.mov(.{ .periph = qpu.W.uniforms_address }, qpu.r(1)));
            p.emit(qpu.nop(.none));
            p.emit(qpu.nop(.none));
            e(&p, qpu.mov(qpu.wr(0), qpu.unif));
            fold(&p);
            e(&p, qpu.mov(qpu.wr(0), qpu.unif));
            fold(&p);
        },
        .threads => {
            // Run with the record's fragment shader dual threaded: a thread switch partway, and
            // the last thread switch before the end.
            addOp(&p, .add, ia, ib);
            p.emit(qpu.nop(.thread_switch));
            p.emit(qpu.nop(.none));
            p.emit(qpu.nop(.none));
            addOp(&p, .xor, ia, yb);
            p.emit(qpu.nop(.last_thread_switch));
            p.emit(qpu.nop(.none));
            p.emit(qpu.nop(.none));
        },
        .sync => {
            // A semaphore counted up and back down, and the mutex taken and given back.
            p.emit(qpu.semaphore(7, false));
            p.emit(qpu.semaphore(7, true));
            e(&p, qpu.mov(qpu.wr(0), .{ .a = qpu.R.mutex_acquire }));
            addOp(&p, .add, ia, ib);
            e(&p, qpu.mov(.{ .periph = qpu.W.mutex_release }, qpu.r(0)));
        },
    }
    e(&p, qpu.alu(.{ .mul = .{ .op = .v8max, .dst = qpu.tlb_color_all, .a = qpu.r(3), .b = qpu.r(3) } }));
    p.end(.fragment);
    return p;
}

/// Reads (to no register) what `src` holds: a wait on VPM_LD_WAIT or VPM_ST_WAIT, or the mutex.
fn readTo(p: anytype, dst: qpu.Dst, src: qpu.Src) void {
    e(p, qpu.mov(dst, src));
}

const vpm_ld_addr: qpu.Dst = .{ .a = qpu.W.vpm_addr };
const vpm_st_addr: qpu.Dst = .{ .b = qpu.W.vpm_addr };
const vpm_ld_wait: qpu.Src = .{ .a = 50 };
const vpm_st_wait: qpu.Src = .{ .b = 50 };

/// A QPU user program (queued through SRQPC), its uniforms: the input address, the output
/// address, its index (0 to 11), and a shared counter's address. It loads its 8 rows of 16 words
/// (512 bytes on from the input by its index) into its own 8 VPM rows by DMA (VDR), reads them
/// (a VPM generic block read), multiplies each word by 3 and adds the word a general memory
/// lookup (TMU) finds at the input plus its element, writes them back (a generic block write) and
/// stores them to the output by DMA (VDW); then, holding the mutex, adds 1 to the counter's words.
/// The master (queued last) then waits for the other 11 (their semaphore 5 counts) and raises a
/// host interrupt.
pub fn userProgram(master: bool) Prog {
    var p: Prog = .{};
    e(&p, qpu.mov(qpu.wa(0), qpu.unif)); // input
    e(&p, qpu.mov(qpu.wb(1), qpu.unif)); // output
    e(&p, qpu.mov(qpu.wa(2), qpu.unif)); // index
    e(&p, qpu.mov(qpu.wb(3), qpu.unif)); // counter
    // Its first VPM row (8 a program), and its byte offset in memory.
    e(&p, qpu.alu(.{ .add = .{ .op = .shl, .dst = qpu.wr(0), .a = qpu.ra(2), .b = qpu.smallImmInt(3) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .shl, .dst = qpu.wr(1), .a = qpu.ra(2), .b = qpu.smallImmInt(9) } }));
    e(&p, qpu.mov(qpu.wa(4), qpu.r(0))); // row
    e(&p, qpu.mov(qpu.wb(5), qpu.r(1))); // offset
    // VDR: 32-bit, a 64-byte pitch, 16 words a row, 8 rows, horizontal, at its row.
    e(&p, qpu.alu(.{ .add = .{ .op = .shl, .dst = qpu.wr(2), .a = qpu.r(0), .b = qpu.smallImmInt(4) } }));
    li(&p, qpu.wr(1), 0x8308_1000);
    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.vpm_read_setup, .a = qpu.r(1), .b = qpu.r(2) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = vpm_ld_addr, .a = qpu.ra(0), .b = qpu.rb(5) } }));
    readTo(&p, .nop, vpm_ld_wait);
    // A general memory lookup: the word at the input plus 4 times its element.
    e(&p, qpu.mov(qpu.wr(2), .{ .a = qpu.R.elem_qpu }));
    e(&p, qpu.alu(.{ .add = .{ .op = .shl, .dst = qpu.wr(2), .a = qpu.r(2), .b = qpu.smallImmInt(2) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = .{ .periph = qpu.W.tmu0_s }, .a = qpu.ra(0), .b = qpu.r(2) } }));
    p.emit(qpu.nop(.load_tmu0));
    e(&p, qpu.mov(qpu.wb(6), qpu.r(4)));
    // Generic read of its 8 rows, then a write of them back.
    li(&p, qpu.wr(1), 0x0080_1a00);
    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.vpm_read_setup, .a = qpu.r(1), .b = qpu.r(0) } }));
    li(&p, qpu.wr(1), 0x0000_1a00);
    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.vpm_write_setup, .a = qpu.r(1), .b = qpu.r(0) } }));
    li(&p, qpu.wr(3), 3);
    for (0..8) |_| {
        e(&p, qpu.mov(qpu.wr(2), qpu.vpm_read));
        e(&p, qpu.alu(.{ .mul = .{ .op = .mul24, .dst = qpu.wr(2), .a = qpu.r(2), .b = qpu.r(3) } }));
        e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = qpu.vpm_write, .a = qpu.r(2), .b = qpu.rb(6) } }));
    }
    // VDW: 8 rows of 16 words, horizontal, from its row; rows packed in memory.
    e(&p, qpu.alu(.{ .add = .{ .op = .shl, .dst = qpu.wr(2), .a = qpu.ra(4), .b = qpu.smallImmInt(7) } }));
    li(&p, qpu.wr(1), 2 << 30 | 8 << 23 | 16 << 16 | 1 << 14);
    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.vpm_write_setup, .a = qpu.r(1), .b = qpu.r(2) } }));
    li(&p, qpu.vpm_write_setup, 3 << 30);
    e(&p, qpu.mov(qpu.wr(2), qpu.rb(5)));
    e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = vpm_st_addr, .a = qpu.rb(1), .b = qpu.r(2) } }));
    readTo(&p, .nop, vpm_st_wait);
    // The counter, under the mutex: loaded (one row, into its last VPM row), 1 added, stored.
    readTo(&p, .nop, .{ .a = qpu.R.mutex_acquire });
    e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = qpu.wr(0), .a = qpu.ra(4), .b = qpu.smallImmInt(7) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .shl, .dst = qpu.wr(2), .a = qpu.r(0), .b = qpu.smallImmInt(4) } }));
    li(&p, qpu.wr(1), 0x8301_1000);
    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.vpm_read_setup, .a = qpu.r(1), .b = qpu.r(2) } }));
    e(&p, qpu.mov(vpm_ld_addr, qpu.rb(3)));
    readTo(&p, .nop, vpm_ld_wait);
    li(&p, qpu.wr(1), 0x0010_1a00);
    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.vpm_read_setup, .a = qpu.r(1), .b = qpu.r(0) } }));
    li(&p, qpu.wr(1), 0x0000_1a00);
    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.vpm_write_setup, .a = qpu.r(1), .b = qpu.r(0) } }));
    e(&p, qpu.mov(qpu.wr(2), qpu.vpm_read));
    e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = qpu.vpm_write, .a = qpu.r(2), .b = qpu.smallImmInt(1) } }));
    e(&p, qpu.alu(.{ .add = .{ .op = .shl, .dst = qpu.wr(2), .a = qpu.r(0), .b = qpu.smallImmInt(7) } }));
    li(&p, qpu.wr(1), 2 << 30 | 1 << 23 | 16 << 16 | 1 << 14);
    e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = qpu.vpm_write_setup, .a = qpu.r(1), .b = qpu.r(2) } }));
    e(&p, qpu.mov(vpm_st_addr, qpu.rb(3)));
    readTo(&p, .nop, vpm_st_wait);
    e(&p, qpu.mov(.{ .periph = qpu.W.mutex_release }, qpu.r(0)));
    if (master) {
        for (0..11) |_| p.emit(qpu.semaphore(5, true));
        e(&p, qpu.alu(.{ .add = .{ .op = .@"or", .dst = .{ .periph = qpu.W.host_int }, .a = qpu.smallImmInt(1), .b = qpu.smallImmInt(1) } }));
    } else {
        p.emit(qpu.semaphore(5, false));
    }
    p.end(.vertex);
    return p;
}

/// A user program of the VPM's access modes: 16 rows loaded by DMA (VDR, 32-bit; then 16-bit and
/// 8-bit, vertical), read back as 8, 16 and 32-bit vectors, laned and packed, horizontal and
/// vertical, their xor written as rows, stored by DMA (VDW, horizontal, then vertical 16-bit and
/// 8-bit). Uniforms: the input and output addresses.
pub fn vpmModesProgram() Prog {
    var p: Prog = .{};
    e(&p, qpu.mov(qpu.wa(0), qpu.unif));
    e(&p, qpu.mov(qpu.wb(1), qpu.unif));
    // VDR loads: 32-bit horizontal, 16 rows at row 0; 16-bit vertical at row 16; 8-bit vertical at
    // row 32 (each from 1 KiB on).
    const loads = [_][2]u32{ .{ 0x8000_0000 | 3 << 24 | 0 << 20 | 0 << 16 | 1 << 12 | 0, 0 }, .{ 0x8000_0000 | 2 << 28 | 3 << 24 | 0 << 16 | 1 << 12 | 1 << 11 | 16 << 4, 1024 }, .{ 0x8000_0000 | 4 << 28 | 3 << 24 | 0 << 16 | 1 << 12 | 1 << 11 | 32 << 4, 2048 } };
    for (loads) |ld| {
        li(&p, qpu.vpm_read_setup, ld[0]);
        li(&p, qpu.wr(1), ld[1]);
        e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = vpm_ld_addr, .a = qpu.ra(0), .b = qpu.r(1) } }));
        readTo(&p, .nop, vpm_ld_wait);
    }
    // Generic reads in each mode (4 vectors each), xored into r3; each mode's result written to its
    // own row from row 48.
    const modes = [_]u32{
        0x1a00 | 0, // 32-bit horizontal
        0x1000 | 0x200 | 0, // 32-bit vertical
        0x1800 | 0x100 | 0x400 | (16 << 1), // 16-bit horizontal laned
        0x1800 | 0x100 | (16 << 1) | 1, // 16-bit horizontal packed
        0x1000 | 0x100 | 0x400 | (16 << 1), // 16-bit vertical laned
        0x1800 | 0x000 | 0x400 | (32 << 2) | 2, // 8-bit horizontal laned
        0x1800 | 0x000 | (32 << 2) | 3, // 8-bit horizontal packed
        0x1000 | 0x000 | (32 << 2) | 1, // 8-bit vertical packed
    };
    for (modes, 0..) |m, i| {
        li(&p, qpu.vpm_read_setup, 4 << 20 | m);
        li(&p, qpu.wr(3), 0);
        p.emit(qpu.nop(.none));
        p.emit(qpu.nop(.none));
        for (0..4) |_| {
            e(&p, qpu.mov(qpu.wr(2), qpu.vpm_read));
            e(&p, qpu.alu(.{ .add = .{ .op = .xor, .dst = qpu.wr(3), .a = qpu.r(3), .b = qpu.r(2) } }));
        }
        li(&p, qpu.vpm_write_setup, 0x1a00 | @as(u32, @intCast(48 + i)));
        e(&p, qpu.mov(qpu.vpm_write, qpu.r(3)));
    }
    // Generic writes in 16 and 8-bit modes, to rows 56 on.
    for ([_]u32{ 0x1800 | 0x100 | 0x400 | (56 << 1), 0x1800 | 0x100 | (57 << 1) | 1, 0x1800 | 0x000 | (58 << 2) | 2, 0x1000 | 0x200 | 0x30 }) |m| {
        li(&p, qpu.vpm_write_setup, m);
        e(&p, qpu.mov(qpu.vpm_write, .{ .a = qpu.R.elem_qpu }));
    }
    // VDW stores: rows 48 to 63 horizontal 32-bit; then a vertical 16-bit block and an 8-bit one.
    const stores = [_][2]u32{ .{ 2 << 30 | 16 << 23 | 16 << 16 | 1 << 14 | (48 << 7), 0 }, .{ 2 << 30 | 8 << 23 | 16 << 16 | (16 << 7) | 2, 1024 }, .{ 2 << 30 | 8 << 23 | 16 << 16 | (32 << 7) | 4, 2048 } };
    for (stores) |st| {
        li(&p, qpu.vpm_write_setup, st[0]);
        li(&p, qpu.vpm_write_setup, 3 << 30 | 1 << 16);
        li(&p, qpu.wr(1), st[1]);
        e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = vpm_st_addr, .a = qpu.rb(1), .b = qpu.r(1) } }));
        readTo(&p, .nop, vpm_st_wait);
    }
    p.end(.vertex);
    return p;
}

test "every program encodes" {
    inline for (.{ false, true }) |c| {
        for (0..5) |v| _ = clipVertexShader(.{ .varyings = @intCast(v) }, c);
        _ = clipVertexShader(.{ .varyings = 3, .point_size = true }, c);
    }
    _ = flatFragmentShader();
    _ = depthFragmentShader(false);
    _ = depthFragmentShader(true);
    _ = stencilFragmentShader(3);
    _ = discardFragmentShader();
    _ = payloadFragmentShader();
    _ = coverageFragmentShader();
    _ = alphaMaskFragmentShader();
    _ = uniformColourFragmentShader();
    _ = sampleWritesFragmentShader();
    _ = hdrFragmentShader();
    for ([_]TextureSample{ .{}, .{ .unit = 1 }, .{ .coords = 3 }, .{ .bias = true }, .{ .child = true }, .{ .two_reads = true }, .{ .modulate = true }, .{ .noswap = true }, .{ .queued = true } }) |s| _ = textureFragmentShader(s);
    _ = directLookupFragmentShader();
    for (std.enums.values(AluGroup)) |g| _ = aluFragmentShader(g);
    _ = userProgram(false);
    _ = userProgram(true);
    _ = vpmModesProgram();
    _ = clipVertexShader(.{ .varyings = 20 }, false);
    _ = manyVaryingsFragmentShader(20);
    _ = longFragmentShader(400);
}

/// `varyings` varyings summed into a colour (red, green and blue each a third of them).
pub fn manyVaryingsFragmentShader(varyings: u8) Prog {
    var p: Prog = .{};
    li(&p, qpu.wr(0), 0);
    li(&p, qpu.wr(1), 0);
    li(&p, qpu.wr(2), 0);
    for (0..varyings) |i| {
        varying(&p, 3);
        const acc: u3 = @intCast(i % 3);
        e(&p, qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(acc), .a = qpu.r(acc), .b = qpu.r(3) } }));
    }
    lif(&p, qpu.wa(0), 3.0 / 20.0);
    p.emit(qpu.nop(.none));
    for (0..3) |i| e(&p, qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(@intCast(i)), .a = qpu.r(@intCast(i)), .b = qpu.ra(0) } }));
    packColour(&p);
    e(&p, qpu.mov(qpu.tlb_color_all, qpu.r(3)));
    p.end(.fragment);
    return p;
}

/// A long fragment shader: `blocks` blocks of arithmetic (float and integer, the SFU) on the
/// fragment's coordinates and varyings, with a counted loop (a branch back) around each eighth
/// of them, folded into its colour.
pub fn longFragmentShader(blocks: usize) LongProg {
    var p: LongProg = .{};
    for (0..3) |i| varying(&p, @intCast(i));
    e(&p, qpu.mov(qpu.wa(10), .{ .a = qpu.R.xy_pixel_coord }));
    e(&p, qpu.mov(qpu.wb(10), .{ .b = qpu.R.xy_pixel_coord }));
    li(&p, qpu.wr(3), 0);
    var b: usize = 0;
    while (b < blocks) : (b += 8) {
        // A loop of 3 passes over 8 blocks, counted down in ra16.
        li(&p, qpu.wa(16), 3);
        const loop_start = p.len;
        for (0..@min(8, blocks - b)) |k| {
            e(&p, qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(0), .a = qpu.ra(10), .b = qpu.r(1) }, .mul = .{ .op = .fmul, .dst = qpu.wr(1), .a = qpu.r(0), .b = qpu.r(2) } }));
            e(&p, qpu.mov(.{ .periph = if (k % 2 == 0) qpu.W.sfu_recipsqrt else qpu.W.sfu_log }, qpu.r(1)));
            e(&p, qpu.alu(.{ .add = .{ .op = .xor, .dst = qpu.wr(3), .a = qpu.r(3), .b = qpu.rb(10) } }));
            e(&p, qpu.alu(.{ .add = .{ .op = .ror, .dst = qpu.wr(3), .a = qpu.r(3), .b = qpu.smallImmInt(5) } }));
            e(&p, qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(2), .a = qpu.r(2), .b = qpu.r(4) } }));
            e(&p, qpu.alu(.{ .add = .{ .op = .add, .dst = qpu.wr(3), .a = qpu.r(3), .b = qpu.ra(10) } }));
        }
        e(&p, qpu.alu(.{ .add = .{ .op = .sub, .dst = qpu.wa(16), .a = qpu.ra(16), .b = qpu.smallImmInt(1) }, .sf = true }));
        const back: i32 = -@as(i32, @intCast((p.len + 4 - loop_start) * 8));
        e(&p, qpu.branch(.{ .cond = .all_nz, .offset = back }));
        p.emit(qpu.nop(.none));
        p.emit(qpu.nop(.none));
        p.emit(qpu.nop(.none));
    }
    e(&p, qpu.alu(.{ .mul = .{ .op = .v8max, .dst = qpu.tlb_color_all, .a = qpu.r(3), .b = qpu.r(3) } }));
    p.end(.fragment);
    return p;
}
